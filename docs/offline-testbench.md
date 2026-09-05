# Offline test vectors and tooling: the `.cam` packet-recording format, `packet.log`, the socket-less replay path, and a concrete offline test bench for a pure-Lua 1530 protocol parser

## 0. Executive answers to the direct questions

| Question | Answer |
|---|---|
| Does `.cam` capture decrypted payloads? | **YES.** Inbound lines are written *after* checksum/sequence stripping, *after* XTEA decryption, *after* zlib decompression, and *after* padding trimming. The first byte of a `<` line is a game opcode. |
| Are outbound packets plaintext too? | **YES.** `Protocol::send` calls the recorder as its *first* statement, before the gunzotc compression header, before padding, before XTEA, before checksum/sequence, before the size header. A `>` line starts with the client opcode. (Exception: the login packet's RSA block is already RSA-encrypted at that point — `encryptRsa()` happens in `sendLoginPacket` before `send()`.) |
| Is there a replay path with no socket? | **YES.** `g_game.playRecord(file)` → `Protocol::playRecord` → `PacketPlayer` → `Protocol::onPlayerPacket` → `ProtocolGame::onRecv` → `parseMessage`. No `Connection`, no asio socket, no crypto. |
| Can new recordings be made from the GUI client? | **YES**, with a 1-line Lua edit (add a 9th arg to `g_game.loginWorld`). No rebuild needed. |
| Existing unit-test scaffolding? | **Half-existing.** `OTCLIENT_BUILD_TESTS`, a vcpkg `tests` feature (gtest), dedicated triplets and `windows-tests`/`linux-debug`/`macos-debug`/`windows-release-asan` test presets all exist — but the `tests/` directory **does not exist**, so `add_subdirectory(tests)` fails today. You must create it. |
| Existing sample data? | `records/test1098.cam` only — 249,183 bytes, 641 lines, 324 inbound + 317 outbound, protocol **1098**, ~60 s of session, 121,444 payload bytes. There is **no 1530 sample**; you must record one. |

---

## 1. The `.cam` file format (exact)

### 1.1 It is a plain-text, line-oriented, hex-encoded format

Writer: `src/framework/net/packet_recorder.cpp:45-67`.

```cpp
void PacketRecorder::addInputPacket(const InputMessagePtr& packet)
{
    m_stream << "< " << (g_clock.millis() - m_start) << " ";
    for (auto& buffer : packet->getBodyBuffer()) {
        m_stream << std::setfill('0') << std::setw(2) << std::hex << (uint16_t)(uint8_t)buffer;
    }
    m_stream << std::dec << "\n";
}
```

Grammar (one record per line):

```
line    := dir SP time SP hexpayload EOL
dir     := "<"            ; server -> client  (inbound)
         | ">"            ; client -> server  (outbound)
SP      := one 0x20 space
time    := decimal ASCII int64, milliseconds since PacketRecorder construction
hexpayload := (hexdigit hexdigit)*   ; lowercase, no separators, 2 chars per byte
EOL     := "\n" written to a TEXT-mode ofstream
```

Concrete facts, verified against `records/test1098.cam`:

- Byte encoding is **lowercase** hex, exactly 2 chars/byte, no `0x`, no spaces (`std::hex` is lowercase by default; `setw(2)`+`setfill('0')` guarantees 2 chars).
- `std::dec` is restored at end of every line, so `time` is always decimal.
- The stream is opened in **text mode** (`std::ofstream(path)` — no `std::ios::binary`), so on Windows every `\n` becomes **CRLF**. Measured: 641 CRLF, 641 LF ⇒ every line ends `\r\n`. On Linux you get bare LF. **A reader must tolerate both.**
- The file has a trailing newline; the last split element is empty.
- Timestamps are monotonically non-decreasing (verified: first `3`, last `59950`, monotone). Many consecutive records share the same timestamp — they are not unique keys.
- `ticks_t` is `int64_t` (`src/framework/stdext/types.h:35`), `g_clock.millis()` is wall-clock-ish ms since client start; `m_start` is captured in the `PacketRecorder` constructor (`packet_recorder.cpp:30`), i.e. at `Game::loginWorld` time, so `t=0` ≈ start of the game-world connection.
- Payload sizes observed: min 1 byte, max 11,099 bytes (one line can be ~22 KB of text). No zero-length payloads in the sample.

### 1.2 File location and lifetime

- Written to `records/<name>` **relative to the process working directory** (`packet_recorder.cpp:36-37`); the directory is created if missing (`std::filesystem::create_directory("records", ec)`). On Android: `g_resources.makeDir("records")` then `records/<name>`.
- `records/.gitignore` is `*` + `!.gitignore !README.md !test1098.cam`, so new recordings are ignored by git by default.
- **There is no explicit flush or close.** `PacketRecorder::~PacketRecorder()` is empty (`packet_recorder.cpp:41-43`); the `std::ofstream` member's destructor is what flushes. The recorder is owned by `ProtocolGame::m_recorder` (a `shared_ptr`), so the file is only fully flushed when the `ProtocolGame` object dies (clean logout / disconnect / client exit). **Kill the process and you lose the tail of the recording.** Always log out cleanly.

### 1.3 What exactly is in a `<` (inbound) payload

`addInputPacket` is called at `src/framework/net/protocol.cpp:327-329`, at the very end of `internalRecvData`, *after* everything:

```cpp
    if (m_recorder) {
        m_recorder->addInputPacket(m_inputMessage);
    }
    onRecv(m_inputMessage);
```

and it serialises `InputMessage::getBodyBuffer()` (`inputmessage.h:47`):

```cpp
std::string getBodyBuffer() { return std::string((char*)m_buffer + m_maxHeaderSize, m_messageSize - getHeaderSize()); }
```

with `m_maxHeaderSize = (clientVersion >= 1405) ? 7 : 8` (`inputmessage.cpp:184,191`) and `getHeaderSize() = m_maxHeaderSize - m_headerPos` (`inputmessage.h:137`).

**Buffer layout for protocol 1530** (checksum ON via `GameProtocolChecksum` ≥840, sequenced ON via `GameSequencedPackets` ≥1290 *and* `Protocol::onConnect` ≥1200):

`recv()` computes `headerSize = 2 + 4 + 1 = 7` (`protocol.cpp:199-206`), `m_maxHeaderSize = 7`, so `m_headerPos = 0`:

```
offset 0..1 : u16 wire size field   (remainingSize = size * 8 + 4   — protocol.cpp:222-224)
offset 2..5 : u32 sequence / compression flag (bit31 = compressed)  — protocol.cpp:252
offset 6    : u8  padding count      (consumed by xteaDecrypt)      — protocol.cpp:382
offset 7..  : DECRYPTED GAME PAYLOAD  <-- getBodyBuffer() starts HERE
```

`xteaDecrypt` for ≥1405 sets `messageSize = headerSize + (encryptedSize - paddingSize - 1)` (`protocol.cpp:384-385`), so `getBodyBuffer()` length == `decryptedSize` == payload **with the XTEA block padding removed**.

If `decompress` was set (sequence bit 31), the inflated bytes are written at offset 7 and `setMessageSize(getHeaderSize() + totalSize)` (`protocol.cpp:323-324`), so the recorded body is the **decompressed** payload.

⇒ **A `<` payload is exactly the byte range that `ProtocolGame::parseMessage` iterates over.** That is what makes it a perfect parser test vector.

**Pre-1405 layout, for reading the shipped `test1098.cam`:** `m_maxHeaderSize = 8`, `headerSize = 2 + 4(checksum) + 2(xtea inner size)` once XTEA is on ⇒ `m_headerPos = 0`; layout `0..1 size | 2..5 checksum | 6..7 xtea decrypted-size | 8.. payload`. Body still starts at `m_maxHeaderSize = 8` = payload. Same guarantee.

### 1.4 ⚠️ The first inbound record is structurally different

`ProtocolGame::onRecv` (`src/client/protocolgame.cpp:61-82`):

```cpp
    if (m_firstRecv) {
        m_firstRecv = false;
        if (g_game.getClientVersion() >= 1405) {
            inputMessage->getU8(); // padding
        } else if (g_game.getFeature(Otc::GameMessageSizeCheck)) {
            const int size = inputMessage->getU16();
            if (size != inputMessage->getUnreadSize()) { ... return; }
        }
    }
    parseMessage(inputMessage);
```

The first server message arrives **before XTEA is enabled** (for 1530 `GameChallengeOnLogin` is on, so `sendLoginPacket` — and therefore `enableXteaEncryption()` at `protocolgamesend.cpp:221` — has not run yet). So `xteaDecrypt` did **not** run on it, which has two consequences for the recording:

1. **Trailing padding is NOT trimmed on the first record.** `m_messageSize` stays `2 + remainingSize`, so `getBodyBuffer()` length is `remainingSize - 5` = *payload + XTEA-block padding bytes*. For 1530 a 6-byte challenge payload comes out as 7 recorded bytes (`1F` + u32 + u8 + one `0x00` pad). A strict "consume every byte" assertion **will fail on record #0** unless you special-case it. (The C++ client tolerates it: opcode `0x00` is not in `GameServerOpcodes`, so it hits the `default:` branch, logs an "Unhandled opcode" warning and `skipBytes(0)` — `protocolgameparse.cpp:684-700`.)
2. **`getBodyBuffer()` starts at offset 7 — i.e. *after* the padding-count byte the ≥1405 `m_firstRecv` branch consumes.** For 1530 the padding-count byte is at buffer offset 6 and is therefore **not** in the recorded line. For <1405 the `GameMessageSizeCheck` u16 lives at offset 8 and **is** in the recorded line (visible in `test1098.cam` line 1: `06 00 1F …`).

⇒ **Consequence for the built-in replay path (see §3): `g_game.playRecord` on a ≥1405 recording eats one byte too many from record #0.** `onPlayerPacket` does `setHeaderSize(0)` so `m_headerPos = m_readPos = m_maxHeaderSize = 7` and the recorded body is placed at offset 7 (`protocol.cpp:496-501`); then `onRecv`'s `m_firstRecv` `getU8()` consumes the recorded body's *first* byte (the opcode `0x1F`) instead of a padding-count byte that isn't there. The 1098 path is self-consistent; the 1530 path is off by one. Your Lua bench must model the **live** semantics (skip nothing on record #0 for ≥1405), not the replay semantics. This is a code-reading conclusion, not runtime-verified.

### 1.5 What exactly is in a `>` (outbound) payload

`addOutputPacket` is called at `protocol.cpp:129-131`, the **first** thing `Protocol::send` does:

```cpp
void Protocol::send(const OutputMessagePtr& outputMessage, bool raw)
{
    if (m_player) { m_player->onOutputPacket(outputMessage); return; }
    if (m_recorder) { m_recorder->addOutputPacket(outputMessage); }
    if (!raw) { /* compression header, padding, xtea, checksum/sequence, size header */ }
```

and serialises `OutputMessage::getBuffer()` = `{ m_buffer + m_headerPos, m_messageSize }` (`outputmessage.h:350`). At record time no `prepend*`/`write*` has run, so `m_headerPos == m_maxHeaderSize` and the slice is **exactly the payload the caller wrote, starting at the client opcode**. Nothing from `prependCompressionHeader` (`outputmessage.cpp:164-181`), `writePaddingAmount`, XTEA, `writeSequence`/`writeChecksum` or `writeHeaderSize` is present.

⇒ `>` lines are **golden vectors for your packet builder**: build the same action in Lua and `assert(built == recorded)` byte-for-byte, before the transport wrapper.

**The first outbound packet is deliberately dropped** (`packet_recorder.cpp:56-60`, "skip packet with login and password"). For clientVersion ≥ 1200 — i.e. for 1530 — that heuristic misfires: `Protocol::onConnect` sends the world-name packet first (`protocol.cpp:423-428`, `worldName + '\n'`, `send(msg, true)` raw), so **the world-name packet is what gets skipped and the login packet IS recorded**. It is recorded with its RSA block already encrypted (`sendLoginPacket` calls `msg->encryptRsa()` before `send()`, `protocolgamesend.cpp:212-218`), so account/password are not in cleartext — but the pre-RSA prefix (opcode, OS id 61, client/protocol version, sprite/content revision, preview flag) **is** cleartext in the file. Treat recordings as semi-sensitive; they also contain your character name, position, inventory and chat.

Also note `send()` is called with `raw=true` for the world-name packet — `raw` does **not** bypass the recorder, only the framing.

### 1.6 Reference reader (Python) and the shipped test vector

```python
def read_cam(path):
    recs = []
    with open(path, 'rb') as f:
        for raw in f.read().split(b'\n'):
            line = raw.rstrip(b'\r').strip()
            if not line: continue
            parts = line.split(b' ')
            d, t = parts[0].decode(), int(parts[1])
            hexs = parts[2] if len(parts) > 2 else b''   # empty payload -> "< 123 " (see gotcha)
            recs.append((d, t, bytes.fromhex(hexs.decode())))
    return recs
```

Decoded sanity vectors from `records/test1098.cam` (protocol 1098):

- Line 1 `< 3 06001ff3ead46794` → body `06 00 1F F3 EA D4 67 94`
  = `u16 0x0006` (GameMessageSizeCheck, matches the 6 remaining bytes) · opcode `0x1F` `GameServerChallenge` (`protocolcodes.h:64`) · `u32 0x67D4EAF3` timestamp · `u8 0x94` random.
- Line 3 `> 23 0f` → `0x0F` = `ClientEnterGame` (sent from `ProtocolGame::sendEnterGame`).
- Line 5 `> 23 32010200656e` → `0x32` = `ClientExtendedOpcode` (= `GameServerExtendedOpcode = 50`, `protocolcodes.h:76`) · sub-opcode `0x01` · `u16 0x0002` + `"en"` (locale, `modules/client_locales/locales.lua`).

Top inbound opcodes in the sample (by first payload byte): `0x6D` ×189, `0x1E` ×59, `0x83` ×27, `0x1D` ×8, `0xA2`/`0x6C`/`0x6E`/`0xB4`/`0xAA` ×5 each.

### 1.7 Parsing gotchas

1. **CRLF vs LF** — text-mode ofstream. Strip `\r`.
2. **Zero-length payloads break the C++ reader.** `PacketPlayer` uses `while (f >> type >> time >> packetHex)` (`packet_player.cpp:45`), a whitespace-token stream. A record whose body is empty produces `"< 123 \n"`, and the next line's `"<"` is then consumed as `packetHex`, desynchronising the whole rest of the file. Your reader must be **line-oriented**, and should hard-error on a record with a missing third token rather than silently mis-parse. (No empty payloads occur in `test1098.cam`, but nothing prevents them: `decryptedSize` can be 0.)
3. **Odd-length hex** would silently drop a nibble in the C++ reader (`i += 2` + `substr(i,2)`); treat it as a fatal error.
4. **`strtol` on non-hex** yields 0 in the C++ reader; be stricter.
5. `>` records are **never replayed** by `PacketPlayer` — they are loaded into `m_output` (`packet_player.cpp:57`) and never read. Only `onOutputPacket`'s `buffer[0] == 0x14` logout check (`packet_player.cpp:80`) uses live output. So the `>` lines exist purely as documentation/test vectors.
6. **One `<` record can contain many game messages.** `parseMessage` loops `while (!msg->eof())` reading one opcode at a time (`protocolgameparse.cpp:47-56`). The 11 KB record in the sample is dozens of concatenated messages. Your parser must loop, not assume one opcode per record.
7. There is **no header, no magic, no version stamp** in a `.cam`. The protocol version is out-of-band — you must record it yourself (put it in the filename, e.g. `1530-20260905-town.cam`).

---

## 2. `packet.log` format

**Single writer:** `src/client/protocolgameparse.cpp:727` — the `catch (const stdext::exception& e)` handler at the bottom of `ProtocolGame::parseMessage`. Nothing else in the tree writes it (`grep -rn "packet\.log" src/ modules/ mods/` → 1 hit).

```cpp
        std::ofstream packet("packet.log", std::ios::app);
        if (!packet.is_open()) { return; }
        packet << fmt::format(
            "[EXCEPTION] {} unread bytes at pos: {}, protocol: {}, current: 0x{:02X} ({:d}), prev: 0x{:02X} ({:d}), error: {}\nBytes: {}\n",
            unread, readPos, g_game.getProtocolVersion(), opcode, opcode, prevOpcode, prevOpcode, e.what(), hexDump.str());
```

- **It is an append-only crash/desync log, not a packet capture.** It records only messages whose parse threw. A healthy session leaves it untouched.
- Two lines per event:
  - `[EXCEPTION] <unread> unread bytes at pos: <readPos>, protocol: <protoVer>, current: 0x<HH> (<dec>), prev: 0x<HH> (<dec>), error: <what>`
  - `Bytes: <HH SP HH SP ...>` — **uppercase** hex, space-separated, **trailing space**, from `msg->peekBytes(unread)` (`fmt::format("{:02X} ", byte)`).
- `opcode`/`prevOpcode` are `int` initialised to `-1`, so `{:02X}` on `-1` prints literally `0x-1 (-1)` — present in the current file. Parsers must tolerate it.
- `readPos` is `InputMessage::getReadPos()` = **absolute buffer offset `m_readPos`**, not an offset into the message body. For 1530 (live path) `m_headerPos == 0` and `m_maxHeaderSize == 7`, so **body offset = readPos − 7**. Under `playRecord` (`setHeaderSize(0)` ⇒ `m_headerPos == 7`) it is also `readPos − 7`. For 1098 subtract 8.
- `unread == 0` gives an empty `Bytes: ` line — see the current file's first two entries.
- The same event is *also* emitted to `otclient.log` via `g_logger.error` in a longer format (`protocolgameparse.cpp:714-726`) that additionally includes `msg->getMessageSize()`.
- Written next to the working directory, `std::ios::app`, opened/closed per event ⇒ each event is flushed immediately (unlike `.cam`).

Current file: `D:/Claude/otclient_mehah1530/otclient/packet.log`, 57,187 bytes, protocol `1530`, e.g.

```
[EXCEPTION] 0 unread bytes at pos: 30, protocol: 1530, current: 0xE2 (226), prev: 0xEE (238), error: InputMessage eof reached
Bytes: 
[EXCEPTION] 18925 unread bytes at pos: 443, protocol: 1530, current: 0xFC (252), prev: 0x-1 (-1), error: InputMessage eof reached
Bytes: 00 05 00 4C 61 6D 70 73 ...
```

**Use it as a bug oracle, not a test corpus:** every entry is a message *the C++ reference client itself gets wrong for 1530*. Your Lua parser will hit the same walls; these entries tell you which opcodes are already broken upstream (`0xE2`/`0xEE`, `0xFC` with a huge unread tail) so you don't chase a phantom bug in your own code. Note the file's dumps are only `peekBytes(unread)` from the failure point — they are not complete messages and cannot be replayed.

---

## 3. The socket-less replay path (does it exist? yes)

`Game::playRecord` (`src/client/game.cpp:621-641`), bound as `g_game.playRecord` (`src/client/luafunctions.cpp:245`):

```
g_game.playRecord("file.cam")
  -> new PacketPlayer(file)                       // parses the whole .cam into two deques
  -> resetGameStates(); new LocalPlayer("Player")
  -> new ProtocolGame; m_protocolGame->playRecord(player)
       Protocol::playRecord (protocol.cpp:506-517):
         m_disconnected = false; m_player = player;
         m_player->start(onPlayerPacket, onLocalDisconnected);   // schedules process() in 50 ms
         onConnect();                                            // ProtocolGame::onConnect
```

- `PacketPlayer::process()` (`packet_player.cpp:86-104`) drains `m_input` on the dispatcher, honouring the recorded millisecond timestamps relative to `m_start = g_clock.millis()` at `start()`. When `m_input` empties it fires `m_disconnectCallback(asio::error::eof)`.
- `Protocol::onPlayerPacket` (`protocol.cpp:487-504`) posts to `g_ioService`, then:
  ```cpp
  m_inputMessage->reset();
  m_inputMessage->setHeaderSize(0);
  m_inputMessage->fillBuffer(packet->data(), packet->size());
  m_inputMessage->setMessageSize(packet->size());
  onRecv(m_inputMessage);
  ```
  `setHeaderSize(0)` ⇒ `m_headerPos = m_readPos = m_maxHeaderSize` (7 for 1530, 8 for <1405), so the body lands exactly where `getBodyBuffer()` read it from. **Symmetric with the recorder** — modulo the ≥1405 first-record off-by-one in §1.4.
- Outbound sends are swallowed by `PacketPlayer::onOutputPacket`, which only checks `buffer[0] == 0x14` (`ClientLogout`) to end playback. `Protocol::send` returns immediately when `m_player` is set (`protocol.cpp:124-127`), so no crypto, no socket, no recorder.
- `ProtocolGame::onConnect` still runs: `Protocol::onConnect` sends the world-name packet (swallowed), enables sequenced packets, `enableChecksum()` runs, and because `GameChallengeOnLogin` is on for 1530 it does **not** send a login packet. When the recorded `0x1F` challenge arrives, `sendLoginPacket` fires and is swallowed. `m_accountName`/`m_password` are empty (playRecord never calls `ProtocolGame::login`), which is harmless.
- Documented invocation (`records/README.md`):
  ```lua
  g_game.setClientVersion(1098)
  g_game.setProtocolVersion(g_game.getClientProtocolVersion(1098))
  g_game.playRecord("test1098.cam")
  EnterGame.hide()
  ```
  For a 1530 recording: `g_game.setClientVersion(1530); g_game.setProtocolVersion(g_game.getClientProtocolVersion(1530)); g_game.playRecord("mycap.cam"); EnterGame.hide()`.
- **Playback is real-time** (it honours the recorded timestamps), so a 60-second recording takes 60 seconds to replay. For CI use your own Lua/Python harness (§5), not `playRecord`.

---

## 4. Producing new 1530 recordings from the existing GUI client

**No rebuild required.** Two options.

### 4.1 Permanent (recommended): edit one Lua line

`modules/client_entergame/characterlist.lua:427-428` currently:

```lua
    g_game.loginWorld(G.account, G.password, charInfo.worldName, charInfo.worldHost, charInfo.worldPort,
                      charInfo.characterName, G.authenticatorToken, G.sessionKey)
```

Add a 9th argument = the output filename (extension is yours; `.cam` by convention):

```lua
    g_game.loginWorld(G.account, G.password, charInfo.worldName, charInfo.worldHost, charInfo.worldPort,
                      charInfo.characterName, G.authenticatorToken, G.sessionKey,
                      ('1530-%s.cam'):format(os.time()))
```

Mechanism: `Game::loginWorld(..., const std::string_view& recordTo)` (`src/client/game.cpp:597`) does

```cpp
    if (!recordTo.empty()) {
        m_protocolGame->setRecorder(std::make_shared<PacketRecorder>(recordTo));
    }
```

The C++ signature has **no default** for `recordTo` (`src/client/game.h:165`), yet the current 8-arg call works — the Lua binder's `polymorphicPop` yields an empty string for the missing argument, which the `!recordTo.empty()` guard treats as "don't record". (Observed behaviour of the shipped client, not a documented contract.) It is safer to make the toggle explicit, e.g.

```lua
local rec = g_settings.getString('packet-record-file') or ''
g_game.loginWorld(..., G.sessionKey, rec)
```

and set `g_settings.set('packet-record-file', '1530-town.cam')` from the console before logging in.

### 4.2 Reminders when recording

- Output lands in `<cwd>/records/<name>`; the directory is auto-created.
- **Log out through the game (Ctrl+Q / logout button), don't kill the process** — the `ofstream` is only flushed by its destructor when `ProtocolGame` is released (§1.2).
- The recorder is attached *before* `ProtocolGame::login`, so the challenge packet and the whole handshake are captured.
- Recordings contain your character name, position, inventory, chat and the cleartext prefix of the login packet. Don't commit them blindly; `records/.gitignore` already ignores everything but the three whitelisted files.
- To get broad opcode coverage, script a deliberate "tour": walk between floors, open every container, open market/store/wheel/bosstiary/imbuement/cyclopedia windows, trade, use a spell, take damage, receive a party invite, open the outfit dialog, log out. One 5-minute tour beats ten idle recordings.
- Record several *small* focused files (`1530-login.cam`, `1530-market.cam`, `1530-store.cam`, `1530-combat.cam`) rather than one giant one — a failing test then names the feature.

### 4.3 Server-side alternative

`records/README.md` also points at gesior's `tmp-cams-system` TFS patch: the server writes the `.cam`, you move it from `tfs/records/` into `otclient/records/`. Same text format. Useful if you want recordings without touching the client, but you'd be trusting the server's idea of the payload rather than the client's — for validating *your* parser the client-side recorder is the better oracle because it captures exactly what the reference parser consumed.

---

## 5. The offline test bench

### 5.1 Design principle

`getBodyBuffer()` gives you exactly the byte range `parseMessage` iterates. So the strongest cheap invariant is:

> After parsing a `<` record, the cursor must land **exactly** on the end of the record — not one byte short, not one byte over.

A single wrong field width anywhere desynchronises the rest of the record and the assertion fires immediately, usually within the same record. This is the "off-by-one desyncs immediately" signal you asked for, and it needs no server.

### 5.2 Bench layers

**L0 — `cam.lua`**: line-oriented reader (§1.6 semantics). Returns `{dir=..., t=..., data=<string of raw bytes>}`. Hard-errors on odd-length hex, non-hex chars, or a missing payload token.

**L1 — `cursor.lua`**: a strict reader over a Lua string with `pos` (1-based), `u8/u16/u32/u64/i64/str/double/skip/peek*`, `remaining()`, `eof()`. Every read bounds-checks and `error()`s with `{opcode, pos, want, have}` — mirroring `InputMessage::checkRead` (`inputmessage.cpp:298-302`). Use LuaJIT `ffi.cast` / `bit` for LE decode; `getString` is `u16 len` + bytes (`inputmessage.cpp:247-254`); `getDouble` is `u8 precision` + `(u32 - INT_MAX) / 10^precision` (`inputmessage.cpp:256-261`) — note `INT_MAX` = 2147483647, not 2^31.

**L2 — `parser.lua`**: your opcode dispatch table, mirroring `parseMessage`'s loop:
```
while not cur:eof() do  opcode = cur:u8();  handler[opcode](cur)  end
```
In **test mode** an unknown opcode must be a hard failure. Do *not* copy the C++ `default:` branch (`msg->skipBytes(unreadSize)`, `protocolgameparse.cpp:697`) — that is a production survival hack that would hide exactly the bugs you're hunting.

**L3 — `runner.lua`**: iterate records, apply the ≥1405 first-record rule (§1.4), assert, report.

### 5.3 The assertion ladder (weakest → strongest)

1. **Full consumption.** `assert(cur.pos == #data + 1)` after each `<` record.
2. **Progress.** Every handler consumes ≥ 1 byte; a handler that consumes 0 is an infinite loop waiting to happen.
3. **No unknown opcode**, and no `pcall`-swallowed handler.
4. **Record #0 special case.** For a ≥1405 recording, record #0 is the plaintext challenge: parse it, then allow **≤ 7 trailing bytes that are all `0x00`** (XTEA block padding, §1.4) — assert they are zeros rather than blanket-skipping.
5. **Per-opcode consumption trace equality vs. the C++ client** (§5.4) — this is the one that catches "both sides consumed 12 bytes but disagreed on which 12".
6. **Decoded-value diff** (§5.5).
7. **Mutation tests.** For each record: (a) truncate by 1 byte ⇒ the parser MUST raise; (b) append 1 byte ⇒ the full-consumption assert MUST fire. A parser that passes the corpus but survives both mutations is silently skipping bytes.
8. **Builder round-trip.** For each `>` record, construct the same message with your Lua builder and `assert(built == recorded)`. Remember record #0 of the outbound stream is missing (§1.5), and for 1530 the first *recorded* `>` is the RSA'd login packet — skip it or compare only its cleartext prefix.

### 5.4 Golden per-opcode trace from the C++ client (the "diff against C++ behaviour" tool)

There is a Lua hook on the hot path that needs **no C++ change and no rebuild**:

`protocolgameparse.cpp:63-71`
```cpp
            const int readPos = msg->getReadPos();
            if (callLuaField<bool>("onOpcode", opcode, msg)) { continue; }
            msg->setReadPos(readPos);   // restore read pos
```

Because the read position is restored when the hook returns false, a hook can observe every opcode **without perturbing parsing**. `ProtocolGame:onOpcode` is a plain Lua method (`modules/gamelib/protocolgame.lua:7-15`), so a mod loaded after `gamelib` can wrap it:

```lua
-- mods/protocol_trace/protocol_trace.lua
local out, base = {}, ProtocolGame.onOpcode
function ProtocolGame:onOpcode(opcode, msg)
    out[#out+1] = string.format('%d %d %d', opcode, msg:getReadSize(), msg:getMessageSize())
    return base(self, opcode, msg)     -- must still return false for unregistered opcodes
end
function dumpTrace(name)
    g_resources.writeFileContentsToWorkDir(name or 'trace.txt', table.concat(out, '\n'))
end
```

Bindings used are all present: `getReadSize`, `getMessageSize`, `eof`, `getUnreadSize` (`src/framework/luafunctions.cpp:1081-1084`); `g_resources.writeFileContentsToWorkDir` (`luafunctions.cpp:285`). Note **`getReadPos` is NOT bound to Lua** — use `getReadSize()` (= `m_readPos - m_headerPos`), which is measured from the same origin as `getMessageSize()` (see `InputMessage::eof`, `inputmessage.h:88`), so the two are directly comparable.

Deriving the reference consumption per opcode from that trace:
- Entry `i` fires *after* the opcode byte was consumed, so `readSize_i` = offset just past opcode *i*.
- `bytesConsumedBy(i) = readSize_{i+1} - 1 - readSize_i` while `i` and `i+1` are in the same record.
- New record detected when `readSize_{i+1} <= readSize_i`. For the live socket path on 1530, the first opcode of a record has `readSize == 8` (headerPos 0, body starts at 7, +1 for the opcode). Under `playRecord` it is `1` (headerPos 7).
- Last opcode of a record: `bytesConsumedBy(last) = getMessageSize() - readSize_last`.

Now drive both sides with the **same** `.cam` — `g_game.playRecord("x.cam")` for the C++ side, your runner for the Lua side — and diff the `(recordIndex, opcode, bytesConsumed)` triples. First mismatch names the offending opcode and the exact byte count you got wrong. This is the highest-value piece of tooling in this document; build it first.

Two caveats: (a) apply the ≥1405 replay off-by-one correction from §1.4 to record #0 (or simply drop record #0 from the diff); (b) `g_resources.writeFileContentsToWorkDir` on every packet would be far too slow — buffer in a table and dump on `onGameEnd`/manually from the console.

A cheaper coarse check that needs no trace at all: replay your recording in the C++ client and watch `packet.log`. If it stays unchanged the recording is fully parseable by the reference implementation, so any failure in your Lua bench is *your* bug. If `packet.log` grows, the reference itself desyncs there — compare against the pre-existing 1530 entries (§2) before blaming yourself.

### 5.5 Value-level diff (beyond byte counts)

Byte counts catch structure; they don't catch endianness or field-order swaps that happen to be the same width. For that, dump the *decoded* values from both sides for a chosen subset:
- **C++ side:** register per-opcode Lua callbacks via `ProtocolGame.registerOpcode(opcode, fn)` (`modules/gamelib/protocolgame.lua:49-55`) for the opcodes you want; that *replaces* the C++ handler, so decode fully in Lua and return true. Cheaper alternative for game-state opcodes: after replay, snapshot observable state through existing bindings (`g_game.getLocalPlayer():getPosition()`, health/mana/skills, `g_map` tile contents at a few coordinates, container contents) and compare against your Lua client's model.
- **Lua side:** emit the same records.
- Diff as JSONL keyed by `(recordIndex, opcodeIndex)`.

### 5.6 Corpus curation and CI

```
tests/protocol/
  cam.lua  cursor.lua  runner.lua
  corpus/1530-login.cam  1530-town.cam  1530-market.cam  1530-store.cam  1530-combat.cam
  golden/1530-town.trace           # from §5.4
  expected/1530-town.summary       # opcode -> count, total bytes  (regression tripwire)
```

Run with plain LuaJIT: `luajit tests/protocol/runner.lua tests/protocol/corpus/*.cam`. Exit non-zero on the first assertion. Add `expected/*.summary` so a parser change that silently starts skipping a message type shows up as a count delta even when every byte still balances.

`records/.gitignore` ignores `*`, so keep your corpus **outside** `records/` (the reference tree is read-only anyway) — put it in your Lua client's own repo and copy files into `otclient/records/` only when you want to replay one in the GUI client.

---

## 6. Existing unit-test scaffolding

- `CMakeLists.txt:29` — `option(OTCLIENT_BUILD_TESTS "Build unit tests" OFF)`.
- `CMakeLists.txt:156-167`:
  ```cmake
  if(OTCLIENT_BUILD_TESTS AND NOT ANDROID)
      if(NOT "tests" IN_LIST VCPKG_MANIFEST_FEATURES)
          message(FATAL_ERROR "OTCLIENT_BUILD_TESTS requires the vcpkg manifest feature 'tests'. ...")
      endif()
      enable_testing()
      add_subdirectory(tests)
  ```
- `vcpkg.json` `"features": { "tests": { "dependencies": [ "gtest" ] } }` — **gtest** is the intended framework.
- Triplets: `cmake/triplets/x64-windows-test-debug.cmake`, `x64-windows-test-release.cmake`.
- Presets (`CMakePresets.json`): configure `windows-tests` (Debug, `OTCLIENT_BUILD_TESTS=ON`, `VCPKG_MANIFEST_FEATURES=tests`, triplet `x64-windows-test-debug`) and `windows-release-asan` (Release + ASAN + tests, triplet `x64-windows-test-release`); build presets of the same names; testPresets `windows-tests`, `windows-release-asan`, `linux-debug`, `macos-debug`, all with `"noTestsAction": "error"`.
- User presets (`CMakeUserPresets.json`): `win-local` (inherits `windows-release`) and `win-local-debug` (inherits `windows-debug`) — **neither enables tests**.

**`D:/Claude/otclient_mehah1530/otclient/tests/` does not exist.** Configuring `windows-tests` today fails at `add_subdirectory(tests)`. So the scaffolding is a hook without a body: you would have to author `tests/CMakeLists.txt` yourself.

**Recommendation:** don't. Your deliverable is a pure-LuaJIT client, and hosting its tests in a gtest target inside a read-only C++ reference tree is the wrong coupling — it forces a full vcpkg/MSVC build for what is a text-file-in, assertion-out test. Use a standalone LuaJIT runner (§5.6). Reserve the gtest slot for the one thing it is genuinely good at, if you ever want it: **differential vectors** for `xteaEncrypt`/`xteaDecrypt` (`protocol.cpp:365-420`), `stdext::computeChecksum` (adler32), the RSA block layout, and `writePaddingAmount`/`writeHeaderSize` framing (`outputmessage.cpp:151-162`) — a tiny gtest target linking only `framework/net` + `framework/util/crypt` that dumps known-answer vectors to a JSON file your Lua tests then assert against. That gives you framing/crypto coverage, which `.cam` files structurally **cannot** provide (§1.3: the wire framing is stripped before recording).

---

## 7. Version gates relevant to this area, resolved for 1530

From `modules/game_features/features.lua` (ids in `modules/gamelib/const.lua`):

| Feature | id | Gate | 1530 |
|---|---|---|---|
| `GameProtocolChecksum` | 1 | `version >= 840` (`features.lua:45`) | **ON** |
| `GameChallengeOnLogin` | 3 | `version >= 841` (`features.lua:51`) | **ON** |
| `GameLoginPending` | 35 | `version >= 981` (`features.lua:112`) | **ON** |
| `GameMessageSizeCheck` | 61 | `version >= 841` (`features.lua:52`) | **ON** (but shadowed: `onRecv` takes the `>= 1405` branch first) |
| `GameLoginPacketEncryption` | 63 | `version >= 770` (`features.lua:28`) | **ON** |
| `GameSequencedPackets` | 90 | `version >= 1290` (`features.lua:225`) | **ON** |

Raw clientVersion comparisons (not feature-gated):
- `>= 1405`: `m_maxHeaderSize` 7 vs 8 (`inputmessage.cpp:184`, `outputmessage.cpp:29`); header `+1` padding byte vs `+2` XTEA size (`protocol.cpp:202-206`); `remainingSize = size*8 + 4` (`protocol.cpp:222-224`); `writePaddingAmount`/`writeHeaderSize` vs `writeMessageSize` (`protocol.cpp:149-170`); padding-trim decrypt (`protocol.cpp:381-394`); `getXteaEncryptionBuffer` = `getHeaderBuffer()` vs `getDataBuffer()-2` (`outputmessage.cpp:214`); the `m_firstRecv` `getU8()` (`protocolgame.cpp:70-72`).
- `>= 1200`: `Protocol::onConnect` sends `worldName + '\n'` raw and calls `enabledSequencedPackets()` (`protocol.cpp:423-431`) — this is why the recorder's "skip the login packet" heuristic skips the world-name packet instead (§1.5).
- OS id 61 (`CLIENTOS_GUNZ_*` range 60..62) gates `prependCompressionHeader` (`protocol.cpp:141-146`) — invisible in `.cam` files because the recorder runs before it.

⇒ For 1530: `m_checksumEnabled = true`, `m_sequencedPackets = true` (sequence takes priority over checksum in `internalRecvData`, `protocol.cpp:251-253`), `headerSize = 7`, `m_maxHeaderSize = 7`, `m_headerPos = 0`.

## Pseudocode

-- ============================================================================
-- cam.lua : reader for the OTClient .cam packet-recording format
--   line := ("<"|">") SP <decimal ms> SP <lowercase hex payload> ("\r\n"|"\n")
--   "<" = server->client, DECRYPTED / DECOMPRESSED / DEPADDED game payload
--   ">" = client->server, PLAINTEXT payload before compression-hdr/XTEA/checksum
-- ============================================================================
local cam = {}

function cam.read(path)
    local f = assert(io.open(path, 'rb'))
    local recs, n = {}, 0
    for raw in f:read('*a'):gmatch('[^\n]*') do
        local line = raw:gsub('\r$', '')                 -- text-mode ofstream -> CRLF on Windows
        if #line > 0 then
            -- MUST be line-oriented. The C++ PacketPlayer uses `f >> type >> time >> hex`,
            -- which desynchronises forever on a zero-length payload ("< 123 \n").
            local dir, t, hex = line:match('^([<>]) (%d+) ([0-9a-f]*)$')
            if not dir then error(('cam: malformed line %d: %q'):format(n + 1, line)) end
            if #hex % 2 ~= 0 then error(('cam: odd hex length on line %d'):format(n + 1)) end
            n = n + 1
            recs[n] = { dir = dir, t = tonumber(t), data = (hex:gsub('%x%x', function(b)
                return string.char(tonumber(b, 16))
            end)) }
        end
    end
    f:close()
    return recs
end

-- ============================================================================
-- cursor.lua : strict little-endian reader (mirrors InputMessage)
-- ============================================================================
local bit, ffi = require('bit'), require('ffi')
local Cursor = {}; Cursor.__index = Cursor

function Cursor.new(s) return setmetatable({ s = s, pos = 1, n = #s }, Cursor) end
function Cursor:eof()       return self.pos > self.n end
function Cursor:remaining() return self.n - self.pos + 1 end

function Cursor:need(k)
    if self.pos + k - 1 > self.n then
        error({ kind = 'eof', pos = self.pos, want = k, have = self:remaining() }, 0)
    end
end

function Cursor:u8()  self:need(1); local v = self.s:byte(self.pos); self.pos = self.pos + 1; return v end
function Cursor:u16() self:need(2); local a,b = self.s:byte(self.pos, self.pos+1)
                      self.pos = self.pos + 2; return a + b*0x100 end
function Cursor:u32() self:need(4); local a,b,c,d = self.s:byte(self.pos, self.pos+3)
                      self.pos = self.pos + 4; return a + b*0x100 + c*0x10000 + d*0x1000000 end
function Cursor:u64() self:need(8); local v = ffi.cast('uint64_t*', ffi.cast('const char*', self.s) + self.pos - 1)[0]
                      self.pos = self.pos + 8; return v end
function Cursor:i64() self:need(8); local v = ffi.cast('int64_t*',  ffi.cast('const char*', self.s) + self.pos - 1)[0]
                      self.pos = self.pos + 8; return v end
-- InputMessage::getString  = u16 len + bytes           (inputmessage.cpp:247)
function Cursor:str()  local n = self:u16(); self:need(n)
                       local v = self.s:sub(self.pos, self.pos + n - 1); self.pos = self.pos + n; return v end
-- InputMessage::getDouble = u8 precision, (u32 - INT_MAX) / 10^precision  (inputmessage.cpp:256)
function Cursor:double() local p = self:u8(); local v = self:u32() - 2147483647; return v / (10 ^ p) end
function Cursor:skip(k) self:need(k); self.pos = self.pos + k end
function Cursor:peek8() self:need(1); return self.s:byte(self.pos) end

-- ============================================================================
-- runner.lua : the bench
-- ============================================================================
local CLIENT_VERSION = 1530
local MAX_HEADER     = (CLIENT_VERSION >= 1405) and 7 or 8   -- inputmessage.cpp:184

local function parse_record(parser, data, recIndex, trace)
    local cur = Cursor.new(data)

    -- Record #0 of a >=1405 recording is the PLAINTEXT challenge: xteaDecrypt never ran,
    -- so messageSize was never trimmed and the XTEA block padding is still on the tail.
    -- (protocol.cpp:381-394 vs. the m_firstRecv path in protocolgame.cpp:66-73.)
    -- getBodyBuffer() starts AFTER the padding-count byte, so we skip nothing here --
    -- do NOT copy playRecord's extra getU8(), which is off by one for >=1405.
    local allowTrailingZeroPad = (recIndex == 1 and CLIENT_VERSION >= 1405)

    -- mirrors ProtocolGame::parseMessage's `while (!msg->eof())` (protocolgameparse.cpp:54)
    while not cur:eof() do
        if allowTrailingZeroPad and cur:remaining() <= 7 then
            local rest = data:sub(cur.pos)
            if rest:match('^%z*$') then break end          -- pure 0x00 padding: fine
        end
        local start  = cur.pos
        local opcode = cur:u8()
        local h = parser.handlers[opcode]
        if not h then
            error(('rec %d: UNKNOWN opcode 0x%02X at body offset %d (%d unread)')
                  :format(recIndex, opcode, start - 1, cur:remaining()), 0)
        end
        h(cur, parser.state)
        if cur.pos <= start + 1 then
            error(('rec %d: opcode 0x%02X consumed 0 payload bytes'):format(recIndex, opcode), 0)
        end
        -- (recIndex, opcode, bytes) triple to diff against the C++ golden trace
        trace[#trace + 1] = { recIndex, opcode, cur.pos - start - 1 }
    end

    -- THE assertion: an off-by-one anywhere desyncs and lands here.
    if not cur:eof() then
        error(('rec %d: %d bytes left unconsumed'):format(recIndex, cur:remaining()), 0)
    end
end

function run(camPath, parser)
    local recs, trace, i = cam.read(camPath), {}, 0
    for _, r in ipairs(recs) do
        if r.dir == '<' then
            i = i + 1
            local ok, err = pcall(parse_record, parser, r.data, i, trace)
            if not ok then
                error(('%s: inbound record #%d (t=%dms, %d bytes): %s\n  %s')
                      :format(camPath, i, r.t, #r.data, tostring(err), hexdump(r.data)))
            end
        end
    end
    return trace
end

-- ---------------------------------------------------------------------------
-- Mutation tests: a parser that survives these is silently skipping bytes.
-- ---------------------------------------------------------------------------
function mutation_check(parser, data, idx)
    assert(not pcall(parse_record, parser, data:sub(1, #data - 1), idx, {}),
           'truncating 1 byte did not raise')
    assert(not pcall(parse_record, parser, data .. '\0',           idx, {}),
           'appending 1 byte did not raise')
end

-- ---------------------------------------------------------------------------
-- Golden trace from the C++ client (mods/protocol_trace/protocol_trace.lua).
-- ProtocolGame:onOpcode fires AFTER the opcode byte is read and BEFORE the C++
-- switch; readPos is restored when it returns false, so this is non-invasive.
-- (protocolgameparse.cpp:63-71; hook defined at modules/gamelib/protocolgame.lua:7)
-- ---------------------------------------------------------------------------
--   local out, base = {}, ProtocolGame.onOpcode
--   function ProtocolGame:onOpcode(opcode, msg)
--       out[#out+1] = ('%d %d %d'):format(opcode, msg:getReadSize(), msg:getMessageSize())
--       return base(self, opcode, msg)
--   end
--   function dumpTrace() g_resources.writeFileContentsToWorkDir('trace.txt', table.concat(out,'\n')) end
--
-- Derive consumption from that file:
function golden_from_trace(lines)                 -- lines = {opcode, readSize, messageSize}
    local out, rec = {}, 0
    for i, e in ipairs(lines) do
        local nxt = lines[i + 1]
        local consumed
        if nxt and nxt[2] > e[2] then             -- same record
            consumed = nxt[2] - 1 - e[2]
        else                                      -- last opcode of this record
            consumed = e[3] - e[2]
            rec = rec + 1
        end
        if i == 1 then rec = 1 end
        out[#out + 1] = { rec, e[1], consumed }
    end
    return out
end
-- Then: diff(golden_from_trace(cpp), run("x.cam", luaParser))  -- first mismatch = the bug.
-- Drive BOTH from the same .cam: C++ via g_game.playRecord("x.cam"), Lua via run().
-- Skip record #1 in the diff: playRecord's m_firstRecv getU8() is off by one for >=1405.

-- ---------------------------------------------------------------------------
-- Builder round-trip against the '>' records (plaintext, pre-XTEA payloads).
-- Skip index 1: for clientVersion >= 1200 the recorder drops the world-name
-- packet instead of the login packet (packet_recorder.cpp:56-60 vs protocol.cpp:423),
-- so the first recorded '>' is the RSA'd login packet.
-- ---------------------------------------------------------------------------
function builder_roundtrip(recs, builders)
    local k = 0
    for _, r in ipairs(recs) do
        if r.dir == '>' then
            k = k + 1
            if k > 1 then
                local op = r.data:byte(1)
                local b  = builders[op]
                if b then assert(b(r.data) == r.data,
                    ('builder mismatch for client opcode 0x%02X'):format(op)) end
            end
        end
    end
end

## Evidence
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/packet_recorder.cpp:45-52 — addInputPacket writes `"< " << (g_clock.millis()-m_start) << " "` then getBodyBuffer() as 2-char lowercase hex per byte, then `std::dec << "\n"`. This is the whole inbound .cam line grammar.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/packet_recorder.cpp:54-67 — addOutputPacket, same grammar with '>'; `if (m_firstOutput) { m_firstOutput=false; return; }` drops the first outbound packet (comment says "skip packet with login and password").
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/packet_recorder.cpp:30 — `m_start = g_clock.millis()` in the ctor: timestamps are ms relative to Game::loginWorld.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/packet_recorder.cpp:35-38 — output goes to `records/<file>` relative to cwd; directory auto-created; ofstream opened WITHOUT std::ios::binary => text mode => CRLF on Windows.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/packet_recorder.h:37-39 + .cpp:41-43 — empty destructor, std::ofstream member; the file is only flushed when the PacketRecorder (owned by ProtocolGame::m_recorder) is destroyed. Kill the process and the tail is lost.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:327-330 — the recorder is called at the END of internalRecvData, after checksum/sequence, after xteaDecrypt, after zlib inflate: the .cam holds DECRYPTED+DECOMPRESSED payloads.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:122-131 — `Protocol::send` calls `m_recorder->addOutputPacket` as its first statement, before prependCompressionHeader/writePaddingAmount/xteaEncrypt/writeSequence/writeHeaderSize: '>' lines are PLAINTEXT payloads.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.h:47 — `getBodyBuffer() { return std::string((char*)m_buffer + m_maxHeaderSize, m_messageSize - getHeaderSize()); }` — body starts at m_maxHeaderSize (7 for >=1405, 8 otherwise) = first opcode byte.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.cpp:184,191 — `m_maxHeaderSize = g_game.getClientVersion() >= 1405 ? 7 : 8`; for 1530 it is 7.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:199-207 — recv() header sizing: 2 (size) + 4 (checksum) + 1 (padding, >=1405). For 1530 headerSize=7 => m_headerPos=0.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:222-224 — `remainingSize = remainingSize * 8U + 4U` for clientVersion >= 1405: the 1530 wire size field counts 8-byte blocks. None of this framing appears in the .cam.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:251-253 — `if (m_sequencedPackets) decompress = (getU32() & 1<<31);` — sequence takes priority over checksum; bit 31 flags a compressed body.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:381-394 — xteaDecrypt >=1405 branch: reads the u8 padding count and sets messageSize = headerSize + (encryptedSize - paddingSize - 1); this is why recorded bodies are depadded.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:318-325 — on decompression, the inflated bytes are written at getDataBuffer() and messageSize = headerSize + totalSize, so the recorded body is post-inflate.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgame.cpp:61-82 — ProtocolGame::onRecv: `if (m_firstRecv) { if (clientVersion >= 1405) getU8(); else if (GameMessageSizeCheck) { u16 size; ... } }` then parseMessage. The first record needs special handling in any bench.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:487-504 — Protocol::onPlayerPacket: setHeaderSize(0) + fillBuffer(whole record) + setMessageSize(size) + onRecv. Socket-less replay; for >=1405 this makes m_firstRecv's getU8() eat the record's first opcode byte (off-by-one vs. live).
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:506-517 — Protocol::playRecord: sets m_player, starts the PacketPlayer, calls onConnect(). No Connection, no crypto.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/packet_player.cpp:34-60 — the .cam reader: `while (f >> type >> time >> packetHex)`, hex decoded 2 chars at a time via strtol; '<' -> m_input, '>' -> m_output. Token-stream parsing desyncs on an empty payload.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/packet_player.cpp:86-104 — process() replays in REAL TIME using the recorded ms offsets, then fires disconnect(eof) when m_input drains. m_output is never replayed.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/packet_player.cpp:78-84 — onOutputPacket only checks `packet->getBuffer()[0] == 0x14` (logout) to stop playback; all other client sends are silently dropped.
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:597,613-615 — `Game::loginWorld(..., const std::string_view& recordTo)`; `if (!recordTo.empty()) m_protocolGame->setRecorder(std::make_shared<PacketRecorder>(recordTo));` — recorder attached BEFORE login, so the handshake is captured.
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:621-641 — Game::playRecord(file): builds a PacketPlayer, resets game state, creates a dummy LocalPlayer named "Player", world name "Record".
- D:/Claude/otclient_mehah1530/otclient/src/client/luafunctions.cpp:244-245 — bindings `g_game.loginWorld` and `g_game.playRecord`.
- D:/Claude/otclient_mehah1530/otclient/modules/client_entergame/characterlist.lua:427-428 — the 8-arg loginWorld call to edit; append a 9th argument (filename) to start recording. No rebuild needed.
- D:/Claude/otclient_mehah1530/otclient/records/README.md — official recipe: add `os.time() .. '.cam'` as the 9th loginWorld arg; play back with g_game.setClientVersion/setProtocolVersion then g_game.playRecord(file) + EnterGame.hide(). Also documents gesior's server-side tmp-cams-system.
- D:/Claude/otclient_mehah1530/otclient/records/test1098.cam — the only sample: 249,183 bytes, 641 CRLF-terminated lines, 324 '<' + 317 '>', t=3..59950 ms, payloads 1..11,099 bytes (121,444 total), all-lowercase hex. Protocol 1098, NOT 1530.
- D:/Claude/otclient_mehah1530/otclient/records/test1098.cam:1 — `< 3 06001ff3ead46794` decodes as u16 0x0006 (GameMessageSizeCheck) + opcode 0x1F GameServerChallenge + u32 0x67D4EAF3 + u8 0x94: proves '<' bodies start where parseMessage starts.
- D:/Claude/otclient_mehah1530/otclient/records/test1098.cam:3,5 — `> 23 0f` (ClientEnterGame 0x0F) and `> 23 32010200656e` (0x32 extended opcode, sub 0x01, u16 2 + "en"): proves '>' bodies are plaintext pre-encryption payloads.
- D:/Claude/otclient_mehah1530/otclient/records/.gitignore — `*` plus `!.gitignore !README.md !test1098.cam`: new recordings are git-ignored by default.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:724-745 — the ONLY packet.log writer, inside parseMessage's catch: two lines per event, `[EXCEPTION] {unread} unread bytes at pos: {readPos}, protocol: {v}, current: 0x{:02X} ({:d}), prev: ..., error: {what}` + `Bytes: ` uppercase space-separated hex from peekBytes(unread). Opened std::ios::app, closed per event (immediately flushed).
- D:/Claude/otclient_mehah1530/otclient/packet.log — 57,187 bytes, protocol 1530; entries show `prev: 0x-1 (-1)` (int -1 through {:02X}) and an empty `Bytes: ` line when unread==0. These are messages the C++ reference itself mis-parses at 1530 (opcodes 0xE2/0xEE, 0xFC).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:47-71 — parseMessage: `while (!msg->eof()) { opcode = msg->getU8(); ... const int readPos = msg->getReadPos(); if (callLuaField<bool>("onOpcode", opcode, msg)) continue; msg->setReadPos(readPos); switch (opcode) ... }` — the non-invasive Lua instrumentation point (read pos is restored).
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:684-700 — the `default:` branch logs an "Unhandled opcode" warning and does `msg->skipBytes(unreadSize)`; the comment explains that passing getMessageSize() to setReadPos() used to busy-loop. Do NOT copy this survival hack into a test-mode parser.
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/protocolgame.lua:7-15,49-57 — ProtocolGame:onOpcode is plain Lua (returns false when no callback is registered) and ProtocolGame.registerOpcode replaces a C++ handler: both are usable from a mod for tracing / value diffing.
- D:/Claude/otclient_mehah1530/otclient/src/framework/luafunctions.cpp:1065-1084 — InputMessage bindings available to a trace mod: getU8/16/32/64, getString, peek*, getReadSize, getUnreadSize, getMessageSize, eof, skipBytes. NOTE getReadPos is NOT bound; use getReadSize (same origin as getMessageSize per inputmessage.h:80,88).
- D:/Claude/otclient_mehah1530/otclient/src/framework/luafunctions.cpp:269,274,285 — g_resources.writeFileContents / makeDir / writeFileContentsToWorkDir, for dumping a trace file from a mod; resourcemanager.cpp:1223-1233 shows writeFileContentsToWorkDir temporarily switches the write dir to the work dir.
- D:/Claude/otclient_mehah1530/otclient/CMakeLists.txt:29,156-167 — option(OTCLIENT_BUILD_TESTS ... OFF), FATAL_ERROR unless VCPKG_MANIFEST_FEATURES contains 'tests', enable_testing(), add_subdirectory(tests).
- D:/Claude/otclient_mehah1530/otclient/vcpkg.json — `"features": { "tests": { "description": "Dependencies required to build unit tests.", "dependencies": ["gtest"] } }`.
- D:/Claude/otclient_mehah1530/otclient/ — `ls -d tests` => 'No such file or directory'. The tests/ subdirectory does not exist, so configuring with OTCLIENT_BUILD_TESTS=ON fails at add_subdirectory(tests).
- D:/Claude/otclient_mehah1530/otclient/CMakePresets.json — configure presets base/windows-release/windows-release-asan/windows-debug/windows-tests/windows-debug-msbuild/linux-*/macos-*; testPresets windows-tests, windows-release-asan, linux-debug, macos-debug with noTestsAction=error; triplets cmake/triplets/x64-windows-test-{debug,release}.cmake.
- D:/Claude/otclient_mehah1530/otclient/CMakeUserPresets.json — only win-local (inherits windows-release) and win-local-debug (inherits windows-debug); neither enables tests.
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:28,45,51-52,112,225 — 1530 gates: GameLoginPacketEncryption >=770, GameProtocolChecksum >=840, GameChallengeOnLogin + GameMessageSizeCheck >=841, GameLoginPending >=981, GameSequencedPackets >=1290. All ON at 1530.
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/const.lua:100,102,132,158,160,187 — feature ids: GameProtocolChecksum=1, GameChallengeOnLogin=3, GameLoginPending=35, GameMessageSizeCheck=61, GameLoginPacketEncryption=63, GameSequencedPackets=90.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:212-225 — sendLoginPacket: encryptRsa() BEFORE send() (so the recorded login packet's RSA block is encrypted), then enableChecksum / enableXteaEncryption / enabledSequencedPackets AFTER send. This is why the first server message is plaintext.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:422-433 — Protocol::onConnect for clientVersion >= 1200 sends worldName+'\n' via send(msg,true); raw does NOT bypass the recorder, so at 1530 the skipped first output is the world-name packet, not the login packet.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.h:350 + outputmessage.cpp:28-40 — getBuffer() = {m_buffer+m_headerPos, m_messageSize}; m_headerPos==m_maxHeaderSize (7 at >=1405) until a prepend/write runs, so at record time the slice is exactly the caller-written payload.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.cpp:247-261 — getString = u16 length + bytes; getDouble = u8 precision then (u32 - INT_MAX) / 10^precision. Reproduce both exactly in Lua.
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.cpp:292-302 — canRead/checkRead throw stdext::exception("InputMessage eof reached") — the error text seen throughout packet.log.
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:45-76 — GameServerOpcodes enum: no opcode 0, GameServerPing=30, GameServerChallenge=31, GameServerFirstGameOpcode=GameServerExtendedOpcode=50 (0x32). A 0x00 padding byte parsed as an opcode therefore lands in the harmless default: branch.
- D:/Claude/otclient_mehah1530/otclient/src/framework/stdext/types.h:35 — `using ticks_t = int64_t`: .cam timestamps are signed 64-bit milliseconds.

## Pitfalls
- The .cam is written by a TEXT-mode ofstream, so lines end CRLF on Windows and LF on Linux. Strip \r or your hex payload gets a stray byte.
- A zero-length payload produces "< 123 " and permanently desynchronises the C++ PacketPlayer's `f >> type >> time >> hex` token stream (packet_player.cpp:45). Parse .cam line-by-line, and hard-error on a missing third token instead of silently mis-associating.
- Record #0 of a >=1405 recording is NOT depadded: the first server message arrives before XTEA is enabled, so xteaDecrypt never trims messageSize and the recorded body carries up to 7 trailing 0x00 XTEA-block padding bytes. A strict full-consumption assert fails there unless you special-case it.
- g_game.playRecord is OFF BY ONE on >=1405 recordings: onPlayerPacket does setHeaderSize(0) so the body sits at offset 7, then ProtocolGame::onRecv's m_firstRecv branch does getU8() and eats the recorded body's first byte (the opcode) instead of a padding-count byte that getBodyBuffer already excluded. The 1098 path is self-consistent because its GameMessageSizeCheck u16 IS inside the recorded body. Model the LIVE semantics in your bench, and drop record #0 from any C++-vs-Lua trace diff.
- The recorder's "skip the login packet" heuristic misfires at clientVersion >= 1200: Protocol::onConnect sends the world-name packet first, so THAT is what m_firstOutput drops and the login packet IS recorded. Its RSA block is encrypted, but the cleartext prefix (opcode, OS id 61, client/protocol version, revisions) is in the file. Recordings also contain character name, position, inventory and chat -- treat them as semi-sensitive.
- Nothing flushes the .cam except the ofstream destructor, reached only when ProtocolGame is released. Alt-F4 / task-kill / crash loses the buffered tail. Always log out in-game before using a recording.
- One '<' record commonly contains MANY concatenated game messages (the sample's largest is 11,099 bytes). Never assume one opcode per record; loop until the cursor is exhausted.
- The .cam contains NO framing and NO crypto: the u16 size field (size*8+4 at 1530), the u32 sequence/compression flag, the padding-count byte, XTEA and the checksum are all stripped before recording. .cam files can validate your message parser and your packet builder but CANNOT validate your handshake, framing, XTEA or RSA. Those need separate known-answer vectors.
- Do not port the C++ `default:` branch (skipBytes(unreadSize)) into your test-mode parser -- it is a production survival hack that converts an unknown opcode into a silent pass and destroys the full-consumption signal. Unknown opcode must be fatal in tests.
- packet.log is an exception log, not a capture. Its `Bytes:` dumps are only peekBytes(unread) from the failure point -- partial messages that cannot be replayed. Its readPos is an ABSOLUTE buffer offset: subtract m_maxHeaderSize (7 at 1530, 8 at 1098) to get the body offset.
- packet.log prints `0x-1 (-1)` when opcode/prevOpcode are still the -1 sentinel (int formatted with {:02X}). Any log parser must tolerate a non-hex value there.
- The existing packet.log already documents 1530 opcodes (0xE2, 0xEE, 0xFC) that the C++ reference itself fails to parse. Diff against those before assuming a failure is your Lua parser's fault.
- InputMessage::getReadPos is NOT exposed to Lua (only getReadSize/getUnreadSize/getMessageSize are bound). Use getReadSize(), which shares its origin (m_headerPos) with getMessageSize() and eof(), so the two are directly comparable -- but note that origin differs between the live path (m_headerPos=0, body starts at readSize 7) and playRecord (m_headerPos=7, body starts at readSize 0).
- PacketPlayer replays in real time honouring the recorded millisecond offsets, so a 60-second capture takes 60 seconds. It is a debugging aid, not a CI harness -- your own reader is instant.
- tests/ does not exist even though OTCLIENT_BUILD_TESTS, the vcpkg 'tests' feature (gtest), the test triplets and the windows-tests preset all do. Configuring with tests ON fails today at add_subdirectory(tests). The user's win-local / win-local-debug presets do not enable tests.
- InputMessage::getDouble subtracts INT_MAX (2147483647), not 2^31. Off by one if you copy it carelessly into Lua.
- records/.gitignore is `*` with three whitelist exceptions, so any recording you drop there is invisible to git. Keep the test corpus in your own Lua client's repo and copy into otclient/records/ only for GUI replay.
- OutputMessage::prependU8/prependU16 decrement m_writePos as well as m_headerPos (outputmessage.cpp:194-210), which looks wrong but is harmless because send() uses getHeaderBuffer()+getMessageSize(). Do not model it in a Lua builder -- just build the header prefix directly.

## Open questions
- There is no 1530 sample recording in the tree -- only records/test1098.cam. Every 1530-specific claim about the recorded body layout (offset 7 start, padding trimmed except on record #0, playRecord's one-byte overshoot) is derived from reading protocol.cpp / inputmessage.cpp / protocolgame.cpp, not observed. Produce a real 1530 .cam first and verify record #0 against the expectation `1F <u32 timestamp> <u8 random> 00` (7 bytes) before trusting the bench's first-record special case.
- Whether Gunzodus actually sets the sequence bit-31 compression flag on inbound traffic is unverified here. If it does, .cam bodies are post-inflate (protocol.cpp:318-325) and your Lua client must implement raw-deflate inflate plus the COMPRESSION_MODE_PER_PACKET vs COMPRESSION_MODE_STREAM auto-detection -- none of which a .cam can test, because the recording is taken after decompression. Check whether any observed u32 at offset 2..5 has bit 31 set by capturing raw socket bytes.
- The Lua binder's handling of a missing 9th loginWorld argument (game.h:165 declares recordTo with NO default) is inferred from the fact that the shipped 8-arg call works; polymorphicPop presumably yields an empty string for nil. Confirm by passing an explicit '' before relying on a conditional-recording wrapper.
- Whether ProtocolGame::sendLoginPacket runs cleanly during playRecord of a 1530 file (m_accountName/m_password are empty because Game::playRecord never calls ProtocolGame::login) is untested. If encryptRsa or the session-key path asserts on empty input, GUI replay of a 1530 recording may abort at the challenge; the pure-Lua bench is unaffected.
- Whether the first inbound 1530 frame is really unencrypted has not been confirmed on the wire. It follows from GameChallengeOnLogin being enabled (enableXteaEncryption fires only after sendLoginPacket, protocolgamesend.cpp:221), but Gunzodus could deviate. If it does not deviate, record #0 is plaintext and padded as described; if it does, record #0 is already depadded and the special case must be removed.
- No decision made on where the Lua test corpus and runner should live. Recommendation is a standalone LuaJIT runner in the new Lua client's repo rather than a gtest target under the read-only reference tree, but if C++-side known-answer vectors for XTEA/adler32/RSA/framing are wanted, someone must author tests/CMakeLists.txt from scratch (the directory does not exist).
- How much opcode coverage a realistic recording session yields is unknown. The 1098 sample touches only 15 distinct inbound opcodes, 189 of 324 records being a single opcode (0x6D). Expect to need a scripted tour across several focused recordings to reach useful coverage of 1530's market/store/wheel/bosstiary/cyclopedia messages.

## VERIFIER (confidence 0.88)

### Corrections (AUTHORITATIVE — these override the spec above)
- **Claim**: §5.3 assertion ladder item 2: "Progress. Every handler consumes ≥ 1 byte; a handler that consumes 0 is an infinite loop waiting to happen." — implemented in the pseudocode as `if cur.pos <= start + 1 then error('opcode 0x%02X consumed 0 payload bytes') end`.
  - **Correction**: FALSE, and it will fire on 67 records of the only shipped corpus file. Many game opcodes have an empty payload. The loop can never spin regardless, because `cur:u8()` for the opcode itself always advances one byte — that is the progress guarantee. DELETE the zero-consumption check entirely; keep only the unknown-opcode and eof checks.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1417-1418 — `void ProtocolGame::parsePing(const InputMessagePtr&) { g_game.processPing(); }` / `void ProtocolGame::parsePingBack(const InputMessagePtr&) { g_game.processPingBack(); }` — the InputMessage parameter is unnamed and never read. protocolcodes.h:62-63 `GameServerPingBack = 29, GameServerPing = 30` (0x1D/0x1E); protocolcodes.h:125 `GameServerCloseNpcTrade = 124` (0x7C, also zero-payload). Measured over records/test1098.cam: single-byte inbound records = 0x1E ×58, 0x1D ×8, 0x7C ×1 = 67 records that the spec's own runner would reject.
- **Claim**: §5.3 item 4 + the runner pseudocode: for record #1 of a ≥1405 recording, `if allowTrailingZeroPad and cur:remaining() <= 7 then ... if rest:match('^%z*$') then break end end`, followed at the end of `parse_record` by `if not cur:eof() then error('%d bytes left unconsumed') end`.
  - **Correction**: These two are mutually exclusive: the `break` is the only way to leave the loop with `cur.pos <= n`, so every time the record-#0 padding exemption actually triggers, the very next statement raises "bytes left unconsumed". Record #0 of a 1530 capture can therefore never pass. The padding exemption must set a flag (or advance `cur.pos` to `n+1`) before breaking, e.g. `cur.pos = cur.n + 1; break`.
  - Evidence: Control flow of the supplied `parse_record`; `Cursor:eof()` is `self.pos > self.n`, so after `break` at `remaining() == 1..7` the guard `if not cur:eof()` is true. Confirmed the exemption is reachable: for 1530 the challenge body is 6 payload bytes inside one 8-byte block, so getBodyBuffer() returns 7 bytes = 6 payload + 1 filler (protocol.cpp:222-223 `remainingSize = remainingSize * 8U + 4U`; inputmessage.h:47 getBodyBuffer).
- **Claim**: §5.4 pseudocode `golden_from_trace`: `if nxt and nxt[2] > e[2] then consumed = nxt[2]-1-e[2] else consumed = e[3]-e[2]; rec = rec+1 end; if i==1 then rec=1 end; out[#out+1] = {rec, e[1], consumed}`.
  - **Correction**: `rec` is incremented BEFORE the entry is appended, so the LAST opcode of every record is tagged with the NEXT record's index. Trace: record 1 op1 → rec=1 (ok); record 1 op_last → else branch sets rec=2, appends {2,...} (wrong, should be 1); record 2 op1 → appends {2,...} (correct by accident); record 2 op_last → rec=3. Every record boundary in the diff is shifted, so the (recordIndex, opcode, bytesConsumed) triples will not line up with the Lua runner's. Fix: append first, then `rec = rec + 1`. The per-opcode byte arithmetic (`nxt[2] - 1 - e[2]`, and `e[3] - e[2]` for the last) is correct.
  - Evidence: Derived from the supplied code. The underlying byte arithmetic is validated by inputmessage.h:78 `int getReadSize() { return m_readPos - m_headerPos; }`, inputmessage.h:81 `uint16_t getMessageSize() { return m_messageSize; }` and inputmessage.h:88 `bool eof() { return (m_readPos - m_headerPos) >= m_messageSize; }` — same origin, so `getMessageSize() - readSize_last` is the last opcode's consumption in both the live (headerPos 0, messageSize 7+body) and playRecord (headerPos 7, messageSize = body) paths.
- **Claim**: §5.3 item 7(a) / `mutation_check`: "For each record: (a) truncate by 1 byte ⇒ the parser MUST raise", asserted unconditionally with `assert(not pcall(parse_record, parser, data:sub(1, #data-1), idx, {}), 'truncating 1 byte did not raise')`.
  - **Correction**: Falsifiable on any record whose final opcode has an empty payload. Truncating the 1-byte record `1E` yields the empty string; `Cursor.new('')` reports `eof()` immediately, the while-loop body never runs, and `parse_record` returns cleanly — so the assert itself fires spuriously on 67 records of test1098.cam. Gate mutation (a) on `#data > 1 and the record's last opcode having a non-empty payload`, or simply skip records whose last handler consumed 0 bytes. Mutation (b) (`append '\0'`) is safe: there is no GameServerOpcode with value 0, so 0x00 is always an unknown opcode.
  - Evidence: Same zero-payload opcodes as above (protocolgameparse.cpp:1417-1418). For mutation (b): src/client/protocolcodes.h:44-47 — `enum GameServerOpcodes : uint8_t { GameServerSessionCreatureData = 3, ... }`; the enumeration starts at 3, so 0/1/2 are unassigned.
- **Claim**: §0 and §1.5: "`Protocol::send` calls the recorder as its *first* statement".
  - **Correction**: It is the second statement. The first is the playback guard `if (m_player) { m_player->onOutputPacket(outputMessage); return; }`, which returns before the recorder ever runs. Consequence worth stating in the spec: under `g_game.playRecord` nothing is recorded at all, so you cannot re-record a replay to normalise a corpus. (The spec states this fact in §3 but the §0/§1.5 wording contradicts it.)
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:122-131 — `void Protocol::send(const OutputMessagePtr& outputMessage, bool raw) { if (m_player) { m_player->onOutputPacket(outputMessage); return; } if (m_recorder) { m_recorder->addOutputPacket(outputMessage); }`
- **Claim**: §1.3 / §5.2 / §7 cite `inputmessage.cpp:184,191` (m_maxHeaderSize), `inputmessage.cpp:247-254` (getString), `inputmessage.cpp:256-261` (getDouble), `inputmessage.cpp:298-302` (checkRead).
  - **Correction**: src/framework/net/inputmessage.cpp is only 152 lines; none of those citations exist. Correct locations: m_maxHeaderSize at inputmessage.cpp:29 (ctor) and :36 (reset); getString at :92-99; getDouble at :101-106; checkRead at :143-147 with canRead at :137-142. The *semantics* the spec states for each are correct.
  - Evidence: `wc -l src/framework/net/inputmessage.cpp` → 152. inputmessage.cpp:29 `m_maxHeaderSize = g_game.getClientVersion() >= 1405 ? 7 : 8;`; :36 same inside `reset()`; :92-99 `std::string InputMessage::getString() { const uint16_t stringLength = getU16(); checkRead(stringLength); ... }`; :101-106 `double InputMessage::getDouble() { const uint8_t precision = getU8(); const int32_t v = getU32() - INT_MAX; return (v / std::pow(10.f, precision)); }`; :139 `if ((m_readPos - m_headerPos + bytes > m_messageSize) || (m_readPos + bytes > BUFFER_MAXSIZE))`.
- **Claim**: §1.5: "`OutputMessage::getBuffer()` = `{ m_buffer + m_headerPos, m_messageSize }` (`outputmessage.h:350`)".
  - **Correction**: Correct content, wrong line — src/framework/net/outputmessage.h is 89 lines and getBuffer is at line 43.
  - Evidence: D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.h:43 — `std::string_view getBuffer() { return std::string_view{ (char*)m_buffer + m_headerPos, m_messageSize }; }`. `wc -l` → 89.
- **Claim**: §1.4/§5.2/§5.4/§1.7 cite `protocolgameparse.cpp:697` (skipBytes), `:684-700` (default branch), `:63-71` (onOpcode hook), `:47-56` (parse loop).
  - **Correction**: Off by a few lines each. Correct: `msg->skipBytes(static_cast<uint16_t>(unreadSize));` is at :698; the `default:` branch spans :680-700; the non-invasive hook is :66-70 (`const int readPos = msg->getReadPos();` at 66, `callLuaField<bool>("onOpcode", opcode, msg)` at 67, `msg->setReadPos(readPos);` at 70); the loop header is :53-54. The `packet.log` writer citation `:727` and the `g_logger.error` citation `:714-726` are exact.
  - Evidence: protocolgameparse.cpp:53 `while (!msg->eof()) {`; :54 `opcode = msg->getU8();`; :66-70 the readPos save/restore; :698 the skipBytes; :727 `std::ofstream packet("packet.log", std::ios::app);`.
- **Claim**: §1.5: "the pre-RSA prefix (opcode, OS id 61, client/protocol version, sprite/content revision, preview flag) **is** cleartext in the file."
  - **Correction**: The order is misstated and one field is version-gated in a way that matters at 1530. The actual cleartext prefix at clientVersion 1530 is: u8 `Proto::ClientPendingGame` (=10, 0x0A) · u16 OS · u16 **protocol** version · u32 **client** version (feature GameClientVersion) · **string** `std::to_string(clientVersion)` (clientVersion >= 1281) · **string** asset identifier / gunz content revision (clientVersion >= 1334 — this REPLACES the u16 content-revision field, which is only reached in the `else if` for < 1334) · u8 0 (feature GamePreviewState). Protocol version precedes client version; there is no u16 "sprite/content revision" at 1530.
  - Evidence: src/client/protocolgamesend.cpp:126-149 — `msg->addU8(Proto::ClientPendingGame); msg->addU16(g_game.getOs()); msg->addU16(g_game.getProtocolVersion()); if (g_game.getFeature(Otc::GameClientVersion)) msg->addU32(g_game.getClientVersion()); if (g_game.getClientVersion() >= 1281) { msg->addString(std::to_string(g_game.getClientVersion())); } if (g_game.getClientVersion() >= 1334) { ... msg->addString(g_things.getAssetIdentifier()); } else if (g_game.getFeature(Otc::GameContentRevision)) { msg->addU16(g_things.getContentRevision()); } if (g_game.getFeature(Otc::GamePreviewState)) msg->addU8(0);`. protocolcodes.h:260 `ClientPendingGame = 10`. OS id 61 is right: src/client/const.h:38-40 `CLIENTOS_GUNZ_LINUX = 60, CLIENTOS_GUNZ_WINDOWS = 61, CLIENTOS_GUNZ_MAC = 62`.
- **Claim**: §1.7 gotcha 2 / §5.2 L0: the reader "should hard-error on a record with a missing third token rather than silently mis-parse", implemented as `line:match('^([<>]) (%d+) ([0-9a-f]*)$')`.
  - **Correction**: The pattern does NOT hard-error on a zero-payload record; it silently accepts it. A zero-length body is written as `"< 123 "` (trailing space, empty hex) and `[0-9a-f]*` matches the empty string, so `dir/t/hex` all capture and `data == ''`. `parse_record` then loops zero times and passes. If you want the stated behaviour, use `([0-9a-f]+)$` and raise on the failure, or check `#hex == 0` explicitly. (The C++ desync gotcha itself is correctly described: packet_player.cpp:45 `while (f >> type >> time >> packetHex)` is a whitespace-token stream.)
  - Evidence: Lua pattern semantics for `*`; packet_recorder.cpp:47 `m_stream << "< " << (g_clock.millis() - m_start) << " ";` unconditionally emits the trailing space before the (possibly empty) hex loop; packet_player.cpp:45.
- **Claim**: §3 and the builder pseudocode: `PacketPlayer::onOutputPacket`'s `buffer[0] == 0x14` is described as `ClientLogout`.
  - **Correction**: The value 0x14 is right, the identifier is not — there is no `ClientLogout` in the tree. The opcode is `Proto::ClientLeaveGame = 20`, sent by `ProtocolGame::sendLogout()`. Anyone grepping the spec's name in a reimplementation will find nothing.
  - Evidence: src/client/protocolcodes.h:262 `ClientLeaveGame = 20,`; src/client/protocolgamesend.cpp:251-256 `void ProtocolGame::sendLogout() { const auto& msg = std::make_shared<OutputMessage>(); msg->addU8(Proto::ClientLeaveGame); send(msg); }`; packet_player.cpp:80 `if (packet->getBuffer()[0] == 0x14) { // logout`. `grep -n Logout src/client/protocolcodes.h` returns only `GameServerVipLogout = 212`.
- **Claim**: §5.3 item 4: "allow **≤ 7 trailing bytes that are all `0x00`** (XTEA block padding) — assert they are zeros rather than blanket-skipping."
  - **Correction**: The count bound (≤7) is provable; the *value* is not. Nothing in the reference tree constrains the SERVER's filler byte — the ≥1405 decrypt only reads the count and discards the filler, and `ProtocolGame::onRecv`'s first-record branch discards the count byte too. The client's own filler happens to default to 0, which makes 0x00 plausible but is not evidence about the server. Assert the count (`remaining() <= 7`) and log the filler bytes on the first capture; do not hard-fail on a non-zero filler until you have observed one 1530 recording. Mark this "unverified" in the spec rather than leaving it as a hard assertion.
  - Evidence: protocol.cpp:381-385 — `const uint8_t paddingSize = inputMessage->getU8(); inputMessage->setPaddingSize(paddingSize); decryptedSize = encryptedSize - paddingSize - 1; inputMessage->setMessageSize(inputMessage->getHeaderSize() + decryptedSize);` — filler bytes are never inspected. Bound ≤7 follows from the block size: outputmessage.cpp:151-156 `const uint8_t paddingAmount = 8 - (m_messageSize % 8) - 1;` ranges 0..7. Filler default: outputmessage.h:51 `void addPaddingBytes(int bytes, uint8_t byte = 0);` — client side only.
- **Claim**: §5.6: "Run with plain LuaJIT: `luajit tests/protocol/runner.lua tests/protocol/corpus/*.cam`", with the runner hardcoding `CLIENT_VERSION = 1530`.
  - **Correction**: The bench as specified cannot run against the only corpus that exists today. `test1098.cam` is a <1405 recording whose record #0 body BEGINS with the `GameMessageSizeCheck` u16 (`06 00`) that `ProtocolGame::onRecv` consumes before `parseMessage`; the 1530-only runner would read `0x06` as an opcode. The runner needs a per-file version (encoded in the filename, per §1.7 gotcha 7) and a <1405 first-record branch: read u16, assert it equals `remaining()`, then parse. Also `MAX_HEADER` is computed in the runner and never used, `hexdump` is referenced in `run` but never defined, and `builder_roundtrip` calls `b(r.data)` — passing the recorded bytes to a builder that should take semantic arguments.
  - Evidence: src/client/protocolgame.cpp:66-78 — `if (m_firstRecv) { m_firstRecv = false; if (g_game.getClientVersion() >= 1405) { inputMessage->getU8(); } else if (g_game.getFeature(Otc::GameMessageSizeCheck)) { const int size = inputMessage->getU16(); if (size != inputMessage->getUnreadSize()) { ... return; } } }`. records/test1098.cam line 1 = `< 3 06001ff3ead46794`. records/ contains only .gitignore, README.md and test1098.cam.
- **Claim**: §5.3 item 8 / `builder_roundtrip`: "Skip index 1 ... for 1530 the first *recorded* `>` is the RSA'd login packet."
  - **Correction**: Correct for clientVersion ≥ 1200 only, and the pseudocode applies `if k > 1` unconditionally. For a <1200 capture the recorder's first-output heuristic drops the LOGIN packet (as intended), so the first recorded `>` is a perfectly good plaintext vector and skipping it loses coverage — in test1098.cam that is line 3, `> 23 0f` (ClientEnterGame). Make the skip conditional on the capture's client version.
  - Evidence: protocol.cpp:422-431 — the world-name raw send exists only `if (g_game.getClientVersion() >= 1200)`; packet_recorder.cpp:56-60 `if (m_firstOutput) { // skip packet with login and password  m_firstOutput = false; return; }`. records/test1098.cam line 3 decodes to a single byte 0x0F = `ClientEnterGame` (protocolcodes.h:261).
- **Claim**: §5.2: "`getDouble` is `u8 precision` + `(u32 - INT_MAX) / 10^precision` ... note `INT_MAX` = 2147483647, not 2^31", implemented in Lua as `local p = self:u8(); local v = self:u32() - 2147483647; return v / (10 ^ p)`.
  - **Correction**: The INT_MAX note is right, but two details of the reference are lost. (a) The subtraction is done in uint32_t and then narrowed to `int32_t`, so at `u32 == 0xFFFFFFFF` C++ yields -2147483648 while the Lua double yields +2147483648. (b) The divisor is `std::pow(10.f, precision)` — a *float* pow, and the whole expression is float-typed before the double return, so the reference value carries only ~7 significant digits. A value-level diff (§5.5) against `Creature::speedA/B/C` will show mismatches in the low digits unless you round to float precision on the Lua side.
  - Evidence: src/framework/net/inputmessage.cpp:101-106 — `double InputMessage::getDouble() { const uint8_t precision = getU8(); const int32_t v = getU32() - INT_MAX; return (v / std::pow(10.f, precision)); }`. Consumers: protocolgameparse.cpp:750-752 `Creature::speedA = msg->getDouble(); Creature::speedB = msg->getDouble(); Creature::speedC = msg->getDouble();`.

### Additions
- SIGN-EXTENSION BUG IN THE REFERENCE i64 READER — affects §5.2's `Cursor:i64` and any §5.5 value diff. `stdext::readSLE32` ORs a sign-extended int16 low half into the result, so any value whose low 16 bits have bit 15 set is corrupted, and `readSLE64` inherits it. D:/Claude/otclient_mehah1530/otclient/src/framework/stdext/math.h:45-47 — `inline int16_t readSLE16(const uint8_t* addr) { return static_cast<int16_t>(addr[1]) << 8 | addr[0]; }` / `inline int32_t readSLE32(const uint8_t* addr) { return static_cast<int32_t>(readSLE16(addr + 2)) << 16 | readSLE16(addr); }` / `inline int64_t readSLE64(const uint8_t* addr) { return static_cast<int64_t>(readSLE32(addr + 4)) << 32 | readSLE32(addr); }`. Bytes `00 80 01 00` decode to -32768 instead of 98304. Width is unaffected (8 bytes are still consumed) so there is NO desync risk, and the only caller discards the values (protocolgameparse.cpp:5334-5335 `msg->get64(); // raw exp` / `msg->get64(); // final exp`). But a *correct* Lua i64 will disagree with the C++ reference — do not treat that as your bug. `readULE16/32/64` (math.h:37-39) are correct little-endian, matching the spec.
- THE 8-ARG `loginWorld` CALL IS A GUARANTEED BINDER CONTRACT, NOT MERELY OBSERVED (§4.1 hedges unnecessarily). The binder pads the Lua stack with nils to the C++ arity before popping: src/framework/luaengine/luabinder.h:145-152 — `while (lua->stackSize() != N) { if (lua->stackSize() < N) g_lua.pushNil(); else g_lua.pop(); }`. `std::string_view` parameters are routed specially: luainterface.h:518-526 — `if constexpr (std::is_same_v<T, std::string_view>) { o = g_lua.toVString(index); }`, and luainterface.cpp:1349-1354 — `const char* value = lua_tostring(L, index); return value != nullptr ? value : ""sv;`. nil yields `""`, so `!recordTo.empty()` is false and no recorder is attached. One caveat the spec should carry: luainterface.cpp:1351 is `assert(hasIndex(index));`, a no-op in Release but live in a Debug build.
- FRAMING KNOWN-ANSWER VECTORS FOR THE §6 gtest SLOT — the exact formulas, since .cam files structurally cannot cover them. Outbound size field: outputmessage.cpp:158-162 `auto headerSize = static_cast<uint16_t>((m_messageSize - 4) / 8); // -4 for checksum  prependU16(headerSize);` — the exact inverse of the inbound `remainingSize = remainingSize * 8U + 4U` (protocol.cpp:222-223), which confirms the spec's §7 entry. Outbound padding: outputmessage.cpp:151-156 `const uint8_t paddingAmount = 8 - (m_messageSize % 8) - 1; addPaddingBytes(paddingAmount); prependU8(paddingAmount);` — note this yields 7 (not 0) when m_messageSize is already a multiple of 8. Checksum: stdext/math.cpp:39-44 `return ::adler32(::adler32(0L, Z_NULL, 0), ...)` — adler32 as the spec says, computed over `{ m_buffer + m_headerPos, m_messageSize }` BEFORE the 4 bytes are accounted (outputmessage.cpp:125-133). XTEA region differs by version: outputmessage.cpp:212-215 `return g_game.getClientVersion() >= 1405 ? getHeaderBuffer() : getDataBuffer() - 2;`.
- SEQUENCED PACKETS ARE ENABLED BY CLIENT VERSION, NOT BY THE FEATURE FLAG — the §7 table attributes it to `GameSequencedPackets` (≥1290). `Protocol::onConnect` enables it on a raw `clientVersion >= 1200` test with no feature check: protocol.cpp:422-431 `if (g_game.getClientVersion() >= 1200) { ... send(msg, true); enabledSequencedPackets(); }`. `sendLoginPacket` redundantly re-enables it under the feature gate (protocolgamesend.cpp:223-224). Both are true at 1530 so the spec's conclusion holds, but a reimplementation targeting 1200-1289 would get this wrong from the table alone. Same shape for checksum: protocolgame.cpp:52-53 `if (g_game.getFeature(Otc::GameProtocolChecksum)) enableChecksum();` runs in onConnect BEFORE `recv()` at :58, which is what makes headerSize 7 (not 3) for record #0.
- LUA BINDING SET FOR THE §5.4 TRACE MOD — the spec's claim that `getReadPos` is not bound is CORRECT (it exists at inputmessage.h:79 but has no binding). The complete InputMessage binding list is src/framework/luafunctions.cpp:1066-1084: create, setBuffer, getBuffer, skipBytes, getU8/U16/U32/U64, getString, peekU8/U16/U32/U64, decryptRsa, getReadSize, getUnreadSize, getMessageSize, eof. Note `setReadPos`, `peekBytes`, `get64` and `getDouble` are ALSO unbound — so a Lua-side value-level decoder (§5.5 `registerOpcode`) cannot read a signed 64-bit or a double field, which limits which opcodes you can fully decode in Lua on the C++ side. `g_resources.writeFileContentsToWorkDir` at luafunctions.cpp:285 is confirmed present.
- packet.log GROUND TRUTH (§2): the current file holds exactly THREE `[EXCEPTION]` entries, all protocol 1530 — two identical `current: 0xE2 (226), prev: 0xEE (238)` with `0 unread bytes at pos: 30` and an empty `Bytes: ` line, and one `current: 0xFC (252), prev: 0x-1 (-1)` with `18925 unread bytes at pos: 443`. The 57,187-byte file size is almost entirely that third entry's hex dump. So the "bug oracle" corpus is much thinner than the byte count suggests: two distinct failing opcodes (0xE2 and 0xFC), not a broad survey. `prev: 0x-1 (-1)` confirms the spec's warning that `{:02X}` on an int -1 prints literally.
- `Game::playRecord` sets `m_worldName = "Record"` at game.cpp:642, i.e. AFTER `m_protocolGame->playRecord(...)` at :640 — so the world-name packet built inside `Protocol::onConnect` during replay carries whatever world name was left from a previous session (usually empty), not "Record". Harmless because `PacketPlayer::onOutputPacket` swallows everything except a first byte of 0x14 (packet_player.cpp:78-84), but worth knowing if you ever instrument that path.
