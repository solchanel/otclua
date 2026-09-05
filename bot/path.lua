--[[============================================================================
bot/path.lua -- A* / Dijkstra pathfinding over the tile store (work item F2).

This is an exact port of `Map::findEveryPath` (src/client/map.cpp:1316-1473) -- variant A in
docs/vbot/pathfinding.md, the ONLY pathfinder vBot ever uses -- plus the Lua wrapper
`findPath`/`getPath` (mods/game_bot/functions/map.lua:143-218) that CaveBot/TargetBot actually
call.  Every rule below carries its citation; the "## VERIFIER (Corrections)" section of
docs/vbot/pathfinding.md overrides the spec body and is followed here.

    local p = path.new(client, world)
    local dirs, why = p:getPath(startPos, destPos, maxDist, params)
        -- dirs = array of Otc::Direction ints (N=0 E=1 S=2 W=3 NE=4 SE=5 SW=6 NW=7),
        --        EMPTY (but truthy) when already standing on the destination;
        -- nil + reason ('no-destination' | 'different-floor' | 'no-path' | 'max-complexity')
    local field = p:findEveryPath(startPos, maxDistance, params)   -- the raw Dijkstra field

`params` keys (docs/vbot/pathfinding.md 1.5 / 6), all optional:
    ignoreCreatures ignoreLastCreature ignoreNonPathable ignoreNonWalkable ignoreStairs
    ignoreCost allowUnseen allowOnlyVisibleTiles maxDistanceFrom={pos,range}
    precision (number) marginMin/marginMax (aliases minMargin/maxMargin) maxComplexity

Truthiness follows the C++ (`value != "0" && value != ""`, map.cpp:1328-1343) after the Lua
wrapper's false/nil -> 0, true -> 1 pass: anything except nil / false / 0 / "0" / "" is TRUE.
`precision`, `marginMin`, `marginMax`, `maxDistanceFrom` and `maxComplexity` are values, not
flags, and are read raw.

Facts a reimplementer must not lose (all verified against map.cpp):
  * pure Dijkstra, NO heuristic; totalCost accumulates the ENTERED tile's ground speed.
  * diagonal multiplier is 3.0 (g_gameConfig.getPlayerDiagonalWalkSpeed, setup.otml:29).
  * unknown-tile speed is 1000, minimap speed is byte*10, no-ground tile speed is 100.
  * neighbour order is exactly NW, W, SW, N, S, NE, E, SE and is a real tie-breaker.
  * relaxation is STRICT `<` -- the FIRST relaxation achieving the minimum wins (VERIFIER).
  * the field's totalCost is TRUNCATED to an int before Lua sees it (std::tuple<int,...>),
    and the margin/precision "cheapest candidate" comparisons run on the truncated value
    (VERIFIER) -- so we store math.floor(total).
  * classification is cached FOREVER per position: a tile first reached as blocked is never
    reconsidered, even from a cheaper direction.
  * `isNotWalkable` has NO destPos exemption; `isNotPathable` and the stairs rule do.
  * hasStairs = isNotPathable AND 210 <= mapColor <= 213 (the local patch; colour alone made
    staircases unreachable).
  * the start tile is never walkability-checked.
  * with ignoreLastCreature a blocked-by-creature neighbour still gets a field entry at
    cost+100 but is never expanded through.
  * hasMargin is set by KEY PRESENCE of the literal keys "marginMin"/"marginMax" only; the
    aliases minMargin/maxMargin drive the Lua ring scan but NOT the C++ +4 extension (VERIFIER).

maxComplexity: `findEveryPath` has no node cap in C++ (only maxDistance); BOT.md requires one,
so this port adds a cutoff on the number of CLASSIFIED CELLS.  On overrun the search stops and
the field is flagged `truncated`; `getPath` still returns a path if the destination was already
settled, otherwise nil, 'max-complexity'.

Grid: the search is clipped to a (2*maxDistance+1) square centred on the start.  That is safe
and lossless -- every created node has Chebyshev(start, node) <= node.distance, and a node is
expanded only while distance < maxDistance (docs/vbot/pathfinding.md VERIFIER "Additions").
The arrays are sized from the ORIGINAL maxDistance (margin mode only shrinks it) and reused
between calls; a monotonically increasing stamp replaces clearing them.
============================================================================]]

local worldmod = require('bot.world')

local floor, min, abs, sqrt = math.floor, math.min, math.abs, math.sqrt

local ok_ffi, ffi = pcall(require, 'ffi')

local path = {}

local P = {}
P.__index = P

-- ---------------------------------------------------------------------------
-- constants
-- ---------------------------------------------------------------------------
local DIAGONAL            = 3.0     -- gameconfig.h:125 + data/setup.otml:29
local UNKNOWN_TILE_SPEED  = 1000    -- map.cpp:1405
local CREATURE_SURCHARGE  = 100     -- map.cpp:1438
local MARGIN_SLACK        = 4       -- map.cpp:1385
local INF                 = 1e7     -- map.cpp:1443 (the C++ literal, not math.huge)
local DEFAULT_MAX_DIST    = 100     -- functions/map.lua:161-163
local DEFAULT_COMPLEXITY  = 50000

path.DIAGONAL_WALK_SPEED = DIAGONAL
path.DEFAULT_MAX_DISTANCE = DEFAULT_MAX_DIST
path.DIR   = worldmod.DIR
path.DELTA = worldmod.DELTA
path.directionBetween = worldmod.directionBetween

-- map.cpp:1392-1395: i = -1..1 outer (dx), j = -1..1 inner (dy) -> NW W SW N S NE E SE
local NB = { { -1, -1 }, { -1, 0 }, { -1, 1 }, { 0, -1 }, { 0, 1 }, { 1, -1 }, { 1, 0 }, { 1, 1 } }
path.NEIGHBOUR_ORDER = NB

local DIR = worldmod.DIR

-- ---------------------------------------------------------------------------
-- truthiness of a findEveryPath param (map.cpp:1328-1343 after functions/map.lua:85-92)
-- ---------------------------------------------------------------------------
local function truthy(v)
    if v == nil or v == false or v == 0 or v == '0' or v == '' then return false end
    return true
end
path.truthy = truthy

-- ---------------------------------------------------------------------------
-- flat arrays (FFI when available, plain tables otherwise -- both 0-based)
-- ---------------------------------------------------------------------------
local function newArr(ctype, n, default)
    if ok_ffi then return ffi.new(ctype .. '[?]', n) end
    local t = {}
    for i = 0, n - 1 do t[i] = default end
    return t
end

-- ---------------------------------------------------------------------------
-- binary min-heap on two parallel arrays, grown by doubling, reused between calls
-- ---------------------------------------------------------------------------
local Heap = {}
Heap.__index = Heap

local function heapNew(cap)
    cap = cap or 1024
    return setmetatable({ n = 0, cap = cap,
                          key = newArr('double', cap + 1, 0),
                          val = newArr('int32_t', cap + 1, 0) }, Heap)
end

function Heap:grow()
    local cap = self.cap * 2
    local key, val = newArr('double', cap + 1, 0), newArr('int32_t', cap + 1, 0)
    for i = 1, self.n do key[i], val[i] = self.key[i], self.val[i] end
    self.key, self.val, self.cap = key, val, cap
end

function Heap:clear() self.n = 0 end

function Heap:push(v, k)
    local n = self.n + 1
    if n > self.cap then self:grow() end
    self.n = n
    local key, val = self.key, self.val
    key[n], val[n] = k, v
    while n > 1 do
        local p = floor(n / 2)
        if key[p] <= key[n] then break end
        key[p], key[n] = key[n], key[p]
        val[p], val[n] = val[n], val[p]
        n = p
    end
end

function Heap:pop()
    local n = self.n
    if n == 0 then return nil end
    local key, val = self.key, self.val
    local top = val[1]
    key[1], val[1] = key[n], val[n]
    n = n - 1
    self.n = n
    local i = 1
    while true do
        local l, r, m = i * 2, i * 2 + 1, i
        if l <= n and key[l] < key[m] then m = l end
        if r <= n and key[r] < key[m] then m = r end
        if m == i then break end
        key[i], key[m] = key[m], key[i]
        val[i], val[m] = val[m], val[i]
        i = m
    end
    return top
end

path._Heap = Heap

-- ---------------------------------------------------------------------------
-- the search field returned by findEveryPath
-- ---------------------------------------------------------------------------
local Field = {}
Field.__index = Field

function Field:idxOf(x, y)
    local gx, gy = x - self.ox, y - self.oy
    if gx < 0 or gy < 0 or gx >= self.side or gy >= self.side then return nil end
    return gy * self.side + gx
end

function Field:posOf(idx)
    return self.ox + (idx % self.side), self.oy + floor(idx / self.side), self.z
end

-- returns total(int), distance, direction-into-this-tile (-1 for start), prevIdx (nil for start)
function Field:nodeAt(idx)
    if idx == nil then return nil end
    local A = self.A
    if A.fs[idx] ~= self.stamp then return nil end
    local prev = A.fprev[idx]
    return A.ftotal[idx], A.fdist[idx], A.fdir[idx], (prev ~= 0) and (prev - 1) or nil
end

function Field:node(x, y)
    return self:nodeAt(self:idxOf(x, y))
end

function Field:has(x, y)
    return self:node(x, y) ~= nil
end

-- the C++-compatible {"x,y,z" = {total, dist, dir, prevKey}} map; diagnostics / parity tests
function Field:toStringMap()
    local out = {}
    local A = self.A
    for idx = 0, self.side * self.side - 1 do
        if A.fs[idx] == self.stamp then
            local x, y, z = self:posOf(idx)
            local prev = A.fprev[idx]
            local pk = ''
            if prev ~= 0 then
                local px, py = self:posOf(prev - 1)
                pk = px .. ',' .. py .. ',' .. z
            end
            out[x .. ',' .. y .. ',' .. z] = { A.ftotal[idx], A.fdist[idx], A.fdir[idx], pk }
        end
    end
    return out
end

-- follow the prev chain back, collecting directions -- functions/map.lua:116-140.
-- Bounded by side*side iterations: translateAllPathsToPath has no cycle guard and a port that
-- builds the field incrementally can hang there (docs/vbot/pathfinding.md VERIFIER Additions).
function Field:translate(idx)
    local rev, guard = {}, 0
    local limit = self.side * self.side + 2
    while idx ~= nil do
        guard = guard + 1
        if guard > limit then return nil end
        local total, dist, dir, prev = self:nodeAt(idx)
        if total == nil then break end
        if dir < 0 then break end                 -- reached the start node
        rev[#rev + 1] = dir
        idx = prev
    end
    local dirs = {}
    for i = #rev, 1, -1 do dirs[#dirs + 1] = rev[i] end
    return dirs
end

path._Field = Field

-- ---------------------------------------------------------------------------
-- construction
-- ---------------------------------------------------------------------------
function path.new(client, w)
    local self = setmetatable({}, P)
    self.client = client
    self.world  = w or worldmod.new(client)
    self.log    = client and client.log
    self.maxComplexity = DEFAULT_COMPLEXITY
    self.A = nil
    self.cells = 0
    self.stamp = 0
    self.heap = heapNew(1024)
    self._pos = { x = 0, y = 0, z = 0 }     -- scratch, never escapes
    self.stats = { searches = 0, classified = 0, relaxations = 0, pops = 0 }
    return self
end

function P:_ensure(cells)
    if self.A and self.cells >= cells then return end
    -- round up so a growing maxDistance does not reallocate on every call
    local n = 1024
    while n < cells do n = n * 2 end
    self.A = {
        ns     = newArr('int32_t', n, 0),
        nstate = newArr('uint8_t', n, 0),
        ncost  = newArr('double',  n, 0),
        ntotal = newArr('double',  n, 0),
        nprev  = newArr('int32_t', n, 0),
        ndist  = newArr('int32_t', n, 0),
        fs     = newArr('int32_t', n, 0),
        ftotal = newArr('double',  n, 0),
        fdist  = newArr('int32_t', n, 0),
        fdir   = newArr('int32_t', n, 0),
        fprev  = newArr('int32_t', n, 0),
    }
    self.cells = n
    self.stamp = 0
end

function P:_nextStamp()
    self.stamp = self.stamp + 1
    if self.stamp >= 2147483000 then          -- int32 headroom; reallocate rather than wrap
        self.A, self.cells, self.stamp = nil, 0, 0
    end
    return self.stamp
end

-- ---------------------------------------------------------------------------
-- Map::findEveryPath (map.cpp:1316-1473)
-- ---------------------------------------------------------------------------
-- start        {x,y,z}
-- maxDistance  step-count cutoff (NOT a cost cutoff)
-- params       raw user params (not mutated)
function P:findEveryPath(start, maxDistance, params)
    params = (type(params) == 'table') and params or {}
    if type(maxDistance) ~= 'number' then maxDistance = DEFAULT_MAX_DIST end
    maxDistance = floor(maxDistance)
    if maxDistance < 0 then maxDistance = 0 end

    local W = self.world
    local ignoreCreatures     = truthy(params.ignoreCreatures)
    local ignoreLastCreature  = truthy(params.ignoreLastCreature)
    local ignoreNonPathable   = truthy(params.ignoreNonPathable)
    local ignoreNonWalkable   = truthy(params.ignoreNonWalkable)
    local ignoreStairs        = truthy(params.ignoreStairs)
    local ignoreCost          = truthy(params.ignoreCost)
    local allowUnseen         = truthy(params.allowUnseen)
    local allowOnlyVisible    = truthy(params.allowOnlyVisibleTiles)
    -- map.cpp:1344-1348: KEY PRESENCE of the literal keys only, any value (VERIFIER).
    local hasMargin           = (params.marginMin ~= nil) or (params.marginMax ~= nil)
    local maxComplexity       = tonumber(params.maxComplexity) or self.maxComplexity

    local mdf, mdfPos, mdfRange = params.maxDistanceFrom, nil, nil
    if type(mdf) == 'table' then
        mdfPos, mdfRange = mdf[1] or mdf.pos, tonumber(mdf[2] or mdf.range)
        if type(mdfPos) ~= 'table' or not mdfRange then mdfPos = nil end
    end

    local side = 2 * maxDistance + 1
    local cells = side * side
    self:_ensure(cells)
    local A = self.A
    local stamp = self:_nextStamp()
    local heap = self.heap
    heap:clear()

    local ox, oy, z = start.x - maxDistance, start.y - maxDistance, start.z

    local F = setmetatable({ A = A, side = side, ox = ox, oy = oy, z = z, stamp = stamp,
                             complexity = 0, truncated = false, pops = 0 }, Field)

    local si = maxDistance * side + maxDistance          -- idxOf(start.x, start.y)
    A.ns[si], A.nstate[si] = stamp, 1
    A.ncost[si], A.ntotal[si], A.nprev[si], A.ndist[si] = 1, 0, 0, 0   -- map.cpp:1373
    heap:push(si, 0)

    local destIdx = nil
    local dest = params.destination
    if type(dest) == 'table' and dest.z == z then
        local gx, gy = dest.x - ox, dest.y - oy
        if gx >= 0 and gy >= 0 and gx < side and gy < side then destIdx = gy * side + gx end
    end

    local maxDist = maxDistance
    local scratch = self._pos
    local classified, relaxations, pops = 0, 0, 0

    while true do
        if classified > maxComplexity then
            F.truncated = true
            break
        end
        local ni = heap:pop()
        if ni == nil then break end
        pops = pops + 1

        local nx = ox + (ni % side)
        local ny = oy + floor(ni / side)
        local ndist, ntotal = A.ndist[ni], A.ntotal[ni]
        local prev = A.nprev[ni]

        -- map.cpp:1380-1382: the direction is RECOMPUTED at pop time from the node's CURRENT
        -- prev, so prev and dir can never drift apart (VERIFIER).
        local dir = -1
        if prev ~= 0 then
            local pi = prev - 1
            local px = ox + (pi % side)
            local py = oy + floor(pi / side)
            local row = DIR[nx - px]
            dir = (row and row[ny - py]) or -1
        end
        A.fs[ni]     = stamp
        A.ftotal[ni] = floor(ntotal)          -- std::tuple<int,...> truncation (VERIFIER)
        A.fdist[ni]  = ndist
        A.fdir[ni]   = dir
        A.fprev[ni]  = prev

        local stop = false
        if ni == destIdx then                                     -- map.cpp:1383-1389
            if hasMargin then
                local m = ndist + MARGIN_SLACK
                if m < maxDist then maxDist = m end
            else
                stop = true
            end
        end

        if stop then break end

        if ndist < maxDist then                                   -- map.cpp:1390
            for k = 1, 8 do
                local nbk = NB[k]
                local i, j = nbk[1], nbk[2]
                local x, y = nx + i, ny + j
                if x >= 0 and y >= 0 then                          -- map.cpp:1397
                    local gx, gy = x - ox, y - oy
                    if gx >= 0 and gy >= 0 and gx < side and gy < side then
                        local mi = gy * side + gx

                        if A.ns[mi] ~= stamp then
                            -- ---- first visit: classify (map.cpp:1399-1445) --------------
                            A.ns[mi] = stamp
                            classified = classified + 1
                            scratch.x, scratch.y, scratch.z = x, y, z
                            local wasSeen, hasCreature, notWalk, notPath, color, speed =
                                W:classifyForPath(scratch, allowOnlyVisible)

                            local hasStairs = notPath and color >= 210 and color <= 213
                            local tooFar = false
                            if mdfPos then
                                local dx, dy = mdfPos.x - x, mdfPos.y - y
                                tooFar = sqrt(dx * dx + dy * dy) > mdfRange   -- EUCLIDEAN
                            end
                            local isDest = (mi == destIdx)

                            if (not wasSeen and not allowUnseen)
                               or (hasStairs and not ignoreStairs      and not isDest)
                               or (notPath   and not ignoreNonPathable and not isDest)
                               or (notWalk   and not ignoreNonWalkable)   -- no dest exemption!
                               or tooFar then
                                A.nstate[mi] = 0                     -- blocked forever
                            elseif hasCreature and not ignoreCreatures then
                                A.nstate[mi] = 0
                                if ignoreLastCreature then           -- map.cpp:1437-1440
                                    A.fs[mi]     = stamp
                                    A.ftotal[mi] = floor(ntotal) + CREATURE_SURCHARGE
                                    A.fdist[mi]  = ndist + 1
                                    A.fdir[mi]   = DIR[i][j]
                                    A.fprev[mi]  = ni + 1
                                end
                            else
                                A.nstate[mi] = 1
                                A.ncost[mi]  = speed
                                A.ntotal[mi] = INF
                                A.nprev[mi]  = ni + 1
                                A.ndist[mi]  = ndist + 1
                            end
                        end

                        if A.nstate[mi] == 1 then
                            local diagonal = (i == 0 or j == 0) and 1.0 or DIAGONAL
                            local cost
                            if ignoreCost then cost = 1 else cost = A.ncost[mi] * diagonal end
                            local nt = ntotal + cost
                            if nt < A.ntotal[mi] then                -- STRICT (map.cpp:1455)
                                A.ntotal[mi] = nt
                                A.nprev[mi]  = ni + 1
                                A.ndist[mi]  = ndist + 1
                                relaxations = relaxations + 1
                                heap:push(mi, nt)
                            end
                        end
                    end
                end
            end
        end
    end

    F.complexity = classified
    F.pops = pops
    local s = self.stats
    s.searches   = s.searches + 1
    s.classified = s.classified + classified
    s.relaxations = s.relaxations + relaxations
    s.pops       = s.pops + pops
    return F
end

-- ---------------------------------------------------------------------------
-- functions/map.lua:143-218 -- findPath / getPath
-- DEVIATION (documented): the real wrapper MUTATES the caller's params table (false->0,
-- true->1) and injects `destination`.  We never touch the caller's table; the same keys are
-- read, so no search result can differ.
-- ---------------------------------------------------------------------------
function P:getPath(startPos, destPos, maxDist, params)
    if not startPos then return nil, 'no-start' end
    if not destPos then return nil, 'no-destination' end
    if startPos.z ~= destPos.z then return nil, 'different-floor' end   -- map.lua:156-158
    if type(maxDist) ~= 'number' then maxDist = DEFAULT_MAX_DIST end    -- map.lua:161-163
    params = (type(params) == 'table') and params or {}

    local p = {}
    for k, v in pairs(params) do p[k] = v end
    p.destination = destPos                                             -- map.lua:168-169

    local F = self:findEveryPath(startPos, maxDist, p)

    -- margin mode (map.lua:171-192): a Chebyshev RING, cheapest truncated cost wins
    local mMin = params.marginMin or params.minMargin
    local mMax = params.marginMax or params.maxMargin
    if type(mMin) == 'number' and type(mMax) == 'number' then
        local best, bestIdx
        for dx = -mMax, mMax do
            for dy = -mMax, mMax do
                if abs(dx) >= mMin or abs(dy) >= mMin then
                    local idx = F:idxOf(destPos.x + dx, destPos.y + dy)
                    local total = idx and F:nodeAt(idx)
                    if total and (best == nil or best > total) then best, bestIdx = total, idx end
                end
            end
        end
        if not bestIdx then
            return nil, F.truncated and 'max-complexity' or 'no-path'
        end
        return F:translate(bestIdx), nil, F
    end

    local di = F:idxOf(destPos.x, destPos.y)
    if di == nil or F:nodeAt(di) == nil then
        -- precision mode (map.lua:195-215): FULL SQUARES p = 1..precision, not rings
        local prec = params.precision
        if type(prec) == 'number' then
            for r = 1, prec do
                local best, bestIdx
                for dx = -r, r do
                    for dy = -r, r do
                        local idx = F:idxOf(destPos.x + dx, destPos.y + dy)
                        local total = idx and F:nodeAt(idx)
                        if total and (best == nil or best > total) then
                            best, bestIdx = total, idx
                        end
                    end
                end
                if bestIdx then return F:translate(bestIdx), nil, F end
            end
        end
        return nil, F.truncated and 'max-complexity' or 'no-path', F
    end

    return F:translate(di), nil, F
end

path.findPath = nil   -- (see getPath; vBot aliases the two names)
P.findPath = P.getPath

-- ---------------------------------------------------------------------------
-- helpers over a direction list
-- ---------------------------------------------------------------------------
local DELTA = worldmod.DELTA

-- the tile positions a direction list visits, starting AFTER `from`
function path.positionsOf(from, dirs)
    local out = {}
    local x, y, z = from.x, from.y, from.z
    for i = 1, #dirs do
        local d = DELTA[dirs[i]]
        if not d then break end
        x, y = x + d[1], y + d[2]
        out[#out + 1] = { x = x, y = y, z = z }
    end
    return out
end

function path.endPosition(from, dirs)
    local x, y, z = from.x, from.y, from.z
    for i = 1, #dirs do
        local d = DELTA[dirs[i]]
        if not d then break end
        x, y = x + d[1], y + d[2]
    end
    return { x = x, y = y, z = z }
end

-- pathCrossesFloorChange (cavebot/walking.lua:185-205): replay the direction list; a hit on
-- any tile OTHER than the exact destination refuses the path (a goto ONTO stairs is
-- intentional).
function P:crossesFloorChange(fromPos, dest, dirs, avoidIds)
    if not dirs then return false end
    local W = self.world
    local x, y, z = fromPos.x, fromPos.y, fromPos.z
    for i = 1, #dirs do
        local d = DELTA[dirs[i]]
        if not d then break end
        x, y = x + d[1], y + d[2]
        if not (dest and x == dest.x and y == dest.y) then
            local bad, why = W:isFloorChangeTile({ x = x, y = y, z = z }, avoidIds)
            if bad then return true, why, { x = x, y = y, z = z } end
        end
    end
    return false
end

return path
