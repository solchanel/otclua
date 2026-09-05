--[[============================================================================
bot/data/optimizers.lua -- PURE DATA for the vBot 4.8 AttackBot spell
optimizers and the Wheel-of-Destiny wave augments.

Work item D3.  This file contains NO engine: no world queries, no casting, no
state.  It is the rules table that `bot/attackbot.lua` (owned by another
module) reads.  Every number here is transcribed verbatim from

  D:\Claude\otclient_mehah1530\otclient\profiles\bot\vBot_4.8\vBot\AttackBot.lua

with the source line cited beside it.  Algorithms are documented in
docs/vbot/attackbot-full.md sections 6 and 7.

    local OPT = require('bot.data.optimizers')
    local def = OPT.spells[entry.spell:lower():gsub('^%s*(.-)%s*$','%1')]
    if def and profile[def.opt] then ... end

Lua 5.1 / LuaJIT 2.1 dialect: no goto, no integer division, no bitops needed.
==============================================================================]]

local M = {}

--------------------------------------------------------------------------- 1
-- OptimizedSpells -- AttackBot.lua:1388-1397, VERBATIM.
--
-- Keyed by the CAST FORMULA, lowercased and trimmed.  Recognition is by
-- formula in ANY category (AttackBot.lua:1385-1387): it does not matter
-- whether the user added the spell as category 1 "Targeted" or category 5
-- "Absolute" -- if the formula is a key here and the profile boolean named by
-- `opt` is true, the optimizer OWNS the entry and the legacy per-category
-- dispatch is skipped entirely for it.
--
-- fields
--   opt        profile boolean that enables it (default false, migrated in at
--              AttackBot.lua:1751-1755)
--   mode       'hop'  = monk chain, each jump measured from the LAST creature
--                       hit, server prefers the highest remaining HP%
--              'star' = druid fork, every extra hit measured from the INITIAL
--                       target, no chaining
--              'tile' = thrown area, aimed at an arbitrary position with
--                       talkSpell(words, SpellAimCursor = 2, pos)
--   castRange  max Chebyshev distance player -> seed / aim tile.  For 'hop'
--              and 'star' the seed must ALSO pass creature:canShoot(castRange)
--              (sight clear AND within castRange).
--   jumps      number of ADDITIONAL creatures beyond the seed the server hits
--              ('hop': chain length cap; 'star': cap on the fork).  nil for
--              'tile'.
--   jumpDist   max Chebyshev distance of one jump.  nil for 'tile'.
M.spells = {
  ['exori med pug']      = { opt = 'OptPenance',  mode = 'hop',  castRange = 3, jumps = 4, jumpDist = 2 },
  ['exori gran mas nia'] = { opt = 'OptOutburst', mode = 'hop',  castRange = 3, jumps = 7, jumpDist = 2 },
  ['exevo fur tera']     = { opt = 'OptThorns',   mode = 'star', castRange = 4, jumps = 5, jumpDist = 4 },
  ['exevo fur frigo']    = { opt = 'OptGlacier',  mode = 'star', castRange = 4, jumps = 6, jumpDist = 4 },
  -- AttackBot.lua:1393-1396 carries an explicit UNVERIFIED note: castRange 5
  -- is what the config assumed for aimed monk casts; the TibiaWiki diagram
  -- suggests the real server range may be up to 7.  Do not "fix" it silently.
  ['exori mas amp pug']  = { opt = 'OptTFB',      mode = 'tile', castRange = 5 },
}

-- Friendly names, for logs only.  Not read by any decision.
M.spellNames = {
  ['exori med pug']      = 'Chained Penance',
  ['exori gran mas nia'] = 'Spiritual Outburst',
  ['exevo fur tera']     = 'Forked Thorns',
  ['exevo fur frigo']    = 'Forked Glacier',
  ['exori mas amp pug']  = 'Thousand Fist Blows',
}

--------------------------------------------------------------------------- 2
-- Chain-mode (hop/star) policy constants -- AttackBot.lua:1431-1512, 1616-1630.

M.chain = {
  -- The candidate world is EVERY monster on screen on the player's floor
  -- (AttackBot.lua:1412-1427).  The entry's hp%/name filters do NOT remove a
  -- monster from the world -- the server ignores them when chaining -- they
  -- only decide whether a hit COUNTS towards entry.count (the `counted` flag).
  worldIncludesUnfilteredMonsters = true,

  -- Seed eligibility (AttackBot.lua:1494-1495):
  --   m.counted  and  chebyshev(playerPos, m.pos) <= def.castRange
  --              and  m.c:canShoot(def.castRange)
  seedMustBeCounted   = true,
  seedMustCanShoot    = true,

  -- Hop simulation (AttackBot.lua:1435-1449): from the current link, jump to
  -- the unvisited world monster with the HIGHEST hp% that is within jumpDist
  -- (Chebyshev) AND sight-clear FROM THE LAST LINK.  First-found wins an hp
  -- tie (strict `m.hp > best.hp`).  Stops early when no candidate remains.
  hopPrefers          = 'highest-hp-percent',
  hopTieBreak         = 'first-in-world-order',
  hopSightFrom        = 'previous-link',

  -- Star scoring (AttackBot.lua:1458-1473): count every OTHER world monster
  -- within jumpDist of the SEED and sight-clear FROM THE SEED, clamp both the
  -- counted and total tallies to `jumps`, then add the seed itself.
  starSightFrom       = 'seed',
  starClampsBothTallies = true,

  -- Best-seed selection (AttackBot.lua:1503-1507), in order:
  --   1. higher `counted`
  --   2. tie -> higher `total`
  --   3. tie -> the seed that IS the current attack target
  -- Anything still tied keeps the first candidate in world iteration order.
  seedTieBreak = { 'counted', 'total', 'is-current-target' },

  -- After a winning seed is chosen and every gate passed, if the seed is not
  -- already the attack target the client sends attack(seed) and then the cast
  -- IN THE SAME TICK (AttackBot.lua:1624-1629).  Attack packet first.
  retargetsBeforeCast = true,

  -- PvP veto BEFORE the seed scan (AttackBot.lua:1618-1620): with PvpSafe on,
  -- bail out when any non-party player is within this Chebyshev radius of the
  -- PLAYER.  radius = castRange + jumpDist * 2 + 1.
  -- Filled in by M.derive() below: Penance/Outburst = 8, Thorns/Glacier = 13.
  pvpSafeRadius = {},
}

--------------------------------------------------------------------------- 3
-- Tile-mode (Thousand Fist Blows) policy constants -- AttackBot.lua:1525-1551.
--
-- IMPORTANT: findBestTfbTile deliberately differs from the area-rune scanner
-- getBestTileByPattern (AttackBot.lua:2580-2596) in FOUR ways.  Both columns
-- are given so a port cannot accidentally share one implementation.
M.tile = {
  -- The 5x5-with-cut-corners area is spellPatterns[4][15][1] (AttackBot.lua:
  -- 1399, grid at AttackBot.lua:736-742): 5x5, 21 enabled cells, radius 2.
  areaPatternCategory = 4,
  areaPatternId       = 15,
  areaRadius          = 2,
  areaCells           = 21,

  -- The player's OWN tile is scored FIRST and unconditionally (distance 0,
  -- sight to your own position is trivially clear) -- AttackBot.lua:1530-1535.
  -- It is only adopted as `best` when its count is > 0.
  seedsOwnTileFirst   = true,

  -- Map scan: dist > 0 and dist <= castRange (so 1..5, NOT `< 4`).
  scanMinDistExclusive = 0,
  scanMaxDistInclusive = 5,          -- == M.spells['exori mas amp pug'].castRange

  -- tile:canShoot() (no arg -> sight from the PLAYER, no distance cap) and
  -- tile:isWalkable(true) -> ignoreCreatures = TRUE.  An occupied tile IS a
  -- legal aim point for a thrown spell, unlike an area rune.
  requiresCanShootFromPlayer = true,
  walkableIgnoresCreatures   = true,

  -- Each candidate is scored with getMonstersInArea(category = 2, centre =
  -- tile, pattern = the 5x5, safePattern = FALSE, sightFromPos = the same
  -- tile).  Category 2 only selects the AREA branch; the entry's real
  -- category is irrelevant here (AttackBot.lua:1531, 1543).
  scoreCategory       = 2,
  scoreSafePattern    = false,
  scoreSightFromTile  = true,

  -- Ties break toward the tile CLOSEST to the player, because melee monsters
  -- converge on the player between scoring and server resolution
  -- (AttackBot.lua:1544).  The area-rune scanner instead keeps the first tile
  -- found in map order.
  tieBreak            = 'nearest-to-player',

  -- PvP-safe uses a RADIUS, not a safe grid: reject a candidate when any
  -- non-party player is within 3 sqm of it (area radius 2 + 1 margin).
  -- Applied to the own-tile seed too (AttackBot.lua:1530, 1542).
  pvpSafeRadius       = 3,

  -- The winning tile is cast at with castAtPos -> castSpellAt(words, pos) ->
  -- talkSpell(words, SpellAimCursor = 2, pos)  (AttackBot.lua:1556-1569).
  aimMode             = 2,

  -- castAtPos returns FALSE when its SpellCastTable delay gate blocks (only
  -- reachable in CustomCooldown mode with entry.cooldown >= 100).  In that
  -- case tryOptimizedSpell returns handled = false and the LEGACY
  -- face-the-target pattern-15 path runs in the same tick
  -- (AttackBot.lua:1605-1614).
  deEscalatesToLegacyOnCastFailure = true,
}

--------------------------------------------------------------------------- 4
-- Shared optimizer gates -- AttackBot.lua:1571-1603.
M.gates = {
  -- Cheap pre-gate run BEFORE any tile scan or chain simulation: count the
  -- filter-matching, non-summon monsters on screen; if fewer than entry.count,
  -- return handled = true, fired = false (AttackBot.lua:1593-1603).
  onScreenPreGate = true,

  -- optimizerCountGate (AttackBot.lua:1576-1578), identical to the legacy one:
  --   entry.orMore  -> n >= entry.count
  --   otherwise     -> n == entry.count
  countGateUsesOrMore = true,

  -- optimizerGuardsPass (AttackBot.lua:1571-1574):
  --   (not BlackListSafe or not isBlackListedPlayerInRange(AntiRsRange))
  --   and (not Kills or killsToRs() > KillsAmount)
  -- NOTE the guards run AFTER the count gate, so a failing guard still costs
  -- the full scan.
  guardsAfterCountGate = true,

  -- The optimizer is reached only after the pvpMode short-circuit and after
  -- canUse (cooldown/mana/harmony) already passed (AttackBot.lua:2912).
  runsAfterCanUse = true,
}

--------------------------------------------------------------------------- 5
-- WAVE_AUGMENTS -- AttackBot.lua:1290-1294, VERBATIM (one entry).
--
-- Wheel-of-Destiny perks enlarge some waves server-side.  The enlarged shape
-- is NOT in any client table, so vBot approximates it by COUNTING against a
-- bigger existing wave pattern.  Only the cast DECISION changes; the words
-- that are said are unchanged, and `entry.pattern` in the JSON is unchanged.
--
--   key   = cast formula, lowercased and trimmed
--   value = the spellPatterns[4] pattern id to count with instead
M.waveAugments = {
  -- Strong Ice Wave (druid).  Base 10 "Small Wave" (7x7, 7 cells per facing)
  -- -> augmented approximated with 12 "Huge Wave" (13x13, 18 cells per facing).
  ['exevo gran frigo hur'] = 12,
}

-- augmentedWavePattern -- AttackBot.lua:1296-1301.
-- The swap happens ONLY when ALL of these hold:
--   * entry.augmented is truthy (a MANUAL per-entry checkbox; the wheel state
--     is not readable from a bot, so vBot never infers it), and
--   * entry.spell is a string, and
--   * its lowercased+trimmed form is a key of M.waveAugments.
-- Otherwise the base entry.pattern is returned unchanged.  Applied at
-- AttackBot.lua:2937 for category 5 ONLY -- category 2 area runes read
-- entry.pattern directly (AttackBot.lua:3074-3075) and are never augmented.
M.augmentAppliesToCategories = { [5] = true }

--------------------------------------------------------------------------- 6
-- Legacy (optimizer OFF) geometry for the same five spells, so a port can see
-- both halves side by side.  Sources: AttackBot.lua:2955-3006.
M.legacy = {
  -- pattern 15, Thousand Fist Blows: face the current target and cast.
  [15] = {
    kind = 'face-target-area',
    centre = 'target-position',
    pattern = { 4, 15, 1 },            -- spellPatterns[pCat][15][1]
    safePattern = { 4, 15, 2 },        -- vetoes on any non-party player inside
    safeCentre = 'target-position',
    sightFrom = 'target-position',
    maxTargetDistance = 5,             -- distanceFromPlayer(targetPos) <= 5
    turnsWith = 'getDirectionToPos(playerPos, targetPos)',
    hasBlacklistKillsGuard = false,    -- NOTE: this sub-path has NO guards
    bailsWholeTickWithoutTarget = true,-- AttackBot.lua:2962 `return`
  },
  -- patterns 17/18, Spiritual Outburst / Chained Penance chain fallback.
  [17] = {
    kind = 'chain-estimate',
    requiresTargetWithin = 3,          -- castRange
    countRadius = 5,                   -- castRange 3 + one 2-sqm jump
    pvpSafeRadius = 8,                 -- nonPartyPlayerNear(playerPos, 8)
    hasBlacklistKillsGuard = true,
    firesWithoutTurning = true,
  },
  [18] = {
    kind = 'chain-estimate',
    requiresTargetWithin = 3,
    countRadius = 5,
    pvpSafeRadius = 8,
    hasBlacklistKillsGuard = true,
    firesWithoutTurning = true,
  },
}

--------------------------------------------------------------------------- 7
-- Category-5 pattern routing table -- AttackBot.lua:2939-3069.
-- `pattern` here is the AUGMENTED pattern (see section 5), except that the
-- spellPatterns lookups index entry.patternCategory, read from the JSON.
M.routing = {
  -- per-direction monk grids, via getMonkBestDir(patternId, ...)
  monkDirection = { [9] = true, [13] = true, [14] = true, [16] = true, [19] = true },
  -- thrown 5x5 around the target
  thrownArea    = { [15] = true },
  -- chain estimate
  chain         = { [17] = true, [18] = true },
  -- everything else falls to the isWave test below.
  --
  -- isWave -- AttackBot.lua:3016, VERBATIM:
  --     isWave = (pattern == 2 or pattern == 7 or pattern >= 9)
  -- Reached only for pattern in {1,2,3,4,5,6,7,8}, because 9/13..19 were
  -- consumed above, so in practice isWave is true for {2, 7} and FALSE for
  -- {1,3,4,5,6,8}.  Pattern 6 "Large Area" is a self-centred 0/1 diamond with
  -- no letters and MUST NOT go through the wave scanner (AttackBot.lua:
  -- 3010-3015); the `>= 9` term is what used to drag it in.
  isWave = function(pattern) return pattern == 2 or pattern == 7 or pattern >= 9 end,
  -- self-centred 0/1 areas, counted around the player
  selfArea = { [1] = true, [3] = true, [4] = true, [5] = true, [6] = true },
  -- pattern 8 "Large Beam" is a letter grid that lands in the self-area
  -- branch, where a position centre disables every letter cell so the count is
  -- always 0.  It fires purely off the legacy quadrant `bestSide` count and
  -- never turns.  This is a vBot bug, preserved here as data.
  quadrantOnly = { [8] = true },
}

--------------------------------------------------------------------------- 8
-- Shared timing constants the optimizers inherit from the main loop.
-- AttackBot.lua:33, 52-60, 2833, 2868, 2891, 2903, 2927, 3086, 2697.
M.timing = {
  USE_COOLDOWN_MS          = 1000,  -- fixed "use anything" lock on this shard
  pingCompensationThreshold = 150,  -- ping > 150 -> compensation = ping - 30
  pingCompensationOffset    = 30,
  firingReserveSpellMs      = 150,  -- AttackBotFiringUntil = now + 150
  firingReserveAreaRuneMs   = 400,  -- ... + 400 on the area-rune path
  runeReadyReserveMs        = 250,  -- AttackBotRuneReadyUntil = now + 250
  runeDelayReserveSlackMs   = 10,   -- AttackBotFiringUntil = delayEnd + 10
  predictiveReserveMs       = 1000, -- reserve a full USE_COOLDOWN_MS ahead
  serverCooldownExecuteMs   = 30,   -- executeCooldown in ServerCooldown mode
  fallbackTickDelayMs       = 400,  -- delay(400) when neither mode is on
  macroTimeoutMs            = 50,   -- macro(5) is clamped to 50 by the host
}

--------------------------------------------------------------------------- 9
-- Derivations and a self-check.  Pure functions of the data above.

function M.derive()
  for words, def in pairs(M.spells) do
    if def.mode == 'hop' or def.mode == 'star' then
      M.chain.pvpSafeRadius[words] = def.castRange + def.jumpDist * 2 + 1
    end
  end
  return M
end

-- normalise a formula the way AttackBot does: `attackData:lower():trim()`
-- (AttackBot.lua:1586) and `entry.spell:lower():trim()` (AttackBot.lua:1299).
function M.normalizeWords(s)
  if type(s) ~= 'string' then return nil end
  return (s:lower():gsub('^%s*(.-)%s*$', '%1'))
end

function M.defFor(words)
  local k = M.normalizeWords(words)
  return k and M.spells[k] or nil
end

function M.augmentedPattern(entry)
  local base = entry.pattern
  if not entry.augmented then return base end
  local words = M.normalizeWords(entry.spell)
  return (words and M.waveAugments[words]) or base
end

M.derive()

return M
