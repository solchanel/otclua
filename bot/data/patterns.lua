--[=[============================================================================
 bot/data/patterns.lua  --  AttackBot spell-area geometry, ported verbatim
==============================================================================

 SOURCE OF TRUTH (read-only, never modified by this port):
   D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/AttackBot.lua
     lines  241- 296  ->  `local patterns`        (UI labels)   -> patterns.NAMES
     lines  299- 839  ->  `local spellPatterns`                 -> patterns.spellPatterns
     lines  842- 912  ->  `local ek` + posN/posE/posS/posW      -> patterns.dirSquares
     lines  914-1170  ->  `local monkDirPatterns`               -> patterns.monkDirPatterns
   Engine parser that consumes these strings (the ONLY authority on how a grid
   maps to the map):
     D:/Claude/otclient_mehah1530/otclient/src/client/map.cpp
       Map::getSpectatorsByPattern(centerPos, pattern, direction)   [line 1475]
   Lua wrapper that decides which `direction` is passed in:
     D:/Claude/otclient_mehah1530/otclient/mods/game_bot/functions/map.lua
       context.getSpectators(param1, param2)                        [line 8]

------------------------------------------------------------------------------
 1. COORDINATE CONVENTION  (transcribed from Map::getSpectatorsByPattern)
------------------------------------------------------------------------------
 A "grid" is a plain multi-line string. The C++ scanner walks the string char
 by char:

   '0' or '-'         -> cell disabled
   '1' or '+'         -> cell enabled
   'N','E','S','W'    -> cell enabled ONLY IF the `direction` argument equals
   (and lowercase)       that compass direction  (N=0, E=1, S=2, W=3)
   anything else      -> line terminator; `lineLength` is decremented first,
                         and the line only "counts" when lineLength > 1.

 Two consequences that matter for a faithful port:
   * Leading indentation is HARMLESS. A run of spaces at the start of a line
     nets out to zero (each space does lineLength+1 then lineLength-1, and the
     `lineLength > 1` guard means no row is emitted). This is why the original
     file can indent its `[[ ... ]]` grids freely. This port stores the grids
     UNINDENTED, which parses to the identical row set.
   * Every row must have the SAME width, and both width and height must be
     ODD, or the engine logs "Invalid pattern ..." and returns an EMPTY
     spectator list (i.e. the spell silently counts 0 monsters). Three grids
     in the original violate this -- see section 5.

 Mapping to map offsets (verbatim from the C++ loop):

     for y = centerPos.y - height/2 .. centerPos.y + height/2      -- integer div
       for x = centerPos.x - width/2  .. centerPos.x + width/2
         if finalPattern[p++] then collect creatures on (x, y, centerPos.z)

   So, with rows indexed r = 1..h (TOP row first) and columns c = 1..w (LEFT
   column first):

       dx = (c - 1) - floor(w / 2)
       dy = (r - 1) - floor(h / 2)

   +x is EAST, +y is SOUTH (Tibia map convention). The grid is therefore drawn
   the same way the map looks on screen: top of the string = north.

   THE CASTER (or, for thrown areas, the aim tile) IS THE EXACT CENTRE CELL:
       r = floor(h/2) + 1 , c = floor(w/2) + 1     (dx = 0, dy = 0)
   The centre cell is NOT automatically excluded -- if it holds a '1' the
   caster's own tile is part of the area (e.g. the 3x3 "adjacent"/"bomb"
   grids), and if it holds a '0' it is not (e.g. pattern 9 "Sweep").

   Z is always centerPos.z; these grids are single-floor only.

------------------------------------------------------------------------------
 2. ROTATION  --  there is NO geometric rotation
------------------------------------------------------------------------------
 This is the single most important thing to get right. The original code never
 rotates a grid. Two different mechanisms exist:

 (a) LETTER GRIDS (spellPatterns category 4 ids 2, 7, 8, 10, 11, 12 -- the
     waves and beams). One grid contains all four facings superimposed, each
     cell tagged with the direction that would hit it. "Rotation" happens
     inside the C++ scanner: a cell tagged 'N' is enabled iff
     `direction == Otc::North`, and so on. The transform is a FILTER, not a
     rotate:

         enabled(cell, dir) = (ch == '1' or ch == '+')
                              or (ch == 'N' and dir == 0)
                              or (ch == 'E' and dir == 1)
                              or (ch == 'S' and dir == 2)
                              or (ch == 'W' and dir == 3)

     Which `direction` reaches the scanner is decided in map.lua:
       getSpectators(<table position>, grid)  -> direction = 8  (INVALID)
                                                 => every letter cell is OFF
       getSpectators(<creature>,      grid)  -> that creature's facing
       getSpectators(grid)                   -> the player's own facing
     The original AttackBot ALWAYS passes a table position (`pos()`), so it
     would always get direction 8 and lose every letter cell. That is exactly
     why the customised file added `extractDirGrid()` (line 1178): it rewrites
     one chosen letter to '1' and everything else to '0', producing a pure 0/1
     grid that can then be fed with a table position. `patterns.dirGrid()`
     below is a byte-faithful port of that helper.

 (b) PER-DIRECTION GRIDS (`monkDirPatterns`). For pattern ids 9, 13, 14, 16
     and 19 the author wrote out four INDEPENDENT hand-drawn grids, one per
     facing, indexed [0]=N [1]=E [2]=S [3]=W. These are already pure 0/1 and
     already "rotated"; nothing further is applied. They are NOT rotations of
     each other in the strict mathematical sense (see the per-pattern notes) --
     do not regenerate them by rotating [0].

 Direction numbering everywhere in this file: 0 = North, 1 = East, 2 = South,
 3 = West (Otc::Direction / player:getDirection()).

------------------------------------------------------------------------------
 3. TABLE LAYOUT
------------------------------------------------------------------------------
 spellPatterns[patternCategory][patternId] = { [1] = normal, [2] = PVP-safe }
   [1] is the real area used for counting monsters.
   [2] is a DELIBERATELY LARGER grid used only for the "PvpSafe" check: if any
       non-party player stands anywhere inside it, the cast is refused. It is
       never used to count monsters.

 `patternCategory` (pCat) is NOT `entry.category`. AttackBot.lua line 1955:
       patternCategory = category == 4 and 3 or category == 5 and 4 or category
   entry.category 1 "Targeted Spell"  -> pCat 1   (no grids; id == sqm range)
   entry.category 2 "Area Rune"       -> pCat 2   (grids: cross/bomb/ball)
   entry.category 3 "Targeted Rune"   -> pCat 3   (no grids; id == sqm range)
   entry.category 4 "Empowerment"     -> pCat 3   (no grids; id == sqm range)
   entry.category 5 "Absolute Spell"  -> pCat 4   (19 grids)
 pCat 1 and pCat 3 are literally `{}` in the original ("blank, wont be used"):
 for those the pattern id is a RANGE IN SQM, not an area, and the code takes
 the `category == 1 or 3 or 4` early-out branch of getMonstersInArea() which
 scans the whole screen instead of a grid. This port keeps them as empty
 tables so index arithmetic stays identical.

------------------------------------------------------------------------------
 4. PATTERN ID REFERENCE  (id -> name -> which spells use it)
------------------------------------------------------------------------------
 pCat 2 -- Area Runes (thrown; the grid is centred on the AIM TILE, chosen by
          getBestTileByPattern over walkable/shootable tiles within distance
          < 4 of the player):
   1  Cross   (explosion)                     3x3 plus-sign
   2  Bomb    (fire bomb / stalagmite etc.)   full 3x3
   3  Ball    (great fireball, avalanche)     7x7 rounded ball

 pCat 4 -- Absolute Spells (self-centred unless noted). The spell->id map is
          AttackBot.lua's AUTO_DETECT table (line 1879):
   1  Adjacent          exori, exori gran                       3x3 around caster
   2  3x3 Wave          exevo vis hur, exevo tera hur           LETTER GRID
   3  Small Area        exori mas, exevo mas san                7x7 ball
   4  Medium Area       exevo mas flam, exevo mas frigo         11x11 diamond-ish
   5  Ulus Area         exevo ulus frigo, exevo ulus tera       9x9 ring (hollow)
   6  Large Area        exevo gran mas vis/tera/frigo/flam/pox  13x13 diamond
                        *** SELF-CENTRED 0/1, NOT A WAVE -- must never go
                        through the wave scanner (see section 6). ***
   7  Short Beam        exevo vis lux                           LETTER GRID
   8  Large Beam        exevo gran vis lux                      LETTER GRID
   9  Sweep             exori min  (Front Sweep, knight)        monkDirPatterns[9]
  10  Small Wave        exevo gran frigo hur                    LETTER GRID
  11  Big Wave          exevo flam hur, exevo frigo hur         LETTER GRID
  12  Huge Wave         exevo gran flam hur                     LETTER GRID
  13  Flurry of Blows        exori mas pug                      monkDirPatterns[13]
  14  Greater Flurry         exori gran mas pug                 monkDirPatterns[14]
  15  Thousand Fist Blows    exori mas amp pug                  centred on TARGET
                        (or on an aimed tile when the "best tile" optimizer is
                        on). 5x5 with cut corners.
  16  Sweeping Takedown      exori mas nia                      monkDirPatterns[16]
  17  Spiritual Outburst     exori gran mas nia                 CHAIN spell
  18  Chained Penance        exori med pug                      CHAIN spell
  19  Balanced Brawl         exori mas res                      monkDirPatterns[19]

 ids 17 and 18 are chain spells: their grids exist only so a generic lookup
 never indexes an empty table (the union reach = cast range 3 + a jump of 2).
 The real behaviour is the hop simulation in the optimizer, not these grids.

 Which ids are routed where in the main loop (AttackBot.lua line 2939+):
   id in {9, 13, 14, 16, 19}  -> getMonkBestDir()  (monkDirPatterns)
   id == 15                   -> centred on the target's position
   id in {17, 18}             -> chain estimate ("monsters within 5 sqm")
   else isWave = (id == 2 or id == 7 or id >= 9)  -> getWaveBestDir()
        Because 9/13/14/16/19 and 15/17/18 are already handled above, the
        `isWave` set that actually reaches the wave scanner is {2, 7, 8, 10,
        11, 12} -- exactly the six LETTER GRIDS. Note id 6 is NOT in it.
   else -> counted around the caster with the plain 0/1 grid.

------------------------------------------------------------------------------
 5. KNOWN DEFECTS IN THE ORIGINAL DATA  (ported verbatim, NOT silently fixed)
------------------------------------------------------------------------------
 These three grids have an EVEN height, which Map::getSpectatorsByPattern
 rejects outright ("width and height should be odd") -> it returns an empty
 list, so any lookup through them counts 0 monsters:
     spellPatterns[4][13][1]  Flurry of Blows, normal    h=4 w=3
     spellPatterns[4][14][2]  Greater Flurry, SAFE       h=6 w=7
     spellPatterns[4][16][2]  Sweeping Takedown, SAFE    h=6 w=7
 In practice 13/14/16 are routed through monkDirPatterns, so [1] is never used
 for counting; the [2] safe grids ARE passed to getMonkBestDir as `safePattern`
 when PvpSafe is on, and being invalid they return no spectators -- i.e. the
 PVP-safety check for Greater Flurry and Sweeping Takedown silently never
 blocks. `patterns.validate()` below reports all of this.

 Two further shape oddities kept verbatim:
   * spellPatterns[4][19] (Balanced Brawl): h=7 w=13, i.e. the centre cell is
     row 4 / col 7 = '1', in the MIDDLE of a shape that is really forward-only.
     monkDirPatterns[19] is the correct data; [4][19] is only a union blob and
     its [1] and [2] entries are byte-identical to each other (there is no
     enlarged safe variant).
   * dirSquares (non-knight) West grid is not the mirror of East: rows are
     "01111000000" / "11110000000" / "11111000000" / "11110000000" /
     "11110000000". Row 4 starts one column further right than rows 5..8.
     Transcribed as-is.

------------------------------------------------------------------------------
 6. dirSquares (posN/posE/posS/posW)
------------------------------------------------------------------------------
 AttackBot.lua line 842:  local ek = (voc() == 1 or voc() == 11) and true
 `voc()` is the CLIENT vocation id (1 = Knight, 11 = Elite Knight), NOT the
 CIP SpellInfo layout. For knights `ek` is true and the compass squares are a
 tiny 3x3 (one row/column adjacent to the caster); for everyone else they are
 11x11 quadrant blocks. Note the `x and true` idiom makes `ek` exactly
 `true` or `false` (never nil-vs-false ambiguity).
 These four squares are used ONLY at AttackBot.lua lines 2741-2744 to compute
 monstersN/E/S/W -> bestSide/bestDir, a coarse "where is the crowd" scan. The
 only decision still driven by it is pattern 8 (Large Beam) at line 3064; the
 waves themselves were moved onto getWaveBestDir. They are generic squares and
 do NOT correspond to any spell's real coverage.

==============================================================================]=]

local patterns = {}

-- ---------------------------------------------------------------------------
-- Direction constants
-- ---------------------------------------------------------------------------
patterns.NORTH, patterns.EAST, patterns.SOUTH, patterns.WEST = 0, 1, 2, 3
-- direction value the engine treats as "no direction" (map.lua passes it when
-- the caller supplies a plain table position) -- all letter cells go OFF
patterns.DIR_INVALID = 8
patterns.DIR_LETTERS = { [0] = "N", [1] = "E", [2] = "S", [3] = "W" }

-- entry.category -> label (AttackBot.lua `local categories`, line 233)
patterns.CATEGORIES = {
  [1] = "Targeted Spell (exori hur, exori flam, etc)",
  [2] = "Area Rune (avalanche, great fireball, etc)",
  [3] = "Targeted Rune (sudden death, icycle, etc)",
  [4] = "Empowerment (utito tempo, etc)",
  [5] = "Absolute Spell (exori, hells core, etc)",
}

-- entry.category -> patternCategory  (AttackBot.lua line 1955)
patterns.CATEGORY_TO_PCAT = { [1] = 1, [2] = 2, [3] = 3, [4] = 3, [5] = 4 }

-- patternCategory -> pattern id -> label (AttackBot.lua `local patterns`, 241)
patterns.NAMES = {
  -- pCat 1: targeted spells (id == sqm range, no grid)
  {
    "1 Sqm Range (exori ico)",
    "2 Sqm Range",
    "3 Sqm Range (strike spells)",
    "4 Sqm Range (exori san)",
    "5 Sqm Range (exori hur)",
    "6 Sqm Range",
    "7 Sqm Range (exori con)",
    "8 Sqm Range",
    "9 Sqm Range",
    "10 Sqm Range",
  },
  -- pCat 2: area runes
  {
    "Cross (explosion)",
    "Bomb (fire bomb)",
    "Ball (gfb, avalanche)",
  },
  -- pCat 3: empowerment / targeted rune (id == sqm range, no grid)
  {
    "1 Sqm Range",
    "2 Sqm Range",
    "3 Sqm Range",
    "4 Sqm Range",
    "5 Sqm Range",
    "6 Sqm Range",
    "7 Sqm Range",
    "8 Sqm Range",
    "9 Sqm Range",
    "10 Sqm Range",
  },
  -- pCat 4: absolute
  {
    "Adjacent (exori, exori gran)",        -- 1
    "3x3 Wave (vis hur, tera hur)",        -- 2
    "Small Area (mas san, exori mas)",     -- 3
    "Medium Area (mas flam, mas frigo)",   -- 4
    "Ulus Area (exevo ulus frigo,tera)",   -- 5
    "Large Area (mas vis, mas tera)",      -- 6
    "Short Beam (vis lux)",                -- 7
    "Large Beam (gran vis lux)",           -- 8
    "Sweep (exori min)",                   -- 9
    "Small Wave (gran frigo hur)",         -- 10
    "Big Wave (flam hur, frigo hur)",      -- 11
    "Huge Wave (gran flam hur)",           -- 12
    "Flurry of Blows (exori mas pug)",     -- 13
    "Greater Flurry (exori gran mas pug)", -- 14
    "Thousand Fist Blows (exori mas amp pug)", -- 15
    "Sweeping Takedown (exori mas nia)",   -- 16
    "Spiritual Outburst (exori gran mas nia)", -- 17
    "Chained Penance (exori med pug)",     -- 18
    "Balanced Brawl (exori mas res)",      -- 19
  },
}

-- ===========================================================================
-- spellPatterns[pCat][id] = { normal, pvpSafe }
-- Transcribed from AttackBot.lua lines 299-839, cell for cell.
-- ===========================================================================
patterns.spellPatterns = {

  -- pCat 1 -------------------------------------------------------------
  {}, -- "blank, wont be used" -- targeted spells use sqm range, not a grid

  -- pCat 2 : AREA RUNES ------------------------------------------------
  -- centred on the AIM TILE (getBestTileByPattern), not on the caster
  {
    { -- 1 Cross (explosion)
[[
010
111
010
]],
      -- cross SAFE
[[
01110
01110
11111
11111
11111
01110
01110
]]
    },
    { -- 2 Bomb (fire bomb)
[[
111
111
111
]],
      -- bomb SAFE
[[
11111
11111
11111
11111
11111
]]
    },
    { -- 3 Ball (great fireball, avalanche)
[[
0011100
0111110
1111111
1111111
1111111
0111110
0011100
]],
      -- ball SAFE
[[
000111000
001111100
011111110
111111111
111111111
111111111
011111110
001111100
000111000
]]
    },
  },

  -- pCat 3 -------------------------------------------------------------
  {}, -- "blank, wont be used" -- empowerment/targeted rune use sqm range

  -- pCat 4 : ABSOLUTE SPELLS -------------------------------------------
  {
    { -- 1 Adjacent (exori, exori gran) -- caster's own tile included
[[
111
111
111
]],
      -- adjacent SAFE
[[
11111
11111
11111
11111
11111
]]
    },
    { -- 2 3x3 Wave (exevo vis hur, exevo tera hur) -- LETTER GRID
[[
0000NNN0000
0000NNN0000
0000NNN0000
00000N00000
WWW00N00EEE
WWWWW0EEEEE
WWW00S00EEE
00000S00000
0000SSS0000
0000SSS0000
0000SSS0000
]],
      -- 3x3 Wave SAFE
[[
0000NNNNN0000
0000NNNNN0000
0000NNNNN0000
0000NNNNN0000
WWWW0NNN0EEEE
WWWWWNNNEEEEE
WWWWWW0EEEEEE
WWWWWSSSEEEEE
WWWW0SSS0EEEE
0000SSSSS0000
0000SSSSS0000
0000SSSSS0000
0000SSSSS0000
]]
    },
    { -- 3 Small Area (exori mas, exevo mas san)
[[
0011100
0111110
1111111
1111111
1111111
0111110
0011100
]],
      -- small area SAFE
[[
000111000
001111100
011111110
111111111
111111111
111111111
011111110
001111100
000111000
]]
    },
    { -- 4 Medium Area (exevo mas flam, exevo mas frigo)
      -- NOTE: rows 8 and 10 are asymmetric vs their mirrors (original data)
[[
00000100000
00011111000
00111111100
01111111110
01111111110
11111111111
01111111110
01111111110
00111111100
00001110000
00000100000
]],
      -- medium area SAFE
[[
0000011100000
0000111110000
0001111111000
0011111111100
0111111111110
0111111111110
1111111111111
0111111111110
0111111111110
0011111111100
0001111111000
0000111110000
0000011100000
]]
    },
    { -- 5 Ulus Area (exevo ulus frigo, exevo ulus tera) -- hollow 3x3 core
[[
000111000
001111100
011111110
111000111
111000111
111000111
011111110
001111100
000111000
]],
      -- ulus area SAFE  (h=9 w=11 -- wider than it is tall, both odd = valid)
[[
00011111000
00111111100
01111111110
11110001111
11110001111
11110001111
01111111110
00111111100
00011111000
]]
    },
    { -- 6 Large Area (exevo gran mas vis/tera/frigo/flam/pox)
      -- SELF-CENTRED 0/1 diamond. NOT a wave: excluded from the isWave gate.
[[
0000001000000
0000011100000
0000111110000
0001111111000
0011111111100
0111111111110
1111111111111
0111111111110
0011111111100
0001111111000
0000111110000
0000011100000
0000001000000
]],
      -- large area SAFE
[[
000000010000000
000000111000000
000001111100000
000011111110000
000111111111000
001111111111100
011111111111110
111111111111111
011111111111110
001111111111100
000111111111000
000011111110000
000001111100000
000000111000000
000000010000000
]]
    },
    { -- 7 Short Beam (exevo vis lux) -- LETTER GRID, 5 sqm each way
[[
00000N00000
00000N00000
00000N00000
00000N00000
00000N00000
WWWWW0EEEEE
00000S00000
00000S00000
00000S00000
00000S00000
00000S00000
]],
      -- short beam SAFE
[[
00000NNN00000
00000NNN00000
00000NNN00000
00000NNN00000
00000NNN00000
WWWWWNNNEEEEE
WWWWWW0EEEEEE
00000SSS00000
00000SSS00000
00000SSS00000
00000SSS00000
00000SSS00000
00000SSS00000
]]
    },
    { -- 8 Large Beam (exevo gran vis lux) -- LETTER GRID, 7 sqm each way
[[
0000000N0000000
0000000N0000000
0000000N0000000
0000000N0000000
0000000N0000000
0000000N0000000
0000000N0000000
WWWWWWW0EEEEEEE
0000000S0000000
0000000S0000000
0000000S0000000
0000000S0000000
0000000S0000000
0000000S0000000
0000000S0000000
]],
      -- large beam SAFE
[[
0000000NNN0000000
0000000NNN0000000
0000000NNN0000000
0000000NNN0000000
0000000NNN0000000
0000000NNN0000000
0000000NNN0000000
WWWWWWWNNNEEEEEEE
WWWWWWWW0EEEEEEEE
WWWWWWWSSSEEEEEEE
0000000SSS0000000
0000000SSS0000000
0000000SSS0000000
0000000SSS0000000
0000000SSS0000000
0000000SSS0000000
0000000SSS0000000
]]
    },
    { -- 9 Sweep (Front Sweep, exori min): semicircle in front of the caster.
      -- Direction handling lives in monkDirPatterns[9]; this entry only
      -- provides the union shape (all 8 surrounding tiles, caster excluded)
      -- and the PVP-safe grid so generic lookups never hit an empty table
      -- again -- the old empty {} here crashed getWaveBestDir with
      -- "attempt to index local 'letterPattern' (a nil value)" for knights.
[[
111
101
111
]],
      -- sweep SAFE
[[
11111
11111
11011
11111
11111
]]
    },
    { -- 10 Small Wave (exevo gran frigo hur) -- LETTER GRID
[[
00NNN00
00NNN00
WW0N0EE
WWW0EEE
WW0S0EE
00SSS00
00SSS00
]],
      -- small wave SAFE
[[
00NNNNN00
00NNNNN00
WWNNNNNEE
WWWWNEEEE
WWWW0EEEE
WWWWSEEEE
WWSSSSSEE
00SSSSS00
00SSSSS00
]]
    },
    { -- 11 Big Wave (exevo flam hur, exevo frigo hur) -- LETTER GRID
[[
000NNNNN000
000NNNNN000
0000NNN0000
WW00NNN00EE
WWWW0N0EEEE
WWWWW0EEEEE
WWWW0S0EEEE
WW00SSS00EE
0000SSS0000
000SSSSS000
000SSSSS000
]],
      -- big wave SAFE
[[
000NNNNNNN000
000NNNNNNN000
000NNNNNNN000
WWWWNNNNNEEEE
WWWWNNNNNEEEE
WWWWWNNNEEEEE
WWWWWW0EEEEEE
WWWWWSSSEEEEE
WWWWSSSSSEEEE
WWWWSSSSSEEEE
000SSSSSSS000
000SSSSSSS000
000SSSSSSS000
]]
    },
    { -- 12 Huge Wave (exevo gran flam hur) -- LETTER GRID
[[
0000NNNNN0000
0000NNNNN0000
00000NNN00000
00000NNN00000
WW0000N0000EE
WWWW00N00EEEE
WWWWWW0EEEEEE
WWWW00S00EEEE
WW0000S0000EE
00000SSS00000
00000SSS00000
0000SSSSS0000
0000SSSSS0000
]],
      -- huge wave SAFE (identical to the Large Beam SAFE grid in the original)
[[
0000000NNN0000000
0000000NNN0000000
0000000NNN0000000
0000000NNN0000000
0000000NNN0000000
0000000NNN0000000
0000000NNN0000000
WWWWWWWNNNEEEEEEE
WWWWWWWW0EEEEEEEE
WWWWWWWSSSEEEEEEE
0000000SSS0000000
0000000SSS0000000
0000000SSS0000000
0000000SSS0000000
0000000SSS0000000
0000000SSS0000000
0000000SSS0000000
]]
    },
    { -- 13 Flurry of Blows (exori mas pug)
      -- !! h=4 (EVEN) -- rejected by getSpectatorsByPattern. Never used for
      -- counting because id 13 routes through monkDirPatterns[13].
[[
010
111
111
101
]],
      -- flurry SAFE (5x5, valid)
[[
01110
11111
11111
11111
01110
]]
    },
    { -- 14 Greater Flurry (exori gran mas pug)
[[
00100
01110
01110
11111
01010
]],
      -- greater flurry SAFE -- !! h=6 (EVEN) -> the PvpSafe check silently
      -- never blocks for this spell
[[
0011100
0111110
0111110
1111111
0111110
0011100
]]
    },
    { -- 15 Thousand Fist Blows (exori mas amp pug): 5x5 with cut corners,
      -- centred on the TARGET (or an aimed position) -- verified against the
      -- TibiaWiki area diagram; the old 7-wide grid here was wrong.
      -- Also aliased as `tfbAreaPattern` at AttackBot.lua line 1399.
[[
01110
11111
11111
11111
01110
]],
      -- SAFE: area + 1 sqm margin
[[
0011100
0111110
1111111
1111111
1111111
0111110
0011100
]]
    },
    { -- 16 Sweeping Takedown (exori mas nia)
[[
01110
11111
11111
11111
11011
]],
      -- sweeping takedown SAFE -- !! h=6 (EVEN), same silent-no-block defect
[[
0111110
1111111
1111111
1111111
1111111
0111110
]]
    },
    { -- 17 Spiritual Outburst (exori gran mas nia): chain spell, handled by
      -- its own logic in the main loop / optimizer. Grids kept only so no
      -- generic lookup ever indexes an empty table: rough reach = cast
      -- range 3 + chain jumps of 2.
[[
0011100
0111110
1111111
1111111
1111111
0111110
0011100
]],
[[
001111100
011111110
111111111
111111111
111111111
111111111
111111111
011111110
001111100
]]
    },
    { -- 18 Chained Penance (exori med pug): chain spell, same note as above
[[
0011100
0111110
1111111
1111111
1111111
0111110
0011100
]],
[[
001111100
011111110
111111111
111111111
111111111
111111111
111111111
011111110
001111100
]]
    },
    { -- 19 Balanced Brawl (exori mas res) -- union blob only, h=7 w=13.
      -- The real per-facing data is monkDirPatterns[19]. In the original the
      -- normal and SAFE grids are byte-identical (no enlarged safe variant).
[[
0000001000000
0000011100000
0000111110000
0011111111100
0111111111110
0111100011110
1111100011111
]],
[[
0000001000000
0000011100000
0000111110000
0011111111100
0111111111110
0111100011110
1111100011111
]]
    },
  },
}

-- ===========================================================================
-- monkDirPatterns[id][dir]  --  dir 0=N 1=E 2=S 3=W
-- Transcribed from AttackBot.lua lines 914-1170.
-- Pure 0/1 grids: the facing is already baked in, no letter filtering and no
-- further rotation is applied. Centre cell = the caster (see section 1).
-- ===========================================================================
patterns.monkDirPatterns = {

  -- [9] Front Sweep (exori min, knight): semicircle in front of the caster --
  -- the 3 tiles directly ahead plus the two side tiles on the front half.
  -- Routed through getMonkBestDir exactly like the monk direction spells,
  -- which fixes the crash the old code hit for knights (Sweep used to fall
  -- into the wave scanner with an empty pattern table).
  -- 5 cells per facing; the centre (caster) cell is always '0'.
  [9] = {
    [0] = -- North
[[
111
101
000
]],
    [1] = -- East
[[
011
001
011
]],
    [2] = -- South
[[
000
101
111
]],
    [3] = -- West
[[
110
100
110
]]
  },

  -- [13] Flurry of Blows (exori mas pug) -- 11x11 canvas, 7 cells lit.
  -- The N grid is NOT a pure 90-degree rotation of E/S/W (hand-drawn).
  [13] = {
    [0] =
[[
00000000000
00000000000
00000100000
00001110000
00001110000
00001010000
00000000000
00000000000
00000000000
00000000000
00000000000
]],
    [1] =
[[
00000000000
00000000000
00000000000
00000000000
00000111000
00000011100
00000111000
00000000000
00000000000
00000000000
00000000000
]],
    [2] =
[[
00000000000
00000000000
00000000000
00000000000
00000000000
00001010000
00001110000
00001110000
00000100000
00000000000
00000000000
]],
    [3] =
[[
00000000000
00000000000
00000000000
00000000000
00011100000
00111000000
00011100000
00000000000
00000000000
00000000000
00000000000
]]
  },

  -- [14] Greater Flurry (exori gran mas pug) -- 11x11 canvas.
  [14] = {
    [0] =
[[
00000000000
00000100000
00001110000
00001110000
00011111000
00001010000
00000000000
00000000000
00000000000
00000000000
00000000000
]],
    [1] =
[[
00000000000
00000000000
00000000000
00000010000
00000111100
00000011110
00000111100
00000010000
00000000000
00000000000
00000000000
]],
    [2] =
[[
00000000000
00000000000
00000000000
00000000000
00000000000
00001010000
00011111000
00001110000
00001110000
00000100000
00000000000
]],
    [3] =
[[
00000000000
00000000000
00000000000
00001000000
00111100000
01111000000
00111100000
00001000000
00000000000
00000000000
00000000000
]]
  },

  -- [16] Sweeping Takedown (exori mas nia) -- 11x11 canvas, wide front block.
  [16] = {
    [0] =
[[
00000000000
00001110000
00011111000
00011111000
00011111000
00011011000
00000000000
00000000000
00000000000
00000000000
00000000000
]],
    [1] =
[[
00000000000
00000000000
00000000000
00000111100
00000111110
00000011110
00000111110
00000111100
00000000000
00000000000
00000000000
]],
    [2] =
[[
00000000000
00000000000
00000000000
00000000000
00000000000
00011011000
00011111000
00011111000
00011111000
00001110000
00000000000
]],
    [3] =
[[
00000000000
00000000000
00000000000
00111100000
01111100000
01111000000
01111100000
00111100000
00000000000
00000000000
00000000000
]]
  },

  -- [19] Balanced Brawl: rebuilt from the TibiaWiki area diagram (51 cells --
  -- a forward beam plus two wide side fans reaching 6 sqm to each flank; the
  -- old grids were missing the outermost fan cells and the four rotations
  -- didn't agree with each other, so some facings under-counted).
  -- 13x13 canvas. All four facings light exactly 51 cells (verified below).
  [19] = {
    [0] =
[[
0000001000000
0000111110000
0001111111000
0011111111100
0111111111110
0111100011110
1111100011111
0000000000000
0000000000000
0000000000000
0000000000000
0000000000000
0000000000000
]],
    [1] =
[[
0000001000000
0000001110000
0000001111000
0000001111100
0000001111110
0000000011110
0000000011111
0000000011110
0000001111110
0000001111100
0000001111000
0000001110000
0000001000000
]],
    [2] =
[[
0000000000000
0000000000000
0000000000000
0000000000000
0000000000000
0000000000000
1111100011111
0111100011110
0111111111110
0011111111100
0001111111000
0000111110000
0000001000000
]],
    [3] =
[[
0000001000000
0000111000000
0001111000000
0011111000000
0111111000000
0111100000000
1111100000000
0111100000000
0111111000000
0011111000000
0001111000000
0000111000000
0000001000000
]]
  }
}

-- ===========================================================================
-- dirSquares  --  the coarse compass squares (posN/posE/posS/posW)
-- AttackBot.lua lines 842-912. `ek` selects the variant:
--   ek == true  when voc() is 1 (Knight) or 11 (Elite Knight)  -> 3x3
--   ek == false for every other vocation                       -> 11x11
-- These are generic quadrant blocks, not any spell's real coverage.
-- ===========================================================================
patterns.dirSquares = {

  -- ek == true (Knight / Elite Knight): the single adjacent row or column
  knight = {
    [0] = -- posN
[[
111
000
000
]],
    [1] = -- posE
[[
001
001
001
]],
    [2] = -- posS
[[
000
000
111
]],
    [3] = -- posW
[[
100
100
100
]]
  },

  -- ek == false (everyone else): 11x11 quadrant blocks
  other = {
    [0] = -- posN
[[
00011111000
00011111000
00011111000
00011111000
00000100000
00000000000
00000000000
00000000000
00000000000
00000000000
00000000000
]],
    [1] = -- posE
[[
00000000000
00000000000
00000000000
00000001111
00000001111
00000011111
00000001111
00000001111
00000000000
00000000000
00000000000
]],
    [2] = -- posS
[[
00000000000
00000000000
00000000000
00000000000
00000000000
00000000000
00000100000
00011111000
00011111000
00011111000
00011111000
]],
    -- NOTE: asymmetric vs posE in the original (row 4 shifted one column
    -- east relative to rows 5-8). Transcribed verbatim, do not "fix".
    [3] = -- posW
[[
00000000000
00000000000
00000000000
01111000000
11110000000
11111000000
11110000000
11110000000
00000000000
00000000000
00000000000
]]
  },
}

-- convenience aliases used by the original code
-- AttackBot.lua line 1399: local tfbAreaPattern = spellPatterns[4][15][1]
patterns.tfbAreaPattern = patterns.spellPatterns[4][15][1]

-- Ids that the main loop routes through monkDirPatterns instead of the wave
-- scanner (AttackBot.lua line 2939).
patterns.MONK_DIR_IDS = { [9] = true, [13] = true, [14] = true, [16] = true, [19] = true }
-- Ids whose grid is a combined N/E/S/W letter grid (the only ids that can
-- legitimately reach getWaveBestDir once 9/13/14/15/16/17/18/19 are peeled
-- off by the earlier branches). Pattern 6 "Large Area" is deliberately absent.
patterns.WAVE_IDS = { [2] = true, [7] = true, [8] = true, [10] = true, [11] = true, [12] = true }

-- ===========================================================================
-- Parsing / geometry helpers
-- ===========================================================================

-- Split a grid string into trimmed non-empty rows. Mirrors what the C++
-- scanner effectively does with indentation (leading spaces net out to zero
-- and never emit a row), and is byte-identical to the original
-- extractDirGrid()'s own line splitter.
function patterns.rows(grid)
  if type(grid) ~= "string" then return nil end
  local out = {}
  for line in grid:gmatch("[^\n]+") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then out[#out + 1] = trimmed end
  end
  if #out == 0 then return nil end
  return out
end

-- Returns rows, height, width, ok, err. `ok` is false when the engine's own
-- validation (equal row widths, odd width AND odd height) would fail -- in
-- which case getSpectatorsByPattern returns an EMPTY list at runtime.
function patterns.dims(grid)
  local rows = patterns.rows(grid)
  if not rows then return nil, 0, 0, false, "not a grid string" end
  local h, w = #rows, #rows[1]
  for i = 2, h do
    if #rows[i] ~= w then
      return rows, h, w, false, "ragged rows (row " .. i .. " is " .. #rows[i] .. ", expected " .. w .. ")"
    end
  end
  if w % 2 ~= 1 or h % 2 ~= 1 then
    return rows, h, w, false, "width and height must both be odd (h=" .. h .. " w=" .. w .. ")"
  end
  return rows, h, w, true, nil
end

-- Is this cell enabled for the given facing? Exact port of the char switch in
-- Map::getSpectatorsByPattern. `dir` may be nil or 8 for "no direction", which
-- turns every letter cell off (that is what happens whenever the original code
-- calls getSpectators(<table position>, grid)).
function patterns.cellEnabled(ch, dir)
  if ch == "1" or ch == "+" then return true end
  if ch == "0" or ch == "-" then return false end
  if ch == "N" or ch == "n" then return dir == 0 end
  if ch == "E" or ch == "e" then return dir == 1 end
  if ch == "S" or ch == "s" then return dir == 2 end
  if ch == "W" or ch == "w" then return dir == 3 end
  return false
end

-- patterns.offsets(grid, dir) -> { {dx, dy}, ... }
-- Resolved tile offsets from the CENTRE cell (the caster, or the aim tile for
-- thrown areas), with the letter cells resolved for `dir` (0=N 1=E 2=S 3=W;
-- nil / 8 = no direction, letters off). Order matches the engine's scan order:
-- north row first, then west-to-east within each row.
--   dx = (col - 1) - floor(w / 2)      (+x = east)
--   dy = (row - 1) - floor(h / 2)      (+y = south)
-- Returns nil plus an error string if the grid would be rejected by the
-- engine, so callers can fail the same way the client does.
function patterns.offsets(grid, dir)
  local rows, h, w, ok, err = patterns.dims(grid)
  if not rows then return nil, err end
  if not ok then return nil, err end
  local cx = math.floor(w / 2)
  local cy = math.floor(h / 2)
  local out = {}
  for r = 1, h do
    local line = rows[r]
    for c = 1, w do
      if patterns.cellEnabled(line:sub(c, c), dir) then
        out[#out + 1] = { c - 1 - cx, r - 1 - cy }
      end
    end
  end
  return out
end

-- Exact port of AttackBot.lua's extractDirGrid() (line 1178): rewrite one
-- letter to '1' and every other character to '0', producing a pure 0/1 grid
-- for a single facing. Used by getWaveBestDir so a letter grid can be passed
-- with a plain table position (which would otherwise mean direction 8 and
-- kill every letter cell). Return value keeps the original's leading and
-- trailing newlines.
function patterns.dirGrid(letterGrid, letter)
  local rows = patterns.rows(letterGrid)
  if not rows then return nil end
  local out = {}
  for _, line in ipairs(rows) do
    local chars = {}
    for ch in line:gmatch(".") do
      chars[#chars + 1] = (ch == letter) and "1" or "0"
    end
    out[#out + 1] = table.concat(chars)
  end
  return "\n" .. table.concat(out, "\n") .. "\n"
end

-- Same, addressed by direction number rather than letter.
function patterns.dirGridFor(letterGrid, dir)
  local letter = patterns.DIR_LETTERS[dir]
  if not letter then return nil end
  return patterns.dirGrid(letterGrid, letter)
end

-- ===========================================================================
-- Accessors
-- ===========================================================================

-- patterns.get(patternCategory, id [, safe]) -> grid string | nil
-- safe == true selects the PVP-safe grid ([2]); otherwise the normal one ([1]).
-- Mirrors AttackBot.lua's getPattern(category, pattern, safe) (line 2519),
-- except it returns nil instead of erroring for the blank categories 1 and 3.
function patterns.get(category, id, safe)
  local cat = patterns.spellPatterns[category]
  if not cat then return nil end
  local entry = cat[id]
  if not entry then return nil end
  return entry[safe and 2 or 1]
end

-- patterns.monk(id, dir) -> grid string | nil     (dir 0=N 1=E 2=S 3=W)
function patterns.monk(id, dir)
  local byDir = patterns.monkDirPatterns[id]
  if not byDir then return nil end
  return byDir[dir]
end

-- patterns.dirSquare(dir, isKnight) -> grid string | nil
-- isKnight corresponds to `ek` (client vocation 1 Knight or 11 Elite Knight).
function patterns.dirSquare(dir, isKnight)
  local set = isKnight and patterns.dirSquares.knight or patterns.dirSquares.other
  return set[dir]
end

-- patterns.name(patternCategory, id) -> label | nil
function patterns.name(category, id)
  local t = patterns.NAMES[category]
  return t and t[id] or nil
end

-- Count of lit cells for a facing -- handy for sanity checks / tests.
function patterns.cellCount(grid, dir)
  local offs = patterns.offsets(grid, dir)
  return offs and #offs or nil
end

-- patterns.validate() -> { {where=..., err=...}, ... }
-- Every grid the engine would reject at runtime. Expected to be non-empty:
-- see section 5 of the header.
function patterns.validate()
  local bad = {}
  local function check(where, grid)
    local _, _, _, ok, err = patterns.dims(grid)
    if not ok then bad[#bad + 1] = { where = where, err = err } end
  end
  for cat = 1, #patterns.spellPatterns do
    for id = 1, #patterns.spellPatterns[cat] do
      check(string.format("spellPatterns[%d][%d][1]", cat, id), patterns.spellPatterns[cat][id][1])
      check(string.format("spellPatterns[%d][%d][2]", cat, id), patterns.spellPatterns[cat][id][2])
    end
  end
  for id, byDir in pairs(patterns.monkDirPatterns) do
    for dir = 0, 3 do
      check(string.format("monkDirPatterns[%d][%d]", id, dir), byDir[dir])
    end
  end
  for _, variant in ipairs({ "knight", "other" }) do
    for dir = 0, 3 do
      check(string.format("dirSquares.%s[%d]", variant, dir), patterns.dirSquares[variant][dir])
    end
  end
  return bad
end

return patterns
