# AttackBot — offensive spells and runes (vBot 4.8)

# AttackBot — behaviour specification for a headless LuaJIT reimplementation

Source of truth: `D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\AttackBot.lua`
(3106 lines; referred to below as **AB**). Helpers live in
`D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\vlib.lua` (**VL**),
`D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\*.lua` (**FN**), and the C++
client `D:\Claude\otclient_mehah1530\otclient\src` (**CPP**).

Everything below is BEHAVIOUR unless a paragraph is explicitly tagged **[WIDGET-ONLY]**.

---

## 0. Runtime model / tick

* The bot host runs `botExecutor.script()` from a 10 ms repeating event
  (`mods/game_bot/bot.lua:531`, `bot.lua:534`).
* Each tick it walks `context._macros` and runs any macro whose
  `lastExecution + timeout <= now` (`mods/game_bot/executor.lua:199-210`).
  `context.now = g_clock.millis()` is refreshed once per tick (`executor.lua:196`).
* AttackBot registers `macro(5, function() ... end)` at **AB:2708**, but
  `context.macro` clamps any timeout below 50 to 50
  (`mods/game_bot/functions/main.lua:37-39`). **The AttackBot loop therefore runs
  every ~50 ms, not 5 ms**, despite the in-file comments claiming 5 ms.
* `delay(ms)` sets `_currentExecution.delay = now + ms`, which suppresses *this macro only*
  until then (`functions/main.lua:206-211`).
* **luaclient mapping:** `LC.sched.every(50, attackBotTick)`, with a module-local
  `suppressUntil` variable emulating `delay()`. `now` = `LC.sys.nowMs()` (a monotonic double;
  `g_clock.millis()` is also monotonic ms, so the semantics match).

### Distance metric (critical)
The bot sandbox overrides `getDistanceBetween` with **Chebyshev**:
`max(|dx|,|dy|)` (`executor.lua:124-126`). Do **not** use the odd
`(|dx|-1)+(|dy|-1)` version in `modules/game_battle/battle.lua:1881` — it is not in the
sandbox. `distanceFromPlayer(p) = getDistanceBetween(playerPos, p)` (**VL:643-646**).
Different-floor positions are never compared (all callers pre-filter to `posz()`).

### "On screen"
`getSpectators()` with no args → `g_map.getSpectators(playerPos, false)`
(`functions/map.lua:8-37`), which is `getSpectatorsInRangeEx(pos,false, awareRange.left,
awareRange.right, awareRange.top, awareRange.bottom)` (`src/client/map.h:166-169`) —
i.e. **every known creature on the player's own floor inside the aware-range box**.
In luaclient this is: iterate `LC.state.creatures`, keep those with `c.pos`,
`c.pos.z == player.pos.z`, and `LC.state:isAwareOf(c.pos)`.

### Monster predicate
vBot uses `spec:isMonster() and (clientVersion < 960 or spec:getType() < 3)`.
`CreatureType` is `0 Player, 1 Monster, 2 Npc, 3 SummonOwn, 4 SummonOther, 5 Hidden`
(`src/client/protocolcodes.h:415-424`), so `getType() < 3` **excludes summons**.
**luaclient gotcha:** `game/state.lua:457` sets `isMonster = (type==1 or type==3 or type==4)`.
The AttackBot predicate must be `c.type == 1`, not `c.isMonster`.

### Party predicate
`isPartyMember()` = shield ∈ {1,3,4,5,6,7,8,9,10} (`modules/gamelib/player.lua:621-626`,
constants `modules/gamelib/const.lua:13-24`). Shield 0 (none), 2 (white-blue = invited)
and 11 (gray) are **not** party members.

---

## 1. The entry model

An attack entry is a plain table (**AB:2258-2277** builds it; **AB:2762-2781** documents it).
Fields, with the exact origin and range:

| field | type | source / range | meaning |
|---|---|---|---|
| `enabled` | bool | always `true` on creation (AB:2269) | per-entry on/off |
| `spell` | string | free text, or picked formula | cast words, e.g. `"exori mas res"`. `""`/`"spell name"` rejected (AB:2245) |
| `itemId` | number | item picker, `0` when it is a spell | rune client id; must be `> 100` to count as a rune (AB:2243, AB:2785) |
| `category` | 1..5 | combobox | see §1.1 |
| `patternCategory` | 1..4 | derived: `category==4 → 3`, `category==5 → 4`, else `category` (AB:1866) | index into `spellPatterns` |
| `pattern` | number | combobox | **range in sqm** for categories 1/3/4; **grid id** for categories 2/5 |
| `count` | 1..99 | SpinBox `creatures` | minimum (or exact) monster count |
| `orMore` | bool | CheckBox | `true` → `n >= count`; `false` → `n == count` |
| `minHp` / `maxHp` | 0..99 / 1..100 | SpinBoxes | monster HP% window, inclusive both ends |
| `mana` | 0..99 | SpinBox `manaPercent` | minimum `manapercent()` (AB:2786) |
| `cooldown` | 0..999999 | SpinBox | **seconds** for runes (`entry.cooldown * 1000`, AB:2847); **milliseconds** for spells (`cast(text, executeCooldown)`, AB:2794) — see Pitfalls |
| `harmony` | 0..10 | SpinBox | minimum `player:getHarmony()` (monk resource) required (AB:2787) |
| `monsters` | `true` \| array of lowercase names | `creatures:lower()`; `true` when text is empty, `"*"` or the placeholder `"monster names"`, otherwise `string.split(creatures, ",")` (AB:2228-2229) | name whitelist |
| `creatures` | string | raw text | **[WIDGET-ONLY]** kept only to repopulate the edit form |
| `augmented` | bool | CheckBox | Wheel-of-Destiny wave augment; swaps the *counting* pattern only (AB:1296-1301) |
| `tooltip` | string\|false | `monsters ~= true and creatures` | **[WIDGET-ONLY]** |
| `description` | string | built at AB:2276 | **[WIDGET-ONLY]** display label |

**Priority** = position in the list. The tick iterates
`panel.entryList:getChildren()` in order (**AB:2783**) and `return`s on the first entry
that fires. The list order is mirrored into `currentSettings.attackTable` in the same
order when the window closes (**AB:1782-1790**). A headless client simply iterates
`attackTable` in array order; index 1 = highest priority. (`refreshAttacks` uses
`pairs()` over the array — AB:2215 — so keep it a dense array.)

**There is no per-entry cooldown *flag***; `cooldown` is only used when the profile is in
`CustomCooldown` mode. There is no per-entry PvP flag either — PvP safety is profile-wide.

### 1.1 Categories (AB:233-239)

| id | name | fires with | pattern semantics |
|---|---|---|---|
| 1 | Targeted Spell (`exori hur`, `exori flam`) | `cast(words)` | `pattern` = max Chebyshev distance to the current target (1..10) |
| 2 | Area Rune (avalanche, GFB) | `useWith(itemId, tileTopThing)` | `pattern` = grid id in `spellPatterns[2]` (1 cross, 2 bomb, 3 ball) |
| 3 | Targeted Rune (SD, icicle) | `useWith(itemId, target())` | `pattern` = max distance to target (1..10) |
| 4 | Empowerment (`utito tempo`) | `cast(words)` | `pattern` = max distance to target; additionally gated by `not isBuffed()` |
| 5 | Absolute Spell (`exori`, waves, monk spells) | `cast(words)` | `pattern` = grid id 1..19 in `spellPatterns[4]` |

### 1.2 Pattern tables (verbatim data — copy them)

`spellPatterns[patternCategory][pattern][safe]` where `safe` is `1` = the real area,
`2` = the "PVP-safe" area (real area + 1 sqm margin) — `getPattern()` at **AB:2519-2523**.
`spellPatterns[1]` and `spellPatterns[3]` are intentionally empty (**AB:300, AB:359**).

Grids are multi-line strings of `0`/`1` (and `N`/`E`/`S`/`W` for directional spells).
Width and height must both be **odd**; the centre cell is the pattern origin.

Area-rune grids (`spellPatterns[2]`, **AB:302-357**):
* `[1]` cross — 3x3 (`010/111/010`), safe 5x7
* `[2]` bomb — 3x3 all-ones, safe 5x5
* `[3]` ball — 7x7 rounded, safe 9x9

Absolute grids (`spellPatterns[4]`, **AB:361-838**), id → source lines → shape:
1 adjacent 3x3 (AB:362-376) · 2 3x3-wave 11x11 letters (AB:377-407) ·
3 small area 7x7 (AB:408-430) · 4 medium area 11x11 (AB:431-461) ·
5 ulus area 9x9 ring (AB:462-486) · 6 large area 13x13 diamond (AB:487-521) ·
7 short beam 11x11 letters (AB:522-552) · 8 large beam 15x15 letters (AB:553-591) ·
9 sweep 3x3 (AB:592-611) · 10 small wave 7x7 letters (AB:612-634) ·
11 large wave 11x11 letters (AB:635-664) · 12 huge wave 13x13 letters (AB:665-700) ·
13 flurry 3x4 → **even height, see Pitfalls** (AB:701-715) · 14 greater flurry 5x5 (AB:716-732) ·
15 thousand fist 5x5 cut corners (AB:733-753) · 16 sweeping takedown 5x5 (AB:754-770) ·
17 spiritual outburst 7x7 (AB:771-795) · 18 chained penance 7x7 (AB:796-817) ·
19 balanced brawl 13x7 → **even-ish, unused as a union grid** (AB:818-837).

Per-direction monk grids `monkDirPatterns[patternId][dir]`, `dir` ∈ {0=N,1=E,2=S,3=W}
(**AB:914-1170**): id 9 (3x3, AB:920-941), 13 (11x11, AB:942-995), 14 (11x11, AB:996-1049),
16 (11x11, AB:1050-1103), 19 (13x13, AB:1108-1169).

Legacy compass quadrant grids `posN/posE/posS/posW` (**AB:842-912**): 3x3 for
knights (`voc()==1 or voc()==11`, client vocation numbering `1 Knight … 5 Monk, +10 promoted`),
11x11 otherwise. Only used for the `bestSide` scan (§3.6).

`WAVE_AUGMENTS` (**AB:1290-1294**): `{["exevo gran frigo hur"] = 12}`. If `entry.augmented`
and the lowercased trimmed `entry.spell` is a key, the *counting* pattern id is replaced
(AB:1296-1301). The cast words are unchanged.

---

## 2. The area-counting algorithm

### 2.1 Pattern → tile set (`getSpectatorsByPattern`, `src/client/map.cpp:1475-1540`)

Parse the pattern string character by character with a cell cursor `p`:
* `'0'` or `'-'` → cell disabled, `p++`
* `'1'` or `'+'` → cell enabled, `p++`
* `'N','n','E','e','S','s','W','w'` → cell enabled **iff** `direction` equals that compass
  direction (0 N, 1 E, 2 S, 3 W), `p++`
* any other char (space, newline, tab) → **row separator**, but only closes a row when the
  running `lineLength` is > 1 after decrementing. This is what makes leading indentation
  harmless: a run of spaces never closes a row.
* All rows must have equal width; width and height must both be **odd**, else the function
  logs an error and returns an empty list.

Then, for `y` from `centerPos.y - height/2` to `+height/2` and `x` likewise, in row-major
order, enabled cells contribute every creature standing on `Position(x,y,centerPos.z)`
(single floor, deduplicated by creature id).

`getSpectators(param1, param2)` (`functions/map.lua:8-37`) resolves the centre and direction:
* `param1` is a **table** (position) → centre = that position, **`direction = 8` (invalid)** →
  **all N/E/S/W cells are disabled**. This is why letter grids must be pre-flattened.
* `param1` is a **creature** → centre = its position, direction = its direction.
* no positional arg → centre = player position, direction = **player direction**.

**luaclient implementation:** write `spectatorsByPattern(centerPos, patternStr, direction)`
that parses the grid once (cache by string), then for each enabled offset reads
`LC.state:tile({x=..,y=..,z=centerPos.z})` and collects `things[i].creatureId`.

### 2.2 `getMonstersInArea(category, posOrCreature, pattern, minHp, maxHp, safePattern, names, sightFromPos)` (**AB:2526-2576**)

```
t = (names == true or names == nil) and {} or names       -- lowercase name whitelist

if safePattern then                                        -- PVP-safe pre-check
  for spec in getSpectators(posOrCreature, safePattern):
    if spec ~= player and spec:isPlayer() and not spec:isPartyMember() then return 0
end

if category is 1, 3 or 4 then                              -- NON-AREA path
  if category is 1 or 3 then
    name = target():getName()
    if #t ~= 0 and not table.find(t, name, true) then return 0   -- case-insensitive
  count = number of creatures anywhere ON SCREEN with
          isMonster and type<3 and minHp <= hp% <= maxHp and (#t==0 or name:lower() in t)
  return count                                             -- NOTE: not distance-limited
end

-- AREA path (categories 2 and 5)
count = 0
for spec in getSpectators(posOrCreature, pattern):
  if spec ~= player and spec:isMonster() and type<3
     and minHp <= hp% <= maxHp
     and (#t==0 or table.find(t, spec:getName():lower()))     -- exact match, both lowered
     and (sightFromPos == nil or isSightClear(sightFromPos, spec:getPosition()))
  then count = count + 1
return count
```
`hp%` is `Creature::getHealthPercent()`, a u8 0..100 (`src/client/creature.h:114`).
Both HP bounds are **inclusive**.

### 2.3 Sight / wall check

`posSightClear(a,b)` = `g_map.isSightClear(a,b)` (**AB:1206-1210**), and
`spellCanReach(fromPos, creature) = posSightClear(fromPos, creature:getPosition())`
(**AB:1211-1213**). If the binding is missing the helper returns `true` (fail-open).

`Map::isSightClear` (`src/client/map.cpp:1181-1225`) is a Bresenham-style walk on the line
`A·x + B·y + C = 0` with `A = dest.y-start.y`, `B = start.x-dest.x`,
`C = -(A·dest.x + B·dest.y)`; at each step it advances y and/or x toward the destination
choosing whichever of `move_hor`/`move_ver`/`move_cross` keeps the line error smallest,
and returns **false** as soon as an intermediate tile exists and `!tile->isLookPossible()`
(i.e. the tile carries the `BLOCK_PROJECTILE` flag, `src/client/tile.h:81`). Same-position
is trivially clear. Missing (never-described) tiles are treated as clear.

**luaclient pitfall:** `assets/items1530.bin` carries only CUMULATIVE/WEAROUT/EXPIRE/
CONTAINER/CLASSIFY/PODIUM/DECOKIT (API.md `proto/items.lua`), **not** `blockProjectile`.
So a faithful `isLookPossible` is impossible today. Implement `isSightClear` with the exact
line walk above and a per-tile predicate that returns `true` unless the tile is known to
block. Until a `blockProjectile` bit is added to the item asset, the function degrades to
"always clear" — which is exactly what vBot does when the binding is unavailable, so
behaviour is unchanged, only quality of direction picking degrades.

`tile:canShoot()` (no arg) = `isSightClear(playerPos, tilePos)` only.
`tile:canShoot(d)` / `creature:canShoot(d)` additionally requires
`max(|dx|,|dy|) <= d` from the player (`src/client/tile.cpp:1133-1141`,
`src/client/creature.cpp:1418-1420`).

### 2.4 Direction picking for waves/beams — `getWaveBestDir` (**AB:1222-1276**)

```
if type(letterPattern) ~= "string" then return -1, 0, {0,0,0,0}   -- never crash
t = names or {}
if safePattern then
  for spec in getSpectators(pos(), safePattern):
    if spec ~= player and spec:isPlayer() and not spec:isPartyMember() then
       return -1, 0, {0,0,0,0}                                  -- whole spell vetoed
grids = cache[letterPattern] or { [d] = extractDirGrid(letterPattern, "NESW"[d]) for d=0..3 }
bestCount, bestDir, curDir = -1, 0, player:getDirection()
for dir = 0..3:
   count = 0
   for spec in getSpectators(myPos, grids[dir]):          -- plain 1/0 grid, no letters
      if spec ~= player and spec:isMonster()
         and minHp <= hp <= maxHp and (#t==0 or name in t)
         and isSightClear(myPos, spec:getPosition())
      then count++
   counts[dir] = count
   if count > bestCount or (count == bestCount and dir == curDir) then
      bestCount, bestDir = count, dir                      -- tie → keep current facing
return bestCount, bestDir, counts
```
`extractDirGrid(letterPattern, letter)` (**AB:1178-1195**) trims each non-empty line and
rewrites every character to `"1"` if it equals `letter`, else `"0"`, producing a plain grid
of the same dimensions. Grids are memoised per pattern string in a weak-keyed table
(**AB:1198**).

`getMonkBestDir(patternId, minHp, maxHp, safePattern, names)` (**AB:1303-1345**) is the
same loop but reads `monkDirPatterns[patternId][dir]` directly (no extraction) and
evaluates the safe-pattern veto *inside* the per-direction loop (equivalent effect —
the safe pattern does not depend on `dir` because it is passed as a position, so all four
directions are blocked together). Same tie-break toward the current facing. Returns
`bestCount, bestDir`.

`getDirectionToPos(from, to)` (**AB:1350-1360**): `dx=to.x-from.x`, `dy=to.y-from.y`;
if both zero → current direction; if `|dx| >= |dy|` → `dx>0 and 1 or 3` (E/W); else
`dy>0 and 2 or 0` (S/N).

### 2.5 Best tile for an area rune — `getBestTileByPattern` (**AB:2580-2596**)

```
best = {amount=0, pos=false}
for tile in g_map.getTiles(posz()):                    -- every known tile on this floor
   tPos = tile:getPosition()
   if tile:canShoot() and tile:isWalkable() and distanceFromPlayer(tPos) < 4 then
      n = getMonstersInArea(2, tPos, pattern, minHp, maxHp, safePattern, names, tPos)
      if n > best.amount then best = {amount=n, pos=tPos}     -- strict >, first wins ties
return best.amount > 0 and best or false
```
`tile:isWalkable()` with no argument means `ignoreCreatures = false`
(`src/client/tile.h:75`, `tile.cpp:708-725`) — a tile occupied by a non-passable, visible
creature is **not** a candidate. Distance is strict `< 4`, i.e. Chebyshev 0..3.
The `safePattern` is evaluated centred on the *candidate tile*, not on the player.

**luaclient mapping:** iterate `LC.state.map` keys, filter `z == player.pos.z`, use
`LC.state:walkableAt(pos)` (treat `'items-unknown'` as walkable, everything else as not).

---

## 3. Firing logic per tick

### 3.0 Global gates (in order, **AB:2708-2733**)

```
if not currentSettings.enabled                            then return
if #currentSettings.attackTable == 0                      then return
if isInPz()                                               then return   -- PlayerStates.Pz = 16384
if not target()                                           then return   -- g_game.isAttacking()
if Training and target():getName():lower():find("training") then return
if clientVersion < 960 or (not CustomCooldown and not ServerCooldown) then delay(400)
```
* `isInPz()` = `bit.band(player.states, 16384) ~= 0`
  (`functions/player_conditions.lua:31`, `modules/gamelib/player.lua:20`). In luaclient:
  `bit.band(LC.state.player.states, 0x4000) ~= 0`.
* `target()` = the creature returned by `g_game.getAttackingCreature()` when
  `g_game.isAttacking()` (**VL:1002-1009**). **AttackBot never picks a target itself** —
  it only fires at whatever TargetBot (or the user) is attacking. In luaclient, keep a
  module-level `currentTargetId` written by whatever issues `sender:attack(id)`,
  cleared on `attackCancel` / `creatureDisappear`.
* On this build `clientVersion` is 1530 and one of the two cooldown modes is normally on,
  so the 400 ms self-throttle is inactive.

Then the compass scan (**AB:2735-2759**):
```
monstersN = getCreaturesInArea(pos(), posN, 2)   -- 2 = "count monsters"
monstersE, monstersS, monstersW likewise
bestSide = max of the four
bestDir  = first of N(0), E(1), S(2), W(3) whose count == bestSide
```
`getCreaturesInArea` (**VL:1055-1074**) counts `spec ~= player and isMonster and type<3`
inside `getSpectators(pos, pattern)`. `bestDir` is computed but **never used**;
only `bestSide` is used, and only by pattern 8 (§3.6).

### 3.1 Per-entry pre-gates (**AB:2783-2797**)

```
for entry in list order:
  attackData = (entry.itemId > 100) and entry.itemId or entry.spell
  if not entry.enabled then continue
  if manapercent() < entry.mana then continue            -- floor(mana*100/maxMana), 100 if maxMana<=1
  if entry.harmony > 0 and player:getHarmony() < entry.harmony then
       if entry.itemId > 100 then runeDelayTimers[itemId] = nil
       continue
  executeCooldown = CustomCooldown and entry.cooldown
                 or ServerCooldown  and 30
                 or 0
```
`player:getHarmony()` is a u8 pushed by server opcode **0xC1 (193) MonkData**, subtype
`TYPES_MONK_HARMONY` (`src/client/protocolgameparse.cpp:5359-5366`,
`src/client/protocolcodes.h:193`). luaclient already parses it into
`state.player.harmony` (`proto/parser.lua:2093-2097`).

### 3.2 Readiness — spells (**AB:2612-2630, AB:2808**)

```
attackSpellCooldownReady(words):
   if not ServerCooldown then return canCast(words, false, true)      -- ignore cooldown entirely
   remaining = getRealSpellRemaining(words)
   if remaining == nil then return canCast(words, false, false)       -- icon-based fallback
   if remaining <= getRawPing() then return canCast(words, false, true)
   return false
```
* `getRealSpellRemaining(words)` (**AB:104-137**): look up `getSpellData(words)`; take
  `SpellCooldownCache[data.id].exhaustion - (now - startTime)`; then for every
  `groupId` in `data.group`, take `SpellCooldownCache["group_"..groupId]` the same way and
  keep the **maximum** remaining. Returns `nil` when no entry exists yet.
* `SpellCooldownCache` is populated by connecting to `g_game.onSpellCooldown(spellId, delay)`
  and `onSpellGroupCooldown(groupId, delay)` (**AB:68-102**) — in luaclient these are the
  existing `spellCooldown` / `spellGroupCooldown` events (API.md, `proto/parser.lua`).
  Store `{exhaustion = delay, startTime = now}` keyed by `spellId` and `"group_"..groupId`.
* `getRawPing()` = `g_game.getPing()` or 0 (**AB:157-161**). Fire up to one ping early, and
  keep retrying every tick until it lands (a wasted chat packet is free).
* `canCast(spell, ignoreRL, ignoreCd)` (**VL:279-306**):
  if `SpellCastTable[spell]` exists → `now - t > d` or `ignoreCd`;
  else if `getSpellData(spell)` → `(ignoreCd or not getSpellCoolDown(spell)) and
  (ignoreRL or level() >= data.level and mana() >= data.mana)`;
  else → `true` (unknown formula ⇒ always allowed).
* `getSpellData` (**VL:333-360**) looks the formula up in
  `modules/gamelib/SpellInfo['Default']` by exact `words` match (206 entries,
  `modules/gamelib/spells.lua`); entry shape:
  `{id, name, words, type, level, mana, soul, maglevel, clientId, group={[groupId]=ms},
    needTarget, range, exhaustion, premium, vocations, ...}` — e.g.
  `['Chained Penance'] = {id=288, words='exori med pug', level=70, mana=180,
    group={[1]=2000}, needTarget=false, range=-1, exhaustion=4000, vocations={9,10}}`
  (`modules/gamelib/spells.lua:234`).
  **A headless client must embed this table** (or at least the `words → {id, level, mana,
  group}` projection) as static configuration data.

### 3.3 Readiness — runes (**AB:2809-2892**)

```
useCooldownClear = getMultiUseCooldown() <= 0
if ServerCooldown:
    groupRemaining = getRealGroupRemaining(1)              -- group 1 = "Attack"
    if groupRemaining then
        readyAt = now + groupRemaining
        if now >= readyAt - USE_COOLDOWN_MS then                       -- 1000 ms
            AttackBotFiringUntil = max(AttackBotFiringUntil, readyAt + 150)
        runeReady = groupRemaining <= getRawPing()
                    and (not Visible or hasItemAvailable(itemId))
    else
        runeReady = (not isGroupCooldownIconActive(1))
                    and (not Visible or hasItemAvailable(itemId))
elseif CustomCooldown:
    readyAt = (runeCooldowns[itemId] or 0) + entry.cooldown*1000 - getPingCompensation()
    if now >= readyAt - USE_COOLDOWN_MS then
        AttackBotFiringUntil = max(AttackBotFiringUntil, readyAt + 150)
    runeReady = now >= readyAt and (not Visible or hasItemAvailable(itemId))
else:
    runeReady = (not Visible or hasItemAvailable(itemId))
canUse = runeReady and useCooldownClear
if runeReady then AttackBotRuneReadyUntil = now + 250
```
* **Shared "use anything" cooldown** (**AB:14-66**): `USE_COOLDOWN_MS = 1000`, a fixed
  server constant on this shard; `SharedUseCooldown.expiresAt` is bumped by
  `recordLocalUseCooldown()` the instant a rune (or HealBot potion) is sent, never from a
  server event. `getMultiUseCooldown() = max(0, expiresAt - now - getPingCompensation())`.
  `getPingCompensation() = ping > 150 and (ping - 30) or 0` (**AB:52-60**).
* `hasItemAvailable(id)` = `itemAmount(id) > 0` where `itemAmount` is
  `max(server-pushed inventory count, visible-container scan)` (**VL:863-886**).
  luaclient: count from `state.player.inventory` + all open `state.containers`, or
  (better) from the 0xF5 inventory-count cache if parsed.
* `isGroupCooldownIconActive(g)` = `g_clock.millis() < groupCooldown[g]`
  (`modules/game_cooldown/cooldown.lua:521-528`) — equivalent to
  `SpellCooldownCache["group_1"]` still running, so in luaclient both branches collapse to
  the same cache. Keep the numeric-ETA branch and treat "no cache entry" as ready.

### 3.4 If **not** `canUse` (**AB:3093-3101**)

```
if entry.itemId > 100 then
   runeDelayTimers[itemId] = nil
   if runeReady then return          -- HOLD the whole tick: a rune whose own cooldown is
                                     -- clear but which is waiting on the shared 1 s use-slot
                                     -- must not let lower-priority entries steal the slot
```
Spells simply fall through to the next entry.

### 3.5 PvP mode short-circuit (**AB:2896-2907**)

Evaluated **before** the optimizers and before any counting:
```
if pvpMode and minHp <= target():getHealthPercent() <= maxHp and target():canShoot() then
   if entry.category == 2 then warn("Area Runes cannot be used in PVP situation!"); return
   if entry.itemId > 100 then
       if not runeDelayGate(itemId) then return
       if CustomCooldown then runeCooldowns[itemId] = now
       AttackBotFiringUntil = now + 150
   return executeAttackBotAction(entry.category, attackData, executeCooldown)
```
No count check, no name filter, no pattern, no BlackList/Kills guard. `canShoot()` here is
the no-argument form: sight-clear only, no distance limit.

### 3.6 Legacy per-category dispatch

Run only when `tryOptimizedSpell` returned `handled == false` (**AB:2912-2914**).

**Category 4 — Empowerment** (**AB:2915-2919**)
```
if not isBuffed() then
   n = getMonstersInArea(4, nil, nil, minHp, maxHp, false, monsters)   -- whole screen
   if countGate(n) and distanceFromPlayer(target():getPosition()) <= entry.pattern then
       return cast(words)
```
`isBuffed()` (**VL:188-203**) = has `PlayerStates.PartyBuff` (4096) **and** the best of
skills 1..4 has `(skillLevel - baseLevel)/100*305 > baseLevel`. In luaclient:
`bit.band(states, 4096) ~= 0` plus the skill-bonus ratio over `state.player.skills`.
*No BlackList/Kills guard on this path.*

**Categories 1 and 3 — Targeted spell / targeted rune** (**AB:2921-2930**)
```
n = getMonstersInArea(entry.category, nil, nil, minHp, maxHp, false, monsters)
if countGate(n) and distanceFromPlayer(target():getPosition()) <= entry.pattern then
   if itemId > 100 then
       if not runeDelayGate(itemId) then return
       if CustomCooldown then runeCooldowns[itemId] = now
       AttackBotFiringUntil = now + 150
   return executeAttackBotAction(entry.category, attackData, executeCooldown)
```
Remember the category-1/3 branch of `getMonstersInArea` first rejects outright if the
**current target's name** is not in the whitelist, then counts *all* matching monsters on
screen (not only those near the target). *No BlackList/Kills guard on this path either.*

**Category 5 — Absolute** (**AB:2932-3070**), with
`pattern = augmentedWavePattern(entry)` and `pCat = entry.patternCategory` (always 4):

*(a) Direction spells* `pattern ∈ {9, 13, 14, 16, 19}` (AB:2939-2954)
```
safe = PvpSafe and spellPatterns[4][pattern][2] or false
n, dir = getMonkBestDir(pattern, minHp, maxHp, safe, monsters)
if countGate(n) and blacklistOk() and killsOk() then
    if autoTurnAndFire(dir, fire) then return
```

*(b) Thousand Fist Blows* `pattern == 15` (AB:2955-2977)
```
targetPos = target():getPosition();  if none then return
safe = PvpSafe and spellPatterns[4][15][2] or false
if safe and any non-party player inside getSpectators(targetPos, safe) then return
n = getMonstersInArea(5, targetPos, spellPatterns[4][15][1], minHp, maxHp, false, monsters, targetPos)
if countGate(n) and distanceFromPlayer(targetPos) <= 5 then
    if autoTurnAndFire(getDirectionToPos(pos(), targetPos), fire) then return
```
Note: **no** BlackList/Kills guard on this sub-path.

*(c) Chain spells* `pattern ∈ {17, 18}`, optimizer OFF (AB:2978-3006)
```
if target() and distanceFromPlayer(target():getPosition()) <= 3 then
  if not (PvpSafe and nonPartyPlayerNear(pos(), 8)) then
     n = count of on-screen monsters (type<3) matching hp+name filters
         with distanceFromPlayer(spec) <= 5           -- range 3 + one 2-sqm jump
     if countGate(n) and blacklistOk() and killsOk() then return fire()
```

*(d) Waves / beams* — `isWave = (pattern == 2 or pattern == 7 or pattern >= 9)`
(AB:3016), reached for `pattern ∈ {2,7,10,11,12}` at this point:
```
safe = PvpSafe and spellPatterns[4][pattern][2] or false
waveCount, waveDir, waveCounts = getWaveBestDir(spellPatterns[4][pattern][1],
                                                minHp, maxHp, safe, monsters)
-- 1) already facing a good direction?
if countGate(waveCounts[player:getDirection()] or 0) then
      if blacklistOk() and killsOk() then return fire()
-- 2) otherwise turn, but only with Auto Turn on
elseif countGate(waveCount) and Rotate and blacklistOk() and killsOk() then
      if safe and any non-party player in getSpectators(pos(), safe) then skip
      if autoTurnAndFire(waveDir, fire) then return
```

*(e) Everything else* — self-centred areas `pattern ∈ {1,3,4,5,6}` **and** `pattern == 8`
(AB:3062-3068)
```
n = getMonstersInArea(5, pos(), spellPatterns[4][pattern][1], minHp, maxHp, safe, monsters, pos())
fires if  (pattern ~= 8 and countGate(n))
      or  (pattern == 8 and bestSide >= entry.count and (not PvpSafe or getPlayers(2) == 0))
guarded by blacklistOk() and killsOk()
```
`getPlayers(range)` (**VL:667-674**) counts non-local players within Chebyshev `range`
excluding party members and green-emblem (guild) players.

**Category 2 — Area rune** (**AB:3072-3090**)
```
safe = PvpSafe and spellPatterns[2][entry.pattern][2] or false
data = getBestTileByPattern(spellPatterns[2][entry.pattern][1], minHp, maxHp, safe, monsters)
if data and countGate(data.amount) and blacklistOk() and killsOk() then
    if not runeDelayGate(entry.itemId) then return
    if CustomCooldown then runeCooldowns[entry.itemId] = now
    AttackBotFiringUntil = now + 400
    recordLocalUseCooldown()                     -- shared 1 s use-lock starts NOW
    return useWith(itemId, g_map.getTile(data.pos):getTopUseThing(), executeCooldown)
```

### 3.7 Shared helpers used by the dispatch

```
countGate(n)      = entry.orMore and n >= entry.count or (not entry.orMore and n == entry.count)
blacklistOk()     = not BlackListSafe or not isBlackListedPlayerInRange(AntiRsRange)
killsOk()         = not Kills or killsToRs() > KillsAmount
nonPartyPlayerNear(centre, r) = any on-screen creature that isPlayer, is not the local
                    player, is not a party member, with getDistanceBetween(centre,p) <= r
                    (AB:1475-1483)
```
* `isBlackListedPlayerInRange(range)` (**VL:676-696**) is **multi-floor**: any player whose
  `|dz| <= 2` (its z flattened to the player's floor) at Chebyshev distance **strictly <**
  `range`, whose name is in `storage.playerList.blackList`.
* `killsToRs()` (**VL:223-228**) = `min(killsDayRemaining, killsWeekRemaining,
  killsMonthRemaining)` from the unjustified-points packet.

### 3.8 Turning — `autoTurnAndFire(neededDir, fireFn)` (**AB:2655-2672**)
```
if player:getDirection() == neededDir then fireFn(); return true
if currentSettings.Rotate then turn(neededDir); fireFn(); return true   -- same tick, 0 delay
return false
```
`turn(dir)` = `g_game.turn(dir)`; the C++ client updates the local direction immediately,
so the subsequent cast is emitted with the new facing already applied. **luaclient must do
the same**: `sender:turn(dir)` then immediately set `state.player.direction = dir` and send
the cast in the same tick (turn packet first, cast packet second — the server processes
them in order).

### 3.9 Rune extra delay — `runeDelayGate(itemId)` (**AB:2681-2705**)
```
if not RuneDelayEnabled then runeDelayTimers[itemId] = nil; return true
delayEnd = runeDelayTimers[itemId]
if not delayEnd then
    delayEnd = now + max(0, RuneDelay - getPingCompensation())
    runeDelayTimers[itemId] = delayEnd
AttackBotFiringUntil = delayEnd + 10          -- reserve the slot for the whole wait
if now < delayEnd then return false
runeDelayTimers[itemId] = nil; return true
```
The timer is started only **after** a real target/pattern match is confirmed, and is
cleared whenever the entry is skipped (mana/harmony/not-ready), so the reservation stays
honest.

### 3.10 The actual send — `executeAttackBotAction(category, idOrFormula, cooldown)` (**AB:2632-2643**)
```
category 1, 4, 5 → cast(formula, cooldown)
category 3       → recordLocalUseCooldown(); useWith(itemId, target(), cooldown)
```
* `cast(text, delay)` (**VL:258-277**): lowercases; if `delay` is nil or `< 100` it is a
  plain `say(text)`; otherwise it maintains `SpellCastTable[text] = {t=lastCastTime, d=delay}`
  and only says when `now - t > d`. `SpellCastTable[text].t` is refreshed by the
  own-talk callback when the server echoes the words (**VL:248-256**) — a real
  cast-confirmation mechanism. In `ServerCooldown` mode `executeCooldown == 30 < 100`, so
  `cast` degenerates to a plain say and the real gating is `attackSpellCooldownReady`.
* `say(text)` (**FN player.lua:90-97**) routes through `tryCastSpellMessage`
  (`modules/game_interface/gameinterface.lua:479-524`): if the words are a known spell and
  protocol >= 1525, it sends **`talkSpell(words, SpellAimTarget=3, sentinel)`**; otherwise a
  plain `talk`. On this Gunz build **every** `talk` at clientVersion >= 1525 carries the aim
  byte (`src/client/protocolgamesend.cpp:710-734`): mode 0..3, modes 1/2 append a valid
  position, mode 3 appends only the byte. luaclient: `sender:talkSpell(words, 3, nil)`.
* `useWith(itemId, thing)` → `g_game.useInventoryItemWith(itemId, thing)`
  (**FN player.lua:168-178**, `src/client/game.cpp:883-906`). The third Lua argument
  (`cooldown`) is **silently dropped** — the C++ signature takes two parameters.
  Wire form: source position is the sentinel `{x=0xFFFF, y=0, z=0}`, source stackpos 0.
  * target is a creature → `sendUseOnCreature(sentinel, itemId, 0, creatureId)`
    (`protocolgamesend.cpp:593-601`) ⇒ luaclient
    `sender:useOnCreature({x=0xFFFF,y=0,z=0}, itemId, 0, creatureId)`
  * target is a tile thing → `sendUseItemWith(sentinel, itemId, 0, thingPos, thingId,
    thingStackPos)` (`protocolgamesend.cpp:580-591`) ⇒ luaclient
    `sender:useWith({x=0xFFFF,y=0,z=0}, itemId, 0, tilePos, topThingId, topThingStack)`.
  * `getTopUseThing()` (`src/client/tile.cpp:600-617`): first thing that `isForceUse()`, or
    the first that is not ground / ground-border / on-bottom / on-top / creature / splash;
    else scan backwards for the last non-splash non-creature thing; else `things[1]`.
    In luaclient the ground item at stack index 1 is normally the right answer for an empty
    tile; implement the full rule once thing-type flags allow it.
* `castAtPos(text, position, delay)` (**AB:1556-1569**) mirrors `cast` but calls
  `castSpellAt(text, position)` = `g_game.talkSpell(text, SpellAimCursor=2, position)`
  (**FN player.lua:101-120**) ⇒ luaclient `sender:talkSpell(text, 2, pos)`.

### 3.11 Interaction with TargetBot's own attack spells

* AttackBot **never selects a target**. It is a pure passenger on
  `g_game.getAttackingCreature()`, which TargetBot sets via `g_game.attack(creature)` at the
  top of `TargetBot.Creature.attack` (`targetbot/creature_attack.lua:58-60`).
  With no target the whole AttackBot tick returns (AB:2727).
* TargetBot has its own, completely independent attack section
  (`targetbot/creature_attack.lua:66-112`): group-attack spell, group-attack rune,
  single attack spell, single attack rune — each gated only by its own
  `lastAttackSpell` / `lastRuneAttack` timestamps (`targetbot/target.lua:285-333`).
  There is **no shared lock, no priority arbitration and no cooldown sharing** with
  AttackBot; both can and do fire in the same window, and the server drops the loser.
  Recommendation for a reimplementation: keep both, but wire TargetBot's rune path into the
  same `SharedUseCooldown` (`recordLocalUseCooldown`) that AttackBot and HealBot use —
  vBot does not, which is a real source of wasted runes.
* The only cross-module arbitration that *does* exist is with **HealBot**, via two globals
  AttackBot writes and HealBot reads: `AttackBotFiringUntil` and `AttackBotRuneReadyUntil`
  (**AB:166-167**; consumed at `HealBot.lua:728, 757, 765` — HealBot refuses to fire a
  potion while `now < AttackBotFiringUntil` or `now < AttackBotRuneReadyUntil`).
  Reproduce them as two module-level timestamps in a shared table.

---

## 4. Profiles and persistence

* Five profiles per config, always exactly five; created blank if missing or if
  `#AttackBotConfig["AttackBot"] ~= 5` (**AB:1635-1718**).
* `AttackBotConfig.currentBotProfile` ∈ 1..5, coerced to 1 when nil/0/>5 (**AB:1720-1722**).
  `setActiveProfile()` sets `currentSettings = AttackBotConfig["AttackBot"][n]`
  (**AB:1728-1732**).
* Migration on load, applied to **all five** profiles (**AB:1734-1757**):
  `AntiRsRange` default 5, `RuneDelay` default 50, `RuneDelayEnabled` default true,
  `OptPenance/OptOutburst/OptTFB/OptThorns/OptGlacier` default false.
* Persisted file:
  `/bot/<configName>/vBot_configs/profile_<g_settings.profile>/AttackBot.json`
  (`vBot/configs.lua:20-27`), written by `vBotConfigSave("atk")` →
  `json.encode(AttackBotConfig, 2)` (`vBot/configs.lua:63-97`).
  On disk for this install:
  `D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot_configs\profile_1\AttackBot.json`.
* Saved on: toggling the AttackBot switch (AB:1767), closing the settings window — which
  also rebuilds `attackTable` from the widget list (AB:1782-1790) — `AttackBot.setOn/setOff`
  (AB:2490, 2496) and any profile switch (AB:2463).
* **Blacklist** for `BlackListSafe` lives elsewhere:
  `/bot/<configName>/storage/profile_<N>.json` → `playerList.blackList` (array of names)
  (`mods/game_bot/bot.lua:268-273`; verified in the on-disk `storage/profile_1.json`).
* **Not persisted:** `Training` is toggled and read but never given a default (AB:2352-2355,
  AB:2729), so it is absent from the JSON until first clicked (treat missing as `false`).
* **Dead keys present in old saves:** `ignoreMana`, `Cooldown` — never read by AttackBot.lua.
* Public API (**AB:2475-2516**): `AttackBot.isOn/isOff/setOn/setOff/getActiveProfile/
  setActiveProfile(n)/show`. `setActiveProfile` errors outside 1..5.

**[WIDGET-ONLY]** everything from AB:1725 to AB:2516 except the profile table creation, the
migration block, the `onVisibilityChange` persistence and the public API: the spell-icon
lookup (AB:180-229), the spell picker and its vocation filter (AB:1978-2144), the
category/pattern comboboxes and `AUTO_DETECT` (AB:1879-1959, a UX convenience that maps a
formula to `{category, pattern}`; a headless client stores the resolved numbers directly),
`setupWidget`, `resetFields`, `loadSettings`, the up/down reorder buttons.

---

## 5. Spell optimizers — **OPTIONAL, skip in a first implementation**

Opt-in per profile via five booleans (`OptPenance`, `OptOutburst`, `OptTFB`,
`OptThorns`, `OptGlacier`, all default `false`). Entry point
`tryOptimizedSpell(entry, attackData, executeCooldown)` (**AB:1584-1631**) returns
`handled, fired`; `handled` means the legacy path is skipped entirely for this entry.
Recognised by formula in **any** category via `OptimizedSpells` (**AB:1388-1397**):

| formula | flag | mode | castRange | jumps | jumpDist |
|---|---|---|---|---|---|
| `exori med pug` | OptPenance | hop | 3 | 4 | 2 |
| `exori gran mas nia` | OptOutburst | hop | 3 | 7 | 2 |
| `exevo fur tera` | OptThorns | star | 4 | 5 | 4 |
| `exevo fur frigo` | OptGlacier | star | 4 | 6 | 4 |
| `exori mas amp pug` | OptTFB | tile | 5 | – | – |

Common pre-gate (**AB:1593-1603**): count filter-matching monsters on screen; if fewer than
`entry.count`, return `handled=true, fired=false` without the expensive scan.

**Chained Penance (`OptPenance`).** The server hits the attacked target within range 3 and
then chains to up to 4 more enemies, each jump reaching at most 2 sqm from the *last*
creature hit and preferring the highest remaining HP%. The optimizer builds a world list of
every non-summon monster on screen (`collectChainWorld`, **AB:1411-1427**), marks which of
them satisfy this entry's HP/name filters, and for every filter-matching, in-range,
`canShoot(3)` candidate simulates that hop chain (`simulateHopChain`, **AB:1431-1455**),
skipping candidates without clear sight from the previous link. It picks the seed whose
chain covers the most *counted* monsters, breaking ties on total hits and then on "is
already my current target"; if the count gate passes and the profile guards pass, it
re-issues `attack(seed)` (unless it is already the target) and casts in the same tick, so
the attack packet is processed before the talk packet (**AB:1488-1512, AB:1621-1630**).

**Spiritual Outburst (`OptOutburst`).** Identical machinery to Chained Penance —
`mode="hop"`, cast range 3, jump distance 2 — but with 7 additional jumps instead of 4,
matching the monk chain system's larger reach for this spell. It consumes Harmony
server-side, so the entry's `harmony` threshold (§3.1) is what stops it firing without
resource; the optimizer itself does not read Harmony.

**Forked Thorns (`OptThorns`) / Forked Glacier (`OptGlacier`).** These are *star* shapes,
not hop chains: every extra hit is measured from the **initial target**, up to 4 sqm away,
capped at 5 (Thorns) or 6 (Glacier) additional enemies. `starChainScore` (**AB:1458-1473**)
counts all sight-clear monsters within 4 sqm of the seed, clamps both the "counted" and
"total" numbers to the cap (exact whenever the cluster fits inside the cap), adds the seed
itself, and the same best-seed selection and re-target-then-cast sequence is used.

**Thousand Fist Blows (`OptTFB`).** A thrown 5x5-with-cut-corners area
(`spellPatterns[4][15][1]`, **AB:1399**) that this client can aim at an arbitrary tile via
`castSpellAt` → `talkSpell(words, SpellAimCursor=2, pos)`. `findBestTfbTile`
(**AB:1525-1551**) seeds the player's **own** tile first (always a legal aim point, distance
0), then scores every tile on the floor with `0 < distanceFromPlayer <= 5` that
`canShoot()` and `isWalkable(true)` — note `ignoreCreatures = true`, unlike area runes — by
how many filter-matching monsters its 5x5 area covers, with `sightFromPos` set to the
candidate tile. Ties break toward the tile **closest to the player**, because melee
monsters converge on the player between scoring and resolution. With `PvpSafe`, a candidate
is rejected if any non-party player is within 3 sqm of it (area radius 2 + 1 margin). If
the best tile passes the count gate and the profile guards, it casts at that tile; if
`castSpellAt` reports the client cannot aim, it returns `handled=false` and the legacy
face-the-target path takes over (**AB:1605-1614**).

Optimizer-specific guards: `optimizerGuardsPass()` = BlackList + Kills checks
(**AB:1571-1574**); chain modes additionally bail out when `PvpSafe` and a non-party player
is within `castRange + 2*jumpDist + 1` of the player (**AB:1618-1620**).

---

## 6. What a first implementation should build

1. `spectatorsByPattern(centre, grid, direction)` + a grid parser/cache.
2. `isSightClear(a,b)` (fail-open until item projectile flags exist).
3. `getMonstersInArea` exactly as §2.2, `getBestTileByPattern` as §2.5.
4. `getWaveBestDir` / `getMonkBestDir` / `extractDirGrid` as §2.4.
5. The tick of §3, iterating `attackTable` in order, with `return`-on-fire semantics.
6. Cooldown bookkeeping: `SpellCooldownCache` from the `spellCooldown`/`spellGroupCooldown`
   events, `SharedUseCooldown` written on every rune/potion send.
7. Config: read `AttackBot.json` verbatim; embed `SpellInfo['Default']` and the pattern
   grids as static Lua tables.
Skip §5 entirely at first; every optimized spell has a working legacy path.


## Configuration format

## Persisted file

Path: `/bot/<configName>/vBot_configs/profile_<g_settings.getNumber('profile')>/AttackBot.json`
(built at `vBot/configs.lua:25`, written by `vBotConfigSave("atk")` at `vBot/configs.lua:63-97`
as `json.encode(AttackBotConfig, 2)`).

On this machine: `D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot_configs\profile_1\AttackBot.json`

## Shape

```
{
  "currentBotProfile": <1..5>,
  "AttackBot": [ <profile1>, <profile2>, <profile3>, <profile4>, <profile5> ]   // exactly 5
}
```

Profile object (defaults from AttackBot.lua:1637-1652, migrations AttackBot.lua:1741-1757):

```
{
  "name":             "Profile #1",   // free text
  "enabled":          false,          // this profile's master switch
  "attackTable":      [ <entry>, ... ],   // ORDER = PRIORITY, index 1 fires first
  "Rotate":           false,   // "Auto Turn (Waves, Monk Spells...)"
  "Kills":            false,   // don't use area attacks if killsToRs() <= KillsAmount
  "KillsAmount":      1,       // 1..10
  "CustomCooldown":   false,   // mutually exclusive with ServerCooldown
  "ServerCooldown":   true,
  "Visible":          true,    // runes: require hasItemAvailable(itemId)
  "pvpMode":          false,   // fire at the player target ignoring counts/patterns
  "PvpSafe":          true,    // use the [2] "safe" grids / non-party-player vetoes
  "BlackListSafe":    false,   // stop if an AntiRS-listed player is in range
  "AntiRsRange":      5,       // 1..10 (multi-floor, strict <)
  "RuneDelay":        50,      // 0..5000 ms extra wait before firing a rune
  "RuneDelayEnabled": true,
  "OptPenance":  false, "OptOutburst": false, "OptTFB": false,
  "OptThorns":   false, "OptGlacier":  false,
  "Training":    <absent until first toggled; treat missing as false>,
  "ignoreMana":  <legacy, never read>, "Cooldown": <legacy, never read>
}
```

Entry object (built at AttackBot.lua:2258-2277):

```
{
  "spell":  "exori mas res",  // "" when itemId > 100
  "itemId": 0,                // > 100 means "this is a rune"
  "category": 1..5, "patternCategory": 1..4, "pattern": <range 1..10 | grid id>,
  "count": 1..99, "orMore": true|false,
  "minHp": 0..99, "maxHp": 1..100,
  "mana": 0..99,              // minimum manapercent()
  "cooldown": 0..999999,      // SECONDS for runes, MILLISECONDS for spells
  "harmony": 0..10,           // minimum player harmony
  "monsters": true | ["name", ...],   // true = any creature; names are lowercase
  "augmented": true|false,
  "enabled": true|false,
  "creatures": "<raw text>",  // WIDGET-ONLY
  "tooltip": false|"<text>",  // WIDGET-ONLY
  "description": "<label>"    // WIDGET-ONLY
}
```

## Real example (verbatim from the profile on disk, reformatted; profiles 2-5 elided)

```json
{
  "currentBotProfile": 1,
  "AttackBot": [
    {
      "name": "Profile #1",
      "enabled": true,
      "Rotate": true,
      "Kills": false, "KillsAmount": 1,
      "CustomCooldown": false, "ServerCooldown": true,
      "Visible": false,
      "pvpMode": false, "PvpSafe": false,
      "BlackListSafe": false, "AntiRsRange": 5,
      "RuneDelay": 50, "RuneDelayEnabled": true,
      "OptPenance": true, "OptOutburst": true, "OptTFB": true,
      "OptThorns": false, "OptGlacier": false,
      "ignoreMana": true, "Cooldown": true,
      "attackTable": [
        { "spell": "exori mas res", "itemId": 0,
          "category": 5, "patternCategory": 4, "pattern": 19,
          "count": 1, "orMore": true, "minHp": 0, "maxHp": 100,
          "mana": 10, "cooldown": 1, "harmony": 0,
          "monsters": ["true frost flower asura"],
          "creatures": "true frost flower asura",
          "tooltip": "true frost flower asura",
          "augmented": false, "enabled": true,
          "description": "[Balanced Brawl] 1+ Creatures: exori mas res, absolute (0%-100%)" },

        { "spell": "exori gran mas nia", "itemId": 0,
          "category": 5, "patternCategory": 4, "pattern": 17,
          "count": 5, "orMore": true, "minHp": 0, "maxHp": 100,
          "mana": 20, "cooldown": 1, "harmony": 5,
          "monsters": true, "creatures": "monster names", "tooltip": false,
          "augmented": false, "enabled": true,
          "description": "[Spiritual Outburst] 5+ Any Creatures: exori gran mas nia, absolute (0%-100% [H:5])" },

        { "spell": "exori med pug", "itemId": 0,
          "category": 5, "patternCategory": 4, "pattern": 18,
          "count": 2, "orMore": true, "minHp": 0, "maxHp": 100,
          "mana": 10, "cooldown": 1, "harmony": 0,
          "monsters": true, "creatures": "monster names", "tooltip": false,
          "enabled": true,
          "description": "[Chained Penance] 2+ Any Creatures: exori med pug, absolute (0%-100%)" },

        { "spell": "exori mas amp pug", "itemId": 0,
          "category": 5, "patternCategory": 4, "pattern": 15,
          "count": 4, "orMore": true, "minHp": 0, "maxHp": 100,
          "mana": 10, "cooldown": 1, "harmony": 0,
          "monsters": true, "creatures": "monster names", "tooltip": false,
          "enabled": true,
          "description": "[Thousand Fist Blows] 4+ Any Creatures: exori mas amp pug, absolute (0%-100%)" },

        { "spell": "exori mas nia", "itemId": 0,
          "category": 5, "patternCategory": 4, "pattern": 16,
          "count": 3, "orMore": true, "minHp": 0, "maxHp": 100,
          "mana": 20, "cooldown": 1, "harmony": 5,
          "monsters": true, "augmented": false, "enabled": true,
          "description": "[Sweeping Takedown] 3+ Any Creatures: exori mas nia, absolute (0%-100% [H:5])" },

        { "spell": "exori gran mas pug", "itemId": 0,
          "category": 5, "patternCategory": 4, "pattern": 14,
          "count": 2, "orMore": true, "minHp": 0, "maxHp": 100,
          "mana": 15, "cooldown": 1, "harmony": 0,
          "monsters": true, "enabled": true,
          "description": "[Greater Flurry] 2+ Any Creatures: exori gran mas pug, absolute (0%-100%)" },

        { "spell": "exori mas pug", "itemId": 0,
          "category": 5, "patternCategory": 4, "pattern": 13,
          "count": 1, "orMore": true, "minHp": 0, "maxHp": 100,
          "mana": 10, "cooldown": 1, "harmony": 0,
          "monsters": true, "enabled": true,
          "description": "[Flurry of Blows] 1+ Any Creatures: exori mas pug, absolute (0%-100%)" },

        { "spell": "exori amp pug", "itemId": 0,
          "category": 1, "patternCategory": 1, "pattern": 7,
          "count": 1, "orMore": true, "minHp": 0, "maxHp": 20,
          "mana": 10, "cooldown": 1, "harmony": 0,
          "monsters": true, "enabled": true,
          "description": "[7 Sqm] 1+ Any Creatures: exori amp pug, targeted (0%-20%)" }
      ]
    },
    { "name": "Profile #2", "enabled": false, "attackTable": [], "Rotate": false,
      "Kills": false, "KillsAmount": 1, "CustomCooldown": false, "pvpMode": false,
      "Visible": true, "PvpSafe": true, "BlackListSafe": false, "AntiRsRange": 5,
      "RuneDelay": 50, "RuneDelayEnabled": true, "OptPenance": false,
      "OptOutburst": false, "OptTFB": false, "OptThorns": false, "OptGlacier": false,
      "ignoreMana": true, "Cooldown": true }
    /* profiles 3,4,5 identical to 2 */
  ]
}
```
Note profile 2 in the real file has **no** `ServerCooldown` key at all (it was never
toggled after creation) — a reader must treat missing booleans as `false` and apply the
migration defaults of §4 before use.

## A rune entry, for completeness

An area-rune entry (category 2) looks like:
```json
{ "spell": "", "itemId": 3200, "category": 2, "patternCategory": 2, "pattern": 3,
  "count": 3, "orMore": true, "minHp": 0, "maxHp": 100, "mana": 0,
  "cooldown": 2, "harmony": 0, "monsters": true, "enabled": true,
  "description": "[Ball] 3+ Any Creatures: rune 3200, area (0%-100%)" }
```
(`pattern` 3 = "ball" in `spellPatterns[2]`; `cooldown` here is **seconds**.)

## Secondary config read by AttackBot

`/bot/<configName>/storage/profile_<N>.json` → `playerList.blackList` : array of player
names, used by `BlackListSafe` / `isBlackListedPlayerInRange(AntiRsRange)`
(`mods/game_bot/bot.lua:268-273`, `vlib.lua:676-696`). Verified present in
`D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\storage\profile_1.json`
as `"playerList": {"blackList": [], "enemyList": [], "friendList": [], ...}`.


## Pseudocode

-- =====================================================================
-- attackbot.lua  --  behaviour port of vBot 4.8 AttackBot for luaclient
-- Depends only on: LC.state, LC.sender, LC.sched, LC.events, lib/json,
--                  bit, and two new local helpers (spectatorsByPattern,
--                  isSightClear) implemented at the bottom.
-- =====================================================================

local bit   = require('bit')
local S     = LC.state
local TX    = LC.sender

local M = { cfg = nil, profile = nil, targetId = nil }

-- --------------------------------------------------------------- consts
local USE_COOLDOWN_MS = 1000                 -- AB:33
local PZ_STATE        = 16384                -- gamelib/player.lua:20
local PARTYBUFF_STATE = 4096

-- Static data tables copied VERBATIM from AttackBot.lua:
--   PATTERNS[2][id] = {normalGrid, safeGrid}      -- AB:302-357
--   PATTERNS[4][id] = {normalGrid, safeGrid}      -- AB:361-838
--   MONK_DIR[id][dir 0..3] = grid                 -- AB:920-1169
--   QUADRANT = {posN,posE,posS,posW}              -- AB:844-912 (ek variant if knight)
--   WAVE_AUGMENTS = { ["exevo gran frigo hur"] = 12 }        -- AB:1290
--   SPELLINFO[words] = {id=, level=, mana=, group={[gid]=ms}}  -- gamelib/spells.lua
local PATTERNS, MONK_DIR, QUADRANT, WAVE_AUGMENTS, SPELLINFO = require('bot.attackdata')()

-- ------------------------------------------------- shared cross-module state
LC.shared = LC.shared or {}
local SH = LC.shared
SH.useCooldownExpiresAt   = SH.useCooldownExpiresAt   or 0   -- SharedUseCooldown
SH.attackBotFiringUntil   = SH.attackBotFiringUntil   or 0   -- AB:166
SH.attackBotRuneReadyUntil= SH.attackBotRuneReadyUntil or 0  -- AB:167
SH.spellCooldownCache     = SH.spellCooldownCache     or {}  -- AB:70

local function nowMs() return LC.sys.nowMs() end
local function recordLocalUseCooldown(ms)                    -- AB:34-36
  SH.useCooldownExpiresAt = math.max(SH.useCooldownExpiresAt, nowMs() + (ms or USE_COOLDOWN_MS))
end
local function rawPing() return M.ping or 0 end
local function pingCompensation()                            -- AB:52-60
  local p = rawPing(); return p > 150 and (p - 30) or 0
end
local function multiUseCooldown()                            -- AB:62-66
  return math.max(0, SH.useCooldownExpiresAt - nowMs() - pingCompensation())
end

LC.events.on('spellCooldown', function(d)                    -- AB:88-92
  SH.spellCooldownCache[d.spellId] = { exhaustion = d.delay, startTime = nowMs() } end)
LC.events.on('spellGroupCooldown', function(d)               -- AB:92-94
  SH.spellCooldownCache['group_'..d.groupId] = { exhaustion = d.delay, startTime = nowMs() } end)

local function realSpellRemaining(words)                     -- AB:113-136
  local info = SPELLINFO[words:lower()]; if not info then return nil end
  local rem
  local direct = SH.spellCooldownCache[info.id]
  if direct then rem = direct.exhaustion - (nowMs() - direct.startTime) end
  for gid in pairs(info.group or {}) do
    local g = SH.spellCooldownCache['group_'..gid]
    if g then
      local gr = g.exhaustion - (nowMs() - g.startTime)
      if not rem or gr > rem then rem = gr end
    end
  end
  return rem
end
local function realGroupRemaining(gid)                       -- AB:150-154
  local g = SH.spellCooldownCache['group_'..gid]; if not g then return nil end
  return g.exhaustion - (nowMs() - g.startTime)
end

-- ------------------------------------------------------------ world queries
local function player() return S.player end
local function ppos()   return S.player.pos end
local function dist(a,b) return math.max(math.abs(a.x-b.x), math.abs(a.y-b.y)) end  -- executor.lua:124
local function distFromPlayer(p) return dist(ppos(), p) end
local function manapercent()                                 -- FN player.lua:8-15
  local pl = player()
  if (pl.maxMana or 0) <= 1 then return 100 end
  return math.floor(pl.mana * 100 / pl.maxMana)
end
local function isInPz() return bit.band(player().states or 0, PZ_STATE) ~= 0 end
local function isRealMonster(c)                              -- type<3 excludes summons
  return c.type == 1
end
local function isNonPartyPlayer(c)
  if not c.isPlayer or c.id == player().id then return false end
  local sh = c.shield or 0
  local party = (sh==1 or sh==3 or sh==4 or sh==5 or sh==6 or sh==7 or sh==8 or sh==9 or sh==10)
  return not party
end
-- every creature on the player's floor inside the aware range  (map.h:166)
local function onScreen()
  local out = {}
  for id, c in pairs(S.creatures) do
    if c.pos and c.pos.z == ppos().z and S:isAwareOf(c.pos) then out[#out+1] = c end
  end
  return out
end
local function target()
  return M.targetId and S.creatures[M.targetId] or nil
end

-- ------------------------------------------------- filters (AB:1401-1409)
local function nameFilter(entry)
  local m = entry.monsters
  if m == true or m == nil then return {} end
  return m
end
local function inFilter(t, lowerName)
  if #t == 0 then return true end
  for i = 1, #t do if t[i] == lowerName then return true end end
  return false
end
local function matches(entry, t, hp, lowerName)
  if hp < entry.minHp or hp > entry.maxHp then return false end
  return inFilter(t, lowerName)
end

-- --------------------------------- getMonstersInArea  (AB:2526-2576)
local function getMonstersInArea(category, centre, grid, minHp, maxHp, safeGrid, names, sightFrom)
  local t = (names == true or names == nil) and {} or names

  if safeGrid then
    for _, c in ipairs(spectatorsByPattern(centre, safeGrid, 8)) do
      if isNonPartyPlayer(c) then return 0 end
    end
  end

  if category == 1 or category == 3 or category == 4 then
    if category == 1 or category == 3 then
      local tg = target()
      if #t ~= 0 and not (tg and inFilter(t, tg.name:lower())) then return 0 end
    end
    local n = 0
    for _, c in ipairs(onScreen()) do
      if isRealMonster(c) and matches({minHp=minHp,maxHp=maxHp}, t, c.healthPercent, c.name:lower()) then
        n = n + 1
      end
    end
    return n
  end

  local n = 0
  for _, c in ipairs(spectatorsByPattern(centre, grid, 8)) do
    if c.id ~= player().id and isRealMonster(c)
       and c.healthPercent >= minHp and c.healthPercent <= maxHp
       and inFilter(t, c.name:lower())
       and (not sightFrom or isSightClear(sightFrom, c.pos)) then
      n = n + 1
    end
  end
  return n
end

-- --------------------------------- getBestTileByPattern (AB:2580-2596)
local function getBestTileByPattern(grid, minHp, maxHp, safeGrid, names)
  local best = { amount = 0, pos = nil }
  local z = ppos().z
  for key, tile in pairs(S.map) do
    local p = tileKeyToPos(key)
    if p.z == z then
      local walk = select(1, S:walkableAt(p))
      if walk and isSightClear(ppos(), p) and distFromPlayer(p) < 4 then
        local n = getMonstersInArea(2, p, grid, minHp, maxHp, safeGrid, names, p)
        if n > best.amount then best = { amount = n, pos = p } end
      end
    end
  end
  return best.amount > 0 and best or nil
end

-- --------------------------------- direction scanners (AB:1222-1345)
local DIR_LETTER = { [0]='N', [1]='E', [2]='S', [3]='W' }
local dirGridCache = {}
local function extractDirGrid(letterGrid, letter)            -- AB:1178-1195
  local out = {}
  for line in letterGrid:gmatch('[^\n]+') do
    local trimmed = line:match('^%s*(.-)%s*$')
    if trimmed ~= '' then
      out[#out+1] = trimmed:gsub('.', function(ch) return ch == letter and '1' or '0' end)
    end
  end
  return '\n'..table.concat(out, '\n')..'\n'
end

local function getWaveBestDir(letterGrid, minHp, maxHp, safeGrid, names)
  if type(letterGrid) ~= 'string' then return -1, 0, {[0]=0,[1]=0,[2]=0,[3]=0} end
  local t = (names == true or names == nil) and {} or names
  if safeGrid then
    for _, c in ipairs(spectatorsByPattern(ppos(), safeGrid, 8)) do
      if isNonPartyPlayer(c) then return -1, 0, {[0]=0,[1]=0,[2]=0,[3]=0} end
    end
  end
  local grids = dirGridCache[letterGrid]
  if not grids then
    grids = {}
    for d = 0, 3 do grids[d] = extractDirGrid(letterGrid, DIR_LETTER[d]) end
    dirGridCache[letterGrid] = grids
  end
  local bestCount, bestDir, counts = -1, 0, {}
  local my, cur = ppos(), player().direction
  for d = 0, 3 do
    local n = 0
    for _, c in ipairs(spectatorsByPattern(my, grids[d], 8)) do
      if c.id ~= player().id and isRealMonster(c)
         and c.healthPercent >= minHp and c.healthPercent <= maxHp
         and inFilter(t, c.name:lower()) and isSightClear(my, c.pos) then n = n + 1 end
    end
    counts[d] = n
    if n > bestCount or (n == bestCount and d == cur) then bestCount, bestDir = n, d end
  end
  return bestCount, bestDir, counts
end

local function getMonkBestDir(patternId, minHp, maxHp, safeGrid, names)  -- AB:1303-1345
  local t = (names == true or names == nil) and {} or names
  local bestCount, bestDir = -1, 0
  local my, cur = ppos(), player().direction
  for d = 0, 3 do
    local blocked = false
    if safeGrid then
      for _, c in ipairs(spectatorsByPattern(my, safeGrid, 8)) do
        if isNonPartyPlayer(c) then blocked = true; break end
      end
    end
    local n = 0
    if not blocked then
      for _, c in ipairs(spectatorsByPattern(my, MONK_DIR[patternId][d], 8)) do
        if c.id ~= player().id and isRealMonster(c)
           and c.healthPercent >= minHp and c.healthPercent <= maxHp
           and inFilter(t, c.name:lower()) and isSightClear(my, c.pos) then n = n + 1 end
      end
    end
    if n > bestCount or (n == bestCount and d == cur) then bestCount, bestDir = n, d end
  end
  return bestCount, bestDir
end

local function directionToPos(from, to)                      -- AB:1350-1360
  local dx, dy = to.x - from.x, to.y - from.y
  if dx == 0 and dy == 0 then return player().direction end
  if math.abs(dx) >= math.abs(dy) then return dx > 0 and 1 or 3 end
  return dy > 0 and 2 or 0
end

-- --------------------------------- sends (AB:2632-2643, FN player.lua)
local INV = { x = 0xFFFF, y = 0, z = 0 }
local function castWords(words)                              -- say() -> talkSpell aim 3
  TX:talkSpell(words:lower(), 3, nil)
end
local function castAtTile(words, p) TX:talkSpell(words:lower(), 2, p) end
local function useRuneOnCreature(itemId, creatureId)
  recordLocalUseCooldown()
  TX:useOnCreature(INV, itemId, 0, creatureId)
end
local function useRuneOnTile(itemId, p)
  local thing = topUseThing(p)                               -- tile.cpp:600-617
  TX:useWith(INV, itemId, 0, p, thing.id, thing.stackPos)
end
local function fireEntry(entry, attackData)                  -- executeAttackBotAction
  local cat = entry.category
  if cat == 1 or cat == 4 or cat == 5 then castWords(entry.spell)
  elseif cat == 3 then useRuneOnCreature(entry.itemId, M.targetId) end
end

-- --------------------------------- turn + fire (AB:2655-2672)
local function autoTurnAndFire(neededDir, fireFn)
  if player().direction == neededDir then fireFn(); return true end
  if M.profile.Rotate then
    TX:turn(neededDir); S.player.direction = neededDir      -- local direction is instant
    fireFn(); return true
  end
  return false
end

-- --------------------------------- rune extra delay (AB:2681-2705)
local runeDelayTimers, runeCooldowns = {}, {}
local function runeDelayGate(itemId)
  if not M.profile.RuneDelayEnabled then runeDelayTimers[itemId] = nil; return true end
  local d = runeDelayTimers[itemId]
  if not d then
    d = nowMs() + math.max(0, (M.profile.RuneDelay or 0) - pingCompensation())
    runeDelayTimers[itemId] = d
  end
  SH.attackBotFiringUntil = d + 10
  if nowMs() < d then return false end
  runeDelayTimers[itemId] = nil
  return true
end

-- --------------------------------- profile guards (AB:1571-1578)
local function countGate(entry, n)
  if entry.orMore then return n >= entry.count end
  return n == entry.count
end
local function guardsPass()
  local p = M.profile
  if p.BlackListSafe and blacklistedPlayerInRange(p.AntiRsRange) then return false end
  if p.Kills and killsToRs() <= p.KillsAmount then return false end
  return true
end
local function nonPartyPlayerNear(centre, r)                 -- AB:1475-1483
  for _, c in ipairs(onScreen()) do
    if isNonPartyPlayer(c) and dist(centre, c.pos) <= r then return true end
  end
  return false
end

-- =====================================================================
-- MAIN TICK   (AB:2708-3106).  LC.sched.every(50, M.tick)
-- =====================================================================
local suppressUntil = 0

function M.tick()
  local p = M.profile
  if not p or not p.enabled then return end
  if nowMs() < suppressUntil then return end
  if #p.attackTable == 0 or isInPz() then return end
  local tg = target(); if not tg then return end
  if p.Training and tg.name:lower():find('training') then return end
  if not p.CustomCooldown and not p.ServerCooldown then suppressUntil = nowMs() + 400 end

  -- legacy compass scan; only bestSide is consumed (pattern 8)   AB:2735-2759
  local q = {}
  for d = 0, 3 do
    q[d] = 0
    for _, c in ipairs(spectatorsByPattern(ppos(), QUADRANT[d], 8)) do
      if c.id ~= player().id and isRealMonster(c) then q[d] = q[d] + 1 end
    end
  end
  local bestSide = math.max(q[0], q[1], q[2], q[3])

  for _, entry in ipairs(p.attackTable) do
    local isRune     = entry.itemId > 100
    local attackData = isRune and entry.itemId or entry.spell

    if entry.enabled and manapercent() >= entry.mana then
      if entry.harmony and entry.harmony > 0 and (player().harmony or 0) < entry.harmony then
        if isRune then runeDelayTimers[entry.itemId] = nil end
      else
        local executeCooldown = p.CustomCooldown and entry.cooldown
                             or (p.ServerCooldown and 30 or 0)

        ------------------------------------------------ readiness
        local canUse, runeReady = false, false
        if not isRune then
          -- attackSpellCooldownReady  (AB:2612-2630)
          if not p.ServerCooldown then
            canUse = true                                  -- canCast(..., ignoreCd=true)
          else
            local rem = realSpellRemaining(entry.spell)
            if rem == nil then canUse = not spellIconActive(entry.spell)
            else canUse = (rem <= rawPing()) end
          end
        else
          local useClear = multiUseCooldown() <= 0
          if p.ServerCooldown then
            local gr = realGroupRemaining(1)
            if gr then
              local readyAt = nowMs() + gr
              if nowMs() >= readyAt - USE_COOLDOWN_MS then
                SH.attackBotFiringUntil = math.max(SH.attackBotFiringUntil, readyAt + 150)
              end
              runeReady = gr <= rawPing() and (not p.Visible or hasItem(entry.itemId))
            else
              runeReady = (realGroupRemaining(1) == nil or realGroupRemaining(1) <= 0)
                          and (not p.Visible or hasItem(entry.itemId))
            end
          elseif p.CustomCooldown then
            local readyAt = (runeCooldowns[entry.itemId] or 0)
                            + entry.cooldown * 1000 - pingCompensation()
            if nowMs() >= readyAt - USE_COOLDOWN_MS then
              SH.attackBotFiringUntil = math.max(SH.attackBotFiringUntil, readyAt + 150)
            end
            runeReady = nowMs() >= readyAt and (not p.Visible or hasItem(entry.itemId))
          else
            runeReady = (not p.Visible or hasItem(entry.itemId))
          end
          canUse = runeReady and useClear
          if runeReady then SH.attackBotRuneReadyUntil = nowMs() + 250 end
        end

        if not canUse then
          if isRune then
            runeDelayTimers[entry.itemId] = nil
            if runeReady then return end          -- HOLD the tick  (AB:3100)
          end
        else
          ---------------------------------------- pvp short-circuit (AB:2896)
          if p.pvpMode and tg.healthPercent >= entry.minHp and tg.healthPercent <= entry.maxHp
             and isSightClear(ppos(), tg.pos) then
            if entry.category == 2 then LC.log.warn('area runes not allowed in pvp'); return end
            if isRune then
              if not runeDelayGate(entry.itemId) then return end
              if p.CustomCooldown then runeCooldowns[entry.itemId] = nowMs() end
              SH.attackBotFiringUntil = nowMs() + 150
            end
            fireEntry(entry, attackData); return
          end

          ---------------------------------------- optimizers (OPTIONAL, §5)
          local handled, fired = tryOptimizedSpell(entry, attackData, executeCooldown)
          if fired then return end
          if not handled then

          ---------------------------------------- category dispatch
          if entry.category == 4 and not isBuffed() then                    -- AB:2915
            local n = getMonstersInArea(4, nil, nil, entry.minHp, entry.maxHp, false, entry.monsters)
            if countGate(entry, n) and distFromPlayer(tg.pos) <= entry.pattern then
              fireEntry(entry, attackData); return
            end

          elseif entry.category == 1 or entry.category == 3 then            -- AB:2921
            local n = getMonstersInArea(entry.category, nil, nil, entry.minHp, entry.maxHp, false, entry.monsters)
            if countGate(entry, n) and distFromPlayer(tg.pos) <= entry.pattern then
              if isRune then
                if not runeDelayGate(entry.itemId) then return end
                if p.CustomCooldown then runeCooldowns[entry.itemId] = nowMs() end
                SH.attackBotFiringUntil = nowMs() + 150
              end
              fireEntry(entry, attackData); return
            end

          elseif entry.category == 5 then                                   -- AB:2932
            local pat = entry.pattern
            if entry.augmented then pat = WAVE_AUGMENTS[entry.spell:lower()] or pat end
            local grids = PATTERNS[4][pat]
            local safe  = p.PvpSafe and grids[2] or false
            local fire  = function() fireEntry(entry, attackData) end

            if pat == 9 or pat == 13 or pat == 14 or pat == 16 or pat == 19 then
              local n, d = getMonkBestDir(pat, entry.minHp, entry.maxHp, safe, entry.monsters)
              if countGate(entry, n) and guardsPass() then
                if autoTurnAndFire(d, fire) then return end
              end

            elseif pat == 15 then                                            -- Thousand Fist
              local tp = tg.pos
              if safe then
                for _, c in ipairs(spectatorsByPattern(tp, safe, 8)) do
                  if isNonPartyPlayer(c) then return end
                end
              end
              local n = getMonstersInArea(5, tp, grids[1], entry.minHp, entry.maxHp, false, entry.monsters, tp)
              if countGate(entry, n) and distFromPlayer(tp) <= 5 then
                if autoTurnAndFire(directionToPos(ppos(), tp), fire) then return end
              end

            elseif pat == 17 or pat == 18 then                               -- chain fallback
              if distFromPlayer(tg.pos) <= 3
                 and not (p.PvpSafe and nonPartyPlayerNear(ppos(), 8)) then
                local t, n = nameFilter(entry), 0
                for _, c in ipairs(onScreen()) do
                  if isRealMonster(c)
                     and matches(entry, t, c.healthPercent, c.name:lower())
                     and distFromPlayer(c.pos) <= 5 then n = n + 1 end
                end
                if countGate(entry, n) and guardsPass() then fire(); return end
              end

            else
              local isWave = (pat == 2 or pat == 7 or pat >= 9)
              if isWave then
                local wc, wd, counts = getWaveBestDir(grids[1], entry.minHp, entry.maxHp, safe, entry.monsters)
                if countGate(entry, counts[player().direction] or 0) then
                  if guardsPass() then fire(); return end
                elseif countGate(entry, wc) and p.Rotate and guardsPass() then
                  local blocked = false
                  if safe then
                    for _, c in ipairs(spectatorsByPattern(ppos(), safe, 8)) do
                      if isNonPartyPlayer(c) then blocked = true; break end
                    end
                  end
                  if not blocked and autoTurnAndFire(wd, fire) then return end
                end
              else
                local n = getMonstersInArea(5, ppos(), grids[1], entry.minHp, entry.maxHp, safe, entry.monsters, ppos())
                local ok = (pat ~= 8 and countGate(entry, n))
                        or (pat == 8 and bestSide >= entry.count
                            and (not p.PvpSafe or countNonPartyPlayersWithin(2) == 0))
                if ok and guardsPass() then fire(); return end
              end
            end

          elseif entry.category == 2 then                                   -- area rune
            local grids = PATTERNS[2][entry.pattern]
            local safe  = p.PvpSafe and grids[2] or false
            local data  = getBestTileByPattern(grids[1], entry.minHp, entry.maxHp, safe, entry.monsters)
            if data and countGate(entry, data.amount) and guardsPass() then
              if not runeDelayGate(entry.itemId) then return end
              if p.CustomCooldown then runeCooldowns[entry.itemId] = nowMs() end
              SH.attackBotFiringUntil = nowMs() + 400
              recordLocalUseCooldown()
              useRuneOnTile(entry.itemId, data.pos); return
            end
          end
          end -- not handled
        end
      end
    end
  end
end

-- =====================================================================
-- spectatorsByPattern  (Map::getSpectatorsByPattern, map.cpp:1475-1540)
-- =====================================================================
local gridCache = {}
local function parseGrid(gridStr)
  local g = gridCache[gridStr]
  if g then return g end
  local cells, width, height, lineLen = {}, 0, 0, 0
  for i = 1, #gridStr do
    local ch = gridStr:sub(i, i)
    if ch == '0' or ch == '-' then cells[#cells+1] = false; lineLen = lineLen + 1
    elseif ch == '1' or ch == '+' then cells[#cells+1] = true;  lineLen = lineLen + 1
    elseif ch:match('[NnEeSsWw]') then cells[#cells+1] = ch:upper(); lineLen = lineLen + 1
    else
      if lineLen > 1 then
        if width == 0 then width = lineLen end
        assert(width == lineLen, 'ragged pattern')
        height = height + 1; lineLen = 0
      elseif lineLen == 1 then lineLen = 0 end
    end
  end
  if lineLen > 0 then
    if width == 0 then width = lineLen end
    assert(width == lineLen, 'ragged pattern'); height = height + 1
  end
  assert(width % 2 == 1 and height % 2 == 1, 'pattern dims must be odd')
  g = { cells = cells, w = width, h = height }
  gridCache[gridStr] = g
  return g
end

function spectatorsByPattern(centre, gridStr, direction)
  -- direction: 0 N, 1 E, 2 S, 3 W; 8 = invalid => all letter cells disabled
  local g = parseGrid(gridStr)
  local letter = ({[0]='N',[1]='E',[2]='S',[3]='W'})[direction]
  local out, seen, p = {}, {}, 0
  for y = centre.y - math.floor(g.h/2), centre.y + math.floor(g.h/2) do
    for x = centre.x - math.floor(g.w/2), centre.x + math.floor(g.w/2) do
      p = p + 1
      local cell = g.cells[p]
      local on = (cell == true) or (type(cell) == 'string' and cell == letter)
      if on then
        local tile = S:tile({x=x, y=y, z=centre.z})
        if tile then
          for _, th in ipairs(tile.things) do
            if th.kind == 'creature' and th.creatureId and not seen[th.creatureId] then
              local c = S.creatures[th.creatureId]
              if c then seen[th.creatureId] = true; out[#out+1] = c end
            end
          end
        end
      end
    end
  end
  return out
end

-- =====================================================================
-- isSightClear  (Map::isSightClear, map.cpp:1181-1225)
-- Fails OPEN on unknown tiles and on tiles whose blocking flags we lack.
-- =====================================================================
function isSightClear(fromPos, toPos)
  if fromPos.x == toPos.x and fromPos.y == toPos.y and fromPos.z == toPos.z then return true end
  local sx, sy = fromPos.x, fromPos.y
  local dx, dy = toPos.x, toPos.y
  local mx = sx < dx and 1 or (sx == dx and 0 or -1)
  local my = sy < dy and 1 or (sy == dy and 0 or -1)
  local A = dy - sy
  local B = sx - dx
  local C = -(A * dx + B * dy)
  while sx ~= dx or sy ~= dy do
    local mh = math.abs(A * (sx + mx) + B * sy       + C)
    local mv = math.abs(A * sx        + B * (sy + my) + C)
    local mc = math.abs(A * (sx + mx) + B * (sy + my) + C)
    if sy ~= dy and (sx == dx or mh > mv or mh > mc) then sy = sy + my end
    if sx ~= dx and (sy == dy or mv > mh or mv > mc) then sx = sx + mx end
    if blocksProjectile({x=sx, y=sy, z=fromPos.z}) then return false end
  end
  return true
end
-- blocksProjectile(pos): returns false today (items1530.bin has no blockProjectile bit),
-- matching vBot's own fail-open path (AB:1206-1210).  Add the flag to the item asset and
-- this becomes exact.


## Evidence
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\AttackBot.lua:24-37 — SharedUseCooldown / recordLocalUseCooldown, USE_COOLDOWN_MS = 1000 (fixed, never from a server event)
- AttackBot.lua:52-60 — getPingCompensation(): ping > 150 → ping - 30, else 0
- AttackBot.lua:62-66 — getMultiUseCooldown() = max(0, expiresAt - now - pingComp)
- AttackBot.lua:68-102 — SpellCooldownCache populated from g_game.onSpellCooldown / onSpellGroupCooldown via modules.game_bot.connect
- AttackBot.lua:104-137 — getRealSpellRemaining: max of the spell's own remaining and every group's remaining
- AttackBot.lua:139-155 — getRealGroupRemaining(groupId)
- AttackBot.lua:166-167 — AttackBotFiringUntil / AttackBotRuneReadyUntil (read by HealBot.lua:728,757,765)
- AttackBot.lua:233-239 — the 5 categories
- AttackBot.lua:241-296 — the `patterns` label tables (4 pattern categories, absolute list has 19 ids)
- AttackBot.lua:299-839 — spellPatterns[2] (3 area-rune grids) and spellPatterns[4] (19 absolute grids), each {normal, safe}
- AttackBot.lua:842-912 — ek (voc()==1 or 11) and the posN/posE/posS/posW quadrant grids
- AttackBot.lua:914-1170 — monkDirPatterns for pattern ids 9, 13, 14, 16, 19 keyed by direction 0..3
- AttackBot.lua:1178-1195 — extractDirGrid: flatten one compass letter of a combined N/E/S/W grid to a plain 1/0 grid
- AttackBot.lua:1206-1213 — posSightClear / spellCanReach; fail-open when g_map.isSightClear is unbound
- AttackBot.lua:1222-1276 — getWaveBestDir: per-direction real-shape counting, PvP veto, tie-break toward current facing
- AttackBot.lua:1290-1301 — WAVE_AUGMENTS {['exevo gran frigo hur']=12} and augmentedWavePattern (affects counting only)
- AttackBot.lua:1303-1345 — getMonkBestDir
- AttackBot.lua:1350-1360 — getDirectionToPos
- AttackBot.lua:1388-1397 — OptimizedSpells table (formula → opt flag, mode, castRange, jumps, jumpDist)
- AttackBot.lua:1411-1473 — collectChainWorld / simulateHopChain / starChainScore
- AttackBot.lua:1475-1483 — nonPartyPlayerNear
- AttackBot.lua:1488-1512 — findBestChainSeed (ties: counted, then total, then current target)
- AttackBot.lua:1525-1551 — findBestTfbTile (own tile seeded first; isWalkable(true); ties toward nearest)
- AttackBot.lua:1556-1569 — castAtPos
- AttackBot.lua:1571-1578 — optimizerGuardsPass / optimizerCountGate
- AttackBot.lua:1584-1631 — tryOptimizedSpell (on-screen pre-gate, tile mode, chain mode + retarget-then-cast)
- AttackBot.lua:1635-1722 — the 5 blank profiles and their exact default field set; currentBotProfile clamp 1..5
- AttackBot.lua:1741-1757 — migration defaults applied to all 5 profiles (RuneDelay 50, RuneDelayEnabled true, 5 Opt* false)
- AttackBot.lua:1782-1790 — attackTable rebuilt from widget order on window hide, then vBotConfigSave('atk')
- AttackBot.lua:2226-2283 — addEntry: monsters parsing (empty/'*'/'monster names' → true, else split on ','), the full params table
- AttackBot.lua:2519-2523 — getPattern(category, pattern, safe) → spellPatterns[category][pattern][safe and 2 or 1]
- AttackBot.lua:2526-2576 — getMonstersInArea, both the non-area (1/3/4) and area (2/5) branches
- AttackBot.lua:2580-2596 — getBestTileByPattern (canShoot, isWalkable, distance < 4, strict > on ties)
- AttackBot.lua:2612-2630 — attackSpellCooldownReady (ServerCooldown → real ETA vs raw ping; else canCast ignoring cooldown)
- AttackBot.lua:2632-2643 — executeAttackBotAction (cast for 1/4/5, recordLocalUseCooldown + useWith for 3)
- AttackBot.lua:2655-2672 — autoTurnAndFire (turn and cast in the same tick; refuses to fire when Rotate is off)
- AttackBot.lua:2681-2705 — runeDelayGate
- AttackBot.lua:2708-2733 — main macro registration and the global gates (enabled, empty table, isInPz, no target, Training, 400 ms fallback delay)
- AttackBot.lua:2735-2759 — compass quadrant scan producing bestSide (bestDir computed but never used)
- AttackBot.lua:2783-2797 — per-entry pre-gates: enabled, mana%, harmony, executeCooldown selection
- AttackBot.lua:2799-2892 — canUse computation for spells and runes, shared-use-slot reservations
- AttackBot.lua:2896-2907 — pvpMode short-circuit (area runes refused)
- AttackBot.lua:2912-2914 — optimizer hand-off
- AttackBot.lua:2915-2930 — categories 4 and 1/3 legacy paths
- AttackBot.lua:2932-3070 — category 5 dispatch: monk directions (9/13/14/16/19), TFB (15), chains (17/18), waves (2/7/10/11/12), self-areas + pattern 8
- AttackBot.lua:3072-3090 — category 2 area-rune path (useWith on the tile's top use thing)
- AttackBot.lua:3093-3101 — the not-canUse branch that HOLDS the tick when a rune is ready but the shared use slot is busy
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot_configs\profile_1\AttackBot.json — real persisted config used for the example (8 live entries, OptPenance/OptOutburst/OptTFB true, PvpSafe false)
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\configs.lua:20-27,63-97 — AttackBot.json path and vBotConfigSave('atk')
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\bot.lua:268-273 — storage/profile_<N>.json (holds playerList.blackList); bot.lua:531-534 — 10 ms executor tick
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\executor.lua:196-210 — macro scheduling; executor.lua:124-126 — getDistanceBetween = Chebyshev max(|dx|,|dy|)
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\main.lua:37-39 — macro timeout clamped to a 50 ms minimum; main.lua:206-211 — delay()
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\map.lua:8-37 — getSpectators: table centre ⇒ direction 8 (invalid) so all N/E/S/W cells are disabled
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\player.lua:8-15 manapercent, :36 voc, :65 turn, :90-120 say/castSpellAt, :168-178 usewith, :203 attack
- D:\Claude\otclient_mehah1530\otclient\mods\game_bot\functions\player_conditions.lua:7,29-31 — hasCondition / isInPz (PlayerStates.Pz = 16384, gamelib/player.lua:20)
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\vlib.lua:248-306 — SpellCastTable, cast(), canCast()
- vlib.lua:333-386 — getSpellData (exact `words` match in modules.gamelib.SpellInfo['Default']) and getSpellCoolDown
- vlib.lua:643-646 distanceFromPlayer, :667-674 getPlayers, :676-696 isBlackListedPlayerInRange (multi-floor, |dz|<=2, strict <), :188-203 isBuffed, :223-228 killsToRs
- vlib.lua:863-886 — hasItemAvailable / itemAmount = max(server 0xF5 count, visible scan)
- vlib.lua:1002-1009 target() = g_game.getAttackingCreature() when isAttacking; vlib.lua:1055-1074 getCreaturesInArea (type 2 = monsters)
- D:\Claude\otclient_mehah1530\otclient\src\client\map.cpp:1475-1540 — getSpectatorsByPattern: character grammar, odd width/height requirement, row-major centred scan
- src\client\map.cpp:1181-1225 — isSightClear line walk, blocks on !tile->isLookPossible()
- src\client\tile.h:75,81,161 and tile.cpp:708-725,1133-1141,600-617 — isWalkable(ignoreCreatures=false), isLookPossible (BLOCK_PROJECTILE), canShoot(distance), getTopUseThing
- src\client\map.h:166-169 — getSpectators(pos,false) = the aware-range box on one floor
- src\client\protocolcodes.h:415-424 — CreatureType enum (3 = SummonOwn, 4 = SummonOther ⇒ getType() < 3 excludes summons)
- src\client\game.cpp:883-906 — useInventoryItemWith: sentinel source Position(0xFFFF,0,0), creature ⇒ sendUseOnCreature, item ⇒ sendUseItemWith; only 2 parameters, so vBot's third `cooldown` argument is dropped
- src\client\protocolgamesend.cpp:580-601 — sendUseItemWith / sendUseOnCreature wire layout
- src\client\protocolgamesend.cpp:677-737 — sendTalk with the Gunz spell-aim tail (mode byte 0..3; modes 1/2 append a valid position)
- src\client\game.cpp:1052-1062 and modules/gamelib/const.lua:343-348 — talkSpell aim modes (1 crosshair, 2 cursor, 3 target) and SpellAimInvalidPosition
- modules/game_interface/gameinterface.lua:479-524 — say() upgrades known spell words to talkSpell(words, SpellAimTarget, sentinel)
- src\client\protocolgameparse.cpp:5359-5366 and protocolcodes.h:193 — GameServerMonkData = 193 (0xC1), subtype HARMONY sets LocalPlayer::m_harmony
- D:\Claude\otclient_web\luaclient\proto\parser.lua:2093-2097 — luaclient already parses 0xC1 into state.player.harmony
- D:\Claude\otclient_web\luaclient\game\state.lua:454-458 — isMonster includes summons (type 1,3,4): AttackBot must test type == 1
- D:\Claude\otclient_web\luaclient\game\state.lua:510-559 — walkableAt and its documented inability to see blocking items (same gap affects isSightClear)
- modules/gamelib/player.lua:621-626 and gamelib/const.lua:13-24 — isPartyMember = shield in {1,3,4,5,6,7,8,9,10}
- modules/gamelib/spells.lua:234,241,246 — SpellInfo entry shape (id, words, level, mana, group={[1]=2000}, needTarget, exhaustion, vocations); 206 entries total
- modules/game_cooldown/cooldown.lua:521-537 — isGroupCooldownIconActive / isCooldownIconActive semantics
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\targetbot\creature_attack.lua:50-113 and targetbot/target.lua:285-333 — TargetBot's own, independent attack spell / rune firing (own timers only, no shared lock with AttackBot)
- D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\AttackBot.otui:303-410, 542-660 — SpinBox/CheckBox ranges: mana 0..99, count 1..99, minHp 0..99, maxHp 1..100, cooldown 0..999999, harmony 0..10, KillsAmount 1..10, RuneDelay 0..5000 step 10, AntiRsRange 1..10

## Pitfalls
- The macro is registered as macro(5, ...) but functions/main.lua:37-39 clamps any timeout under 50 to 50. The real tick is ~50 ms. Every comment in AttackBot.lua claiming a 5 ms tick is wrong; do not build timing assumptions on 5 ms.
- getDistanceBetween inside the bot sandbox is Chebyshev max(|dx|,|dy|) (executor.lua:124-126). The global in modules/game_battle/battle.lua:1881 is a different, weird metric ((|dx|-1)+(|dy|-1)) and is NOT what the bot uses. Using it would shift every range check by one.
- luaclient's state.lua marks type 3/4 (summons) as isMonster. vBot explicitly excludes them with getType() < 3. Test c.type == 1, never c.isMonster, or the bot will count and shoot at summons.
- entry.cooldown is SECONDS on the rune path (entry.cooldown * 1000 at AB:2847) and MILLISECONDS on the spell path (passed straight to cast(text, delay), AB:2794). With the default value 1 a spell entry gets delay=1, which cast() treats as "< 100 ⇒ just say it". Preserve both readings exactly or CustomCooldown will behave nothing like vBot.
- executeAttackBotAction passes `cooldown` as the third argument of useWith, which becomes the `subtype` parameter of context.usewith and is then silently dropped, because Game::useInventoryItemWith takes only (itemId, toThing) (game.cpp:883). Runes never honour the custom cooldown through that path; the gating happens earlier in canUse.
- Pattern 8 (Large Beam) is excluded from isWave = (pattern == 2 or pattern == 7 or pattern >= 9) at AB:3016, even though pattern 7 (Short Beam) is included. Large Beam therefore falls into the self-area branch, where its letter grid counts 0 (position centre ⇒ direction 8 ⇒ all letters off) and it is fired purely off the legacy quadrant `bestSide` count, without ever turning. This is a genuine vBot bug; reproduce it only if bug-for-bug fidelity matters, otherwise route 8 through getWaveBestDir like 7.
- `bestDir` from the compass scan (AB:2755-2759) is computed every tick and never used. Only `bestSide` is consumed, and only by pattern 8.
- getSpectators with a POSITION centre passes direction = 8 (functions/map.lua:19), so every N/E/S/W cell in the grid evaluates false. Any code path that feeds a letter grid to getMonstersInArea/getSpectators with a position centre counts ZERO. This is why waves must go through extractDirGrid, and it also silently weakens the PvP-safe check for letter-tagged safe grids (AB:3049, AB:2946).
- Grid dimensions must be odd in both axes or Map::getSpectatorsByPattern logs an error and returns nothing. spellPatterns[4][13] (Flurry of Blows) is 3 wide x 4 tall and spellPatterns[4][19] (Balanced Brawl) is 13x7 — both are only ever reached through monkDirPatterns (which are odd), so the malformed union grids are never actually scanned. Do not use those two union grids for counting.
- The BlackListSafe / Kills guards are applied ONLY on category 5 and category 2 paths (and inside the optimizers). Categories 1, 3, 4 and the pvpMode short-circuit ignore them entirely.
- The category 1/3/4 branch of getMonstersInArea does NOT restrict the count to anything near the target: it counts every matching monster on screen. The only spatial condition is distanceFromPlayer(target) <= entry.pattern. A single-target spell with count 5 fires when 5 matching monsters are anywhere on screen.
- The name filter is applied with table.find(t, name, true) (case-insensitive) in the 1/3/4 branch but with table.find(t, name) (case-sensitive) in the 2/5 branch (AB:2559 vs AB:2569). Both work today only because the stored names and the compared names are both lowercased at entry time.
- The tick iterates panel.entryList:getChildren(), not currentSettings.attackTable. The JSON array is only refreshed when the settings window closes (AB:1782-1790). A headless port must treat attackTable order as authoritative and keep it dense.
- The rune "hold the tick" rule (AB:3100) is easy to miss: when a rune's own cooldown is clear but the shared 1 s use-cooldown is not, the WHOLE tick returns so lower-priority entries cannot steal the slot. Dropping this reintroduces the "HealBot always wins, rune never fires" loop the comments describe.
- AttackBotFiringUntil / AttackBotRuneReadyUntil are globals shared with HealBot (HealBot.lua:728,757,765). Port them as an explicit shared table, or the potion/rune arbitration disappears.
- recordLocalUseCooldown() is called at two different moments: inside executeAttackBotAction for category 3 (AB:2640) and inline before the useWith for category 2 (AB:3087). Both must fire the instant the packet is sent, never on a server confirmation — g_game.onMultiUseCooldown does not fire on this build (AB:15-17).
- isSightClear needs the BLOCK_PROJECTILE thing-type flag, which assets/items1530.bin does not carry (API.md proto/items.lua flag list). Sight checks will fail open, exactly as vBot does when the binding is missing, so wave direction picking and chain simulation will be optimistic. Do not silently substitute a walkability check — a tile can be unwalkable and still projectile-transparent.
- TargetBot's own attack spells/runes (targetbot/creature_attack.lua:66-112) run on completely independent timers and share nothing with AttackBot. They can and do double-fire in the same window. Do not assume any arbitration exists.
- Profile objects in the on-disk JSON may be missing keys entirely (profile 2 in the real file has no ServerCooldown). Apply the AB:1741-1757 migration defaults on load before reading anything.
- `Training` has no default anywhere in the code, so it is absent from freshly created profiles; treat missing as false. `ignoreMana` and `Cooldown` appear in saved files but are dead — AttackBot.lua never reads them.
- getBestTileByPattern uses tile:isWalkable() (creatures block) while findBestTfbTile uses tile:isWalkable(true) (creatures ignored). This asymmetry is deliberate: an area rune cannot be dropped on an occupied tile, an aimed spell can.

## Open questions
- blockProjectile / blockPathfind flags are absent from assets/items1530.bin, so a faithful Map::isSightClear cannot be implemented today. Is extending tools/extract_appearances.py (and the items1530.bin format) with the `unpass`, `blockprojectile` and `unsight` appearance flags in scope? Without it, wave direction picking, chain simulation and canShoot all degrade to fail-open.
- The luaclient state does not currently expose a creature's `shield` value in the documented creature record (API.md lists skull, shield, emblem — please confirm the parser actually fills `shield`). isPartyMember (and therefore every PvP-safe check) depends on it.
- g_game.getPing() has no luaclient equivalent documented. The ping-compensation logic (fire up to `ping` ms early, shorten RuneDelay by ping-30 above 150 ms) needs a measured RTT — presumably from the 0x1E/0x1D ping round trip. Should the control plane expose it, or should ping compensation be disabled (returning 0) in the first port?
- `hasItemAvailable` relies on the server-pushed inventory-count list (opcode 0xF5) so that runes in a CLOSED backpack still count. Does proto/parser.lua parse 0xF5 into a per-item count cache? If not, `Visible` mode will only see equipped slots plus open containers, and rune entries will stall whenever the backpack is closed.
- `isBuffed()` (used only by category 4 / Empowerment) needs player skill level vs base level for skills 1..4 plus the PartyBuff state bit. Confirm state.player.skills carries both `level` and `baseLevel` for the melee skill indices vBot uses (it iterates i = 1..4).
- `killsToRs()` needs g_game.getUnjustifiedPoints() (killsDayRemaining / WeekRemaining / MonthRemaining). Which opcode carries that on 1530, and does the parser handle it? If not, the `Kills` guard must be treated as always-passing.
- Tile::getTopUseThing needs thing-type flags (isForceUse, isGround, isGroundBorder, isOnBottom, isOnTop, isSplash) that items1530.bin does not carry. For area runes the ground item at stack index 1 is usually correct, but a tile with a splash or a top item will pick the wrong target thing. Is an approximation acceptable, or should the asset be extended?
- The comment at AttackBot.lua:1394-1396 flags that Thousand Fist Blows' cast range is set to 5 but the TibiaWiki diagram suggests up to 7. Unverified against the live server.
- starChainScore caps both the counted and total hits at the jump cap but the server's preference order when more candidates than the cap are in range is undocumented (AB:1467-1470). The optimizer's score is therefore approximate in dense packs.
- modules/gamelib/SpellInfo['Default'] (206 entries) must be embedded as static data. Should it be converted to a generated Lua/JSON asset under assets/, and should the reimplementation also keep the AUTO_DETECT formula → {category, pattern} table (AttackBot.lua:1879-1910) as a convenience for hand-authored configs, or is it purely a UI affordance to drop?

## VERIFIER (confidence 0.88)

### Corrections (AUTHORITATIVE)
- **Claim**: §3.11: "AttackBot **never selects a target**. It is a pure passenger on g_game.getAttackingCreature()" and "The only cross-module arbitration that *does* exist is with HealBot".
  - **Correction**: False whenever a chain optimizer is enabled. tryOptimizedSpell re-targets the client via g_game.attack before casting. Since the on-disk profile 1 has OptPenance=true, OptOutburst=true, OptTFB=true, this path is live for the real user and a reimplementation that omits it will attack a different creature than vBot does. The spec must state: for hop/star optimizers, if the chosen chain seed is not the current target, AttackBot sends attack(seed) and then the cast in the same tick (attack packet first).
  - Evidence: AttackBot.lua:1625-1629: `if not best.isCurrent then -- re-target to the best chain seed ... attack(best.creature) end; executeAttackBotAction(1, attackData, executeCooldown)`. mods/game_bot/functions/player.lua:203: `context.attack = g_game.attack`. vBot_configs/profile_1/AttackBot.json profile 1: OptPenance/OptOutburst/OptTFB = true.
- **Claim**: §4: "Migration on load, applied to **all five** profiles (AB:1734-1757): `AntiRsRange` default 5, `RuneDelay` default 50, `RuneDelayEnabled` default true, `OptPenance/OptOutburst/OptTFB/OptThorns/OptGlacier` default false."
  - **Correction**: AntiRsRange is migrated ONLY on the currently active profile, outside and before the 5-profile loop. Only RuneDelay / RuneDelayEnabled / Opt* are applied to all five. A profile the user never switched to can therefore still have AntiRsRange = nil, and `isBlackListedPlayerInRange(nil)` then defaults its own range to 10 (vlib.lua:679), not 5.
  - Evidence: AttackBot.lua:1732 `setActiveProfile()`; 1734-1736 `if not currentSettings.AntiRsRange then currentSettings.AntiRsRange = 5 end`; the `for i = 1, 5 do` loop only starts at 1741 and touches RuneDelay, RuneDelayEnabled, OptPenance, OptOutburst, OptTFB, OptThorns, OptGlacier. vlib.lua:678-679 `if not range then range = 10 end`.
- **Claim**: §1.2: pattern 19 "balanced brawl 13x7 → **even-ish, unused as a union grid** (AB:818-837)".
  - **Correction**: 13 wide x 7 tall — both dimensions are ODD, so it is a fully valid grid for getSpectatorsByPattern (unlike pattern 13, which really is 3x4 and invalid). It is also NOT unused: pattern 19 is dispatched through getMonkBestDir, and `spellPatterns[4][19][2]` is passed as the PvP-safe veto pattern. Additionally, spellPatterns[4][19][2] is byte-identical to [1] — there is no +1 sqm margin on the Balanced Brawl safe grid, contradicting §1.2's blanket statement that safe = "real area + 1 sqm margin".
  - Evidence: AttackBot.lua:818-837 — both the [1] and [2] grids are the identical 13-column, 7-row block `0000001000000 / 0000011100000 / 0000111110000 / 0011111111100 / 0111111111110 / 0111100011110 / 1111100011111`. AttackBot.lua:2946 `local safe = currentSettings.PvpSafe and spellPatterns[pCat][pattern][2] or false` on the pattern∈{9,13,14,16,19} branch.
- **Claim**: §3.6(e): "fires if (pattern ~= 8 and countGate(n)) ... n = getMonstersInArea(5, pos(), ...)" — implying the count is computed conditionally on `pattern`.
  - **Correction**: The real guard is on `pCat` (entry.patternCategory), not `pattern`: `local monsterAmount = pCat ~= 8 and getMonstersInArea(...)`. Because patternCategory is always 4 for category 5, the count is ALWAYS computed (including for pattern 8, where it is then ignored). Behaviourally equivalent only as long as the reimplementation keeps patternCategory from the saved config. More importantly the spec should say every spellPatterns lookup on this path indexes `spellPatterns[entry.patternCategory][...]`, read from the JSON, not a hard-coded 4 — a config with a stale patternCategory will index a different (or empty) table.
  - Evidence: AttackBot.lua:3063 `local monsterAmount = pCat ~= 8 and getMonstersInArea(entry.category, pos(), spellPatterns[pCat][pattern][1], ...)`; AttackBot.lua:3057, 2946, 2961, 3073-3075 all use `pCat`. patternCategory derivation at AttackBot.lua:1866.
- **Claim**: §3.2 pseudocode: `if rem == nil then canUse = not spellIconActive(entry.spell) else canUse = (rem <= rawPing()) end` — and the not-ServerCooldown branch `canUse = true`.
  - **Correction**: All three returns of attackSpellCooldownReady go through `canCast(words, ignoreRL=false, ...)`, so the level/mana requirement is ALWAYS enforced when SpellCastTable has no entry for the words: `level() >= data.level and mana() >= data.mana`. The pseudocode drops it entirely, so a reimplementation will cast spells the player cannot afford. Also, canCast checks SpellCastTable FIRST (`now - t > d or ignoreCd`), which short-circuits the level/mana check for any spell previously cast through cast() with delay >= 100.
  - Evidence: AttackBot.lua:2613-2630 (`return canCast(spellText, false, true)` / `canCast(spellText, false, false)`); vlib.lua:279-306 `if (ignoreCd or not getSpellCoolDown(spell)) and (ignoreRL or level() >= getSpellData(spell).level and mana() >= getSpellData(spell).mana)`.
- **Claim**: §3.2: "getSpellData (VL:333-360) looks the formula up in modules/gamelib/SpellInfo['Default'] by exact words match ... A headless client must embed this table."
  - **Correction**: Incomplete: getSpellData has a second lookup path. If the words are not in SpellInfo it falls back to `vBot.customCooldowns[words]`, a runtime-learned table keyed by the last-said lowercased phrase and filled from onSpellCooldown / onGroupSpellCooldown, returning `{id = <icon id>, mana = 1, level = 1, group = ...}`. With a static-only table, an unknown formula makes getRealSpellRemaining return nil forever and canCast fall through to its `return true` tail, i.e. the spell is treated as permanently ready — vBot instead acquires a real id/group after the first successful cast. Also note the whole SpellCooldownCache hook can silently fail to install (SpellCooldownHookInstalled reset to false when modules.game_bot.connect is missing), in which case getRealSpellRemaining always returns nil and every spell falls back to the icon path.
  - Evidence: vlib.lua:344-357 (customCooldowns fallback, `c = {id = v.id, mana = 1, level = 1, group = v.group}`); vlib.lua:302-330 populate vBot.customCooldowns from onSpellCooldown/onGroupSpellCooldown using `lastPhrase`; AttackBot.lua:83-101 `local realConnect = modules and modules.game_bot and modules.game_bot.connect ... else SpellCooldownHookInstalled = false end`.
- **Claim**: §3.6(e) / §3.7: "`getPlayers(range)` (VL:667-674) counts non-local players within Chebyshev `range` excluding party members and green-emblem (guild) players."
  - **Correction**: Party members are excluded only when their shield is NOT 1. A ShieldWhiteYellow (=1) party member IS counted, so `getPlayers(2) == 0` can fail because of your own party. The exact predicate is `not spec:isLocalPlayer() and spec:isPlayer() and dist <= range and not ((spec:getShield() ~= 1 and spec:isPartyMember()) or spec:getEmblem() == 1)`.
  - Evidence: vlib.lua:672. Shield constants: modules/gamelib/const.lua:14 `ShieldWhiteYellow = 1`; Player:isPartyMember() (modules/gamelib/player.lua:621-626) does include ShieldWhiteYellow, so the `~= 1` term deliberately re-admits it.
- **Claim**: §3.6: "`isBuffed()` (VL:188-203) = has PlayerStates.PartyBuff (4096) **and** the best of skills 1..4 has (skillLevel - baseLevel)/100*305 > baseLevel".
  - **Correction**: The scan starts with `skillId = 0` (Fist) as the incumbent and only replaces it when a skill in 1..4 has a strictly greater BASE level. So the candidate set is effectively skills 0..4, and Fist wins whenever no other base level exceeds it (common for a monk/knight). Reimplementing "best of 1..4" will pick a different skill and flip isBuffed() in edge cases.
  - Evidence: vlib.lua:188-203: `local skillId = 0; for i = 1, 4 do if player:getSkillBaseLevel(i) > player:getSkillBaseLevel(skillId) then skillId = i end end`.
- **Claim**: §3.7: "`isBlackListedPlayerInRange(range)` (VL:676-696) ... whose name is in `storage.playerList.blackList`."
  - **Correction**: The name comparison is CASE-SENSITIVE — `table.find(storage.playerList.blackList, spec:getName())` is called without the `lowercase` third argument, unlike every name test in AttackBot itself. It also short-circuits to nil (falsy) when the list is empty, and range defaults to 10 when nil is passed.
  - Evidence: vlib.lua:692 `if table.find(storage.playerList.blackList, spec:getName()) then`; contrast modules/corelib/table.lua:74 `function table.find(t, value, lowercase)`; vlib.lua:677 `if #storage.playerList.blackList == 0 then return end`; vlib.lua:679 `if not range then range = 10 end`.
- **Claim**: §2.3: "returns **false** as soon as an **intermediate** tile exists and `!tile->isLookPossible()`".
  - **Correction**: The destination tile is also tested. The loop body advances `start` and then tests the tile at the NEW position; on the final iteration that position is the destination, so a projectile-blocking destination tile fails the check. Only the start tile is exempt. (Same-position is short-circuited true before the loop.)
  - Evidence: src/client/map.cpp:1196-1214: `while (start.x != destination.x || start.y != destination.y) { ...advance start...; const auto tile = getTile(Position(start.x, start.y, start.z)); if (tile && !tile->isLookPossible()) return false; }`.
- **Claim**: §2.1: the pattern parser description ends at "any other char → row separator, but only closes a row when the running lineLength is > 1 after decrementing."
  - **Correction**: Omits the post-loop flush: after the character loop there is a second `if (lineLength > 0)` block that validates width and increments height once more. A grid string that does not end in whitespace (e.g. one built by extractDirGrid without its trailing "\n", or any hand-built grid) loses its last row entirely if this flush is not implemented. Also `finalPattern` is sized to the raw string length while the cell cursor `p` only advances on cell characters, so the two indices are independent.
  - Evidence: src/client/map.cpp:1507-1516.
- **Claim**: §1 entry table: "`creatures` | string | **raw text**" and "`monsters` ... otherwise `string.split(creatures, ",")`".
  - **Correction**: Two omissions. (a) `creatures` is stored already lowercased — `panel.monsters:getText():lower()`. (b) string.split does NOT trim: `"dragon, hydra"` produces `{"dragon", " hydra"}`, and the leading-space entry can never match `spec:getName():lower()`. It does remove empty strings. A reimplementation that trims will match names vBot silently never matches.
  - Evidence: AttackBot.lua:2227-2229; modules/corelib/string.lua `function string:split(delim)` — pure `string.sub` between delimiters plus `table.removevalue(results, '')`, no trim.
- **Claim**: §3.10: "`say(text)` ... routes through `tryCastSpellMessage` ...: if the words are a known spell and protocol >= 1525, it sends `talkSpell(words, SpellAimTarget=3, sentinel)`; otherwise a plain `talk`. On this Gunz build **every** `talk` at clientVersion >= 1525 carries the aim byte." → "luaclient: `sender:talkSpell(words, 3, nil)`".
  - **Correction**: Prose is right but the luaclient mapping is unconditional and therefore diverges. When `Spells.getSpellByWords(words:lower())` returns nil (a formula the client's spell list does not know — a custom-server spell, a typo, a conjure), tryCastSpellMessage returns false and vBot sends a plain `g_game.talk(text)` with aimMode 0. Also the aim tail is gated on `isGunzOs` (g_game.getOs() in CLIENTOS_GUNZ_LINUX..CLIENTOS_GUNZ_MAC) AND clientVersion >= 1525, not on the version alone.
  - Evidence: modules/game_interface/gameinterface.lua:483-492 (`if not Spells.getSpellByWords(message:lower()) then return false end`), 522-524; mods/game_bot/functions/player.lua:90-97; src/client/protocolgamesend.cpp:713-734 (`const bool isGunzOs = osValue >= Otc::CLIENTOS_GUNZ_LINUX && osValue <= Otc::CLIENTOS_GUNZ_MAC; if (isGunzOs && g_game.getClientVersion() >= 1525) { ... }`).
- **Claim**: §3.1 pseudocode: `if entry.harmony > 0 and player:getHarmony() < entry.harmony then ...`
  - **Correction**: The real guard is `if entry.harmony and entry.harmony > 0 and ...`. Every pre-2024 saved entry lacks `harmony` (and `augmented`, and `tooltip`) — three of the eight entries in the on-disk profile 1 have no `augmented` key at all. Without the nil guard the reimplementation errors on legacy configs. Same applies to `entry.orMore` (nil → treated as false → exact-count semantics).
  - Evidence: AttackBot.lua:2789 `if entry.harmony and entry.harmony > 0 and player:getHarmony() < entry.harmony then`. vBot_configs/profile_1/AttackBot.json: entries for `exori med pug`, `exori mas amp pug`, `exori gran mas pug`, `exori mas pug`, `exori amp pug` have no `augmented` key.
- **Claim**: §0: "`D:\...\AttackBot.lua` (3106 lines; referred to below as **AB**)".
  - **Correction**: The file is 3105 lines. Every AB:NNNN citation I spot-checked is otherwise accurate to ±2 lines; the pattern-table citations (AB:362/377/408/431/462/487/522/553/592/612/635/665/701/716/733/754/771/796/818 and monkDirPatterns 920/942/996/1050/1108) are exact.
  - Evidence: `wc -l AttackBot.lua` → 3105.

### Additions
- §5 (truncated in the spec) — chain optimizers have an extra PvP gate the spec does not state: before findBestChainSeed, `if currentSettings.PvpSafe and nonPartyPlayerNear(pos(), def.castRange + def.jumpDist * 2 + 1) then return true, false end` — radius 8 for Penance/Outburst, 13 for Thorns/Glacier (AttackBot.lua:1616-1618).
- §5 — the TFB tile optimizer (findBestTfbTile, AttackBot.lua:1524-1550) differs from getBestTileByPattern in four ways that must be copied: it uses `tile:isWalkable(true)` (ignoreCreatures = TRUE, so occupied tiles ARE candidates); the range test is `dist > 0 and dist <= def.castRange` (1..5, not `< 4`); the player's OWN tile is seeded first with a separate `nonPartyPlayerNear(myPos, 3)` veto; and count ties break toward the CLOSEST tile (`counted > best.counted or (counted == best.counted and counted > 0 and dist < best.dist)`), not first-wins. Its PvP-safe check is `nonPartyPlayerNear(tPos, 3)`, not a safe grid.
- §5 — tryOptimizedSpell's tile branch can DE-escalate to the legacy path: `if castAtPos(...) then return true, true end; return false, false`. castAtPos returns false when its SpellCastTable delay gate blocks (CustomCooldown with entry.cooldown >= 100), so in that case the legacy face-the-target Thousand-Fist path runs in the same tick (AttackBot.lua:1605-1611, 1556-1569).
- §3.6(a) — getMonkBestDir returns bestCount = 0 (not -1) when the safe pattern vetoes, because every direction scores 0 and `count > bestCount` with bestCount starting at -1 fires on dir 0. getWaveBestDir instead returns -1 with a 1-BASED `{0,0,0,0}` table, so `waveCounts[player:getDirection()]` is nil for direction 0 on the veto path and relies on the `or 0`. Both fail countGate for any count >= 1, so this is only a typing detail, but a reimplementation should not assume the two helpers return the same sentinel.
- §0 — `local ek = (voc() == 1 or voc() == 11) and true` (AttackBot.lua:842) is evaluated ONCE at chunk load, so the knight-vs-other quadrant grids are frozen at whatever vocation the client reported when the bot script loaded. A per-tick recomputation will diverge on a reload before the vocation is known.
- §2.2 — getMonstersInArea calls `getTarget()` internally (vlib.lua:1012, an alias of `target()`); the target is not a parameter. It is read twice per call and can differ from the `tg` the tick captured if TargetBot switched target mid-tick. Also the category-1/3 whitelist test compares the target's UN-lowered name via `table.find(t, name, true)` (case-insensitive), whereas the area path uses `table.find(t, name)` with no flag on an already-lowered name — two different comparison functions in the same routine.
- §3.7 — `killsToRs()` calls `g_game.getUnjustifiedPoints()` three times and takes min of killsDayRemaining / killsWeekRemaining / killsMonthRemaining (vlib.lua:223-228). If the unjustified-points packet has never arrived, this throws or returns garbage; vBot has no guard, so a headless port should decide explicitly (returning a large number keeps killsOk() true, matching the common case).
- §3.3 — `isGroupCooldownIconActive(1)` is reached through `modules.game_cooldown.isGroupCooldownIconActive(1)` (AttackBot.lua:2840); `getSpellCoolDown` (vlib.lua:363-384, used by the canCast fallback) checks BOTH the spell's own icon (`isCooldownIconActive(data.id)`) and every group id in `data.group`. The spec only mentions the group form.
- SpinBox ranges in §1/CONFIG FORMAT all check out exactly against AttackBot.otui: manaPercent 0..99 (line 309-310), creatures 1..99 (327-328), minHp 0..99 (352-353), maxHp 1..100 (370-371), cooldown 0..999999 (389-390), harmony 0..10 (409-410), KillsAmount 1..10 (560-561), RuneDelay 0..5000 (603-604), AntiRsRange 1..10 (658-659).
- The following spec claims are CORRECT and were verified line by line: the 50 ms macro clamp and the fact that macro.callback returns true so lastExecution advances (functions/main.lua:38-40, 114-122; executor.lua:196-210); Chebyshev getDistanceBetween in the sandbox and the unused (|dx|-1)+(|dy|-1) form in battle.lua:1881; getSpectators' direction = 8 for a table centre (functions/map.lua:16-20); the monster predicate isMonster() (class, id/type-derived) AND getType() < 3 collapsing to type == 1, and luaclient state.lua:457 being wrong for it; CreatureType enum values (protocolcodes.h:415-424); isPartyMember shield set {1,3,4,5,6,7,8,9,10} (gamelib/player.lua:621-626, const.lua:14-24); PlayerStates.Pz = 16384 and PartyBuff = 4096 (gamelib/player.lua:20,14) with hasCondition = band(states, c) > 0; USE_COOLDOWN_MS = 1000 and getPingCompensation = ping > 150 and ping - 30 or 0 (AB:33, 52-60); the whole getMonstersInArea / getBestTileByPattern / getWaveBestDir / getMonkBestDir / getDirectionToPos / autoTurnAndFire / runeDelayGate / executeAttackBotAction control flow; the +150 / +400 / +250 / +10 AttackBotFiringUntil-AttackBotRuneReadyUntil constants and HealBot's three consumption sites (HealBot.lua:728, 757, 765); the 'HOLD the tick when runeReady but use-slot busy' rule (AB:3095-3101); tile:isWalkable() defaulting ignoreCreatures=false (tile.h:75, tile.cpp:708-725), tile/creature canShoot(d) semantics (tile.cpp:1133-1141, creature.cpp:1418-1420), getTopUseThing (tile.cpp:600-617) and isLookPossible = !(flags & BLOCK_PROJECTTILE) (tile.h:81); useInventoryItemWith taking only 2 C++ params so the Lua third arg is dropped, with the 0xFFFF sentinel source position and stackpos 0 (game.cpp:883-906, protocolgamesend.cpp:580-601); SpellAimCursor = 2 / SpellAimTarget = 3 (const.lua:344-345); spells.lua having 206 `words =` entries with 'Chained Penance' at line 234 exactly as quoted; the config path and vBotConfigSave('atk') (configs.lua:25, 63-97); the on-disk profile_1/AttackBot.json contents including profile 2 genuinely missing the ServerCooldown key; storage/profile_1.json playerList.blackList; and Training being toggled at AB:2352-2355 and read at AB:2729 with no default anywhere.
