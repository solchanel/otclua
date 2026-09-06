# TargetBot — target selection, combat behaviour and looting (vBot 4.8)

# TargetBot — complete behavioural specification (vBot 4.8)

> Implementation status per targeting/looting rule: **[docs/vbot/parity.md](parity.md) §3**.

All citations are `file:line`. Source root `P = D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8`,
`B = D:/Claude/otclient_mehah1530/otclient/mods/game_bot`, `S = D:/Claude/otclient_mehah1530/otclient/src`.

TargetBot is **one 100 ms macro** (`P/targetbot/target.lua:49`) plus **two event handlers**
(`onCreatureDisappear` → corpse queue, `P/targetbot/looting.lua:310`; `onTextMessage` → "not the owner",
`P/targetbot/looting.lua:276`) and one `onPlayerPositionChange` handler for CaveBot lure-delay
(`P/targetbot/creature_attack.lua:236`). Everything else is state held in module locals.

---

## 0. Runtime substrate (what a headless client must provide)

### 0.1 Tick
`B/bot.lua:531` — the whole bot is driven by `scheduleEvent(check, 10)`, i.e. a **10 ms** master tick.
`B/executor.lua:199-209` — on each master tick every macro whose
`lastExecution + timeout <= now` runs; `macro.callback` always returns true
(`B/functions/main.lua:123`) so `lastExecution = now` after every run.
`B/functions/main.lua:38-40` clamps any macro timeout to a minimum of 50 ms.
`B/functions/main.lua:46` — `lastExecution` is initialised to `now + random(0,100)` (jitter, not important).

**TargetBot macro period = 100 ms** (`P/targetbot/target.lua:49`). A macro can be postponed by setting
`macro.delay`: `TargetBot.delay(ms)` sets `targetbotMacro.delay = now + ms` (`P/targetbot/target.lua:234`);
`B/functions/main.lua:114` skips the callback while `macro.delay >= now`.

For reference, **CaveBot's macro period is 20 ms** (`P/cavebot/cavebot.lua:80`) and it yields to TargetBot
(§3.7).

### 0.2 `now`
`B/executor.lua:195-196` — `context.now = context.time = g_clock.millis()`, refreshed once per master
tick. In luaclient: `LC.sched` + `sys.nowMs()`; snapshot it once per tick so all comparisons in one tick
use the same value.

### 0.3 Path finding — `findPath` / `getPath`
`B/functions/map.lua:143` (`getPath` is an alias, `:220`). Signature
`findPath(startPos, destPos, maxDist, params) -> {dir, dir, ...} | nil`.
It **returns a list of walk directions**, so `#path` is the *number of steps*, i.e. the walking distance.
It refuses cross-floor requests outright (`map.lua:159`: `if not destPos or startPos.z ~= destPos.z then return`).

Under the hood `g_map.findEveryPath` (`S/client/map.cpp:1316`) is **Dijkstra over 8-neighbourhood**:
* node cost = tile ground speed (`map.cpp:1449`), diagonal multiplier `PlayerDiagonalWalkSpeed`
  (`map.cpp:1454`); `ignoreCost=1` forces every edge cost to exactly 1 → plain BFS (`map.cpp:1456`).
* expansion stops at `node->distance >= maxDistance` (`map.cpp:1387`).
* a neighbour is **rejected** (`map.cpp:1430-1434`) when:
  `(!wasSeen && !allowUnseen)`, or `hasStairs && !ignoreStairs && neighbor != dest`, or
  `isNotPathable && !ignoreNonPathable && neighbor != dest`, or `isNotWalkable && !ignoreNonWalkable`,
  or it violates `maxDistanceFrom`.
* `hasStairs` = `isNotPathable && minimapColor in [210..213]` (`map.cpp:1428`).
* a neighbour with a **blocking creature** is rejected unless `ignoreCreatures`; with `ignoreLastCreature`
  it is still written into the result map as a **terminal** node costing +100 (`map.cpp:1436-1441`) — that
  is how the bot can path *onto* the target monster's own tile.
* `marginMin/marginMax` (`map.lua:171-192`): after `findEveryPath`, pick the cheapest reachable tile
  `(dx,dy)` with `|dx| >= marginMin or |dy| >= marginMax`... precisely `math.abs(x) >= marginMin or
  math.abs(y) >= marginMin` scanning `x,y ∈ [-marginMax, marginMax]`. Note the C++ side extends the
  search by 4 past the destination when margins are used (`map.cpp:1382`).
* `precision` (`map.lua:196-215`): if the exact destination is unreachable, try rings `p = 1..precision`
  and take the cheapest node in the square of radius `p`.

**luaclient has none of this.** You must implement the same Dijkstra over `LC.state.map`, and you need
per-item `NOT_WALKABLE` / `NOT_PATHABLE` / `isGround` flags which `proto/items.lua` does **not** currently
extract (see Pitfalls).

### 0.4 Distance metrics — there are **two**, do not mix them
* `getDistanceBetween(p1,p2)` (`modules/game_battle/battle.lua:1881`):
  `xd = |dx|; yd = |dy|; if xd>0 then xd=xd-1 end; if yd>0 then yd=yd-1 end; return xd+yd`.
  This is **not** Chebyshev. `distanceFromPlayer(pos)` = `getDistanceBetween(playerPos, pos)`
  (`P/vBot/vlib.lua:643`).
* Raw Chebyshev `math.max(|dx|,|dy|)` is used inline in `walking.lua:26`, `looting.lua:150`,
  `looting.lua:322`.

### 0.5 Spectators
`g_map.getSpectatorsInRange(centerPos, multiFloor, xRange, yRange)` (`S/client/map.h:176`) →
`getSpectatorsInRangeEx` (`S/client/map.cpp:651`). It walks **z outer, y middle, x inner, all ascending**
(`map.cpp:674-687`) and appends every creature on each tile in tile-stack order, de-duplicated by id.
Range is inclusive on both sides, so `(pos,false,6,6)` is a **13×13** box, not 12×12 as the comment says.

`getSpectators()` with no args (`B/functions/map.lua:8`) = `g_map.getSpectators(playerPos,false)` = the
whole aware range. `getSpectators(posOrCreature, patternString)` = `g_map.getSpectatorsByPattern`
(`map.lua:28`, impl `S/client/map.cpp:1481`), centred on the given position.

### 0.6 Regex
`regexMatch(subject, pattern)` (`S/framework/luafunctions.cpp:95`) is **std::regex, ECMAScript grammar**,
returning a list of match-groups lists; the bot only checks `[1]` truthiness.

---

## 1. The creature-config model

### 1.1 Where it lives
* File: `<botProfile>/targetbot_configs/<selected>.json`, e.g.
  `P/targetbot_configs/turter.json`. `context.configDir = "/bot/" .. config` (`B/executor.lua:22`),
  dir name `"targetbot_configs"` (`P/targetbot/target.lua:131`), extension `"json"`.
* Which file is selected + whether TargetBot is enabled: the **bot storage file**
  `<botProfile>/storage/profile_<N>.json` (`B/bot.lua:268-273`), key
  `_configs.targetbot_configs = { enabled = <bool>, selected = "<name>" }`
  (`B/functions/config.lua:141-144`; read back by `TargetBot.getCurrentProfile`, `target.lua:220`).
  Real value on disk: `{"targetbot_configs":{"enabled":false,"selected":"true_asura"}}`.
* Loading: `Config.setup("targetbot_configs", widget, "json", cb)` (`target.lua:131`). The callback gets
  `(name, enabled, data)`; `data == nil` ⇒ turn the macro off (`target.lua:132-135`). Otherwise it
  rebuilds the creature list from `data["targeting"]` and hands `data["looting"]` to the looter
  (`target.lua:136-140`). `targetbotMacro.delay = nil` and `lureEnabled = true` are reset on every
  config (re)load (`target.lua:150-151`).
* Saving: `TargetBot.save()` (`target.lua:238`) writes `{targeting = {...}, looting = {...}}` back to the
  same file via `json.encode(value, 2)` (`B/functions/config.lua:106`).

### 1.2 Entry fields
`data.targeting` is a **JSON array**; order is the widget list order and is the tie-break order only for
*saving*, not for matching. Every field below is produced by `TargetBot.Creature.edit`
(`P/targetbot/creature_editor.lua:79-105`); the number after each is `(min, max, default)` for sliders.

| key | type | range/default | meaning |
|---|---|---|---|
| `name` | string | — | comma-separated name patterns. `*` = any chars, `?` = any single char. `"*"` matches everything. |
| `regex` | string | derived | cached ECMAScript alternation built from `name` (§1.3). Persisted so it is *not* recomputed on load (`creature.lua:21`). |
| `priority` | number | 0..10, **1** | base score added when the creature is in range (`creature_priority.lua:22`) |
| `danger` | number | 0..10, **1** | contribution to the global danger aggregate (`creature.lua:97`) |
| `maxDistance` | number | 1..10, **10** | max *path steps* at which the creature is targetable (`creature_priority.lua:12`) |
| `chase` | bool | **true** | walk to melee range (precision 1) |
| `keepDistance` | bool | **false** | hold a ring at `keepDistanceRange` |
| `keepDistanceRange` | number | 1..5, **1** | desired path distance when `keepDistance` |
| `anchor` | bool | **false** | when keeping distance, also stay within `anchorRange` of an anchor tile |
| `anchorRange` | number | 1..10, **3** | anchor radius |
| `avoidAttacks` | bool | **false** | side-step out of straight-line wave/beam (§3.5) |
| `faceMonster` | bool | **false** | step out of diagonals / turn to face the monster (§3.6) |
| `rePosition` | bool | **false** | move to a tile with more free neighbours |
| `rePositionAmount` | number | 0..7, **5** | free-neighbour threshold below which repositioning triggers |
| `lure` | bool | **false** | classic luring enabled |
| `lureCount` | number | 0..5, **1** | keep pulling while `targets < lureCount` |
| `lureCavebot` | bool | **false** | lure by letting CaveBot walk instead of walking to the monster |
| `dynamicLure` | bool | **false** | hysteretic luring between `lureMin`/`lureMax` |
| `lureMin` | number | 0..29, **1** | dynamic lure: below/equal this many targets ⇒ start pulling |
| `lureMax` | number | 1..30, **3** | dynamic lure: at/above this many targets ⇒ stop pulling |
| `dynamicLureDelay` | bool | **false** | additionally slow CaveBot down while pulling |
| `lureDelay` | number | 100..1000, **250** | ms of CaveBot delay per player step while pulling |
| `delayFrom` | number | 1..29, **2** | monster count at which `dynamicLureDelay` starts biting |
| `closeLure` | bool | **false** | "close pulling": hand control to CaveBot while few monsters are adjacent |
| `closeLureAmount` | number | 0..8, **3** | close-pull until this many monsters are near |
| `dontLoot` | bool | **false** | **do not queue this creature's corpse** (`looting.lua:315`) |
| `diamondArrows` | bool | **false** | add priority proportional to the mobs inside a 5×5 diamond around the creature |
| `rpSafe` | bool | **false** | PvP-safe: drop the target when out of range, or when any creature is inside the 7×7 large-rune area |

**Fields that the code reads but the vBot 4.8 editor never writes** — they are therefore always `nil`
in every on-disk config and every guarded branch is dead. Reimplement them anyway (they are the upstream
OTClient TargetBot attack model) but default them to off:
`useGroupAttack`, `groupAttackSpell`, `minManaGroup`, `groupAttackRadius`, `groupAttackTargets`,
`groupAttackDelay`, `groupAttackIgnoreParty`, `groupAttackIgnorePlayers`,
`useGroupAttackRune`, `groupAttackRune`, `groupRuneAttackRadius`, `groupRuneAttackTargets`,
`groupRuneAttackDelay`, `useSpellAttack`, `attackSpell`, `minMana`, `attackSpellDelay`,
`useRuneAttack`, `attackRune`, `attackRuneDelay` (`creature_attack.lua:68,86,103,108`). A `grep` over the
whole profile finds no other writer (verified).

There is **no "ignore/avoid creature" flag** — a creature is ignored simply by having no matching entry,
or by matching an entry whose `priority` is 0.

### 1.3 Name → regex
`P/targetbot/creature.lua:21-29` (identical code in `creature_editor.lua:66-72`):

```
if config.regex is absent:
  regex = ""
  for part in name:gmatch("[^,]+"):
     if #regex > 0 then regex = regex .. "|" end
     regex = regex .. "^" .. part:trim():lower():gsub("%*", ".*"):gsub("%?", ".?") .. "$"
```
`"Demon,Vexclaw"` → `"^demon$|^vexclaw$"`; `"*"` → `"^.*$"`.
Matching (`creature.lua:53-72`): `name = creature:getName():trim():lower()`, then
`regexMatch(name, cfg.regex)[1]` for **every** entry in list order; **all matching entries are kept**
(a creature can have several configs). Result cached per lowercase name in `configsCache`; the cache is
flushed when it exceeds 1000 entries (`creature.lua:66`) or when any config is added/edited/removed
(`creature.lua:19`, `target.lua:168,177`).

### 1.4 Global settings that TargetBot reads (persisted in `storage/profile_<N>.json`)
From `P/vBot/extras.lua` (namespace `storage.extras`, written by the extras window, `extras.lua:4-8`):

| storage key | slider range / default | used at |
|---|---|---|
| `extras.killUnder` | 0..100, **1** | `creature_attack.lua:151,171,174` — force chase below this HP% |
| `extras.looting` | 0..50, **40** | `looting.lua:151` — max corpse distance (Chebyshev) |
| `extras.lootDelay` | 0..1000, **200** | `looting.lua:180` — wait after opening a corpse |
| `extras.lootLast` | bool, **true** | `looting.lua:121,153,175,273,280` — take the *last* queue entry |
| `extras.reachable` | bool, false | declared (`extras.lua:143`) but **not used by TargetBot** |
| `foodItems` | list of `{id,count}` | `looting.lua:248-255` — eat while looting |
| `TargetBotDelayWhenPlayer` | bool | `creature_attack.lua:240` — if truthy, suppress dynamic lure delay |
| `targetbotAvoidFloorChange` | bool, **default true when key absent** | `target.lua:39`, `walking.lua:17` |

Real values from `P/storage/profile_1.json`: `"killUnder":1, "looting":40, "lootDelay":220,
"lootLast":true, "reachable":false`, `foodItems` = `[{id:3582,count:1},{id:3577,count:1},
{id:3607,count:1},{id:3585,count:1},{id:3592,count:1},{id:3600,count:1},{id:3601,count:1}]`.

---

## 2. Target selection algorithm (one tick)

`P/targetbot/target.lua:49-128`. Exact order:

### 2.1 Candidate gathering
```
pos   = player:getPosition()
specs = g_map.getSpectatorsInRange(pos, false, 6, 6)          -- 13x13, same floor  [target.lua:51]
n     = count of specs where spec:isMonster()                   [target.lua:53-57]
if n > 10 then candidates = g_map.getSpectatorsInRange(pos, false, 3, 3)  -- 7x7  [target.lua:59]
else            candidates = specs                                        [target.lua:61]
```
(the `creatures` local is reused as both counter and list — harmless.)

For each candidate, in spectator order:
```
hppc = creature:getHealthPercent()
if not hppc or hppc <= 0 then skip                                        [target.lua:68-69]
path = findPath(pos, creature:getPosition(), 7,
        {ignoreLastCreature=true, ignoreNonPathable=true,
         ignoreCost=true, ignoreCreatures=true})                          [target.lua:70]
if creature:isMonster()
   and (clientVersion < 960 or creature:getType() < 3)   -- excludes summons [target.lua:71]
   and path then  ... score it ...
```
So the **hard gates** are: monster, non-summon (`CreatureType < 3`: Player=0, Monster=1, Npc=2,
SummonOwn=3, SummonOther=4 — `S/client/protocolcodes.h:415-423`), alive, inside the 13×13 (or 7×7) box,
**and reachable within 7 BFS steps** ignoring creatures and non-pathable tiles (but *not* ignoring
stairs, so the pathfinder still refuses to route through a yellow non-pathable tile,
`S/client/map.cpp:1428`). `oldTibia` is `g_game.getClientVersion() < 960` (`target.lua:46`) — false at 1530.

### 2.2 Scoring
`TargetBot.Creature.calculateParams(creature, path)` (`P/targetbot/creature.lua:74-93`):
```
priority = 0; danger = 0; selectedConfig = nil
for each matching config (list order):
    p = calculatePriority(creature, config, path)
    if p > priority then                        -- STRICT: first config wins ties
        priority = p
        danger   = calculateDanger(creature, config, path)   -- == config.danger  [creature.lua:97]
        selectedConfig = config
return {config=selectedConfig, creature=creature, danger=danger, priority=priority}
```

`TargetBot.Creature.calculatePriority` (`P/targetbot/creature_priority.lua:1-60`), in exact order:
```
priority = 0
currentTarget = g_game.getAttackingCreature()

1. HYSTERESIS: if currentTarget == creature then priority += 1          [:7-9]

2. RANGE GATE: if #path > config.maxDistance then                      [:12]
       if config.rpSafe and currentTarget == creature then
           g_game.cancelAttackAndFollow()                              [:14-16]
       return priority          -- 0, or 1 if it is the current target

3. priority += config.priority                                         [:22]

4. DISTANCE BONUS (mutually exclusive):
       #path == 1  -> priority += 10                                   [:26-27]
       #path <= 3  -> priority += 5                                    [:28-29]

5. DIAMOND ARROWS (only if config.diamondArrows):                      [:33]
       mobCount = getCreaturesInArea(creaturePos, diamondArrowArea, 2) -- monsters only
       priority += mobCount * 4
       if config.rpSafe and getCreaturesInArea(creaturePos, largeRuneArea, 3) > 0 then
            -- 3 == "players, excluding friends"
            if currentTarget == creature then g_game.cancelAttackAndFollow() end
            return 0                                                   [:37-44]

6. LOW-HP BONUS (if/elseif chain — only ONE fires):                    [:48-58]
       config.chase and hp% < 30  -> +5
       elseif hp% < 20            -> +2.5
       elseif hp% < 40            -> +1.5
       elseif hp% < 60            -> +0.5
       elseif hp% < 80            -> +0.2
return priority
```
Note the chain quirk: with `chase=false` and hp<20 the `< 20` branch gives +2.5; with `chase=true`
and hp<30 the first branch gives +5 and the rest are skipped (so a chased 15% monster gets +5, not +2.5).

`diamondArrowArea` (`P/vBot/vlib.lua:1291`) is 5×5 with the corners cut:
```
01110 / 11111 / 11111 / 11111 / 01110
```
`largeRuneArea` (`P/vBot/vlib.lua:1205`) is 7×7 with the corners cut (2 per corner):
```
0011100 / 0111110 / 1111111 / 1111111 / 1111111 / 0111110 / 0011100
```
`getCreaturesInArea(posOrCreature, pattern, mode)` (`P/vBot/vlib.lua:1055-1078`): centre the pattern on
the position, count spectators inside; mode `1`=everyone, `2`=monsters (excl. summons), else
`3`/anything = players excluding friends. The local player is always excluded.

### 2.3 Selection
Back in the loop (`target.lua:73-83`):
```
dangerLevel += params.danger                      -- 0 when nothing matched / out of range
if params.priority > 0 then
    targets += 1
    if params.priority > highestPriority then     -- STRICT: first in spectator order wins ties
        highestPriority = params.priority
        highestPriorityParams = params
```
* `targets` is the **monster count used by all luring logic**: every creature with a positive score,
  including a current target that is beyond `maxDistance` (it still scores 1 from hysteresis).
* Ties are broken by spectator iteration order: z↑, y↑, x↑ (`S/client/map.cpp:674-687`), i.e.
  top-left-most tile of the box wins.
* There is **no "keep the previous target" rule beyond the +1**. A rival that scores >1 higher steals it,
  and switching happens immediately on the next tick.

### 2.4 Nothing matches
`target.lua:117-127`:
```
ui.target = "-"; ui.config = "-"
if looting then TargetBot.walk(); lastAction = now end
status = lootingStatus (if any) else "Waiting"
```
No attack is issued, no `cancelAttackAndFollow` is sent (the server-side attack simply persists unless
`rpSafe` cancelled it in step 2/5). Because `lastAction` is *not* refreshed, `TargetBot.isActive()`
goes false 300 ms later and CaveBot resumes.

### 2.5 PZ
`target.lua:98` — the attack branch is gated on `not isInPz()`
(`isInPz` = `hasCondition(PlayerStates.Pz)`, `B/functions/player_conditions.lua:31`). Looting is **not**
gated on PZ inside the macro; only corpse *discovery* is (`looting.lua:311`).

---

## 3. Combat behaviour

`TargetBot.Creature.attack(params, targets, isLooting)` — `P/targetbot/creature_attack.lua:50-113`.

### 3.1 Attack command
```
if g_game.getAttackingCreature() ~= creature then g_game.attack(creature) end   [:58-60]
```
Sent at most once per target change; no re-send while the target is unchanged.
In luaclient: `LC.sender:attack(creatureId)` (and track the id you last sent).

### 3.2 Movement gate
```
if not isLooting then TargetBot.Creature.walk(creature, config, targets) end    [:62-64]
```
i.e. **while a corpse is being looted, chasing/keep-distance movement is completely suppressed**; the
looter's own `walkTo` (set by `Looting.process`) is what moves the character.

### 3.3 Spells / runes (all dead in vBot 4.8 — fields never persisted, §1.2)
Evaluated **after** movement, in this exact order, each `return`ing on success so at most one action per
tick (`creature_attack.lua:66-112`):
1. **Group attack spell** — `config.useGroupAttack and #config.groupAttackSpell > 1 and
   player:getMana() > config.minManaGroup`. Count spectators in a `groupAttackRadius` box **around the
   player**; `playersAround` = any non-local player (party members with `shield <= 2` are excluded when
   `groupAttackIgnoreParty`); `monsters` counts `isMonster()` spectators. Fire when
   `monsters >= config.groupAttackTargets and (not playersAround or config.groupAttackIgnorePlayers)`,
   via `TargetBot.sayAttackSpell(spell, config.groupAttackDelay)`.
2. **Group attack rune** — same shape, but the spectator box is centred **on the target creature**
   (`:87`), threshold `groupRuneAttackTargets`, radius `groupRuneAttackRadius`, action
   `TargetBot.useAttackItem(config.groupAttackRune, 0, creature, config.groupRuneAttackDelay)`; requires
   `config.groupAttackRune > 100`.
3. **Single attack spell** — `useSpellAttack and #attackSpell > 1 and mana > minMana` →
   `sayAttackSpell(attackSpell, attackSpellDelay)`.
4. **Single attack rune** — `useRuneAttack and attackRune > 100` →
   `useAttackItem(attackRune, 0, creature, attackRuneDelay)`.

Rate limiters (module-global, shared across all configs — `P/targetbot/target.lua:268-333`):
* `TargetBot.saySpell(text, delay=500)`: fires when `lastSpell + delay < now`; on protocol < 1090 it also
  pushes `lastAttackSpell = now` (healing wins). Not used by TargetBot itself.
* `TargetBot.sayAttackSpell(text, delay=2000)`: fires when `lastAttackSpell + delay < now`, then
  `lastAttackSpell = now`. **Default 2000 ms.**
* `TargetBot.useItem(item, subType, target, delay=200)` / `TargetBot.useAttackItem(..., delay=2000)`:
  gate on `lastItemUse` / `lastRuneAttack`. Non-fluid-container items force `subType = 0` on
  clientVersion >= 860. On >= 780 the action is `g_game.useInventoryItemWith(itemId, target, subType)`
  (a "use from anywhere" hotkey packet); below 780 it looks the item up in the backpacks first.
  **Neither returns a value**, so the `if TargetBot.useAttackItem(...) then return end` guards at
  `creature_attack.lua:98,109` never short-circuit — a rune use falls through to the next branch.

### 3.4 Movement — `TargetBot.Creature.walk(creature, config, targets)` (`creature_attack.lua:115-233`)
Executed top-to-bottom; the **first `return` wins**. `walkTo` only *records* a destination; the actual
step is emitted later by `TargetBot.walk()` (§3.8).

**(a) trapped test** (`:119-127`): for the 8 neighbours (computed as `pos - dir`, which enumerates the
same 8 tiles), `isTrapped = false` as soon as one tile exists and `tile:isWalkable(false)`
(false ⇒ creatures block).

**(b) dynamic-lure hysteresis state** (`:130-145`), only when `lureMin and lureMax and dynamicLure`:
```
if config.lureMin >= targets then targetBotLure = true
elseif targets >= config.lureMax then targetBotLure = false
```
`targetBotLure` is a *module-level latch*, so it survives ticks (that is the hysteresis). Then
`targetCount = targets`, `delayValue = config.lureDelay`, `lureMax = config.lureMax`,
`dynamicLureDelay = config.dynamicLureDelay`, `delayFrom = config.delayFrom`.

**(c) close lure** (`:148-150`):
```
if config.closeLure and config.closeLureAmount <= getMonsters(1) then
    return TargetBot.allowCaveBot(150)
```
`getMonsters(1)` (`P/vBot/vlib.lua:652`) counts non-summon monsters with
`distanceFromPlayer(pos) <= 1` under the §0.4 metric — that is roughly a 5×5 cross, not the 8 neighbours.

**(d) luring** (`:151-168`):
```
if TargetBot.canLure()                                  -- global lureEnabled flag
   and (config.lure or config.lureCavebot or config.dynamicLure)
   and not (creature:getHealthPercent() < (storage.extras.killUnder or 30))
   and not isTrapped then
     if targetBotLure then
         anchorPosition = nil
         return TargetBot.allowCaveBot(150)             -- let CaveBot pull
     elseif targets < config.lureCount then
         if config.lureCavebot then
             anchorPosition = nil; return TargetBot.allowCaveBot(150)
         else
             path = findPath(pos, cpos, 5, {ignoreNonPathable=true, precision=2})
             if path then
                 return TargetBot.walkTo(cpos, 10,
                        {marginMin=5, marginMax=6, ignoreNonPathable=true})
             end
```
i.e. classic luring keeps the character **5–6 tiles away** from the monster (a "hold the pull" ring).

**(e) rePosition** (`:170-173`):
```
currentDistance = findPath(pos, cpos, 10, {ignoreCreatures=true, ignoreNonPathable=true, ignoreCost=true})
if (not config.chase or #currentDistance == 1)
   and not config.avoidAttacks and not config.keepDistance
   and config.rePosition
   and creature:getHealthPercent() >= storage.extras.killUnder then
       return rePosition(config.rePositionAmount or 6)
```
`rePosition(minTiles=8)` (`:22-48`): throttled to once per 500 ms via `lastCall`; count walkable-or-
occupied neighbours of the player (`getWalkableTilesCount`, `:10-20`); if that count `> minTiles`, do
nothing; otherwise pick the neighbouring **free, walkable, creature-less** tile with the highest
neighbour count strictly greater than the player's own, and `CaveBot.GoTo(target, 0)` — which is
`CaveBot.walkTo(position, 20, {ignoreCreatures=true, precision=0})` (`P/vBot/new_cavebot_lib.lua:225`).
NB this uses the **CaveBot** walker, not `TargetBot.walkTo`.
(`currentDistance` can be `nil` when the monster is > 10 steps away → `#nil` raises; in practice the
7-step gate in §2.1 prevents it.)

**(f) chase** (`:174-177`):
```
if ((storage.extras.killUnder > 1 and creature:getHealthPercent() < storage.extras.killUnder)
     or config.chase)
   and not config.keepDistance then
       if #currentDistance > 1 then
           return TargetBot.walkTo(cpos, 10, {ignoreNonPathable=true, precision=1})
```
So: walk to any tile adjacent to the monster; stop once the path length is 1.

**(g) keep distance** (`:178-189`):
```
elseif config.keepDistance then
   if not anchorPosition or distanceFromPlayer(anchorPosition) > config.anchorRange then
       anchorPosition = pos                                  -- (re)anchor here
   if #currentDistance ~= config.keepDistanceRange
      and #currentDistance ~= config.keepDistanceRange + 1 then      -- the dead band
        if config.anchor and anchorPosition
           and getDistanceBetween(pos, anchorPosition) <= config.anchorRange*2 then
             TargetBot.walkTo(cpos, 10, {ignoreNonPathable=true,
                 marginMin=config.keepDistanceRange, marginMax=config.keepDistanceRange+1,
                 maxDistanceFrom={anchorPosition, config.anchorRange}})
        else
             TargetBot.walkTo(cpos, 10, {ignoreNonPathable=true,
                 marginMin=config.keepDistanceRange, marginMax=config.keepDistanceRange+1})
```
**The dead band is exactly `{range, range+1}`** — no movement while the path length is one of those two.

**(h) avoidAttacks — side-step out of a straight line** (`:192-206`), only reached if (f)/(g) did not
return:
```
diffx = cpos.x - pos.x ; diffy = cpos.y - pos.y
if |diffx| == 1 and diffy == 0 then candidates = {(x, y-1), (x, y+1)}
elseif diffx == 0 and |diffy| == 1 then candidates = {(x-1, y), (x+1, y)}
else candidates = {}
for each candidate: if g_map.getTile(c) and tile:isWalkable() then
    return TargetBot.walkTo(c, 2, {ignoreNonPathable=true})
```
(only handles distance-1 alignment; `tile:isWalkable()` defaults `ignoreCreatures=false`,
`S/client/tile.h:75`.)

**(i) faceMonster** (`:207-232`): when the monster is exactly diagonal (`|diffx|==|diffy|==1`), step to
one of two orthogonally-adjacent tiles so the monster ends up straight ahead; otherwise just **turn**:
```
diffx== 1, diffy== 1 -> candidates {(x+1,y), (x,y-1)}
diffx==-1, diffy== 1 -> {(x-1,y), (x,y-1)}
diffx==-1, diffy==-1 -> {(x,y-1), (x-1,y)}
diffx== 1, diffy==-1 -> {(x,y-1), (x+1,y)}
else: dir = player:getDirection()
      diffx== 1 and dir~=1 -> turn(1) East
      diffx==-1 and dir~=3 -> turn(3) West
      diffy== 1 and dir~=2 -> turn(2) South
      diffy==-1 and dir~=0 -> turn(0) North
then walkTo(candidate, 2, {ignoreNonPathable=true}) for the first walkable candidate
```
Direction constants: North=0, East=1, South=2, West=3, NorthEast=4, SouthEast=5, SouthWest=6,
NorthWest=7 (matches `P/cavebot/walking.lua:43-52` `dirDelta`).

### 3.5 The danger aggregate CaveBot consults
`dangerLevel = Σ params.danger` over all scanned creatures (`target.lua:74`); stored in `dangerValue`
(`target.lua:95`) and exposed as `TargetBot.Danger()` (`target.lua:259`).
Because `params.danger` is only set when a config actually won the priority contest
(`creature.lua:83`), creatures out of `maxDistance` or with no config contribute **0**.
Consumers: the looter's own gate (`looting.lua:112`) and `P/vBot/Equipper.lua:600`
(`TargetBot.Danger() > v and TargetBot.isOn()` — condition "TargetBot Danger is Above").

### 3.6 Public state API (what other modules see)
`P/targetbot/target.lua:181-265`:
```
TargetBot.isActive()              -> lastAction + 300 > now
TargetBot.isCaveBotActionAllowed()-> cavebotAllowance > now
TargetBot.allowCaveBot(ms)        -> cavebotAllowance = now + ms
TargetBot.Danger()                -> dangerValue
TargetBot.lootStatus()            -> looterStatus  ("", "Looting", "High danger", "No cap", "No space")
TargetBot.getStatus()/setStatus() -> the status string
TargetBot.isOn()/isOff()/setOn()/setOff()  -> the Config switch
TargetBot.delay(ms)               -> postpone the macro
TargetBot.disableLuring()/enableLuring()/canLure()  -> the global lureEnabled latch
TargetBot.getCurrentProfile()/setCurrentProfile(name)
```
`lastAction = now` is set only on the two "we did something" paths (`target.lua:113`, `:122`).

### 3.7 CaveBot interlock
`P/cavebot/cavebot.lua:81-84`:
```
if TargetBot and TargetBot.isActive() and not TargetBot.isCaveBotActionAllowed() then
    CaveBot.resetWalking(); return
```
So CaveBot is frozen for 300 ms after every TargetBot action, **unless** TargetBot explicitly granted
`allowCaveBot(150)` (the luring paths in §3.4c/d).

`P/targetbot/creature_attack.lua:236-244` — on every player position change:
```
if CaveBot.isOff() or TargetBot.isOff() then return
if not lureMax then return
if storage.TargetBotDelayWhenPlayer then return
if not dynamicLureDelay then return
if targetCount < (delayFrom or lureMax/2) or not target() then return
CaveBot.delay(delayValue or 0)          -- cavebotMacro.delay = max(existing, now + lureDelay)
```
i.e. while pulling with enough monsters behind you, **each step you take costs CaveBot `lureDelay` ms**
(`CaveBot.delay`, `P/cavebot/cavebot.lua:563`).

Also `P/cavebot/lure.lua:5-19`: a CaveBot waypoint action `lure` with value `start|stop|toggle` maps to
`TargetBot.setOff()` / `setOn()` / toggle.

### 3.8 The stepper — `TargetBot.walk()` (`P/targetbot/walking.lua:21-50`)
Called at most once per tick, only after an attack or a looting action.
```
if not dest then return                                   -- walkTo(nil) each tick resets it [target.lua:89]
if player:isWalking() then return                         -- ONE confirmed step at a time
pos = player:getPosition()
if pos.z ~= dest.z then return
dist = max(|pos.x-dest.x|, |pos.y-dest.y|)                -- Chebyshev
if params.precision and params.precision >= dist then return
if params.marginMin and params.marginMax
   and dist >= params.marginMin and dist <= params.marginMax then return
path = getPath(pos, dest, maxDist, params)
if path then
    if TargetBot.avoidFloorChangeEnabled() and CaveBot.wouldStepChangeFloor then
        bad, why = CaveBot.wouldStepChangeFloor(pos, path[1])
        if bad then (log at most every 10 s) return end
    walk(path[1])                                         -- exactly ONE direction
```
`walk(dir)` = `modules.game_walk.smartWalk(dir)` (`B/functions/player.lua:64`) — for a headless client
this is a single `sender:walk(dir)`.

`CaveBot.wouldStepChangeFloor(fromPos, dir)` (`P/cavebot/walking.lua:172-181` → `isFloorChangeTile`,
`:131-165`): returns true when the destination tile is
(a) minimap colour 210..213 **and** `not tile:isPathable()`, or
(b) the ground item's `LensHelp` is a floor-change one, or the ground item is a ground that
`isNotPathable()`, or
(c) the tile's top-use thing is such an item, or
(d) the ground/top item id is in `CaveBot.Config.get("avoidTileIds")` (a comma-separated string).
A tile that is not loaded returns false (fail-open). The whole classifier is `pcall`-wrapped.

`TargetBot.avoidFloorChangeEnabled()` (`walking.lua:16-18`) = `storage.targetbotAvoidFloorChange ~= false`
— **default ON**. The toggle is persisted at storage key `targetbotAvoidFloorChange`
(`P/targetbot/target.lua:39-44`).

---

## 4. Looting

`P/targetbot/looting.lua`. State: `TargetBot.Looting.list` (the corpse queue), plus module locals
`items`, `containers`, `itemsById`, `containersById` (from the config), `waitTill`,
`waitingForContainer`, `status`, `lastFoodConsumption`.

### 4.1 Configuration (`data.looting` in the same JSON file)
`TargetBot.Looting.update(data)` (`:55-75`) / `.save(data)` (`:77-83`):
```
items       = data['items']      or {}   -- list of {id=<itemId>, count=<n>}
containers  = data['containers'] or {}   -- list of {id=<itemId>, count=<n>}
everyItem   = not not data['everyItem']  -- bool
maxDanger   = data['maxDanger']   or 10
minCapacity = data['minCapacity'] or 100
```
**The loot list is by numeric item id only** — no names, no categories, no count/value filters. `count`
is written by the item-widget (`B/functions/ui_elements.lua:45`) but is never read by the looter.
`updateItemsAndContainers` (`:85-96`) builds the `itemsById` / `containersById` sets used for O(1) lookup.
`update` also mirrors the ids into `vBot.lootConainers` / `vBot.lootItems` (`:66-74`) for other scripts.

`everyItem = true` inverts the meaning: the list becomes an **ignore** list (`:243`; label flips to
"Items to ignore", `:11-14`).

### 4.2 Corpse discovery — `onCreatureDisappear` (`:310-341`)
```
if isInPz() then return
if not TargetBot.isOn() then return
if not creature:isMonster() then return
cfg = TargetBot.Creature.calculateParams(creature, {})     -- NOTE: empty path!
if not cfg.config or cfg.config.dontLoot then return
pos = player pos ; mpos = creature pos
if pos.z ~= mpos.z or max(|dx|,|dy|) > 6 then return
schedule(20, function()                                     -- 20 ms later
    if not containers[1] then return                        -- no loot bag configured
    if TargetBot.Looting.list[20] then return               -- queue cap: max 20 entries
    tile = g_map.getTile(mpos); if not tile then return
    container = tile:getTopUseThing()
    if not container or not container:isContainer() then return
    if not findPath(playerPos, mpos, 6,
          {ignoreNonPathable=true, ignoreCreatures=true, ignoreCost=true}) then return
    table.insert(list, {pos=mpos, creature=name, container=container:getId(), added=now, tries=0})
    table.sort(list, function(a,b) a.dist=distanceFromPlayer(a.pos)
                                   b.dist=distanceFromPlayer(b.pos)
                                   return a.dist > b.dist end)     -- FARTHEST FIRST
    container:setMarked('#000088')                          -- widget detail only
end)
```
Important consequences:
* `calculateParams(creature, {})` is called with an **empty path**, so `#path == 0 <= maxDistance` always
  passes the range gate; only "is there any matching config" and `dontLoot` matter.
* The comparator **mutates** the entries (writes `dist`); the sort is a one-shot snapshot at insert time —
  the queue is never re-sorted as the player moves.
* Sorted **descending by distance**, so `list[1]` is the farthest and `list[#list]` the nearest.
  With `storage.extras.lootLast = true` (the default) the looter always takes `list[#list]` = the
  **nearest** corpse, despite the option being labelled "Start loot from last corpse".
* The `container` field (a container-item id) is stored but never read.
* `getTopUseThing` (`S/client/tile.cpp`) = first non-ground/non-border/non-bottom/non-top/non-creature/
  non-splash thing, i.e. the corpse.

`onTextMessage` (`:276-282`): if the message contains `"you are not the owner"` (case-insensitive) and
the queue is non-empty, drop the current entry (same `lootLast` index rule).

### 4.3 The per-tick looting state machine — `TargetBot.Looting.process(targets, dangerLevel)`
Called from the macro at `target.lua:92`, **before** the attack decision, and returns
`true` when looting is "in charge" this tick. Exact order (`looting.lua:107-183`):

```
1. if (no items configured and not everyItem) or no containers configured:
       status = ""; return false                                   [:108-111]
2. if dangerLevel > maxDanger: status = "High danger"; return false [:112-115]
3. if player:getFreeCapacity() < minCapacity:
       status = "No cap"; list = {}; return false                   [:116-120]   -- queue is WIPED
4. loot = lootLast and list[#list] or list[1]
   if loot == nil: status = ""; return false                        [:121-125]
5. if waitTill > now: return true                                   [:127-129]   -- hold everything
6. openContainers = g_game.getContainers()
   lootContainers = getLootContainers(openContainers)               [:130-131]
7. if #lootContainers == 0: status = "No space"; return false        [:134-138]
8. status = "Looting"
9. for each open container with .lootContainer == true:
       lootContainer(lootContainers, container); return true         [:142-147]
10. dist = max(|pos.x-loot.pos.x|, |pos.y-loot.pos.y|)               [:150]
    maxRange = storage.extras.looting or 40
    if loot.tries > 30 or loot.pos.z ~= pos.z or dist > maxRange:
        remove the entry; return true                                [:152-155]
11. tile = g_map.getTile(loot.pos)
    minDist, walkPrecision = 2, 2   (1, 1 when clientVersion <= 760) [:158-166]
    if dist > minDist or not tile:
        loot.tries = loot.tries + 1
        TargetBot.walkTo(loot.pos, 20, {ignoreNonPathable=true, precision=walkPrecision})
        return true                                                  [:167-171]
12. container = tile:getTopUseThing()
    if not container or not container:isContainer():
        remove the entry; return true                                [:173-177]
13. g_game.open(container)                                           [:179]
    waitTill = now + (storage.extras.lootDelay or 200)
    waitingForContainer = container:getId()   -- the ITEM id of the corpse
    return true
```
"remove the entry" = `table.remove(list, lootLast and #list or 1)` — always the same end the reader picked.

`onContainerOpen(container, previousContainer)` (`:303-308`): when the newly opened container's
**container item id** equals `waitingForContainer`, mark `container.lootContainer = true` and clear the
wait. That flag is what step 9 looks for.

### 4.4 Choosing the destination bags — `getLootContainers(openContainers)` (`:186-235`)
```
lootContainers = {} ; openedById = {} ; toOpen = nil
for each open container c:
    openedById[c:getContainerItem():getId()] = 1
    if containersById[c:getContainerItem():getId()] and not c.lootContainer then
        if c:getItemsCount() < c:getCapacity() or c:hasPages() then
            insert c into lootContainers                    -- has room
        else
            for slot,item in ipairs(c:getItems()):
                if item:isContainer() and containersById[item:getId()] then
                    toOpen = {item, c}; break               -- a nested spare bag
if #lootContainers == 0:
    A) if toOpen then g_game.open(toOpen[1], toOpen[2])     -- replace the full bag in its own window
           waitTill = now + 500 ; return {}
    B) for each open container c that is NOT a loot container and not c.lootContainer:
           for slot,item in ipairs(c:getItems()):
               if item:isContainer() and containersById[item:getId()] then
                   g_game.open(item); waitTill = now + 500; return {}
    C) for slot = InventorySlotFirst(1) .. InventorySlotLast(10):
           item = getInventoryItem(slot)
           if item and item:isContainer() and not openedById[item:getId()] then
               g_game.open(item); waitTill = now + 500; return {}
return lootContainers
```
`g_game.open(item, previousContainer)` (`S/client/game.cpp:935`) sends `useItem(itemPos, itemId,
stackpos, containerId)` where `containerId` = the previous container's id, or the lowest free index.

Note step 9 of §4.3 runs **before** the corpse-approach code, so once a corpse container is flagged
`lootContainer` the looter does nothing but empty it.

### 4.5 Emptying a corpse — `lootContainer(lootContainers, container)` (`:237-274`)
```
nextContainer = nil
for i, item in ipairs(container:getItems()):        -- slot order, 1-based
    if item:isContainer() and not itemsById[item:getId()] then
        nextContainer = item                        -- remember (keeps the LAST such slot)
    elseif (not everyItem and itemsById[item:getId()])
        or (everyItem and not item:isContainer() and not itemsById[item:getId()]) then
            item.lootTries = (item.lootTries or 0) + 1
            if item.lootTries < 5 then              -- max 5 attempts (~0.5s each -> ~1.5s)
                return lootItem(lootContainers, item)
    elseif storage.foodItems and storage.foodItems[1]
        and lastFoodConsumption + 5000 < now then
            for _, food in ipairs(storage.foodItems):
                if item:getId() == food.id then
                    g_game.use(item); lastFoodConsumption = now; return

if nextContainer then                               -- a nested bag inside the corpse
    nextContainer.lootTries = (nextContainer.lootTries or 0) + 1
    if nextContainer.lootTries < 2 then             -- max 2 attempts
        g_game.open(nextContainer, container)       -- opens IN PLACE of the corpse window
        waitTill = now + 300
        waitingForContainer = nextContainer:getId()
        return

-- done
container.lootContainer = false
g_game.close(container)
table.remove(list, lootLast and #list or 1)
```
Only **one item is moved per call**, i.e. one item per 100 ms tick, and each move sets `waitTill = now+300`
so the real cadence is one item per ~300–400 ms.

`lootTries` is stored on the *Item userdata*; it therefore survives only as long as that Item object,
which the client recreates whenever the container contents are re-sent. In luaclient, key it on
`(containerId, slot, itemId)` and clear it when the container is closed.

### 4.6 Moving one item — `lootItem(lootContainers, item)` (`:284-301`)
```
if item:isStackable() then
    for _, c in ipairs(lootContainers):
        for slot, citem in ipairs(c:getItems()):
            if item:getId() == citem:getId() and citem:getCount() < 100 then
                g_game.move(item, c:getSlotPosition(slot - 1), item:getCount())   -- MERGE full stack
                waitTill = now + 300 ; return
-- fallback: append
c = lootContainers[1]
g_game.move(item, c:getSlotPosition(c:getItemsCount()), 1)                        -- count = 1 !
waitTill = now + 300
```
`getSlotPosition(slot)` (`S/client/container.h:37`) = `{x = 0xFFFF, y = containerId | 0x40, z = slot}`
(**0-based slot**, hence `slot - 1` in the merge branch). The wire stackpos for an item inside a container
is that same `z` (`S/client/thing.cpp:94-97`).
`g_game.move` clamps `count <= 0` to 1 (`S/client/game.cpp:804`).

Consequence of the `1` in the fallback: a fresh stack (e.g. gold) is first moved **one unit** into the
loot bag; on the next pass the merge branch finds the partial stack and moves the rest in one go. Two
moves, ~600 ms, per new stackable type. Reproduce it verbatim if you want identical timing.

### 4.7 Interleaving with fighting and CaveBot
Per tick (`target.lua:88-127`):
```
TargetBot.walkTo(nil)                              -- clear the movement destination
looting      = TargetBot.Looting.process(targets, dangerLevel)
lootingStatus= TargetBot.Looting.getStatus()
dangerValue  = dangerLevel
if highestPriorityParams and not isInPz() then
    TargetBot.Creature.attack(params, targets, looting)   -- 'looting' suppresses chase movement
    status = lootingStatus ~= "" and ("Attack & "..lootingStatus)
             or (cavebotAllowance > now and "Luring using CaveBot")
             or (lureEnabled and "Attacking" or "Attacking (luring off)")
    TargetBot.walk() ; lastAction = now ; return
if looting then TargetBot.walk(); lastAction = now end
status = lootingStatus ~= "" and lootingStatus or "Waiting"
```
So:
* **Attacking always wins the tick**; looting still runs (its `walkTo` is what the stepper executes),
  but chase/keep-distance movement is skipped while `looting == true`.
* Either branch sets `lastAction = now`, which blocks CaveBot for the next 300 ms.
* HealBot backs off while the looter is busy: `if TargetBot.isOn() and
  TargetBot.Looting.getStatus():len() > 0 and Interval then delay(700 or 200) end`
  (`P/vBot/HealBot.lua:767-773`).

### 4.8 All looting timers in one place
| event | value | cite |
|---|---|---|
| macro period | 100 ms | `target.lua:49` |
| corpse-check delay after `onCreatureDisappear` | 20 ms | `looting.lua:323` |
| queue cap | 20 entries | `looting.lua:325` |
| discovery radius (Chebyshev) | 6 | `looting.lua:322` |
| discovery path budget | 6 steps | `looting.lua:330` |
| walk-to-corpse attempts before dropping | `tries > 30` | `looting.lua:152` |
| max corpse distance | `storage.extras.looting`, default 40 | `looting.lua:151` |
| loot-from distance (v > 760) | ≤ 2, walk precision 2 | `looting.lua:158-166` |
| wait after opening a corpse | `storage.extras.lootDelay`, default 200 (220 on this profile) | `looting.lua:180` |
| wait after opening a nested/spare bag | 300 ms | `looting.lua:264` |
| wait after opening a fallback loot bag | 500 ms | `looting.lua:208,217,229` |
| wait after moving an item | 300 ms | `looting.lua:291,300` |
| per-item move attempts | `< 5` | `looting.lua:245` |
| nested-container open attempts | `< 2` | `looting.lua:262` |
| food re-use interval | 5000 ms | `looting.lua:248` |

### 4.9 Combat timers
| event | value | cite |
|---|---|---|
| attack spell / group spell | `sayAttackSpell` default 2000 ms, or `config.*Delay` | `target.lua:285-294` |
| attack rune | `useAttackItem` default 2000 ms, or `config.*Delay` | `target.lua:317-333` |
| generic spell | `saySpell` default 500 ms | `target.lua:271-284` |
| generic item use | `useItem` default 200 ms | `target.lua:299-316` |
| `rePosition` throttle | 500 ms | `creature_attack.lua:24` |
| CaveBot allowance granted by luring | 150 ms | `creature_attack.lua:149,154,159` |
| CaveBot freeze after any TargetBot action | 300 ms | `target.lua:183` |
| CaveBot per-step lure delay | `config.lureDelay` (100..1000) | `creature_attack.lua:244` |
| avoid-floor-change log throttle | 10000 ms | `walking.lua:42` |
| one walk step at a time | gated on `player:isWalking()` | `walking.lua:23` |

---

## 5. Widget-detail vs behaviour (explicit separation)

**Pure widget detail — a headless client must NOT reproduce it:**
* every `ui.status/target/config/danger` label update (`target.lua:17-24, 97-118`);
* the target-list `TextList` and its `TargetBotEntry` children — but note that
  `TargetBot.targetList:getChildren()` is *the actual storage of the creature configs*
  (`creature.lua:61`, `target.lua:240`). A headless port must keep a plain Lua array of config tables
  and index it the same way (list order, first match wins on priority ties);
* `ui.editor.debug` "Show target priority" and `creature:setText(...)` overlays (`target.lua:26-34, 80-82`);
* `container:setMarked('#000088')` on discovered corpses (`looting.lua:339`);
* `configButton` show/hide of the editor, the `TargetBotCreatureEditorWindow` itself, all scroll bars,
  check boxes and `BotItem` widgets (`creature_editor.lua`, `creature_editor.otui`);
* `ui.labelToLoot` text flip (`looting.lua:11-14`).

**Widget-backed values that ARE behaviour** (read every tick from a widget, persisted in the JSON):
* `ui.everyItem:isOn()` → `looting.everyItem` (`looting.lua:82, 108, 243`);
* `ui.maxDangerPanel.value` → `looting.maxDanger` (`looting.lua:80, 112`);
* `ui.minCapacityPanel.value` → `looting.minCapacity` (`looting.lua:81, 116`);
* `ui.items` / `ui.containers` (`BotContainer`) → `looting.items` / `looting.containers`, each a list of
  `{id=<number>, count=<number>}` (`looting.lua:78-79`);
* `ui.avoidFloorChange` → `storage.targetbotAvoidFloorChange` (`target.lua:39-44`);
* the whole creature editor → one entry of `targeting[]`.

---

## 6. Mapping to the luaclient API

| vBot / otclient | luaclient equivalent |
|---|---|
| `macro(100, fn)` | `LC.sched.every(100, fn)` (drive on the existing 10 ms loop; add a `delayUntil` field) |
| `now` | `sys.nowMs()`, snapshot once per tick |
| `player:getPosition()` | `LC.state.player.pos` |
| `player:getMana()` / `getFreeCapacity()` | `LC.state.player.mana` / `maxCapacity - capacity`… use `LC.state.player.capacity` (free cap as sent) |
| `player:isWalking()` | you must model it: true between sending a walk and receiving the confirming `creatureMove`/`positionChange`, or `walkCancel` |
| `g_map.getSpectatorsInRange(pos,false,r,r)` | scan `LC.state.map` tiles in the box, collect `things[k].kind=='creature'` → `LC.state.creatures[creatureId]` |
| `creature:isMonster()` / `getType()` | `c.isMonster`; **`type` is the raw creature type byte — filter `type < 3`** |
| `creature:getHealthPercent()` | `c.healthPercent` |
| `creature:getName()` | `c.name` |
| `g_game.getAttackingCreature()` | track it yourself: the id last passed to `sender:attack` (clear on `attackCancel` / `creatureDisappear`) |
| `g_game.attack(c)` / `cancelAttackAndFollow()` | `LC.sender:attack(id)` / `LC.sender:cancelAttackAndFollow()` |
| `walk(dir)` | `LC.sender:walk(dir)` |
| `turn(dir)` | `LC.sender:turn(dir)` |
| `say(text)` | `LC.sender:talk(mode=1, 0, nil, text)` |
| `g_game.useInventoryItemWith(id, target, sub)` | `LC.sender:useOnCreature(HOTKEY_POS, itemId, 0, creatureId)` with `HOTKEY_POS = {x=0xFFFF,y=0,z=0}` |
| `g_game.use(item)` | `LC.sender:use(item.pos, item.id, stackpos, 0)` |
| `g_game.open(item, prev)` | `LC.sender:openContainer(item.pos, item.id, stackpos, prev and prev.id or lowestFreeContainerId())` |
| `g_game.close(container)` | `LC.sender:closeContainer(container.id)` |
| `g_game.move(item, toPos, n)` | `LC.sender:move(item.pos, item.id, item.stackpos, toPos, n)` |
| `container:getSlotPosition(s)` | `{x=0xFFFF, y=bit.bor(containerId,0x40), z=s}` (0-based `s`) |
| `container:getItems()/getItemsCount()/getCapacity()/hasPages()` | `LC.state.containers[id].items / #items / .capacity / .hasPages` |
| `container:getContainerItem():getId()` | you must remember which **item id** each open container was opened from (record it when you send `openContainer`, confirm on `containerOpen`) |
| `tile:getTopUseThing()` | scan `LC.state.map:tile(pos).things` with the §4.2 rule; container-ness from `items.flags(id)` bit `items.CONTAINER` |
| `item:isStackable()` | `items.flags(id)` bit `items.CUMULATIVE` |
| `tile:isWalkable()/isPathable()` | **missing** — see Pitfalls |
| `isInPz()` | `LC.state.player.states` bit for PZ |
| `findPath(...)` | new module (§0.3) |
| `onCreatureDisappear` | `LC.events.on('creatureDisappear', ...)` |
| `onContainerOpen` | `LC.events.on('containerOpen', ...)` |
| `onTextMessage` | `LC.events.on('textMessage', ...)` |
| `onPlayerPositionChange` | `LC.events.on('positionChange', ...)` |


## Configuration format

## A. Creature/looting config — `<botProfile>/targetbot_configs/<name>.json`

Written by `Config.save` → `json.encode(value, 2)` (`mods/game_bot/functions/config.lua:106`).
Top level is an object with exactly two keys, `targeting` (array) and `looting` (object). Key order is
Lua-table order, i.e. arbitrary — parse by key, never by position. A brand-new config created from the
UI is literally `{}` (`config.lua:194`), and one profile on disk is even `[]`
(`targetbot_configs/true_asuras.json`) — handle both as "empty".

```jsonc
{
  "targeting": [                       // array of creature entries, list order = tie-break order
    {
      "name": "Dark Torturer",         // string, comma-separated patterns, * and ? wildcards
      "regex": "^dark torturer$",      // cached ECMAScript alternation derived from name
      "priority": 4,                   // 0..10
      "danger": 1,                     // 0..10
      "maxDistance": 8,                // 1..10 path steps
      "chase": true,                   // bool
      "keepDistance": false,
      "keepDistanceRange": 1,          // 1..5
      "anchor": false,
      "anchorRange": 3,                // 1..10
      "avoidAttacks": false,
      "faceMonster": false,
      "rePosition": true,
      "rePositionAmount": 7,           // 0..7
      "lure": false,
      "lureCount": 1,                  // 0..5
      "lureCavebot": false,
      "dynamicLure": true,
      "lureMin": 3,                    // 0..29
      "lureMax": 9,                    // 1..30
      "dynamicLureDelay": true,
      "lureDelay": 655,                // 100..1000 ms
      "delayFrom": 4,                  // 1..29
      "closeLure": true,
      "closeLureAmount": 6,            // 0..8
      "dontLoot": false,
      "diamondArrows": true,
      "rpSafe": false
    }
    // ... more entries
  ],
  "looting": {
    "items":      [ {"id": 16131, "count": 0}, {"id": 9636, "count": 0} ],  // count is IGNORED
    "containers": [ {"id": 23721, "count": 0} ],                            // backpack ITEM ids
    "everyItem":  false,     // true => `items` becomes an IGNORE list
    "maxDanger":  10,        // number; looting is skipped while dangerLevel > this
    "minCapacity": 100       // number; below this free cap the queue is WIPED and looting stops
  }
}
```

### Real file verbatim — `profiles/bot/vBot_4.8/targetbot_configs/true_asura.json`
```json
{"targeting":[{"lureMax":5,"lureMin":2,"dynamicLure":true,"lureDelay":536,"rePosition":true,"closeLureAmount":6,"regex":"^.*$","rpSafe":false,"lureCavebot":false,"lureCount":1,"anchor":false,"rePositionAmount":7,"name":"*","keepDistanceRange":1,"priority":1,"danger":1,"maxDistance":10,"diamondArrows":false,"closeLure":false,"keepDistance":false,"avoidAttacks":false,"chase":true,"dynamicLureDelay":true,"faceMonster":false,"lure":false,"dontLoot":true,"delayFrom":4,"anchorRange":3}],"looting":{"maxDanger":10,"containers":[{"id":23721,"count":0}],"minCapacity":100,"items":[{"id":16131,"count":0},{"id":9636,"count":0}],"everyItem":false}}
```

### Real multi-entry file — `targetbot_configs/turter.json` (4 entries, priorities 4/3/2/1)
`{"targeting":[{... "name":"Dark Torturer","regex":"^dark torturer$","priority":4,"maxDistance":8,"diamondArrows":true,"closeLure":true,"closeLureAmount":6,"lureMax":9,"lureMin":3,"lureDelay":655,"delayFrom":4,"dontLoot":false ...},{... "name":"Betrayed Wraith","priority":3 ...},{... "name":"Lost Soul","priority":2 ...},{... "name":"Hand Of Cursed Fate","regex":"^hand of cursed fate$","priority":1,"chase":false,"dontLoot":true,"lureMax":12 ...}],"looting":{"everyItem":false,"containers":[],"minCapacity":100,"items":[],"maxDanger":25}}`

### Multi-name pattern example — `targetbot_configs/hellhub.json`
`"name":"Demon,Vexclaw,Grimeleech,Blightwalker,Undead Dragon"` →
`"regex":"^demon$|^vexclaw$|^grimeleech$|^blightwalker$|^undead dragon$"`

---

## B. Runtime/global settings — `<botProfile>/storage/profile_<N>.json`

`N` = `g_settings.getNumber('profile')` (`mods/game_bot/bot.lua:273`); the file is the whole `storage`
table serialised with `json.encode(botStorage, 2)` (`bot.lua:311`) on every `save()`.
Excerpt of the real file `profiles/bot/vBot_4.8/storage/profile_1.json` (44 975 bytes), only the
TargetBot-relevant keys:

```json
{
  "_configs": {
    "targetbot_configs": { "enabled": false, "selected": "true_asura" },
    "cavebot_configs":   { "enabled": false, "selected": "true_asura_mk" }
  },
  "extras": {
    "killUnder": 1,
    "looting": 40,
    "lootDelay": 220,
    "lootLast": true,
    "reachable": false,
    "pathfinding": true,
    "gotoMaxDistance": 64,
    "talkDelay": 1000,
    "huntRoutes": 300,
    "joinBot": false,
    "highlightTarget": true
  },
  "foodItems": [
    {"count":1,"id":3582},{"count":1,"id":3577},{"count":1,"id":3607},
    {"count":1,"id":3585},{"count":1,"id":3592},{"count":1,"id":3600},{"count":1,"id":3601}
  ]
}
```
Keys absent from this dump but read by TargetBot, with their effective defaults:
* `targetbotAvoidFloorChange` — absent ⇒ **true** (`storage.targetbotAvoidFloorChange ~= false`,
  `targetbot/walking.lua:17`).
* `TargetBotDelayWhenPlayer` — absent ⇒ falsy ⇒ the dynamic lure delay is active
  (`targetbot/creature_attack.lua:240`).
* `_macros` — the per-name macro on/off map; TargetBot's macro is unnamed so it is not stored there.

A headless client should read exactly these two files: one JSON for the hunt profile, one JSON for the
global switches. Nothing else about TargetBot is persisted.

## Pseudocode

-- ============================================================================
-- TargetBot for luaclient. Everything below is expressed against API.md:
--   LC.state (player/creatures/map/containers), LC.sender, LC.sched, LC.events,
--   proto/items.lua flags. `pf` = the Dijkstra module you must add (see §0.3).
-- ============================================================================

local bit   = require('bit')
local items = require('proto.items')

local TB = {
  cfg          = nil,   -- parsed targetbot_configs/<selected>.json
  configsCache = {},    -- lowercase name -> {config,...}
  cached       = 0,
  -- combat state
  attackingId  = nil,   -- last id sent to sender:attack
  lastAction   = 0,     -- CaveBot interlock
  cavebotAllow = 0,
  lureEnabled  = true,
  dangerValue  = 0,
  targetBotLure= false, -- dynamic-lure latch (module-level ON PURPOSE)
  anchorPos    = nil,
  lastRePos    = 0,
  -- spell/rune rate limits (global, shared across configs)
  lastSpell=0, lastAttackSpell=0, lastItemUse=0, lastRuneAttack=0,
  -- walking
  dest=nil, maxDist=nil, params=nil,
  -- looting
  lootList = {},        -- {pos=,creature=,container=,added=,tries=}
  waitTill = 0,
  waitingForContainerItemId = nil,
  lootStatus = "",
  lastFood = 0,
  lootTries = {},       -- key "cid:slot:itemid" -> n
  openedFromItemId = {},-- containerId -> item id it was opened from
}

local HOTKEY_POS = {x=0xFFFF, y=0, z=0}

-- ---------------------------------------------------------------- distances
local function chebyshev(a,b) return math.max(math.abs(a.x-b.x), math.abs(a.y-b.y)) end
local function tibiaDist(a,b)                      -- getDistanceBetween, battle.lua:1881
  local xd, yd = math.abs(a.x-b.x), math.abs(a.y-b.y)
  if xd > 0 then xd = xd - 1 end
  if yd > 0 then yd = yd - 1 end
  return xd + yd
end
local function distFromPlayer(p) return tibiaDist(LC.state.player.pos, p) end

-- --------------------------------------------------------------- spectators
-- z outer, y middle, x inner, ALL ASCENDING (map.cpp:674) - tie-break depends on it
local function spectatorsInRange(center, r)
  local out = {}
  for y = center.y - r, center.y + r do
    for x = center.x - r, center.x + r do
      local t = LC.state:tile({x=x, y=y, z=center.z})
      if t then
        for _, th in ipairs(t.things) do
          if th.kind == 'creature' then
            local c = LC.state:getCreature(th.creatureId)
            if c and c.id ~= LC.state.player.id then out[#out+1] = c end
          end
        end
      end
    end
  end
  return out
end

-- ------------------------------------------------------------- config match
local function buildRegex(name)                    -- creature.lua:21-29
  local re = ""
  for part in name:gmatch("[^,]+") do
    if #re > 0 then re = re .. "|" end
    re = re .. "^" .. part:gsub("^%s+",""):gsub("%s+$",""):lower()
                       :gsub("%*", ".*"):gsub("%?", ".?") .. "$"
  end
  return re
end
-- NOTE: vBot uses std::regex (ECMAScript). With only Lua patterns available,
-- compile each alternative separately into a Lua pattern and OR the results.
local function matchesName(lowerName, cfg) --> bool  (implement per alternative)
  for alt in cfg.regex:gmatch("[^|]+") do
    if lowerName:match(alt:gsub("%.%*",".-"):gsub("%.%?",".?")) then return true end
  end
  return false
end

function TB.getConfigs(creature)
  local name = (creature.name or ""):gsub("^%s+",""):gsub("%s+$",""):lower()
  local hit = TB.configsCache[name]; if hit then return hit end
  local out = {}
  for _, c in ipairs(TB.cfg.targeting) do
    if matchesName(name, c) then out[#out+1] = c end
  end
  if TB.cached > 1000 then TB.configsCache, TB.cached = {}, 0 end
  TB.configsCache[name] = out; TB.cached = TB.cached + 1
  return out
end

-- ------------------------------------------------------- priority (verbatim)
local DIAMOND_AREA = {"01110","11111","11111","11111","01110"}     -- vlib.lua:1291
local LARGE_RUNE_AREA = {"0011100","0111110","1111111","1111111",
                         "1111111","0111110","0011100"}            -- vlib.lua:1205
-- countInArea(centerPos, area, mode) : mode 2 = monsters(type<3), 3 = non-friend players

function TB.calculatePriority(creature, cfg, pathLen)   -- creature_priority.lua
  local priority = 0
  if TB.attackingId == creature.id then priority = priority + 1 end          -- hysteresis

  if pathLen > cfg.maxDistance then
    if cfg.rpSafe and TB.attackingId == creature.id then
      LC.sender:cancelAttackAndFollow(); TB.attackingId = nil
    end
    return priority                                                          -- 0 or 1
  end

  priority = priority + cfg.priority

  if     pathLen == 1 then priority = priority + 10
  elseif pathLen <= 3 then priority = priority + 5 end

  if cfg.diamondArrows then
    priority = priority + countInArea(creature.pos, DIAMOND_AREA, 2) * 4
    if cfg.rpSafe and countInArea(creature.pos, LARGE_RUNE_AREA, 3) > 0 then
      if TB.attackingId == creature.id then
        LC.sender:cancelAttackAndFollow(); TB.attackingId = nil
      end
      return 0
    end
  end

  local hp = creature.healthPercent
  if     cfg.chase and hp < 30 then priority = priority + 5
  elseif hp < 20 then priority = priority + 2.5
  elseif hp < 40 then priority = priority + 1.5
  elseif hp < 60 then priority = priority + 0.5
  elseif hp < 80 then priority = priority + 0.2 end

  return priority
end

function TB.calculateParams(creature, pathLen)          -- creature.lua:74
  local priority, danger, sel = 0, 0, nil
  for _, cfg in ipairs(TB.getConfigs(creature)) do
    local p = TB.calculatePriority(creature, cfg, pathLen)
    if p > priority then priority, danger, sel = p, cfg.danger, cfg end  -- STRICT >
  end
  return {config=sel, creature=creature, danger=danger, priority=priority}
end

-- ================================================================ MAIN TICK
-- LC.sched.every(100, TB.tick)
function TB.tick()
  local now = LC.sched.now()
  if TB.delayUntil and TB.delayUntil > now then return end
  local pos = LC.state.player.pos

  -- 1. candidates ---------------------------------------------------------
  local specs = spectatorsInRange(pos, 6)                    -- 13x13
  local nMon = 0
  for _, c in ipairs(specs) do if c.isMonster then nMon = nMon + 1 end end
  local cands = (nMon > 10) and spectatorsInRange(pos, 3) or specs   -- 7x7

  local highestPriority, highestParams, dangerLevel, targets = 0, nil, 0, 0
  for _, c in ipairs(cands) do
    local hp = c.healthPercent
    if hp and hp > 0 and c.isMonster and c.type < 3 then
      local path = pf.findPath(pos, c.pos, 7, {
        ignoreLastCreature=true, ignoreNonPathable=true,
        ignoreCost=true, ignoreCreatures=true })
      if path then
        local p = TB.calculateParams(c, #path)
        dangerLevel = dangerLevel + p.danger
        if p.priority > 0 then
          targets = targets + 1
          if p.priority > highestPriority then                 -- STRICT >
            highestPriority, highestParams = p.priority, p
          end
        end
      end
    end
  end

  -- 2. reset movement, run looter ----------------------------------------
  TB.walkTo(nil)
  local looting = TB.lootingProcess(targets, dangerLevel)
  TB.dangerValue = dangerLevel

  -- 3. attack wins the tick ----------------------------------------------
  if highestParams and not TB.isInPz() then
    TB.attack(highestParams, targets, looting)
    TB.walk(); TB.lastAction = now; return
  end
  if looting then TB.walk(); TB.lastAction = now end
end

-- ================================================================== COMBAT
function TB.attack(params, targets, isLooting)          -- creature_attack.lua:50
  local cfg, c = params.config, params.creature
  if TB.attackingId ~= c.id then
    LC.sender:attack(c.id); TB.attackingId = c.id
  end
  if not isLooting then TB.creatureWalk(c, cfg, targets) end

  -- spell/rune block: dead in vBot 4.8 (fields never persisted) but keep the
  -- exact ordering + rate limits if you ever populate them.
  local now, mana = LC.sched.now(), LC.state.player.mana
  if cfg.useGroupAttack and cfg.groupAttackSpell and #cfg.groupAttackSpell > 1
     and mana > cfg.minManaGroup then
    local mons, players = 0, false
    for _, s in ipairs(spectatorsInRange(LC.state.player.pos, cfg.groupAttackRadius)) do
      if s.isPlayer and (not cfg.groupAttackIgnoreParty or s.shield <= 2) then players = true
      elseif s.isMonster then mons = mons + 1 end
    end
    if mons >= cfg.groupAttackTargets and (not players or cfg.groupAttackIgnorePlayers) then
      if TB.sayAttackSpell(cfg.groupAttackSpell, cfg.groupAttackDelay) then return end
    end
  end
  -- (2) group rune: same, spectators centred on c.pos, useAttackItem(...)
  -- (3) if cfg.useSpellAttack and #cfg.attackSpell>1 and mana>cfg.minMana
  --        -> sayAttackSpell(cfg.attackSpell, cfg.attackSpellDelay)
  -- (4) if cfg.useRuneAttack and cfg.attackRune>100
  --        -> useAttackItem(cfg.attackRune, 0, c, cfg.attackRuneDelay)
end

function TB.sayAttackSpell(text, delay)                 -- target.lua:285
  if type(text) ~= 'string' or #text < 1 then return end
  delay = delay or 2000
  local now = LC.sched.now()
  if TB.lastAttackSpell + delay < now then
    LC.sender:talk(1, 0, nil, text); TB.lastAttackSpell = now; return true
  end
  return false
end

function TB.useAttackItem(itemId, subType, creature, delay)   -- target.lua:317
  delay = delay or 2000
  local now = LC.sched.now()
  if TB.lastRuneAttack + delay < now then
    if not isFluidContainer(itemId) then subType = 0 end      -- clientVersion >= 860
    LC.sender:useOnCreature(HOTKEY_POS, itemId, 0, creature.id)
    TB.lastRuneAttack = now
  end
  -- NOTE: returns nil, exactly like vBot. The callers' `if ... then return end`
  -- therefore never short-circuits. Keep it for behavioural fidelity.
end

-- ------------------------------------------------------------- movement AI
function TB.creatureWalk(c, cfg, targets)               -- creature_attack.lua:115
  local pos, cpos, now = LC.state.player.pos, c.pos, LC.sched.now()

  -- (a) trapped?
  local trapped = true
  for _, d in ipairs{{-1,1},{0,1},{1,1},{-1,0},{1,0},{-1,-1},{0,-1},{1,-1}} do
    if isWalkable({x=pos.x-d[1], y=pos.y-d[2], z=pos.z}, false) then trapped = false end
  end

  -- (b) dynamic lure latch
  if cfg.lureMin and cfg.lureMax and cfg.dynamicLure then
    if cfg.lureMin >= targets then TB.targetBotLure = true
    elseif targets >= cfg.lureMax then TB.targetBotLure = false end
  end
  TB.targetCount, TB.delayValue = targets, cfg.lureDelay
  if cfg.lureMax then TB.lureMax = cfg.lureMax end
  TB.dynamicLureDelay, TB.delayFrom = cfg.dynamicLureDelay, cfg.delayFrom

  -- (c) close lure
  if cfg.closeLure and cfg.closeLureAmount <= countMonstersWithin(1) then
    TB.cavebotAllow = now + 150; return
  end

  -- (d) luring
  local killUnder = TB.storage.extras.killUnder or 1
  if TB.lureEnabled and (cfg.lure or cfg.lureCavebot or cfg.dynamicLure)
     and not (c.healthPercent < (killUnder or 30)) and not trapped then
    if TB.targetBotLure then
      TB.anchorPos = nil; TB.cavebotAllow = now + 150; return
    elseif targets < cfg.lureCount then
      if cfg.lureCavebot then
        TB.anchorPos = nil; TB.cavebotAllow = now + 150; return
      else
        if pf.findPath(pos, cpos, 5, {ignoreNonPathable=true, precision=2}) then
          return TB.walkTo(cpos, 10, {marginMin=5, marginMax=6, ignoreNonPathable=true})
        end
      end
    end
  end

  local cur = pf.findPath(pos, cpos, 10,
                {ignoreCreatures=true, ignoreNonPathable=true, ignoreCost=true})
  local curLen = cur and #cur or 999

  -- (e) rePosition
  if (not cfg.chase or curLen == 1) and not cfg.avoidAttacks and not cfg.keepDistance
     and cfg.rePosition and c.healthPercent >= killUnder then
    return TB.rePosition(cfg.rePositionAmount or 6)
  end

  -- (f) chase
  if ((killUnder > 1 and c.healthPercent < killUnder) or cfg.chase)
     and not cfg.keepDistance then
    if curLen > 1 then
      return TB.walkTo(cpos, 10, {ignoreNonPathable=true, precision=1})
    end
  -- (g) keep distance
  elseif cfg.keepDistance then
    if not TB.anchorPos or distFromPlayer(TB.anchorPos) > cfg.anchorRange then
      TB.anchorPos = {x=pos.x,y=pos.y,z=pos.z}
    end
    if curLen ~= cfg.keepDistanceRange and curLen ~= cfg.keepDistanceRange + 1 then
      local p = {ignoreNonPathable=true,
                 marginMin=cfg.keepDistanceRange, marginMax=cfg.keepDistanceRange+1}
      if cfg.anchor and TB.anchorPos
         and tibiaDist(pos, TB.anchorPos) <= cfg.anchorRange*2 then
        p.maxDistanceFrom = {TB.anchorPos, cfg.anchorRange}
      end
      return TB.walkTo(cpos, 10, p)
    end
  end

  -- (h) avoidAttacks  /  (i) faceMonster  -- see spec §3.4h,i for the exact
  --     candidate tables and the turn() fallback; both end with
  --     TB.walkTo(candidate, 2, {ignoreNonPathable=true})
end

function TB.rePosition(minTiles)                        -- creature_attack.lua:22
  minTiles = minTiles or 8
  local now = LC.sched.now()
  if now - TB.lastRePos < 500 then return end
  local pos = LC.state.player.pos
  local mine = walkableNeighbourCount(pos)              -- walkable OR has creatures
  if mine > minTiles then return end
  local best, target = 0, nil
  for _, np in ipairs(neighbours(pos)) do
    if not hasCreature(np) and isWalkable(np, false) then
      local v = walkableNeighbourCount(np)
      if v > best and v > mine then best, target = v, np end
    end
  end
  if target then
    TB.lastRePos = now
    CaveBot.walkTo(target, 20, {ignoreCreatures=true, precision=0})   -- CaveBot walker!
  end
end

-- ------------------------------------------------------------- the stepper
function TB.walkTo(dest, maxDist, params)
  TB.dest, TB.maxDist, TB.params = dest, maxDist, params
end

function TB.walk()                                      -- walking.lua:21
  if not TB.dest then return end
  if TB.isWalking() then return end                     -- ONE confirmed step at a time
  local pos, d = LC.state.player.pos, TB.dest
  if pos.z ~= d.z then return end
  local dist = chebyshev(pos, d)
  if TB.params.precision and TB.params.precision >= dist then return end
  if TB.params.marginMin and TB.params.marginMax
     and dist >= TB.params.marginMin and dist <= TB.params.marginMax then return end
  local path = pf.findPath(pos, d, TB.maxDist, TB.params)
  if not path or #path == 0 then return end
  if TB.avoidFloorChangeEnabled() and wouldStepChangeFloor(pos, path[1]) then return end
  LC.sender:walk(path[1])
  TB.markWalking()
end

-- ================================================================= LOOTING
LC.events.on('creatureDisappear', function(c)           -- looting.lua:310
  if TB.isInPz() or not TB.isOn() or not c.isMonster then return end
  local p = TB.calculateParams(c, 0)                    -- EMPTY path => range gate passes
  if not p.config or p.config.dontLoot then return end
  local ppos, mpos = LC.state.player.pos, c.pos
  if not ppos or not mpos then return end
  if ppos.z ~= mpos.z or chebyshev(ppos, mpos) > 6 then return end
  local name = c.name
  LC.sched.after(20, function()
    if not TB.cfg.looting.containers[1] then return end
    if TB.lootList[20] then return end                  -- cap 20
    local cid = topUseContainerId(mpos); if not cid then return end
    if not pf.findPath(LC.state.player.pos, mpos, 6,
         {ignoreNonPathable=true, ignoreCreatures=true, ignoreCost=true}) then return end
    TB.lootList[#TB.lootList+1] =
      {pos=mpos, creature=name, container=cid, added=LC.sched.now(), tries=0}
    table.sort(TB.lootList, function(a,b)
      a.dist, b.dist = distFromPlayer(a.pos), distFromPlayer(b.pos)
      return a.dist > b.dist                            -- FARTHEST FIRST
    end)
  end)
end)

LC.events.on('textMessage', function(m)                 -- looting.lua:276
  if not TB.isOn() or #TB.lootList == 0 then return end
  if m.text:lower():find("you are not the owner", 1, true) then TB.popLoot() end
end)

LC.events.on('containerOpen', function(ct)              -- looting.lua:303
  local fromItemId = TB.openedFromItemId[ct.id]
  if fromItemId and fromItemId == TB.waitingForContainerItemId then
    TB.isLootContainer[ct.id] = true
    TB.waitingForContainerItemId = nil
  end
end)

function TB.popLoot()                                   -- the lootLast index rule
  local lootLast = TB.storage.extras.lootLast ~= false
  table.remove(TB.lootList, lootLast and #TB.lootList or 1)
end

function TB.lootingProcess(targets, dangerLevel)        -- looting.lua:107
  local L = TB.cfg.looting
  if (not L.items[1] and not L.everyItem) or not L.containers[1] then
    TB.lootStatus = ""; return false end
  if dangerLevel > (L.maxDanger or 10) then TB.lootStatus = "High danger"; return false end
  if LC.state.player.capacity < (L.minCapacity or 100) then
    TB.lootStatus = "No cap"; TB.lootList = {}; return false end

  local lootLast = TB.storage.extras.lootLast ~= false
  local loot = lootLast and TB.lootList[#TB.lootList] or TB.lootList[1]
  if not loot then TB.lootStatus = ""; return false end

  local now = LC.sched.now()
  if TB.waitTill > now then return true end

  local lootContainers = TB.getLootContainers()
  if not lootContainers[1] then TB.lootStatus = "No space"; return false end
  TB.lootStatus = "Looting"

  for id, ct in pairs(LC.state.containers) do
    if TB.isLootContainer[id] then TB.lootContainer(lootContainers, ct); return true end
  end

  local pos  = LC.state.player.pos
  local dist = chebyshev(pos, loot.pos)
  local maxRange = TB.storage.extras.looting or 40
  if loot.tries > 30 or loot.pos.z ~= pos.z or dist > maxRange then
    TB.popLoot(); return true end

  local minDist, walkPrecision = 2, 2                   -- (1,1 for clientVersion <= 760)
  if dist > minDist or not LC.state:tile(loot.pos) then
    loot.tries = loot.tries + 1
    TB.walkTo(loot.pos, 20, {ignoreNonPathable=true, precision=walkPrecision})
    return true
  end

  local corpse = topUseThing(loot.pos)                  -- item table {id=,stackpos=,pos=}
  if not corpse or not isContainerItem(corpse.id) then TB.popLoot(); return true end

  local cid = TB.openContainer(corpse, nil)             -- sender:openContainer
  TB.openedFromItemId[cid] = corpse.id
  TB.waitTill = now + (TB.storage.extras.lootDelay or 200)
  TB.waitingForContainerItemId = corpse.id
  return true
end

function TB.getLootContainers()                         -- looting.lua:186
  local byId, out, openedById, toOpen = TB.containersById(), {}, {}, nil
  for id, ct in pairs(LC.state.containers) do
    local fromId = TB.openedFromItemId[id]
    openedById[fromId] = 1
    if byId[fromId] and not TB.isLootContainer[id] then
      if #ct.items < ct.capacity or ct.hasPages then out[#out+1] = ct
      else
        for _, it in ipairs(ct.items) do
          if isContainerItem(it.id) and byId[it.id] then toOpen = {it, ct}; break end
        end
      end
    end
  end
  if not out[1] then
    if toOpen then
      TB.openContainer(toOpen[1], toOpen[2]); TB.waitTill = LC.sched.now()+500; return {}
    end
    for id, ct in pairs(LC.state.containers) do
      if not byId[TB.openedFromItemId[id]] and not TB.isLootContainer[id] then
        for _, it in ipairs(ct.items) do
          if isContainerItem(it.id) and byId[it.id] then
            TB.openContainer(it, nil); TB.waitTill = LC.sched.now()+500; return {}
          end
        end
      end
    end
    for slot = 1, 10 do                                 -- InventorySlotFirst..Last
      local it = LC.state.player.inventory[slot]
      if it and isContainerItem(it.id) and not openedById[it.id] then
        TB.openContainer(it, nil); TB.waitTill = LC.sched.now()+500; return {}
      end
    end
  end
  return out
end

function TB.lootContainer(lootContainers, ct)           -- looting.lua:237
  local L, byId, now = TB.cfg.looting, TB.itemsById(), LC.sched.now()
  local nextContainer = nil
  for slot, it in ipairs(ct.items) do
    local isCt = isContainerItem(it.id)
    if isCt and not byId[it.id] then
      nextContainer = {item=it, slot=slot}                       -- keeps the LAST one
    elseif (not L.everyItem and byId[it.id])
        or (L.everyItem and not isCt and not byId[it.id]) then
      local key = ct.id..":"..slot..":"..it.id
      TB.lootTries[key] = (TB.lootTries[key] or 0) + 1
      if TB.lootTries[key] < 5 then
        return TB.lootItem(lootContainers, ct, slot, it)
      end
    elseif TB.storage.foodItems and TB.storage.foodItems[1]
        and TB.lastFood + 5000 < now then
      for _, f in ipairs(TB.storage.foodItems) do
        if it.id == f.id then
          LC.sender:use(slotPos(ct.id, slot-1), it.id, slot-1, 0)
          TB.lastFood = now; return
        end
      end
    end
  end

  if nextContainer then
    local key = "nc:"..ct.id..":"..nextContainer.slot
    TB.lootTries[key] = (TB.lootTries[key] or 0) + 1
    if TB.lootTries[key] < 2 then
      TB.openContainer(nextContainer.item, ct)          -- replaces the corpse window
      TB.waitTill = now + 300
      TB.waitingForContainerItemId = nextContainer.item.id
      return
    end
  end

  TB.isLootContainer[ct.id] = nil
  LC.sender:closeContainer(ct.id)
  TB.popLoot()
end

local function slotPos(containerId, slot0)              -- container.h:37
  return {x=0xFFFF, y=bit.bor(containerId, 0x40), z=slot0}
end

function TB.lootItem(lootContainers, srcCt, srcSlot, it)  -- looting.lua:284
  local from, stack = slotPos(srcCt.id, srcSlot-1), srcSlot-1
  if bit.band(items.flags(it.id), items.CUMULATIVE) ~= 0 then
    for _, c in ipairs(lootContainers) do
      for slot, ci in ipairs(c.items) do
        if ci.id == it.id and (ci.count or 1) < 100 then
          LC.sender:move(from, it.id, stack, slotPos(c.id, slot-1), it.count or 1)
          TB.waitTill = LC.sched.now() + 300; return
        end
      end
    end
  end
  local c = lootContainers[1]
  LC.sender:move(from, it.id, stack, slotPos(c.id, #c.items), 1)   -- count 1, verbatim
  TB.waitTill = LC.sched.now() + 300
end

-- ============================================================ PUBLIC / GLUE
function TB.isActive()             return TB.lastAction + 300 > LC.sched.now() end
function TB.isCaveBotAllowed()     return TB.cavebotAllow > LC.sched.now() end
function TB.Danger()               return TB.dangerValue end
function TB.avoidFloorChangeEnabled() return TB.storage.targetbotAvoidFloorChange ~= false end

-- CaveBot side (cavebot.lua:81):
--   if TB.isActive() and not TB.isCaveBotAllowed() then resetWalking(); return end

-- positionChange hook (creature_attack.lua:236):
LC.events.on('positionChange', function()
  if CaveBot.isOff() or not TB.isOn() then return end
  if not TB.lureMax then return end
  if TB.storage.TargetBotDelayWhenPlayer then return end
  if not TB.dynamicLureDelay then return end
  if TB.targetCount < (TB.delayFrom or TB.lureMax/2) or not TB.attackingId then return end
  CaveBot.delay(TB.delayValue or 0)
end)

## Evidence
- D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/targetbot/target.lua:49 — targetbotMacro = macro(100, ...) : the single 100 ms TargetBot tick
- targetbot/target.lua:51 — g_map.getSpectatorsInRange(pos, false, 6, 6) : the 13x13 candidate box (comment says 12x12)
- targetbot/target.lua:53-62 — if more than 10 monsters, shrink the box to getSpectatorsInRange(pos,false,3,3) (7x7)
- targetbot/target.lua:68-71 — candidate gates: healthPercent>0, isMonster, (oldTibia or getType()<3), and a findPath result
- targetbot/target.lua:70 — findPath(playerPos, creaturePos, 7, {ignoreLastCreature=true, ignoreNonPathable=true, ignoreCost=true, ignoreCreatures=true})
- targetbot/target.lua:73-79 — dangerLevel += params.danger; targets counted for priority>0; strict `>` keeps the first-found on ties
- targetbot/target.lua:89 — TargetBot.walkTo(nil) resets the movement destination every tick
- targetbot/target.lua:92-95 — Looting.process(targets, dangerLevel) runs BEFORE the attack decision; dangerValue = dangerLevel
- targetbot/target.lua:98-115 — attack branch: gated on `not isInPz()`, calls Creature.attack(params, targets, looting), then TargetBot.walk(), lastAction = now, return
- targetbot/target.lua:119-127 — no-target branch: walk only if looting, status 'Waiting'
- targetbot/target.lua:131-152 — Config.setup('targetbot_configs', widget, 'json', cb); data['targeting'] and data['looting']; macro delay + lureEnabled reset
- targetbot/target.lua:183 — TargetBot.isActive() = lastAction + 300 > now
- targetbot/target.lua:187 — TargetBot.isCaveBotActionAllowed() = cavebotAllowance > now
- targetbot/target.lua:220-232 — profile name read/written at storage._configs.targetbot_configs.selected
- targetbot/target.lua:238-245 — TargetBot.save() writes {targeting=<list widget values>, looting=<Looting.save>}
- targetbot/target.lua:247-249 — TargetBot.allowCaveBot(time) sets cavebotAllowance = now + time
- targetbot/target.lua:271-294 — saySpell(delay 500) / sayAttackSpell(delay 2000) rate limiters
- targetbot/target.lua:299-333 — useItem(delay 200) / useAttackItem(delay 2000); subType forced to 0 on clientVersion>=860; useInventoryItemWith on >=780; NEITHER returns a value
- targetbot/target.lua:36-44 — avoidFloorChange switch persisted at storage.targetbotAvoidFloorChange, default ON
- targetbot/creature.lua:15-29 — addConfig requires a string `name`; builds `regex` from comma-separated parts with * -> .* and ? -> .?
- targetbot/creature.lua:53-72 — getConfigs: lowercase trimmed name, regexMatch against every entry, ALL matches returned, cache flushed above 1000 entries
- targetbot/creature.lua:74-93 — calculateParams: strict `>` selects the config, danger only set for the winning config
- targetbot/creature.lua:95-98 — calculateDanger returns config.danger verbatim
- targetbot/creature_priority.lua:7-9 — hysteresis: +1 when the creature is the current attack target
- targetbot/creature_priority.lua:12-19 — range gate `#path > config.maxDistance`; rpSafe cancels the attack; returns the hysteresis-only score
- targetbot/creature_priority.lua:22-30 — +config.priority, then +10 for path length 1 or +5 for <=3
- targetbot/creature_priority.lua:33-45 — diamondArrows: +4 per monster in diamondArrowArea; rpSafe returns 0 if any player in largeRuneArea
- targetbot/creature_priority.lua:48-58 — low-HP if/elseif chain: chase&<30 => +5, else <20 => +2.5, <40 => +1.5, <60 => +0.5, <80 => +0.2
- targetbot/creature_attack.lua:58-60 — g_game.attack(creature) only when the current attack target differs
- targetbot/creature_attack.lua:62-64 — movement is SKIPPED entirely while isLooting
- targetbot/creature_attack.lua:68-112 — the four attack branches in order (group spell, group rune, spell, rune) with their mana/target/player conditions
- targetbot/creature_attack.lua:119-127 — isTrapped test over the 8 neighbours using tile:isWalkable(false)
- targetbot/creature_attack.lua:130-136 — dynamic lure latch: lureMin >= targets => lure on; targets >= lureMax => lure off
- targetbot/creature_attack.lua:148-150 — closeLure: closeLureAmount <= getMonsters(1) => allowCaveBot(150)
- targetbot/creature_attack.lua:151-168 — luring block: canLure, (lure|lureCavebot|dynamicLure), hp >= killUnder, not trapped; classic lure walks to marginMin=5/marginMax=6
- targetbot/creature_attack.lua:170-173 — rePosition gate and rePosition(config.rePositionAmount or 6)
- targetbot/creature_attack.lua:22-48 — rePosition(): 500 ms throttle, walkable-neighbour count, CaveBot.GoTo(target, 0)
- targetbot/creature_attack.lua:174-177 — chase rule: (killUnder>1 and hp<killUnder) or config.chase, walkTo(cpos, 10, {precision=1}) while #path > 1
- targetbot/creature_attack.lua:178-189 — keepDistance: anchor (re)set when beyond anchorRange; dead band is exactly {keepDistanceRange, keepDistanceRange+1}; maxDistanceFrom={anchorPosition, anchorRange} when anchored within anchorRange*2
- targetbot/creature_attack.lua:192-206 — avoidAttacks side-step candidates for distance-1 alignment
- targetbot/creature_attack.lua:207-232 — faceMonster diagonal step candidates and the turn(0/1/2/3) fallback
- targetbot/creature_attack.lua:236-244 — onPlayerPositionChange => CaveBot.delay(lureDelay) while targetCount >= (delayFrom or lureMax/2) and a target exists
- targetbot/walking.lua:6-10 — walkTo(dest, maxDist, params) only records the destination
- targetbot/walking.lua:16-18 — avoidFloorChangeEnabled: storage.targetbotAvoidFloorChange ~= false (default true)
- targetbot/walking.lua:21-50 — the stepper: nil dest, isWalking, z mismatch, precision, margin band, getPath, wouldStepChangeFloor, then ONE walk(path[1])
- targetbot/looting.lua:55-75 — Looting.update: items/containers/everyItem/maxDanger(10)/minCapacity(100); mirrors ids into vBot.lootItems/lootConainers
- targetbot/looting.lua:77-83 — Looting.save writes items, containers, maxDanger, minCapacity, everyItem
- targetbot/looting.lua:85-96 — itemsById/containersById lookup sets built from the id fields
- targetbot/looting.lua:107-125 — process() gates: nothing configured, danger > maxDanger, freeCapacity < minCapacity (WIPES the queue), empty queue; lootLast picks list[#list]
- targetbot/looting.lua:127-129 — global waitTill gate returns true (looting stays 'in charge')
- targetbot/looting.lua:142-147 — any container flagged .lootContainer is emptied before anything else
- targetbot/looting.lua:150-155 — corpse dropped when tries>30, z mismatch, or Chebyshev distance > storage.extras.looting (40)
- targetbot/looting.lua:157-171 — minDist/walkPrecision = 2 (1 for clientVersion<=760); walkTo(loot.pos, 20, {precision}) and tries++
- targetbot/looting.lua:173-183 — tile:getTopUseThing() must be a container; g_game.open(container); waitTill = now + (storage.extras.lootDelay or 200); waitingForContainer = item id
- targetbot/looting.lua:186-235 — getLootContainers: room test (itemsCount < capacity or hasPages), nested spare bag, non-loot container scan, inventory slots 1..10; each fallback waits 500 ms
- targetbot/looting.lua:237-274 — lootContainer: one item per call, lootTries<5, everyItem inversion, food use every 5000 ms, nested container lootTries<2 with 300 ms wait, then close + pop
- targetbot/looting.lua:284-301 — lootItem: stackable merge into a slot with the same id and count<100 moving the FULL count, else append with count 1; both wait 300 ms
- targetbot/looting.lua:303-308 — onContainerOpen marks container.lootContainer when its container item id equals waitingForContainer
- targetbot/looting.lua:310-341 — onCreatureDisappear discovery: not PZ, TargetBot on, isMonster, config exists and not dontLoot, same z and Chebyshev <= 6, 20 ms later require a container top-use thing and a 6-step path, queue cap 20, sort DESCENDING by distanceFromPlayer
- targetbot/looting.lua:276-282 — onTextMessage 'you are not the owner' pops the current queue entry
- targetbot/creature_editor.lua:79-105 — the complete authoritative field list with ranges and defaults (priority 0-10/1, danger 0-10/1, maxDistance 1-10/10, keepDistanceRange 1-5/1, anchorRange 1-10/3, lureCount 0-5/1, lureMin 0-29/1, lureMax 1-30/3, lureDelay 100-1000/250, delayFrom 1-29/2, rePositionAmount 0-7/5, closeLureAmount 0-8/3; checkboxes chase=true, everything else false)
- targetbot/creature_editor.lua:66-72 — the same name->regex derivation on save
- profiles/bot/vBot_4.8/targetbot_configs/true_asura.json — a complete real config (single '*' entry, dontLoot true, loot bag 23721, loot items 16131 and 9636)
- profiles/bot/vBot_4.8/targetbot_configs/turter.json — a real 4-entry config with per-monster priorities 4/3/2/1, maxDistance 8, diamondArrows true, closeLure true
- profiles/bot/vBot_4.8/targetbot_configs/hellhub.json — a real multi-name entry: name 'Demon,Vexclaw,Grimeleech,Blightwalker,Undead Dragon' -> regex '^demon$|^vexclaw$|^grimeleech$|^blightwalker$|^undead dragon$'
- profiles/bot/vBot_4.8/storage/profile_1.json — real storage: _configs.targetbot_configs = {enabled:false, selected:'true_asura'}; extras.killUnder=1, extras.looting=40, extras.lootDelay=220, extras.lootLast=true; foodItems list
- profiles/bot/vBot_4.8/vBot/extras.lua:130-141 — slider/checkbox definitions and defaults for looting(40), lootDelay(200), killUnder(1), lootLast(true)
- profiles/bot/vBot_4.8/vBot/vlib.lua:643-646 — distanceFromPlayer = getDistanceBetween(pos(), coords)
- profiles/bot/vBot_4.8/vBot/vlib.lua:649-661 — getMonsters(range, multifloor): non-summon monsters with distanceFromPlayer <= range
- profiles/bot/vBot_4.8/vBot/vlib.lua:900-917 — getNearTiles(pos): the 8 neighbours (computed as pos - dir)
- profiles/bot/vBot_4.8/vBot/vlib.lua:1055-1078 — getCreaturesInArea(posOrCreature, pattern, mode): mode 2 = monsters, 3/else = non-friend players
- profiles/bot/vBot_4.8/vBot/vlib.lua:1205-1213 — largeRuneArea 7x7 with cut corners
- profiles/bot/vBot_4.8/vBot/vlib.lua:1291-1297 — diamondArrowArea 5x5 with cut corners
- profiles/bot/vBot_4.8/vBot/new_cavebot_lib.lua:225-230 — CaveBot.GoTo(pos, precision) = CaveBot.walkTo(pos, 20, {ignoreCreatures=true, precision=precision})
- profiles/bot/vBot_4.8/cavebot/cavebot.lua:80-84 — CaveBot macro period 20 ms and the TargetBot.isActive()/isCaveBotActionAllowed() interlock
- profiles/bot/vBot_4.8/cavebot/cavebot.lua:563-565 — CaveBot.delay(value) = max(existing, now + value)
- profiles/bot/vBot_4.8/cavebot/walking.lua:131-165 — isFloorChangeTile: yellow(210-213)+not pathable, floor-change LensHelp, not-pathable ground, top-use item, or an id from the avoidTileIds list; pcall fail-open
- profiles/bot/vBot_4.8/cavebot/walking.lua:172-181 — CaveBot.wouldStepChangeFloor(fromPos, dir) used by the TargetBot stepper
- profiles/bot/vBot_4.8/cavebot/walking.lua:43-52 — dirDelta: North=0,East=1,South=2,West=3,NE=4,SE=5,SW=6,NW=7
- profiles/bot/vBot_4.8/cavebot/lure.lua:5-19 — the CaveBot 'lure' waypoint action toggles TargetBot on/off
- profiles/bot/vBot_4.8/vBot/HealBot.lua:767-773 — HealBot delays itself 700/200 ms while TargetBot.Looting.getStatus() is non-empty
- profiles/bot/vBot_4.8/vBot/Equipper.lua:600 — 'TargetBot Danger is Above' condition uses TargetBot.Danger()
- mods/game_bot/bot.lua:525-534 — the master tick: scheduleEvent(check, 10) driving botExecutor.script()
- mods/game_bot/bot.lua:268-282 — storage path <botProfile>/storage/profile_<g_settings profile>.json, JSON-decoded at load
- mods/game_bot/bot.lua:311-320 — storage saved with json.encode(botStorage, 2)
- mods/game_bot/executor.lua:22 — context.configDir = '/bot/' .. config
- mods/game_bot/executor.lua:195-209 — the macro dispatch loop: lastExecution + timeout <= now
- mods/game_bot/functions/main.lua:37-40 — macro timeout clamped to a 50 ms minimum
- mods/game_bot/functions/main.lua:112-124 — macro.delay skip and the always-true return
- mods/game_bot/functions/config.lua:54-79 — Config.load reads <configDir>/<dir>/<name>.json
- mods/game_bot/functions/config.lua:93-108 — Config.save writes json.encode(value, 2)
- mods/game_bot/functions/config.lua:137-144 — storage._configs[dir] = {enabled=false, selected=''}
- mods/game_bot/functions/config.lua:258-260 — config.save(data) writes to storage._configs[dir].selected
- mods/game_bot/functions/map.lua:143-219 — findPath: cross-floor refusal, marginMin/marginMax ring search, precision ring search; returns a DIRECTION list
- mods/game_bot/functions/map.lua:116-139 — translateAllPathsToPath rebuilds the direction list by following node[4] back to the start
- mods/game_bot/functions/map.lua:8-35 — getSpectators(param1, param2) forms, including the pattern form
- mods/game_bot/functions/player.lua:64-65 — walk(dir) = modules.game_walk.smartWalk(dir); turn(dir) = g_game.turn(dir)
- mods/game_bot/functions/player_conditions.lua:31 — isInPz() = hasCondition(PlayerStates.Pz)
- mods/game_bot/functions/const.lua:32-33 — InventorySlotFirst = 1, InventorySlotLast = 10
- src/client/map.cpp:1316-1470 — findEveryPath: Dijkstra, ignoreCost forces cost 1, rejection rules, ignoreLastCreature terminal +100 nodes, hasStairs = notPathable && minimapColor 210..213
- src/client/map.cpp:651-690 — getSpectatorsInRangeEx: inclusive ranges, iteration z->y->x ascending (defines all tie-breaks)
- src/client/map.h:176-179 — getSpectatorsInRange(center, multiFloor, xRange, yRange) maps to the Ex form with symmetric ranges
- src/client/protocolcodes.h:415-423 — CreatureType enum: Player=0, Monster=1, Npc=2, SummonOwn=3, SummonOther=4 (the `< 3` summon filter)
- src/client/container.h:37 — getSlotPosition(slot) = {0xffff, containerId | 0x40, slot} (0-based slot)
- src/client/thing.cpp:94-97 — an item inside a container reports stackpos == its slot index
- src/client/game.cpp:802-812 — Game::move clamps count<=0 to 1 and sends (fromPos, itemId, stackpos, toPos, count)
- src/client/game.cpp:935-943 — Game::open sends useItem(pos, id, stackpos, previousContainer ? its id : findEmptyContainerId())
- src/client/game.cpp:954-959 — Game::close sends sendCloseContainer(container id)
- src/client/tile.cpp — Tile::getTopUseThing: first forceUse / non-ground / non-groundBorder / non-onBottom / non-onTop / non-creature / non-splash thing
- src/client/tile.cpp — Tile::isWalkable(ignoreCreatures): NOT_WALKABLE flag or missing ground => false; blocking non-passable visible creatures block when ignoreCreatures is false
- src/client/tile.h:75-77 — isWalkable default argument ignoreCreatures=false; isPathable = !(flags & NOT_PATHABLE)
- src/framework/luafunctions.cpp:95-107 — regexMatch uses std::regex with the ECMAScript grammar

## Pitfalls
- luaclient has NO pathfinder and NO per-item blocking flags. `proto/items.lua` only extracts CUMULATIVE/WEAROUT/EXPIRE/CONTAINER/CLASSIFY/PODIUM/DECOKIT (API.md:124-131) — there is no NOT_WALKABLE / NOT_PATHABLE / isGround / isForceUse / isOnBottom / isOnTop / isSplash bit. Every single TargetBot decision depends on those. You must extend tools/extract_appearances.py and the items1530.bin format before any of this works, and bump the format version.
- `findPath` returns DIRECTIONS, not positions. `#path` is a step count and is used everywhere as 'distance' (maxDistance, the +10/+5 priority bonus, keepDistanceRange, the chase `#path > 1` test). Do not substitute Chebyshev distance for it — an obstacle between player and monster changes the score.
- There are TWO distance metrics and they disagree. `getDistanceBetween` subtracts 1 from each nonzero axis (battle.lua:1881), so `getMonsters(1)` covers roughly a 5x5 cross, not the 8 neighbours, and `distanceFromPlayer(anchorPos) > anchorRange` is looser than it reads. Chebyshev is used only at walking.lua:26, looting.lua:150 and looting.lua:322.
- Priority ties are resolved by SPECTATOR ORDER (z, then y, then x, all ascending — map.cpp:674-687) because the comparison is a strict `>`. If your spectator scan iterates differently, the bot will pick a different monster than vBot on every tie, which is the common case with a single '*' config.
- Config ties inside calculateParams are resolved by LIST ORDER for the same reason (creature.lua:81). Preserve the JSON array order.
- A creature beyond `maxDistance` that is the CURRENT attack target still scores exactly 1 (hysteresis, creature_priority.lua:7-18) and therefore still counts in `targets`, which feeds every luring threshold. It can even be re-selected when nothing else scores above 1.
- `params.danger` is only assigned when a config wins the priority contest (creature.lua:83). Creatures out of maxDistance, dead, or unmatched contribute 0 danger — the aggregate is NOT 'sum of danger of all nearby monsters'.
- The low-HP priority chain is if/elseif: with `chase=true` a 15% monster gets +5 (the first branch), never +2.5. Implementing it as independent ifs changes target selection.
- `TargetBot.useItem` / `useAttackItem` return nil (target.lua:299-333), so `if TargetBot.useAttackItem(...) then return end` at creature_attack.lua:98 and :109 never short-circuits. Preserve that if you want identical ordering.
- Every attack-spell/rune field (useSpellAttack, attackSpell, minMana, attackRune, useGroupAttack, ...) is read by creature_attack.lua but is NEVER written by the vBot 4.8 editor and appears in none of the 11 on-disk configs. Those branches are dead. Do not report them as active behaviour; default them to off.
- `TargetBot.Creature.walk` is skipped entirely while looting (creature_attack.lua:62). If you move the chase logic outside that guard, the bot will fight the looter for the movement destination.
- `storage.extras.lootLast` defaults to TRUE, and the queue is sorted DESCENDING by distance at insert time, so `list[#list]` is the NEAREST corpse — the option label ('Start loot from last corpse') is misleading. The sort is a one-shot snapshot; the queue is never re-ordered as the player moves.
- `table.sort` in looting.lua:333 mutates the entries (writes `a.dist`/`b.dist`) inside the comparator. With an unstable sort and mutating comparator this is technically UB in Lua; reproduce the intent (descending by distance-at-insert), not the mechanism.
- Free-capacity below `minCapacity` WIPES the whole corpse queue (looting.lua:118), it does not merely pause looting.
- `lootItem` moves count=1 for a stackable that has no partial stack in the loot bag (looting.lua:299). The full stack only moves on the NEXT pass via the merge branch. That costs an extra ~300 ms move per new stackable type — it is the real behaviour, not a bug to fix silently.
- `getSlotPosition` is 0-BASED while `container:getItems()` is 1-based Lua; the merge branch passes `slot - 1` and the append branch passes `getItemsCount()`. Off-by-one here silently moves items into the wrong slot.
- `item.lootTries` and `nextContainer.lootTries` are stored on the C++ Item userdata and vanish whenever the client re-creates the container item list. In luaclient you must key them explicitly and expire them (per container-open, say), or a corpse can loop forever.
- `waitingForContainer` holds the corpse's ITEM id, and `onContainerOpen` matches it against `container:getContainerItem():getId()`. luaclient's `containerOpen` event does not tell you which item the container was opened from — you must record it when you send openContainer and correlate on the reply.
- `g_game.open(item)` with no previous container allocates `findEmptyContainerId()` (game.cpp:940). If you always pass 0 you will silently replace an already-open backpack.
- The corpse-discovery handler calls `calculateParams(creature, {})` with an EMPTY path (looting.lua:314), so `#path == 0` always passes the maxDistance gate. Only 'has a matching config' and `dontLoot` matter there. Passing the real path would change which corpses get queued.
- `onCreatureDisappear` fires for creatures leaving the aware range as well as for deaths. vBot relies on the 20 ms deferred tile check (a container must be on the tile) to filter that; keep the delay.
- The macro loop uses `lastExecution + timeout <= now` with a shared `now` snapshot per master tick (executor.lua:195-200). If your scheduler drifts, the 100 ms period becomes the dominant timing error for every 200/300/500 ms wait in the looter.
- `TargetBot.walk()` sends exactly ONE step and refuses to send another while `player:isWalking()` (walking.lua:23). luaclient has no `isWalking`; you must synthesise it from the sent-walk / positionChange / walkCancel cycle or the bot will flood walk packets.
- `avoidFloorChangeEnabled` defaults to TRUE when the storage key is absent (`~= false`). It depends on the CaveBot classifier, which needs minimap colours (g_map.getMinimapColor) — luaclient has no minimap. Without it, only the item-flag half of the classifier is available.
- `rePosition` uses the CAVEBOT walker (`CaveBot.GoTo`), not `TargetBot.walkTo` (creature_attack.lua:46). If CaveBot is off, this branch does nothing at all.
- `process()` shadows the module-level `containers` (the configured loot-bag ids) with `g_game.getContainers()` at looting.lua:130. Lines before that use the config list, lines after use the open-container map. Getting this wrong inverts the 'No space' logic.

## Open questions
- luaclient's `LC.state.player` exposes `capacity` and `maxCapacity` (API.md:229) but vBot calls `player:getFreeCapacity()`. Confirm which of the two luaclient fields carries the FREE capacity (the 1530 player-stats packet sends free capacity) before wiring the `minCapacity` gate — an inverted meaning disables looting permanently.
- `LC.state.creatures[id]` has no `type` field documented in API.md (only isPlayer/isMonster/isNpc). The summon filter needs the raw CreatureType byte (`< 3`). Confirm the parser stores it, or add it — otherwise summons will be targeted and will inflate `targets`, breaking every lure threshold.
- `LC.state.containers[id]` (API.md:234) has no field recording which ITEM the container was opened from, and no `.lootContainer`-style marker. Decide where to store `openedFromItemId` (parser-side on containerOpen, or bot-side on send).
- No `shield` field is documented on creatures, so the `groupAttackIgnoreParty` party filter (`creature:getShield() <= 2`) cannot be reproduced. It only matters if you ever populate the (currently dead) group-attack fields.
- vBot's name matching is std::regex/ECMAScript. Lua patterns cannot express alternation or `.*?` the same way. Decide whether to (a) split the alternation on `|` and translate each `^...$` alternative to a Lua pattern, or (b) implement a tiny glob matcher directly from the ORIGINAL `name` field (recommended — the wildcard vocabulary is only `*` and `?`) and ignore the persisted `regex`.
- `storage.extras.killUnder` is read unguarded at creature_attack.lua:171 and :174 but with `or 30` at :151. Confirm whether a headless client should default it to 1 (the slider default and the value on disk) or 30 for the luring branch; the two call sites genuinely disagree.
- `getMonsters(1)` (close lure) and `getCreaturesInArea(..., pattern, n)` use `getSpectators()` with NO range argument, i.e. the whole aware range, then filter by distance. Confirm luaclient's aware-range bookkeeping (`st:isAwareOf`) gives the same candidate set, or the close-lure and diamond-arrow counts will differ near the map edge.
- Minimap colours (210..213) are unavailable in luaclient, so `hasStairs` in the pathfinder and half of `isFloorChangeTile` cannot be reproduced. Decide whether to derive an equivalent from item flags alone (ground item is NOT_PATHABLE), and accept that the bot may path onto tiles vBot refuses.
- `PlayerDiagonalWalkSpeed` (the diagonal cost multiplier, map.cpp:1454) comes from g_gameConfig. Find its 1530 value (commonly 3.0) or force `ignoreCost` on every TargetBot path — every TargetBot findPath call except the keepDistance/lure ones already passes ignoreCost, so this only affects the keepDistance margin search and the classic-lure precision search.
- vBot never re-issues `g_game.attack` for an unchanged target. Confirm the 1530 server keeps the attack alive across creature moves and does not need a periodic refresh; if it does, add a keepalive that vBot does not have and document the divergence.

## VERIFIER (confidence 0.9)

### Corrections (AUTHORITATIVE)
- **Claim**: §0.1: "`macro.callback` always returns true (`B/functions/main.lua:123`) so `lastExecution = now` after every run."
  - **Correction**: FALSE. `return true` sits INSIDE `if not macro.delay or macro.delay < context.now then`. When the macro is delayed the callback returns nil, `lastExecution` is NOT advanced, so the executor re-attempts the macro on every 10 ms master tick and it fires the instant the delay expires — not on the next 100 ms boundary. The pseudocode's `LC.sched.every(100, TB.tick)` + `if TB.delayUntil > now then return end` reproduces the wrong resume timing after `TargetBot.delay()`.
  - Evidence: mods/game_bot/functions/main.lua:113-124 (`macro.callback = function(macro) if not macro.delay or macro.delay < context.now then ... return true end end`); executor.lua:200 `if macro.lastExecution + macro.timeout <= context.now and macro.enabled then`
- **Claim**: §1.2: "a creature is ignored simply by having no matching entry, or by matching an entry whose `priority` is 0."
  - **Correction**: FALSE for the priority-0 case. `config.priority` is only one addend. A priority-0 entry still collects +1 hysteresis, +10 at path length 1, +5 at path length <=3, +4 per mob for diamondArrows, and the low-HP bonuses — so the creature is still selected and still increments `targets`. The ONLY ways to ignore a creature are: no matching entry at all, or a `maxDistance` shorter than the shortest path (and even then it scores 1 while it is the current target).
  - Evidence: targetbot/creature_priority.lua (global creature.lua:120-156): `priority = priority + config.priority` then unconditional distance/diamond/HP bonuses
- **Claim**: §3.5: "creatures out of `maxDistance` or with no config contribute **0** [danger]."
  - **Correction**: FALSE for the current target, and the spec contradicts its own §2.3. Out of range, `calculatePriority` returns 1 (hysteresis). 1 > 0, so `calculateParams` sets `danger = config.danger` and `selectedConfig = config`. An out-of-range current target therefore DOES add its danger to `dangerLevel`, which can flip the looter's `dangerLevel > maxDanger` gate and `TargetBot.Danger()`.
  - Evidence: targetbot/creature.lua:79-86 (`if config_priority > priority then priority=...; danger = calculateDanger(...)`) combined with creature_priority.lua:105-117
- **Claim**: §1.2 field table: "`?` = any single char"
  - **Correction**: WRONG. The regex builder emits `.?`, which in ECMAScript is ZERO-OR-ONE of any character, not exactly one. `"Demo?n"` matches both "demon" and "demn".
  - Evidence: targetbot/creature.lua:27 `... :gsub("%*", ".*"):gsub("%?", ".?") ...` (identical at creature_editor.lua:71)
- **Claim**: §3.4(b): "**dynamic-lure hysteresis state** (`:130-145`), only when `lureMin and lureMax and dynamicLure` … Then `targetCount = targets`, `delayValue = config.lureDelay`, `lureMax = config.lureMax`, `dynamicLureDelay = …`, `delayFrom = …`."
  - **Correction**: Wrong scoping. Only the `targetBotLure` latch (lines 131-135) is inside the `lureMin and lureMax and dynamicLure` guard. `targetCount`, `delayValue`, `dynamicLureDelay` and `delayFrom` are assigned UNCONDITIONALLY on every `walk()` call (137-145), and `lureMax` is assigned only under a separate `if config.lureMax then` guard (140-142). These four are exactly what `onPlayerPositionChange` reads, so scoping them under dynamicLure changes CaveBot lure-delay behaviour for every config with dynamicLure off.
  - Evidence: targetbot/creature_attack.lua:130-145
- **Claim**: Pseudocode TB table / §3.7 `if not lureMax then return end`
  - **Correction**: The module locals' INITIAL values are omitted and one of them is load-bearing: `lureMax` initialises to **0** (creature_attack.lua:4), which is truthy in Lua, so `if not lureMax then return end` at :239 is DEAD CODE and never fires. The pseudocode's `TB` table has no `lureMax` field at all (nil), which would make that guard always return and kill the dynamic lure delay until the first `creatureWalk` runs. Also missing: `targetBotLure=false`, `targetCount=0`, `delayValue=0`, `delayFrom=nil`, `dynamicLureDelay=false`, and `lastCall = now` (NOT 0 — rePosition is blocked for the first 500 ms after script load).
  - Evidence: targetbot/creature_attack.lua:1-8 (`local lureMax = 0`, `local lastCall = now`); :239 `if not lureMax then return end`
- **Claim**: §3.1: "Sent at most once per target change; no re-send while the target is unchanged. In luaclient: `LC.sender:attack(creatureId)` (and track the id you last sent)."
  - **Correction**: The real test reads the CLIENT'S server-confirmed attack state, not a locally remembered id: `if g_game.getAttackingCreature() ~= creature then g_game.attack(creature) end`. If the server clears the attack (target dies out of view, `cancelAttackAndFollow` from rpSafe, a "target lost" packet), `getAttackingCreature()` becomes nil and vBot RE-SENDS the attack on the very next tick. The pseudocode's `TB.attackingId ~= c.id` will not. The same applies to the `+1` hysteresis in `calculatePriority`, which also reads `g_game.getAttackingCreature()`.
  - Evidence: targetbot/creature_attack.lua:58-60; creature_priority.lua:102 (`local currentTarget = g_game.getAttackingCreature()`)
- **Claim**: Pseudocode §3.4(d): `local killUnder = TB.storage.extras.killUnder or 1` then `not (c.healthPercent < (killUnder or 30))`
  - **Correction**: Divergence. vBot uses `(storage.extras.killUnder or 30)` at :151 but BARE `storage.extras.killUnder` at :171 and :174. Pre-resolving to `or 1` makes the lure guard fall back to 1 instead of 30 when the key is absent, so luring would keep running on a 25 %-HP monster where vBot stops. Also, with the key absent vBot raises on :171/:174 (`>=`/`>` against nil) and the whole tick is aborted by executor.lua's pcall — the pseudocode silently continues. Pick one and state it.
  - Evidence: targetbot/creature_attack.lua:151 vs :171 vs :174
- **Claim**: §3.4(h)/(i): presented as two sequential steps, "(h) avoidAttacks … (i) faceMonster …"
  - **Correction**: They are `if config.avoidAttacks then … elseif config.faceMonster then …` — MUTUALLY EXCLUSIVE. With `avoidAttacks = true` the faceMonster block (including the `turn()` fallback) is never reached, even when both avoid candidates are blocked and nothing is done.
  - Evidence: targetbot/creature_attack.lua:192 `if config.avoidAttacks then` … :207 `elseif config.faceMonster then`
- **Claim**: Pseudocode §3.4(e): `local curLen = cur and #cur or 999`
  - **Correction**: Invented; vBot has no fallback. `#currentDistance` on nil raises, the error is caught by executor.lua's pcall around the macro, printed as "Macro: … execution error", and the ENTIRE tick is aborted — no walk, no `lastAction` refresh (so CaveBot resumes 300 ms later). With `999` the reimplementation chases instead. Decide deliberately and document it; do not present it as fidelity.
  - Evidence: targetbot/creature_attack.lua:170-175; mods/game_bot/executor.lua:201-207
- **Claim**: §3.3: "Non-fluid-container items force `subType = 0` on clientVersion >= 860."
  - **Correction**: Incomplete. The assignment is `subType = g_game.getClientVersion() >= 860 and 0 or 1`, so below 860 the subType is forced to **1**, not left as the caller passed it.
  - Evidence: targetbot/target.lua:304 and :322
- **Claim**: §3.3: "`TargetBot.saySpell(text, delay=500)`: fires when `lastSpell + delay < now`; on protocol < 1090 it also pushes `lastAttackSpell = now`"
  - **Correction**: The `lastAttackSpell = now` push happens BEFORE the rate check, i.e. on EVERY call to `saySpell` regardless of whether the spell is actually said. So merely calling saySpell on a <1090 protocol starves attack spells for another full `sayAttackSpell` delay.
  - Evidence: targetbot/target.lua:274-281 (protocol check at 274-276, rate check at 277)
- **Claim**: §3.3: "party members with `shield <= 2` are excluded when `groupAttackIgnoreParty`"
  - **Correction**: Inverted wording. The condition is `(not config.groupAttackIgnoreParty or creature:getShield() <= 2)`; `shield <= 2` is the set that COUNTS as `playersAround` (shields 0/1/2 = not in a party). What gets excluded when `groupAttackIgnoreParty` is set is players with shield >= 3, i.e. actual party members.
  - Evidence: targetbot/creature_attack.lua:73 and :91
- **Claim**: §4.1 / §1.1: config (re)load side effects listed as "`targetbotMacro.delay = nil` and `lureEnabled = true` are reset on every config (re)load"
  - **Correction**: Incomplete — `TargetBot.Looting.update` is called on every config load (target.lua:140) and its FIRST statement wipes the corpse queue: `TargetBot.Looting.list = {}`. A reimplementation that keeps the queue across a config reload will loot corpses vBot has forgotten.
  - Evidence: targetbot/looting.lua:55-57 (`TargetBot.Looting.update = function(data) dontSave = true; TargetBot.Looting.list = {}`)
- **Claim**: §4.1: presents `everyItem`, `maxDanger`, `minCapacity` as module locals assigned once in `update`
  - **Correction**: They are not cached. `process` re-reads them from the UI widgets on EVERY tick: `ui.everyItem:isOn()` (:108, :243), `tonumber(ui.maxDangerPanel.value:getText())` (:112), `tonumber(ui.minCapacityPanel.value:getText())` (:116). Only `items`/`containers`/`itemsById`/`containersById` are true cached locals (set by `updateItemsAndContainers`). Behaviourally identical for a static headless load, but the spec's model hides that a UI edit takes effect on the next tick without a save/reload.
  - Evidence: targetbot/looting.lua:85-96 vs :108-120 and :243
- **Claim**: §B: "`_macros` — the per-name macro on/off map; TargetBot's macro is unnamed so it is not stored there."
  - **Correction**: Wrong. `macro.setOn`/`setOff` write `context.storage._macros[name] = true/false` unconditionally, so the unnamed TargetBot macro (and the unnamed CaveBot macro) both write the EMPTY-STRING key. The real profile_1.json does contain `"": false`. It is never read back (`if name:len() > 0` gates the load at main.lua:96), so behaviour is unaffected, but the claim that the key does not exist is false.
  - Evidence: mods/game_bot/functions/main.lua:73 and :82; profiles/bot/vBot_4.8/storage/profile_1.json `_macros` contains key `""` = false
- **Claim**: §1.2 / §2.2: `diamondArrows` = "add priority proportional to the mobs inside a 5×5 diamond around the creature"
  - **Correction**: Understates it: `getCreaturesInArea` excludes only the LOCAL PLAYER, so the target monster itself is always counted inside its own diamond. `mobCount` is therefore >= 1 and `diamondArrows` adds a FLOOR of +4 to every match, on top of everything else. With turter.json (priority 4, diamondArrows true) a lone Dark Torturer scores 4+4=8 before distance bonuses.
  - Evidence: vBot/vlib.lua:1055-1078 (`if spec ~= player then ... if spec:isMonster() and (... spec:getType() < 3) then monsters = monsters + 1`)
- **Claim**: §0.3 pathfinder description (the rejection list and cost model)
  - **Correction**: Several rules that change results are missing: (1) walkability is evaluated IGNORING creatures — `isNotWalkable = !tile->isWalkable(true)` — with blocking creatures handled separately via `tile->hasBlockingCreature()`; (2) when `destPos` is popped and NO margins are set the search BREAKS immediately, truncating the `paths` map (only the margin case extends to `min(distance+4, maxDistance)`); (3) tiles outside the aware range fall back to `g_minimap.getTile` flags/colour, and since no TargetBot call sets `allowUnseen`, an unseen tile is rejected (fail-closed) — a headless client with no minimap gets a strictly smaller search area; (4) `maxDistanceFrom` (the anchor ring) uses `Position::distance`, which is EUCLIDEAN `sqrt(dx²+dy²)`, not Chebyshev and not the Tibia metric; (5) `ignoreCost` sets cost=1 AFTER the diagonal multiplier, while `node->distance` (what `#path` reflects) is always +1 per step; (6) when marginMin/marginMax are set and no candidate exists, `findPath` returns nil — it does NOT fall back to the exact destination.
  - Evidence: src/client/map.cpp:1383-1388, 1409-1424, 1429-1441, 1450-1458; src/client/position.h:184 `double distance(...) { return sqrt(...); }`; mods/game_bot/functions/map.lua:191
- **Claim**: §0.3 / §3.8: `findPath` returns "a list of walk directions, so `#path` is the number of steps" — implying path[1] is determined
  - **Correction**: `#path` is determined, but `path[1]` — the direction actually walked — is NOT. Relaxation is strict `<` (map.cpp:1455) so the first equal-cost path found wins, the neighbour scan is `i`(dx) outer −1..1 / `j`(dy) inner −1..1, and the `std::priority_queue` gives no defined order among equal `totalCost` nodes (which is everything, once `ignoreCost=1`). Any Dijkstra you write will pick different tie-broken routes than vBot unless you fix an explicit tie-break; the spec should say so rather than implying the route is reproducible.
  - Evidence: src/client/map.cpp:1318-1324 (LessNode), 1391-1400 (neighbour loop order), 1455-1462 (strict `<` relaxation)
- **Claim**: §0.5: "appends every creature on each tile in tile-stack order"
  - **Correction**: `Tile::appendSpectators` walks `m_things` in REVERSE (`m_things.rbegin() + beginOffset`), so creatures on one tile come out top-of-stack first. Irrelevant in practice (creatures do not stack in Tibia) but the stated order is backwards.
  - Evidence: src/client/tile.cpp:477-489
- **Claim**: §4.2: "`getTopUseThing` (`S/client/tile.cpp`) = first non-ground/non-border/non-bottom/non-top/non-creature/non-splash thing, i.e. the corpse."
  - **Correction**: Incomplete: `isForceUse()` things win outright, and there are TWO fallbacks — if nothing matches, it returns the last non-splash/non-creature thing (iterating i = size-1 down to 1), and failing that `m_things[0]` (the ground). So on a non-empty tile it NEVER returns nil; what actually filters is the subsequent `:isContainer()` test. A reimplementation returning nil for "no use thing" behaves the same downstream but is not the same function.
  - Evidence: src/client/tile.cpp:600-616
- **Claim**: §1.4 table: `extras.killUnder` "0..100, **1**", `extras.looting` "0..50, **40**", `extras.lootDelay` "0..1000, **200**"
  - **Correction**: The slider ranges are right but the persisted value can never be 0: `addScrollBar`'s `onValueChange` does `if value == 0 then value = 1 end` before writing `settings[id]`. So 0 on any extras scrollbar is stored as 1. This matters for `killUnder`, which is tested with `> 1` at creature_attack.lua:174 — dragging the slider to 0 does NOT disable the branch differently from 1, but it also can never store 0 for a reimplementation to round-trip.
  - Evidence: profiles/bot/vBot_4.8/vBot/extras.lua:87-92
- **Claim**: Pseudocode `TB.lootingProcess`: `if LC.state.player.capacity < (L.minCapacity or 100)`
  - **Correction**: Must be FREE capacity, not total. vBot uses `player:getFreeCapacity()`. A field named `capacity` will almost certainly be total capacity in a fresh client state model and the gate would never fire.
  - Evidence: targetbot/looting.lua:116
- **Claim**: Pseudocode `matchesName`: split `cfg.regex` on `|` and convert each alternative to a Lua pattern
  - **Correction**: Lossy and wrong for several real names. The regex builder never escapes anything except rewriting `*` and `?` (creature.lua:27), so any Lua-magic character in a monster name (`-`, `%`, `+`, `(`, `)`, `[`, `]`) behaves differently under `string.match` than under std::regex. Implement the two wildcards directly against the comma-split `name` list instead of round-tripping through `regex`. Note also that `regex` is PERSISTED and `addConfig` only rebuilds it `if not config.regex` — a hand-edited file whose `regex` disagrees with `name` must have the stored `regex` win.
  - Evidence: targetbot/creature.lua:21-29 and :62 (`regexMatch(name, config.value.regex)[1]`); src/framework/luafunctions.cpp:95 (std::regex, ECMAScript, `regex_search` not `regex_match`)
- **Claim**: Assorted line citations
  - **Correction**: Off-by-N citations to fix: `json.encode(value, 2)` is config.lua:**108** (106 is the .cfg branch); the new-config `json.encode({})` is config.lua:**197** (194 is the "already exist" error); `context.now`/`context.time` are executor.lua:**196-197** and the macro loop **200-210**; `json.encode(botStorage, 2)` is bot.lua:**310**; `getSpectatorsByPattern` is map.lua:**30** and map.cpp:**1475**; in map.cpp the destPos/margin block is **1383-1388**, `distance >= maxDistance` is **1390**, `hasStairs` is **1429**, the diagonal multiplier is **1450**, `ignoreCost` is **1453**, ground speed is captured at **1415**; `isFloorChangeTile` is cavebot/walking.lua:**132-166**; the CreatureType enum runs to protocolcodes.h:**424** and includes `CreatureTypeHidden = 5`.
  - Evidence: verified by grep -n / sed -n on each file

### Additions
- MISSING SECTION — the spec is truncated mid-§4.4 and never specifies `lootContainer`/`lootItem`, which is the entire item-transfer half of the looter. `TargetBot.Looting.lootContainer(lootContainers, container)` (looting.lua:237-274): iterate `container:getItems()` in slot order, first matching branch wins per item — (i) `item:isContainer() and not itemsById[id]` -> remember as `nextContainer` (keeps the LAST such item, there is no break, so a container item that IS on the loot list falls through to (ii) and gets looted rather than opened); (ii) `(not everyItem and itemsById[id])` or `(everyItem and not item:isContainer() and not itemsById[id])` -> `item.lootTries = (item.lootTries or 0) + 1`, and ONLY if `< 5` do `return lootItem(...)` (i.e. an item that cannot be moved within ~5 attempts / 0.5 s is abandoned); (iii) else food: `storage.foodItems and storage.foodItems[1] and lastFoodConsumption + 5000 < now` -> on an id match `g_game.use(item)`, `lastFoodConsumption = now`, return. After the loop: if `nextContainer` then `nextContainer.lootTries += 1` and if `< 2` -> `g_game.open(nextContainer, container)`, `waitTill = now + 300`, `waitingForContainer = nextContainer:getId()`, return. Otherwise finish: `container.lootContainer = false`, `g_game.close(container)`, `table.remove(list, lootLast and #list or 1)`.
- MISSING — `TargetBot.Looting.lootItem(lootContainers, item)` (looting.lua:284-301): if `item:isStackable()`, scan every loot container's items for a same-id stack with `getCount() < 100` and `g_game.move(item, container:getSlotPosition(slot - 1), count)` — the WHOLE stack, with a 0-based slot index derived from the 1-based ipairs index. Otherwise `g_game.move(item, lootContainers[1]:getSlotPosition(lootContainers[1]:getItemsCount()), 1)` — exactly ONE item, appended at the end of the first loot bag. Both paths set `waitTill = now + 300`. Note `lootTries` is stored on the item OBJECT, so it resets whenever the server re-sends the container contents.
- The `lootContainers` ORDER is non-deterministic in vBot: `getLootContainers` iterates `pairs(g_game.getContainers())`, an unordered id-keyed map, and `lootContainers[1]` is the default destination bag for every non-stackable item. The step-9 scan for `container.lootContainer == true` (looting.lua:142) is likewise `pairs`. If you want reproducible behaviour, sort by container id and say so explicitly rather than inheriting an accident.
- The spec should state that `TargetBot.isOn()/isOff()` read the Config WIDGET switch, not `targetbotMacro.enabled` — the macro is unnamed so it has no switch and is enabled purely by `targetbotMacro.setOn(enabled)` from the config callback (target.lua:149). §3.6 hints at this; make it explicit, because `onCreatureDisappear` and `onTextMessage` gate on `TargetBot.isOn()` while the macro gates on `macro.enabled`, and the two can disagree transiently.
- `creature_attack.lua:51-53` writes a bare global `lastWalk = now` at the top of `TargetBot.Creature.attack` when the player is walking. A grep over the whole profile shows it is never read anywhere — genuinely dead. Worth one line in the spec so a reimplementer does not go hunting for the consumer.
- §3.4(c) `getMonsters(1)` deserves an exact shape, not "roughly a 5x5 cross": under `getDistanceBetween`, `<= 1` admits exactly the 13 tiles of a radius-2 diamond — all of |dx|<=1,|dy|<=1 plus the four tiles at (±2,0)/(0,±2) plus the eight at (±2,±1)/(±1,±2)… precisely: every tile where max(|dx|,|dy|)<=1, plus every tile where one coordinate is 2 and the other is <=1. It is centred on the player and includes the player's own tile. Also, it scans `getSpectators(nil)` = the FULL aware range and filters by distance, not a small box.
- §1.2's field-defaults table is fully correct — I checked all 27 editor-written fields against `creature_editor.lua:79-105`: priority 0..10/1, danger 0..10/1, maxDistance 1..10/10, keepDistanceRange 1..5/1, anchorRange 1..10/3, lureCount 0..5/1, lureMin 0..29/1, lureMax 1..30/3, lureDelay 100..1000/250, delayFrom 1..29/2, rePositionAmount 0..7/5, closeLureAmount 0..8/3, and all fourteen checkboxes with chase=true and the rest false. The list of never-written upstream attack fields (useGroupAttack … attackRuneDelay) is also exactly right and matches creature_attack.lua:68/86/103/108.
- The CONFIG FORMAT section is verbatim-accurate. `true_asura.json` matches byte for byte; `true_asuras.json` really is `[]`; `turter.json` really has 4 entries at priorities 4/3/2/1 with the quoted maxDistance/lureMax/lureMin/lureDelay/delayFrom/dontLoot values (Hand Of Cursed Fate additionally has maxDistance 10, worth adding); `hellhub.json`'s name->regex pair is exact. `profile_1.json` is 44975 bytes with `_configs` exactly as quoted, extras killUnder=1 / looting=40 / lootDelay=220 / lootLast=true / reachable=false, and the seven foodItems ids in the stated order. `targetbotAvoidFloorChange` and `TargetBotDelayWhenPlayer` are both genuinely absent, and `extras.reachable` is genuinely never read anywhere in the profile.
- Everything else in §2 is correct and I confirmed it line by line: the 13x13 -> 7x7 candidate switch at >10 monsters (target.lua:51-62, with the misleading "12x12"/"6x6" comments), the hppc>0 gate before findPath, the exact findPath params and maxDist 7, the `creature:getType() < 3` summon exclusion, the strict `>` in both `calculateParams` and the highest-priority selection, the z/y/x-ascending spectator tie-break, the +1/+10/+5 and the if/elseif low-HP chain including the chase quirk, the two rpSafe cancel sites, the `targets` semantics, the `TargetBot.walkTo(nil)` reset at :89, looting running BEFORE the attack decision at :92, `not isInPz()` gating only the attack branch, and `lastAction = now` on exactly :113 and :122.
- §3.4(f)/(g) are exact, including the `{range, range+1}` dead band, the `anchorRange*2` gate on the `maxDistanceFrom` variant, and the re-anchor rule. §3.4(h)/(i) candidate tables are correct tile-for-tile, as is the turn-direction fallback. §3.8's stepper is exact (Chebyshev dist, precision short-circuit, margin short-circuit, one direction per call, the `wouldStepChangeFloor` gate and the 10 s log throttle), and the four-clause `isFloorChangeTile` classifier is described correctly (add only the `top ~= ground` guard at walking.lua:148). `CaveBot.GoTo(target, 0)` really does resolve to `walkTo(pos, 20, {ignoreCreatures=true, precision=0})` because 0 is truthy. `CaveBot.delay` really is `math.max(existing or 0, now + value)`. `lure.lua`'s counterintuitive start->setOff / stop->setOn mapping is quoted correctly.
- One benign deviation to note deliberately: the pseudocode's stepper adds `if not path or #path == 0 then return end`, but vBot only tests `if path then` and then calls `walk(path[1])`. `findPath` returns an empty direction list when the destination equals the start (`translateAllPathsToPath` breaks immediately on `node[3] < 0`), so vBot can call `walk(nil)`. The guard is an improvement, not fidelity — say so.
