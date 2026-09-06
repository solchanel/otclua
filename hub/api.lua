--[[============================================================================
hub/api.lua -- every RPC command the panel calls, authorised by role.

  local api = require('hub.api').new{
      model = model, auth = auth, audit = audit,
      sup = supervisor, tel = telemetry,
      version = 'hub-1.0', workersDir = ROOT,
  }
  api:dispatch(cmd, args, ctx, function(ok, resultOrError) ... end)

`ctx` is built by hub/server.lua for one request:
    { session, user, ip, userAgent,
      setSession = function(session) end,      -- writes the cookies
      clearSession = function() end,
      insecure = <bool>, csrfToken = <string> }

--------------------------------------------------------------------------------
AUTHORISATION -- enforced HERE, never by the UI
--------------------------------------------------------------------------------
Three gates, applied in this order for every command:

  1. AUTHENTICATION.  Everything except `auth.session`, `auth.login` and
     `auth.bootstrap` requires a live session.  No session -> 401 `unauthorized`.
  2. ROLE.  Every command in the ADMIN_ONLY set requires role == 'admin'.  A
     `user` gets 403 `forbidden` -- and gets it from the SERVER, whether or not
     the panel drew the button.  That includes the entire audit log: PANEL.md
     says only the administrator may read it, so `admin.audit` is refused before
     a single record is touched.
  3. OWNERSHIP.  A `user` sees only rows they own: instances by ownerUserId, game
     accounts by ownerUserId, characters through their account, scripts and
     proxies by ownerUserId.  Every lookup goes through ownedInstance() /
     ownedAccount() / ... which return 404 `not-found` for a row that exists but
     is not theirs -- an id probe must not distinguish "not yours" from "gone".
     An admin sees everything.

--------------------------------------------------------------------------------
AUDIT
--------------------------------------------------------------------------------
Every state-changing command writes exactly one audit record, with the actor's
web-account name, the source IP, the action, the target and the outcome -- on
FAILURE as well as on success, because a refused admin route is the interesting
one.  Passwords never reach it: only field NAMES are recorded for a patch, and
`exec` records the code (PANEL.md asks for that explicitly).

--------------------------------------------------------------------------------
DEPENDENCIES (work item B2) -- the surface this file uses
--------------------------------------------------------------------------------
db       hub/model.lua's attached db: :list(kind) :get(kind,id) :insert(kind,rec)
         :update(kind,id,patch) :delete(kind,id[,opts]) :findBy :count
         model.NIL clears an optional field.  A thin per-kind adapter is built in
         new() so the handlers below read as `self.model.instances:get(id)`.
auth     hub/auth.lua: :needsBootstrap() :bootstrapToken() :createFirstAdmin()
         :login(name,pw,ip,ua) -> token,user   :authenticate(token,ip) -> sess,user
         :logout(token) :revoke(id) :revokeUser(id) :sessions()
         :createUser(name,pw,role) :setRole :setDisabled :deleteUser :setPassword
         :sealAccountPassword/:openAccountPassword/:sealAccountToken2fa
         :sealProxyPassword/:openProxyPassword
audit    hub/audit.lua: :record{actor,actorId,ip,action,target,outcome,detail}
         :query{actor,action,from,to,limit,cursor} -> {rows,nextCursor,scanned}
storage  hub/storage.lua's store, for the script blob directory (storage.fs).

SCRIPT SOURCES.  hub/model.lua stores a script's metadata (name, size, sha256);
the SOURCE is a file, `<data-dir>/scripts/<scriptId>.lua`, written through
storage.fs.writeDurable and read back on demand.  PANEL.md puts the uploads in
`scripts/` with the metadata beside them, and keeping a 512 KiB blob out of
scripts.json means a script upload does not rewrite (and re-fsync) the whole
collection.

Lua 5.1 / LuaJIT: no goto, math.floor for integer division.
============================================================================]]

local json   = require('lib.json')
local sys    = require('lib.sys')
local sched  = require('lib.sched')
local socket = require('lib.socket')
local sha2   = require('lib.sha2')
local proxylib = require('lib.proxy')
local model  = require('hub.model')      -- for model.NIL, the clear-a-field sentinel

local M = {}
M.PENDING = { '<pending>' }          -- a handler that will call done() itself

local floor = math.floor
local function wallMs() return os.time() * 1000 end

-- =================================================================== errors ==
local function err(code, message)
  error(setmetatable({ code = code, message = message },
                     { __tostring = function(e) return e.code .. ': ' .. e.message end }), 0)
end
local function need(cond, code, message) if not cond then err(code, message) end end
M.err, M.need = err, need

-- ================================================================== helpers ==
local function str(v, max)
  if v == nil then return nil end
  v = tostring(v)
  if max and #v > max then v = v:sub(1, max) end
  return v
end

local function shallow(t)
  local o = {}
  if type(t) == 'table' then for k, v in pairs(t) do o[k] = v end end
  return o
end

local function keysOf(t, skip)
  local out = {}
  if type(t) == 'table' then
    for k in pairs(t) do if not (skip and skip[k]) then out[#out + 1] = tostring(k) end end
  end
  table.sort(out)
  return table.concat(out, ',')
end

local function isArray(t) return type(t) == 'table' end

-- ================================================================== the API ==
local A = {}
A.__index = A
M.A = A

-- Commands that never require a session.
local PUBLIC = {
  ['auth.session'] = true, ['auth.login'] = true, ['auth.bootstrap'] = true,
}

-- Commands the administrator alone may reach.  Server-side, always.
local ADMIN_ONLY = {
  ['admin.users'] = true, ['admin.userCreate'] = true, ['admin.userUpdate'] = true,
  ['admin.userDelete'] = true, ['admin.userResetPassword'] = true,
  ['admin.sessions'] = true, ['admin.sessionRevoke'] = true,
  ['admin.audit'] = true,
}
M.ADMIN_ONLY = ADMIN_ONLY

-- ---------------------------------------------------------------------------
-- Commands that hand the caller ARBITRARY LUA inside a worker process.
--
-- That worker runs unsandboxed under the HUB's uid with the hub's data
-- directory readable, so `exec` and an uploaded script are not "power over your
-- own bot": they are power over secret.key, accounts.json, users.json and the
-- audit log -- i.e. over every OTHER account's game credentials.  They are
-- therefore administrator-only by default, and an administrator may grant the
-- `canExec` capability to a named account when that account is trusted with the
-- host.  Every use is audited WITH the source (see A:record calls below).
-- PANEL.md and README-HUB.md state the residual risk in the same words.
local EXEC_CAPABILITY = {
  ['instance.exec'] = true, ['script.upload'] = true,
}
M.EXEC_CAPABILITY = EXEC_CAPABILITY

-- Error codes worth an audit record when a MUTATING command raises them: these
-- are the shapes a cross-tenant probe takes.  'bad-request' is deliberately not
-- here -- a malformed body is noise, not a signal.
local AUDITED_REFUSAL = { ['not-found'] = true, ['forbidden'] = true, ['conflict'] = true }

--- Classify a hub/model.lua error as a duplicate-key conflict or a bad request.
---
--- It lives here as a named function because the inline form was
--- `err(find('unique') or find('taken') and 'conflict' or 'bad-request', ...)`,
--- which binds as `a or ((b and c) or d)` -- and string.find returns a NUMBER,
--- so any model error containing 'unique' made the error CODE an integer that
--- M.statusFor then mapped to 400 and the panel had to render.  It only ever
--- worked because model.lua happens to say "taken".  Decide first, classify
--- after, and let a test pin both spellings.
function M.duplicateCode(e)
  local msg = tostring(e)
  local dup = msg:find('unique', 1, true) or msg:find('taken', 1, true)
  return dup and 'conflict' or 'bad-request'
end

-- Commands that change state: they must carry CSRF protection and be audited.
local MUTATING = {
  ['auth.login'] = true, ['auth.logout'] = true, ['auth.bootstrap'] = true,
  ['auth.changePassword'] = true,
}
for _, prefix in ipairs{ 'instance.', 'account.', 'character.', 'proxy.', 'script.', 'admin.' } do
  local _ = prefix
end
local function isMutating(cmd)
  if MUTATING[cmd] then return true end
  local verb = cmd:match('%.(.+)$')
  if not verb then return false end
  local readOnly = { list = true, get = true, configs = true, history = true,
                     logs = true, chat = true, users = true, sessions = true, audit = true }
  return not readOnly[verb]
end
M.isMutating = isMutating

-- A per-kind view over hub/model.lua's single-object db, so the handlers can say
-- `self.model.instances:get(id)` instead of repeating the kind at every call site.
local function collection(db, kind)
  return {
    kind   = kind,
    list   = function(_)             return db:list(kind) end,
    get    = function(_, id)         return db:get(kind, tostring(id or '')) end,
    create = function(_, rec)        return db:insert(kind, rec) end,
    update = function(_, id, patch)  return db:update(kind, id, patch) end,
    delete = function(_, id, o)      return db:delete(kind, id, o) end,
    findBy = function(_, f, v, ci)   return db:findBy(kind, f, v, ci) end,
  }
end
M.collection = collection

function M.new(opts)
  opts = opts or {}
  local a = setmetatable({}, A)
  local db = assert(opts.db or opts.model, 'hub.api: db (hub/model attach result) is required')
  a.db      = db
  a.model   = {
    db = db,
    users      = collection(db, 'users'),
    accounts   = collection(db, 'accounts'),
    characters = collection(db, 'characters'),
    proxies    = collection(db, 'proxies'),
    scripts    = collection(db, 'scripts'),
    instances  = collection(db, 'instances'),
  }
  a.storage = opts.storage
  a.dataDir = opts.dataDir or (opts.storage and opts.storage.dir) or nil
  a.configsCache = {}                        -- instanceId -> last bot.listConfigs answer
  a.auth    = assert(opts.auth, 'hub.api: auth is required')
  a.audit   = opts.audit
  a.sup     = opts.sup
  a.tel     = opts.tel
  a.log     = opts.log or require('lib.log')
  a.sched   = opts.sched or sched
  a.version = opts.version or 'hub-1.0'
  a.workersDir = opts.workersDir
  a.insecure = opts.insecure and true or false
  a.proxyTestTarget = opts.proxyTestTarget or 'example.com:443'
  -- Opt-in for an operator whose proxies really are on a private network.
  a.allowPrivateProxies = opts.allowPrivateProxies and true or false
  a.gameHost = opts.gameHost
  a.gamePort = opts.gamePort
  a.loginUrl = opts.loginUrl
  a.maxScriptBytes = opts.maxScriptBytes or (512 * 1024)
  return a
end

-- ------------------------------------------------------------ script blobs --
function A:scriptPath(id)
  if not self.dataDir then return nil end
  return self.dataDir .. '/scripts/' .. tostring(id) .. '.lua'
end

function A:scriptSource(id)
  local p = self:scriptPath(id)
  if not p then return nil, 'no data dir' end
  local storage = require('hub.storage')
  return storage.fs.readFile(p)
end

function A:putScriptSource(id, source)
  local p = self:scriptPath(id)
  if not p then return nil, 'no data dir' end
  local storage = require('hub.storage')
  local ok, e = storage.fs.mkdirp(self.dataDir .. '/scripts')
  if not ok then return nil, e end
  return storage.fs.writeDurable(p, source)
end

function A:deleteScriptSource(id)
  local p = self:scriptPath(id)
  if not p then return true end
  local storage = require('hub.storage')
  return storage.fs.remove(p)
end

-- --------------------------------------------------------------------- audit
function A:record(ctx, action, target, outcome, detail)
  if not self.audit then return end
  local ok = pcall(function()
    self.audit:record{
      actor   = (ctx.user and ctx.user.name) or 'anonymous',
      actorId = ctx.user and ctx.user.id or nil,
      ip      = ctx.ip or '',
      action  = action,
      target  = target and tostring(target) or '',
      outcome = outcome or 'ok',
      detail  = detail and tostring(detail) or '',
    }
  end)
  if not ok then self.log.warn('hub.api: audit write failed for %s', tostring(action)) end
end

-- ---------------------------------------------------------------- projections
function A:userName(id)
  if not id then return nil end
  local u = self.model.users:get(id)
  return u and u.name or nil
end

local function pubUser(u)
  return { id = u.id, name = u.name, role = u.role, createdAt = u.createdAt,
           disabled = u.disabled and true or false, lastLoginAt = u.lastLoginAt,
           -- an administrator always may; the flag is what a plain account was granted
           canExec = (u.role == 'admin') or (u.canExec == true) }
end

function A:pubAccount(acc)
  local n = 0
  for _, c in ipairs(self.model.characters:list()) do if c.accountId == acc.id then n = n + 1 end end
  return { id = acc.id, label = acc.label, login = acc.login, ownerUserId = acc.ownerUserId,
           ownerName = self:userName(acc.ownerUserId),
           has2fa = (acc.token2fa ~= nil and acc.token2fa ~= ''),
           hasPassword = (acc.password ~= nil and acc.password ~= ''),
           characterCount = n }
end

function A:pubCharacter(c)
  local acc = self.model.accounts:get(c.accountId)
  local instId = nil
  for _, i in ipairs(self.model.instances:list()) do
    if i.characterId == c.id then instId = i.id; break end
  end
  return { id = c.id, accountId = c.accountId, accountLabel = acc and acc.label or '?',
           name = c.name, world = c.world, vocation = c.vocation, lastLevel = c.lastLevel,
           instanceId = instId }
end

function A:pubProxy(p, ctx)
  local n = 0
  for _, i in ipairs(self.model.instances:list()) do if i.proxyId == p.id then n = n + 1 end end
  local mine = nil
  if ctx and ctx.user then
    mine = self:isAdmin(ctx) or (p.ownerUserId ~= nil and p.ownerUserId == ctx.user.id)
  end
  return { id = p.id, label = p.label, kind = p.kind or 'http-connect', host = p.host,
           port = p.port, user = p.user, hasPass = (p.pass ~= nil and p.pass ~= ''),
           inUse = n,
           ownerUserId = p.ownerUserId, ownerName = self:userName(p.ownerUserId),
           -- the panel greys out Edit/Delete on a proxy this account may only use
           canEdit = mine and true or false }
end

function A:pubScript(s)
  local ids = {}
  for _, i in ipairs(self.model.instances:list()) do
    for _, sid in ipairs(i.scripts or {}) do if sid == s.id then ids[#ids + 1] = i.id end end
  end
  return { id = s.id, name = s.name, size = s.size, sha256 = s.sha256,
           ownerUserId = s.ownerUserId, ownerName = self:userName(s.ownerUserId),
           createdAt = s.createdAt, instanceIds = ids }
end

function A:pubInstance(inst)
  local ch  = self.model.characters:get(inst.characterId)
  local acc = ch and self.model.accounts:get(ch.accountId) or nil
  local px  = inst.proxyId and self.model.proxies:get(inst.proxyId) or nil
  local live = (self.tel and self.tel:live(inst.id)) or {}
  local info = (self.sup and self.sup:info(inst.id)) or {}
  local out = {
    id = inst.id, characterId = inst.characterId,
    characterName = ch and ch.name or '?',
    accountLabel = acc and acc.label or '?',
    world = ch and ch.world or nil, vocation = ch and ch.vocation or nil,
    ownerUserId = inst.ownerUserId, ownerName = self:userName(inst.ownerUserId),
    proxyId = inst.proxyId, proxyLabel = px and px.label or nil,
    botProfile = inst.botProfile or 'profile_1',
    cavebotConfig = inst.cavebotConfig, targetbotConfig = inst.targetbotConfig,
    scripts = shallow(inst.scripts or {}),
    autoStart = inst.autoStart and true or false,
    autoRelogin = inst.autoRelogin ~= false,
    state = info.state or 'stopped',
    botEnabled = live.botEnabled and true or false,
    live = {},
  }
  -- the array must survive json.encode as an array
  local sc = {}
  for i, v in ipairs(inst.scripts or {}) do sc[i] = v end
  out.scripts = sc
  for k, v in pairs(live) do out.live[k] = v end
  out.live.id = nil
  out.live.uptimeMs = info.uptimeMs or 0
  out.live.onlineMs = info.onlineMs or 0
  out.live.reconnects = info.reconnects or 0
  if out.live.level == nil and ch then out.live.level = ch.lastLevel end
  return out
end

-- ---------------------------------------------------------------- ownership
function A:isAdmin(ctx) return ctx.user and ctx.user.role == 'admin' end

--- May this context run arbitrary Lua inside a worker?  Administrators always
--- may; a plain account only with the explicitly granted `canExec` capability.
--- The row is re-read from the model rather than trusted from the session, so a
--- revoked capability takes effect on the very next request.
function A:mayExec(user)
  if type(user) ~= 'table' then return false end
  local row = self.model.users:get(tostring(user.id or '')) or user
  if row.role == 'admin' then return true end
  return row.canExec == true
end

function A:ownsInstance(ctx, inst)
  return self:isAdmin(ctx) or (inst.ownerUserId == ctx.user.id)
end

function A:ownedInstance(ctx, id)
  need(id, 'bad-request', 'no instance id')
  local inst = self.model.instances:get(tostring(id))
  need(inst and self:ownsInstance(ctx, inst), 'not-found', 'no such instance')
  return inst
end

function A:ownedAccount(ctx, id)
  local acc = self.model.accounts:get(tostring(id or ''))
  need(acc and (self:isAdmin(ctx) or acc.ownerUserId == ctx.user.id),
       'not-found', 'no such game account')
  return acc
end

function A:ownedCharacter(ctx, id)
  local c = self.model.characters:get(tostring(id or ''))
  need(c, 'not-found', 'no such character')
  self:ownedAccount(ctx, c.accountId)
  return c
end

--- Read/attach access to a proxy: the pool is deliberately SHARED, so this only
--- has to exist.  The stored credential is never returned by any of the callers.
function A:ownedProxy(ctx, id)
  local p = self.model.proxies:get(tostring(id or ''))
  need(p, 'not-found', 'no such proxy')
  return p
end

--- WRITE access to a proxy.  Sharing the pool is a decision about USE; it was
--- never a decision that anybody may repoint somebody else's exit node.  A
--- proxy whose host, port or credential can be changed by any account is a
--- man-in-the-middle switch for every instance attached to it, so update and
--- delete require the owner or an administrator.  A row with no ownerUserId
--- (written before the field existed) is administrator-only, and the refusal is
--- 'not-found' so the endpoint is not an id oracle.
function A:ownedProxyForWrite(ctx, id)
  local p = self:ownedProxy(ctx, id)
  need(self:isAdmin(ctx) or (p.ownerUserId ~= nil and p.ownerUserId == ctx.user.id),
       'not-found', 'no such proxy')
  return p
end

function A:ownedScript(ctx, id)
  local s = self.model.scripts:get(tostring(id or ''))
  need(s and (self:isAdmin(ctx) or s.ownerUserId == ctx.user.id), 'not-found', 'no such script')
  return s
end

--- The visibility predicate a panel WebSocket carries.
function A:visibilityFor(user)
  local self_ = self
  return function(instanceId)
    if not user then return false end
    if user.role == 'admin' then return true end
    local inst = self_.model.instances:get(tostring(instanceId))
    return inst ~= nil and inst.ownerUserId == user.id
  end
end

-- =============================================================== the handlers
local H = {}
A.handlers = H

-- ------------------------------------------------------------------ auth ----
H['auth.session'] = function(self, args, ctx)
  local boot = self.auth:needsBootstrap()
  return {
    user = ctx.user and { id = ctx.user.id, name = ctx.user.name, role = ctx.user.role,
                          canExec = self:mayExec(ctx.user) } or nil,
    serverTime = wallMs(),
    version = self.version,
    bootstrap = boot and true or false,
    insecure = self.insecure,
    csrf = ctx.csrfToken,
    csrfToken = ctx.csrfToken,        -- panel/api.js's name for the same value
  }
end

--- Turn a fresh auth token into (token, session) and give the session its CSRF
--- token.  hub/auth.lua's session table is the live one, so the field survives.
function A:sessionFor(token, ip)
  local sess = select(1, self.auth:authenticate(token, ip))
  if sess and not sess.csrf then
    local raw = sys.randomBytes(16)
    sess.csrf = (raw:gsub('.', function(c) return string.format('%02x', c:byte()) end))
  end
  return sess
end

H['auth.login'] = function(self, args, ctx)
  local name = str(args.name, 64)
  need(name and #name > 0, 'bad-request', 'a name is required')
  need(type(args.password) == 'string', 'bad-request', 'a password is required')
  local token, user, code = self.auth:login(name, args.password, ctx.ip, ctx.userAgent)
  if not token then
    self:record(ctx, 'login.fail', name, 'denied', tostring(code or user or 'refused'))
    if code == 'locked' then err('forbidden', tostring(user or 'too many attempts')) end
    err('unauthorized', 'wrong name or password')
  end
  -- Signing in REPLACES whatever session the client already held.  Minting a
  -- fresh token was never the problem (there is no fixation here), but leaving
  -- the previous one live for its whole idle window meant a stolen-then-noticed
  -- session survived the victim signing in again, and a shared browser kept a
  -- second usable credential.
  local previous = ctx.session
  local sess = self:sessionFor(token, ctx.ip)
  ctx.user, ctx.session = user, sess
  ctx.setSession(token, sess)
  if previous and previous.id and previous.id ~= (sess and sess.id) then
    self.auth:revoke(previous.id)
    self:record(ctx, 'session.revoke', user.name, 'ok',
                'replaced by a new sign-in from ' .. tostring(ctx.ip or '-'))
  end
  self:record(ctx, 'login.ok', user.name, 'ok', '')
  return { user = { id = user.id, name = user.name, role = user.role,
                    canExec = self:mayExec(user) },
           csrf = sess and sess.csrf or nil, csrfToken = sess and sess.csrf or nil }
end

H['auth.bootstrap'] = function(self, args, ctx)
  need(self.auth:needsBootstrap(), 'conflict', 'the hub is already bootstrapped')
  local name = str(args.name, 32)
  need(name and name:match('^[%w_%.%-]+$') and #name >= 2, 'bad-request', 'invalid account name')
  need(type(args.password) == 'string' and #args.password >= 10,
       'bad-request', 'the password must be at least 10 characters')
  local user, e, code = self.auth:createFirstAdmin(args.token, name, args.password)
  if not user then
    self:record(ctx, 'user.create', name, 'denied', 'bootstrap: ' .. tostring(code or e))
    err(code == 'invalid' and 'bad-request' or 'forbidden', tostring(e or 'bad bootstrap token'))
  end
  local token = self.auth:login(name, args.password, ctx.ip, ctx.userAgent)
  local sess = token and self:sessionFor(token, ctx.ip) or nil
  ctx.user, ctx.session = user, sess
  if token then ctx.setSession(token, sess) end
  self:record(ctx, 'user.create', user.name, 'ok', 'bootstrap administrator')
  return { user = { id = user.id, name = user.name, role = user.role, canExec = true },
           csrf = sess and sess.csrf or nil, csrfToken = sess and sess.csrf or nil }
end

H['auth.logout'] = function(self, args, ctx)
  if ctx.session then
    self:record(ctx, 'logout', ctx.user and ctx.user.name or '', 'ok', '')
    self.auth:revoke(ctx.session.id)
  end
  ctx.clearSession()
  ctx.user, ctx.session = nil, nil
  return {}
end

--- Self-service password change.  The current password is proved by
--- auth:verifyPassword, which is the same constant-cost derivation login() runs
--- but touches NEITHER rate limiter and mints no session: proving it with a real
--- login() meant five mistyped entries in this form locked the caller out of the
--- panel for fifteen minutes -- a self-service form must not be able to lock the
--- account it belongs to.  Reaching into users.json for the pwhash from up here
--- is still forbidden; verifyPassword is hub/auth.lua's answer to that.
H['auth.changePassword'] = function(self, args, ctx)
  need(type(args.current) == 'string' and type(args.next) == 'string',
       'bad-request', 'both passwords are required')
  need(#args.next >= 10, 'bad-request', 'the new password must be at least 10 characters')
  if not self.auth:verifyPassword(ctx.user.id, args.current) then
    self:record(ctx, 'user.password', ctx.user.name, 'denied', 'wrong current password')
    err('forbidden', 'the current password is wrong')
  end
  local ok, e = self.auth:setPassword(ctx.user.id, args.next)
  if not ok then
    self:record(ctx, 'user.password', ctx.user.name, 'error', tostring(e))
    err('bad-request', tostring(e))
  end
  self:record(ctx, 'user.password', ctx.user.name, 'ok', 'self-service change')
  ctx.clearSession()       -- setPassword revokes every session, including ours
  return {}
end

-- ------------------------------------------------------------- instances ----
function A:visibleInstances(ctx)
  local out = {}
  for _, i in ipairs(self.model.instances:list()) do
    if self:isAdmin(ctx) or i.ownerUserId == ctx.user.id then out[#out + 1] = i end
  end
  return out
end

H['instance.list'] = function(self, args, ctx)
  local out = {}
  for _, i in ipairs(self:visibleInstances(ctx)) do out[#out + 1] = self:pubInstance(i) end
  return { instances = out }
end

H['instance.get'] = function(self, args, ctx)
  return { instance = self:pubInstance(self:ownedInstance(ctx, args.id)) }
end

H['instance.create'] = function(self, args, ctx)
  local ch = self:ownedCharacter(ctx, args.characterId)
  for _, i in ipairs(self.model.instances:list()) do
    need(i.characterId ~= ch.id, 'conflict', 'that character already has an instance')
  end
  if args.proxyId then self:ownedProxy(ctx, args.proxyId) end
  local inst, e = self.model.instances:create{
    characterId = ch.id, ownerUserId = ctx.user.id, proxyId = args.proxyId or nil,
    botProfile = str(args.botProfile, 64) or 'profile_1',
    cavebotConfig = str(args.cavebotConfig, 128),
    targetbotConfig = str(args.targetbotConfig, 128),
    scripts = {}, autoStart = args.autoStart and true or false,
    autoRelogin = args.autoRelogin ~= false, state = 'stopped',
  }
  if not inst then
    self:record(ctx, 'instance.create', ch.name, 'error', tostring(e))
    err('internal', tostring(e))
  end
  self:record(ctx, 'instance.create', ch.name, 'ok', 'instance ' .. inst.id)
  local pub = self:pubInstance(inst)
  if self.tel then self.tel:publish('instance', { id = inst.id, instance = pub }, { instanceId = inst.id }) end
  return { instance = pub }
end

local INSTANCE_PATCH = { proxyId = true, botProfile = true, cavebotConfig = true,
                         targetbotConfig = true, autoStart = true, autoRelogin = true,
                         scripts = true }

H['instance.update'] = function(self, args, ctx)
  local inst = self:ownedInstance(ctx, args.id)
  local p = type(args.patch) == 'table' and args.patch or {}
  local patch = {}
  for k, v in pairs(p) do
    need(INSTANCE_PATCH[k], 'bad-request', 'field not settable: ' .. tostring(k))
    patch[k] = v
  end
  -- Detaching a proxy.  The documented way is `""`, and `null` / `false` mean the
  -- same thing.  Mapping any of them to Lua nil DELETES the key from the patch
  -- table, so the update became a silent no-op that still answered 200 with the
  -- old proxy still attached -- a proxy could never be detached at all.
  -- hub/model.lua's NIL sentinel exists for exactly this and is what clears a
  -- field.  A JSON `null` decodes to an ABSENT key in lib/json and is therefore
  -- indistinguishable from "field not mentioned" -- which is why "" is the
  -- documented spelling, and why `false` is accepted rather than reaching the
  -- model as a boolean and erroring.
  if patch.proxyId == '' or patch.proxyId == false then
    patch.proxyId = model.NIL
  elseif patch.proxyId ~= nil then
    self:ownedProxy(ctx, patch.proxyId)
  end
  if patch.scripts ~= nil then
    need(isArray(patch.scripts), 'bad-request', 'scripts must be an array of ids')
    local clean = {}
    for _, sid in ipairs(patch.scripts) do
      self:ownedScript(ctx, sid)
      clean[#clean + 1] = tostring(sid)
    end
    patch.scripts = clean
  end
  local ch = self.model.characters:get(inst.characterId)
  local updated, e = self.model.instances:update(inst.id, patch)
  if not updated then
    self:record(ctx, 'instance.config', ch and ch.name or inst.id, 'error', tostring(e))
    err('internal', tostring(e))
  end
  self:record(ctx, 'instance.config', ch and ch.name or inst.id, 'ok', keysOf(patch))
  -- push the new bot config to a running worker; harmless if it is not running
  if self.sup and self.sup:isRunning(inst.id) then
    if patch.cavebotConfig then self.sup:command(inst.id, 'bot.setCavebot', { name = patch.cavebotConfig }) end
    if patch.targetbotConfig then self.sup:command(inst.id, 'bot.setTargetbot', { name = patch.targetbotConfig }) end
    if patch.scripts then self:pushScripts(updated) end
  end
  local pub = self:pubInstance(updated)
  if self.tel then self.tel:publish('instance', { id = inst.id, instance = pub }, { instanceId = inst.id }) end
  return { instance = pub }
end

H['instance.delete'] = function(self, args, ctx)
  local inst = self:ownedInstance(ctx, args.id)
  local ch = self.model.characters:get(inst.characterId)
  if self.sup then self.sup:forget(inst.id) end
  self.model.instances:delete(inst.id)
  if self.tel then
    self.tel:forget(inst.id)
    -- SCOPED: an empty opts table means "everyone", so every signed-in account
    -- learned the ids of other people's instances and scripts as they were
    -- deleted.  The visibility predicate refuses a foreign instance id, so
    -- naming it here is what keeps the removal private.
    self.tel:publish('instance', { id = inst.id, removed = true }, { instanceId = inst.id })
  end
  self:record(ctx, 'instance.delete', ch and ch.name or inst.id, 'ok', '')
  return {}
end

--- Build the launch payload: the ONLY place a stored credential is decrypted.
function A:launchSpec(inst)
  local ch = self.model.characters:get(inst.characterId)
  if not ch then return nil, 'the instance has no character' end
  local acc = self.model.accounts:get(ch.accountId)
  if not acc then return nil, 'the character has no game account' end
  local password, e = self.auth:openAccountPassword(acc.id)
  if not password then return nil, 'cannot decrypt the account password: ' .. tostring(e) end
  local token2fa = nil
  if acc.token2fa and acc.token2fa ~= '' then
    token2fa = self.auth:openAccountToken2fa(acc.id)
  end
  local spec = {
    instance = {
      id = inst.id, botProfile = inst.botProfile, cavebotConfig = inst.cavebotConfig,
      targetbotConfig = inst.targetbotConfig, autoRelogin = inst.autoRelogin ~= false,
    },
    character = { name = ch.name, world = ch.world, vocation = ch.vocation },
    account   = { login = acc.login, password = password, token2fa = token2fa },
    scripts   = {},
  }
  if self.gameHost or self.loginUrl then
    spec.server = { host = self.gameHost, port = self.gamePort, loginUrl = self.loginUrl }
  end
  if inst.proxyId then
    local p = self.model.proxies:get(inst.proxyId)
    if p then
      local pass = nil
      if p.pass and p.pass ~= '' then pass = self.auth:openProxyPassword(p.id) end
      spec.proxy = { host = p.host, port = p.port, kind = p.kind or 'http-connect',
                     user = p.user, pass = pass }
    end
  end
  for _, sid in ipairs(inst.scripts or {}) do
    local s = self.model.scripts:get(sid)
    if s then
      local src = self:scriptSource(s.id)
      if src then spec.scripts[#spec.scripts + 1] = { name = s.name, source = src } end
    end
  end
  return spec
end

function A:pushScripts(inst)
  if not self.sup then return end
  for _, sid in ipairs(inst.scripts or {}) do
    local s = self.model.scripts:get(sid)
    if s then
      local src = self:scriptSource(s.id)
      if src then self.sup:command(inst.id, 'script.put', { name = s.name, source = src }) end
    end
  end
end

--- The largest id list a bulk action accepts.  The panel selects instances from
--- a table it has already loaded, so a hundred is far past any real use; the cap
--- exists because the list used to be UNBOUNDED, and each failing id wrote its
--- own fsynced audit record.  One 360 KB request produced 20,000 records, and
--- eleven of them scrolled the entire five-file retention out of the log -- an
--- audit-erasing primitive available to any signed-in account, plus tens of
--- seconds of blocked reactor on a host where fsync costs anything.
M.MAX_BULK_IDS = 100

--- start / stop / restart share the bulk-result shape the panel expects.
local function bulk(self, ctx, args, action, fn)
  local ids = args.ids
  if type(ids) ~= 'table' then ids = { args.id } end
  need(#ids <= M.MAX_BULK_IDS, 'bad-request',
       'at most ' .. M.MAX_BULK_IDS .. ' ids per request (got ' .. #ids .. ')')
  local results = {}
  -- Failures are COLLAPSED into one record per request rather than one per id:
  -- the interesting fact is "this actor was refused these ids", and writing it
  -- once keeps the cost of a request O(1) fsyncs instead of O(#ids).
  local failed, firstMsg = {}, nil
  for _, id in ipairs(ids) do
    local ok, res = pcall(fn, self, ctx, tostring(id))
    if ok and res == true then
      results[#results + 1] = { id = id, ok = true }
    else
      local msg = 'failed'
      if type(res) == 'table' and res.message then msg = res.message
      elseif res ~= nil and res ~= true then msg = tostring(res) end
      results[#results + 1] = { id = id, ok = false, error = msg }
      failed[#failed + 1] = tostring(id)
      firstMsg = firstMsg or msg
    end
  end
  if #failed > 0 then
    local shown = failed
    if #shown > 10 then
      shown = {}
      for i = 1, 10 do shown[i] = failed[i] end
      shown[11] = '... and ' .. (#failed - 10) .. ' more'
    end
    self:record(ctx, action, failed[1], 'denied',
                ('%d of %d refused (%s): %s'):format(#failed, #ids,
                 tostring(firstMsg), table.concat(shown, ',')))
  end
  return { results = results }
end

H['instance.start'] = function(self, args, ctx)
  return bulk(self, ctx, args, 'instance.start', function(s, c, id)
    local inst = s:ownedInstance(c, id)
    local ch = s.model.characters:get(inst.characterId)
    need(s.sup, 'internal', 'no supervisor')
    need(not s.sup:isRunning(inst.id), 'conflict', 'already running')
    local spec, e = s:launchSpec(inst)
    need(spec, 'bad-request', tostring(e))
    local ok, se = s.sup:startInstance(inst.id, spec)
    spec = nil                                   -- drop the plaintext reference
    need(ok, 'internal', tostring(se))
    s:record(c, 'instance.start', ch and ch.name or inst.id, 'ok', '')
    return true
  end)
end

H['instance.stop'] = function(self, args, ctx)
  return bulk(self, ctx, args, 'instance.stop', function(s, c, id)
    local inst = s:ownedInstance(c, id)
    local ch = s.model.characters:get(inst.characterId)
    need(s.sup, 'internal', 'no supervisor')
    need(s.sup:isRunning(inst.id), 'conflict', 'already stopped')
    local ok, e = s.sup:stopInstance(inst.id)
    need(ok, 'internal', tostring(e))
    s:record(c, 'instance.stop', ch and ch.name or inst.id, 'ok', '')
    return true
  end)
end

H['instance.restart'] = function(self, args, ctx)
  return bulk(self, ctx, args, 'instance.start', function(s, c, id)
    local inst = s:ownedInstance(c, id)
    local ch = s.model.characters:get(inst.characterId)
    need(s.sup, 'internal', 'no supervisor')
    local spec, e = s:launchSpec(inst)
    need(spec, 'bad-request', tostring(e))
    local ok, se = s.sup:restartInstance(inst.id, spec)
    spec = nil
    need(ok, 'internal', tostring(se))
    s:record(c, 'instance.start', ch and ch.name or inst.id, 'ok', 'restart')
    return true
  end)
end

H['instance.botEnable'] = function(self, args, ctx)
  local on = args.on and true or false
  return bulk(self, ctx, args, 'instance.config', function(s, c, id)
    local inst = s:ownedInstance(c, id)
    local ch = s.model.characters:get(inst.characterId)
    need(s.sup and s.sup:isRunning(inst.id), 'conflict', 'instance is not online')
    s.sup:command(inst.id, 'bot.enable', { on = on })
    if s.tel then
      local l = s.tel:merge(inst.id, { botEnabled = on })
      s.tel:publish('status', { id = inst.id, botEnabled = on, state = s.sup:state(inst.id) },
                    { instanceId = inst.id })
    end
    s:record(c, 'instance.config', ch and ch.name or inst.id, 'ok', 'bot.enable=' .. tostring(on))
    return true
  end)
end

-- The config lists live in the worker's profile directory, so only a running
-- worker can enumerate them.  The last answer is cached IN MEMORY (hub/model.lua's
-- instances spec has no field for it, and a cache does not belong in the durable
-- record anyway); a stopped instance gets that cache back marked `stale`.
H['instance.configs'] = function(self, args, ctx, done)
  local inst = self:ownedInstance(ctx, args.id)
  local function cached(stale)
    local c = self.configsCache[inst.id] or {}
    return { cavebot = c.cavebot or {}, targetbot = c.targetbot or {},
             profiles = c.profiles or {}, macros = c.macros or {}, stale = stale or nil }
  end
  if self.sup and self.sup:isRunning(inst.id) then
    self.sup:command(inst.id, 'bot.listConfigs', {}, function(ok, res)
      if ok and type(res) == 'table' then
        local c = { cavebot = res.cavebot or {}, targetbot = res.targetbot or {},
                    profiles = res.profiles or {}, macros = res.macros or {} }
        self.configsCache[inst.id] = c
        done(true, { cavebot = c.cavebot, targetbot = c.targetbot,
                     profiles = c.profiles, macros = c.macros })
      else
        done(true, cached(true))
      end
    end)
    return M.PENDING
  end
  return cached(true)
end

H['instance.setMacro'] = function(self, args, ctx, done)
  local inst = self:ownedInstance(ctx, args.id)
  local ch = self.model.characters:get(inst.characterId)
  local name = str(args.name, 64)
  need(name and #name > 0, 'bad-request', 'no macro name')
  need(self.sup and self.sup:isRunning(inst.id), 'conflict', 'the instance is not running')
  local on = args.on and true or false
  self.sup:command(inst.id, 'bot.setMacro', { name = name, on = on }, function(ok, res)
    self:record(ctx, 'instance.config', ch and ch.name or inst.id, ok and 'ok' or 'error',
                'macro ' .. name .. '=' .. tostring(on))
    if ok then
      -- panel/api.js expects {macro:{name,label,on,hotkey}}; the worker answers
      -- with whatever it knows, so fill in what it left out.
      local m = (type(res) == 'table' and type(res.macro) == 'table') and res.macro
                or (type(res) == 'table' and res or {})
      local out = { name = m.name or name, label = m.label or m.name or name,
                    on = (m.on ~= nil and m.on) or (m.enabled ~= nil and m.enabled) or on,
                    hotkey = m.hotkey }
      done(true, { macro = out })
    else done(false, res) end
  end)
  return M.PENDING
end

H['instance.reload'] = function(self, args, ctx, done)
  local inst = self:ownedInstance(ctx, args.id)
  local ch = self.model.characters:get(inst.characterId)
  need(self.sup and self.sup:isRunning(inst.id), 'conflict', 'the instance is not running')
  self.sup:command(inst.id, 'bot.reload', {}, function(ok, res)
    self:record(ctx, 'instance.config', ch and ch.name or inst.id, ok and 'ok' or 'error', 'bot.reload')
    if ok then done(true, res or {}) else done(false, res) end
  end)
  return M.PENDING
end

H['instance.exec'] = function(self, args, ctx, done)
  local inst = self:ownedInstance(ctx, args.id)
  local ch = self.model.characters:get(inst.characterId)
  need(type(args.code) == 'string' and #args.code > 0, 'bad-request', 'no code given')
  need(#args.code <= 64 * 1024, 'bad-request', 'that chunk is too large')
  need(self.sup and self.sup:isRunning(inst.id), 'conflict', 'the instance is not running')
  -- PANEL.md: remote Lua is audited WITH the code.
  self:record(ctx, 'exec', ch and ch.name or inst.id, 'ok', 'code: ' .. args.code:sub(1, 2000))
  self.sup:command(inst.id, 'exec', { code = args.code }, function(ok, res)
    if ok then
      -- control/commands.lua answers {ms, type, value}; the panel's Console wants
      -- ONE string to print.  A table is rendered as JSON so a status snapshot is
      -- readable; everything else is tostring()'d, and nil prints as `nil`.
      local out
      if type(res) ~= 'table' then out = tostring(res)
      elseif type(res.output) == 'string' then out = res.output
      elseif res.value == nil then out = 'nil'
      elseif type(res.value) == 'table' then
        local okj, txt = pcall(json.encode, res.value)
        out = okj and txt or tostring(res.value)
      else out = tostring(res.value) end
      done(true, { output = out, ms = type(res) == 'table' and res.ms or nil,
                   type = type(res) == 'table' and res.type or nil })
    else
      self:record(ctx, 'exec', ch and ch.name or inst.id, 'error',
                  tostring(res and res.message or 'failed'))
      done(false, res)
    end
  end, 30000)
  return M.PENDING
end

H['instance.history'] = function(self, args, ctx)
  local inst = self:ownedInstance(ctx, args.id)
  return { points = self.tel and self.tel:history(inst.id, args.since) or {} }
end

H['instance.logs'] = function(self, args, ctx)
  local inst = self:ownedInstance(ctx, args.id)
  local lim = math.min(tonumber(args.limit) or 200, 800)
  return { lines = self.sup and self.sup:logs(inst.id, lim) or {} }
end

H['instance.chat'] = function(self, args, ctx)
  local inst = self:ownedInstance(ctx, args.id)
  local lim = math.min(tonumber(args.limit) or 200, 500)
  return { messages = self.sup and self.sup:chat(inst.id, lim) or {} }
end

H['instance.say'] = function(self, args, ctx, done)
  local inst = self:ownedInstance(ctx, args.id)
  local ch = self.model.characters:get(inst.characterId)
  local text = str(args.text, 255)
  need(text and text:match('%S'), 'bad-request', 'empty message')
  need(self.sup and self.sup:state(inst.id) == 'online', 'conflict', 'the character is not online')
  -- control/commands.lua's command list (PANEL.md's list, exactly) has no `say`.
  -- Rather than draw a button that cannot work, fall back to the `exec` command,
  -- which runs in the same vBot-compatible environment where say() lives.  %q is
  -- Lua's own quoting, so the operator's text cannot escape the string literal.
  local function fallback()
    self.sup:command(inst.id, 'exec', { code = string.format('say(%q)', text) },
      function(ok2, res2)
        self:record(ctx, 'instance.say', ch and ch.name or inst.id, ok2 and 'ok' or 'error',
                    'via exec: ' .. text:sub(1, 200))
        if ok2 then done(true, {}) else done(false, res2) end
      end)
  end
  self.sup:command(inst.id, 'say', { text = text, channel = args.channel }, function(ok, res)
    if not ok and type(res) == 'table' and res.code == 'unknown-command' then
      return fallback()
    end
    self:record(ctx, 'instance.say', ch and ch.name or inst.id, ok and 'ok' or 'error',
                text:sub(1, 200))
    if ok then done(true, res or {}) else done(false, res) end
  end)
  return M.PENDING
end

-- -------------------------------------------------------- game accounts -----
H['account.list'] = function(self, args, ctx)
  local out = {}
  for _, a in ipairs(self.model.accounts:list()) do
    if self:isAdmin(ctx) or a.ownerUserId == ctx.user.id then out[#out + 1] = self:pubAccount(a) end
  end
  return { accounts = out }
end

H['account.create'] = function(self, args, ctx)
  local label = str(args.label, 64)
  local login = str(args.login, 128)
  need(label and #label > 0 and login and #login > 0, 'bad-request', 'label and login are required')
  need(type(args.password) == 'string' and #args.password > 0, 'bad-request', 'a password is required')
  -- The row is created WITHOUT the credential, then sealed into its own slot: the
  -- associated data hub/auth.lua binds is "accounts:<id>:password", so the id has
  -- to exist first.  A ciphertext lifted into another row will not decrypt.
  local acc, e = self.model.accounts:create{
    label = label, login = login, ownerUserId = ctx.user.id }
  if not acc then
    self:record(ctx, 'account.create', label, 'error', tostring(e))
    err('bad-request', tostring(e))
  end
  local sealed, se = self.auth:sealAccountPassword(acc.id, args.password)
  if not sealed then
    self.model.accounts:delete(acc.id)
    self:record(ctx, 'account.create', label, 'error', tostring(se))
    err('internal', tostring(se))
  end
  if type(args.token2fa) == 'string' and #args.token2fa > 0 then
    self.auth:sealAccountToken2fa(acc.id, args.token2fa)
  end
  acc = self.model.accounts:get(acc.id) or acc
  -- NEVER the password, not even its length
  self:record(ctx, 'account.create', label, 'ok', 'login=' .. login)
  return { account = self:pubAccount(acc) }
end

H['account.update'] = function(self, args, ctx)
  local acc = self:ownedAccount(ctx, args.id)
  local p = type(args.patch) == 'table' and args.patch or {}
  local patch = {}
  if p.label ~= nil then patch.label = str(p.label, 64) end
  if p.login ~= nil then patch.login = str(p.login, 128) end
  local updated = acc
  if next(patch) then
    local u, ue = self.model.accounts:update(acc.id, patch)
    if not u then
      self:record(ctx, 'account.update', acc.label, 'error', tostring(ue))
      err('bad-request', tostring(ue))
    end
    updated = u
  end
  if type(p.password) == 'string' and #p.password > 0 then
    local ok, se = self.auth:sealAccountPassword(acc.id, p.password)
    if not ok then err('internal', tostring(se)) end
  end
  if p.token2fa ~= nil then
    -- '' / false clears it: sealInto() maps an empty value to model.NIL
    self.auth:sealAccountToken2fa(acc.id,
      (type(p.token2fa) == 'string' and #p.token2fa > 0) and p.token2fa or '')
  end
  updated = self.model.accounts:get(acc.id) or updated
  self:record(ctx, 'account.update', acc.label, 'ok',
              'fields ' .. keysOf(p, { password = true, token2fa = true }) ..
              (p.password and ' +password' or '') .. (p.token2fa and ' +token2fa' or ''))
  return { account = self:pubAccount(updated) }
end

H['account.delete'] = function(self, args, ctx)
  local acc = self:ownedAccount(ctx, args.id)
  local removed = 0
  for _, c in ipairs(self.model.characters:list()) do
    if c.accountId == acc.id then
      for _, i in ipairs(self.model.instances:list()) do
        if i.characterId == c.id then
          if self.sup then self.sup:forget(i.id) end
          self.model.instances:delete(i.id)
          if self.tel then
            self.tel:publish('instance', { id = i.id, removed = true }, { instanceId = i.id })
          end
        end
      end
      self.model.characters:delete(c.id)
      removed = removed + 1
    end
  end
  self.model.accounts:delete(acc.id)
  self:record(ctx, 'account.delete', acc.label, 'ok', removed .. ' characters removed')
  return {}
end

-- ---------------------------------------------------------- characters ------
H['character.list'] = function(self, args, ctx)
  local mine = {}
  for _, a in ipairs(self.model.accounts:list()) do
    if self:isAdmin(ctx) or a.ownerUserId == ctx.user.id then mine[a.id] = true end
  end
  local out = {}
  for _, c in ipairs(self.model.characters:list()) do
    if mine[c.accountId] then out[#out + 1] = self:pubCharacter(c) end
  end
  return { characters = out }
end

H['character.create'] = function(self, args, ctx)
  local acc = self:ownedAccount(ctx, args.accountId)
  local name = str(args.name, 64)
  local world = str(args.world, 64)
  need(name and #name > 0 and world and #world > 0, 'bad-request',
       'accountId, name and world are required')
  for _, c in ipairs(self.model.characters:list()) do
    need(c.name:lower() ~= name:lower(), 'conflict', 'a character with that name already exists')
  end
  local c, e = self.model.characters:create{
    accountId = acc.id, name = name, world = world,
    vocation = str(args.vocation, 32), lastLevel = nil }
  if not c then err('internal', tostring(e)) end
  self:record(ctx, 'character.create', name, 'ok', 'account ' .. acc.label)
  return { character = self:pubCharacter(c) }
end

H['character.delete'] = function(self, args, ctx)
  local c = self:ownedCharacter(ctx, args.id)
  for _, i in ipairs(self.model.instances:list()) do
    if i.characterId == c.id then
      if self.sup then self.sup:forget(i.id) end
      self.model.instances:delete(i.id)
      if self.tel then
        self.tel:publish('instance', { id = i.id, removed = true }, { instanceId = i.id })
      end
    end
  end
  self.model.characters:delete(c.id)
  self:record(ctx, 'character.delete', c.name, 'ok', '')
  return {}
end

-- ------------------------------------------------------------- proxies ------
-- Proxies are a SHARED pool: hub/model.lua's proxies spec has no ownerUserId,
-- PANEL.md never scopes them, and an operator's exit nodes are infrastructure
-- rather than personal data.  Every authenticated account may list one and
-- attach it to an instance.  The stored credential is never returned -- only
-- `hasPass` -- and `proxy.test` decrypts it inside the hub and throws it away.
H['proxy.list'] = function(self, args, ctx)
  local out = {}
  for _, p in ipairs(self.model.proxies:list()) do out[#out + 1] = self:pubProxy(p, ctx) end
  return { proxies = out }
end

H['proxy.create'] = function(self, args, ctx)
  local label = str(args.label, 64)
  local host  = str(args.host, 255)
  local port  = tonumber(args.port)
  need(label and #label > 0 and host and #host > 0 and port and port > 0 and port < 65536,
       'bad-request', 'label, host and port are required')
  local p, e = self.model.proxies:create{
    label = label, kind = str(args.kind, 32) or 'http-connect', host = host, port = floor(port),
    user = str(args.user, 128), ownerUserId = ctx.user.id }
  if not p then
    self:record(ctx, 'proxy.create', label, 'error', tostring(e))
    err('bad-request', tostring(e))
  end
  if type(args.pass) == 'string' and #args.pass > 0 then
    self.auth:sealProxyPassword(p.id, args.pass)
    p = self.model.proxies:get(p.id) or p
  end
  self:record(ctx, 'proxy.create', label, 'ok', host .. ':' .. floor(port))
  return { proxy = self:pubProxy(p, ctx) }
end

H['proxy.update'] = function(self, args, ctx)
  local p = self:ownedProxyForWrite(ctx, args.id)
  local q = type(args.patch) == 'table' and args.patch or {}
  local patch = {}
  if q.label ~= nil then patch.label = str(q.label, 64) end
  if q.kind  ~= nil then patch.kind  = str(q.kind, 32) end
  if q.host  ~= nil then patch.host  = str(q.host, 255) end
  if q.user  ~= nil then patch.user  = str(q.user, 128) end
  if q.port  ~= nil then
    local n = tonumber(q.port)
    need(n and n > 0 and n < 65536, 'bad-request', 'bad port')
    patch.port = floor(n)
  end
  local updated = p
  if next(patch) then
    local u, ue = self.model.proxies:update(p.id, patch)
    if not u then
      self:record(ctx, 'proxy.change', p.label, 'error', tostring(ue))
      err('bad-request', tostring(ue))
    end
    updated = u
  end
  if q.pass ~= nil then
    self.auth:sealProxyPassword(p.id,
      (type(q.pass) == 'string' and #q.pass > 0) and q.pass or '')
    updated = self.model.proxies:get(p.id) or updated
  end
  self:record(ctx, 'proxy.change', p.label, 'ok', keysOf(q, { pass = true }) ..
              (q.pass and ' +pass' or ''))
  return { proxy = self:pubProxy(updated, ctx) }
end

H['proxy.delete'] = function(self, args, ctx)
  local p = self:ownedProxyForWrite(ctx, args.id)
  for _, i in ipairs(self.model.instances:list()) do
    need(i.proxyId ~= p.id, 'conflict', 'the proxy is still assigned to an instance')
  end
  self.model.proxies:delete(p.id)
  self:record(ctx, 'proxy.change', p.label, 'ok', 'deleted')
  return {}
end

--- Is this host one an authenticated user must not be able to make the hub
--- connect to?  proxy.create accepts any host and any port, and proxy.test then
--- opens a TCP connection FROM THE HUB'S NETWORK POSITION and reports a
--- distinguishable outcome -- which maps every internal service the hub can
--- reach and the user cannot.  Loopback, link-local and the RFC1918 ranges are
--- refused unless the operator opted in with allowPrivateProxies.
local function isPrivateHost(host)
  host = tostring(host or ''):lower()
  if host == 'localhost' or host == '::1' or host == '[::1]' or host == '' then return true end
  local a, b = host:match('^(%d+)%.(%d+)%.%d+%.%d+$')
  if not a then
    -- Not a bare IPv4 literal: an IPv6 literal is refused outright (we cannot
    -- classify it here); a DNS name is allowed and resolves at connect time.
    if host:find(':', 1, true) then return true end
    return false
  end
  a, b = tonumber(a), tonumber(b)
  if a == 127 or a == 0 or a == 10 then return true end
  if a == 169 and b == 254 then return true end               -- link-local + IMDS
  if a == 172 and b >= 16 and b <= 31 then return true end
  if a == 192 and b == 168 then return true end
  if a == 100 and b >= 64 and b <= 127 then return true end   -- CGNAT
  return false
end
M.isPrivateHost = isPrivateHost

--- The fixed reason set proxy.test may report.  Echoing the peer's own status
--- line and the socket errno turned this endpoint into a port scanner with a
--- readable banner; these answers are everything an operator needs to fix a
--- proxy entry, and the peer's own words go to the AUDIT LOG instead.
local function testReason(kind)
  local REASONS = {
    ok            = 'the proxy accepted the CONNECT',
    unreachable   = 'the proxy did not answer',
    ['not-proxy'] = 'the peer answered, but not as a proxy',
    refused       = 'the proxy refused the CONNECT',
    timeout       = 'the proxy did not finish the handshake in time',
    blocked       = 'testing a private or loopback address is not allowed',
  }
  return REASONS[kind] or REASONS.unreachable
end
M.proxyTestReason = testReason

--- A real, non-blocking HTTP CONNECT against the proxy.  It never touches the game
--- server: the CONNECT target is a configurable, harmless host:port, and ANY HTTP
--- answer (even 403) proves the proxy is reachable and speaking.
H['proxy.test'] = function(self, args, ctx, done)
  local p = self:ownedProxy(ctx, args.id)
  -- Rate-limited per session: not more often than once a second, so the endpoint
  -- cannot be driven as a scanner even inside the allowed address space.
  local sid = (ctx.session and ctx.session.id) or ctx.ip or '-'
  self.proxyTestAt = self.proxyTestAt or {}
  local last = self.proxyTestAt[sid]
  local nowMs = sys.nowMs()
  need(not last or (nowMs - last) >= 1000, 'rate-limited',
       'one proxy test per second, please')
  self.proxyTestAt[sid] = nowMs
  if isPrivateHost(p.host) and not self.allowPrivateProxies then
    self:record(ctx, 'proxy.test', p.label, 'denied', 'private address refused')
    return { ok = false, latencyMs = 0, reason = 'blocked', error = testReason('blocked') }
  end
  local pass = nil
  if p.pass and p.pass ~= '' then pass = self.auth:openProxyPassword(p.id) end
  local thost, tport = proxylib.parseEndpoint(self.proxyTestTarget)
  if not thost then thost, tport = 'example.com', 443 end
  local hs = proxylib.newHandshake{ host = thost, port = tport, user = p.user, pass = pass,
                                    proxyHost = p.host, proxyPort = p.port, timeoutMs = 8000 }
  local s, e = socket.tcp()
  if not s then
    self:record(ctx, 'proxy.test', p.label, 'error', tostring(e))
    return { ok = false, latencyMs = 0, error = tostring(e) }
  end
  local t0 = sys.nowMs()
  local finished, timer = false, nil
  --- `kind` is one of the fixed reasons above; `detail` is for the AUDIT LOG
  --- only (an administrator may see the peer's own words), never for the reply.
  local function finish(ok, kind, detail, latency)
    if finished then return end
    finished = true
    if timer then pcall(self.sched.cancel, timer) end
    pcall(function() self.sched.removeSocket(s) end)
    pcall(function() s:close() end)
    self:record(ctx, 'proxy.test', p.label, ok and 'ok' or 'error',
                tostring(kind) .. (detail and (': ' .. tostring(detail)) or ''))
    if ok then done(true, { ok = true, latencyMs = latency or 0, reason = 'ok' })
    else done(true, { ok = false, latencyMs = 0, reason = kind,
                      error = testReason(kind) }) end
  end
  local ok, cerr = s:connect(p.host, p.port)
  if not ok then finish(false, 'unreachable', cerr or 'connect failed'); return M.PENDING end
  local sent = false
  self.sched.onSocket(s,
    function()
      local d, rerr = s:recv(65536)
      if d == nil then
        finish(false, 'unreachable',
               rerr == 'closed' and 'proxy closed the connection' or tostring(rerr))
        return
      end
      if d == '' then return end
      local status = hs:feed(d, sys.nowMs())
      if status == 'connected' then finish(true, 'ok', 'CONNECT ok', floor(sys.nowMs() - t0))
      elseif status == 'error' then
        -- The peer answered.  An HTTP status line means it speaks proxy and is
        -- refusing this target; anything else means it is not a proxy at all.
        local line = tostring(hs.statusLine or '')
        finish(false, line:match('^HTTP/') and 'refused' or 'not-proxy',
               line ~= '' and line or tostring(hs.err or 'refused'))
      end
    end,
    function()
      if sent then s:flush(); return end
      if not s:isConnected() then
        if s.state == 'error' then finish(false, 'unreachable', s.err or 'connect failed') end
        return
      end
      sent = true
      s:send(hs.request)
    end)
  timer = self.sched.after(9000, function() finish(false, 'timeout', 'no answer in 9 s') end)
  return M.PENDING
end

-- ------------------------------------------------------------- scripts ------
H['script.list'] = function(self, args, ctx)
  local out = {}
  for _, s in ipairs(self.model.scripts:list()) do
    if self:isAdmin(ctx) or s.ownerUserId == ctx.user.id then out[#out + 1] = self:pubScript(s) end
  end
  return { scripts = out }
end

H['script.get'] = function(self, args, ctx)
  local s = self:ownedScript(ctx, args.id)
  return { script = self:pubScript(s), source = self:scriptSource(s.id) or '' }
end

H['script.upload'] = function(self, args, ctx)
  local name = str(args.name, 64)
  -- hub/model.lua's scripts spec pins this shape (it has to end in .lua); check it
  -- here so the panel gets a sentence instead of a schema error.
  need(name and name:match('^[%w][%w%._%- ]*%.lua$') and #name >= 5,
       'bad-request', 'the script name must look like `name.lua`')
  need(type(args.source) == 'string' and #args.source > 0, 'bad-request', 'empty source')
  need(#args.source <= self.maxScriptBytes, 'too-large',
       'script exceeds ' .. floor(self.maxScriptBytes / 1024) .. ' KiB')
  local existing = nil
  for _, s in ipairs(self.model.scripts:list()) do
    if s.name == name and (self:isAdmin(ctx) or s.ownerUserId == ctx.user.id) then existing = s; break end
  end
  local digest = sha2.sha256hex(args.source)
  local rec
  if existing then
    rec = self.model.scripts:update(existing.id,
      { size = #args.source, sha256 = digest, createdAt = wallMs() }) or existing
  else
    local e
    rec, e = self.model.scripts:create{ name = name, size = #args.source, sha256 = digest,
                                        ownerUserId = ctx.user.id, createdAt = wallMs() }
    if not rec then
      self:record(ctx, 'script.upload', name, 'error', tostring(e))
      err('internal', tostring(e))
    end
  end
  local ok, e2 = self:putScriptSource(rec.id, args.source)
  if not ok then
    self:record(ctx, 'script.upload', name, 'error', tostring(e2))
    err('internal', tostring(e2))
  end
  self:record(ctx, 'script.upload', name, 'ok',
              #args.source .. ' bytes, sha256 ' .. digest:sub(1, 12))
  local pub = self:pubScript(rec)
  if self.tel then self.tel:publish('script', { id = rec.id, script = pub }, { userId = rec.ownerUserId }) end
  -- refresh it on every instance that already runs it
  for _, i in ipairs(self.model.instances:list()) do
    for _, sid in ipairs(i.scripts or {}) do
      if sid == rec.id and self.sup and self.sup:isRunning(i.id) then
        self.sup:command(i.id, 'script.put', { name = rec.name, source = args.source })
      end
    end
  end
  return { script = pub }
end

H['script.delete'] = function(self, args, ctx)
  local s = self:ownedScript(ctx, args.id)
  for _, i in ipairs(self.model.instances:list()) do
    local keep, changed = {}, false
    for _, sid in ipairs(i.scripts or {}) do
      if sid == s.id then changed = true else keep[#keep + 1] = sid end
    end
    if changed then
      self.model.instances:update(i.id, { scripts = keep })
      if self.sup and self.sup:isRunning(i.id) then
        self.sup:command(i.id, 'script.remove', { name = s.name })
      end
    end
  end
  self.model.scripts:delete(s.id)
  self:deleteScriptSource(s.id)
  self:record(ctx, 'script.delete', s.name, 'ok', '')
  if self.tel then
    self.tel:publish('script', { id = s.id, removed = true }, { userId = s.ownerUserId })
  end
  return {}
end

H['script.assign'] = function(self, args, ctx)
  local s = self:ownedScript(ctx, args.id)
  local want = {}
  need(isArray(args.instanceIds), 'bad-request', 'instanceIds must be an array')
  for _, iid in ipairs(args.instanceIds) do
    self:ownedInstance(ctx, iid)           -- refuses someone else's instance
    want[tostring(iid)] = true
  end
  local src = self:scriptSource(s.id)
  for _, i in ipairs(self.model.instances:list()) do
    if self:isAdmin(ctx) or i.ownerUserId == ctx.user.id then
      local list, has = {}, false
      for _, sid in ipairs(i.scripts or {}) do
        if sid == s.id then has = true else list[#list + 1] = sid end
      end
      local wantIt = want[i.id] and true or false
      if wantIt then list[#list + 1] = s.id end
      if wantIt ~= has then
        local updated = self.model.instances:update(i.id, { scripts = list })
        if self.sup and self.sup:isRunning(i.id) then
          if wantIt and src then self.sup:command(i.id, 'script.put', { name = s.name, source = src })
          elseif not wantIt then self.sup:command(i.id, 'script.remove', { name = s.name }) end
        end
        if self.tel and updated then
          self.tel:publish('instance', { id = i.id, instance = self:pubInstance(updated) },
                           { instanceId = i.id })
        end
      end
    end
  end
  local n = 0
  for _ in pairs(want) do n = n + 1 end
  self:record(ctx, 'script.assign', s.name, 'ok', n .. ' instances')
  return { script = self:pubScript(s) }
end

-- --------------------------------------------------------------- admin ------
H['admin.users'] = function(self, args, ctx)
  local out = {}
  for _, u in ipairs(self.model.users:list()) do out[#out + 1] = pubUser(u) end
  return { users = out }
end

H['admin.userCreate'] = function(self, args, ctx)
  local name = str(args.name, 32)
  need(name and name:match('^[%w][%w%._%-]*$') and #name >= 2, 'bad-request', 'invalid account name')
  need(type(args.password) == 'string' and #args.password >= 10, 'bad-request', 'password too short')
  need(args.role == 'admin' or args.role == 'user', 'bad-request', 'role must be admin or user')
  local u, e = self.auth:createUser(name, args.password, args.role)
  if not u then
    self:record(ctx, 'user.create', name, 'denied', tostring(e))
    err(M.duplicateCode(e), tostring(e))
  end
  self:record(ctx, 'user.create', u.name, 'ok', 'role=' .. u.role)   -- never the password
  return { user = pubUser(u) }
end

H['admin.userUpdate'] = function(self, args, ctx)
  local u = self.model.users:get(tostring(args.id or ''))
  need(u, 'not-found', 'no such account')
  need(u.id ~= ctx.user.id, 'forbidden', 'you cannot change your own role or status')
  local p = type(args.patch) == 'table' and args.patch or {}
  local changed = {}
  if p.role ~= nil then
    need(p.role == 'admin' or p.role == 'user', 'bad-request', 'bad role')
    local ok, e = self.auth:setRole(u.id, p.role)
    if not ok then
      self:record(ctx, 'user.update', u.name, 'error', tostring(e))
      err('conflict', tostring(e))       -- e.g. demoting the last administrator
    end
    changed[#changed + 1] = 'role'
  end
  if p.disabled ~= nil then
    local ok, e = self.auth:setDisabled(u.id, p.disabled and true or false)
    if not ok then
      self:record(ctx, 'user.update', u.name, 'error', tostring(e))
      err('conflict', tostring(e))
    end
    changed[#changed + 1] = 'disabled'
  end
  if p.canExec ~= nil then
    -- Granting remote Lua is granting the host.  It gets its own audit record,
    -- separate from the rest of the patch, so the grant is never buried in a
    -- 'role,disabled' summary line.
    local ok, e = self.auth:setCanExec(u.id, p.canExec and true or false)
    if not ok then
      self:record(ctx, 'user.update', u.name, 'error', tostring(e))
      err('conflict', tostring(e))
    end
    self:record(ctx, 'user.canExec', u.name, 'ok',
                p.canExec and 'GRANTED remote Lua (admin-equivalent)' or 'revoked remote Lua')
    changed[#changed + 1] = 'canExec'
  end
  local updated = self.model.users:get(u.id) or u
  self:record(ctx, 'user.update', u.name, 'ok', table.concat(changed, ','))
  return { user = pubUser(updated) }
end

H['admin.userDelete'] = function(self, args, ctx)
  local u = self.model.users:get(tostring(args.id or ''))
  need(u, 'not-found', 'no such account')
  need(u.id ~= ctx.user.id, 'forbidden', 'you cannot delete your own account')
  self.auth:revokeUser(u.id)
  local ok, e = self.auth:deleteUser(u.id)
  if not ok then
    -- hub/model.lua refuses while the account still owns rows; say which.
    self:record(ctx, 'user.delete', u.name, 'denied', tostring(e))
    err('conflict', tostring(e))
  end
  self:record(ctx, 'user.delete', u.name, 'ok', '')
  return {}
end

H['admin.userResetPassword'] = function(self, args, ctx)
  local u = self.model.users:get(tostring(args.id or ''))
  need(u, 'not-found', 'no such account')
  need(type(args.password) == 'string' and #args.password >= 10, 'bad-request', 'password too short')
  local ok, e = self.auth:setPassword(u.id, args.password)   -- revokes that user's sessions
  if not ok then
    self:record(ctx, 'user.password', u.name, 'error', tostring(e))
    err('bad-request', tostring(e))
  end
  self:record(ctx, 'user.password', u.name, 'ok', 'reset by administrator')  -- never the password
  return {}
end

H['admin.sessions'] = function(self, args, ctx)
  local out = {}
  for _, s in ipairs(self.auth:sessions()) do
    out[#out + 1] = { id = s.id, userId = s.userId, userName = s.name or self:userName(s.userId),
                      ip = s.ip, userAgent = s.userAgent, createdAt = s.createdAt,
                      lastSeenAt = s.lastSeenAt, expiresAt = s.expiresAt,
                      current = (ctx.session and s.id == ctx.session.id) and true or false }
  end
  table.sort(out, function(a, b) return (a.createdAt or 0) > (b.createdAt or 0) end)
  return { sessions = out }
end

H['admin.sessionRevoke'] = function(self, args, ctx)
  local id = tostring(args.id or '')
  local target
  for _, s in ipairs(self.auth:sessions()) do if s.id == id then target = s end end
  need(target, 'not-found', 'no such session')
  self.auth:revoke(id)
  self:record(ctx, 'session.revoke', target.name or self:userName(target.userId) or target.userId,
              'ok', target.ip or '')
  return {}
end

--- The admin-only activity log.  hub/audit.lua answers newest-first with a real
--- cursor; the filter dropdowns are filled from the known action vocabulary and
--- the current account list, which is cheap and does not require scanning the log.
H['admin.audit'] = function(self, args, ctx)
  need(self.audit, 'internal', 'no audit log')
  -- The free-text term goes DOWN into the backward scanner alongside the other
  -- filters, so it narrows the log rather than the page: filtering afterwards
  -- meant a search missed every match outside the page the scanner happened to
  -- return, and still reported a nextCursor, so the viewer could not tell "no
  -- matches" from "no matches on this page".
  local res, e = self.audit:query{
    actor = str(args.actor, 64), action = str(args.action, 64),
    actionPrefix = str(args.actionPrefix, 64), outcome = str(args.outcome, 16),
    q = str(args.q, 200),
    from = tonumber(args.from), to = tonumber(args.to),
    cursor = args.cursor, limit = math.min(tonumber(args.limit) or 100, 500),
  }
  if not res then err('bad-request', tostring(e)) end
  local rows = res.rows or {}
  local actors = { 'system' }
  for _, u in ipairs(self.model.users:list()) do actors[#actors + 1] = u.name end
  table.sort(actors)
  local actions, seen = {}, {}
  for _, a in ipairs(require('hub.audit').ACTIONS or {}) do
    if not seen[a] then seen[a] = true; actions[#actions + 1] = a end
  end
  -- actions this layer emits that are not in audit.ACTIONS' base vocabulary
  for _, a in ipairs{ 'user.update', 'user.canExec', 'instance.say', 'proxy.test' } do
    if not seen[a] then seen[a] = true; actions[#actions + 1] = a end
  end
  table.sort(actions)
  -- `total` used to be #rows AFTER filtering, which is neither the number of
  -- matches nor the page size.  It is the true match count only when the scan
  -- reached the end of the log (no cursor left); otherwise it is absent and the
  -- panel shows the page count it can actually justify.
  return { rows = rows, nextCursor = res.nextCursor,
           total = (res.nextCursor == nil) and #rows or nil,
           count = #rows, complete = (res.nextCursor == nil),
           scanned = res.scanned, files = res.files, actors = actors, actions = actions }
end

-- ================================================================= dispatch ==
--- Run one command.  `done(ok, resultOrError)` is called exactly once, possibly
--- from a later reactor turn (worker passthrough, proxy test).
function A:dispatch(cmd, args, ctx, done)
  cmd = tostring(cmd or '')
  args = type(args) == 'table' and args or {}
  local answered = false
  local function reply(ok, payload)
    if answered then return end
    answered = true
    done(ok, payload)
  end

  local fn = H[cmd]
  if not fn then
    return reply(false, { code = 'unknown-command', message = 'no such command: ' .. cmd })
  end
  if not PUBLIC[cmd] and not ctx.user then
    return reply(false, { code = 'unauthorized', message = 'not signed in' })
  end
  if ADMIN_ONLY[cmd] and (not ctx.user or ctx.user.role ~= 'admin') then
    -- audited: a refused admin route is exactly what the log is for
    self:record(ctx, cmd, '', 'denied', 'role=' .. tostring(ctx.user and ctx.user.role or 'none'))
    return reply(false, { code = 'forbidden', message = 'administrators only' })
  end
  if EXEC_CAPABILITY[cmd] and not self:mayExec(ctx.user) then
    self:record(ctx, cmd, '', 'denied',
                'remote Lua is not granted to this account (role=' ..
                tostring(ctx.user and ctx.user.role or 'none') .. ')')
    return reply(false, { code = 'forbidden',
      message = 'running Lua on a worker is administrator-only; ' ..
                'an administrator can grant this account the canExec capability' })
  end
  if ctx.user and ctx.user.disabled then
    return reply(false, { code = 'forbidden', message = 'this account is disabled' })
  end

  local ok, res = pcall(fn, self, args, ctx, function(k, v) reply(k, v) end)
  if not ok then
    if type(res) == 'table' and res.code then
      -- A cross-tenant probe -- deleting, patching or reading somebody else's
      -- instance, account, character or script -- is raised by the owned*
      -- helpers BEFORE any handler reaches record(), so it used to leave no
      -- trace at all.  A refused admin route was logged and the more
      -- interesting signal was not.  One record per refused mutating command,
      -- naming the id that was asked for.
      if AUDITED_REFUSAL[res.code] and isMutating(cmd) then
        local target = args.id or (type(args.ids) == 'table' and args.ids[1]) or ''
        pcall(function()
          self:record(ctx, cmd, tostring(target), 'denied',
                      tostring(res.code) .. ': ' .. tostring(res.message or ''))
        end)
      end
      return reply(false, res)
    end
    self.log.error('hub.api: %s crashed: %s', cmd, tostring(res))
    return reply(false, { code = 'internal', message = 'internal error' })
  end
  if res == M.PENDING then return end
  return reply(true, res or {})
end

-- =============================================================== REST routing
--[[
The panel (panel/api.js) speaks REST, not an RPC envelope: one path per resource,
the HTTP verb carries the intent, and the id is a path segment.  That is the more
natural shape for a UI, so the hub matches it here and the command layer above is
left untouched -- POST /api/rpc still works and hub/api.lua's handler names are
still the audit vocabulary.

Each route says which handler answers it and how to fold the path parameters, the
query string and the JSON body into that handler's `args`.  `cmd` may be a
function when one path fans out over several handlers (POST /api/instances/actions).
]]

local function segments(path)
  local out = {}
  for seg in tostring(path or ''):gmatch('[^/]+') do out[#out + 1] = seg end
  return out
end

--- Percent-decode one path segment.  '+' is NOT a space in a path.
local function unpct(s)
  return (tostring(s):gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

-- id + patch: the REST body IS the patch
local function idPatch(p, q, body)
  local patch = {}
  for k, v in pairs(body or {}) do patch[k] = v end
  return { id = p.id, patch = patch }
end

local function idBody(p, q, body)
  local args = {}
  for k, v in pairs(body or {}) do args[k] = v end
  for k, v in pairs(q or {}) do if args[k] == nil then args[k] = v end end
  for k, v in pairs(p or {}) do args[k] = v end
  return args
end

local function bodyOnly(p, q, body)
  local args = {}
  for k, v in pairs(body or {}) do args[k] = v end
  return args
end

local function queryOnly(p, q, body)
  local args = {}
  for k, v in pairs(q or {}) do args[k] = v end
  return args
end

local ACTION_CMD = { start = 'instance.start', stop = 'instance.stop',
                     restart = 'instance.restart', botEnable = 'instance.botEnable' }

local ROUTES = {
  -- session & bootstrap
  { 'GET',    '/api/session',                'auth.session' },
  { 'POST',   '/api/session',                'auth.login',          bodyOnly },
  { 'DELETE', '/api/session',                'auth.logout' },
  { 'POST',   '/api/session/password',       'auth.changePassword', bodyOnly },
  { 'POST',   '/api/bootstrap',              'auth.bootstrap',      bodyOnly },

  -- instances
  { 'GET',    '/api/instances',              'instance.list' },
  { 'POST',   '/api/instances',              'instance.create',     bodyOnly },
  { 'POST',   '/api/instances/actions',
    function(p, q, body)
      local a = tostring((body or {}).action or '')
      if not ACTION_CMD[a] then err('bad-request', 'unknown action: ' .. a) end
      return ACTION_CMD[a]
    end, bodyOnly },
  { 'GET',    '/api/instances/:id',          'instance.get',        idBody },
  { 'PATCH',  '/api/instances/:id',          'instance.update',     idPatch },
  { 'DELETE', '/api/instances/:id',          'instance.delete',     idBody },
  { 'GET',    '/api/instances/:id/configs',  'instance.configs',    idBody },
  { 'PUT',    '/api/instances/:id/macros/:name', 'instance.setMacro', idBody },
  { 'POST',   '/api/instances/:id/reload',   'instance.reload',     idBody },
  { 'POST',   '/api/instances/:id/exec',     'instance.exec',       idBody },
  { 'GET',    '/api/instances/:id/history',  'instance.history',    idBody },
  { 'GET',    '/api/instances/:id/logs',     'instance.logs',       idBody },
  { 'GET',    '/api/instances/:id/chat',     'instance.chat',       idBody },
  { 'POST',   '/api/instances/:id/chat',     'instance.say',        idBody },

  -- game accounts
  { 'GET',    '/api/accounts',               'account.list' },
  { 'POST',   '/api/accounts',               'account.create',      bodyOnly },
  { 'PATCH',  '/api/accounts/:id',           'account.update',      idPatch },
  { 'DELETE', '/api/accounts/:id',           'account.delete',      idBody },

  -- characters
  { 'GET',    '/api/characters',             'character.list' },
  { 'POST',   '/api/characters',             'character.create',    bodyOnly },
  { 'DELETE', '/api/characters/:id',         'character.delete',    idBody },

  -- proxies
  { 'GET',    '/api/proxies',                'proxy.list' },
  { 'POST',   '/api/proxies',                'proxy.create',        bodyOnly },
  { 'PATCH',  '/api/proxies/:id',            'proxy.update',        idPatch },
  { 'DELETE', '/api/proxies/:id',            'proxy.delete',        idBody },
  { 'POST',   '/api/proxies/:id/test',       'proxy.test',          idBody },

  -- scripts
  { 'GET',    '/api/scripts',                'script.list' },
  { 'POST',   '/api/scripts',                'script.upload',       bodyOnly },
  { 'GET',    '/api/scripts/:id',            'script.get',          idBody },
  { 'DELETE', '/api/scripts/:id',            'script.delete',       idBody },
  { 'PUT',    '/api/scripts/:id/assignments','script.assign',       idBody },

  -- admin
  { 'GET',    '/api/admin/users',            'admin.users' },
  { 'POST',   '/api/admin/users',            'admin.userCreate',    bodyOnly },
  { 'PATCH',  '/api/admin/users/:id',        'admin.userUpdate',    idPatch },
  { 'DELETE', '/api/admin/users/:id',        'admin.userDelete',    idBody },
  { 'POST',   '/api/admin/users/:id/password', 'admin.userResetPassword', idBody },
  { 'GET',    '/api/admin/sessions',         'admin.sessions' },
  { 'DELETE', '/api/admin/sessions/:id',     'admin.sessionRevoke', idBody },
  { 'GET',    '/api/admin/audit',            'admin.audit',         queryOnly },
}

-- compile the templates once
local COMPILED = {}
for _, r in ipairs(ROUTES) do
  COMPILED[#COMPILED + 1] = { method = r[1], segs = segments(r[2]),
                              template = r[2], cmd = r[3], map = r[4] }
end
M.ROUTES = ROUTES

--- Every REST path the panel may call, as 'METHOD /path' -- the contract, in one
--- place, so a test can assert both directions of coverage.
function M.restRoutes()
  local out = {}
  for _, r in ipairs(ROUTES) do out[#out + 1] = r[1] .. ' ' .. r[2] end
  table.sort(out)
  return out
end

--- Resolve one REST request.
---   method  'GET' | 'POST' | ...
---   path    the request path, already without the query string
---   query   decoded query table (or nil)
---   body    decoded JSON body table (or nil)
--- Returns  cmd, args, nil, nil, template   on a match
---          nil, nil, 405, allowedVerbs     when the path exists under another verb
---          nil                             when nothing matches
function M.resolveRest(method, path, query, body)
  method = tostring(method or 'GET'):upper()
  local want = segments(path)
  local pathMatched, allowed = false, {}
  for _, r in ipairs(COMPILED) do
    if #r.segs == #want then
      local params, ok = {}, true
      for i = 1, #r.segs do
        local seg = r.segs[i]
        if seg:sub(1, 1) == ':' then
          params[seg:sub(2)] = unpct(want[i])
        elseif seg ~= want[i] then
          ok = false
          break
        end
      end
      if ok then
        pathMatched = true
        if r.method == method then
          local cmd = r.cmd
          if type(cmd) == 'function' then cmd = cmd(params, query, body) end
          local args = r.map and r.map(params, query, body) or params
          return cmd, args, nil, nil, r.template
        end
        allowed[#allowed + 1] = r.method
      end
    end
  end
  if pathMatched then return nil, nil, 405, table.concat(allowed, ', ') end
  return nil
end

--- The HTTP status one of this layer's error codes deserves.
M.STATUS = {
  ['bad-request'] = 400, ['unauthorized'] = 401, ['forbidden'] = 403,
  ['not-found'] = 404, ['unknown-command'] = 404, ['conflict'] = 409,
  ['too-large'] = 413, ['rate-limited'] = 429, ['csrf-invalid'] = 403,
  ['internal'] = 500,
}
function M.statusFor(code) return M.STATUS[tostring(code or '')] or 400 end

return M
