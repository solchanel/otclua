--[[============================================================================
test/replay.lua -- feed a capture of server payloads through proto/parser.lua and
assert that every message is consumed to the last byte.

  luajit test/replay.lua                 -- generate a synthetic capture, replay it
  luajit test/replay.lua FILE [FILE...]  -- replay real captures
  luajit main.lua --replay=FILE

Two capture formats are understood.

1. `.cam` -- the OTClient PacketRecorder format (docs/offline-testbench.md §1),
   plain text, one record per line, tolerant of CRLF and LF:

       line   := dir SP time SP hexpayload EOL
       dir    := "<"  (server -> client)   |   ">"  (client -> server)
       time   := decimal ms since the recorder was constructed
       hex    := lowercase, 2 chars per byte, no separators

   A `<` payload is exactly what proto/transport.lua hands to onMessage: framing,
   sequence, XTEA, zlib and padding are all already stripped, so the first byte is
   a game opcode.  `>` records are counted but not parsed (they are client
   packets; proto/sender.lua builds those).
   NOTE: a `.cam` recorded from a protocol other than 1530 will (correctly)
   desync this parser -- the protocol version is out-of-band, put it in the
   filename.

2. `.lcap` -- the length-prefixed binary format this client writes/reads itself:

       "LCAP" u8 version(=1)
       record* := u8 dir ('<'=0x3C or '>'=0x3E), u32 LE timeMs, u32 LE length, length bytes

   Both directions are stored verbatim; only `<` records are parsed.

Exit code 0 when every inbound message was consumed byte-exactly, non-zero on the
first message that was not (the parser's own desync report names the opcode, the
byte offset and the previous three opcodes).
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local buffer    = require('lib.buffer')
local state     = require('game.state')
local parser    = require('proto.parser')
local items     = require('proto.items')
local transport = require('proto.transport')
local handshake = require('proto.handshake')

local HEXD = {}
for b = 0, 255 do HEXD[string.char(b)] = ('%02x'):format(b) end
local function tohex(s) return (s:gsub('.', HEXD)) end
local function fromhex(h)
    return (h:gsub('%x%x', function(cc) return string.char(tonumber(cc, 16)) end))
end

-- ============================================================ capture readers
local capture = {}

--- Read a .cam file -> array of {dir='<'|'>', time=ms, payload=string}
function capture.readCam(path)
    local f, err = io.open(path, 'rb')
    if not f then return nil, err end
    local text = f:read('*a'); f:close()
    local records, lineNo = {}, 0
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        lineNo = lineNo + 1
        line = line:gsub('\r$', '')
        if line ~= '' then
            local dir, time, hex = line:match('^([<>])%s+(%d+)%s+(%x*)%s*$')
            if not dir then
                return nil, ('%s:%d: malformed .cam record %q'):format(path, lineNo, line:sub(1, 60))
            end
            if #hex % 2 ~= 0 then
                return nil, ('%s:%d: odd number of hex digits'):format(path, lineNo)
            end
            records[#records + 1] = { dir = dir, time = tonumber(time), payload = fromhex(hex),
                                      line = lineNo }
        end
    end
    return records
end

--- Read an .lcap file -> the same record array.
function capture.readLcap(path)
    local f, err = io.open(path, 'rb')
    if not f then return nil, err end
    local data = f:read('*a'); f:close()
    if data:sub(1, 4) ~= 'LCAP' then return nil, path .. ': bad magic (expected "LCAP")' end
    local version = data:byte(5)
    if version ~= 1 then return nil, ('%s: unsupported version %d'):format(path, version) end
    local R = buffer.reader(data)
    R:skip(5)
    local records = {}
    while not R:eof() do
        local ok, rec = pcall(function()
            local d = string.char(R:u8())
            local t = R:u32()
            local n = R:u32()
            return { dir = d, time = t, payload = R:bytes(n) }
        end)
        if not ok then
            return nil, ('%s: truncated record #%d (%s)'):format(path, #records + 1, tostring(rec))
        end
        if rec.dir ~= '<' and rec.dir ~= '>' then
            return nil, ('%s: record #%d has direction byte 0x%02X'):format(
                path, #records + 1, rec.dir:byte())
        end
        records[#records + 1] = rec
    end
    return records
end

function capture.read(path)
    if path:lower():match('%.cam$') then return capture.readCam(path) end
    if path:lower():match('%.lcap$') then return capture.readLcap(path) end
    -- sniff: LCAP is the only format with a magic
    local f = io.open(path, 'rb')
    if not f then return nil, path .. ': cannot open' end
    local head = f:read(4) or ''; f:close()
    if head == 'LCAP' then return capture.readLcap(path) end
    return capture.readCam(path)
end

function capture.writeLcap(path, records)
    local f, err = io.open(path, 'wb')
    if not f then return nil, err end
    f:write('LCAP', string.char(1))
    local W = buffer.writer()
    for _, r in ipairs(records) do
        W:reset()
        W:u8(r.dir:byte()):u32(r.time or 0):u32(#r.payload)
        f:write(W:data(), r.payload)
    end
    f:close()
    return true
end

function capture.writeCam(path, records)
    local f, err = io.open(path, 'wb')
    if not f then return nil, err end
    for _, r in ipairs(records) do
        f:write(r.dir, ' ', tostring(r.time or 0), ' ', tohex(r.payload), '\n')
    end
    f:close()
    return true
end

-- =================================================================== replay
--- Replay one capture. Returns a stats table, or nil + a message on the first
--- message that is not consumed byte-exactly.
local function replayFile(path, opts)
    opts = opts or {}
    local records, err = capture.read(path)
    if not records then return nil, err end

    local st = state.new()
    local events = {}
    local p = parser.new(st, function(name)
        events[name] = (events[name] or 0) + 1
    end)
    p.unknownOpcodeIsFatal = true

    local stats = { file = path, records = #records, inbound = 0, outbound = 0,
                    bytes = 0, opcodes = {}, events = events, opcodeCount = 0 }

    -- exact per-opcode histogram: P:push is called once per dispatched opcode
    local origPush = p.push
    p.push = function(self, op, offset)
        stats.opcodes[op] = (stats.opcodes[op] or 0) + 1
        return origPush(self, op, offset)
    end

    for i, r in ipairs(records) do
        if r.dir == '>' then
            stats.outbound = stats.outbound + 1
        else
            stats.inbound = stats.inbound + 1
            stats.bytes = stats.bytes + #r.payload
            if #r.payload == 0 then
                return nil, ('%s: record #%d (line %s) has an empty payload')
                    :format(path, i, tostring(r.line))
            end
            local before = p.opcodeCount or 0
            local ok, perr = pcall(function() return p:parse(r.payload) end)
            if not ok then
                return nil, ('%s: record #%d (line %s, %d bytes, first opcode 0x%02X)\n  %s')
                    :format(path, i, tostring(r.line), #r.payload, r.payload:byte(1), tostring(perr))
            end
            -- explicit full-consumption assertion (the parser also raises on its own)
            local left = p.reader and p.reader:remaining() or 0
            if left ~= 0 then
                return nil, ('%s: record #%d left %d unconsumed byte(s)'):format(path, i, left)
            end
            stats.opcodeCount = stats.opcodeCount + ((p.opcodeCount or 0) - before)
        end
    end
    stats.state = st
    return stats
end

-- ======================================================= synthetic capture
-- The repo now ships two REAL 1530 recordings (test/fixtures-*.cam); --self replays
-- both of those AND builds a synthetic capture from the same fixtures the selftest uses,
-- driving them through the REAL framing code so the payloads are exactly what a
-- live transport would hand the parser.
local function buildSyntheticCapture()
    local records = {}
    local key = { 0x01234567, 0x89ABCDEF, 0xDEADBEEF, 0xCAFEBABE }

    -- The server side of the framing code; the client side then de-frames.
    local peer = transport.new{ gunzOs = false, onMessage = function() end }
    local t = transport.new{ onMessage = function(payload)
        records[#records + 1] = { dir = '<', time = #records * 7, payload = payload }
    end }
    t._write = function() return true end

    local function serverSends(body)
        local frame = peer:buildFrame(body)
        -- feed it in two pieces, so the accumulator is exercised as well
        local cut = math.max(1, math.floor(#frame / 3))
        assert(t:feed(frame:sub(1, cut)))
        assert(t:feed(frame:sub(cut + 1)))
    end

    local w = buffer.writer()

    -- 1. challenge (pre-XTEA)
    w:reset(); w:u8(0x1F):u32(0x11223344):u8(0x5A):u8(0)
    serverSends(w:data())

    -- the client would answer with the login packet here
    local body = handshake.buildLoginPacket{
        sessionKey = 'REPLAY-SESSION', characterName = 'Bot',
        challengeTs = 0x11223344, challengeRand = 0x5A, contentRevision = 42196,
        xteaKey = key,
    }
    records[#records + 1] = { dir = '>', time = #records * 7, payload = body }
    t:enableXtea(key)
    peer:enableXtea(key)

    -- 2. pending, then the enter-game frames go out
    serverSends(string.char(0x0A))
    for _, b in ipairs(handshake.buildEnterGameFrames('replay')) do
        records[#records + 1] = { dir = '>', time = #records * 7, payload = b }
    end

    -- 3. player data (60 payload bytes at 1530)
    w:reset(); w:u8(0xA0)
    w:u32(1234):u32(2000):u32(87650):u64(123456789):u16(42):u16(4321)
    w:u16(0):u16(0):u16(0):u16(0)
    w:u32(300):u32(600):u8(100):u16(2400):u16(220):u16(0):u16(0)
    w:u16(0):u8(0)
    w:u32(0):u32(0)
    serverSends(w:data())

    -- 4. a text message, a creature-health update and the two ping opcodes,
    --    several of them packed into ONE message (the server does this a lot)
    w:reset()
    w:u8(0xB4):u8(19):string('Welcome to Gunzodus.')
    w:u8(0x8C):u32(0x11223344):u8(77)
    w:u8(0x1E)
    w:u8(0xB5):u8(2)
    serverSends(w:data())

    -- 5. a server ping request on its own
    serverSends(string.char(0x1D))

    -- 6. a long message (a capture stores payloads AFTER inflate, so inbound
    --    compression is invisible here by construction -- it is covered by the
    --    transport suite in test/selftest.lua instead)
    w:reset(); w:u8(0xB4):u8(19):string(string.rep('a long line of server text ', 20))
    serverSends(w:data())

    return records
end

-- ===================================================================== main
-- lib/sys knows TEMP/TMP on Windows and TMPDIR//tmp on POSIX.  The local copy
-- this replaced only knew the Windows variables, so on Linux it fell back to
-- '.' and dropped luaclient-replay-selftest.cam/.lcap into the project root.
local function tempDir()
    return (require('lib.sys').tempDir():gsub('\\', '/'))
end

local function main(argv)
    -- load the item table: the parser cannot decode a tile description without it
    local ok, err = pcall(items.load, ROOT .. '/assets/items1530.bin')
    if not ok then
        io.stderr:write('replay: ', tostring(err), '\n')
        return 1
    end

    -- When main.lua dofile()s us for `--replay=FILE`, `arg` still holds MAIN's
    -- command line (--replay=..., --log-level=..., --assets=...), and the loop
    -- below rejects every unknown `--` flag -- so `run.bat --replay=FILE` used
    -- to die with "replay: unknown flag --replay=FILE" without replaying
    -- anything.  LC.replayTarget IS the handoff; when it is set, ignore argv.
    local files = {}
    local selfMode = false
    if _G.LC and _G.LC.replayTarget then argv = {} end
    for _, a in ipairs(argv) do
        if a == '--self' then selfMode = true
        elseif a:sub(1, 2) == '--' then
            io.stderr:write('replay: unknown flag ', a, '\n'); return 1
        else files[#files + 1] = a end
    end
    if _G.LC and _G.LC.replayTarget then files[#files + 1] = _G.LC.replayTarget end
    if #files == 0 then selfMode = true end

    local failures = 0

    if selfMode then
        io.write('replay: no capture given -- generating a synthetic 1530 capture\n')
        local records = buildSyntheticCapture()
        local camPath  = tempDir() .. '/luaclient-replay-selftest.cam'
        local lcapPath = tempDir() .. '/luaclient-replay-selftest.lcap'
        assert(capture.writeCam(camPath, records))
        assert(capture.writeLcap(lcapPath, records))
        io.write(('  wrote %d records (%d inbound) to\n    %s\n    %s\n'):format(
            #records, (function() local n = 0 for _, r in ipairs(records) do
                if r.dir == '<' then n = n + 1 end end return n end)(), camPath, lcapPath))
        files[#files + 1] = camPath
        files[#files + 1] = lcapPath
        -- ...and every REAL 1530 corpus recorded off the live server with --capture.
        -- These are the ones that matter: they carry the map row slices, the creature
        -- moves and the opcode mix no hand-built fixture reproduces.
        for _, name in ipairs({ 'test/fixtures-first-session.cam', 'test/fixtures-v-session.cam' }) do
            local p = ROOT .. '/' .. name
            local fh = io.open(p, 'r')
            if fh then fh:close(); files[#files + 1] = p end
        end
    end

    for _, path in ipairs(files) do
        local stats, rerr = replayFile(path)
        if not stats then
            io.write('  FAIL  ', tostring(rerr), '\n')
            failures = failures + 1
        else
            local ops = {}
            for op in pairs(stats.opcodes) do ops[#ops + 1] = op end
            table.sort(ops)
            local names = {}
            local opcodes = require('proto.opcodes')
            for _, op in ipairs(ops) do
                names[#names + 1] = ('0x%02X %s x%d'):format(op, opcodes.server[op] or '?',
                                                             stats.opcodes[op])
            end
            io.write(('  PASS  %s\n'):format(path))
            io.write(('          %d record(s): %d inbound (%d bytes, %d opcode(s)), %d outbound\n')
                :format(stats.records, stats.inbound, stats.bytes, stats.opcodeCount, stats.outbound))
            io.write('          opcodes: ', table.concat(names, ', '), '\n')
        end
    end

    io.write(('\nreplay: %d file(s), %d failure(s) -> %s\n'):format(
        #files, failures, failures == 0 and 'PASS' or 'FAIL'))
    return failures == 0 and 0 or 1
end

local code = main(arg or {})
pcall(function() require('lib.sys').shutdown() end)
os.exit(code)
