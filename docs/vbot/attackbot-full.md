# AttackBot — the complete algorithm (vBot 4.8, customised build)

Companion to `docs/vbot/attackbot.md`. That file is the behaviour *summary*;
its **"VERIFIER Corrections"** section is authoritative and every correction in
it is folded into the text below. This file goes deeper on the two things the
summary only sketched: **the data tables** (§2) and **the geometry** (§4–§7).

Source of truth (READ-ONLY):
`D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\AttackBot.lua`
— **3105 lines**, cited below as `AB:NNNN`. Supporting: `vBot/vlib.lua` (`VL`),
`mods/game_bot/functions/*.lua` (`FN`), `src/client/*` (`CPP`),
`modules/gamelib/spells.lua`.

Data extracted from it lives in `bot/data/optimizers.lua` (this work item) and
`bot/data/attackdata.lua` (grids, owned elsewhere).

**What was executed vs. only read** — stated up front so nothing here is
over-claimed:

| part | status |
|---|---|
| Grid parsing, dimensions, cell counts, radii, identity checks (§2, §4) | **executed** with LuaJIT 2.1.1781602682 against the real file — output pasted in §2.3/§2.5 |
| `extractDirGrid` per-facing cell counts (§2.4) | **executed** (verbatim port of AB:1178-1195) |
| `bot/data/optimizers.lua` contents, `augmentedPattern`, `defFor`, routing table (§6, §7) | **executed** — output pasted in §6.1/§7.2 |
| The real `AttackBot.json` schema and values (§8) | **executed** (JSON decoded and dumped) |
| Everything that needs a live game world — the tick order, cooldown state machine, `getSpectators`, `isSightClear`, chain simulation against real creatures, what the server actually does | **read only**. No OTClient runtime was available, so control flow is transcribed from source, not observed. |

---

## 1. Per-tick pipeline

### 1.0 Scheduling

`macro(5, function() ... end)` at **AB:2708**. `context.macro` clamps any
timeout below 50 to 50 (`FN main.lua:37-39`), so the real period is **~50 ms**,
not 5 ms — every comment in AttackBot.lua that says "5 ms" is wrong.
`now = g_clock.millis()` is refreshed once per host tick (`executor.lua:196`).
`delay(ms)` suppresses **this macro only** until `now + ms`.

### 1.1 Global gates, in source order (AB:2709-2733)

```
1.  if not currentSettings.enabled                     -> return
2.  if #currentSettings.attackTable == 0               -> return
3.  if isInPz()                                        -> return      band(states, 16384)
4.  if not target()                                    -> return      g_game.isAttacking()
5.  if Training and target():getName():lower():find("training") -> return
6.  if clientVersion < 960
       or (not CustomCooldown and not ServerCooldown)  -> delay(400)  (does NOT return)
```

Gates 2, 3 and 4 are one `or` expression on **AB:2727**, so their relative
order is irrelevant. Gate 4 is the reason **AttackBot never picks a target on
its own**: with nothing attacked the entire tick returns. `target()` is
`g_game.getAttackingCreature()` when `g_game.isAttacking()` (`VL:1002-1009`).

> **Correction already folded in:** this "pure passenger" statement is false the
> moment a *chain optimizer* is on. `tryOptimizedSpell` re-issues
> `attack(seed)` before casting (AB:1624-1629), and the user's real profile 1
> has `OptPenance`, `OptOutburst`, `OptTFB` = true. See §6.2.

**No gate for "do not attack players" exists.** There is no such option in
AttackBot at all. The closest things are (a) `PvpSafe`, which vetoes *casting*
when a non-party **player** would be caught in the area, and (b) `pvpMode`,
which is the opposite — it makes the bot fire at whatever is targeted with no
count/pattern check whatsoever (§1.5). AttackBot only ever fires at
`g_game.getAttackingCreature()`, so "attacking a player" is entirely a
TargetBot / user decision.

### 1.2 The compass quadrant scan (AB:2735-2759)

Runs once per tick, before the entry loop:

```
monstersN = getCreaturesInArea(pos(), posN, 2)      -- 2 = "count monsters"
monstersE, monstersS, monstersW likewise
posTable  = {monstersE, monstersN, monstersS, monstersW}   -- note the order
bestSide  = 0;  for v in posTable: if v > bestSide then bestSide = v
bestDir   = first of N(0), E(1), S(2), W(3) whose count == bestSide
```

* `getCreaturesInArea` (`VL:1055-1074`) counts `spec ~= player and isMonster()
  and (clientVersion < 960 or getType() < 3)` inside `getSpectators(pos, grid)`.
* `bestSide` starts at **0**, not −1, so an empty screen yields
  `bestSide = 0, bestDir = 0`.
* **`bestDir` is computed every tick and never read again.** Only `bestSide` is
  consumed, and only by the pattern-8 branch (§5.5).
* The quadrant grids `posN/posE/posS/posW` are frozen at chunk load:
  `local ek = (voc() == 1 or voc() == 11) and true` (**AB:842**) is evaluated
  once. On a reload before the vocation is known, `ek` is `nil` for a knight
  and the 11×11 grids are used forever.

### 1.3 Entry ordering

The loop is `for i, child in ipairs(panel.entryList:getChildren())` (**AB:2783**)
and every firing path uses `return`, so **the first entry that fires ends the
tick**. Index 1 = highest priority. The widget list is mirrored back into
`currentSettings.attackTable` in the same order only when the settings window
closes (AB:1782-1790). A headless port iterates `attackTable` in array order and
must keep it dense (`refreshAttacks` uses `pairs()`, AB:2215).

### 1.4 Per-entry gates, in source order (AB:2784-2893)

```
entry      = child.params
attackData = entry.itemId > 100 and entry.itemId or entry.spell   -- number | string
isRune     = entry.itemId > 100

G1  if not entry.enabled                       -> next entry
G2  if manapercent() < entry.mana              -> next entry
G3  if entry.harmony and entry.harmony > 0
       and player:getHarmony() < entry.harmony -> if isRune then runeDelayTimers[id]=nil end
                                                  next entry
    executeCooldown = CustomCooldown and entry.cooldown
                   or ServerCooldown  and 30
                   or 0
G4  canUse = readiness (spell: §1.4a / rune: §1.4b)
    if not canUse -> §1.4c
G5  pvpMode short-circuit                      -> §1.5   (fires or returns)
G6  tryOptimizedSpell                          -> §6     (may fire / may own the entry)
G7  per-category dispatch                      -> §5     (count, name filter,
                                                          hp window, geometry,
                                                          PvpSafe, BlackList, Kills)
```

The literal guard `entry.harmony and entry.harmony > 0` (AB:2787) is nil-safe:
pre-2024 entries have no `harmony` key. Same for `entry.augmented` and
`entry.orMore` (nil `orMore` ⇒ exact-count semantics).

Note there is **no** per-entry monster-name gate, hp-window gate or PvP gate at
this level. All three live inside the counting functions of §4 and the dispatch
of §5, which is why a category-1 entry with a name filter still counts every
matching monster on screen (§4.2).

#### 1.4a Readiness — spells (`attackSpellCooldownReady`, AB:2612-2630)

```
if not currentSettings.ServerCooldown then return canCast(words, false, true)
remaining = getRealSpellRemaining(words)
if remaining == nil                then return canCast(words, false, false)
if remaining <= getRawPing()       then return canCast(words, false, true)
return false
```

All three exits go through `canCast(words, ignoreRL = false, ...)`, so the
**level and mana requirement is always enforced** (`VL:279-306`):

```
if SpellCastTable[spell] then return (now - t > d) or ignoreCd          -- short-circuits!
elseif getSpellData(spell) then
     return (ignoreCd or not getSpellCoolDown(spell))
        and (ignoreRL or (level() >= data.level and mana() >= data.mana))
else return true                                                        -- unknown formula
```

`getSpellData` (`VL:333-360`) has **two** lookup paths: exact `words` match in
`modules/gamelib/SpellInfo['Default']` (206 entries), and — on a miss — the
runtime-learned `vBot.customCooldowns[words]`, populated from
`onSpellCooldown`/`onGroupSpellCooldown` keyed by the last phrase said
(`VL:302-330`), returning `{id = <icon id>, mana = 1, level = 1, group = ...}`.
A headless port that embeds only the static table makes every unknown formula
"permanently ready" via the `return true` tail.

`getRealSpellRemaining` (AB:104-137) takes the **maximum** of the spell's own
remaining and every one of its groups' remaining, from `SpellCooldownCache`.
That cache can silently never install: `SpellCooldownHookInstalled` is reset to
`false` when `modules.game_bot.connect` is missing (AB:86-101), after which
every spell falls through to the icon path.

#### 1.4b Readiness — runes (AB:2809-2892)

```
useCooldownClear = getMultiUseCooldown() <= 0            -- shared 1 s use lock
if ServerCooldown:
    groupRemaining = getRealGroupRemaining(1)            -- group 1 = "Attack"
    if groupRemaining then
        readyAt = now + groupRemaining
        if now >= readyAt - 1000 then                    -- USE_COOLDOWN_MS
            AttackBotFiringUntil = max(AttackBotFiringUntil, readyAt + 150)
        runeReady = groupRemaining <= getRawPing()
                    and (not Visible or hasItemAvailable(itemId))
    else
        runeReady = not modules.game_cooldown.isGroupCooldownIconActive(1)
                    and (not Visible or hasItemAvailable(itemId))
elseif CustomCooldown:
    readyAt = (runeCooldowns[itemId] or 0) + entry.cooldown*1000 - getPingCompensation()
    if now >= readyAt - 1000 then
        AttackBotFiringUntil = max(AttackBotFiringUntil, readyAt + 150)
    runeReady = now >= readyAt and (not Visible or hasItemAvailable(itemId))
else:
    runeReady = (not Visible or hasItemAvailable(itemId))
canUse = runeReady and useCooldownClear
if runeReady then AttackBotRuneReadyUntil = now + 250
```

`getPingCompensation()` = `ping > 150 and (ping - 30) or 0` (AB:52-60).
`getMultiUseCooldown()` = `max(0, SharedUseCooldown.expiresAt - now -
getPingCompensation())` (AB:62-66). `SharedUseCooldown.expiresAt` is bumped
**only** by `recordLocalUseCooldown()`, called the instant a rune or potion is
sent — never from a server event, because `g_game.onMultiUseCooldown` does not
fire on this build (AB:15-20).

#### 1.4c When `canUse` is false (AB:3093-3101)

```
if isRune then
   runeDelayTimers[itemId] = nil
   if runeReady then return                -- HOLD the WHOLE tick
```

A rune whose own cooldown is clear but which is waiting on the shared 1 s
use-slot **stops the tick**, so lower-priority entries cannot steal the slot.
Spells simply fall through to the next entry.

### 1.5 pvpMode short-circuit (AB:2896-2907)

Evaluated *before* the optimizers and before any counting:

```
if currentSettings.pvpMode
   and entry.minHp <= target():getHealthPercent() <= entry.maxHp
   and target():canShoot()                          -- NO-ARG form: sight only, no range cap
then
   if entry.category == 2 then warn(...); return    -- area runes refused outright
   if isRune then
       if not runeDelayGate(itemId) then return
       if CustomCooldown then runeCooldowns[itemId] = now
       AttackBotFiringUntil = now + 150
   return executeAttackBotAction(entry.category, attackData, executeCooldown)
```

No count gate, no name filter, no pattern, no BlackList/Kills guard, no
`recordLocalUseCooldown` for category 3 beyond the one inside
`executeAttackBotAction`.

### 1.6 What happens after a successful cast

There is no post-cast bookkeeping beyond what each path does inline:

| path | side effects, in order |
|---|---|
| spell (cat 1/4/5, incl. optimizers) | `cast(words, executeCooldown)` → `say()`; nothing else. No timer, no `delay()`, no reservation. The next tick re-evaluates from scratch and `attackSpellCooldownReady` is what stops a double-cast. |
| targeted rune (cat 3) | `runeDelayGate` (may `return`), `runeCooldowns[id] = now` if CustomCooldown, `AttackBotFiringUntil = now + 150`, then inside `executeAttackBotAction`: `recordLocalUseCooldown()` then `useWith(id, target(), cooldown)`. |
| area rune (cat 2) | `runeDelayGate`, `runeCooldowns[id] = now` if CustomCooldown, `AttackBotFiringUntil = now + 400`, `recordLocalUseCooldown()`, `useWith(id, tile:getTopUseThing(), cooldown)`. |
| chain optimizer | optional `attack(seed)`, then `executeAttackBotAction(1, words, cooldown)` — i.e. `cast`. |
| tile optimizer | `castAtPos(words, tile, cooldown)` → `talkSpell(words, SpellAimCursor = 2, pos)`. |

In every case the enclosing statement is `return`, so **the tick ends**. Nothing
is remembered about "which entry fired last"; priority is re-established from
the top on the next tick.

`cast(text, delay)` (`VL:258-277`) lowercases, and with `delay < 100` (which is
always the case in ServerCooldown mode, where `executeCooldown == 30`)
degenerates to a plain `say(text)`. With `delay >= 100` it maintains
`SpellCastTable[text] = {t, d}` and refuses to say until `now - t > d`; `t` is
refreshed by the own-talk callback when the server echoes the words
(`VL:248-256`).

`say()` upgrades known spell words to `talkSpell(words, SpellAimTarget = 3,
sentinel)` **only** when `Spells.getSpellByWords(words:lower())` resolves and
the client is a Gunz OS build at clientVersion >= 1525
(`gameinterface.lua:483-524`, `CPP protocolgamesend.cpp:713-734`). An unknown
formula falls back to a plain `g_game.talk(text)` with aim mode 0.

### 1.7 Cross-module state

Two globals AttackBot writes and HealBot reads (AB:166-167; consumed at
`HealBot.lua:728, 757, 765` — HealBot refuses a potion while `now <
AttackBotFiringUntil` or `now < AttackBotRuneReadyUntil`), plus the shared
`SharedUseCooldown` table. TargetBot's own attack section
(`targetbot/creature_attack.lua:66-112`) shares **nothing** with AttackBot and
can double-fire in the same window.

---

## 2. The data tables, measured

Everything in this section was produced by parsing the real file with a
verbatim Lua port of `Map::getSpectatorsByPattern`
(`CPP map.cpp:1475-1540`) and running it under LuaJIT.

### 2.1 The grid grammar (exact, `CPP map.cpp:1479-1519`)

Per character, with a cell cursor `p` and a running `lineLength`:

```
lineLength += 1
'0' '-'                  -> cell disabled,  p++
'1' '+'                  -> cell enabled,   p++
'N''n''E''e''S''s''W''w' -> cell enabled IFF direction == that compass value, p++
anything else            -> lineLength -= 1
                            if lineLength > 1:
                               if width == 0 then width = lineLength
                               if width ~= lineLength -> ERROR, return {}
                               height += 1; lineLength = 0
POST-LOOP (map.cpp:1507-1516):
  if lineLength > 0:  same width check, height += 1
FINALLY:
  if width % 2 ~= 1 or height % 2 ~= 1 -> ERROR, return {}
```

Consequences that matter:

* A **run** of separator chars closes at most one row (the second one sees
  `lineLength == 1` → `-= 1` → `0`, and `0 > 1` is false). Leading indentation
  is therefore harmless, which is why the `[[ ]]` literals can be indented.
* The **post-loop flush** is mandatory. `extractDirGrid` (AB:1178-1195) returns
  `"\n" .. rows .. "\n"`, so it happens to end in a separator — but any
  hand-built grid that does not will lose its last row without the flush.
* `finalPattern` is sized to the **raw string length** while `p` only advances
  on cell characters; the two indices are independent.
* **Even width or height ⇒ the function logs an error and returns an empty
  list.** Three grids in this file are even (§2.3) and are consequently inert.
* The scan is row-major from `centerPos.y - height/2` to `+height/2`, `x`
  likewise, single floor, deduplicated by creature id.

`getSpectators(param1, param2)` (`FN map.lua:8-37`) resolves the centre and
direction:

| `param1` | centre | direction |
|---|---|---|
| a **table** (position) | that position | **8 (invalid)** ⇒ every N/E/S/W cell is disabled |
| a **creature** (userdata) | its position | its direction |
| absent | player position | **player direction** |

This single rule is responsible for most of the geometry surprises below.

### 2.2 Category → patternCategory → grid table

`patternCategory` is derived once, in the UI, at **AB:1866**:

```
patternCategory = (category == 4) and 3
               or (category == 5) and 4
               or category
```

so `1→1, 2→2, 3→3, 4→3, 5→4`. It is **stored in the JSON** and every runtime
lookup indexes `spellPatterns[entry.patternCategory]`, never a hard-coded 4
(AB:2946, 2963, 2971, 3017, 3028, 3063, 3074-3075). A config with a stale
`patternCategory` therefore indexes a different — possibly empty — table.

`spellPatterns[1]` and `spellPatterns[3]` are deliberately `{}` (AB:300, 359):
categories 1, 3 and 4 use `pattern` as a **plain range in sqm**, not a grid id.

`getPattern(category, pattern, safe)` = `spellPatterns[category][pattern][safe and 2 or 1]`
(AB:2519-2523) — defined but only used by widget code; the tick indexes the
table directly.

### 2.3 Measured geometry of every grid (executed)

```
$ luajit gridcheck.lua
total lines: 3106                 (3105 lines + trailing newline)
grid literals found in 299..1170: 72

grid                                   w     h    on   ltr flags
P2[cross] normal                       3     3     5     0
P2[cross] SAFE                         5     7    27     0
P2[bomb] normal                        3     3     9     0
P2[bomb] SAFE                          5     5    25     0
P2[ball] normal                        7     7    37     0
P2[ball] SAFE                          9     9    57     0
P4[1 adjacent] normal                  3     3     9     0
P4[1 adjacent] SAFE                    5     5    25     0
P4[2 3x3 wave] normal                 11    11     0    44
P4[2 3x3 wave] SAFE                   13    13     0   100
P4[3 small area] normal                7     7    37     0
P4[3 small area] SAFE                  9     9    57     0
P4[4 medium area] normal              11    11    71     0
P4[4 medium area] SAFE                13    13   105     0
P4[5 ulus area] normal                 9     9    48     0
P4[5 ulus area] SAFE                  11     9    66     0
P4[6 large area] normal               13    13    85     0
P4[6 large area] SAFE                 15    15   113     0
P4[7 short beam] normal               11    11     0    20
P4[7 short beam] SAFE                 13    13     0    58
P4[8 large beam] normal               15    15     0    28
P4[8 large beam] SAFE                 17    17     0    92
P4[9 sweep] normal                     3     3     8     0
P4[9 sweep] SAFE                       5     5    24     0
P4[10 small wave] normal               7     7     0    28
P4[10 small wave] SAFE                 9     9     0    64
P4[11 large wave] normal              11    11     0    68
P4[11 large wave] SAFE                13    13     0   132
P4[12 huge wave] normal               13    13     0    72
P4[12 huge wave] SAFE                 17    17     0    92
P4[13 flurry] normal                   3     4     9     0 EVEN-DIM->REJECTED-BY-C++
P4[13 flurry] SAFE                     5     5    21     0
P4[14 greater flurry] normal           5     5    14     0
P4[14 greater flurry] SAFE             7     6    28     0 EVEN-DIM->REJECTED-BY-C++
P4[15 thousand fist] normal            5     5    21     0
P4[15 thousand fist] SAFE              7     7    37     0
P4[16 sweeping takedown] normal        5     5    22     0
P4[16 sweeping takedown] SAFE          7     6    38     0 EVEN-DIM->REJECTED-BY-C++
P4[17 spiritual outburst] normal       7     7    37     0
P4[17 spiritual outburst] SAFE         9     9    69     0
P4[18 chained penance] normal          7     7    37     0
P4[18 chained penance] SAFE            9     9    69     0
P4[19 balanced brawl] normal          13     7    47     0
P4[19 balanced brawl] SAFE            13     7    47     0
quad posN (ek 3x3)                     3     3     3     0
quad posN (other)                     11    11    21     0
quad posE (ek 3x3)                     3     3     3     0
quad posE (other)                     11    11    21     0
quad posS (ek 3x3)                     3     3     3     0
quad posS (other)                     11    11    21     0
quad posW (ek 3x3)                     3     3     3     0
quad posW (other)                     11    11    21     0
monkDir[9][0 N]                        3     3     5     0
monkDir[9][1 E]                        3     3     5     0
monkDir[9][2 S]                        3     3     5     0
monkDir[9][3 W]                        3     3     5     0
monkDir[13][0 N]                      11    11     9     0
monkDir[13][1 E]                      11    11     9     0
monkDir[13][2 S]                      11    11     9     0
monkDir[13][3 W]                      11    11     9     0
monkDir[14][0 N]                      11    11    14     0
monkDir[14][1 E]                      11    11    14     0
monkDir[14][2 S]                      11    11    14     0
monkDir[14][3 W]                      11    11    14     0
monkDir[16][0 N]                      11    11    22     0
monkDir[16][1 E]                      11    11    22     0
monkDir[16][2 S]                      11    11    22     0
monkDir[16][3 W]                      11    11    22     0
monkDir[19][0 N]                      13    13    51     0
monkDir[19][1 E]                      13    13    51     0
monkDir[19][2 S]                      13    13    51     0
monkDir[19][3 W]                      13    13    51     0

CLAIM: spellPatterns[4][19][1] identical to [2]  -> true
CLAIM: monkDirPatterns[19] cell counts (rebuilt to 51 each):
   dir 0 -> 51 cells, 13x13
   dir 1 -> 51 cells, 13x13
   dir 2 -> 51 cells, 13x13
   dir 3 -> 51 cells, 13x13
```

`on` = plain `1` cells, `ltr` = direction-tagged cells.

### 2.4 Radii, identities and per-facing coverage (executed)

```
$ luajit gridcheck2.lua
=== spellPatterns[4]: per-grid radius / cells ===
pattern            normal(r,cells,wxh) safe(r,cells,wxh)
1 adjacent         r=1  c=9    3x3    r=2  c=25   5x5
2 3x3wave          r=-1 c=0   11x11   r=-1 c=0   13x13
3 smallArea        r=3  c=37   7x7    r=4  c=57   9x9
4 medArea          r=5  c=71  11x11   r=6  c=105 13x13
5 ulusArea         r=4  c=48   9x9    r=5  c=66  11x9
6 largeArea        r=6  c=85  13x13   r=7  c=113 15x15
7 shortBeam        r=-1 c=0   11x11   r=-1 c=0   13x13
8 largeBeam        r=-1 c=0   15x15   r=-1 c=0   17x17
9 sweep            r=1  c=8    3x3    r=2  c=24   5x5
10 smallWave       r=-1 c=0    7x7    r=-1 c=0    9x9
11 largeWave       r=-1 c=0   11x11   r=-1 c=0   13x13
12 hugeWave        r=-1 c=0   13x13   r=-1 c=0   17x17
13 flurry          r=2  c=9    3x4    r=2  c=21   5x5
14 grFlurry        r=2  c=14   5x5    r=3  c=28   7x6   SAFE-GRID-INVALID(even)
15 tfb             r=2  c=21   5x5    r=3  c=37   7x7
16 sweepTakedown   r=2  c=22   5x5    r=3  c=38   7x6   SAFE-GRID-INVALID(even)
17 spirOutburst    r=3  c=37   7x7    r=4  c=69   9x9
18 chainPenance    r=3  c=37   7x7    r=4  c=69   9x9
19 balancedBrawl   r=6  c=47  13x7    r=6  c=47  13x7

=== identity checks ===
P4[12].safe == P4[8].safe            : true
P4[19].normal == P4[19].safe         : true
P4[17].normal == P4[18].normal       : true
P4[17].safe   == P4[18].safe         : true
P4[3].normal  == P2[ball].normal     : true
P4[15].safe   == P4[3].normal        : false

=== letter grids: cells per direction after extractDirGrid (what getWaveBestDir counts) ===
  2 3x3wave        11x11  N=11 E=11 S=11 W=11
  7 shortBeam      11x11  N=5 E=5 S=5 W=5
  8 largeBeam      15x15  N=7 E=7 S=7 W=7
  10 smallWave      7x7   N=7 E=7 S=7 W=7
  11 largeWave     11x11  N=17 E=17 S=17 W=17
  12 hugeWave      13x13  N=18 E=18 S=18 W=18

=== monkDirPatterns radius/cells ===
  [ 9]  3x3   d0:r=1,c=5  d1:r=1,c=5  d2:r=1,c=5  d3:r=1,c=5
  [13] 11x11  d0:r=3,c=9  d1:r=3,c=9  d2:r=3,c=9  d3:r=3,c=9
  [14] 11x11  d0:r=4,c=14  d1:r=4,c=14  d2:r=4,c=14  d3:r=4,c=14
  [16] 11x11  d0:r=4,c=22  d1:r=4,c=22  d2:r=4,c=22  d3:r=4,c=22
  [19] 13x13  d0:r=6,c=51  d1:r=6,c=51  d2:r=6,c=51  d3:r=6,c=51
```

`r = -1, c = 0` for a letter grid means it has **zero plain `1` cells** — every
cell is direction-tagged.

### 2.5 Data findings a port must copy bug-for-bug

1. **Every wave/beam safe grid is 100 % letters** (patterns 2, 7, 8, 10, 11, 12:
   `c=0`). The safe grid is always passed to `getSpectators(pos(), safe)` with a
   **position** centre ⇒ direction 8 ⇒ every letter cell is disabled ⇒ the
   spectator list is always empty ⇒ **`PvpSafe` is a guaranteed no-op for every
   wave and beam**, in `getWaveBestDir` (AB:1231-1237) and in the second
   `blockedByPlayer` check (AB:3048-3055).
2. **`spellPatterns[4][14][2]` and `[16][2]` are 7×6 — even height.**
   `getSpectatorsByPattern` rejects them and returns `{}`. So Greater Flurry and
   Sweeping Takedown *also* have a dead `PvpSafe` veto, even though they route
   through `getMonkBestDir` where the veto is otherwise live.
   Of the five monk-direction patterns, only **9, 13 and 19** have a working
   PvP veto.
3. **`spellPatterns[4][19][2]` is byte-identical to `[19][1]`** — no `+1 sqm`
   margin at all. The blanket claim "safe = real area + 1 sqm" is false here.
4. **`spellPatterns[4][19]` (13×7, 47 cells) disagrees with
   `monkDirPatterns[19]` (13×13, 51 cells).** The union grid is the *old*
   wiki-derived shape; the per-direction grids were rebuilt programmatically
   (AB:1104-1107). Pattern 19 counts with the 51-cell grids and vetoes with the
   47-cell one.
5. **`spellPatterns[4][12][2]` is a copy of `[8][2]`** (17×17, 92 letters) —
   Huge Wave's safe grid is the Large Beam's. Harmless only because of finding 1.
6. **`spellPatterns[4][13][1]` is 3×4 — even height, rejected.** Flurry of Blows
   is only ever counted through `monkDirPatterns[13]` (9 cells, matching), so the
   invalid union grid is never scanned. Its **safe** grid (5×5) is valid.
7. **`spellPatterns[4][5][2]` (ulus safe) is 11×9** — the `+1` margin exists on
   the x axis only. Both dimensions odd, so it works, just asymmetrically.
8. **`spellPatterns[4][9]`** (Front Sweep union, 3×3 ring with a hole in the
   centre) exists purely so a generic lookup never indexes an empty table:
   AB:592-597 records that the old empty `{}` here crashed `getWaveBestDir` with
   *"attempt to index local 'letterPattern' (a nil value)"* for knights. Pattern
   9 is now routed through `getMonkBestDir`, so the union grid is used only as
   the source of `[9][2]`, the (valid, 5×5) PvP-safe grid.
9. `spellPatterns[4][17]` and `[18]` are identical to each other (both the
   7×7/9×9 pair), and `[4][3][1]` is identical to `spellPatterns[2][3][1]` (the
   ball rune). Cache grid parses by string and these collapse to one entry.

---

## 3. Entry → geometry dispatch

Reached only when `canUse` is true, `pvpMode` did not fire, and
`tryOptimizedSpell` returned `handled == false` (AB:2912-2914).

```
category 4  and not isBuffed()   -> whole-screen count + range check  (§5.1)
category 1 or 3                  -> whole-screen count + range check  (§5.2)
category 5                       -> pattern = augmentedWavePattern(entry)   (§7)
     pattern in {9,13,14,16,19}  -> getMonkBestDir            (§4.4, §5.3a)
     pattern == 15               -> area centred on the TARGET (§5.3b)
     pattern in {17,18}          -> chain estimate            (§5.3c)
     else, isWave = (p==2 or p==7 or p>=9)
          isWave true            -> getWaveBestDir            (§4.3, §5.4)
          isWave false           -> getMonstersInArea around the player (§5.5)
category 2                       -> getBestTileByPattern       (§4.5, §5.6)
```

Two corrections against the naive reading:

* **The `isWave` gate must NOT catch pattern 6.** `isWave` literally reads
  `pattern == 2 or pattern == 7 or pattern >= 9` (AB:3016), but by the time the
  `else` branch is reached, 9/13/14/15/16/17/18/19 have already been consumed by
  the earlier branches. The reachable set is `{1,2,3,4,5,6,7,8}`, so
  `isWave` is true only for **2 and 7**, and pattern 6 "Large Area" — a
  self-centred 0/1 diamond with **no letters** — correctly falls into the
  self-area branch. AB:3010-3015 documents exactly this: routing 6 through the
  wave scanner extracted empty direction grids, counted 0 and the spell never
  cast. Patterns **10, 11, 12** *do* still reach `isWave` and are true.
  A reimplementation that reorders the branches must keep this invariant.
* **Front Sweep (pattern 9) goes through the monk grids, not the wave code.**
  AB:2939-2945; the union table entry at AB:592 exists only to keep generic
  lookups from indexing `nil`.

---

## 4. The counting functions, in full

### 4.1 Common conventions

* Distance is **Chebyshev**: `getDistanceBetween(a,b) = max(|dx|,|dy|)`
  (`executor.lua:124-126`). Never the odd `(|dx|-1)+(|dy|-1)` form in
  `game_battle/battle.lua:1881`.
* Monster predicate: `spec:isMonster() and (clientVersion < 960 or
  spec:getType() < 3)`. `CreatureType` is `0 Player, 1 Monster, 2 Npc,
  3 SummonOwn, 4 SummonOther, 5 Hidden`, so `< 3` **excludes summons**. In
  luaclient this is `c.type == 1`, *not* `c.isMonster` (which includes 3 and 4).
* HP window is `getHealthPercent()`, a u8 0..100, **inclusive at both ends**.
* Party predicate: shield ∈ {1,3,4,5,6,7,8,9,10}. Shield 0, 2 and 11 are not
  party members.

### 4.2 `getMonstersInArea(category, posOrCreature, pattern, minHp, maxHp, safePattern, names, sightFromPos)` — AB:2526-2576

```
t = (names == true or not names) and {} or names

-- (A) PvP-safe pre-check, BEFORE anything else
if safePattern then
  for spec in getSpectators(posOrCreature, safePattern):
     if spec ~= player and spec:isPlayer() and not spec:isPartyMember() then return 0

-- (B) NON-AREA path: categories 1, 3, 4
if category == 1 or 3 or 4 then
   if category == 1 or 3 then
      name = getTarget() and getTarget():getName()          -- NOT lowercased
      if #t ~= 0 and not table.find(t, name, true) then return 0     -- CASE-INSENSITIVE
   monsters = 0
   for spec in getSpectators():                             -- WHOLE SCREEN, no distance limit
      monsters = spec:isMonster()
             and hp >= minHp and hp <= maxHp
             and (#t == 0 or table.find(t, spec:getName():lower(), true))
             and (clientVersion < 960 or spec:getType() < 3)
             and monsters + 1 or monsters
   return monsters

-- (C) AREA path: categories 2 and 5
monsters = 0
for spec in getSpectators(posOrCreature, pattern):
   if spec ~= player then
      monsters = spec:isMonster()
             and hp >= minHp and hp <= maxHp
             and (#t == 0 or table.find(t, spec:getName():lower()))   -- CASE-SENSITIVE
             and (clientVersion < 960 or spec:getType() < 3)
             and (not sightFromPos or spellCanReach(sightFromPos, spec))
             and monsters + 1 or monsters
return monsters
```

Details that bite:

* The target is read via `getTarget()` **inside** the function (`VL:1012`, alias
  of `target()`), twice, not passed in. It can differ from the target the tick
  captured if TargetBot switched mid-tick.
* Two **different name comparisons in the same function**: `table.find(t, name,
  true)` (case-insensitive) in the 1/3/4 branch, `table.find(t, name)`
  (case-sensitive) in the 2/5 branch (AB:2559 vs AB:2569). Both happen to work
  because names are lowercased at entry time — but `string.split` does **not
  trim**, so `"dragon, hydra"` stores `{"dragon", " hydra"}` and the
  leading-space entry can never match. A port that trims will match names vBot
  silently never matches.
* Branch (B) has **no `spec ~= player` test** — harmless, the player is not a
  monster.
* Branch (B) is **not distance-limited at all**. A category-1 entry with
  `count = 5` fires when 5 matching monsters are anywhere on screen; the only
  spatial condition is the caller's `distanceFromPlayer(target) <= entry.pattern`.
* The `and ... or monsters` chain means any false link leaves the counter
  unchanged — including a `hp` of 0 for a just-dead creature.
* `sightFromPos` is **the position the area spreads FROM**, and it is passed as
  `pos()` for self-centred areas, as the candidate tile for area runes and TFB
  tiles, and as the target position for the pattern-15 legacy path. It is
  `nil`/absent everywhere else.

### 4.3 `getWaveBestDir(letterPattern, minHp, maxHp, safePattern, names)` — AB:1222-1276

```
if type(letterPattern) ~= "string" then
    return -1, 0, { [0]=0, [1]=0, [2]=0, [3]=0 }        -- 0-based, never crash
t = (names == true or not names) and {} or names

if safePattern then
    for spec in getSpectators(pos(), safePattern):
        if spec ~= player and spec:isPlayer() and not spec:isPartyMember() then
            return -1, 0, {0, 0, 0, 0}                  -- NOTE: 1-BASED table here
grids = waveDirGridCache[letterPattern]                 -- weak-KEYED memo, AB:1198
     or { [d] = extractDirGrid(letterPattern, "NESW"[d]) for d = 0..3 }

bestCount, bestDir = -1, 0
myPos  = pos()
curDir = player:getDirection()
for dir = 0, 3:
    count = 0
    for spec in getSpectators(myPos, grids[dir]):        -- plain 1/0 grid, dir irrelevant
        if spec ~= player and spec:isMonster() then
            if hp >= minHp and hp <= maxHp
               and (#t == 0 or table.find(t, name:lower(), true))   -- CASE-INSENSITIVE
               and spellCanReach(myPos, spec)                       -- SIGHT FROM THE PLAYER
            then count = count + 1
    counts[dir] = count
    if count > bestCount or (count == bestCount and dir == curDir) then
        bestCount, bestDir = count, dir                  -- tie -> prefer current facing
return bestCount, bestDir, counts
```

* **No summon filter here.** Unlike `getMonstersInArea`, `getWaveBestDir` tests
  only `spec:isMonster()`, so `getType() >= 3` summons **are counted**
  (AB:1257). Same in `getMonkBestDir` (AB:1326). This is an inconsistency in
  vBot, and a port must reproduce it or wave direction scores will differ.
* Sight is measured **from the player's own position**, one `isSightClear` call
  per candidate per direction — up to 4× the work of a plain area count.
  Rationale at AB:1200-1204: turning toward a wall makes the server refuse the
  cast, so wall-blocked directions must score 0.
* The tie-break `count == bestCount and dir == curDir` is evaluated *inside*
  the ascending `dir` loop, so it only fires when the current facing ties the
  best seen **so far**. With counts `{N=3, E=3, S=0, W=0}` and `curDir = E`, E
  wins. With `{N=3, E=0, S=0, W=3}` and `curDir = W`, W wins. With
  `{N=0,E=3,S=3,W=0}` and `curDir = N`, E wins (N never ties a higher value).
* The two sentinel returns are **shaped differently**: the type guard returns a
  0-based table, the PvP veto returns a 1-based one. On the veto path
  `waveCounts[player:getDirection()]` is `nil` for direction 0 and relies on the
  caller's `or 0` (AB:3032). Both fail any `count >= 1` gate, so it is a typing
  detail only — but do not assume the two helpers agree.
* Because of §2.5 finding 1, the `safePattern` veto in this function can never
  actually trigger for any pattern in the shipped data.

`extractDirGrid(letterPattern, letter)` (AB:1178-1195): split on `\n`, trim each
line, drop empty lines, rewrite every character to `"1"` if it equals `letter`
else `"0"`, join with `\n`, wrap in leading and trailing `\n`. Dimensions are
preserved; the result is a plain grid with no letters.

### 4.4 `getMonkBestDir(patternId, minHp, maxHp, safePattern, names)` — AB:1303-1345

Same loop, three differences:

1. Grids come straight from `monkDirPatterns[patternId][dir]` — no extraction,
   no cache, and **no `type()` guard**: an unknown `patternId` throws.
2. The safe-pattern veto is evaluated **inside** the per-direction loop
   (AB:1315-1322) and sets a local `blocked` flag instead of returning. The
   effect is the same for all four directions, because the safe pattern is
   passed to `getSpectators(myPos, safe)` with a *position* centre, which does
   not depend on `dir`.
3. On the veto path every direction scores 0, and `count > bestCount` with
   `bestCount` starting at −1 fires on `dir = 0`, so it returns
   **`bestCount = 0, bestDir = 0`** — not −1. Contrast §4.3.

Returns `bestCount, bestDir` (two values, no counts table).

### 4.5 `getBestTileByPattern(pattern, minHp, maxHp, safePattern, names)` — AB:2580-2596

```
targetTile = { amount = 0, pos = false }
for tile in g_map.getTiles(posz()):                  -- every KNOWN tile on this floor
    tPos = tile:getPosition()
    if tile:canShoot()                               -- isSightClear(playerPos, tPos)
       and tile:isWalkable()                         -- ignoreCreatures = FALSE
       and distanceFromPlayer(tPos) < 4              -- STRICT <, so Chebyshev 0..3
    then
        amount = getMonstersInArea(2, tPos, pattern, minHp, maxHp, safePattern, names, tPos)
        if amount > targetTile.amount then           -- STRICT >, first tile wins ties
            targetTile = { amount = amount, pos = tPos }
return targetTile.amount > 0 and targetTile or false
```

* `tile:isWalkable()` with no argument means `ignoreCreatures = false`
  (`CPP tile.h:75`, `tile.cpp:708-725`): a tile occupied by a non-passable
  visible creature is not a candidate. Deliberate — an area rune cannot be
  thrown onto an occupied tile.
* The `safePattern` is centred on the **candidate tile**, not the player, and
  goes through step (A) of `getMonstersInArea`, so a candidate covering a
  non-party player scores 0 rather than being skipped.
* `sightFromPos = tPos`: monsters behind a wall *relative to the impact tile*
  do not count.
* Ties keep the first tile in `g_map.getTiles` order, which is arbitrary. This
  is the opposite policy from `findBestTfbTile` (§6.3).

### 4.6 Sight — `posSightClear` / `spellCanReach` (AB:1206-1213)

```
sightClearBound = g_map and type(g_map.isSightClear) == "function"    -- evaluated ONCE
posSightClear(a, b)   = sightClearBound and g_map.isSightClear(a, b) or true
spellCanReach(from, spec) = posSightClear(from, spec:getPosition())
```

Fails **open** when the binding is missing. `Map::isSightClear`
(`CPP map.cpp:1181-1225`) walks the line `A·x + B·y + C = 0` with
`A = dest.y - start.y`, `B = start.x - dest.x`, `C = -(A·dest.x + B·dest.y)`,
advancing y and/or x toward the destination by whichever of
`move_hor`/`move_ver`/`move_cross` keeps `|A·x + B·y + C|` smallest, and
returning **false** as soon as a tile at the *new* position exists and
`!tile->isLookPossible()` (`BLOCK_PROJECTILE`). The **destination tile is
tested**; only the start tile is exempt; same-position short-circuits to true;
missing tiles are treated as clear.

`tile:canShoot()` (no arg) = `isSightClear(playerPos, tilePos)`.
`tile:canShoot(d)` / `creature:canShoot(d)` additionally require
`max(|dx|,|dy|) <= d` from the player (`CPP tile.cpp:1133-1141`,
`creature.cpp:1418-1420`).

Where sight is measured FROM, per call site:

| call site | `sightFromPos` | AB line |
|---|---|---|
| `getWaveBestDir` per-candidate | **player position** | 1261 |
| `getMonkBestDir` per-candidate | **player position** | 1330 |
| `getBestTileByPattern` → `getMonstersInArea` | **the candidate tile** | 2588 |
| `findBestTfbTile` → `getMonstersInArea` | **the candidate tile** (and the player's own tile for the seed) | 1531, 1543 |
| category-5 self-area | **player position** | 3063 |
| category-5 pattern 15 legacy | **the target's position** | 2971 |
| `simulateHopChain` | **the previous chain link** | 1441 |
| `starChainScore` | **the seed** | 1462 |
| categories 1/3/4 | none — sight is never checked | 2916, 2922 |

---

## 5. Category dispatch, path by path

Shared helpers:

```
countGate(n)  = (entry.orMore and n >= entry.count)
             or (not entry.orMore and n == entry.count)
guardsPass()  = (not BlackListSafe or not isBlackListedPlayerInRange(AntiRsRange))
            and (not Kills or killsToRs() > KillsAmount)
nonPartyPlayerNear(centre, r) = any on-screen creature that isPlayer, is not the
                local player, is not a party member, with chebyshev(centre, p) <= r
                (AB:1475-1483; uses getSpectators() = whole screen, one floor)
```

`isBlackListedPlayerInRange(range)` (`VL:676-696`) is **multi-floor**
(`|dz| <= 2`, z flattened), uses **strict `<`**, compares names
**case-sensitively**, returns `nil` (falsy) when the list is empty, and defaults
`range` to **10** when passed nil — which happens on any profile the user never
activated, because the `AntiRsRange = 5` migration runs **only on the active
profile** (AB:1734-1736), outside the 5-profile loop (AB:1741-1757).

`killsToRs()` (`VL:223-228`) = `min(killsDayRemaining, killsWeekRemaining,
killsMonthRemaining)` from `g_game.getUnjustifiedPoints()`, called three times,
unguarded.

### 5.1 Category 4 — Empowerment (AB:2915-2919)

```
if entry.category == 4 and not isBuffed() then
    n = getMonstersInArea(4, nil, nil, minHp, maxHp, false, entry.monsters)
    if countGate(n) and distanceFromPlayer(target():getPosition()) <= entry.pattern then
        return executeAttackBotAction(4, attackData, executeCooldown)
```

`isBuffed()` (`VL:188-203`) = `hasCondition(PartyBuff = 4096)` **and**
`(skillLevel - baseLevel)/100*305 > baseLevel` for the skill chosen by
`skillId = 0; for i = 1,4 do if getSkillBaseLevel(i) > getSkillBaseLevel(skillId)
then skillId = i end end` — i.e. the candidate set is skills **0..4**, and Fist
(0) wins whenever nothing beats it. **No BlackList/Kills guard on this path.**
Note the whole branch is skipped (falls to the next entry) when `isBuffed()` is
true — it is a condition on the `elseif` chain, not an inner test.

### 5.2 Categories 1 and 3 — targeted spell / targeted rune (AB:2921-2930)

```
n = getMonstersInArea(entry.category, nil, nil, minHp, maxHp, false, entry.monsters)
if countGate(n) and distanceFromPlayer(target():getPosition()) <= entry.pattern then
    if entry.itemId > 100 then
        if not runeDelayGate(entry.itemId) then return end
        if CustomCooldown then runeCooldowns[entry.itemId] = now end
        AttackBotFiringUntil = now + 150
    return executeAttackBotAction(entry.category, attackData, executeCooldown)
```

Remember branch (B) of §4.2: the whitelist is applied **to the current target's
name first** (reject outright on a miss), then the count is taken over the whole
screen. `entry.pattern` here is a **range in sqm**, 1..10.
**No BlackList/Kills guard.** No sight check at all.

### 5.3 Category 5 sub-paths

`pCat = entry.patternCategory` (from JSON), `pattern = augmentedWavePattern(entry)`.

#### (a) Monk direction spells — `pattern ∈ {9, 13, 14, 16, 19}` (AB:2939-2954)

```
safe = PvpSafe and spellPatterns[pCat][pattern][2] or false
n, dir = getMonkBestDir(pattern, minHp, maxHp, safe, entry.monsters)
if countGate(n) and guardsPass() then
    if autoTurnAndFire(dir, cast) then return
```

Per §2.5, `safe` is inert for 14 and 16 (even dims) and margin-free for 19.

#### (b) Thousand Fist Blows legacy — `pattern == 15` (AB:2955-2977)

```
targetPos = target() and target():getPosition()
if not targetPos then return end                 -- returns the WHOLE TICK
safe = PvpSafe and spellPatterns[pCat][15][2] or false
if safe then
    for spec in getSpectators(targetPos, safe):
        if spec ~= player and spec:isPlayer() and not spec:isPartyMember() then return end
n = getMonstersInArea(5, targetPos, spellPatterns[pCat][15][1], minHp, maxHp,
                      false, entry.monsters, targetPos)
if countGate(n) and distanceFromPlayer(targetPos) <= 5 then
    if autoTurnAndFire(getDirectionToPos(pos(), targetPos), cast) then return
```

The safe grid here is **plain 0/1 (7×7)**, so this PvP veto genuinely works —
unlike the wave ones. **No BlackList/Kills guard on this sub-path.** The
hard-coded `<= 5` matches `OptimizedSpells['exori mas amp pug'].castRange`.

#### (c) Chain fallback — `pattern ∈ {17, 18}`, optimizer OFF (AB:2978-3006)

```
if target() and distanceFromPlayer(target():getPosition()) <= 3 then
  if not (PvpSafe and nonPartyPlayerNear(pos(), 8)) then
     n = 0
     for spec in getSpectators():                       -- whole screen
        if spec ~= player and spec:isMonster() and type < 3
           and matchesEntryFilters(entry, nameFilter, hp, name:lower())
           and distanceFromPlayer(spec:getPosition()) <= 5
        then n = n + 1
     if countGate(n) and guardsPass() then
        return executeAttackBotAction(5, attackData, executeCooldown)
```

Radius 5 = cast range 3 + one 2-sqm jump. Radius 8 = the same
`castRange + 2*jumpDist + 1` the optimizer uses. **No turning, no sight check.**
AB:2984-2986 records that the old code passed numbers into `getSpectators`,
which silently means "whole screen".

`matchesEntryFilters` (AB:1405-1409) is `hp within [minHp,maxHp]` and
`#nameFilter == 0 or table.find(nameFilter, lowerName, true)` — case-insensitive.

### 5.4 Waves and beams — `isWave` true (AB:3019-3061)

```
safe = PvpSafe and spellPatterns[pCat][pattern][2] or false
waveCount, waveDir, waveCounts = getWaveBestDir(spellPatterns[pCat][pattern][1],
                                                minHp, maxHp, safe, entry.monsters)
currentDirCount = waveCounts[player:getDirection()] or 0

-- 1) already facing well enough?
if countGate(currentDirCount) then
    if guardsPass() then return cast()          -- fires WITHOUT turning
-- 2) otherwise consider turning
else
    if countGate(waveCount) and currentSettings.Rotate and guardsPass() then
        blockedByPlayer = false
        if safe then
            for spec in getSpectators(pos(), safe):
                if spec ~= player and spec:isPlayer() and not spec:isPartyMember() then
                    blockedByPlayer = true; break
        if not blockedByPlayer and autoTurnAndFire(waveDir, cast) then return
```

Note the asymmetry: branch 1 does **not** re-check `blockedByPlayer` (it relies
on `getWaveBestDir`'s own veto, which per §2.5 never fires), and branch 2
requires `Rotate` explicitly even though `autoTurnAndFire` already checks it —
so with `Rotate` off, branch 2 is dead and only "already facing right" can fire.

### 5.5 Self-centred areas and pattern 8 (AB:3062-3069)

```
monsterAmount = pCat ~= 8 and getMonstersInArea(5, pos(), spellPatterns[pCat][pattern][1],
                                                minHp, maxHp, safe, entry.monsters, pos())
if (pattern ~= 8 and countGate(monsterAmount))
   or (pattern == 8 and bestSide >= entry.count
                    and (not PvpSafe or getPlayers(2) == 0)) then
    if guardsPass() then return cast()
```

* The guard on the count is `pCat ~= 8`, **not** `pattern ~= 8`. `pCat` is
  `entry.patternCategory`, which is 4 for every category-5 entry, so the count is
  **always computed**, including for pattern 8 where it is then ignored. Behaviour
  matches only as long as a port keeps `patternCategory` from the saved config.
* **Pattern 8 (Large Beam) is a genuine vBot bug.** `isWave` excludes it even
  though pattern 7 (Short Beam) is included, so its letter grid is counted with a
  *position* centre (direction 8 ⇒ everything off ⇒ 0), the count is discarded,
  and the fire decision is taken purely from the legacy quadrant `bestSide` —
  with **no turning at all**. Reproduce it only for bug-for-bug fidelity;
  otherwise route 8 through `getWaveBestDir` like 7.
* Pattern 8's `entry.count` is compared against `bestSide`, which counts the
  best 11×11 quadrant (or 3×3 for a knight), a completely different shape.
* `getPlayers(range)` (`VL:667-674`) counts
  `not isLocalPlayer() and isPlayer() and distanceFromPlayer <= range and
  not ((getShield() ~= 1 and isPartyMember()) or getEmblem() == 1)`.
  The `~= 1` term deliberately **re-admits** `ShieldWhiteYellow` party members,
  so `getPlayers(2) == 0` can fail because of your own party leader.

### 5.6 Category 2 — area rune (AB:3072-3090)

```
pCat = entry.patternCategory
safe = PvpSafe and spellPatterns[pCat][entry.pattern][2] or false   -- NOT augmented
data = getBestTileByPattern(spellPatterns[pCat][entry.pattern][1], minHp, maxHp,
                            safe, entry.monsters)
if data and countGate(data.amount) and guardsPass() then
    if not runeDelayGate(entry.itemId) then return end
    if CustomCooldown then runeCooldowns[entry.itemId] = now end
    AttackBotFiringUntil = now + 400
    recordLocalUseCooldown()
    return useWith(attackData, g_map.getTile(data.pos):getTopUseThing(), executeCooldown)
```

Area runes read `entry.pattern` directly — **`augmentedWavePattern` is never
applied to category 2.** The area-rune safe grids (`spellPatterns[2][*][2]`) are
all plain 0/1, so this PvP veto works.

`useWith(itemId, thing, cooldown)` → `g_game.useInventoryItemWith(itemId,
thing)`; the third Lua argument is silently dropped because the C++ signature
takes two (`CPP game.cpp:883-906`). Wire form: source is the sentinel
`{x = 0xFFFF, y = 0, z = 0}`, stackpos 0; a creature target becomes
`sendUseOnCreature`, a tile thing becomes `sendUseItemWith`.

### 5.7 Turning and the rune delay

`autoTurnAndFire(neededDir, fireFn)` (AB:2655-2672):

```
if player:getDirection() == neededDir then fireFn(); return true
if currentSettings.Rotate then turn(neededDir); fireFn(); return true   -- SAME TICK
return false
```

`turn()` updates the local direction immediately, so the cast is emitted with
the new facing already applied. A port must send the turn packet first and the
cast packet second, in the same tick, with no delay.

`runeDelayGate(itemId)` (AB:2681-2705):

```
if not RuneDelayEnabled then runeDelayTimers[itemId] = nil; return true
delayEnd = runeDelayTimers[itemId]
   or (now + max(0, (RuneDelay or 0) - getPingCompensation()))     -- stored on first call
AttackBotFiringUntil = delayEnd + 10            -- reserve the slot for the whole wait
if now < delayEnd then return false
runeDelayTimers[itemId] = nil; return true
```

The timer starts only **after** a real target/pattern match is confirmed, and is
cleared whenever the entry is skipped for mana/harmony/not-ready, so the
reservation stays honest.

---

## 6. The five optimizers

Data: `bot/data/optimizers.lua`. Entry point `tryOptimizedSpell(entry,
attackData, executeCooldown)` (AB:1584-1631) returns `handled, fired`.
`handled = true` skips the legacy path for this entry entirely; `fired = true`
ends the tick.

```
if type(attackData) ~= "string" then return false, false        -- runes are never optimized
def = OptimizedSpells[attackData:lower():trim()]
if not def or not currentSettings[def.opt] then return false, false

-- cheap pre-gate (AB:1593-1603)
onScreen = count of spectators with spec ~= player, isMonster, type < 3,
           hp present, and matchesEntryFilters(entry, nameFilter, hp, lowerName)
if onScreen < entry.count then return true, false               -- owns the entry, no scan

if def.mode == "tile" then ... (§6.3)
-- hop / star:
if PvpSafe and nonPartyPlayerNear(pos(), def.castRange + def.jumpDist*2 + 1) then
    return true, false
best = findBestChainSeed(entry, def)
if not best or not optimizerCountGate(entry, best.counted) then return true, false
if not optimizerGuardsPass() then return true, false
if not best.isCurrent then attack(best.creature) end
executeAttackBotAction(1, attackData, executeCooldown)          -- category 1 => cast()
return true, true
```

The pre-gate uses `entry.count` even when `entry.orMore` is false, so an
exact-count entry is still skipped only when *fewer* than `count` are on screen.

### 6.1 The parameter table (executed)

```
$ luajit opt_test.lua
LuaJIT: Lua 5.1 / LuaJIT 2.1.1781602682

=== M.spells (5 optimizers) ===
formula              name                   opt flag    mode   range  jumps/dist pvpSafeRadius
exori med pug        Chained Penance        OptPenance  hop    3      4/2       8
exori gran mas nia   Spiritual Outburst     OptOutburst hop    3      7/2       8
exevo fur tera       Forked Thorns          OptThorns   star   4      5/4       13
exevo fur frigo      Forked Glacier         OptGlacier  star   4      6/4       13
exori mas amp pug    Thousand Fist Blows    OptTFB      tile   5      -         n/a (tile mode -> radius 3 per tile)

=== M.waveAugments ===
  exevo gran frigo hur     -> pattern 12

=== defFor() recognition is case/whitespace insensitive and category-blind ===
  "EXORI MED PUG" -> OptPenance / hop
  "  exori mas amp pug " -> OptTFB / tile
  "exori mas pug" -> not optimized
  "exevo fur tera" -> OptThorns / star

=== tile vs area-rune scanner asymmetry ===
  TFB  : dist 0<d<=5, isWalkable(ignoreCreatures=true), tie=nearest-to-player, pvp=radius 3
  rune : dist < 4 (0..3), isWalkable(ignoreCreatures=false), tie=first-in-map-order, pvp=safe grid

=== timing ===
  USE_COOLDOWN_MS            1000
  fallbackTickDelayMs        400
  firingReserveAreaRuneMs    400
  firingReserveSpellMs       150
  macroTimeoutMs             50
  pingCompensationOffset     30
  pingCompensationThreshold  150
  predictiveReserveMs        1000
  runeDelayReserveSlackMs    10
  runeReadyReserveMs         250
  serverCooldownExecuteMs    30
```

`pvpSafeRadius` is derived, not stored: `castRange + jumpDist*2 + 1`.

### 6.2 Chain modes — Chained Penance, Spiritual Outburst (hop); Forked Thorns, Forked Glacier (star)

**The candidate world** (`collectChainWorld`, AB:1412-1427) is every spectator
with `spec ~= player and spec:isMonster() and (clientVersion < 960 or
spec:getType() < 3)` and a non-nil `getHealthPercent()`. Each becomes
`{ c = spec, pos = spec:getPosition(), hp = hp, counted = matchesEntryFilters(...) }`.
Critically: **the entry's hp%/name filters do not remove anything from the
world** — the server does not care about them when chaining. They only set the
`counted` flag, which is what the count gate measures.

**Hop simulation** (`simulateHopChain(seed, world, jumpDist, maxJumps)`,
AB:1431-1455):

```
hits = {seed}; hitSet = {[seed]=true}; cur = seed
repeat maxJumps times:
    best = nil
    for m in world:
        if not hitSet[m]
           and getDistanceBetween(cur.pos, m.pos) <= jumpDist
           and posSightClear(cur.pos, m.pos)                 -- sight from the LAST LINK
        then if not best or m.hp > best.hp then best = m
    if not best then break
    hitSet[best] = true; hits[#hits+1] = best; cur = best
counted = #{ m in hits : m.counted }
return counted, #hits
```

The jump origin is the **last creature hit**, not the player and not the seed.
Preference is the **highest remaining HP%** — the server's documented monk-chain
priority — with strict `>` so the first candidate in world-iteration order wins
an hp tie. `world` order comes from `pairs(getSpectators())`, which is
**unordered in Lua**, so hp ties are non-deterministic; a port that wants
reproducibility should sort the world.

**Star scoring** (`starChainScore(seed, world, jumpDist, cap)`, AB:1458-1473):

```
total, counted = 0, 0
for m in world:
    if m ~= seed and getDistanceBetween(seed.pos, m.pos) <= jumpDist
       and posSightClear(seed.pos, m.pos)                    -- sight from the SEED
    then total++; if m.counted then counted++ end
total   = min(total, cap)
counted = min(counted, cap)
return counted + (seed.counted and 1 or 0), total + 1
```

Every extra hit is measured **from the initial target**, never chained. Both
tallies are clamped to `cap` and the seed is added afterwards, so the maximum
returned `total` is `jumps + 1` (6 for Thorns, 7 for Glacier). AB:1467-1470
flags this as approximate: which `cap` of the in-range candidates the server
actually prefers is undocumented, so in dense packs the score is a guess.

**Seed selection** (`findBestChainSeed`, AB:1488-1512):

```
cur = target()
for m in world:
    if m.counted and getDistanceBetween(pos(), m.pos) <= def.castRange
       and m.c:canShoot(def.castRange)                       -- sight AND range from player
    then
        counted, total = (mode == "hop") and simulateHopChain(m, world, jumpDist, jumps)
                                          or starChainScore(m, world, jumpDist, jumps)
        isCurrent = (cur ~= nil and m.c == cur)
        replace best when:  no best yet
                         |  counted > best.counted
                         |  counted == best.counted and total > best.total
                         |  counted == best.counted and total == best.total
                                and isCurrent and not best.isCurrent
```

The seed must itself be `counted` — a monster outside the entry's hp/name filter
can never be the initial target, even if chaining from it would cover more.

**What makes the optimizer choose differently from the legacy path.** The legacy
17/18 path (§5.3c) requires the *current* target within 3 and then counts every
filter-matching monster within 5 sqm **of the player**, regardless of whether the
chain could reach it. The optimizer instead simulates the actual jump graph from
each legal seed and counts only the creatures the chain would really touch — so
it fires in cases the legacy count misses (a tight line of monsters leading away
from the player) and holds fire in cases the legacy count over-counts (five
monsters spread around the player, no two within 2 sqm of each other). It also
**changes the target**: `attack(best.creature)` is sent before the cast whenever
the winning seed is not already the target.

### 6.3 Tile mode — Thousand Fist Blows (`findBestTfbTile`, AB:1525-1551)

```
safeCheck = currentSettings.PvpSafe
myPos = pos()
best = { counted = 0, pos = nil, dist = 999 }

-- (1) the player's OWN tile, seeded first and unconditionally
if not (safeCheck and nonPartyPlayerNear(myPos, 3)) then
    selfCount = getMonstersInArea(2, myPos, tfbAreaPattern, minHp, maxHp,
                                  false, entry.monsters, myPos)
    if selfCount > 0 then best = { counted = selfCount, pos = myPos, dist = 0 }

-- (2) every other tile on this floor
for tile in g_map.getTiles(posz()):
    tPos = tile:getPosition();  dist = distanceFromPlayer(tPos)
    if dist > 0 and dist <= def.castRange           -- 1..5, NOT "< 4"
       and tile:canShoot()                          -- sight from the PLAYER
       and tile:isWalkable(true)                    -- ignoreCreatures = TRUE
    then
        if not (safeCheck and nonPartyPlayerNear(tPos, 3)) then
            counted = getMonstersInArea(2, tPos, tfbAreaPattern, minHp, maxHp,
                                        false, entry.monsters, tPos)
            if counted > best.counted
               or (counted == best.counted and counted > 0 and dist < best.dist)
            then best = { counted = counted, pos = tPos, dist = dist }
return best.pos and best or nil
```

`tfbAreaPattern = spellPatterns[4][15][1]` (AB:1399) — hard-coded to
`patternCategory 4`, unlike the legacy path which uses `entry.patternCategory`.

Four deliberate differences from `getBestTileByPattern` (§4.5), all of which
must be copied:

| | `getBestTileByPattern` (area rune) | `findBestTfbTile` |
|---|---|---|
| walkability | `isWalkable()` — creatures **block** | `isWalkable(true)` — creatures **ignored** |
| range | `distance < 4` (0..3) | `0 < distance <= 5` |
| own tile | only if it happens to be in range | **seeded first**, with its own `nonPartyPlayerNear(myPos, 3)` veto |
| tie-break | first tile in map order | **nearest to the player** (`dist < best.dist`, and only when `counted > 0`) |
| PvP-safe | the `[2]` safe grid, via `getMonstersInArea`'s step (A) | `nonPartyPlayerNear(tPos, 3)` — a plain radius |

Rationale for the tie-break (AB:1517-1524): melee monsters converge on the
player between scoring and the server resolving the cast, so among equal
snapshots the nearer centre — the player's own tile at distance 0 — is strictly
more robust. The old strict `>` kept whichever tied tile happened to be scanned
first.

The winner is cast at with `castAtPos(words, pos, executeCooldown)`
(AB:1556-1569), which mirrors `cast()`'s `SpellCastTable` bookkeeping and then
calls `castSpellAt(text, position)` = `g_game.talkSpell(text,
SpellAimCursor = 2, position)` (`FN player.lua:101-120`). If `castAtPos`
returns false — reachable only in `CustomCooldown` mode with
`entry.cooldown >= 100`, since `ServerCooldown` passes 30 — `tryOptimizedSpell`
returns `handled = false, fired = false` and the **legacy face-the-target
pattern-15 path runs in the same tick** (AB:1605-1614).

**What makes it choose a tile over the plain path.** The legacy path centres the
5×5 on the *target* and only checks that the target is within 5. The optimizer
scores every legal aim point, so it will aim one or two tiles off the target — or
at the player's own feet — whenever that covers more filter-matching monsters,
and it prefers the closest such tile.

### 6.4 Optimizer guards summary

```
optimizerGuardsPass()  = (not BlackListSafe or not isBlackListedPlayerInRange(AntiRsRange))
                     and (not Kills or killsToRs() > KillsAmount)      -- AB:1571-1574
optimizerCountGate(e,n)= (e.orMore and n >= e.count) or (not e.orMore and n == e.count)
```

Order of gates inside `tryOptimizedSpell`: formula lookup → profile flag →
on-screen pre-gate → (chain only) PvP radius veto → scan → count gate →
guards → fire. The guards run **after** the expensive scan.

---

## 7. Wave augments

### 7.1 The table (AB:1290-1294, verbatim)

```lua
local WAVE_AUGMENTS = {
  ["exevo gran frigo hur"] = 12,     -- Strong Ice Wave: base 10 "Small Wave" -> 12 "Huge Wave"
}
```

One entry, and only one. Reproduced as `M.waveAugments` in
`bot/data/optimizers.lua`.

The rationale (AB:1278-1289) is worth preserving verbatim in spirit: some Wheel
of Destiny perks enlarge a wave's area a lot; the enlarged shape is applied
**server-side and is not in any client table**, so vBot approximates it by
counting against a bigger *existing* wave pattern. Whether the augment is active
is a **manual per-entry checkbox** — the wheel state is not reliably readable
from a bot, so vBot never infers it.

Measured effect (§2.4): pattern 10 covers **7 cells per facing** in a 7×7 box;
pattern 12 covers **18 cells per facing** in a 13×13 box. The augment therefore
roughly 2.5× the counted coverage.

### 7.2 When the swap applies (AB:1296-1301, AB:2937)

```lua
local function augmentedWavePattern(entry)
  local basePattern = entry.pattern
  if not entry.augmented then return basePattern end
  local words = type(entry.spell) == "string" and entry.spell:lower():trim() or nil
  return (words and WAVE_AUGMENTS[words]) or basePattern
end
```

All of the following must hold, or the base pattern is kept:

1. `entry.augmented` is truthy. It is nil on every pre-2024 entry (five of the
   eight in the user's real profile 1 have no `augmented` key), and `nil` is
   falsy, so those keep their base pattern.
2. `entry.spell` is a **string** — a rune entry has `spell = ""`, which is a
   string but will not be a key.
3. The lowercased, trimmed formula is a key of `WAVE_AUGMENTS`.

Where it is applied:

* **Category 5 only.** `local pattern = augmentedWavePattern(entry)` at
  **AB:2937**, before the sub-path dispatch. Every subsequent
  `spellPatterns[pCat][pattern]` lookup on that path — including the safe grid —
  uses the augmented id.
* **Category 2 never.** AB:3074-3075 index `spellPatterns[pCat][entry.pattern]`
  directly. Area runes cannot be augmented.
* **The words cast are unchanged.** `attackData` is still `entry.spell`; only
  the counting geometry moves.

Because pattern 12 is a letter grid, an augmented Strong Ice Wave routes through
`isWave` → `getWaveBestDir` exactly as pattern 10 did. And because
`spellPatterns[4][12][2]` is the (all-letters) Large Beam safe grid, its PvP
veto is inert either way (§2.5).

Executed check (`bot/data/optimizers.lua`, `M.augmentedPattern`):

```
=== augmentedPattern() against the real profile_1 entries ===
  spell="exori mas res" augmented=false pattern 19 -> 19
  spell="exori gran mas nia" augmented=false pattern 17 -> 17
  spell="exori med pug" augmented=nil   pattern 18 -> 18
  spell="exevo gran frigo hur" augmented=true  pattern 10 -> 12
  spell="exevo gran frigo hur" augmented=false pattern 10 -> 10
  spell="  ExeVo Gran Frigo Hur  " augmented=true  pattern 10 -> 12
```

### 7.3 Category-5 routing over every pattern id (executed)

```
 1=selfArea   2=WAVE   3=selfArea   4=selfArea   5=selfArea   6=selfArea   7=WAVE
 8=quadrant(bug)   9=monkDir  10=WAVE  11=WAVE  12=WAVE  13=monkDir  14=monkDir
15=thrown  16=monkDir  17=chain  18=chain  19=monkDir
```

(Patterns 10, 11 and 12 *do* reach the `isWave` test and are true; 9, 13–19 are
consumed by the earlier branches and never reach it.)

---

## 8. The `AttackBot.json` entry schema, field by field

Path: `/bot/<configName>/vBot_configs/profile_<g_settings.profile>/AttackBot.json`
(`vBot/configs.lua:20-27`), written by `vBotConfigSave("atk")` as
`json.encode(AttackBotConfig, 2)`. On this machine:
`D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot_configs\profile_1\AttackBot.json`.

Decoded and dumped from the real file:

```
top keys: ['AttackBot', 'currentBotProfile']
currentBotProfile: 1
n profiles: 5
profile1 non-entry keys:
    AntiRsRange = 5          BlackListSafe = False    Cooldown = True
    CustomCooldown = False   Kills = False            KillsAmount = 1
    OptGlacier = False       OptOutburst = True       OptPenance = True
    OptTFB = True            OptThorns = False        PvpSafe = False
    Rotate = True            RuneDelay = 50           RuneDelayEnabled = True
    ServerCooldown = True    Visible = False          enabled = True
    ignoreMana = True        name = 'Profile #1'      pvpMode = False
profile2 keys: [AntiRsRange, BlackListSafe, Cooldown, Kills, KillsAmount,
                OptGlacier, OptOutburst, OptPenance, OptTFB, OptThorns, PvpSafe,
                Rotate, RuneDelay, RuneDelayEnabled, Visible, attackTable,
                enabled, ignoreMana, name, pvpMode]
```

Profile 1 has **no `Training` key** (never toggled), and profile 2 has **neither
`ServerCooldown` nor `CustomCooldown`** — a reader must apply the AB:1741-1757
migration defaults before reading anything, and treat missing booleans as false.

### 8.1 Entry fields as the code reads them

Built at **AB:2258-2277**. Every field, with how the tick actually uses it:

| field | type | read at | meaning — **flagged** where the name misleads |
|---|---|---|---|
| `enabled` | bool | AB:2786 | per-entry on/off. Always `true` on creation. |
| `spell` | string | AB:2785, 2808, 1586 | cast words. `""` for a rune. **Flag:** also the optimizer lookup key and the augment key, after `:lower():trim()`. |
| `itemId` | number | AB:2785, 2788 | rune client id. **Flag: the rune/spell discriminator is `itemId > 100`, not `itemId ~= 0`.** Values 1..100 are treated as spells. |
| `category` | 1..5 | AB:2915-3072 | see §1.1 of the base spec. |
| `patternCategory` | 1..4 | AB:2933, 3073 | **Flag:** derived in the UI as `cat==4→3, cat==5→4, else cat` (AB:1866) and then **persisted**. Every grid lookup indexes it, so a stale value silently indexes the wrong (or empty) table. |
| `pattern` | number | AB:2917, 2923, 2937, 3074 | **Flag: two different meanings.** For categories 1/3/4 it is a **range in sqm** (1..10) compared with `distanceFromPlayer(target)`. For categories 2/5 it is a **grid id** into `spellPatterns[patternCategory]`. |
| `count` | 1..99 | countGate | minimum (or exact) monster count. |
| `orMore` | bool | countGate | `true` → `n >= count`; `false`/nil → `n == count`. **Flag: nil means exact-count**, and older entries have no key. |
| `minHp` / `maxHp` | 0..99 / 1..100 | everywhere | monster HP% window, **inclusive both ends**. In `pvpMode` it is applied to the *target's* hp instead (AB:2896). |
| `mana` | 0..99 | AB:2786 | minimum `manapercent()` = `floor(mana*100/maxMana)`, or 100 when `maxMana <= 1`. |
| `cooldown` | 0..999999 | AB:2794, 2847 | **Flag: two different units.** `entry.cooldown * 1000` on the rune path ⇒ **seconds**; passed straight to `cast(text, delay)` on the spell path ⇒ **milliseconds**. Only read in `CustomCooldown` mode. With the common value `1`, a spell entry gets `delay = 1`, which `cast()` treats as "< 100 ⇒ just say it". |
| `harmony` | 0..10 | AB:2787 | minimum `player:getHarmony()` (monk resource, from opcode 0xC1 MonkData). Guarded as `entry.harmony and entry.harmony > 0`. |
| `monsters` | `true` \| array of lowercase strings | §4.2, §4.3, §4.4, §6 | name whitelist. `true` when the text was empty, `"*"` or the placeholder `"monster names"`; otherwise `string.split(creatures, ",")`. **Flag: `string.split` does NOT trim**, so `"a, b"` stores `{"a", " b"}` and the second can never match. |
| `augmented` | bool | AB:1298 | Wheel-of-Destiny wave augment. **Flag: manual, per entry, and it swaps only the COUNTING pattern** — the words cast are unchanged, and it is ignored for category 2. |
| `creatures` | string | — | **WIDGET-ONLY.** Raw text, already `:lower()`ed at AB:2228. Kept to repopulate the edit form. |
| `tooltip` | string \| false | — | **WIDGET-ONLY.** `monsters ~= true and creatures`. |
| `description` | string | — | **WIDGET-ONLY.** Display label, built at AB:2276. |

There is **no** per-entry cooldown *flag*, **no** per-entry PvP flag and **no**
per-entry "ignore this in PZ" flag. All of those are profile-wide.

### 8.2 The real eight entries (verbatim, from the decoded JSON)

```json
1 {"augmented": false, "category": 5, "cooldown": 1, "count": 1, "creatures": "true frost flower asura", "description": "[Balanced Brawl] 1+ Creatures: exori mas res, absolute (0%-100%)", "enabled": true, "harmony": 0, "itemId": 0, "mana": 10, "maxHp": 100, "minHp": 0, "monsters": ["true frost flower asura"], "orMore": true, "pattern": 19, "patternCategory": 4, "spell": "exori mas res", "tooltip": "true frost flower asura"}
2 {"augmented": false, "category": 5, "cooldown": 1, "count": 5, "creatures": "monster names", "description": "[Spiritual Outburst] 5+ Any Creatures: exori gran mas nia, absolute (0%-100% [H:5])", "enabled": true, "harmony": 5, "itemId": 0, "mana": 20, "maxHp": 100, "minHp": 0, "monsters": true, "orMore": true, "pattern": 17, "patternCategory": 4, "spell": "exori gran mas nia", "tooltip": false}
3 {"category": 5, "cooldown": 1, "count": 2, "creatures": "monster names", "description": "[Chained Penance] 2+ Any Creatures: exori med pug, absolute (0%-100%)", "enabled": true, "harmony": 0, "itemId": 0, "mana": 10, "maxHp": 100, "minHp": 0, "monsters": true, "orMore": true, "pattern": 18, "patternCategory": 4, "spell": "exori med pug", "tooltip": false}
4 {"category": 5, "cooldown": 1, "count": 4, "creatures": "monster names", "description": "[Thousand Fist Blows] 4+ Any Creatures: exori mas amp pug, absolute (0%-100%)", "enabled": true, "harmony": 0, "itemId": 0, "mana": 10, "maxHp": 100, "minHp": 0, "monsters": true, "orMore": true, "pattern": 15, "patternCategory": 4, "spell": "exori mas amp pug", "tooltip": false}
5 {"augmented": false, "category": 5, "cooldown": 1, "count": 3, "creatures": "monster names", "description": "[Sweeping Takedown] 3+ Any Creatures: exori mas nia, absolute (0%-100% [H:5])", "enabled": true, "harmony": 5, "itemId": 0, "mana": 20, "maxHp": 100, "minHp": 0, "monsters": true, "orMore": true, "pattern": 16, "patternCategory": 4, "spell": "exori mas nia", "tooltip": false}
6 {"category": 5, "cooldown": 1, "count": 2, "creatures": "monster names", "description": "[Greater Flurry] 2+ Any Creatures: exori gran mas pug, absolute (0%-100%)", "enabled": true, "harmony": 0, "itemId": 0, "mana": 15, "maxHp": 100, "minHp": 0, "monsters": true, "orMore": true, "pattern": 14, "patternCategory": 4, "spell": "exori gran mas pug", "tooltip": false}
7 {"category": 5, "cooldown": 1, "count": 1, "creatures": "monster names", "description": "[Flurry of Blows] 1+ Any Creatures: exori mas pug, absolute (0%-100%)", "enabled": true, "harmony": 0, "itemId": 0, "mana": 10, "maxHp": 100, "minHp": 0, "monsters": true, "orMore": true, "pattern": 13, "patternCategory": 4, "spell": "exori mas pug", "tooltip": false}
8 {"category": 1, "cooldown": 1, "count": 1, "creatures": "monster names", "description": "[7 Sqm] 1+ Any Creatures: exori amp pug, targeted (0%-20%)", "enabled": true, "harmony": 0, "itemId": 0, "mana": 10, "maxHp": 20, "minHp": 0, "monsters": true, "orMore": true, "pattern": 7, "patternCategory": 1, "spell": "exori amp pug", "tooltip": false}
```

Reading the user's real setup through the algorithm above:

* This is a **monk** build. `Rotate = true`, `PvpSafe = false`,
  `ServerCooldown = true`, `Visible = false`, `pvpMode = false`,
  `BlackListSafe = false`, `Kills = false`.
* With `PvpSafe = false`, **every** `safe` grid in §5 is `false` and none of the
  PvP vetoes of §2.5 matter for this user. The optimizers' `nonPartyPlayerNear`
  vetoes are likewise skipped.
* `OptPenance`, `OptOutburst`, `OptTFB` are **on**, so entries 2, 3 and 4 are
  owned by the optimizers and their legacy paths (§5.3b, §5.3c) never run.
  Entries 2 and 3 will **re-target** (`attack(seed)`), so this client does not
  merely follow TargetBot's target.
* Entry 1 is the only one with a name filter, and it is a single name with no
  comma, so the `string.split` trimming trap does not bite.
* Entries 3, 4, 6, 7, 8 have no `augmented` key — nil, falsy, base pattern.
* Entry 6 (pattern 14) and entry 5 (pattern 16) are exactly the two whose safe
  grids are invalid (§2.5 finding 2) — invisible here only because
  `PvpSafe = false`.
* `cooldown = 1` on every entry is dead data: `ServerCooldown` mode ignores
  `entry.cooldown` entirely and uses `executeCooldown = 30`.
* `ignoreMana` and `Cooldown` are legacy keys that AttackBot.lua never reads.

### 8.3 Profile-level fields

Defaults at AB:1637-1717 (all five profiles created identically); migrations at
AB:1734-1757.

```
name              string  "Profile #N"
enabled           bool    false      -- this profile's master switch
attackTable       array   {}         -- ORDER = PRIORITY, index 1 fires first
Rotate            bool    false      -- "Auto Turn (Waves, Monk Spells...)"
Kills             bool    false      -- block area attacks while killsToRs() <= KillsAmount
KillsAmount       1..10   1
CustomCooldown    bool    false      -- mutually exclusive with ServerCooldown in practice
ServerCooldown    bool    true
Visible           bool    true       -- runes: require hasItemAvailable(itemId)
pvpMode           bool    false      -- fire at the target ignoring counts/patterns
PvpSafe           bool    true       -- use the [2] safe grids / non-party-player vetoes
BlackListSafe     bool    false
AntiRsRange       1..10   5          -- MIGRATED ONLY ON THE ACTIVE PROFILE (AB:1734-1736)
RuneDelay         0..5000 50         -- ms, migrated on all 5
RuneDelayEnabled  bool    true       -- migrated on all 5
OptPenance/OptOutburst/OptTFB/OptThorns/OptGlacier  bool  false   -- migrated on all 5
Training          bool    (no default anywhere; absent until first toggled -> treat as false)
ignoreMana, Cooldown                 -- dead keys in old saves, never read
```

`currentBotProfile` ∈ 1..5, coerced to 1 when nil, 0 or > 5 (AB:1720-1722).
The five-profile array is recreated from scratch whenever
`#AttackBotConfig["AttackBot"] ~= 5` (AB:1635).

Secondary config: `/bot/<configName>/storage/profile_<N>.json` →
`playerList.blackList` (array of names, compared case-sensitively).

---

## 9. Reimplementation checklist, in dependency order

1. Grid parser + cache, a faithful port of `Map::getSpectatorsByPattern`
   including the post-loop flush and the odd-dimension rejection (§2.1).
2. `spectatorsByPattern(centre, grid, direction)` with `direction = 8` for a
   position centre (§2.1).
3. `isSightClear` with the exact line walk, testing the destination tile,
   failing open on unknown tiles (§4.6).
4. `getMonstersInArea` exactly as §4.2, including both name comparisons.
5. `extractDirGrid` + `getWaveBestDir` (§4.3) and `getMonkBestDir` (§4.4),
   remembering that neither filters summons.
6. `getBestTileByPattern` (§4.5) and, separately, `findBestTfbTile` (§6.3) —
   do not share an implementation.
7. The tick of §1, iterating `attackTable` in order with `return`-on-fire.
8. Cooldown bookkeeping: `SpellCooldownCache`, `SharedUseCooldown`,
   `AttackBotFiringUntil` / `AttackBotRuneReadyUntil` in a shared table (§1.4).
9. The optimizers of §6, driven by `bot/data/optimizers.lua`, including the
   `attack(seed)` re-target.
10. Config load with the §8.3 migrations, treating missing booleans as false.
