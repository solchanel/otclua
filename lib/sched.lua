-- lib/sched.lua -- the single-threaded reactor every part of the client runs on.
--
-- One loop turn:
--   1. drain sched.post() work
--   2. compute the select() timeout = min(next timer deadline, 50 ms), clamped to >= 0
--   3. socket.select() over every registered socket (select() on Windows,
--      poll() on Linux -- lib/socket.lua hides the difference behind one name)
--        read   : all registered sockets (+ listeners)
--        write  : sockets with a non-empty outbox, and sockets still connecting
--        except : sockets still connecting  -- on Windows a FAILED non-blocking
--                 connect is signalled ONLY here, never in writefds.  On Linux
--                 the same socket comes back POLLOUT-ready with POLLERR|POLLHUP,
--                 which lib/socket.lua reports in BOTH the write and the except
--                 list, so this loop needs no branch of its own.
--      with zero sockets registered the loop sleeps for the same interval instead
--      (Winsock select() with three empty sets returns WSAEINVAL, it does not sleep;
--      poll(NULL,0,ms) would sleep, but one code path for both is simpler)
--   4. fire ready sockets: except -> writable (settle connect / drain outbox) -> readable
--   5. fire due timers, rescheduling repeats as at = at + every (drift-free, with a
--      catch-up clamp after a long stall)
--
-- API (docs/API.md):
--   sched.every(ms, fn) -> id      sched.after(ms, fn) -> id      sched.cancel(id)
--   sched.onSocket(sock, onReadable [, onWritable])
--   sched.removeSocket(sock)
--   sched.run()  sched.stop()  sched.post(fn)
--
-- onReadable(sock) is called when the socket has data (or EOF) pending; the owner
-- calls sock:recv() itself and sees nil,'closed' on peer shutdown.  Errors raised in
-- callbacks are caught and reported through sched.onError (default: log.error).

local sys    = require('lib.sys')
local socket = require('lib.socket')

local sched = {}

local MAX_WAIT = 50            -- ms; select() never sleeps longer than this

local timers   = {}            -- array of {id, at, every, fn}
local byId     = {}            -- id -> timer
local socks    = {}            -- tonumber(fd) -> {sock, onReadable, onWritable}
local sockList = {}            -- array of the same entries (stable iteration order)
local posts    = {}
local nextId   = 1

sched.running = false

--- Error sink for callbacks. Replaceable; defaults to log.error (loaded lazily so
--- that requiring sched never drags in a log file handle).
function sched.onError(what, err)
  local ok, log = pcall(require, 'lib.log')
  if ok then log.error('sched: %s: %s', what, tostring(err))
  else io.stderr:write('sched: ', tostring(what), ': ', tostring(err), '\n') end
end

local function guard(what, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then sched.onError(what, err) end
  return ok
end

-- ---------------------------------------------------------------- timers ----
local function addTimer(ms, fn, every)
  ms = tonumber(ms) or 0
  if ms < 0 then ms = 0 end
  local t = { id = nextId, at = sys.nowMs() + ms, fn = fn, every = every and ms or nil }
  nextId = nextId + 1
  timers[#timers + 1] = t
  byId[t.id] = t
  return t.id
end

function sched.after(ms, fn) return addTimer(ms, fn, false) end
function sched.every(ms, fn) return addTimer(ms, fn, true) end

function sched.cancel(id)
  local t = byId[id]
  if not t then return false end
  byId[id] = nil
  t.dead = true
  for i = 1, #timers do
    if timers[i] == t then table.remove(timers, i); break end
  end
  return true
end

function sched.timerCount() return #timers end

function sched.post(fn)
  posts[#posts + 1] = fn
end

-- --------------------------------------------------------------- sockets ----
function sched.onSocket(sock, onReadable, onWritable)
  local key = socket.fdnum(sock)
  if not key then return nil, 'sched.onSocket: socket has no fd' end
  local e = socks[key]
  if e then
    e.sock, e.onReadable, e.onWritable = sock, onReadable, onWritable
    return true
  end
  e = { sock = sock, key = key, onReadable = onReadable, onWritable = onWritable }
  socks[key] = e
  sockList[#sockList + 1] = e
  return true
end

function sched.removeSocket(sock)
  local key = socket.fdnum(sock)
  if key == nil or not socks[key] then return false end
  socks[key] = nil
  for i = 1, #sockList do
    if sockList[i].key == key then table.remove(sockList, i); break end
  end
  return true
end

function sched.socketCount() return #sockList end

-- ------------------------------------------------------------------ loop ----
local rl, wl, el = {}, {}, {}

local function clear(t) for i = #t, 1, -1 do t[i] = nil end end

--- Run exactly one turn of the loop. maxWait defaults to 50 ms.
function sched.tick(maxWait)
  maxWait = maxWait or MAX_WAIT

  -- 1) posted work
  if #posts > 0 then
    local batch = posts
    posts = {}
    for i = 1, #batch do guard('post', batch[i]) end
  end

  -- 2) how long may we sleep?
  local now  = sys.nowMs()
  local wait = maxWait
  for i = 1, #timers do
    local d = timers[i].at - now
    if d < wait then wait = d end
  end
  if wait < 0 then wait = 0 end
  if wait > MAX_WAIT then wait = MAX_WAIT end
  if #posts > 0 then wait = 0 end

  -- 3) build the three select sets
  clear(rl); clear(wl); clear(el)
  for i = 1, #sockList do
    local s = sockList[i].sock
    local st = s.state
    if st ~= 'closed' then
      rl[#rl + 1] = s
      if st == 'connecting' then
        wl[#wl + 1] = s
        el[#el + 1] = s
      elseif s.outboxLen and s.outboxLen > 0 then
        wl[#wl + 1] = s
      end
    end
  end

  if #rl == 0 and #wl == 0 and #el == 0 then
    sys.sleepMs(wait > 1 and wait or 1)      -- no sockets: plain sleep, never a spin
  else
    local ready, err = socket.select(rl, wl, wait, el)
    if not ready then
      sched.onError('select', err)
      sys.sleepMs(1)
    else
      -- 4a) exceptional: a failed non-blocking connect lands here on Windows
      --     (exceptfds) and on Linux (POLLERR/POLLHUP); either way the verdict
      --     comes from getsockopt(SO_ERROR) inside _settleConnect.
      for i = 1, #ready.except do
        local s = ready.except[i]
        if s.state == 'connecting' then guard('connect', s._settleConnect, s) end
      end
      -- 4b) writable: settle a pending connect, then drain the outbox
      for i = 1, #ready.write do
        local s = ready.write[i]
        local e = socks[socket.fdnum(s)]
        -- a callback earlier in this batch may have closed s and opened a new
        -- socket that got the same fd number: only fire the owner's callback.
        if e and e.sock ~= s then e = nil end
        if s.state == 'connecting' then
          guard('connect', s._settleConnect, s)
        end
        if s.state == 'connected' and s.outboxLen and s.outboxLen > 0 then
          local ok, ferr = s:flush()
          if ok == nil then sched.onError('flush', ferr) end
        end
        if e and e.onWritable then guard('onWritable', e.onWritable, s) end
      end
      -- 4c) readable
      for i = 1, #ready.read do
        local s = ready.read[i]
        local e = socks[socket.fdnum(s)]
        if e and e.sock == s and e.onReadable and s.state ~= 'closed' then
          guard('onReadable', e.onReadable, s)
        end
      end
    end
  end

  -- 5) due timers, drift-free
  now = sys.nowMs()
  local i = 1
  while i <= #timers do
    local t = timers[i]
    if t.dead then
      table.remove(timers, i)
    elseif t.at <= now then
      if t.every then
        t.at = t.at + t.every
        if t.at <= now then t.at = now + t.every end   -- catch up after a long stall
        i = i + 1
      else
        byId[t.id] = nil
        table.remove(timers, i)
      end
      guard('timer', t.fn)
    else
      i = i + 1
    end
  end
end

function sched.run(maxWait)
  sched.running = true
  while sched.running do
    sched.tick(maxWait)
  end
  return true
end

function sched.stop()
  sched.running = false
end

--- Drop every timer and socket registration (used by tests and by reconnect paths).
function sched.reset()
  timers, byId, posts = {}, {}, {}
  socks, sockList = {}, {}
  sched.running = false
end

return sched
