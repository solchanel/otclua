-- hub/audit.lua -- the admin-only activity log: append-only JSONL, durable, rotating, queryable.
--
-- PANEL.md: "Append-only JSONL, one record per event: timestamp, actor (web account or `system`),
-- source IP, action, target, outcome.  The admin UI can filter by actor, action and time range.
-- Retention and rotation are configurable."
--
-- Admin-only ENFORCEMENT is the API layer's job -- this module has no idea who is asking.  What
-- it owns is that a record, once record() has returned, is on the disk platter, and that reading
-- the log back does not require holding it in memory.
--
-- ============================================================================================
-- RECORD SHAPE
-- ============================================================================================
--   {"action":"login.ok","actor":"arnold","actorId":"u_9f3a…","detail":"","ip":"127.0.0.1",
--    "outcome":"ok","seq":41,"t":1757000000123,"target":"arnold"}
--
--   t        wall-clock milliseconds (hub/storage.wallMs: anchored once, advanced monotonically,
--            so an NTP step cannot make the log go backwards mid-run)
--   actor    web-account name, or 'system' for anything the hub did on its own
--   actorId  the user id when there is one; absent for 'system' and for a failed login
--   ip       source address, or '-' when there is no request behind the event
--   action   dotted verb from ACTIONS below (login.ok, instance.start, exec, ...)
--   target   what it was done to (character name, script file, account label, ...)
--   outcome  'ok' | 'denied' | 'error'
--   detail   free text; the executed Lua for `exec`, the changed keys for a config change
--   seq      per-process counter, so two records in the same millisecond still order
--
-- Keys are emitted sorted by hub/storage.encodeCanon, which also escapes every control byte --
-- a newline inside `detail` (an uploaded script's source, a stack trace) therefore cannot break
-- the one-record-per-line invariant.
--
-- ============================================================================================
-- DURABILITY
-- ============================================================================================
-- Default `sync = 'always'`: every record is written and fsync()ed (FlushFileBuffers on Windows)
-- before record() returns.  That is the only policy under which the LAST record survives a
-- crash, and the last record is the interesting one -- it is what the intruder did just before
-- the machine went down.  The cost is one fsync per audited action, which on PANEL.md's traffic
-- (logins, start/stop, uploads -- not telemetry) is nothing.
--
-- `sync = 'batch'` buffers and flushes on flush(); it exists for a bulk import and is documented
-- as LOSSY on a crash.  Do not run the hub on it.
--
-- The file is opened O_APPEND (FILE_APPEND_DATA on Windows), so a write always lands at the true
-- end of file even if something else appended behind our back, and a partially written last line
-- from a torn write is skipped by the reader (it will not parse) instead of poisoning a query.
--
-- ============================================================================================
-- ROTATION AND RETENTION
-- ============================================================================================
-- When the current file would pass `maxBytes` (default 8 MB) it is closed and shifted down:
-- audit.jsonl -> audit.1.jsonl -> audit.2.jsonl ... and audit.<keep>.jsonl (default keep = 5) is
-- deleted.  Rotation happens BEFORE the record that would overflow, so no record is ever split
-- across two files.  Queries read the current file and the rotated ones as one logical stream,
-- so rotation is invisible to the admin UI.
--
-- ============================================================================================
-- QUERY
-- ============================================================================================
-- Newest-first, with real paging, and it never reads a whole log file into memory: the scanner
-- walks each file BACKWARDS in 64 KB chunks and stops as soon as it has `limit` matches.  A
-- typical "last 100 events" therefore touches ~64 KB regardless of how big the log is.
--
-- A single call is additionally capped by `maxScanBytes` (default 1 MB) so that a filter which
-- matches nothing cannot turn into a multi-second stall of the hub's single reactor thread:
-- when the budget runs out the call returns what it has plus a `nextCursor`, and the UI asks for
-- the next page.  A cursor is a file index plus a byte offset that is always a line boundary; it
-- is short-lived by construction and is invalidated by a rotation (the indexes shift), which is
-- why it is opaque and why the UI should re-query rather than cache one.
--
-- ============================================================================================
-- API
-- ============================================================================================
--   audit.open{ dir=, name='audit', maxBytes=, keep=, sync='always'|'batch', recent=,
--               now=, log= } -> a | nil, err
--   a:record{ actor=, actorId=, ip=, action=, target=, outcome=, detail= } -> rec | nil, err
--   a:system(action, target, outcome, detail)          -- actor = 'system', ip = '-'
--   a:query{ actor=, action=, actionPrefix=, outcome=, actorId=, from=, to=, limit=,
--            cursor=, maxScanBytes=, chunkBytes=, order='desc'|'asc' }
--          -> { rows = {...}, nextCursor = string|nil, scanned = bytes, files = n }
--   a:recent([n])        -> the in-memory tail, newest last (for the live websocket push)
--   a:files()            -> { {path=, bytes=, index=} } newest first
--   a:rotate()           -> true | nil, err        (forced; normally automatic)
--   a:flush()            -> true | nil, err
--   a:close()
--   audit.ACTIONS        the vocabulary PANEL.md lists, for the UI's filter dropdown

local storage = require('hub.storage')
local json    = require('lib.json')

local fs = storage.fs
local sformat, ssub, sfind, sgsub = string.format, string.sub, string.find, string.gsub
local slower = string.lower
local floor, min, max = math.floor, math.min, math.max

local M = {}

M.DEFAULT_MAX_BYTES     = 8 * 1024 * 1024
M.DEFAULT_KEEP          = 5
M.DEFAULT_LIMIT         = 100
M.MAX_LIMIT             = 1000
M.DEFAULT_SCAN_BUDGET   = 1024 * 1024
M.CHUNK                 = 64 * 1024
M.MAX_DETAIL            = 8192
M.MAX_FIELD             = 256
M.DEFAULT_RECENT        = 256

-- PANEL.md's list, plus the handful the supervisor needs.  Not enforced -- an unknown action is
-- accepted and logged -- but it is the vocabulary the UI's filter offers and the set the
-- hub should stick to so filtering by action stays useful.
M.ACTIONS = {
  'login.ok', 'login.fail', 'logout', 'session.revoke',
  'user.create', 'user.delete', 'user.password', 'user.role', 'user.disable',
  'user.canExec',
  'account.create', 'account.update', 'account.delete',
  'character.create', 'character.update', 'character.delete',
  'proxy.create', 'proxy.change', 'proxy.delete',
  'instance.create', 'instance.start', 'instance.stop', 'instance.delete', 'instance.config',
  'script.upload', 'script.assign', 'script.enable', 'script.delete',
  'exec', 'hub.start', 'hub.stop', 'hub.bootstrap', 'audit.throttled',
}

local OUTCOMES = { ok = true, denied = true, error = true }

local nullLog = { info = function() end, warn = function() end, error = function() end,
                  debug = function() end }

-- ================================================================== sanitising

local function cleanField(v, cap)
  if v == nil then return nil end
  local s = tostring(v)
  -- Control bytes are escaped by encodeCanon anyway; folding them to spaces keeps the log
  -- readable and keeps a pasted terminal escape sequence out of an admin's console.
  s = sgsub(s, '[%z\1-\31\127]', ' ')
  if #s > cap then s = ssub(s, 1, cap - 3) .. '...' end
  return s
end

-- ==================================================================== Audit

local Audit = {}
Audit.__index = Audit

function M.open(opts)
  opts = opts or {}
  local dir = opts.dir
  if type(dir) ~= 'string' or dir == '' then return nil, 'audit.open: dir is required' end
  dir = dir:gsub('\\', '/'):gsub('/+$', '')
  local ok, err = fs.mkdirp(dir)
  if not ok then return nil, 'audit.open: ' .. tostring(err) end

  local name = opts.name or 'audit'
  if not name:match('^[%w_%-]+$') then return nil, 'audit.open: illegal log name' end

  local self = setmetatable({
    dir       = dir,
    name      = name,
    maxBytes  = tonumber(opts.maxBytes) or M.DEFAULT_MAX_BYTES,
    keep      = tonumber(opts.keep) or M.DEFAULT_KEEP,
    sync      = (opts.sync == 'batch') and 'batch' or 'always',
    now       = opts.now or storage.wallMs,
    log       = opts.log or nullLog,
    recentMax = tonumber(opts.recent) or M.DEFAULT_RECENT,
    ring      = {},
    seq       = 0,
    pending   = {},
    pendingBytes = 0,
    budget    = {},                         -- actor -> token bucket, see _budgetOk
    budgetBurst  = tonumber(opts.budgetBurst) or M.DEFAULT_BUDGET_BURST,
    budgetPerSec = tonumber(opts.budgetPerSec) or M.DEFAULT_BUDGET_PER_SEC,
  }, Audit)
  if self.maxBytes < 4096 then self.maxBytes = 4096 end
  if self.keep < 0 then self.keep = 0 end

  self.path  = self:_pathFor(0)
  self.bytes = fs.size(self.path) or 0
  local h, herr = fs.openAppend(self.path)
  if not h then return nil, 'audit.open: ' .. tostring(herr) end
  self.handle = h
  return self
end

function Audit:_pathFor(i)
  if i == 0 then return sformat('%s/%s.jsonl', self.dir, self.name) end
  return sformat('%s/%s.%d.jsonl', self.dir, self.name, i)
end

--- Every file that makes up the log, newest first.  Index 1 is the live file.
function Audit:files()
  local out = { { path = self.path, bytes = self.bytes, index = 0 } }
  for i = 1, self.keep do
    local p = self:_pathFor(i)
    local sz = fs.size(p)
    if sz then out[#out + 1] = { path = p, bytes = sz, index = i } end
  end
  return out
end

--- Close, shift every file down one, drop what falls off the end, reopen.  Renaming needs the
--- handle closed on Windows, so the order here is not negotiable.
function Audit:rotate()
  local fok, ferr = self:flush()
  if not fok then return nil, ferr end
  fs.close(self.handle)
  self.handle = nil

  if self.keep <= 0 then
    fs.remove(self.path)
  else
    fs.remove(self:_pathFor(self.keep))
    for i = self.keep - 1, 1, -1 do
      local from = self:_pathFor(i)
      if fs.exists(from) then fs.rename(from, self:_pathFor(i + 1)) end
    end
    local rok, rerr = fs.rename(self.path, self:_pathFor(1))
    if not rok then
      -- Reopen so the log keeps working even if the shift failed.
      self.handle = fs.openAppend(self.path)
      return nil, 'audit.rotate: ' .. tostring(rerr)
    end
  end

  local h, herr = fs.openAppend(self.path)
  if not h then return nil, 'audit.rotate: reopen failed: ' .. tostring(herr) end
  self.handle = h
  self.bytes  = 0
  fs.fsyncDir(self.dir)
  self.log.info('audit: rotated %s', self.path)
  return true
end

function Audit:flush()
  if #self.pending == 0 then return true end
  local blob = table.concat(self.pending)
  self.pending, self.pendingBytes = {}, 0
  local ok, err = fs.appendSync(self.handle, blob)
  if not ok then return nil, 'audit: append failed: ' .. tostring(err) end
  return true
end

--- Per-actor write budget.
---
--- The log rotates by size and keeps `keep` files, so an actor who can make the
--- hub write records faster than anybody reads them can scroll every genuine
--- record out of retention -- which is an audit-ERASING primitive, not merely a
--- noisy one.  Each actor therefore gets a token bucket: `budgetBurst` records
--- immediately and `budgetPerSec` sustained.  Going over does not lose the fact
--- that something happened: ONE `audit.throttled` record is written for that
--- actor, naming how many were suppressed, and normal recording resumes as soon
--- as the bucket refills.  'system' is exempt -- those records come from the hub
--- itself, not from a request.
M.DEFAULT_BUDGET_BURST   = 200
M.DEFAULT_BUDGET_PER_SEC = 20

function Audit:_budgetOk(actor)
  if not actor or actor == '' or actor == 'system' then return true end
  local now = self.now()
  local b = self.budget[actor]
  if not b then
    b = { tokens = self.budgetBurst, at = now, suppressed = 0, warned = false }
    self.budget[actor] = b
  end
  local dt = (now - b.at) / 1000
  if dt > 0 then
    b.tokens = min(self.budgetBurst, b.tokens + dt * self.budgetPerSec)
    b.at = now
  end
  if b.tokens >= 1 then
    b.tokens = b.tokens - 1
    if b.warned and b.suppressed > 0 then
      -- resume: say how many were dropped, then carry on normally
      local n = b.suppressed
      b.suppressed, b.warned = 0, false
      self:_write{ actor = actor, action = 'audit.throttled', outcome = 'error',
                   target = actor,
                   detail = ('%d records from this actor were suppressed by the write budget')
                            :format(n) }
    end
    return true
  end
  b.suppressed = b.suppressed + 1
  if not b.warned then
    b.warned = true
    self:_write{ actor = actor, action = 'audit.throttled', outcome = 'error', target = actor,
                 detail = 'write budget exhausted -- further records from this actor are ' ..
                          'suppressed until it refills' }
  end
  return false
end

--- Append one record.  Returns the stored record (the caller pushes it to the admin sockets).
function Audit:record(ev)
  if type(ev) ~= 'table' then return nil, 'audit.record: a table is required' end
  if not self:_budgetOk(cleanField(ev.actor, M.MAX_FIELD)) then
    return nil, 'audit: write budget exhausted for this actor'
  end
  return self:_write(ev)
end

function Audit:_write(ev)
  local action = cleanField(ev.action, 64)
  if not action or action == '' then return nil, 'audit.record: action is required' end
  if not action:match('^[%w][%w%.%-_]*$') then
    return nil, 'audit.record: illegal action ' .. action
  end
  local outcome = cleanField(ev.outcome, 16) or 'ok'
  if not OUTCOMES[outcome] then outcome = 'error' end

  self.seq = self.seq + 1
  local rec = {
    t       = ev.t and floor(tonumber(ev.t) or 0) or self.now(),
    seq     = self.seq,
    actor   = cleanField(ev.actor, M.MAX_FIELD) or 'system',
    actorId = cleanField(ev.actorId, 64),
    ip      = cleanField(ev.ip, 64) or '-',
    action  = action,
    target  = cleanField(ev.target, M.MAX_FIELD) or '',
    outcome = outcome,
    detail  = cleanField(ev.detail, M.MAX_DETAIL) or '',
  }

  local eok, line = pcall(storage.encodeCanon, rec)
  if not eok then return nil, 'audit.record: encoding failed: ' .. tostring(line) end
  line = line .. '\n'

  -- Rotate BEFORE the record that would overflow, so a record is never split across files.
  if self.bytes > 0 and (self.bytes + self.pendingBytes + #line) > self.maxBytes then
    local rok, rerr = self:rotate()
    if not rok then self.log.error('%s', tostring(rerr)) end
  end

  if self.sync == 'batch' then
    self.pending[#self.pending + 1] = line
    self.pendingBytes = self.pendingBytes + #line
  else
    local ok, err = fs.appendSync(self.handle, line)
    if not ok then return nil, 'audit: append failed: ' .. tostring(err) end
  end
  self.bytes = self.bytes + #line

  local ring = self.ring
  ring[#ring + 1] = rec
  if #ring > self.recentMax then table.remove(ring, 1) end
  return rec
end

function Audit:system(action, target, outcome, detail)
  return self:record{ actor = 'system', ip = '-', action = action, target = target,
                      outcome = outcome or 'ok', detail = detail }
end

function Audit:recent(n)
  local ring = self.ring
  n = min(tonumber(n) or #ring, #ring)
  local out = {}
  for i = #ring - n + 1, #ring do out[#out + 1] = ring[i] end
  return out
end

function Audit:close()
  self:flush()
  if self.handle then fs.close(self.handle); self.handle = nil end
  return true
end

-- ===================================================================== query

local function matches(rec, f)
  if f.actor and rec.actor ~= f.actor then return false end
  -- Free text, applied HERE rather than over a page the caller already holds:
  -- filtering after the limit meant a search silently missed every match outside
  -- the current page while still reporting a nextCursor, so "no matches" and "no
  -- matches on this page" looked identical.
  if f.q then
    local hay = slower((rec.target or '') .. ' ' .. (rec.detail or '') .. ' ' ..
                       (rec.action or '') .. ' ' .. (rec.actor or '') .. ' ' ..
                       (rec.ip or ''))
    if not sfind(hay, f.q, 1, true) then return false end
  end
  if f.actorId and rec.actorId ~= f.actorId then return false end
  if f.action and rec.action ~= f.action then return false end
  if f.actionPrefix and ssub(rec.action or '', 1, #f.actionPrefix) ~= f.actionPrefix then
    return false
  end
  if f.outcome and rec.outcome ~= f.outcome then return false end
  if f.ip and rec.ip ~= f.ip then return false end
  if f.from and (rec.t or 0) < f.from then return false end
  if f.to and (rec.t or 0) > f.to then return false end
  if f.target and rec.target ~= f.target then return false end
  return true
end

--- Split a buffer into lines, remembering where each one starts inside the buffer.
local function splitLines(buf)
  local lines, starts, at = {}, {}, 1
  while true do
    local nl = sfind(buf, '\n', at, true)
    if not nl then
      lines[#lines + 1] = ssub(buf, at)
      starts[#starts + 1] = at
      break
    end
    lines[#lines + 1] = ssub(buf, at, nl - 1)
    starts[#starts + 1] = at
    at = nl + 1
  end
  return lines, starts
end

local function decodeLine(ln)
  if #ln == 0 or ssub(ln, 1, 1) ~= '{' then return nil end
  local ok, rec = pcall(json.decode, ln)
  if not ok or type(rec) ~= 'table' or type(rec.action) ~= 'string' then return nil end
  return rec
end

local function parseCursor(c)
  local fi, off = tostring(c):match('^(%d+):(%-?%d+)$')
  if not fi then return nil end
  return tonumber(fi), tonumber(off)
end

function Audit:query(opts)
  opts = opts or {}
  local limit = tonumber(opts.limit) or M.DEFAULT_LIMIT
  if limit < 1 then limit = 1 end
  if limit > M.MAX_LIMIT then limit = M.MAX_LIMIT end
  local budget = tonumber(opts.maxScanBytes) or M.DEFAULT_SCAN_BUDGET
  -- Chunk size is tunable so a deployment on a slow disk can trade syscalls for memory, and so
  -- the test suite can force the budget path on a small log.
  local chunk = tonumber(opts.chunkBytes) or M.CHUNK
  if chunk < 1024 then chunk = 1024 end
  if chunk > 1024 * 1024 then chunk = 1024 * 1024 end

  -- Anything still buffered must be visible to a query, or 'batch' mode would read stale.
  self:flush()

  local q = opts.q
  if type(q) == 'string' then
    q = slower(q):match('^%s*(.-)%s*$')
    if q == '' then q = nil end
  else
    q = nil
  end
  local filter = {
    actor = opts.actor, actorId = opts.actorId, action = opts.action,
    actionPrefix = opts.actionPrefix, outcome = opts.outcome, ip = opts.ip,
    target = opts.target, q = q,
    from = tonumber(opts.from), to = tonumber(opts.to),
  }

  local files = self:files()
  local fi, startAt = 1, nil
  if opts.cursor then
    local a, b = parseCursor(opts.cursor)
    if not a then return nil, 'audit.query: malformed cursor' end
    fi = a
    startAt = (b >= 0) and b or nil
  end

  local rows, scanned = {}, 0
  local nextCursor = nil

  while fi <= #files and not nextCursor do
    local f = files[fi]
    local pos = startAt or f.bytes
    startAt = nil
    if pos > f.bytes then pos = f.bytes end
    local tail = ''
    while pos > 0 do
      local from = pos - chunk
      if from < 0 then from = 0 end
      local data = fs.readRange(f.path, from, pos - from) or ''
      scanned = scanned + #data
      local buf = data .. tail
      local lines, starts = splitLines(buf)
      local firstIdx = 1
      if from > 0 then
        tail = lines[1]                 -- a partial line: its start is below `from`
        firstIdx = 2
      else
        tail = ''
      end
      local lastLineStart = nil
      for i = #lines, firstIdx, -1 do
        local ln = lines[i]
        if #ln > 0 then
          lastLineStart = from + starts[i] - 1
          local rec = decodeLine(ln)
          if rec and matches(rec, filter) then
            rows[#rows + 1] = rec
            if #rows >= limit then
              nextCursor = sformat('%d:%d', fi, lastLineStart)
              break
            end
          end
        end
      end
      pos = from
      if nextCursor then break end
      -- Only ever hand back a cursor that IS a line boundary; if this chunk produced none
      -- (one very long line straddling it) keep going rather than emit an offset that would
      -- resume mid-record.
      if scanned >= budget and pos > 0 and lastLineStart then
        nextCursor = sformat('%d:%d', fi, lastLineStart)
        break
      end
    end
    if not nextCursor then fi = fi + 1 end
  end

  if opts.order == 'asc' then
    local rev = {}
    for i = #rows, 1, -1 do rev[#rev + 1] = rows[i] end
    rows = rev
  end
  return { rows = rows, nextCursor = nextCursor, scanned = scanned, files = #files }
end

return M
