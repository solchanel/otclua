--[[============================================================================
shim/g_minimap.lua -- `g_minimap` (work item S1).

vBot never touches `g_minimap` directly -- api-game.md sec.3 measured **0/0** call sites.
It exists for two reasons:

 1. `Map::getMinimapColor` (map.cpp:1168-1179) falls back to `g_minimap.getTile(pos).color`
    when the live tile's colour byte is 0.  shim/g_map.lua reproduces that fallback and
    needs somewhere to read it from.
 2. Blocker **B1** (api-game.md sec.6, PLAN sec.6.1): `Map::findEveryPath` reads the
    PERSISTED minimap for every tile outside the aware range, which is the only reason a
    26-tile cavebot `goto` can be pathed at all.  `bot/world.lua` already consumes that
    through `opts.known` (a `lib/minimap.lua` reader over the reference client's
    profiles/minimap.otmm), and `main.lua --minimap=PATH` threads it in as `LC.minimap`.

So this module is a thin, read-only view over `LC.minimap`.  With no minimap loaded it
answers the C++ "nulltile" (minimap.h:41-45, minimap.cpp:52): flags 0, colour 255,
speed byte 10 -> getSpeed() == 100 -- which is what bot/world.lua:knownAt already returns.

MinimapTile flag bits, matching bot/world.lua:248-249:
    1 WasSeen   2 NotPathable   4 NotWalkable   8 Empty
============================================================================]]

local M = {}

local FLAG_WAS_SEEN     = 1
local FLAG_NOT_PATHABLE = 2
local FLAG_NOT_WALKABLE = 4
local FLAG_EMPTY        = 8

M.MinimapTileWasSeen     = FLAG_WAS_SEEN
M.MinimapTileNotPathable = FLAG_NOT_PATHABLE
M.MinimapTileNotWalkable = FLAG_NOT_WALKABLE
M.MinimapTileEmpty       = FLAG_EMPTY

local MinimapTile = {}
MinimapTile.__index = MinimapTile
function MinimapTile:getColor()   return self.color end
function MinimapTile:getFlags()   return self.flags end
-- MinimapTile::getSpeed() = speed byte * 10 (minimap.h)
function MinimapTile:getSpeed()   return self.speed * 10 end
function MinimapTile:hasFlag(f)   return math.floor(self.flags / f) % 2 == 1 end
function MinimapTile:wasSeen()    return self:hasFlag(FLAG_WAS_SEEN) end

-- M.new(LC, reg [, opts]) -> g_minimap
--   opts.known  overrides LC.minimap (anything with :get(pos) -> flags, colorByte, speedByte)
function M.new(LC, reg, opts)
    opts = opts or {}
    local g = {}
    local failed = false

    local function source()
        return opts.known or LC.minimap
    end

    -- Fails OPEN and fails ONCE, exactly like bot/world.lua:knownAt -- a minimap reader that
    -- raises must not be retried tens of thousands of times per pathfinding search.
    local function read(pos)
        local k = source()
        if not k or failed then return 0, 255, 10 end
        local ok, f, c, s = pcall(k.get, k, pos)
        if not ok then
            failed = true
            if LC.log and LC.log.warn then
                LC.log.warn('shim/g_minimap: minimap source raised (%s); ignoring it for the '
                            .. 'rest of the session', tostring(f))
            end
            return 0, 255, 10
        end
        return f or 0, c or 255, s or 10
    end
    g._read = read

    function g.getTile(pos)
        local f, c, s = read(pos)
        return setmetatable({ flags = f, color = c, speed = s }, MinimapTile)
    end

    -- The colour byte alone -- what shim/g_map.getMinimapColor's fallback wants.
    function g.getColor(pos)
        local _, c = read(pos)
        return c
    end

    function g.hasMinimap() return source() ~= nil and not failed end

    function g.setTile() return nil end
    function g.clean()   return nil end
    function g.loadImage() return false end
    function g.saveImage() return false end
    function g.loadOtmm()  return false end
    function g.saveOtmm()  return false end

    setmetatable(g, { __index = function(_, k)
        reg:report('g_minimap.' .. tostring(k), 'unused binding (0 vBot call sites)')
        return function() return nil end
    end })

    return g
end

M.MinimapTile = MinimapTile
return M
