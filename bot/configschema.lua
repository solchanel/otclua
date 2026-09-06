--[[============================================================================
bot/configschema.lua -- work item N2.  The shared schema tables CONFIGAPI.md
requires: "factor the schema tables into a file both sides can load, e.g.
bot/configschema.lua, required by both control/commands.lua and
hub/botconfig.lua".

Every schema below is a plain, JSON-encodable description precise enough for
TWO independent consumers to walk without guessing:

  * a VALIDATOR (this file's own M.validate / M.validateCavebotPairs -- reject,
    don't coerce, on a structural mismatch);
  * a UI FORM GENERATOR (the panel's Bot Config cards, PANEL.md) -- field name,
    type, enum values, and which fields are required.

Field descriptor shape:

    { name = 'sign', type = 'enum', enum = {'=','>','<'}, required = true }

`type` is one of:
    'string' 'number' 'boolean' 'enum' 'monsters' 'any'
    'object'          -- nested fields, itself a { fields = {...} } table
    'array-of-object' -- a JSON array of objects, itself a { fields = {...} } table

`monsters` is vBot's recurring `true | {"lowercase name", ...}` shape (AttackBot
entries, Stances entries, TargetBot creature-config `name`... no -- TargetBot
uses plain strings, see below).  `any` is used only for the handful of
widget-only fields real files sometimes carry (`tooltip: false | "text"`).

FIELD SETS ARE THE REAL ONES, not invented ones.  Every list below cites the
line range in the module that owns the shape, per CONFIGAPI.md's instruction
to read bot/healbot.lua / bot/attackbot.lua / bot/targetbot.lua / bot/cavebot.lua
(and docs/vbot/*.md + the real vBot source when CONFIGAPI.md points there) for
the REAL field set:

  healbot     bot/healbot.lua:100-135 (defaultConditionPanel, blankProfile),
              :350-370 (sourceValue/matches -- sign/origin), and the real
              vBot AttackBot-sibling HealBot.lua:501,536 (spellTable/itemTable
              entry construction: index/spell/sign/origin/cost/value/enabled
              and index/item/sign/origin/value/enabled respectively).
  attackbot   bot/attackbot.lua:96-104 (blankProfile) + :404-1080 (entry.*
              reads: category/spell/itemId/monsters/orMore/count/mana/harmony/
              cooldown/minHp/maxHp/pattern/patternCategory/augmented/enabled),
              cross-checked against docs/vbot/attackbot.md's "Configuration
              format" (the exact entry object, real examples on disk).
  stances     CONFIGAPI.md's documented storage.stances shape, cross-checked
              against the real vBot/Stances.lua:50-56 (module defaults) and
              :363-379 (the entry object a fresh row is built from).
  targetbot   docs/vbot/targetbot.md section 1.2 (the 27-field creature-config
              table) and section 4.1 (the `looting` sub-object), cross-checked
              against bot/targetbot.lua:172-183 (ENTRY_DEFAULTS) and
              bot/loot.lua:252-282 (:update/:save).
  cavebot     docs/vbot/config-compat-cavebot.md sections 1-3 (the `type:value`
              grammar) and section 5 ("Rules for a foreign writer" MUST /
              MUST NEVER), cross-checked against bot/config.lua:837-899
              (Profile:loadCavebot / saveCavebot).

CAVEBOT IS SPECIAL.  Its data shape is the RAW `{type, value}` pair list in
file order -- exactly bot/config.lua's `Profile:loadCavebot(name).pairs`,
renamed `key`->`type` for CONFIGAPI's own wording -- because that is the only
shape that round-trips byte-for-byte through the existing, verified
encodeCfg/decodeCfg and preserves an unknown waypoint type, an unknown
`config` key and a `function` body's exact text.  It gets its own validator
(the generic descriptor walker doesn't know the multi-line-block escaping
rules) and its own function-body-change detector, both exported here so
commands.lua and hub/botconfig.lua call the SAME code rather than two
hand-rolled copies drifting apart.

Lua 5.1 / LuaJIT: no goto, bit.band is signed (unused here), math.floor for
integer division.
============================================================================]]

local M = {}

local floor = math.floor

-- ===========================================================================
-- shared enums
-- ===========================================================================
M.SIGNS   = { '=', '>', '<' }
M.ORIGINS = { 'HP%', 'HP', 'MP%', 'MP', 'burst' }

-- ===========================================================================
-- generic helpers
-- ===========================================================================
--- isPlainArray(t) -> ok, n   -- a table with ONLY integer keys 1..n, no holes.
local function isPlainArray(t)
    if type(t) ~= 'table' then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k ~= floor(k) then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end
M.isPlainArray = isPlainArray

local function isMonstersValue(v)
    if v == true then return true end
    local ok, n = isPlainArray(v)
    if not ok then return false end
    for i = 1, n do if type(v[i]) ~= 'string' then return false end end
    return true
end

local function fieldTypeOk(f, v)
    local t = f.type
    if t == 'boolean' then return type(v) == 'boolean'
    elseif t == 'number' then return type(v) == 'number'
    elseif t == 'string' then return type(v) == 'string'
    elseif t == 'any' then return true
    elseif t == 'monsters' then return isMonstersValue(v)
    elseif t == 'enum' then
        if type(v) ~= 'string' then return false end
        for i = 1, #f.enum do if f.enum[i] == v then return true end end
        return false
    end
    return false
end

--- validateFields(fields, data, path) -> ok, err
--- Recursive: an 'array-of-object' or 'object' field descends with its own
--- `fields` list.  A field absent from `data` is fine unless `required`.
--- UNKNOWN keys inside an entry (array element) are tolerated on purpose --
--- CONFIGAPI.md's compatibility test requires "unknown fields the panel
--- didn't touch survive unchanged", and real vBot files carry legacy entries
--- missing `harmony`/`augmented`/`tooltip` (docs/vbot/attackbot.md VERIFIER).
local function validateFields(fields, data, path)
    if type(data) ~= 'table' then
        return false, (path .. ' must be an object')
    end
    for i = 1, #fields do
        local f = fields[i]
        local v = data[f.name]
        if v == nil then
            if f.required then
                return false, (path .. '.' .. f.name .. ' is required')
            end
        elseif f.type == 'array-of-object' then
            local ok, n = isPlainArray(v)
            if not ok then
                return false, (path .. '.' .. f.name .. ' must be an array')
            end
            for j = 1, n do
                local ok2, err2 = validateFields(f.fields, v[j],
                                   ('%s.%s[%d]'):format(path, f.name, j))
                if not ok2 then return false, err2 end
            end
        elseif f.type == 'object' then
            local ok2, err2 = validateFields(f.fields, v, path .. '.' .. f.name)
            if not ok2 then return false, err2 end
        else
            if not fieldTypeOk(f, v) then
                return false, ('%s.%s must be a %s'):format(path, f.name, f.type)
            end
        end
    end
    return true
end
M.validateFields = validateFields

--- rejectUnknown(fields, data, path) -- strict at ONE level only (the kind's
--- own top-level shape is small and fully enumerated by CONFIGAPI.md; entries
--- inside its arrays stay permissive, see validateFields above).
local function rejectUnknown(fields, data, path)
    if type(data) ~= 'table' then return false, (path .. ' must be an object') end
    local known = {}
    for i = 1, #fields do known[fields[i].name] = true end
    for k in pairs(data) do
        if not known[k] then
            return false, ('%s has an unknown field %q'):format(path, tostring(k))
        end
    end
    return true
end

-- ===========================================================================
-- 1. healbot -- bot/healbot.lua's spellTable / itemTable
-- ===========================================================================
-- HealBot.lua:501 (spellTable) / :536 (itemTable): {index,...,enabled=true} is
-- what the real editor writes; `index` is stale/informational (H:matches never
-- reads it) so it is optional here, exactly as bot/healbot.lua tolerates it.
local HEALBOT_ITEM_FIELDS = {
    { name = 'enabled', type = 'boolean', required = true },
    { name = 'sign',    type = 'enum',    required = true, enum = M.SIGNS },
    { name = 'origin',  type = 'enum',    required = true, enum = M.ORIGINS },
    { name = 'item',    type = 'number',  required = true },   -- item id
    { name = 'value',   type = 'number',  required = true },   -- threshold
    { name = 'index',   type = 'number',  required = false },  -- stale, never read
}

local HEALBOT_SPELL_FIELDS = {
    { name = 'enabled', type = 'boolean', required = true },
    { name = 'sign',    type = 'enum',    required = true, enum = M.SIGNS },
    { name = 'origin',  type = 'enum',    required = true, enum = M.ORIGINS },
    { name = 'spell',   type = 'string',  required = true },   -- words
    { name = 'value',   type = 'number',  required = true },   -- threshold
    { name = 'cost',    type = 'number',  required = false },  -- mana cost; H:spellTick defaults 0
    { name = 'index',   type = 'number',  required = false },
}

local HEALBOT_FIELDS = {
    { name = 'itemTable',  type = 'array-of-object', required = true, fields = HEALBOT_ITEM_FIELDS },
    { name = 'spellTable', type = 'array-of-object', required = true, fields = HEALBOT_SPELL_FIELDS },
}

-- ===========================================================================
-- 2. conditions -- bot/healbot.lua's ConditionPanel (defaultConditionPanel())
-- ===========================================================================
-- Verbatim field set from bot/healbot.lua:121-134.  `curePosion` is the
-- misspelled compat key (CONFIGAPI.md): optional on input, never required;
-- commands.lua keeps it in sync with `curePoison` on write per that contract.
local CONDITIONS_FIELDS = {
    { name = 'enabled',        type = 'boolean', required = true },
    { name = 'curePoison',     type = 'boolean', required = true },
    { name = 'curePosion',     type = 'boolean', required = false },  -- legacy compat key
    { name = 'poisonCost',     type = 'number',  required = true },
    { name = 'cureCurse',      type = 'boolean', required = true },
    { name = 'curseCost',      type = 'number',  required = true },
    { name = 'cureBleed',      type = 'boolean', required = true },
    { name = 'bleedCost',      type = 'number',  required = true },
    { name = 'cureBurn',       type = 'boolean', required = true },
    { name = 'burnCost',       type = 'number',  required = true },
    { name = 'cureElectrify',  type = 'boolean', required = true },
    { name = 'electrifyCost',  type = 'number',  required = true },
    { name = 'cureParalyse',   type = 'boolean', required = true },
    { name = 'paralyseCost',   type = 'number',  required = true },
    { name = 'paralyseSpell',  type = 'string',  required = true },
    { name = 'holdHaste',      type = 'boolean', required = true },
    { name = 'hasteCost',      type = 'number',  required = true },
    { name = 'hasteSpell',     type = 'string',  required = true },
    { name = 'holdUtamo',      type = 'boolean', required = true },
    { name = 'utamoCost',      type = 'number',  required = true },
    { name = 'holdUtana',      type = 'boolean', required = true },
    { name = 'utanaCost',      type = 'number',  required = true },
    { name = 'holdUtura',      type = 'boolean', required = true },
    { name = 'uturaType',      type = 'string',  required = true },   -- may be ''
    { name = 'uturaCost',      type = 'number',  required = true },
    { name = 'ignoreInPz',     type = 'boolean', required = true },
    { name = 'stopHaste',      type = 'boolean', required = true },
}

-- ===========================================================================
-- 3. attackbot -- bot/attackbot.lua's attackTable (kind's shape IS the array)
-- ===========================================================================
-- docs/vbot/attackbot.md "Entry object" + the VERIFIER note that harmony /
-- augmented / tooltip are legacy-optional (missing on pre-2024 saved entries).
local ATTACKBOT_ENTRY_FIELDS = {
    { name = 'category',        type = 'number',   required = true },   -- 1..5
    { name = 'patternCategory', type = 'number',   required = true },   -- 1..4
    { name = 'pattern',         type = 'number',   required = true },   -- range | grid id
    { name = 'spell',           type = 'string',   required = true },   -- '' when itemId is a rune
    { name = 'itemId',          type = 'number',   required = true },   -- >100 => rune
    { name = 'count',           type = 'number',   required = true },
    { name = 'orMore',          type = 'boolean',  required = false },  -- nil => exact count
    { name = 'minHp',           type = 'number',   required = true },
    { name = 'maxHp',           type = 'number',   required = true },
    { name = 'mana',            type = 'number',   required = true },   -- minimum manapercent()
    { name = 'cooldown',        type = 'number',   required = true },   -- ms (spell) | s (rune)
    { name = 'harmony',         type = 'number',   required = false },  -- legacy-optional
    { name = 'monsters',        type = 'monsters', required = true },
    { name = 'augmented',       type = 'boolean',  required = false },  -- legacy-optional
    { name = 'enabled',         type = 'boolean',  required = true },
    -- widget-only, persisted verbatim by the real editor; kept optional so a
    -- round trip of a real file never trips "unknown field" at the entry level
    -- (entries stay permissive, see validateFields above).
    { name = 'creatures',       type = 'string',   required = false },
    { name = 'tooltip',         type = 'any',      required = false },  -- false | "text"
    { name = 'description',     type = 'string',   required = false },
}

-- ===========================================================================
-- 4. stances -- storage.stances (CONFIGAPI.md; native module bot/stances.lua)
-- ===========================================================================
-- Entry fields from the real vBot/Stances.lua:363-379 `params` table build.
local STANCES_ENTRY_FIELDS = {
    { name = 'spell',      type = 'string',   required = true },   -- words
    { name = 'spellId',    type = 'number',   required = true },
    { name = 'stanceName', type = 'string',   required = false },
    { name = 'needTarget', type = 'boolean',  required = false },
    { name = 'monsters',   type = 'monsters', required = true },
    { name = 'minHp',      type = 'number',   required = true },
    { name = 'maxHp',      type = 'number',   required = true },
    { name = 'minMana',    type = 'number',   required = true },
    { name = 'count',      type = 'number',   required = true },
    { name = 'range',      type = 'number',   required = true },
    { name = 'orMore',     type = 'boolean',  required = false },
    { name = 'enabled',    type = 'boolean',  required = true },
    -- widget-only, persisted verbatim
    { name = 'creatures',   type = 'string', required = false },
    { name = 'tooltip',     type = 'any',    required = false },
    { name = 'description', type = 'string', required = false },
}

local STANCES_FIELDS = {
    { name = 'enabled',    type = 'boolean',         required = true },
    { name = 'ignoreInPz', type = 'boolean',         required = true },
    { name = 'entries',    type = 'array-of-object', required = true, fields = STANCES_ENTRY_FIELDS },
}

-- ===========================================================================
-- 5. targetbot -- docs/vbot/targetbot.md section 1.2 (targeting) + 4.1 (looting)
-- ===========================================================================
-- All 27 creature-config fields.  Only `name` is required: every other field
-- has a documented default (bot/targetbot.lua:172-183 ENTRY_DEFAULTS) and a
-- real file may omit any of them (spec 1.2's "never written" group is the
-- extreme case -- always nil on disk).  `regex` is the cached, PERSISTED
-- derived value (docs 1.3); it is optional here because a caller may leave it
-- to be recomputed and because older entries may lack it.
local TARGETING_ENTRY_FIELDS = {
    { name = 'name',              type = 'string',  required = true },
    { name = 'regex',             type = 'string',  required = false },
    { name = 'priority',          type = 'number',  required = false },
    { name = 'danger',            type = 'number',  required = false },
    { name = 'maxDistance',       type = 'number',  required = false },
    { name = 'chase',             type = 'boolean', required = false },
    { name = 'keepDistance',      type = 'boolean', required = false },
    { name = 'keepDistanceRange', type = 'number',  required = false },
    { name = 'anchor',            type = 'boolean', required = false },
    { name = 'anchorRange',       type = 'number',  required = false },
    { name = 'avoidAttacks',      type = 'boolean', required = false },
    { name = 'faceMonster',       type = 'boolean', required = false },
    { name = 'rePosition',        type = 'boolean', required = false },
    { name = 'rePositionAmount',  type = 'number',  required = false },
    { name = 'lure',              type = 'boolean', required = false },
    { name = 'lureCount',         type = 'number',  required = false },
    { name = 'lureCavebot',       type = 'boolean', required = false },
    { name = 'dynamicLure',       type = 'boolean', required = false },
    { name = 'lureMin',           type = 'number',  required = false },
    { name = 'lureMax',           type = 'number',  required = false },
    { name = 'dynamicLureDelay',  type = 'boolean', required = false },
    { name = 'lureDelay',         type = 'number',  required = false },
    { name = 'delayFrom',         type = 'number',  required = false },
    { name = 'closeLure',         type = 'boolean', required = false },
    { name = 'closeLureAmount',   type = 'number',  required = false },
    { name = 'dontLoot',          type = 'boolean', required = false },
    { name = 'diamondArrows',     type = 'boolean', required = false },
    { name = 'rpSafe',            type = 'boolean', required = false },
    -- Note: the "declared but never written by the 4.8 editor" attack-model
    -- fields (useGroupAttack, attackSpell, minMana, ...) are deliberately NOT
    -- enumerated here.  They are always nil in every real file (docs/vbot/
    -- targetbot.md section 1.2), entries stay permissive to unknown keys
    -- (see validateFields), so a caller MAY still send them through untouched.
}

-- docs/vbot/targetbot.md section 4.1 + bot/loot.lua:252-282.
local LOOT_ITEM_FIELDS = {
    { name = 'id',    type = 'number', required = true },
    { name = 'count', type = 'number', required = false },  -- written, never read
}

local LOOTING_FIELDS = {
    { name = 'items',       type = 'array-of-object', required = false, fields = LOOT_ITEM_FIELDS },
    { name = 'containers',  type = 'array-of-object', required = false, fields = LOOT_ITEM_FIELDS },
    { name = 'everyItem',   type = 'boolean',          required = false },
    { name = 'maxDanger',   type = 'number',           required = false },
    { name = 'minCapacity', type = 'number',           required = false },
}

local TARGETBOT_FIELDS = {
    { name = 'targeting', type = 'array-of-object', required = true,  fields = TARGETING_ENTRY_FIELDS },
    { name = 'looting',   type = 'object',           required = false, fields = LOOTING_FIELDS },
}

-- ===========================================================================
-- kind registry
-- ===========================================================================
-- `top`: 'object' (the default) or 'array' -- attackbot's shape IS the bare
-- attackTable array (CONFIGAPI.md's shape column), not an object wrapping it.
M.kinds = {
    healbot    = { top = 'object', fields = HEALBOT_FIELDS },
    conditions = { top = 'object', fields = CONDITIONS_FIELDS },
    attackbot  = { top = 'array',  fields = ATTACKBOT_ENTRY_FIELDS },
    stances    = { top = 'object', fields = STANCES_FIELDS },
    targetbot  = { top = 'object', fields = TARGETBOT_FIELDS },
    -- cavebot has no descriptor-driven schema; see M.validateCavebotPairs.
    cavebot    = { top = 'cavebot-pairs',
                   fields = {
                       { name = 'type',  type = 'string', required = true },
                       { name = 'value', type = 'string', required = true },
                   } },
}

M.KIND_NAMES = { 'healbot', 'conditions', 'attackbot', 'stances', 'targetbot', 'cavebot' }

-- ===========================================================================
-- cavebot -- docs/vbot/config-compat-cavebot.md sections 1, 2, 5
-- ===========================================================================
-- The MUST / MUST NEVER rules a foreign writer has to follow (section 5),
-- restated as checks so a bad payload is rejected before it ever reaches
-- bot/config.lua's encodeCfg -- which trusts its input completely (it is the
-- verified LOW-level writer, not a validator).
local CAVEBOT_TYPE_MAX = 20

local function pairType(p)  return p.type  or p[1] end
local function pairValue(p) return p.value or p[2] end
M.cavebotPairType, M.cavebotPairValue = pairType, pairValue

local RESERVED = { config = true, extensions = true, staypositions = true }
M.CAVEBOT_RESERVED_KEYS = RESERVED

--- validateCavebotPairs(data) -> ok, err
--- `data` is an array of {type=, value=} (or positional {ty, val}) pairs, in
--- file order -- exactly what config.get('cavebot') hands back.
function M.validateCavebotPairs(data)
    local ok, n = isPlainArray(data)
    if not ok then return false, 'cavebot data must be an array of {type, value}' end
    if n == 0 then return true end  -- an empty route is legal (CaveBot off / new)

    for i = 1, n do
        local p = data[i]
        if type(p) ~= 'table' then
            return false, ('cavebot[%d] is not an object'):format(i)
        end
        local ty, val = pairType(p), pairValue(p)

        if type(ty) ~= 'string' or ty == '' then
            return false, ('cavebot[%d]: type must be a non-empty string'):format(i)
        end
        if #ty > CAVEBOT_TYPE_MAX then
            return false, ('cavebot[%d]: type %q is longer than %d bytes'):format(i, ty, CAVEBOT_TYPE_MAX)
        end
        if ty:find('[:%^]') or ty:find('\n') then
            return false, ('cavebot[%d]: type %q contains a forbidden character (":" "^" or newline)')
                          :format(i, ty)
        end
        if ty:match('^%s') or ty:match('%s$') then
            return false, ('cavebot[%d]: type %q has leading or trailing whitespace'):format(i, ty)
        end
        if ty ~= ty:lower() then
            return false, ('cavebot[%d]: type %q must be lowercase'):format(i, ty)
        end

        if type(val) ~= 'string' then
            return false, ('cavebot[%d] (%s): value must be a string'):format(i, ty)
        end
        if val == '' then
            return false, ('cavebot[%d] (%s): value must not be empty ' ..
                           '(an empty value drops the whole waypoint on load)'):format(i, ty)
        end
        if val:find('\r', 1, true) then
            return false, ('cavebot[%d] (%s): value must not contain a carriage return ' ..
                           '(CRLF is not supported by the .cfg grammar)'):format(i, ty)
        end

        local multiline = val:find('\n', 1, true) ~= nil
        if multiline then
            -- encodeCfg wraps any '\n'-carrying value as type:[[\n...\n]]\n --
            -- an embedded "]]" would end that block early and truncate the rest
            -- of the file (MUST NEVER #2).
            if val:find(']]', 1, true) then
                return false, ('cavebot[%d] (%s): a multi-line value must not contain "]]" ' ..
                               '(it would truncate the block on load)'):format(i, ty)
            end
        else
            -- a single-line value is written as a plain "type:value" -- but if it
            -- STARTS with "[[", decodeCfg will still misread it as a block opener
            -- (MUST NEVER #4).
            if val:sub(1, 2) == '[[' then
                return false, ('cavebot[%d] (%s): a single-line value must not start with "[[" ' ..
                               '(it would be misread as a multi-line block on load)'):format(i, ty)
            end
        end

        if RESERVED[ty] then
            local cfglib = require('bot.config')
            local decoded = cfglib.jsonDecode(val)
            if decoded == nil then
                return false, ('cavebot[%d]: %q is a reserved key and must be valid JSON'):format(i, ty)
            end
        end
    end
    return true
end

--- cavebotFunctionBodyChanged(oldPairs, newPairs) -> bool
---
--- The security-critical predicate (CONFIGAPI.md): true only when the diff
--- ADDS or CHANGES a `function`-type waypoint's Lua body -- never for a pure
--- reorder of the same bodies, and never for an edit to a non-function value.
---
--- Algorithm: count how many times each exact `function` body string occurs
--- in the OLD list; walk the NEW list decrementing that count per occurrence.
--- The moment a `function` body appears in NEW more times than it appeared in
--- OLD, that occurrence cannot be explained by "the same bodies, reordered" or
--- "one was removed" -- it is new or edited text.  Removing a function
--- waypoint (fewer occurrences in NEW) never trips this, matching CONFIGAPI's
--- "adds or changes", not "touches".
function M.cavebotFunctionBodyChanged(oldPairs, newPairs)
    local have = {}
    for _, p in ipairs(oldPairs or {}) do
        if pairType(p) == 'function' then
            local v = pairValue(p)
            have[v] = (have[v] or 0) + 1
        end
    end
    for _, p in ipairs(newPairs or {}) do
        if pairType(p) == 'function' then
            local v = pairValue(p)
            local n = have[v] or 0
            if n <= 0 then return true end
            have[v] = n - 1
        end
    end
    return false
end

--- cavebotRouteFromPairs(pairs_) -> route
--- Builds exactly what bot/cavebot.lua's CB:reload(route) expects:
--- { waypoints = {{action=,value=,index=},...}, config=, extensions=,
---   staypositions= } -- mirroring bot/config.lua's Profile:loadCavebot loop
--- (RESERVED keys are JSON-decoded into top-level fields; everything else
--- becomes a waypoint in order).
function M.cavebotRouteFromPairs(pairs_)
    local cfglib = require('bot.config')
    local out = { waypoints = {} }
    for _, p in ipairs(pairs_ or {}) do
        local k, v = pairType(p), pairValue(p)
        if RESERVED[k] then
            local decoded = cfglib.jsonDecode(v)
            out[k] = decoded
        else
            out.waypoints[#out.waypoints + 1] =
                { action = k, value = v, index = #out.waypoints + 1 }
        end
    end
    return out
end

--- cavebotPairsFromRoute(route) -> pairs_ (positional {type, value})
--- The inverse, mirroring bot/config.lua's Profile:saveCavebot -- waypoints
--- first in order, then config/extensions/staypositions (only the ones that
--- are non-nil), matching vBot's own write order (section 3 "Placement").
function M.cavebotPairsFromRoute(route)
    local cfglib = require('bot.config')
    local out = {}
    local wps = (route and route.waypoints) or {}
    for i = 1, #wps do
        local w = wps[i]
        out[#out + 1] = { type = w.action or w[1], value = w.value or w[2] }
    end
    if route and route.config ~= nil then
        out[#out + 1] = { type = 'config', value = (cfglib.jsonEncode(route.config)) }
    end
    if route and route.extensions ~= nil then
        out[#out + 1] = { type = 'extensions', value = (cfglib.jsonEncode(route.extensions)) }
    end
    if route and route.staypositions ~= nil then
        out[#out + 1] = { type = 'staypositions', value = (cfglib.jsonEncode(route.staypositions)) }
    end
    return out
end

-- ===========================================================================
-- audit diff summary -- hub/api.lua's instance.configSet audit record
-- ===========================================================================
-- Security review finding (major): every kind's audit `detail` used to name
-- only the KIND (`kind=healbot`), never what changed -- not actionable for an
-- admin.  This builds a short, bounded-size "changed=..." summary from the
-- PRE-WRITE value (fetched via config.get / botconfig.get before the write --
-- see hub/api.lua) and the value being written.  Only used for the audit
-- trail; never affects validation or what gets persisted.  A cavebot
-- `function`-body change keeps its existing separate full-body audit
-- treatment (hub/api.lua's finish()) -- this is for every OTHER write,
-- including an ordinary (non-function) cavebot edit.
local DIFF_MAX_ITEMS      = 24  -- cap so one huge array edit can't blow the budget
local DIFF_STRING_PREVIEW = 40  -- truncate long string scalars inside the summary

local function formatDiffVal(v)
    local t = type(v)
    if v == nil then return 'nil' end
    if t == 'boolean' or t == 'number' then return tostring(v) end
    if t == 'string' then
        if #v > DIFF_STRING_PREVIEW then
            return ('%q'):format(v:sub(1, DIFF_STRING_PREVIEW) .. '...')
        end
        return ('%q'):format(v)
    end
    if t == 'table' then
        local okj, txt = pcall(function() return require('lib.json').encode(v) end)
        if okj and type(txt) == 'string' then
            if #txt > 60 then return txt:sub(1, 60) .. '...' end
            return txt
        end
        return '<table>'
    end
    return tostring(v)
end

--- diffWalk(path, old, new, out, budget) -- appends "path:old->new" (and, for
--- an array whose length changed, "path entries added=N removed=M") entries
--- to `out`, recursing into nested objects and arrays-of-objects, stopping
--- once `budget.max` entries have been recorded so the final string stays
--- bounded no matter how large the payload is.
local function diffWalk(path, old, new, out, budget)
    if budget.n >= budget.max then return end
    if old == new then return end  -- nil==nil, identical scalars, or the same table

    local oldIsArr = isPlainArray(old)
    local newIsArr = isPlainArray(new)
    if oldIsArr and newIsArr then
        local oldN, newN = #old, #new
        local common = (oldN < newN) and oldN or newN
        for i = 1, common do
            if budget.n >= budget.max then return end
            diffWalk(path .. '[' .. i .. ']', old[i], new[i], out, budget)
        end
        if oldN ~= newN then
            budget.n = budget.n + 1
            out[#out + 1] = ('%s entries added=%d removed=%d'):format(
                path, (newN > oldN) and (newN - oldN) or 0, (oldN > newN) and (oldN - newN) or 0)
        end
        return
    end

    if type(old) == 'table' and type(new) == 'table' and not oldIsArr and not newIsArr then
        local seen = {}
        for k in pairs(old) do
            seen[k] = true
            if budget.n >= budget.max then return end
            diffWalk(path .. '.' .. tostring(k), old[k], new[k], out, budget)
        end
        for k in pairs(new) do
            if not seen[k] then
                if budget.n >= budget.max then return end
                diffWalk(path .. '.' .. tostring(k), old[k], new[k], out, budget)
            end
        end
        return
    end

    -- scalar, or a type mismatch (e.g. `monsters`'s true|array, or a table
    -- replaced outright) -- record it directly rather than recursing further.
    budget.n = budget.n + 1
    out[#out + 1] = ('%s:%s->%s'):format(path, formatDiffVal(old), formatDiffVal(new))
end

--- M.diffSummary(kind, oldData, newData[, maxBytes]) -> a short "changed=..."
--- string, byte-capped at maxBytes (default 900).  `oldData` is the
--- PRE-WRITE value; nil when unavailable (e.g. the module wasn't running to
--- answer a config.get) -- diffing degrades to an honest "unavailable" note
--- rather than erroring, since a missing pre-image must never block the
--- write itself (only the audit's usefulness).
function M.diffSummary(kind, oldData, newData, maxBytes)
    maxBytes = maxBytes or 900
    if oldData == nil then
        return 'kind=' .. kind .. ' changed=(no prior value available for diff)'
    end
    local out = {}
    diffWalk(kind, oldData, newData, out, { n = 0, max = DIFF_MAX_ITEMS })
    local detail
    if #out == 0 then
        detail = 'kind=' .. kind .. ' changed=(no field differences detected)'
    else
        detail = 'kind=' .. kind .. ' changed=' .. table.concat(out, '; ')
    end
    if #detail > maxBytes then
        detail = detail:sub(1, maxBytes) .. '...(truncated)'
    end
    return detail
end

--- M.cavebotFunctionShapeChanged(oldPairs, newPairs) -> bool
--- Minor security-review finding: cavebotFunctionBodyChanged (by design, see
--- its own doc comment) does not trip on a pure relocation of an identical
--- function body (net-zero occurrence count for that exact string) -- correct
--- for the canExec gate (no new code can ever run without it), but that
--- relocation should still be VISIBLE in the audit trail instead of being
--- silently indistinguishable from an ordinary value edit.  True whenever the
--- ordered list of indices holding a function-typed waypoint differs between
--- old and new, even when cavebotFunctionBodyChanged itself returns false.
function M.cavebotFunctionShapeChanged(oldPairs, newPairs)
    local function functionIndices(pairs_)
        local idxs = {}
        for i, p in ipairs(pairs_ or {}) do
            if pairType(p) == 'function' then idxs[#idxs + 1] = i end
        end
        return idxs
    end
    local oldIdx, newIdx = functionIndices(oldPairs), functionIndices(newPairs)
    if #oldIdx ~= #newIdx then return true end
    for i = 1, #oldIdx do
        if oldIdx[i] ~= newIdx[i] then return true end
    end
    return false
end

-- ===========================================================================
-- top-level validate
-- ===========================================================================
--- M.validate(kind, data) -> ok, err
--- The single entry point BOTH control/commands.lua and hub/botconfig.lua call
--- (CONFIGAPI.md: "the same validation... mirrored, not reimplemented").
function M.validate(kind, data)
    local schema = M.kinds[kind]
    if not schema then
        return false, ('unknown config kind %q'):format(tostring(kind))
    end
    if schema.top == 'cavebot-pairs' then
        return M.validateCavebotPairs(data)
    end
    if schema.top == 'array' then
        local ok, n = isPlainArray(data)
        if not ok then return false, (kind .. ' data must be an array') end
        for i = 1, n do
            local ok2, err2 = validateFields(schema.fields, data[i], ('%s[%d]'):format(kind, i))
            if not ok2 then return false, err2 end
        end
        return true
    end
    -- object-shaped: strict on the kind's own top level (it is small and
    -- fully enumerated by CONFIGAPI.md); permissive inside nested entry arrays.
    local ok, err = rejectUnknown(schema.fields, data, kind)
    if not ok then return false, err end
    return validateFields(schema.fields, data, kind)
end

return M
