-- hub/model.lua -- typed entities, validation, id generation and referential integrity for the
-- hub's data model (PANEL.md, "Data model").
--
-- hub/storage.lua knows how to put an array of tables on disk without losing it.  This module is
-- what decides which tables are allowed in there.  Everything the panel writes goes through
-- db:insert / db:update / db:delete, and every one of those either produces a row that satisfies
-- the whole schema or produces `nil, err` and changes nothing.
--
-- ============================================================================================
-- ENTITIES  (field -> type; ? = optional, -> = reference)
-- ============================================================================================
--   users       id, name (unique, case-insensitive), role in {admin,user}, pwhash,
--               createdAt, disabled
--   accounts    id, label, login, password? (enc), token2fa? (enc), ownerUserId -> users,
--               createdAt                                            [game accounts]
--   characters  id, accountId -> accounts, name, world, vocation?, lastLevel?
--   proxies     id, label, kind in {http-connect,socks5}, host, port, user?, pass? (enc)
--   scripts     id, name (*.lua), ownerUserId -> users, size, sha256, createdAt
--   instances   id, characterId -> characters, ownerUserId -> users, proxyId? -> proxies,
--               botProfile, cavebotConfig?, targetbotConfig?, scripts[] -> scripts,
--               autoStart, autoRelogin, state, createdAt
--
-- The `enc` fields hold lib/authsecret.lua records ("sbx$1$..."), never plaintext.  model.lua
-- refuses to store a value in an `enc` field that is not a well-formed record when a box is
-- attached, so "forgot to encrypt it" fails at the schema, not in a code review.  hub/auth.lua
-- owns the encrypt/decrypt calls.
--
-- ============================================================================================
-- REFERENTIAL INTEGRITY
-- ============================================================================================
-- The dependent graph is DERIVED from the field specs, not hand-maintained, so adding a `ref`
-- field automatically protects the target:
--   * insert/update -- every ref must resolve to an existing row.  An instance naming a proxy
--     that is not in proxies.json is refused at the door.
--   * delete -- refused while any row still references the target, naming the dependents:
--     deleting a game account that still has characters, a character that still has an
--     instance, a proxy an instance still uses, a script an instance still runs, or a user who
--     still owns accounts/instances/scripts.  `opts.cascade` is available and must be asked for
--     explicitly; there is no implicit cascade anywhere.
--   * db:checkIntegrity() re-derives the whole graph from what is actually on disk and reports
--     every dangling reference, duplicate id and duplicate user name.  The hub should run it at
--     startup: a hand-edited data dir is the normal way these files go wrong.
--
-- ============================================================================================
-- IDS
-- ============================================================================================
-- `<prefix><12 lowercase hex>` -- 48 bits from the OS CSPRNG (sys.randomBytes), e.g.
-- `u_9f3ac1d20b47`.  The prefix makes a stray id self-describing in a log line and makes a
-- cross-kind mix-up ("this instance's characterId is a proxy id") visible at a glance; the
-- collision probability over the thousands of rows this hub will ever hold is ~1e-9, and
-- newId() additionally re-draws while the id is already taken, so it is exactly zero in practice.
-- Ids are opaque: nothing derives meaning from the hex.
--
-- ============================================================================================
-- API
-- ============================================================================================
--   model.SPECS                        the schema, readable at runtime (the panel builds forms
--                                      from it rather than duplicating the field list)
--   model.kinds()                      -> array of collection names
--   model.newId(kind)                  -> id string
--   model.validate(kind, rec [, opts]) -> normalised copy | nil, err
--        opts.partial = true  -- only validate the given fields (used by update)
--   model.attach(store [, opts])       -> db | nil, err
--        opts.secret = an authsecret box; when present, `enc` fields are shape-checked
--        opts.now    = clock injection for tests
--   db:list(kind)                      -> the live array (do not mutate; use update/delete)
--   db:get(kind, id)                   -> row | nil
--   db:findBy(kind, field, value [, ci]) -> row | nil
--   db:filter(kind, predicate)         -> array
--   db:count(kind)                     -> n
--   db:insert(kind, rec [, opts])      -> row | nil, err
--   db:update(kind, id, patch [, opts])-> row | nil, err
--   db:delete(kind, id [, opts])       -> true | nil, err        opts.cascade = true
--   db:save() / db:saveAll()           -> true | nil, err
--        insert/update/delete persist immediately unless opts.defer is set; a batch that sets
--        defer must finish with db:save().
--   db:dependentsOf(kind, id)          -> array of {kind=, id=, field=}
--   db:checkIntegrity()                -> true | false, problems[]
--   db:refresh()                       -> rebuild the id indexes after an external reload

local storage = require('hub.storage')
local sys     = require('lib.sys')

local sformat, srep, slower = string.format, string.rep, string.lower
local floor = math.floor

local M = {}

-- ================================================================ field kinds

local function isArray(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= 'number' then return false end
    n = n + 1
  end
  return n == #t
end

-- ===================================================================== SPECS
-- `t` is the field type; everything else is a constraint.  `ref` names the collection a value
-- must exist in and is what builds the dependent graph.

local NAME_PAT   = '^[%w][%w%._%-]*$'
-- A character name reaches the worker as --instance-name and is shown in the
-- panel; it may carry spaces and apostrophes but nothing that could be read as a
-- path or a shell metacharacter.
local CHARNAME_PAT = "^[%w][%w%._%- ']*$"
-- A bot profile name becomes a DIRECTORY under the worker's profile root
-- (main.lua's resolveBotProfileDir), so it must contain no separator and cannot
-- be a traversal component.  The leading %w already rules out '.' and '..'.
local PROFILE_PAT = '^[%w][%w%._%-]*$'
local HOST_PAT   = '^[%w%.%-_:%[%]]+$'
local SCRIPT_PAT = '^[%w][%w%._%- ]*%.lua$'

M.SPECS = {
  users = {
    prefix = 'u_', order = 1,
    fields = {
      id        = { t = 'id' },
      name      = { t = 'string', min = 1, max = 64, pattern = NAME_PAT, unique = 'ci',
                    desc = 'web account name' },
      role      = { t = 'enum', values = { 'admin', 'user' }, default = 'user' },
      pwhash    = { t = 'string', min = 8, max = 512, sensitive = true },
      createdAt = { t = 'time', default = 'now' },
      disabled  = { t = 'bool', default = false },
      -- Remote Lua (instance.exec, script.upload) is admin-equivalent: the code
      -- runs unsandboxed in a process under the HUB's uid, with the hub's data
      -- directory readable.  It is therefore OFF for a plain account and an
      -- administrator grants it deliberately, per account.  See PANEL.md,
      -- "Remote Lua is admin-equivalent".
      canExec   = { t = 'bool', default = false },
      -- when this account last signed in; the admin screen shows it, and a
      -- long-idle account is the one worth disabling
      lastLoginAt = { t = 'time', optional = true },
    },
  },
  accounts = {
    prefix = 'a_', order = 2,
    fields = {
      id          = { t = 'id' },
      label       = { t = 'string', min = 1, max = 64 },
      login       = { t = 'string', min = 1, max = 128 },
      password    = { t = 'enc', optional = true },
      token2fa    = { t = 'enc', optional = true },
      ownerUserId = { t = 'ref', ref = 'users' },
      createdAt   = { t = 'time', default = 'now' },
    },
  },
  characters = {
    prefix = 'c_', order = 3,
    fields = {
      id        = { t = 'id' },
      accountId = { t = 'ref', ref = 'accounts' },
      name      = { t = 'string', min = 1, max = 64, pattern = CHARNAME_PAT },
      world     = { t = 'string', min = 1, max = 64, pattern = CHARNAME_PAT },
      vocation  = { t = 'string', max = 32, optional = true },
      lastLevel = { t = 'int', min = 0, max = 100000, optional = true },
    },
  },
  proxies = {
    prefix = 'p_', order = 4,
    fields = {
      id    = { t = 'id' },
      -- Who created it.  The POOL is shared -- any signed-in account may list a
      -- proxy and attach one to its own instance, which is what an operator's
      -- exit nodes are for -- but only the owner or an administrator may repoint
      -- or delete one.  Optional because rows written before this field existed
      -- have none; those are administrator-only to mutate (see A:ownedProxy).
      ownerUserId = { t = 'ref', ref = 'users', optional = true },
      label = { t = 'string', min = 1, max = 64 },
      kind  = { t = 'enum', values = { 'http-connect', 'socks5' }, default = 'http-connect' },
      host  = { t = 'string', min = 1, max = 255, pattern = HOST_PAT },
      port  = { t = 'int', min = 1, max = 65535 },
      user  = { t = 'string', max = 128, optional = true },
      pass  = { t = 'enc', optional = true },
    },
  },
  scripts = {
    prefix = 's_', order = 5,
    fields = {
      id          = { t = 'id' },
      name        = { t = 'string', min = 5, max = 128, pattern = SCRIPT_PAT },
      ownerUserId = { t = 'ref', ref = 'users' },
      size        = { t = 'int', min = 0, max = 8 * 1024 * 1024 },
      sha256      = { t = 'string', pattern = '^%x%x*$', min = 64, max = 64 },
      createdAt   = { t = 'time', default = 'now' },
    },
  },
  instances = {
    prefix = 'i_', order = 6,
    fields = {
      id              = { t = 'id' },
      characterId     = { t = 'ref', ref = 'characters' },
      ownerUserId     = { t = 'ref', ref = 'users' },
      proxyId         = { t = 'ref', ref = 'proxies', optional = true },
      botProfile      = { t = 'string', min = 1, max = 64, default = 'profile_1',
                          pattern = PROFILE_PAT },
      cavebotConfig   = { t = 'string', max = 128, optional = true },
      targetbotConfig = { t = 'string', max = 128, optional = true },
      scripts         = { t = 'reflist', ref = 'scripts', default = 'array', max = 64 },
      autoStart       = { t = 'bool', default = false },
      autoRelogin     = { t = 'bool', default = true },
      state           = { t = 'enum', default = 'stopped',
                          values = { 'stopped', 'starting', 'online', 'stopping', 'error' } },
      createdAt       = { t = 'time', default = 'now' },
    },
  },
}

function M.kinds()
  local out = {}
  for k in pairs(M.SPECS) do out[#out + 1] = k end
  table.sort(out, function (a, b) return M.SPECS[a].order < M.SPECS[b].order end)
  return out
end

-- The dependent graph, derived once from the specs above.  DEPENDENTS[target] is every place a
-- row of `target` can be pointed at.
local DEPENDENTS = {}
for kind, spec in pairs(M.SPECS) do
  for field, f in pairs(spec.fields) do
    if f.t == 'ref' or f.t == 'reflist' then
      DEPENDENTS[f.ref] = DEPENDENTS[f.ref] or {}
      DEPENDENTS[f.ref][#DEPENDENTS[f.ref] + 1] =
        { kind = kind, field = field, list = (f.t == 'reflist') }
    end
  end
end
for _, list in pairs(DEPENDENTS) do
  table.sort(list, function (a, b)
    if a.kind ~= b.kind then return a.kind < b.kind end
    return a.field < b.field
  end)
end
M.DEPENDENTS = DEPENDENTS

-- ======================================================================= ids

local HEX = '0123456789abcdef'
local function hex(bytes)
  local out = {}
  for i = 1, #bytes do
    local b = bytes:byte(i)
    out[i] = sformat('%02x', b)
  end
  return table.concat(out)
end

--- Raw id for `kind`, without checking the store.  db:newId() is the one to use: it also
--- guarantees the id is free.
function M.newId(kind)
  local spec = M.SPECS[kind]
  if not spec then error('model.newId: unknown kind ' .. tostring(kind), 2) end
  return spec.prefix .. hex(sys.randomBytes(6))
end

local function idPattern(kind)
  return '^' .. M.SPECS[kind].prefix:gsub('%p', '%%%0') .. '%x%x%x%x%x%x%x%x%x%x%x%x$'
end

-- ================================================================ validation

local function fail(fmt, ...) return nil, sformat(fmt, ...) end

local function checkString(field, f, v)
  if type(v) ~= 'string' then return fail('%s must be a string, got %s', field, type(v)) end
  if f.min and #v < f.min then return fail('%s is too short (min %d characters)', field, f.min) end
  if f.max and #v > f.max then return fail('%s is too long (max %d characters)', field, f.max) end
  if f.pattern and not v:match(f.pattern) then
    return fail('%s has an illegal value (must match %s)', field, f.pattern)
  end
  if v:find('[%z\1-\31]') then return fail('%s must not contain control characters', field) end
  return v
end

local function checkInt(field, f, v)
  if type(v) ~= 'number' then
    local n = tonumber(v)
    if n == nil then return fail('%s must be a number, got %s', field, type(v)) end
    v = n
  end
  if v ~= v or v == math.huge or v == -math.huge then
    return fail('%s must be a finite number', field)
  end
  if v ~= floor(v) then return fail('%s must be a whole number', field) end
  if f.min and v < f.min then return fail('%s must be >= %d', field, f.min) end
  if f.max and v > f.max then return fail('%s must be <= %d', field, f.max) end
  return v
end

--- One field.  `ctx` carries the reference resolver (nil while validating without a store).
local function checkField(kind, field, f, v, ctx)
  local t = f.t
  if t == 'id' then
    local s, err = checkString(field, { min = 3, max = 64 }, v)
    if not s then return nil, err end
    if not s:match(idPattern(kind)) then
      return fail('%s %q is not a well-formed %s id (expected %s + 12 hex digits)',
                  field, s, kind, M.SPECS[kind].prefix)
    end
    return s

  elseif t == 'string' then
    return checkString(field, f, v)

  elseif t == 'int' then
    return checkInt(field, f, v)

  elseif t == 'time' then
    local n, err = checkInt(field, { min = 0, max = 4102444800000 }, v)
    if not n then return nil, err end
    return n

  elseif t == 'bool' then
    if type(v) ~= 'boolean' then return fail('%s must be true or false', field) end
    return v

  elseif t == 'enum' then
    if type(v) ~= 'string' then return fail('%s must be a string', field) end
    for i = 1, #f.values do
      if f.values[i] == v then return v end
    end
    return fail('%s must be one of %s (got %q)', field, table.concat(f.values, ', '), v)

  elseif t == 'enc' then
    if type(v) ~= 'string' then return fail('%s must be a string', field) end
    if #v > 8192 then return fail('%s is too long', field) end
    if ctx and ctx.secret then
      if not ctx.secret:isRecord(v) then
        return fail('%s must be an authsecret record -- refusing to store it in the clear', field)
      end
    elseif v:sub(1, 4) ~= 'sbx$' then
      return fail('%s must be an authsecret record -- refusing to store it in the clear', field)
    end
    return v

  elseif t == 'ref' then
    local s, err = checkString(field, { min = 3, max = 64 }, v)
    if not s then return nil, err end
    if not s:match(idPattern(f.ref)) then
      return fail('%s %q is not a %s id (expected the %s prefix)',
                  field, s, f.ref, M.SPECS[f.ref].prefix)
    end
    if ctx and ctx.resolve and not ctx.resolve(f.ref, s) then
      return fail('%s references %s %s, which does not exist', field, f.ref, s)
    end
    return s

  elseif t == 'reflist' then
    if not isArray(v) then return fail('%s must be an array', field) end
    if f.max and #v > f.max then return fail('%s holds too many entries (max %d)', field, f.max) end
    local out, seen = {}, {}
    for i = 1, #v do
      local s, err = checkField(kind, sformat('%s[%d]', field, i),
                                { t = 'ref', ref = f.ref }, v[i], ctx)
      if not s then return nil, err end
      if seen[s] then return fail('%s lists %s twice', field, s) end
      seen[s] = true
      out[i] = s
    end
    return out
  end
  return fail('%s has an unknown field type %s', field, tostring(t))
end

local function defaultFor(f, ctx)
  if f.default == nil then return nil end
  if f.default == 'now' then return (ctx and ctx.now or storage.wallMs)() end
  if f.default == 'array' then return {} end
  return f.default
end

--- Validate a whole record.  Returns a NEW normalised table -- the caller's table is never
--- mutated and never stored, so a caller cannot smuggle extra keys in by keeping a reference.
function M.validate(kind, rec, opts)
  opts = opts or {}
  local spec = M.SPECS[kind]
  if not spec then return nil, 'unknown kind ' .. tostring(kind) end
  if type(rec) ~= 'table' then return nil, 'record must be a table' end

  local out, ctx = {}, opts.ctx
  -- Unknown keys are reported FIRST: a typo ("cavebotconfig") is far more likely than a genuine
  -- constraint failure on another field, and reporting the typo is what the caller can act on.
  for k in pairs(rec) do
    if spec.fields[k] == nil then
      return nil, sformat('%s: unknown field %q', kind, tostring(k))
    end
  end
  for field, f in pairs(spec.fields) do
    local v = rec[field]
    if v == nil then
      if opts.partial then
        -- untouched by this patch
      elseif f.optional then
        -- absent is fine
      else
        local d = defaultFor(f, ctx)
        if d == nil then
          return nil, sformat('%s: %s is required', kind, field)
        end
        out[field] = d
      end
    else
      local val, err = checkField(kind, field, f, v, ctx)
      if val == nil then return nil, sformat('%s: %s', kind, err) end
      out[field] = val
    end
  end

  return out
end

-- ======================================================================== db

local Db = {}
Db.__index = Db

function M.attach(store, opts)
  opts = opts or {}
  if type(store) ~= 'table' or type(store.items) ~= 'function' then
    return nil, 'model.attach: a hub/storage store is required'
  end
  local self = setmetatable({
    store  = store,
    secret = opts.secret,
    now    = opts.now or storage.wallMs,
    index  = {},
  }, Db)
  self.ctx = {
    secret  = opts.secret,
    now     = self.now,
    resolve = function (kind, id) return self:get(kind, id) ~= nil end,
  }
  local ok, err = self:refresh()
  if not ok then return nil, err end
  return self
end

--- Rebuild the id -> row index for every collection.  Also the first place a duplicate id or a
--- row that is not a table shows up, so it reports rather than silently indexing garbage.
function Db:refresh()
  local kinds = M.kinds()
  for i = 1, #kinds do
    local kind = kinds[i]
    if self.store:has(kind) then
      local ix, rows = {}, self.store:items(kind)
      for j = 1, #rows do
        local r = rows[j]
        if type(r) ~= 'table' then
          return nil, sformat('%s row %d is not an object', kind, j)
        end
        if type(r.id) ~= 'string' then
          return nil, sformat('%s row %d has no id', kind, j)
        end
        if ix[r.id] then
          return nil, sformat('%s has two rows with id %s', kind, r.id)
        end
        ix[r.id] = r
      end
      self.index[kind] = ix
    end
  end
  return true
end

function Db:list(kind)
  if not self.store:has(kind) then error('model: unknown kind ' .. tostring(kind), 2) end
  return self.store:items(kind)
end

function Db:count(kind) return #self:list(kind) end

function Db:get(kind, id)
  if type(id) ~= 'string' then return nil end
  local ix = self.index[kind]
  return ix and ix[id] or nil
end

function Db:findBy(kind, field, value, ci)
  local rows = self:list(kind)
  local want = ci and type(value) == 'string' and slower(value) or value
  for i = 1, #rows do
    local v = rows[i][field]
    if ci and type(v) == 'string' then v = slower(v) end
    if v == want then return rows[i] end
  end
  return nil
end

function Db:filter(kind, pred)
  local rows, out = self:list(kind), {}
  for i = 1, #rows do
    if pred(rows[i]) then out[#out + 1] = rows[i] end
  end
  return out
end

function Db:newId(kind)
  local ix = self.index[kind] or {}
  for _ = 1, 64 do
    local id = M.newId(kind)
    if not ix[id] then return id end
  end
  error('model: could not find a free ' .. kind .. ' id in 64 draws (CSPRNG broken?)', 2)
end

local function uniqueClash(self, kind, row, ignoreId)
  local spec = M.SPECS[kind]
  for field, f in pairs(spec.fields) do
    if f.unique and row[field] ~= nil then
      local rows = self:list(kind)
      local ci = (f.unique == 'ci')
      local want = ci and slower(row[field]) or row[field]
      for i = 1, #rows do
        local other = rows[i]
        if other.id ~= ignoreId then
          local v = other[field]
          if ci and type(v) == 'string' then v = slower(v) end
          if v == want then
            return sformat('%s: %s %q is already taken', kind, field, tostring(row[field]))
          end
        end
      end
    end
  end
  return nil
end

function Db:insert(kind, rec, opts)
  opts = opts or {}
  if not self.store:has(kind) then return nil, 'unknown kind ' .. tostring(kind) end
  local draft = {}
  for k, v in pairs(rec) do draft[k] = v end
  if draft.id == nil then draft.id = self:newId(kind) end

  local row, err = M.validate(kind, draft, { ctx = self.ctx })
  if not row then return nil, err end
  if self:get(kind, row.id) then
    return nil, sformat('%s: id %s already exists', kind, row.id)
  end
  local clash = uniqueClash(self, kind, row, nil)
  if clash then return nil, clash end

  local rows = self:list(kind)
  rows[#rows + 1] = row
  self.index[kind][row.id] = row
  self.store:markDirty(kind)
  if not opts.defer then
    local ok, serr = self.store:save(kind)
    if not ok then
      -- Roll the in-memory state back so the cache never claims something the disk refused.
      rows[#rows] = nil
      self.index[kind][row.id] = nil
      return nil, serr
    end
  end
  return row
end

function Db:update(kind, id, patch, opts)
  opts = opts or {}
  local row = self:get(kind, id)
  if not row then return nil, sformat('%s %s not found', kind, tostring(id)) end
  if patch.id ~= nil and patch.id ~= id then
    return nil, 'the id of a row cannot be changed'
  end

  local merged = {}
  for k, v in pairs(row) do merged[k] = v end
  local clearing = {}
  for k, v in pairs(patch) do
    if v == M.NIL then
      merged[k] = nil
      clearing[k] = true
    else
      merged[k] = v
    end
  end
  -- Clearing a required field is a schema error, not a silent default.
  for k in pairs(clearing) do
    local f = M.SPECS[kind].fields[k]
    if not f then return nil, sformat('%s: unknown field %q', kind, k) end
    if not f.optional then return nil, sformat('%s: %s cannot be cleared', kind, k) end
  end

  local newRow, err = M.validate(kind, merged, { ctx = self.ctx })
  if not newRow then return nil, err end
  local clash = uniqueClash(self, kind, newRow, id)
  if clash then return nil, clash end

  local rows = self:list(kind)
  local at
  for i = 1, #rows do if rows[i] == row then at = i; break end end
  if not at then return nil, 'internal: row is not in its collection' end

  rows[at] = newRow
  self.index[kind][id] = newRow
  self.store:markDirty(kind)
  if not opts.defer then
    local ok, serr = self.store:save(kind)
    if not ok then
      rows[at] = row
      self.index[kind][id] = row
      return nil, serr
    end
  end
  return newRow
end

--- Every row that points at (kind, id).
function Db:dependentsOf(kind, id)
  local out = {}
  local deps = DEPENDENTS[kind]
  if not deps then return out end
  for i = 1, #deps do
    local d = deps[i]
    if self.store:has(d.kind) then
      local rows = self:list(d.kind)
      for j = 1, #rows do
        local v = rows[j][d.field]
        if d.list then
          if type(v) == 'table' then
            for n = 1, #v do
              if v[n] == id then
                out[#out + 1] = { kind = d.kind, id = rows[j].id, field = d.field }
              end
            end
          end
        elseif v == id then
          out[#out + 1] = { kind = d.kind, id = rows[j].id, field = d.field }
        end
      end
    end
  end
  return out
end

local function describeDeps(deps)
  local seen, parts = {}, {}
  for i = 1, #deps do
    local key = deps[i].kind .. '.' .. deps[i].field
    if not seen[key] then
      seen[key] = 0
      parts[#parts + 1] = key
    end
    seen[key] = seen[key] + 1
  end
  local out = {}
  for i = 1, #parts do out[i] = sformat('%s (%d)', parts[i], seen[parts[i]]) end
  return table.concat(out, ', ')
end

--- Delete.  Refused while anything still points here unless opts.cascade is asked for.
function Db:delete(kind, id, opts)
  opts = opts or {}
  local row = self:get(kind, id)
  if not row then return nil, sformat('%s %s not found', kind, tostring(id)) end

  local deps = self:dependentsOf(kind, id)
  if #deps > 0 and not opts.cascade then
    return nil, sformat('%s %s is still referenced by %s -- delete those first, or pass cascade',
                        kind, id, describeDeps(deps))
  end

  if opts.cascade then
    -- Depth-first so a chain (user -> account -> character -> instance) unwinds bottom-up.
    local guard = (opts._depth or 0) + 1
    if guard > 8 then return nil, 'cascade is too deep' end
    for i = #deps, 1, -1 do
      local d = deps[i]
      local f = M.SPECS[d.kind].fields[d.field]
      if f.t == 'reflist' then
        local other = self:get(d.kind, d.id)
        if other then
          local kept = {}
          for n = 1, #other[d.field] do
            if other[d.field][n] ~= id then kept[#kept + 1] = other[d.field][n] end
          end
          local ok, err = self:update(d.kind, d.id, { [d.field] = kept }, { defer = true })
          if not ok then return nil, err end
        end
      elseif f.optional then
        local ok, err = self:update(d.kind, d.id, { [d.field] = M.NIL }, { defer = true })
        if not ok then return nil, err end
      else
        local ok, err = self:delete(d.kind, d.id,
                                    { cascade = true, defer = true, _depth = guard })
        if not ok then return nil, err end
      end
    end
  end

  local rows = self:list(kind)
  for i = 1, #rows do
    if rows[i].id == id then table.remove(rows, i); break end
  end
  self.index[kind][id] = nil
  self.store:markDirty(kind)

  -- One saveAll: a cascade touches several collections and store:save() skips the clean ones.
  if not opts.defer then
    local ok, err = self.store:saveAll()
    if not ok then return nil, err end
  end
  return true
end

function Db:save(kind)
  if kind then return self.store:save(kind) end
  return self.store:saveAll()
end
Db.saveAll = Db.save

--- Full sweep of what is actually stored.  Meant for startup and for the admin UI's
--- "check data" button; it never repairs anything.
function Db:checkIntegrity()
  local problems = {}
  local function bad(fmt, ...) problems[#problems + 1] = sformat(fmt, ...) end

  local kinds = M.kinds()
  for i = 1, #kinds do
    local kind = kinds[i]
    if self.store:has(kind) then
      local rows, seenId = self:list(kind), {}
      for j = 1, #rows do
        local r = rows[j]
        if type(r) ~= 'table' or type(r.id) ~= 'string' then
          bad('%s row %d has no usable id', kind, j)
        else
          if seenId[r.id] then bad('%s: duplicate id %s', kind, r.id) end
          seenId[r.id] = true
          local ok, err = M.validate(kind, r, { ctx = { secret = self.secret, now = self.now } })
          if not ok then bad('%s %s: %s', kind, r.id, err) end
          for field, f in pairs(M.SPECS[kind].fields) do
            if f.t == 'ref' and r[field] ~= nil then
              if not self:get(f.ref, r[field]) then
                bad('%s %s: %s -> %s %s does not exist', kind, r.id, field, f.ref, r[field])
              end
            elseif f.t == 'reflist' and type(r[field]) == 'table' then
              for n = 1, #r[field] do
                if not self:get(f.ref, r[field][n]) then
                  bad('%s %s: %s[%d] -> %s %s does not exist',
                      kind, r.id, field, n, f.ref, r[field][n])
                end
              end
            end
          end
        end
      end
      local spec = M.SPECS[kind]
      for field, f in pairs(spec.fields) do
        if f.unique then
          local seen = {}
          for j = 1, #rows do
            local v = rows[j][field]
            if type(v) == 'string' then
              local key = (f.unique == 'ci') and slower(v) or v
              if seen[key] then bad('%s: %s %q is used by more than one row', kind, field, v) end
              seen[key] = true
            end
          end
        end
      end
    end
  end
  if #problems == 0 then return true end
  return false, problems
end

--- Sentinel for "clear this optional field" in an update patch (a Lua table cannot carry a nil).
M.NIL = setmetatable({}, { __tostring = function () return '<model.NIL>' end })

return M
