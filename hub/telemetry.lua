--[[============================================================================
hub/telemetry.lua -- per-instance live state, rolling history, and the fan-out to
                     subscribed panel WebSockets.

  local telemetry = require('hub.telemetry')
  local tel = telemetry.new{ sup = supervisor, storage = storage }
  tel:install()

  -- fed by hub/supervisor.lua's callbacks
  tel:onWorkerEvent(instanceId, event, data)
  tel:onWorkerLog(instanceId, line)
  tel:onState(instanceId, state, detail)

  -- panel sockets
  tel:addSocket(ws)          -- ws.user = { userId=, role=, visible=function(id) }
  tel:removeSocket(ws)
  tel:publish('instance', { id = ..., instance = ... }, { instanceId = ... })

  -- reads for the RPC layer
  tel:live(id)   tel:history(id, since)   tel:flush()

--------------------------------------------------------------------------------
WHY THE FAN-OUT IS QUEUED AND NOT A DIRECT ws:send()
--------------------------------------------------------------------------------
The hub is single-threaded.  A browser that stops reading (a backgrounded tab, a
laptop that slept, a phone on a train) leaves its TCP window shut, so every
ws:send() lands in lib/socket.lua's outbox instead of on the wire.  With N
instances pushing status at 1 Hz and M such sockets that is unbounded memory and,
worse, unbounded work per reactor turn -- one slow browser would stall telemetry
for everybody.

So every socket has its own small mailbox and the reactor drains them on a timer:

  * COALESCED events ('status', 'stats', 'instance') are keyed by event+instance.
    A newer frame REPLACES the pending one -- the panel only ever wants the
    latest value, so a 5-second stall costs 1 frame, not 5.
  * DISCRETE events ('log', 'chat', 'error', ...) go into a FIFO capped at
    `maxQueue` (200) frames.  Past the cap the OLDEST are dropped and a single
    {event='dropped', data={n=...}} frame tells the panel its log has a hole.
  * A socket whose transport backlog is already over `maxOutbox` (256 KiB) is
    skipped entirely for that round: nothing is queued into a pipe that is not
    draining.
  * At most `maxPerFlush` (60) frames leave per socket per flush tick
    (`sendEveryMs`, 200 ms), so the cost of one turn is bounded by
    (sockets x 60) regardless of how much telemetry arrived.

--------------------------------------------------------------------------------
HISTORY
--------------------------------------------------------------------------------
One point per instance every `historyEveryMs` (30 s), a ring of `historyMax`
(400) points -- 3h20m, which is what the panel's charts draw.  Points are
flushed to `<data>/history/<instanceId>.json` every `flushMs` (60 s) and on
shutdown, and read back at startup, so a hub restart does not blank the charts.
The flush is a small JSON file written through storage's atomic write-and-rename;
at 400 points x ~90 bytes it is ~36 KB per instance and never grows.

Lua 5.1 / LuaJIT: no goto, math.floor for integer division.
============================================================================]]

local json  = require('lib.json')
local sys   = require('lib.sys')
local sched = require('lib.sched')

local M = {}

local floor = math.floor
local function nowMs() return sys.nowMs() end
local function wallMs() return os.time() * 1000 end

-- Events whose newest value supersedes the pending one.
local COALESCE = { status = true, stats = true, instance = true, supplies = true }

local DEFAULTS = {
  historyEveryMs = 30000,
  historyMax     = 400,
  flushMs        = 60000,
  sendEveryMs    = 200,
  maxQueue       = 200,
  maxPerFlush    = 60,
  maxOutbox      = 256 * 1024,
}

-- ================================================================== the ring =
local function ringPush(hist, point, cap)
  hist[#hist + 1] = point
  if #hist > cap then table.remove(hist, 1) end
end

-- =================================================================== object ==
local T = {}
T.__index = T
M.T = T

function M.new(opts)
  opts = opts or {}
  local t = setmetatable({}, T)
  for k, v in pairs(DEFAULTS) do t[k] = opts[k] ~= nil and opts[k] or v end
  t.sup      = opts.sup
  t.storage  = opts.storage
  t.log      = opts.log or require('lib.log')
  t.sched    = opts.sched or sched
  t.sockets  = {}            -- array of subscriber records
  t.byWs     = {}            -- ws -> record
  t.snap     = {}            -- instanceId -> merged live snapshot
                             -- (NOT `t.live`: T:live(id) is the accessor)
  t.hist     = {}            -- instanceId -> array of points
  t.dirty    = {}            -- instanceId -> true
  t.lastPoint= {}            -- instanceId -> ms of the last history point
  t.timers   = {}
  t.installed = false
  t.maxPerUser = tonumber(opts.maxPerUser) or T.MAX_PER_USER
  t.stat = { queued = 0, sent = 0, dropped = 0, skipped = 0 }
  return t
end

-- ------------------------------------------------------------------ live state
function T:live(id)
  id = tostring(id)
  return self.snap[id]
end

function T:merge(id, data)
  id = tostring(id)
  local l = self.snap[id]
  if not l then l = {}; self.snap[id] = l end
  if type(data) == 'table' then
    for k, v in pairs(data) do
      if k ~= 'id' then l[k] = v end
    end
  end
  return l
end

function T:forget(id)
  id = tostring(id)
  self.snap[id] = nil
  self.hist[id] = nil
  self.dirty[id] = nil
  self.lastPoint[id] = nil
  if self.storage and self.storage.deleteFile then
    pcall(function() self.storage:deleteFile('history/' .. id .. '.json') end)
  end
end

-- ------------------------------------------------------------------- history
function T:history(id, since)
  id = tostring(id)
  local h = self.hist[id]
  if not h then return {} end
  since = tonumber(since) or 0
  if since <= 0 then return h end
  local out = {}
  for i = 1, #h do if (h[i].t or 0) >= since then out[#out + 1] = h[i] end end
  return out
end

function T:_point(id)
  local l = self.snap[id]
  if not l then return nil end
  return {
    t   = wallMs(),
    exp = l.expPerHour or 0,
    mon = l.moneyPerHour or 0,
    kil = l.killsPerHour or 0,
    hp  = l.hp or 0,
    mp  = l.mana or 0,
    lvl = l.level or 0,
  }
end

function T:_sampleHistory()
  local now = nowMs()
  local ids = {}
  for id in pairs(self.snap) do ids[#ids + 1] = id end
  for i = 1, #ids do
    local id = ids[i]
    local last = self.lastPoint[id]
    if not last or (now - last) >= self.historyEveryMs then
      local st = self.sup and self.sup:state(id) or nil
      if st and st ~= 'stopped' and st ~= 'error' then
        local p = self:_point(id)
        if p then
          local h = self.hist[id]
          if not h then h = {}; self.hist[id] = h end
          ringPush(h, p, self.historyMax)
          self.dirty[id] = true
        end
      end
      self.lastPoint[id] = now
    end
  end
end

--- Write every dirty history ring out.  Small files, atomic rename, at most one
--- per instance per flush tick -- never a blocking read of anything large.
function T:flush()
  if not self.storage then self.dirty = {}; return 0 end
  local n = 0
  for id in pairs(self.dirty) do
    local h = self.hist[id]
    if h and #h > 0 then
      local ok, enc = pcall(json.encode, { v = 1, id = id, points = h })
      if ok then
        local wrote = self.storage.writeFile and
                      select(1, self.storage:writeFile('history/' .. id .. '.json', enc))
        if wrote then n = n + 1 end
      end
    end
    self.dirty[id] = nil
  end
  return n
end

--- Read the persisted rings back at startup.  Called once, before the reactor runs.
function T:load(instanceIds)
  if not self.storage or not self.storage.readFile then return 0 end
  local n = 0
  for _, id in ipairs(instanceIds or {}) do
    id = tostring(id)
    local raw = self.storage:readFile('history/' .. id .. '.json')
    if raw and #raw > 0 then
      local ok, doc = pcall(json.decode, raw)
      if ok and type(doc) == 'table' and type(doc.points) == 'table' then
        local pts = doc.points
        while #pts > self.historyMax do table.remove(pts, 1) end
        self.hist[id] = pts
        n = n + 1
      end
    end
  end
  return n
end

-- ============================================================== subscribers ==
--- Register a panel WebSocket.  `ws.user` must carry:
---   userId, role ('admin'|'user'), visible(instanceId) -> boolean
--- Per-user socket cap.  wsserver's own maxConnections bounds the process; this
--- bounds one ACCOUNT, so a single signed-in session cannot take the whole
--- allowance and lock everybody else out.  The OLDEST socket of that user is
--- closed rather than refusing the new one: a panel that reconnects after a
--- laptop sleep must not be the one that loses.
T.MAX_PER_USER = 8

function T:addSocket(ws)
  if self.byWs[ws] then return self.byWs[ws] end
  local uid = ws.user and ws.user.userId or nil
  if uid then
    local cap = tonumber(self.maxPerUser) or T.MAX_PER_USER
    local mine = {}
    for i = 1, #self.sockets do
      local r = self.sockets[i]
      if r.user and r.user.userId == uid then mine[#mine + 1] = r end
    end
    local over = #mine - cap + 1
    for i = 1, over do
      local victim = mine[i]
      if victim then
        self:removeSocket(victim.ws)
        pcall(function() victim.ws:close(1013, 'too many sockets for this account') end)
      end
    end
  end
  local rec = {
    ws = ws, user = ws.user or {},
    coalesced = {}, order = {}, fifo = {}, fifoHead = 1, fifoTail = 0,
    dropped = 0, sent = 0,
    -- panel/rpc.js's {type:'subscribe'} frame.  nil = not subscribed, so a socket
    -- that never subscribes never receives a log or chat line for ANY instance.
    subs = { logs = nil, chat = nil },
  }
  self.byWs[ws] = rec
  self.sockets[#self.sockets + 1] = rec
  return rec
end

function T:removeSocket(ws)
  local rec = self.byWs[ws]
  if not rec then return false end
  self.byWs[ws] = nil
  for i = 1, #self.sockets do
    if self.sockets[i] == rec then table.remove(self.sockets, i); break end
  end
  return true
end

function T:socketCount() return #self.sockets end

--- Set a socket's log/chat subscriptions.  Either may be nil (unsubscribe) and
--- either may name an instance the user cannot see -- visibleTo() still decides,
--- so a subscription can never widen what a socket is allowed to receive.
function T:setSubs(ws, logsId, chatId)
  local rec = self.byWs[ws]
  if not rec then return false end
  rec.subs = { logs = logsId ~= nil and tostring(logsId) or nil,
               chat = chatId ~= nil and tostring(chatId) or nil }
  return true
end

function T:subsOf(ws)
  local rec = self.byWs[ws]
  return rec and rec.subs or nil
end

local function visibleTo(rec, opts)
  if opts.adminOnly and rec.user.role ~= 'admin' then return false end
  -- A log or chat line goes ONLY to a socket that asked for that instance.  A
  -- socket in the older /api/events dialect has no subs table and gets everything
  -- it may see, which is what the hub's own tests drive.
  if opts.subscription and rec.subs then
    if rec.subs[opts.subscription] ~= tostring(opts.instanceId or '') then return false end
  end
  if opts.userId and rec.user.userId ~= opts.userId and rec.user.role ~= 'admin' then return false end
  if opts.instanceId then
    local fn = rec.user.visible
    if type(fn) == 'function' then
      local ok, vis = pcall(fn, opts.instanceId)
      if not ok or not vis then return false end
    end
  end
  return true
end

local function enqueue(self, rec, event, data, key)
  -- do not feed a pipe that is not draining
  local conn = rec.ws and rec.ws.conn
  if conn and conn.outboxLen and conn.outboxLen > self.maxOutbox then
    self.stat.skipped = self.stat.skipped + 1
    rec.dropped = rec.dropped + 1
    return false
  end
  if key then
    if rec.coalesced[key] == nil then rec.order[#rec.order + 1] = key end
    rec.coalesced[key] = { event = event, data = data }
  else
    local n = rec.fifoTail - rec.fifoHead + 1
    if n >= self.maxQueue then
      rec.fifo[rec.fifoHead] = nil
      rec.fifoHead = rec.fifoHead + 1
      rec.dropped = rec.dropped + 1
      self.stat.dropped = self.stat.dropped + 1
    end
    rec.fifoTail = rec.fifoTail + 1
    rec.fifo[rec.fifoTail] = { event = event, data = data }
  end
  self.stat.queued = self.stat.queued + 1
  return true
end

--- Queue one event for every socket allowed to see it.
---   opts.instanceId  -> only sockets whose visible(id) says yes
---   opts.adminOnly   -> only admins
---   opts.userId      -> that user (admins always included)
---   opts.key         -> override the coalescing key ('' disables coalescing)
function T:publish(event, data, opts)
  opts = opts or {}
  local key = nil
  if opts.key ~= nil then
    if opts.key ~= '' then key = opts.key end
  elseif COALESCE[event] then
    key = event .. '|' .. tostring(opts.instanceId or (type(data) == 'table' and data.id) or '-')
  end
  for i = 1, #self.sockets do
    local rec = self.sockets[i]
    if rec.ws:isOpen() and visibleTo(rec, opts) then
      enqueue(self, rec, event, data, key)
    end
  end
end

--- Send one event to one socket immediately (the hello frame, an RPC echo).
function T:sendTo(ws, event, data)
  if not ws or not ws:isOpen() then return false end
  local ok, payload = pcall(json.encode, { event = event, data = data })
  if not ok then return false end
  return ws:send(payload) and true or false
end

function T:_drain()
  local sendEach = self.maxPerFlush
  for i = #self.sockets, 1, -1 do
    local rec = self.sockets[i]
    if not rec.ws:isOpen() then
      table.remove(self.sockets, i)
      self.byWs[rec.ws] = nil
    else
      local budget = sendEach
      local conn = rec.ws.conn
      local backed = conn and conn.outboxLen and conn.outboxLen > self.maxOutbox
      if rec.dropped > 0 and not backed then
        local n = rec.dropped
        rec.dropped = 0
        self:sendTo(rec.ws, 'dropped', { n = n })
        budget = budget - 1
      end
      if not backed then
        -- coalesced first: the panel wants current values before backlog
        local order = rec.order
        local k = 1
        while k <= #order and budget > 0 do
          local key = order[k]
          local frame = rec.coalesced[key]
          rec.coalesced[key] = nil
          if frame then
            if self:sendTo(rec.ws, frame.event, frame.data) then
              rec.sent = rec.sent + 1
              self.stat.sent = self.stat.sent + 1
            end
            budget = budget - 1
          end
          k = k + 1
        end
        if k > #order then
          rec.order = {}
        else
          local rest = {}
          for j = k, #order do rest[#rest + 1] = order[j] end
          rec.order = rest
        end
        while budget > 0 and rec.fifoHead <= rec.fifoTail do
          local frame = rec.fifo[rec.fifoHead]
          rec.fifo[rec.fifoHead] = nil
          rec.fifoHead = rec.fifoHead + 1
          if frame then
            if self:sendTo(rec.ws, frame.event, frame.data) then
              rec.sent = rec.sent + 1
              self.stat.sent = self.stat.sent + 1
            end
            budget = budget - 1
          end
        end
        if rec.fifoHead > rec.fifoTail then rec.fifoHead, rec.fifoTail = 1, 0 end
      end
    end
  end
end

-- ============================================ supervisor -> telemetry bridge =
function T:onWorkerEvent(instanceId, event, data)
  local id = tostring(instanceId)
  if event == 'status' or event == 'stats' then
    local l = self:merge(id, data)
    local payload = { id = id }
    for k, v in pairs(l) do payload[k] = v end
    self:publish(event, payload, { instanceId = id })
    return
  end
  if event == 'chat' then
    self:publish('chat', data, { instanceId = id, key = '', subscription = 'chat' })
    return
  end
  if event == 'log' then
    self:publish('log', data, { instanceId = id, key = '', subscription = 'logs' })
    return
  end
  local d = type(data) == 'table' and data or {}
  if d.id == nil then d.id = id end
  self:publish(event, d, { instanceId = id, key = '' })
end

function T:onWorkerLog(instanceId, line)
  self:publish('log', line, { instanceId = tostring(instanceId), key = '',
                              subscription = 'logs' })
end

function T:onState(instanceId, state, detail)
  local id = tostring(instanceId)
  local l = self:merge(id, {})
  l.state = state
  local info = self.sup and self.sup:info(id) or {}
  self:publish('status', {
    id = id, state = state, detail = detail,
    uptimeMs = info.uptimeMs, onlineMs = info.onlineMs,
    reconnects = info.reconnects, pid = info.pid,
    hp = l.hp, maxHp = l.maxHp, mana = l.mana, maxMana = l.maxMana,
    level = l.level, expPercent = l.expPercent,
    target = l.target, waypoint = l.waypoint,
    botEnabled = l.botEnabled,
  }, { instanceId = id })
end

-- =================================================================== timers ==
function T:install()
  if self.installed then return end
  self.installed = true
  local t = self
  self.timers[#self.timers + 1] = self.sched.every(self.sendEveryMs, function() t:_drain() end)
  self.timers[#self.timers + 1] = self.sched.every(math.min(self.historyEveryMs, 5000),
                                                   function() t:_sampleHistory() end)
  self.timers[#self.timers + 1] = self.sched.every(self.flushMs, function() t:flush() end)
end

function T:uninstall()
  for _, id in ipairs(self.timers) do pcall(self.sched.cancel, id) end
  self.timers = {}
  self.installed = false
end

function T:stats()
  return { sockets = #self.sockets, queued = self.stat.queued, sent = self.stat.sent,
           dropped = self.stat.dropped, skipped = self.stat.skipped }
end

return M
