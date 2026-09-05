--[[============================================================================
test/bot_f2_path.lua -- offline tests for work item F2 (bot/path.lua, bot/walker.lua,
bot/world.lua).  No network, no live account: everything runs against a synthetic world
built from ASCII maps.

    luajit test/bot_f2_path.lua            (from D:/Claude/otclient_web/luaclient)

Exits non-zero on any failure.

STUBS LIVE HERE, NEVER IN THE SHIPPING MODULES.  Work item F1 owns `assets/items1530.bin`
v2 and the `proto/items.lua` accessors listed in docs/vbot/gaps.md P0-1; until it lands this
file injects a fake `items` module carrying the same accessor names so the real predicates
can be exercised.  bot/world.lua reads them through `client.items`.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local state    = require('game.state')
local events   = require('lib.events')
local worldmod = require('bot.world')
local pathmod  = require('bot.path')
local walkmod  = require('bot.walker')

-- ============================================================ tiny framework
local pass, fail, msgs = 0, 0, {}
local section = ''
local function S(name) section = name; io.write('\n-- ', name, '\n') end
local function ok(cond, desc, detail)
    if cond then
        pass = pass + 1
        io.write('   ok   ', desc, '\n')
    else
        fail = fail + 1
        local line = '   FAIL ' .. section .. ' / ' .. desc
                     .. (detail and ('  -- ' .. tostring(detail)) or '')
        msgs[#msgs + 1] = line
        io.write(line, '\n')
    end
    return cond
end
local function eq(got, want, desc)
    if got == want then return ok(true, desc) end
    return ok(false, desc, ('got %s, want %s'):format(tostring(got), tostring(want)))
end
local function dirs2str(d)
    if d == nil then return 'nil' end
    local t = {}
    for i = 1, #d do t[i] = tostring(d[i]) end
    return '{' .. table.concat(t, ',') .. '}'
end
local function eqDirs(got, want, desc)
    local g, w = dirs2str(got), dirs2str(want)
    if g == w then return ok(true, desc .. ' = ' .. g) end
    return ok(false, desc, ('got %s, want %s'):format(g, w))
end

-- ============================================================ fake item table (F1's job)
-- Fields mirror the appearance flags of docs/vbot/gaps.md P0-1.
local ITEMS = {
    [100] = { ground = true, speed = 100 },                      -- plain floor
    [101] = { ground = true, speed = 50  },                      -- fast floor
    [102] = { ground = true, speed = 250 },                      -- slow floor
    [200] = { unpass = true, unsight = true },                   -- wall
    [300] = { avoid = true },                                    -- magic field (fire)
    [400] = { avoid = true, color = 210 },                       -- yellow + non-pathable = stairs
    [401] = { avoid = true, color = 210, ground = true, speed = 100 }, -- stairs GROUND tile
    [500] = { lens = 1100 },                                     -- ladder (NOT a floor change)
    [501] = { lens = 1104 },                                     -- stairs up (IS a floor change)
    [600] = { ground = true, avoid = true, speed = 100 },        -- hole ground
    [700] = { },                                                 -- ordinary common item
}
local function I(id) return ITEMS[id] or {} end
local fakeItems = {
    isGround          = function(id) return I(id).ground == true end,
    isGroundBorder    = function(id) return I(id).clip   == true end,
    isOnBottom        = function(id) return I(id).bottom == true end,
    isOnTop           = function(id) return I(id).top    == true end,
    isNotWalkable     = function(id) return I(id).unpass == true end,
    isNotPathable     = function(id) return I(id).avoid  == true end,
    isBlockProjectile = function(id) return I(id).unsight== true end,
    isForceUse        = function(id) return I(id).forceuse == true end,
    isSplash          = function(id) return I(id).splash == true end,
    groundSpeed       = function(id) return I(id).speed or 0 end,
    minimapColor      = function(id) return I(id).color or 0 end,
    elevation         = function(id) return I(id).elev  or 0 end,
    lensHelp          = function(id) return I(id).lens  or 0 end,
}

-- ============================================================ synthetic world
-- ASCII legend (one char per tile, row 1 = north):
--   '.'  plain floor          '#'  floor + wall            ' '  NO TILE (never described)
--   '~'  floor + fire field   'Y'  stairs ground (yellow + non-pathable)
--   'H'  hole ground          'L'  floor + ladder item     'U'  floor + stairs-up item
--   'm'  floor + blocking monster                          'p'  floor + passable creature
--   'f'  fast floor (speed 50)                             's'  slow floor (speed 250)
--   '@'  floor, marks the start                            'X'  floor, marks the goal
local nextCreatureId = 1000

local function newWorld(rows, opts)
    opts = opts or {}
    local st = state.new()
    local baseX = opts.baseX or 1000
    local baseY = opts.baseY or 1000
    local z     = opts.z or 7
    -- Synthetic aware window: the real one is 18x14 (game/state.lua:160).  Widening it here
    -- keeps every fixture tile "live" so the tests exercise the aware branch of
    -- Map::findEveryPath; the unseen tests deliberately leave holes INSIDE the window and
    -- the minimap test narrows it back.
    local a = st.world.awareRange
    a.left, a.top, a.right, a.bottom = opts.aware or 80, opts.aware or 80,
                                       opts.aware or 80, opts.aware or 80

    local start, goal
    for y = 1, #rows do
        local row = rows[y]
        for x = 1, #row do
            local ch = row:sub(x, x)
            local pos = { x = baseX + x - 1, y = baseY + y - 1, z = z }
            local ground, extra, creature = nil, nil, nil
            if ch == '.' or ch == '@' or ch == 'X' then ground = 100
            elseif ch == 'f' then ground = 101
            elseif ch == 's' then ground = 102
            elseif ch == '#' then ground, extra = 100, 200
            elseif ch == '~' then ground, extra = 100, 300
            elseif ch == 'Y' then ground = 401
            elseif ch == 'H' then ground = 600
            elseif ch == 'L' then ground, extra = 100, 500
            elseif ch == 'U' then ground, extra = 100, 501
            elseif ch == 'm' then ground, creature = 100, 'monster'
            elseif ch == 'p' then ground, creature = 100, 'passable'
            elseif ch == ' ' then ground = nil
            else error('bad map char ' .. ch) end
            if ground then
                st:addThing(pos, 0, { kind = 'item', id = ground })
                if extra then st:addThing(pos, -2, { kind = 'item', id = extra }) end
                if creature then
                    nextCreatureId = nextCreatureId + 1
                    local id = nextCreatureId
                    st:addCreature({ id = id, name = 'mob' .. id, type = 1,
                                     pos = pos, healthPercent = 100,
                                     passable = (creature == 'passable'),
                                     outfit = { lookType = 128, lookTypeEx = 0 } })
                    st:addThing(pos, -2, { kind = 'creature', creatureId = id, id = 0x63 })
                end
            end
            if ch == '@' then start = pos end
            if ch == 'X' then goal = pos end
        end
    end

    st.player.id    = 1
    st.player.pos   = start or { x = baseX, y = baseY, z = z }
    st.player.speed = opts.speed or 220
    st.central      = { x = st.player.pos.x, y = st.player.pos.y, z = st.player.pos.z }

    local client = { state = st, items = fakeItems, events = events.new(),
                     log = { warn = function() end, info = function() end,
                             debug = function() end, error = function() end } }
    local w = worldmod.new(client)
    local p = pathmod.new(client, w)
    return { st = st, client = client, world = w, path = p,
             start = start, goal = goal, base = { x = baseX, y = baseY, z = z } }
end

-- ============================================================================
S('world: item metadata level')
do
    local F = newWorld({ '@.X' })
    eq(F.world.itemDataLevel, 'full', 'fake v2 item table satisfies every accessor')
end

-- ============================================================================
S('world: degraded mode (items1530.bin v1, before work item F1 lands)')
do
    -- This is what main.lua boots with TODAY.  The modules must stay usable: no crash, the
    -- level is reported, and the fallbacks equal what game/state.lua:512-537 can decide --
    -- ground = "things[1] is an item", nothing blocks, speed 100, colour 0/255.
    local F = newWorld({ '@#..X' })
    local warned = {}
    local client = { state = F.st, items = {}, events = events.new(),
                     log = { warn = function(fmt, ...) warned[#warned + 1] = fmt end,
                             info = function() end, debug = function() end,
                             error = function() end } }
    local w = worldmod.new(client)
    local p = pathmod.new(client, w)
    eq(w.itemDataLevel, 'degraded', 'the level is reported as degraded')
    eq(#warned, 1, 'and a single warning was logged')
    ok(#w.missingItemApi == 13, 'all 13 accessors are listed as missing ('
       .. #w.missingItemApi .. ')')
    local d = p:getPath(F.start, F.goal, 20, {})
    eqDirs(d, { 1, 1, 1, 1 }, 'pathing still works -- but walks THROUGH the wall it cannot see')
    eq(w:groundSpeed(F.st:tile(F.start)), 100, 'ground speed falls back to 100')
    eq(w:isSightClear(F.start, F.goal), true, 'isSightClear fails open, as vBot does')
end

-- ============================================================================
S('path: a straight line')
do
    local F = newWorld({ '@....X' })
    local d, why = F.path:getPath(F.start, F.goal, 20, {})
    eqDirs(d, { 1, 1, 1, 1, 1 }, 'five steps east')
    eq(why, nil, 'no failure reason')

    local back = F.path:getPath(F.goal, F.start, 20, {})
    eqDirs(back, { 3, 3, 3, 3, 3 }, 'and five steps back west')

    local here = F.path:getPath(F.start, F.start, 20, {})
    ok(here ~= nil and #here == 0, 'standing on the destination yields {} (empty but truthy)')
end

-- ============================================================================
S('path: around a wall')
do
    -- a wall with a single gap at the bottom row
    local F = newWorld({
        '.....',
        '.@#X.',
        '..#..',
        '.....',
    })
    local d = F.path:getPath(F.start, F.goal, 30, {})
    ok(d ~= nil, 'a path exists around the wall')
    if d then
        local pts = pathmod.positionsOf(F.start, d)
        eq(pts[#pts].x, F.goal.x, 'path ends on the goal (x)')
        eq(pts[#pts].y, F.goal.y, 'path ends on the goal (y)')
        local steppedOnWall = false
        for i = 1, #pts do
            local tile = F.st:tile(pts[i])
            if tile and F.world:notWalkable(tile) then steppedOnWall = true end
        end
        ok(not steppedOnWall, 'no step lands on an unpass tile')
        io.write('        route: ', dirs2str(d), '  (', #d, ' steps)\n')
    end
end

-- ============================================================================
S('path: diagonal handling (multiplier 3.0, no corner-cut rule)')
do
    -- open field: the goal is one NE step away.  diagonal = 100*3 = 300, but
    -- E then N = 100 + 100 = 200, so the pathfinder must prefer the TWO straight steps.
    local F = newWorld({
        '..X',
        '.@.',
        '...',
    })
    local d = F.path:getPath(F.start, F.goal, 10, {})
    eq(d and #d, 2, 'a NE goal is reached in two straight steps, not one diagonal')
    io.write('        route: ', dirs2str(d), '\n')

    -- with ignoreCost every edge is 1, so the single diagonal wins
    local d2 = F.path:getPath(F.start, F.goal, 10, { ignoreCost = true })
    eqDirs(d2, { 4 }, 'ignoreCost=1 per edge makes the single NE diagonal optimal')

    -- corner case: both orthogonals blocked, only the diagonal is open.
    -- findEveryPath has NO corner-cutting prevention, so the diagonal is taken.
    local G2 = newWorld({
        '.#X',
        '.@#',
        '...',
    })
    local d3 = G2.path:getPath(G2.start, G2.goal, 10, {})
    eqDirs(d3, { 4 }, 'diagonal squeeze between two blocked orthogonals is allowed')
end

-- ============================================================================
S('path: blocked by a creature')
do
    local F = newWorld({ '@m..X' })
    local d, why = F.path:getPath(F.start, F.goal, 20, {})
    eq(d, nil, 'a blocking creature in a one-tile corridor kills the path')
    eq(why, 'no-path', 'reason is no-path')

    local d2 = F.path:getPath(F.start, F.goal, 20, { ignoreCreatures = true })
    eqDirs(d2, { 1, 1, 1, 1 }, 'ignoreCreatures walks straight through it')

    -- a PASSABLE creature never blocks (Creature::isPassable, set by 0x92)
    local G = newWorld({ '@p..X' })
    local d3 = G.path:getPath(G.start, G.goal, 20, {})
    eqDirs(d3, { 1, 1, 1, 1 }, 'a passable creature does not block')

    -- ignoreLastCreature: the creature's own tile is reachable-as-a-final-step at cost +100
    local H = newWorld({ '@.m' })
    local mpos = { x = H.base.x + 2, y = H.base.y, z = H.base.z }
    local d4 = H.path:getPath(H.start, mpos, 20, { ignoreLastCreature = true })
    eqDirs(d4, { 1, 1 }, 'ignoreLastCreature reaches the creature tile')
    local field = H.path:findEveryPath(H.start, 20,
        { ignoreLastCreature = true, destination = mpos })
    local total, dist, dir = field:node(mpos.x, mpos.y)
    eq(dist, 2, 'the creature entry records distance 2')
    eq(total, 100 + 100, 'and totalCost = prev(100) + the 100 surcharge')
    eq(dir, 1, 'with the direction that would enter it (East)')
    local d5 = H.path:getPath(H.start, mpos, 20, {})
    eq(d5, nil, 'without ignoreLastCreature the creature tile is unreachable')
end

-- ============================================================================
S('path: unseen tiles')
do
    -- CASE 1 -- AWARE but never described.  map.cpp:1406-1414: the tile pointer is null, so
    -- the DEFAULTS stand: wasSeen=false, isNotWalkable=true, isNotPathable=true, speed=1000.
    -- `isNotWalkable` has no destination exemption and vBot never passes ignoreNonWalkable,
    -- so such a tile is blocked even WITH allowUnseen.
    local F = newWorld({ '@.  ..X' })
    local d, why = F.path:getPath(F.start, F.goal, 20, {})
    eq(d, nil, 'aware-but-missing tiles are not wasSeen, so the path fails')
    eq(why, 'no-path', 'reason is no-path')

    eq(F.path:getPath(F.start, F.goal, 20, { allowUnseen = true }), nil,
       'allowUnseen alone is NOT enough: the tile also defaults to notWalkable + notPathable')

    local d2 = F.path:getPath(F.start, F.goal, 20,
        { allowUnseen = true, ignoreNonWalkable = true, ignoreNonPathable = true })
    eqDirs(d2, { 1, 1, 1, 1, 1, 1 },
           'all three flags together are what it takes to cross an aware-but-missing tile')

    -- and they cost 1000 each (map.cpp:1405), not 100
    local field = F.path:findEveryPath(F.start, 20,
        { allowUnseen = true, ignoreNonWalkable = true, ignoreNonPathable = true,
          destination = F.goal })
    local total = field:node(F.goal.x, F.goal.y)
    eq(total, 100 + 1000 + 1000 + 100 + 100 + 100, 'unknown tiles cost 1000 per step')

    -- CASE 2 -- OUTSIDE the aware window with no minimap store: the C++ "nulltile"
    -- {flags=0, colour=255, speed=10} => wasSeen=false but walkable/pathable at speed 100.
    local narrow = newWorld({ '@.....X' }, { aware = 2 })
    eq(narrow.path:getPath(narrow.start, narrow.goal, 20, {}), nil,
       'unaware tiles are refused without allowUnseen')
    local d3 = narrow.path:getPath(narrow.start, narrow.goal, 20, { allowUnseen = true })
    eqDirs(d3, { 1, 1, 1, 1, 1, 1 }, 'allowUnseen plans straight through unexplored space')
    local f2 = narrow.path:findEveryPath(narrow.start, 20,
                                         { allowUnseen = true, destination = narrow.goal })
    eq(f2:node(narrow.goal.x, narrow.goal.y), 600,
       'nulltile speed byte 10 -> 100 per step (6 x 100)')

    -- allowOnlyVisibleTiles kills the minimap branch entirely
    eq(narrow.path:getPath(narrow.start, narrow.goal, 20,
                           { allowUnseen = true, allowOnlyVisibleTiles = true }), nil,
       'allowOnlyVisibleTiles refuses tiles outside the aware window')
end

-- ============================================================================
S('path: the minimap (known store) fallback')
do
    -- tiles outside the aware window come from the persistent MinimapTile store
    local F = newWorld({ '@.....X' }, { aware = 2 })
    local known = { tiles = {} }
    function known:get(pos)
        local t = self.tiles[pos.x .. ',' .. pos.y .. ',' .. pos.z]
        if not t then return 0, 255, 10 end          -- the C++ "nulltile"
        return t[1], t[2], t[3]
    end
    for i = 0, 6 do
        known.tiles[(F.base.x + i) .. ',' .. F.base.y .. ',' .. F.base.z] =
            { worldmod.KNOWN_WAS_SEEN, 255, 10 }     -- seen, walkable, speed byte 10 -> 100
    end
    local w2 = worldmod.new(F.client, { known = known })
    local p2 = pathmod.new(F.client, w2)
    local d = p2:getPath(F.start, F.goal, 20, {})
    eqDirs(d, { 1, 1, 1, 1, 1, 1 }, 'known-store tiles are walkable at speed byte*10')

    known.tiles[(F.base.x + 3) .. ',' .. F.base.y .. ',' .. F.base.z] =
        { worldmod.KNOWN_NOT_WALKABLE, 255, 10 }
    local d2 = p2:getPath(F.start, F.goal, 20, {})
    eq(d2, nil, 'a NotWalkable minimap tile blocks (and implies wasSeen)')
end

-- ============================================================================
S('path: fields, stairs and the destination exemptions')
do
    -- a magic field is walkable but NOT pathable: it blocks unless ignoreNonPathable
    local F = newWorld({ '@~..X' })
    eq(F.path:getPath(F.start, F.goal, 20, {}), nil, 'a fire field blocks by default')
    eqDirs(F.path:getPath(F.start, F.goal, 20, { ignoreNonPathable = true }),
           { 1, 1, 1, 1 }, 'ignoreNonPathable ("ignore fields") crosses it')

    -- hasStairs = non-pathable AND minimap colour 210-213
    local G = newWorld({ '@Y..X' })
    eq(G.path:getPath(G.start, G.goal, 20, { ignoreNonPathable = true }), nil,
       'a yellow non-pathable tile blocks even with ignoreNonPathable (the stairs rule)')
    local stairsPos = { x = G.base.x + 1, y = G.base.y, z = G.base.z }
    eqDirs(G.path:getPath(G.start, stairsPos, 20, { ignoreNonPathable = true }), { 1 },
           'but the stairs tile is reachable AS the destination')

    -- isNotWalkable has NO destination exemption
    local H = newWorld({ '@#' })
    local wallPos = { x = H.base.x + 1, y = H.base.y, z = H.base.z }
    eq(H.path:getPath(H.start, wallPos, 20, { ignoreNonPathable = true }), nil,
       'an unpass tile is never reachable, not even as the destination')
end

-- ============================================================================
S('path: no path at all')
do
    local F = newWorld({
        '###',
        '#X#',
        '###',
        '...',
        '.@.',
    })
    local d, why = F.path:getPath(F.start, F.goal, 30, {})
    eq(d, nil, 'a walled-in destination is unreachable')
    eq(why, 'no-path', 'reason is no-path')

    local far = { x = F.base.x, y = F.base.y - 50, z = F.base.z }
    local d2, why2 = F.path:getPath(F.start, far, 5, {})
    eq(d2, nil, 'maxDistance cuts the search off')
    eq(why2, 'no-path', 'and reports no-path')

    local other = { x = F.goal.x, y = F.goal.y, z = F.goal.z + 1 }
    local d3, why3 = F.path:getPath(F.start, other, 30, {})
    eq(d3, nil, 'a destination on another floor is refused outright')
    eq(why3, 'different-floor', 'reason is different-floor')
end

-- ============================================================================
S('path: maxComplexity cutoff')
do
    local rows = {}
    for y = 1, 41 do rows[y] = string.rep('.', 41) end
    local F = newWorld(rows)
    local start = { x = F.base.x + 20, y = F.base.y + 20, z = F.base.z }
    local goal  = { x = F.base.x + 40, y = F.base.y + 20, z = F.base.z }
    F.st.player.pos = start
    F.st.central = start

    local d, why = F.path:getPath(start, goal, 40, { maxComplexity = 50 })
    eq(d, nil, 'a 50-cell complexity budget cannot reach 20 tiles away')
    eq(why, 'max-complexity', 'reason is max-complexity')

    local field = F.path:findEveryPath(start, 40, { maxComplexity = 50 })
    ok(field.truncated, 'the field is flagged truncated')
    ok(field.complexity > 50 and field.complexity <= 58,
       'the cutoff fires just past the budget (classified=' .. field.complexity .. ')')

    local d2, why2 = F.path:getPath(start, goal, 40, {})
    ok(d2 ~= nil and #d2 == 20, 'the same search without a budget succeeds in 20 steps')
end

-- ============================================================================
S('path: precision and margin fallbacks')
do
    -- precision: the exact destination is a wall, so fall back to the cheapest tile within p
    local F = newWorld({ '@..#.' })
    local wall = { x = F.base.x + 3, y = F.base.y, z = F.base.z }
    eq(F.path:getPath(F.start, wall, 20, {}), nil, 'precision 0: the wall itself or nothing')
    eqDirs(F.path:getPath(F.start, wall, 20, { precision = 1 }), { 1, 1 },
           'precision 1 stops on the adjacent tile')

    -- margin: path to the cheapest tile in the Chebyshev ring [min,max] around the goal
    local rows = {}
    for y = 1, 15 do rows[y] = string.rep('.', 15) end
    local G = newWorld(rows)
    local start = { x = G.base.x, y = G.base.y + 7, z = G.base.z }
    local goal  = { x = G.base.x + 12, y = G.base.y + 7, z = G.base.z }
    G.st.player.pos, G.st.central = start, start
    local d = G.path:getPath(start, goal, 30, { marginMin = 3, marginMax = 4 })
    ok(d ~= nil, 'margin mode finds a ring tile')
    if d then
        local e = pathmod.endPosition(start, d)
        local cheb = math.max(math.abs(e.x - goal.x), math.abs(e.y - goal.y))
        ok(cheb >= 3 and cheb <= 4, 'and it lands in the ring (chebyshev ' .. cheb .. ')')
    end
end

-- ============================================================================
S('path: neighbour order is the tie-breaker (NW, W, SW, N, S, NE, E, SE)')
do
    eq(#pathmod.NEIGHBOUR_ORDER, 8, 'eight neighbours')
    local order = {}
    for i = 1, 8 do
        local n = pathmod.NEIGHBOUR_ORDER[i]
        order[i] = worldmod.DIR[n[1]][n[2]]
    end
    eqDirs(order, { 7, 3, 6, 0, 2, 4, 1, 5 }, 'scan order in Otc::Direction terms')
end

-- ============================================================================
S('path: 40x40 open area timing')
do
    local N = 41
    local rows = {}
    for y = 1, N do rows[y] = string.rep('.', N) end
    local F = newWorld(rows)
    local start = { x = F.base.x + 20, y = F.base.y + 20, z = F.base.z }   -- centre
    local goal  = { x = F.base.x + 40, y = F.base.y + 20, z = F.base.z }   -- east edge
    F.st.player.pos, F.st.central = start, start

    -- NOTE: the far DIAGONAL corner (+40,+40) is deliberately NOT used as the goal.  A
    -- diagonal step costs 3x a straight one, so Dijkstra's cheapest route there is 80
    -- straight steps; `node.distance` follows the CHEAPEST relaxation, so maxDistance=40
    -- cuts the search off before it arrives.  That is the real client's behaviour
    -- (map.cpp:1455-1461 sets distance inside the strict-less-than relaxation).
    for _ = 1, 5 do F.path:getPath(start, goal, 40, {}) end                -- warm up

    local reps = 50
    local t0 = os.clock()
    local d
    for _ = 1, reps do d = F.path:getPath(start, goal, 40, {}) end
    local ms = (os.clock() - t0) * 1000 / reps

    ok(d ~= nil, 'the east edge, 20 tiles away, is reachable')
    eq(d and #d, 20, 'in 20 steps')

    -- the full Dijkstra field over the whole 40x40 area (no destination -> no early break)
    local t1 = os.clock()
    local field
    for _ = 1, reps do field = F.path:findEveryPath(start, 40, {}) end
    local msField = (os.clock() - t1) * 1000 / reps

    io.write(string.format('        %dx%d open area, maxDistance 40:\n', N, N))
    io.write(string.format('          getPath to a 20-tile goal : %.3f ms  (%d reps)\n', ms, reps))
    io.write(string.format('          FULL field (every tile)   : %.3f ms  '
                           .. '(%d cells classified, %d pops)\n',
                           msField, field.complexity, field.pops))
    ok(ms < 10, string.format('getPath is well under 10 ms (%.3f ms)', ms))
    ok(msField < 10, string.format('the full field is well under 10 ms (%.3f ms)', msField))
end

-- ============================================================================
S('world: predicates')
do
    local F = newWorld({ '@#~L' })
    local b = F.base
    local wall  = { x = b.x + 1, y = b.y, z = b.z }
    local field = { x = b.x + 2, y = b.y, z = b.z }
    local lad   = { x = b.x + 3, y = b.y, z = b.z }

    local okw, why = F.world:tileWalkable(wall, {})
    eq(okw, false, 'a wall is not walkable'); eq(why, 'not-walkable', 'reason')
    okw, why = F.world:tileWalkable(field, {})
    eq(okw, false, 'a field is refused by default'); eq(why, 'not-pathable', 'reason')
    okw = F.world:tileWalkable(field, { ignoreNonPathable = true })
    eq(okw, true, 'a field IS walkable with ignoreNonPathable (walkable, not pathable)')
    okw, why = F.world:tileWalkable({ x = b.x + 9, y = b.y, z = b.z }, {})
    eq(okw, false, 'an undescribed tile is refused'); eq(why, 'unknown-tile', 'reason')

    eq(F.world:groundSpeed(F.st:tile(F.start)), 100, 'plain ground speed 100')
    local G = newWorld({ '@fs' })
    eq(G.world:groundSpeed(G.st:tile({ x = G.base.x + 1, y = G.base.y, z = G.base.z })), 50,
       'fast ground speed 50')
    eq(G.world:groundSpeed(G.st:tile({ x = G.base.x + 2, y = G.base.y, z = G.base.z })), 250,
       'slow ground speed 250')

    eq(F.world:minimapColor(F.st:tile(F.start)), 255, 'no automap colour -> 255')
    local H = newWorld({ 'Y' })
    eq(H.world:minimapColor(H.st:tile(H.base)), 210, 'the stairs ground reports colour 210')

    -- isSightClear: a wall carries `unsight`
    local K = newWorld({ '@#X' })
    eq(K.world:isSightClear(K.start, K.goal), false, 'a wall blocks the projectile line')
    local L = newWorld({ '@.X' })
    eq(L.world:isSightClear(L.start, L.goal), true, 'an open line is clear')
    eq(L.world:isSightClear(L.start, L.start), true, 'from == to is always clear')

    eq(worldmod.distance({ x = 0, y = 0 }, { x = 3, y = 1 }), 3, 'distance is Chebyshev')
    eq(F.world:distance({ x = 0, y = 0 }, { x = 3, y = 1 }), 3, 'and works as a method')
end

-- ============================================================================
S('world: spectators / monsters / countInArea')
do
    local F = newWorld({
        '.m.',
        'm@m',
        '.m.',
    })
    eq(#F.world:monsters(F.start, 1), 4, 'four monsters around the player')
    eq(#F.world:players(F.start, 5), 0, 'no players')
    eq(#F.world:spectators(F.start, false), 4, 'four spectators on this floor')
    -- a 3x3 plus-shaped pattern
    eq(F.world:countInArea(F.start, '010\n111\n010', 8), 4, 'plus pattern counts 4 monsters')
    eq(F.world:countInArea(F.start, '000\n010\n000', 8), 0, 'centre-only counts 0 (the player)')
    eq(F.world:countInArea(F.start, '00\n11', 8), 0, 'even-sided patterns are refused')
    -- letter cells are direction gated
    eq(F.world:countInArea(F.start, '0N0\n000\n000', 0), 1, 'N cell active when facing north')
    eq(F.world:countInArea(F.start, '0N0\n000\n000', 2), 0, 'and inactive when facing south')
end

-- ============================================================================
S('world/path: the floor-change guard')
do
    -- 'U' carries lenshelp 1104 (stairs up); 'H' is a non-pathable GROUND (a hole)
    local F = newWorld({ '@.U.X' })
    local b = F.base
    local stairs = { x = b.x + 2, y = b.y, z = b.z }
    local bad, why = F.world:isFloorChangeTile(stairs, {})
    eq(bad, true, 'a lenshelp-1104 item makes the tile a floor change')
    io.write('        reason: ', tostring(why), '\n')

    local d = F.path:getPath(F.start, F.goal, 20, { ignoreNonPathable = true })
    ok(d ~= nil, 'the pathfinder itself happily crosses it')
    local crosses, r = F.path:crossesFloorChange(F.start, F.goal, d, {})
    eq(crosses, true, 'but the floor-change guard refuses the path')

    -- a goto ONTO the transfer tile is intentional and must be allowed
    local d2 = F.path:getPath(F.start, stairs, 20, { ignoreNonPathable = true })
    eq(F.path:crossesFloorChange(F.start, stairs, d2, {}), false,
       'the exact destination is exempt')

    -- ladders (lenshelp 1100) are DELIBERATELY not floor changes
    local G = newWorld({ '@.L.X' })
    eq(G.world:isFloorChangeTile({ x = G.base.x + 2, y = G.base.y, z = G.base.z }, {}), false,
       'lenshelp 1100 (ladder) is excluded on purpose')

    -- a hole ground (ground item carrying `avoid`)
    local H = newWorld({ '@.H.X' })
    eq(H.world:isFloorChangeTile({ x = H.base.x + 2, y = H.base.y, z = H.base.z }, {}), true,
       'a non-pathable GROUND item is a floor change')

    -- avoidTileIds
    local K = newWorld({ '@.L.X' })
    eq(K.world:isFloorChangeTile({ x = K.base.x + 2, y = K.base.y, z = K.base.z },
                                 worldmod.parseIdList('500,777')), true,
       'an id listed in avoidTileIds counts')

    eq(K.world:wouldStepChangeFloor(K.start, 1, {}), false, 'wouldStepChangeFloor: east is safe')
end

-- ============================================================ walker harness
local function newWalker(F, cfg, opts)
    opts = opts or {}
    local clock = { t = 1000 }
    local sent = {}
    local sender = {
        refuse = false,
        walk = function(self, dir)
            sent[#sent + 1] = { op = 'walk', dir = dir, t = clock.t }
            if self.refuse then return nil, 'transport refused' end
            return 'body'
        end,
        stop = function(self) sent[#sent + 1] = { op = 'stop', t = clock.t }; return 'body' end,
        autoWalk = function(self, dirs)
            sent[#sent + 1] = { op = 'autoWalk', n = #dirs, t = clock.t }
            return 'body', math.min(#dirs, 127)
        end,
    }
    F.client.sender = sender
    local wk = walkmod.new(F.client, { world = F.world, path = F.path, config = cfg,
                                       now = function() return clock.t end })
    wk:attach()
    -- move the player and emit the event the parser would emit
    local function moveTo(pos)
        local old = F.st.player.pos
        F.st.player.pos = pos
        F.st.central = pos
        F.client.events:emit('positionChange', { pos = pos, oldPos = old })
    end
    local function stepDir(dir)
        local d = worldmod.DELTA[dir]
        local pp = F.st.player.pos
        moveTo({ x = pp.x + d[1], y = pp.y + d[2], z = pp.z })
    end
    return { wk = wk, clock = clock, sent = sent, sender = sender,
             moveTo = moveTo, stepDir = stepDir,
             walks = function()
                 local out = {}
                 for i = 1, #sent do if sent[i].op == 'walk' then out[#out + 1] = sent[i].dir end end
                 return out
             end }
end

-- ============================================================================
S('walker: drives a synthetic route to the exact direction sequence')
do
    local F = newWorld({
        '@....',
        '####.',
        '...X.',
    })
    -- route: E E E E, S, S, W  -> but the pathfinder picks its own; assert what it walks.
    local H = newWalker(F, { walkDelay = 10 })
    local expected = F.path:getPath(F.start, F.goal, 30, { ignoreNonPathable = true })
    io.write('        planned: ', dirs2str(expected), '\n')

    local guard, status = 0, nil
    while guard < 60 do
        guard = guard + 1
        status = H.wk:walkTo(F.goal, { maxDist = 30 })
        if status == 'arrived' then break end
        if status ~= 'walking' then break end
        -- the server answers every unconfirmed step, then time advances past the walk delay
        while #H.wk.expected > 0 do H.stepDir(H.wk.expected[1]) end
        H.clock.t = H.clock.t + 500
    end
    eq(status, 'arrived', 'the walker reaches the goal')
    eqDirs(H.walks(), expected, 'the exact direction sequence matches the planned path')
    eq(F.st.player.pos.x, F.goal.x, 'player ended on the goal (x)')
    eq(F.st.player.pos.y, F.goal.y, 'player ended on the goal (y)')
end

-- ============================================================================
S('walker: one step per call, ledger confirmation, lookahead')
do
    local F = newWorld({ '@....X' })
    local H = newWalker(F, { walkDelay = 10 })

    eq(H.wk:walkTo(F.goal, { maxDist = 20 }), 'walking', 'first call sends one step')
    eq(#H.walks(), 1, 'exactly one walk packet')
    eq(#H.wk.expected, 1, 'and one unconfirmed step in the ledger')
    eq(H.wk.iter, 2, 'the plan cursor points at the second step')

    -- while the step is unconfirmed the walker sends ONE lookahead step per call
    H.clock.t = H.clock.t + 500
    eq(H.wk:walkTo(F.goal, { maxDist = 20 }), 'walking', 'second call pumps the lookahead')
    eq(#H.walks(), 2, 'two walk packets')
    eq(#H.wk.expected, 2, 'two unconfirmed steps')

    H.clock.t = H.clock.t + 500
    H.wk:walkTo(F.goal, { maxDist = 20 })
    eq(#H.walks(), 3, 'three walk packets')
    eq(#H.wk.expected, 3, 'three unconfirmed steps')

    -- three unconfirmed -> the whole plan is dropped and the action re-paths
    H.clock.t = H.clock.t + 500
    H.wk:walkTo(F.goal, { maxDist = 20 })
    ok(#H.wk.expected <= 1, 'the plan was dropped at three unconfirmed steps and re-pathed')

    -- confirmation pops the ledger head only when the observed direction matches
    local G = newWorld({ '@....X' })
    local H2 = newWalker(G, { walkDelay = 10 })
    H2.wk:walkTo(G.goal, { maxDist = 20 })
    eq(#H2.wk.expected, 1, 'one step outstanding')
    H2.stepDir(2)                                   -- the server moves us SOUTH instead
    eq(#H2.wk.expected, 1, 'a mismatching move does not confirm the step')
    G.st.player.pos = G.start; G.st.central = G.start
    H2.moveTo({ x = G.start.x + 1, y = G.start.y, z = G.start.z })
    eq(#H2.wk.expected, 0, 'the matching move confirms and pops it')
end

-- ============================================================================
S('walker: a refused step is retried, then reported blocked')
do
    local F = newWorld({ '@....X' })
    local H = newWalker(F, { walkDelay = 10 })
    H.sender.refuse = true

    local s = H.wk:walkTo(F.goal, { maxDist = 20 })
    eq(s, 'walking', 'a refused send is still "walking" (a retry is pending)')
    eq(#H.walks(), 1, 'one send was attempted')
    eq(#H.wk.expected, 0, 'nothing entered the ledger -- nothing was sent')
    eq(H.wk.refusals, 1, 'the refusal was counted')
    eq(H.wk:isDelayed(), true, 'and a retry delay was set')
    eq(math.floor(H.wk.readyAt - H.clock.t), walkmod.REFUSAL_DELAY_MS,
       'the retry delay is 25 ms')

    eq(H.wk:walkTo(F.goal, { maxDist = 20 }), 'walking', 'while delayed the walker paces')
    eq(#H.walks(), 1, 'and sends nothing')

    H.clock.t = H.clock.t + 30
    s = H.wk:walkTo(F.goal, { maxDist = 20 })
    eq(#H.walks(), 2, 'after the delay the SAME first step is retried')
    eq(H.walks()[2], H.walks()[1], 'same direction')
    eq(H.wk.refusals, 2, 'second refusal counted')

    H.clock.t = H.clock.t + 30
    s = H.wk:walkTo(F.goal, { maxDist = 20 })
    eq(s, 'blocked', 'the third consecutive refusal reports blocked')
    eq(H.wk.lastReason, 'send-refused-limit', 'with reason send-refused-limit')
    eq(#H.wk.walkPath, 0, 'and the plan was dropped')

    -- a working transport clears the counter and walks again
    H.sender.refuse = false
    H.clock.t = H.clock.t + 100
    eq(H.wk:walkTo(F.goal, { maxDist = 20 }), 'walking', 'recovery')
    eq(H.wk.refusals, 0, 'the refusal counter reset on the first good send')
    eq(#H.wk.expected, 1, 'and the step is now in the ledger')
end

-- ============================================================================
S('walker: a creature on the next tile')
do
    local F = newWorld({ '@..X' })
    local H = newWalker(F, { walkDelay = 10 })
    -- drop a monster on the tile east of the player AFTER the search would have run
    local np = { x = F.start.x + 1, y = F.start.y, z = F.start.z }
    nextCreatureId = nextCreatureId + 1
    local cid = nextCreatureId
    F.st:addCreature({ id = cid, name = 'blocker', type = 1, pos = np, healthPercent = 100,
                       passable = false, outfit = { lookType = 128, lookTypeEx = 0 } })
    F.st:addThing(np, -2, { kind = 'creature', creatureId = cid, id = 0x63 })

    local s = H.wk:walkTo(F.goal, { maxDist = 20, params = { ignoreCreatures = true } })
    eq(s, 'blocked', 'a creature standing on the next tile blocks the step')
    eq(H.wk.lastReason, 'creature-blocks', 'with reason creature-blocks')
    eq(#H.walks(), 0, 'and nothing was sent')

    H.clock.t = H.clock.t + 200
    local s2 = H.wk:walkTo(F.goal, { maxDist = 20, allowCreatures = true,
                                     params = { ignoreCreatures = true } })
    eq(s2, 'walking', 'allowCreatures steps anyway')
    eq(#H.walks(), 1, 'one packet sent')
end

-- ============================================================================
S('walker: floor-change guard, walkCancel, arrival, no path')
do
    local F = newWorld({ '@.U.X' })
    local H = newWalker(F, { walkDelay = 10, avoidFloorChange = true })
    local s = H.wk:walkTo(F.goal, { maxDist = 20, params = { ignoreNonPathable = true } })
    eq(s, 'blocked', 'avoidFloorChange refuses a route over a stairs tile')
    ok((H.wk.lastReason or ''):find('floor%-change'), 'with a floor-change reason')

    H.clock.t = H.clock.t + 100
    local s2 = H.wk:walkTo(F.goal, { maxDist = 20, avoidFloorChange = false,
                                     params = { ignoreNonPathable = true } })
    eq(s2, 'walking', 'and walks it when the guard is off')

    -- walkCancel drops the plan and backs off a flat 200 ms
    H.clock.t = H.clock.t + 500
    H.wk:onWalkCancel({ direction = 1 })
    eq(#H.wk.expected, 0, 'walkCancel clears the ledger')
    eq(#H.wk.walkPath, 0, 'and the plan')
    eq(math.floor(H.wk.readyAt - H.clock.t), walkmod.WALK_CANCEL_RETRY_MS,
       'and backs off 200 ms')

    -- arrival / nopath
    local G = newWorld({ '@' })
    local H2 = newWalker(G, {})
    eq(H2.wk:walkTo(G.start, {}), 'arrived', 'standing on the destination is "arrived"')
    eq(H2.wk:walkTo({ x = G.start.x + 3, y = G.start.y, z = G.start.z }, { maxDist = 10 }),
       'nopath', 'an unreachable destination is "nopath"')
    eq(H2.wk:walkTo({ x = G.start.x, y = G.start.y, z = G.start.z + 1 }, {}), 'nopath',
       'another floor is "nopath"')
    eq(H2.wk.lastReason, 'different-floor', 'with reason different-floor')
end

-- ============================================================================
S('walker: step duration and floor-change detection')
do
    local F = newWorld({ '@.', 's.' }, { speed = 200 })
    local H = newWalker(F, {})
    -- ceil((1000*100/200)/50)*50 = 500; last step direction unknown -> use dir; -10
    eq(H.wk:stepDuration(1), 490, 'orthogonal step on speed-100 ground at speed 200')
    -- ground speed 250 south: ceil((1000*250/200)/50)*50 = 1250; -10
    eq(H.wk:stepDuration(2), 1240, 'slow ground raises the step duration')
    H.wk.lastStepDir = 4                      -- the LAST step was diagonal (VERIFIER)
    eq(H.wk:stepDuration(1), 1490, 'the x3 multiplier follows the LAST step direction')
    H.wk.lastStepDir = nil
    F.st.player.speed = 0
    eq(H.wk:stepDuration(1), walkmod.STEP_FALLBACK_MS, 'an unusable speed falls back to 200 ms')
    F.st.player.speed = 200

    -- floor change detection + the 60 s bounce guard
    local before = F.st.player.pos
    H.moveTo({ x = before.x, y = before.y, z = before.z + 1 })
    ok(H.wk.lastFloorChange ~= nil, 'a z change is recorded')
    eq(H.wk.lastFloorChange.suppressed, false, 'the first fall is not suppressed')
    local back = F.st.player.pos
    H.moveTo({ x = before.x, y = before.y, z = before.z })
    H.clock.t = H.clock.t + 1000
    H.moveTo({ x = before.x, y = before.y, z = before.z + 1 })
    eq(H.wk.lastFloorChange.suppressed, true, 'the same fall inside 60 s is suppressed')
end

-- ============================================================================
S('walker: map-click mode')
do
    local F = newWorld({ '@....X' })
    local H = newWalker(F, { mapClick = true, mapClickDelay = 100 })
    local s = H.wk:walkTo(F.goal, { maxDist = 20 })
    eq(s, 'walking', 'map click mode reports walking')
    eq(#H.sent, 1, 'exactly one packet')
    eq(H.sent[1].op, 'autoWalk', 'and it is an autoWalk')
    eq(H.sent[1].n, 5, 'carrying the whole 5-step path')
    eq(math.floor(H.wk.readyAt - H.clock.t), 150, 'delay = mapClickDelay + 50')
end

-- ============================================================================
S('walker: smooth-walk pacing and watchdog')
do
    local F = newWorld({ '@..........X' }, { speed = 220 })
    local H = newWalker(F, { smoothWalk = true, walkDelay = 10, ping = 100 })
    -- stepDuration = ceil((1000*100/220)/50)*50 - 10 = 490
    -- sendWindow   = min(3, 1 + ceil(100/490)) = 2
    eq(H.wk:stepDuration(1), 490, 'step duration on this fixture')

    eq(H.wk:walkTo(F.goal, { maxDist = 20 }), 'walking', 'first call')
    eq(#H.wk.pending, 1, 'one step in flight')

    H.clock.t = H.clock.t + 60
    H.wk:walkTo(F.goal, { maxDist = 20 })
    eq(#H.wk.pending, 2, 'the pacer fills the send window (2)')

    H.clock.t = H.clock.t + 60
    H.wk:walkTo(F.goal, { maxDist = 20 })
    eq(#H.wk.pending, 2, 'and refuses to exceed it')

    -- confirming the head frees a slot
    H.stepDir(H.wk.pending[1].dir)
    eq(#H.wk.pending, 1, 'a matching move confirms the head')
    H.clock.t = H.clock.t + 60
    H.wk:walkTo(F.goal, { maxDist = 20 })
    eq(#H.wk.pending, 2, 'the freed slot is refilled')

    -- watchdog: ping + 2*stepDuration + 400 = 100 + 980 + 400 = 1480 ms of silence
    local before = #H.sent
    H.clock.t = H.clock.t + 2000
    H.wk:walkTo(F.goal, { maxDist = 20 })
    eq(H.sent[before + 1].op, 'stop', 'the watchdog sends a stop')
    eq(H.wk.lastReason, 'smooth-watchdog', 'with reason smooth-watchdog')
    -- ...and, exactly like vBot, doWalking returning false lets the SAME tick re-path:
    -- the two stale in-flight steps are gone and a single fresh step is on the wire.
    eq(#H.wk.pending, 1, 'the stale ledger was voided and one fresh step re-planned')
    eq(H.sent[before + 2].op, 'walk', 'the re-path sent a walk')
end

-- ============================================================================
S('walker: anti-lost recovery-tile search')
do
    -- 'Y' is yellow, 'L' carries a ladder id.  The fall spot is the centre.
    local F = newWorld({
        '.....',
        '..Y..',
        '..@..',
        '.....',
    })
    local H = newWalker(F, {})
    local fall = { x = F.base.x + 2, y = F.base.y + 2, z = F.base.z }
    -- the fall spot itself is not a recovery tile, so the radius-2 search finds the yellow one
    local target, how = H.wk:recoveryTarget(fall, F.base.z, {}, {})
    ok(target ~= nil, 'a recovery tile is found within radius 2')
    if target then
        eq(target.x, F.base.x + 2, 'x of the yellow tile')
        eq(target.y, F.base.y + 1, 'y of the yellow tile')
        eq(how, 'nearby', 'reported as a nearby recovery tile')
    end

    -- far away -> nothing (never a wider search)
    local G = newWorld({
        '.......',
        '.......',
        '...@...',
        '.......',
        '......Y',
    })
    local H2 = newWalker(G, {})
    local far = { x = G.base.x + 3, y = G.base.y + 2, z = G.base.z }
    eq(H2.wk:recoveryTarget(far, G.base.z, {}, {}), nil,
       'a recovery tile outside radius 2 is never used')
end

-- ============================================================================
io.write('\n================ bot F2 selftest ================\n')
for i = 1, #msgs do io.write(msgs[i], '\n') end
io.write(string.format('  %d passed, %d failed\n', pass, fail))
-- Runnable standalone (exits non-zero on failure) AND embeddable: a harness that sets
-- _G.BOT_F2_NO_EXIT before dofile()ing this file gets the counters back instead.
-- test/botsuite.lua (owned by the bot-core work item) should do:
--     _G.BOT_F2_NO_EXIT = true
--     local r = dofile(ROOT .. '/test/bot_f2_path.lua')   -- r = {pass=, fail=, failures={}}
if _G.BOT_F2_NO_EXIT then
    return { pass = pass, fail = fail, failures = msgs }
end
if fail > 0 then os.exit(1) end
os.exit(0)
