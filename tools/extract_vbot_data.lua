--[[============================================================================
tools/extract_vbot_data.lua  --  generate the two static data assets the bot
layer needs, straight out of the READ-ONLY otclient/vBot sources.

    luajit tools/extract_vbot_data.lua [<otclientRoot>]

Writes (deterministically, byte-for-byte reproducible):

  data/spells1530.lua        words(lower) -> { id, level, mana, exhaustion,
                                               group = {[gid]=ms}, name }
                             from modules/gamelib/spells.lua SpellInfo['Default']
                             (vlib.lua:278 hardcodes the 'Default' profile).

  data/attackpatterns1530.lua  spellPatterns / monkDirPatterns / quadrant grids /
                             WAVE_AUGMENTS, verbatim out of vBot/AttackBot.lua.

Both are pure data; the extractor never runs vBot code that touches the client.
The three source slices are located by ANCHOR TEXT, not by hard-coded line
numbers, so a differently-versioned AttackBot.lua fails loudly instead of
producing garbage.
============================================================================]]

local ROOT = ...
ROOT = ROOT or 'D:/Claude/otclient_mehah1530/otclient'
ROOT = ROOT:gsub('\\', '/'):gsub('/$', '')

local OUT = 'data'

local function read(path)
    local f = assert(io.open(path, 'rb'), 'cannot open ' .. path)
    local s = f:read('*a'); f:close(); return s
end

-- ---------------------------------------------------------------------------
-- slice helpers
-- ---------------------------------------------------------------------------
--- everything between the line that starts with `startAnchor` (inclusive of the
--- part after `=`) and the first line that is exactly `endAnchor`.
local function sliceAssignment(src, name)
    local i = src:find('\nlocal ' .. name .. ' = ', 1, true)
    assert(i, 'anchor not found: local ' .. name)
    local j = src:find('\n}', i, true)
    assert(j, 'end of table not found for ' .. name)
    return src:sub(i + #('\nlocal ' .. name .. ' = '), j + 1)
end

local function evalTable(text, what)
    local chunk, err = loadstring('return ' .. text, what)
    assert(chunk, (what or '?') .. ': ' .. tostring(err))
    local ok, v = pcall(chunk)
    assert(ok, (what or '?') .. ': ' .. tostring(v))
    return v
end

-- ---------------------------------------------------------------------------
-- serialisation (sorted keys => deterministic output)
-- ---------------------------------------------------------------------------
local function q(s)
    if s:find('\n') then
        local eq = ''
        while s:find(']' .. eq .. ']', 1, true) do eq = eq .. '=' end
        return '[' .. eq .. '[\n' .. s .. ']' .. eq .. ']'
    end
    return string.format('%q', s)
end

local function sortedKeys(t)
    local nk, sk = {}, {}
    for k in pairs(t) do
        if type(k) == 'number' then nk[#nk + 1] = k else sk[#sk + 1] = tostring(k) end
    end
    table.sort(nk); table.sort(sk)
    return nk, sk
end

local ser
ser = function(v, indent)
    local t = type(v)
    if t == 'string' then return q(v) end
    if t == 'number' or t == 'boolean' then return tostring(v) end
    if t ~= 'table' then error('cannot serialise ' .. t) end
    local nk, sk = sortedKeys(v)
    local pad, pad2 = string.rep(' ', indent), string.rep(' ', indent + 2)
    local out = { '{' }
    -- dense array part first, unindexed
    local n, dense = #v, true
    for i = 1, n do if v[i] == nil then dense = false end end
    local seen = {}
    if dense and n > 0 then
        for i = 1, n do
            seen[i] = true
            out[#out + 1] = pad2 .. ser(v[i], indent + 2) .. ','
        end
    end
    for _, k in ipairs(nk) do
        if not seen[k] then
            out[#out + 1] = pad2 .. '[' .. k .. '] = ' .. ser(v[k], indent + 2) .. ','
        end
    end
    for _, k in ipairs(sk) do
        out[#out + 1] = pad2 .. '[' .. string.format('%q', k) .. '] = ' ..
                        ser(v[k], indent + 2) .. ','
    end
    out[#out + 1] = pad .. '}'
    return table.concat(out, '\n')
end

-- ===========================================================================
-- 1. the spell database
-- ===========================================================================
local function buildSpells()
    local src = read(ROOT .. '/modules/gamelib/spells.lua')
    local env = {}
    local chunk = assert(loadstring(src, 'spells.lua'))
    setfenv(chunk, setmetatable(env, { __index = _G }))
    assert(pcall(chunk))
    local info = assert(env.SpellInfo and env.SpellInfo['Default'],
                        "SpellInfo['Default'] missing")

    local out, n, dupes = {}, 0, 0
    for name, s in pairs(info) do
        local w = tostring(s.words or ''):lower()
        if #w > 0 then
            if out[w] then dupes = dupes + 1 end
            local grp
            if type(s.group) == 'table' then
                grp = {}
                for gid, ms in pairs(s.group) do grp[gid] = ms end
            end
            out[w] = { id = s.id, level = s.level or 1, mana = s.mana or 0,
                       exhaustion = s.exhaustion, group = grp, name = name }
            n = n + 1
        end
    end
    return out, n, dupes
end

-- ===========================================================================
-- 2. the attack pattern grids
-- ===========================================================================
local function buildPatterns()
    local src = read(ROOT .. '/profiles/bot/vBot_4.8/vBot/AttackBot.lua')

    local spellPatterns   = evalTable(sliceAssignment(src, 'spellPatterns'),   'spellPatterns')
    local monkDirPatterns = evalTable(sliceAssignment(src, 'monkDirPatterns'), 'monkDirPatterns')
    local waveAugments    = evalTable(sliceAssignment(src, 'WAVE_AUGMENTS'),   'WAVE_AUGMENTS')

    -- The quadrant grids depend on `ek` (AB:842, frozen at chunk load for a
    -- knight).  Extract BOTH variants; the runtime picks by vocation.
    local qi = assert(src:find('\nlocal posN = ', 1, true), 'posN anchor')
    local qj = assert(src:find('\nlocal monkDirPatterns', 1, true), 'monkDirPatterns anchor')
    local quadSrc = src:sub(qi, qj)
    local quad = {}
    for _, ek in ipairs({ true, false }) do
        local chunk = assert(loadstring('local ek = ' .. tostring(ek) .. '\n' .. quadSrc ..
                                        '\nreturn { [0] = posN, [1] = posE, [2] = posS, [3] = posW }',
                                        'quadrants'))
        quad[ek and 'knight' or 'other'] = chunk()
    end
    return spellPatterns, monkDirPatterns, waveAugments, quad
end

-- ===========================================================================
-- main
-- ===========================================================================
local spells, spellCount, dupes = buildSpells()
local sp, monk, aug, quad = buildPatterns()

local HDR = [[
-- GENERATED by tools/extract_vbot_data.lua -- DO NOT EDIT BY HAND.
-- Source: %s
-- %s
]]

local f = assert(io.open(OUT .. '/spells1530.lua', 'wb'))
f:write(string.format(HDR, 'modules/gamelib/spells.lua  SpellInfo[\'Default\']',
        'words(lowercase) -> { id, level, mana, exhaustion, group = {[groupId]=ms}, name }'))
f:write('return ' .. ser(spells, 0) .. '\n')
f:close()

local pat = { spellPatterns = sp, monkDirPatterns = monk, waveAugments = aug,
              quadrant = quad }
f = assert(io.open(OUT .. '/attackpatterns1530.lua', 'wb'))
f:write(string.format(HDR, 'profiles/bot/vBot_4.8/vBot/AttackBot.lua',
        'spellPatterns[cat][id][1=real,2=pvpSafe], monkDirPatterns[id][dir], quadrant[voc][dir]'))
f:write('return ' .. ser(pat, 0) .. '\n')
f:close()

local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end
io.write(string.format('spells       : %d words (%d duplicate words collapsed)\n', spellCount, dupes))
io.write(string.format('spellPatterns: cat2=%d cat4=%d\n', count(sp[2]), count(sp[4])))
io.write(string.format('monkDir      : %d patterns\n', count(monk)))
io.write(string.format('quadrant     : knight/other\n'))
io.write(string.format('waveAugments : %d\n', count(aug)))
