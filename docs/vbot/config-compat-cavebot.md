# vBot 4.8 cavebot `.cfg` — exact READ/WRITE contract

Scope: `profiles/bot/<botconfig>/cavebot_configs/*.cfg`.
Goal: a foreign reader/writer that round-trips the user's real files so the GUI
otclient+vBot keeps loading them identically.

All citations are to the live install at
`D:/Claude/otclient_mehah1530/otclient/`.

Everything below was verified by running vBot's **real** `decodeStringPairList` /
`encodeStringPairList` / `json.lua` under LuaJIT against the user's 18 real
`.cfg` files (see [§7 Verification](#7-verification)).

---

## 0. Who touches a `.cfg`

| Step | Code |
| --- | --- |
| pick file, read bytes | `mods/game_bot/functions/config.lua:69-79` (`Config.load`) |
| bytes → pair list | `modules/corelib/table.lua:291-328` (`table.decodeStringPairList`) |
| the actual line regex | `src/framework/luafunctions.cpp:95-114` (`regexMatch`, `std::regex` ECMAScript) |
| pair list → waypoints/UI | `profiles/bot/vBot_4.8/cavebot/cavebot.lua:207-290` |
| waypoint → list widget | `profiles/bot/vBot_4.8/cavebot/actions.lua:185-227` (`CaveBot.addAction`) |
| UI → pair list | `profiles/bot/vBot_4.8/cavebot/cavebot.lua:578-610` (`CaveBot.save`) |
| pair list → bytes | `modules/corelib/table.lua:279-289` (`table.encodeStringPairList`) |
| bytes → disk | `mods/game_bot/functions/config.lua:95-111` (`Config.save`) → `g_resources.writeFileContents` → `src/framework/core/resourcemanager.cpp:665` → `writeFileBuffer` (`:621`) → PhysFS, raw bytes |

`Config.load` (`config.lua:56-68`) checks `<name>.json` **first**. A stray
`cavebot_configs/foo.json` therefore **shadows** `foo.cfg` completely.
`CaveBot` always passes `configExtension = "cfg"` (`cavebot.lua:207`), so
`Config.save` always takes the `.cfg` branch (`config.lua:105-106`) regardless
of `table.isStringPairList`.

I/O is byte-exact: PhysFS `PHYSFS_readBytes` / `PHYSFS_openWrite`
(`resourcemanager.cpp:559-587`, `:621-660`). No newline translation, no BOM
handling, no charset conversion. `ENABLE_ENCRYPTION` is `0`
(`src/framework/config.h:36`), so no header is prepended/stripped.

---

## 1. File grammar, as vBot's own parser sees it

### 1.1 The one regex

`table.decodeStringPairList` (`table.lua:291-293`) does:

```lua
function table.decodeStringPairList(l)
  local ret = {}
  local r = regexMatch(l, "(?:^|\\n)([^:^\n]{1,20}):?(.*)(?:$|\\n)")
```

and `regexMatch` (`luafunctions.cpp:95-114`) is:

```cpp
g_lua.bindGlobalFunction("regexMatch", [](std::string s, const std::string& exp) {
    int limit = 10000;
    std::vector<std::vector<std::string>> ret;
    if (s.empty() || exp.empty()) return ret;
    try {
        std::smatch m;
        const std::regex e(exp, std::regex::ECMAScript);
        while (std::regex_search(s, m, e)) {
            ret.emplace_back();
            for (auto x : m) ret[ret.size()-1].push_back(x);
            s = m.suffix().str();
            if (--limit == 0) return ret;
        }
    } catch (...) {}
    return ret;
});
```

Consequences, all of them load-bearing:

* Each iteration re-runs `regex_search` on a **fresh** `std::string` (the
  previous suffix), so `^` re-anchors at the start of what is left → the loop
  eats exactly one *non-empty* line per iteration.
* `v[1]` = `m[0]` = **the whole match, including the newline it consumed**
  (and including a *leading* `\n` when the `\n` alternative fired, i.e. after
  blank lines). `v[2]` = the type, `v[3]` = the value.
* `std::regex` is not multiline: `^` = start of the remaining buffer, `$` = its
  true end. `.` never matches `\n`.
* **Hard cap: 10000 matches.** A `.cfg` with more than 10000 non-empty lines is
  silently truncated. The user's biggest file is 375 lines.
* The whole call is inside `try{}catch(...){}` and `Config.load` wraps the
  decode in `pcall` (`config.lua:71-78`): a broken file yields `{}` and the
  message `Invalid cfg config (<name>): ...`, never a crash.

### 1.2 How a line is split

For the remaining buffer, at the first position where it can match:

1. `(?:^|\n)` — zero-width at buffer start, else it *consumes* one `\n`.
2. `([^:^\n]{1,20})` → **type**. Greedy, 1..20 characters, and the class
   excludes `:`, `^` (caret) and `\n`. Zero-length ⇒ no match at this position.
3. `:?` — greedy optional colon. Present ⇒ consumed and not part of either group.
4. `(.*)` → **value**. Greedy to the end of the line (never past a `\n`).
5. `(?:$|\n)` — end of buffer, or consume the line's `\n`.

Verified behaviour (real parser output, `\n` shown as `\n`):

| input line | type (`v[2]`) | value (`v[3]`) | result |
| --- | --- | --- | --- |
| `goto:1,2,3` | `goto` | `1,2,3` | kept |
| `label:` | `label` | `` (empty) | **DROPPED** (`table.lua:322`) |
| `label:` + one space | `label` | `" "` | kept |
| `justtext` (no colon) | `justtext` | `` | **DROPPED** |
| ` goto:1,2,3` (leading space) | `" goto"` | `1,2,3` | kept, but type is `" goto"` → unknown action |
| `\tgoto:1,2,3` | `"\tgoto"` | `1,2,3` | same problem |
| `abcdefghijklmnopqrstuvwxyz:1` | `abcdefghijklmnopqrst` | `uvwxyz:1` | **corrupt** — type >20 chars |
| `abcdefghijklmnopqrst:1` (exactly 20) | `abcdefghijklmnopqrst` | `1` | fine |
| `go^to:1,2,3` | `go` | `^to:1,2,3` | **corrupt** — caret before the colon |
| `label:a^b` | `label` | `a^b` | fine — caret in the value is harmless |
| `blahblah:whatever` | `blahblah` | `whatever` | kept by the parser; rejected later (§1.5) |

### 1.3 Terminator, whitespace, CRLF, blank lines

* A value is terminated **only** by `\n` or end-of-file. There is no comment
  syntax, no quoting, no escaping and no line continuation.
* A missing final newline is fine (`$` alternative). The last pair is still read.
* **Blank lines are legal and skipped.** Runs of `\n` are absorbed by the
  `(?:^|\n)` alternative. Verified: `goto:1,2,3\n\n\n\nlabel:x\n` → exactly two
  pairs.
* **CRLF is NOT supported.** `.` matches `\r`, so `goto:1,2,3\r\n` parses as
  value `"1,2,3\r"` — the CR ends up *inside* the value and every downstream
  `tonumber`/name comparison breaks. All 18 of the user's files are LF-only.
  **A writer must emit LF only.**
* No trimming anywhere. Leading spaces/tabs become part of the *type*; trailing
  spaces become part of the *value*. (Individual actions `:trim()` their own
  comma fields — e.g. `actions.lua:283`, `bank.lua:18` — but the type is never
  trimmed.)
* Bytes ≥ 0x80 pass through untouched (verified with `npcsay:złoty żeton`).
  Files are byte strings, not text; treat them as UTF-8 in, UTF-8 out.

### 1.4 The multi-line `function:[[ ... ]]` block

Detection and accumulation, verbatim (`table.lua:297-326`):

```lua
  for k, v in ipairs(r) do
    if multilineActive then
      local endPos = v[1]:find("%]%]")
      if endPos then
        if endPos > 1 then
          table.insert(ret, { multilineKey, multiline .. "\n" .. v[1]:sub(1, endPos - 1) })
        else
          table.insert(ret, { multilineKey, multiline })
        end
        multilineActive = false
        multiline = ""
        multilineKey = ""
      else
        if multiline:len() == 0 then
          multiline = v[1]
        else
          multiline = multiline .. "\n" .. v[1]
        end
      end
    else
      local bracketPos = v[3]:find("%[%[")
      if bracketPos == 1 then -- multiline begin
        multiline = v[3]:sub(bracketPos + 2)
        multilineActive = true
        multilineKey = v[2]
      elseif v[2]:len() > 0 and v[3]:len() > 0 then
        table.insert(ret, { v[2], v[3] })
      end
    end
  end
```

Rules that follow:

* A block **starts** when the value begins with `[[` at position 1
  (`bracketPos == 1`). Anything after `[[` *on that same line* becomes the first
  chunk of the body. Real files always write `function:[[` with nothing after it.
  This is keyed on the *value*, not on the type: `label:[[x` also starts a block
  (verified).
* `x[[y` (brackets not at position 1) is a plain literal value.
* A block **ends** at the first accumulated line containing `]]` **anywhere**
  (`v[1]:find("%]%]")`). Text before the `]]` on that line is appended; text
  after it is discarded.
  → A body line such as `local t = x[[1]]` terminates the block early and eats
  the rest. Verified: `function:[[\nlocal t = x[[1]]\nreturn true\n]]\n`
  parses to a single pair `function = "\nlocal t = x[[1"`.
* An **unterminated** `[[` swallows the rest of the file. Verified:
  `function:[[\nreturn true\ngoto:1,2,3\nconfig:{}\n` → **empty pair list**, i.e.
  the whole config loads as nothing.
* Because `v[1]` is the *whole match with its newline*, and the accumulator adds
  its own `"\n"` joiner, **the multi-line round trip is lossy exactly once and
  then idempotent.** Measured generation-by-generation:

```
gen0 value="TargetBot.setOn()\nreturn true"
gen1 value="TargetBot.setOn()\n\nreturn true\n"
gen2 value="TargetBot.setOn()\n\n\nreturn true\n\n\n"
gen3 value="TargetBot.setOn()\n\n\nreturn true\n\n\n"   <- fixed point
gen4 value="TargetBot.setOn()\n\n\nreturn true\n\n\n"
```

  This is exactly why every `function` body in the user's real files carries two
  blank lines between statements and three before `]]`
  (`bultaur_bottom.cfg:104-112`, `dtseal_mk.cfg:2-11`). It is **not** corruption
  to be repaired — those files are already at the fixed point, and
  `encode(decode(file)) == file` byte-for-byte for all 18 (§7).
  **Do not "clean up" the blank lines**: doing so restarts the growth cycle and
  the GUI will re-add them on its next save.

### 1.5 Unknown types and malformed lines

The *parser* is permissive — it keeps any `type:value` pair with a non-empty
type and non-empty value. Rejection happens one layer up:

* `cavebot.lua:239-274` iterates the pairs; anything that is not `config` /
  `extensions` / `staypositions` goes to
  `CaveBot.addAction(v[1], v[2], false, stayPos, true)`.
* `CaveBot.addAction` lowercases the type and looks it up
  (`actions.lua:186-189`):
  ```lua
  action = action:lower()
  local raction = CaveBot.Actions[action]
  if not raction then
    return warn("Invalid cavebot action: " .. action)
  end
  ```
  → an unregistered type prints a warning and **no widget is created**. The rest
  of the file still loads.
* **Danger:** `actionIndex` is incremented *before* that call
  (`cavebot.lua:266`), so stay-position indices stay aligned on load — but the
  dropped waypoint is **gone from the list**, so the next GUI save writes the
  file back **without it**, and every later `staypositions` index shifts down by
  one. Unknown types are silently, permanently deleted on the next save.
* Types are matched **case-insensitively on load** (`:lower()` in both
  `registerAction` `actions.lua:262` and `addAction` `actions.lua:186`) but
  vBot always **writes** the lowercased form, because `CaveBot.save` emits
  `child.action` which was already lowercased.

---

## 2. Waypoint types

Every type registered in this install (`CaveBot.registerAction`, lowercased):

`bank buysupplies cleartile delay depositor dpwithdraw exanihur follow forge
function goto gotolabel imbuing inwithdraw label lure npcsay opendoors poscheck
rushlure say sayhello sellall stowdeposit supplycheck tasker travel turn use
usewith walkdelay withdraw`

(`sayhello` is the disabled `extension_template.lua` demo; `node` appears in a
comparison at `cavebot.lua:41` but is **never registered** — dead branch.)

The 22 types that actually occur in the user's 18 files, with real examples:

| type | value syntax | real example | parsed at |
| --- | --- | --- | --- |
| `goto` | `x,y,z` or `x,y,z,precision` — regex `\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+),?\s*([0-9]?)`; the 4th field (recorder writes `,0`) forces exact-tile arrival | `goto:32359,32226,7` / `goto:32413,32171,7,0` | `actions.lua:345-357` |
| `label` | free text, used verbatim; matched case-insensitively by `gotoLabel` | `label:hunt` | `actions.lua:272-275`, `cavebot.lua:567-576` |
| `gotolabel` | label name | `gotolabel:start` | `actions.lua:277-279` |
| `delay` | `ms` or `ms,randomPercent` (`string.split(value, ",")`, each field `:trim()`ed) | `delay:500` | `actions.lua:281-305` |
| `use` | `x,y,z` — or, if that regex fails, a bare item id | `use:32321,32211,7` | `actions.lua:545-580` |
| `usewith` | `itemid,x,y,z` | `usewith:9596,32787,32364,8` | `actions.lua:582-617` |
| `follow` | creature name (exact) | `follow:Captain Bluebear` | `actions.lua:307-323` |
| `function` | Lua chunk; multi-line ⇒ `[[ … ]]` block. Compiled with a generated prefix (`retries`, `prev`, `delay`, `gotoLabel`, one local per extension) | see §1.4 | `actions.lua:325-343` |
| `say` | text said in the default channel | *(not in the user's files)* | `actions.lua:619-622` |
| `npcsay` | text sent through the NPC channel | `npcsay:Veggie Casserole` | `actions.lua:624-627` |
| `supplycheck` | `label` or `label,x,y,z` | `supplycheck:hunt,32894,32356,9` | `supply_check.lua:60-…` |
| `buysupplies` | `NPCname` or `NPCname,delayMs` (1..2 fields) | `buysupplies:Donald McRonald,200` | `buy_supplies.lua:21-40` |
| `sellall` | `NPCname[,yes][,itemIds…]` — `yes` anywhere ⇒ sell with delay, numeric fields are exceptions | `sellall:Johny The Marketer` | `sell_all.lua:5-30` |
| `bank` | `deposit,NPC` \| `withdraw,NPC,amount` \| `transfer,NPC,name,balanceLeft` (2, 3 or 4 fields) | `bank:deposit,Ebenizer` | `bank.lua:6-33` |
| `depositor` | `yes` \| `no` | `depositor:no` | `depositor.lua:34-…` |
| `stowdeposit` | `yes` \| `no` | `stowdeposit:no` | `depositor.lua:168-…` |
| `opendoors` | `x,y,z` or `x,y,z,keyId` | `opendoors:32864,32810,9` | `doors.lua:4-20` |
| `poscheck` | `label,dist,x,y,z` or `label,dist,x,y,z,maxRetries` (`maxRetries` = positive int or `inf`) — exactly 5 or 6 fields | `poscheck:up1,10,33357,31591,13` | `pos_check.lua:6-30` |
| `exanihur` | `up\|down,north\|east\|south\|west[,label]` (direction may also be `0..3`) | `exanihur:up,north` | `route_tools.lua:129-175` |
| `travel` | `NPCname,cityName` (≥2 fields) | `travel:Captain Seahorse,thais` | `travel.lua:4-32` |
| `walkdelay` | integer ms, 0..10000 — sets `CaveBot.Config` `walkDelay` from here on | *(none in these files)* | `route_tools.lua:38-49` |
| `turn` | `north\|east\|south\|west` or `0..3` | *(none in these files)* | `route_tools.lua:209-219` |

Remaining registered types and their editor-declared value templates:
`lure` = `start|stop|toggle` (`lure.lua:4-19`),
`cleartile` = `x,y,z[,doors|stand]` (`clear_tile.lua:120-123`),
`rushlure` = `x,y,z,delayMs[,yes|no]` (`stand_lure.lua:148-161`),
`withdraw` = `index|inbox,id,amount` (`withdraw.lua:51-54`),
`dpwithdraw` = `index,containerName,containerId` (`d_withdraw.lua:99-102`),
`inwithdraw` = `id,amount` (`inbox_withdraw.lua:86-89`),
`imbuing` = `config` (`imbuing.lua:770-777`),
`forge`/`tasker` — free-form, configured through their own editor windows.

Note the value is **always a string**; `CaveBot.addAction` only converts a
`number` argument (`actions.lua:190-192`), which never happens on the load path.

---

## 3. The three special lines: `config`, `extensions`, `staypositions`

Read at `cavebot.lua:223-275`, written at `cavebot.lua:590-607`.

### Placement / order

* vBot **writes** them last, in exactly this order — all waypoints first, then
  `config`, then `extensions`, then `staypositions` (`cavebot.lua:591`, `:603`,
  `:607`). All 18 real files match (e.g. `dtseal_mk.cfg:373-375`).
* The **reader does not care about position**: `cavebot.lua:239-274` walks the
  whole list and dispatches on the key, and the `staypositions` pre-scan
  (`:223-236`) is a separate full pass done *before* the waypoints are added.
  A special line placed in the middle is handled and does **not** consume an
  `actionIndex` (the three branches at `:241`, `:250`, `:263` all skip the
  `actionIndex = actionIndex + 1` in the `else` at `:266`).
* Duplicates: for `config` and `extensions` the **last** occurrence wins;
  for `staypositions` the pre-scan `break`s, so the **first** wins.
* Since `staypositions` indices are 1-based positions in the *waypoint* list,
  keeping the vBot order (specials last) is the only sane choice for a writer.

### Exact JSON shapes

**`config:` — a JSON object** of `CaveBot.Config.values` (`config.lua:92-94`
returns the table; `cavebot.lua:591` encodes it). The 15 keys currently declared
by `CaveBot.Config.setup` (`cavebot/config.lua:26-59`):

| key | type | default |
| --- | --- | --- |
| `ping` | number | `100` |
| `walkDelay` | number | `10` |
| `mapClick` | boolean | `false` |
| `mapClickDelay` | number | `100` |
| `ignoreFields` | boolean | `false` |
| `skipBlocked` | boolean | `false` |
| `useDelay` | number | `400` |
| `wptDistance` | number | `5` |
| `antiLostEnabled` | boolean | `true` |
| `antiLostTeleportIds` | string | `"1949,1950,1951,1952"` |
| `antiLostLadderIds` | string | long comma list |
| `antiLostRopeIds` | string | `"386,7762,12935,12936,13381,33051"` |
| `antiLostRopeToolId` | number | `3003` (declared `{ item = 3003 }`, stored as a plain number, `config.lua:145-175`) |
| `stayPathEnabled` | boolean | `true` |
| `waypointHud` | boolean | `false` |

All 18 real files also carry `smoothWalk` (18/18) and `avoidFloorChange` /
`avoidTileIds` (4/18) — keys from an **older** build. On load they are ignored
(`config.lua:85-89` only applies a key that has a `value_setters` entry); on the
next GUI save they are **dropped**, because `CaveBot.Config.save()` returns only
the currently-declared values.

Real line (`sell_all.cfg:2`):

```
config:{"waypointHud":false,"antiLostEnabled":false,"smoothWalk":false,"ignoreFields":false,"antiLostTeleportIds":"1949,1950,1951,1952","skipBlocked":false,"antiLostLadderIds":"1948,1968,…,21298","walkDelay":10,"ping":100,"useDelay":400,"mapClickDelay":100,"antiLostRopeIds":"386,7762,12935,12936,13381,33051","antiLostRopeToolId":3003,"mapClick":false,"stayPathEnabled":true,"wptDistance":5}
```

**Missing `config`** ⇒ `cavebotConfig` stays `nil` ⇒
`CaveBot.Config.onConfigChange(name, enabled, nil)` resets every setting to its
default and returns (`cavebot/config.lua:80-90`). Harmless, but the user loses
their per-route tuning.
**Malformed `config` JSON** ⇒ `pcall` fails, `warn("warn while parsing CaveBot
extensions from config:\n"…)`, `cavebotConfig` stays `nil` — same reset.

**`extensions:` — a JSON object keyed by `CaveBot.Extensions` table name**
(`Bank`, `BuySupplies`, `Depositor`, `Imbuing`, … see
`CaveBot.Extensions.<Name> = {}` at the top of each `cavebot/*.lua`), whose
values are whatever that extension's `onSave()` returned (`cavebot.lua:594-603`).
**In this install no shipped extension defines `onSave`** (only the disabled
`extension_template.lua:43`), so `extension_data` is always the empty table and
`json.encode` emits `[]` — which is why all 18 files contain literally:

```
extensions:[]
```

**Missing `extensions`** ⇒ the `for extension, callbacks in pairs(...)` loop at
`cavebot.lua:257-261` never runs, so no extension's `onConfigChange` is called
and each keeps whatever state the *previously loaded* config left it in. A
writer should always emit the line.

**`staypositions:` — a JSON object** mapping the waypoint's 1-based index
**as a decimal string** to `{x,y,z}` (`cavebot.lua:585-587`):

```lua
if child.stayPos then
  stayPositions[tostring(actionIndex)] = { x = child.stayPos.x, y = child.stayPos.y, z = child.stayPos.z }
end
```

Read back at `cavebot.lua:268-271`:

```lua
local sp = stayPositionsData[tostring(actionIndex)]
if sp then stayPos = { x = tonumber(sp.x), y = tonumber(sp.y), z = tonumber(sp.z) } end
```

`actionIndex` counts **only** non-special pairs, in file order, starting at 1.
Verified against the user's files: every key is ≤ the waypoint count
(`bultaur_bottom` 255 waypoints / max key 253; `rossh_west` 155 / 149;
`true_asura_mk` 292 / 272; `vegge_casserole` 291 / 196; `test` 3 / 3;
`sell_all` 1 / 1).

Real lines:

```
staypositions:[]
staypositions:{"3":{"x":33218,"y":32433,"z":6},"2":{"x":33218,"y":32434,"z":7}}
staypositions:{"160":{"y":32356,"z":9,"x":32894},"253":{"y":32223,"z":7,"x":32359},…}
```

Note both key orders `x,y,z` and `y,z,x` occur — see §4 on key ordering.

**Missing `staypositions`** ⇒ `stayPositionsData = {}` ⇒ no waypoint gets a
`stayPos` ⇒ the Stay Path pre-walk (`cavebot.lua:100-…`) is skipped everywhere.
Non-fatal, but the route behaves differently.
**Malformed** ⇒ `warn("warn while parsing CaveBot stay positions from config")`
and the same empty result (`cavebot.lua:229-233`).

Empty is written as **`[]`, not `{}`** (see §4). Both decode to an empty Lua
table, so both are accepted on read; emit `[]` to stay byte-identical to vBot.

---

## 4. The WRITE path

`CaveBot.save()` (`cavebot.lua:578-610`) builds `data` — a plain array of
`{typeString, valueString}` pairs — in this order:

1. every widget of `ui.list`, in list order, as `{child.action, child.value}`
   (`:582-588`); `child.action` is already lowercase;
2. `{"config", json.encode(CaveBot.Config.save())}` (`:591`);
3. `{"extensions", json.encode(extension_data, 2)}` (`:603`);
4. `{"staypositions", json.encode(stayPositions)}` (`:607`);

then `config.save(data)` → `Config.save(dir, name, data, "cfg")`
(`functions/config.lua:95-111`) → `table.encodeStringPairList(data)` →
`g_resources.writeFileContents(file .. ".cfg", …)`.

### The serialiser (`table.lua:279-289`, verbatim)

```lua
function table.encodeStringPairList(t)
  local ret = ""
  for k, v in ipairs(t) do
    if v[2]:find("\n") then
      ret = ret .. v[1] .. ":[[\n" .. v[2] .. "\n]]\n"
    else
      ret = ret .. v[1] .. ":" .. v[2] .. "\n"
    end
  end
  return ret
end
```

* One `\n`-terminated line per pair, **including the last** → the file always
  ends with `\n`.
* The *only* escaping that exists: if the value contains a `\n` **anywhere**, it
  is wrapped as `type:[[\n` + value + `\n]]\n`. Nothing inside the body is
  escaped — no backslashes, no `]]` protection. See §1.4 for why `]]` in a body
  is unrecoverable.
* A value containing `\r` but no `\n` is written **inline**, CR and all.
* Nothing is quoted, trimmed, or length-checked. A type longer than 20 chars or
  containing `:`/`^` is written happily and read back wrong (§1.2).

### The JSON encoder — `modules/corelib/json.lua` (rxi json.lua 0.1.2)

`json.encode(val)` takes **one** argument (`json.lua:131-133`). The `, 2` at
`cavebot.lua:603` and `functions/config.lua:108` is **silently ignored** — there
is no pretty-printing, ever. Output is always one dense line, which is exactly
why the JSON survives the line-oriented `.cfg` format.

Verified quirks (run against this file):

| input | output | source |
| --- | --- | --- |
| `{}` (empty table) | `[]` — **not `{}`** | `json.lua:70` `if rawget(val,1) ~= nil or next(val) == nil then` treats an empty table as an array |
| `{1,2,3}` | `[1,2,3]` | `json.lua:83-87` |
| `{a=1}` | `{"a":1}` | `json.lua:91-98` |
| `{a=true,b={x=1}}` | `{"a":true,"b":{"x":1}}` | booleans via `tostring` (`json.lua:119`) |
| `{n=32894}` | `{"n":32894}` | `string.format("%.14g", val)` (`json.lua:111`) |
| `{n=0.1}` | `{"n":0.1}` | |
| `{n=1/3}` | `{"n":0.33333333333333}` | `%.14g` ⇒ **14 significant digits** |
| `{n=123456789012345}` | `{"n":1.2345678901234e+14}` | integers ≥ 1e14 turn into exponent notation and **lose digits** |
| `{n=1e15}` | `{"n":1e+15}` | |
| `{s='a"b\\c/d\te\nf\1g'}` | `{"s":"a\"b\\c/d\te\nf\u0001g"}` | escape set is `[%z\1-\31\\"]` only (`json.lua:103`) — `/` is **not** escaped |
| `{s="złoty"}` | `{"s":"złoty"}` | non-ASCII bytes pass through **raw**, never `\uXXXX` (`json.lua:51-53` only `\u`-escapes bytes < 32) |
| `{n=0/0}` | error `unexpected number value 'nan'` | `json.lua:108-110` (also ±inf) |
| `{[1]="a", x="b"}` | error `invalid table: mixed or invalid key types` | `json.lua:74-77` |

* **Key ordering is `pairs()` order — undefined and unstable.** Two saves of the
  same data can emit the object keys in different orders. This is visible in the
  user's own files: `test.cfg` has `{"x":…,"y":…,"z":…}` while
  `bultaur_bottom.cfg` has `{"y":…,"z":…,"x":…}`. **A foreign writer may use any
  key order**; a differ must compare decoded JSON, never the raw line.
* Any string value that contains a literal `\n` is emitted as `\n` (escaped), so
  a JSON line can never accidentally trigger the `[[` multi-line path. But a
  string containing `[[` at the very start of the *value*… cannot happen either,
  because the value always starts with `{` or `[`.

`json.decode` (`json.lua:365-375`) is strict: it rejects trailing garbage,
control characters inside strings, and non-string object keys. It accepts
`1e+15`. Object keys become Lua strings — hence `tostring(actionIndex)` on both
sides of the `staypositions` map.

---

## 5. Rules for a foreign writer

### MUST

1. **LF only.** Every line ends with a single `\n`, including the last one. Never
   `\r\n`.
2. **One `type:value` line per waypoint**, in route order, types lowercase, taken
   from the registered set in §2.
3. **Type ≤ 20 bytes, no `:`, no `^`, no leading/trailing whitespace, no
   newline.** All real types are ≤ 13 bytes.
4. **Value non-empty.** An empty value makes the parser drop the whole line
   (`table.lua:322`) and the waypoint vanishes. Emit at least one character
   (vBot itself never writes an empty value for a registered action).
5. **Values must not contain `\r`.**
6. **Multi-line values** (in practice only `function`) must be written exactly as
   `type:[[\n` + body + `\n]]\n`, with `[[` immediately after the colon and
   nothing else on that line.
7. **Preserve `function` bodies byte-for-byte** as they were read. They are
   already at the parser's fixed point (§1.4); re-wrapping an unchanged body
   reproduces the file exactly (verified for all 18 files).
8. **Emit all three special lines, last, in the order `config`, `extensions`,
   `staypositions`.**
9. **Empty `extensions` / `staypositions` must be `[]`**, matching rxi's
   empty-table-is-an-array rule. `config` is always a non-empty object.
10. **`staypositions` keys are decimal strings of the 1-based waypoint index,
    counting only non-special lines.** Renumber them whenever waypoints are
    inserted, removed or reordered, or the Stay Path positions attach to the
    wrong waypoints.
11. **Emit JSON on a single line**, dense (no spaces), with `%.14g`-style numbers
    (plain integers for coordinates and item ids), `true`/`false` for booleans,
    and raw UTF-8 in strings.
12. **Escape only `"` `\` and bytes < 0x20** in JSON strings; leave `/` and every
    byte ≥ 0x80 alone, so the line matches what vBot would write.
13. **Write the whole file atomically** (temp file + rename): `Config.save` does
    a truncating `PHYSFS_openWrite`, so a half-written file is a lost route.

### MUST NEVER

1. **Never write CRLF, a BOM, or any encoding other than the bytes you read.**
2. **Never put `]]` inside a `function` body** (including `x[[1]]`,
   `--[[ … ]]`, `s = "]]"`). It ends the block early and silently truncates the
   rest of the file. Use `--[==[ … ]==]` / `\93\93` if a literal is unavoidable.
3. **Never leave a `[[` block unterminated** — the entire remainder of the file
   is swallowed and the config loads as *nothing*.
4. **Never start a non-multiline value with `[[`** — the parser will read it as a
   block opener regardless of type.
5. **Never emit a comment, a blank-line separator you care about, or any
   indentation.** Comments do not exist; a leading space becomes part of the
   type; blank lines survive a load but are erased by the next GUI save.
6. **Never invent a type** that is not in `CaveBot.Actions` (§2). It loads with a
   warning, is not added to the list, and is **deleted** by the next GUI save —
   which also shifts every later `staypositions` index.
7. **Never pretty-print / indent the JSON lines.** A newline inside a JSON value
   turns the line into a `[[` block on the *next* save and corrupts the file.
8. **Never rely on JSON object key order** for comparison or diffing — vBot's
   own order is `pairs()` order and changes between saves.
9. **Never "normalise" the blank lines inside an existing `function` body.**
10. **Never create `cavebot_configs/<name>.json`** — `Config.load` prefers it and
    would shadow the `.cfg` (`functions/config.lua:56-68`), and `Config.list`
    would show the name twice (`:28-33`).
11. **Never use a config file name containing `json` or `cfg`.**
    `Config.list` strips them with `v:gsub(".json",""):gsub(".cfg","")` — Lua
    *patterns*, where `.` is a wildcard — so e.g. `myjson.cfg` is listed as `m`.
12. **Never exceed 10000 non-empty lines** (`regexMatch`'s hard `limit`).
13. **Never drop a waypoint you did not understand.** Round-trip unknown pairs
    verbatim; deleting them is exactly what the GUI does and it is destructive.

### Recommended

* Keep unknown `config` keys (`smoothWalk`, `avoidFloorChange`, `avoidTileIds`)
  when rewriting a file. vBot ignores them on load and drops them on save;
  keeping them is strictly less destructive.
* Validate before writing with the same predicate `Config.save` uses:
  `table.isStringPairList` (`table.lua:269-277`) — a non-empty array whose every
  element is a 2-element array of **strings**.
* Diff by decoding, not by bytes: compare the pair list and the decoded JSON.

---

## 6. Reference: minimal well-formed file

```
label:start
goto:32359,32226,7
goto:32359,32220,7,0
buysupplies:Topsy,300
delay:500
function:[[
TargetBot.setOn()


return true


]]
poscheck:up1,10,33357,31591,13
gotolabel:start
config:{"ping":100,"walkDelay":10,"mapClick":false,"mapClickDelay":100,"ignoreFields":false,"skipBlocked":false,"useDelay":400,"wptDistance":5,"antiLostEnabled":true,"antiLostTeleportIds":"1949,1950,1951,1952","antiLostLadderIds":"1948,1968","antiLostRopeIds":"386,7762","antiLostRopeToolId":3003,"stayPathEnabled":true,"waypointHud":false}
extensions:[]
staypositions:{"7":{"x":33357,"y":31591,"z":13}}
```

Waypoint indices for `staypositions`: `label`=1, `goto`=2, `goto`=3,
`buysupplies`=4, `delay`=5, `function`=6, `poscheck`=7, `gotolabel`=8.

---

## 7. Verification

Method: a scratch harness in the system temp dir (nothing written into either
project) running under
`otclient/build/win-local/vcpkg_installed/x64-windows-static-release/tools/luajit/luajit.exe`.
It contains `table.decodeStringPairList`, `table.encodeStringPairList`,
`table.isStringPairList` copied **verbatim** from `modules/corelib/table.lua`
and `dofile`s the real `modules/corelib/json.lua`. Only `regexMatch` had to be
re-implemented (it is a C++ `std::regex` binding). That re-implementation was
cross-checked against an **independent** Python implementation of the same loop
(`^`→start-of-buffer, `$`→`\Z`, matching C++ ECMAScript non-multiline
semantics): **the parsed pair lists agree exactly on all 18 real `.cfg` files.**

Round-trip, all 18 files: `encodeStringPairList(decodeStringPairList(bytes))`
is **byte-identical** to the file on disk, and a second generation is stable:

```
bultaur_bottom.cfg  isStringPairList=true  in=5658 out=5658  identical=true
  gen2: pairs=258 bytes=5658  stable(out2==out)=true
dtseal_mk.cfg       isStringPairList=true  in=7663 out=7663  identical=true
  gen2: pairs=357 bytes=7663  stable(out2==out)=true
…same for the other 16 files…
```

### `dtseal_mk.cfg` — real parser output

```
== dtseal_mk.cfg : 7663 bytes, 357 parsed pairs (first 24 + last 4) ==
   1  label          | hunt
   2  function       | \nTargetBot.setOn()\n\n\nreturn true\n\n\n
   3  goto           | 33366,31610,14
   4  goto           | 33360,31610,14
   5  goto           | 33354,31609,14
   6  goto           | 33352,31603,14
   7  goto           | 33352,31597,14
   8  goto           | 33351,31591,14
   9  goto           | 33357,31591,14
  10  label          | up1
  11  goto           | 33358,31591,14,0
  12  goto           | 33358,31588,13,0
  13  goto           | 33363,31597,13
  14  poscheck       | up1,10,33357,31591,13
  15  goto           | 33357,31599,13
  16  goto           | 33351,31599,13
  17  goto           | 33349,31605,13
  18  goto           | 33347,31611,13
  19  label          | up2
  20  goto           | 33350,31610,13,0
  21  goto           | 33353,31608,12,0
  22  poscheck       | up2,10,33354,31609,12
  23  goto           | 33356,31607,12
  24  goto           | 33356,31601,12
  ...
 354  gotolabel      | hunt
 355  config         | {"smoothWalk":false,"skipBlocked":false,"antiLostLadderIds":"1948,1968,5542,7771,9116,20474,20475,21365,28656,31129,31130,31262,33770,34243,35908,4337 ...<515 chars>
 356  extensions     | []
 357  staypositions  | []

-- pair 2  function  (35 chars) --
[[
TargetBot.setOn()


return true


]]
   visible: "\nTargetBot.setOn()\n\n\nreturn true\n\n\n"
-- pair 61  function  (36 chars) --
[[
TargetBot.setOff()


return true


]]
   visible: "\nTargetBot.setOff()\n\n\nreturn true\n\n\n"
```

### `bultaur_bottom.cfg` — real parser output

```
== bultaur_bottom.cfg : 5658 bytes, 258 parsed pairs (first 24 + last 4) ==
   1  label          | start
   2  goto           | 32359,32226,7
   3  goto           | 32359,32220,7
   4  goto           | 32365,32215,7
   5  goto           | 32369,32209,7
   6  goto           | 32369,32203,7
   7  goto           | 32369,32197,7
   8  goto           | 32369,32191,7
   9  goto           | 32369,32185,7
  10  goto           | 32375,32183,7
  11  goto           | 32381,32183,7
  12  goto           | 32387,32182,7
  13  goto           | 32393,32182,7
  14  goto           | 32399,32182,7
  15  goto           | 32405,32182,7
  16  goto           | 32411,32179,7
  17  goto           | 32411,32173,7
  18  goto           | 32413,32171,7,0
  19  buysupplies    | Topsy,300
  20  delay          | 500
  21  goto           | 32410,32179,7
  22  goto           | 32404,32184,7
  23  goto           | 32398,32183,7
  24  goto           | 32392,32182,7
  ...
 255  gotolabel      | start
 256  config         | {"waypointHud":false,"antiLostEnabled":true,"smoothWalk":false,"ignoreFields":false,"antiLostTeleportIds":"1949,1950,1951,1952","skipBlocked":false,"a ...<514 chars>
 257  extensions     | []
 258  staypositions  | {"160":{"y":32356,"z":9,"x":32894},"253":{"y":32223,"z":7,"x":32359},"162":{"y":32225,"z":7,"x":32358},"104":{"y":32225,"z":7,"x":32358},"19":{"y":321 ...<170 chars>

-- pair 104  function  (34 chars) --
[[TargetBot.setOn()


return true


]]
   visible: "TargetBot.setOn()\n\n\nreturn true\n\n\n"
-- pair 162  function  (35 chars) --
[[TargetBot.setOff()


return true


]]
   visible: "TargetBot.setOff()\n\n\nreturn true\n\n\n"
```

(Note the difference between the two files: `dtseal_mk`'s bodies begin with a
`\n`, `bultaur_bottom`'s do not. Both are valid; both are fixed points. Preserve
whichever the file already has.)
