-- hub/storage.lua -- the hub's JSON-file store: atomic writes, crash detection, schema
-- versioning, and the tiny filesystem layer the rest of hub/ shares.
--
-- PANEL.md asks for "JSON files under the hub's data dir, atomic write-and-rename".  This module
-- is that, taken seriously: every collection is one file, every write is temp + fsync + rename +
-- directory fsync, and every read verifies an integrity footer so a half-written or bit-rotted
-- file is REPORTED rather than silently treated as an empty collection (which would look exactly
-- like "all your accounts are gone" and then be made permanent by the next save).
--
-- ============================================================================================
-- FILE FORMAT
-- ============================================================================================
-- Each collection file is a single JSON object written with a deterministic encoder (sorted
-- keys, no insignificant whitespace) and terminated by an integrity footer:
--
--     {"collection":"users","count":2,"items":[ ... ],"savedAt":1757000000000,"schema":1,"version":1,
--     "sum":"<64 lowercase hex>"}
--
-- `sum` is SHA-256 of every byte BEFORE the newline that precedes it.  The canonical encoder
-- escapes every control character inside strings, so a raw '\n' can never occur in the body:
-- the byte sequence '\n"sum":"' therefore appears exactly once in a well-formed file and the
-- split point is unambiguous.  The whole thing is still valid JSON, so the files stay readable
-- with any JSON tool and greppable by eye.
--
-- What each failure mode looks like on read:
--   file absent           -> a NEW, empty collection (this is first run, not an error)
--   zero bytes            -> error "empty file"          (a truncated write, never a valid save)
--   no '\n"sum":"' footer -> error "missing integrity footer (truncated or partial write)"
--   sum mismatch          -> error "checksum mismatch"   (torn write, bit rot, hand edit)
--   body not JSON         -> error "invalid JSON"
--   version > current     -> error "written by a newer hub"   (never silently downgraded)
-- storage.open() propagates all of these; it NEVER starts empty on a file that exists but does
-- not parse.  opts.onCorrupt = 'quarantine' is available for an operator who has decided to
-- accept the loss: it renames the bad file aside and starts empty, and says so in the log.
--
-- ============================================================================================
-- ATOMICITY
-- ============================================================================================
-- save(name) is two steps and they are separately callable so the crash window can be tested:
--   stageWrite(name)  -> writes <file>.tmp, flushes it, fsyncs it, closes it.  The live file is
--                        untouched; a crash here loses only the staged copy.
--   commitStage(name) -> rename(<file>.tmp, <file>) + fsync(dir).  rename(2) is atomic within a
--                        filesystem; on Windows MoveFileEx with REPLACE_EXISTING|WRITE_THROUGH.
-- A reader therefore only ever sees the complete old file or the complete new one.
--
-- The temp name is FIXED per collection ('users.json.tmp') rather than randomised, because that
-- makes recovery a lookup instead of a directory scan: storage.open() deletes any leftover .tmp
-- for every known collection, which is precisely the "crash between stage and commit" case.
-- The cost is that two hub processes must not share a data dir -- they must not anyway.
--
-- ============================================================================================
-- SCHEMA VERSIONING
-- ============================================================================================
--   opts.schemas = { users = { version = 2, migrate = { [1] = function(items) ... end } } }
-- On load, while the file's version is below the declared one, migrate[v] is applied and the
-- result is marked dirty so the upgrade is persisted at the next save.  A missing migration hook
-- is a hard error.  `schema` (the file-format version, currently 1) is separate from `version`
-- (the collection's data shape) so the two can move independently.
--
-- ============================================================================================
-- COST
-- ============================================================================================
-- A save is one encode + one SHA-256 + one write + two fsyncs.  Measured on the realistic sizes
-- PANEL.md implies (hundreds of rows, tens of KB) it is single-digit milliseconds; the figure is
-- printed live by test/hubcoresuite.lua's "storage / write cost" note, which is the one to size
-- from.  fsync dominates and is storage-dependent, so treat a slow figure as a slow disk, not a
-- slow encoder.  Nothing here yields, so the hub must not call save() in a tight loop from a
-- reactor callback: batch with markDirty() and flush from a timer.
--
-- ============================================================================================
-- API
-- ============================================================================================
--   storage.open(dir [, opts]) -> store | nil, err
--        opts.collections = { 'users', ... }        (default: the PANEL.md set)
--        opts.schemas     = per-collection {version=, migrate={}}
--        opts.onCorrupt   = 'error' (default) | 'quarantine'
--        opts.log         = a lib/log-shaped table
--   store:items(name)          -> the live array (mutate it, then markDirty)
--   store:setItems(name, arr)  -> replaces and marks dirty
--   store:markDirty(name)
--   store:save(name [, force]) -> true | nil, err      (no-op when not dirty unless forced)
--   store:saveAll([force])     -> true | nil, err
--   store:load(name)           -> true | nil, err      (re-read from disk, discards cache)
--   store:info(name)           -> {version=, count=, savedAt=, bytes=, dirty=}
--   store:pathOf(name) / store:tempPathOf(name)
--   store:stageWrite(name)     -> tmpPath | nil, err   (the crash window; no rename)
--   store:commitStage(name)    -> true | nil, err
--   store:close()              -> saveAll()
--
--   storage.fs -- the shared filesystem layer (hub/audit.lua uses it too):
--        fs.mkdirp(path)                  -> true | nil, err   (0700 on POSIX)
--        fs.exists(path) / fs.isDir(path) / fs.size(path)
--        fs.readFile(path)                -> data | nil, err, 'enoent'|'io'
--        fs.writeDurable(path, data)      -> true | nil, err   (write + fsync, no rename)
--        fs.rename(from, to)              -> true | nil, err   (atomic replace)
--        fs.remove(path)                  -> true | nil, err
--        fs.fsyncDir(path)                -> true | nil, err   (no-op on Windows)
--        fs.openAppend(path)              -> handle | nil, err
--        fs.appendSync(handle, data)      -> true | nil, err   (write + fsync)
--        fs.close(handle)
--        fs.readRange(path, offset, len)  -> data | nil, err
--   storage.encodeCanon(v) -> deterministic JSON text (sorted keys, all control chars escaped)
--   storage.wallMs()       -> wall-clock milliseconds, monotonic within a run
--
-- PATHS ON WINDOWS: the FFI calls are the ANSI (…A) variants, matching what Lua's own io.open
-- does, so the data dir must be representable in the process ANSI codepage.  Keep it ASCII.

local ffi  = require('ffi')
local bit  = require('bit')
local json = require('lib.json')
local sha2 = require('lib.sha2')
local sys  = require('lib.sys')

local sformat, srep, ssub, sbyte, sfind = string.format, string.rep, string.sub, string.byte, string.find
local concat, sort, floor = table.concat, table.sort, math.floor

local M = {}

M.SCHEMA        = 1                 -- file-format version (the envelope, not the rows)
M.DEFAULT_COLLECTIONS = { 'users', 'accounts', 'characters', 'instances', 'proxies', 'scripts' }
M.FOOTER_MARK   = '\n"sum":"'
M.DIR_MODE      = 448               -- 0700
M.FILE_MODE     = 384               -- 0600

-- ================================================================= wall clock
-- os.time() only has second resolution and can step backwards (NTP).  Anchor once and advance
-- with the monotonic clock, so audit timestamps are millisecond-resolution and never go back
-- inside one hub run.
local WALL_BASE = os.time() * 1000
local MONO_BASE = sys.nowMs()

function M.wallMs()
  return floor(WALL_BASE + (sys.nowMs() - MONO_BASE) + 0.5)
end

-- ============================================================ canonical JSON
-- Deterministic: object keys sorted, no whitespace, every byte < 0x20 escaped (so a literal
-- newline cannot appear inside the body and the footer split point is unique).

local ESCAPES = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
for i = 0, 31 do
  local c = string.char(i)
  if not ESCAPES[c] then ESCAPES[c] = sformat('\\u%04x', i) end
end
ESCAPES[string.char(127)] = '\\u007f'

local function escapeStr(s)
  return '"' .. s:gsub('[%z\1-\31\127\\"]', ESCAPES) .. '"'
end

local function encodeNumber(v)
  if v ~= v or v == math.huge or v == -math.huge then
    error('storage: cannot encode non-finite number', 0)
  end
  if v == floor(v) and v >= -9007199254740992 and v <= 9007199254740992 then
    return sformat('%d', v)
  end
  return sformat('%.17g', v)
end

local encodeCanon
local function encodeTable(v, depth)
  if depth > 64 then error('storage: JSON nesting too deep', 0) end
  local n = #v
  local isArray = (n > 0)
  local keys
  if isArray then
    -- A table with both [1] and a string key would otherwise silently lose the string key.
    local total = 0
    for _ in pairs(v) do total = total + 1 end
    if total ~= n then
      error('storage: table with both array and non-array keys is not encodable', 0)
    end
  else
    keys = {}
    for k in pairs(v) do
      if type(k) ~= 'string' then
        error('storage: table with non-string key ' .. tostring(k) .. ' is not encodable', 0)
      end
      keys[#keys + 1] = k
    end
    if #keys == 0 then return '[]' end          -- empty table is always an ARRAY, both ways
    sort(keys)
  end
  local out = {}
  if isArray then
    for i = 1, n do
      if v[i] == nil then error('storage: sparse array is not encodable', 0) end
      out[i] = encodeCanon(v[i], depth + 1)
    end
    return '[' .. concat(out, ',') .. ']'
  end
  for i = 1, #keys do
    local k = keys[i]
    out[i] = escapeStr(k) .. ':' .. encodeCanon(v[k], depth + 1)
  end
  return '{' .. concat(out, ',') .. '}'
end

encodeCanon = function(v, depth)
  depth = depth or 0
  local t = type(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'number' then return encodeNumber(v) end
  if t == 'string' then return escapeStr(v) end
  if t == 'table' then return encodeTable(v, depth) end
  error('storage: cannot encode a ' .. t, 0)
end

M.encodeCanon = function(v) return encodeCanon(v, 0) end

-- ================================================================ filesystem
-- ffi.cdef is process-global and lib/process.lua / lib/authsecret.lua may already have declared
-- some of these; every declaration is therefore individually pcall'd, exactly as they do.
local function cdef(s) pcall(ffi.cdef, s) end

local fs = {}
M.fs = fs

local isWin = sys.isWindows

if isWin then
  cdef [[ void* CreateFileA(const char*, unsigned long, unsigned long, void*,
                            unsigned long, unsigned long, void*); ]]
  cdef [[ int WriteFile(void*, const void*, unsigned long, unsigned long*, void*); ]]
  cdef [[ int FlushFileBuffers(void*); ]]
  cdef [[ int CloseHandle(void*); ]]
  cdef [[ int MoveFileExA(const char*, const char*, unsigned long); ]]
  cdef [[ int CreateDirectoryA(const char*, void*); ]]
  cdef [[ int DeleteFileA(const char*); ]]
  cdef [[ unsigned long GetFileAttributesA(const char*); ]]
  cdef [[ unsigned long GetLastError(void); ]]

  local k32 = ffi.load('kernel32')
  local INVALID = ffi.cast('void*', -1)
  local GENERIC_WRITE, FILE_APPEND_DATA = 0x40000000, 0x0004
  local FILE_SHARE_READ = 0x00000001
  local CREATE_ALWAYS, OPEN_ALWAYS = 2, 4
  local FILE_ATTRIBUTE_NORMAL = 0x80
  local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
  local FILE_ATTRIBUTE_DIRECTORY = 0x10
  local MOVEFILE_REPLACE_WRITETHROUGH = 9   -- REPLACE_EXISTING | WRITE_THROUGH
  local ERROR_ALREADY_EXISTS = 183

  local nwritten = ffi.new('unsigned long[1]')

  local function lastErr(what)
    return sformat('%s failed (GetLastError=%d)', what, tonumber(k32.GetLastError()))
  end

  local function openHandle(path, append)
    local access = append and FILE_APPEND_DATA or GENERIC_WRITE
    local disp   = append and OPEN_ALWAYS or CREATE_ALWAYS
    local h = k32.CreateFileA(path, access, FILE_SHARE_READ, nil, disp, FILE_ATTRIBUTE_NORMAL, nil)
    if h == INVALID then return nil, lastErr('CreateFileA(' .. path .. ')') end
    return h
  end

  local function writeAll(h, data)
    local n, len = 0, #data
    local buf = ffi.cast('const char*', data)
    while n < len do
      local chunk = len - n
      if chunk > 0x100000 then chunk = 0x100000 end
      if k32.WriteFile(h, buf + n, chunk, nwritten, nil) == 0 then
        return nil, lastErr('WriteFile')
      end
      local got = tonumber(nwritten[0])
      if got <= 0 then return nil, 'WriteFile wrote 0 bytes' end
      n = n + got
    end
    return true
  end

  function fs.writeDurable(path, data)
    local h, err = openHandle(path, false)
    if not h then return nil, err end
    local ok, werr = writeAll(h, data)
    if ok then
      if k32.FlushFileBuffers(h) == 0 then ok, werr = nil, lastErr('FlushFileBuffers') end
    end
    k32.CloseHandle(h)
    if not ok then return nil, werr end
    return true
  end

  function fs.rename(from, to)
    if k32.MoveFileExA(from, to, MOVEFILE_REPLACE_WRITETHROUGH) == 0 then
      return nil, lastErr('MoveFileExA')
    end
    return true
  end

  function fs.remove(path)
    if k32.DeleteFileA(path) == 0 then
      local e = tonumber(k32.GetLastError())
      if e == 2 or e == 3 then return true end        -- already gone
      return nil, lastErr('DeleteFileA')
    end
    return true
  end

  function fs.mkdirp(path)
    path = path:gsub('\\', '/'):gsub('/+$', '')
    if path == '' then return true end
    local parts, acc = {}, nil
    for seg in path:gmatch('[^/]+') do parts[#parts + 1] = seg end
    for i = 1, #parts do
      acc = acc and (acc .. '/' .. parts[i]) or parts[i]
      if not (i == 1 and acc:match('^%a:$')) then
        if k32.CreateDirectoryA(acc, nil) == 0 then
          local e = tonumber(k32.GetLastError())
          if e ~= ERROR_ALREADY_EXISTS and e ~= 5 then
            return nil, sformat('CreateDirectoryA(%s) failed (GetLastError=%d)', acc, e)
          end
        end
      end
    end
    return true
  end

  local function attrs(path)
    local a = tonumber(k32.GetFileAttributesA(path))
    if a == INVALID_FILE_ATTRIBUTES then return nil end
    return a
  end
  function fs.exists(path) return attrs(path) ~= nil end
  function fs.isDir(path)
    local a = attrs(path)
    return a ~= nil and bit.band(a, FILE_ATTRIBUTE_DIRECTORY) ~= 0
  end

  function fs.fsyncDir(_) return true end             -- no directory handles on Win32 (by design)

  function fs.openAppend(path)
    local h, err = openHandle(path, true)
    if not h then return nil, err end
    return { h = h }
  end
  function fs.appendSync(fh, data)
    local ok, err = writeAll(fh.h, data)
    if not ok then return nil, err end
    if k32.FlushFileBuffers(fh.h) == 0 then return nil, lastErr('FlushFileBuffers') end
    return true
  end
  function fs.close(fh)
    if fh and fh.h then k32.CloseHandle(fh.h); fh.h = nil end
    return true
  end

else
  cdef [[ int open(const char *path, int flags, unsigned int mode); ]]
  cdef [[ long write(int fd, const void *buf, unsigned long n); ]]
  cdef [[ int close(int fd); ]]
  cdef [[ int fsync(int fd); ]]
  cdef [[ int rename(const char *oldp, const char *newp); ]]
  cdef [[ int mkdir(const char *path, unsigned int mode); ]]
  cdef [[ int chmod(const char *path, unsigned int mode); ]]
  cdef [[ int unlink(const char *path); ]]
  cdef [[ char *strerror(int errnum); ]]
  cdef [[ int fcntl(int, int, ...); ]]

  local C = ffi.C
  local O_RDONLY, O_WRONLY = 0, 1
  local O_CREAT, O_EXCL, O_TRUNC, O_APPEND = 64, 128, 512, 1024
  local O_DIRECTORY, O_NOFOLLOW = 0x10000, 0x20000
  -- O_CLOEXEC on EVERY descriptor this backend opens.  The hub forks workers
  -- that run operator-supplied Lua; without this the child inherits the audit
  -- log's O_APPEND write handle (and could forge records in it) and whatever
  -- data file happened to be open.  lib/process.lua also sweeps fds > 2 in the
  -- child -- belt and braces, because a leak here is silent.
  local O_CLOEXEC = 0x80000
  local EINTR, EEXIST, ENOENT = 4, 17, 2

  local function errStr(what)
    local e = ffi.errno()
    local s = C.strerror(e)
    return sformat('%s failed: %s (errno=%d)', what, s ~= nil and ffi.string(s) or '?', e)
  end

  local function openFd(path, flags, mode)
    local fd
    flags = bit.bor(flags, O_CLOEXEC)
    repeat
      fd = C.open(path, flags, mode or M.FILE_MODE)
    until fd >= 0 or ffi.errno() ~= EINTR
    if fd < 0 then return nil, errStr('open(' .. path .. ')') end
    return fd
  end

  local function writeAll(fd, data)
    local n, len = 0, #data
    local buf = ffi.cast('const char*', data)
    while n < len do
      local r = tonumber(C.write(fd, buf + n, len - n))
      if r < 0 then
        if ffi.errno() == EINTR then
          -- retry
        else
          return nil, errStr('write')
        end
      elseif r == 0 then
        return nil, 'write returned 0'
      else
        n = n + r
      end
    end
    return true
  end

  function fs.writeDurable(path, data)
    local fd, err = openFd(path, bit.bor(O_WRONLY, O_CREAT, O_TRUNC), M.FILE_MODE)
    if not fd then return nil, err end
    local ok, werr = writeAll(fd, data)
    if ok and C.fsync(fd) ~= 0 then ok, werr = nil, errStr('fsync') end
    C.close(fd)
    if not ok then return nil, werr end
    return true
  end

  function fs.rename(from, to)
    if C.rename(from, to) ~= 0 then return nil, errStr('rename') end
    return true
  end

  function fs.remove(path)
    if C.unlink(path) ~= 0 then
      if ffi.errno() == ENOENT then return true end
      return nil, errStr('unlink')
    end
    return true
  end

  function fs.mkdirp(path)
    path = path:gsub('/+$', '')
    if path == '' then return true end
    local acc = (path:sub(1, 1) == '/') and '' or nil
    for seg in path:gmatch('[^/]+') do
      acc = acc and (acc .. '/' .. seg) or seg
      if C.mkdir(acc, M.DIR_MODE) ~= 0 and ffi.errno() ~= EEXIST then
        return nil, errStr('mkdir(' .. acc .. ')')
      end
    end
    -- mkdir's mode is masked by umask; state the intent explicitly.
    if C.chmod(path, M.DIR_MODE) ~= 0 then
      return nil, errStr('chmod 0700 ' .. path)
    end
    return true
  end

  function fs.exists(path)
    local f = io.open(path, 'rb')
    if f then f:close(); return true end
    local fd = C.open(path, bit.bor(O_RDONLY, O_DIRECTORY, O_CLOEXEC), 0)
    if fd >= 0 then C.close(fd); return true end
    return false
  end

  function fs.isDir(path)
    local fd = C.open(path, bit.bor(O_RDONLY, O_DIRECTORY, O_CLOEXEC), 0)
    if fd < 0 then return false end
    C.close(fd)
    return true
  end

  --- fsync the DIRECTORY, which is what actually makes a rename survive power loss on Linux.
  function fs.fsyncDir(path)
    local fd = C.open(path, bit.bor(O_RDONLY, O_DIRECTORY, O_CLOEXEC), 0)
    if fd < 0 then return nil, errStr('open dir ' .. path) end
    local ok = (C.fsync(fd) == 0)
    local err = ok and nil or errStr('fsync dir')
    C.close(fd)
    if not ok then return nil, err end
    return true
  end

  function fs.openAppend(path)
    local fd, err = openFd(path, bit.bor(O_WRONLY, O_CREAT, O_APPEND), M.FILE_MODE)
    if not fd then return nil, err end
    return { fd = fd }
  end
  function fs.appendSync(fh, data)
    local ok, err = writeAll(fh.fd, data)
    if not ok then return nil, err end
    if C.fsync(fh.fd) ~= 0 then return nil, errStr('fsync') end
    return true
  end
  function fs.close(fh)
    if fh and fh.fd then C.close(fh.fd); fh.fd = nil end
    return true
  end

  --- Is this handle's descriptor close-on-exec?  A test asserts the invariant
  --- rather than trusting that O_CLOEXEC was asked for.
  local F_GETFD, FD_CLOEXEC = 1, 1
  function fs.isCloexec(fh)
    local fd = (type(fh) == 'table') and fh.fd or tonumber(fh)
    if not fd or fd < 0 then return nil end
    local fl = tonumber(C.fcntl(fd, F_GETFD, ffi.cast('long', 0)))
    if not fl or fl < 0 then return nil end
    return bit.band(fl, FD_CLOEXEC) ~= 0
  end
end

--- Whole-file read.  Distinguishes "not there" from "there but unreadable": the caller has to
--- treat those differently (first run vs a permissions problem it must not paper over).
function fs.readFile(path)
  local f, oerr = io.open(path, 'rb')
  if not f then return nil, tostring(oerr or ('cannot open ' .. path)), 'enoent' end
  local ok, data = pcall(f.read, f, '*a')
  f:close()
  if not ok or data == nil then
    return nil, sformat('read(%s) failed: %s', path, tostring(data)), 'io'
  end
  return data
end

function fs.size(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local n = f:seek('end')
  f:close()
  return n
end

--- Bounded read at an offset -- audit's reverse scanner uses this so a query never has to pull a
--- whole rotated log into memory.
function fs.readRange(path, offset, len)
  if len <= 0 then return '' end
  local f, oerr = io.open(path, 'rb')
  if not f then return nil, tostring(oerr) end
  local ok, err = f:seek('set', offset)
  if not ok then f:close(); return nil, tostring(err) end
  local data = f:read(len)
  f:close()
  return data or ''
end

-- ================================================================== envelope

--- Serialise one collection into the on-disk envelope, footer and all.
local function encodeEnvelope(name, version, items)
  local body = encodeCanon({
    schema     = M.SCHEMA,
    collection = name,
    version    = version,
    savedAt    = M.wallMs(),
    count      = #items,
    items      = items,
  }, 0)
  -- Drop the closing brace and re-open for the footer key, so `sum` is provably the last key
  -- and the bytes it covers are provably everything above it.
  local prefix = ssub(body, 1, #body - 1) .. ','
  local sum    = sha2.sha256hex(prefix)
  return prefix .. M.FOOTER_MARK .. sum .. '"}\n', sum
end

--- Parse and VERIFY.  Returns doc | nil, err.  Never returns an empty collection for a file
--- that exists but does not verify -- that distinction is the whole point of the footer.
local function decodeEnvelope(name, data)
  if #data == 0 then
    return nil, sformat('%s: empty file (a truncated write, or the disk filled)', name)
  end
  -- The canonical encoder escapes every control byte, so this marker occurs at most once.
  local p = nil
  local from = 1
  while true do
    local i = sfind(data, M.FOOTER_MARK, from, true)
    if not i then break end
    p, from = i, i + 1
  end
  if not p then
    return nil, sformat('%s: missing integrity footer (truncated or partial write, %d bytes)',
                        name, #data)
  end
  local prefix = ssub(data, 1, p - 1)
  local rest   = ssub(data, p + 1)
  local sum    = rest:match('^"sum":"(%x+)"}%s*$')
  if not sum or #sum ~= 64 then
    return nil, sformat('%s: malformed integrity footer', name)
  end
  local want = sha2.sha256hex(prefix)
  if sum ~= want then
    return nil, sformat('%s: checksum mismatch (file says %s, contents hash to %s) -- corrupt',
                        name, ssub(sum, 1, 12), ssub(want, 1, 12))
  end
  local ok, doc = pcall(json.decode, prefix .. M.FOOTER_MARK .. sum .. '"}')
  if not ok then
    return nil, sformat('%s: invalid JSON: %s', name, tostring(doc))
  end
  if type(doc) ~= 'table' then return nil, name .. ': top level is not an object' end
  if doc.schema ~= M.SCHEMA then
    return nil, sformat('%s: file schema %s, this hub speaks %d',
                        name, tostring(doc.schema), M.SCHEMA)
  end
  if doc.collection ~= name then
    return nil, sformat('%s: file says it is collection %q', name, tostring(doc.collection))
  end
  if type(doc.items) ~= 'table' then return nil, name .. ': items is not an array' end
  if doc.count ~= nil and doc.count ~= #doc.items then
    return nil, sformat('%s: count says %s but %d rows are present',
                        name, tostring(doc.count), #doc.items)
  end
  return doc
end

M._encodeEnvelope = encodeEnvelope       -- exported for the test suite's corruption cases
M._decodeEnvelope = decodeEnvelope

-- ===================================================================== store

local Store = {}
Store.__index = Store

local nullLog = { info = function() end, warn = function() end, error = function() end,
                  debug = function() end }

function M.open(dir, opts)
  opts = opts or {}
  if type(dir) ~= 'string' or dir == '' then return nil, 'storage.open: dir is required' end
  dir = dir:gsub('\\', '/'):gsub('/+$', '')

  local ok, err = fs.mkdirp(dir)
  if not ok then return nil, 'storage.open: ' .. tostring(err) end

  local self = setmetatable({
    dir        = dir,
    log        = opts.log or nullLog,
    onCorrupt  = opts.onCorrupt or 'error',
    schemas    = {},
    cache      = {},
    meta       = {},
    names      = {},
    quarantined = {},
  }, Store)

  local names = opts.collections or M.DEFAULT_COLLECTIONS
  for i = 1, #names do
    local n = names[i]
    if not n:match('^[%w_%-]+$') then
      return nil, 'storage.open: illegal collection name ' .. tostring(n)
    end
    self.names[#self.names + 1] = n
    local sc = (opts.schemas and opts.schemas[n]) or {}
    self.schemas[n] = { version = tonumber(sc.version) or 1, migrate = sc.migrate or {} }
  end

  -- Recovery: a .tmp left behind is a write that never committed.  Discarding it is the correct
  -- resolution -- the live file is the last complete state.
  for i = 1, #self.names do
    local tmp = self:tempPathOf(self.names[i])
    if fs.exists(tmp) then
      self.log.warn('storage: discarding uncommitted %s (crash between stage and commit)', tmp)
      fs.remove(tmp)
    end
  end

  for i = 1, #self.names do
    local lok, lerr = self:load(self.names[i])
    if not lok then return nil, lerr end
  end
  return self
end

function Store:pathOf(name)     return self.dir .. '/' .. name .. '.json' end
function Store:tempPathOf(name) return self.dir .. '/' .. name .. '.json.tmp' end

function Store:has(name) return self.schemas[name] ~= nil end

local function requireName(self, name)
  if not self.schemas[name] then
    error('storage: unknown collection ' .. tostring(name), 3)
  end
end

--- (Re)read one collection from disk.  A missing file is a new empty collection; anything else
--- that does not verify is an error (or a quarantine, if the operator asked for that).
function Store:load(name)
  requireName(self, name)
  local path = self:pathOf(name)
  local data, rerr, why = fs.readFile(path)
  if not data then
    if why == 'enoent' then
      self.cache[name] = {}
      self.meta[name]  = { version = self.schemas[name].version, savedAt = nil, bytes = 0,
                           dirty = false, fresh = true }
      return true
    end
    return nil, 'storage: ' .. tostring(rerr)
  end

  local doc, derr = decodeEnvelope(name, data)
  if not doc then
    if self.onCorrupt == 'quarantine' then
      local aside = path .. '.corrupt-' .. tostring(M.wallMs())
      fs.rename(path, aside)
      self.log.error('storage: %s -- QUARANTINED to %s, starting this collection EMPTY',
                     tostring(derr), aside)
      self.quarantined[name] = aside
      self.cache[name] = {}
      self.meta[name]  = { version = self.schemas[name].version, bytes = 0, dirty = true }
      return true
    end
    return nil, 'storage: ' .. tostring(derr)
  end

  local items   = doc.items
  local fileVer = tonumber(doc.version) or 1
  local want    = self.schemas[name].version
  local dirty   = false
  if fileVer > want then
    return nil, sformat('storage: %s is version %d but this hub only knows %d ' ..
                        '(written by a newer build -- refusing to downgrade it)',
                        name, fileVer, want)
  end
  while fileVer < want do
    local hook = self.schemas[name].migrate[fileVer]
    if type(hook) ~= 'function' then
      return nil, sformat('storage: %s needs a migration from version %d and none is registered',
                          name, fileVer)
    end
    local mok, res = pcall(hook, items, fileVer)
    if not mok then
      return nil, sformat('storage: migrating %s from v%d failed: %s', name, fileVer, tostring(res))
    end
    items   = res or items
    fileVer = fileVer + 1
    dirty   = true
    self.log.info('storage: migrated %s to version %d', name, fileVer)
  end

  self.cache[name] = items
  self.meta[name]  = { version = want, savedAt = doc.savedAt, bytes = #data, dirty = dirty }
  return true
end

function Store:items(name)
  requireName(self, name)
  return self.cache[name]
end

function Store:setItems(name, arr)
  requireName(self, name)
  if type(arr) ~= 'table' then error('storage.setItems: array expected', 2) end
  self.cache[name] = arr
  self.meta[name].dirty = true
  return true
end

function Store:markDirty(name)
  requireName(self, name)
  self.meta[name].dirty = true
end

function Store:isDirty(name)
  requireName(self, name)
  return self.meta[name].dirty == true
end

function Store:info(name)
  requireName(self, name)
  local m = self.meta[name]
  return { version = m.version, count = #self.cache[name], savedAt = m.savedAt,
           bytes = m.bytes, dirty = m.dirty == true, quarantined = self.quarantined[name] }
end

--- STEP 1 of a save: the complete new file lands in <file>.tmp and is fsynced.  The live file is
--- untouched.  A crash here is invisible to the next start (open() sweeps the .tmp).
function Store:stageWrite(name)
  requireName(self, name)
  local items = self.cache[name]
  local eok, text = pcall(encodeEnvelope, name, self.schemas[name].version, items)
  if not eok then return nil, 'storage: encoding ' .. name .. ' failed: ' .. tostring(text) end
  local tmp = self:tempPathOf(name)
  local wok, werr = fs.writeDurable(tmp, text)
  if not wok then return nil, 'storage: staging ' .. name .. ': ' .. tostring(werr) end
  self._staged = self._staged or {}
  self._staged[name] = #text
  return tmp
end

--- STEP 2: the atomic swap.  After this returns, every reader sees the new file.
function Store:commitStage(name)
  requireName(self, name)
  local tmp, path = self:tempPathOf(name), self:pathOf(name)
  if not fs.exists(tmp) then return nil, 'storage: nothing staged for ' .. name end
  local rok, rerr = fs.rename(tmp, path)
  if not rok then return nil, 'storage: committing ' .. name .. ': ' .. tostring(rerr) end
  local dok, derr = fs.fsyncDir(self.dir)
  if not dok then
    -- The data is on disk and the rename happened; only its durability across a power cut is in
    -- doubt.  Say so loudly rather than failing a save the caller already believes succeeded.
    self.log.warn('storage: fsync of %s failed after committing %s: %s', self.dir, name,
                  tostring(derr))
  end
  local m = self.meta[name]
  m.dirty   = false
  m.bytes   = (self._staged and self._staged[name]) or m.bytes
  m.savedAt = M.wallMs()
  if self._staged then self._staged[name] = nil end
  return true
end

function Store:save(name, force)
  requireName(self, name)
  if not force and not self.meta[name].dirty then return true end
  local tmp, err = self:stageWrite(name)
  if not tmp then return nil, err end
  return self:commitStage(name)
end

function Store:saveAll(force)
  for i = 1, #self.names do
    local ok, err = self:save(self.names[i], force)
    if not ok then return nil, err end
  end
  return true
end

function Store:close()
  return self:saveAll()
end

return M
