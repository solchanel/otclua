--[[============================================================================
shim/resources.lua -- `g_resources`, otclient's PhysFS-backed virtual filesystem.

    local resources   = require('shim.resources')
    local g_resources = resources.new('D:/.../otclient/profiles/', { strict = true })

WHAT IT REPLACES
  src/framework/core/resourcemanager.cpp, bound in luafunctions.cpp.  vBot stores
  EVERY persistent thing through this object: bot storage, HealBot/AttackBot/Supplies
  configs, cavebot `.cfg` routes, targetbot `.json` profiles.

PATH MODEL (resourcemanager.cpp:832-850 `resolvePath`)
  * a path starting with '/' is used as-is;
  * otherwise it is prefixed with '/' + g_lua.getCurrentSourcePath() + '/';
  * finally EVERY '//' is collapsed to '/'  -- repeatedly, until none is left.

  The '//' rule is load-bearing, not cosmetic: `executor.lua:115` builds
  "/bot/" .. config .. "/" .. file and `_Loader.lua:13` passes "/vBot/main.lua",
  producing "/bot/vBot_4.8//vBot/main.lua".  A shim that does not collapse fails on
  the very first script.

  getCurrentSourcePath (luainterface.cpp:414-445 + functionSourcePath:929-947) walks
  the Lua stack to the first LUA function and takes the directory of its chunk name --
  but ONLY when that chunk name starts with '@' (i.e. it came from a real file load).
  Chunks the bot executor creates with `load(src, "/vBot/alarms.lua", nil, context)`
  have NO '@', so the real client resolves their relative paths against "/" and not
  against "/vBot".  We reproduce that exactly (`resources.currentSourcePath`), which
  is why `alarms.lua:122 g_resources.fileExists("sounds/magnum.ogg")` returns false
  here for the same reason it returns false in the live client.
  `g_resources.setCurrentSourcePath(p)` overrides the stack walk when a caller
  (executor, tests) wants to pin it.

SANDBOX
  Every virtual path resolves to  <writeDir> .. <virtualPath>  and nothing else.
  A path is REFUSED -- loudly, with an error naming the path -- when, after
  collapsing, it:
      * contains a '..' segment (`/bot/../../etc/passwd`),
      * contains a NUL byte or a backslash (Windows separator smuggling),
      * looks absolute in the host sense (`C:/...`, `\\server\share`),
      * is empty or does not start with '/'.
  Refusal raises for the mutating calls (write/makeDir/delete) and for
  readFileContents; the predicates (fileExists/directoryExists/listDirectoryFiles)
  return false/{} after logging, because a predicate that raises would turn a
  traversal attempt into a crash inside vBot's pcall-free paths.
  There is no symlink resolution: the sandbox is lexical.  A symlink planted inside
  the profile by something else can still point out of it -- documented, not fixed,
  because the profile directory is the user's own and PhysFS does not check either.

FIDELITY NOTES (docs/shim/api-platform.md section 2.2, invariants I6 / B11 / B12)
  * `readFileContents` RAISES on a missing file (the C++ throws Exception; callers
    such as `bot.lua:275` and `vBot/configs.lua:32` wrap it in pcall and depend on the
    failure path).  Returning nil would silently change their behaviour.
  * `listDirectoryFiles` SORTS its result (`files.sort()`, resourcemanager.cpp:797).
    The order fixes the `.otui` import order in `_Loader.lua:4-9` and the top-level
    lua order in `executor.lua:3-14`.
  * `fileExists` is true only for REGULAR FILES, `directoryExists` only for
    directories -- `bot.lua:377,461-469` discriminates on exactly that.
  * `getWriteDir()` keeps its trailing '/' (resourcemanager.cpp:403-408) because
    callers concatenate onto it directly.
  * `deleteFile` DIVERGES: PHYSFS_delete removes a file or an EMPTY directory and
    fails on a populated one; PLAN.md section 1.6 asks for "files *and* directory
    trees" (bot.lua:477's comment says "also delete dirs"), so this implementation
    removes a tree.  There are ZERO vBot call sites -- only the config-manager UI the
    shim drops -- so the divergence is unreachable from the profile.
  * `createArchive` / `decompressArchive` are inert (B7): reachable only from that
    same dropped UI.  They log at error and return nil rather than lying.

PLATFORM
  Windows: FindFirstFileA / GetFileAttributesA / CreateDirectoryA / DeleteFileA /
           RemoveDirectoryA.
  Linux:   opendir / readdir / closedir / mkdir / unlink / rmdir.
  Both through LuaJIT ffi, no external process, so `--selftest` runs identically on
  Windows and under WSL Debian.  ffi.cdef is process-global, so every declaration is
  made one at a time under pcall and every struct is named `LCRES_*`, which no other
  module in this tree declares (tools/shim_probe.lua uses WIN32_FIND_DATAA_).
============================================================================]]

local ffi = require('ffi')
local bit = require('bit')

local resources = {}

local isWindows = (ffi.os == 'Windows')

local function cdef(s) pcall(ffi.cdef, s) end

-- ===========================================================================
-- 0. logging (lazy: requiring resources must not open a log file)
-- ===========================================================================
local function logline(level, fmt, ...)
    local ok, log = pcall(require, 'lib.log')
    if ok and log[level] then log[level](fmt, ...) return end
    io.stderr:write(('[%s] '):format(level), (select('#', ...) > 0 and fmt:format(...) or fmt), '\n')
end

-- ===========================================================================
-- 1. host filesystem primitives
-- ===========================================================================

local host = {}

if isWindows then
    cdef [[
    typedef struct { unsigned long dwLowDateTime, dwHighDateTime; } LCRES_FILETIME;
    typedef struct {
      unsigned long dwFileAttributes;
      LCRES_FILETIME ftCreationTime, ftLastAccessTime, ftLastWriteTime;
      unsigned long nFileSizeHigh, nFileSizeLow;
      unsigned long dwReserved0, dwReserved1;
      char cFileName[260];
      char cAlternateFileName[14];
    } LCRES_FINDDATA;
    ]]
    cdef [[ void* FindFirstFileA(const char* lpFileName, LCRES_FINDDATA* lpFindFileData); ]]
    cdef [[ int   FindNextFileA(void* hFindFile, LCRES_FINDDATA* lpFindFileData); ]]
    cdef [[ int   FindClose(void* hFindFile); ]]
    cdef [[ unsigned long GetFileAttributesA(const char* lpFileName); ]]
    cdef [[ int   CreateDirectoryA(const char* lpPathName, void* lpSecurityAttributes); ]]
    cdef [[ int   DeleteFileA(const char* lpFileName); ]]
    cdef [[ int   RemoveDirectoryA(const char* lpPathName); ]]

    local INVALID_HANDLE  = ffi.cast('void*', -1)
    local INVALID_ATTRS   = 0xFFFFFFFF
    local ATTR_DIRECTORY  = 0x10

    local function attrs(p)
        local a = ffi.C.GetFileAttributesA(p)
        -- DWORD comes back as a Lua number already (uint32 fits a double)
        return tonumber(a)
    end

    function host.isDir(p)
        local a = attrs(p)
        return a ~= INVALID_ATTRS and bit.band(a, ATTR_DIRECTORY) ~= 0
    end

    function host.isFile(p)
        local a = attrs(p)
        return a ~= INVALID_ATTRS and bit.band(a, ATTR_DIRECTORY) == 0
    end

    -- The FIND_DATA pointer is passed as a `void*` ON PURPOSE.  `cdef` above is a
    -- pcall, so if ANOTHER module in the same process already declared
    -- FindFirstFileA with its own struct typedef -- bot/config.lua:567-569 does
    -- exactly that, with a byte-identical layout under a different name -- our
    -- declaration is silently dropped and the surviving prototype wants THAT
    -- struct pointer.  Passing LCRES_FINDDATA* then raises
    -- "cannot convert 'struct N' to 'struct M *'" and every directory listing
    -- fails, which means the shim cannot boot at all in a process that also uses
    -- the native bot layer.  void* converts to any pointer type in the FFI, so
    -- this call is correct under either declaration.
    local function findData() return ffi.new('LCRES_FINDDATA') end
    local function vp(x) return ffi.cast('void*', x) end

    function host.list(p)
        local out = {}
        local fd = findData()
        local h = ffi.C.FindFirstFileA(p .. '/*', vp(fd))
        if h == INVALID_HANDLE then return out end
        repeat
            local name = ffi.string(fd.cFileName)
            if name ~= '.' and name ~= '..' then out[#out + 1] = name end
        until ffi.C.FindNextFileA(h, vp(fd)) == 0
        ffi.C.FindClose(h)
        return out
    end

    function host.mkdir(p)  return ffi.C.CreateDirectoryA(p, nil) ~= 0 end
    function host.unlink(p) return ffi.C.DeleteFileA(p) ~= 0 end
    function host.rmdir(p)  return ffi.C.RemoveDirectoryA(p) ~= 0 end
else
    -- glibc / musl x86-64 dirent layout.  d_type is the byte right after d_reclen;
    -- DT_DIR == 4, DT_UNKNOWN == 0 (some filesystems).  We never trust d_type for the
    -- directory decision -- opendir() succeeding is the definitive test and costs one
    -- syscall on the handful of entries a profile directory holds.
    cdef [[
    typedef struct {
      unsigned long  d_ino;
      long           d_off;
      unsigned short d_reclen;
      unsigned char  d_type;
      char           d_name[256];
    } LCRES_DIRENT;
    ]]
    cdef [[ void* opendir(const char* name); ]]
    cdef [[ LCRES_DIRENT* readdir(void* dirp); ]]
    cdef [[ int   closedir(void* dirp); ]]
    cdef [[ int   mkdir(const char* pathname, unsigned int mode); ]]
    cdef [[ int   unlink(const char* pathname); ]]
    cdef [[ int   rmdir(const char* pathname); ]]

    function host.isDir(p)
        local d = ffi.C.opendir(p)
        if d == nil then return false end
        ffi.C.closedir(d)
        return true
    end

    function host.isFile(p)
        if host.isDir(p) then return false end
        local f = io.open(p, 'rb')
        if not f then return false end
        f:close()
        return true
    end

    function host.list(p)
        local out = {}
        local d = ffi.C.opendir(p)
        if d == nil then return out end
        while true do
            local e = ffi.C.readdir(d)
            if e == nil then break end
            local name = ffi.string(e.d_name)
            if name ~= '.' and name ~= '..' then out[#out + 1] = name end
        end
        ffi.C.closedir(d)
        return out
    end

    function host.mkdir(p)  return ffi.C.mkdir(p, 511) == 0 end   -- 0777, umask applies
    function host.unlink(p) return ffi.C.unlink(p) == 0 end
    function host.rmdir(p)  return ffi.C.rmdir(p) == 0 end
end

resources.host = host        -- exposed for the test suite

-- ===========================================================================
-- 2. virtual-path helpers
-- ===========================================================================

--- Collapse every '//' to '/', repeatedly (stdext::replace_all is a single pass over
--- a growing string and therefore also collapses runs; '///' -> '/').
local function collapse(p)
    while true do
        local n
        p, n = p:gsub('//', '/')
        if n == 0 then return p end
    end
end
resources.collapse = collapse

local THIS_SOURCE = debug.getinfo(1, 'S').source

--- The C++ LuaInterface::getCurrentSourcePath, ported.
--- Walks the Lua stack outward; the FIRST Lua function that is not part of this file
--- decides -- the same role the C++ binding frames play, which getStackFunction skips
--- because they are not Lua functions.
--- Returns the chunk's directory when its source starts with '@', else ''.
function resources.currentSourcePath(startLevel)
    local level = startLevel or 2
    while true do
        local info = debug.getinfo(level, 'S')
        if not info then return '' end
        if info.what ~= 'C' and info.source ~= THIS_SOURCE then
            local src = info.source or ''
            if src:sub(1, 1) ~= '@' then return '' end
            src = src:sub(2)
            local slash = src:match('^.*()/')            -- last '/', 1-based
            if not slash then return '' end
            local dir = src:sub(1, slash - 1)
            local colon = dir:match('^.*():')            -- C++ strips a trailing ':...'
            if colon then dir = dir:sub(1, colon - 1) end
            return dir
        end
        level = level + 1
    end
end

-- ===========================================================================
-- 3. the object
-- ===========================================================================

local RES = {}
RES.__index = RES

-- NOTE ON CALL STYLE: the real g_resources is a C++ singleton bound with
-- bindSingletonFunction, so every call site in vBot and in game_bot uses a DOT --
-- `g_resources.fileExists(path)`, never `g_resources:fileExists(path)`.  `new`
-- therefore returns a flat table of closures, not an object with a metatable; the
-- methods below take an explicit `self` and are internal.  `g_resources._impl` is
-- the bound instance, exposed for the test suite only.

function RES:setCurrentSourcePath(p) self._sourcePath = p end
function RES:getCurrentSourcePath()
    if self._sourcePath ~= nil then return self._sourcePath end
    return resources.currentSourcePath(2)
end

--- resolvePath, exactly as resourcemanager.cpp:832-850.
function RES:resolvePath(path)
    if type(path) ~= 'string' then
        error('g_resources: path must be a string, got ' .. type(path), 3)
    end
    local full
    if path:sub(1, 1) == '/' then
        full = path
    else
        full = '/' .. self:getCurrentSourcePath() .. '/' .. path
    end
    return collapse(full)
end

--- Sandbox check.  Returns hostPath, or nil + reason.
function RES:_hostPath(virtualPath)
    local p = virtualPath
    if p:find('%z') then return nil, 'path contains a NUL byte' end
    if p:find('\\', 1, true) then return nil, 'path contains a backslash' end
    if p:sub(1, 1) ~= '/' then return nil, 'path is not absolute after resolution' end
    if p:match('^/%a:') then return nil, 'path smuggles a host drive letter' end
    -- reject any '..' PATH SEGMENT (but not a file literally named '..foo')
    for seg in p:gmatch('[^/]+') do
        if seg == '..' then return nil, "path contains a '..' segment" end
    end
    return self._writeDir .. p:sub(2)
end

--- Resolve + sandbox in one step.  `mode` is 'read' | 'write' | 'predicate'.
function RES:_real(path, mode)
    local v = self:resolvePath(path)
    local host_, why = self:_hostPath(v)
    if host_ then return host_, v end
    self._refusals[v] = why
    local msg = ('g_resources: refusing %q -- %s (sandbox root %s)')
                :format(tostring(path), why, self._writeDir)
    if mode == 'predicate' and not self._strict then
        logline('error', '%s', msg)
        return nil, v
    end
    error(msg, 3)
end

-- --------------------------------------------------------------- predicates --

function RES:fileExists(path)
    local real = self:_real(path, 'predicate')
    if not real then return false end
    return host.isFile(real)
end

function RES:directoryExists(path)
    local real = self:_real(path, 'predicate')
    if not real then return false end
    return host.isDir(real)
end

-- --------------------------------------------------------------- listing ----

--- listDirectoryFiles(dir [, fullPath [, raw [, recursive]]])
--- Mirrors resourcemanager.cpp:770-799, including its two oddities:
---   * `raw` skips resolvePath entirely (the caller passes a host-shaped path);
---   * the recursive branch recurses on `fileOrDir`, which is a BARE NAME when
---     fullPath is false -- upstream's bug, reproduced.
function RES:listDirectoryFiles(dir, fullPath, raw, recursive)
    local files = {}
    local path, real
    if raw then
        path = dir
        real = dir
    else
        real, path = self:_real(dir, 'predicate')
        if not real then return files end
    end

    local names = host.list(real)
    for i = 1, #names do
        local fileOrDir = names[i]
        if fullPath then
            if path ~= '/' then fileOrDir = path .. '/' .. fileOrDir
            else                fileOrDir = path .. fileOrDir end
        end

        if recursive and self:directoryExists('/' .. fileOrDir) then
            local more = self:listDirectoryFiles(fileOrDir, fullPath, raw, recursive)
            for j = 1, #more do files[#files + 1] = more[j] end
        else
            files[#files + 1] = fileOrDir
        end
    end

    -- files.sort() -- std::string operator<, i.e. byte-wise.  Lua's '<' on strings is
    -- strcoll in the C locale, which is the same for the ASCII names in a profile.
    table.sort(files)
    return files
end

-- ------------------------------------------------------------------ read ----

--- readFileContents(path) -> string.  RAISES when the file is missing (I6/B11).
function RES:readFileContents(path)
    local real = self:_real(path, 'read')
    local f = io.open(real, 'rb')
    if not f then
        error(("unable to open file '%s': not found"):format(self:resolvePath(path)), 2)
    end
    local data = f:read('*a')
    f:close()
    if data == nil then
        error(("unable to read file '%s'"):format(self:resolvePath(path)), 2)
    end
    return data
end

-- ----------------------------------------------------------------- write ----

local function mkdirRecursive(realDir)
    if host.isDir(realDir) then return true end
    local parent = realDir:match('^(.*)/[^/]+$')
    if parent and parent ~= '' and not host.isDir(parent) then
        if not mkdirRecursive(parent) then return false end
    end
    if host.mkdir(realDir) then return true end
    return host.isDir(realDir)          -- lost a race, or already there
end

function RES:makeDir(path)
    local real = self:_real(path, 'write')
    return mkdirRecursive(real)
end

--- writeFileContents(path, data) -> bool.  Creates missing parent directories, which
--- is what PhysFS does for a file opened for write under the write dir.
function RES:writeFileContents(path, data)
    if type(data) ~= 'string' then data = tostring(data) end
    local real = self:_real(path, 'write')
    local parent = real:match('^(.*)/[^/]+$')
    if parent and not host.isDir(parent) then mkdirRecursive(parent) end
    local f, err = io.open(real, 'wb')
    if not f then
        logline('error', 'g_resources.writeFileContents(%s): %s', tostring(path), tostring(err))
        return false
    end
    local ok, werr = f:write(data)
    f:close()
    if not ok then
        logline('error', 'g_resources.writeFileContents(%s): %s', tostring(path), tostring(werr))
        return false
    end
    return true
end

-- ---------------------------------------------------------------- delete ----

local function deleteTree(real)
    if host.isDir(real) then
        local names = host.list(real)
        for i = 1, #names do deleteTree(real .. '/' .. names[i]) end
        return host.rmdir(real)
    end
    return host.unlink(real)
end

function RES:deleteFile(path)
    local real = self:_real(path, 'write')
    if not (host.isFile(real) or host.isDir(real)) then return false end
    return deleteTree(real)
end
RES.removeFile = RES.deleteFile        -- g_platform.removeFile spelling, same thing

-- ------------------------------------------------------------------ misc ----

function RES:getWriteDir() return self._writeDir end          -- trailing '/' kept
function RES:getRealDir(path)
    local real = self:_real(path, 'predicate')
    if not real then return '' end
    return real:match('^(.*)/[^/]+$') or real
end
function RES:getRealPath(path)
    local real = self:_real(path, 'predicate')
    return real or ''
end

--- B7: reachable only from the config-manager UI the shim drops.  Loud and honest --
--- returning an empty zip would make an upload look like it worked.
function RES:createArchive()
    logline('error', 'g_resources.createArchive is not implemented in the headless shim '
                  .. '(docs/shim/api-platform.md B7) -- returning nil')
    return nil
end
function RES:decompressArchive()
    logline('error', 'g_resources.decompressArchive is not implemented in the headless shim '
                  .. '(docs/shim/api-platform.md B7) -- returning nil')
    return nil
end

--- Diagnostics for the test suite / strict mode.
function RES:refusals() return self._refusals end

--- SHIM-ONLY (not part of the otclient API -- hence the leading underscore).
--- Validate a path without logging, raising, or touching the filesystem, so a caller
--- that will use the path later (shim/settings.lua at construction time) can refuse
--- early instead of discovering the refusal inside a pcall.
--- Returns hostPath, virtualPath   or   nil, reason.
function RES:_checkPath(path)
    local v = self:resolvePath(path)
    local host_, why = self:_hostPath(v)
    if not host_ then return nil, why, v end
    return host_, v
end

-- ===========================================================================
-- 4. the singleton factory
-- ===========================================================================

--- new(writeDir [, opts]) -> g_resources
---   writeDir : host directory that the virtual '/' maps onto.  A trailing '/' is
---              added when absent, and getWriteDir() returns it WITH that slash.
---   opts.strict     : true -> a refused path always raises, predicates included
---   opts.sourcePath : pin getCurrentSourcePath to this value (executor / tests)
function resources.new(writeDir, opts)
    opts = opts or {}
    if type(writeDir) ~= 'string' or writeDir == '' then
        error('resources.new: writeDir must be a non-empty string', 2)
    end
    writeDir = writeDir:gsub('\\', '/')
    if writeDir:sub(-1) ~= '/' then writeDir = writeDir .. '/' end

    local impl = setmetatable({
        _writeDir   = writeDir,
        _strict     = opts.strict and true or false,
        _sourcePath = opts.sourcePath,          -- nil => walk the stack
        _refusals   = {},                       -- virtual path -> refusal reason
    }, RES)

    local g = { _impl = impl }
    local names = {
        'fileExists', 'directoryExists', 'listDirectoryFiles', 'readFileContents',
        'writeFileContents', 'makeDir', 'deleteFile', 'removeFile', 'getWriteDir',
        'getRealDir', 'getRealPath', 'resolvePath', 'createArchive',
        'decompressArchive', 'setCurrentSourcePath', 'getCurrentSourcePath',
        'refusals', '_checkPath',
    }
    for i = 1, #names do
        local n = names[i]
        local fn = RES[n]
        g[n] = function(...) return fn(impl, ...) end
    end
    return g
end

return resources
