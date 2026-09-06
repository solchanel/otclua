--[[============================================================================
panel/devhub.lua -- a TEST FIXTURE, not the hub.

The real hub is work item B3 (`hub/`).  This file exists so the panel can be
developed and proved against a real HTTP server, a real cookie, a real CSRF
header and a real WebSocket instead of only against the in-page mock: it serves
panel/ statically and answers exactly the endpoint table in panel/api.js with
in-memory data and a small fleet simulator.

    luajit panel/devhub.lua [--port=8777] [--host=127.0.0.1] [--fleet=8]

It prints a one-time bootstrap token, exactly as PANEL.md says the hub must on
first run; open http://127.0.0.1:8777/, paste it, and choose an administrator
password.  Nothing here ever prints or stores a password in clear: the password
is hashed with lib/pbkdf2.lua the moment it arrives and only the hash is kept.

What it is NOT: durable (everything is in RAM and dies with the process), a
supervisor (no worker is spawned; the numbers are simulated), or rate limited.
Do not expose it.  It binds 127.0.0.1 and refuses anything else.

Run it on both target systems the same way:
    luajit panel/devhub.lua --port=8777
    wsl -d Debian -e sh -c 'cd /mnt/d/... && luajit panel/devhub.lua --port=8777'
============================================================================]]

local scriptPath = (arg and arg[0]) or 'panel/devhub.lua'
local scriptDir  = scriptPath:match('^(.*)[/\\][^/\\]*$') or '.'
local ROOT       = scriptDir:match('^(.*)[/\\][^/\\]*$') or '.'
package.path = ROOT .. '/?.lua;' .. ROOT .. '/?/init.lua;' .. package.path

local sched      = require('lib.sched')
local httpserver = require('lib.httpserver')
local wsserver   = require('lib.wsserver')
local json       = require('lib.json')
local sys        = require('lib.sys')
local pbkdf2     = require('lib.pbkdf2')

-- ================================================================== flags ====

local OPT = { port = 8777, host = '127.0.0.1', fleet = 8 }
for i = 1, #(arg or {}) do
  local k, v = tostring(arg[i]):match('^%-%-([%w%-]+)=?(.*)$')
  if k == 'port' then OPT.port = tonumber(v) or OPT.port
  elseif k == 'host' then OPT.host = v
  elseif k == 'fleet' then OPT.fleet = tonumber(v) or OPT.fleet
  elseif k == 'selftest' then OPT.selftest = true
  end
end
if OPT.host ~= '127.0.0.1' and OPT.host ~= 'localhost' then
  io.stderr:write('devhub: refusing to bind ' .. OPT.host .. '; this fixture is loopback only\n')
  os.exit(2)
end

-- ================================================================= helpers ===

local function nowMs() return math.floor(os.time() * 1000) end
local function hex(s) return (s:gsub('.', function (c) return string.format('%02x', c:byte()) end)) end
local function token(n) return hex(sys.randomBytes(n or 24)) end
local function uid(p) return p .. '_' .. hex(sys.randomBytes(4)) end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b else return v end end
local function round(v) return math.floor(v + 0.5) end
local function copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = (type(v) == 'table') and copy(v) or v end
  return o
end
local function find(list, id)
  for i = 1, #list do if list[i].id == id then return list[i], i end end
  return nil
end
local function removeById(list, id)
  local _, at = find(list, id)
  if at then table.remove(list, at) end
end
local function map(list, fn)
  local o = {}
  for i = 1, #list do o[#o + 1] = fn(list[i]) end
  return o
end
local function filter(list, fn)
  local o = {}
  for i = 1, #list do if fn(list[i]) then o[#o + 1] = list[i] end end
  return o
end

-- An "empty" JSON object.  rxi's json.lua encodes an empty Lua table as `[]`,
-- which is not what `{}` means in the contract, so nothing here ever returns a
-- bare empty table.  (The hub has to make the same choice -- see the report.)
local function OKAY() return { ok = true } end

-- ==================================================================== data ===

local DB = {
  users = {}, sessions = {}, accounts = {}, characters = {},
  proxies = {}, instances = {}, scripts = {}, audit = {}
}
local LOGS, CHAT, HIST, MACROS = {}, {}, {}, {}
local BOOTSTRAP = token(16)

local CAVEBOTS  = { 'drefia-ghouls.cfg', 'venore-dwarfs.cfg', 'roshamuul-lower.cfg', 'darashia-hydras.cfg' }
local TARGETBOT = { 'knight-default.json', 'paladin-safe.json', 'druid-aoe.json', 'monk-chain.json' }
local PROFILES  = { 'profile_1', 'profile_2', 'profile_3' }
local MACRONAMES = {
  { name = 'healbot', label = 'HealBot' }, { name = 'attackbot', label = 'AttackBot' },
  { name = 'eat_food', label = 'Eat food' }, { name = 'anti_paralyze', label = 'Anti-paralyze' },
  { name = 'auto_haste', label = 'Auto haste' }, { name = 'depot_deposit', label = 'Deposit at depot' }
}
local MONSTERS = { 'Ghoul', 'Hydra', 'Frost Dragon', 'Nightmare', 'Grim Reaper', 'Dwarf Guard' }
local NAMES = { 'Arnoldus', 'Ballista', 'Mudflower', 'Emberwick', 'Kettlebell', 'Spareparts',
                'Grimbane', 'Ashwick', 'Bramblethorn', 'Cinderfall', 'Duskmire', 'Ironcrest',
                'Kestrelvale', 'Larkbrand', 'Mossridge', 'Nettleshade', 'Onyxfen', 'Pikecrest',
                'Rookbane', 'Slatewick', 'Thornfall', 'Umberlark', 'Vexmire', 'Wickthorn' }

local function auditRec(actor, ip, action, target, outcome, detail)
  local rec = { t = nowMs(), actor = actor or 'system', ip = ip or '-', action = action,
                target = target or '', outcome = outcome or 'ok', detail = detail or '' }
  table.insert(DB.audit, 1, rec)
  if #DB.audit > 4000 then table.remove(DB.audit) end
  return rec
end

local pushEvent   -- forward (defined with the socket registry)

local function mkInstance(char, proxyId, state, ownerUserId)
  local level = char.lastLevel or 60
  local maxHp, maxMana = 900 + level * 12, 400 + level * 9
  local px = proxyId and find(DB.proxies, proxyId) or nil
  local inst = {
    id = uid('i'), characterId = char.id, characterName = char.name,
    accountLabel = (find(DB.accounts, char.accountId) or {}).label or '?',
    world = char.world, vocation = char.vocation,
    ownerUserId = ownerUserId, proxyId = proxyId, proxyLabel = px and px.label or nil,
    botProfile = 'profile_1',
    cavebotConfig = CAVEBOTS[math.random(#CAVEBOTS)],
    targetbotConfig = TARGETBOT[math.random(#TARGETBOT)],
    scripts = {}, autoStart = false, autoRelogin = true,
    state = state, botEnabled = (state == 'online'),
    live = {
      level = level, exp = round(level ^ 3 * 51), expPercent = math.random() * 100,
      expPerHour = state == 'online' and (380000 + math.random() * 900000) or 0,
      moneyPerHour = state == 'online' and (40000 + math.random() * 120000) or 0,
      lootPerHour = 0, wastePerHour = 0, balancePerHour = 0,
      killsPerHour = state == 'online' and (90 + math.random() * 120) or 0,
      deaths = math.random(0, 3),
      hp = round(maxHp * 0.8), maxHp = maxHp, mana = round(maxMana * 0.7), maxMana = maxMana,
      cap = math.random(200, 1800), maxCap = 2400 + level * 10,
      soul = math.random(0, 200), stamina = math.random(2000, 2520),
      pos = { x = 32800 + math.random(-100, 100), y = 31900 + math.random(-100, 100), z = math.random(6, 11) },
      waypointIndex = 0, waypointCount = math.random(28, 84),
      uptimeMs = 0, onlineMs = 0, reconnects = 0,
      supplies = {
        { name = 'Mana potion', itemId = 268, count = math.random(20, 220), min = 60 },
        { name = 'Health potion', itemId = 266, count = math.random(5, 120), min = 40 },
        { name = 'Rune (SD)', itemId = 3155, count = math.random(0, 90), min = 25 }
      }
    }
  }
  LOGS[inst.id] = {}; CHAT[inst.id] = {}; HIST[inst.id] = {}
  MACROS[inst.id] = map(MACRONAMES, function (m)
    return { name = m.name, label = m.label, on = math.random() > 0.4 }
  end)
  return inst
end

--- Called once, right after the bootstrap administrator exists, so the panel has
--- something to show. A real hub obviously starts empty.
local function seed(ownerId)
  DB.proxies = {
    { id = 'p_de', label = 'de-frankfurt', kind = 'http-connect', host = '10.20.0.11', port = 8080,
      user = 'w1', pass = 'not-a-real-secret', hasPass = true },
    { id = 'p_nl', label = 'nl-amsterdam', kind = 'http-connect', host = '10.20.0.12', port = 8080,
      user = nil, hasPass = false }
  }
  DB.accounts = {
    { id = 'a_main', label = 'main-eu', login = 'demo-main', pwEnc = '<encrypted>',
      ownerUserId = ownerId, has2fa = true },
    { id = 'a_alt', label = 'alt-farm', login = 'demo-alt', pwEnc = '<encrypted>',
      ownerUserId = ownerId, has2fa = false }
  }
  local states = { 'online', 'online', 'online', 'connecting', 'stopped', 'error' }
  for i = 1, math.max(1, OPT.fleet) do
    local ch = {
      id = 'c_' .. i, accountId = (i % 2 == 0) and 'a_alt' or 'a_main',
      name = NAMES[((i - 1) % #NAMES) + 1] .. (i > #NAMES and tostring(i) or ''),
      world = 'Gunzodus',
      vocation = ({ 'Knight', 'Paladin', 'Druid', 'Sorcerer', 'Monk' })[(i % 5) + 1],
      lastLevel = math.random(60, 300)
    }
    table.insert(DB.characters, ch)
    local st = states[((i - 1) % #states) + 1]
    table.insert(DB.instances, mkInstance(ch, (i % 3 == 0) and 'p_nl' or 'p_de', st, ownerId))
  end
  DB.scripts = {
    { id = 's_1', name = 'refill_supplies.lua', source = '-- demo\nmacro(2000, "refill", function() end)\n',
      size = 52, sha256 = token(32), ownerUserId = ownerId, createdAt = nowMs(), instanceIds = {} }
  }
  DB.scripts[1].size = #DB.scripts[1].source
end

-- =============================================================== simulator ===

local function logLine(inst, level, text)
  local line = { id = inst.id, t = nowMs(), level = level, text = text }
  local L = LOGS[inst.id]
  L[#L + 1] = line
  if #L > 800 then table.remove(L, 1) end
  pushEvent('log', line, inst.id, 'logs')
  return line
end

local ticks = 0
local function tick()
  ticks = ticks + 1
  for _, i in ipairs(DB.instances) do
    local L = i.live
    if i.state == 'starting' and ticks % 3 == 0 then i.state = 'connecting'
    elseif i.state == 'connecting' and ticks % 3 == 0 then
      i.state = 'online'; L.uptimeMs = 0; L.onlineMs = 0
      pushEvent('gameStart', { id = i.id, t = nowMs() })
      logLine(i, 'info', 'game start: ' .. i.characterName .. ' entered ' .. i.world)
    elseif i.state == 'stopping' and ticks % 2 == 0 then
      i.state = 'stopped'; i.botEnabled = false
      pushEvent('gameEnd', { id = i.id, reason = 'operator stop' })
    end

    if i.state ~= 'stopped' then
      L.uptimeMs = L.uptimeMs + 1000
      if i.state == 'online' then L.onlineMs = L.onlineMs + 1000 end
      if i.state == 'online' and i.botEnabled then
        L.hp = clamp(round(L.hp + (math.random() - 0.42) * L.maxHp * 0.06), round(L.maxHp * 0.08), L.maxHp)
        L.mana = clamp(round(L.mana + (math.random() - 0.45) * L.maxMana * 0.09), 0, L.maxMana)
        L.expPercent = (L.expPercent + math.random() * 0.35) % 100
        L.exp = L.exp + round(L.expPerHour / 3600)
        if math.random() < 0.3 then L.target = MONSTERS[math.random(#MONSTERS)]
        elseif math.random() < 0.12 then L.target = nil end
        if math.random() < 0.18 then
          L.waypointIndex = (L.waypointIndex % L.waypointCount) + 1
          L.waypoint = 'goto #' .. L.waypointIndex
        end
        L.pos.x = clamp(L.pos.x + math.random(-1, 1), 32000, 33500)
        L.pos.y = clamp(L.pos.y + math.random(-1, 1), 31000, 32500)
        if math.random() < 0.22 then
          logLine(i, 'info', 'cavebot: waypoint ' .. L.waypointIndex .. '/' .. L.waypointCount)
        end
      end
    end

    pushEvent('status', {
      id = i.id, state = i.state, botEnabled = i.botEnabled,
      hp = L.hp, maxHp = L.maxHp, mana = L.mana, maxMana = L.maxMana,
      level = L.level, expPercent = L.expPercent, target = L.target, waypoint = L.waypoint,
      waypointIndex = L.waypointIndex, waypointCount = L.waypointCount,
      uptimeMs = L.uptimeMs, onlineMs = L.onlineMs, pos = L.pos,
      cap = L.cap, maxCap = L.maxCap, soul = L.soul, stamina = L.stamina
    })

    if ticks % 5 == 0 and i.state == 'online' then
      L.expPerHour = round(clamp(L.expPerHour * (0.985 + math.random() * 0.032), 60000, 2600000))
      L.moneyPerHour = round(clamp(L.moneyPerHour * (0.98 + math.random() * 0.045), 4000, 700000))
      L.killsPerHour = round(clamp(L.killsPerHour * (0.98 + math.random() * 0.045), 8, 420))
      L.lootPerHour = round(L.moneyPerHour * 1.4)
      L.wastePerHour = round(L.lootPerHour * 0.5)
      L.balancePerHour = L.lootPerHour - L.wastePerHour
      local st = { id = i.id, t = nowMs(), expPerHour = L.expPerHour, moneyPerHour = L.moneyPerHour,
                   killsPerHour = L.killsPerHour, lootPerHour = L.lootPerHour,
                   wastePerHour = L.wastePerHour, balancePerHour = L.balancePerHour,
                   deaths = L.deaths, level = L.level, exp = L.exp, supplies = L.live and nil or nil,
                   reconnects = L.reconnects }
      st.supplies = L.supplies
      pushEvent('stats', st)
      local H = HIST[i.id]
      H[#H + 1] = { t = st.t, expPerHour = L.expPerHour, moneyPerHour = L.moneyPerHour,
                    killsPerHour = L.killsPerHour, level = L.level,
                    hpPercent = (L.hp / L.maxHp) * 100, manaPercent = (L.mana / L.maxMana) * 100 }
      if #H > 400 then table.remove(H, 1) end
    end

    if i.state == 'online' and math.random() < 0.05 then
      local m = { id = i.id, t = nowMs(), channel = 'Local',
                  from = MONSTERS[math.random(#MONSTERS)], text = 'anyone selling a stone skin amulet?' }
      local C = CHAT[i.id]
      C[#C + 1] = m
      if #C > 500 then table.remove(C, 1) end
      pushEvent('chat', m, i.id, 'chat')
    end
  end
end

-- ============================================================= projections ===

local function nameOf(userId)
  local u = find(DB.users, userId)
  return u and u.name or '?'
end

local function pubInstance(i)
  local o = copy(i)
  return o
end
local function pubAccount(a)
  return { id = a.id, label = a.label, login = a.login, ownerUserId = a.ownerUserId,
           ownerName = nameOf(a.ownerUserId), has2fa = a.has2fa and true or false,
           characterCount = #filter(DB.characters, function (c) return c.accountId == a.id end) }
end
local function pubCharacter(c)
  local a = find(DB.accounts, c.accountId)
  local inst
  for _, i in ipairs(DB.instances) do if i.characterId == c.id then inst = i end end
  return { id = c.id, accountId = c.accountId, accountLabel = a and a.label or '?', name = c.name,
           world = c.world, vocation = c.vocation, lastLevel = c.lastLevel,
           instanceId = inst and inst.id or nil }
end
local function pubProxy(p)
  return { id = p.id, label = p.label, kind = p.kind, host = p.host, port = p.port,
           user = p.user, hasPass = p.hasPass and true or false,
           inUse = #filter(DB.instances, function (i) return i.proxyId == p.id end) }
end
local function pubScript(s)
  return { id = s.id, name = s.name, size = s.size, sha256 = s.sha256, ownerUserId = s.ownerUserId,
           ownerName = nameOf(s.ownerUserId), createdAt = s.createdAt, instanceIds = copy(s.instanceIds) }
end
local function pubUser(u)
  return { id = u.id, name = u.name, role = u.role, createdAt = u.createdAt,
           disabled = u.disabled and true or false, lastLoginAt = u.lastLoginAt }
end

-- ================================================================== errors ===

local STATUS = { ['bad-request'] = 400, ['unauthorized'] = 401, ['forbidden'] = 403,
                 ['csrf-invalid'] = 403, ['not-found'] = 404, ['conflict'] = 409,
                 ['too-large'] = 413, ['rate-limited'] = 429, ['internal'] = 500 }

local function fail(code, message) error({ code = code, message = message }, 0) end
local function need(cond, code, message) if not cond then fail(code, message) end end

-- ================================================================ sessions ===

local function cookieOf(req, name)
  local raw = req:header('cookie')
  if not raw then return nil end
  for k, v in raw:gmatch('([%w_%-]+)=([^;%s]*)') do
    if k == name then return v end
  end
  return nil
end

local function sessionOf(req)
  local tok = cookieOf(req, 'hubsess')
  if not tok then return nil end
  local s = DB.sessions[tok]
  if not s then return nil end
  s.lastSeenAt = nowMs()
  return s, tok
end

local function newSession(user, req)
  local tok = token(32)
  DB.sessions[tok] = { id = 'sess_' .. tok:sub(1, 8), userId = user.id, csrf = token(24),
                       ip = req.remoteIp or '?', userAgent = req:header('user-agent') or '',
                       createdAt = nowMs(), lastSeenAt = nowMs() }
  return tok, DB.sessions[tok]
end

local function revokeSessionsOf(userId, keepTok)
  for tok, s in pairs(DB.sessions) do
    if s.userId == userId and tok ~= keepTok then DB.sessions[tok] = nil end
  end
end

-- ================================================== the websocket registry ===

local liveSockets = {}     -- ws -> true

--- pushEvent(name, data [, instanceId, streamKey])
--- A stream event (log/chat) only goes to the sockets that subscribed to that
--- instance; everything else goes to every socket whose user may see it.
function pushEvent(name, data, instanceId, streamKey)
  local frame = json.encode({ event = name, data = data })
  for ws in pairs(liveSockets) do
    local u = ws.user
    if u and u.ready then
      local mayStream = (not streamKey) or (u.subs and u.subs[streamKey] == instanceId)
      if mayStream then ws:send(frame) end
    end
  end
end

-- ================================================================= handlers ===
-- ctx = { params, query, body, sess, user, req }

local H = {}

local function requireUser(ctx)
  need(ctx.user, 'unauthorized', 'not signed in')
  return ctx.user
end
local function requireAdmin(ctx)
  requireUser(ctx)
  need(ctx.user.role == 'admin', 'forbidden', 'administrators only')
  return ctx.user
end
local function maySee(ctx, inst)
  return ctx.user.role == 'admin' or inst.ownerUserId == ctx.user.id
end
local function instanceOf(ctx)
  local i = find(DB.instances, ctx.params.id)
  need(i, 'not-found', 'no such instance')
  need(maySee(ctx, i), 'forbidden', 'not your instance')
  return i
end
local function logAudit(ctx, action, target, outcome, detail)
  local rec = auditRec(ctx.user and ctx.user.name or 'anonymous', ctx.req.remoteIp,
                       action, target, outcome, detail)
  pushEvent('audit', rec)
  return rec
end

-- ---- session ---------------------------------------------------------------

H['GET /api/session'] = function (ctx)
  return {
    user = ctx.user and { id = ctx.user.id, name = ctx.user.name, role = ctx.user.role } or nil,
    serverTime = nowMs(), version = 'devhub-1.0',
    bootstrap = (#DB.users == 0),
    insecure = true,                       -- this fixture is plain HTTP by design
    csrfToken = ctx.sess and ctx.sess.csrf or ctx.anonCsrf
  }
end

H['POST /api/session'] = function (ctx)
  local b = ctx.body
  need(type(b.name) == 'string' and type(b.password) == 'string', 'bad-request', 'name and password')
  local u
  for _, x in ipairs(DB.users) do if x.name:lower() == b.name:lower() then u = x end end
  -- constant cost whether or not the account exists
  local okpw = pbkdf2.verifyOrDummy(b.password, u and u.pwhash or nil)
  if not u or not okpw then
    auditRec(b.name, ctx.req.remoteIp, 'login.fail', b.name, 'denied', '')
    fail('unauthorized', 'wrong name or password')
  end
  need(not u.disabled, 'forbidden', 'this account is disabled')
  local tok, sess = newSession(u, ctx.req)
  u.lastLoginAt = nowMs()
  ctx.setCookie = tok
  auditRec(u.name, ctx.req.remoteIp, 'login.ok', u.name, 'ok', '')
  return { user = { id = u.id, name = u.name, role = u.role }, csrfToken = sess.csrf }
end

H['DELETE /api/session'] = function (ctx)
  if ctx.sessToken then DB.sessions[ctx.sessToken] = nil end
  if ctx.user then auditRec(ctx.user.name, ctx.req.remoteIp, 'logout', ctx.user.name, 'ok', '') end
  ctx.clearCookie = true
  return OKAY()
end

H['POST /api/session/password'] = function (ctx)
  local u = requireUser(ctx)
  local b = ctx.body
  need(type(b.current) == 'string' and type(b.next) == 'string', 'bad-request', 'both passwords')
  need(#b.next >= 10, 'bad-request', 'the new password is too short')
  need(pbkdf2.verifyOrDummy(b.current, u.pwhash), 'forbidden', 'the current password is wrong')
  u.pwhash = pbkdf2.hash(b.next)
  revokeSessionsOf(u.id, ctx.sessToken)
  logAudit(ctx, 'user.password', u.name, 'ok', 'self-service change')
  return OKAY()
end

H['POST /api/bootstrap'] = function (ctx)
  need(#DB.users == 0, 'conflict', 'already bootstrapped')
  local b = ctx.body
  need(b.token == BOOTSTRAP, 'forbidden', 'wrong bootstrap token')
  need(type(b.name) == 'string' and b.name:match('^[%w_%.%-]+$') ~= nil
       and #b.name >= 2 and #b.name <= 32, 'bad-request', 'invalid administrator name')
  need(type(b.password) == 'string' and #b.password >= 10, 'bad-request', 'password too short')
  local u = { id = uid('u'), name = b.name, role = 'admin', pwhash = pbkdf2.hash(b.password),
              createdAt = nowMs(), disabled = false, lastLoginAt = nowMs() }
  table.insert(DB.users, u)
  seed(u.id)
  local tok, sess = newSession(u, ctx.req)
  ctx.setCookie = tok
  auditRec(u.name, ctx.req.remoteIp, 'user.create', u.name, 'ok', 'bootstrap administrator')
  return { user = { id = u.id, name = u.name, role = u.role }, csrfToken = sess.csrf }
end

-- ---- instances -------------------------------------------------------------

H['GET /api/instances'] = function (ctx)
  requireUser(ctx)
  return { instances = map(filter(DB.instances, function (i) return maySee(ctx, i) end), pubInstance) }
end

H['GET /api/instances/:id'] = function (ctx)
  requireUser(ctx)
  return { instance = pubInstance(instanceOf(ctx)) }
end

H['POST /api/instances'] = function (ctx)
  requireUser(ctx)
  local b = ctx.body
  local ch = find(DB.characters, b.characterId)
  need(ch, 'not-found', 'no such character')
  for _, i in ipairs(DB.instances) do
    need(i.characterId ~= ch.id, 'conflict', 'that character already has an instance')
  end
  local inst = mkInstance(ch, b.proxyId, 'stopped', ctx.user.id)
  inst.botProfile = b.botProfile or 'profile_1'
  inst.autoStart = b.autoStart and true or false
  inst.autoRelogin = b.autoRelogin ~= false
  table.insert(DB.instances, inst)
  logAudit(ctx, 'instance.create', ch.name, 'ok', '')
  pushEvent('instance', { id = inst.id, instance = pubInstance(inst) })
  return { instance = pubInstance(inst) }
end

H['PATCH /api/instances/:id'] = function (ctx)
  requireUser(ctx)
  local i = instanceOf(ctx)
  local p = ctx.body
  for _, k in ipairs({ 'botProfile', 'cavebotConfig', 'targetbotConfig', 'autoStart', 'autoRelogin' }) do
    if p[k] ~= nil then i[k] = p[k] end
  end
  if p.proxyId ~= nil then
    if p.proxyId == '' or p.proxyId == false then i.proxyId, i.proxyLabel = nil, nil
    else
      local px = find(DB.proxies, p.proxyId)
      need(px, 'not-found', 'no such proxy')
      i.proxyId, i.proxyLabel = px.id, px.label
    end
  end
  if p.scripts ~= nil then
    i.scripts = copy(p.scripts)
    for _, s in ipairs(DB.scripts) do
      local has = false
      for _, sid in ipairs(i.scripts) do if sid == s.id then has = true end end
      local at
      for k, iid in ipairs(s.instanceIds) do if iid == i.id then at = k end end
      if has and not at then table.insert(s.instanceIds, i.id) end
      if (not has) and at then table.remove(s.instanceIds, at) end
    end
  end
  logAudit(ctx, 'instance.config', i.characterName, 'ok', '')
  pushEvent('instance', { id = i.id, instance = pubInstance(i) })
  return { instance = pubInstance(i) }
end

H['DELETE /api/instances/:id'] = function (ctx)
  requireUser(ctx)
  local i = instanceOf(ctx)
  removeById(DB.instances, i.id)
  logAudit(ctx, 'instance.delete', i.characterName, 'ok', '')
  pushEvent('instance', { id = i.id, removed = true })
  return OKAY()
end

H['POST /api/instances/actions'] = function (ctx)
  requireUser(ctx)
  local b = ctx.body
  local action = b.action
  need(action == 'start' or action == 'stop' or action == 'restart' or action == 'botEnable',
       'bad-request', 'unknown action')
  need(type(b.ids) == 'table', 'bad-request', 'ids must be a list')
  local results = {}
  for _, id in ipairs(b.ids) do
    local i = find(DB.instances, id)
    if not i or not maySee(ctx, i) then
      results[#results + 1] = { id = id, ok = false, error = 'no such instance' }
    elseif action == 'start' then
      if i.state == 'online' or i.state == 'starting' or i.state == 'connecting' then
        results[#results + 1] = { id = id, ok = false, error = 'already running' }
      else
        i.state = 'starting'; i.live.uptimeMs = 0
        logLine(i, 'info', 'supervisor: spawning worker via ' .. (i.proxyLabel or 'direct connection'))
        logAudit(ctx, 'instance.start', i.characterName, 'ok', '')
        results[#results + 1] = { id = id, ok = true }
      end
    elseif action == 'stop' then
      if i.state == 'stopped' then
        results[#results + 1] = { id = id, ok = false, error = 'already stopped' }
      else
        i.state = 'stopping'
        logLine(i, 'info', 'supervisor: sending shutdown')
        logAudit(ctx, 'instance.stop', i.characterName, 'ok', '')
        results[#results + 1] = { id = id, ok = true }
      end
    elseif action == 'restart' then
      i.state = 'starting'; i.live.reconnects = i.live.reconnects + 1
      logAudit(ctx, 'instance.start', i.characterName, 'ok', 'restart')
      results[#results + 1] = { id = id, ok = true }
    else
      if i.state ~= 'online' then
        results[#results + 1] = { id = id, ok = false, error = 'instance is not online' }
      else
        i.botEnabled = b.on and true or false
        logLine(i, 'info', 'bot ' .. (i.botEnabled and 'enabled' or 'disabled') .. ' by ' .. ctx.user.name)
        logAudit(ctx, 'instance.config', i.characterName, 'ok', 'bot.enable=' .. tostring(i.botEnabled))
        results[#results + 1] = { id = id, ok = true }
      end
    end
    if i then pushEvent('instance', { id = i.id, instance = pubInstance(i) }) end
  end
  return { results = results }
end

H['GET /api/instances/:id/configs'] = function (ctx)
  requireUser(ctx)
  local i = instanceOf(ctx)
  return { cavebot = copy(CAVEBOTS), targetbot = copy(TARGETBOT), profiles = copy(PROFILES),
           macros = copy(MACROS[i.id] or {}) }
end

H['PUT /api/instances/:id/macros/:name'] = function (ctx)
  requireUser(ctx)
  local i = instanceOf(ctx)
  local m
  for _, x in ipairs(MACROS[i.id] or {}) do if x.name == ctx.params.name then m = x end end
  need(m, 'not-found', 'no such macro')
  m.on = ctx.body.on and true or false
  logAudit(ctx, 'instance.config', i.characterName, 'ok', 'macro ' .. m.name .. '=' .. tostring(m.on))
  return { macro = copy(m) }
end

H['POST /api/instances/:id/reload'] = function (ctx)
  requireUser(ctx)
  local i = instanceOf(ctx)
  logLine(i, 'info', 'bot: reloading profile ' .. i.botProfile)
  logAudit(ctx, 'instance.config', i.characterName, 'ok', 'bot.reload')
  return OKAY()
end

H['POST /api/instances/:id/exec'] = function (ctx)
  requireUser(ctx)
  local i = instanceOf(ctx)
  local code = ctx.body.code
  need(type(code) == 'string' and #code > 0, 'bad-request', 'no code given')
  logAudit(ctx, 'exec', i.characterName, 'ok', 'code: ' .. code:sub(1, 400))
  local out = 'nil'
  if code:find('[Ll]evel') then out = tostring(i.live.level)
  elseif code:find('[Hh]ealth') or code:find('%f[%w]hp%f[%W]') then out = i.live.hp .. ' / ' .. i.live.maxHp
  elseif code:find('[Nn]ame') then out = i.characterName
  elseif code:find('error') then fail('bad-request', 'chunk:1: something went wrong') end
  return { output = out }
end

H['GET /api/instances/:id/history'] = function (ctx)
  requireUser(ctx)
  local i = instanceOf(ctx)
  local since = tonumber(ctx.query.since or 0) or 0
  return { points = filter(HIST[i.id] or {}, function (p) return p.t >= since end) }
end

H['GET /api/instances/:id/logs'] = function (ctx)
  requireUser(ctx)
  local i = instanceOf(ctx)
  local lim = math.min(tonumber(ctx.query.limit or 200) or 200, 800)
  local all = LOGS[i.id] or {}
  local out = {}
  for k = math.max(1, #all - lim + 1), #all do out[#out + 1] = all[k] end
  return { lines = out }
end

H['GET /api/instances/:id/chat'] = function (ctx)
  requireUser(ctx)
  local i = instanceOf(ctx)
  local lim = math.min(tonumber(ctx.query.limit or 200) or 200, 500)
  local all = CHAT[i.id] or {}
  local out = {}
  for k = math.max(1, #all - lim + 1), #all do out[#out + 1] = all[k] end
  return { messages = out }
end

H['POST /api/instances/:id/chat'] = function (ctx)
  requireUser(ctx)
  local i = instanceOf(ctx)
  need(i.state == 'online', 'conflict', 'the character is not online')
  local text = ctx.body.text
  need(type(text) == 'string' and text:match('%S'), 'bad-request', 'empty message')
  local m = { id = i.id, t = nowMs(), channel = 'Ch' .. tostring(ctx.body.channel or 0),
              from = i.characterName, text = text }
  local C = CHAT[i.id]; C[#C + 1] = m
  pushEvent('chat', m, i.id, 'chat')
  return OKAY()
end

-- ---- accounts / characters / proxies ---------------------------------------

H['GET /api/accounts'] = function (ctx)
  requireUser(ctx)
  return { accounts = map(filter(DB.accounts, function (a)
    return ctx.user.role == 'admin' or a.ownerUserId == ctx.user.id end), pubAccount) }
end

H['POST /api/accounts'] = function (ctx)
  requireUser(ctx)
  local b = ctx.body
  need(type(b.label) == 'string' and #b.label > 0, 'bad-request', 'label is required')
  need(type(b.login) == 'string' and #b.login > 0, 'bad-request', 'login is required')
  need(type(b.password) == 'string' and #b.password > 0, 'bad-request', 'a password is required')
  -- the real hub encrypts with lib/authsecret.lua; the fixture only records that
  -- a secret was supplied, and never keeps or logs the plaintext
  local a = { id = uid('a'), label = b.label, login = b.login, pwEnc = '<encrypted>',
              ownerUserId = ctx.user.id, has2fa = b.token2fa ~= nil and b.token2fa ~= '' }
  table.insert(DB.accounts, a)
  logAudit(ctx, 'account.create', a.label, 'ok', '')
  return { account = pubAccount(a) }
end

H['PATCH /api/accounts/:id'] = function (ctx)
  requireUser(ctx)
  local a = find(DB.accounts, ctx.params.id)
  need(a, 'not-found', 'no such account')
  need(ctx.user.role == 'admin' or a.ownerUserId == ctx.user.id, 'forbidden', 'not your account')
  local b = ctx.body
  if b.label then a.label = b.label end
  if b.login then a.login = b.login end
  if b.password then a.pwEnc = '<encrypted>' end
  if b.token2fa ~= nil then a.has2fa = (b.token2fa ~= '' and b.token2fa ~= false) end
  logAudit(ctx, 'account.change', a.label, 'ok', '')
  return { account = pubAccount(a) }
end

H['DELETE /api/accounts/:id'] = function (ctx)
  requireUser(ctx)
  local a = find(DB.accounts, ctx.params.id)
  need(a, 'not-found', 'no such account')
  need(ctx.user.role == 'admin' or a.ownerUserId == ctx.user.id, 'forbidden', 'not your account')
  local chars = filter(DB.characters, function (c) return c.accountId == a.id end)
  for _, c in ipairs(chars) do
    for _, i in ipairs(copy(DB.instances)) do
      if i.characterId == c.id then
        removeById(DB.instances, i.id); pushEvent('instance', { id = i.id, removed = true })
      end
    end
    removeById(DB.characters, c.id)
  end
  removeById(DB.accounts, a.id)
  logAudit(ctx, 'account.delete', a.label, 'ok', #chars .. ' characters removed')
  return OKAY()
end

H['GET /api/characters'] = function (ctx)
  requireUser(ctx)
  local mine = {}
  for _, a in ipairs(DB.accounts) do
    if ctx.user.role == 'admin' or a.ownerUserId == ctx.user.id then mine[a.id] = true end
  end
  return { characters = map(filter(DB.characters, function (c) return mine[c.accountId] end), pubCharacter) }
end

H['POST /api/characters'] = function (ctx)
  requireUser(ctx)
  local b = ctx.body
  need(b.accountId and b.name and b.world, 'bad-request', 'accountId, name and world are required')
  for _, c in ipairs(DB.characters) do
    need(c.name:lower() ~= tostring(b.name):lower(), 'conflict', 'a character with that name exists')
  end
  local c = { id = uid('c'), accountId = b.accountId, name = b.name, world = b.world,
              vocation = b.vocation, lastLevel = nil }
  table.insert(DB.characters, c)
  logAudit(ctx, 'character.create', c.name, 'ok', '')
  return { character = pubCharacter(c) }
end

H['DELETE /api/characters/:id'] = function (ctx)
  requireUser(ctx)
  local c = find(DB.characters, ctx.params.id)
  need(c, 'not-found', 'no such character')
  for _, i in ipairs(copy(DB.instances)) do
    if i.characterId == c.id then
      removeById(DB.instances, i.id); pushEvent('instance', { id = i.id, removed = true })
    end
  end
  removeById(DB.characters, c.id)
  logAudit(ctx, 'character.delete', c.name, 'ok', '')
  return OKAY()
end

H['GET /api/proxies'] = function (ctx)
  requireUser(ctx)
  return { proxies = map(DB.proxies, pubProxy) }
end

H['POST /api/proxies'] = function (ctx)
  requireUser(ctx)
  local b = ctx.body
  need(b.label and b.host and b.port, 'bad-request', 'label, host and port are required')
  local p = { id = uid('p'), label = b.label, kind = b.kind or 'http-connect', host = b.host,
              port = tonumber(b.port), user = b.user, hasPass = (b.pass ~= nil and b.pass ~= '') }
  table.insert(DB.proxies, p)
  logAudit(ctx, 'proxy.create', p.label, 'ok', p.host .. ':' .. tostring(p.port))
  return { proxy = pubProxy(p) }
end

H['PATCH /api/proxies/:id'] = function (ctx)
  requireUser(ctx)
  local p = find(DB.proxies, ctx.params.id)
  need(p, 'not-found', 'no such proxy')
  local b = ctx.body
  for _, k in ipairs({ 'label', 'kind', 'host', 'user' }) do if b[k] ~= nil then p[k] = b[k] end end
  if b.port then p.port = tonumber(b.port) end
  if b.pass and b.pass ~= '' then p.hasPass = true end
  for _, i in ipairs(DB.instances) do if i.proxyId == p.id then i.proxyLabel = p.label end end
  logAudit(ctx, 'proxy.change', p.label, 'ok', '')
  return { proxy = pubProxy(p) }
end

H['DELETE /api/proxies/:id'] = function (ctx)
  requireUser(ctx)
  local p = find(DB.proxies, ctx.params.id)
  need(p, 'not-found', 'no such proxy')
  need(#filter(DB.instances, function (i) return i.proxyId == p.id end) == 0,
       'conflict', 'the proxy is still assigned to an instance')
  removeById(DB.proxies, p.id)
  logAudit(ctx, 'proxy.change', p.label, 'ok', 'deleted')
  return OKAY()
end

H['POST /api/proxies/:id/test'] = function (ctx)
  requireUser(ctx)
  local p = find(DB.proxies, ctx.params.id)
  need(p, 'not-found', 'no such proxy')
  if math.random() < 0.2 then return { ok = false, latencyMs = 0, error = 'CONNECT refused (HTTP 403)' } end
  return { ok = true, latencyMs = math.random(18, 240) }
end

-- ---- scripts ---------------------------------------------------------------

H['GET /api/scripts'] = function (ctx)
  requireUser(ctx)
  return { scripts = map(DB.scripts, pubScript) }
end

H['GET /api/scripts/:id'] = function (ctx)
  requireUser(ctx)
  local s = find(DB.scripts, ctx.params.id)
  need(s, 'not-found', 'no such script')
  return { script = pubScript(s), source = s.source }
end

H['POST /api/scripts'] = function (ctx)
  requireUser(ctx)
  local b = ctx.body
  need(type(b.name) == 'string' and b.name:match('^[%w%._%- ]+$') and #b.name <= 64,
       'bad-request', 'invalid script name')
  need(type(b.source) == 'string' and #b.source > 0, 'bad-request', 'empty source')
  need(#b.source <= 512 * 1024, 'too-large', 'script exceeds 512 KiB')
  local s
  for _, x in ipairs(DB.scripts) do if x.name == b.name then s = x end end
  if not s then
    s = { id = uid('s'), name = b.name, instanceIds = {}, ownerUserId = ctx.user.id }
    table.insert(DB.scripts, s)
  end
  s.source, s.size, s.createdAt = b.source, #b.source, nowMs()
  s.sha256 = token(32)                       -- the real hub stores the real digest
  logAudit(ctx, 'script.upload', s.name, 'ok', s.size .. ' bytes')
  pushEvent('script', { id = s.id, script = pubScript(s) })
  return { script = pubScript(s) }
end

H['DELETE /api/scripts/:id'] = function (ctx)
  requireUser(ctx)
  local s = find(DB.scripts, ctx.params.id)
  need(s, 'not-found', 'no such script')
  for _, i in ipairs(DB.instances) do
    i.scripts = filter(i.scripts, function (x) return x ~= s.id end)
  end
  removeById(DB.scripts, s.id)
  logAudit(ctx, 'script.delete', s.name, 'ok', '')
  pushEvent('script', { id = s.id, removed = true })
  return OKAY()
end

H['PUT /api/scripts/:id/assignments'] = function (ctx)
  requireUser(ctx)
  local s = find(DB.scripts, ctx.params.id)
  need(s, 'not-found', 'no such script')
  local ids = ctx.body.instanceIds
  need(type(ids) == 'table', 'bad-request', 'instanceIds must be a list')
  s.instanceIds = copy(ids)
  for _, i in ipairs(DB.instances) do
    local want = false
    for _, id in ipairs(s.instanceIds) do if id == i.id then want = true end end
    local at
    for k, sid in ipairs(i.scripts) do if sid == s.id then at = k end end
    if want and not at then table.insert(i.scripts, s.id)
    elseif (not want) and at then table.remove(i.scripts, at) end
    pushEvent('instance', { id = i.id, instance = pubInstance(i) })
  end
  logAudit(ctx, 'script.assign', s.name, 'ok', #s.instanceIds .. ' instances')
  return { script = pubScript(s) }
end

-- ---- admin -----------------------------------------------------------------

H['GET /api/admin/users'] = function (ctx)
  requireAdmin(ctx)
  return { users = map(DB.users, pubUser) }
end

H['POST /api/admin/users'] = function (ctx)
  requireAdmin(ctx)
  local b = ctx.body
  need(type(b.name) == 'string' and b.name:match('^[%w%._%-]+$') and #b.name >= 2 and #b.name <= 32,
       'bad-request', 'invalid account name')
  for _, u in ipairs(DB.users) do need(u.name:lower() ~= b.name:lower(), 'conflict', 'that name is taken') end
  need(type(b.password) == 'string' and #b.password >= 10, 'bad-request', 'password too short')
  need(b.role == 'admin' or b.role == 'user', 'bad-request', 'role must be admin or user')
  local u = { id = uid('u'), name = b.name, role = b.role, pwhash = pbkdf2.hash(b.password),
              createdAt = nowMs(), disabled = false }
  table.insert(DB.users, u)
  logAudit(ctx, 'user.create', u.name, 'ok', 'role=' .. u.role)
  return { user = pubUser(u) }
end

H['PATCH /api/admin/users/:id'] = function (ctx)
  requireAdmin(ctx)
  local u = find(DB.users, ctx.params.id)
  need(u, 'not-found', 'no such account')
  need(u.id ~= ctx.user.id, 'forbidden', 'you cannot change your own role or status')
  local b = ctx.body
  if b.role then
    need(b.role == 'admin' or b.role == 'user', 'bad-request', 'bad role')
    u.role = b.role
  end
  if b.disabled ~= nil then
    u.disabled = b.disabled and true or false
    if u.disabled then revokeSessionsOf(u.id) end
  end
  logAudit(ctx, 'user.change', u.name, 'ok', '')
  return { user = pubUser(u) }
end

H['DELETE /api/admin/users/:id'] = function (ctx)
  requireAdmin(ctx)
  local u = find(DB.users, ctx.params.id)
  need(u, 'not-found', 'no such account')
  need(u.id ~= ctx.user.id, 'forbidden', 'you cannot delete your own account')
  removeById(DB.users, u.id)
  revokeSessionsOf(u.id)
  logAudit(ctx, 'user.delete', u.name, 'ok', '')
  return OKAY()
end

H['POST /api/admin/users/:id/password'] = function (ctx)
  requireAdmin(ctx)
  local u = find(DB.users, ctx.params.id)
  need(u, 'not-found', 'no such account')
  need(type(ctx.body.password) == 'string' and #ctx.body.password >= 10, 'bad-request', 'password too short')
  u.pwhash = pbkdf2.hash(ctx.body.password)
  revokeSessionsOf(u.id, u.id == ctx.user.id and ctx.sessToken or nil)
  logAudit(ctx, 'user.password', u.name, 'ok', 'reset by administrator')
  return OKAY()
end

H['GET /api/admin/sessions'] = function (ctx)
  requireAdmin(ctx)
  local out = {}
  for tok, s in pairs(DB.sessions) do
    out[#out + 1] = { id = s.id, userId = s.userId, userName = nameOf(s.userId), ip = s.ip,
                      userAgent = s.userAgent, createdAt = s.createdAt, lastSeenAt = s.lastSeenAt,
                      current = (tok == ctx.sessToken) }
  end
  table.sort(out, function (a, b) return a.createdAt > b.createdAt end)
  return { sessions = out }
end

H['DELETE /api/admin/sessions/:id'] = function (ctx)
  requireAdmin(ctx)
  local killed
  for tok, s in pairs(DB.sessions) do
    if s.id == ctx.params.id then killed = s; DB.sessions[tok] = nil end
  end
  need(killed, 'not-found', 'no such session')
  logAudit(ctx, 'session.revoke', nameOf(killed.userId), 'ok', killed.ip)
  return OKAY()
end

H['GET /api/admin/audit'] = function (ctx)
  requireAdmin(ctx)
  local q = ctx.query
  local rows = DB.audit
  if q.actor and q.actor ~= '' then rows = filter(rows, function (r) return r.actor == q.actor end) end
  if q.action and q.action ~= '' then rows = filter(rows, function (r) return r.action == q.action end) end
  if q.from and q.from ~= '' then
    local f = tonumber(q.from) or 0
    rows = filter(rows, function (r) return r.t >= f end)
  end
  if q.to and q.to ~= '' then
    local t = tonumber(q.to) or math.huge
    rows = filter(rows, function (r) return r.t <= t end)
  end
  if q.q and q.q ~= '' then
    local needle = q.q:lower()
    rows = filter(rows, function (r)
      return (r.target .. ' ' .. r.detail .. ' ' .. r.action):lower():find(needle, 1, true) ~= nil
    end)
  end
  local start = tonumber(q.cursor or 0) or 0
  local lim = math.min(tonumber(q.limit or 100) or 100, 500)
  local page = {}
  for k = start + 1, math.min(start + lim, #rows) do page[#page + 1] = rows[k] end
  local actorSet, actionSet = {}, {}
  for _, r in ipairs(DB.audit) do actorSet[r.actor] = true; actionSet[r.action] = true end
  local actors, actions = {}, {}
  for k in pairs(actorSet) do actors[#actors + 1] = k end
  for k in pairs(actionSet) do actions[#actions + 1] = k end
  table.sort(actors); table.sort(actions)
  return { rows = page, nextCursor = (start + lim < #rows) and tostring(start + lim) or nil,
           total = #rows, actors = actors, actions = actions }
end

-- ================================================================== router ===

local ROUTES = {}
for key, fn in pairs(H) do
  local method, tmpl = key:match('^(%u+) (.+)$')
  local names, pattern = {}, {}
  for seg in tmpl:gmatch('[^/]+') do
    local p = seg:match('^:(%w+)$')
    if p then names[#names + 1] = p; pattern[#pattern + 1] = true
    else pattern[#pattern + 1] = seg end
  end
  ROUTES[#ROUTES + 1] = { method = method, key = key, segs = pattern, names = names, fn = fn }
end

local function splitPath(path)
  local out = {}
  for seg in path:gmatch('[^/]+') do out[#out + 1] = seg end
  return out
end

local function routeFor(method, path)
  local segs = splitPath(path)
  for _, r in ipairs(ROUTES) do
    if r.method == method and #r.segs == #segs then
      local params, okAll, n = {}, true, 0
      for k = 1, #segs do
        if r.segs[k] == true then n = n + 1; params[r.names[n]] = segs[k]
        elseif r.segs[k] ~= segs[k] then okAll = false; break end
      end
      if okAll then return r, params end
    end
  end
  return nil
end

local SAFE = { GET = true, HEAD = true, OPTIONS = true }
local anonCsrf = token(24)     -- handed to a signed-out browser so login can be posted

local function apiHandler(req, res)
  local sess, sessTok = sessionOf(req)
  local user = sess and find(DB.users, sess.userId) or nil
  if user and user.disabled then user = nil end

  local r, params = routeFor(req.method, req.path)
  if not r then
    return res:json(404, { error = { code = 'not-found', message = 'no route for ' .. req.method .. ' ' .. req.path } })
  end

  if not SAFE[req.method] then
    local want = sess and sess.csrf or anonCsrf
    local got = req:header('x-csrf-token')
    if got ~= want then
      return res:json(403, { error = { code = 'csrf-invalid', message = 'bad or missing X-CSRF-Token' } })
    end
  end

  local body = {}
  if req.body and req.body ~= '' then
    local decoded, derr = req:json()
    if not decoded then
      return res:json(400, { error = { code = 'bad-request', message = 'malformed JSON body: ' .. tostring(derr) } })
    end
    body = decoded
  end

  local ctx = { params = params, query = req.query or {}, body = body, sess = sess,
                sessToken = sessTok, user = user, req = req, anonCsrf = anonCsrf }
  local ok, result = pcall(r.fn, ctx)
  if not ok then
    local e = result
    if type(e) == 'table' and e.code then
      return res:json(STATUS[e.code] or 500, { error = { code = e.code, message = e.message } })
    end
    io.stderr:write('devhub: handler error in ' .. r.key .. ': ' .. tostring(e) .. '\n')
    return res:json(500, { error = { code = 'internal', message = 'handler error' } })
  end

  if ctx.setCookie then
    res:header('Set-Cookie', 'hubsess=' .. ctx.setCookie ..
               '; HttpOnly; SameSite=Strict; Path=/; Max-Age=86400')
  elseif ctx.clearCookie then
    res:header('Set-Cookie', 'hubsess=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0')
  end
  res:header('Cache-Control', 'no-store')
  return res:json(200, result or OKAY())
end

-- =============================================================== websocket ===

local function wsHandler(req, res)
  local sess, sessTok = sessionOf(req)
  local route = httpserver.websocketRoute(wsserver, {
    -- allowedOrigins defaults to same-origin, which is what the panel needs
    user = { sess = sess, sessToken = sessTok, ready = false, subs = {} },
    onOpen = function (ws) liveSockets[ws] = true end,
    onClose = function (ws) liveSockets[ws] = nil end,
    onMessage = function (ws, msg)
      local ok, f = pcall(json.decode, msg)
      if not ok or type(f) ~= 'table' then return end
      local u = ws.user
      if f.type == 'auth' then
        local s = u.sess
        if not s or f.csrf ~= s.csrf then
          ws:close(4401, 'unauthenticated')
          return
        end
        u.ready = true
        ws:send(json.encode({ event = 'ready', data = { version = 'devhub-1.0', t = nowMs() } }))
        return
      end
      if not u.ready then return end
      if f.type == 'subscribe' then
        u.subs = { logs = f.logs, chat = f.chat }
      elseif f.type == 'ping' then
        ws:send(json.encode({ event = 'pong', data = { t = f.t } }))
      end
    end
  })
  return route(req, res)
end

-- ==================================================================== main ===

local serveStatic = httpserver.static{ root = ROOT .. '/panel', index = 'index.html' }

local server = httpserver.new{
  host = OPT.host, port = OPT.port,
  allowedHosts = { '127.0.0.1', 'localhost' },
  maxBodyBytes = 1024 * 1024,
  onRequest = function (req, res)
    if req.path == '/ws' then return wsHandler(req, res) end
    if req.path:sub(1, 5) == '/api/' then return apiHandler(req, res) end
    if req.path == '/' then req.rawPath = '/index.html' end
    return serveStatic(req, res)
  end
}

local port, err = server:start()
if not port then
  io.stderr:write('devhub: cannot listen: ' .. tostring(err) .. '\n')
  os.exit(1)
end

math.randomseed(os.time())

io.write('devhub  http://' .. OPT.host .. ':' .. port .. '/\n')
io.write('        panel   http://' .. OPT.host .. ':' .. port .. '/index.html\n')
io.write('        tests   http://' .. OPT.host .. ':' .. port .. '/test/index.html\n')
io.write('        mock    http://' .. OPT.host .. ':' .. port .. '/index.html?mock=1\n')
io.write('bootstrap token: ' .. BOOTSTRAP .. '\n')
io.write('(first run: the panel asks for that token and for a NEW administrator password;\n')
io.write(' the password is hashed with PBKDF2 on arrival and is never written anywhere)\n')
io.flush()

sched.every(1000, tick)

if OPT.selftest then
  -- a smoke test for CI: come up, prove the route table is complete, exit.
  local names = {}
  for _, r in ipairs(ROUTES) do names[#names + 1] = r.key end
  table.sort(names)
  io.write('routes(' .. #names .. '):\n  ' .. table.concat(names, '\n  ') .. '\n')
  sched.after(50, function () server:stop(); sched.stop() end)
end

sched.run()
