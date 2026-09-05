--[[============================================================================
bot/data/spells.lua -- the spell metadata a headless AttackBot needs.

Work item D2.  Behaviour source: docs/vbot/attackbot.md (its "VERIFIER
Corrections" section is authoritative).  Data sources, all READ-ONLY:

  modules/gamelib/spells.lua      SpellInfo['Default']  (204 distinct formulas)
                                  SpellGroups, SpellRunesData, VocationNames
  modules/gamelib/creature.lua:32 VocationsClient  (the OTHER numbering)
  src/client/const.h:1037         Otc::Vocations_t (same numbers as the above)
  vBot/AttackBot.lua:1879         AUTO_DETECT   formula -> {category, pattern}
  vBot/AttackBot.lua:1290         WAVE_AUGMENTS formula -> enlarged pattern id
  vBot/AttackBot.lua:1388         OptimizedSpells
  vBot/AttackBot.lua:241          the pattern combobox labels

The DB / AREA_BY_WORDS / RUNES tables below were MACHINE-EXTRACTED from those
files (sorted keys, one line per record, so a re-extraction diffs cleanly).
Everything else in this file is hand written.

    local spells = require('bot.data.spells')

    spells.byWords(words)                    -> entry | nil
    spells.all()                             -> the whole words->entry table
    spells.matchesVocation(words, vocClient) -> boolean
    spells.cipPairForClientVocation(id)      -> { cipA, cipB } | nil
    spells.group(words)                      -> groups{gid=ms} | nil, primaryGid
    spells.cooldown(words)                   -> spellCdMs, groups{gid=ms} | nil

------------------------------------------------------------------------------
1.  THE TWO VOCATION NUMBERINGS (they COLLIDE -- never compare them directly)
------------------------------------------------------------------------------
`player:getVocation()` returns a CLIENT vocation id (Otc::Vocations_t,
src/client/const.h:1037, mirrored in modules/gamelib/creature.lua:32):

      1 Knight   2 Paladin   3 Sorcerer   4 Druid   5 Monk      (base)
     11 Elite K 12 Royal P  13 Master S  14 Elder D 15 Exalted M (promoted)

`SpellInfo[*].vocations` uses the CIP layout (modules/gamelib/spells.lua:270):

      1 Sorcerer 2 Druid  3 Paladin  4 Knight  5 Master Sorcerer
      6 Elder D  7 Royal P 8 Elite K 9 Monk   10 Exalted Monk

so CLIENT 1 (Knight) is CIP 1 (Sorcerer): a raw `table.find(vocations, voc())`
matches every vocation to the WRONG spells.  vBot hit exactly this bug and
fixed it (AttackBot.lua:1988-2005) by going through the client's own vocation
PREDICATES instead of the number.  This module reproduces that predicate
mapping as a pure table -- `CIP_BY_CLIENT_VOCATION` -- keyed by client id,
which is the only id a headless client ever receives (0x8D / login payload).

     Knight   {4, 8}      Paladin  {3, 7}      Sorcerer {1, 5}
     Druid    {2, 6}      Monk     {9,10}

Unknown / 0 ("No Vocation") maps to nil, and `matchesVocation` then returns
TRUE for everything -- vBot's `spellMatchesVocation` does the same with a nil
cipSet ("unknown vocation: don't hide anything", AttackBot.lua:2009).

------------------------------------------------------------------------------
2.  GROUPS AND THE TWO COOLDOWN CLOCKS
------------------------------------------------------------------------------
Every spell carries `group = {[groupId] = ms}` -- USUALLY one entry, sometimes
two (Wrath of Nature is {[1]=4000, [7]=40000}).  Group ids are SpellGroups
(modules/gamelib/spells.lua:284):

      1 Attack     2 Healing   3 Support    4 Special   5 Conjure
      6 Crippling  7 Focus     8 UltimateStrikes  9 GreatBeams
     10 BurstsOfNature        11 Virtue

There are TWO independent clocks and a cast needs BOTH clear:

  * per-spell   server opcode 0xA4 SpellDelay      -> spellCooldown(spellId, delay)
                keyed by `entry.id` (a u16 when GameUshortSpell is on, and it
                is at 1530 -- proto/parser.lua:1869).  NOT by clientId.
  * per-group   server opcode 0xA5 SpellGroupDelay -> spellGroupCooldown(groupId, delay)
                keyed by the group id, shared by EVERY spell in that group.

vBot caches both in one table (AttackBot.lua:68-102):
`SpellCooldownCache[spellId]` and `SpellCooldownCache["group_"..groupId]`, each
`{exhaustion = delay, startTime = now}`, and `getRealSpellRemaining` takes the
MAXIMUM remaining across the spell entry and every one of its groups
(AttackBot.lua:113-136).  `remainingFromCache` below is that function, verbatim,
with the cache passed in instead of read from a global.

  *  GOTCHA: `entry.cooldown` (SpellInfo `exhaustion`) is a STATIC table value
     and is regularly wrong for this server -- that is exactly why vBot stopped
     using it and switched to the server-pushed delays.  Use `cooldown(words)`
     only as a fallback when the cache has no entry yet.
  *  GOTCHA: an entry's `group` is NOT "is it an attack spell".  Balanced Brawl
     (`exori mas res`, a monk AoE attack) is group 3 = Support, so it shares its
     group clock with Haste and Light, not with the other monk attacks.  Front
     Sweep, Chained Penance, Flurry of Blows, Spiritual Outburst etc. are all
     group 1 = Attack and DO share one clock.
  *  Runes have no spell entry to look up; AttackBot gates them on group 1
     alone (`getRealGroupRemaining(1)`, AttackBot.lua:2812) plus the shared
     1000 ms "use anything" lock.  `RUNES[itemId].group` below is the client's
     own per-rune group (SpellRunesData) if a finer gate is ever wanted --
     note it says group 2 for healing runes and 3 for paralyze/convince.

------------------------------------------------------------------------------
3.  RUNES vs SPELLS
------------------------------------------------------------------------------
AttackBot decides per ENTRY, not per spell: `entry.itemId > 100` makes it a
rune (AttackBot.lua:2785) and the entry's `spell` text is then ignored.  So the
authoritative rune metadata is keyed by ITEM id -> `RUNES` (36 ids, from
SpellRunesData).  On the spell side, `isRune = true` marks a CONJURE spell whose
conjured item id is known; `runeItemIds` lists them (Light Magic Missile Rune
conjures three different ids on this build).  A conjure formula is never what
AttackBot casts to attack -- it is only useful to map "avalanche rune" back to
its formula for supply/refill logic.

------------------------------------------------------------------------------
4.  AREA / PATTERN METADATA
------------------------------------------------------------------------------
`entry.area = {category, pattern, patternCategory}` is AttackBot's AUTO_DETECT
result for that formula (AttackBot.lua:1879-1911) -- the widget uses it to
pre-fill the two comboboxes, and a headless client can use it to sanity-check
or to seed an entry that the user never edited.  THE PROFILE JSON WINS: a saved
entry stores its own resolved `category`/`pattern`, and vBot never re-derives
them at runtime.

  category 1 Targeted Spell   pattern = max Chebyshev distance to target (1..10)
           2 Area Rune        pattern = grid id in spellPatterns[2]  (1..3)
           3 Targeted Rune    pattern = max distance to target (1..10)
           4 Empowerment      pattern = max distance to target (1..10)
           5 Absolute Spell   pattern = grid id in spellPatterns[4]  (1..19)
  patternCategory = category==4 and 3 or category==5 and 4 or category

`AREA_BY_WORDS` is the full AUTO_DETECT map including the one formula with no
SpellInfo entry at all (`exevo gran mas pox`), so look area up there, not only
on the spell entry.  `detectArea(words)` adds AttackBot's fallback heuristic
for formulas the map does not know.

Two traps carried over from docs/vbot/attackbot.md:
  * pattern 9 (Sweep, `exori min` Front Sweep) is a DIRECTION grid -- it goes
    through monkDirPatterns, NOT through the wave code, and its wave-side
    pattern table is empty (the original crashed on it).
  * the category-5 "isWave" gate is `pattern == 2 or pattern == 7 or
    pattern >= 9` and must NOT include pattern 6 (Large Area), which is
    self-centred.
Neither is decided here -- both live in bot/attackbot.lua -- but the pattern
ids they test are the ones in `area` / `AREA_BY_WORDS`.

`augmentedPattern` is the Wheel-of-Destiny wave augment (AttackBot.lua:1290).
It is a MANUAL per-entry toggle (`entry.augmented`): the enlarged area is
server-side only and cannot be read from the client, so nothing here infers it.
Only `exevo gran frigo hur` has one (base 10 "small wave" -> 12 "huge wave"),
and it swaps the COUNTING pattern only -- the cast words never change.

`optimizer` is the OptimizedSpells row (AttackBot.lua:1388) for the five spells
that have a hand-written targeting optimizer, each gated by its own per-profile
boolean (`flag`).  The user's real profile 1 has OptPenance / OptOutburst /
OptTFB on and OptThorns / OptGlacier off.
============================================================================]]

local spells = {}

spells.SOURCE = {
    client = 1530,
    spellInfo = "modules/gamelib/spells.lua SpellInfo['Default']",
    attackBot = "profiles/bot/vBot_4.8/vBot/AttackBot.lua",
}

-- ---------------------------------------------------------------------------
-- vocations
-- ---------------------------------------------------------------------------

--- Otc::Vocations_t / VocationsClient -- what player:getVocation() returns.
spells.VOCATION_CLIENT = {
    [0] = 'No Vocation',
    [1] = 'Knight', [2] = 'Paladin', [3] = 'Sorcerer', [4] = 'Druid', [5] = 'Monk',
    [11] = 'Elite Knight', [12] = 'Royal Paladin', [13] = 'Master Sorcerer',
    [14] = 'Elder Druid', [15] = 'Exalted Monk',
}

--- VocationNames -- what SpellInfo[*].vocations contains.
spells.VOCATION_CIP = {
    [0] = 'None',
    [1] = 'Sorcerer', [2] = 'Druid', [3] = 'Paladin', [4] = 'Knight',
    [5] = 'Master Sorcerer', [6] = 'Elder Druid', [7] = 'Royal Paladin',
    [8] = 'Elite Knight', [9] = 'Monk', [10] = 'Exalted Monk',
}

--- CLIENT vocation id -> the CIP pair SpellInfo uses.  This IS the documented
--- predicate mapping (isKnight/isPaladin/isSorcerer/isDruid/isMonk), flattened.
--- Base and promoted ids map to the SAME pair, exactly like the predicates.
spells.CIP_BY_CLIENT_VOCATION = {
    [1]  = { 4, 8 },  [11] = { 4, 8 },   -- Knight   / Elite Knight
    [2]  = { 3, 7 },  [12] = { 3, 7 },   -- Paladin  / Royal Paladin
    [3]  = { 1, 5 },  [13] = { 1, 5 },   -- Sorcerer / Master Sorcerer
    [4]  = { 2, 6 },  [14] = { 2, 6 },   -- Druid    / Elder Druid
    [5]  = { 9, 10 }, [15] = { 9, 10 },  -- Monk     / Exalted Monk
}

-- ---------------------------------------------------------------------------
-- groups
-- ---------------------------------------------------------------------------

spells.GROUPS = {
    [1] = 'Attack', [2] = 'Healing', [3] = 'Support', [4] = 'Special',
    [5] = 'Conjure', [6] = 'Crippling', [7] = 'Focus', [8] = 'UltimateStrikes',
    [9] = 'GreatBeams', [10] = 'BurstsOfNature', [11] = 'Virtue',
}

spells.GROUP_ATTACK  = 1
spells.GROUP_HEALING = 2
spells.GROUP_SUPPORT = 3

--- Group 11 "Virtue" is the stance clock: a toggled spell the server keeps
--- active on the player (Spells.StanceSpellIds, modules/gamelib/spells.lua:347).
--- The three MONK virtues are the ones the 0xC1 MonkData virtue payload names,
--- and they share a 30 s group-11 cooldown with each other -- so a monk profile
--- that swaps virtue mid-fight is gated by group 11, not by group 3.  Nothing
--- in AttackBot casts these; they are here so a caller can recognise them.
spells.STANCE_SPELL_IDS = {
    [132] = true, [133] = true,                 -- Protector / Blood Rage (EK)
    [274] = true, [275] = true, [276] = true,   -- Virtue of Harmony/Justice/Sustain (Monk)
    [304] = true, [305] = true, [306] = true,   -- Master of Flames/Thunder/Decay (Sorcerer)
    [309] = true,                               -- Shared Conservation (Druid)
    [311] = true, [312] = true,                 -- Aura of Sapped Strength / Exposed Weakness
    [313] = true, [314] = true,                 -- Sharpshooter / Divine Defiance (RP)
    [319] = true,                               -- Elemental Synthesis (Druid)
}

--- MonkData TYPES_MONK_VIRTUE state -> stance spell id.
spells.VIRTUE_STATE_TO_SPELL_ID = { [1] = 274, [2] = 275, [3] = 276 }

-- ---------------------------------------------------------------------------
-- pattern combobox labels (AttackBot.lua:241) -- indexed by patternCategory
-- ---------------------------------------------------------------------------

spells.PATTERN_LABELS = {
    -- [1] targeted spell / [3] empowerment+targeted rune: plain sqm ranges 1..10
    [4] = {
        'Adjacent', '3x3 Wave', 'Small Area', 'Medium Area', 'Ulus Area',
        'Large Area', 'Short Beam', 'Large Beam', 'Sweep', 'Small Wave',
        'Big Wave', 'Huge Wave', 'Flurry of Blows', 'Greater Flurry',
        'Thousand Fist Blows', 'Sweeping Takedown', 'Spiritual Outburst',
        'Chained Penance', 'Balanced Brawl',
    },
    [2] = { 'Cross (explosion)', 'Bomb (fire bomb)', 'Ball (gfb, avalanche)' },
}
--- how far AUTO_DETECT clamps a derived pattern (AttackBot.lua:1953).
spells.PATTERN_COUNT = { [1] = 10, [2] = 3, [3] = 10, [4] = 19 }

-- ---------------------------------------------------------------------------
-- MACHINE-EXTRACTED: SpellInfo["Default"] + AttackBot AUTO_DETECT / WAVE_AUGMENTS
-- / OptimizedSpells, one line per formula, keys sorted.
-- ---------------------------------------------------------------------------

spells.DB = {
  ["adana ani"] = { name="Paralyze Rune", id=54, clientId=70, type="Conjure", level=54, mana=1400, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, isRune=true, runeItemIds={3165} },
  ["adana mort"] = { name="Animate Dead Rune", id=83, clientId=92, type="Conjure", level=27, mana=600, soul=5, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,2,5,6}, isRune=true, runeItemIds={3203} },
  ["adana pox"] = { name="Cure Poison Rune", id=31, clientId=88, type="Conjure", level=15, mana=200, soul=1, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={2,6}, isRune=true, runeItemIds={3153} },
  ["adeta sio"] = { name="Convince Creature Rune", id=12, clientId=89, type="Conjure", level=16, mana=200, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={2,6}, isRune=true, runeItemIds={3177} },
  ["adevo grav flam"] = { name="Fire Field Rune", id=25, clientId=80, type="Conjure", level=15, mana=240, soul=1, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3188} },
  ["adevo grav pox"] = { name="Poison Field Rune", id=26, clientId=68, type="Conjure", level=14, mana=200, soul=1, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3172} },
  ["adevo grav tera"] = { name="Magic Wall Rune", id=86, clientId=71, type="Conjure", level=32, mana=750, soul=5, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,5}, isRune=true, runeItemIds={3180} },
  ["adevo grav vis"] = { name="Energy Field Rune", id=27, clientId=84, type="Conjure", level=18, mana=320, soul=2, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3164} },
  ["adevo grav vita"] = { name="Wild Growth Rune", id=94, clientId=60, type="Conjure", level=27, mana=600, soul=5, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, isRune=true, runeItemIds={3156} },
  ["adevo ina"] = { name="Chameleon Rune", id=14, clientId=90, type="Conjure", level=27, mana=600, soul=2, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={2,6}, isRune=true, runeItemIds={3178} },
  ["adevo mas flam"] = { name="Fire Bomb Rune", id=17, clientId=81, type="Conjure", level=27, mana=600, soul=4, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3192} },
  ["adevo mas grav flam"] = { name="Fire Wall Rune", id=28, clientId=79, type="Conjure", level=33, mana=780, soul=4, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3190} },
  ["adevo mas grav pox"] = { name="Poison Wall Rune", id=32, clientId=67, type="Conjure", level=29, mana=640, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3176} },
  ["adevo mas grav vis"] = { name="Energy Wall Rune", id=33, clientId=83, type="Conjure", level=41, mana=1000, soul=5, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3166} },
  ["adevo mas hur"] = { name="Explosion Rune", id=18, clientId=82, type="Conjure", level=31, mana=570, soul=4, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3200} },
  ["adevo mas pox"] = { name="Poison Bomb Rune", id=91, clientId=69, type="Conjure", level=25, mana=520, soul=2, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, isRune=true, runeItemIds={3173} },
  ["adevo mas vis"] = { name="Energy Bomb Rune", id=55, clientId=85, type="Conjure", level=37, mana=880, soul=5, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,5}, isRune=true, runeItemIds={3149} },
  ["adevo res flam"] = { name="Soulfire Rune", id=50, clientId=66, type="Conjure", level=27, mana=420, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,2,5,6}, isRune=true, runeItemIds={3195} },
  ["adito grav"] = { name="Destroy Field Rune", id=30, clientId=86, type="Conjure", level=17, mana=120, soul=2, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,3,5,6,7}, isRune=true, runeItemIds={3148} },
  ["adito tera"] = { name="Disintegrate Rune", id=78, clientId=87, type="Conjure", level=21, mana=200, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,2,3,5,6,7}, isRune=true, runeItemIds={3197} },
  ["adori dis min vis"] = { name="Lightest Magic Missile", id=0, clientId=129, type="Conjure", level=1, mana=5, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={0} },
  ["adori flam"] = { name="Fireball Rune", id=15, clientId=78, type="Conjure", level=27, mana=460, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,5}, isRune=true, runeItemIds={3189} },
  ["adori frigo"] = { name="Icicle Rune", id=114, clientId=74, type="Conjure", level=28, mana=460, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, isRune=true, runeItemIds={3158} },
  ["adori gran mort"] = { name="Sudden Death Rune", id=21, clientId=63, type="Conjure", level=45, mana=985, soul=5, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,5}, isRune=true, runeItemIds={3155} },
  ["adori mas flam"] = { name="Great Fireball Rune", id=16, clientId=77, type="Conjure", level=30, mana=530, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,5}, isRune=true, runeItemIds={3191} },
  ["adori mas frigo"] = { name="Avalanche Rune", id=115, clientId=91, type="Conjure", level=30, mana=530, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={2,6}, isRune=true, runeItemIds={3161} },
  ["adori mas tera"] = { name="Stone Shower Rune", id=116, clientId=64, type="Conjure", level=28, mana=430, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, isRune=true, runeItemIds={3175,21351} },
  ["adori mas vis"] = { name="Thunderstorm Rune", id=117, clientId=62, type="Conjure", level=28, mana=430, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,5}, isRune=true, runeItemIds={3202} },
  ["adori min vis"] = { name="Light Magic Missile Rune", id=7, clientId=72, type="Conjure", level=15, mana=120, soul=1, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3174,17512,21352} },
  ["adori san"] = { name="Holy Missile Rune", id=130, clientId=75, type="Conjure", level=27, mana=300, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7}, isRune=true, runeItemIds={3182} },
  ["adori tera"] = { name="Stalagmite Rune", id=77, clientId=65, type="Conjure", level=24, mana=350, soul=2, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3179} },
  ["adori vis"] = { name="Heavy Magic Missile Rune", id=8, clientId=76, type="Conjure", level=25, mana=350, soul=2, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6}, isRune=true, runeItemIds={3198} },
  ["adura gran"] = { name="Intense Healing Rune", id=4, clientId=73, type="Conjure", level=15, mana=120, soul=2, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={2,6}, isRune=true, runeItemIds={3152} },
  ["adura vita"] = { name="Ultimate Healing Rune", id=5, clientId=61, type="Conjure", level=24, mana=400, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={2,6}, isRune=true, runeItemIds={3160} },
  ["exana amp res"] = { name="Divine Dazzle", id=238, clientId=138, type="Instant", level=250, mana=80, soul=0, maglevel=0, cooldown=16000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["exana flam"] = { name="Cure Burning", id=145, clientId=12, type="Instant", level=30, mana=30, soul=0, maglevel=0, cooldown=6000, group={ [2]=1000 }, needTarget=false, range=-1, premium=true, vocations={2,6} },
  ["exana ina"] = { name="Cancel Invisibility", id=90, clientId=94, type="Instant", level=26, mana=200, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["exana kor"] = { name="Cure Bleeding", id=144, clientId=11, type="Instant", level=45, mana=30, soul=0, maglevel=0, cooldown=6000, group={ [2]=1000 }, needTarget=false, range=-1, premium=true, vocations={2,4,6,8} },
  ["exana mort"] = { name="Cure Curse", id=147, clientId=10, type="Instant", level=80, mana=40, soul=0, maglevel=0, cooldown=6000, group={ [2]=1000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["exana pox"] = { name="Cure Poison", id=29, clientId=9, type="Instant", level=10, mana=30, soul=0, maglevel=0, cooldown=6000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={1,2,3,4,5,6,7,8,9,10} },
  ["exana vis"] = { name="Cure Electrification", id=146, clientId=13, type="Instant", level=22, mana=30, soul=0, maglevel=0, cooldown=6000, group={ [2]=1000 }, needTarget=false, range=-1, premium=true, vocations={2,6} },
  ["exana vita"] = { name="Cancel Magic Shield", id=245, clientId=146, type="Instant", level=14, mana=50, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6} },
  ["exani hur"] = { name="Levitate", id=81, clientId=124, type="Instant", level=12, mana=50, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,2,3,4,5,6,7,8,9,10} },
  ["exani tera"] = { name="Magic Rope", id=76, clientId=104, type="Instant", level=9, mana=20, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,2,3,4,5,6,7,8,9,10} },
  ["exeta amp res"] = { name="Chivalrous Challenge", id=237, clientId=111, type="Instant", level=150, mana=80, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={4,8} },
  ["exeta con"] = { name="Enchant Spear", id=110, clientId=103, type="Conjure", level=45, mana=350, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["exeta res"] = { name="Challenge", id=93, clientId=96, type="Instant", level=20, mana=30, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={8} },
  ["exeta vis"] = { name="Enchant Staff", id=92, clientId=141, type="Conjure", level=41, mana=80, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={5} },
  ["exevo con"] = { name="Conjure Arrow", id=51, clientId=105, type="Conjure", level=13, mana=100, soul=1, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={3,7} },
  ["exevo con flam"] = { name="Conjure Explosive Arrow", id=49, clientId=108, type="Conjure", level=25, mana=290, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={3,7} },
  ["exevo con grav"] = { name="Conjure Piercing Bolt", id=109, clientId=48, type="Conjure", level=33, mana=180, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["exevo con hur"] = { name="Conjure Sniper Arrow", id=108, clientId=240, type="Conjure", level=24, mana=160, soul=3, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["exevo con mort"] = { name="Conjure Bolt", id=79, clientId=79, type="Conjure", level=17, mana=140, soul=2, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["exevo con pox"] = { name="Conjure Poisoned Arrow", id=48, clientId=48, type="Conjure", level=16, mana=130, soul=2, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={3,7} },
  ["exevo con vis"] = { name="Conjure Power Bolt", id=95, clientId=89, type="Conjure", level=59, mana=700, soul=4, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={7} },
  ["exevo dis flam hur"] = { name="Practise Fire Wave", id=167, clientId=128, type="Instant", level=1, mana=5, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=false, vocations={0} },
  ["exevo flam hur"] = { name="Fire Wave", id=19, clientId=43, type="Instant", level=18, mana=25, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,5}, area={ category=5, pattern=11, patternCategory=4 } },
  ["exevo frigo hur"] = { name="Ice Wave", id=121, clientId=44, type="Instant", level=18, mana=25, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=false, vocations={2,6}, area={ category=5, pattern=11, patternCategory=4 } },
  ["exevo fur frigo"] = { name="Forked Glacier", id=317, clientId=200, type="Instant", level=90, mana=180, soul=0, maglevel=0, cooldown=6000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, area={ category=1, pattern=4, patternCategory=1 }, optimizer={ castRange=4, flag="OptGlacier", jumpDist=4, jumps=6, mode="star" } },
  ["exevo fur tera"] = { name="Forked Thorns", id=318, clientId=201, type="Instant", level=80, mana=180, soul=0, maglevel=0, cooldown=6000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, area={ category=1, pattern=4, patternCategory=1 }, optimizer={ castRange=4, flag="OptThorns", jumpDist=4, jumps=5, mode="star" } },
  ["exevo gran con grav"] = { name="Conjure Royal Star", id=191, clientId=191, type="Conjure", level=150, mana=1000, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["exevo gran flam hur"] = { name="Great Fire Wave", id=240, clientId=102, type="Instant", level=38, mana=120, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,5}, area={ category=5, pattern=12, patternCategory=4 } },
  ["exevo gran frigo hur"] = { name="Strong Ice Wave", id=43, clientId=45, type="Instant", level=40, mana=170, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=false, range=-1, premium=false, vocations={2,6}, area={ category=5, pattern=10, patternCategory=4 }, augmentedPattern=12 },
  ["exevo gran mas flam"] = { name="Hell's Core", id=24, clientId=48, type="Instant", level=60, mana=1100, soul=0, maglevel=0, cooldown=40000, group={ [1]=4000 }, needTarget=false, range=-1, premium=true, vocations={1,5}, area={ category=5, pattern=6, patternCategory=4 } },
  ["exevo gran mas frigo"] = { name="Eternal Winter", id=118, clientId=49, type="Instant", level=60, mana=1150, soul=0, maglevel=0, cooldown=20000, group={ [1]=4000, [7]=20000 }, needTarget=false, range=5, premium=false, vocations={2,6}, area={ category=5, pattern=6, patternCategory=4 } },
  ["exevo gran mas tera"] = { name="Wrath of Nature", id=56, clientId=47, type="Instant", level=55, mana=700, soul=0, maglevel=0, cooldown=40000, group={ [1]=4000, [7]=40000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, area={ category=5, pattern=6, patternCategory=4 } },
  ["exevo gran mas vis"] = { name="Rage of the Skies", id=119, clientId=51, type="Instant", level=55, mana=600, soul=0, maglevel=0, cooldown=40000, group={ [1]=4000 }, needTarget=false, range=-1, premium=true, vocations={1,5}, area={ category=5, pattern=6, patternCategory=4 } },
  ["exevo gran mort"] = { name="Conjure Wand of Darkness", id=92, clientId=141, type="Conjure", level=41, mana=250, soul=0, maglevel=0, cooldown=1800000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,5} },
  ["exevo gran vis lux"] = { name="Great Energy Beam", id=23, clientId=41, type="Instant", level=29, mana=110, soul=0, maglevel=0, cooldown=6000, group={ [1]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,5}, area={ category=5, pattern=8, patternCategory=4 } },
  ["exevo infir con"] = { name="Arrow Call", id=176, clientId=137, type="Conjure", level=1, mana=10, soul=1, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={3,7} },
  ["exevo infir flam hur"] = { name="Scorch", id=178, clientId=131, type="Instant", level=1, mana=8, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,5} },
  ["exevo infir frigo hur"] = { name="Chill Out", id=173, clientId=135, type="Instant", level=1, mana=8, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=1, premium=false, vocations={2,6} },
  ["exevo mas san"] = { name="Divine Caldera", id=124, clientId=39, type="Instant", level=50, mana=160, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7}, area={ category=5, pattern=3, patternCategory=4 } },
  ["exevo max mort"] = { name="Great Death Beam", id=260, clientId=157, type="Instant", level=300, mana=140, soul=0, maglevel=0, cooldown=10000, group={ [1]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,5} },
  ["exevo mort ora"] = { name="Death Echo", id=310, clientId=195, type="Instant", level=120, mana=150, soul=0, maglevel=0, cooldown=6000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,5} },
  ["exevo pan"] = { name="Food", id=42, clientId=98, type="Instant", level=14, mana=120, soul=1, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={2,6} },
  ["exevo tempo mas san"] = { name="Divine Grenade", id=258, clientId=155, type="Instant", level=300, mana=160, soul=0, maglevel=0, cooldown=1000, group={ [1]=2000 }, needTarget=true, range=7, premium=true, vocations={3,7} },
  ["exevo tera hur"] = { name="Terra Wave", id=120, clientId=46, type="Instant", level=38, mana=170, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, area={ category=5, pattern=2, patternCategory=4 } },
  ["exevo ulus frigo"] = { name="Ice Burst", id=262, clientId=153, type="Instant", level=300, mana=230, soul=0, maglevel=0, cooldown=22000, group={ [1]=2000, [10]=22000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, area={ category=5, pattern=5, patternCategory=4 } },
  ["exevo ulus tera"] = { name="Terra Burst", id=263, clientId=154, type="Instant", level=300, mana=230, soul=0, maglevel=0, cooldown=22000, group={ [1]=2000, [10]=22000 }, needTarget=false, range=-1, premium=true, vocations={2,6}, area={ category=5, pattern=5, patternCategory=4 } },
  ["exevo vis hur"] = { name="Energy Wave", id=13, clientId=42, type="Instant", level=38, mana=170, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,5}, area={ category=5, pattern=2, patternCategory=4 } },
  ["exevo vis lux"] = { name="Energy Beam", id=22, clientId=40, type="Instant", level=23, mana=40, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,5}, area={ category=5, pattern=7, patternCategory=4 } },
  ["exiva"] = { name="Find Person", id=20, clientId=113, type="Instant", level=8, mana=20, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,3,4,5,6,7,8,9,10} },
  ["exori"] = { name="Berserk", id=80, clientId=20, type="Instant", level=35, mana=115, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={4,8}, area={ category=5, pattern=1, patternCategory=4 } },
  ["exori amp kor"] = { name="Executioner's Throw", id=261, clientId=152, type="Instant", level=300, mana=225, soul=0, maglevel=0, cooldown=18000, group={ [1]=2000 }, needTarget=true, range=5, premium=true, vocations={4,8} },
  ["exori amp pug"] = { name="Mystic Repulse", id=290, clientId=178, type="Instant", level=30, mana=150, soul=0, maglevel=0, cooldown=14000, group={ [1]=2000 }, needTarget=true, range=7, premium=true, vocations={9,10} },
  ["exori amp vis"] = { name="Lightning", id=149, clientId=50, type="Instant", level=55, mana=60, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=false, range=4, premium=true, vocations={1,5} },
  ["exori con"] = { name="Ethereal Spear", id=111, clientId=17, type="Instant", level=23, mana=25, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=true, range=7, premium=true, vocations={3,7}, area={ category=1, pattern=7, patternCategory=1 } },
  ["exori dir moe"] = { name="Ethereal Barrage", id=303, clientId=189, type="Instant", level=60, mana=135, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=true, range=-1, premium=true, vocations={3,7} },
  ["exori dir san"] = { name="Divine Barrage", id=302, clientId=188, type="Instant", level=70, mana=175, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=true, range=-1, premium=true, vocations={3,7} },
  ["exori flam"] = { name="Flame Strike", id=89, clientId=25, type="Instant", level=14, mana=20, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={1,2,5,6}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori frigo"] = { name="Ice Strike", id=112, clientId=31, type="Instant", level=15, mana=20, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={1,2,5,6}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori gran"] = { name="Fierce Berserk", id=105, clientId=21, type="Instant", level=90, mana=340, soul=0, maglevel=0, cooldown=6000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={4,8}, area={ category=5, pattern=1, patternCategory=4 } },
  ["exori gran con"] = { name="Strong Ethereal Spear", id=57, clientId=58, type="Instant", level=90, mana=55, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=true, range=7, premium=true, vocations={3,7} },
  ["exori gran flam"] = { name="Strong Flame Strike", id=150, clientId=26, type="Instant", level=70, mana=60, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={1,5}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori gran frigo"] = { name="Strong Ice Strike", id=152, clientId=32, type="Instant", level=80, mana=60, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={2,6}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori gran ico"] = { name="Annihilation", id=62, clientId=23, type="Instant", level=110, mana=300, soul=0, maglevel=0, cooldown=30000, group={ [1]=2000 }, needTarget=true, range=1, premium=true, vocations={4,8}, area={ category=1, pattern=1, patternCategory=1 } },
  ["exori gran mas nia"] = { name="Spiritual Outburst", id=295, clientId=183, type="Instant", level=300, mana=425, soul=0, maglevel=0, cooldown=60000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={9,10}, area={ category=5, pattern=17, patternCategory=4 }, optimizer={ castRange=3, flag="OptOutburst", jumpDist=2, jumps=7, mode="hop" } },
  ["exori gran mas pug"] = { name="Greater Flurry of Blows", id=289, clientId=177, type="Instant", level=90, mana=300, soul=0, maglevel=0, cooldown=10000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={9,10}, area={ category=5, pattern=14, patternCategory=4 } },
  ["exori gran nia"] = { name="Devastating Knockout", id=293, clientId=181, type="Instant", level=125, mana=210, soul=0, maglevel=0, cooldown=24000, group={ [1]=2000 }, needTarget=true, range=1, premium=true, vocations={9,10} },
  ["exori gran pug"] = { name="Forceful Uppercut", id=286, clientId=174, type="Instant", level=110, mana=325, soul=0, maglevel=0, cooldown=40000, group={ [1]=2000 }, needTarget=true, range=1, premium=true, vocations={9,10} },
  ["exori gran tera"] = { name="Strong Terra Strike", id=153, clientId=35, type="Instant", level=70, mana=60, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={2,6}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori gran vis"] = { name="Strong Energy Strike", id=151, clientId=29, type="Instant", level=80, mana=60, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={1,5}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori hur"] = { name="Whirlwind Throw", id=107, clientId=18, type="Instant", level=28, mana=40, soul=0, maglevel=0, cooldown=6000, group={ [1]=2000 }, needTarget=true, range=5, premium=true, vocations={4,8}, area={ category=1, pattern=5, patternCategory=1 } },
  ["exori ico"] = { name="Brutal Strike", id=61, clientId=22, type="Instant", level=16, mana=30, soul=0, maglevel=0, cooldown=6000, group={ [1]=2000 }, needTarget=true, range=1, premium=false, vocations={4,8}, area={ category=1, pattern=1, patternCategory=1 } },
  ["exori ico scu"] = { name="Shield Bash", id=315, clientId=198, type="Instant", level=18, mana=30, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={4,8} },
  ["exori infir amp pug"] = { name="Lesser Mystic Repulse", id=300, clientId=186, type="Instant", level=6, mana=30, soul=0, maglevel=0, cooldown=20000, group={ [1]=2000 }, needTarget=true, range=-1, premium=true, vocations={9,10} },
  ["exori infir nia"] = { name="Tiger Clash", id=291, clientId=179, type="Instant", level=1, mana=18, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=true, range=1, premium=false, vocations={9,10} },
  ["exori infir pug"] = { name="Swift Jab", id=284, clientId=172, type="Instant", level=1, mana=3, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=true, range=1, premium=false, vocations={9,10} },
  ["exori infir tera"] = { name="Mud Attack", id=174, clientId=136, type="Instant", level=1, mana=6, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=false, range=3, premium=false, vocations={2,6} },
  ["exori infir vis"] = { name="Buzz", id=177, clientId=132, type="Instant", level=1, mana=6, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=false, range=3, premium=false, vocations={1,5} },
  ["exori kor"] = { name="Sap Strength", id=244, clientId=110, type="Instant", level=275, mana=300, soul=0, maglevel=0, cooldown=12000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,5} },
  ["exori kor tempo"] = { name="Aura of Exposed Weakness", id=312, clientId=202, type="Instant", level=20, mana=1500, soul=0, maglevel=0, cooldown=30000, group={ [3]=2000, [6]=30000 }, needTarget=false, range=-1, premium=true, vocations={1,5} },
  ["exori mas"] = { name="Groundshaker", id=106, clientId=24, type="Instant", level=33, mana=160, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={4,8}, area={ category=5, pattern=3, patternCategory=4 } },
  ["exori mas amp pug"] = { name="Thousand Fist Blows", id=301, clientId=187, type="Instant", level=120, mana=145, soul=0, maglevel=0, cooldown=12000, group={ [1]=2000 }, needTarget=true, range=-1, premium=true, vocations={9,10}, area={ category=5, pattern=15, patternCategory=4 }, optimizer={ castRange=5, flag="OptTFB", mode="tile" } },
  ["exori mas nia"] = { name="Sweeping Takedown", id=294, clientId=182, type="Instant", level=60, mana=195, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={9,10}, area={ category=5, pattern=16, patternCategory=4 } },
  ["exori mas pug"] = { name="Flurry of Blows", id=287, clientId=175, type="Instant", level=35, mana=110, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={9,10}, area={ category=5, pattern=13, patternCategory=4 } },
  ["exori mas res"] = { name="Balanced Brawl", id=280, clientId=168, type="Instant", level=175, mana=80, soul=0, maglevel=0, cooldown=10000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={9,10}, area={ category=5, pattern=19, patternCategory=4 } },
  ["exori max flam"] = { name="Ultimate Flame Strike", id=154, clientId=27, type="Instant", level=90, mana=100, soul=0, maglevel=0, cooldown=30000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={1,5}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori max frigo"] = { name="Ultimate Ice Strike", id=156, clientId=33, type="Instant", level=100, mana=100, soul=0, maglevel=0, cooldown=30000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={2,6}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori max tera"] = { name="Ultimate Terra Strike", id=157, clientId=36, type="Instant", level=90, mana=100, soul=0, maglevel=0, cooldown=30000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={2,6}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori max vis"] = { name="Ultimate Energy Strike", id=155, clientId=30, type="Instant", level=100, mana=100, soul=0, maglevel=0, cooldown=30000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={1,5}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori med pug"] = { name="Chained Penance", id=288, clientId=176, type="Instant", level=70, mana=180, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={9,10}, area={ category=5, pattern=18, patternCategory=4 }, optimizer={ castRange=3, flag="OptPenance", jumpDist=2, jumps=4, mode="hop" } },
  ["exori min"] = { name="Front Sweep", id=59, clientId=19, type="Instant", level=70, mana=200, soul=0, maglevel=0, cooldown=6000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={4,8}, area={ category=5, pattern=9, patternCategory=4 } },
  ["exori min flam"] = { name="Apprentice's Strike", id=169, clientId=126, type="Instant", level=8, mana=6, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=false, range=3, premium=false, vocations={1,2,5,6} },
  ["exori moe"] = { name="Expose Weakness", id=243, clientId=109, type="Instant", level=275, mana=400, soul=0, maglevel=0, cooldown=12000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,5} },
  ["exori moe ico"] = { name="Physical Strike", id=148, clientId=16, type="Instant", level=16, mana=20, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={2,6}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori moe tempo"] = { name="Aura of Sapped Strength", id=311, clientId=203, type="Instant", level=20, mana=1500, soul=0, maglevel=0, cooldown=30000, group={ [3]=2000, [6]=30000 }, needTarget=false, range=-1, premium=true, vocations={1,5} },
  ["exori mort"] = { name="Death Strike", id=87, clientId=37, type="Instant", level=16, mana=20, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={1,5}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori nia"] = { name="Greater Tiger Clash", id=292, clientId=180, type="Instant", level=18, mana=50, soul=0, maglevel=0, cooldown=8000, group={ [1]=2000 }, needTarget=true, range=1, premium=true, vocations={9,10} },
  ["exori pug"] = { name="Double Jab", id=285, clientId=173, type="Instant", level=14, mana=30, soul=0, maglevel=0, cooldown=4000, group={ [1]=2000 }, needTarget=true, range=1, premium=false, vocations={9,10}, area={ category=1, pattern=1, patternCategory=1 } },
  ["exori san"] = { name="Divine Missile", id=122, clientId=38, type="Instant", level=40, mana=20, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=false, range=4, premium=true, vocations={3,7}, area={ category=1, pattern=4, patternCategory=1 } },
  ["exori scu"] = { name="Shield Slam", id=316, clientId=199, type="Instant", level=30, mana=90, soul=0, maglevel=0, cooldown=6000, group={ [1]=2000 }, needTarget=false, range=-1, premium=true, vocations={4,8} },
  ["exori tera"] = { name="Terra Strike", id=113, clientId=34, type="Instant", level=13, mana=20, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=false, range=3, premium=false, vocations={1,2,5,6}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exori vis"] = { name="Energy Strike", id=88, clientId=28, type="Instant", level=12, mana=20, soul=0, maglevel=0, cooldown=2000, group={ [1]=2000 }, needTarget=false, range=3, premium=true, vocations={1,2,5,6}, area={ category=1, pattern=3, patternCategory=1 } },
  ["exura"] = { name="Light Healing", id=1, clientId=5, type="Instant", level=8, mana=20, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={1,2,3,5,6,7,9,10} },
  ["exura dis"] = { name="Practice Healing", id=166, clientId=127, type="Instant", level=1, mana=5, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={0} },
  ["exura gran"] = { name="Intense Healing", id=2, clientId=6, type="Instant", level=20, mana=70, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={1,2,3,5,6,7,9,10} },
  ["exura gran ico"] = { name="Intense Wound Cleansing", id=158, clientId=3, type="Instant", level=80, mana=200, soul=0, maglevel=0, cooldown=600000, group={ [2]=1000 }, needTarget=false, range=-1, premium=true, vocations={4,8} },
  ["exura gran mas res"] = { name="Mass Healing", id=82, clientId=8, type="Instant", level=36, mana=150, soul=0, maglevel=0, cooldown=2000, group={ [2]=1000 }, needTarget=false, range=-1, premium=true, vocations={2,6} },
  ["exura gran san"] = { name="Salvation", id=36, clientId=59, type="Instant", level=60, mana=210, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["exura gran sio"] = { name="Nature's Embrace", id=242, clientId=106, type="Instant", level=300, mana=400, soul=0, maglevel=0, cooldown=60000, group={ [2]=1000 }, needTarget=true, range=-1, premium=true, vocations={2,6} },
  ["exura gran tio"] = { name="Spirit Mend", id=273, clientId=161, type="Instant", level=80, mana=210, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=true, vocations={9,10} },
  ["exura ico"] = { name="Wound Cleansing", id=123, clientId=2, type="Instant", level=8, mana=40, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={4,8} },
  ["exura infir"] = { name="Magic Patch", id=174, clientId=133, type="Instant", level=1, mana=6, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={1,2,3,5,6,7,9,10} },
  ["exura infir ico"] = { name="Bruise Bane", id=170, clientId=134, type="Instant", level=1, mana=10, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={4,8} },
  ["exura mas nia"] = { name="Mass Spirit Mend", id=296, clientId=184, type="Instant", level=150, mana=250, soul=0, maglevel=0, cooldown=8000, group={ [2]=2000 }, needTarget=false, range=-1, premium=true, vocations={9,10} },
  ["exura max vita"] = { name="Restoration", id=241, clientId=107, type="Instant", level=300, mana=260, soul=0, maglevel=0, cooldown=6000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6} },
  ["exura med ico"] = { name="Fair Wound Cleansing", id=239, clientId=4, type="Instant", level=300, mana=90, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=true, vocations={4,8} },
  ["exura san"] = { name="Divine Healing", id=125, clientId=1, type="Instant", level=35, mana=160, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={3,7} },
  ["exura sio"] = { name="Heal Friend", id=84, clientId=7, type="Instant", level=18, mana=120, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=true, range=-1, premium=true, vocations={2,6} },
  ["exura tio sio"] = { name="Restore Balance", id=297, clientId=185, type="Instant", level=18, mana=120, soul=0, maglevel=0, cooldown=2000, group={ [2]=1000 }, needTarget=true, range=-1, premium=true, vocations={9,10} },
  ["exura vita"] = { name="Ultimate Healing", id=3, clientId=3, type="Instant", level=30, mana=160, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6} },
  ["utamo mas sio"] = { name="Protect Party", id=127, clientId=122, type="Instant", level=32, mana=90, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["utamo tempo"] = { name="Protector", id=132, clientId=121, type="Instant", level=55, mana=200, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000, [11]=30000 }, needTarget=false, range=-1, premium=true, vocations={4,8} },
  ["utamo tempo san"] = { name="Swift Foot", id=134, clientId=118, type="Instant", level=55, mana=400, soul=0, maglevel=0, cooldown=10000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["utamo tio"] = { name="Focus Serenity", id=281, clientId=169, type="Instant", level=150, mana=500, soul=0, maglevel=0, cooldown=600000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={9,10} },
  ["utamo vita"] = { name="Magic Shield", id=44, clientId=123, type="Instant", level=14, mana=50, soul=0, maglevel=0, cooldown=14000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6} },
  ["utana vid"] = { name="Invisibility", id=45, clientId=93, type="Instant", level=35, mana=440, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6} },
  ["utani gran hur"] = { name="Strong Haste", id=39, clientId=101, type="Instant", level=20, mana=100, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,2,5,6,9,10} },
  ["utani hur"] = { name="Haste", id=6, clientId=100, type="Instant", level=14, mana=60, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,2,3,4,5,6,7,8,9,10} },
  ["utani tempo hur"] = { name="Charge", id=131, clientId=97, type="Instant", level=25, mana=100, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={4,8} },
  ["uteta flam"] = { name="Master of Flames", id=304, clientId=190, type="Instant", level=20, mana=400, soul=0, maglevel=0, cooldown=30000, group={ [3]=2000, [11]=30000 }, needTarget=false, range=-1, premium=true, vocations={1,5} },
  ["uteta mort"] = { name="Master of Decay", id=306, clientId=192, type="Instant", level=20, mana=400, soul=0, maglevel=0, cooldown=30000, group={ [3]=2000, [11]=30000 }, needTarget=false, range=-1, premium=true, vocations={1,5} },
  ["uteta res dru"] = { name="Avatar of Nature", id=267, clientId=149, type="Instant", level=300, mana=2200, soul=0, maglevel=0, cooldown=7200000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={2,6} },
  ["uteta res eq"] = { name="Avatar of Steel", id=264, clientId=148, type="Instant", level=300, mana=800, soul=0, maglevel=0, cooldown=7200000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={4,8} },
  ["uteta res sac"] = { name="Avatar of Light", id=265, clientId=150, type="Instant", level=300, mana=1500, soul=0, maglevel=0, cooldown=7200000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={3,7} },
  ["uteta res tio"] = { name="Avatar of Balance", id=283, clientId=171, type="Instant", level=300, mana=1200, soul=0, maglevel=0, cooldown=7200000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={9,10} },
  ["uteta res ven"] = { name="Avatar of Storm", id=266, clientId=151, type="Instant", level=300, mana=2200, soul=0, maglevel=0, cooldown=7200000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,5} },
  ["uteta tio"] = { name="Mentor Other", id=277, clientId=165, type="Instant", level=150, mana=110, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=true, range=-1, premium=false, vocations={9,10} },
  ["uteta vis"] = { name="Master of Thunder", id=305, clientId=191, type="Instant", level=20, mana=400, soul=0, maglevel=0, cooldown=30000, group={ [3]=2000, [11]=30000 }, needTarget=false, range=-1, premium=true, vocations={1,5} },
  ["utevo gran lux"] = { name="Great Light", id=11, clientId=115, type="Instant", level=13, mana=60, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,3,4,5,6,7,8,9,10} },
  ["utevo gran res dru"] = { name="Druid familiar", id=197, clientId=143, type="Instant", level=200, mana=3000, soul=0, maglevel=0, cooldown=0, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={2,6} },
  ["utevo gran res eq"] = { name="Knight familiar", id=194, clientId=142, type="Instant", level=200, mana=1000, soul=0, maglevel=0, cooldown=0, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={4,8} },
  ["utevo gran res sac"] = { name="Paladin familiar", id=195, clientId=144, type="Instant", level=200, mana=2000, soul=0, maglevel=0, cooldown=0, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={3,7} },
  ["utevo gran res tio"] = { name="Summon Monk Familiar", id=282, clientId=170, type="Instant", level=200, mana=1500, soul=0, maglevel=0, cooldown=0, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={9,10} },
  ["utevo gran res ven"] = { name="Sorcerer familiar", id=196, clientId=145, type="Instant", level=200, mana=3000, soul=0, maglevel=0, cooldown=0, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,5} },
  ["utevo grav san"] = { name="Divine Empowerment", id=268, clientId=158, type="Instant", level=300, mana=500, soul=0, maglevel=0, cooldown=32000, group={ [3]=2000 }, needTarget=false, range=7, premium=true, vocations={3,7} },
  ["utevo lux"] = { name="Light", id=10, clientId=116, type="Instant", level=8, mana=20, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,3,4,5,6,7,8,9,10} },
  ["utevo mas sio"] = { name="Enlighten Party", id=278, clientId=166, type="Instant", level=32, mana=75, soul=0, maglevel=0, cooldown=300000, group={ [3]=1000 }, needTarget=false, range=-1, premium=false, vocations={9,10} },
  ["utevo nia"] = { name="Focus Harmony", id=279, clientId=167, type="Instant", level=275, mana=500, soul=0, maglevel=0, cooldown=120000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={9,10} },
  ["utevo res"] = { name="Summon Creature", id=9, clientId=117, type="Instant", level=25, mana=0, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6} },
  ["utevo res ina"] = { name="Creature Illusion", id=38, clientId=99, type="Instant", level=23, mana=100, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={1,2,5,6} },
  ["utevo vis lux"] = { name="Ultimate Light", id=75, clientId=114, type="Instant", level=26, mana=140, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,2,5,6} },
  ["utito dru"] = { name="Elemental Synthesis", id=319, clientId=193, type="Instant", level=20, mana=400, soul=0, maglevel=0, cooldown=10000, group={ [3]=2000, [11]=10000 }, needTarget=false, range=-1, premium=true, vocations={2,6} },
  ["utito mas sio"] = { name="Train Party", id=126, clientId=119, type="Instant", level=32, mana=60, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={4,8} },
  ["utito tempo"] = { name="Blood Rage", id=133, clientId=95, type="Instant", level=60, mana=290, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000, [11]=30000 }, needTarget=false, range=-1, premium=true, vocations={4,8} },
  ["utito tempo san"] = { name="Sharpshooter", id=135, clientId=120, type="Instant", level=60, mana=450, soul=0, maglevel=0, cooldown=10000, group={ [3]=2000 }, needTarget=false, range=-1, premium=false, vocations={3,7} },
  ["utito virtu"] = { name="Virtue of Justice", id=275, clientId=163, type="Instant", level=20, mana=210, soul=0, maglevel=0, cooldown=10000, group={ [3]=2000, [11]=30000 }, needTarget=false, range=-1, premium=false, vocations={9,10} },
  ["utori con"] = { name="Sharpshooter (Stance)", id=313, clientId=196, type="Instant", level=20, mana=250, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000, [11]=10000 }, needTarget=true, range=-1, premium=true, vocations={3,7} },
  ["utori flam"] = { name="Ignite", id=138, clientId=54, type="Instant", level=26, mana=30, soul=0, maglevel=0, cooldown=30000, group={ [1]=2000 }, needTarget=true, range=3, premium=false, vocations={1,5} },
  ["utori hur"] = { name="Divine Defiance", id=314, clientId=197, type="Instant", level=20, mana=250, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000, [11]=10000 }, needTarget=true, range=-1, premium=true, vocations={3,7} },
  ["utori kor"] = { name="Inflict Wound", id=141, clientId=56, type="Instant", level=40, mana=30, soul=0, maglevel=0, cooldown=30000, group={ [1]=2000 }, needTarget=true, range=1, premium=false, vocations={4,8,9,10} },
  ["utori mas sio"] = { name="Enchant Party", id=129, clientId=112, type="Instant", level=32, mana=120, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={1,5} },
  ["utori mort"] = { name="Curse", id=139, clientId=53, type="Instant", level=75, mana=30, soul=0, maglevel=0, cooldown=40000, group={ [1]=2000 }, needTarget=true, range=3, premium=false, vocations={1,5} },
  ["utori pox"] = { name="Envenom", id=142, clientId=57, type="Instant", level=50, mana=30, soul=0, maglevel=0, cooldown=40000, group={ [1]=2000 }, needTarget=true, range=3, premium=false, vocations={2,6} },
  ["utori san"] = { name="Holy Flash", id=143, clientId=52, type="Instant", level=70, mana=30, soul=0, maglevel=0, cooldown=40000, group={ [1]=2000 }, needTarget=true, range=3, premium=false, vocations={3,7} },
  ["utori virtu"] = { name="Virtue of Harmony", id=274, clientId=162, type="Instant", level=20, mana=210, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000, [11]=30000 }, needTarget=false, range=-1, premium=false, vocations={9,10} },
  ["utori vis"] = { name="Electrify", id=140, clientId=55, type="Instant", level=34, mana=30, soul=0, maglevel=0, cooldown=30000, group={ [1]=2000 }, needTarget=true, range=3, premium=false, vocations={1,5} },
  ["utura"] = { name="Recovery", id=159, clientId=14, type="Instant", level=50, mana=75, soul=0, maglevel=0, cooldown=60000, group={ [2]=1000 }, needTarget=false, range=-1, premium=false, vocations={3,4,7,8} },
  ["utura gran"] = { name="Intense Recovery", id=160, clientId=15, type="Instant", level=100, mana=165, soul=0, maglevel=0, cooldown=1000, group={ [2]=1000 }, needTarget=false, range=-1, premium=true, vocations={3,4,7,8} },
  ["utura mas sio"] = { name="Heal Party", id=128, clientId=125, type="Instant", level=32, mana=120, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000 }, needTarget=false, range=-1, premium=true, vocations={2,6} },
  ["utura sio"] = { name="Shared Conservation", id=309, clientId=194, type="Instant", level=20, mana=400, soul=0, maglevel=0, cooldown=10000, group={ [3]=2000, [11]=10000 }, needTarget=false, range=-1, premium=true, vocations={2,6} },
  ["utura tio"] = { name="Virtue of Sustain", id=276, clientId=164, type="Instant", level=20, mana=210, soul=0, maglevel=0, cooldown=2000, group={ [3]=2000, [11]=30000 }, needTarget=false, range=-1, premium=false, vocations={9,10} },
}

--- AttackBot.lua:1879 AUTO_DETECT, complete (one formula, "exevo gran mas pox",
--- has NO SpellInfo entry, so this map is wider than spells.DB).
spells.AREA_BY_WORDS = {
  ["exevo flam hur"] = { category = 5, pattern = 11, patternCategory = 4 },
  ["exevo frigo hur"] = { category = 5, pattern = 11, patternCategory = 4 },
  ["exevo fur frigo"] = { category = 1, pattern = 4, patternCategory = 1 },
  ["exevo fur tera"] = { category = 1, pattern = 4, patternCategory = 1 },
  ["exevo gran flam hur"] = { category = 5, pattern = 12, patternCategory = 4 },
  ["exevo gran frigo hur"] = { category = 5, pattern = 10, patternCategory = 4 },
  ["exevo gran mas flam"] = { category = 5, pattern = 6, patternCategory = 4 },
  ["exevo gran mas frigo"] = { category = 5, pattern = 6, patternCategory = 4 },
  ["exevo gran mas pox"] = { category = 5, pattern = 6, patternCategory = 4 },
  ["exevo gran mas tera"] = { category = 5, pattern = 6, patternCategory = 4 },
  ["exevo gran mas vis"] = { category = 5, pattern = 6, patternCategory = 4 },
  ["exevo gran vis lux"] = { category = 5, pattern = 8, patternCategory = 4 },
  ["exevo mas san"] = { category = 5, pattern = 3, patternCategory = 4 },
  ["exevo tera hur"] = { category = 5, pattern = 2, patternCategory = 4 },
  ["exevo ulus frigo"] = { category = 5, pattern = 5, patternCategory = 4 },
  ["exevo ulus tera"] = { category = 5, pattern = 5, patternCategory = 4 },
  ["exevo vis hur"] = { category = 5, pattern = 2, patternCategory = 4 },
  ["exevo vis lux"] = { category = 5, pattern = 7, patternCategory = 4 },
  ["exori"] = { category = 5, pattern = 1, patternCategory = 4 },
  ["exori con"] = { category = 1, pattern = 7, patternCategory = 1 },
  ["exori flam"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori frigo"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori gran"] = { category = 5, pattern = 1, patternCategory = 4 },
  ["exori gran flam"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori gran frigo"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori gran ico"] = { category = 1, pattern = 1, patternCategory = 1 },
  ["exori gran mas nia"] = { category = 5, pattern = 17, patternCategory = 4 },
  ["exori gran mas pug"] = { category = 5, pattern = 14, patternCategory = 4 },
  ["exori gran tera"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori gran vis"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori hur"] = { category = 1, pattern = 5, patternCategory = 1 },
  ["exori ico"] = { category = 1, pattern = 1, patternCategory = 1 },
  ["exori mas"] = { category = 5, pattern = 3, patternCategory = 4 },
  ["exori mas amp pug"] = { category = 5, pattern = 15, patternCategory = 4 },
  ["exori mas nia"] = { category = 5, pattern = 16, patternCategory = 4 },
  ["exori mas pug"] = { category = 5, pattern = 13, patternCategory = 4 },
  ["exori mas res"] = { category = 5, pattern = 19, patternCategory = 4 },
  ["exori max flam"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori max frigo"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori max tera"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori max vis"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori med pug"] = { category = 5, pattern = 18, patternCategory = 4 },
  ["exori min"] = { category = 5, pattern = 9, patternCategory = 4 },
  ["exori moe ico"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori mort"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori pug"] = { category = 1, pattern = 1, patternCategory = 1 },
  ["exori san"] = { category = 1, pattern = 4, patternCategory = 1 },
  ["exori tera"] = { category = 1, pattern = 3, patternCategory = 1 },
  ["exori vis"] = { category = 1, pattern = 3, patternCategory = 1 },
}

--- SpellRunesData: rune ITEM id -> its conjure spell id, group and cooldown.
--- This is the table to consult for an AttackBot entry with itemId > 100.
spells.RUNES = {
  [3148] = { name = "destroy field rune", spellId = 30, group = 3, cooldown = 2000 },
  [3149] = { name = "energybomb rune", spellId = 55, group = 1, cooldown = 2000 },
  [3152] = { name = "intense healing rune", spellId = 4, group = 2, cooldown = 1000 },
  [3153] = { name = "antidote rune", spellId = 31, group = 2, cooldown = 1000 },
  [3155] = { name = "sudden death rune", spellId = 21, group = 1, cooldown = 2000 },
  [3156] = { name = "Wild Growth Rune", spellId = 94, group = 1, cooldown = 2000 },
  [3158] = { name = "icicle rune", spellId = 114, group = 1, cooldown = 2000 },
  [3160] = { name = "ultimate healing rune", spellId = 5, group = 2, cooldown = 1000 },
  [3161] = { name = "avalanche rune", spellId = 115, group = 1, cooldown = 2000 },
  [3164] = { name = "energy field rune", spellId = 27, group = 1, cooldown = 2000 },
  [3165] = { name = "paralyze rune", spellId = 54, group = 3, cooldown = 6000 },
  [3166] = { name = "energy wall rune", spellId = 33, group = 1, cooldown = 2000 },
  [3172] = { name = "poison field rune", spellId = 26, group = 1, cooldown = 2000 },
  [3173] = { name = "poison bomb rune", spellId = 91, group = 1, cooldown = 2000 },
  [3174] = { name = "light magic missile rune", spellId = 7, group = 1, cooldown = 2000 },
  [3175] = { name = "stone shower rune", spellId = 116, group = 1, cooldown = 2000 },
  [3176] = { name = "poison wall rune", spellId = 32, group = 1, cooldown = 2000 },
  [3177] = { name = "convince creature rune", spellId = 12, group = 3, cooldown = 2000 },
  [3178] = { name = "chameleon rune", spellId = 14, group = 3, cooldown = 2000 },
  [3179] = { name = "stalagmite rune", spellId = 77, group = 1, cooldown = 2000 },
  [3180] = { name = "Magic Wall Rune", spellId = 86, group = 1, cooldown = 2000 },
  [3182] = { name = "holy missile rune", spellId = 130, group = 1, cooldown = 2000 },
  [3188] = { name = "fire field rune", spellId = 25, group = 1, cooldown = 2000 },
  [3189] = { name = "fireball rune", spellId = 15, group = 1, cooldown = 2000 },
  [3190] = { name = "fire wall rune", spellId = 28, group = 1, cooldown = 2000 },
  [3191] = { name = "great fireball rune", spellId = 16, group = 1, cooldown = 2000 },
  [3192] = { name = "firebomb rune", spellId = 17, group = 1, cooldown = 2000 },
  [3195] = { name = "soulfire rune", spellId = 50, group = 1, cooldown = 2000 },
  [3197] = { name = "desintegrate rune", spellId = 78, group = 3, cooldown = 2000 },
  [3198] = { name = "heavy magic missile rune", spellId = 8, group = 1, cooldown = 2000 },
  [3200] = { name = "explosion rune", spellId = 18, group = 1, cooldown = 2000 },
  [3202] = { name = "thunderstorm rune", spellId = 117, group = 1, cooldown = 2000 },
  [3203] = { name = "animate dead rune", spellId = 83, group = 3, cooldown = 2000 },
  [17512] = { name = "lightest magic missile rune", spellId = 7, group = 1, cooldown = 2000 },
  [21351] = { name = "light stone shower rune", spellId = 116, group = 1, cooldown = 2000 },
  [21352] = { name = "lightest missile rune", spellId = 7, group = 1, cooldown = 2000 },
}

-- ===========================================================================
-- API
-- ===========================================================================

local DB     = spells.DB
local AREA   = spells.AREA_BY_WORDS
local RUNES  = spells.RUNES
local CIP    = spells.CIP_BY_CLIENT_VOCATION

--- Canonical lookup key.  vBot's getSpellData (vlib.lua:333) lowercases only;
--- this also trims, which is a strict superset (a formula that vBot would miss
--- because of a stray trailing space is found here).  AttackBot itself trims
--- for its own optimizer/augment lookups (AttackBot.lua:1298, 1586), so the
--- trimming behaviour is the one the customised bot already relies on.
local function norm(words)
    if type(words) ~= 'string' then return nil end
    return (words:lower():match('^%s*(.-)%s*$'))
end
spells.normalise = norm

--- words -> entry, or nil for a formula SpellInfo does not know.
--- vBot treats "unknown formula" as ALWAYS castable (vlib.lua:298 falls through
--- to `return true`), so callers must not turn nil into "cannot cast".
function spells.byWords(words)
    local w = norm(words)
    return w and DB[w] or nil
end

--- the whole table (words -> entry).  Treat as READ-ONLY; it is not copied.
function spells.all()
    return DB
end

--- iterate spells in a stable (alphabetical by formula) order.
function spells.sortedWords()
    local out = {}
    for w in pairs(DB) do out[#out + 1] = w end
    table.sort(out)
    return out
end

--- CLIENT vocation id -> { cipA, cipB }, or nil for 0/unknown.
--- Returns the shared table; do not mutate it.
function spells.cipPairForClientVocation(vocClientId)
    return CIP[tonumber(vocClientId) or -1]
end

--- Does this spell belong to the player's vocation?
---   * unknown formula                     -> true  (nothing to filter on)
---   * entry without a `vocations` array   -> true  (AttackBot.lua:2008)
---   * unknown / 0 client vocation         -> true  (AttackBot.lua:2009)
--- The client id is NEVER compared against the CIP ids directly.
function spells.matchesVocation(words, vocClientId)
    local e = spells.byWords(words)
    if not e or type(e.vocations) ~= 'table' then return true end
    local pair = CIP[tonumber(vocClientId) or -1]
    if not pair then return true end
    for i = 1, #pair do
        local cip = pair[i]
        for j = 1, #e.vocations do
            if e.vocations[j] == cip then return true end
        end
    end
    return false
end

--- groups{groupId = cooldownMs} | nil, primaryGroupId | nil
--- The primary is the lowest group id, which for every attack spell in the DB
--- is 1 (Attack).  Gate on ALL of them, not only the primary -- see the header.
function spells.group(words)
    local e = spells.byWords(words)
    if not e or type(e.group) ~= 'table' then return nil, nil end
    local primary
    for gid in pairs(e.group) do
        if not primary or gid < primary then primary = gid end
    end
    return e.group, primary
end

--- sorted array of the spell's group ids (empty table when unknown).
function spells.groupIds(words)
    local groups = spells.group(words)
    local out = {}
    if groups then
        for gid in pairs(groups) do out[#out + 1] = gid end
        table.sort(out)
    end
    return out
end

--- per-spell cooldown in ms (SpellInfo `exhaustion`), plus the group table.
--- 0 for an unknown formula.  STATIC AND OFTEN WRONG on this server -- prefer
--- remainingFromCache(); this is the "never cast it this session" fallback.
function spells.cooldown(words)
    local e = spells.byWords(words)
    if not e then return 0, nil end
    return e.cooldown or 0, e.group
end

--- true when the entry is a CONJURE spell whose rune item id is known.
function spells.isRune(words)
    local e = spells.byWords(words)
    return (e and e.isRune) == true
end

--- rune ITEM id -> { name, spellId, group, cooldown }.  This is what an
--- AttackBot entry with `itemId > 100` actually is.
function spells.runeByItemId(itemId)
    return RUNES[tonumber(itemId) or -1]
end

--- { category, pattern, patternCategory } | nil -- AttackBot's AUTO_DETECT.
function spells.area(words)
    local w = norm(words)
    return w and AREA[w] or nil
end

--- AUTO_DETECT plus AttackBot's fallback heuristic (AttackBot.lua:1913-1937),
--- including the final clamp to the number of patterns in that category.
--- Returns nil when the formula is neither mapped nor a known spell.
function spells.detectArea(words)
    local w = norm(words)
    if not w then return nil end
    local exact = AREA[w]
    if exact then return exact end

    local e = DB[w]
    if not e then return nil end

    local cat, pat
    if type(e.group) == 'table' and e.group[3] then
        cat, pat = 4, 1                              -- support/buff -> Empowerment
    elseif e.needTarget then
        local r = tonumber(e.range)
        if not r or r < 1 or r > 10 then r = 3 end
        cat, pat = 1, r
    elseif w:find('^exevo') then
        cat = 5
        if w:find('hur$') then pat = 11
        elseif w:find('mas') then pat = 4
        else pat = 3 end
    elseif w:find('^exori') then
        cat, pat = 5, 1
    else
        return nil
    end

    local pcat = (cat == 4 and 3) or (cat == 5 and 4) or cat
    local limit = spells.PATTERN_COUNT[pcat] or pat
    if pat > limit then pat = limit end
    return { category = cat, pattern = pat, patternCategory = pcat }
end

--- The COUNTING pattern id for an entry, applying the manual wave augment.
--- `augmented` is entry.augmented -- a user checkbox, never inferred.
--- Mirrors augmentedWavePattern (AttackBot.lua:1296-1301): an unknown formula
--- or a spell with no augment keeps its base pattern.
function spells.augmentedWavePattern(words, basePattern, augmented)
    if not augmented then return basePattern end
    local e = spells.byWords(words)
    return (e and e.augmentedPattern) or basePattern
end

--- { flag, mode, castRange, jumps, jumpDist } | nil  (OptimizedSpells).
function spells.optimizer(words)
    local e = spells.byWords(words)
    return e and e.optimizer or nil
end

--- vBot's canCast level/mana half (vlib.lua:299-302), cooldowns excluded.
--- Unknown formula -> true, matching vlib's final `return true`.
function spells.meetsRequirements(words, level, mana)
    local e = spells.byWords(words)
    if not e then return true end
    return (level or 0) >= (e.level or 0) and (mana or 0) >= (e.mana or 0)
end

-- ---------------------------------------------------------------------------
-- server-pushed cooldown clocks
--
-- `cache` is the AttackBot.lua:68-102 table, fed from the luaclient events:
--     spellCooldown      { spellId, delay }  -> cache[spellId]           = { exhaustion = delay, startTime = now }
--     spellGroupCooldown { groupId, delay }  -> cache['group_'..groupId] = { exhaustion = delay, startTime = now }
-- ---------------------------------------------------------------------------

--- ms left on one group clock, or nil when it has never fired this session.
--- getRealGroupRemaining (AttackBot.lua:152-155).  May be NEGATIVE (expired).
function spells.groupRemainingFromCache(cache, groupId, now)
    local g = cache and cache['group_' .. groupId]
    if not g then return nil end
    return g.exhaustion - (now - g.startTime)
end

--- ms left before `words` may be cast: the MAXIMUM of the spell's own clock
--- and every one of its group clocks.  nil when nothing is cached yet (the
--- caller then falls back to the icon/`cooldown()` path, exactly as
--- attackSpellCooldownReady does).  getRealSpellRemaining (AttackBot.lua:113-136).
function spells.remainingFromCache(cache, words, now)
    local e = spells.byWords(words)
    if not e or not cache then return nil end

    local remaining
    local direct = cache[e.id]
    if direct then
        remaining = direct.exhaustion - (now - direct.startTime)
    end
    if type(e.group) == 'table' then
        for groupId in pairs(e.group) do
            local g = cache['group_' .. groupId]
            if g then
                local gr = g.exhaustion - (now - g.startTime)
                if not remaining or gr > remaining then remaining = gr end
            end
        end
    end
    return remaining
end

return spells
