--[[============================================================================
shim/position.lua -- position helpers for the otclient compatibility shim (work item S1).

Positions are PLAIN LUA TABLES `{x=,y=,z=}` on both sides of the C++ binder, and vBot
builds them literally (`{x=65535, y=slot, z=0}`), reads `.x/.y/.z` directly and serialises
them as `x..","..y..","..z` (mods/game_bot/functions/map.lua:116-140).  So there is no
Position CLASS to emulate -- this module is internal plumbing only and installs no global.
`shim/otlua.lua` (work item W2-G) loads otclient's own `modules/gamelib/position.lua`
verbatim on top of the shim; nothing here may collide with it.

THE THREE POSITION FORMS (api-game.md sec.0.3, invariant I3) -- all three are real wire
addresses and getting them wrong silently corrupts every move / use / stow:

    tile item        {x, y, z}                       the tile's own position
    container item   {x=0xFFFF, y=containerId|0x40, z=slot}   (container.h:37, 0-BASED slot)
    equipped item    {x=0xFFFF, y=inventorySlot, z=0}         (game.cpp:325)
    detached item    {x=0xFFFF, y=0xFFFF, z=255}     Position() -- isValid() == false

`Thing::getStackPos()` (thing.cpp:94-104) returns `m_position.z` whenever
`m_position.x == 0xFFFF and isItem()`, and the stored tile stack index otherwise.

DIRECTIONS are Otc::Direction (const.h:158-170): N=0 E=1 S=2 W=3 NE=4 SE=5 SW=6 NW=7.
============================================================================]]

local bit = require('bit')
local bor, band = bit.bor, bit.band

local P = {}

P.INVALID_COORD = 65535
P.INVALID_Z     = 255
P.CONTAINER_FLAG = 0x40      -- container.h:37 `m_id | 0x40`

-- Otc::Direction -> {dx, dy}
local DELTA = {
    [0] = {  0, -1 },  -- North
    [1] = {  1,  0 },  -- East
    [2] = {  0,  1 },  -- South
    [3] = { -1,  0 },  -- West
    [4] = {  1, -1 },  -- NorthEast
    [5] = {  1,  1 },  -- SouthEast
    [6] = { -1,  1 },  -- SouthWest
    [7] = { -1, -1 },  -- NorthWest
}
P.DELTA = DELTA
P.DIRECTIONS = { North = 0, East = 1, South = 2, West = 3,
                 NorthEast = 4, SouthEast = 5, SouthWest = 6, NorthWest = 7,
                 Invalid = 8 }

function P.new(x, y, z)
    return { x = x, y = y, z = z }
end

function P.copy(p)
    if type(p) ~= 'table' then return nil end
    return { x = p.x, y = p.y, z = p.z }
end

function P.is(p)
    return type(p) == 'table' and type(p.x) == 'number'
       and type(p.y) == 'number' and type(p.z) == 'number'
end

function P.equals(a, b)
    if not (P.is(a) and P.is(b)) then return false end
    return a.x == b.x and a.y == b.y and a.z == b.z
end

-- Position::isValid() (position.h:183): everything except the (65535,65535,255) sentinel.
function P.isValid(p)
    if not P.is(p) then return false end
    return not (p.x == P.INVALID_COORD and p.y == P.INVALID_COORD and p.z == P.INVALID_Z)
end

function P.invalid()
    return { x = P.INVALID_COORD, y = P.INVALID_COORD, z = P.INVALID_Z }
end

-- "x,y,z" -- the key functions/map.lua uses for every findEveryPath node.
function P.key(p)
    return p.x .. ',' .. p.y .. ',' .. p.z
end

function P.parse(s)
    if type(s) ~= 'string' then return nil end
    local x, y, z = s:match('^%s*(-?%d+)%s*,%s*(-?%d+)%s*,%s*(-?%d+)%s*$')
    if not x then return nil end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

function P.translated(p, dx, dy, dz)
    return { x = p.x + (dx or 0), y = p.y + (dy or 0), z = p.z + (dz or 0) }
end

function P.translatedToDirection(p, dir)
    local d = DELTA[dir]
    if not d then return P.copy(p) end
    return { x = p.x + d[1], y = p.y + d[2], z = p.z }
end

-- Chebyshev, the distance every vBot range test uses.
function P.distance(a, b)
    if not (P.is(a) and P.is(b)) then return math.huge end
    local dx, dy = a.x - b.x, a.y - b.y
    if dx < 0 then dx = -dx end
    if dy < 0 then dy = -dy end
    return (dx > dy) and dx or dy
end

-- ---------------------------------------------------------------------------
-- the synthetic forms
-- ---------------------------------------------------------------------------

-- Container::getSlotPosition (container.h:37).  `slot` is 0-BASED.
function P.containerSlot(containerId, slot)
    return { x = P.INVALID_COORD, y = bor(containerId, P.CONTAINER_FLAG), z = slot }
end

-- game.cpp:325 -- what the client stamps onto an equipped item.
function P.inventorySlot(slot)
    return { x = P.INVALID_COORD, y = slot, z = 0 }
end

-- "means that is a item in inventory" (game.cpp:846/860/873/900) -- the fallback source
-- position g_game.use / useWith / useInventoryItem* put on the wire for a virtual item.
function P.virtualInventory()
    return { x = P.INVALID_COORD, y = 0, z = 0 }
end

-- Is this one of the two 0xFFFF forms?  (Thing::getStackPos's discriminator.)
function P.isSynthetic(p)
    return P.is(p) and p.x == P.INVALID_COORD
end

function P.isContainerRef(p)
    return P.isSynthetic(p) and p.y ~= P.INVALID_COORD and band(p.y, P.CONTAINER_FLAG) ~= 0
end

function P.isInventoryRef(p)
    return P.isSynthetic(p) and p.y ~= P.INVALID_COORD and band(p.y, P.CONTAINER_FLAG) == 0
end

return P
