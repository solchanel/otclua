# vBot 4.8 JSON config compatibility — READ and WRITE contract

Scope: the four JSON file families a foreign client must round-trip without breaking the
real OTClient + vBot 4.8 GUI:

| File | Path (relative to the bot config dir) |
|---|---|
| AttackBot | `vBot_configs/profile_<1..10>/AttackBot.json` |
| HealBot | `vBot_configs/profile_<1..10>/HealBot.json` |
| Supplies | `vBot_configs/profile_<1..10>/Supplies.json` |
| TargetBot | `targetbot_configs/<name>.json` |
| Bot storage | `storage/profile_<1..10>.json` |

Live root on this machine:
`D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/`

All line citations are to files under
`D:/Claude/otclient_mehah1530/otclient/` unless the full path is spelled out.

Everything here was verified by reading the consuming Lua, and by **running vBot's own
decoder/encoder** (`modules/corelib/json.lua`) under
`build/win-local/vcpkg_installed/x64-windows-static-release/tools/luajit/luajit.exe`
(LuaJIT 2.1.1781602682). Real transcripts are pasted in §7.

---

## 0. The single most important fact

**vBot's own encoder cannot reproduce its own files byte-for-byte.**
A decode → encode round trip through `json.encode` reorders every object's keys, and the
order is different on every process start (LuaJIT seeds its string hash per process). See
§7.1 and §7.2 for three runs of the same script producing three different key orders.

Consequence for us: **byte-identity is not the bar and never can be.** The bar is
*semantic* identity — same keys, same values, same array order. Our writer is correct if
`json.decode(ours)` deep-equals `json.decode(theirs)`. §7.3 shows vBot's own round trip
meets exactly that bar and nothing stronger.

---

## 1. Who loads, who writes, and with which encoder

### 1.1 The encoder is rxi json.lua 0.1.2, compact, and the `2` argument is a no-op

`modules/corelib/json.lua` is rxi's json.lua (`json._version = '0.1.2'`, json.lua:25).
It is loaded globally by corelib and handed to the bot sandbox verbatim at
`mods/game_bot/executor.lua:121` (`context.json = json`). There is no second JSON
implementation anywhere in `mods/game_bot`.

```lua
-- modules/corelib/json.lua:131
function json.encode(val)
    return (encode(val))
end
```

`json.encode` takes **one** parameter. Every vBot call site passes an indent argument —
`json.encode(configTable, 2)` at `profiles/bot/vBot_4.8/vBot/configs.lua:86`,
`json.encode(botStorage, 2)` at `mods/game_bot/bot.lua:310`,
`json.encode(value, 2)` at `mods/game_bot/functions/config.lua:108` — and **it is silently
discarded**. Output is always minified: no spaces, no newlines, no indentation.

`encode_table` (json.lua:59-100) joins with `','` and `':'` with no padding; `escape_char`
(json.lua:51) and `encode_number` (json.lua:106-112) are the only value formatters.

### 1.2 Bytes on disk

`g_resources.writeFileContents` is a raw byte write
(`src/framework/core/resourcemanager.cpp:665-668` → `writeFileBuffer(..., data.size())`),
and `readFileContents` returns the raw bytes (`resourcemanager.cpp:559-588`).
**No trailing newline, no BOM, no encoding transform.** Verified on the user's files —
`AttackBot.json`, `turter.json` and `storage/profile_1.json` all end in `}` with no `\n`.

### 1.3 Per-file ownership

| File | Loader | Writer |
|---|---|---|
| `HealBot.json` | `vBot/configs.lua:31-39` → global `HealBotConfig` | `vBotConfigSave("heal")` — `vBot/configs.lua:63-97` |
| `AttackBot.json` | `vBot/configs.lua:42-50` → global `AttackBotConfig` | `vBotConfigSave("atk")` — same function |
| `Supplies.json` | `vBot/configs.lua:53-61` → global `SuppliesConfig` | `vBotConfigSave("supply")` — same function |
| `targetbot_configs/*.json` | `Config.load` (`mods/game_bot/functions/config.lua:55-81`), driven by `Config.setup` (config.lua:130-269), consumed in `targetbot/target.lua:131-152` | `Config.save` (`config.lua:95-111`) via `TargetBot.save()` (`targetbot/target.lua:238-245`) |
| `storage/profile_N.json` | `mods/game_bot/bot.lua:273-281` → sandbox global `storage` (`executor.lua:29`) | `save()` — `bot.lua:298-321` |

The three vBot files are chosen by `g_settings.getNumber('profile')` at
`vBot/configs.lua:20`; storage by the same setting at `bot.lua:273`. On this machine only
`profile_1` has files.

### 1.4 When writes happen — and the clobber window

* `vBotConfigSave` fires **immediately** on every relevant UI interaction
  (e.g. `AttackBot.lua:1767`, `1788`, `2463`, `2490`, `2496`;
  `HealBot.lua`; `Conditions.lua:64`, `:80`; `supplies.lua:77`, `:226`, `:246`, `:266`, `:299`).
* `Config.save` for targetbot fires on every list/looting edit (`targetbot/target.lua:158`,
  `169`, `178`; `targetbot/looting.lua:23`, `31`, `39`, `45`, `51`).
* **`storage/profile_N.json` is written only on `terminate()` (bot.lua:95), `refresh()`
  (bot.lua:210) and `offline()` (bot.lua:347).** It is *not* written continuously.

> **MUST:** never write any of these files while the real client is running with that
> profile loaded. vBot holds the whole tree in memory and rewrites the file wholesale from
> memory on the next UI touch (or, for storage, on logout), silently discarding whatever we
> wrote. Edit only with the client closed, or reload the bot afterwards.

### 1.5 What a malformed file actually does — it is worse than the code suggests

`vBot/configs.lua:36`, `:47`, `:58` and `:89` all do `return onError(...)` on failure.
**`onError` does not exist in the bot sandbox.** `executor.lua:21` creates `local context = {}`
with no metatable, and the only `onError` in `mods/game_bot` is an unrelated websocket field
(`functions/server.lua:69`). So a decode failure raises
`attempt to call global 'onError' (a nil value)` out of `configs.lua`, which propagates out of
the chunk into `executeBot`'s pcall at `bot.lua:275-281` and **kills the entire bot script
load**, not just that config.

Contrast: the *targetbot* path is safe — `Config.load` catches and returns `{}`
(`functions/config.lua:63-66`), and the sandbox's `error()` is a message printer, not Lua's
`error` (`executor.lua:162`: `context.error = function(text) return msgCallback("error", ...) end`).
So `TargetBot.Creature.addConfig`'s rejection at `targetbot/creature.lua:16-18` **drops that one
entry and keeps loading the rest**.

---

## 2. `AttackBot.json`

### 2.1 Top level

```
{
  "currentBotProfile": <number 1..5>,
  "AttackBot":         <array of EXACTLY 5 profile objects>
}
```

`panelName = "AttackBot"` (`vBot/AttackBot.lua:3`).

**The 5-element gate (`AttackBot.lua:1635`):**

```lua
if not AttackBotConfig[panelName] or not AttackBotConfig[panelName][1] or #AttackBotConfig[panelName] ~= 5 then
```

If `AttackBot` is missing, empty, an object, or has any length other than 5, vBot
**replaces the whole thing with 5 blank profiles (AttackBot.lua:1636-1717) and the user's
attack setups are gone.** Verified in §7.5 A.

`currentBotProfile` guard (`AttackBot.lua:1720-1722`): `not X or X == 0 or X > 5 → 1`.
Note what is *not* guarded: negative, fractional, string and boolean values.
`-1` and `1.5` index a nil profile → hard error on first field access; `"1"` and `true`
raise `attempt to compare number with string/boolean` **inside the guard itself**. Any of
these kills the bot load (§7.5 B). `null` is safe (the key vanishes, `not X` catches it).

### 2.2 Profile object

Keys vBot writes as defaults (`AttackBot.lua:1637-1652`) plus keys injected on load:

| Key | Type | Default when absent | Read at | Notes |
|---|---|---|---|---|
| `name` | string | `"Profile #N"` | AttackBot.lua:1760, 2425 | shown in UI |
| `enabled` | bool | `false` | 1765, 2420, 2480 | master switch for the profile |
| `attackTable` | array | `{}` | 2212, 2215, 2727 | **order = priority**, see §2.3 |
| `Visible` | bool | `true` | 2426, 2835, 2840, 2871, 2873 | "only fire what I actually carry" |
| `CustomCooldown` | bool | `false` (`or false` at 2427) | 2793, 2847, 2902 | mutually exclusive with `ServerCooldown` (2327-2336) |
| `ServerCooldown` | bool | `true` | 2428, 2795 | |
| `pvpMode` | bool | `false` | 2429, 2896 | |
| `PvpSafe` | bool | `true` | 2430, 1526, 1618, 3064 | |
| `BlackListSafe` | bool | `false` | 2431, 1572 | |
| `AntiRsRange` | number | `5` — **injected**, AttackBot.lua:1734-1736 | 2432, 1572 | |
| `RuneDelay` | number (ms) | `50` — **injected for all 5 profiles**, 1744-1746 | 2433, 2367 | |
| `RuneDelayEnabled` | bool | `true` — **injected**, 1747-1749 | 2434, 2370 | |
| `Rotate` | bool | `false` | 2435, 2317 | |
| `Kills` | bool | `false` | 2436, 1573 | |
| `KillsAmount` | number | `1` | 2437, 1573 | |
| `Training` | bool | *no default* → `nil` = off | 2438, 2729 | **absent from the user's file**; feature silently off |
| `OptPenance` | bool | `false` — injected, 1751 | 2439-2442, 2933+ | chain/AoE optimizer |
| `OptOutburst` | bool | `false` — injected, 1752 | idem | |
| `OptTFB` | bool | `false` — injected, 1753 | idem, 1531/1543 | |
| `OptThorns` | bool | `false` — injected, 1754 | idem | |
| `OptGlacier` | bool | `false` — injected, 1755 | idem | |
| `Cooldown` | bool | — | **never read** | dead key present in the user's file |
| `ignoreMana` | bool | — | **never read** | dead key; `grep -rn ignoreMana` over the whole profile returns nothing |

> The "injected" defaults mean: if we omit `RuneDelay` / `RuneDelayEnabled` / `Opt*` /
> `AntiRsRange`, vBot fills them in and writes them back on the next save. Omitting them is
> safe. Omitting `Visible`, `pvpMode`, `PvpSafe`, `BlackListSafe`, `Rotate`, `Kills`,
> `KillsAmount` is *not* protected by an `or false` and reaches `setChecked(nil)` /
> `setValue(nil)` in `loadSettings` (2426-2437). **MUST write all of them.**

### 2.3 `attackTable` entry — every field, with a real value from the user's file

Built at `AttackBot.lua:2258-2277`, saved verbatim at `AttackBot.lua:1782-1790`
(`currentSettings.attackTable = {}` then `table.insert(..., child.params)` in widget order).

Real entry #1 from
`profiles/bot/vBot_4.8/vBot_configs/profile_1/AttackBot.json` (pretty-printed here; on disk
it is minified and the key order is arbitrary):

```json
{
  "enabled":         true,
  "spell":           "exori mas res",
  "itemId":          0,
  "mana":            10,
  "count":           1,
  "orMore":          true,
  "minHp":           0,
  "maxHp":           100,
  "cooldown":        1,
  "harmony":         0,
  "augmented":       false,
  "category":        5,
  "patternCategory": 4,
  "pattern":         19,
  "monsters":        ["true frost flower asura"],
  "creatures":       "true frost flower asura",
  "tooltip":         "true frost flower asura",
  "description":     "[Balanced Brawl] 1+ Creatures: exori mas res, absolute (0%-100%)"
}
```

Real entry #2 from the same file, showing the **`true` form** of `monsters`/`tooltip`:

```json
{
  "enabled":true,"spell":"exori gran mas nia","itemId":0,"mana":20,"count":5,
  "orMore":true,"minHp":0,"maxHp":100,"cooldown":1,"harmony":5,"augmented":false,
  "category":5,"patternCategory":4,"pattern":17,
  "monsters":true, "creatures":"monster names", "tooltip":false,
  "description":"[Spiritual Outburst] 5+ Any Creatures: exori gran mas nia, absolute (0%-100% [H:5])"
}
```

| Field | Type | Meaning / read at | Missing-key behaviour |
|---|---|---|---|
| `enabled` | bool | 2166, 2786 | falsy → entry skipped. Silent. |
| `spell` | string | 2158, 2181, 2785, 2808, 1299 | used only when `itemId <= 100` |
| `itemId` | number | 2151, 2154, 2179, 2180, **2785** | **HARD ERROR** if absent: `entry.itemId > 100` → *attempt to compare number with nil* (§7.5 E). `0` means "spell entry". |
| `mana` | number (percent) | 2173, 2786 (`manapercent() >= entry.mana`) | HARD ERROR (arith/compare on nil) |
| `count` | number | 2174, 1577, 2917, 2923, 2948, 3033, 3044, 3064 | HARD ERROR |
| `orMore` | bool | 2182, 1577 | falsy → exact-count match instead of `>=`. **Silent behaviour change.** |
| `minHp` / `maxHp` | number (percent) | 2175/2176, 1406, 2896, 2916 | HARD ERROR |
| `cooldown` | number (seconds) | 2177, 2794, 2847 (`entry.cooldown * 1000`) | only used when `CustomCooldown` |
| `harmony` | number | 2178 (`or 0`), 2160, **2787** | guarded by `entry.harmony and entry.harmony > 0` — safe to omit |
| `augmented` | bool | 2183 (`and true or false`), **1296-1298** | safe to omit; absent in 6 of the user's 8 entries |
| `category` | number 1..5 | 2185, 2897, 2905, 2915, 2921, 2932, 3072 | **see §2.4 — a wrong value silently rewires the whole firing branch** |
| `patternCategory` | number 1..4 | 2186, 2933, 3073, 2971, 3028, 3063 | idem |
| `pattern` | number | 2187, 1297, 2917, 2923, and as an index into `spellPatterns[pCat][pattern]` | idem |
| `monsters` | `true` \| array of lowercase strings | 1402, 1531, 1543, 2916, 2947, 2971, 3028, 3063 | `true` = any creature. `nil` is treated the same as `true` by `(entry.monsters == true or not entry.monsters)` at 1402. |
| `creatures` | string | 2228-2229 (round-trip only) | display/edit only |
| `tooltip` | `false` \| string | 2160 (`params.tooltip or ""`) | display only |
| `description` | string | 2150 (`widget:setText`) | display only — **but this is the entire visible label; a wrong description makes the list lie about what the entry does** |

**`monsters` construction (AttackBot.lua:2229):**
```lua
local monsters = (creatures:len() == 0 or creatures == "*" or creatures == "monster names")
                 and true or string.split(creatures, ",")
```
i.e. JSON `true` for "any", otherwise an array of comma-split, **already lowercased**
(`:lower()` at 2228) names. `tooltip = monsters ~= true and creatures` (2238) — so `tooltip`
is JSON `false` exactly when `monsters` is `true`.

### 2.4 `category` / `patternCategory` / `pattern` — the silent-corruption triple

`categories` (`AttackBot.lua:233-239`, listed at 29-35 of the excerpt):

| `category` | meaning |
|---|---|
| 1 | Targeted Spell (exori hur, exori flam) |
| 2 | Area Rune (avalanche, GFB) |
| 3 | Targeted Rune (SD, icicle) |
| 4 | Empowerment (utito tempo) |
| 5 | Absolute Spell (exori, hells core) |

`patternCategory` is **derived**, not free (`AttackBot.lua:1866`, identically at `1955`):

```lua
patternCategory = category == 4 and 3 or category == 5 and 4 or category
```

so `1→1, 2→2, 3→3, 4→3, 5→4`.

`pattern` is a 1-based index into `patterns[patternCategory]` (`AttackBot.lua:241-…`):

* `patterns[1]` = 10 entries, "1 Sqm Range" … "10 Sqm Range" — **the value is literally the
  range in tiles**, used as such at 2917/2923 (`distanceFromPlayer(...) <= entry.pattern`).
* `patterns[2]` = 3 entries: 1 Cross, 2 Bomb, 3 Ball.
* `patterns[3]` = 10 entries, ranges 1..10 (shared by Empowerment and Targeted Rune).
* `patterns[4]` = 19 entries: 1 Adjacent, 2 3x3 Wave, 3 Small Area, 4 Medium Area,
  5 Ulus Area, 6 Large Area, 7 Short Beam, 8 Large Beam, 9 Sweep, 10 Small Wave,
  11 Big Wave, 12 Huge Wave, 13 Flurry of Blows, 14 Greater Flurry,
  15 Thousand Fist Blows, 16 Sweeping Takedown, 17 Spiritual Outburst,
  18 Chained Penance, 19 Balanced Brawl.

> **NEVER** write these three independently. If `patternCategory` does not match the
> formula above, `spellPatterns[pCat][pattern]` (2971, 3028, 3063) indexes a different
> shape table and the bot fires a *different area pattern than the one shown in the UI
> label*, or indexes nil and errors. The user's file is self-consistent
> (`category:5, patternCategory:4, pattern:19` = Balanced Brawl; `category:1,
> patternCategory:1, pattern:7` = "7 Sqm").

### 2.5 Array order is priority

`AttackBot.lua:2783` iterates `panel.entryList:getChildren()` in list order and every branch
ends in `return executeAttackBotAction(...)` — first satisfied entry wins. The save at
1784-1787 preserves that exact order. **MUST preserve `attackTable` array order.**

---

## 3. `HealBot.json`

### 3.1 Top level

```
{
  "currentHealBotProfile": <number 1..5>,
  "healbot":               <array of EXACTLY 5 profile objects>,
  "ConditionPanel":        <object>
}
```

`healPanelName = "healbot"` (`HealBot.lua:195`), `panelName = "ConditionPanel"`
(`Conditions.lua:2`).

Same 5-element gate at `HealBot.lua:271`; same `currentHealBotProfile` guard at
`HealBot.lua:281-283`, with the same unguarded negative/fractional/string/boolean holes
(§7.5 B).

### 3.2 Profile object (defaults at `HealBot.lua:273-277`)

| Key | Type | Default | Read at | Notes |
|---|---|---|---|---|
| `name` | string | `"Profile #N"` | 343, 346, 552 | |
| `enabled` | bool | `false` | 303, 305, 550, **688**, **750** | master switch |
| `spellTable` | array | `{}` | 375, 377, 432, 444, 501, 573, **690** | order = priority |
| `itemTable` | array | `{}` | 401, 403, 456, 468, 536, 574, **750**, **775** | order = priority |
| `Visible` | bool | `true` | 350, 555, 575, **780** | "only use potions I actually have" |
| `Cooldown` | bool | `true` | 354, 556, 576, **646** | |
| `Interval` | bool | `true` | 358, 559, 579, **767** | |
| `Conditions` | bool | `true` | 362, 560, 580 | **UI-only in this build — never read by a macro** |
| `Delay` | bool | `true` | 366, 557, 577 | **UI-only in this build — never read by a macro** |
| `MessageDelay` | bool | `false` | 370, 558, 578, **768** | |

Real profile #1 from the user's file:

```json
{
  "name":"Profile #1","enabled":true,
  "Visible":false,"Cooldown":true,"Interval":false,"Conditions":false,
  "Delay":false,"MessageDelay":false,
  "spellTable":[ ... ], "itemTable":[ ... ]
}
```

### 3.3 `spellTable` entry (built at `HealBot.lua:501`)

Real entries from the user's file, in file order:

```json
{"index":2,"enabled":true,"spell":"exura gran tio","origin":"HP%","sign":"<","value":75,"cost":210}
{"index":1,"enabled":true,"spell":"exura gran",    "origin":"HP%","sign":"<","value":95,"cost":75}
```

| Field | Type | Read at | Notes |
|---|---|---|---|
| `enabled` | bool | 379, **691** | |
| `spell` | string | 393, 394, **692**, `castHealSpell` 671-673 | said verbatim via `say()` |
| `cost` | number (mana) | 394, **691** (`entry.cost < mana()`) | gate, not the spell's real cost — see the comment block at HealBot.lua:660-668 |
| `origin` | `"HP"`\|`"HP%"`\|`"MP"`\|`"MP%"`\|`"burst"` | 394, **693-712** | see §3.5 |
| `sign` | `"<"`\|`">"`\|`"="` | 394, **694-712** | |
| `value` | number | 394, **694-712** | |
| `index` | number | written at 501, rewritten by `reindexTable` (`vBot/vlib.lua:210-218`) | **never read for behaviour** — see §3.6 |

### 3.4 `itemTable` entry (built at `HealBot.lua:536`)

Real entries from the user's file, in file order — note the out-of-order `index`:

```json
{"index":2,"enabled":false,"item":23374,"origin":"HP%","sign":"<","value":40}
{"index":3,"enabled":true, "item":23374,"origin":"HP%","sign":"<","value":75}
{"index":1,"enabled":true, "item":23374,"origin":"MP%","sign":"<","value":75}
```

| Field | Type | Read at | Notes |
|---|---|---|---|
| `enabled` | bool | 405, **780** | |
| `item` | number (item id) | **419** `label.id:setItemId(entry.item)`, 420, **779** `hasItemAvailable(entry.item)`, **782+** `useHealItem(entry.item)` | **must be a number, not a string** |
| `origin` / `sign` / `value` | as above | 420, **781-800** | |
| `index` | number | written at 536 | never read |

### 3.5 `origin` / `sign` — the silent-behaviour field pair

`origin` is produced by `HealBot.lua:490-494` / `525-529`, `sign` by `496-498` / `531-533`:

| UI label | `origin` |
|---|---|
| Current Mana | `"MP"` |
| Current Health | `"HP"` |
| Mana Percent | `"MP%"` |
| Health Percent | `"HP%"` |
| *(anything else)* | `"burst"` |

| UI label | `sign` |
|---|---|
| Above | `">"` |
| Below | `"<"` |
| *(anything else)* | `"="` |

Consumption is a literal `if/elseif` chain (`HealBot.lua:693-713` for spells,
`781-801` for items). **Any string outside those exact five / three literals makes the
entry match nothing at all — no error, no warning, the rule is simply dead.**
`"HP"` vs `"HP%"` is the classic disaster: `value: 75` under `"HP"` means 75 *hitpoints*,
under `"HP%"` it means 75 *percent*. `"<"` vs `">"` inverts the rule.

Note `sign` is compared with `<=` / `>=` in the code (`hppercent() <= entry.value` at 696),
so `"<"` is really "at or below".

### 3.6 `index` is a decoy — array order is authoritative

`index` is written once at insert time (`= #table+1`, HealBot.lua:501/536) and refreshed
only by `reindexTable` after a removal (`vlib.lua:210-218`, called at HealBot.lua:390/416).
**MoveUp/MoveDown swap the array slots and never touch `index`**
(`HealBot.lua:432-433`, `444-445`, `456-457`, `468-469`).

The user's real file proves it: `itemTable` array positions 1,2,3 carry `index` 2,3,1.
Evaluation iterates `pairs(currentSettings.itemTable)` (HealBot.lua:775) — the array part,
in slot order — and `return`s on the first match. So **array order is the priority; `index`
is a stale artifact that must be round-tripped verbatim and never used to re-sort.**

### 3.7 `ConditionPanel`

Defaults at `Conditions.lua:28-55`. Guard is `if not HealBotConfig["ConditionPanel"]`
(Conditions.lua:27) — **the whole object is replaced only when it is entirely absent.**
A partially-written object is used as-is with `nil` holes, which reach
`setText(nil)` / `setChecked(nil)` at Conditions.lua:85-222.

The user's real `ConditionPanel`, complete:

```json
{
  "enabled":true, "ignoreInPz":true, "stopHaste":false,
  "curePosion":false,   "poisonCost":20,
  "cureCurse":false,    "curseCost":80,
  "cureBleed":false,    "bleedCost":45,
  "cureBurn":false,     "burnCost":30,
  "cureElectrify":false,"electrifyCost":22,
  "cureParalyse":true,  "paralyseCost":200, "paralyseSpell":"utani gran hur",
  "holdHaste":true,     "hasteCost":200,    "hasteSpell":"utani gran hur",
  "holdUtamo":false,    "utamoCost":40,
  "holdUtana":false,    "utanaCost":440,
  "holdUtura":false,    "uturaCost":100,    "uturaType":""
}
```

| Key | Type | Default (Conditions.lua) | Read at |
|---|---|---|---|
| `enabled` | bool | `false` :29 | 60, 62, **239**, **254** |
| `curePosion` | bool | `false` :30 | **written by the default table but NEVER read** |
| `curePoison` | bool | *(no default)* | **241** — the real gate; also 152, 154 |
| `poisonCost` | number | `20` :31 | 85, 87, 241 |
| `cureCurse` / `curseCost` | bool / number | `false` / `80` :32-33 | 158-161, 90-93, **242** |
| `cureBleed` / `bleedCost` | bool / number | `false` / `45` :34-35 | 164-167, 95-98, **243** |
| `cureBurn` / `burnCost` | bool / number | `false` / `30` :36-37 | 170-173, 100-103, **244** |
| `cureElectrify` / `electrifyCost` | bool / number | `false` / `22` :38-39 | 176-179, 105-108, **245** |
| `cureParalyse` / `paralyseCost` / `paralyseSpell` | bool / number / string | `false` / `40` / `"utani hur"` :40-42 | 182-185, 110-118, **257** |
| `holdHaste` / `hasteCost` / `hasteSpell` | bool / number / string | `false` / `40` / `"utani hur"` :43-45 | 188-191, 120-128, **256** |
| `holdUtamo` / `utamoCost` | bool / number | `false` / `40` :46-47 | 194-197, 130-133, **255** |
| `holdUtana` / `utanaCost` | bool / number | `false` / `440` :48-49 | 200-203, 135-138, **249** |
| `holdUtura` / `uturaType` / `uturaCost` | bool / string / number | `false` / `""` / `100` :50-52 | 206-209, 140-149, **248** |
| `ignoreInPz` | bool | `true` :53 | 212-216, 248, 249, 255, 256 |
| `stopHaste` | bool | `false` :54 | 218-222, 256 |

> **`curePosion` vs `curePoison` is a real, live typo in vBot.**
> The default table writes `curePosion` (Conditions.lua:30). The checkbox
> (Conditions.lua:152-155) and the cure macro (Conditions.lua:241) both read `curePoison`.
> The user's file has only `curePosion`. Net effect: *Cure Poison is permanently off until
> the user clicks that checkbox*, which then adds the correctly-spelled key.
> **MUST:** round-trip `curePosion` untouched (it is what vBot writes), and if we want to
> express "cure poison is on" we must write **`curePoison`** — writing only `curePosion:true`
> does nothing.

---

## 4. `Supplies.json`

### 4.1 Shape

`panelName = "supplies"` (`vBot/supplies.lua:2`). The user's real file, complete and
verbatim off disk:

```json
{"supplies":{"Default":{"capSwitch":true,"lootPouchValue":"50","lootPouchSwitch":true,"capValue":"200","items":{"23374":{"avg":0,"min":200,"max":1200},"3097":{"avg":0,"min":1,"max":5}}},"currentProfile":"Default"}}
```

```
{
  "supplies": {
    "currentProfile": "<profile name>",
    "<profile name>": { ...profile... },     // one or more, up to 7 (supplies.lua:292)
    ...
  }
}
```

`supplies` is a **map that mixes one scalar key (`currentProfile`) with N profile keys**.
`refreshProfileList` (supplies.lua:234-235) and the old-config sweep (supplies.lua:68-71)
both discriminate with `type(v) == "table"`.

> **NEVER name a supply profile `currentProfile`** — it would be shadowed and the config
> would break. vBot itself only ever generates `"Default"` and `"Profile #N"`
> (supplies.lua:6, :295), but the name is user-editable (supplies.lua:268-274).

### 4.2 Reset gate

`supplies.lua:3`: `if not SuppliesConfig["supplies"] or SuppliesConfig["supplies"].item1 then`
→ resets to `{currentProfile = "Default", Default = {}}`. So a stray top-level `item1` key
wipes everything.

`supplies.lua:79-87`: if `currentProfile` names a key that does not exist, vBot picks the
first table-valued key it finds via `pairs` (**non-deterministic order**) and rewrites
`currentProfile`. Then `vBotConfigSave("supply")` runs unconditionally at supplies.lua:77 —
**Supplies.json is rewritten on every single bot load.**

### 4.3 Profile object

| Key | Type | Read at | Notes |
|---|---|---|---|
| `items` | **object**, string-item-id → `{min,max,avg}` | 11, 56, 139, 158, **181-188**, 207, 218 | see §4.4 |
| `capSwitch` | bool | 17, 192, 302-304, **482** | |
| `capValue` | **string** of digits (or number `0`) | 21, **196** (`or 0`), 322-330, **482** | see §4.5 |
| `lootPouchSwitch` | bool | 23, 198, 344-346, **485** | |
| `lootPouchValue` | **string** of digits (or number `0`) | 24, **199** (`or 0`), 349-357, **485** | |
| `staminaSwitch` | bool | 20, 195, 317-319, **481** | absent from the user's file → `setOn(nil)` |
| `staminaValue` | string/number | 22, **197** (`or 0`), 333-341, **481** | absent from the user's file |
| `SoftBoots` | bool | 18, 193, 307-309, **483** | absent from the user's file |
| `imbues` | bool | 19, 194, 312-314, **484** | absent from the user's file |

The user's `Default` profile omits `staminaSwitch`, `staminaValue`, `SoftBoots` and
`imbues`. That is *tolerated*: the `or 0` at 196/197/199 covers the values, and
`setOn(nil)` is benign for the switches. `Supplies.getAdditionalData` (479-488) then hands
`{enabled = nil}` downstream, which `supply_check.lua:98-100` and `:143` treat as off.
**Omitting them is safe; we should still preserve whatever is there.**

### 4.4 `items` — a string-keyed object, never an array

Written as `newConfig.items[tostring(item)]` (supplies.lua:56) and
`...items[id]` with `id = tostring(panel.id:getItemId())` (supplies.lua:213, 218-222).
Read back with `pairs(config.items)` + `tonumber(id)` (supplies.lua:181-184).

Each value: `{min = <number>, max = <number>, avg = <number>}`
(supplies.lua:218-222; consumed at `Supplies.hasEnough` supplies.lua:435-452, where
`values.min` is compared against `itemAmount(id)`).

> **MUST:** item ids are **string keys** made by `tostring(<integer>)` — `"23374"`, never
> `23374` and never `"23374.0"`.
> * A **numeric** Lua key makes the whole `json.encode` throw
>   `invalid table: mixed or invalid key types` (json.lua:92-93), the `pcall` at
>   `configs.lua:85-90` swallows it, and **the file is never written** (§7.4 §8).
> * A `"23374.0"` string key is silently invisible to `config.items[tostring(id)]`
>   (supplies.lua:158) and to the save loop, so the entry survives on disk but the GUI
>   drops it the moment the user opens and closes the Supplies window (§7.5 F).

If `items` is empty, vBot's encoder emits `"items":[]` (see §6.1). That is what vBot itself
writes, and its own loader reads it back as an empty table — but `convertOldConfig`
(supplies.lua:10-13) tests `config.items` for truthiness only, so an empty table still
counts as "new format". Safe either way.

### 4.5 `capValue` / `lootPouchValue` are STRINGS on purpose

`supplies.lua:322-330`:

```lua
SuppliesWindow.capValue.onTextChange = function(widget, text)
  local value = tonumber(SuppliesWindow.capValue:getText())
  if not value then
    SuppliesWindow.capValue:setText(0)
    config.capValue = 0            -- number 0 on the "invalid" branch
  else
    text = text:match("0*(%d+)")   -- STRING on the normal branch
    config.capValue = text
  end
end
```

That is why the user's file has `"capValue":"200"` and `"lootPouchValue":"50"` as JSON
strings. The consumer is tolerant — `tonumber(supplyInfo.capacity.value)` at
`cavebot/supply_check.lua:143` — so a number would also work. **Write the string form** to
stay byte-shaped like vBot; do not "fix" it to a number.

---

## 5. `targetbot_configs/<name>.json`

### 5.1 Shape

```
{ "targeting": [ <entry>, ... ], "looting": { ... } }
```

Loaded at `targetbot/target.lua:131-152`:

```lua
for _, value in ipairs(data["targeting"] or {}) do TargetBot.Creature.addConfig(value) end
TargetBot.Looting.update(data["looting"] or {})
```

Saved at `targetbot/target.lua:238-245` → `Config.save(dir, name, data, "json")`
(`functions/config.lua:95-111`; the `"json"` forced extension bypasses the
`table.isStringPairList` cfg branch at config.lua:105).

Both top-level keys are `or {}`-guarded — a missing one silently means "no targets" /
"default looting". `Config.setup`'s **add** button writes `json.encode({})` = **`[]`**
(config.lua:197); the user has one such file, `targetbot_configs/true_asuras.json`, whose
entire content is the two bytes `[]`. It loads fine (both `or {}` guards fire).

### 5.2 `targeting` entry — all 28 fields

The full key set is fixed by the editor (`targetbot/creature_editor.lua:79-105` plus
`name` at :8 and `regex` at :66-72). Real entry from
`profiles/bot/vBot_4.8/targetbot_configs/turter.json` (first entry, pretty-printed):

```json
{
  "name":"Dark Torturer",
  "regex":"^dark torturer$",
  "priority":4, "danger":1,
  "maxDistance":8, "keepDistanceRange":1, "anchorRange":3,
  "lureCount":1, "lureMin":3, "lureMax":9, "lureDelay":655, "delayFrom":4,
  "rePositionAmount":7, "closeLureAmount":6,
  "chase":true, "keepDistance":false, "anchor":false, "dontLoot":false,
  "lure":false, "lureCavebot":false, "faceMonster":false, "avoidAttacks":false,
  "dynamicLure":true, "dynamicLureDelay":true, "diamondArrows":true,
  "rePosition":true, "closeLure":true, "rpSafe":false
}
```

Numeric fields — editor id, range, default (`creature_editor.lua:79-90`), consumer:

| Key | Range | Default | Read at |
|---|---|---|---|
| `priority` | 0..10 | 1 | **`creature_priority.lua:22`** `priority = priority + config.priority` |
| `danger` | 0..10 | 1 | **`creature.lua:97`** `return config.danger` → summed into `dangerLevel` at `target.lua:73` |
| `maxDistance` | 1..10 | 10 | **`creature_priority.lua:12`** `#path > config.maxDistance` |
| `keepDistanceRange` | 1..5 | 1 | `creature_attack.lua:182, 184, 186` |
| `anchorRange` | 1..10 | 3 | `creature_attack.lua:179, 183, 184` |
| `lureCount` | 0..5 | 1 | `creature_attack.lua:156` |
| `lureMin` | 0..29 | 1 | `creature_attack.lua:130, 131` |
| `lureMax` | 1..30 | 3 | `creature_attack.lua:130, 133, 140, 141` |
| `lureDelay` | 100..1000 | 250 | `creature_attack.lua:138` |
| `delayFrom` | 1..29 | 2 | `creature_attack.lua:145` |
| `rePositionAmount` | 0..7 | 5 | `creature_attack.lua:172` (`or 6`) |
| `closeLureAmount` | 0..8 | 3 | `creature_attack.lua:148` |

Boolean fields (`creature_editor.lua:92-105`), default in parentheses:
`chase` (true), `keepDistance` (false), `anchor` (false), `dontLoot` (false), `lure` (false),
`lureCavebot` (false), `faceMonster` (false), `avoidAttacks` (false), `dynamicLure` (false),
`dynamicLureDelay` (false), `diamondArrows` (false), `rePosition` (false), `closeLure` (false),
`rpSafe` (false).

String fields: `name` (`creature_editor.lua:7-8`) and `regex`.

**Those editor "defaults" only apply inside the editor window** — they are what
`config[id] or defaultValue` (creature_editor.lua:21) falls back to when you *open* an
entry for editing. **They are NOT applied at load time.** `addConfig`
(`creature.lua:15-51`) fills in exactly one thing:

```lua
-- targetbot/creature.lua:16-29
if type(config) ~= 'table' or type(config.name) ~= 'string' then
  return error("Invalid targetbot creature config (missing name)")   -- sandbox error = a printed message
end
...
if not config.regex then                       -- derived from `name` when absent
  config.regex = "" ; for part in string.gmatch(config.name, "[^,]+") do ... end
end
```

So at runtime a missing numeric key is a **hard error inside the 100 ms targeting macro**:

* missing `maxDistance` → `attempt to compare nil with number` (creature_priority.lua:12)
* missing `priority` → `attempt to perform arithmetic on field 'priority' (a nil value)` (:22)
* `maxDistance` as a **string** → `attempt to compare string with number`
* missing `danger` → `params.danger` is nil → `dangerLevel + params.danger` errors at target.lua:73

All four verified in §7.5 C. Missing `name` (or a non-string one) is the only graceful case:
the entry is dropped with a printed message and the rest of the file still loads (§7.5 D).

> **MUST:** write **all 28 keys** on every targeting entry. Do not rely on defaults —
> there are none at load time.

**`regex` is derived from `name` and is the actual matcher.** `getConfigs`
(`creature.lua:62`) matches `regexMatch(creatureName, config.value.regex)`; `name` is only
the list label. The transform (`creature_editor.lua:66-72`, duplicated at
`creature.lua:21-29`) is: split `name` on `,`, then per part
`"^" .. part:trim():lower():gsub("%*", ".*"):gsub("%?", ".?") .. "$"`, joined with `|`.
`"*"` → `"^.*$"`; `"Demon,Vexclaw"` → `"^demon$|^vexclaw$"`. Both appear in the user's files.

> **NEVER** let `name` and `regex` drift apart. If we edit `name` we must recompute
> `regex` with exactly that transform, or the entry will keep targeting the old creature
> while the UI shows the new name.

**`priority` and `danger` are the silent-behaviour fields.** `priority` is added to a
distance/HP-derived score (`creature_priority.lua:3-60`) and the highest wins
(`creature.lua:79-86`) — bumping it by 1 can permanently steal targeting from another
entry. `danger` is summed across every visible monster (`target.lua:73`) and gates looting
(`looting.lua:112`, `dangerLevel > maxDanger → "High danger"`) — so raising `danger`
silently stops the looter.

### 5.3 `looting` section

Real section from `targetbot_configs/true_asura.json`:

```json
{"maxDanger":10,"minCapacity":100,"everyItem":false,
 "containers":[{"id":23721,"count":0}],
 "items":[{"id":16131,"count":0},{"id":9636,"count":0}]}
```

and from `turter.json`, showing the empty form vBot writes:

```json
{"everyItem":false,"containers":[],"minCapacity":100,"items":[],"maxDanger":25}
```

| Key | Type | Default when absent | Read at |
|---|---|---|---|
| `items` | array of `{id:number, count:number}` | `{}` (`looting.lua:58`) | 58, 78, 86, 90-91, 108, 241-243; `vBot.lootItems` at 72-74 |
| `containers` | array of `{id:number, count:number}` | `{}` (`looting.lua:59`) | 59, 79, 87, 93-94, 108, 192, 197, 213, 215; `vBot.lootConainers` at 69-71 |
| `everyItem` | bool | `false` (`not not data['everyItem']`, looting.lua:60) | 13, 20-21, 60, 82, 108, 243 — **inverts the meaning of `items` from "loot list" to "ignore list"** (looting.lua:13) |
| `maxDanger` | number | **`10`** (`looting.lua:62`) | 62, 80, **112** |
| `minCapacity` | number | **`100`** (`looting.lua:63`) | 63, 81, **116** |

The `{id, count}` shape comes from `UI.Container`
(`mods/game_bot/functions/ui_elements.lua:84-96`):
`table.insert(items, {id = child:getItemId(), count = child:getItemCountOrSubType()})`,
filtered to `id >= 100`. `setItems` also accepts a bare number and normalises it
(`ui_elements.lua:70-72`: `items[i] = {id = items[i], count = 1}`), so a legacy
`"items":[3031,3035]` still loads — but **`getItems` will rewrite it to the object form on
the next save**, so write the object form.

`maxDanger` / `minCapacity` go through `setText(...)` then back out via
`tonumber(...:getText())` (looting.lua:80-81, 112, 116) — a JSON string would survive the
round trip, but write numbers.

> **`everyItem` is the highest-consequence boolean in the file.** With `everyItem: true`
> the `items` array stops being "what to loot" and becomes "what to *skip*"
> (`looting.lua:243`). Flipping it turns a 2-item loot list into "loot everything except
> these 2".

---

## 6. `storage/profile_N.json`

### 6.1 Contract

Free-form namespace. `bot.lua:273-281` decodes it straight into `botStorage`, which
`executor.lua:29` exposes to every bot script as the global `storage`. There is **no
schema** — each script owns its own top-level key and creates it on demand. `bot.lua:298-321`
re-encodes the whole table on `terminate()` / `refresh()` / `offline()`.

The user's file has 33 top-level keys:
`AutoImbueManager, AutoTrainingWeapon, BOTserver, BotServerChannel, BotServerUrl,
EquipperPanel, _configs, _icons, _macros, alarms, analyzers, autoEquip, autoImbue,
autoTradeMessage, bestHeal, bestHit, caveBot, caveBotTasker, cavebotSell,
cavebotSellMigrated, combobot, dropper, extras, foodItems, ingame_hotkeys, moneyItems,
navibot, newHealer, playerList, pushmax, renameContainers, specialDeposit, stances`.

Framework-owned keys (the only ones with a fixed contract):

| Key | Shape | Owner |
|---|---|---|
| `_macros` | object: macro display name → bool (enabled) | `executor.lua:30-32` creates it if `nil` |
| `_configs` | object: config-dir name → `{enabled: bool, selected: string}` | `functions/config.lua:137-147` |
| `_icons` | object: icon name → `{x: float, y: float, enabled: bool}` | bot icon framework |

Real values from the user's file:

```json
"_configs": {"targetbot_configs":{"enabled":false,"selected":"true_asura"},
             "cavebot_configs":{"enabled":false,"selected":"true_asura_mk"}}
"_icons":   {"looter":{"y":0.25,"enabled":false,"x":0.01},
             "might_auto":{"y":0.12320916905444,"enabled":false,"x":0.010135135135135},
             "ssa_auto":{"y":0.45,"enabled":false,"x":0.01}}
```

Two shapes worth knowing about because they stress the encoder:

* `_macros` contains a **key that is the empty string** (`"": false`). rxi handles it
  (`encode_string("")` → `""`), and `next(val) ~= nil` keeps the table on the object
  branch. A writer must not drop it.
* `ingame_hotkeys` is a long multi-line Lua source string; it exercises `\n`, `\"` and `\\`
  escaping (§6.3).
* `_configs.<dir>.selected` is set to **`nil`** when no configs exist
  (`functions/config.lua:167`), so the key legitimately disappears from the file.

### 6.2 Non-schema keys

Every other key belongs to a vBot script and is created with a literal default the first
time that script runs (e.g. `storage.targetbotAvoidFloorChange` at
`targetbot/target.lua:39-44`, read as `~= false` so "absent = on"). There is no central
default table. **Round-trip everything verbatim; do not prune keys we do not recognise.**

### 6.3 Storage-specific hazards

* Floats appear here (`_icons` x/y). `%.14g` (json.lua:111) is lossy past 14 significant
  digits — `0.1234567890123456` comes back as `0.12345678901235` (§7.4 §1). The user's
  actual values (`0.010135135135135`, `0.12320916905444`) are already ≤14 sig digits and
  round-trip exactly.
* **Storage is written only at logout.** Writing it while the client is running is
  guaranteed to be clobbered.

---

## 7. Encoder / decoder behaviour, verified by running vBot's own json.lua

Everything in this section is real output from
`build/win-local/vcpkg_installed/x64-windows-static-release/tools/luajit/luajit.exe`
loading `modules/corelib/json.lua`.

### 7.1 The round-trip baseline — which of the user's real files survive byte-identically

Script: read the file → `json.decode` → `json.encode` → compare bytes.

```
FILE                                           BYTES_IN BYTES_OUT  IDENTICAL NOTE
--------------------------------------------------------------------------------------------------------------
vBot_configs/profile_1/AttackBot.json              4555     4555  NO        first diff at byte 39: in="Kills\":false,\"OptGlacier\":fals" out="OptOutburst\":true,\"ignoreMana\""
  ^ re-encode of own output                                       UNSTABLE  key order differs between two encodes of same data
vBot_configs/profile_1/HealBot.json                1801     1801  NO        first diff at byte 3: in="currentHealBotProfile\":1,\"Cond" out="ConditionPanel\":{\"curseCost\":8"
  ^ re-encode of own output                                       UNSTABLE  key order differs between two encodes of same data
vBot_configs/profile_1/Supplies.json                214      214  NO        first diff at byte 114: in="23374\":{\"avg\":0,\"min\":200,\"max" out="3097\":{\"max\":5,\"avg\":0,\"min\":1"
storage/profile_1.json                            44975    44975  NO        first diff at byte 3: in="combobot\":{\"onCastEnabled\":fal" out="BOTserver\":{\"outfit\":true,\"mwa"
  ^ re-encode of own output                                       UNSTABLE  key order differs between two encodes of same data
targetbot_configs/bultaur.json                      577      577  NO        first diff at byte 18: in="anger\":1,\"maxDistance\":10,\"clo" out="ontLoot\":false,\"anchor\":false,"
targetbot_configs/def.json                          622      622  NO        first diff at byte 14: in="everyItem\":false,\"maxDanger\":1" out="containers\":[{\"count\":0,\"id\":2"
targetbot_configs/def_target.json                   620      620  NO        first diff at byte 17: in="name\":\"*\",\"rpSafe\":false,\"anch" out="dontLoot\":true,\"anchor\":false,"
targetbot_configs/feru_undead.json                  578      578  NO        first diff at byte 17: in="lureMax\":6,\"name\":\"*\",\"dynamic" out="dontLoot\":true,\"anchor\":false,"
targetbot_configs/hellhub.json                     1174     1174  NO        first diff at byte 17: in="lureMax\":7,\"name\":\"Demon,Vexcl" out="dontLoot\":false,\"anchor\":false"
targetbot_configs/lines.json                        576      576  NO        first diff at byte 17: in="lureMax\":5,\"name\":\"*\",\"dynamic" out="dontLoot\":true,\"anchor\":false,"
targetbot_configs/poi_plag.json                     578      578  NO        first diff at byte 17: in="lureMax\":10,\"name\":\"*\",\"dynami" out="dontLoot\":false,\"anchor\":false"
targetbot_configs/rossh.json                        600      600  NO        first diff at byte 17: in="lureMax\":13,\"name\":\"*\",\"dynami" out="dontLoot\":true,\"anchor\":false,"
targetbot_configs/true_asura.json                   642      642  NO        first diff at byte 17: in="lureMax\":5,\"lureMin\":2,\"dynami" out="dontLoot\":true,\"anchor\":false,"
targetbot_configs/true_asuras.json                    2        2  YES
targetbot_configs/turter.json                      2085     2085  NO        first diff at byte 18: in="anger\":1,\"maxDistance\":8,\"clos" out="ontLoot\":false,\"anchor\":false,"
```

**Result: 14 of 15 files are NOT byte-identical after a round trip through vBot's own
encoder. The one that is — `targetbot_configs/true_asuras.json` — is the two-byte file `[]`,
which has no keys to reorder.**

Every non-identical file has **identical byte length** — the only change is key order.

### 7.2 Key order is non-deterministic per process

Running the exact same script three times:

```
run 1: AttackBot.json  first diff at byte 39: out="OptOutburst\":true,\"ignoreMana\""
run 2: AttackBot.json  first diff at byte  3: out="AttackBot\":[{\"Rotate\":true,\"Co"
run 3: AttackBot.json  first diff at byte 53: out="Cooldown\":true,\"pvpMode\":false"

run 1: turter.json     first diff at byte  3: out="looting\":{\"minCapacity\":100,\"e"
run 2: turter.json     first diff at byte  3: out="looting\":{\"everyItem\":false,\"c"
run 3: turter.json     first diff at byte 18: out="ontLoot\":false,\"anchor\":false,"
```

and even inside one process, two decodes of the *same* text produce a table whose encode
order is stable per table but the top-level object order flips between `{"targeting":...}`
and `{"looting":...}` from run to run. `encode_table`'s object branch is a plain
`for k, v in pairs(val)` (json.lua:91) — Lua hash order, LuaJIT-seeded per process.

**Nothing in vBot can depend on key order, and nothing does.** Every consumer reads by name.

### 7.3 …but the round trip is semantically lossless

Same files, comparing decoded trees (deep equality) and a key-sorted canonical encoding:

```
FILE                                           BYTE-EXACT  SAME-LENGTH CANON-EXACT   SEMANTIC DIFFS
------------------------------------------------------------------------------------------------------------
vBot_configs/profile_1/AttackBot.json          NO          YES         YES           none
vBot_configs/profile_1/HealBot.json            NO          YES         YES           none
vBot_configs/profile_1/Supplies.json           NO          YES         YES           none
storage/profile_1.json                         NO          YES         YES           none
targetbot_configs/bultaur.json                 NO          YES         YES           none
targetbot_configs/def.json                     NO          YES         YES           none
targetbot_configs/def_target.json              NO          YES         YES           none
targetbot_configs/feru_undead.json             NO          YES         YES           none
targetbot_configs/hellhub.json                 NO          YES         YES           none
targetbot_configs/lines.json                   NO          YES         YES           none
targetbot_configs/poi_plag.json                NO          YES         YES           none
targetbot_configs/rossh.json                   NO          YES         YES           none
targetbot_configs/true_asura.json              NO          YES         YES           none
targetbot_configs/true_asuras.json             YES         YES         YES           none
targetbot_configs/turter.json                  NO          YES         YES           none
```

**This is the bar our writer has to clear: `CANON-EXACT = YES`, zero semantic diffs.**

### 7.4 Encoder quirks

```
== 1. number formatting: encode_number = string.format('%.14g', val) ==
  lua 0                      -> json 0
  lua 23374                  -> json 23374
  lua 3097                   -> json 3097
  lua 50292                  -> json 50292
  lua 1000000                -> json 1000000
  lua 0.25                   -> json 0.25
  lua 0.12320916905444       -> json 0.12320916905444
  lua 0.010135135135135      -> json 0.010135135135135
  lua 1e+15                  -> json 1e+15
  lua 1e+16                  -> json 1e+16
  json.decode('23374.0')            -> 23374  type=number  re-encode=23374
  json.decode('23374.0') == 23374   -> true
  concat  ''..json.decode('23374.0')-> '23374'
  tostring(json.decode('23374.0'))  -> '23374'
  concat  'profile_'..decode('2.0') -> 'profile_2'
  json.decode('1e3')                -> 1000
  rt of 0.010135135135135           -> 0.010135135135135
  rt of 0.1234567890123456          -> 0.12345678901235   <-- 14 sig digits only
  rt of 12345678901234567           -> 1.2345678901235e+16   <-- exponent form

== 2. empty-table ambiguity ==
  json.encode({})                   -> []
  decode('{}') then encode          -> []   <-- OBJECT BECOMES ARRAY
  decode('[]') then encode          -> []
  encode({a={}})                    -> {"a":[]}
  decode('{"items":{}}') then encode -> {"items":[]}

== 3. null handling ==
  decode object with null 'b': b=nil (key vanishes); re-encode: {"c":3,"a":1}
  decode [1,null,3] ok=true
    #arr=1  [1]=1 [2]=nil [3]=3
    re-encode ok=false  result/err= .../corelib/json.lua:80: invalid table: sparse array
  decode [null] ok=true  #=0  re-encode ok=true -> []
  decode bare null ok=true  value=nil

== 4. escaping ==
  encode('a/b')                     -> "a/b"   <-- slash NOT escaped on write
  decode of an escaped slash        -> a/b   <-- but accepted on read
  encode of a TAB                   -> "tab\there"
  encode of a NEWLINE               -> "line\nbreak"
  encode of byte 0x7f (DEL)         -> ""   <-- passed through RAW, not escaped
  encode of UTF-8 'zaozty'          -> "zaółty"   <-- raw UTF-8 bytes, never uXXXX
  decode of a uXXXX escape ok=true  bytes=2  re-encode="ó"   <-- escape is NOT preserved

== 5. tables that REFUSE to encode (pcall in vBotConfigSave swallows this: file is NOT written) ==
  encode({1,2,x=3})        ok=false  err=.../corelib/json.lua:75: invalid table: mixed or invalid key types
  encode(sparse [1]=1,[3]=3) ok=false  err=.../corelib/json.lua:80: invalid table: sparse array
  encode({[1]='a',name='b'}) ok=false  err=.../corelib/json.lua:75: invalid table: mixed or invalid key types
  encode({['1']=1})                 -> {"1":1}   <-- string key survives as a key

== 6. duplicate keys: last wins ==
  decode of a duplicated key 'a'    -> a=2

== 7. key-order determinism inside one process ==
  encode #1 of the SAME table       {"delta":4,"epsilon":5,"alpha":1,"beta":2,"gamma":3}
  encode #2 of the SAME table       {"delta":4,"epsilon":5,"alpha":1,"beta":2,"gamma":3}
  encode of a 2nd, equal table      {"delta":4,"epsilon":5,"alpha":1,"beta":2,"gamma":3}

== 8. Supplies items map: integer-looking string keys ==
  key='23374'  type(key)=string  tonumber(key)=23374
  re-encode -> {"items":{"23374":{"max":1200,"avg":0,"min":200}}}
  what if a writer used a NUMBER key instead:
    encode ok=false  err=.../corelib/json.lua:93: invalid table: mixed or invalid key types   <-- WHOLE SAVE FAILS

== 9. top-level scalars / decoder strictness ==
  decode(""          ) ok=false -> unexpected character '' at line 1 col 1
  decode(" "         ) ok=false -> unexpected character '' at line 1 col 2
  decode("[]"        ) ok=true
  decode("{}"        ) ok=true
  decode("5"         ) ok=true  -> 5
  decode(""x""       ) ok=true  -> x
  decode("true"      ) ok=true  -> true
  decode("{"a":1,}"  ) ok=true          <-- trailing comma TOLERATED
  decode("{'a':1}"   ) ok=false -> expected string for key at line 1 col 2
  decode("{"a":1} "  ) ok=true          <-- trailing whitespace tolerated
  decode("{"a":1}x"  ) ok=false -> trailing garbage at line 1 col 8
  decode("{"a":01}"  ) ok=true          <-- leading zeros TOLERATED (tonumber)
  decode("{"a":.5}"  ) ok=false -> unexpected character '.' at line 1 col 6
  decode("{"a":+1}"  ) ok=false -> unexpected character '+' at line 1 col 6
```

Reading these against the source:

* **Numbers** — `encode_number` is `string.format('%.14g', val)` (json.lua:106-112).
  LuaJIT has one numeric type (double), so `23374` and `23374.0` are the *same value*;
  `%.14g` and `tostring` both print integral doubles with no decimal point.
  **Answer to "does an item id ever come back as `23374.0` and break a concatenation?" —
  No.** `json.decode("23374.0")` is `23374`, `'' .. that` is `"23374"`, and re-encoding
  emits `23374`. The concatenations in `supplies.lua:56/213` (`tostring(item)`) and
  `HealBot.lua:420` are safe. Writing `23374.0` in a *value* position is therefore
  harmless — but writing `"23374.0"` as a Supplies **key** is not (§4.4).
  `Infinity` / `NaN` raise (json.lua:107-110). Values past 14 significant digits or
  ≥1e15 change shape (exponent form) — irrelevant for item ids, relevant for `_icons` floats.
* **Empty tables** — json.lua:70: `if rawget(val, 1) ~= nil or next(val) == nil then`
  → array branch. **An empty Lua table always encodes as `[]`, never `{}`.** So vBot's own
  files contain `"attackTable":[]`, `"itemTable":[]`, `"items":[]`, `"containers":[]`.
  In Lua both decode to the same thing, so this is lossless *for vBot*. It is **not**
  lossless for a foreign reader: our client must accept `[]` wherever the schema says
  "object" (`Supplies.items`, `storage._macros`, …) and treat it as an empty map.
  For writing: emitting `{}` for an empty object also works (vBot's decoder yields the same
  table), but emitting `[]` matches what vBot itself produces.
* **null** — `literal_map['null'] = nil` (json.lua:157). In an **object**, `res[key] = nil`
  (json.lua:321) simply never creates the key: `null` and "absent" are indistinguishable.
  In an **array** it is destructive: `parse_array` does `res[n] = x; n = n + 1`
  (json.lua:280-281), so a `null` element leaves a **hole** — `[1,null,3]` decodes to a
  table with `#` = 1 and a live `[3]`. Re-encoding it throws
  `invalid table: sparse array` (json.lua:79-81), the `pcall` in `vBotConfigSave`
  (configs.lua:85-90) swallows it, and **the config is silently never saved again** —
  a permanent, invisible save failure. **NEVER emit `null` inside any array.**
* **Escaping** — `escape_char_map` covers only `\ " \b \f \n \r \t` (json.lua:34-42);
  everything else in `[%z\1-\31\\"]` becomes `\u00xx` (json.lua:51-53, 103). `/` is not
  escaped on write but `\/` is accepted on read (json.lua:44-46). Bytes ≥ 0x7f are passed
  through raw — **files are UTF-8 byte-transparent, never `\uXXXX`-escaped**. A `\uXXXX`
  escape in an input file is decoded to UTF-8 and re-encoded raw, i.e. **not preserved**.
* **Mixed / sparse key types** — any Lua table with both integer and string keys, or a
  numeric key in a map, throws (json.lua:74-75, 79-81, 92-93). All three failures land in
  `vBotConfigSave`'s `pcall` and mean *the file is not written*.
* **Duplicate keys** — last wins (json.lua:321). Don't emit duplicates.
* **Decoder tolerance** — trailing commas and leading zeros are accepted;
  single quotes, `.5`, `+1`, trailing garbage, and an empty file are not. Note
  `Config.load`/`Config.parse` short-circuit on `data:len() < 2` and return `{}`
  (config.lua:60, config.lua:40), so a 0- or 1-byte targetbot file is tolerated —
  but a 0-byte `HealBot.json`/`AttackBot.json`/`Supplies.json` goes straight into
  `json.decode` (configs.lua:33) and **kills the bot load** (§1.5).

### 7.5 Graceful-degradation matrix (what actually happens on bad input)

```
== A. HealBot/AttackBot profile-array length gate ==
   guard: `not C[n] or not C[n][1] or #C[n] ~= 5`  (HealBot.lua:271, AttackBot.lua:1635)
   {"healbot":[]}                      #=0  -> vBot REGENERATES 5 blank profiles (USER DATA LOST)
   {"healbot":{}}                      #=0  -> vBot REGENERATES 5 blank profiles (USER DATA LOST)
   {"healbot":[{},{},{},{},{}]}        #=5  -> vBot keeps the file's profiles
   {"healbot":[{},{},{},{},{},{}]}     #=6  -> vBot REGENERATES 5 blank profiles (USER DATA LOST)

== B. currentHealBotProfile / currentBotProfile type confusion ==
   guard: `not X or X == 0 or X > 5` then C[panel][X]
   1      -> ok, resolved profile index 1
   5      -> ok, resolved profile index 5
   0      -> ok, resolved profile index 1
   6      -> ok, resolved profile index 1
   -1     -> HARD ERROR: attempt to index local 'cur' (a nil value)
   1.5    -> HARD ERROR: attempt to index local 'cur' (a nil value)
   "1"    -> HARD ERROR: attempt to compare number with string
   true   -> HARD ERROR: attempt to compare number with boolean
   null   -> ok, resolved profile index 1

== C. targeting entry with a missing numeric key ==
   creature_priority.lua:12 `#path > config.maxDistance`, :22 `priority + config.priority`
   maxDistance missing: ok=false  attempt to compare nil with number
   priority missing:    ok=false  attempt to perform arithmetic on field 'priority' (a nil value)
   maxDistance = STRING: ok=false  attempt to compare string with number

== D. targeting entry with no `name` ==
   creature.lua:16 `type(config.name) ~= 'string'` -> error('Invalid targetbot creature config (missing name)')
   {"priority":1}     -> REJECTED (entry dropped, rest of file still loads)
   {"name":123}       -> REJECTED (entry dropped, rest of file still loads)
   {"name":"*"}       -> accepted

== E. attackTable entry with missing itemId ==
   AttackBot.lua:2785 `entry.itemId > 100`
   itemId missing: ok=false  attempt to compare number with nil

== F. Supplies: items key written as a number vs a string ==
   string key '23374'   -> lookup items[tostring(23374)] = true
   string key '23374.0' -> lookup items[tostring(23374)] = false   <-- entry becomes invisible to the save path

== G. what a totally empty file body does ==
   decode('[]') -> C.healbot=nil  => vBot regenerates defaults, no error (safe reset value)
   decode('{}') -> C.healbot=nil  => vBot regenerates defaults, no error (safe reset value)
```

Summary of the three degradation modes:

| Mode | Where | Symptom |
|---|---|---|
| **Silent data loss** | HealBot/AttackBot profile array ≠ 5 (A) | file rewritten with 5 blank profiles |
| **Hard error** | wrong scalar type / missing required number (B, C, E) | for `vBot_configs/*` and `storage`: the whole bot script fails to load (§1.5). For targetbot: an error every 100 ms inside the targeting macro |
| **Silent no-op** | unknown `origin`/`sign` string, dead keys, `curePosion` | rule never matches; no message anywhere |

---

## 8. MUST / NEVER for a foreign writer

### MUST

1. **Emit minified JSON: no indentation, no trailing newline, no BOM.**
   That is what `json.encode` + `writeFileContents` produce (json.lua:87/98,
   resourcemanager.cpp:665-668). Verified: all of the user's files end in `}` with nothing after it.
2. **Preserve array order exactly** for `attackTable`, `spellTable`, `itemTable`,
   `targeting`, `looting.items`, `looting.containers`. Order is priority everywhere
   (AttackBot.lua:2783, HealBot.lua:690/775, and the save loops at AttackBot.lua:1785,
   target.lua:240).
3. **Round-trip every key we do not understand, byte-for-value.** `ignoreMana`,
   `Cooldown` (AttackBot), `curePosion`, `index`, `creatures`, `tooltip`, `description`
   and every unrecognised `storage` key must survive untouched.
4. **Keep `healbot` and `AttackBot` at exactly 5 elements**, and `currentHealBotProfile` /
   `currentBotProfile` an integer in 1..5.
5. **Write all 28 keys on every `targeting` entry.** There are no load-time defaults.
6. **Keep `regex` consistent with `name`** using the exact transform at
   `creature_editor.lua:66-72`.
7. **Keep `category` → `patternCategory` consistent** with
   `category == 4 and 3 or category == 5 and 4 or category` (AttackBot.lua:1866), and keep
   `pattern` a valid 1-based index into `patterns[patternCategory]`.
8. **Write Supplies `items` keys as `tostring(<integer id>)`** — `"23374"`.
9. **Write Supplies `capValue` / `lootPouchValue` / `staminaValue` as digit strings**
   (`"200"`), matching supplies.lua:328-329.
10. **Write `looting.items` / `looting.containers` as `{"id":N,"count":M}` objects**
    (ui_elements.lua:90), not bare numbers.
11. **Regenerate `description` (AttackBot) whenever the entry's parameters change** —
    it is the only thing shown in the UI list (AttackBot.lua:2150). Format at
    AttackBot.lua:2276.
12. **Only write when the client is closed**, or force a bot reload afterwards (§1.4).

### NEVER

1. **Never emit `null` inside an array.** It creates a sparse table whose next
   `json.encode` throws `invalid table: sparse array` (json.lua:80) inside a swallowing
   `pcall` — the config then silently stops saving forever. In an *object*, `null` is only
   equivalent to omitting the key; prefer omitting it.
2. **Never use a non-string key in a JSON-object position** — for us that means never
   emitting a bare-number Supplies item id. On the Lua side that is
   `invalid table: mixed or invalid key types` (json.lua:93) → save silently fails.
3. **Never write a 0- or 1-byte `HealBot.json` / `AttackBot.json` / `Supplies.json`.**
   `configs.lua:33/44/55` has no length short-circuit, `json.decode("")` throws, and the
   `onError` handler does not exist in the sandbox → the whole bot fails to load (§1.5).
   `[]` is the safe "reset" content for all five file types.
4. **Never change `origin` or `sign` casing/spelling.** Only `"HP"`, `"HP%"`, `"MP"`,
   `"MP%"`, `"burst"` and `"<"`, `">"`, `"="` do anything (HealBot.lua:693-712, 781-800).
5. **Never re-sort `spellTable` / `itemTable` by the `index` field.** It is stale by design
   (§3.6) — the user's real file has array order 1,2,3 carrying index 2,3,1.
6. **Never rename a Supplies profile to `currentProfile`.**
7. **Never assume key order means anything, and never try to reproduce it.**
   vBot cannot reproduce its own (§7.1, §7.2).
8. **Never `\uXXXX`-escape non-ASCII.** vBot writes raw UTF-8 bytes; escapes decode fine
   but are not what the GUI will write back, and `\uXXXX` is not round-trip-preserved.
9. **Never add a 6th profile** to `healbot` / `AttackBot`, and never turn either into an
   object — both wipe the user's data (§7.5 A).
10. **Never convert `[]` back to `{}` blindly in a *value* position we don't understand.**
    In Lua they are the same, but if we hand a `{}` where vBot's own writer would put `[]`
    we create pointless diffs; and if we hand `[]` where our own reader expects a map we
    break ourselves.

### The fields where a mistake changes bot behaviour with no error and no warning

| File | Field | What a wrong value silently does |
|---|---|---|
| AttackBot | `category` / `patternCategory` / `pattern` | fires a different area shape / range than the label says; can index a wrong `spellPatterns` table (AttackBot.lua:2971, 3028, 3063) |
| AttackBot | `orMore` | flips "N or more monsters" to "exactly N monsters" (AttackBot.lua:1577) |
| AttackBot | `monsters` | `true` = any creature; a wrong/absent value is treated as "any" (AttackBot.lua:1402) |
| AttackBot | array position in `attackTable` | reorders spell priority; first match wins and returns (AttackBot.lua:2783+) |
| AttackBot | `description` | the only text in the UI; a stale one makes the list lie |
| HealBot | `origin` | `"HP"` (absolute hitpoints) vs `"HP%"` (percent) — same `value`, wildly different trigger |
| HealBot | `sign` | `"<"` ↔ `">"` inverts the rule; anything else disables it |
| HealBot | array position in `spellTable`/`itemTable` | priority; first match returns (HealBot.lua:690, 775) |
| HealBot | `Visible` | `true` = only use potions the client can see; `false` = fire blind (HealBot.lua:780) |
| ConditionPanel | `curePoison` vs `curePosion` | the misspelled one is inert; only `curePoison` is read (Conditions.lua:241) |
| TargetBot | `priority` | steals or loses targeting vs other entries (creature_priority.lua:22, creature.lua:81) |
| TargetBot | `danger` | summed over all monsters; gates the looter off above `looting.maxDanger` (target.lua:73, looting.lua:112) |
| TargetBot | `everyItem` | inverts `looting.items` from a loot list into an ignore list (looting.lua:13, 243) |
| TargetBot | `regex` (vs `name`) | the entry keeps matching the old creature while the UI shows the new name (creature.lua:62) |
| TargetBot | `dontLoot`, `chase`, `keepDistance` | change walking/looting behaviour with no visible marker |
| Supplies | `items` key spelling | a `"23374.0"`-style key is invisible to the GUI and is dropped on the next save (supplies.lua:158, 213) |
| Supplies | `currentProfile` | pointing at a missing profile makes vBot pick one via `pairs` — **non-deterministic** (supplies.lua:79-87) |
| storage | any unrecognised key | dropping it silently resets that script's whole feature to its first-run default |
