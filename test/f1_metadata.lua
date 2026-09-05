--[[============================================================================
test/f1_metadata.lua -- offline checks for WORK ITEM F1:
    tools/extract_appearances.py v2  ->  assets/items1530.bin v2
    proto/items.lua v2 loader + derived predicates
    game/state.lua tile derived-flag cache and queries

  luajit test/f1_metadata.lua          (from D:/Claude/otclient_web/luaclient)

Exits non-zero if ANY check fails.  Nothing here touches the network.

Every expected item value below was produced INDEPENDENTLY of the .bin file, by
`python tools/extract_appearances.py --dump <id>`, which re-decodes the raw protobuf
appearance record.  The ids 386 (rope spot) and 1948 (ladder) are additionally
cross-checked against the user's real cavebot configs
(profiles/bot/vBot_4.8/cavebot_configs/*.cfg keys antiLostRopeIds / antiLostLadderIds).
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

-- =========================================================== tiny framework
local suites, cur = {}, nil
local totalPass, totalFail = 0, 0

local function suite(name)
    cur = { name = name, pass = 0, fail = 0 }
    suites[#suites + 1] = cur
    return cur
end

local function check(ok, desc, detail)
    if ok then
        cur.pass = cur.pass + 1
        totalPass = totalPass + 1
    else
        cur.fail = cur.fail + 1
        totalFail = totalFail + 1
        io.write('    FAIL  ', desc, detail and ('  -- ' .. tostring(detail)) or '', '\n')
    end
    return ok
end

local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    return check(false, desc, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local function raises(fn, pattern, desc)
    local ok, err = pcall(fn)
    if ok then return check(false, desc, 'no error was raised') end
    err = tostring(err)
    if pattern and not err:find(pattern, 1, true) then
        return check(false, desc, ('error %q does not contain %q'):format(err, pattern))
    end
    return check(true, desc)
end

local function runSuite(name, fn)
    suite(name)
    local ok, err = pcall(fn)
    if not ok then check(false, 'suite crashed', err) end
end

-- ============================================================== proto.items
local items = require('proto.items')

local loadSeconds, loadKb
runSuite('items v2: file format', function()
    collectgarbage('collect')
    local kb0 = collectgarbage('count')
    local t0 = os.clock()
    items.load(ROOT .. '/assets/items1530.bin')
    loadSeconds = os.clock() - t0
    collectgarbage('collect')
    loadKb = collectgarbage('count') - kb0

    eq(items.fileVersion, 2, 'the checked-in asset is format version 2')
    eq(items.MAX_ID, 62144, 'items.MAX_ID')
    eq(items.COUNT, 43536, 'items.COUNT (ids with an appearance)')
    eq(items.CREATURE_MAX_ID, 10003, 'items.CREATURE_MAX_ID')
    eq(items.EFFECT_MAX_ID, 343, 'items.EFFECT_MAX_ID')
    eq(items.MISSILE_MAX_ID, 82, 'items.MISSILE_MAX_ID')
    eq(items.CONTENT_REVISION, 42196, 'content revision in the header')
    eq(items.byteSize, 949392, 'file size')

    local S = items.sections
    local n = 0
    for _ in pairs(S) do n = n + 1 end
    eq(n, 12, 'the directory lists 12 sections')
    for _, sid in ipairs({ items.S_FLAGS1, items.S_FLAGS2, items.S_FLAGS3, items.S_FLAGS4,
                           items.S_FLAGS5, items.S_MINIMAPCOLOR, items.S_ELEVATION,
                           items.S_CLOTHSLOT }) do
        eq(S[sid].len, 62145, 'section ' .. sid .. ' is one byte per item id')
    end
    eq(S[items.S_GROUNDSPEED].len, 124290, 'GROUNDSPEED is two bytes per item id')
    eq(S[items.S_LENSHELP].len, 124290, 'LENSHELP is two bytes per item id')
    eq(S[items.S_NAMEIDX].len, 6 * 8951, 'NAMEIDX holds 8951 six-byte entries')
    eq(S[items.S_NAMEBLOB].len, 149730, 'NAMEBLOB is 149730 bytes')
    for sid, s in pairs(S) do
        check(s.off % 4 == 0, 'section ' .. sid .. ' payload is 4-byte aligned', s.off)
    end
end)

runSuite('items v2: id contract', function()
    -- unchanged v1 contract
    eq(items.flags(1), 0, 'id 1 is a hole -> flags 0, not an error')
    eq(items.flags2(1), 0, 'a hole reads 0 from FLAGS2 too')
    eq(items.groundSpeed(1), 0, 'a hole reads 0 from a u16 column')
    eq(items.name(1), nil, 'a hole has no name')
    eq(items.flags(130), items.CUMULATIVE, 'id 130 is CUMULATIVE (v1 vector)')
    eq(items.flags(645), items.CLASSIFY, 'id 645 is CLASSIFY (v1 vector)')
    eq(items.flags(111), items.CONTAINER, 'id 111 is CONTAINER (v1 vector)')
    check(items.flags(62144) ~= nil, 'the last id is readable')

    for _, fn in ipairs({ 'flags', 'flags2', 'flags3', 'flags4', 'flags5', 'groundSpeed',
                          'minimapColor', 'elevation', 'lensHelp', 'clothSlot', 'name' }) do
        raises(function() items[fn](0) end, 'out of range', fn .. '(0) raises')
        raises(function() items[fn](items.MAX_ID + 1) end, 'out of range',
               fn .. '(MAX_ID+1) raises')
    end
    raises(function() items.flags2('x') end, 'must be an integer', 'a non-number raises')
    raises(function() items.flags2(1.5) end, 'must be an integer', 'a fraction raises')
end)

-- Ten-plus known items.  Columns: id, name, FLAGS1..5, groundSpeed, minimapColor,
-- elevation, lensHelp, clothSlot -- all from `extract_appearances.py --dump <id>`.
local KNOWN = {
    -- id, name, f1, f2, f3, f4, f5, gs, mc, elev, lens, cloth, note
    { 3031, 'gold coin',                   0x01, 0x00, 0x01, 0x00, 0x01,   0,   0, 0,    0, 0 },
    { 3043, 'crystal coin',                0x01, 0x00, 0x01, 0x00, 0x01,   0,   0, 0,    0, 0 },
    { 2854, 'backpack',                    0x08, 0x00, 0x03, 0x00, 0x02,   0,   0, 0,    0, 3 },
    { 3160, 'ultimate healing rune',       0x01, 0x00, 0x07, 0x00, 0x03,   0,   0, 0,    0, 0 },
    { 2874, 'vial',                        0x01, 0x00, 0x17, 0x00, 0x02,   0,   0, 0,    0, 0 },
    { 2886, nil,                           0x01, 0x44, 0x20, 0x00, 0x00,   0,   0, 0,    0, 0 },
    {  103, nil,                           0x00, 0x41, 0x00, 0x02, 0x00, 110, 129, 0,    0, 0 },
    {  369, nil,                           0x00, 0x61, 0x00, 0x00, 0x00, 110, 210, 0,    0, 0 },
    {  386, nil,                           0x00, 0x41, 0x0A, 0x02, 0x00, 120, 210, 0, 1102, 0 },
    { 1948, nil,                           0x00, 0x44, 0x0A, 0x00, 0x00,   0, 210, 0, 1100, 0 },
    { 1025, nil,                           0x00, 0xD4, 0x00, 0x00, 0x00,   0, 114, 0,    0, 0 },
    {  140, 'parcel',                      0x00, 0x20, 0x01, 0x00, 0x06,   0,   0, 8,    0, 0 },
    { 3503, 'parcel',                      0x08, 0x20, 0x03, 0x00, 0x06,   0,   0, 8,    0, 0 },
    { 3994, 'dead rat',                    0x08, 0x00, 0x03, 0x08, 0x00,   0,   0, 0,    0, 0 },
    { 4242, 'dead human',                  0x00, 0x00, 0x01, 0x18, 0x00,   0,   0, 0,    0, 0 },
    { 9596, 'squeezing gear of girlpower', 0x00, 0x00, 0x07, 0x00, 0x02,   0,   0, 0,    0, 0 },
    { 3003, 'rope',                        0x00, 0x00, 0x07, 0x00, 0x02,   0,   0, 0,    0, 0 },
    { 3357, 'plate armor',                 0x10, 0x00, 0x01, 0x00, 0x02,   0,   0, 0,    0, 4 },
    {23473, 'furniture kit',               0x00, 0x20, 0x01, 0x80, 0x04,   0,   0, 8,    0, 0 },
    {  290, nil,                           0x00, 0x42, 0x00, 0x00, 0x00,   0,   0, 0,    0, 0 },
    {  244, nil,                           0x00, 0x48, 0x00, 0x00, 0x00,   0,   0, 0,    0, 0 },
}

runSuite('items v2: known items (name + every column)', function()
    for _, r in ipairs(KNOWN) do
        local id, name = r[1], r[2]
        local tag = 'id ' .. id .. (name and (' "' .. name .. '"') or '')
        eq(items.name(id),         name,  tag .. ' name')
        eq(items.flags(id),        r[3],  tag .. ' FLAGS1')
        eq(items.flags2(id),       r[4],  tag .. ' FLAGS2')
        eq(items.flags3(id),       r[5],  tag .. ' FLAGS3')
        eq(items.flags4(id),       r[6],  tag .. ' FLAGS4')
        eq(items.flags5(id),       r[7],  tag .. ' FLAGS5')
        eq(items.groundSpeed(id),  r[8],  tag .. ' groundSpeed')
        eq(items.minimapColor(id), r[9],  tag .. ' minimapColor')
        eq(items.elevation(id),    r[10], tag .. ' elevation')
        eq(items.lensHelp(id),     r[11], tag .. ' lensHelp')
        eq(items.clothSlot(id),    r[12], tag .. ' clothSlot')
    end
end)

runSuite('items v2: derived predicates', function()
    -- a gold coin is stackable and pickupable, and is NOT a container
    check(items.isStackable(3031),   'gold coin is stackable')
    check(items.isPickupable(3031),  'gold coin is pickupable')
    check(not items.isContainer(3031), 'gold coin is not a container')
    check(items.isCommon(3031),      'gold coin is a common item (stack priority 5)')
    eq(items.stackPriority(3031), items.PRIO_COMMON, 'gold coin stack priority')
    -- gold coin has no market block, so vBot's getMarketData().name is empty for it
    check(not items.hasMarket(3031), 'gold coin carries no market block')
    eq(items.marketName(3031), nil,  'gold coin has no market name (analyzer.lua hardcodes it)')
    eq(items.name(3031), 'gold coin', 'but Appearance.name is still there')
    eq(items.marketName(2854), 'backpack', 'backpack has a market name')

    -- a backpack is a container
    check(items.isContainer(2854),  'backpack is a container')
    check(items.isUsable(2854),     'backpack is usable')
    eq(items.clothSlot(2854), 3,    'backpack cloth slot 3')
    check(not items.isStackable(2854), 'backpack is not stackable')

    -- THE TRAP: a vial sets FLAGS1 CUMULATIVE (the protocol reads a u8 subtype) but is
    -- NOT Item::isStackable.  Merging loot into a vial stack would be wrong.
    check(items.has(2874, items.CUMULATIVE), 'vial sets the FLAGS1 CUMULATIVE read bit')
    check(items.isFluidContainer(2874),      'vial is a fluid container')
    check(not items.isStackable(2874),       'vial is NOT stackable (FLAGS5, not FLAGS1)')
    check(items.has(2886, items.CUMULATIVE), 'a splash sets the FLAGS1 CUMULATIVE read bit')
    check(items.isSplash(2886),              'a splash is a splash')
    check(not items.isStackable(2886),       'a splash is NOT stackable')

    -- a stone wall blocks walking and projectiles, and is on-bottom
    check(items.isNotWalkable(1025),     'wall 1025 is not walkable')
    check(items.isBlockProjectile(1025), 'wall 1025 blocks projectiles')
    check(items.isOnBottom(1025),        'wall 1025 is on-bottom')
    check(items.isNotMoveable(1025),     'wall 1025 is not moveable')
    check(not items.isCommon(1025),      'wall 1025 is not a common item')
    eq(items.stackPriority(1025), items.PRIO_ON_BOTTOM, 'wall stack priority is 2')

    -- rope spot / ladder / stairs ground
    check(items.isGround(386),    'rope spot 386 is a ground')
    check(items.isForceUse(386),  'rope spot 386 is force-use')
    eq(items.lensHelp(386), 1102, 'rope spot 386 lenshelp 1102 (NOT a floor change)')
    eq(items.minimapColor(386), 210, 'rope spot 386 minimap colour 210')
    check(items.isOnBottom(1948), 'ladder 1948 is on-bottom, not a ground')
    check(not items.isGround(1948), 'ladder 1948 is not a ground')
    eq(items.lensHelp(1948), 1100, 'ladder 1948 lenshelp 1100 (NOT a floor change)')
    -- the hasStairs rule of Map::findEveryPath: isNotPathable AND 210 <= colour <= 213
    check(items.isGround(369) and items.isNotPathable(369)
          and items.minimapColor(369) >= 210 and items.minimapColor(369) <= 213,
          'ground 369 satisfies the pathfinder stairs rule')

    -- a parcel is not pathable (you cannot path over it) but is pickupable, and it raises
    -- the tile (elevation 8)
    check(items.isNotPathable(140), 'parcel 140 is not pathable')
    check(not items.isNotWalkable(140), 'parcel 140 IS walkable')
    check(items.isPickupable(140),  'parcel 140 is pickupable')
    check(items.hasElevation(140),  'parcel 140 carries the elevation flag')
    eq(items.elevation(140), 8,     'parcel 140 elevation 8')
    check(items.isContainer(3503),  'the 3503 parcel variant is a container')

    -- corpses
    check(items.isCorpse(3994),        'dead rat is a corpse')
    check(items.isContainer(3994),     'dead rat is a container (loot goes in it)')
    check(items.isCorpse(4242) and items.isPlayerCorpse(4242), 'dead human is a player corpse')

    -- runes / tools
    check(items.isMultiUse(3160) and items.isUsable(3160), 'UH rune is a usable multi-use item')
    check(items.isStackable(3160),  'UH rune is stackable')
    check(items.isMultiUse(9596),   'the machete (9596) is multi-use')
    check(items.isMultiUse(3003),   'the rope (3003) is multi-use')

    -- misc FLAGS4
    check(items.isUnwrapable(23473), 'furniture kit is unwrapable')
    check(items.isFullGround(103),   'ground 103 is a full ground')
    check(items.isNotMoveable(103),  'ground 103 is not moveable')

    -- stack priorities across all five classes
    eq(items.stackPriority(103),  items.PRIO_GROUND,        'ground -> 0')
    eq(items.stackPriority(290),  items.PRIO_GROUND_BORDER, 'ground border -> 1')
    eq(items.stackPriority(1025), items.PRIO_ON_BOTTOM,     'on bottom -> 2')
    eq(items.stackPriority(244),  items.PRIO_ON_TOP,        'on top -> 3')
    eq(items.stackPriority(3031), items.PRIO_COMMON,        'common item -> 5')
end)

runSuite('items v2: v1 files still load', function()
    -- Build a synthetic v1 file (32-byte header + a flag table) and make sure the loader
    -- still reads it, with every v2 column reading 0.
    local path = os.tmpname()
    if path:sub(1, 1) == '/' or path:sub(2, 2) == ':' then else path = './' .. path end
    local itemLen = 300
    local tbl = {}
    for i = 1, itemLen do tbl[i] = '\0' end
    tbl[1 + 7] = string.char(0x08)     -- id 7 is a CONTAINER
    local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
    local function u32(v)
        return string.char(v % 256, math.floor(v / 256) % 256,
                           math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
    end
    local hdr = 'LCIT' .. string.char(1, 32) .. u16(4) .. u32(itemLen) .. u32(10) ..
                u32(10) .. u32(10) .. u32(42) .. u16(1234) .. u16(0)
    local f = assert(io.open(path, 'wb'))
    f:write(hdr .. table.concat(tbl))
    f:close()

    items.unload()
    items.load(path)
    eq(items.fileVersion, 1, 'a v1 file reports fileVersion 1')
    eq(items.MAX_ID, itemLen - 1, 'v1 MAX_ID')
    eq(items.flags(7), 0x08, 'v1 FLAGS1 still readable')
    eq(items.flags2(7), 0, 'a v1 file has no FLAGS2 -> reads 0')
    eq(items.groundSpeed(7), 0, 'a v1 file has no GROUNDSPEED -> reads 0')
    eq(items.name(7), nil, 'a v1 file has no names')
    check(not items.isNotWalkable(7), 'predicates degrade to false on a v1 file')
    raises(function() items.flags(0) end, 'out of range', 'v1 id 0 still raises')
    os.remove(path)

    items.unload()
    raises(function() items.flags(100) end, 'not loaded', 'unload() really unloads')
    items.load(ROOT .. '/assets/items1530.bin')   -- restore for the rest of the run
end)

-- ============================================================== game.state
local state = require('game.state')

local GROUND, GROUND2 = 103, 4526      -- speed 110 colour 129 / speed 150 colour 24
local STAIRS  = 369                    -- ground, avoid, colour 210
local WALL    = 1025                   -- onBottom, unpass, unsight, colour 114
local PARCEL  = 140                    -- avoid but walkable, elevation 8
local COIN    = 3031                   -- common, stackable
local SPLASH  = 2886                   -- onBottom, liquidpool
local ROPESPOT = 386                   -- ground + forceuse
local BED     = 26088                  -- common AND unmove
local ONTOP   = 244

local function mk()
    local st = state.new()
    st.player.id = 0x1000
    return st
end
local function P(x, y, z) return { x = x, y = y, z = z or 7 } end
local function put(st, pos, ...)
    for _, id in ipairs({ ... }) do
        st:addThing(pos, -2, { kind = 'item', id = id })
    end
end

runSuite('state: tile flag cache + walkability', function()
    local st = mk()
    check(st:tileFlagsExact(), 'the flag cache is flag-backed (item table loaded)')

    eq(st:tileFlags(P(1, 1)), nil, 'an unknown tile has no flags')
    eq(select(2, st:isWalkable(P(1, 1))), 'unknown-tile', 'unknown tile -> unknown-tile')
    eq(st:isPathable(P(1, 1)), false, 'an unknown tile is not pathable')

    put(st, P(10, 10), GROUND)
    eq(st:isWalkable(P(10, 10)), true, 'plain ground is walkable')
    eq(st:isPathable(P(10, 10)), true, 'plain ground is pathable')
    eq(st:getGroundSpeed(P(10, 10)), 110, 'ground speed comes from bank.waypoints')
    eq(st:getMinimapColorByte(P(10, 10)), 129, 'minimap colour comes from automap.color')
    eq(st:getGround(P(10, 10)).id, GROUND, 'getGround returns things[0]')
    check(st:isLookPossible(P(10, 10)), 'plain ground does not block projectiles')

    -- a wall on top of the ground
    put(st, P(11, 10), GROUND, WALL)
    eq(st:isWalkable(P(11, 10)), false, 'a wall makes the tile unwalkable')
    eq(select(2, st:isWalkable(P(11, 10))), 'item', 'and the reason is the item')
    eq(st:isPathable(P(11, 10)), true, 'a wall carries no `avoid`, so it stays pathable')
    check(not st:isLookPossible(P(11, 10)), 'a wall blocks projectiles')
    eq(st:getMinimapColorByte(P(11, 10)), 114, 'the wall wins the minimap colour (reverse scan)')

    -- a parcel: walkable but NOT pathable (this is the magic-field / parcel case)
    put(st, P(12, 10), GROUND, PARCEL)
    eq(st:isWalkable(P(12, 10)), true, 'a parcel is walkable')
    eq(st:isPathable(P(12, 10)), false, 'a parcel is not pathable')
    eq(st:elevation(P(12, 10)), 1, 'the parcel bumps the elevation counter')
    check(st:hasElevation(P(12, 10), 1), 'hasElevation(1)')
    check(not st:hasElevation(P(12, 10), 2), 'not hasElevation(2)')

    -- a common item at index 0 is NOT a ground
    put(st, P(13, 10), COIN)
    eq(st:isWalkable(P(13, 10)), false, 'a tile whose things[0] is a coin has no ground')
    eq(select(2, st:isWalkable(P(13, 10))), 'no-ground', 'and the reason is no-ground')
    eq(st:getGround(P(13, 10)), nil, 'getGround refuses a non-ground things[0]')
    eq(st:getGroundSpeed(P(13, 10)), 100, 'no ground -> the 100 fallback')
    eq(st:getMinimapColorByte(P(13, 10)), 255, 'a tile with only common items -> 255')

    -- the stairs rule the pathfinder uses
    put(st, P(14, 10), STAIRS)
    local color = st:getMinimapColorByte(P(14, 10))
    check(not st:isPathable(P(14, 10)) and color >= 210 and color <= 213,
          'a stairs tile is (not pathable AND colour 210..213)')

    -- cache invalidation: adding then removing must be seen
    local p = P(15, 10)
    put(st, p, GROUND)
    eq(st:isWalkable(p), true, 'ground only: walkable')
    put(st, p, WALL)
    eq(st:isWalkable(p), false, 'after adding a wall: not walkable (cache invalidated)')
    st:removeThing(p, 1)
    eq(st:isWalkable(p), true, 'after removing the wall: walkable again')

    -- getMinimapColorByte skips common items and the per-tile override wins
    put(st, P(16, 10), GROUND, COIN)
    eq(st:getMinimapColorByte(P(16, 10)), 129, 'a common item is skipped by the colour scan')
    st:tile(P(16, 10))._minimapColor = 77
    eq(st:getMinimapColorByte(P(16, 10)), 77, 'a per-tile override wins (Tile::m_minimapColor)')
    eq(st:getMinimapColor(P(99, 99)), 0, 'Map::getMinimapColor of a missing tile is 0')
    eq(st:getMinimapColor(P(99, 99), function() return 210 end), 210,
       'and it consults the minimap fallback')
end)

runSuite('state: creatures on tiles', function()
    local st = mk()
    local p = P(20, 20)
    put(st, p, GROUND)
    st:addCreature({ id = 55, name = 'Rat', type = 1 })          -- passable unknown -> blocks
    st:addThing(p, -1, { kind = 'creature', creatureId = 55, id = 0x63 })

    check(st:hasCreatures(p), 'hasCreatures sees the rat')
    check(st:hasCreature(p), 'hasCreature is the same predicate')
    eq(st:isWalkable(p), false, 'an unknown-passability creature blocks (m_passable = false)')
    eq(select(2, st:isWalkable(p)), 'creature', 'and the reason is the creature')
    eq(st:isWalkable(p, true), true, 'ignoreCreatures skips the creature loop')
    check(st:hasBlockingCreature(p), 'hasBlockingCreature sees it')
    eq(st:getTopCreature(p).creatureId, 55, 'getTopCreature')

    -- 0x92 CreatureUnpass said passable
    st.creatures[55].passable = true
    eq(st:isWalkable(p), true, 'a passable creature does not block')
    check(not st:hasBlockingCreature(p), 'nor does it block the pathfinder')

    -- an INVISIBLE monster: canBeSeen() is false, so Tile::isWalkable ignores it, but
    -- Tile::hasBlockingCreature (no canBeSeen test) still reports it.
    local q = P(21, 20)
    put(st, q, GROUND)
    st:addCreature({ id = 56, name = 'Ghost', type = 1,
                     outfit = { lookType = 0, lookTypeEx = 0 } })
    st:addThing(q, -1, { kind = 'creature', creatureId = 56, id = 0x63 })
    eq(st:isWalkable(q), true, 'an invisible monster does not make the tile unwalkable')
    check(st:hasBlockingCreature(q), 'but it IS a blocking creature for the pathfinder')

    -- the LOCAL PLAYER: isWalkable does NOT exempt it, hasBlockingCreature does
    local r = P(22, 20)
    put(st, r, GROUND)
    st:addCreature({ id = st.player.id, name = 'Me', type = 0 })
    st:addThing(r, -1, { kind = 'creature', creatureId = st.player.id, id = 0x63 })
    eq(st:isWalkable(r), false, 'your own tile is not walkable (no local-player exemption)')
    check(not st:hasBlockingCreature(r), 'but the local player is not a blocking creature')
end)

runSuite('state: getTopUseThing / getTopMoveThing', function()
    local st = mk()

    -- 1. the first isCommon non-splash thing wins
    local a = P(30, 30)
    put(st, a, GROUND, WALL, COIN)
    eq(st:getTopUseThing(a).id, COIN, 'getTopUseThing returns the first common item')

    -- 2. a force-use ground beats everything (this is the rope-spot / lever case)
    local b = P(31, 30)
    put(st, b, ROPESPOT, COIN)
    eq(st:getTopUseThing(b).id, ROPESPOT, 'a force-use thing wins even at index 0')

    -- 3. no common thing: scan backwards, skipping splashes, down to index 1
    local c = P(32, 30)
    put(st, c, GROUND, SPLASH)
    eq(st:getTopUseThing(c).id, GROUND, 'a splash is skipped and we fall back to things[0]')
    local d = P(33, 30)
    put(st, d, GROUND, WALL, SPLASH)
    eq(st:getTopUseThing(d).id, WALL, 'the backward scan returns the last non-splash')
    eq(st:getTopUseThing(P(34, 30)), nil, 'an unknown tile has no top use thing')

    -- getTopMoveThing
    local e = P(35, 30)
    put(st, e, GROUND, COIN)
    eq(st:getTopMoveThing(e).id, COIN, 'getTopMoveThing returns the first common item')
    local f = P(36, 30)
    put(st, f, GROUND, WALL, BED)         -- BED is common AND not moveable, at index 2
    eq(st:getTopMoveThing(f).id, WALL, 'an immovable common item yields the thing before it')
    local g = P(37, 30)
    put(st, g, GROUND, WALL)
    st:addCreature({ id = 91, type = 1 })
    st:addThing(g, -1, { kind = 'creature', creatureId = 91, id = 0x63 })
    eq(st:getTopMoveThing(g).creatureId, 91, 'with no common item, the first creature wins')
    local h = P(38, 30)
    put(st, h, GROUND, WALL)
    eq(st:getTopMoveThing(h).id, GROUND, 'and with neither, things[0]')
end)

runSuite('state: stack-priority insertion is flag-driven now', function()
    local st = mk()
    local p = P(40, 40)
    -- ground(0), onBottom(2), common(5); a creature (4) must land BETWEEN them.
    put(st, p, GROUND, WALL, COIN)
    st:addCreature({ id = 77, type = 1 })
    local at = st:addThing(p, -1, { kind = 'creature', creatureId = 77, id = 0x63 })
    eq(at, 2, 'an auto-placed creature sorts after on-bottom and before common items')
    eq(st:tile(p).things[3].creatureId, 77, 'and that is where it really is')

    -- an on-top item sorts after on-bottom, before creatures
    local q = P(41, 40)
    put(st, q, GROUND, WALL)
    local at2 = st:addThing(q, -1, { kind = 'item', id = ONTOP })
    eq(at2, 2, 'an auto-placed on-top item lands at index 2')

    -- a ground-border item sorts right after the ground
    local r = P(42, 40)
    put(st, r, GROUND, WALL)
    local at3 = st:addThing(r, -1, { kind = 'item', id = 290 })
    eq(at3, 1, 'an auto-placed ground border lands right after the ground')

    -- an explicit stackPriority still wins
    local s = P(43, 40)
    put(st, s, GROUND, WALL)
    -- append = (priority <= ON_TOP) = true, and the scan breaks on otherPriority > 0, so a
    -- pinned ground-priority coin lands AFTER the existing ground and before the wall.
    local at4 = st:addThing(s, -1, { kind = 'item', id = COIN, stackPriority = 0 })
    eq(at4, 1, 'an explicit stackPriority overrides the flags (ground priority -> index 1)')
    local at5 = st:addThing(s, -1, { kind = 'item', id = GROUND, stackPriority = 5 })
    eq(at5, 3, 'and a ground pinned to common priority sorts to the end')

    eq(state.stackPriorityOf({ kind = 'item', id = GROUND }), 0, 'stackPriorityOf ground')
    eq(state.stackPriorityOf({ kind = 'item', id = COIN }), 5, 'stackPriorityOf common item')
    eq(state.stackPriorityOf({ kind = 'creature', creatureId = 1 }), 4, 'stackPriorityOf creature')
end)

runSuite('state: isSightClear', function()
    local st = mk()
    for x = 0, 10 do put(st, P(x, 50), GROUND) end
    check(st:isSightClear(P(0, 50), P(0, 50)), 'a position always sees itself')
    check(st:isSightClear(P(0, 50), P(10, 50)), 'a clear line of ground is clear')
    put(st, P(5, 50), WALL)
    check(not st:isSightClear(P(0, 50), P(10, 50)), 'a wall halfway blocks the line')
    check(st:isSightClear(P(0, 50), P(4, 50)), 'but not a line that stops short of it')
    -- a MISSING tile is transparent (map.cpp:1200 `if (tile && !tile->isLookPossible())`)
    check(st:isSightClear(P(0, 60), P(10, 60)), 'unknown tiles do not block sight')
    -- the vertical tail: any thing on the intermediate floor blocks
    check(st:isSightClear(P(0, 70, 6), P(0, 70, 7)), 'an empty column is clear across floors')
    put(st, P(0, 70, 6), GROUND)
    check(not st:isSightClear(P(0, 70, 6), P(0, 70, 7)), 'a thing in the column blocks')
end)

runSuite('state: existing behaviour is untouched', function()
    -- walkableAt keeps its documented four-value reason contract
    local st = mk()
    eq(select(2, st:walkableAt(P(1, 1))), 'unknown-tile', 'walkableAt unknown-tile')
    put(st, P(1, 1), GROUND)
    eq(select(2, st:walkableAt(P(1, 1))), 'items-unknown', 'walkableAt items-unknown')
    put(st, P(1, 1), WALL)
    eq(select(2, st:walkableAt(P(1, 1))), 'items-unknown',
       'walkableAt still cannot see a wall (frozen v1 contract)')
    st:addCreature({ id = 5, type = 1 })
    st:addThing(P(1, 1), -1, { kind = 'creature', creatureId = 5, id = 0x63 })
    eq(select(2, st:walkableAt(P(1, 1))), 'creature', 'walkableAt creature')

    -- the 11-thing trim is unchanged
    local st2 = mk()
    local p = P(2, 2)
    for i = 1, 13 do st2:addThing(p, -2, { kind = 'item', id = 100 + i }) end
    eq(st2:thingCount(p), 11, 'a tile still keeps at most 11 things')

    -- the flag cache survives eviction: setCentralPosition drops tiles, not answers
    local st3 = mk()
    put(st3, P(1000, 1000), GROUND)
    put(st3, P(1030, 1000), GROUND)
    st3:setCentralPosition(P(1000, 1000))
    eq(st3:isWalkable(P(1000, 1000)), true, 'the central tile survives')
    eq(select(2, st3:isWalkable(P(1030, 1000))), 'unknown-tile', 'the evicted tile is unknown')
end)

runSuite('state: degrades without the item table', function()
    items.unload()
    local st = mk()
    check(not st:tileFlagsExact(), 'tileFlagsExact() reports the degraded mode')
    put(st, P(1, 1), GROUND, WALL)
    eq(st:isWalkable(P(1, 1)), true, 'without flags a wall cannot be seen (documented)')
    eq(st:getGroundSpeed(P(1, 1)), 100, 'and the ground speed falls back to 100')
    -- the v1 stack-priority heuristic comes back
    eq(state.stackPriorityOf({ kind = 'item', id = GROUND }), 5,
       'without flags every item is a common item')
    items.load(ROOT .. '/assets/items1530.bin')
end)

runSuite('perf: load time and tile recompute', function()
    items.unload()
    collectgarbage('collect')
    local kb0 = collectgarbage('count')
    local t0 = os.clock()
    items.load(ROOT .. '/assets/items1530.bin')
    local dt = os.clock() - t0
    collectgarbage('collect')
    local kb = collectgarbage('count') - kb0
    check(dt < 1.0, 'items.load takes under 1 s', ('%.1f ms'):format(dt * 1000))
    check(kb < 4096, 'items.load costs under 4 MB of Lua heap', ('%.0f KB'):format(kb))
    loadSeconds, loadKb = dt, kb

    -- names are looked up lazily (binary search + memo), so they must be cheap in bulk
    local t1 = os.clock()
    local n = 0
    for id = 1, items.MAX_ID do if items.name(id) then n = n + 1 end end
    local dtn = os.clock() - t1
    eq(n, 8951, 'every name in the index is reachable')
    check(dtn < 5.0, 'a full 62k name sweep is under 5 s', ('%.0f ms'):format(dtn * 1000))

    -- tile flag recompute: 40x40 aware area, 4 things each
    local st = mk()
    for x = 1, 40 do for y = 1, 40 do put(st, P(x, y), GROUND, WALL, COIN, ONTOP) end end
    local t2 = os.clock()
    for _ = 1, 10 do
        for x = 1, 40 do for y = 1, 40 do
            st:invalidateTile(P(x, y))
            st:isWalkable(P(x, y))
        end end
    end
    local dtt = (os.clock() - t2) / 10
    check(dtt < 0.050, 'a full 40x40 flag recompute + isWalkable sweep is under 50 ms',
          ('%.2f ms'):format(dtt * 1000))
    io.write(('    load %.1f ms, %.0f KB Lua heap (file %d bytes); ' ..
              'name sweep %.0f ms; 40x40 recompute %.2f ms\n')
             :format(loadSeconds * 1000, loadKb, items.byteSize, dtn * 1000, dtt * 1000))
end)

-- ================================================================== summary
io.write('\n================ F1 metadata selftest ================\n')
for _, s in ipairs(suites) do
    io.write(('  %-46s %s  %d passed'):format(s.name, s.fail == 0 and 'PASS' or 'FAIL', s.pass))
    if s.fail > 0 then io.write((', %d FAILED'):format(s.fail)) end
    io.write('\n')
end
io.write(('  ------------------------------------------------\n  TOTAL: %d passed, %d failed  -> %s\n')
         :format(totalPass, totalFail, totalFail == 0 and 'PASS' or 'FAIL'))
-- Embeddable in test/botsuite.lua: set _G.BOT_F1_NO_EXIT before dofile()ing this file
-- and it hands the counters back instead of exiting.
if _G.BOT_F1_NO_EXIT then
    local failures = {}
    for _, s in ipairs(suites) do
        if s.fail > 0 then failures[#failures + 1] = s.name end
    end
    return { pass = totalPass, fail = totalFail, failures = failures }
end
os.exit(totalFail == 0 and 0 or 1)
