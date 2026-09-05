# HealBot — self-healing and condition curing (vBot 4.8)

# HealBot — behaviour specification for a headless LuaJIT reimplementation

Sources (read-only):
* `D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\HealBot.lua` (816 lines)
* `D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\Conditions.lua` (259 lines)
* `D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\configs.lua` (97 lines)
* `D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\vlib.lua` (helpers)
* `D:\Claude\otclient_mehah1530\otclient\mods\game_bot\executor.lua`, `...\functions\player.lua`, `...\functions\player_conditions.lua`, `...\functions\callbacks.lua`
* `D:\Claude\otclient_mehah1530\otclient\src\client\const.h` (PlayerStates), `...\src\client\game.cpp` (useInventoryItemWith)
* `D:\Claude\otclient_mehah1530\otclient\modules\gamelib\spells.lua` (spell DB), `...\modules\game_interface\gameinterface.lua` (say → wire)

Target: `D:\Claude\otclient_web\luaclient` (see `API.md`).

---

## 0. Executive summary — what HealBot actually is

HealBot is **four independent, stateless-per-tick polling loops**. There is *no* unified rule
list, *no* priority number, *no* "condition" trigger type inside HealBot itself. Concretely:

| loop | file:line | period (declared → effective) | what it does |
|---|---|---|---|
| spell loop | `HealBot.lua:687-717` | `macro(20)` → **50 ms** (clamped, `executor.lua:38-40`) | first matching **spell** rule fires, `return` |
| item loop | `HealBot.lua:748-805` | `macro(100)` → 100 ms | first matching **item** rule fires, `return` |
| conditions slow loop | `Conditions.lua:238-251` | `macro(500)` → 500 ms | cures (poison/curse/bleed/burn/electrify) + utura + utana |
| conditions fast loop | `Conditions.lua:253-259` | `macro(50)` → 50 ms | utamo vita + haste + paralysis cure |

`Conditions.lua` is a **separate module with a separate on/off switch**, but it persists into the
**same JSON file** as HealBot (`HealBotConfig.ConditionPanel`, `Conditions.lua:27-56`, saved by
`vBotConfigSave("heal")` at `Conditions.lua:64` / `:80`). A reimplementation should treat them as
one subsystem with two enable flags.

Every macro is registered by `context.macro` (`executor.lua:9-127`) and driven by the single tick
function at `executor.lua:194-212`: a macro runs when `macro.lastExecution + macro.timeout <= now`
**and** `macro.enabled` **and** `(not macro.delay or macro.delay < now)`. Two consequences a
reimplementer must copy:

1. **Minimum period is 50 ms.** `executor.lua:38-40`: `if timeout < 50 then timeout = 50 end`. The
   `macro(20, ...)` in HealBot is therefore a 50 ms loop, and AttackBot's `macro(5, ...)` is also
   50 ms.
2. **Random start jitter.** `executor.lua:46`: `lastExecution = now + math.random(0, 100)`. Purely
   anti-detection dithering; safe to keep or drop.

---

## 1. The rule model

### 1.1 A spell rule (`spellTable` entry)

Constructed at `HealBot.lua:501`:

```lua
{index = #t+1, spell = <string>, sign = "<"|">"|"=", origin = "HP"|"HP%"|"MP"|"MP%"|"burst",
 cost = <number>, value = <number>, enabled = <bool>}
```

| field | meaning | behaviour or widget-only |
|---|---|---|
| `spell` | literal spell words, e.g. `"exura gran"` — sent verbatim | **behaviour** |
| `origin` | trigger source (see 1.3) | **behaviour** |
| `sign` | comparison operator | **behaviour** |
| `value` | threshold compared against the source | **behaviour** |
| `cost` | mana gate: the rule is skipped unless `cost < mana()` (`HealBot.lua:691`) — note **strict `<`**, and note it is *not* the spell's real mana cost, it is a user-entered floor | **behaviour** |
| `enabled` | per-rule on/off (`HealBot.lua:691`) | **behaviour** |
| `index` | written at insert time and **never read by the tick logic**; it goes stale the moment MoveUp/MoveDown swaps array slots (`HealBot.lua:426-448` swaps `t[i]`/`t[i±1]` without touching `.index`). Real ordering is the **array order**. | **widget detail** |

There is **no per-rule delay and no per-rule priority field.** Priority == array position.

### 1.2 An item rule (`itemTable` entry)

Constructed at `HealBot.lua:536`:

```lua
{index = #t+1, item = <itemId number>, sign = "<"|">"|"=", origin = ..., value = <number>,
 enabled = <bool>}
```

Same fields minus `spell`/`cost` (**items have no mana gate at all**). `item` must be `> 100`
(`HealBot.lua:535`) — the widget refuses smaller ids.

### 1.3 Trigger sources (`origin`)

Widget dropdown text → stored token (`HealBot.lua:490-494` for spells, `:525-529` for items;
options declared in `HealBot.otui:11-15`):

| dropdown text | stored `origin` | evaluated as |
|---|---|---|
| `Current Mana` | `"MP"` | `player:getMana()` |
| `Current Health` | `"HP"` | `player:getHealth()` |
| `Mana Percent` | `"MP%"` | `math.floor(mana*100/maxMana)`, **or 100 when `maxMana <= 1`** (`player.lua:8-15`) |
| `Health Percent` | `"HP%"` | `player:getHealthPercent()` — the **server-sent 0-100 byte from opcode `0x8C`**, *not* `health/maxHealth` (`protocolgameparse.cpp:2470`) |
| anything else (`Burst Damage`) | `"burst"` | `burstDamageValue()` (`vlib.lua:68-78`) |

`sign` mapping (`HealBot.lua:496-498` / `:531-533`; options at `HealBot.otui:21-23`):
`Below → "<"`, `Above → ">"`, `Equal To → "="`.

**The comparisons are NOT what the labels say.** `HealBot.lua:693-713`:
* `"="` → `source == value`
* `">"` → `source >= value` (inclusive!)
* `"<"` → `source <= value` (inclusive!)

`burstDamageValue()` (`vlib.lua:44-78`): a `onTextMessage` hook collects `"you lose … due to …"`
messages, `string.match(text, "%d+")` (**first number only**, kept as a *string*), timestamped;
entries older than 3000 ms are pruned; `burstDamageValue()` returns
`math.ceil(sum / ((now - firstEntryTime)/1000))` and **returns 0 when fewer than 2 entries exist**
(the `d`/`time` locals stay 0/0 → `math.ceil(0/…)`; with `#dmgTable == 0`, `time == 0`, so it is
`ceil(0/huge) = 0`). This is damage-per-second over the trailing ≤3 s window.

### 1.4 Ordering and selection — one rule per tick, per loop

Both loops are `for _, entry in pairs(table) do … return … end` and **`return` on the first match**.
So exactly **one spell per spell tick** and **one item per item tick** at most.

`pairs()` on a pure array in LuaJIT walks the array part in ascending index order, which is why
MoveUp/MoveDown (`HealBot.lua:426-472`) — which physically swaps array slots — is the priority
mechanism. **Reimplement with `ipairs`/numeric `for`, top of the list = highest priority.**

Note the ordering interacts with the guards: the mana gate (`entry.cost < mana()`) and the cooldown
gate are evaluated **inside** the loop, so a blocked high-priority rule does **not** stop lower rules
from firing on the same tick — the loop simply continues to the next entry.

### 1.5 Not a rule model: conditions

Curing/holding is **not** expressible as a `spellTable` entry. It lives in `Conditions.lua` as a
fixed, hardcoded if/elseif chain over a flat settings record. See §4.

### 1.6 Dead configuration (widget-only, ignore in a headless port)

Verified by grep over `HealBot.lua` — these per-profile flags exist in the JSON but are **never read
by any tick**:
* `Delay` — only toggled/checked in UI (`:365-368`, `:557`, `:577`). **Unused.**
* `Conditions` — only toggled/checked in UI (`:361-364`, `:560`, `:580`). **Unused** (it does *not*
  gate `Conditions.lua`, which has its own `HealBotConfig.ConditionPanel.enabled`).

Live flags: `Cooldown` (`:646`), `Visible` (`:780`), `Interval` + `MessageDelay` (`:767-772`).

Also dead code inside the file: `standBySpells` (assigned in 6 places, **never read**);
`checkInventoryConsumption` (`:35-46`, **never called** from HealBot or AttackBot).

---

## 2. Exact tick logic

### 2.1 Spell loop — `HealBot.lua:687-717`

```
every 50 ms:
  if not profile.enabled: return
  for entry in profile.spellTable (array order):
    if not entry.enabled:            continue
    if not (entry.cost < mana()):    continue          -- strict <
    if not healSpellCooldownReady(entry.spell): continue
    if compare(source(entry.origin), entry.sign, entry.value):
        say(entry.spell)
        return                                          -- one cast per tick
```

Notably absent, **by design**:
* no shared use-cooldown check (spells do not consume the 1 s item slot),
* no `AttackBotFiringUntil` / `AttackBotRuneReadyUntil` check (spells are never yielded to AttackBot),
* no PZ check, no dead check, no target check,
* no post-cast local lockout — the only pacing is `healSpellCooldownReady`.

#### `healSpellCooldownReady(spellText)` — `HealBot.lua:645-669`

```
if not profile.Cooldown: return true                    -- user disabled cooldown gating entirely
remaining = getRealSpellRemaining(spellText)
if remaining == nil: return canCast(spellText, true, false)   -- icon fallback, first cast only
return remaining <= getRawPing()                        -- fire early by exactly one RTT
```

`getRealSpellRemaining` — `HealBot.lua:95-120`:
```
data = getSpellData(spellText)          -- from the static spell DB, or from vBot.customCooldowns
if not data: return nil
remaining = nil
if SpellCooldownCache[data.id]:  remaining = cache.exhaustion - (now - cache.startTime)
for groupId in pairs(data.group or {}):
    g = SpellCooldownCache["group_"..groupId]
    if g: gr = g.exhaustion - (now - g.startTime); remaining = max(remaining or -inf, gr)
return remaining                                        -- MAX of own and every group cooldown
```

`SpellCooldownCache` is filled by two callbacks (`HealBot.lua:82-92`):
* `onSpellCooldown(spellId, durationMs)` → `cache[spellId] = {exhaustion=duration, startTime=now}`
  — wire opcode **`0xA4` SpellDelay**, luaclient event `spellCooldown {spellId, delay}`
  (`parser.lua:1869-1872`).
* `onGroupSpellCooldown(groupId, durationMs)` → `cache["group_"..groupId] = {...}`
  — wire opcode **`0xA5` SpellGroupDelay**, luaclient event `spellGroupCooldown {groupId, delay}`
  (`parser.lua:1873-1876`).

The cache key `data.id` is the spell's **protocol spell id** from `SpellInfo['Default'][…].id`
(e.g. Intense Healing = 2, Spirit Mend = 273 — `gamelib/spells.lua:38`, `:219`), *not* `clientId`
(which is the icon sprite index only).

`getRawPing()` = `g_game.getPing()` or 0 (`HealBot.lua:122-126`).
`getPingCompensation()` = `ping > 150 and ping - 30 or 0` (`HealBot.lua:48-56`) — used by the
*item* path and by AttackBot, **not** by `healSpellCooldownReady` (which uses raw ping).

**Anti-double-cast**: there is none other than the cooldown predictor. The comment at
`HealBot.lua:638-643` is explicit that this is intentional: "a spell costs nothing extra if the
server silently rejects an early attempt — so after a predictive cast we keep retrying every tick
until the cooldown icon actually confirms it landed". Between the send and the server's `0xA4`/`0xA5`
arriving (≈1 RTT), the loop **re-fires the same spell every 50 ms**. Expect 1-4 duplicate casts per
heal at typical ping. A headless port that wants to be quieter should add its own optimistic
`startTime = now` write into the cache at send time (see Pitfalls).

### 2.2 Item loop — `HealBot.lua:748-805`

```
every 100 ms:
  if standByItems:                          return       -- sleep flag, see 2.4
  if not profile.enabled or #itemTable==0:  return
  if getMultiUseCooldown() > 0:             return       -- shared 1 s use slot busy
  if now < AttackBotFiringUntil:            return       -- AttackBot reserved the slot
  if now < AttackBotRuneReadyUntil:         return       -- a rune is ready and waiting for the slot
  if TargetBot.isOn() and #TargetBot.Looting.getStatus() > 0 and profile.Interval:
      delay(profile.MessageDelay and 200 or 700)         -- pauses the NEXT invocation only
  for entry in profile.itemTable (array order):
      item = hasItemAvailable(entry.item)
      if (not profile.Visible or item) and entry.enabled:
          if compare(source(entry.origin), entry.sign, entry.value):
              useHealItem(entry.item); return
  standByItems = true                                    -- nothing matched → sleep
```

Order of the guards matters and must be preserved: the shared-cooldown / AttackBot guards are
checked **before** any rule is evaluated, so a busy slot costs a whole 100 ms tick.

`delay(ms)` (`executor.lua:206-211`) sets `_currentExecution.delay = now + ms`; the **current pass
still completes normally** — only the *next* invocation is postponed. So during looting the item
loop degrades from 100 ms to 700 ms (or 200 ms if `MessageDelay` is on). `MessageDelay`'s name is
misleading: `true` means the **shorter** 200 ms delay.

#### `useHealItem(itemId)` — `HealBot.lua:724-745`

```
if now < AttackBotFiringUntil or now < AttackBotRuneReadyUntil: return   -- re-checked
if now - lastHealItemUse < 50: return                                    -- same-tick double-send guard
lastHealItemUse = now
recordLocalUseCooldown()                       -- SharedUseCooldown.expiresAt = max(old, now+1000)
g_game.useInventoryItemWith(itemId, player)
```

`g_game.useInventoryItemWith(itemId, <the local player creature>)` resolves in C++
(`game.cpp:883-907`) — for clientVersion ≥ 780, target is a creature, so it sends
**`sendUseOnCreature(Position(0xFFFF, 0, 0), itemId, 0, player:getId())`**, i.e. opcode `0x84` with
`fromPos = {x=0xFFFF, y=0, z=0}`, `itemId`, `stackpos = 0`, `creatureId = <own id>`.
**Note `y = 0`, not the item id** — this is the "item is in inventory, resolve by id server-side"
sentinel. That is why potions work out of a *closed* backpack.

#### Shared use-cooldown — `HealBot.lua:20-33`, `:58-62`

```
USE_COOLDOWN_MS = 1000                                            -- fixed, authoritative
SharedUseCooldown = { expiresAt = 0 }
recordLocalUseCooldown(ms) -> expiresAt = max(expiresAt, now + (ms or 1000))
getMultiUseCooldown()      -> max(0, expiresAt - now - getPingCompensation())
```

This block is **duplicated verbatim in `AttackBot.lua:22-46` and `HealBot.lua:20-46`** and guarded
so whichever chunk loads first wins. It is a purely **client-side, optimistic** model: the code
comment (`HealBot.lua:11-19`) states `g_game.onMultiUseCooldown` does not fire on this build, so no
server signal is ever consulted. (Aside: the luaclient parser *does* decode opcode `0xA6`
MultiUseDelay → event `multiUseCooldown {delay}`, `parser.lua:1877-1879`, so a port can do better —
see Open questions.)

`hasItemAvailable(id, tier)` (`vlib.lua:863-871`) = `itemAmount(id,tier) > 0`, where `itemAmount`
(`vlib.lua:873-887`) is `max(visible scan, server-pushed count)`:
* server count = `player:getInventoryCount(id, tier or 0)` — fed by opcode **`0xF5`**, which counts
  everything *carried*, including closed containers, but **not** depot/inbox/stash/corpses;
* visible scan = `player:getItemsCount(id)` — equipped slots + **open** containers only (so it does
  see an open depot).

### 2.3 What it does when dead / in PZ / not logged in

* **Not logged in**: the whole bot is torn down. `bot.lua:346-350` `offline()` → `save(); clear()`,
  so no macro exists off-game. In a headless port: only run the loops while the session is in the
  playing state.
* **Dead**: **nothing special.** There is no `isDead()` check anywhere in `HealBot.lua`. On death
  `healthPercent` goes to 0, so every `HP% <` rule matches and both loops keep firing heals/potions
  against a corpse until the client actually leaves the world. This is a genuine defect to fix in
  the port (gate on `st.player.health > 0`).
* **In PZ**: HealBot itself ignores PZ entirely. Only `Conditions.lua` has a PZ gate
  (`ignoreInPz`, §4.3), and it applies **only** to the *hold*-buff branches (utura/utana/utamo/haste),
  never to the cure branches.

### 2.4 The `standByItems` sleep flag

`standByItems` starts `false` (`HealBot.lua:2`), is set `true` when a full item pass matched nothing
(`:804`), blocks the loop at `:749`, and is cleared by:
* `onPlayerHealthChange(healthPercent)` — `:809-812` (fires on opcode `0x8C` for the local player,
  `callbacks.lua:264-271`);
* `onManaChange(player, mana, maxMana, oldMana, oldMaxMana)` — `:814-817` (opcode `0xA0`);
* any UI mutation of a rule (`:381-388`, `:407-414`, `:506-507`, `:537-538`).

**This is a latent bug for `burst`-origin item rules**: burst damage decays on a timer with no HP/MP
event, so a sleeping item loop is never woken. The spell loop deliberately abandoned the same
mechanism — see the long comment at `HealBot.lua:676-686`. **A port should drop `standByItems`
entirely and just poll**; the 100 ms cost is negligible.

---

## 3. Interaction with AttackBot / CaveBot / TargetBot

There is **no general action lock**. There are three narrowly-scoped, *global-variable*
handshakes, all owned by AttackBot and only ever read (never written) by HealBot:

| global | writer | value | effect on HealBot |
|---|---|---|---|
| `SharedUseCooldown.expiresAt` | both, via `recordLocalUseCooldown()` | `now + 1000` | item loop returns while `getMultiUseCooldown() > 0` (`HealBot.lua:753`) |
| `AttackBotFiringUntil` | `AttackBot.lua:2697` (`runeDelayGate`: `delayEnd + 10`), `:2833`/`:2868` (`max(cur, readyAt + 150)` — set as soon as `now >= readyAt - 1000`), `:2903`/`:2927` (`now + 150`), `:3086` (`now + 400`) | absolute ms | item loop returns (`:757`); `useHealItem` returns (`:728`) |
| `AttackBotRuneReadyUntil` | `AttackBot.lua:2891` — `now + 250`, **refreshed every AttackBot tick while a rune is off cooldown but blocked on the shared slot** | absolute ms | item loop returns (`:765`); `useHealItem` returns (`:728`) |

**Priority verdict: for items, AttackBot outranks HealBot.** Potions yield to runes, both
predictively (up to a full `USE_COOLDOWN_MS` = 1000 ms before the rune is ready) and reactively
(`AttackBotRuneReadyUntil`). **For spells, HealBot has absolute priority** — the spell loop consults
none of these.

TargetBot interaction is one-way and cosmetic: while `TargetBot.isOn()` and looting is in progress
(`TargetBot.Looting.getStatus()` non-empty, `targetbot/looting.lua:103-105`), the item loop
throttles itself to 700/200 ms so potion sends don't collide with the loot-move traffic
(`HealBot.lua:767-773`). CaveBot is not referenced from HealBot at all;
`TargetBot.isCaveBotActionAllowed()` (`targetbot/target.lua:186-188`, `cavebotAllowance > now`) is
consulted only by the haste branch in `Conditions.lua:256`.

---

## 4. Condition curing (`Conditions.lua`)

### 4.1 Detection: the player-states bitmask

`player_conditions.lua:7` — `hasCondition(bit) = Bit.band(player:getStates(), bit) > 0`.
Bits from `src/client/const.h:278-297` (`enum PlayerStates : uint64_t`):

| bit | value | vBot predicate (`player_conditions.lua`) |
|---|---|---|
| Poison | `1` | `isPoisioned()` *(sic — typo is the real name)* `:9` |
| Burn | `2` | `isBurning()` `:10` |
| Energy | `4` | `isEnergized()` `:11` |
| Drunk | `8` | `isDrunk()` `:12` |
| ManaShield | `16` | `hasManaShield()` `:13` |
| Paralyze | `32` | `isParalyzed()` `:15` |
| Haste | `64` | `hasHaste()` `:16` |
| Swords (in fight) | `128` | `isInFight()` `:18` |
| Drowning | `256` | `isDrowning()` `:20` |
| Freezing | `512` | `isFreezing()` `:21` |
| Dazzled | `1024` | `isDazzled()` `:22` |
| Cursed | `2048` | `isCursed()` `:23` |
| PartyBuff | `4096` | `hasPartyBuff()` `:24` |
| PzBlock | `8192` | `isPzLocked()` `:25-28` |
| Pz | `16384` | `isInPz()` `:29-31` |
| Bleeding | `32768` | `isBleeding()` `:32` |
| Hungry | `65536` | `isHungry()` `:33` |

`hasNewManaShield()` (`:14`) maps to `PlayerStates.NewManaShield`, which **does not exist in the
1530 `const.h` enum** — `PlayerStates.NewManaShield` is `nil`, so `Bit.band(states, nil)` either
errors or is treated as 0 depending on the Bit shim; in practice it evaluates falsy. Treat the
utamo branch as gated on `ManaShield (16)` only.

In luaclient: `st.player.states` (u64 as a Lua number, `parser.lua:1849-1861`, opcode `0xA2`, split
`statesLo`/`statesHigh`), event `statesChange {states, lo, hi}`. **Use `statesLo` with `bit.band`** —
all 17 bits above fit in the low u32; `bit.band` on the combined `states` double would be wrong.

### 4.2 Slow loop — `Conditions.lua:238-251` (500 ms)

```
if not config.enabled: return
if isGroupCooldownIconActive(2): return          -- group 2 == "Healing" (gamelib/spells.lua:286)

if hppercent() > 95 then                          -- cures only run at near-full HP
    if     config.curePoison    and mana() >= config.poisonCost    and isPoisioned()  then say("exana pox")
    elseif config.cureCurse     and mana() >= config.curseCost     and isCursed()     then say("exana mort")
    elseif config.cureBleed     and mana() >= config.bleedCost     and isBleeding()   then say("exana kor")
    elseif config.cureBurn      and mana() >= config.burnCost      and isBurning()    then say("exana flam")
    elseif config.cureElectrify and mana() >= config.electrifyCost and isEnergized()  then say("exana vis")
    end
end
-- second, INDEPENDENT chain (not elseif-joined to the block above → can fire in the SAME tick)
if     (not config.ignoreInPz or not isInPz()) and config.holdUtura and mana() >= config.uturaCost
       and canCast(config.uturaType) and hppercent() < 90 then say(config.uturaType)
elseif (not config.ignoreInPz or not isInPz()) and config.holdUtana and mana() >= config.utanaCost
       and (not utanaCast or now - utanaCast > 120000) then say("utana vid"); utanaCast = now
end
```

The cure→spell table is **hardcoded and fixed**:

| condition | bit | spell words | mana key | enable key | protocol spell id / group (gamelib/spells.lua) |
|---|---|---|---|---|---|
| Poison | 1 | `exana pox` | `poisonCost` (20) | `curePoison` | id 29, group `{[2]=1000}`, exhaustion 6000 (`:65`) |
| Cursed | 2048 | `exana mort` | `curseCost` (80) | `cureCurse` | id 147, group `{[2]=1000}`, exh 6000 (`:161`) |
| Bleeding | 32768 | `exana kor` | `bleedCost` (45) | `cureBleed` | id 144, group `{[2]=1000}`, exh 6000 (`:158`) |
| Burn | 2 | `exana flam` | `burnCost` (30) | `cureBurn` | id 145, group `{[2]=1000}`, exh 6000 (`:159`) |
| Energy | 4 | `exana vis` | `electrifyCost` (22) | `cureElectrify` | id 146, group `{[2]=1000}`, exh 6000 (`:160`) |
| Paralyze | 32 | `config.paralyseSpell` (default `"utani hur"`) | `paralyseCost` (40) | `cureParalyse` | user-specified → looked up by words |

Note there is **no poison-*rune*/antidote-item path** — vBot cures poison only with the spell.
`mana()` comparisons here use **`>=`** (unlike the spell rules' strict `<`).

### 4.3 Fast loop — `Conditions.lua:253-259` (50 ms)

```
if not config.enabled: return
if     PZ_OK and config.holdUtamo and mana() >= config.utamoCost
       and not (hasManaShield() or hasNewManaShield())                    then say("utamo vita")
elseif (PZ_OK and standTime() < 5000 and config.holdHaste and mana() >= config.hasteCost
        and not hasHaste() and not getSpellCoolDown(config.hasteSpell)
        and (not target() or not config.stopHaste or TargetBot.isCaveBotActionAllowed()))
        and standTime() < 3000                                            then say(config.hasteSpell)
elseif config.cureParalyse and mana() >= config.paralyseCost and isParalyzed()
        and not getSpellCoolDown(config.paralyseSpell)                    then say(config.paralyseSpell)
end
```
where `PZ_OK = (not config.ignoreInPz or not isInPz())`.

* This chain is **`elseif`-joined**: exactly one of utamo / haste / paralysis-cure per 50 ms tick,
  in that fixed priority order. Utamo outranks haste outranks paralysis cure.
* `standTime()` = `now - vBot.standTime`, where `vBot.standTime` is reset on every
  `onPlayerPositionChange` (`vlib.lua:7`, `:20-26`). The two redundant guards `< 5000` and `< 3000`
  mean **haste is only cast within 3 s of the last step** — i.e. while actually moving. Standing
  still, haste is never recast.
* `stopHaste`: when true and a target exists, haste is suppressed unless CaveBot is currently
  allowed to act.
* Paralysis cure appears **twice** (slow loop is not the one that runs it — it's here in the fast
  loop). Its extra gate is `not getSpellCoolDown(config.paralyseSpell)`, which is the **icon-based**
  check (`vlib.lua:363-379`), *not* the predictive `getRealSpellRemaining` used by HealBot proper.
* This whole loop **bypasses the group-2 gate** that the slow loop has, because haste/utamo are
  group 3 (`Support`).

### 4.4 The group-cooldown ids

`gamelib/spells.lua:284-296`: `1=Attack 2=Healing 3=Support 4=Special 5=Conjure 6=Crippling
7=Focus 8=UltimateStrikes 9=GreatBeams 10=BurstsOfNature 11=Virtue`.
`isGroupCooldownIconActive(2)` == "any Healing-group spell is on cooldown".

---

## 5. The 5 named profiles

### 5.1 Structure and selection

`HealBotConfig.healbot` is a **5-element array** (`HealBot.lua:271-279`), each element a full
profile record. The active index is `HealBotConfig.currentHealBotProfile` (1..5), defaulted at
`HealBot.lua:281-283`:

```lua
if not currentHealBotProfile or == 0 or > 5 then currentHealBotProfile = 1 end
```

`setActiveProfile()` (`:286-289`) simply binds `currentSettings = HealBotConfig.healbot[n]`. Every
tick reads `currentSettings`, so switching profiles is instantaneous and total: rules, enable flag,
and all six flags swap at once.

Structural repair at `HealBot.lua:271`: if `HealBotConfig.healbot` is missing, or `[1]` is missing,
**or `#HealBotConfig.healbot ~= 5`**, the entire array is reset to five blank profiles. A port must
reproduce this or refuse to load malformed configs.

Programmatic API exposed to other scripts (`HealBot.lua:597-624`):
`HealBot.isOn() / isOff() / setOn() / setOff() / getActiveProfile() / setActiveProfile(n) / show()`.
`setActiveProfile(n)` errors for `n < 1 or n > 5`. **Bug worth not copying**: `HealBot.setOn/setOff`
call `vBotConfigSave("atk")` (`:604`, `:609`) — they save the *AttackBot* file, so a scripted
enable/disable of HealBot is never persisted.

### 5.2 Persistence

`configs.lua`:
* `configName = modules.game_bot.contentsPanel.config:getCurrentOption().text` (`:5`) — the bot
  config directory name, here **`vBot_4.8`**.
* `profile = g_settings.getNumber('profile')` (`:20`) — the *client-wide* profile number 1..10, read
  from the client's own settings, **not** the HealBot profile index. Directories
  `profile_1 … profile_10` are pre-created at `:13-18`.
* File path (`:23`): `"/bot/" .. configName .. "/vBot_configs/profile_" .. profile .. "/HealBot.json"`
  → on disk `D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot_configs\profile_1\HealBot.json`.
* Load (`:31-39`): `json.decode(readFileContents(file))` inside `pcall`; on failure the *entire
  configs.lua chunk returns* with `onError(...)` — which also skips loading AttackBot/Supplies.
* Save `vBotConfigSave("heal")` (`:63-97`): `json.encode(HealBotConfig, 2)`, refuse if > 100 MB,
  then `writeFileContents`.

Save is triggered by: the HealBot on/off switch (`HealBot.lua:307`), the setup window closing
(`:323`), a profile-button click (`:568` via `profileChange`), the Conditions on/off switch
(`Conditions.lua:64`), and the Conditions window closing (`:80`).
**Not triggered by** editing/adding/removing/reordering rules or toggling the six flags — those are
only flushed the next time one of the above happens (window close is the usual one).

### 5.3 The two config trees in one file

```
HealBotConfig = {
  currentHealBotProfile = <1..5>,
  healbot        = { [1..5] = <profile record> },       -- HealBot.lua:272-278
  ConditionPanel = { <flat condition settings> },       -- Conditions.lua:28-55
}
```

---

## 6. Timing summary (everything time-critical, one table)

| constant | value | source |
|---|---|---|
| macro minimum period | 50 ms | `executor.lua:38-40` |
| macro start jitter | `+ random(0,100)` ms | `executor.lua:46` |
| spell loop period | 20 → **50 ms** | `HealBot.lua:687` |
| item loop period | 100 ms | `HealBot.lua:748` |
| conditions slow loop | 500 ms | `Conditions.lua:238` |
| conditions fast loop | 50 ms | `Conditions.lua:253` |
| friend healer loop | 200 ms | `Sio.lua:217` / `new_healer.lua` |
| `USE_COOLDOWN_MS` (shared item slot) | **1000 ms** | `HealBot.lua:29` |
| `useHealItem` same-tick guard | 50 ms | `HealBot.lua:740` |
| looting throttle for items | 700 ms (or 200 ms when `MessageDelay`) | `HealBot.lua:767-772` |
| ping compensation | `ping > 150 → ping - 30`, else 0 | `HealBot.lua:48-56` |
| spell early-fire allowance | `remaining <= rawPing` | `HealBot.lua:668` |
| AttackBot slot reservation | `+150 ms` (rune fire), `+400 ms` (area), `readyAt+150` predictive from `readyAt-1000` | `AttackBot.lua:2833/2868/2903/2927/3086` |
| AttackBot rune-ready hold-off | `now + 250 ms`, refreshed every tick | `AttackBot.lua:2891` |
| utana recast interval | 120000 ms | `Conditions.lua:249` |
| haste "am I moving" window | `standTime() < 3000 ms` | `Conditions.lua:256` |
| burst-damage window | 3000 ms | `vlib.lua:52`, `:60-62` |
| cure gate | `hppercent() > 95` | `Conditions.lua:240` |
| utura gate | `hppercent() < 90` | `Conditions.lua:248` |

---

## 7. How `say()` reaches the wire (needed to reimplement casts correctly)

`context.say(text)` (`player.lua:90-101`) → `modules.game_interface.tryCastSpellMessage(text)`
(`gameinterface.lua:479-493`) → if `Spells.getSpellByWords(text:lower())` **is found**:
`castAimedSpell(text, SpellAimTarget=3, nil)` → `gameinterface.lua:522-524`
`g_game.talkSpell(words, 3, SpellAimInvalidPosition)`.

Wire result (opcode `0x96`, `sender.lua:344-382`):
* **known spell** → `mode = Say(1)`, `channel/receiver` omitted, `text`, `aimByte = 3`,
  **no position appended** (positions are only written for aim 1/2).
* **unknown words** (not in the spell DB, e.g. a custom-server heal) → `tryCastSpellMessage` returns
  false → `g_game.talk(text)` → same packet with `aimByte = 0`.

In luaclient: `sender:talkSpell(words, 3)` and `sender:talk(1, 0, '', words, 0)` respectively.

---

## 8. Friend healing — `Sio.lua` (OPTIONAL for a solo worker)

**Not loaded.** `_Loader.lua:18-58` lists `"new_healer"` but **not** `"Sio"`; `Sio.lua` is dead
legacy code in the profile directory. `new_healer.lua` is the friend healer actually in use (same
panel title "Friend Healer", `storage` key `newHealer`).

`Sio.lua` behaviour, briefly (`Sio.lua:217-277`), 200 ms macro, gated on
`isGroupCooldownIconActive(2)`, strict priority order:
1. custom spell `config.customSpellName "Name"` when a friend's HP% ≤ `minFriendHp` — `cast(..., 1000)`
2. `exura gran sio "Name"` when HP% ≤ `minFriendHp/3` — `cast(..., 60000)`
3. `exura gran mas res` when **>1** friend inside `largeRuneArea` is ≤ `minFriendHp` — `cast(..., 2000)`
4. `exura sio "Name"` — `cast(..., 1000)`
5. else `useWith(config.id, spec)` (default id 3160 = ultimate healing rune) when `findItem(id)` and
   `distanceFromPlayer(spec:getPosition()) <= config.distance`

Candidate filter: `spec:isPlayer() and spec ~= player and isValid(spec) and spec:canShoot()` and
`isFriend(spec)`. `isValid` (`Sio.lua:176-215`) filters by **vocation clientId** (1=EK 2=RP 3=MS
4=ED 5=EM, +10 when promoted, normalised back), sourced from `creature:getVocation()` (parsed off
the wire for cv ≥ 1281) with `vBot.BotServerMembers[name]` as fallback; **with no vocation ticked it
passes everyone through**. Persisted in the bot's generic `storage` table under key
`advancedFriendHealer` (NOT in `HealBot.json`).

For a **solo headless worker: skip this entirely.** It requires a friend list, a spectator scan and
a BotServer relay, none of which a solo bot needs.

---

## 9. Behaviour vs. widget detail — the clean split

**Behaviour (must port):** the four loop periods and their guard order; `origin`/`sign`/`value`
comparison semantics incl. the inclusive `>`/`<`; the strict-`<` mana gate on spell rules; array
order = priority; first-match-then-return; `healSpellCooldownReady` and the `SpellCooldownCache`
built from `0xA4`/`0xA5`; the 1000 ms shared use-cooldown and the two AttackBot hold-off globals;
`hasItemAvailable` semantics (`0xF5` counts ∪ open-container scan); the `useOnCreature` sentinel
position; every threshold in §6; the hardcoded cure table in §4.2; the elseif priority chain in §4.3;
5-profile array + `currentHealBotProfile`; the JSON file path and shape.

**Widget detail (do not port):** the entire `setupUI`/`healWindow`/`conditionsWindow` tree
(`HealBot.lua:194-625`, `Conditions.lua:3-235`); `trySetSpellIcon` (`:140-192`) which only paints a
sprite; profile-button colouring (`:292-301`); the label strings at `:394` and `:420`; the dropdown
option texts (only their *mapped tokens* matter); `entry.index`; `standBySpells`;
`checkInventoryConsumption`; the per-profile `Delay` and `Conditions` flags.


## Configuration format

## File location

```
<otclient>/profiles/bot/<configName>/vBot_configs/profile_<N>/HealBot.json
```

* `<configName>` = the selected bot config directory (`configs.lua:5`), here `vBot_4.8`.
* `<N>` = `g_settings.getNumber('profile')` (`configs.lua:20`) — the CLIENT-wide profile number
  (1..10, dirs pre-created at `configs.lua:13-18`). **Not** the HealBot profile index.
* Real path on disk right now:
  `D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot_configs\profile_1\HealBot.json`
* Written by `vBotConfigSave("heal")` → `json.encode(HealBotConfig, 2)` (`configs.lua:63-97`).
  Sibling files in the same directory: `AttackBot.json`, `Supplies.json`.
* The Sio / new_healer friend-healer settings are NOT here — they live in the bot's generic
  `storage` table (keys `advancedFriendHealer` / `newHealer`).

## Schema

```
HealBotConfig = {
  currentHealBotProfile : integer 1..5          -- active profile index (HealBot.lua:281-283)

  healbot : array[5] of {                       -- HealBot.lua:272-278; MUST be exactly 5 elements
    name        : string                        -- display only
    enabled     : boolean                       -- BEHAVIOUR: master switch for this profile
    Visible     : boolean                       -- BEHAVIOUR: item rules require hasItemAvailable()
    Cooldown    : boolean                       -- BEHAVIOUR: gate spells on predicted cooldown
    Interval    : boolean                       -- BEHAVIOUR: throttle item loop while looting
    MessageDelay: boolean                       -- BEHAVIOUR: true -> 200ms throttle, false -> 700ms
    Delay       : boolean                       -- DEAD (never read)
    Conditions  : boolean                       -- DEAD (never read)

    spellTable : array of {                     -- HealBot.lua:501; ARRAY ORDER == PRIORITY
      spell  : string                           -- literal words sent to the server
      origin : "HP" | "HP%" | "MP" | "MP%" | "burst"
      sign   : "<" | ">" | "="                  -- means <= , >= , ==
      value  : number                           -- threshold
      cost   : number                           -- fires only when cost < mana()  (STRICT <)
      enabled: boolean
      index  : number                           -- WIDGET ONLY, goes stale on reorder, never read
    }

    itemTable : array of {                      -- HealBot.lua:536; ARRAY ORDER == PRIORITY
      item   : number                           -- item id, must be > 100
      origin : "HP" | "HP%" | "MP" | "MP%" | "burst"
      sign   : "<" | ">" | "="
      value  : number
      enabled: boolean
      index  : number                           -- WIDGET ONLY
    }
  }

  ConditionPanel : {                            -- Conditions.lua:28-55
    enabled        : boolean                    -- separate master switch for BOTH condition loops

    curePoison     : boolean   poisonCost    : number   -- NOTE: the DEFAULT table writes the
    cureCurse      : boolean   curseCost     : number   --   MISSPELLED key "curePosion"; the logic
    cureBleed      : boolean   bleedCost     : number   --   reads "curePoison". Both can coexist
    cureBurn       : boolean   burnCost      : number   --   in the file (see the real dump below).
    cureElectrify  : boolean   electrifyCost : number
    cureParalyse   : boolean   paralyseCost  : number   paralyseSpell : string

    holdHaste      : boolean   hasteCost     : number   hasteSpell    : string
    holdUtamo      : boolean   utamoCost     : number
    holdUtana      : boolean   utanaCost     : number
    holdUtura      : boolean   uturaCost     : number   uturaType : "" | "Utura" | "Utura Gran"

    ignoreInPz     : boolean                    -- suppress the 4 hold-buffs while PlayerStates.Pz set
    stopHaste      : boolean                    -- suppress haste while a target exists, unless
                                                --   TargetBot.isCaveBotActionAllowed()
  }
}
```

Defaults for a fresh profile (`HealBot.lua:273-277`, mirrored by `resetSettings` `:571-582`):
`{enabled=false, spellTable={}, itemTable={}, name="Profile #N", Visible=true, Cooldown=true,
Interval=true, Conditions=true, Delay=true, MessageDelay=false}`.

Defaults for `ConditionPanel` (`Conditions.lua:28-55`):
`enabled=false, curePosion=false, poisonCost=20, cureCurse=false, curseCost=80, cureBleed=false,
bleedCost=45, cureBurn=false, burnCost=30, cureElectrify=false, electrifyCost=22,
cureParalyse=false, paralyseCost=40, paralyseSpell="utani hur", holdHaste=false, hasteCost=40,
hasteSpell="utani hur", holdUtamo=false, utamoCost=40, holdUtana=false, utanaCost=440,
holdUtura=false, uturaType="", uturaCost=100, ignoreInPz=true, stopHaste=false`.

## REAL example — verbatim content of profile_1/HealBot.json (reformatted, values unchanged)

```json
{
  "currentHealBotProfile": 1,
  "ConditionPanel": {
    "enabled": true,
    "curePosion": false,        "poisonCost": 20,
    "cureCurse": false,         "curseCost": 80,
    "cureBleed": false,         "bleedCost": 45,
    "cureBurn": false,          "burnCost": 30,
    "cureElectrify": false,     "electrifyCost": 22,
    "cureParalyse": true,       "paralyseCost": 200,
    "paralyseSpell": "utani gran hur",
    "holdHaste": true,          "hasteCost": 200,
    "hasteSpell": "utani gran hur",
    "holdUtamo": false,         "utamoCost": 40,
    "holdUtana": false,         "utanaCost": 440,
    "holdUtura": false,         "uturaCost": 100,   "uturaType": "",
    "ignoreInPz": true,
    "stopHaste": false
  },
  "healbot": [
    {
      "name": "Profile #1",
      "enabled": true,
      "Visible": false,
      "Cooldown": true,
      "Interval": false,
      "MessageDelay": false,
      "Delay": false,
      "Conditions": false,
      "spellTable": [
        {"spell": "exura gran tio", "origin": "HP%", "sign": "<", "value": 75, "cost": 210,
         "enabled": true, "index": 2},
        {"spell": "exura gran",     "origin": "HP%", "sign": "<", "value": 95, "cost": 75,
         "enabled": true, "index": 1}
      ],
      "itemTable": [
        {"item": 23374, "origin": "HP%", "sign": "<", "value": 40, "enabled": false, "index": 2},
        {"item": 23374, "origin": "HP%", "sign": "<", "value": 75, "enabled": true,  "index": 3},
        {"item": 23374, "origin": "MP%", "sign": "<", "value": 75, "enabled": true,  "index": 1}
      ]
    },
    {"name": "Profile #2", "enabled": false, "Visible": true, "Cooldown": true, "Interval": true,
     "MessageDelay": false, "Delay": true, "Conditions": true, "spellTable": [], "itemTable": []},
    {"name": "Profile #3", "enabled": false, "Visible": true, "Cooldown": true, "Interval": true,
     "MessageDelay": false, "Delay": true, "Conditions": true, "spellTable": [], "itemTable": []},
    {"name": "Profile #4", "enabled": false, "Visible": true, "Cooldown": true, "Interval": true,
     "MessageDelay": false, "Delay": true, "Conditions": true, "spellTable": [], "itemTable": []},
    {"name": "Profile #5", "enabled": false, "Visible": true, "Cooldown": true, "Interval": true,
     "MessageDelay": false, "Delay": true, "Conditions": true, "spellTable": [], "itemTable": []}
  ]
}
```

Reading this example the way the bot does:
* profile 1 is active and enabled; a Monk build (`exura gran tio` = Spirit Mend, id 273, group 2).
* spell priority is the ARRAY order, so **"exura gran tio" is tried first** even though its stale
  `index` is 2 — the user moved it up with MoveUp and `index` was not rewritten.
* item priority: `HP% <= 40` (disabled) → `HP% <= 75` → `MP% <= 75`; item 23374 = Ultimate Mana
  Potion. `Visible:false` means "use it even if I can't see it in an open container".
* `ConditionPanel.curePoison` is **absent** (only the misspelled `curePosion` was ever written), so
  `config.curePoison` is `nil` → falsy → poison cure is off. `cureParalyse` and `holdHaste` are on
  with `utani gran hur` (Strong Haste, id 39, group `{[3]=2000}`, real mana 100 — the configured
  cost floor of 200 is the user's own, higher gate).


## Pseudocode

-- ============================================================================
-- healbot.lua  -- port of vBot 4.8 HealBot + Conditions onto D:\Claude\otclient_web\luaclient
-- Depends only on: _G.LC = { log, sched, state, sender, events, config }
-- ============================================================================
local bit  = require('bit')
local json = require('lib.json')

local M = {}
local st, snd, ev, sch = LC.state, LC.sender, LC.events, LC.sched
local now = function() return LC.sys.nowMs() end          -- monotonic ms, sys.nowMs()

-- ---------------------------------------------------------------------------
-- 0. PlayerStates bits  (src/client/const.h:278-297) -- use statesLo with bit.band
-- ---------------------------------------------------------------------------
local S = { Poison=1, Burn=2, Energy=4, Drunk=8, ManaShield=16, Paralyze=32, Haste=64,
            Swords=128, Drowning=256, Freezing=512, Dazzled=1024, Cursed=2048,
            PartyBuff=4096, PzBlock=8192, Pz=16384, Bleeding=32768, Hungry=65536 }
local function hasCond(b) return bit.band(st.player.statesLo or 0, b) ~= 0 end

-- ---------------------------------------------------------------------------
-- 1. Player accessors (game_bot/functions/player.lua)
-- ---------------------------------------------------------------------------
local function hp()    return st.player.health or 0 end
local function mana()  return st.player.mana   or 0 end
local function hppercent()                       -- opcode 0x8C for OUR creature, not health/max
  local c = st.creatures[st.player.id]
  return (c and c.healthPercent) or 0
end
local function manapercent()                     -- player.lua:8-15
  local mx = st.player.maxMana or 0
  if mx <= 1 then return 100 end
  return math.floor(mana() * 100 / mx)
end

-- ---------------------------------------------------------------------------
-- 2. Burst damage tracker (vlib.lua:44-78)
-- ---------------------------------------------------------------------------
local dmg = {}
ev.on('textMessage', function(d)
  local t = (d.text or ''):lower()
  if not t:find('you lose') or not t:find('due to') then return end
  local n = tonumber(t:match('%d+')); if not n then return end
  local T = now()
  for i = #dmg, 1, -1 do if T - dmg[i].t > 3000 then table.remove(dmg, i) end end
  dmg[#dmg+1] = { d = n, t = T }
end)
local function burstDamageValue()
  if #dmg < 2 then return 0 end
  local sum, t0 = 0, dmg[1].t
  for _, v in ipairs(dmg) do sum = sum + v.d end
  local dt = (now() - t0) / 1000
  if dt <= 0 then return 0 end
  return math.ceil(sum / dt)
end

-- ---------------------------------------------------------------------------
-- 3. Spell database + cooldown prediction
--    Port modules/gamelib/spells.lua SpellInfo['Default'] to a words-keyed table:
--      SPELLDB["exura gran"] = { id=2, mana=70, level=20, exhaustion=1000, group={[2]=1000} }
--      SPELLDB["exura gran tio"] = { id=273, ..., group={[2]=1000} }
--      SPELLDB["utani gran hur"] = { id=39, mana=100, level=20, group={[3]=2000} }
--    Ship it as data/spells1530.lua; the words key is lowercase.
-- ---------------------------------------------------------------------------
local SPELLDB = require('data.spells1530')       -- words(lower) -> spell record

local cdSpell, cdGroup = {}, {}                  -- id -> {dur, start}
ev.on('spellCooldown',      function(d) cdSpell[d.spellId] = { dur = d.delay, start = now() } end)
ev.on('spellGroupCooldown', function(d) cdGroup[d.groupId] = { dur = d.delay, start = now() } end)

-- Optional upgrade over vBot: it claims 0xA6 never fires, but parser.lua:1877 decodes it.
local sharedUseExpiresAt = 0
local USE_COOLDOWN_MS    = 1000                  -- HealBot.lua:29 (fixed, authoritative)
ev.on('multiUseCooldown', function(d)
  sharedUseExpiresAt = math.max(sharedUseExpiresAt, now() + d.delay)
end)
local function recordLocalUseCooldown(ms)        -- HealBot.lua:30-32
  sharedUseExpiresAt = math.max(sharedUseExpiresAt, now() + (ms or USE_COOLDOWN_MS))
end

-- RTT: luaclient has no getPing(); measure it from the ping/pingBack round trip.
local rttMs, lastPingSent = 0, 0
local function getRawPing()          return rttMs end
local function getPingCompensation() return rttMs > 150 and (rttMs - 30) or 0 end   -- :48-56

local function getMultiUseCooldown() -- HealBot.lua:58-62
  return math.max(0, sharedUseExpiresAt - now() - getPingCompensation())
end

local function getRealSpellRemaining(words)      -- HealBot.lua:95-120
  local data = SPELLDB[words:lower()]
  if not data then return nil end
  local T, rem = now(), nil
  local d = cdSpell[data.id]
  if d then rem = d.dur - (T - d.start) end
  for gid in pairs(data.group or {}) do
    local g = cdGroup[gid]
    if g then
      local gr = g.dur - (T - g.start)
      if not rem or gr > rem then rem = gr end    -- MAX over own + every group
    end
  end
  return rem
end

local function groupCooldownActive(gid)          -- isGroupCooldownIconActive(gid)
  local g = cdGroup[gid]; if not g then return false end
  return (g.dur - (now() - g.start)) > 0
end
local function spellCooldownActive(words)        -- vlib.lua:363-379 getSpellCoolDown (icon-style)
  local r = getRealSpellRemaining(words)
  return r ~= nil and r > 0
end

-- ---------------------------------------------------------------------------
-- 4. Item availability (vlib.lua:863-887)
-- ---------------------------------------------------------------------------
local function itemAmountFromServer(id, tier)    -- opcode 0xF5, parser.lua:1429-1447
  local c = st.inventoryCounts; if not c then return nil end
  return c[id * 256 + (tier or 0)] or 0
end
local function itemAmountVisible(id)             -- equipped slots + OPEN containers only
  local n = 0
  for _, it in pairs(st.player.inventory or {}) do
    if it and it.id == id then n = n + (it.count or 1) end
  end
  for _, cont in pairs(st.containers or {}) do
    for _, it in ipairs(cont.items or {}) do
      if it.id == id then n = n + (it.count or 1) end
    end
  end
  return n
end
local function hasItemAvailable(id, tier)
  return math.max(itemAmountVisible(id), itemAmountFromServer(id, tier) or 0) > 0
end

-- ---------------------------------------------------------------------------
-- 5. Actions
-- ---------------------------------------------------------------------------
local function say(words)                        -- player.lua:90 -> gameinterface.lua:479-524
  if SPELLDB[words:lower()] then
    return snd:talkSpell(words, 3)               -- SpellAimTarget, no position appended
  end
  return snd:talk(1, 0, '', words, 0)            -- plain Say, aim byte 0
end

local lastHealItemUse = 0
local function useHealItem(itemId)               -- HealBot.lua:724-745
  local T = now()
  if T < M.AttackBotFiringUntil or T < M.AttackBotRuneReadyUntil then return end
  if T - lastHealItemUse < 50 then return end
  lastHealItemUse = T
  recordLocalUseCooldown()                       -- mark BEFORE sending, exactly like vBot
  -- game.cpp:900-902: inventory sentinel is Position(0xFFFF, 0, 0), stackpos 0
  snd:useOnCreature({ x = 0xFFFF, y = 0, z = 0 }, itemId, 0, st.player.id)
end

-- Shared with the AttackBot port; HealBot only ever READS these.
M.AttackBotFiringUntil   = 0
M.AttackBotRuneReadyUntil = 0

-- ---------------------------------------------------------------------------
-- 6. Config load / save  (configs.lua:5-97)
-- ---------------------------------------------------------------------------
local CFG                                        -- the whole HealBotConfig tree
local cfgPath

local function blankProfile(n)
  return { name = "Profile #"..n, enabled = false, spellTable = {}, itemTable = {},
           Visible = true, Cooldown = true, Interval = true, Conditions = true,
           Delay = true, MessageDelay = false }
end

function M.load(botConfigName, clientProfileNum)
  cfgPath = ("profiles/bot/%s/vBot_configs/profile_%d/HealBot.json")
            :format(botConfigName, clientProfileNum)
  local f = io.open(cfgPath, 'rb')
  CFG = f and json.decode(f:read('*a')) or {}
  if f then f:close() end

  -- HealBot.lua:271 structural repair
  if not CFG.healbot or not CFG.healbot[1] or #CFG.healbot ~= 5 then
    CFG.healbot = {}
    for i = 1, 5 do CFG.healbot[i] = blankProfile(i) end
  end
  -- HealBot.lua:281-283
  local p = CFG.currentHealBotProfile
  if not p or p == 0 or p > 5 then CFG.currentHealBotProfile = 1 end
  CFG.ConditionPanel = CFG.ConditionPanel or { enabled = false, ignoreInPz = true }
end

function M.save()                                -- vBotConfigSave("heal")
  local s = json.encode(CFG)
  if #s > 100 * 1024 * 1024 then return LC.log.error('healbot config too big') end
  local f = assert(io.open(cfgPath, 'wb')); f:write(s); f:close()
end

local function profile() return CFG.healbot[CFG.currentHealBotProfile] end

function M.setActiveProfile(n)                   -- HealBot.lua:612-619
  assert(type(n) == 'number' and n >= 1 and n <= 5, '[HealBot] wrong profile parameter!')
  CFG.currentHealBotProfile = n
  M.save()
end
function M.getActiveProfile() return CFG.currentHealBotProfile end
function M.isOn()  return profile().enabled end
function M.setOn(v) profile().enabled = (v ~= false); M.save() end   -- vBot saves "atk" here: BUG

-- ---------------------------------------------------------------------------
-- 7. Rule evaluation  (HealBot.lua:693-713 / :781-800)
-- ---------------------------------------------------------------------------
local function sourceValue(origin)
  if origin == "HP%"   then return hppercent()
  elseif origin == "HP"    then return hp()
  elseif origin == "MP%"   then return manapercent()
  elseif origin == "MP"    then return mana()
  elseif origin == "burst" then return burstDamageValue() end
  return nil                                     -- unknown origin -> rule can never fire
end

local function matches(entry)
  local v = sourceValue(entry.origin); if v == nil then return false end
  if     entry.sign == "=" then return v == entry.value
  elseif entry.sign == ">" then return v >= entry.value      -- NOTE: inclusive
  elseif entry.sign == "<" then return v <= entry.value end  -- NOTE: inclusive
  return false
end

-- ---------------------------------------------------------------------------
-- 8. Spell loop -- macro(20) clamped to 50 ms      (HealBot.lua:687-717)
-- ---------------------------------------------------------------------------
local function healSpellCooldownReady(words)     -- HealBot.lua:645-669
  if not profile().Cooldown then return true end
  local rem = getRealSpellRemaining(words)
  if rem == nil then return true end             -- no data yet -> vBot falls back to canCast();
                                                 -- with no icon module, "allow one probe cast"
  return rem <= getRawPing()
end

sch.every(50, function()
  if not M.enabledGlobally then return end
  local P = profile(); if not P.enabled then return end
  for i = 1, #P.spellTable do                    -- ARRAY ORDER == PRIORITY
    local e = P.spellTable[i]
    if e.enabled and e.cost < mana() then        -- STRICT <
      if healSpellCooldownReady(e.spell) then
        if matches(e) then
          say(e.spell)
          -- IMPROVEMENT over vBot (see Pitfalls): optimistic local mark so the next ~RTT of
          -- ticks do not re-send the same words 1-4 times.
          local d = SPELLDB[e.spell:lower()]
          if d then cdSpell[d.id] = { dur = d.exhaustion or 1000, start = now() } end
          return                                 -- ONE cast per tick
        end
      end
    end
  end
end)

-- ---------------------------------------------------------------------------
-- 9. Item loop -- 100 ms                          (HealBot.lua:748-805)
-- ---------------------------------------------------------------------------
local itemLoopBlockedUntil = 0                   -- models executor.lua delay()
sch.every(100, function()
  if not M.enabledGlobally then return end
  local T = now()
  if T < itemLoopBlockedUntil then return end
  local P = profile()
  if not P.enabled or #P.itemTable == 0 then return end
  if getMultiUseCooldown() > 0 then return end             -- shared 1 s slot
  if T < M.AttackBotFiringUntil then return end            -- AttackBot priority
  if T < M.AttackBotRuneReadyUntil then return end         -- rune ready, waiting for the slot

  if M.targetBotLooting and P.Interval then                -- HealBot.lua:767-772
    itemLoopBlockedUntil = T + (P.MessageDelay and 200 or 700)
    -- NOTE: vBot's delay() only postpones the NEXT call; this pass still runs. Same here.
  end

  for i = 1, #P.itemTable do
    local e = P.itemTable[i]
    if e.enabled and (not P.Visible or hasItemAvailable(e.item)) then
      if matches(e) then useHealItem(e.item); return end    -- ONE item per tick
    end
  end
  -- vBot sets standByItems = true here. DO NOT PORT: it starves 'burst' rules (see Pitfalls).
end)

-- ---------------------------------------------------------------------------
-- 10. Conditions -- slow loop, 500 ms             (Conditions.lua:238-251)
-- ---------------------------------------------------------------------------
local CURES = {                                  -- fixed table, evaluated in THIS order
  { on='curePoison',    cost='poisonCost',    test=function() return hasCond(S.Poison)   end, words='exana pox'  },
  { on='cureCurse',     cost='curseCost',     test=function() return hasCond(S.Cursed)   end, words='exana mort' },
  { on='cureBleed',     cost='bleedCost',     test=function() return hasCond(S.Bleeding) end, words='exana kor'  },
  { on='cureBurn',      cost='burnCost',      test=function() return hasCond(S.Burn)     end, words='exana flam' },
  { on='cureElectrify', cost='electrifyCost', test=function() return hasCond(S.Energy)   end, words='exana vis'  },
}

local utanaCast = nil
sch.every(500, function()
  if not M.enabledGlobally then return end
  local C = CFG.ConditionPanel
  if not C.enabled then return end
  if groupCooldownActive(2) then return end                  -- group 2 == Healing

  if hppercent() > 95 then                                   -- cures only near full HP
    for _, c in ipairs(CURES) do
      if C[c.on] and mana() >= (C[c.cost] or 0) and c.test() then say(c.words); break end
    end
  end

  -- SEPARATE chain: can fire in the SAME tick as a cure above
  local pzOk = (not C.ignoreInPz) or (not hasCond(S.Pz))
  if pzOk and C.holdUtura and mana() >= C.uturaCost
     and not spellCooldownActive(C.uturaType) and hppercent() < 90 then
    say(C.uturaType)                                         -- "Utura" / "Utura Gran" (as typed)
  elseif pzOk and C.holdUtana and mana() >= C.utanaCost
     and (not utanaCast or now() - utanaCast > 120000) then
    say('utana vid'); utanaCast = now()
  end
end)

-- ---------------------------------------------------------------------------
-- 11. Conditions -- fast loop, 50 ms              (Conditions.lua:253-259)
--     STRICT elseif chain: utamo > haste > paralysis cure, one per tick.
-- ---------------------------------------------------------------------------
local lastPosChange = now()
ev.on('positionChange', function(d)
  if d.creature == nil or d.creature.id == st.player.id then lastPosChange = now() end
end)
local function standTime() return now() - lastPosChange end  -- vlib.lua:7,:20-26

sch.every(50, function()
  if not M.enabledGlobally then return end
  local C = CFG.ConditionPanel
  if not C.enabled then return end
  local pzOk = (not C.ignoreInPz) or (not hasCond(S.Pz))

  if pzOk and C.holdUtamo and mana() >= C.utamoCost and not hasCond(S.ManaShield) then
    say('utamo vita')
  elseif pzOk and standTime() < 3000                          -- the <5000 guard is redundant
     and C.holdHaste and mana() >= C.hasteCost
     and not hasCond(S.Haste) and not spellCooldownActive(C.hasteSpell)
     and (not M.hasTarget or not C.stopHaste or M.caveBotActionAllowed) then
    say(C.hasteSpell)
  elseif C.cureParalyse and mana() >= C.paralyseCost and hasCond(S.Paralyze)
     and not spellCooldownActive(C.paralyseSpell) then
    say(C.paralyseSpell)                                      -- NOTE: no PZ gate on this branch
  end
end)

return M


## Evidence
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:20-33 — SharedUseCooldown / USE_COOLDOWN_MS = 1000 / recordLocalUseCooldown(ms) sets expiresAt = max(expiresAt, now + (ms or 1000)); block is duplicated verbatim in AttackBot.lua:22-46 and load-order guarded
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:35-46 — checkInventoryConsumption defined but NEVER called anywhere (grep over HealBot.lua + AttackBot.lua): dead code
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:48-56 — getPingCompensation() = ping > 150 and ping - 30 or 0
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:58-62 — getMultiUseCooldown() = max(0, SharedUseCooldown.expiresAt - now - getPingCompensation())
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:82-92 — SpellCooldownCache fed by onSpellCooldown(iconId,duration) -> cache[id] and onGroupSpellCooldown -> cache['group_'..id]
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:95-120 — getRealSpellRemaining: own remaining, then MAX over every group remaining; returns nil when the spell is unknown
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:131-132 — AttackBotFiringUntil / AttackBotRuneReadyUntil globals declared (read-only for HealBot)
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:271-283 — HealBotConfig.healbot 5-profile array defaults + '#healbot ~= 5 -> reset' repair; currentHealBotProfile clamped to 1 when nil/0/>5
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:490-501 — spell rule construction: dropdown text -> origin token (MP/HP/MP%/HP%/burst), Above/Below/Equal To -> >/</=, entry = {index, spell, sign, origin, cost, value, enabled}
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:525-536 — item rule construction, identical mapping, item id must be > 100, no mana cost field
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:426-472 — MoveUp/MoveDown swap t[index] with t[index±1] and never rewrite entry.index: array order is the real priority, entry.index is stale widget data
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:645-669 — healSpellCooldownReady: 'not Cooldown -> true'; 'remaining == nil -> canCast(spell,true,false)'; else 'remaining <= getRawPing()'
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:676-686 — explicit comment: the spell loop deliberately does NOT sleep on standBySpells because time-based cooldown readiness needs a real poll
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:687-717 — spell macro(20): enabled -> per-entry (enabled and cost < mana()) -> healSpellCooldownReady -> compare(origin,sign,value) -> say + return; '>' means >= and '<' means <=
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:724-745 — useHealItem: AttackBot hold-off recheck, 50 ms same-tick guard, recordLocalUseCooldown() then g_game.useInventoryItemWith(itemId, player)
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:748-805 — item macro(100) guard order: standByItems / enabled / getMultiUseCooldown()>0 / AttackBotFiringUntil / AttackBotRuneReadyUntil / looting delay(700|200) / first matching entry -> useHealItem + return / else standByItems = true
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:767-772 — TargetBot.isOn() and TargetBot.Looting.getStatus():len() > 0 and Interval -> delay(700) or delay(200) when MessageDelay
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:780 — '(not currentSettings.Visible or item) and entry.enabled' with item = hasItemAvailable(entry.item)
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:809-817 — onPlayerHealthChange and onManaChange both clear standByItems/standBySpells (the only wake-ups)
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/HealBot.lua:601-610 — HealBot.setOff/setOn call vBotConfigSave("atk"), saving the AttackBot file instead of HealBot.json (bug)
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/Conditions.lua:28-55 — ConditionPanel defaults incl. the misspelled key curePosion (logic reads config.curePoison)
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/Conditions.lua:238-251 — slow macro(500): group-2 cooldown gate, hppercent()>95 cure chain (exana pox/mort/kor/flam/vis), then a SEPARATE utura/utana chain with hppercent()<90 and a 120000 ms utana interval
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/Conditions.lua:253-259 — fast macro(50) elseif chain: utamo vita > haste (standTime()<3000, not hasHaste, not getSpellCoolDown, stopHaste/target/isCaveBotActionAllowed) > paralysis cure
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/configs.lua:5,20,23 — configName from the bot config dropdown, profile = g_settings.getNumber('profile'), healBotFile = /bot/<configName>/vBot_configs/profile_<N>/HealBot.json
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/configs.lua:63-97 — vBotConfigSave('heal'|'atk'|'supply'): json.encode(table, 2), 100 MB refusal, writeFileContents
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot_configs/profile_1/HealBot.json — the live config: currentHealBotProfile=1, profile 1 enabled with spellTable [exura gran tio HP%<75 cost 210, exura gran HP%<95 cost 75] and itemTable [23374 HP%<40 disabled, 23374 HP%<75, 23374 MP%<75], Visible=false, Cooldown=true, Interval=false; ConditionPanel enabled with cureParalyse/holdHaste on 'utani gran hur' at cost 200
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/executor.lua:38-40 — 'if timeout < 50 then timeout = 50 end': macro(20) and macro(5) are both really 50 ms loops
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/executor.lua:46 — lastExecution = context.now + math.random(0,100) start jitter
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/executor.lua:113-125,194-212 — tick: run when lastExecution+timeout <= now and enabled and (not macro.delay or macro.delay < now); macro.callback returns true so lastExecution advances
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/executor.lua:206-211 — delay(duration) sets _currentExecution.delay = now + duration; the current pass still finishes
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/functions/player_conditions.lua:7-33 — hasCondition = Bit.band(player:getStates(), bit) > 0 plus isPoisioned/isBurning/isEnergized/isParalyzed/hasHaste/hasManaShield/isInPz/isBleeding/isCursed
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:278-297 — enum PlayerStates: Poison=1 Burn=2 Energy=4 Drunk=8 ManaShield=16 Paralyze=32 Haste=64 Swords=128 Drowning=256 Freezing=512 Dazzled=1024 Cursed=2048 PartyBuff=4096 PzBlock=8192 Pz=16384 Bleeding=32768 Hungry=65536 (no NewManaShield member)
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:883-907 — useInventoryItemWith: for cv>=780 with a creature target it sends sendUseOnCreature(Position(0xFFFF,0,0), itemId, 0, creatureId)
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/functions/player.lua:5-15 — hp/mana/hppercent(=creature health percent byte)/manapercent(=floor(mana*100/max), 100 when max<=1)
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/functions/player.lua:90-101 — say() routes through modules.game_interface.tryCastSpellMessage first, falling back to g_game.talk
- D:/Claude/otclient_mehah1530/otclient/modules/game_interface/gameinterface.lua:479-524 — known spell -> castAimedSpell(words, SpellAimTarget=3) -> g_game.talkSpell(words, 3, invalidPos); unknown words -> plain talk with aim byte 0
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/vlib.lua:44-78 — burst damage: 'you lose ... due to' text messages, first %d+ per message, 3000 ms window, ceil(sum/((now-t0)/1000)), 0 when fewer than 2 samples
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/vlib.lua:7,20-26 — vBot.standTime reset on onPlayerPositionChange; standTime() = now - vBot.standTime
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/vlib.lua:333-379 — getSpellData(words) looks up modules.gamelib.SpellInfo['Default'] by exact lowercase words, else vBot.customCooldowns; getSpellCoolDown uses the icon modules (isCooldownIconActive(data.id) / isGroupCooldownIconActive(groupId))
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/vlib.lua:797-887 — hasItemAvailable(id,tier) = itemAmount > 0 = max(player:getItemsCount(id) visible scan, player:getInventoryCount(id,tier) 0xF5 server count)
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/spells.lua:284-296 — SpellGroups 1=Attack 2=Healing 3=Support 4=Special 5=Conjure 6=Crippling 7=Focus 8=UltimateStrikes 9=GreatBeams 10=BurstsOfNature 11=Virtue
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/spells.lua:38,65,74,78,79,158-161,219 — real spell records used by this profile: exura gran id2 group{2:1000} exh1000 mana70; exana pox id29 exh6000; utani gran hur id39 group{3:2000} mana100; utamo vita id44 exh14000; utana vid id45 mana440; exana kor/flam/vis/mort ids 144/145/146/147 exh6000; exura gran tio id273 group{2:1000} mana210
- D:/Claude/otclient_web/luaclient/proto/parser.lua:1849-1879 — 0xA2 PlayerState (statesLo/statesHigh -> statesChange), 0xA4 SpellDelay -> spellCooldown{spellId,delay}, 0xA5 SpellGroupDelay -> spellGroupCooldown{groupId,delay}, 0xA6 MultiUseDelay -> multiUseCooldown{delay}
- D:/Claude/otclient_web/luaclient/proto/parser.lua:1429-1447 — 0xF5 PlayerInventory populates state.inventoryCounts keyed itemId*256+tier
- D:/Claude/otclient_web/luaclient/proto/parser.lua:1617-1623 — 0x8C CreatureHealth sets creature.healthPercent and emits creatureHealth (this is what hppercent() reads for the local player)
- D:/Claude/otclient_web/luaclient/proto/sender.lua:344-419 — talk(mode,channel,receiver,text,aimMode,aimPos), talkSpell(text,aimMode,pos,mode) defaulting to Say, useOnCreature(pos,itemId,stackpos,creatureId) = opcode 0x84
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/_Loader.lua:18-58 — load order includes 'Conditions', 'HealBot', 'new_healer', 'AttackBot'; 'Sio' is NOT listed, so Sio.lua is dead legacy code
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/Sio.lua:217-277 — friend-healer macro(200): group-2 gate, then custom spell -> exura gran sio (at minFriendHp/3) -> exura gran mas res (>1 friend in largeRuneArea) -> exura sio -> useWith(item id, spec) within config.distance; settings live in the generic storage table under key 'advancedFriendHealer', NOT in HealBot.json
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/targetbot/target.lua:186-188 and targetbot/looting.lua:103-105 — TargetBot.isCaveBotActionAllowed() = cavebotAllowance > now; TargetBot.Looting.getStatus() returns the looting status string used by HealBot's throttle
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/AttackBot.lua:2697,2833,2868,2891,2903,2927,3086 — the only writers of AttackBotFiringUntil (delayEnd+10, max(cur, readyAt+150) armed once now >= readyAt - USE_COOLDOWN_MS, now+150, now+400) and AttackBotRuneReadyUntil (now+250, refreshed every tick while a rune is ready but blocked on the shared slot)
- D:/Claude/otclient_mehah1530/otclient/mods/game_bot/bot.lua:339-350 — online() rebuilds the bot, offline() does save(); clear(): no macros exist while logged out

## Pitfalls
- 'Above'/'Below' in the UI are NOT strict. HealBot.lua:693-713 implements '>' as >= and '<' as <=. A rule 'HP% Below 75' fires at exactly 75.
- The mana gate on spell rules is STRICT: 'entry.cost < mana()' (HealBot.lua:691). A rule with cost 210 will NOT fire at exactly 210 mana. Items have no mana gate whatsoever.
- macro(20) is a lie: executor.lua:38-40 clamps every macro period to a 50 ms floor. Reproducing the '20 ms' literally makes the spell loop 2.5x more aggressive than the real bot (and AttackBot's macro(5) is also really 50 ms).
- entry.index is stale the moment a user reorders. MoveUp/MoveDown (HealBot.lua:426-472) swaps array slots without touching .index. NEVER sort by index -- iterate the array. The live profile_1 config already has an inverted index (exura gran tio is first in the array but carries index 2).
- The spell loop deliberately re-sends the same words every 50 ms until the server's 0xA4/0xA5 arrives (HealBot.lua:638-643 comment). At 120 ms ping that is ~2-3 duplicate casts per heal. If your port must be quiet on the wire, write an optimistic {dur=exhaustion, start=now} into the cooldown cache at send time -- vBot chose not to.
- getRealSpellRemaining returns nil for any spell whose words are not in the static SpellInfo table AND that has never fired 0xA4 this session. In that case healSpellCooldownReady falls back to canCast(), which for an unknown spell returns true unconditionally (vlib.lua:297) -- so custom-server heal words are effectively cooldown-unchecked. Port that fallback deliberately, or your port will simply never cast them.
- SpellCooldownCache is keyed by the spell's protocol id (SpellInfo[...].id, e.g. 2 / 273 / 39), NOT clientId (the icon sprite index, e.g. 6 / 161 / 101). Confusing the two silently disables all cooldown prediction.
- PlayerStates is a uint64 in const.h but every bit HealBot uses fits in the low u32. luaclient stores states as a Lua double (lo + hi*2^32, parser.lua:1858) -- bit.band on that value is WRONG. Use player.statesLo.
- PlayerStates.NewManaShield does not exist in this build's const.h enum, so hasNewManaShield() (player_conditions.lua:14) evaluates against nil. The utamo branch is effectively gated on ManaShield (16) alone.
- The ConditionPanel default table writes the MISSPELLED key 'curePosion' (Conditions.lua:30) while every reader uses 'curePoison' (Conditions.lua:154, :241). The live profile_1 JSON contains only 'curePosion':false, so poison curing is off until the checkbox is clicked once. Support BOTH keys when reading, or you will silently change behaviour.
- Conditions.lua:240-250 has TWO chains, not one: the hppercent()>95 cure block and the utura/utana block are separate statements, so a cure and a utura can be said in the SAME 500 ms tick -- two spells, one tick.
- Conditions.lua:256 has the redundant pair 'standTime() < 5000 ... and standTime() < 3000'. Only the 3000 ms bound matters: haste is recast only within 3 seconds of the last step, never while standing.
- The paralysis cure lives in the FAST loop (Conditions.lua:257), behind the utamo and haste branches of an elseif chain -- while utamo or haste are eligible, paralysis is never cured. It also has NO PZ gate (unlike the four hold-buffs).
- The paralysis/haste/utura branches use getSpellCoolDown / canCast (icon-based, vlib.lua:363-379), NOT HealBot's predictive getRealSpellRemaining. Do not unify them without deciding you want the behaviour change.
- standByItems (HealBot.lua:749, :804) is only cleared by health/mana change events. A 'burst'-origin item rule can therefore sleep forever while burst damage decays with static HP/MP. Recommendation: drop the flag and poll.
- There is NO dead-player check anywhere in HealBot.lua. On death healthPercent goes to 0 and every 'HP% <' rule matches, so the bot spams heals and potions at a corpse. Add 'st.player.health > 0'.
- HealBot.setOn/setOff call vBotConfigSave("atk") (HealBot.lua:604, :609): scripted enable/disable writes AttackBot.json and is never persisted for HealBot.
- Adding, removing, reordering rules and toggling the six per-profile flags do NOT save. Only the on/off switch, the setup window closing and a profile-button click call vBotConfigSave("heal"). A headless port should just save on mutation.
- The item action is useOnCreature with fromPos = {x=0xFFFF, y=0, z=0} -- y is 0, NOT the item id (game.cpp:900). Getting this wrong makes every potion silently fail while the client thinks it succeeded.
- 'Visible' inverts the way you would guess: Visible=true means 'only use what I can see' (adds a hasItemAvailable gate). The live config has Visible=false, i.e. fire blind. 'MessageDelay'=true means the SHORTER 200 ms looting throttle, not a longer one.
- 'Delay' and 'Conditions' are per-profile JSON fields that no tick ever reads. Do not wire them to anything; a reimplementer who assumes 'Conditions' gates Conditions.lua will break the module (it has its own HealBotConfig.ConditionPanel.enabled).
- uturaType is stored as the dropdown TEXT with capitals ('Utura' / 'Utura Gran') and is passed straight into say() (Conditions.lua:248). canCast lowercases before lookup but the words on the wire keep the capitals. Lowercase before sending in the port.
- g_settings.getNumber('profile') in the file path is the CLIENT profile (1..10), a completely different concept from HealBotConfig.currentHealBotProfile (1..5). Confusing them points you at the wrong JSON file.
- The shared 1 s use-cooldown is entirely client-side and optimistic (HealBot.lua:11-19 explicitly refuses to use any server signal). It is duplicated verbatim in AttackBot.lua, so in a port it MUST be one module owned by neither -- two copies with independent expiresAt values will let a rune and a potion collide.
- burstDamageValue stores string.match results (strings) and relies on Lua coercion in 'd = d + v.d'. In LuaJIT this works; in a stricter port, tonumber() it explicitly -- and note only the FIRST number in the damage line is captured.
- vBot claims onMultiUseCooldown never fires on this build, but luaclient's parser DOES decode 0xA6 MultiUseDelay (parser.lua:1877-1879). Feeding it into sharedUseExpiresAt is a strict improvement, but it changes timing relative to the reference bot -- decide consciously.
- Sio.lua is not loaded by _Loader.lua (new_healer.lua is). Do not port Sio as if it were live behaviour; for a solo worker skip friend healing entirely.

## Open questions
- luaclient has no getPing(). getRawPing() gates every predictive spell cast ('remaining <= rawPing', HealBot.lua:668) and getPingCompensation() gates the item slot. You must measure RTT yourself from the Ping(0x1D)/PingBack(0x1E) pair -- decide whether to use an EWMA or the last sample, and what value to use before the first round trip (0 is the safe, conservative choice: it makes the bot fire exactly on cooldown rather than early).
- canCast() (vlib.lua:279-298) is the fallback inside healSpellCooldownReady when no cooldown data exists yet. It consults modules.game_cooldown icon state plus a level/mana check against the static spell DB. The port has no icon module; the pseudocode above returns true (allow one probe cast). Confirm this is acceptable, or reimplement the level/mana precondition from the ported SpellInfo table.
- modules/gamelib/spells.lua SpellInfo['Default'] must be ported to data (words -> {id, mana, level, exhaustion, group}). Confirm which profile key the target server uses -- vlib.lua:278 hardcodes ['Default'], but SpelllistSettings supports multiple profiles and getSpelllistProfile() exists.
- vBot.customCooldowns (vlib.lua:307-325) learns spell ids for words that are NOT in the static DB, by correlating the last self-uttered phrase with the next 0xA4/0xA5. Worth porting for custom-server heals, but the correlation is racy (schedule(1)/schedule(2) hacks). Decide whether to implement it or to require every heal spell to be present in the ported DB.
- Does the target server actually send 0xA6 MultiUseDelay? vBot asserts it does not fire on this OTClient build (HealBot.lua:11-19) but the luaclient parser decodes it. A capture would settle whether the 1000 ms constant can be replaced by the real server value.
- hppercent() reads the health-percent byte from 0x8C for the player's own creature. Confirm this server actually sends 0x8C for the local player on every HP change (some servers only send 0xA0). If not, fall back to floor(health*100/maxHealth) -- which is what most people assume vBot does anyway.
- itemAmountVisible() in the port scans st.player.inventory and st.containers. otclient's player:getItemsCount also recurses into nested open containers and counts stack counts and tiers. Confirm luaclient's container model exposes counts and nested containers the same way, or accept that the 'Visible' gate is slightly more permissive/restrictive than the reference.
- The AttackBot handshake globals (AttackBotFiringUntil / AttackBotRuneReadyUntil / SharedUseCooldown) must become a real shared module in the port. Decide the ownership boundary now -- HealBot only reads them, but the AttackBot port must write all five reservation values from AttackBot.lua:2697/2833/2868/2891/2903/2927/3086.
- TargetBot integration: the item-loop throttle needs 'is looting in progress' and the haste branch needs 'is CaveBot allowed to act'. Both are TargetBot state. If TargetBot is not being ported, decide the defaults (looting = false, caveBotActionAllowed = true) -- note that caveBotActionAllowed=false plus stopHaste=true plus any target would permanently suppress haste.
- The vBot spell loop's intentional re-send spam is a detectability risk on a headless worker with no human-looking input. Decide whether to keep bug-for-bug fidelity or add the optimistic local cooldown mark suggested in the pseudocode.
- Persisting configuration: the reference saves only on a handful of UI events. For a headless client, decide whether the JSON is read-only input (recommended: reload on file change) or whether the worker writes it back, and if so how to avoid clobbering an otclient instance sharing the same file.

## VERIFIER (confidence 0.88)

### Corrections (AUTHORITATIVE)
- **Claim**: §4.1: "hasNewManaShield() maps to PlayerStates.NewManaShield, which does not exist in the 1530 const.h enum — PlayerStates.NewManaShield is nil ... Treat the utamo branch as gated on ManaShield (16) only." The pseudocode's S table omits it and §11 checks only S.ManaShield.
  - **Correction**: PlayerStates.NewManaShield DOES exist and equals 67108864 (bit 26). The Lua PlayerStates table is NOT the C++ enum — it is defined in modules/gamelib/player.lua:3-40 and is a superset of const.h. The utamo branch is gated on ManaShield(16) OR NewManaShield(67108864). A port checking only bit 16 will re-cast 'utamo vita' every 50 ms forever whenever the server sets the new mana-shield bit. Add NewManaShield=67108864 to S and test `not (hasCond(S.ManaShield) or hasCond(S.NewManaShield))`.
  - Evidence: modules/gamelib/player.lua:3-40 (`PlayerStates = { None=0, Poison=1, ... ManaShield=16, ... NewManaShield=67108864, Agony=134217728, Powerless=268435456, Mentored=536870912 }`); it is also used live at player.lua:163. The C++ enum names in src/client/const.h:278-297 are IconPoison/IconManaShield/... and grep shows the enum is never registered to Lua (no IconPoison/IconManaShield hit outside const.h). Conditions.lua:255 `not (hasManaShield() or hasNewManaShield())`.
- **Claim**: PSEUDOCODE §1: `local function hppercent() local c = st.creatures[st.player.id]; return (c and c.healthPercent) or 0 end`
  - **Correction**: The fallback must be 101, not 0. Creature::m_healthPercent is initialised to 101 (not 0, not 100), and only opcode 0x8C ever writes it — LocalPlayer::setHealth does not touch it. With `or 0` the port fails OPEN: before the first 0x8C (login, or any tick where the creature record is missing) every `HP% <` rule matches and both loops spam heals/potions, while the Conditions cure gate `hppercent() > 95` flips from true (vBot) to false (port).
  - Evidence: src/client/creature.h:337 `uint8_t m_healthPercent{ 101 };`, :114 getHealthPercent; src/client/localplayer.cpp:351-367 setHealth touches only m_health/m_maxHealth and fires onHealthChange; src/client/protocolgameparse.cpp:2460-2471 is the only setHealthPercent caller path for 0x8C. mods/game_bot/functions/player.lua:7 `context.hppercent = function() return context.player:getHealthPercent() end`.
- **Claim**: §1.3: "a onTextMessage hook collects ... entries older than 3000 ms are pruned; burstDamageValue() returns math.ceil(sum / ((now - firstEntryTime)/1000))" — and PSEUDOCODE §2 implements pruning only inside the textMessage handler.
  - **Correction**: The spec omits the scheduled full wipe. vlib.lua:61-63 fires `schedule(3050, function() if now - lastDmgMessage > 3000 then dmgTable = {} end end)` on EVERY damage message. That wipe is the only thing that ever returns burstDamageValue() to 0 once damage stops — the in-handler prune never runs when no messages arrive. Without it the port's burst value decays asymptotically but never reaches 0, so a `burst >` rule keeps firing indefinitely after combat ends, and a `burst <` rule never re-arms correctly.
  - Evidence: vlib.lua:47-64 — `local lastDmgMessage = now` ... `lastDmgMessage = now; table.insert(dmgTable, {d=dmg,t=now}); schedule(3050, function() if now - lastDmgMessage > 3000 then dmgTable = {} end end)`.
- **Claim**: PSEUDOCODE §2 prunes the burst table with a reverse loop: `for i = #dmg, 1, -1 do if T - dmg[i].t > 3000 then table.remove(dmg, i) end end`, presented as equivalent to vBot.
  - **Correction**: vBot removes while FORWARD-iterating with ipairs, which skips roughly every other stale entry, so stale samples survive and dmgTable[1].t is routinely older than 3000 ms. The real burst window is therefore longer than 3 s and vBot's returned DPS is systematically LOWER than the corrected reverse-loop version. If bit-for-bit parity matters, replicate the forward-remove; otherwise document the deliberate divergence.
  - Evidence: vlib.lua:54-58 `if #dmgTable > 0 then for k, v in ipairs(dmgTable) do if now - v.t > 3000 then table.remove(dmgTable, k) end end end`.
- **Claim**: §4.2/§4.3 present `isGroupCooldownIconActive(2)` and `getSpellCoolDown(...)` as reliable gates, and §2.1 presents `canCast(spellText, true, false)` as an "icon fallback"; PSEUDOCODE §3/§10/§11 substitute the predictive SpellCooldownCache (`groupCooldownActive`, `spellCooldownActive`) for all three.
  - **Correction**: All three icon-based paths are populated ONLY while the cooldown window is visible. modules/game_cooldown/cooldown.lua:539-541 and :562-565 both `return` immediately when `not cooldownWindow:isVisible()`, and groupCooldown[gid]/cooldown[iconId] are written only inside that guarded path. On a client with the cooldown bar hidden the group-2 gate at Conditions.lua:239 never blocks, `getSpellCoolDown(hasteSpell)`/`(paralyseSpell)` are always false, and canCast's fallback always reports ready. Substituting the predictive cache makes the port strictly MORE restrictive than vBot — it will suppress cures, haste and paralysis-cure where vBot fires. (The bot's own SpellCooldownCache is unaffected: bot.lua hooks g_game's signals directly.)
  - Evidence: modules/game_cooldown/cooldown.lua:539-541 `function onSpellCooldown(iconId,duration) ... if not cooldownWindow:isVisible() then return end`; :562-565 same for onSpellGroupCooldown; :588-592 `groupCooldown[groupId] = true` is inside the `if progressRect then` block after that guard; :521-528 isGroupCooldownIconActive reads groupCooldown. Independent bot path: mods/game_bot/bot.lua:572-573 and :637-638 connect g_game onSpellCooldown/onSpellGroupCooldown -> botSpellCooldown/botGroupSpellCooldown (:857-865).
- **Claim**: PSEUDOCODE §10: `if pzOk and C.holdUtura and mana() >= C.uturaCost and not spellCooldownActive(C.uturaType) and hppercent() < 90 then`
  - **Correction**: The real gate is `canCast(config.uturaType)`, not a cooldown-only check. canCast additionally consults SpellCastTable and, when getSpellData resolves the words, requires `level() >= data.level and mana() >= data.mana` (ignoreRL is nil here) — for 'utura' that is level 50 / 75 mana, for 'utura gran' level 100 / 165 mana. It also returns TRUE when getSpellData finds nothing, so the default `uturaType == ""` makes canCast("") true and vBot would `say("")` if holdUtura were enabled with no type picked.
  - Evidence: Conditions.lua:248 `... and canCast(config.uturaType) and hppercent() < 90 then say(config.uturaType)`; vlib.lua:279-300 canCast (line 291-292 level/mana check, line 299 `return true` when no data); modules/gamelib/spells.lua:173 Recovery ('utura', level 50, mana 75, exhaustion 60000, group {[2]=1000}) and :174 Intense Recovery ('utura gran', level 100, mana 165).
- **Claim**: §6 timing table: "friend healer loop | 200 ms | Sio.lua:217 / new_healer.lua".
  - **Correction**: new_healer.lua — the friend healer actually loaded — runs at macro(100, ...), i.e. 100 ms. Only the dead Sio.lua uses macro(200). The row conflates the two.
  - Evidence: new_healer.lua:1304 `macro(100, function()` (the only top-level macro in the file); Sio.lua:217 `macro(200, function()`; _Loader.lua:18-58 lists "new_healer" (index 34) and not "Sio".
- **Claim**: §0 and §6 cite `executor.lua:9-127` (macro registration), `executor.lua:38-40` (50 ms clamp), `executor.lua:46` (jitter) and `executor.lua:206-211` (delay).
  - **Correction**: All four live in mods/game_bot/functions/main.lua, not executor.lua: main.lua:9-127 context.macro, :38-40 the `if timeout < 50 then timeout = 50 end` clamp, :46 `lastExecution = context.now + math.random(0,100)`, :113-125 the macro.callback wrapper that holds the delay gate, :206-211 context.delay. grep over executor.lua returns zero hits for `macro`/`delay`/`timeout` other than the tick loop's use of macro.timeout.
  - Evidence: mods/game_bot/functions/main.lua:9 `context.macro = function(timeout, name, hotkey, callback, parent)`, :37-40, :42-48, :113-125, :206-211. `grep -n "context.macro|lastExecution|delay|timeout" mods/game_bot/executor.lua` -> only lines 200, 203, 234, 262.
- **Claim**: §0: "driven by the single tick function at executor.lua:194-212: a macro runs when macro.lastExecution + macro.timeout <= now and macro.enabled and (not macro.delay or macro.delay < now)."
  - **Correction**: The predicate is split across two files and, crucially, `macro.lastExecution` is advanced ONLY when the callback wrapper returns true — which it does only after the delay has expired. So a delayed macro is re-evaluated on every 10 ms bot tick and fires the instant its delay expires, not on the next timeout boundary. The spec's claim that the item loop "degrades from 100 ms to 700 ms" is therefore approximate: after delay(700) the next run is at exactly +700 ms, then 100 ms cadence resumes.
  - Evidence: executor.lua:199-210 `if macro.lastExecution + macro.timeout <= context.now and macro.enabled then pcall(function() if macro.callback(macro) then macro.lastExecution = context.now end end)`; main.lua:113-125 `macro.callback = function(macro) if not macro.delay or macro.delay < context.now then ... return true end end` (returns nil while delayed).
- **Claim**: §0/§6 present the loop periods as exact (50 / 100 / 500 / 50 ms) and the pseudocode calls a live `now()` per use.
  - **Correction**: The bot scheduler ticks every 10 ms and `now`/`context.now` is a single per-tick snapshot, not a live clock. A macro(50) therefore actually runs every 50-60 ms, macro(100) every 100-110 ms, and every `now` read inside one tick (including recordLocalUseCooldown's `now + 1000`, useHealItem's `now - lastHealItemUse < 50`, and standTime()) is identical across all four loops in that tick.
  - Evidence: mods/game_bot/bot.lua:525-535 `function check() removeEvent(checkEvent) ... checkEvent = scheduleEvent(check, 10) ... botExecutor.script()`; executor.lua:196-197 `context.now = g_clock.millis(); context.time = g_clock.millis()`.
- **Claim**: §2.2 pseudocode's ping helpers and PSEUDOCODE §3: `local rttMs, lastPingSent = 0, 0; local function getRawPing() return rttMs end`.
  - **Correction**: rttMs is never assigned anywhere in the pseudocode, so getRawPing() is permanently 0. That silently disables the two mechanisms the spec spends most of §2.1 explaining: healSpellCooldownReady degrades to `remaining <= 0` (zero early-fire — exactly the "only fires once the icon actually clears" behaviour HealBot.lua:627-643 was written to eliminate), and getPingCompensation() is permanently 0 so getMultiUseCooldown() never shortens. The port must actually drive sender:ping() and time the pingBack event.
  - Evidence: PSEUDOCODE §3 declares but never writes rttMs; HealBot.lua:122-126 getRawPing = g_game.getPing() or 0; :48-56 getPingCompensation; :668 `return remaining <= getRawPing()`; :60 `SharedUseCooldown.expiresAt - now - getPingCompensation()`. Target client: proto/sender.lua:275 `function sender:ping()`, proto/parser.lua:879-881 emits 'pingBack'.
- **Claim**: PSEUDOCODE §8 labels the post-cast `cdSpell[d.id] = { dur = d.exhaustion or 1000, start = now() }` an "IMPROVEMENT over vBot" and §2.1 calls it optional quieting.
  - **Correction**: It is a substantive behaviour change on a heal bot, not just noise reduction. HealBot.lua:638-643 states the retry is deliberate: if the server rejects the cast (fired early, mana race, silent drop) vBot re-fires on the next 50 ms tick, while the port will block for a full exhaustion period — 1000 ms for exura gran/exura gran tio, but 6000 ms for every exana cure and 60000 ms for 'utura'. It also writes only the per-spell key, never the group key, so it will not suppress a different group-2 spell later in the same list on subsequent ticks.
  - Evidence: HealBot.lua:638-643 comment; :645-669 healSpellCooldownReady has no post-cast lockout; :671-673 castHealSpell is a bare say(). Exhaustions from modules/gamelib/spells.lua:65,158,159,160,161 (6000 for the cures), :173 (60000 for 'utura'), :38 and :219 (1000).
- **Claim**: §1.6: "standBySpells (assigned in 6 places, never read)".
  - **Correction**: Assigned in 8 places (HealBot.lua:381, 387, 407, 413, 506, 537, 811, 816) plus the declaration at :1. The "never read" half is correct.
  - Evidence: `grep -n standBySpells HealBot.lua` -> 1, 381, 387, 407, 413, 506, 537, 676 (comment), 811, 816.
- **Claim**: §2.2: "This block is duplicated verbatim in AttackBot.lua:22-46 and HealBot.lua:20-46".
  - **Correction**: In AttackBot.lua the block is at lines 24-50 (SharedUseCooldown 24-26, recordLocalUseCooldown 28-37, checkInventoryConsumption 39-50). The HealBot.lua:20-46 citation is correct. Also, concretely on this install HealBot's chunk wins the race, not AttackBot's, because _Loader.lua loads HealBot (index 15) before AttackBot (index 17).
  - Evidence: AttackBot.lua:24-50; HealBot.lua:20-46; _Loader.lua:18-58 order: ... "Conditions"(29), "HealBot"(33), "new_healer"(34), "AttackBot"(35).
- **Claim**: §1.1 field table: "index — written at insert time and never read by the tick logic; it goes stale the moment MoveUp/MoveDown swaps array slots ... without touching .index" (stated as a blanket "never rewritten").
  - **Correction**: Removing a rule DOES rewrite every entry's .index: the remove handlers call reindexTable(), which walks the table and sets e.index = i. Only MoveUp/MoveDown leave it stale. The "never read by the tick logic" claim is correct.
  - Evidence: HealBot.lua:389-390 and :415-416 `table.removevalue(...); reindexTable(...)`; vlib.lua:210-218 `function reindexTable(t) ... for _, e in pairs(t) do i = i + 1; e.index = i end end`.
- **Claim**: §4.2's cure table lists a Paralyze row (bit 32, config.paralyseSpell, paralyseCost, cureParalyse) alongside the five slow-loop cures.
  - **Correction**: Self-contradictory with §4.3. Paralysis cure is NOT in the 500 ms loop at all — it is the third branch of the 50 ms elseif chain, it is not gated by `hppercent() > 95`, it is not gated by the group-2 icon check, and it has an extra `not getSpellCoolDown(config.paralyseSpell)` gate. Putting it in the slow-loop table invites a reimplementer to run it at 500 ms behind an HP>95 gate, which would make paralysis cure fire an order of magnitude less often.
  - Evidence: Conditions.lua:238-251 (slow loop: exactly five cures, no paralysis) vs :253-259 (fast loop, third elseif branch: `elseif config.cureParalyse and mana() >= config.paralyseCost and isParalyzed() and not getSpellCoolDown(config.paralyseSpell) then say(config.paralyseSpell)`).
- **Claim**: §7: "if Spells.getSpellByWords(text:lower()) is found: castAimedSpell(text, SpellAimTarget=3, nil) -> g_game.talkSpell(words, 3, SpellAimInvalidPosition)" — stated unconditionally.
  - **Correction**: castAimedSpell has an earlier branch: when `g_game.getClientVersion() < 1525` it sends a plain `g_game.talk(words)` (aim byte 0) and returns true. The aimByte-3 path applies only at cv >= 1525. Harmless for the 1530 target but the spec states it as absolute. Also, getSpellByWords does `:lower():trim()` and scans ALL SpellInfo profiles, whereas vlib's getSpellData scans only SpellInfo['Default'] plus vBot.customCooldowns — the pseudocode's single SPELLDB conflates two different lookups.
  - Evidence: modules/game_interface/gameinterface.lua:501-525 (line 507-510 the <1525 branch, :522-524 the aim-3 branch); modules/gamelib/spells.lua:448-458 getSpellByWords; vlib.lua:278 `local Spells = modules.gamelib.SpellInfo['Default']`, :333-359 getSpellData.
- **Claim**: §2.1/§8: the SPELLDB is a static port of gamelib/spells.lua and `if rem == nil then return true` ("no data yet -> allow one probe cast").
  - **Correction**: The spec never mentions getSpellData's SECOND source. vlib.lua:302-324 records the player's last spoken phrase via onTalk and, on the next 0xA4/0xA5, writes vBot.customCooldowns[lastPhrase] = {id = iconId, group = {[groupId] = duration}}. So spells absent from the static DB (custom-server heals) become fully predictable after their first cast, with synthetic mana=1/level=1. A static-only SPELLDB makes getRealSpellRemaining return nil forever for such words, and the pseudocode's `return true` then removes ALL cooldown gating — the port would re-send those words every 50 ms permanently.
  - Evidence: vlib.lua:302-307 onTalk/lastPhrase; :309-324 onSpellCooldown/onGroupSpellCooldown writing vBot.customCooldowns; :344-351 getSpellData's fallback `for k, v in pairs(vBot.customCooldowns) do if k == spell then c = {id = v.id, mana = 1, level = 1, group = v.group} end end`.

### Additions
- VERIFIED CORRECT (spot-checked line by line, no changes needed): the four loop periods and their exact source lines (HealBot.lua:687-717, :748-805, Conditions.lua:238-251, :253-259); the 50 ms macro clamp and the random(0,100) start jitter; the inclusive comparison semantics ('>' -> >=, '<' -> <=, '=' -> ==) at HealBot.lua:693-713 and :781-800; the STRICT `entry.cost < mana()` spell mana gate at :691 vs the `mana() >= cost` used throughout Conditions.lua; item ids must be > 100 (:535); first-match-then-return in both loops; the item loop's guard ORDER (standByItems -> enabled/#itemTable -> getMultiUseCooldown -> AttackBotFiringUntil -> AttackBotRuneReadyUntil -> looting delay -> rule scan -> standByItems=true); USE_COOLDOWN_MS = 1000 (HealBot.lua:29); the 50 ms same-tick guard and the AttackBot re-check inside useHealItem (:728, :740); recordLocalUseCooldown fires BEFORE the send (:743-744); getMultiUseCooldown = max(0, expiresAt - now - pingCompensation) (:58-62); getPingCompensation = ping > 150 and ping - 30 or 0 (:48-56); healSpellCooldownReady's three-way structure and `remaining <= getRawPing()` (:645-669); getRealSpellRemaining taking the MAX over own + every group cooldown (:95-120); the item loop's 700/200 ms looting throttle and MessageDelay's inverted-sounding meaning (:767-773); Visible/Cooldown/Interval/MessageDelay live, Delay/Conditions dead; checkInventoryConsumption never called; the 5-element structural repair `#HealBotConfig.healbot ~= 5` (:271) and the currentHealBotProfile 1..5 default (:281-283); the setOn/setOff vBotConfigSave("atk") bug (:604, :609); the save triggers (:307, :323, :568, Conditions.lua:64, :80) and the fact that editing rules does NOT save; hasItemAvailable = max(server 0xF5 count, open-container/equipped scan) > 0 (vlib.lua:863-887); the Position(0xFFFF, 0, 0) / stackpos 0 / sendUseOnCreature inventory sentinel (game.cpp:883-907); SpellAimTarget == 3 and MessageSay == 1; the PlayerStates BIT VALUES (all 17 correct); all cure spell words, protocol ids, groups and 6000 ms exhaustions; SpellGroups 1..11 at spells.lua:284-296; configs.lua path/profile/save semantics incl. the 100 MB refusal and the whole-chunk `return onError(...)` on a decode failure; targetbot/looting.lua:103-105 and targetbot/target.lua:186-188; bot.lua:346-350 offline(); Sio.lua not in _Loader.lua:18-58; the storage keys advancedFriendHealer / newHealer; and every AttackBot handshake line (2697, 2833, 2868, 2891, 2903, 2927, 3086) with the correct +10/+150/+250/+400 and readyAt-1000 predictive window.
- VERIFIED: the real on-disk profile_1/HealBot.json is byte-for-byte consistent with the spec's "REAL example" — same currentHealBotProfile, same ConditionPanel values (paralyseCost 200, hasteCost 200, both spells 'utani gran hur', curePosion present / curePoison absent), same two spellTable entries in the same array order with stale index 2 then 1, same three itemTable entries (23374 at HP%<40 disabled, HP%<75, MP%<75), same five profile records with Visible:false/Interval:false/Delay:false/Conditions:false on #1. Only the key ORDER differs (json.encode does not preserve insertion order), which is irrelevant.
- VERIFIED: `hppercent()` really is the server byte, not health/maxHealth — LocalPlayer::setHealth (localplayer.cpp:351-367) never writes m_healthPercent, and parseCreatureHealth (protocolgameparse.cpp:2460-2471) is the write path. This is the single most load-bearing detail in the spec and it is right.
- OMISSION — load order determines intra-tick send order. _Loader.lua loads Conditions (index 29 in the list, position 11) before HealBot (33, position 15) before AttackBot (35, position 17). Macros execute in registration order within one 10 ms bot tick (executor.lua:199), so the sequence is: conditions-500ms -> conditions-50ms -> healbot-spell -> healbot-item -> attackbot. A tick can therefore emit a cure say(), a utura/utana say(), a utamo/haste/paralysis say(), a heal say() and a potion use — up to five actions. A port that serialises or rate-limits outgoing 0x96/0x84 must preserve this order or it will change which action wins.
- OMISSION — the two Conditions chains in the 500 ms loop can BOTH fire in one tick (the spec says this) but so can the 50 ms chain in the same bot tick, because the 500 ms and 50 ms macros are separate entries in _macros and both are due on the same context.now. The pseudocode reproduces this correctly; the spec text should state it explicitly.
- OMISSION — in the item loop `hasItemAvailable(entry.item)` is evaluated for EVERY entry before the enabled check (HealBot.lua:779: `local item = hasItemAvailable(entry.item)` then `if (not currentSettings.Visible or item) and entry.enabled`). The pseudocode short-circuits it behind `e.enabled`. Behaviourally identical, but it means vBot runs a full 0xF5-count + open-container scan per rule per 100 ms tick — relevant if a port caches or throttles that scan.
- OMISSION — useHealItem can return without sending (AttackBot gates re-checked at :728, or the 50 ms same-tick guard at :740) and the item loop still `return`s. That tick is consumed with no potion sent AND without setting standByItems. The pseudocode reproduces it; the spec text should say the tick is wasted.
- OMISSION — HealBot.setActiveProfile's validation is `if not n or not tonumber(n) or n < 1 or n > 5` (HealBot.lua:613). `n < 1` on a string argument raises a comparison error before tonumber can help, so it does not actually accept numeric strings. The pseudocode's `assert(type(n) == 'number' ...)` is stricter and safer, but is not a faithful copy — worth an explicit note since the spec presents §5.1 as a straight description.
- NUANCE on §4.1's `bit.band` advice — vBot's own hasCondition uses the PURE-LUA Bit.band from modules/corelib/bitwise.lua:36-49, which is arithmetic (repeated %2 / *0.5) and correctly handles values up to 2^53, not a 32-bit truncating band. The spec's recommendation to use statesLo with LuaJIT's bit.band is still right (all vBot-used bits, NewManaShield at 2^26 included, fit in the low u32), but the port should be aware that statesHigh bits (>= 2^32, present at cv >= 1405 per parser.lua:1852-1858) become unreachable — fine for every predicate vBot uses, but not for a future one.
- NUANCE on §2.1's canCast fallback — HealBot calls canCast(spellText, true, false), i.e. ignoreRL=TRUE, so the level/mana recheck the code comment at HealBot.lua:661-667 warns about is actually SKIPPED on that path (that comment describes the ignoreCd=true case it chose not to use). The fallback is a pure icon check plus the SpellCastTable branch at vlib.lua:282-288. The spec quotes the comment as if it described the call actually made.
- TARGET-CLIENT CHECK (D:\Claude\otclient_web\luaclient) — all cited plumbing exists and the signatures match the pseudocode: proto/parser.lua:1849-1861 (0xA2 statesLo/statesHigh/states + 'statesChange'), :1869-1872 (0xA4 'spellCooldown' {spellId, delay}), :1873-1876 (0xA5 'spellGroupCooldown' {groupId, delay}), :1877-1879 (0xA6 'multiUseCooldown' {delay}), :1429-1448 (0xF5 -> state.inventoryCounts keyed itemId*256+tier, exactly as the pseudocode assumes); proto/sender.lua:344-378 talk(mode, channelId, receiver, text, aimMode, aimPos), :382-384 talkSpell(text, aimMode, pos, mode), :413-420 useOnCreature(pos, itemId, stackpos, creatureId). game/state.lua:110-130 declares player.statesLo/statesHigh and, notably, player.isDead — which is a cleaner gate for the §2.3 dead-loop defect than the spec's suggested `st.player.health > 0`. Containers carry an `items` array (parser.lua:1356-1361) so itemAmountVisible's shape is right; note it sums `it.count or 1` where the real Player:getItemsCount (gamelib/player.lua:693-699) sums getCount().
