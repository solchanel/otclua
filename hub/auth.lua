-- hub/auth.lua -- web accounts, password hashing, sessions, login rate limiting, the first-run
-- bootstrap, and the encrypt/decrypt of stored game-account and proxy passwords.
--
-- PANEL.md's authorisation section, implemented.  Everything that touches a credential lives
-- here; the API layer above must never reach past it into hub/model.lua for a pwhash or a
-- password(enc) field.
--
-- ============================================================================================
-- PASSWORDS
-- ============================================================================================
-- PBKDF2-HMAC-SHA256, per-user random salt, 200,000 iterations by default (lib/pbkdf2.lua's
-- DEFAULT_ITERATIONS, which PANEL.md's ">= 200k" pins), stored as
-- `pbkdf2$sha256$<iter>$<salt_b64>$<hash_b64>`.  Nothing here ever logs, returns or copies a
-- plaintext password into a data structure that outlives the call.
--
-- The login path calls pbkdf2.verifyOrDummy() and does NOT branch on account existence before
-- it.  That matters more than it looks: plain verify() returns in microseconds for a missing or
-- unparsable stored hash and in ~270 ms for a real one, so the obvious `verify(pw, u and
-- u.pwhash or '')` is a user-enumeration oracle that no amount of per-account rate limiting can
-- close.  test/hubcoresuite.lua measures both paths and fails if they diverge.
--
-- Cost note (lib/pbkdf2.lua, COST): a verification is ~270 ms of UNINTERRUPTIBLE work on a
-- single-threaded reactor.  auth.lua deliberately does not queue for you -- the HTTP layer must
-- serialise /login behind a concurrency-1 queue with a short backlog cap, or a handful of
-- concurrent login attempts is a self-inflicted denial of service.  `auth.LOGIN_COST_HINT_MS`
-- is exported so that layer can size its cap.
--
-- ============================================================================================
-- SESSIONS
-- ============================================================================================
-- A token is 32 bytes from the OS CSPRNG, handed to the caller once as 64 hex characters (the
-- HttpOnly cookie value).  Only SHA-256(token) is kept in memory, so the process never holds a
-- value that could be replayed if it were dumped, and a session lookup is a hash-table hit on
-- the digest.
--
-- Sessions are IN MEMORY only, and that is a decision, not an omission: PANEL.md's data model
-- has no sessions.json, a hub restart is exactly when you want every session invalidated, and
-- persisting them would put a bearer credential on disk for no gain.  Restarting the hub logs
-- everyone out.
--
-- Expiry is sliding (`idleMs`, default 8 h, refreshed on every authenticated request) under a
-- hard ceiling (`absoluteMs`, default 7 days) that sliding cannot extend.  revoke() kills one
-- session, revokeUser() kills every session of one account (what "revocable by the admin" and
-- "delete the account" both need), and a disabled or deleted user fails authentication on the
-- next request even if the token has not expired.
--
-- ============================================================================================
-- RATE LIMITING
-- ============================================================================================
-- Two counters with DIFFERENT jobs.
--
--   NAME (lower-cased, `maxFails` = 5).  Reaching it locks that ACCOUNT for `lockoutMs`, and the
--   lock is checked before the password is verified.  Locking the account is the useful half:
--   it costs an attacker the account they are guessing at and nothing else.
--
--   SOURCE IP (`ipMaxFails` = 50).  A THROTTLE, not a lock, and it is consulted only AFTER the
--   password has been checked and found wrong.  A correct credential is therefore never refused
--   because of the address it arrived from.  That matters because PANEL.md's supported
--   deployment puts nginx/Caddy or an SSH tunnel in front and the hub deliberately does not
--   trust X-Forwarded-For unless the peer is a configured front end, so without this split five
--   bad guesses by any anonymous visitor locked every account on the panel, administrator
--   included.
--
-- The account counter is keyed by the SUBMITTED NAME rather than by a resolved user id, on
-- purpose: keying it by user id would mean a name that does not exist can never lock out, and
-- "this name locks after 5 tries, that one never does" is the same enumeration oracle the
-- constant-cost verify was there to close.
--
-- Neither counter bounds the COST of a login: one verification is ~270 ms of uninterruptible
-- reactor time whether it succeeds or fails.  hub/server.lua serialises the login route behind
-- a one-at-a-time queue with a bounded backlog for that, and answers 429 past it.
--
-- A successful login clears both counters for that pair.  sweep() drops expired entries and
-- must be called from a timer (the hub's housekeeping tick); without it the tables grow with
-- one small entry per distinct attacking IP.
--
-- ============================================================================================
-- SECRETS AT REST
-- ============================================================================================
-- Game-account and proxy passwords are sealed with lib/authsecret.lua before they reach
-- hub/model.lua, with the associated data bound to the slot ("accounts:<id>:password"), so a
-- ciphertext copied from one row to another fails to authenticate rather than silently
-- decrypting into the wrong account.  They are opened only by openAccountPassword() /
-- openProxyPassword(), which the supervisor calls at the moment it launches a worker.  Note
-- lib/process.lua REFUSES a secret in argv; the plaintext must be handed to the child on stdin.
--
-- ============================================================================================
-- FIRST RUN
-- ============================================================================================
-- With no users on disk, auth is in BOOTSTRAP state: needsBootstrap() is true, bootstrapToken()
-- returns a fresh 32-byte token for the hub to print to stdout, and login()/authenticate() and
-- every account mutation refuse with the code 'bootstrap'.  createFirstAdmin(token, name, pw)
-- compares the token in constant time and, on success, creates the sole admin and leaves
-- bootstrap state for good.  The token exists only in this process: restarting the hub before
-- the first admin is created mints a new one and invalidates the old.  Wrong tokens are counted
-- and after `bootstrapAttempts` (default 5) the flow is dead until the hub is restarted, so the
-- token cannot be ground down by a script.
--
-- ============================================================================================
-- API
-- ============================================================================================
--   auth.open{ db=, secret=, log=, now=, iterations=, idleMs=, absoluteMs=,
--              maxFails=, windowMs=, lockoutMs=, bootstrapAttempts= } -> a | nil, err
--   a:needsBootstrap()                     -> boolean
--   a:bootstrapToken()                     -> token | nil        (print this to stdout, once)
--   a:createFirstAdmin(token, name, pw)    -> user | nil, err, code
--   a:createUser(name, pw, role)           -> user | nil, err
--   a:setPassword(userId, pw)              -> true | nil, err    (revokes that user's sessions)
--   a:setRole(userId, role) / a:setDisabled(userId, bool)
--   a:deleteUser(userId [, opts])          -> true | nil, err
--   a:login(name, pw, ip [, userAgent])    -> token, user | nil, err, code
--        code: 'bootstrap' | 'locked' | 'denied'
--   a:authenticate(token [, ip])           -> session, user | nil, err, code
--   a:logout(token)                        -> true
--   a:revoke(sessionId) / a:revokeUser(userId) -> n
--   a:sessions([userId])                   -> array of public session views (no tokens)
--   a:sweep()                              -> {sessions=, limiters=}   call from a timer
--   a:limitState(name, ip)                 -> {locked=, retryInMs=, nameFails=, ipFails=}
--   a:sealAccountPassword(accountId, pw)   -> record | nil, err
--   a:openAccountPassword(accountId)       -> plaintext | nil, err
--   a:sealProxyPassword(proxyId, pw) / a:openProxyPassword(proxyId)
--   a:sealFor(kind, id, field, plaintext) / a:openFor(kind, id, field, record)

local pbkdf2  = require('lib.pbkdf2')
local sha2    = require('lib.sha2')
local sys     = require('lib.sys')
local storage = require('hub.storage')
local model   = require('hub.model')

local sformat, slower, ssub, sbyte = string.format, string.lower, string.sub, string.byte
local floor, min = math.floor, math.min

local M = {}

M.LOGIN_COST_HINT_MS   = 300          -- one verify at DEFAULT_ITERATIONS; see lib/pbkdf2 COST
M.DEFAULT_IDLE_MS      = 8 * 3600 * 1000
M.DEFAULT_ABSOLUTE_MS  = 7 * 24 * 3600 * 1000
M.DEFAULT_MAX_FAILS    = 5
-- The per-IP bucket is a THROTTLE, not a lock, and its threshold is an order of
-- magnitude looser than the per-account one: under the deployment PANEL.md
-- supports (nginx/Caddy or an SSH tunnel in front) every request shares one
-- source address, so a low per-IP lock let five bad guesses by any anonymous
-- visitor lock the entire panel -- administrator included.
M.DEFAULT_IP_MAX_FAILS = 50
M.DEFAULT_WINDOW_MS    = 15 * 60 * 1000
M.DEFAULT_LOCKOUT_MS   = 15 * 60 * 1000
M.TOKEN_BYTES          = 32
M.MIN_PASSWORD         = 8
M.MAX_PASSWORD         = 1024

local nullLog = { info = function() end, warn = function() end, error = function() end,
                  debug = function() end }

-- =================================================================== helpers

local function hex(s)
  local out = {}
  for i = 1, #s do out[i] = sformat('%02x', sbyte(s, i)) end
  return table.concat(out)
end

--- Length-independent-ish constant-time compare.  Lua cannot promise constant time (see the
--- note in lib/authsecret.lua), but this never returns early on a byte mismatch, which is the
--- part that would otherwise be a trivial oracle.
local function ctEq(a, b)
  if type(a) ~= 'string' or type(b) ~= 'string' then return false end
  local diff = #a ~= #b and 1 or 0
  local n = min(#a, #b)
  for i = 1, n do
    local x = sbyte(a, i)
    local y = sbyte(b, i)
    diff = diff + ((x == y) and 0 or 1)
  end
  return diff == 0
end
M._ctEq = ctEq

local function checkPassword(pw)
  if type(pw) ~= 'string' then return nil, 'password must be a string' end
  if #pw < M.MIN_PASSWORD then
    return nil, sformat('password must be at least %d characters', M.MIN_PASSWORD)
  end
  if #pw > M.MAX_PASSWORD then return nil, 'password is too long' end
  if pw:find('[%z]') then return nil, 'password must not contain a NUL byte' end
  return true
end

-- ====================================================================== Auth

local Auth = {}
Auth.__index = Auth

function M.open(opts)
  opts = opts or {}
  local db = opts.db
  if type(db) ~= 'table' or type(db.list) ~= 'function' then
    return nil, 'auth.open: opts.db (a hub/model db) is required'
  end
  local self = setmetatable({
    db           = db,
    secret       = opts.secret,
    log          = opts.log or nullLog,
    now          = opts.now or storage.wallMs,
    iterations   = tonumber(opts.iterations) or pbkdf2.DEFAULT_ITERATIONS,
    idleMs       = tonumber(opts.idleMs) or M.DEFAULT_IDLE_MS,
    absoluteMs   = tonumber(opts.absoluteMs) or M.DEFAULT_ABSOLUTE_MS,
    maxFails     = tonumber(opts.maxFails) or M.DEFAULT_MAX_FAILS,
    ipMaxFails   = tonumber(opts.ipMaxFails) or M.DEFAULT_IP_MAX_FAILS,
    windowMs     = tonumber(opts.windowMs) or M.DEFAULT_WINDOW_MS,
    lockoutMs    = tonumber(opts.lockoutMs) or M.DEFAULT_LOCKOUT_MS,
    bootstrapMax = tonumber(opts.bootstrapAttempts) or 5,

    byHash       = {},    -- SHA-256(token) -> session
    byId         = {},    -- sessionId -> session
    fails        = { name = {}, ip = {} },
    bootstrapTries = 0,
  }, Auth)

  if self:_userCount() == 0 then
    self.bootstrap = hex(sys.randomBytes(M.TOKEN_BYTES))
  end
  return self
end

function Auth:_userCount() return self.db:count('users') end

function Auth:_userByName(name)
  if type(name) ~= 'string' then return nil end
  return self.db:findBy('users', 'name', name, true)
end

-- ================================================================= bootstrap

function Auth:needsBootstrap() return self.bootstrap ~= nil end

--- The one-time token, for the hub to print to stdout.  It stays available until the first
--- admin exists (the operator may need to scroll back), and vanishes the moment it is used.
function Auth:bootstrapToken() return self.bootstrap end

function Auth:createFirstAdmin(token, name, password)
  if not self.bootstrap then return nil, 'the hub is already set up', 'done' end
  if self.bootstrapTries >= self.bootstrapMax then
    return nil, 'too many bootstrap attempts -- restart the hub for a new token', 'locked'
  end
  self.bootstrapTries = self.bootstrapTries + 1
  if not ctEq(tostring(token or ''), self.bootstrap) then
    self.log.warn('auth: bootstrap token rejected (%d/%d)', self.bootstrapTries, self.bootstrapMax)
    return nil, 'invalid bootstrap token', 'denied'
  end
  -- Race guard: another path may have created a user between open() and here.
  if self:_userCount() > 0 then
    self.bootstrap = nil
    return nil, 'the hub is already set up', 'done'
  end
  local user, err = self:_createUser(name, password, 'admin')
  if not user then return nil, err, 'invalid' end
  self.bootstrap = nil
  self.bootstrapTries = 0
  self.log.info('auth: bootstrap complete, administrator %q created', user.name)
  return user
end

-- ================================================================== accounts

function Auth:_createUser(name, password, role)
  local pok, perr = checkPassword(password)
  if not pok then return nil, perr end
  if role ~= 'admin' and role ~= 'user' then return nil, 'role must be admin or user' end
  local hash = pbkdf2.hash(password, { iterations = self.iterations })
  local user, err = self.db:insert('users', {
    name = name, role = role, pwhash = hash, createdAt = self.now(), disabled = false,
  })
  if not user then return nil, err end
  return user
end

function Auth:createUser(name, password, role)
  if self:needsBootstrap() then
    return nil, 'the hub is not set up yet', 'bootstrap'
  end
  return self:_createUser(name, password, role or 'user')
end

function Auth:setPassword(userId, password)
  if self:needsBootstrap() then return nil, 'the hub is not set up yet', 'bootstrap' end
  local user = self.db:get('users', userId)
  if not user then return nil, 'no such account' end
  local pok, perr = checkPassword(password)
  if not pok then return nil, perr end
  local hash = pbkdf2.hash(password, { iterations = self.iterations })
  local ok, err = self.db:update('users', userId, { pwhash = hash })
  if not ok then return nil, err end
  -- A password change must not leave old sessions alive: that is the whole point of a reset.
  self:revokeUser(userId)
  self:_clearFails(slower(user.name), nil)
  return true
end

function Auth:setRole(userId, role)
  if role ~= 'admin' and role ~= 'user' then return nil, 'role must be admin or user' end
  local user = self.db:get('users', userId)
  if not user then return nil, 'no such account' end
  if user.role == 'admin' and role ~= 'admin' and self:_adminCount() <= 1 then
    return nil, 'this is the last administrator'
  end
  return self.db:update('users', userId, { role = role })
end

--- Grant or revoke the remote-Lua capability.  It is admin-equivalent in effect
--- (the code runs unsandboxed under the hub's uid), so it lives beside setRole
--- rather than in the API layer, and every change is audited by the caller.
function Auth:setCanExec(userId, allowed)
  local user = self.db:get('users', userId)
  if not user then return nil, 'no such account' end
  return self.db:update('users', userId, { canExec = allowed and true or false })
end

--- May this user run remote Lua?  An administrator always may.
function Auth:mayExec(user)
  if type(user) ~= 'table' then return false end
  if user.role == 'admin' then return true end
  return user.canExec == true
end

function Auth:setDisabled(userId, disabled)
  local user = self.db:get('users', userId)
  if not user then return nil, 'no such account' end
  if disabled and user.role == 'admin' and self:_adminCount() <= 1 then
    return nil, 'this is the last administrator'
  end
  local ok, err = self.db:update('users', userId, { disabled = disabled and true or false })
  if not ok then return nil, err end
  if disabled then self:revokeUser(userId) end
  return ok
end

function Auth:_adminCount()
  local n = 0
  local rows = self.db:list('users')
  for i = 1, #rows do
    if rows[i].role == 'admin' and not rows[i].disabled then n = n + 1 end
  end
  return n
end

function Auth:deleteUser(userId, opts)
  local user = self.db:get('users', userId)
  if not user then return nil, 'no such account' end
  if user.role == 'admin' and self:_adminCount() <= 1 then
    return nil, 'refusing to delete the last administrator'
  end
  local ok, err = self.db:delete('users', userId, opts)
  if not ok then return nil, err end
  self:revokeUser(userId)
  return true
end

-- ============================================================ rate limiting

local function bucketEntry(tbl, key, now, windowMs)
  local e = tbl[key]
  if not e then
    e = { count = 0, first = now, lockedUntil = nil }
    tbl[key] = e
  elseif not e.lockedUntil and (now - e.first) > windowMs then
    e.count, e.first = 0, now
  end
  return e
end

--- How long this ACCOUNT NAME is locked for, in ms (0 = not locked).
--- Deliberately the name only: see _ipThrottled.
function Auth:_lockedFor(key)
  local now = self.now()
  local n = self.fails.name[key]
  if n and n.lockedUntil and now < n.lockedUntil then return n.lockedUntil - now end
  return 0
end

--- Is this SOURCE ADDRESS over its (much looser) failure threshold?  This never
--- refuses a request on its own -- the caller consults it only after the
--- password has been checked and found wrong -- so a correct credential from a
--- busy shared address always signs in.
function Auth:_ipThrottled(ip)
  if not ip then return 0 end
  local now = self.now()
  local e = self.fails.ip[ip]
  if e and e.lockedUntil and now < e.lockedUntil then return e.lockedUntil - now end
  return 0
end

function Auth:_recordFail(key, ip)
  local now = self.now()
  local function bump(tbl, k, limit)
    if not k then return end
    local e = bucketEntry(tbl, k, now, self.windowMs)
    e.count = e.count + 1
    if e.count >= limit then
      e.lockedUntil = now + self.lockoutMs
      e.count = 0
      e.first = now
    end
  end
  bump(self.fails.name, key, self.maxFails)
  bump(self.fails.ip, ip, self.ipMaxFails)
end

function Auth:_clearFails(key, ip)
  if key then self.fails.name[key] = nil end
  if ip then self.fails.ip[ip] = nil end
end

function Auth:limitState(name, ip)
  local key = slower(tostring(name or ''))
  local n, i = self.fails.name[key], ip and self.fails.ip[ip]
  local retry = self:_lockedFor(key)
  local ipRetry = self:_ipThrottled(ip)
  return { locked = retry > 0, retryInMs = retry,
           ipThrottled = ipRetry > 0, ipRetryInMs = ipRetry,
           nameFails = n and n.count or 0, ipFails = i and i.count or 0 }
end

-- =================================================================== sessions

function Auth:_newSession(user, ip, userAgent)
  local raw   = sys.randomBytes(M.TOKEN_BYTES)
  local token = hex(raw)
  local now   = self.now()
  local sess = {
    id        = 'sess_' .. hex(sys.randomBytes(8)),
    hash      = sha2.sha256(token),
    userId    = user.id,
    name      = user.name,
    role      = user.role,
    ip        = tostring(ip or '-'),
    userAgent = ssub(tostring(userAgent or ''), 1, 256),
    createdAt = now,
    lastSeenAt = now,
    expiresAt = now + self.idleMs,
    deadline  = now + self.absoluteMs,
  }
  self.byHash[sess.hash] = sess
  self.byId[sess.id] = sess
  return token, sess
end

function Auth:_drop(sess)
  if not sess then return end
  self.byHash[sess.hash] = nil
  self.byId[sess.id] = nil
end

--- Look a token up and slide its expiry.  Returns session, user | nil, err, code.
function Auth:authenticate(token, ip)
  if self:needsBootstrap() then return nil, 'the hub is not set up yet', 'bootstrap' end
  if type(token) ~= 'string' or #token == 0 then return nil, 'no session', 'denied' end
  local sess = self.byHash[sha2.sha256(token)]
  if not sess then return nil, 'no session', 'denied' end
  local now = self.now()
  if now >= sess.expiresAt then
    self:_drop(sess)
    return nil, 'session expired', 'expired'
  end
  if now >= sess.deadline then
    self:_drop(sess)
    return nil, 'session reached its maximum lifetime', 'expired'
  end
  local user = self.db:get('users', sess.userId)
  if not user then
    self:_drop(sess)
    return nil, 'account no longer exists', 'denied'
  end
  if user.disabled then
    self:_drop(sess)
    return nil, 'account is disabled', 'denied'
  end
  sess.lastSeenAt = now
  -- Sliding, but never past the absolute deadline.
  local slid = now + self.idleMs
  sess.expiresAt = (slid < sess.deadline) and slid or sess.deadline
  sess.role = user.role
  sess.name = user.name
  if ip then sess.ip = tostring(ip) end
  return sess, user
end

function Auth:logout(token)
  if type(token) ~= 'string' then return true end
  self:_drop(self.byHash[sha2.sha256(token)])
  return true
end

function Auth:revoke(sessionId)
  local s = self.byId[sessionId]
  if not s then return 0 end
  self:_drop(s)
  return 1
end

function Auth:revokeUser(userId)
  local n = 0
  for _, s in pairs(self.byId) do
    if s.userId == userId then self:_drop(s); n = n + 1 end
  end
  return n
end

--- Public view of the live sessions.  Deliberately free of `hash`: a session listing is shown
--- in the admin UI and must not be able to leak anything replayable.
function Auth:sessions(userId)
  local out = {}
  for _, s in pairs(self.byId) do
    if not userId or s.userId == userId then
      out[#out + 1] = { id = s.id, userId = s.userId, name = s.name, role = s.role, ip = s.ip,
                        userAgent = s.userAgent, createdAt = s.createdAt,
                        lastSeenAt = s.lastSeenAt, expiresAt = s.expiresAt }
    end
  end
  table.sort(out, function (a, b) return a.createdAt < b.createdAt end)
  return out
end
Auth.sessionList = Auth.sessions

--- Drop expired sessions and stale limiter entries.  Cheap; call it once a minute.
function Auth:sweep()
  local now, ns, nl = self.now(), 0, 0
  for _, s in pairs(self.byId) do
    if now >= s.expiresAt or now >= s.deadline then self:_drop(s); ns = ns + 1 end
  end
  local horizon = self.windowMs + self.lockoutMs
  for _, tbl in pairs(self.fails) do
    for k, e in pairs(tbl) do
      local dead = (not e.lockedUntil) and ((now - e.first) > horizon)
      if e.lockedUntil and now >= e.lockedUntil then dead = true end
      if dead then tbl[k] = nil; nl = nl + 1 end
    end
  end
  return { sessions = ns, limiters = nl }
end

-- ====================================================================== login

--- The one path that must not leak anything by timing or by branch order.
function Auth:login(name, password, ip, userAgent)
  if self:needsBootstrap() then
    return nil, 'the hub is not set up yet', 'bootstrap'
  end
  local key = slower(tostring(name or ''))
  ip = ip and tostring(ip) or nil

  -- The ACCOUNT lock is checked first and refuses outright: it is keyed by the
  -- submitted name, so it costs an attacker one account, not the panel.
  local retry = self:_lockedFor(key)
  if retry > 0 then
    return nil, sformat('too many failed attempts for that account -- try again in %d s',
                        floor(retry / 1000) + 1), 'locked'
  end

  -- No early return on "no such user": verifyOrDummy burns an identical derivation either way.
  local user   = self:_userByName(key)
  local stored = user and user.pwhash or nil
  local passOk = pbkdf2.verifyOrDummy(password, stored)

  if not passOk or not user or user.disabled then
    self:_recordFail(key, ip)
    -- The per-IP bucket is consulted only HERE, on a wrong credential.  A
    -- correct one is never refused because of the address it came from -- which
    -- is what made the old bucket an office-wide lockout switch, and what made a
    -- reverse proxy in front of the hub a single point of denial.
    local ipRetry = self:_ipThrottled(ip)
    if ipRetry > 0 then
      return nil, sformat('too many failed attempts from this address -- try again in %d s',
                          floor(ipRetry / 1000) + 1), 'rate-limited'
    end
    return nil, 'invalid name or password', 'denied'
  end

  self:_clearFails(key, ip)

  -- Opportunistic upgrade: a hash below the current cost is re-derived while we hold the
  -- plaintext.  Failure here must not fail the login.
  if pbkdf2.needsRehash(user.pwhash, { iterations = self.iterations }) then
    local ok = pcall(function ()
      self.db:update('users', user.id, { pwhash = pbkdf2.hash(password, {
        iterations = self.iterations }) })
    end)
    if ok then self.log.info('auth: re-hashed %q at the current cost', user.name) end
  end

  -- Stamp the successful login on the row: the admin screen's LAST LOGIN column
  -- reads it, and it is the cheapest signal that an account has gone unused.
  -- A failure to persist it must never fail the login itself.
  local stamped = pcall(function()
    return self.db:update('users', user.id, { lastLoginAt = self.now() })
  end)
  if stamped then user = self.db:get('users', user.id) or user end

  local token = self:_newSession(user, ip, userAgent)
  return token, user
end

--- Prove a password for an account we ALREADY know, at the same constant cost as
--- login() and without touching either limiter or minting a session.
---
--- The self-service password change needs exactly this: proving the current
--- password by calling login() ran the real rate limiter, so five mistyped
--- entries in a settings form locked the user out of the panel for fifteen
--- minutes (and, before the limiter split above, everybody else at that address
--- with them).  A form should not be able to lock the account it belongs to.
--- Callers that want to bound retries should count them themselves.
function Auth:verifyPassword(userId, password)
  local user = self.db:get('users', tostring(userId or ''))
  local stored = user and user.pwhash or nil
  -- verifyOrDummy, not verify: the cost must not depend on whether the row or
  -- its hash exists, exactly as in login().
  local ok = pbkdf2.verifyOrDummy(password, stored)
  if not ok or not user or user.disabled then return false end
  return true
end

-- ============================================================ secrets at rest

function Auth:_aad(kind, id, field)
  return sformat('%s:%s:%s', kind, tostring(id), field)
end

function Auth:sealFor(kind, id, field, plaintext)
  if not self.secret then return nil, 'auth: no secret box is attached' end
  if type(plaintext) ~= 'string' then return nil, 'a string is required' end
  if #plaintext > 4096 then return nil, 'value is too long to seal' end
  return self.secret:encrypt(plaintext, self:_aad(kind, id, field))
end

function Auth:openFor(kind, id, field, record)
  if not self.secret then return nil, 'auth: no secret box is attached' end
  if type(record) ~= 'string' then return nil, 'no sealed value' end
  return self.secret:decrypt(record, self:_aad(kind, id, field))
end

local function sealInto(self, kind, field, id, plaintext)
  local row = self.db:get(kind, id)
  if not row then return nil, kind .. ' ' .. tostring(id) .. ' not found' end
  if plaintext == nil or plaintext == '' then
    local ok, err = self.db:update(kind, id, { [field] = model.NIL })
    if not ok then return nil, err end
    return true
  end
  local rec, err = self:sealFor(kind, id, field, plaintext)
  if not rec then return nil, err end
  local ok, uerr = self.db:update(kind, id, { [field] = rec })
  if not ok then return nil, uerr end
  return rec
end

local function openFrom(self, kind, field, id)
  local row = self.db:get(kind, id)
  if not row then return nil, kind .. ' ' .. tostring(id) .. ' not found' end
  if row[field] == nil then return nil, 'no ' .. field .. ' is stored' end
  return self:openFor(kind, id, field, row[field])
end

function Auth:sealAccountPassword(accountId, pw) return sealInto(self, 'accounts', 'password', accountId, pw) end
function Auth:openAccountPassword(accountId)     return openFrom(self, 'accounts', 'password', accountId) end
function Auth:sealAccountToken2fa(accountId, tk) return sealInto(self, 'accounts', 'token2fa', accountId, tk) end
function Auth:openAccountToken2fa(accountId)     return openFrom(self, 'accounts', 'token2fa', accountId) end
function Auth:sealProxyPassword(proxyId, pw)     return sealInto(self, 'proxies', 'pass', proxyId, pw) end
function Auth:openProxyPassword(proxyId)         return openFrom(self, 'proxies', 'pass', proxyId) end

return M
