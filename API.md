# luaclient — module contract (authoritative for all implementers)

Standalone LuaJIT worker client for Gunzodus (Tibia protocol 1530, OS 61). No otclient, no C++, no
OpenGL/audio/graphics. Run with `run.bat` → `luajit main.lua [flags]`.

Byte-level truth lives in `docs/*.md` (produced by a verified reverse-engineering pass over the C++
reference at `D:\Claude\otclient_mehah1530\otclient`). **The `## VERIFIER → Corrections` section of each
doc overrides the spec body above it.** Never guess a wire detail: it is in those docs.

Layout:

```
main.lua              entry point / CLI / wiring
lib/     json.lua bit-free helpers: log.lua buffer.lua xtea.lua adler32.lua rsa.lua bigint.lua
         inflate.lua sys.lua socket.lua sched.lua http.lua
proto/   transport.lua handshake.lua opcodes.lua parser.lua sender.lua items.lua
game/    state.lua
tools/   extract_appearances.py
assets/  items1530.bin              (generated, checked in)
test/    selftest.lua replay.lua
docs/    the protocol specs
```

Every module returns a table. No globals except `_G.LC` (see main.lua). Lua 5.1 / LuaJIT dialect:
no `goto`, no integer division, use `bit` (`require('bit')`) and `ffi` freely.

## lib/log.lua
```lua
log.setLevel(name)          -- 'debug'|'info'|'warn'|'error'
log.debug(fmt, ...) log.info(...) log.warn(...) log.error(...)
log.hex(prefix, str)        -- debug-level hexdump, max 512 bytes
log.onLine(fn)              -- fn(level, text, ms) for the control plane; multiple allowed
```
Writes to stdout and, if `log.setFile(path)` was called, appends+flushes per line.

## lib/sys.lua  (FFI, Windows)
```lua
sys.nowMs()          -- monotonic double ms (QueryPerformanceCounter)
sys.randomBytes(n)   -- string, BCryptGenRandom; errors if unavailable
sys.randomU32()      -- number 0..2^32-1
sys.sleepMs(ms)
sys.getEnv(name)
```

## lib/socket.lua  (FFI ws2_32, non-blocking)
```lua
socket.init()                       -- WSAStartup once, idempotent
local s = socket.tcp()              -- object
s:connect(host, port)               -- resolves via getaddrinfo; returns true or nil,err
                                    -- non-blocking: returns immediately, use s:isConnected()
s:isConnected() -> bool
s:send(str) -> bytesSent|nil,err    -- partial sends handled internally by an outbox
s:recv(max) -> str|nil,err          -- '' when no data available (EWOULDBLOCK), nil+err on failure
s:close()
s:fd()                              -- raw SOCKET for select
socket.select(readFds, writeFds, timeoutMs) -> readySet
```
The client only needs an outbound TCP connection; a listening socket (`socket.listen(host,port)` →
`:accept()`) is required later by the control plane, so implement both.

## lib/sched.lua
```lua
sched.every(ms, fn) -> id      sched.after(ms, fn) -> id      sched.cancel(id)
sched.onSocket(sock, onReadable)     -- registers a socket in the select loop
sched.removeSocket(sock)
sched.run()                    -- blocking loop: select(all sockets, min timer delay) then fire
sched.stop()
sched.post(fn)                 -- run fn on the next loop turn
```
Timer resolution target: 10 ms. All game logic runs on this single thread.

## lib/buffer.lua
Two classes mirroring InputMessage/OutputMessage semantics but plain-Lua strings.
```lua
local R = buffer.reader(str)
R:u8() R:u16() R:u32() R:u64() R:i8()... R:bytes(n) R:string()   -- string = u16 len + bytes
R:peek8() R:skip(n) R:pos() R:setPos(p) R:remaining() R:eof()
R:double()                    -- InputMessage::getDouble (u8 precision + u32) - see docs
local W = buffer.writer()
W:u8(v) W:u16(v) W:u32(v) W:u64(v) W:bytes(str) W:string(str) W:pad(n, byte)
W:size() W:data()             -- data() = the assembled string
```
All little-endian. `R:u64` returns a Lua number when < 2^53 (fine for exp/money) and must not error.

## lib/xtea.lua / lib/adler32.lua
```lua
xtea.encrypt(key4, str) -> str      -- key4 = {u32,u32,u32,u32}; str length % 8 == 0
xtea.decrypt(key4, str) -> str
xtea.newContext(key4) -> ctx        -- ctx:encrypt(str) / ctx:decrypt(str)
xtea.scheduleBuilds() -> n          -- diagnostics: how many key schedules were ever computed
adler32.sum(str) -> u32
```
The 32 round constants are memoised per key, so encrypt/decrypt do not rebuild them per packet.

## lib/bigint.lua + lib/rsa.lua
```lua
rsa.encrypt(plain128, modulusDecimalString, exponent) -> string   -- textbook m^e mod n, NO padding,
                                                                  -- big-endian, output exactly 128 B
```
Input is exactly `rsa.size()` = 128 bytes. Must run in < 500 ms on this machine (called once/login).

## lib/inflate.lua
Raw DEFLATE (windowBits −15) in pure Lua, supporting the two modes in `docs/framing-crypto.md`:
```lua
local z = inflate.new()      -- persistent stream (STREAM mode: never reset, sync-flush framing)
z:inflateSyncFlush(str) -> outStr        -- appends "\0\0\255\255" internally if absent
inflate.once(str) -> outStr|nil          -- PER_PACKET mode (whole-stream, Z_FINISH semantics)
```
Mode latching is the transport's job, not this module's.

## lib/http.lua
```lua
http.post(url, headersTable, body) -> {status=, body=, headers=} | nil, err   -- blocking, TLS ok
```
Implementation per `docs/lua-runtime.md`'s recommendation (WinHTTP FFI preferred, curl.exe fallback
selected automatically). Must send the exact headers listed in `docs/login-http-and-packet.md`.

## proto/items.lua
```lua
items.load(path)            -- reads assets/items1530.bin, default path resolved from main
items.flags(id) -> number   -- 0 for holes and for ids in range with no flags; errors only if id==0
                            -- or id > maxObjectId
items.MAX_ID, items.COUNT
-- flag bits (must match tools/extract_appearances.py exactly):
items.CUMULATIVE = 0x01   -- count/subtype u8
items.WEAROUT    = 0x02
items.EXPIRE     = 0x04
items.CONTAINER  = 0x08
items.CLASSIFY   = 0x10   -- upgradeclassification > 0 -> tier u8
items.PODIUM     = 0x20
items.DECOKIT    = 0x40
```
`assets/items1530.bin` format (little-endian): magic `"LCIT"`, u8 version=1, u16 category count… —
**the extractor and the loader are written by the same work item; document the final format in a
comment at the top of both files.**

## proto/transport.lua
Owns socket framing + crypto state. Knows nothing about opcodes.
```lua
local t = transport.new{ host=, port=, worldName=, onMessage=function(readerOrString) end,
                         onError=function(msg) end, onConnect=function() end,
                         connectTimeoutMs=30000, readTimeoutMs=30000 }
t:connect()                 -- async; fires onConnect after the raw world-name preamble is written
                            -- REFUSES (nil,err) without a non-empty worldName: the preamble is
                            -- the first bytes on the wire.  Resets ALL per-connection state
                            -- (dead, receive accumulator, XTEA, zlib latch, sequence), so the
                            -- same object may be reconnected by a supervisor loop.
t:checkTimeouts()           -- driven by a 1 s sched timer; _fail()s on connect/read timeout
                            -- (Connection::READ_TIMEOUT == WRITE_TIMEOUT == 30 s)
t:send(bodyString)          -- applies compression header / padding / xtea / sequence / size
t:enableXtea(key4)
t:close()
t.stats                     -- {sent=, recv=, bytesIn=, bytesOut=, seq=}
```
`onMessage` receives the fully de-framed, decrypted, decompressed payload (opcode byte first).
Incoming rules, padding, the bit-31 compression flag, the pre-XTEA padding-strip rule and the
`blocks == 0` rejection are in `docs/framing-crypto.md` (read the Corrections).

## proto/handshake.lua
```lua
handshake.httpLogin{account=, password=, token=} -> {sessionKey=, worlds={}, characters={}} | nil,err
handshake.buildLoginPacket{sessionKey=, accountName=, password=, characterName=, challengeTs=,
                           challengeRand=, contentRevision=, xteaKey=} -> string
handshake.buildEnterGameFrames(accountName) -> {frame1, frame2}   -- 0x0F and the 0x32/0x0A hwid frame
handshake.hwid(accountName) -> string                             -- FNV-1a-32, "%04X-%04X"
```

## proto/opcodes.lua
```lua
opcodes.server = { [0x0A]='PendingGame', ... }        -- value -> name
opcodes.client = { EnterGame=0x0F, Ping=0x1E, ... }   -- name -> value
opcodes.names = { server=<reverse>, client=<reverse> }
```

## proto/parser.lua
```lua
local p = parser.new(state, emit)      -- state = game/state.lua instance, emit(name, data)
p:parse(payloadString)                 -- loops opcodes until the buffer is consumed; MUST consume
                                       -- every byte or raise a desync error naming the opcode,
                                       -- the byte offset and the previous opcode
p.unknownOpcodeIsFatal = true          -- default; the stream cannot resync otherwise
```
Parser updates `state` and calls `emit(eventName, payload)`. Event names mirror the C++ Lua callbacks
without the `on` prefix, lowerCamel: `gameStart`, `login`, `pending`, `talk`, `textMessage`,
`healthChange`, `manaChange`, `positionChange`, `creatureAppear`, `creatureDisappear`, `creatureMove`,
`creatureHealth`, `containerOpen`, `containerClose`, `containerAddItem`, `containerUpdateItem`,
`containerRemoveItem`, `inventoryChange`, `walkCancel`, `death`, `ping`, `pingBack`, `modalDialog`,
`loginError`, `loginAdvice`, `loginWait`, `sessionEnd`, `updateNeeded`, `spellCooldown`,
`spellGroupCooldown`, `channelList`, `openChannel`, `closeChannel`, `mapDescription`, `tileUpdate`,
`awareRangeChange`, `attackCancel`, `distanceEffect`, `magicEffect`, `animatedText`, `staticText`.

`positionChange` is emitted **exactly once per local-player move**, from the 0x6D handler (and
from the position-authoritative 0x64 / 0x4B, plus `Map::setCentralPosition`'s teleport fixup when
we are off the map). The map row slices 0x65-0x68 and the floor changes 0xBE/0xBF move the
**camera only** — `P:setCentral` does not write `state.player.pos`, exactly as the C++ does not.
Before work item V both handlers advanced the position, so every step reported two tiles and the
row slice wrote its column one tile off; see `docs/live-findings.md`, bug 4.

## proto/sender.lua
Every builder returns the body string on success, or `nil, err` when the transport refused the
frame (dead transport / failed socket write).  A refused frame is not counted in `sender.sent`,
and `attack`/`follow` do not advance `m_seq`.
```lua
local s = sender.new(transport [, {accountName=}])
s:enterGame()               -- emits BOTH gunz frames: 0x0F and 0x32/0x0A/STR hwid.
                            -- s:enterGame(false) suppresses the fingerprint frame.
s:ping() s:pingBack() s:logout()
s:walk(dir) s:turn(dir) s:stop() s:autoWalk(dirs)
s:talk(mode, channelId, receiver, text) s:talkSpell(text, aimMode, pos)
s:use(pos, itemId, stackpos, index) s:useWith(fromPos, itemId, fromStack, toPos, toId, toStack)
s:useOnCreature(pos, itemId, stackpos, creatureId)
s:move(fromPos, itemId, stackpos, toPos, count)
s:look(pos, itemId, stackpos) s:lookCreature(id)
s:attack(creatureId) s:follow(creatureId) s:cancelAttackAndFollow()
s:setFightMode(fight, chase, safe, pvp)
s:openContainer(pos, itemId, stackpos, containerId) s:closeContainer(id) s:upContainer(id)
s:equipItem(itemId, tier) s:requestChannels() s:joinChannel(id) s:leaveChannel(id)
s:answerModalDialog(id, button, choice) s:extendedOpcode(opcode, buffer)
s:seekInContainer(containerId, index)                  -- 0xCC, pages a container
s:buyItem(itemId, subType, amount, ignoreCapacity, buyWithBackpack)     -- 0x7A
s:sellItem(itemId, subType, amount, ignoreEquipped)                     -- 0x7B
s:closeNpcTrade()                                                       -- 0x7C
s:requestOutfit()                                                       -- 0xD2
s:changeOutfit{id=,head=,body=,legs=,feet=,addons=,mount=,hasMount=,familiar=}  -- 0xD3
```
`s:autoWalk(dirs)` returns `body, sentSteps`; when `sentSteps < #dirs` the path was clamped to
the 127-step wire limit and the caller must re-issue autoWalk for the remainder.
Positions are `{x=,y=,z=}`. Every builder writes bytes per `docs/opcode-map.md`.

## game/state.lua
```lua
local st = state.new()
st.player        -- {id, name, pos, health, maxHealth, mana, maxMana, level, levelPercent, exp,
                 --  magicLevel, soul, stamina, capacity, maxCapacity, speed, baseSpeed, states,
                 --  skills={[i]={level, baseLevel, percent}}, inventory={[slot]=item}, direction,
                 --  outfit, vocation, blessings, isDead}
st.creatures     -- [id] = {id, name, type, pos, direction, healthPercent, outfit, speed, light,
                 --         skull, shield, emblem, icon, isPlayer, isMonster, isNpc, passable}
st.map           -- tiles keyed "x,y,z" -> {things={ {kind='item'|'creature', id=, count=, tier=,
                 --   creatureId=} , ...}}  (max 11 things per tile, trimmed like Tile::addThing)
st.containers    -- [id] = {id, name, capacity, hasPages, firstIndex, size, items={}}
st.channels      -- [id] = name
st.world         -- {name, awareRange={left,top,right,bottom}, worldTime}
st.serverBeat    -- ms, from 0x17 LoginSuccess.  bot/walker.lua rounds every step duration to it
st.ping          -- ms round trip, written by main.lua from the 0x1E pong of our own keepalive
                 --   (nil until the first pong; every reader must have a fallback)
st.npcTrade      -- {open=bool, items={{id, subType, name, weight, buyPrice, sellPrice}, ...}}
                 --   from 0x7A OpenNpcTrade, cleared by 0x7C.  bot/cavebot.lua buysupplies/sellall
st.inventoryCounts -- [itemId*256 + tier] = amount, from 0xC0.  The only way to count items in a
                 --   CLOSED backpack (bot/supplies.lua:itemAmount)
st:tile(pos) st:setTile(pos, tile) st:cleanTile(pos) st:getCreature(id) st:walkableAt(pos)
st:setCentralPosition(pos)  -- Map::setCentralPosition: records the centre and evicts every
                            -- tile outside the aware range (GameKeepUnawareTiles is never on).
                            -- proto/parser.lua calls it from P:setCentral.
st:isAwareOf(pos [, central]) -> bool     -- Map::isAwareOfPosition, incl. the floor projection
st:reset()                  -- mutates st.world / st.world.awareRange IN PLACE: proto/parser.lua
                            -- aliases the awareRange table and must see the reset
```
`st:walkableAt(pos)` second return is one of `'unknown-tile'`, `'no-ground'`, `'creature'`
(definite false) or `'items-unknown'` (true, item blocking unchecked).
`st:addThing(...)` returns `nil` when the thing was filtered out **or** when the 11-thing trim
deleted the very thing it just inserted.
The map keeps only what the server sends (aware range around the player); `cleanTile` removes.

## main.lua
```lua
_G.LC = { log=, sched=, state=, transport=, parser=, sender=, config=, events=, items=,
          sys=, dir=, bot= }        -- `bot` only while the bot layer is running
```
CLI flags: `--account=`, `--password=`, `--character=`, `--world=`, `--token=`, `--host=`,
`--assets=<dir with items1530.bin>`, `--log-level=`, `--log-file=`, `--dry-run` (offline: no
sockets, used by tests), `--selftest` (run test/selftest.lua and exit), and the bot flags
`--bot`, `--bot-profile=`, `--bot-vprofile=`, `--cavebot=`, `--targetbot=`,
`--bot-status-interval=` (see BOT.md).
`LC.events.on(name, fn)` / `LC.events.emit(name, data)` is the single event bus the parser feeds.

Boot: parse flags → load items → HTTP login → pick world+character → transport connect → challenge →
login packet → XTEA on → enterGame → parse loop → log `player: hp/mana/level/pos` on change.
With `--bot`, the bot layer is constructed and started on the `gameStart` / `login` event
(`bot.new(LC, ...)` then `b:wireModules{...}` then `b:start()`), logs a one-line status every
`--bot-status-interval` ms, and is stopped -- which persists its storage -- from `shutdown()`,
so a disconnect, a `SessionEnd` and a fatal all save. The contract is [`BOT.md`](BOT.md).

## Testing (test/)
* `selftest.lua`: XTEA vectors, adler32, RSA against a known ciphertext, inflate round-trip, buffer
  round-trip, hwid string, framing round-trip (build a frame, feed it back through the receive path).
* `replay.lua`: reads a capture file and feeds payloads to `parser:parse`, asserting full consumption.
Both must run with `luajit test/selftest.lua` from the project root and exit non-zero on failure.
