# CaveBot — waypoint execution, walking, supplies (vBot 4.8) → luaclient reimplementation spec

# CaveBot behaviour specification (vBot 4.8) for a headless LuaJIT client

Everything below is BEHAVIOUR unless explicitly marked **[WIDGET]**. Where vBot stores a value in a
widget, the persisted location is named.

Sources are cited `file:line`. Root of the profile is
`D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8` (referred to as `<P>`).

---

## 0. Runtime substrate (what the loop runs on)

| fact | value | evidence |
|---|---|---|
| bot host tick | 10 ms (`scheduleEvent(check,10)`) | `mods/game_bot/bot.lua:531` |
| macro dispatch | `lastExecution + timeout <= now` | `mods/game_bot/executor.lua:199-210` |
| **macro timeout floor** | **50 ms** — `macro(20,…)` really runs every 50 ms | `mods/game_bot/functions/main.lua:37-40` |
| `now` | `g_clock.millis()` refreshed once per host tick | `executor.lua:196` |
| `delay(ms)` (inside an action) | **overwrites** `macro.delay = now+ms` | `main.lua:206-211` |
| `CaveBot.delay(ms)` | **max()** — `macro.delay = max(macro.delay or 0, now+ms)` | `<P>/cavebot/cavebot.lua:563-565` |
| a delayed macro is skipped entirely | `if not macro.delay or macro.delay < now then run()` | `main.lua:114` |
| `getDistanceBetween(a,b)` | **Chebyshev** `max(|dx|,|dy|)` | `executor.lua:124-126` |

Loop periods actually in force: CaveBot **50 ms** (`cavebot.lua:80` declares 20), AntiLost **200 ms**
(`antilost.lua:589`), waypoint-HUD **150 ms** (`antilost.lua:846`), TargetBot **100 ms**
(`targetbot/target.lua:49`).

**luaclient mapping.** One `LC.sched.every(50, cavebotTick)`, one `LC.sched.every(200, antiLostTick)`.
Reproduce `CaveBot.delay` as a module-level `nextRunAt` compared against `LC.sched` time / `sys.nowMs()`;
reproduce the max-vs-overwrite distinction exactly, it is load bearing (a `delay(70)` at the top of
depositor must not shorten a `CaveBot.delay(3000)` set later in the same tick — and it doesn't, because
they are different functions writing the same field with different rules).

---

## 1. The waypoint list model

### 1.1 File location and selection

* Routes: `<P>/cavebot_configs/<name>.cfg` (`.json` also accepted — `mods/game_bot/functions/config.lua:55-81`).
* Which route is active + on/off: bot storage `<P>/storage/profile_<N>.json`, key
  `_configs.cavebot_configs = { enabled=<bool>, selected="<name>" }`
  (`config.lua:137-147,164-171`; `cavebot.lua:344-346`; real file has `"selected":"true_asura_mk"`).
  `<N>` = `g_settings.getNumber('profile')` (`bot.lua:273`).
* Switching profile at runtime: `CaveBot.setCurrentProfile(name)` → off, set `selected`, on
  (`cavebot.lua:554-561`).

### 1.2 The `.cfg` wire format (`table.encodeStringPairList` / `decodeStringPairList`)

`modules/corelib/table.lua:279-328`.

* An ordered **list of `[key, value]` string pairs**, one per line, `key:value`.
* Key regex: `(?:^|\n)([^:^\n]{1,20}):?(.*)` — **key is at most 20 chars, no `:` and no newline**.
* Multi-line values are written as
  ```
  key:[[
  line1
  line2
  ]]
  ```
  Encoder emits this iff `value:find("\n")` (`table.lua:282-283`). Decoder starts a block when the
  value *starts* with `[[`, ends it on the first line containing `]]` (text before `]]` on that line
  is appended) (`table.lua:317-321,299-305`).
* **A line whose value is empty is silently DROPPED on load** (`table.lua:322`: `v[2]:len()>0 and v[3]:len()>0`).
  Never write a waypoint with an empty value.
* Order is preserved and *is* the waypoint order.

### 1.3 Reserved trailing keys

`CaveBot.save()` appends, in this order (`cavebot.lua:578-610`):

1. `config:<json>` — the CaveBot Config panel values (`CaveBot.Config.save()` returns `CaveBot.Config.values`).
2. `extensions:<json>` — per-extension blob (`{}`/`[]` in practice; no shipped extension implements `onSave`).
3. `staypositions:<json>` — `{ "<1-based action index>": {x=,y=,z=} }`, or `[]` when empty
   (Lua `json.encode({})` → `[]`).

Loader (`cavebot.lua:220-275`): pre-scans for `staypositions` **before** adding actions, then walks the
list; `config`/`extensions`/`staypositions` are consumed as metadata, every other pair becomes a
waypoint, and `actionIndex` counts **only real waypoints** (so the stay-position key is the waypoint
ordinal, not the file line).

### 1.4 REAL example from disk — `<P>/cavebot_configs/test.cfg` (complete file)

```
goto:33218,32434,7,0
exanihur:up,north
exanihur:down,south
config:{"ignoreFields":false,"skipBlocked":false,"antiLostLadderIds":"1948,1968,5542,7771,9116,20474,20475,21365,28656,31129,31130,31262,33770,34243,35908,43374,48493,48494,50122,50123,50564,50565,435,7750,21221,21298","ping":100,"antiLostRopeToolId":9596,"stayPathEnabled":true,"waypointHud":false,"walkDelay":10,"avoidTileIds":"","avoidFloorChange":true,"mapClickDelay":100,"useDelay":400,"wptDistance":5,"antiLostTeleportIds":"1949,1950,1951,1952","mapClick":false,"smoothWalk":false,"antiLostRopeIds":"386,7762,12935,12936,13381,33051","antiLostEnabled":true}
extensions:[]
staypositions:{"3":{"x":33218,"y":32433,"z":6},"2":{"x":33218,"y":32434,"z":7}}
```
(waypoint 2 = the `exanihur:up` entry, waypoint 3 = `exanihur:down` — confirming index semantics.)

Second REAL example, multi-line value + full route tail — `<P>/cavebot_configs/true_asura_mk.cfg`
(lines 1,5,8,16-18,61,69-77,149-150,270-271,301,306,308-311):

```
label:start
use:32626,32742,6
buysupplies:Tandros,100
follow:Old Adall
delay:500
travel:Old Adall,east
opendoors:32864,32810,9
function:[[

TargetBot.setOn()


return true



]]
supplycheck:hunt,32822,32816,11
label:refill
follow:Lorek
travel:Lorek,center
stowdeposit:no
bank:deposit,Ferks
gotolabel:start
config:{... "walkDelay":30, "ignoreFields":true, "avoidTileIds":"21793", "antiLostRopeToolId":9596 ...}
extensions:[]
staypositions:{"69":{"x":32629,"y":32743,"z":6},"270":{"x":32582,"y":32763,"z":7},"272":{"x":32582,"y":32763,"z":7},"141":{"x":32822,"y":32816,"z":11},"143":{"x":32629,"y":32743,"z":6}}
```

### 1.5 The in-memory waypoint record **[partly WIDGET]**

`CaveBot.addAction(action, value, focus, stayPos, isLoading)` (`actions.lua:185-228`) creates a list row
carrying exactly three semantic fields:

```lua
{ action = <lowercased type>, value = <raw string>, stayPos = {x,y,z} | nil }
```
Everything else on the widget (text `action..":"..firstLine(value)`, colour, double-click editor) is
**[WIDGET]**. `stayPos` capture rule: use the explicit argument if given; else, if **not** loading from a
config **and** the action is not in `STAYPATH_EXCLUDED_ACTIONS`, capture the live player position
(`actions.lua:201-208`). Headless: only ever load stayPos from `staypositions`.

`action` is **lower-cased** on add and on lookup (`actions.lua:186`, `registerAction` `actions.lua:262`),
so `BuySupplies`, `SellAll`, `PosCheck`, `Travel`, `Tasker`, `ClearTile`, `OpenDoors` register under
`buysupplies`, `sellall`, `poscheck`, `travel`, `tasker`, `cleartile`, `opendoors`.

### 1.6 Every waypoint TYPE

Return contract for an action callback: `true` (done, advance), `false` (failed, advance anyway),
or the string `"retry"` (stay on this waypoint, `retries+1`, re-run next tick)
(`actions.lua:253-260`; dispatcher `cavebot.lua:158-190`).

| type | value syntax | semantics | limits / evidence |
|---|---|---|---|
| `label` | free text | sets `vBot.lastLabel = value`; returns true. Pure marker. | `actions.lua:272-275` |
| `gotolabel` | label name | `CaveBot.gotoLabel(v)`: case-insensitive scan for the first `label` waypoint whose value matches, focus it. Returns true/false. **Focus is set to the label itself, and the dispatcher then advances +1**, so execution resumes at the waypoint *after* the label. | `cavebot.lua:567-576`, `cavebot.lua:192-202` |
| `delay` | `ms` or `ms,percent` | On `retries==0`: `final = ms`; if a 2nd field, `diff = ms/100*percent`, `final = math.random(ms-diff, ms+diff)`; `CaveBot.delay(final)`; return `"retry"`. On the next entry (`retries==1`) return true. So the delay is applied once, then the waypoint completes. | `actions.lua:281-305`; editor validation `^[0-9]{1,10}$\|^[0-9]{1,10},[0-9]{1,4}$` `editor.lua:98` |
| `goto` | `x,y,z` or `x,y,z,precision` | The main walker. Full algorithm in §2.3. The 4th field is the **precision marker**; presence (even `,0`) switches to exact-stand semantics and makes the waypoint unskippable. | `actions.lua:345-543` |
| `use` | `x,y,z` **or** `itemId` | If the value parses as `x,y,z`: bail false when `z≠playerZ` or `Chebyshev>7`; require tile loaded and a `getTopUseThing()`; `use(topThing)`; `CaveBot.delay(useDelay + ping)`; true. If it is a bare number: `use(itemId)` (inventory use) and return true immediately with no delay. | `actions.lua:545-580` |
| `usewith` | `itemId,x,y,z` | Same guards (`z`, Chebyshev ≤ 7, tile, topUseThing); `usewith(itemId, topThing)`; `CaveBot.delay(useDelay + ping)`; true. | `actions.lua:582-617` |
| `say` | text | `say(text)` — normal public talk (routed through spell-aim if the words are a known spell). true. | `actions.lua:619-622`, `functions/player.lua:90-97` |
| `npcsay` | text | `NPC.say(text)` → `g_game.talkChannel(11,0,text)` (NPC channel) for client ≥ 810. true. | `actions.lua:624-627`, `functions/npc.lua:5-12` |
| `follow` | creature name | `getCreatureByName(v)` (same floor only). Not found → print + false. If `Chebyshev(creature,player) < 2` → `cancelFollow()`, true. Else `follow(c)`, `delay(200)`, `"retry"`. | `actions.lua:307-323` |
| `function` | Lua source (usually multi-line) | Compiled with a prefix injecting `retries`, `prev`, `delay=CaveBot.delay`, `gotoLabel=CaveBot.gotoLabel`, a `macro` stub that warns, and one local per `CaveBot.Extensions.<name>`. Runs in the bot sandbox env. Its **return value is the action's return value** (so it may return `"retry"`). Compile/run error → warn + false. | `actions.lua:325-343` |
| `walkdelay` | integer 0..10000 | Sets `CaveBot.Config.set("walkDelay", v)` (and thus writes the route's `config:` blob). true. Out of range → warn + false. | `route_tools.lua:38-57` |
| `turn` | `north\|east\|south\|west` or `0..3` | `turn(dir)`; true. | `route_tools.lua:209-218` |
| `exanihur` | `up\|down,north\|east\|south\|west[,fallbackLabel]` (numeric facing 0-3 accepted) | On `retries==0` record `exaniStartZ = posz()`. Success test first: `dz = posz()-startZ`; `up` needs `dz<0`, `down` needs `dz>0` → true. At `retries>=20` → if a fallback label was given `gotoLabel(label)` else false. Otherwise: re-face (`turn(dir)` if facing differs), `say("exani hur "..mode)`, `CaveBot.delay(1000)`, `"retry"`. | `route_tools.lua:126-175` |
| `forge` | `convert[,times]` or `limit[,times]` (times clamped 1..50, default 1) | `convert`→ForgeAction 2 (DUST2SLIVER), `limit`→4 (INCREASELIMIT). `retries >= count` → true. Else `g_game.forgeRequest(actionType)`, `CaveBot.delay(800)`, `"retry"`. | `route_tools.lua:60-89` |
| `poscheck` | `label,dist,x,y,z[,maxRetries]` | `maxRetries` default 10, `inf`/`infinity` → unlimited, must otherwise be a positive integer. Retry counter resets whenever the *value string* changes. If counter ≥ maxRetries → reset, print, **false** (unclog, proceed). Else if `z` matches and `Chebyshev(player,target) <= dist` → true. Else counter++ and: `label == "last"` → `gotoFirstPreviousReachableWaypoint()`, otherwise `gotoLabel(label)`; return **false**. | `pos_check.lua:6-63` |
| `opendoors` | `x,y,z[,keyId]` | `retries>=5` → false. Find the tile by scanning `g_map.getTiles(posz())`. Tile missing → false. If `not tile:isWalkable()` → `use(topUseThing)` (or `useWith(key, topUseThing)`), `delay(200)`, `"retry"`. Walkable → true. | `doors.lua:4-49` |
| `cleartile` | `x,y,z[,doors][,stand]` (tokens in any order) | `retries>=20` → false. Standing on it (Chebyshev==0) → true. Tile missing → false. If walkable && top-use-thing immovable && no creature && no `doors` flag: if `stand` and not at exact tile → `CaveBot.GoTo(tPos,0)` + retry, else true. Not within 3 → `CaveBot.GoTo(tPos,3)` + retry. `retries>0` → `delay(1100)`. Then, in order: monster on tile → `attack`, retry; movable top item → `g_game.move(item, playerPos, count)`, retry; player on tile → pick a random walkable tile adjacent to him (≠ our tile) and `g_game.move(creature,pos,1)`, retry (no candidate → false); `doors` flag → `use(topUseThing)`, retry. | `clear_tile.lua:4-118` |
| `lure` | `start\|stop\|toggle` | `start` → `TargetBot.setOff()`, `stop` → `TargetBot.setOn()`, `toggle` → flip. Always true. (Yes, `start`=TargetBot **off** — the character lures.) | `lure.lua:4-20` |
| `rushlure` | `x,y,z,delayMs[,yes\|no]` | Aborts (false) if supplies are short. `retries>50` (and no reset pending) → false. `Chebyshev>30` → false. Pathfind twice (ignoring / not ignoring creatures); if only the creature-ignoring path exists, find the first blocking monster and attack it (chase mode 1), retry. Then `TargetBot.delay(300)` + `CaveBot.walkTo(pos,30,{precision=0})` until standing exactly on the tile; then `TargetBot.setOn()`, `CaveBot.delay(delayMs)`, true. The 5th field defers a TargetBot on/off until focus leaves this waypoint. | `stand_lure.lua:45-186` |
| `supplycheck` | `label` or `label,x,y,z` | §4.1. | `supply_check.lua:60-157` |
| `buysupplies` | `NpcName[,delayMs]` | §4.3. | `buy_supplies.lua:21-99` |
| `sellall` | `NpcName[,yes][,exceptionId…]` | §4.4. | `sell_all.lua:5-81` |
| `depositor` | `no` \| `yes` | §4.5. | `depositor.lua:34-130` |
| `stowdeposit` | `no` \| `yes` | §4.6 (stash first, depot second). | `depositor.lua:168-285` |
| `bank` | `deposit,NPC` \| `withdraw,NPC,amount` \| `transfer,NPC,targetName,balanceLeft` | §4.7. | `bank.lua:6-78` |
| `withdraw` | `source,itemId,amount` (`source` = depot-box index, or falsy → inbox) | `retries>100` → close depot/locker containers, true. `itemAmount(id) >= amount` → close containers, true. Else `CaveBot.WithdrawItem(id,amount,source)`, `CaveBot.PingDelay()`, `"retry"`. | `withdraw.lua:4-49`, `vBot/new_cavebot_lib.lua:505-543` |
| `dpwithdraw` | `depotIndex,destContainerName,destContainerId[,capLimit]` | `retries>600` → false. `freecap() < (capLimit or 200)` → close depot/locker, print, **false**. Find dest container by exact lowercase name and any open `depot box`. No dest → false. Dest full → open the next nested `destContainerId` inside it, retry. Depot box open and empty → close it, true. `CaveBot.OpenDepotBox(index)` until open. `PingDelay(2)`. Then move the **first** item of the depot box into the dest container's first free slot, retry. | `d_withdraw.lua:4-104` |
| `inwithdraw` | `itemId,amount` | `itemAmount>=amount` → true. `retries>400` → true. Open `your inbox` via `ReachAndOpenInbox`. Inbox holds none → warn, close, true. Destination = last open container that is not full and whose name lacks `quiver`/`depot`/`loot`/`inbox`; none → close inbox, false. `PingDelay(2)`; move one stack (`min(count, amount-current)` if stackable, else 1) to the dest's first free slot; retry. | `inbox_withdraw.lua:4-84` |
| `travel` | `NpcName,destination[,…]` | §4.8. | `travel.lua:4-33` |
| `imbuing` | must be exactly `config` | Everything is configured out-of-band in `storage.autoImbue`; the waypoint only triggers a run. §4.9. | `imbuing.lua:616-768` |
| `tasker` | `1,taskName,count,monster[,monster2]` \| `2,labelInProgress,labelDone` \| `3` | 1 = take task (`Conversation("hi","task",name,"yes")`, `delay(talkDelay*4)`, seed `storage.caveBotTasker`); 2 = branch on progress via `gotoLabel`; 3 = report (`Conversation("hi","report","task")`, `delay(talkDelay*3)`, reset). Modes 1 and 3 require an NPC within 3 sqm (`getNpcs(3)`). Kill counter is driven by `Loot of …` text messages. | `tasker.lua:29-177` |
| `sayhello` | (template/demo only) | `extension_template.lua:15` |

**There is no `node` action.** `cavebot.lua:42`, `cavebot.lua:173` and `antilost.lua:212,252,284`
still branch on `"node"` (legacy vBot), but nothing registers it — loading a `node:` line yields
`warn("Invalid cavebot action: node")` (`actions.lua:188-189`). Do not implement it; do keep the
`goto`-equivalent parsing branches if you want byte-compatibility with old routes.

### 1.7 The recorder (how routes are produced) — behaviour worth keeping

`recorder.lua:29-63`. Never records while CaveBot is on.
* First position change: emit `goto:oldPos`.
* `newPos.z ~= oldPos.z` **or** a jump > 1 tile in x/y → emit `goto:oldPos,0` (the **transfer marker**);
  if the immediately preceding entry is a plain `goto` with the *same* `x,y,z`, that entry is **upgraded
  in place** to `…,0` instead of duplicating.
* Otherwise emit a new `goto:newPos` whenever `max(|dx|,|dy|)` from the last recorded point exceeds
  `wptDistance` (Config, default 5, floored at 1).
* `onUse(pos,…)` with `pos.x ~= 0xFFFF` → `use:x,y,z`. `onUseWith` on an item target → `usewith:id,x,y,z`.

---

## 2. The main execution loop

`cavebot.lua:80-203`, one tick every 50 ms.

### 2.1 Tick order

```
1. if TargetBot and TargetBot.isActive() and not TargetBot.isCaveBotActionAllowed():
       CaveBot.resetWalking(); return            -- TargetBot owns the character
2. if CaveBot.doWalking(): return                -- a walk is in flight
3. if list empty: return
4. current = focusedChild or firstChild
5. Stay-Path pre-walk gate (§2.4) — may `return` without running the action
6. run the action callback inside pcall, after CaveBot.resetWalking()
7. "retry" -> retries++, return (stay on this waypoint)
   boolean  -> retries = 0, prevActionResult = result, update positionedBySelfNav
   anything else -> warn
8. if focus changed during the action, re-read it and reset retries/prevActionResult
9. advance: nextIndex = index(current)+1; wrap to 1 past the end; focusChild(next)
```

Notes that matter:
* **`false` also advances.** Only `"retry"` holds position. A "failed" waypoint is skipped, not retried.
* `CaveBot.resetWalking()` runs **before every action callback** (`cavebot.lua:163`), clearing the
  single-step path ledger; the action is expected to re-issue its own walk.
* Index advance is computed from the *possibly re-read* current widget, so an action that calls
  `gotoLabel`/`gotoNextWaypointInRange` and returns true lands on `label+1`.
* `retries` is a single loop-scoped counter shared by whatever waypoint is focused, reset to 0 on any
  boolean return and on focus change (`cavebot.lua:78,168,196`).
* `prevActionResult` is passed as the 3rd callback arg (only `function` waypoints read it).

### 2.2 What counts as "arrived" (goto)

Two different tests, chosen by whether the destination is a *transfer tile*
(`actions.lua:393-396`, `431-434`):

```
minimapColor = getMinimapColor(dest)
stairs        = 210 <= minimapColor <= 213
hasPrecisionMarker = a 4th comma-field was present (even "0")

if stairs or hasPrecisionMarker:
    prec = tonumber(field4) or 0
    arrived  <=>  |dx| <= prec and |dy| <= prec        -- BOTH axes
else:
    arrived  <=>  dx == 0 and |dy| <= 1                -- asymmetric, see pitfalls
```

### 2.3 goto: full control flow (`actions.lua:345-543`)

```
0. parse "\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+),?\s*(\d?)"; unparsable -> warn, false
1. retry ceiling, checked FIRST:
      mapClick and not marker : retries >= 5   -> noPath++, pathfinder(), false
      otherwise               : retries >= 100 -> noPath++, pathfinder(), false
2. dest.z ~= player.z                      -> noPath++, pathfinder(), false
3. |dx| + |dy| > gotoMaxDistance (MANHATTAN)-> noPath++, pathfinder(), false
4. arrival test (§2.2) -> noPath = 0; true
5. FINAL APPROACH (only when stairs or marker) and Chebyshev(dx,dy) <= 3:
      if player is walking or prewalking -> CaveBot.delay(50); "retry"
      p = findPath(playerPos, dest, 10, {ignoreNonPathable, precision=0})
      if p[1]: walk(p[1]); CaveBot.delay(stepDuration(p[1]) + ping + 50); "retry"
      (no path -> fall through)
6. path  = findPath(playerPos,dest,maxDist,{ignoreNonPathable,precision=1,
                                            ignoreCreatures,allowUnseen,
                                            allowOnlyVisibleTiles=false})
   if not path:
        breakFurniture(dest) succeeded -> CaveBot.delay(1000); "retry"
        else noPath++, pathfinder(), false
7. path2 = findPath(playerPos,dest,maxDist,{ignoreNonPathable,precision=1})  -- creatures COUNT
   if not path2:                       -- something living is in the way
        replay `path` tile by tile; first tile with a monster
        (isMonster, healthPercent>0, getType()<3 on 9.60+) that is itself
        reachable within 7:
             if not already attacking it:
                 Chebyshev(creature) > 3 -> CaveBot.walkTo(creature,7,{ignoreNonPathable,precision=1})
                 else                    -> attack(creature)
             setChaseMode(1); CaveBot.delay(100); retries = 0(local); break
        if no such monster:
             marker or stairs -> CaveBot.delay(200); "retry"   -- NEVER skip a precision wpt
             else             -> false
8. if not ignoreFields and CaveBot.walkTo(dest, 40)                      -> "retry"
9. if CaveBot.walkTo(dest, maxDist, {ignoreNonPathable, allowUnseen,
                                     allowOnlyVisibleTiles=false})       -> "retry"
10. if retries >= 3:
       prec = (stairs or marker) and 0 or (retries - 1)
       if CaveBot.walkTo(dest, 50, {ignoreNonPathable, precision=prec, allowUnseen,
                                    allowOnlyVisibleTiles=false})        -> "retry"
11. if (not mapClick) and retries >= 5 and not marker and not stairs
                                                -> noPath++, pathfinder(), false
12. if skipBlocked and not marker and not stairs -> noPath++, pathfinder(), false
13. last resort: CaveBot.walkTo(dest, maxDist, {ignoreNonPathable, precision=1,
                                                ignoreCreatures, allowUnseen,
                                                allowOnlyVisibleTiles=false})
       if it returned false: CaveBot.delay(min(100 + retries*50, 500))
    "retry"
```

So: **skip** happens at steps 1,2,3,6,7(no-monster, plain wpt),11,12. **Wait** happens for stairs and
precision waypoints at 7 and, indefinitely (up to 100 retries), through 13.

`pathfinder()` (`actions.lua:119-134`): no-op unless `storage.extras.pathfinding`; fires only when
`noPath >= 10`. Then `CaveBot.gotoNextWaypointInRange()`; if that fails and a `getConfigFromName()`
hook exists, it toggles the active cavebot profile between `#Unibase` and that name. Resets `noPath`.

`CaveBot.gotoNextWaypointInRange()` (`cavebot.lua:352-401`): scan forward from the current index, then
from the start, for the first `goto:` whose `z == posz()`, `Chebyshev <= storage.extras.gotoMaxDistance`,
and for which `findPath(player, pos, maxDist, {ignoreNonPathable})` succeeds; focus **index-1** (so the
main loop's +1 lands on it).

`CaveBot.gotoFirstPreviousReachableWaypoint()` (`cavebot.lua:422-455`): walk backwards up to 100 rows for
a `goto` on the current floor within `gotoMaxDistance/2`; focus it directly.

`breakFurniture(destPos)` (`actions.lua:69-101`): never in PZ. Over all tiles on the current floor, pick
the candidate top thing that is either a magic wall (id 2130) or (non-walkable and moveable, id not in
`{2986}`), reachable within 7, minimising `Chebyshev(destPos, tilePos)`; `useWith(3197, thing)`
(destroy field / disintegrate rune).

Also unconditional and independent of the loop: an `onTextMessage` hook for
`"There is not enough room."` (`actions.lua:41-67`) — with CaveBot on, find an adjacent tile with no
creature, walkable, and **>9 items**; outside PZ `useWith(3197, topThing)`, inside PZ move the top thing
to any other walkable neighbour, throttled to one move per 200 ms.

### 2.4 Stay Path — the hidden goto for non-`goto` waypoints

`cavebot.lua:97-156`, constants `cavebot.lua:8,17-22,34`.

Applies when `stayPathEnabled` **and** the waypoint carries a `stayPos` **and**
`CaveBot.positionedBySelfNav == false` **and** the action is not in `CaveBot.StayPathExcluded`.

`STAYPATH_EXCLUDED_ACTIONS` (`actions.lua:139-175`): `goto, use, usewith, label, gotolabel, delay,
follow, walkdelay, depositor, stowdeposit, bank, buysupplies, sellall, travel, imbuing, inwithdraw,
dpwithdraw, withdraw, cleartile, opendoors`.

`STAYPATH_SELF_NAV` (`cavebot.lua:17-21`, controls the `positionedBySelfNav` latch): `follow, sellall,
buysupplies, bank, travel, depositor, stowdeposit, withdraw, dpwithdraw, inwithdraw, imbuing, cleartile,
opendoors`. Latch is **set** when one of those returns `true`, and **cleared** by any `goto`/`node`
returning a boolean (`cavebot.lua:173-177`) and on config load (`cavebot.lua:282`).

Staleness filter: `previousRoutePosition(list, index)` scans up to 12 rows back for a
`goto`/`node`/`use` (`x,y,z`) or `usewith` (`id,x,y,z`) position. If that reference exists and
(`ref.z ~= stayPos.z` **or** `max(|dx|,|dy|) > 15`), the stayPos is declared **stale**, logged once, and
ignored.

Otherwise, if `player.z == stayPos.z` and (`|dx| > 2` or `|dy| > 2`):
* track best distance reached (`dist = Chebyshev`), refresh a timestamp on strict improvement;
* while `now - bestAt < 3000` ms: `CaveBot.walkTo(stayPos, 40, {ignoreNonPathable=true, precision=2})`,
  warn at most once per 3000 ms if that returns false, and **return** (action does not run yet);
* after 3000 ms without improvement: **fail open** — fall through and run the action from wherever we are.

Different floor, or within 2 tiles → clear tracking state and run the action.

### 2.5 TargetBot interaction — who wins

* Gate: `TargetBot.isActive()` is `lastAction + 300 > now`, where `lastAction` is stamped whenever
  TargetBot attacked or looted in its 100 ms loop (`targetbot/target.lua:182-184,113,121`).
* Override: `TargetBot.isCaveBotActionAllowed()` is `cavebotAllowance > now`; TargetBot sets
  `allowCaveBot(150)` while **luring** (close-lure amount reached, dynamic lure, or `lureCavebot`)
  (`target.lua:186-188,247-249`; `targetbot/creature_attack.lua:148-159`).
* So: TargetBot wins by default while fighting/looting; CaveBot keeps walking only during the 150 ms
  lure grants, refreshed every TargetBot tick.
* On preemption CaveBot calls `CaveBot.resetWalking()`, which in smooth mode also sends `g_game.stop()`
  to cancel the server-side walk queue (`walking.lua:250-262`). Resumption is implicit: the very next
  50 ms tick after the gate opens re-runs the same waypoint from its current `retries` value.
* The other direction: cavebot `function` waypoints call `TargetBot.setOn()/setOff()`; the `lure`
  waypoint does the same; `rushlure` calls `TargetBot.delay(300)` while approaching.

---

## 3. Walking

### 3.1 The pathfinder (`findPath` / `getPath`)

`mods/game_bot/functions/map.lua:143-220` on top of `Map::findEveryPath`
(`src/client/map.cpp:1316-1473`). Dijkstra over the 8 neighbours from `start`.

* **Refuses immediately when `startPos.z ~= destPos.z`** (`map.lua:159-161`). CaveBot never crosses
  floors with a path.
* `maxDist` defaults to 100 when not a number; it caps `node.distance` (step count), not cost.
* Node cost = tile ground speed (default 100 when no ground; 150 in the step-duration path), multiplied
  by `playerDiagonalWalkSpeed = 3` for diagonal moves (`map.cpp:1451`, `gameconfig.h:125`).
  `ignoreCost` flattens every edge to 1.
* A neighbour is rejected when any of:
  * `not wasSeen and not allowUnseen`
  * `hasStairs and not ignoreStairs and neighbor ~= dest`, where **`hasStairs = isNotPathable and 210 <= minimapColor <= 213`** (`map.cpp:1429-1431`) — yellow **and** not pathable
  * `isNotPathable and not ignoreNonPathable and neighbor ~= dest`
  * `isNotWalkable and not ignoreNonWalkable`
  * `maxDistanceFrom` exceeded
  * `hasBlockingCreature and not ignoreCreatures` (with `ignoreLastCreature` it is still recorded at
    cost +100 so a path *to* the creature exists)
* Off-map / unaware tiles fall back to the persisted minimap (`wasSeen`, `notWalkable`, `notPathable`,
  colour, speed) unless `allowOnlyVisibleTiles`.
* `precision = p`: if the exact destination is not in the result set, search rings `p = 1..precision`
  for the cheapest reachable tile within that Chebyshev box and path there (`map.lua:194-214`).
* `marginMin`/`marginMax`: path to the cheapest tile in an annulus around the destination — used by
  TargetBot, not CaveBot.
* Return value is a **list of direction ints** from start (`map.lua:116-140`). Standing on the
  destination yields `{}` (empty, **truthy**), not nil — so callers test `path[1]`.

Direction ints: `North=0, East=1, South=2, West=3, NorthEast=4, SouthEast=5, SouthWest=6, NorthWest=7`
(`actions.lua:10-37`, `walking.lua:43-52`).

### 3.2 Who actually moves the character

Three mechanisms, selected by config (`walking.lua:307-333`, `471-502`):

1. **Single step** (default; `mapClick = false`, `smoothWalk = false`)
   `CaveBot.walkTo(dest, maxDist, params)`:
   * `path = getPath(player:getPosition(), dest, maxDist, params)`; `not path or not path[1]` → **false**
   * `avoidFloorChange` filter (§3.4) → false when the path steps on a transfer tile
   * `g_game.walk(path[1], false)` (raw, no prewalk), store `walkPath = path`, `walkPathIter = 2`,
     `expectedDirs = {path[1]}`
   * `CaveBot.delay(walkDelay + stepDuration(path[1]))`; return true
   `CaveBot.doWalking()` then pumps the rest: while `#expectedDirs > 0`, send `walkPath[walkPathIter]`,
   append to `expectedDirs`, `walkPathIter++`, `CaveBot.delay(walkDelay + stepDuration)`, return true.
   `#expectedDirs >= 3` → `resetWalking()` (drop the whole plan, the action re-paths).
   `onPlayerPositionChange` pops `expectedDirs[1]` when the observed direction matches
   (`walking.lua:337-378`).
2. **Map click / autowalk** (`mapClick = true`)
   `autoWalk(path)` → `g_game.autoWalk(dirs, {0,0,0})` — one packet with the whole direction list,
   protocol limit **127 steps** (`src/client/game.cpp:692-695`). `CaveBot.delay(mapClickDelay + 50)`.
3. **Smooth walk (ping sync)** (`smoothWalk = true`, `walking.lua:382-469,265-305`)
   Keeps a FIFO `pending` of sent-but-unconfirmed steps; pathfinds from `projectedPos()` = confirmed
   position advanced by every in-flight step; paces sends with
   `sendWindow = min(3, 1 + ceil(ping / stepDuration))` and a 50 ms minimum inter-send gap; never
   re-sends. Watchdog: if `now - max(lastConfirmAt, pending[1].t) > ping + 2*stepDuration + 400` →
   `g_game.stop()`, drop everything, `CaveBot.delay(100)`. A position change that does not match
   `pending[1].dir` (teleport/push/floor change) voids the ledger and forces a re-path with
   `CaveBot.delay(100)`. In map-click mode it refuses to stack a second autowalk while
   `#pending > 0 or player:isPreWalking()` (`CaveBot.delay(50)`, report "walking"), and it mirrors the
   client's stair truncation before sending: cut the path at the first tile with
   `hasFloorChange()` or `hasElevation(3)`.

`walk(dir)` used by the goto final approach is `modules.game_walk.smartWalk(dir)`
(`functions/player.lua:64`), i.e. the normal client walk with prewalk; `g_game.walk(dir,false)` in
walking.lua is the raw no-prewalk send.

`stepDuration = player:getStepDuration(false, dir)` (`src/client/creature.cpp:1106-1160`):
```
groundSpeed = tile(dir):getGroundSpeed() or 150
d = 1000 * groundSpeed / speed
d = ceil(d / serverBeat) * serverBeat            -- serverBeat default 50 ms
diagonal steps: d *= 3 (playerDiagonalWalkSpeed)
d += 10 * max(1, preWalkingSize)  ; then d -= 10 (baseline correction)
```
Fallback in walking.lua when it returns a non-number or ≤0: **200 ms** (`walking.lua:217-223`).

`ping = g_game.getPing()`, rejected and replaced by `CaveBot.Config.values["ping"]` (default 100) when
not a number, ≤ 0, or > 5000 (`walking.lua:209-215`, `actions.lua:420-423`).

### 3.3 Creature blocking the way

Handled only inside `goto` step 7 (§2.3): compare a creature-ignoring path with a creature-respecting
one; if only the former exists, walk the former's tiles, find the first monster on one, verify it is
itself reachable within 7, then approach (>3 away) or attack it, set chase mode 1, and retry with a
100 ms delay. Players are never attacked — for those, the waypoint eventually falls through to
`skipBlocked`/retry-limit skipping (or to `cleartile`'s explicit push logic if the route uses it).

`pushPlayer()` exists in `actions.lua:103-117` (push a creature onto any adjacent non-stairs walkable
tile) but is **dead code** — nothing calls it.

### 3.4 Floor-change avoidance (the "don't fall in the hole" filter)

`walking.lua:78-207`, config keys `avoidFloorChange` (default true) and `avoidTileIds` (CSV of item ids).

A tile counts as a floor-change tile when **any** of:
1. minimap colour in `[210,213]` **and** `not tile:isPathable()` — the pathfinder's own stairs rule;
2. its **ground** item is `notPathable` (holes, trapdoors, stairs — fields sit *on* the ground and do
   not trip this, so `ignoreNonPathable` can still cross fire/energy);
3. any of ground/top-use-thing has `getLensHelp()` in `{1104, 1105}` (stairs up / stairs down).
   **1100 ladders, 1101 sewer grates, 1102 rope spots, 1106 shovel spots are deliberately excluded** —
   standing on them is harmless, they need a `use`;
4. its ground id or top-use id is in `avoidTileIds`.

**Yellow alone is never enough** — a staircase is drawn over several yellow tiles of which only one
transfers, and blocking them all leaves the bot at the foot of the stairs.

The whole classifier is inside a `pcall` and **fails open** (returns "not a floor change") — a helper
error must never stop the bot walking. A tile that is not loaded returns false (only the minimap knows
it, and colour alone is not proof).

`pathCrossesFloorChange(fromPos, dest, path)` replays the direction list; a hit on any tile **other than
the exact destination** refuses the path (a `goto` *onto* stairs is intentional). Log throttled to one
message per tile per 10 s. Exposed for TargetBot chase as
`CaveBot.wouldStepChangeFloor(fromPos, dir)` (`walking.lua:172-181`).

### 3.5 Deliberate floor changes

There is no dedicated "climb" waypoint. Routes change floor by:
* `goto:x,y,z,0` onto the transfer tile (recorder-emitted marker; stairs / holes you walk into);
* `use:x,y,z` for ladders and sewer grates;
* `usewith:ropeId,x,y,z` for rope spots (`usewith:9596,…` for a multi-tool on this server);
* `exanihur:up|down,facing[,label]` for levitation;
* the antilost teleport recovery for teleport tiles.

### 3.6 Anti-lost recovery

`<P>/cavebot/antilost.lua`. Independent 200 ms macro. Constants: `GIVE_UP_ATTEMPTS = 200`,
`RETRY_DELAY = 200`, `RECOVERY_FREEZE_MS = 1500`, `STAIRS_COLOR_MIN/MAX = 210/213`,
`LOCAL_SEARCH_RADIUS = 2`, `WIDE_SEARCH_RADIUS = 6`, `REPEAT_FALL_WINDOW_MS = 60000`,
`MAX_FLOOR_CHANGES_PER_RECOVERY = 4`, `LOOKAHEAD = 6` (`antilost.lua:5-11,149-151,303`).

**Trigger** (`antilost.lua:363-432`) on `onPlayerPositionChange` with `newPos.z ~= oldPos.z`, CaveBot on,
`antiLostEnabled` on, not already recovering, and:

* `isExpectedFloorChange(newZ, oldPos)` must be **false**. That predicate (`antilost.lua:279-361`) asks,
  for the current waypoint, the previous one, and up to 6 following ones:
  * action is `use`, `usewith` or `exanihur` → deliberate;
  * `goto` whose `z == newZ` → deliberate ("the waypoint is on the floor we arrived at");
  * `goto` within 1 tile of `oldPos` that carries the `,0` marker → deliberate;
  * `goto` within 1 tile of `oldPos` sitting on a yellow (210-213) tile → deliberate;
  * a positional waypoint that is **not** near `oldPos`, or is on a different floor than `newZ` →
    **accidental**.
* Bounce guard: `recentFalls["x,y,z>newZ"]`; a repeat of the same fall inside 60 s is treated as an
  intended transfer and left alone.

**Classification.** Look at the top-use thing of the tile we fell from. If its id is in
`antiLostTeleportIds` → mode `"teleport"`, remembering that id. Otherwise mode `"stairs"`.
Then `CaveBot.delay(1500)` to freeze CaveBot.

**Recovery loop** (every 200 ms while recovering; each pass re-freezes CaveBot with
`CaveBot.delay(1500)`):
1. `isBackOnTrack(pPos)` (`antilost.lua:192-241`) — the current waypoint's own position
   (`goto`/`use`/`usewith` value, else `stayPos`; position-less waypoints count as OK) must be on our
   floor and reachable with `findPath(…, gotoMaxDistance, {ignoreNonPathable, precision=1,
   ignoreCreatures, allowUnseen, allowOnlyVisibleTiles=false})`. If so → stop recovering.
2. If we are back on `fallSpot.z` and still not on track → `giveUpToCaveBot()`:
   `gotoNextWaypointInRange()` or, failing that, `gotoFirstPreviousReachableWaypoint()`.
3. `teleport` mode: target = nearest tile within radius 6 whose top-use id equals the remembered
   teleport id. None → give up. `Chebyshev > 1` → `CaveBot.walkTo(target, 30, {ignoreNonPathable,
   precision=0})`; a false return drops the target so it is re-searched. Adjacent → verify the id is
   still there and step onto it.
4. `stairs` mode: target = **exactly** `{fallSpot.x, fallSpot.y, currentZ}` if that tile is a *recovery
   tile*; otherwise the nearest recovery tile within radius **2** of it. Never a wider search — a
   different hole would take the bot somewhere else entirely. None → give up.
   A **recovery tile** = yellow (210-213) **or** its top-use id is in `antiLostLadderIds` or
   `antiLostRopeIds` (`antilost.lua:80-103`).
   `Chebyshev > 1` → walkTo (precision 0); on failure drop the target.
   Adjacent/on it → dispatch **in this order** (`antilost.lua:544-585`):
   * id in `antiLostLadderIds` → `use(topThing)`;
   * id in `antiLostRopeIds` → `usewith(antiLostRopeToolId, topThing)` (falls back to 3003 if the item
     slot is empty or < 100);
   * else `topThing:isUsable()` → `use(topThing)`;
   * else a plain hole: if we are standing on it (dist 0) step onto a walkable neighbour first
     (walkTo precision 0, radius 3) so that a later pass can re-enter it by an actual step; otherwise
     step onto it.
   The list order is deliberate: the generic `isUsable()` fallback must come **after** the explicit
   lists.
5. Any floor change while recovering clears the target and increments a counter; more than **4**
   floor changes in one recovery → give up ("bouncing, not recovering").
6. Per-target attempt counter capped at 200, then give up.

**Minimap colour rules, summarised** — colour is only ever used as *evidence*, never alone:
* pathfinder blocks a through-tile only when `yellow AND notPathable` (`map.cpp:1429`);
* `avoidFloorChange` blocks the same, plus ground-notPathable, plus lenshelp 1104/1105, plus the id list;
* antilost accepts a **yellow OR listed-id** tile as a return point, but only at the exact fall spot ± 2;
* `pushPlayer` refuses yellow tiles as push targets (`actions.lua:110-112`).

### 3.7 Waypoint HUD **[WIDGET]**

`antilost.lua:622-870`, config `waypointHud`. Draws a crosshair effect and a coordinate label on every
waypoint tile. Pure cosmetics — do not implement.

---

## 4. Supplies, refill, deposit

### 4.1 `supplycheck` — the round gate

`supply_check.lua:60-157`. Value: `label` or `label,x,y,z`.

Position guard (only when x,y,z given):
* `missedChecks >= 4` → reset counters, print, **return true** (proceed into town anyway);
* `getDistanceBetween(player, pos) > 10` → `missedChecks++`, **`return CaveBot.gotoLabel(label)`**
  (bounce back into the hunt and try again). Five tries total.

Decision cascade — the **first** matching branch wins (`supply_check.lua:102-155`):

| # | condition | result |
|---|---|---|
| 1 | `storage.caveBot.forceRefill` (clears the flag) | false → refill |
| 2 | `storage.caveBot.backStop` | false → refill (depositor will then turn CaveBot off) |
| 3 | `storage.caveBot.backTrainers` | false → refill (then `gotoLabel('toTrainers')`) |
| 4 | `storage.caveBot.backOffline` | false → refill (then `gotoLabel('toOfflineTraining')`) |
| 5 | `storage.extras.huntRoutes ~= 0` and `supplyRetries > huntRoutes` | false → refill (round limit) |
| 6 | `imbues.enabled` and `player:getSkillLevel(11) == 0` | false → refill |
| 7 | `stamina.enabled` and `stamina() < stamina.value` | false → refill |
| 8 | `softBoots.enabled` and `itemAmount(6529)+itemAmount(3549) < 1` | false → refill |
| 9 | `Supplies.hasEnough()` returned a table `{id, amount}` (some item below its **min**) | false → refill |
| 10 | `capacity.enabled` and `freecap() < capacity.value` | false → refill |
| 11 | `lootPouch.enabled` and pouch page count `>= lootPouch.value` | false → refill |
| 12 | otherwise | `setCaveBotData(true)` (round++) and **`return CaveBot.gotoLabel(label)`** → keep hunting |

Loot-pouch pages (`supply_check.lua:39-57`): only the container literally named `loot pouch`;
`pages = ceil(size / capacity)` where `size = getSize()` (server total across pages) falling back to
`getItemsCount()`; returns nil (check skipped) if the pouch is closed or capacity ≤ 0.

Statistics kept in `vBot.CaveBotData` (`refills`, `rounds`, `time[]`, `refillTime[]`, `lastRefill`) —
telemetry only.

### 4.2 Supply configuration data

Persisted at `<P>/vBot_configs/profile_<N>/Supplies.json` (`vBot/configs.lua:26-27,63-96`).
**REAL file on disk:**

```json
{"supplies":{"Default":{"capSwitch":true,"lootPouchValue":"50","lootPouchSwitch":true,"capValue":"200","items":{"23374":{"avg":0,"min":200,"max":1200},"3097":{"avg":0,"min":1,"max":5}}},"currentProfile":"Default"}}
```

Shape: `supplies.currentProfile` names the active sub-profile; `supplies[<profile>]` holds
`items = { ["<itemId>"] = {min=<number>, max=<number>, avg=<number>} }` plus the boolean/threshold
switches `capSwitch/capValue`, `staminaSwitch/staminaValue`, `SoftBoots`, `imbues`,
`lootPouchSwitch/lootPouchValue`. **Threshold values are stored as STRINGS** — always `tonumber()`.
Missing keys are simply absent (falsy).

Semantics (`vBot/supplies.lua:396-497`):
* `Supplies.hasEnough()` → `true`, or the first `{id, amount}` whose `itemAmount(id) < min`.
* `Supplies.getAdditionalData()` → `{stamina={enabled,value}, capacity={enabled,value},
  softBoots={enabled}, imbues={enabled}, lootPouch={enabled,value}}`.
* `itemAmount(id, tier)` = `max(player:getItemsCount(id) over equipped+open containers,
  player:getInventoryCount(id, tier or 0) reported by the server)` — so **closed backpacks count**
  (`vBot/vlib.lua:822-888`).

**[WIDGET]** the panel reads/writes the live widget list; a headless client reads the JSON directly.

### 4.3 `buysupplies` — refilling at the shop

`buy_supplies.lua:14-99`. Value `NpcName[,delayMs]`. Constants: `BATCH_SIZE = 100` (NPC per-trade
limit), `STUCK_ROUNDS = 50` (consecutive *no-progress* rounds), `MAX_ROUNDS = 2000` (absolute).

```
retries == 0 -> noProgress = 0
npc = getCreatureByName(name); not found -> print, false
optional delay(delayMs)
noProgress > 50 or retries > 2000 -> print, false
not CaveBot.ReachNPC(name) -> noProgress++, "retry"
not NPC.isTrading() -> CaveBot.OpenNpcTrade(); CaveBot.delay(talkDelay*2); noProgress++, "retry"
possibleItems = ids offered by the NPC's buy list
for each configured supply id present in that list:
    toBuy = min(100, max - itemAmount(id))
    if toBuy > 0: NPC.buy(id, toBuy); noProgress = 0; "retry"
nothing left to buy -> true
```
The `noProgress`/`retries` split is deliberate: a successful 100-item batch is *progress*, so a 12 000
item order is not capped by the stuck detector.

`CaveBot.OpenNpcTrade()` = `Conversation("hi","trade")` (`new_cavebot_lib.lua:566-568`).

### 4.4 `sellall`

`sell_all.lua:5-81`. Value `NpcName[,yes][,exceptionId…]`; `yes` anywhere in the list means "sell with
delay".

```
npc not found -> false;  retries > 10 -> false
freecap() == sellAllCap  -> sellAllCap = 0; true      (capacity stopped changing = nothing left)
delay(800)
not ReachNPC -> "retry"
not NPC.isTrading() -> OpenNpcTrade(); delay(talkDelay*2); "retry"
else sellAllCap = freecap()
exceptions = value ids  ∪  modules.game_npctrade.getSellExceptions()  ∪  storage.cavebotSell
modules.game_npctrade.sellAll(wait, exceptions)
"retry"
```
`storage.cavebotSell` in the real profile: `[3048, 21183, 3097, 22728, 20200, 16131, 9636]`
(bot storage `<P>/storage/profile_1.json`). Default seed `{23544, 3081}`
(`vBot/depositer_config.lua:128-132`).

### 4.5 `depositor` — depot deposit

`depositor.lua:34-130`. Value `no` (deposit what is open) or `yes` (also reopen nested loot backpacks).

Loot item list is read from the **TargetBot** config, not the cavebot one:
`<P>/targetbot_configs/<selected>.json` → `looting.items[].id` (`new_cavebot_lib.lua:25-33,77-88`),
containers from `looting.containers[].id`.

```
loot list empty -> print, resetCache, true
delay(70)
value == "yes":
    first pass: CloseAllLootContainers(); delay(3000); "retry"
    then, if no loot items visible: open the next nested container of a loot-container id
        (g_game.open(item, container); delay(100); "retry")
        no more -> CloseAllLootContainers(); delay(3000); resetCache; true
retries == 0 and not HasLootItems() -> print, resetCache, true
retries > 400 -> print, resetCache, true
not CaveBot.ReachAndOpenDepot() -> "retry"
CaveBot.PingDelay(2)
destination = getContainerByName("Depot chest")   (nil -> "retry")
for every open container whose name lacks "depot" and "your inbox":
    first item whose id is in the loot list:
        index = getStashingIndex(id)  or  (item:isStackable() and 1 or 0)
        g_game.move(item, destination:getSlotPosition(index), item:getCount())
        "retry"
nothing left -> resetCache, true
```

`resetCache()` also closes every open container named `depot*`/`locker*` and consumes the
`backStop`/`backTrainers`/`backOffline` flags — turning CaveBot off, or jumping to `toTrainers` /
`toOfflineTraining` (`depositor.lua:8-29`).

`getStashingIndex(id)` (`vBot/depositer_config.lua:117-123`) reads `storage.specialDeposit.items` =
`[{id=<itemId>, index=<1-based depot box>}, …]` and returns `index-1`. Real profile has
`{"items": [], "height": 0}` (empty).

**Depot reach/open primitives** (`new_cavebot_lib.lua:307-496`):
* `LOCKERS_LIST = {3497, 3498, 3499, 3500}`; access-tile offsets
  `3497 → (0,-1)`, `3498 → (1,0)`, `3499 → (0,1)`, `3500 → (-1,0)`.
* `ReachDepot()`: refuses to evaluate anything while walking/prewalking (`delay(50)`, false). If any of
  the 8 neighbouring tiles already holds a locker id → true. Otherwise scan all tiles on the floor for
  locker items, require the computed access tile to be creature-free and
  `findPath(pos, lockerPos, 20, {ignoreNonPathable=false, precision=1, ignoreCreatures=true})` to
  succeed, pick the nearest, then `CaveBot.PreciseGoTo(target, 1)`; give the target up after 20 reach
  retries.
* `OpenLocker()`: if a `Locker` container is not open, `g_game.open` the locker item on an adjacent
  tile (moving the top thing aside first if it is movable).
* `OpenDepotChest()`: open item **3502** inside `Locker`. `OpenInbox()`: item **12902**.
* `OpenDepotBox(index)`: `g_game.open` the `index`-th item of `Depot chest`; short-circuits to true if a
  `depot box` container is already open.
* `ReachAndOpenDepot() = ReachDepot() and OpenDepotChest()`.
* `PreciseGoTo(position, precision)` (`new_cavebot_lib.lua:242-279`): long range → normal
  `walkTo(pos, 20, {ignoreCreatures=true, precision})`; within 3 tiles → wait out any in-flight step
  (`delay(50)`), then send exactly **one** step and `delay(stepDuration + ping + 50)` — the same
  overshoot-proof approach the precision `goto` uses.
* `GoTo(position, precision=3) = walkTo(position, 20, {ignoreCreatures = true, precision})`.

### 4.6 `stowdeposit` — supply-stash first, depot second

`depositor.lua:168-285`. Same preamble as `depositor`. Then two passes:

* **PASS 1** — for every loot item in an open non-depot/non-inbox container that `canStow(item)`
  (client ≥ 1410, `player:isSupplyStashAvailable()`, `item:isPickupable()`, tier ≤ 0):
  `g_game.stashStowItem(item:getPosition(), id, 0, item:getStackPos(), 2)` (action 2 = "stow all items
  of this type"), `delay(200)`, `"retry"`. After **3** attempts on the same id without it disappearing,
  the id is added to `stowFallback` and handled by pass 2.
* **PASS 2** — identical to the plain depositor's depot-box move.

### 4.7 `bank`

`bank.lua:6-78`. Value: `deposit,NPC` | `withdraw,NPC,amount` | `transfer,NPC,targetName,balanceLeft`.

```
field count must be 2, 3 or 4; type must be withdraw|deposit|transfer
retries > 5 -> print, false
npc not found -> print, false
not ReachNPC -> "retry"
deposit  : Conversation("hi","deposit all","yes");  CaveBot.delay(talkDelay*3); true
withdraw : Conversation("hi","withdraw", amount, "yes"); CaveBot.delay(talkDelay*4); true
transfer : Conversation("hi","balance"); schedule(5000, function()
               amountToTransfer = balance - balanceLeft
               if <= 0: warn, abort
               Conversation("hi","transfer", amountToTransfer, targetName, "yes")
           end); CaveBot.delay(talkDelay*11); true
```
`balance` is scraped from an NPC talk with `mode == 51` containing `"Your account balance is"`
(`bank.lua:87-91`).

### 4.8 `travel`

`travel.lua:4-33`. `retries > 5` → false; npc not found → false; `ReachNPC` → retry; then
`CaveBot.Travel(dest)` = `Conversation("hi", dest, "yes")`, `delay(talkDelay*3)`, true.

### 4.9 `imbuing`

`imbuing.lua:616-768`. Value must be the literal `config`. Configuration lives in bot storage
`storage.autoImbue = { useProtection=<bool>, items = { ["<itemId>"] = { slotPicks = { ["<slotIndex>"] =
{id=,name=} }, minSeconds=<default 3600> } }, seen={}, catalog={} }`.

Flow: build the work list from configured items that are actually found on the character; nothing
configured → true. On `retries == 0` reset run state and turn the equipment manager off. `retries > 150`
→ close the imbuing window, false. Pick the first item whose tracker data says a slot is empty, holds
the wrong imbuement, or has `duration < minSeconds`; all fresh → true. Find a shrine
(`{25060, 25061, 25182, 25183}`) on the current floor; none → false. `CaveBot.GoTo(shrinePos, 1)` until
within 1 (`CaveBot.delay(300)`, retry). Then: use the shrine (throttle 2000 ms) →
`selectImbuementItem` (throttle 800 ms, `CaveBot.delay(400)`) → per slot `clearImbuement` (delay 700)
and `applyImbuement(slot, id, useProtection)` (delay 900), 700 ms minimum between operations, 600 ms
after finishing an item.

---

## 5. Configuration data (CaveBot Config panel)

Declared in `config.lua:26-59` plus three appended by `walking.lua:31-37`. Values are persisted **inside
the route file** as the `config:` JSON pair, and reloaded through
`CaveBot.Config.onConfigChange` which first restores every default then applies the file
(`config.lua:80-90`).

| key | type | default | used by |
|---|---|---|---|
| `ping` | number | 100 | fallback when `g_game.getPing()` is unusable; added to `useDelay` |
| `walkDelay` | number | 10 | added to every step's delay |
| `mapClick` | bool | false | autowalk instead of single steps |
| `mapClickDelay` | number | 100 | delay after an autowalk |
| `ignoreFields` | bool | false | skip the "respect fields" walkTo attempt (goto step 8) |
| `skipBlocked` | bool | false | skip a plain goto as soon as everything failed once |
| `useDelay` | number | 400 | delay after `use`/`usewith` (plus `ping`) |
| `wptDistance` | number | 5 | recorder waypoint density |
| `antiLostEnabled` | bool | true | anti-lost master switch |
| `antiLostTeleportIds` | string CSV | `1949,1950,1951,1952` | teleport recovery |
| `antiLostLadderIds` | string CSV | 26 ids (see §1.4) | ladder/grate recovery |
| `antiLostRopeIds` | string CSV | `386,7762,12935,12936,13381,33051` | rope-spot recovery |
| `antiLostRopeToolId` | item id (number in JSON) | 3003 | `usewith` tool for rope spots |
| `stayPathEnabled` | bool | true | §2.4 |
| `waypointHud` | bool | false | **[WIDGET]** |
| `smoothWalk` | bool | false | ping-synced walking |
| `avoidFloorChange` | bool | true | §3.4 |
| `avoidTileIds` | string CSV | `""` | extra floor-change tile ids |

Empty CSV strings fall back to the built-in defaults inside anti-lost (`antilost.lua:41-59`), so
`""` does **not** disable a recovery mode.

Global knobs read from bot storage `<P>/storage/profile_<N>.json` (real values from disk):
`extras.gotoMaxDistance = 64`, `extras.pathfinding = true`, `extras.talkDelay = 1000`,
`extras.huntRoutes = 300`, `extras.machete = 9596`, `extras.killUnder = 1`, plus
`caveBot = {backStop, backOffline, backTrainers, forceRefill}` (all false) and
`cavebotSell = [3048,21183,3097,22728,20200,16131,9636]`.

---

## 6. Timing table (everything that makes it look human)

| moment | delay | evidence |
|---|---|---|
| main loop period | 50 ms (declared 20, floored by `macro`) | `cavebot.lua:80`, `main.lua:37-40` |
| per walking step | `walkDelay + stepDuration(dir)` | `walking.lua:329,500` |
| map-click walk (stock) | `mapClickDelay + 50` | `walking.lua:489` |
| map-click walk (smooth) | `mapClickDelay` | `walking.lua:460` |
| smooth: min gap between sends | 50 ms; window `min(3, 1+ceil(ping/step))` | `walking.lua:246-248,291` |
| smooth: refused walk | 25 ms | `walking.lua:299` |
| smooth: watchdog | `ping + 2*step + 400` then `stop()` + 100 ms | `walking.lua:275-283` |
| smooth: dest change mid-autowalk | `100 + ceil(ping/2)` | `walking.lua:393` |
| smooth: pathfind fail with pending | 50 ms | `walking.lua:405-408` |
| goto final approach, step in flight | 50 ms | `actions.lua:415` |
| goto final approach, after a step | `stepDuration + ping + 50` | `actions.lua:425` |
| goto blocked by monster | 100 ms | `actions.lua:479` |
| goto precision tile temporarily occupied | 200 ms | `actions.lua:492` |
| goto after breaking furniture | 1000 ms | `actions.lua:439` |
| goto last-resort back-off | `min(100 + retries*50, 500)` | `actions.lua:540` |
| after `use` / `usewith` | `useDelay + ping` = 500 ms default | `actions.lua:578,615` |
| `follow` retry | 200 ms | `actions.lua:320` |
| `exanihur` per cast | 1000 ms, ≤ 20 casts | `route_tools.lua:126,173` |
| `forge` per action | 800 ms, ≤ 50 | `route_tools.lua:87` |
| `opendoors` retry | 200 ms, ≤ 5 | `doors.lua:38,42,15` |
| `cleartile` retry | 1100 ms after the first, ≤ 20 | `clear_tile.lua:58-60,25` |
| Stay Path insist window | 3000 ms without improvement, then fail open; warn ≤ 1/3 s | `cavebot.lua:8,144,146` |
| NPC conversation | one phrase per `storage.extras.talkDelay` (1000 ms), scheduled | `new_cavebot_lib.lua:552-561` |
| after `bank deposit / withdraw / transfer` | `talkDelay * 3 / 4 / 11` (+ a 5 s scheduled balance read) | `bank.lua:57,61,66,75` |
| after `travel` | `talkDelay * 3` | `travel.lua:30` |
| after opening a trade window | `talkDelay * 2` | `buy_supplies.lua:65`, `sell_all.lua:45` |
| `sellall` per round | 800 ms | `sell_all.lua:38` |
| depositor per round | 70 ms; 3000 ms after closing loot containers; 100 ms after opening one | `depositor.lua:50,56,69` |
| high-ping padding `PingDelay(m)` | if `ping > 150`: `delay(min(ping*m, 2000))` | `new_cavebot_lib.lua:142-148` |
| stow one id | 200 ms | `depositor.lua:252` |
| anti-lost macro / freeze | 200 ms period, `CaveBot.delay(1500)` per pass | `antilost.lua:6-7,589,598` |
| imbuing ops | 200/300/400/500/600/700/900/2000 ms, ≤ 150 retries | `imbuing.lua:646,691,699,714,729,741,755,760,766` |

Retry ceilings, one place: `goto` 5 (map-click) / 100; `opendoors` 5; `bank` 5; `travel` 5; `sellall` 10;
`cleartile` 20; `exanihur` 20; `rushlure` 50; `buysupplies` 50 no-progress / 2000 absolute; `withdraw`
100; `imbuing` 150; `inwithdraw` 400; `depositor`/`stowdeposit` 400; `dpwithdraw` 600; `poscheck`
10 (configurable, `inf` allowed); anti-lost 200 per target and 4 floor changes per recovery.


## Configuration format

## A. Route file — `<profile>/cavebot_configs/<name>.cfg`

Ordered `key:value` text pairs, one per line; multi-line values wrapped in `[[` … `]]`.
Key ≤ 20 chars, contains no `:` and no newline. Lines with an empty value are dropped on load.
Three reserved trailing keys: `config`, `extensions`, `staypositions`.

### REAL complete file — `D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/cavebot_configs/test.cfg`

```
goto:33218,32434,7,0
exanihur:up,north
exanihur:down,south
config:{"ignoreFields":false,"skipBlocked":false,"antiLostLadderIds":"1948,1968,5542,7771,9116,20474,20475,21365,28656,31129,31130,31262,33770,34243,35908,43374,48493,48494,50122,50123,50564,50565,435,7750,21221,21298","ping":100,"antiLostRopeToolId":9596,"stayPathEnabled":true,"waypointHud":false,"walkDelay":10,"avoidTileIds":"","avoidFloorChange":true,"mapClickDelay":100,"useDelay":400,"wptDistance":5,"antiLostTeleportIds":"1949,1950,1951,1952","mapClick":false,"smoothWalk":false,"antiLostRopeIds":"386,7762,12935,12936,13381,33051","antiLostEnabled":true}
extensions:[]
staypositions:{"3":{"x":33218,"y":32433,"z":6},"2":{"x":33218,"y":32434,"z":7}}
```

`staypositions` keys are **1-based waypoint ordinals** (metadata pairs are not counted). When empty the
Lua JSON encoder writes `[]`, not `{}` — accept both. Same for `extensions`.

### REAL multi-line value + full-featured route (excerpt, `cavebot_configs/true_asura_mk.cfg`)

```
label:start
use:32626,32742,6
buysupplies:Tandros,100
follow:Old Adall
delay:500
travel:Old Adall,east
opendoors:32864,32810,9
function:[[

TargetBot.setOn()


return true



]]
goto:33062,32700,8
supplycheck:hunt,32822,32816,11
label:refill
sellall:Johny The Marketer
npcsay:hi
buysupplies:Johny The Marketer,100
stowdeposit:no
bank:deposit,Ferks
gotolabel:start
config:{"wptDistance":5,"skipBlocked":false,"antiLostEnabled":true,"antiLostTeleportIds":"1949,1950,1951,1952","useDelay":400,"ping":100,"antiLostRopeIds":"386,7762,12935,12936,13381,33051","smoothWalk":false,"antiLostRopeToolId":9596,"avoidFloorChange":true,"stayPathEnabled":true,"avoidTileIds":"21793","waypointHud":false,"walkDelay":30,"mapClick":false,"mapClickDelay":100,"antiLostLadderIds":"1948,...,21298","ignoreFields":true}
extensions:[]
staypositions:{"69":{"x":32629,"y":32743,"z":6},"270":{"x":32582,"y":32763,"z":7},"272":{"x":32582,"y":32763,"z":7},"141":{"x":32822,"y":32816,"z":11},"143":{"x":32629,"y":32743,"z":6}}
```

## B. Which route is active — bot storage `<profile>/storage/profile_<N>.json`

`<N>` = the client `profile` setting. REAL excerpt:

```json
{
  "_configs": {
    "targetbot_configs": { "enabled": false, "selected": "true_asura" },
    "cavebot_configs":   { "enabled": false, "selected": "true_asura_mk" }
  },
  "caveBot": { "backStop": false, "backOffline": false, "backTrainers": false, "forceRefill": false },
  "cavebotSell": [3048, 21183, 3097, 22728, 20200, 16131, 9636],
  "specialDeposit": { "items": [], "height": 0 },
  "extras": {
    "gotoMaxDistance": 64, "pathfinding": true, "talkDelay": 1000, "huntRoutes": 300,
    "machete": 9596, "rope": 9596, "shovel": 9596, "killUnder": 1, "lootDelay": 220,
    "autoOpenDoors": true, "nextBackpack": true, "looting": 40
  }
}
```
`specialDeposit.items` shape when populated: `[{"id": <itemId>, "index": <1-based depot box>}, …]`;
`getStashingIndex` returns `index - 1`.
`storage.autoImbue` shape: `{"useProtection":bool, "items":{"<itemId>":{"slotPicks":{"<slot>":{"id":n,"name":s}},"minSeconds":3600}}, "seen":{}, "catalog":{}}`.

## C. Supplies — `<profile>/vBot_configs/profile_<N>/Supplies.json`

REAL complete file:

```json
{"supplies":{"Default":{"capSwitch":true,"lootPouchValue":"50","lootPouchSwitch":true,"capValue":"200","items":{"23374":{"avg":0,"min":200,"max":1200},"3097":{"avg":0,"min":1,"max":5}}},"currentProfile":"Default"}}
```

Keys: `supplies.currentProfile` → sub-profile name; `supplies[<name>].items["<itemId>"] = {min,max,avg}`
(`min` triggers a refill, `max` is the buy-up-to target, `avg` is the per-round consumption estimate the
+/- buttons use); optional `capSwitch/capValue`, `staminaSwitch/staminaValue`, `SoftBoots`, `imbues`,
`lootPouchSwitch/lootPouchValue`. **`capValue`, `staminaValue`, `lootPouchValue` are strings.**

## D. Loot list (used by depositor/stowdeposit) — `<profile>/targetbot_configs/<selected>.json`

Read as `Config.parse(file)['looting']` → `.items[] = {id=…}` and `.containers[] = {id=…}`.
The cavebot never has its own loot list.


## Pseudocode

-- =====================================================================
-- CaveBot for luaclient (LuaJIT, no UI).  Uses only LC.* from API.md.
-- =====================================================================
local sched, st, sender, events, log = LC.sched, LC.state, LC.sender, LC.events, LC.log
local now = function() return LC.sys.nowMs() end

local North,East,South,West,NorthEast,SouthEast,SouthWest,NorthWest = 0,1,2,3,4,5,6,7
local D = { [North]={0,-1},[East]={1,0},[South]={0,1},[West]={-1,0},
            [NorthEast]={1,-1},[SouthEast]={1,1},[SouthWest]={-1,1},[NorthWest]={-1,-1} }
local function cheb(a,b) return math.max(math.abs(a.x-b.x), math.abs(a.y-b.y)) end

-- ---------------------------------------------------------------- 1. cfg I/O
-- table.decodeStringPairList, ported verbatim (corelib/table.lua:291)
function parseCfg(text)
  local out, ml, mlKey, mlOn = {}, "", "", false
  for line in (text.."\n"):gmatch("([^\n]*)\n") do
    if mlOn then
      local e = line:find("%]%]")
      if e then
        out[#out+1] = { mlKey, e > 1 and (ml.."\n"..line:sub(1,e-1)) or ml }
        ml, mlKey, mlOn = "", "", false
      else ml = (#ml == 0) and line or (ml.."\n"..line) end
    else
      local k, v = line:match("^([^:\n]?[^:\n]-):(.*)$")   -- key <= 20 chars, no ':'
      if k and #k >= 1 and #k <= 20 then
        if v:sub(1,2) == "[[" then ml, mlKey, mlOn = v:sub(3), k, true
        elseif #k > 0 and #v > 0 then out[#out+1] = { k, v } end
      end
    end
  end
  return out
end

function loadRoute(path)
  local pairsList = parseCfg(io.open(path):read("*a"))
  local route = { wps = {}, cfg = defaultCaveBotConfig() }
  local stay = {}
  for _, kv in ipairs(pairsList) do                     -- PRE-SCAN (cavebot.lua:220)
    if kv[1] == "staypositions" then
      local ok, t = pcall(LC.json.decode, kv[2]); if ok and type(t)=="table" then stay = t end
    end
  end
  local idx = 0
  for _, kv in ipairs(pairsList) do
    local k, v = kv[1], kv[2]
    if k == "config" then
      local ok, t = pcall(LC.json.decode, v)
      if ok then for ck, cv in pairs(t) do route.cfg[ck] = cv end end
    elseif k == "extensions" or k == "staypositions" then -- metadata, not a waypoint
    else
      idx = idx + 1
      local sp = stay[tostring(idx)]
      route.wps[idx] = { action = k:lower(), value = v,
                         stayPos = sp and {x=tonumber(sp.x),y=tonumber(sp.y),z=tonumber(sp.z)} }
    end
  end
  return route
end

-- --------------------------------------------------- 2. tile predicates / path
-- Dijkstra, a direct port of Map::findEveryPath (map.cpp:1316).
-- Everything comes from LC.state; a tile we have never seen is "unseen".
local function tileInfo(p)
  local t = st:tile(p)
  if not t then return { seen = false, notWalkable = true, notPathable = true, color = 0, speed = 1000 } end
  local ground, notWalk, notPath, color, speed, blockingCreature = nil, false, false, 255, 100, false
  for _, thing in ipairs(t.things) do
    if thing.kind == 'creature' then
      local c = st:getCreature(thing.creatureId)
      if c and not c.passable and c.id ~= st.player.id then blockingCreature = true end
    else
      local f = LC.itemflags(thing.id)                      -- notWalkable / notPathable / ground / speed
      if f.isGround then ground = thing.id; speed = f.groundSpeed or 100; color = f.minimapColor or color end
      if f.notWalkable then notWalk = true end
      if f.notPathable then notPath = true end
      if (not f.isGround) and f.minimapColor and f.minimapColor ~= 0 and color == 255 then color = f.minimapColor end
    end
  end
  if not ground then notWalk = true end                     -- Tile::isWalkable: no ground => not walkable
  return { seen = true, notWalkable = notWalk, notPathable = notPath, color = color,
           speed = speed, creature = blockingCreature }
end

function findPath(startPos, destPos, maxDist, o)
  o = o or {}
  if not destPos or startPos.z ~= destPos.z then return nil end        -- map.lua:159
  maxDist = maxDist or 100
  local key = function(p) return p.x..","..p.y..","..p.z end
  local best, prev, dist, dirTo = { [key(startPos)] = 0 }, {}, { [key(startPos)] = 0 }, {}
  local heap = { { cost = 0, pos = startPos } }             -- use a real binary heap
  local seenSet = {}
  local destK = key(destPos)
  while #heap > 0 do
    local n = heapPop(heap)
    local k = key(n.pos)
    if not seenSet[k] then
      seenSet[k] = true
      if k == destK then break end
      if dist[k] < maxDist then
        for dir, d in pairs(D) do
          local np = { x = n.pos.x + d[1], y = n.pos.y + d[2], z = n.pos.z }
          local nk = key(np)
          if np.x >= 0 and np.y >= 0 and not seenSet[nk] then
            local ti = tileInfo(np)
            local stairs = ti.notPathable and ti.color >= 210 and ti.color <= 213   -- map.cpp:1429
            local blocked =
                 (not ti.seen and not o.allowUnseen)
              or (stairs and not o.ignoreStairs and nk ~= destK)
              or (ti.notPathable and not o.ignoreNonPathable and nk ~= destK)
              or (ti.notWalkable and not o.ignoreNonWalkable)
              or (ti.creature and not o.ignoreCreatures)
            if not blocked then
              local diag = (d[1] ~= 0 and d[2] ~= 0) and 3 or 1        -- playerDiagonalWalkSpeed
              local c = o.ignoreCost and 1 or (ti.speed * diag)
              if best[nk] == nil or n.cost + c < best[nk] then
                best[nk] = n.cost + c; prev[nk] = k; dirTo[nk] = dir
                dist[nk] = dist[k] + 1
                heapPush(heap, { cost = best[nk], pos = np })
              end
            end
          end
        end
      end
    end
  end
  local target = destK
  if best[target] == nil then                                          -- map.lua:194-214
    local prec = o.precision
    if type(prec) ~= 'number' then return nil end
    local found
    for p = 1, prec do
      local bc
      for x = -p, p do for y = -p, p do
        local kk = (destPos.x+x)..","..(destPos.y+y)..","..destPos.z
        if best[kk] and (not bc or best[kk] < best[bc]) then bc = kk end
      end end
      if bc then found = bc break end
    end
    if not found then return nil end
    target = found
  end
  local rev = {}
  while prev[target] do rev[#rev+1] = dirTo[target]; target = prev[target] end
  local out = {}
  for i = #rev, 1, -1 do out[#out+1] = rev[i] end
  return out                                                           -- may be {} when already there
end

-- ------------------------------------------------- 3. floor-change avoidance
local FLOOR_CHANGE_LENSHELP = { [1104] = true, [1105] = true }
local function isFloorChangeTile(p, cfg)
  local ok, bad, why = pcall(function()                                -- FAIL OPEN (walking.lua:132)
    local t = st:tile(p); if not t then return false end
    local ti = tileInfo(p)
    if ti.color >= 210 and ti.color <= 213 and ti.notPathable then return true, "stairs" end
    local g, top = groundOf(t), topUseThingOf(t)
    if g and (FLOOR_CHANGE_LENSHELP[lensHelp(g.id)] or itemIsNotPathable(g.id)) then return true, "ground "..g.id end
    if top and top ~= g and FLOOR_CHANGE_LENSHELP[lensHelp(top.id)] then return true, "item "..top.id end
    for _, id in ipairs(cfg.avoidIds) do
      if (g and g.id == id) or (top and top.id == id) then return true, "listed "..id end
    end
    return false
  end)
  if not ok then return false end
  return bad, why
end

local function pathCrossesFloorChange(from, dest, path, cfg)
  local x, y = from.x, from.y
  for i = 1, #path do
    local d = D[path[i]]; if not d then break end
    x, y = x + d[1], y + d[2]
    if not (x == dest.x and y == dest.y) then
      if (isFloorChangeTile({x=x,y=y,z=from.z}, cfg)) then return true end
    end
  end
  return false
end

-- --------------------------------------------------------------- 4. walking
local CB = { nextRunAt = 0, expectedDirs = {}, walkPath = {}, iter = 0,
             pending = {}, pendingAuto = false, lastConfirmAt = 0, lastSendAt = 0, smoothDest = nil }

function CB.delay(ms) CB.nextRunAt = math.max(CB.nextRunAt, now() + ms) end   -- cavebot.lua:563 (MAX)
function CB.setDelay(ms) CB.nextRunAt = now() + ms end                        -- main.lua:206 (OVERWRITE)

local function pingMs(cfg)
  local p = LC.net.pingMs
  if type(p) ~= 'number' or p <= 0 or p > 5000 then p = cfg.ping or 100 end
  return p
end
local function stepMs(dir)
  local groundSpeed = groundSpeedAt(st.player.pos, dir) or 150
  local d = math.ceil((1000 * groundSpeed / st.player.speed) / 50) * 50        -- serverBeat 50
  if D[dir] and D[dir][1] ~= 0 and D[dir][2] ~= 0 then d = d * 3 end
  return math.max(d - 10, 1)
end

function CB.resetWalking(cfg)
  CB.expectedDirs, CB.walkPath, CB.iter = {}, {}, 0
  if cfg.smoothWalk and #CB.pending > 0 then
    sender:stop(); CB.pending, CB.pendingAuto, CB.smoothDest = {}, false, nil
  end
end

-- returns true while a walk is in progress (cavebot tick must then return)
function CB.doWalking(cfg)
  if cfg.smoothWalk then return CB.smoothWalking(cfg) end
  if cfg.mapClick then return false end
  if #CB.expectedDirs == 0 then return false end
  if #CB.expectedDirs >= 3 then CB.resetWalking(cfg) end
  local dir = CB.walkPath[CB.iter]
  if dir then
    sender:walk(dir)
    CB.expectedDirs[#CB.expectedDirs+1] = dir
    CB.iter = CB.iter + 1
    CB.delay(cfg.walkDelay + stepMs(dir))
    return true
  end
  return false
end

function CB.smoothWalking(cfg)
  local nextDir = CB.walkPath[CB.iter]
  if #CB.pending == 0 and not nextDir then return false end
  if #CB.pending > 0 then
    local ref = math.max(CB.lastConfirmAt, CB.pending[1].t)
    if now() - ref > pingMs(cfg) + 2*stepMs(CB.pending[1].dir) + 400 then
      sender:stop(); CB.pending, CB.pendingAuto = {}, false
      CB.walkPath, CB.iter, CB.smoothDest = {}, 0, nil
      CB.delay(100); return false
    end
  end
  if CB.pendingAuto then return true end
  if nextDir then
    local window = math.min(3, 1 + math.ceil(pingMs(cfg) / stepMs(nextDir)))
    if #CB.pending < window and now() - CB.lastSendAt >= 50 then
      if sender:walk(nextDir) then
        CB.pending[#CB.pending+1] = { dir = nextDir, t = now() }
        CB.lastSendAt = now(); CB.iter = CB.iter + 1
        CB.delay(cfg.walkDelay)
      else CB.delay(25) end
    end
  end
  return true
end

-- LC.events.on('positionChange', ...) : confirm / void the ledger  (walking.lua:337)
events.on('positionChange', function(e)
  local newPos, oldPos = e.new, e.old
  local dir = 8
  if newPos.z == oldPos.z and math.abs(newPos.x-oldPos.x) <= 1 and math.abs(newPos.y-oldPos.y) <= 1 then
    local rows = {{NorthWest,North,NorthEast},{West,8,East},{SouthWest,South,SouthEast}}
    local r = rows[newPos.y-oldPos.y+2]; dir = r and (r[newPos.x-oldPos.x+2] or 8) or 8
  end
  if #CB.pending > 0 then
    if dir ~= 8 and CB.pending[1].dir == dir then
      table.remove(CB.pending, 1); CB.lastConfirmAt = now()
      if #CB.pending == 0 then CB.pendingAuto = false end
    else
      CB.pending, CB.pendingAuto, CB.smoothDest = {}, false, nil
      CB.delay(100)                                  -- teleport / push / floor change: re-path
    end
  end
  if CB.expectedDirs[1] == dir then table.remove(CB.expectedDirs, 1) end
end)

function CB.walkTo(dest, maxDist, params, cfg)
  local from = cfg.smoothWalk and projectedPos() or st.player.pos
  local path = findPath(from, dest, maxDist, params)
  if not path or not path[1] then
    if cfg.smoothWalk and #CB.pending > 0 then CB.delay(50); return true end
    return false
  end
  if cfg.avoidFloorChange ~= false and pathCrossesFloorChange(from, dest, path, cfg) then return false end
  if cfg.mapClick then
    local body, sent = sender:autoWalk(path)                 -- clamps to 127 steps
    if not body then return false end
    CB.delay(cfg.mapClickDelay + (cfg.smoothWalk and 0 or 50))
    if cfg.smoothWalk then
      CB.pendingAuto = true; CB.lastConfirmAt = now()
      for i = 1, sent do CB.pending[#CB.pending+1] = { dir = path[i], t = now() } end
    end
    return true
  end
  if cfg.smoothWalk then
    CB.walkPath, CB.iter = path, 1; CB.smoothWalking(cfg); return true
  end
  sender:walk(path[1])
  CB.walkPath, CB.iter, CB.expectedDirs = path, 2, { path[1] }
  CB.delay(cfg.walkDelay + stepMs(path[1]))
  return true
end

-- ----------------------------------------------------------- 5. goto action
local noPath = 0
local function actionGoto(value, retries, route, cfg)
  local x,y,z,prec = value:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+),?%s*(%d?)")
  if not x then log.warn("bad goto: %s", value); return false end
  local marker = (prec ~= nil and prec ~= "")
  local dest = { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
  local precision = tonumber(prec)
  local pp = st.player.pos
  local maxDist = cfg.gotoMaxDistance or 40

  if (cfg.mapClick and not marker) then if retries >= 5   then noPath=noPath+1; pathfinder(); return false end
  else                                  if retries >= 100 then noPath=noPath+1; pathfinder(); return false end end
  if dest.z ~= pp.z then noPath=noPath+1; pathfinder(); return false end
  if math.abs(dest.x-pp.x) + math.abs(dest.y-pp.y) > maxDist then noPath=noPath+1; pathfinder(); return false end

  local color  = minimapColor(dest)
  local stairs = color >= 210 and color <= 213

  if stairs or marker then
    local p = precision or 0
    if math.abs(dest.x-pp.x) <= p and math.abs(dest.y-pp.y) <= p then noPath = 0; return true end
    if cheb(dest, pp) <= 3 then                                 -- FINAL APPROACH, one confirmed step
      if isWalking() then CB.delay(50); return "retry" end
      local sp = findPath(pp, dest, 10, { ignoreNonPathable = true, precision = 0 })
      if sp and sp[1] then
        sender:walk(sp[1])
        CB.delay(stepMs(sp[1]) + pingMs(cfg) + 50)
        return "retry"
      end
    end
  elseif math.abs(dest.x-pp.x) == 0 and math.abs(dest.y-pp.y) <= (precision or 1) then
    noPath = 0; return true
  end

  local path = findPath(pp, dest, maxDist, { ignoreNonPathable=true, precision=1,
                                             ignoreCreatures=true, allowUnseen=true })
  if not path then
    if breakFurniture(dest) then CB.delay(1000); return "retry" end
    noPath = noPath + 1; pathfinder(); return false
  end
  local path2 = findPath(pp, dest, maxDist, { ignoreNonPathable=true, precision=1 })
  if not path2 then
    local found = false
    local np = { x = pp.x, y = pp.y, z = pp.z }        -- NOTE: vBot aliases pp here; do NOT copy that
    for _, dir in ipairs(path) do
      local d = D[dir]; np.x, np.y = np.x + d[1], np.y + d[2]
      local c = firstCreatureAt(np)
      if c and c.isMonster and (c.healthPercent or 0) > 0 and (c.type or 0) < 3 then
        if findPath(pp, c.pos, 7, { ignoreNonPathable=true, precision=1 }) then
          found = true
          if st.player.attacking ~= c.id then
            if cheb(pp, c.pos) > 3 then CB.walkTo(c.pos, 7, {ignoreNonPathable=true, precision=1}, cfg)
            else sender:attack(c.id) end
          end
          sender:setFightMode(nil, 1, nil, nil)         -- chase = 1
          CB.delay(100); break
        end
      end
    end
    if not found then
      if marker or stairs then CB.delay(200); return "retry" end
      return false
    end
  end

  if not cfg.ignoreFields and CB.walkTo(dest, 40, nil, cfg) then return "retry" end
  if CB.walkTo(dest, maxDist, { ignoreNonPathable=true, allowUnseen=true }, cfg) then return "retry" end
  if retries >= 3 then
    local p = (stairs or marker) and 0 or (retries - 1)
    if CB.walkTo(dest, 50, { ignoreNonPathable=true, precision=p, allowUnseen=true }, cfg) then return "retry" end
  end
  if (not cfg.mapClick) and retries >= 5 and not marker and not stairs then
    noPath = noPath + 1; pathfinder(); return false end
  if cfg.skipBlocked and not marker and not stairs then
    noPath = noPath + 1; pathfinder(); return false end
  if not CB.walkTo(dest, maxDist, { ignoreNonPathable=true, precision=1,
                                    ignoreCreatures=true, allowUnseen=true }, cfg) then
    CB.delay(math.min(100 + retries*50, 500))
  end
  return "retry"
end

-- --------------------------------------------------------- 6. the main tick
local S = { index = 1, retries = 0, prevResult = true, positionedBySelfNav = false,
            stayTarget = nil, stayBest = nil, stayBestAt = 0, lastLabel = "" }

local STAY_EXCLUDED = { goto_=true, use=true, usewith=true, label=true, gotolabel=true, delay=true,
  follow=true, walkdelay=true, depositor=true, stowdeposit=true, bank=true, buysupplies=true,
  sellall=true, travel=true, imbuing=true, inwithdraw=true, dpwithdraw=true, withdraw=true,
  cleartile=true, opendoors=true }                          -- key "goto" (renamed here only)
local STAY_SELFNAV = { follow=true, sellall=true, buysupplies=true, bank=true, travel=true,
  depositor=true, stowdeposit=true, withdraw=true, dpwithdraw=true, inwithdraw=true,
  imbuing=true, cleartile=true, opendoors=true }

local function previousRoutePosition(wps, i)
  for j = i-1, math.max(1, i-12), -1 do
    local w = wps[j]; if w then
      if w.action == "goto" or w.action == "use" then
        local a,b,c = w.value:match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
        if a then return {x=tonumber(a),y=tonumber(b),z=tonumber(c)} end
      elseif w.action == "usewith" then
        local _,a,b,c = w.value:match("(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)")
        if a then return {x=tonumber(a),y=tonumber(b),z=tonumber(c)} end
      end
    end
  end
end

sched.every(50, function()
  if not caveBotEnabled then return end
  if now() < CB.nextRunAt then return end                    -- the delay gate (main.lua:114)

  if TargetBot.isActive() and not TargetBot.isCaveBotActionAllowed() then
    CB.resetWalking(route.cfg); return
  end
  if CB.doWalking(route.cfg) then return end

  local wps = route.wps
  if #wps == 0 then return end
  if S.index < 1 or S.index > #wps then S.index = 1 end
  local w = wps[S.index]

  -- ---- Stay Path pre-walk (cavebot.lua:108)
  if route.cfg.stayPathEnabled and w.stayPos and not S.positionedBySelfNav
     and not STAY_EXCLUDED[w.action == "goto" and "goto_" or w.action] then
    local sp, pp = w.stayPos, st.player.pos
    local ref = previousRoutePosition(wps, S.index)
    local drift = ref and math.max(math.abs(ref.x-sp.x), math.abs(ref.y-sp.y)) or 0
    local stale = ref ~= nil and (ref.z ~= sp.z or drift > 15)
    if stale then S.stayTarget = nil
    elseif pp.z == sp.z and (math.abs(pp.x-sp.x) > 2 or math.abs(pp.y-sp.y) > 2) then
      local d = cheb(pp, sp)
      if S.stayTarget ~= w then S.stayTarget, S.stayBest, S.stayBestAt = w, d, now()
      elseif d < (S.stayBest or d) then S.stayBest, S.stayBestAt = d, now() end
      if now() - (S.stayBestAt or now()) < 3000 then
        CB.walkTo(sp, 40, { ignoreNonPathable = true, precision = 2 }, route.cfg)
        return                                               -- do not run the action yet
      end
      -- 3 s with no progress: FAIL OPEN, fall through
    else S.stayTarget = nil end
  end

  -- ---- dispatch
  local before = S.index
  CB.resetWalking(route.cfg)                                 -- ALWAYS, before the action
  local ok, result = pcall(ACTIONS[w.action] or function() log.warn("Invalid cavebot action: %s", w.action) end,
                           w.value, S.retries, S.prevResult)
  if not ok then log.warn("cavebot action %s: %s", w.action, result); result = nil end

  if result == "retry" then S.retries = S.retries + 1; return end
  if type(result) == 'boolean' then
    S.retries, S.prevResult = 0, result
    if w.action == "goto" then S.positionedBySelfNav = false
    elseif result == true and STAY_SELFNAV[w.action] then S.positionedBySelfNav = true end
  end
  if S.index ~= before then S.retries, S.prevResult = 0, true end   -- gotoLabel jumped us
  S.index = S.index + 1
  if S.index > #wps then S.index = 1 end
end)

-- ------------------------------------------------------------ 7. anti-lost
local AL = { recovering=false, mode=nil, fallSpot=nil, tpId=nil, target=nil,
             attempts={}, recentFalls={}, floorChanges=0 }

events.on('positionChange', function(e)
  if e.new.z == e.old.z then return end
  if not caveBotEnabled or not route.cfg.antiLostEnabled then return end
  if AL.recovering then
    AL.target = nil; AL.floorChanges = AL.floorChanges + 1
    if AL.floorChanges > 4 then giveUpToCaveBot() end
    return
  end
  if isExpectedFloorChange(e.new.z, e.old) then return end            -- see spec §3.6
  local k = e.old.x..","..e.old.y..","..e.old.z..">"..e.new.z
  local last = AL.recentFalls[k]; AL.recentFalls[k] = now()
  if last and now() - last < 60000 then return end                    -- bounce guard
  local topId = topUseIdAt(e.old)
  AL.fallSpot = { x=e.old.x, y=e.old.y, z=e.old.z }
  AL.recovering, AL.target, AL.attempts, AL.floorChanges = true, nil, {}, 0
  if topId and inList(route.cfg.antiLostTeleportIds, topId) then AL.mode, AL.tpId = "teleport", topId
  else AL.mode, AL.tpId = "stairs", nil end
  CB.delay(1500)
end)

sched.every(200, function()
  if not caveBotEnabled or not route.cfg.antiLostEnabled then AL.recovering = false; return end
  if not AL.recovering then return end
  local pp = st.player.pos
  CB.delay(1500)                                                     -- freeze the cavebot
  if isBackOnTrack(pp) then AL.recovering = false; return end
  if AL.fallSpot and pp.z == AL.fallSpot.z then giveUpToCaveBot(); return end
  if AL.mode == "teleport" then handleTeleportRecovery(pp) else handleStairsRecovery(pp) end
end)

-- handleStairsRecovery: target = {fallSpot.x, fallSpot.y, pp.z} when it is a recovery tile
-- (yellow 210..213 OR its top-use id is in antiLostLadderIds/antiLostRopeIds), else the nearest
-- recovery tile within radius 2 of that point.  cheb > 1 -> walkTo(target,30,{precision=0});
-- adjacent -> ladder list => use(); rope list => useWith(antiLostRopeToolId, tile);
-- else isUsable => use(); else plain hole: step onto a walkable neighbour first when dist==0.
-- 200 attempts per target, then giveUpToCaveBot().

-- ------------------------------------------------------------ 8. supplies
function supplyCheck(value)
  local d = split(value, ",")
  local label = trim(d[1])
  local pos = (#d == 4) and { x=tonumber(d[2]), y=tonumber(d[3]), z=tonumber(d[4]) } or nil
  if pos then
    if missedChecks >= 4 then missedChecks, supplyRetries = 0, 0; return true end
    if cheb(st.player.pos, pos) > 10 or st.player.pos.z ~= pos.z then
      missedChecks = missedChecks + 1; return gotoLabel(label)
    end
  end
  local S = supplies                                  -- parsed Supplies.json for currentProfile
  if storage.caveBot.forceRefill then storage.caveBot.forceRefill = false; return false end
  if storage.caveBot.backStop or storage.caveBot.backTrainers or storage.caveBot.backOffline then return false end
  if (extras.huntRoutes or 0) ~= 0 and supplyRetries > extras.huntRoutes then return false end
  if S.imbues and skillLevel(11) == 0 then return false end
  if S.staminaSwitch and st.player.stamina < tonumber(S.staminaValue) then return false end
  if S.SoftBoots and (itemAmount(6529) + itemAmount(3549)) < 1 then return false end
  for idStr, v in pairs(S.items) do
    if itemAmount(tonumber(idStr)) < v.min then return false end      -- Supplies.hasEnough()
  end
  if S.capSwitch and st.player.capacity < tonumber(S.capValue) then return false end
  if S.lootPouchSwitch and lootPouchPages() and lootPouchPages() >= tonumber(S.lootPouchValue) then return false end
  supplyRetries = supplyRetries + 1
  return gotoLabel(label)                                             -- keep hunting
end

function buySupplies(value, retries)
  local d = split(value, ",")
  local npcName, waitMs = trim(d[1]), d[2] and tonumber(trim(d[2]))
  if retries == 0 then noProgress = 0 end
  local npc = creatureByName(npcName); if not npc then noProgress = 0; return false end
  if waitMs then CB.setDelay(waitMs) end
  if noProgress > 50 or retries > 2000 then noProgress = 0; return false end
  if not reachNPC(npcName) then noProgress = noProgress + 1; return "retry" end
  if not npcTradeOpen then
    say("hi"); after(extras.talkDelay, function() say("trade") end)   -- Conversation("hi","trade")
    CB.delay(extras.talkDelay * 2); noProgress = noProgress + 1; return "retry"
  end
  for idStr, v in pairs(supplies.items) do
    local id = tonumber(idStr)
    if npcSells(id) then
      local toBuy = math.min(100, v.max - itemAmount(id))
      if toBuy > 0 then sender:buyItem(id, 0, toBuy, false, false); noProgress = 0; return "retry" end
    end
  end
  noProgress = 0; return true
end

-- reachNPC(name): find the npc among st.creatures on our floor; if cheb(player,npc) <= 3 -> true,
-- else CB.walkTo(npc.pos, 20, {ignoreCreatures=true, precision=3}) and return nil (=> caller "retry").
-- reachDepot(): if any of the 8 neighbours holds item 3497/3498/3499/3500 -> true; else pick the
-- nearest locker tile on this floor whose access tile ((0,-1)/(1,0)/(0,1)/(-1,0) by locker id) is
-- creature-free and reachable with findPath(...,20,{precision=1,ignoreCreatures=true}), then
-- preciseGoTo(target,1); drop the target after 20 tries.
-- openDepotChest(): open item 3502 inside the "Locker" container; inbox is item 12902.
-- depositor(): move each loot-list item to Depot chest slot getStashingIndex(id)
--              or (stackable and 1 or 0).


## Evidence
- <P>/cavebot/cavebot.lua:80-203 — the whole main loop: TargetBot gate, doWalking gate, Stay Path pre-walk, pcall dispatch, retry/boolean handling, index advance with wrap
- <P>/cavebot/cavebot.lua:8 — STAYPATH_STUCK_MS = 3000
- <P>/cavebot/cavebot.lua:17-22 — STAYPATH_SELF_NAV list + CaveBot.positionedBySelfNav
- <P>/cavebot/cavebot.lua:34 — STAYPATH_MAX_DRIFT = 15
- <P>/cavebot/cavebot.lua:37-56 — previousRoutePosition(): 12-row lookback over goto/node/use/usewith
- <P>/cavebot/cavebot.lua:108-156 — Stay Path gate: staleness, >2 tile tolerance, walkTo(sp,40,{precision=2}), 3 s fail-open, 3 s warn throttle
- <P>/cavebot/cavebot.lua:163 — CaveBot.resetWalking() before every action callback
- <P>/cavebot/cavebot.lua:173-177 — positionedBySelfNav latch set/cleared
- <P>/cavebot/cavebot.lua:192-202 — focus re-read after action, +1 advance with wrap to 1
- <P>/cavebot/cavebot.lua:207-290 — config loader: staypositions pre-scan, actionIndex counting, metadata keys
- <P>/cavebot/cavebot.lua:344-346 — CaveBot.getCurrentProfile() = storage._configs.cavebot_configs.selected
- <P>/cavebot/cavebot.lua:352-401 — gotoNextWaypointInRange(): forward then wrap scan, z match, gotoMaxDistance, findPath, focus index-1
- <P>/cavebot/cavebot.lua:422-455 — gotoFirstPreviousReachableWaypoint(): 100 rows back, gotoMaxDistance/2
- <P>/cavebot/cavebot.lua:563-565 — CaveBot.delay uses math.max
- <P>/cavebot/cavebot.lua:567-576 — gotoLabel(): case-insensitive, focuses the label row
- <P>/cavebot/cavebot.lua:578-610 — CaveBot.save(): config, extensions, staypositions ordering; stayPositions keyed by 1-based actionIndex
- <P>/cavebot/actions.lua:10-37 — modPos(): direction ints 0..7
- <P>/cavebot/actions.lua:41-67 — 'There is not enough room.' antistuck: >9 items, useWith(3197) outside PZ, 200 ms throttle
- <P>/cavebot/actions.lua:69-101 — breakFurniture(): magic wall 2130, ignore {2986}, reachable within 7, useWith(3197)
- <P>/cavebot/actions.lua:103-117 — pushPlayer(): refuses minimap 210-213 tiles (dead code)
- <P>/cavebot/actions.lua:119-134 — pathfinder(): storage.extras.pathfinding, noPath>=10, profile toggle #Unibase
- <P>/cavebot/actions.lua:139-175 — STAYPATH_EXCLUDED_ACTIONS full list; exported as CaveBot.StayPathExcluded
- <P>/cavebot/actions.lua:185-228 — addAction(): lowercase, stayPos capture rule, isLoading
- <P>/cavebot/actions.lua:253-270 — registerAction contract: true/false/'retry'
- <P>/cavebot/actions.lua:272-343 — label, gotolabel, delay (randomness formula), follow (<2 cancelFollow, 200 ms), function (prefix injection)
- <P>/cavebot/actions.lua:345-543 — goto: precision marker, retry ceilings 5/100, manhattan gotoMaxDistance, stairs 210-213, final approach, both findPath passes, monster unclog, walkTo ladder, skipBlocked, back-off min(100+retries*50,500)
- <P>/cavebot/actions.lua:545-617 — use / usewith: z guard, Chebyshev>7 guard, topUseThing, delay useDelay+ping
- <P>/cavebot/actions.lua:619-627 — say / npcsay
- <P>/cavebot/walking.lua:31-37 — Config.setup wrapper adds smoothWalk / avoidFloorChange / avoidTileIds
- <P>/cavebot/walking.lua:43-52 — dirDelta table
- <P>/cavebot/walking.lua:78-207 — floor-change avoidance: lenshelp 1104/1105 only, ground notPathable, avoidTileIds, yellow+notPathable, pcall fail-open, destination exemption, 10 s log throttle
- <P>/cavebot/walking.lua:209-223 — pingMs() and stepMs() fallbacks (100 / 200)
- <P>/cavebot/walking.lua:246-248 — sendWindow = min(3, 1+ceil(ping/step))
- <P>/cavebot/walking.lua:250-262 — resetWalking + g_game.stop() in smooth mode
- <P>/cavebot/walking.lua:265-305 — smoothWalking pacer: watchdog ping+2*step+400, 50 ms gap, delay 25 on refusal
- <P>/cavebot/walking.lua:307-333 — doWalking: mapClick short-circuit, >=3 expectedDirs reset, walkDelay+stepDuration
- <P>/cavebot/walking.lua:337-378 — onPlayerPositionChange ledger confirm/void
- <P>/cavebot/walking.lua:382-469 — smoothWalkTo: projectedPos, autowalk stacking guard, stair truncation, mapClickDelay
- <P>/cavebot/walking.lua:471-502 — stock walkTo: findPath, floor-change filter, g_game.walk(dir,false), mapClickDelay+50
- <P>/cavebot/config.lua:26-59 — every Config key and default value
- <P>/cavebot/config.lua:80-90 — onConfigChange restores defaults then applies file data
- <P>/cavebot/config.lua:92-94 — Config.save() returns the raw values table
- <P>/cavebot/antilost.lua:5-11 — GIVE_UP_ATTEMPTS 200, RETRY_DELAY 200, RECOVERY_FREEZE_MS 1500, colours 210-213, radii 2 / 6
- <P>/cavebot/antilost.lua:41-59 — DEFAULT_ID_LISTS + parseIdList fallback when the config string is empty
- <P>/cavebot/antilost.lua:80-103 — isStairsColorTile / isKnownHoleTile / isRecoveryTile
- <P>/cavebot/antilost.lua:149-151 — REPEAT_FALL_WINDOW_MS 60000, MAX_FLOOR_CHANGES_PER_RECOVERY 4
- <P>/cavebot/antilost.lua:192-241 — isBackOnTrack: per-action position source, findPath tolerances
- <P>/cavebot/antilost.lua:275-361 — DELIBERATE_ACTIONS {use,usewith,exanihur}, explainsFloorChange, LOOKAHEAD 6
- <P>/cavebot/antilost.lua:363-432 — the trigger, bounce guard, teleport vs stairs classification, CaveBot.delay(1500)
- <P>/cavebot/antilost.lua:434-475 — teleport recovery (radius 6, pair by item id)
- <P>/cavebot/antilost.lua:493-586 — stairs recovery: exact fallSpot only, radius 2, ladder->use / rope->usewith / usable->use / plain hole step-off ordering
- <P>/cavebot/antilost.lua:588-620 — the 200 ms macro and give-up conditions
- <P>/cavebot/supply_check.lua:39-57 — lootPouchPages(): ceil(size/capacity), 'loot pouch' only
- <P>/cavebot/supply_check.lua:60-157 — position guard (>10, 5 tries) and the full refill cascade in order
- <P>/cavebot/buy_supplies.lua:14-99 — BATCH_SIZE 100, STUCK_ROUNDS 50, MAX_ROUNDS 2000, buy loop against Supplies.getItemsData()
- <P>/cavebot/sell_all.lua:5-81 — freecap()==sellAllCap termination, delay 800, exception merging
- <P>/cavebot/depositor.lua:8-29 — resetCache: closes depot/locker, consumes backStop/backTrainers/backOffline
- <P>/cavebot/depositor.lua:34-130 — depositor flow, retries>400, PingDelay(2), getStashingIndex fallback
- <P>/cavebot/depositor.lua:160-285 — stowdeposit: canStow conditions, stashStowItem action 2, 3 attempts then depot fallback
- <P>/cavebot/bank.lua:6-91 — deposit/withdraw/transfer conversations, talkDelay multipliers 3/4/11, mode 51 balance scrape
- <P>/cavebot/travel.lua:4-33 — retries>5, ReachNPC, CaveBot.Travel
- <P>/cavebot/withdraw.lua:4-49, d_withdraw.lua:4-104, inbox_withdraw.lua:4-84 — the three withdraw variants and their limits (100 / 600 / 400)
- <P>/cavebot/pos_check.lua:6-70 — poscheck value grammar, maxRetries default 10 and 'inf', 'last' branch
- <P>/cavebot/doors.lua:4-57 — opendoors: retries>=5, key id, isWalkable test
- <P>/cavebot/clear_tile.lua:4-125 — cleartile: stand/doors tokens, retries>=20, 1100 ms, push order
- <P>/cavebot/lure.lua:4-28 — start=TargetBot off, stop=on, toggle
- <P>/cavebot/stand_lure.lua:45-186 — rushlure full flow and the deferred TargetBot toggle on focus change
- <P>/cavebot/route_tools.lua:38-57 — walkdelay writes CaveBot.Config walkDelay
- <P>/cavebot/route_tools.lua:60-117 — forge: actions 2/4, count clamp 1..50, 800 ms
- <P>/cavebot/route_tools.lua:126-206 — exanihur: 20 tries, floor-delta success test, re-face, 1000 ms, fallback label
- <P>/cavebot/route_tools.lua:209-248 — turn
- <P>/cavebot/imbuing.lua:22 — SHRINES {25060,25061,25182,25183}
- <P>/cavebot/imbuing.lua:27-53 — storage.autoImbue shape and v1->v2 migration, minSeconds default 3600
- <P>/cavebot/imbuing.lua:616-780 — imbuing action: value must be 'config', retries>150, all the delays
- <P>/cavebot/recorder.lua:29-63 — recording rules incl. the ',0' transfer marker and the in-place upgrade
- <P>/cavebot/editor.lua:87-150 — editor defaults and validation regexes for label/delay/gotolabel/goto/use/usewith/say/follow/npcsay/function [WIDGET]
- <P>/cavebot/tasker.lua:29-177 — tasker markers 1/2/3 and the 'Loot of' kill counter
- <P>/vBot/new_cavebot_lib.lua:17-23 — LOCKERS_LIST and LOCKER_ACCESSTILE_MODIFIERS
- <P>/vBot/new_cavebot_lib.lua:25-33,77-119 — loot list/containers come from the TargetBot json ['looting']
- <P>/vBot/new_cavebot_lib.lua:142-148 — PingDelay: ping>150 -> delay(min(ping*m,2000))
- <P>/vBot/new_cavebot_lib.lua:213-230 — MatchPosition (Chebyshev) and GoTo(pos, precision=3)
- <P>/vBot/new_cavebot_lib.lua:242-279 — PreciseGoTo one-confirmed-step approach
- <P>/vBot/new_cavebot_lib.lua:283-298 — ReachNPC (distance 3)
- <P>/vBot/new_cavebot_lib.lua:309-376 — ReachDepot: prewalk guard, neighbour check, candidate scoring, 20 retries
- <P>/vBot/new_cavebot_lib.lua:380-464 — OpenLocker / OpenDepotChest (3502) / OpenInbox (12902) / OpenDepotBox
- <P>/vBot/new_cavebot_lib.lua:491-543 — StashItem and WithdrawItem (destination container selection filter)
- <P>/vBot/new_cavebot_lib.lua:552-576 — Conversation (talkDelay-spaced schedule), OpenNpcTrade, Travel
- <P>/vBot/supplies.lua:396-497 — Supplies.getItemsData / hasEnough / getAdditionalData
- <P>/vBot/configs.lua:22-27,63-96 — Supplies.json path and vBotConfigSave
- <P>/vBot/depositer_config.lua:11-18,117-123,128-132 — storage.specialDeposit shape, getStashingIndex, default sell exceptions
- <P>/vBot/vlib.lua:165-175 — containerIsFull
- <P>/vBot/vlib.lua:822-888 — itemAmount = max(visible, server-reported)
- <P>/vBot/vlib.lua:1123-1133 — getContainerByName
- <P>/targetbot/target.lua:4,49,113,121,182-188,247-249 — TargetBot 100 ms loop, isActive (lastAction+300), isCaveBotActionAllowed (cavebotAllowance)
- <P>/targetbot/creature_attack.lua:148-159 — allowCaveBot(150) during luring
- mods/game_bot/bot.lua:265-320,531 — storage path /bot/<cfg>/storage/profile_<N>.json, 10 ms host tick
- mods/game_bot/executor.lua:124-126 — getDistanceBetween is Chebyshev
- mods/game_bot/executor.lua:196-220 — macro dispatch and the scheduler
- mods/game_bot/functions/main.lua:37-40 — macro timeout floor of 50 ms
- mods/game_bot/functions/main.lua:114,206-211 — delay gate and delay() overwrite semantics
- mods/game_bot/functions/config.lua:38-111,130-171 — .cfg/.json load/save and storage._configs bookkeeping
- mods/game_bot/functions/map.lua:80-140 — findAllPaths param marshalling and translateAllPathsToPath
- mods/game_bot/functions/map.lua:143-220 — findPath: same-floor requirement, precision ring search, marginMin/Max
- mods/game_bot/functions/map.lua:223-237 — autoWalk(dirs) sends g_game.autoWalk(path,{0,0,0})
- mods/game_bot/functions/player.lua:64-65,161-178,203-207 — walk=smartWalk, turn, use/usewith, attack/follow
- mods/game_bot/functions/npc.lua:5-12,38-53,95-117 — NPC.say (channel 11), getBuyItems, NPC.buy
- modules/corelib/table.lua:269-328 — isStringPairList / encodeStringPairList / decodeStringPairList (the .cfg codec)
- src/client/map.cpp:1316-1473 — findEveryPath Dijkstra, the hasStairs = notPathable && 210<=color<=213 rule, minimap fallback, diagonal cost
- src/client/creature.cpp:1106-1160 — getStepDuration formula, serverBeat rounding, diagonal multiplier, the -10 baseline correction
- src/client/game.cpp:683-711 — autoWalk 127-step protocol limit and follow cancellation
- src/client/gameconfig.h:69,125 — playerDiagonalWalkSpeed = 3
- src/client/game.h:366-367,533 — serverBeat default 50 ms
- src/client/tile.cpp:563-617,708-725,838-844,995-1014 — getGroundSpeed (default 100), getMinimapColorByte, getTopUseThing, isWalkable, hasBlockingCreature, NOT_WALKABLE/NOT_PATHABLE flag derivation
- <P>/cavebot_configs/test.cfg — REAL 3-waypoint route with precision marker, exanihur and staypositions
- <P>/cavebot_configs/true_asura_mk.cfg — REAL production route with every extension type and a multi-line function block
- <P>/cavebot_configs/sell_all.cfg — REAL single-waypoint route showing staypositions with one entry
- <P>/vBot_configs/profile_1/Supplies.json — REAL supplies config on disk
- <P>/storage/profile_1.json — REAL bot storage: _configs, caveBot flags, extras, cavebotSell, specialDeposit

## Pitfalls
- The main loop is NOT 20 ms. `macro()` clamps any timeout below 50 to 50 (functions/main.lua:37-40), so `macro(20, ...)` in cavebot.lua:80 runs every 50 ms. Every 'per tick' budget in the code (retries>=100 on a goto, retries>400 in the depositor) is really 50 ms per attempt.
- `delay(ms)` and `CaveBot.delay(ms)` are different functions with different semantics on the SAME field: `delay` overwrites (`main.lua:210`), `CaveBot.delay` takes the max (`cavebot.lua:564`). Actions mix them freely (depositor uses `delay(70)` then `delay(3000)`; goto uses `CaveBot.delay`). Getting this backwards either stalls the bot for seconds or makes it spam the server.
- Returning `false` from an action does NOT retry it — the loop advances to the next waypoint exactly as it does for `true` (cavebot.lua:188-202). Only the literal string `"retry"` holds position. A 'failed' goto is a SKIPPED goto.
- The plain (non-marker, non-stairs) goto arrival test is asymmetric and almost certainly a vBot bug: `dx == 0 and |dy| <= (precision or 1)` (actions.lua:431). It tolerates one tile of vertical error but zero horizontal error. Reproduce it if you want bit-identical routing; if you 'fix' it to Chebyshev<=1 the bot will cut corners differently from every recorded route.
- `findPath` returns an EMPTY TABLE (truthy), not nil, when start == destination (map.lua:124-139). `if not path` is therefore false and every caller must test `path[1]`. actions.lua:436 tests `if not path` — so 'standing on the destination' silently passes that gate.
- `findPath` hard-refuses when `startPos.z ~= destPos.z` (map.lua:159). Nothing in CaveBot can path across floors; floor changes only ever happen via `use`/`usewith`/`exanihur`/stepping on a marked transfer tile/antilost.
- actions.lua:452-457 aliases the player position table: `nextPos = nextPos or playerPos` then mutates `nextPos.x`. In otclient `player:getPosition()` returns a fresh table each call so it is merely confusing; in luaclient `st.player.pos` is a LIVE table — copying this pattern would corrupt the player position. Always deep-copy.
- `CaveBot.ReachNPC(name)` dereferences `npc:getPosition()` without a nil check (new_cavebot_lib.lua:293). It only survives because every caller does `getCreatureByName(name)` first — and `getCreatureByName` is same-floor-only by default (functions/map.lua:52-64).
- `CaveBot.ReachDepot()` indexes `candidates[1].pos` unguarded (new_cavebot_lib.lua:363). With no reachable locker on the floor this throws, the pcall in cavebot.lua:162 catches it, and the depositor waypoint just warns forever until retries>400.
- Yellow minimap colour ALONE never means 'floor change'. Both the C++ pathfinder (map.cpp:1429) and walking.lua:142 require yellow AND not-pathable, because staircases are painted over several yellow tiles of which only one transfers. An earlier version blocked all yellow tiles and the bot stopped at the foot of every staircase.
- Anti-lost must never widen its search: it returns ONLY through the exact fall spot (± 2 tiles, antilost.lua:493-511). A wider search finds a different hole and teleports the character somewhere else entirely.
- An empty CSV config string does NOT disable an anti-lost mode — `parseIdList` substitutes the built-in default list (antilost.lua:48-52). Only removing ids you do not want has an effect.
- A `.cfg` line whose value is empty is dropped by the decoder (`table.lua:322`). `CaveBot.addAction` guards the widget text against it (actions.lua:197) because such a node would otherwise 'disappear' on the next reload. Never emit `key:` with nothing after the colon.
- `staypositions` keys are 1-based WAYPOINT ordinals, not file line numbers — the multi-line `function:[[ ... ]]` block occupies many lines but exactly one ordinal (cavebot.lua:266-272). Editing a route by hand renumbers every subsequent stayPos.
- Stay Path silently ignores a saved position that is >15 tiles or on another floor from the nearest preceding positional waypoint (cavebot.lua:113-124). Otherwise a stayPos captured while standing in the depot would walk the bot back to town before a mid-hunt `function` waypoint.
- Stay Path FAILS OPEN after 3 s without progress (cavebot.lua:144-152). Do not turn that into a hard wait — a monster standing on the saved tile used to deadlock the route permanently.
- `gotoLabel` focuses the LABEL row, and the loop then advances +1, so execution continues at the waypoint after the label — never at the label itself. Both `supplycheck` and `poscheck` depend on this.
- `supplycheck` returns the RESULT OF `gotoLabel` when supplies are fine — i.e. `true` if the label exists, `false` if it does not. A typo'd label silently turns into 'proceed to refill'.
- Supply thresholds in Supplies.json are stored as strings (`"capValue":"200"`); the code `tonumber()`s them at every use (supply_check.lua:131,143). A naive `<` against a string in LuaJIT throws.
- `itemAmount()` is max(visible scan, server inventory count) (vlib.lua:872-888). Using only the open-container scan makes a full but CLOSED backpack read as zero and triggers an endless refill loop — this is exactly the bug the comment at buy_supplies.lua:80-81 describes.
- `buysupplies` counts `"retry"` returns as `retries`, but a successful 100-item batch resets a SEPARATE `noProgress` counter. Conflating the two caps a large order at ~50 batches (~5000 items).
- In smooth-walk mode a stale re-send is worse than a missed step: the server applies autoWalk direction lists relative to ITS current tile, half a round trip ahead of the client, so re-issuing a path computed from a predicted position lands one tile off. walking.lua:419-427 refuses to stack a second autowalk while any step is in flight.
- `getDistanceBetween` is Chebyshev, but the goto range test at actions.lua:387 uses MANHATTAN (`|dx| + |dy| > maxDist`). Two different metrics in the same function; both must be reproduced.
- There is no `node` action registered anywhere. `cavebot.lua:42/173` and `antilost.lua:212/252/284` still branch on it (legacy); loading a `node:` line only produces a warning.
- `storage.extras.gotoMaxDistance` is 64 in the shipped profile but the code's fallback is 40 (actions.lua:385) and Stay Path hardcodes 40 (cavebot.lua:145). Three different ranges are in play.
- `positionedBySelfNav` is only cleared by a `goto` returning a boolean. A route that goes travel -> function -> travel without an intervening goto keeps Stay Path disabled for the whole stretch (cavebot.lua:173-177) — which is the intended behaviour, not a bug, but it surprises.

## Open questions
- Item metadata the walker needs is not in luaclient today. `isNotPathable`, `isNotWalkable`, `isGround`, `getLensHelp()` (1104/1105 stairs), `getMinimapColor`, and `getGroundSpeed` all come from appearances.dat via g_things. `proto/items.lua` currently only exposes CUMULATIVE/WEAROUT/EXPIRE/CONTAINER/CLASSIFY/PODIUM/DECOKIT. The extractor (tools/extract_appearances.py) must be extended with at least: notPathable, notWalkable, isGround, groundSpeed, minimapColor(u8), lensHelp(u16), blockProjectile, isForceUse, isSplash, isOnBottom/isOnTop/isGroundBorder (needed to reimplement getTopUseThing). Which of these the 15.30 appearances actually carry needs a verification pass.
- There is no persisted minimap in luaclient. `Map::findEveryPath` falls back to `g_minimap.getTile()` for tiles outside the aware range (map.cpp:1415-1424) — that is where `allowUnseen` gets its data, and where `getMinimapColor` for an off-screen goto destination comes from. Without it, `goto` cannot classify a destination as stairs before arriving, and long-range paths degrade. Decide: (a) implement an OTMM-compatible minimap store (colour + wasSeen/notWalkable/notPathable flags per tile), or (b) restrict CaveBot to `allowOnlyVisibleTiles` and accept shorter routes.
- `player:isWalking()` / `isPreWalking()` have no luaclient equivalent. The goto final approach and `ReachDepot`/`PreciseGoTo` gate on them (actions.lua:414, new_cavebot_lib.lua:314). The smooth-walk `pending` ledger is a workable substitute (a step is 'in flight' while pending is non-empty), but the exact behaviour with the server's own walk queue on this server needs measuring.
- `g_game.getPing()` — does luaclient measure round-trip time from the 0x1E/0x1D ping exchange? Every timing that matters (final approach, sendWindow, PingDelay) reads it, with a config fallback of 100 ms. If no live ping exists, decide whether to measure it from the ping opcode pair or just always use the config value.
- Container slot addressing: `destination:getSlotPosition(index)` produces the {0xFFFF, containerId|0x40, slot} pseudo-position used by every deposit/withdraw move. API.md's `s:move(fromPos, itemId, stackpos, toPos, count)` takes raw positions, so the pseudo-position encoding must be confirmed against docs/opcode-map.md before the depositor can be written.
- `g_game.stashStowItem(pos, id, 0, stackpos, 2)` (supply stash, action 2) and `g_game.forgeRequest`, `g_game.applyImbuement`, `g_game.clearImbuement`, `g_game.selectImbuementItem`, `g_game.closeImbuingWindow` have no builders in proto/sender.lua. stowdeposit / forge / imbuing cannot be implemented until those opcodes are documented.
- `modules.game_npctrade.sellAll(wait, exceptions)` is a client-module routine, not a single packet — it iterates the sell list and issues one 0x7B per item. Its exact ordering, the `wait` pacing, and how 'sold everything' is detected (vBot uses 'free capacity stopped changing') need to be reproduced or replaced with an explicit per-item loop.
- TargetBot is out of scope here but the CaveBot contract depends on two predicates: `isActive()` (last attack/loot within 300 ms) and `isCaveBotActionAllowed()` (a 150 ms lure grant). Whoever specs TargetBot must expose exactly these, refreshed on a 100 ms cadence, or the walking will stutter.
- `player:getSkillLevel(11)` is used as the 'imbuements ran out' probe (supply_check.lua:127). Which skill index 11 actually is on this server (and whether the 1530 skills packet even carries it) is unverified.
- `g_map.getTiles(z)` (used by breakFurniture, opendoors, cleartile, ReachDepot, imbuing shrine search) enumerates every loaded tile on a floor. luaclient's st.map is a flat 'x,y,z' hash; a per-floor index (or an O(n) scan with an early bounding-box filter around the player) is needed, and the cost at 50 ms cadence should be measured — the otclient version is already flagged as 'resource consuming'.
- The `function` waypoint executes arbitrary Lua from the .cfg in the bot sandbox, with `TargetBot`, `CaveBot`, `delay`, `gotoLabel` and every extension injected. Decide whether the headless client runs route Lua at all; if yes, define the exact environment it gets (routes in the wild call `TargetBot.setOn()/setOff()`, `gotoLabel()`, `itemAmount()`), and note that arbitrary code from a config file is a trust boundary.
- `storage.caveBot.forceRefill / backStop / backTrainers / backOffline` are set by UI buttons elsewhere in vBot. A headless client needs an equivalent control-plane command surface; the labels `toTrainers` and `toOfflineTraining` that depositor jumps to are route conventions, not code.

## VERIFIER (confidence 0.88)

### Corrections (AUTHORITATIVE)
- **Claim**: §3.2 stepDuration: 'diagonal steps: d *= 3 (playerDiagonalWalkSpeed)' — i.e. the multiplier follows the `dir` argument passed to player:getStepDuration(false, dir).
  - **Correction**: The diagonal multiplier is selected by the creature's LAST step direction, not by the `dir` argument. `dir` only chooses which tile's ground speed is read. So getStepDuration(false, NorthEast) returns the NON-diagonal duration if the previous step was orthogonal, and returns the diagonal (x3) duration for an orthogonal `dir` if the previous step was diagonal. Also the `+10*max(1,preWalkingSize)` term is applied only when isCameraFollowing() && isLocalPlayer(); the serverBeat ceil-rounding applies only when isForcingNewWalkingFormula() or clientVersion>=860; hasSpeedFormula() divides by m_calculatedStepSpeed instead of m_speed; the 150 fallback applies only when the tile is null or getGroundSpeed()==0 (Tile::getGroundSpeed already returns 100 for a tile with no ground).
  - Evidence: src/client/creature.cpp:1106-1160 — `auto duration = ignoreDiagonal ? m_stepCache.duration : m_stepCache.getDuration(m_lastStepDirection);` and creature.h:264 `getDuration(dir) { return Position::isDiagonal(dir) ? diagonalDuration : duration; }`; src/client/tile.cpp:563-569.
- **Claim**: §2.3 `CaveBot.gotoFirstPreviousReachableWaypoint()` (cavebot.lua:422-455): 'walk backwards up to 100 rows for a goto on the current floor within gotoMaxDistance/2; focus it directly.'
  - **Correction**: It does NOT walk backwards row by row. The loop body is `for i=0,100 do index = index - i` — index is decremented CUMULATIVELY, so the inspected offsets from the start index are the triangular numbers 0,1,3,6,10,15,21,28,36,45,55,66,78,91, and the loop breaks as soon as |index-currentIndex| > 100 (i=14 → 105). It therefore examines at most ~14 waypoints at ever-sparser intervals, and the FIRST one examined (i=0) is the current waypoint itself. It also returns the value of `ui.list:focusChild(child)` (nil), not true, on success.
  - Evidence: cavebot/cavebot.lua:428-450.
- **Claim**: §0: 'Loop periods actually in force: CaveBot 50 ms' and the pseudocode `sched.every(50, cavebotTick)` with `if now() < CB.nextRunAt then return end`.
  - **Correction**: 50 ms is only the FREE-RUNNING period. `macro.lastExecution` is updated only when the callback actually ran (`if macro.callback(macro) then macro.lastExecution = context.now end`), and macro.callback returns nil while the macro is delayed. So while delayed, lastExecution goes stale and the `lastExecution + timeout <= now` gate is already satisfied; the binding constraint is `macro.delay < now`, which is re-checked on every 10 ms host tick. A `CaveBot.delay(50)` therefore resumes ~10 ms after expiry, not up to 50 ms later. The reimplementation must tick at 10 ms (or otherwise poll nextRunAt at 10 ms granularity), or every delayed step gains up to 50 ms of jitter — this compounds badly in the goto final-approach loop and the smooth-walk pacer.
  - Evidence: mods/game_bot/executor.lua:199-208 (`if macro.callback(macro) then macro.lastExecution = context.now end`), mods/game_bot/functions/main.lua:114-124, mods/game_bot/bot.lua:531 (`scheduleEvent(check, 10)`).
- **Claim**: §2.3 step 7 / pseudocode comment: 'NOTE: vBot aliases pp here; do NOT copy that.'
  - **Correction**: The aliasing is load-bearing and dropping it changes behaviour. `nextPos = nextPos or playerPos` makes nextPos THE SAME TABLE as playerPos, so every `nextPos.x/y` advance mutates `playerPos`. The subsequent reachability test `findPath(playerPos, creature:getPosition(), 7, {...})` on line 468 therefore measures reachability from the tile currently being replayed, not from the player. Fixing the alias makes some monsters pass/fail the 7-tile reachability gate differently and changes which monster (if any) gets attacked. If you intend to diverge, say so as a deliberate deviation rather than presenting the spec as a faithful description.
  - Evidence: cavebot/actions.lua:454-456 and 468 — `nextPos = nextPos or playerPos; nextPos.x = nextPos.x + dirs[1]` … `findPath(playerPos, creature:getPosition(), 7, …)`.
- **Claim**: Pseudocode `actionGoto`: `local maxDist = cfg.gotoMaxDistance or 40` (reading gotoMaxDistance out of the route config).
  - **Correction**: `gotoMaxDistance` is NOT a route-config (`config:` blob) key and does not exist in CaveBot.Config — it lives in bot storage at `storage.extras.gotoMaxDistance` (the spec's own §B shows 64). The code reads `storage.extras.gotoMaxDistance or 40`. Same for `storage.extras.pathfinding`, `machete`, `huntRoutes`, `talkDelay`. `CaveBot.Config.get('gotoMaxDistance')` would warn 'Invalid CaveBot.Config.get' and return nil. Also `CaveBot.gotoNextWaypointInRange`/`gotoFirstPreviousReachableWaypoint` read `storage.extras.gotoMaxDistance` with NO `or 40` fallback.
  - Evidence: cavebot/actions.lua:385; cavebot/cavebot.lua:366,387,443; cavebot/config.lua:26-59 (the complete Config key list, which has no gotoMaxDistance).
- **Claim**: §0: 'reproduce the max-vs-overwrite distinction exactly, it is load bearing (a `delay(70)` at the top of depositor must not shorten a `CaveBot.delay(3000)` set later in the same tick — and it doesn't, because they are different functions writing the same field with different rules).'
  - **Correction**: The example is wrong. In depositor.lua the 3000 is a plain `delay(3000)` (the OVERWRITE variant), not `CaveBot.delay(3000)` — both writes are overwrites and the later one simply wins. The max-vs-overwrite distinction is real, but this is not an instance of it. (A real instance: `CaveBot.PingDelay()` uses `delay()`, so it can *shorten* a CaveBot.delay already set this tick.) Note also that `delay(70)` appears at the top of BOTH depositor.lua and d_withdraw.lua (dpwithdraw), which the §1.6 dpwithdraw row omits.
  - Evidence: cavebot/depositor.lua:49 (`delay(70)`) and :55 (`delay(3000)`); cavebot/d_withdraw.lua:13 (`delay(70)`); vBot/new_cavebot_lib.lua:142-148 (`CaveBot.PingDelay` calls `delay(value)`).
- **Claim**: §1.6 `use`/`usewith`: 'CaveBot.delay(useDelay + ping)', with §3.2 defining ping as g_game.getPing() validated against the config value.
  - **Correction**: For use/usewith the ping term is ALWAYS the raw config value `CaveBot.Config.get('ping')` (default 100) — g_game.getPing() is never consulted. The getPing()-with-fallback rule (§3.2) applies only in walking.lua's pingMs() and in the goto final-approach block (actions.lua:420-423). Default use delay is therefore a fixed 500 ms regardless of real latency.
  - Evidence: cavebot/actions.lua:578 and :615 — `CaveBot.delay(CaveBot.Config.get("useDelay") + CaveBot.Config.get("ping"))`.
- **Claim**: §3.1: 'Node cost = tile ground speed (default 100 when no ground; 150 in the step-duration path)'.
  - **Correction**: Incomplete. In Map::findEveryPath the local `speed` is initialised to **1000** and only overwritten when the position is aware and a tile exists (`tile->getGroundSpeed()`, which is 100 for a tile with no ground) or from the persisted minimap (`mtile.getSpeed()`). So a neighbour that is aware-but-has-no-tile, or that is unaware while `allowOnlyVisibleTiles` is set, costs 1000 per step — 10x a normal tile. Additionally, a tile's cost/creature flags are evaluated exactly ONCE, at first discovery, and never re-evaluated when the node is relaxed via a cheaper predecessor.
  - Evidence: src/client/map.cpp:1400-1440 (`int speed = 1000;` … `it = nodes.emplace(neighbor, new Node{ (float)speed, …})` inside `if (it == nodes.end())`).
- **Claim**: §3.2 item 2 / pseudocode: `sender:autoWalk(path) -- clamps to 127 steps`.
  - **Correction**: There is no clamping. `Game::autoWalk` logs 'Auto walk path too great' and RETURNS WITHOUT WALKING when dirs.size() > 127. Worse, the bot-side `context.autoWalk(dirs)` returns `true` unconditionally, so `CaveBot.walkTo` reports success and the goto action returns "retry" forever while the character never moves. (In practice maxDist<=64 keeps paths short, but the pseudocode's 'clamps' is factually wrong and would produce different behaviour if copied.)
  - Evidence: src/client/game.cpp:692-695; mods/game_bot/functions/map.lua:224-227 (`g_game.autoWalk(destination,{x=0,y=0,z=0}); return true`).
- **Claim**: §3.6: 'Recovery loop (every 200 ms while recovering; each pass re-freezes CaveBot with CaveBot.delay(1500)): 1. isBackOnTrack(pPos) … If so → stop recovering.'
  - **Correction**: The order is inverted: `CaveBot.delay(RECOVERY_FREEZE_MS)` is executed BEFORE isBackOnTrack is evaluated. So the pass that ends recovery still leaves CaveBot frozen for up to 1500 ms afterwards. Reproduce the freeze-then-test order or the bot resumes ~1.5 s earlier than the real one.
  - Evidence: cavebot/antilost.lua:596-601 — `local pPos = player:getPosition(); CaveBot.delay(RECOVERY_FREEZE_MS); if isBackOnTrack(pPos) then … stopRecovering() …`.
- **Claim**: §3.6 `isExpectedFloorChange`: 'That predicate asks, for the current waypoint, the previous one, and up to 6 following ones: …'
  - **Correction**: The lookahead is conditional, not unconditional. After testing {current, prev} the function does an early hard exit: `local curPos = actionPosition(current); if curPos and not nearXY(curPos, oldPos, 1) then return false end` — if the current waypoint has a position and the fall did not happen within 1 tile of it, the change is classified accidental IMMEDIATELY and the 6 following waypoints are never examined. Only when the current waypoint has no position, or the fall was from its own tile, does the idx+1..idx+LOOKAHEAD scan run. Also, the bullet 'a positional waypoint that is not near oldPos, OR is on a different floor than newZ → accidental' misstates the test: the loop's abort condition is only `p and not nearXY(p, oldPos, 1)`; the floor is not part of that condition (the z==newZ case was already accepted earlier by explainsFloorChange).
  - Evidence: cavebot/antilost.lua:322-360.
- **Claim**: §3.6 bounce guard: "recentFalls['x,y,z>newZ']; a repeat of the same fall inside 60 s is treated as an intended transfer and left alone."
  - **Correction**: The timestamp is written BEFORE the window is tested (`recentFalls[fallKey] = now` then `if lastRecovery and now - lastRecovery < WINDOW`), so every suppressed fall refreshes the window. A character that keeps falling through the same tile every <60 s stays suppressed indefinitely, never re-arming recovery. Also the guard is checked AFTER isExpectedFloorChange, and recentFalls is never pruned.
  - Evidence: cavebot/antilost.lua:396-402.
- **Claim**: §1.2: "Key regex: `(?:^|\n)([^:^\n]{1,20}):?(.*)` — key is at most 20 chars, no `:` and no newline." plus the pseudocode `parseCfg` key match `line:match("^([^:\n]?[^:\n]-):(.*)$")` with `#k <= 20` rejecting longer keys.
  - **Correction**: Two errors. (a) The character class `[^:^\n]` also excludes the caret `^`, so a key containing `^` cannot be parsed. (b) The `{1,20}` is a length CAP on the capture, not a validity test: a line whose first colon sits past column 20 is not dropped — the key becomes the first 20 characters and the value becomes the remainder INCLUDING the colon (`:?` simply matches nothing). The pseudocode instead splits at the colon and discards the line when the prefix exceeds 20 chars. Additionally the multi-line accumulator in the real decoder appends `v[1]`, the FULL regex match (which carries the trailing \n and any leading \n's from blank lines that the regex skipped), not the bare line; the results coincide for the shipped routes but the mechanisms differ.
  - Evidence: modules/corelib/table.lua:293 (`regexMatch(l, "(?:^|\\n)([^:^\n]{1,20}):?(.*)(?:$|\\n)")`) and :298-305 (`v[1]:find("%]%]")`, `multiline .. "\n" .. v[1]`); src/framework/luafunctions.cpp:95-112 (regex_search on the shrinking suffix, ECMAScript).
- **Claim**: §3.2 item 3 (smooth walk) description of CaveBot.smoothWalkTo, and the pseudocode's CB.walkTo smooth branch.
  - **Correction**: Missing branch: before pathfinding, smoothWalkTo checks for a destination change while steps are still in flight — `if #pending > 0 and smoothDest and dest differs then if pendingIsAutoWalk then g_game.stop(); clearPending(); walkPath={}; walkPathIter=0; smoothDest=nil; CaveBot.delay(100 + ceil(ping/2)); return true end`. Without it, a route that re-targets mid-autowalk stacks a stale server-side walk queue. Also: in onPlayerPositionChange the ledger-void path only issues `CaveBot.delay(100)` when smoothWalk is ON (`if smoothOn() then CaveBot.delay(100) end`); the pseudocode issues it unconditionally, which would inject a spurious 100 ms delay on every teleport/push in single-step mode.
  - Evidence: cavebot/walking.lua:385-398 and :360-368.
- **Claim**: §1.6 `cleartile` / `withdraw` / `dpwithdraw` rows cite `CaveBot.GoTo(tPos,0)`, `CaveBot.MatchPosition`, `CaveBot.WithdrawItem`, `CaveBot.PingDelay()` without defining them.
  - **Correction**: These are undefined in the spec and cannot be reimplemented from it. Actual semantics: `CaveBot.GoTo(pos, precision)` = `CaveBot.walkTo(pos, 20, {ignoreCreatures = true, precision = precision or 3})` — note maxDist is a hard 20 and it does NOT pass ignoreNonPathable, so it refuses to path across fields. `CaveBot.MatchPosition(pos, distance)` = `getDistanceBetween(playerPos, pos) <= (distance or 1)`. `CaveBot.PingDelay(mult)` is a NO-OP unless `g_game.getPing() > 150`, and otherwise calls the OVERWRITE `delay(min(ping*mult, 2000))`, not CaveBot.delay — so at low ping every 'PingDelay' in withdraw/dpwithdraw/inwithdraw/depositor does nothing at all.
  - Evidence: vBot/new_cavebot_lib.lua:142-148 (PingDelay), :213-218 (MatchPosition), :225-231 (GoTo).
- **Claim**: §1.6 `goto` row: 'The 4th field is the precision marker; presence (even `,0`) switches to exact-stand semantics and makes the waypoint unskippable.'
  - **Correction**: 'Unskippable' contradicts the spec's own §2.3 and the code. A marked goto still returns false (and advances) at step 1 (retries>=100), step 2 (destination on a different floor), step 3 (Manhattan distance > gotoMaxDistance) and step 6 (no creature-ignoring path and breakFurniture fails). The marker only exempts it from steps 7 (no-monster), 11 (retries>=5) and 12 (skipBlocked), and forces precision 0 at step 10.
  - Evidence: cavebot/actions.lua:362-391 (all four unconditional false exits), :488-497, :510-533.
- **Claim**: §1.6 `rushlure` row: 'Pathfind twice (ignoring / not ignoring creatures)' and 'CaveBot.delay(delayMs)'.
  - **Correction**: Three inaccuracies. (a) The two pathfinds use DIFFERENT ranges: the creature-ignoring one uses maxDist 30, the creature-respecting one passes the bare identifier `maxDist`, which is an undefined global (nil) — findPath then defaults it to 100. (b) `delayMs` defaults to 1000 when the 4th field is absent or non-numeric. (c) The deferred TargetBot on/off from the 5th field does not fire when focus leaves the waypoint: onChildFocusChange sets a `next` flag when the OLD child was the rushlure and returns; the toggle is applied on the FOLLOWING focus change, i.e. one waypoint later. (d) Unlike goto, rushlure never walks toward a distant blocking monster — it calls `attack(creature)` regardless of distance.
  - Evidence: cavebot/stand_lure.lua:88-89, :61, :161-186; mods/game_bot/functions/map.lua:162-164 (`if type(maxDist) ~= 'number' then maxDist = 100 end`).
- **Claim**: §1.6 `dpwithdraw` row lists the branches: retries>600 → false; cap → false; no dest → false; dest full → open nested, retry; depot empty → close, true; OpenDepotBox; PingDelay(2); move first item, retry.
  - **Correction**: Two branches are missing. (1) A `delay(70)` (overwrite) at the very top, before validation. (2) A SECOND `containerIsFull(destContainer)` block after the depot-empty check: if the destination is full and does NOT contain a nested destId it prints 'loot containers full!' and returns **false** (skip); if it does contain one it calls `g_game.open(foundNextContainer, destContainer)` with the undefined global `foundNextContainer`, which throws, is swallowed by the dispatcher's pcall, yields a nil result and the waypoint is advanced past. Also the move is `item:getCount()` (whole stack), not one item.
  - Evidence: cavebot/d_withdraw.lua:13, :69-78, :90.
- **Claim**: §3.2 item 1: 'CaveBot.doWalking() then pumps the rest: while #expectedDirs > 0, send walkPath[walkPathIter] …'
  - **Correction**: Misleading in a way that changes behaviour. doWalking sends at most ONE step per tick and only fires while `#expectedDirs > 0`, i.e. while a previously sent step is still UNCONFIRMED. As soon as onPlayerPositionChange pops the last expectedDir, doWalking returns false, the action runs again, `CaveBot.resetWalking()` (cavebot.lua:163) discards the remaining walkPath, and the action re-paths from scratch. So a stored path is only ever consumed as a lookahead during unconfirmed steps; it is never walked to completion.
  - Evidence: cavebot/walking.lua:307-333 (single send + `return true`), :372-377 (pop), cavebot/cavebot.lua:162-164 (resetWalking before every callback).
- **Claim**: §2.3 step 7: 'replay `path` tile by tile; first tile with a monster (isMonster, healthPercent>0, getType()<3 on 9.60+) that is itself reachable within 7'. Same wording for §1.6 cleartile ('monster on tile → attack').
  - **Correction**: Only the FIRST creature on each tile is examined: `local creature = tile:getCreatures()[1]`. If a player (or a summon failing getType()<3) happens to be index 1 on a tile that also holds a qualifying monster, that tile is skipped entirely and the scan continues to the next tile. clear_tile.lua does the same (`tile:getCreatures()[1]`), so a tile with a player stacked first is never attacked even if a monster is on it.
  - Evidence: cavebot/actions.lua:464-466; cavebot/clear_tile.lua:63-68 and :84-86.
- **Claim**: §2.3 `pathfinder()` / §2.3 goto — implicit claim that the goto skip/advance flow is fully described by steps 1-13.
  - **Correction**: `noPath` (actions.lua:5) is a single file-local counter SHARED by every goto waypoint in the route, not per-waypoint; it is incremented at steps 1,2,3,6,7,11,12, zeroed on any arrival (step 4) and by pathfinder(). The spec never says this, and a per-waypoint counter would make the 10-strike pathfinder rescue fire far less often. Similarly `nextPos`/`nextPosF` are file-locals reset at the top of every goto call.
  - Evidence: cavebot/actions.lua:5, :359-360, :364, :401, :432, :443.
- **Claim**: §1.6 `sayhello` row: '(template/demo only) | extension_template.lua:15'.
  - **Correction**: extension_template.lua is not loaded at all — its dofile is commented out in the loader, so `sayhello` is never registered and a `sayhello:` line in a .cfg produces `warn("Invalid cavebot action: sayhello")` exactly like `node:`. (This is also what makes §1.3's 'no shipped extension implements onSave' true — the template does implement onSave, it is simply disabled.)
  - Evidence: vBot/cavebot.lua:21 — `--dofile("/cavebot/extension_template.lua")`; cavebot/extension_template.lua:15,43.
- **Claim**: Pseudocode `tileInfo` (color default 255, colour derived from item flags) and `isFloorChangeTile` reading `ti.color` from tileInfo.
  - **Correction**: Both diverge from the sources. (a) The pathfinder's colour comes from `tile->getMinimapColorByte()` (or the persisted `mtile.color`), whose 'no colour' value is 0, not 255; the pseudocode's `color = 255` sentinel plus the `color == 255` guard will misclassify tiles. (b) walking.lua's isFloorChangeTile uses `g_map.getMinimapColor(p)`, which prefers the live tile's colour byte and falls back to the persisted minimap — not item flags; and actions.lua's stairs test is also `g_map.getMinimapColor(pos)`. Deriving the colour from item flags will disagree on any tile whose minimap colour is cached or minimap-only.
  - Evidence: src/client/map.cpp:1168-1178, :1412, :1424; src/client/tile.cpp:571-578; cavebot/walking.lua:141-143; cavebot/actions.lua:393.
- **Claim**: §2.3 `CaveBot.gotoNextWaypointInRange()`: 'scan forward from the current index, then from the start … focus index-1 (so the main loop's +1 lands on it).'
  - **Correction**: Minor but real edge cases: the second pass scans `i <= index`, i.e. it INCLUDES the current waypoint itself, not just 'from the start' up to it; and when the match is at i==1 it calls `focusChild(getChildByIndex(0))` (nil), which unfocuses the list — the main loop then falls back to getFirstChild() and advances to index 2, skipping waypoint 1. Also the range test is `distanceFromPlayer(pos) <= storage.extras.gotoMaxDistance` with no `or 40` fallback, so an absent storage.extras.gotoMaxDistance errors.
  - Evidence: cavebot/cavebot.lua:379-397, :369, :390.
- **Claim**: §1.6 `opendoors`: 'If `not tile:isWalkable()` → use(topUseThing) … Walkable → true.'
  - **Correction**: `Tile:isWalkable()` is called with no argument, so ignoreCreatures is false and any non-passable visible creature standing in the doorway makes the tile 'not walkable' — the action then repeatedly use()s an already-open door until retries>=5 and returns false. Worth stating, because a headless implementation that tests only ground/door state will behave differently around blocked doorways.
  - Evidence: cavebot/doors.lua:35; src/client/tile.cpp:708-725.
- **Claim**: §4.1 branch 5: '`storage.extras.huntRoutes ~= 0` and `supplyRetries > huntRoutes`'.
  - **Correction**: Both reads are defaulted, and with DIFFERENT defaults: the gate is `(storage.extras.huntRoutes or 0) ~= 0 and supplyRetries > (storage.extras.huntRoutes or 50)`. If huntRoutes is nil the gate is disabled by the first `or 0`; the `or 50` in the comparison (and in the two print statements) is therefore dead but must be mirrored if you ever set huntRoutes to nil-like values.
  - Evidence: cavebot/supply_check.lua:123.
- **Claim**: §3.6 recovery: 'target = nearest tile within radius 6 …' / 'nearest recovery tile within radius 2 of it'.
  - **Correction**: 'Nearest' is MANHATTAN (`|dx| + |dy|`), while the radius itself is a square box (dx,dy each in [-r,r]) and every other distance in the cavebot is Chebyshev. With ties the first found in the dx-then-dy scan order wins. Using Chebyshev for the nearest-selection picks a different tile whenever two candidates share a Chebyshev distance but differ in Manhattan.
  - Evidence: cavebot/antilost.lua:104-116 and :121-140.

### Additions
- CONFIRMED CORRECT (spot-checked line by line): host tick 10 ms (bot.lua:531); macro dispatch `lastExecution + timeout <= now` and the 50 ms timeout floor (main.lua:37-40); `delay()` overwrite vs `CaveBot.delay()` max (main.lua:206-211 vs cavebot.lua:563-565); getDistanceBetween = Chebyshev (executor.lua:123-125); distanceFromPlayer = Chebyshev (vlib.lua:643); antilost macro 200 ms, HUD macro 150 ms, targetbot macro 100 ms; TargetBot.isActive = lastAction+300>now, isCaveBotActionAllowed = cavebotAllowance>now, allowCaveBot(150) at creature_attack.lua:149/154/159; TargetBot.delay is an OVERWRITE (target.lua:236-238).
- CONFIRMED CORRECT: the .cfg model — ordered key:value pairs, `[[`/`]]` multiline emitted iff the value contains \n, empty-value lines silently dropped (`v[2]:len()>0 and v[3]:len()>0`), reserved trailing keys config/extensions/staypositions in exactly that order, staypositions pre-scanned before actions are added, actionIndex counting only real waypoints. I re-ran the decoder against both real files: test.cfg yields exactly the 3 waypoints + 3 metadata pairs the spec shows, and true_asura_mk.cfg yields 292 waypoints, with the `function` body landing at ordinal 69 — matching the `"69"` staypositions key. The decoded function value is 'TargetBot.setOn()\n\n\nreturn true\n\n\n'.
- CONFIRMED CORRECT: the main-loop tick order and dispatch contract (cavebot.lua:80-203) — TargetBot gate, doWalking, focused-or-first, Stay Path pre-walk, resetWalking INSIDE the pcall before the callback, "retry"→retries++ and hold, boolean→retries=0 + prevActionResult + positionedBySelfNav latch (set by STAYPATH_SELF_NAV on true, cleared by goto/node on any boolean), focus re-read + state reset when focus changed, index+1 with wrap to 1. `false` really does advance.
- CONFIRMED CORRECT: the full goto control flow (actions.lua:345-543) — retry ceiling first (5 with mapClick&&no-marker, else 100), z mismatch, MANHATTAN > gotoMaxDistance, the two arrival tests (both-axes<=prec for stairs/marker vs dx==0 && |dy|<=1 otherwise), the <=3 final-approach with isWalking/isPreWalking → delay(50), the ignoreFields walkTo(dest,40), the retries>=3 precision=(retries-1) or 0, the retries>=5 non-mapClick skip, skipBlocked, and the last-resort walkTo with `CaveBot.delay(min(100+retries*50, 500))` on failure. pathfinder() gated on storage.extras.pathfinding and noPath>=10 with the #Unibase toggle is accurate.
- CONFIRMED CORRECT: Stay Path (cavebot.lua:97-156) — STAYPATH_MAX_DRIFT 15, STAYPATH_STUCK_MS 3000, the 12-row previousRoutePosition lookback over goto/node/use/usewith, the stale test `ref.z ~= sp.z or drift > 15`, the >2-tile trigger, best-distance timestamp refreshed only on strict improvement, walkTo(sp, 40, {ignoreNonPathable, precision=2}), warn throttled to 3000 ms, and the fail-open fall-through. Both exclusion lists (STAYPATH_EXCLUDED_ACTIONS at actions.lua:139-171 and STAYPATH_SELF_NAV at cavebot.lua:17-21) match the spec member-for-member.
- CONFIRMED CORRECT: findPath/getPath semantics (map.lua:143-220 + map.cpp:1316-1473) — refuses cross-floor immediately, maxDist defaults to 100 and caps node.distance, hasStairs = isNotPathable && 210<=color<=213, the neighbour rejection set, ignoreLastCreature recording at cost+100, the destination exemption for the stairs/nonPathable rules, precision searching boxes p=1..precision for the cheapest settled tile, `{}` returned when already standing on the destination, and direction ints North=0..NorthWest=7. playerDiagonalWalkSpeed is indeed 3 (gameconfig.h:125).
- CONFIRMED CORRECT: floor-change avoidance (walking.lua:78-207) — the four criteria, the deliberate exclusion of lenshelp 1100/1101/1102/1106, 'yellow alone is never enough', the pcall fail-open, unloaded tile → false, destination exemption in pathCrossesFloorChange, and the 10 s per-tile log throttle. Also CaveBot.wouldStepChangeFloor and `avoidFloorChangeOn() = get('avoidFloorChange') ~= false`.
- CONFIRMED CORRECT: config defaults (cavebot/config.lua) — ping 100, walkDelay 10, mapClick false, mapClickDelay 100, ignoreFields false, skipBlocked false, useDelay 400, wptDistance 5, antiLostEnabled true, the four id lists, antiLostRopeToolId {item=3003}, stayPathEnabled true, waypointHud false, plus smoothWalk/avoidFloorChange/avoidTileIds appended by walking.lua's setup wrapper. onConfigChange resets every key to its default before applying the route blob, so a missing key really does revert.
- CONFIRMED CORRECT: antilost constants (200/1500/210-213/2/6/60000/4/6/200), the trigger conditions, the teleport-vs-stairs classification from the fall tile's top-use id, the stairs target = exact fallSpot x,y at current z else nearest recovery tile within 2 (never wider), the recovery-tile definition (yellow OR ladder/rope list), the dispatch order ladder→rope→isUsable→plain hole with the dist==0 step-off, the 3003 rope-tool fallback below 100, isBackOnTrack's per-action-type position extraction with position-less waypoints counting as OK, and giveUpToCaveBot = gotoNextWaypointInRange else gotoFirstPreviousReachableWaypoint.
- CONFIRMED CORRECT: per-action rows for label, gotolabel, delay (incl. the editor regex at editor.lua:98), follow, function (the exact prefix, sandbox env via context.load/loadstring, return value passthrough), say, npcsay (talkChannel(11,0,text) for >=810 — with an unmentioned fallback to plain say below 810), walkdelay (0..10000), turn, exanihur (retries==0 startZ, success test first, 20-try ceiling with optional label fallback, re-face, delay 1000), forge (2/4, clamp 1..50, delay 800), poscheck (5-or-6 fields, default 10, inf/infinity, counter reset on value change, ceiling checked before the position test, false in every failure path), cleartile, lure (including invalid values still returning true), supplycheck's position guard and the first eight cascade branches, withdraw (>100), inwithdraw (>=amount before >400, last non-full non-quiver/depot/loot/inbox container, first-free-slot move), tasker (getNpcs(3), talkDelay*4 / talkDelay*3, 'Loot of' counter), and the recorder (transfer marker, in-place upgrade of a duplicate plain goto, wptDistance floored at 1, onUse/onUseWith 0xFFFF guards).
- CONFIRMED CORRECT: there is no `node` action — nothing registers it, `cavebot.lua:42/173` and `antilost.lua:212/252/284` still branch on it, and loading `node:` warns 'Invalid cavebot action: node'. `pushPlayer` (actions.lua:103-117) is indeed dead code. `action` is lower-cased on both addAction and registerAction. The 'There is not enough room.' onTextMessage hook matches the spec (adjacent tile, no creatures, walkable, >9 items, disintegrate outside PZ / move top thing inside PZ, 200 ms throttle).
- OMISSION worth adding for the reimplementation: on config (re)load cavebot.lua:279-284 also sets `cavebotMacro.delay = nil` (clearing any pending CaveBot.delay), actionRetries=0, prevActionResult=true, positionedBySelfNav=false, and calls CaveBot.resetWalking(). Also, `macro()` seeds `lastExecution = now + math.random(0,100)`, so a fresh macro's first run is jittered by 0-100 ms.
- OMISSION: breakFurniture's candidate is initialised with `dist = 100` and the comparison is strict `<`, so if the destination is 100+ tiles (Chebyshev) from every candidate no furniture is ever broken. Its reachability test is `findPath(playerPos, tpos, 7, {ignoreNonPathable=true, precision=1})`. It is also called as `breakFurniture(pos, storage.extras.machete)` — the second argument is ignored by the function signature.
- AMBIGUITY: §1.6's `delay` row says `final = math.random(ms-diff, ms+diff)`. In LuaJIT math.random with non-integer bounds is implementation-defined (it floors); e.g. `500,15` gives min=425, max=575 (integers here), but `501,15` gives 425.15/576.85. State the rounding you intend.
