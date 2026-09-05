# Transport framing and packet crypto (protocol 1530 / Gunzodus, OS 61)

# Transport framing & packet crypto — protocol 1530 (Gunzodus / mehah "OTClient Redemption" fork)

All paths below are relative to `D:/Claude/otclient_mehah1530/otclient`.

**IMPORTANT: this fork is NOT vanilla OTClient on the wire.** At `clientVersion >= 1405` the framing changes completely: the u16 size field counts **8-byte blocks**, not bytes; the "decrypted size u16" is replaced by a **1-byte padding count**; and for OS 60..62 every XTEA-encrypted body carries an extra 4-byte compression header. Do not port a stock OTClient/TFS transport layer.

---

## 0. Effective configuration for 1530

`Game::setClientVersion` (`src/client/game.cpp:1727-1743`) does nothing but `m_features.reset()` + `g_lua.callGlobalField("g_game","onClientVersionChange", version)`. All feature bits therefore come from `modules/game_features/features.lua`.

Flags relevant to transport, and their value at 1530:

| Flag | Value @1530 | Set at |
|---|---|---|
| `GameLoginPacketEncryption` | **ON** (>=770) | features.lua:28 |
| `GameProtocolChecksum` | **ON** (>=840) | features.lua:45 |
| `GameChallengeOnLogin` | **ON** (>=841) | features.lua:51 |
| `GameMessageSizeCheck` | ON (>=841) — **dead at >=1405** | features.lua:52 |
| `GameClientVersion` | **ON** (>=980) | features.lua:108 |
| `GamePreviewState` | **ON** (>=980) | features.lua:107 |
| `GameContentRevision` | ON (>=1071) — **superseded by the >=1334 branch** | features.lua:165 |
| `GameAuthenticator` | ON (>=1072) — unused (session-key branch wins) | features.lua:169 |
| `GameSessionKey` | **ON** (>=1074) | features.lua:173 |
| `GameSequencedPackets` | **ON** (>=1290) | features.lua:225 |
| RSA key | **`GUNZODUS_RSA`**, e=65537 | features.lua:304 |
| OS id | **61** (`CLIENTOS_GUNZ_WINDOWS`) | features.lua:305, const.h:39 |

`Otc::CLIENTOS_GUNZ_LINUX = 60`, `CLIENTOS_GUNZ_WINDOWS = 61`, `CLIENTOS_GUNZ_MAC = 62` (`src/client/const.h:38-40`). "isGunzOs" throughout means `60 <= os <= 62`, i.e. **true** for us.

There is **no `MAX_HEADER_SIZE` constant**. The header reservation is the per-message field `m_maxHeaderSize`:

```cpp
m_maxHeaderSize = g_game.getClientVersion() >= 1405 ? 7 : 8;   // outputmessage.cpp:29,36 ; inputmessage.cpp:29,36
```

So **for 1530: `maxHeaderSize = 7`** = 2 (size) + 4 (sequence/checksum) + 1 (padding count).
Buffers: `OutputMessage::BUFFER_MAXSIZE = 65536`, `MAX_STRING_LENGTH = 65536` (outputmessage.h:34-35); `InputMessage::BUFFER_MAXSIZE = 65536` (inputmessage.h:37). `Connection::RECV_BUFFER_SIZE = SEND_BUFFER_SIZE = 65536`, `READ_TIMEOUT = WRITE_TIMEOUT = 30` s (connection.h:36-39).

---

## 1. Outgoing message layout

### 1.1 Who enables what, and when

* `Protocol::onConnect()` (`protocol.cpp:422-433`): for `clientVersion >= 1200` it **first sends the world name raw** and then calls `enabledSequencedPackets()`.

```cpp
if (g_game.getClientVersion() >= 1200) {
    std::string sendWorldName(g_game.getWorldName());
    sendWorldName += '\n';
    const auto& msg = std::make_shared<OutputMessage>();
    msg->addBytes(std::string_view(sendWorldName));
    send(msg, true);              // raw == true: no size, no seq, no padding, no xtea
    enabledSequencedPackets();
}
callLuaField("onConnect");
```

  → **The very first bytes the client writes to the socket are the plain ASCII world name followed by `'\n'`, with no framing whatsoever.** (`m_worldName` is set in `Game::loginWorld`, game.cpp:618, before the async connect completes.)

* `ProtocolGame::onConnect()` (`protocolgame.cpp:45-59`): sets `m_firstRecv = true`, calls `Protocol::onConnect()`, then `if (getFeature(GameProtocolChecksum)) enableChecksum();` then (only if `!GameChallengeOnLogin`) `sendLoginPacket(0,0)`, then `recv()`.
  At 1530 `GameChallengeOnLogin` is ON, so **the login packet is not sent until the server's challenge (0x1F) arrives**.

* `ProtocolGame::sendLoginPacket()` (`protocolgamesend.cpp:215-224`): `enableChecksum()` again *before* `send(msg)`, then **after** the send: `enableXteaEncryption()` and `enabledSequencedPackets()`.

Net effect for 1530: **sequenced packets are ON from the moment of connect; checksum is ON from connect too but is never actually emitted** (see §2.2); XTEA turns on immediately after the login packet leaves.

### 1.2 `Protocol::send()` order of operations (protocol.cpp:122-188)

```cpp
if (!raw) {
    // 1. compression header  (only when xtea already enabled AND os in [60,62])
    if (m_xteaEncryptionEnabled) {
        const auto os = static_cast<uint16_t>(g_game.getOs());
        if (os >= Otc::CLIENTOS_GUNZ_LINUX && os <= Otc::CLIENTOS_GUNZ_MAC)
            outputMessage->prependCompressionHeader(m_outboundCompressionMode);  // mode == 0 always
    }
    // 2. padding
    if (g_game.getClientVersion() >= 1405) outputMessage->writePaddingAmount();
    // 3. encrypt
    if (m_xteaEncryptionEnabled) xteaEncrypt(outputMessage);
    // 4. sequence OR checksum  (mutually exclusive, sequence wins)
    if (m_sequencedPackets)      outputMessage->writeSequence(m_packetNumber++);
    else if (m_checksumEnabled)  outputMessage->writeChecksum();
    // 5. size
    if (g_game.getClientVersion() >= 1405) outputMessage->writeHeaderSize();
    else                                   outputMessage->writeMessageSize();
}
m_connection->write(outputMessage->getHeaderBuffer(), outputMessage->getMessageSize());
```

Note steps 1 and 2 run **inside** the region that step 3 encrypts. `m_outboundCompressionMode` is hard-coded `0` (protocol.h:125, with a long comment proving the gunzotc expression can never evaluate to anything else).

### 1.3 Buffer arithmetic

`OutputMessage` grows forward from `m_writePos` (init `= m_maxHeaderSize = 7`) and prepends backward by decrementing `m_headerPos` (init `= 7`). `m_messageSize` always equals the length of the live region `[m_headerPos, m_headerPos + m_messageSize)`.

* `prependCompressionHeader(mode)` (outputmessage.cpp:164-181) does **not** prepend backward — there is no header room left at maxHeaderSize 7. It `memmove`s the body 4 bytes forward and writes `[mode][0][0][0]` at `m_headerPos`:

```cpp
checkWrite(4);
uint8_t* const data = m_buffer + m_headerPos;
memmove(data + 4, data, m_messageSize);
data[0] = mode; data[1] = data[2] = data[3] = 0;
m_writePos += 4; m_messageSize += 4;
```

* `writePaddingAmount()` (outputmessage.cpp:151-156):

```cpp
const uint8_t paddingAmount = 8 - (m_messageSize % 8) - 1;
addPaddingBytes(paddingAmount);   // zero bytes appended at the end
prependU8(paddingAmount);         // count byte prepended in front
```
  Result: `newSize = M + (8 - M%8 - 1) + 1 = M + 8 - M%8`, i.e. **always a multiple of 8, and always at least 1 byte is added** (when `M%8==0` the amount is 7 → +8). `addPaddingBytes` fills with `0x00` (default arg `uint8_t byte = 0`, outputmessage.h:51).
  Quirk: `prependU8`/`prependU16` also decrement `m_writePos` (outputmessage.cpp:194-210). Harmless here because nothing appends afterwards (the message is already 8-aligned so `xteaEncrypt` adds nothing).

* `xteaEncrypt` (protocol.cpp:399-420) at >=1405 does **not** call `writeMessageSize()` and encrypts `getXteaEncryptionBuffer()` == `getHeaderBuffer()` == `m_buffer + m_headerPos` for `m_messageSize` bytes (already a multiple of 8).
  (Legacy <1405: `writeMessageSize()` first, then pad to 8, buffer = `getDataBuffer() - 2` = `m_buffer + maxHeaderSize - 2`.)

* `writeSequence(seq)` (outputmessage.cpp:135-141): `m_headerPos -= 4; writeULE32(m_buffer+m_headerPos, seq); m_messageSize += 4;`
* `writeHeaderSize()` (outputmessage.cpp:158-162):

```cpp
auto headerSize = static_cast<uint16_t>((m_messageSize - 4) / 8);  // -4 for checksum
prependU16(headerSize);   // headerPos -= 2, messageSize += 2
```

  **The u16 size field is a BLOCK COUNT, not a byte count.** It excludes both itself and the 4-byte sequence/checksum dword, and it counts the encrypted region in units of 8 bytes.

`m_headerPos` lands on exactly 0 (7 − 1 − 4 − 2), so the wire image is `m_buffer[0 .. m_messageSize)`.

### 1.4 Byte-level layout — encrypted outgoing packet (steady state, 1530)

```
wire offset
 0  u16  blocks          = (4 + 8*blocks - 4)/8   little-endian
 2  u32  sequence        little-endian, plaintext, NOT encrypted
 6  ...  XTEA ciphertext, exactly 8*blocks bytes
```
plaintext under XTEA (starts at wire offset 6):
```
 +0  u8   paddingAmount     (= 8 - (M % 8) - 1, where M = 4 + bodyLen)
 +1  u8   compressionMode   = 0x00
 +2  u8   0x00
 +3  u8   0x00
 +4  u8   0x00
 +5  ...  opcode + body     (bodyLen bytes)
 +5+bodyLen .. : paddingAmount zero bytes
```
total plaintext length = `1 + 4 + bodyLen + paddingAmount` = multiple of 8 = `8*blocks`.
Total wire length = `2 + 4 + 8*blocks`.

### 1.5 Byte-level layout — the login packet (XTEA not yet enabled)

Identical minus the compression header and minus encryption:
```
 0  u16 blocks   = (4 + 8*blocks - 4)/8
 2  u32 sequence = 0        (m_packetNumber starts at 0; the raw world-name send does not consume one)
 6  u8  paddingAmount       (= 8 - (M % 8) - 1, M = bodyLen)
 7  ... 0x0A + login body (see §4.4), cleartext
 ... paddingAmount zero bytes
```

### 1.6 Max sizes

* `canWrite`: `m_writePos + bytes <= 65536` (outputmessage.cpp:183-186).
* `m_messageSize` is `uint16_t` → hard ceiling 65535 wire bytes; the block count field caps at 8191 blocks = 65528 encrypted bytes.
* Incoming ceiling: `remainingSize == 0 || remainingSize > 0xFFFF` → rejected (protocol.cpp:226-230).

---

## 2. Checksum and sequence

### 2.1 Adler-32 (`stdext::computeChecksum`, `src/framework/stdext/math.cpp:39-44`)

```cpp
uint32_t computeChecksum(std::span<const uint8_t> data) noexcept {
    const uInt n = static_cast<uInt>(data.size());
    return ::adler32(::adler32(0L, Z_NULL, 0), reinterpret_cast<const Bytef*>(data.data()), n);
}
```
`adler32(0, Z_NULL, 0)` returns 1, so this is plain RFC-1950 Adler-32: `A = 1; B = 0; for each byte: A = (A + b) % 65521; B = (B + A) % 65521; result = (B << 16) | A`. Written little-endian by `writeULE32`.

**Bytes covered, outgoing** (`OutputMessage::writeChecksum`, outputmessage.cpp:125-133): `{ m_buffer + m_headerPos, m_messageSize }` **at the moment of the call** — i.e. after padding and after XTEA encryption, everything that will follow the checksum dword, excluding the u16 size field.

**Bytes covered, incoming** (`InputMessage::readChecksum`, inputmessage.cpp:129-135): reads the u32 at the current read position (wire offset 2), then checksums `getUnreadSize()` bytes starting at the new read position — i.e. wire offset 6 to end of message.

### 2.2 Sequence numbers

* Field: `uint32_t m_packetNumber{0}` (protocol.h:92), post-incremented on every non-raw `send()` (protocol.cpp:160). **Starts at 0, +1 per sent framed packet.** The raw world-name write does not increment it, so the login packet carries sequence 0.
* Checksum and sequence are **mutually exclusive** (`if (m_sequencedPackets) ... else if (m_checksumEnabled) ...`). At 1530 both flags are true, so **the client never emits an Adler-32 checksum on the game connection** — the dword at offset 2 is always the sequence number.
* `enableChecksum()` still matters: it is what makes `Protocol::recv()` reserve 4 header bytes for that dword (protocol.cpp:200-201). Without it the receive header would be 3 bytes and framing breaks.
* **Incoming sequence is NOT validated.** `internalRecvData` (protocol.cpp:251-252) reads the dword only to test bit 31:

```cpp
if (m_sequencedPackets) {
    decompress = (m_inputMessage->getU32() & 1 << 31);
} else if (m_checksumEnabled && !m_inputMessage->readChecksum()) { ...reject... }
```
  The low 31 bits are discarded. A Lua client can therefore ignore inbound sequence values entirely — but it MUST consume the 4 bytes and MUST test bit 31.

---

## 3. XTEA

### 3.1 Key

`std::array<uint32_t, 4> m_xteaKey` (protocol.h:91). Generated in `Protocol::generateXteaKey()` (protocol.cpp:333-338):

```cpp
std::random_device rd;
std::uniform_int_distribution<uint32_t> unif;
std::ranges::generate(m_xteaKey, [&unif,&rd]{ return unif(rd); });
```
Four uniformly random `uint32_t` from `std::random_device` (OS CSPRNG). Any cryptographic RNG works in Lua.

Written into the RSA block with `addU32` × 4, i.e. **little-endian**, in index order 0,1,2,3 (protocolgamesend.cpp:158-161).

### 3.2 Round function (protocol.cpp:340-420)

`constexpr uint32_t delta = 0x9E3779B9;` `apply_rounds` splits each 8-byte block into two **little-endian** u32s `left = data[j+0] | data[j+1]<<8 | data[j+2]<<16 | data[j+3]<<24`, `right` from `data[j+4..7]`, and writes them back little-endian.

Encrypt (`xteaEncrypt`, 32 rounds, `sum` starts at 0):
```cpp
for (uint32_t i=0, sum=0, next_sum=sum+delta; i<32; ++i, sum=next_sum, next_sum+=delta) {
    left  += ((right << 4 ^ right >> 5) + right) ^ (sum      + m_xteaKey[sum & 3]);
    right += ((left  << 4 ^ left  >> 5) + left ) ^ (next_sum + m_xteaKey[(next_sum >> 11) & 3]);
}
```
Decrypt (`xteaDecrypt`, `sum` starts at `delta << 5` = **0xC6EF3720**):
```cpp
for (uint32_t i=0, sum=delta<<5, next_sum=sum-delta; i<32; ++i, sum=next_sum, next_sum-=delta) {
    right -= ((left  << 4 ^ left  >> 5) + left ) ^ (sum      + m_xteaKey[(sum >> 11) & 3]);
    left  -= ((right << 4 ^ right >> 5) + right) ^ (next_sum + m_xteaKey[next_sum & 3]);
}
```
This is textbook XTEA/32 in **ECB** mode. (The outer loop applies one round across *all* blocks before advancing `sum`; blocks are independent so it is equivalent to running 32 rounds per block.) All shifts are logical on `uint32_t`; `>>5` is a logical shift.

### 3.3 Padding

**At >=1405 the padding is applied *before* encryption by `writePaddingAmount()` (§1.3), with `0x00` filler, and a 1-byte count is prepended.** `xteaEncrypt`'s own top-up (`if ((encryptedSize % 8) != 0) addPaddingBytes(n)`) is dead code at 1530 because the message is already 8-aligned.

### 3.4 Where the size lives inside the encrypted payload

**There is no "decrypted size u16" at 1530.** `xteaDecrypt` (protocol.cpp:380-394):

```cpp
uint16_t decryptedSize;
if (g_game.getClientVersion() >= 1405) {
    const uint8_t paddingSize = inputMessage->getU8();
    inputMessage->setPaddingSize(paddingSize);
    decryptedSize = encryptedSize - paddingSize - 1;
    inputMessage->setMessageSize(inputMessage->getHeaderSize() + decryptedSize);
} else {
    decryptedSize = inputMessage->getU16() + 2;      // legacy path
    ...
}
```
So the **first plaintext byte of the encrypted region is a padding count**, and the payload length is `encryptedSize - paddingCount - 1`. Legacy (<1405) clients put a u16 "decrypted size" there instead; do not implement that for 1530.

### 3.5 Byte-level layout — incoming encrypted packet

```
 0  u16 blocks               (little-endian)     ; body length = blocks*8 + 4
 2  u32 seqOrFlags           bit31 = "this packet is zlib-compressed"; other bits ignored
 6  ... XTEA ciphertext, blocks*8 bytes
```
after decrypting `[6, 6+blocks*8)`:
```
 6  u8  paddingCount
 7  ... payload, (blocks*8 - paddingCount - 1) bytes   <- opcode stream starts here
 ... paddingCount trailing bytes (ignored)
```

---

## 4. RSA

### 4.1 Key material

`Crypt::rsaSetPublicKey(n, e)` parses both as **decimal strings** (`BN_dec2bn`, crypt.cpp:188-199; GMP build: `mpz_set_str(..., 10)`).
`g_game.setRsa(rsa, e)` defaults `e = '65537'` (`modules/gamelib/game.lua:44-48`).

`Crypt::rsaGetSize()` = `RSA_size(m_rsa)` = **128 bytes (1024 bits)** (crypt.cpp:289-297).

Encryption (crypt.cpp:235-260):
```cpp
return RSA_public_encrypt(size, msg, msg, m_rsa, RSA_NO_PADDING) != -1;
```
**`RSA_NO_PADDING`** — raw textbook `c = m^e mod n`, input exactly 128 bytes interpreted **big-endian**, output exactly 128 bytes big-endian, left-zero-padded. (`rsaDecrypt` is the mirror with `d`; only used by `InputMessage::decryptRsa`, which the game protocol never calls at 1530.)

`OutputMessage::encryptRsa()` (outputmessage.cpp:115-123) encrypts **the last 128 bytes written**: `m_buffer + m_writePos - 128`.

### 4.2 Which key for 1530

`modules/game_features/features.lua:295-306`:
```lua
if version >= 1530 then
    g_game.setRsa(GUNZODUS_RSA)
    g_game.setCustomOs(61)
end
```
`g_game.chooseRsa(host)` (`modules/gamelib/game.lua:19-22`) early-returns unless the current key is `CIPSOFT_RSA` or `OTSERV_RSA`, so the later `chooseRsa` calls from `modules/client_entergame/entergame.lua:1247,1465` are no-ops and cannot clobber either the key or the OS.

**Full modulus (`GUNZODUS_RSA`, `modules/gamelib/const.lua:329-333`), decimal, 309 digits, 1024-bit:**

```
124627388324231447675617769701366117842696721548962156708623895647474174346300521696190833934580287020164278359414195549510925428212676699226328012721269908075137544578076908574898562097520735449263292165722384481748538646580304452734750003927519095249000286367283230450217221784214070032637657596780069118601
```
Hex (for convenience, not present in the source):
`0xb179acbd3cb90486f85f2602c23327bf2a636d8e0c31969cb55a0fd661df6ef9c9e6d738ba46b5631f8cdaa94b19b504e2383ef7825b84e4bb3334dca2458e1c71c01997256d9b6819ff50018e400a8f2d45badcc1fb1f8e5ab270a78c6d83f4fb39434efd5da3dfe42af3ee47504ab8d0d8a7f866cd78f1c3fca106df49e289`

Exponent: **65537**.

### 4.3 Login packet: unencrypted prefix

`ProtocolGame::sendLoginPacket(challengeTimestamp, challengeRandom)` (protocolgamesend.cpp:115-225), with `isGunzOs = true`:

```
u8   0x0A                       ClientPendingGame  (protocolcodes.h:260)
u16  61                         g_game.getOs()
u16  1530                       g_game.getProtocolVersion()
u32  1530                       GameClientVersion  (ON)
str  "1530"                     clientVersion >= 1281  (u16 len + bytes)
str  "<contentRevision>"        clientVersion >= 1334 && isGunzOs: decimal text of the u32 parsed
                                from "assets/assets.json.sha256" or
                                "things/1530/assets.json.sha256"; 0 if unresolved (→ "0")
u8   0x00                       GamePreviewState (ON)
```
`const int offset = msg->getMessageSize();` is taken here — everything after this point up to +128 bytes is the RSA block.

### 4.4 RSA block contents, in order (exactly 128 bytes before encryption)

```
u8   0x00                       "first RSA byte must be 0"
u32  xteaKey[0]  (LE)           generateXteaKey() called here
u32  xteaKey[1]  (LE)
u32  xteaKey[2]  (LE)
u32  xteaKey[3]  (LE)
u8   0x00                       "is gm set?"
str  sessionKey                 GameSessionKey ON  -> session-key branch
str  characterName
u32  challengeTimestamp         GameChallengeOnLogin ON
u8   challengeRandom
u16  0x0002                     isGunzOs only (protocolgamesend.cpp:191-192); meaning UNVERIFIED
str  extendedData               "261" when empty and isGunzOs && clientVersion >= 1281
                                (protocolgamesend.cpp:198-204)
pad  0x00 * (128 - bytesSoFar)  addPaddingBytes(paddingBytes) -> ZERO filler
```
Then `msg->encryptRsa()` transforms those 128 bytes in place.

Note the account-name/password branch (`GameAccountNames`, `msg->addString(m_accountPassword)`, `GameAuthenticator`) is **not** taken at 1530 because `GameSessionKey` is enabled.
Note `ProtocolLogin` (`modules/gamelib/protocollogin.lua`) pads its RSA blocks with **random** bytes instead (`math.random(0,0xff)`, lines 90-92, 124-126) — irrelevant if you use HTTPS login, which 1530 does.

---

## 5. Compression

**Yes, but inbound only, and it is opt-in per packet by the server.**

* `Protocol` owns a raw-deflate zlib stream: `inflateInit2(&m_zstream, -15)` in the ctor (protocol.cpp:41), `inflateEnd` in the dtor. `-15` = **raw DEFLATE, no zlib/gzip header**.
* **Trigger:** bit 31 of the inbound sequence dword (protocol.cpp:252). There is no feature flag; `CompressionMode_t` (protocol.h:28-33) is a runtime-learned mode, not a version gate.
* **Ordering:** the flag is read from the *plaintext* dword at offset 2; **XTEA decryption happens first**, then decompression operates on the decrypted payload (protocol.cpp:265-325).
* **Mode autodetection** (protocol.cpp:278-316):
  1. While mode is `UNKNOWN` or `PER_PACKET`: `inflate(Z_FINISH)` over `getDataBuffer()` (= `m_buffer + 7`) for `getUnreadSize()` bytes into a 64 KiB scratch. If it returns `Z_STREAM_END` and produced >0 bytes → mode := `PER_PACKET`, `inflateReset`.
  2. Else, if mode was `UNKNOWN` → `inflateReset`, mode := `STREAM`, fall through.
  3. In `STREAM` mode: append the 4-byte sync footer `00 00 FF FF` to the buffer if not already present (`InputMessage::addCompressionFooter`, inputmessage.h:106-125), then `inflate(Z_SYNC_FLUSH)`; accept `Z_OK` or `Z_STREAM_END`. **The stream context is NOT reset between packets** in this mode.
  4. `fillBuffer(zbuffer, totalSize)` then `setMessageSize(getHeaderSize() + totalSize)`; the decompressed bytes replace the payload starting at `m_buffer + m_readPos` (which is `m_buffer + 7`).
* **Outbound:** no deflate anywhere. The 4-byte `[mode][0][0][0]` header (`prependCompressionHeader`) only *declares* a mode, and `m_outboundCompressionMode` is permanently `0` (protocol.h:113-125). The client never compresses what it sends. **But the 4 bytes must still be emitted** — protocol.cpp:135-140 warns that omitting them shifts every gameplay packet by 4 bytes and the server silently drops them.
* No LZMA, no other compression, anywhere in the net path (grep of `src/framework/net`, `src/client/protocolgame*.cpp` finds zlib only in protocol.cpp and in `protocolhttp.h` for HTTP bodies).

---

## 6. Incoming read loop

### 6.1 Framing (`Protocol::recv` / `internalRecvHeader` / `internalRecvData`)

`Protocol::recv()` (protocol.cpp:190-215):
```cpp
m_inputMessage->reset();
int headerSize = 2;                                        // size field
if (m_checksumEnabled)                headerSize += 4;     // checksum OR sequence dword
if (g_game.getClientVersion() >= 1405) headerSize += 1;    // padding-size byte
else if (m_xteaEncryptionEnabled)      headerSize += 2;    // legacy decrypted-size u16
m_inputMessage->setHeaderSize(headerSize);                 // -> headerPos = readPos = 7 - 7 = 0
m_connection->read(2, internalRecvHeader);
```
At 1530 `headerSize == 7 == maxHeaderSize`, so `m_headerPos = 0`.

`internalRecvHeader` (protocol.cpp:217-238):
```cpp
m_inputMessage->fillBuffer(buffer, size);          // 2 bytes at offset 0
uint32_t remainingSize = m_inputMessage->readSize();   // getU16(), readPos -> 2
if (g_game.getClientVersion() >= 1405)
    remainingSize = remainingSize * 8U + 4U;       // <<< blocks -> bytes, +4 for the seq dword
if (remainingSize == 0 || remainingSize > 0xFFFF) { g_logger.error("invalid packet size = {}"); return; }
m_connection->read(remainingSize, internalRecvData);
```

**So: exactly two socket reads per message — 2 bytes, then `blocks*8 + 4` bytes.** `Connection::read` uses `asio::async_read`, i.e. it blocks until *exactly* that many bytes have arrived (`connection.cpp:191-209`), with a 30-second read timer. Your Lua client must do the same: read 2, decode, read `n*8+4`.

Note the fatal-looking non-recovery: on an invalid size the function simply `return`s **without re-arming a read**, so the connection goes silent. Don't copy that.

`internalRecvData` (protocol.cpp:240-331):
1. bail if not connected.
2. `fillBuffer(buffer, size)` at offset 2 → `m_messageSize = 2 + remainingSize`.
3. sequence/checksum branch (§2.2).
4. `if (m_xteaEncryptionEnabled) if (!xteaDecrypt(...)) { traceError("failed to decrypt message"); return; }`
5. optional decompress (§5).
6. `onRecv(m_inputMessage)`.

Sizes after step 4: `encryptedSize = getUnreadSize() = messageSize - (readPos - headerPos) = (2 + blocks*8 + 4) - 6 = blocks*8`; rejected if not a multiple of 8 (`"invalid encrypted network message"`).

### 6.2 Checksum mismatch

Only reachable when `m_sequencedPackets` is false (never at 1530). Behaviour (protocol.cpp:253-263): log
`"got a network message with invalid checksum, header: <hex of the first headerSize buffer bytes>, size: <messageSize>"` and **`return` — the packet is dropped and, critically, `recv()` is not re-armed**, so the connection stalls. There is no disconnect and no retry.

### 6.3 Are the first packets unencrypted?

**Yes.** XTEA is enabled only *after* the login packet is sent (`protocolgamesend.cpp:220-221`), so everything the server sends before that — the challenge `0x1F`, and any login error / `GameServerLoginError (20)`, `GameServerLoginAdvice`, `GameServerLoginWait`, `GameServerUpdateNeeded` sent in its place — arrives **unencrypted**, but still framed with the u16 block count + u32 sequence dword + padding byte.

`ProtocolGame::onRecv` (protocolgame.cpp:61-82) handles the padding byte for that first message, because `xteaDecrypt` (which normally eats it) did not run:
```cpp
if (m_firstRecv) {
    m_firstRecv = false;
    if (g_game.getClientVersion() >= 1405) {
        inputMessage->getU8();          // padding
    } else if (g_game.getFeature(Otc::GameMessageSizeCheck)) { ...legacy u16 size check... }
}
parseMessage(inputMessage);
recv();
```
Consequence to replicate or work around: **`m_messageSize` is not shrunk for that first message**, so the trailing zero padding stays in the buffer and `parseMessage`'s `while (!msg->eof())` loop sees a bogus opcode `0x00` after the real content. In this client that lands in the `default:` arm (protocolgameparse.cpp) which logs "Unhandled opcode 0x00" and `skipBytes(unreadSize)`, ending the loop harmlessly. A from-scratch client should instead trim `paddingCount` bytes off the end of the first message.

Challenge payload (`parseLoginChallenge`, protocolgameparse.cpp:1420-1430):
```
u8  0x1F   (GameServerChallenge = 31, protocolcodes.h:64)
u32 timestamp
u8  random
u8  <skipped>    // clientVersion >= 1405 only
```
→ then `sendLoginPacket(timestamp, random)`.

### 6.4 Full handshake sequence for a from-scratch Lua client

1. HTTPS login (out of scope here) → session key, character name, world name, world host/port.
2. TCP connect (set `TCP_NODELAY`, connection.cpp:276-278).
3. **Write `worldName .. "\n"` raw, unframed.** Enable "sequenced" mode locally.
4. Read frame → challenge `0x1F` (unencrypted; skip its leading padding byte).
5. Build and send the login packet (unencrypted body, but WITH the padding byte, sequence 0, and block-count size). Generate the XTEA key while building it; RSA-encrypt the last 128 bytes.
6. Turn XTEA on. From here every outgoing packet gets the `[0][0][0][0]` compression header, the padding byte, XTEA, sequence (starting at 1), block count; every incoming packet is XTEA-decrypted and possibly raw-inflated.


## Pseudocode

-- =====================================================================
-- transport.lua  — byte-exact port of otclient_mehah1530 framing/crypto
-- protocol/client version 1530, OS 61 (Gunzodus). LuaJIT + bit + ffi.
-- =====================================================================
local bit = require('bit')
local band, bor, bxor, lsh, rsh = bit.band, bit.bor, bit.bxor, bit.lshift, bit.rshift
local tobit, tohex = bit.tobit, bit.tohex

local CLIENT_VERSION   = 1530
local PROTOCOL_VERSION = 1530
local OS_ID            = 61          -- CLIENTOS_GUNZ_WINDOWS
local MAX_HEADER       = 7           -- clientVersion >= 1405 ? 7 : 8
local DELTA            = 0x9E3779B9
local RSA_SIZE         = 128         -- bytes (1024-bit modulus)
local RSA_N_DEC = "124627388324231447675617769701366117842696721548962156708623895647474174346300521696190833934580287020164278359414195549510925428212676699226328012721269908075137544578076908574898562097520735449263292165722384481748538646580304452734750003927519095249000286367283230450217221784214070032637657596780069118601"
local RSA_E     = 65537

-- ---------------------------------------------------------------- adler32
-- stdext::computeChecksum  == RFC1950 adler32 seeded with adler32(0,NULL,0)==1
local function adler32(buf, off, len)          -- buf: byte string, 1-based off
  local A, B = 1, 0
  for i = off, off + len - 1 do
    A = (A + buf:byte(i)) % 65521
    B = (B + A) % 65521
  end
  return bor(lsh(B, 16), A) % 0x100000000
end

-- ------------------------------------------------------------------ XTEA
-- key = {k0,k1,k2,k3} as u32.  ECB, 32 rounds, little-endian words.
local function u32(x) return band(x, 0xFFFFFFFF) end
local function add32(a,b) return (a + b) % 0x100000000 end
local function sub32(a,b) return (a - b) % 0x100000000 end

local function xtea_encrypt_block(k, L, R)
  local sum = 0
  for _ = 1, 32 do
    local nsum = add32(sum, DELTA)
    L = add32(L, bxor(add32(bxor(lsh(R,4), rsh(R,5)), R), add32(sum,  k[band(sum,3)+1])))
    R = add32(R, bxor(add32(bxor(lsh(L,4), rsh(L,5)), L), add32(nsum, k[band(rsh(nsum,11),3)+1])))
    sum = nsum
  end
  return L, R
end

local function xtea_decrypt_block(k, L, R)
  local sum = u32(DELTA * 32)                    -- delta << 5 == 0xC6EF3720
  for _ = 1, 32 do
    local nsum = sub32(sum, DELTA)
    R = sub32(R, bxor(add32(bxor(lsh(L,4), rsh(L,5)), L), add32(sum,  k[band(rsh(sum,11),3)+1])))
    L = sub32(L, bxor(add32(bxor(lsh(R,4), rsh(R,5)), R), add32(nsum, k[band(nsum,3)+1])))
    sum = nsum
  end
  return L, R
end
-- apply over every 8-byte block of a mutable byte buffer, LE word order:
--   L = b[0] | b[1]<<8 | b[2]<<16 | b[3]<<24 ; R = b[4..7]

-- ============================================================== OUTGOING
-- Protocol::send(msg, raw=false) for clientVersion 1530, OS 61.
--   state: xteaOn, seqOn(true from connect), checksumOn(true, never used),
--          packetNumber (starts 0), xteaKey
function Transport:send(body)          -- body = opcode..payload, no framing
  local out = body

  -- 1) compression header  [mode=0][0][0][0]   (only once XTEA is on, OS 60..62)
  if self.xteaOn then
    out = "\0\0\0\0" .. out
  end

  -- 2) padding (clientVersion >= 1405, ALWAYS, encrypted or not)
  local M   = #out
  local pad = 8 - (M % 8) - 1                 -- 0..7 ; when M%8==0 -> 7
  out = string.char(pad) .. out .. string.rep("\0", pad)
  assert(#out % 8 == 0)

  -- 3) XTEA (ECB, in place, over the whole padded region)
  if self.xteaOn then out = xtea_encrypt(self.xteaKey, out) end

  -- 4) sequence  (wins over checksum; checksum branch is dead at 1530)
  local head4
  if self.seqOn then
    head4 = le_u32(self.packetNumber); self.packetNumber = self.packetNumber + 1
  else -- legacy only
    head4 = le_u32(adler32(out, 1, #out))
  end

  -- 5) size == BLOCK COUNT, excludes itself and the dword
  local blocks = (#out + 4 - 4) / 8            -- == #out / 8
  local frame  = le_u16(blocks) .. head4 .. out
  self.sock:send(frame)
end

-- Raw send (world name at connect): no header at all.
function Transport:sendRaw(bytes) self.sock:send(bytes) end

-- ============================================================== INCOMING
function Transport:recvMessage()
  -- exactly two reads, like asio::async_read
  local hdr    = self.sock:receive(2)
  local blocks = le_u16_read(hdr, 1)
  local remaining = blocks * 8 + 4             -- clientVersion >= 1405
  if remaining == 0 or remaining > 0xFFFF then error("invalid packet size") end
  local body = self.sock:receive(remaining)    -- [u32 seq/flags][blocks*8 bytes]

  local seq        = le_u32_read(body, 1)
  local decompress = band(rsh(seq, 31), 1) == 1   -- ONLY bit31 is used; seq NOT validated
  local enc        = body:sub(5)                  -- blocks*8 bytes

  local payload
  if self.xteaOn then
    if #enc % 8 ~= 0 then error("invalid encrypted network message") end
    local dec  = xtea_decrypt(self.xteaKey, enc)
    local padc = dec:byte(1)
    payload = dec:sub(2, 1 + (#enc - padc - 1))   -- decryptedSize = enc - pad - 1
  else
    -- first (pre-XTEA) message: ProtocolGame::onRecv skips one padding byte.
    -- The C++ does NOT trim the tail; we do, to avoid a bogus opcode 0x00.
    local padc = enc:byte(1)
    payload = enc:sub(2, #enc - padc)
  end

  if decompress then
    -- raw DEFLATE (inflateInit2 windowBits = -15), on the DECRYPTED payload.
    -- mode autodetect, sticky per connection:
    --   try inflate(Z_FINISH) -> if Z_STREAM_END and out>0 : PER_PACKET (reset each packet)
    --   else                                               : STREAM
    -- STREAM: append "\0\0\255\255" if not already the last 4 bytes, then
    --         inflate(Z_SYNC_FLUSH) on a stream that is NEVER reset.
    payload = self:inflatePayload(payload)
  end
  return payload
end

-- ========================================================== LOGIN PACKET
function Transport:sendLoginPacket(challengeTimestamp, challengeRandom)
  local m = OutMsg()
  m:u8(0x0A)                                   -- ClientPendingGame
  m:u16(OS_ID)                                 -- 61
  m:u16(PROTOCOL_VERSION)                      -- 1530
  m:u32(CLIENT_VERSION)                        -- GameClientVersion
  m:str(tostring(CLIENT_VERSION))              -- >= 1281
  m:str(tostring(self.contentRevision or 0))   -- >= 1334 && isGunzOs
  m:u8(0)                                      -- GamePreviewState

  local offset = m:size()                      -- RSA block starts here
  m:u8(0)                                      -- first RSA byte must be 0
  self.xteaKey = { rand32(), rand32(), rand32(), rand32() }
  m:u32(self.xteaKey[1]); m:u32(self.xteaKey[2])
  m:u32(self.xteaKey[3]); m:u32(self.xteaKey[4])
  m:u8(0)                                      -- is gm set?
  m:str(self.sessionKey)                       -- GameSessionKey branch
  m:str(self.characterName)
  m:u32(challengeTimestamp)                    -- GameChallengeOnLogin
  m:u8(challengeRandom)
  m:u16(2)                                     -- isGunzOs marker (meaning UNVERIFIED)
  m:str(self.extendedData ~= "" and self.extendedData or "261")
  m:zeros(RSA_SIZE - (m:size() - offset))      -- ZERO padding to exactly 128

  local block = m:take(RSA_SIZE)               -- last 128 bytes
  m:put(rsa_raw_encrypt(block, RSA_N_DEC, RSA_E))  -- c = m^e mod n, NO PADDING, big-endian

  self:send(m:bytes())                         -- xteaOn is still false here -> seq 0, no comp hdr
  self.xteaOn = true                           -- enable AFTER the send
end

-- ============================================================ HANDSHAKE
function Transport:connect(host, port, worldName)
  self.sock:connect(host, port); self.sock:setoption('tcp-nodelay', true)
  self.packetNumber, self.seqOn, self.xteaOn = 0, true, false
  self:sendRaw(worldName .. "\n")              -- Protocol::onConnect, clientVersion >= 1200
  -- GameChallengeOnLogin is ON at 1530 -> do NOT send the login packet yet.
  local first = self:recvMessage()             -- unencrypted: 0x1F challenge (or a login error)
  -- 0x1F: u32 timestamp, u8 random, u8 skipped (>= 1405)
  local ts, rnd = parseChallenge(first)
  self:sendLoginPacket(ts, rnd)                -- sequence 0
end


## Evidence
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:122-188 — Protocol::send: exact order compression-header -> writePaddingAmount -> xteaEncrypt -> writeSequence/writeChecksum -> writeHeaderSize; sequence wins over checksum (else-if)
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:141-146 — compression header gated on `m_xteaEncryptionEnabled && os in [CLIENTOS_GUNZ_LINUX(60), CLIENTOS_GUNZ_MAC(62)]`, no clientVersion term
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:149-151,166-170 — `clientVersion >= 1405` selects writePaddingAmount + writeHeaderSize instead of writeMessageSize
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:190-215 — recv(): headerSize = 2 + (checksum?4) + (cv>=1405 ? 1 : (xtea?2)); first socket read is exactly 2 bytes
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:217-238 — internalRecvHeader: `remainingSize = readSize() * 8U + 4U` at cv>=1405; reject if 0 or > 0xFFFF; second read of exactly remainingSize bytes
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:250-263 — inbound: sequenced branch reads u32 and uses ONLY bit 31 as a decompress flag; checksum branch only runs when !m_sequencedPackets; mismatch logs and returns without re-arming recv
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:274-325 — inbound zlib: raw-deflate (inflateInit2 -15, line 41), autodetect PER_PACKET via Z_FINISH else STREAM via Z_SYNC_FLUSH with the 00 00 FF FF footer; no reset in STREAM mode
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:333-338 — generateXteaKey(): 4 x uniform uint32 from std::random_device
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:342 — `constexpr uint32_t delta = 0x9E3779B9`
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:344-362 — apply_rounds: little-endian u32 pack/unpack of each 8-byte block
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:365-397 — xteaDecrypt: sum starts at delta<<5 (0xC6EF3720); at cv>=1405 the FIRST decrypted byte is a padding count, decryptedSize = encryptedSize - paddingSize - 1 (the legacy u16 decrypted-size is the <1405 branch)
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:399-420 — xteaEncrypt: no writeMessageSize at >=1405, buffer = getXteaEncryptionBuffer(), sum starts at 0, 32 rounds
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:422-433 — Protocol::onConnect sends `worldName + '\n'` with send(msg, raw=true) then enabledSequencedPackets() for clientVersion >= 1200
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.h:91-92 — `std::array<uint32_t,4> m_xteaKey`, `uint32_t m_packetNumber{0}`
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.h:112-125 — CompressionMode_t state and `m_outboundCompressionMode{0}` with the proof it can never be non-zero
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:28-40 — m_maxHeaderSize = (clientVersion >= 1405) ? 7 : 8; writePos = headerPos = maxHeaderSize
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:115-123 — encryptRsa encrypts the LAST rsaGetSize() bytes: `m_buffer + m_writePos - size`
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:125-133 — writeChecksum: adler32 over {m_buffer + m_headerPos, m_messageSize} at call time, i.e. post-XTEA, pre-size-field
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:151-156 — writePaddingAmount: `paddingAmount = 8 - (m_messageSize % 8) - 1`, zero filler appended, count prepended
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:158-162 — writeHeaderSize: `(m_messageSize - 4) / 8` — the u16 size field is a BLOCK COUNT excluding itself and the dword
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:164-181 — prependCompressionHeader memmoves the body forward 4 bytes and writes [mode][0][0][0] at m_headerPos (no backward room at maxHeaderSize 7)
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:194-210 — prependU8/prependU16 also decrement m_writePos (quirk; harmless because the message is already 8-aligned)
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:212-215 — getXteaEncryptionBuffer(): >=1405 -> getHeaderBuffer(); legacy -> getDataBuffer()-2
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.h:34-35,84-88 — BUFFER_MAXSIZE 65536, MAX_STRING_LENGTH 65536, m_maxHeaderSize/m_headerPos/m_writePos/m_messageSize fields
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.cpp:28-40 — InputMessage m_maxHeaderSize = (cv>=1405) ? 7 : 8
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.cpp:122-135 — setHeaderSize sets headerPos = maxHeaderSize - size (0 for 1530); readChecksum reads the u32 then adler32s the remaining unread bytes
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.h:37,106-125,149-154 — BUFFER_MAXSIZE 65536; addCompressionFooter appends 00 00 FF FF unless already present
- D:/Claude/otclient_mehah1530/otclient/src/framework/stdext/math.cpp:39-44 — computeChecksum = zlib adler32 seeded with adler32(0,Z_NULL,0)
- D:/Claude/otclient_mehah1530/otclient/src/framework/stdext/math.h:37-43 — readULE16/32/64 and writeULE16/32/64: everything on the wire is little-endian
- D:/Claude/otclient_mehah1530/otclient/src/framework/util/crypt.cpp:188-199 — rsaSetPublicKey parses n and e as DECIMAL strings (BN_dec2bn / mpz_set_str base 10)
- D:/Claude/otclient_mehah1530/otclient/src/framework/util/crypt.cpp:235-260 — rsaEncrypt: `RSA_public_encrypt(size, msg, msg, m_rsa, RSA_NO_PADDING)`; GMP path is c = m^e mod n with big-endian import/export
- D:/Claude/otclient_mehah1530/otclient/src/framework/util/crypt.cpp:289-297 — rsaGetSize() = RSA_size = 128 bytes for the 1024-bit modulus
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/connection.cpp:191-209 — Connection::read uses asio::async_read (exact-length read) with a 30 s read timer
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/connection.cpp:273-286 — TCP_NODELAY set on connect
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/connection.h:36-39 — READ_TIMEOUT/WRITE_TIMEOUT 30, SEND/RECV_BUFFER_SIZE 65536
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgame.cpp:45-59 — onConnect: m_firstRecv=true, Protocol::onConnect(), enableChecksum() if GameProtocolChecksum, sendLoginPacket only if !GameChallengeOnLogin, then recv()
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgame.cpp:61-82 — onRecv: on the FIRST message at cv>=1405 it skips one padding byte (message size is NOT trimmed)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:115-225 — sendLoginPacket: full field order, isGunzOs u16(2) marker at :191-192, "261" extended-data fallback at :198-204, zero RSA padding at :207-209, enableXteaEncryption/enabledSequencedPackets AFTER send at :220-224
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:65-98 — resolveGunzContentRevision(): decimal u32 from assets/assets.json.sha256 or things/<cv>/assets.json.sha256, 1..0xFFFF, else 0
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1420-1430 — parseLoginChallenge: u32 timestamp, u8 random, skip 1 byte at cv>=1405, then sendLoginPacket
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:47-71 — parseMessage loops `while (!msg->eof())` reading a u8 opcode; default arm skips the remaining bytes (this is what swallows the untrimmed first-message padding)
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:38-40 — CLIENTOS_GUNZ_LINUX=60, CLIENTOS_GUNZ_WINDOWS=61, CLIENTOS_GUNZ_MAC=62
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:260 — ClientPendingGame = 10 (0x0A); :64 GameServerChallenge = 31 (0x1F); :53 GameServerLoginError = 20
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:1727-1743 — setClientVersion only resets features and fires the Lua onClientVersionChange hook
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:1793-1801 — getOs() returns m_clientCustomOs when > CLIENTOS_NONE
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:597-619 — loginWorld sets m_worldName after ProtocolGame::login (async connect, so it is set before onConnect fires)
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:295-306 — version >= 1530: g_game.setRsa(GUNZODUS_RSA); g_game.setCustomOs(61)
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:28,45,51,52,107,108,173,225 — GameLoginPacketEncryption/GameProtocolChecksum/GameChallengeOnLogin/GameMessageSizeCheck/GamePreviewState/GameClientVersion/GameSessionKey/GameSequencedPackets all ON at 1530
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/const.lua:326-333 — GUNZODUS_RSA, 1024-bit decimal modulus, exponent 65537
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/game.lua:19-48 — chooseRsa early-returns unless the current key is CIPSOFT/OTSERV (so the 1530 key+OS survive); setRsa defaults e = '65537'
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/protocollogin.lua:61-145 — the login-server protocol variant: RSA blocks padded with RANDOM bytes, enableChecksum before send, enableXtea after, sequenced enabled 1 s later

## Pitfalls
- The u16 size field at 1530 is a BLOCK COUNT (bytes/8), not a byte count, and it excludes both itself and the 4-byte sequence dword: outgoing `(messageSize-4)/8`, incoming `size*8+4`. Treating it as a byte length breaks framing on the very first packet.
- There is NO 'decrypted size u16' at 1530. It is a single u8 padding COUNT as the first plaintext byte of the encrypted region, and payloadLen = encryptedSize - paddingCount - 1. Porting stock OTClient/TFS code here is the single most likely failure.
- The padding byte + 8-byte alignment is applied even when XTEA is OFF (the gate is `clientVersion >= 1405`, not `xteaEnabled`). The login packet and the server's challenge both carry it.
- The 4-byte `[0][0][0][0]` compression header goes INSIDE the XTEA region and AFTER the padding byte, but is added only once XTEA is enabled and only for OS 60..62. Omitting it makes the server read your opcode as the compression flag: login still succeeds and pings answer, but every gameplay action is silently dropped (protocol.cpp:135-140).
- Sequence and checksum are mutually exclusive and sequence wins. At 1530 you must call the equivalent of enableChecksum() anyway, because it is what makes recv() reserve the 4 header bytes — but you must never actually emit an adler32.
- The very first bytes on the socket are the raw, unframed `worldName + '\n'`. It bypasses send()'s whole pipeline and does NOT consume a sequence number, so the login packet is sequence 0.
- XTEA is enabled AFTER the login packet is sent, and sequenced packets are enabled at connect (not at login). Order matters: seq on from packet 0, xtea from packet 1.
- The inbound sequence number is never validated — only bit 31 is read, as a per-packet compression flag. Do not reject packets on sequence mismatch, and do not forget to consume the dword.
- The first received message is unencrypted, so the C++ skips its padding byte in ProtocolGame::onRecv but never trims the trailing padding; the parse loop then sees a bogus opcode 0x00 and only survives because the default arm skips to EOF. Trim `paddingCount` bytes off the tail yourself.
- RSA is RSA_NO_PADDING — raw m^e mod n over exactly 128 big-endian bytes, zero-padded on the left. The plaintext block itself is zero-padded on the RIGHT to 128 bytes by addPaddingBytes (the login-SERVER protocol in protocollogin.lua uses random padding instead — do not confuse them).
- XTEA word packing is little-endian, and `>>5` is a LOGICAL shift on uint32. In LuaJIT use bit.rshift and mask every add to 32 bits; a signed shift or an unmasked add silently corrupts round 1.
- Inbound zlib is RAW deflate (windowBits -15) applied AFTER XTEA decryption, and in STREAM mode the inflate context is shared across packets and never reset — a per-packet inflate object will desync after the first compressed packet.
- `m_maxHeaderSize` is 7 (not 8) at 1530, and the header fields consume it exactly: 1 padding + 4 seq + 2 size. That is why prependCompressionHeader has to memmove forward instead of prepending.
- On an invalid size, a checksum mismatch, or a decrypt failure the C++ just returns without re-arming the read, stalling the connection. Do not replicate that; treat those as protocol errors.
- g_game.chooseRsa() runs after setClientVersion in entergame.lua and would reset OS to Windows(-1/2) and the key to OTSERV_RSA — it is only a no-op because features.lua installed GUNZODUS_RSA first. A from-scratch client must simply hard-code OS 61 + GUNZODUS_RSA.

## Open questions
- The `u16 2` literal inserted into the RSA block for OS 60..62 (protocolgamesend.cpp:188-192) is documented in-tree as UNVERIFIED — its semantic meaning is unknown, only that the server's fixed-layout parse expects it there.
- The `"261"` extended-data fallback (protocolgamesend.cpp:194-204) is a literal lifted from the gunzotc binary; its meaning is undocumented. It is emitted only when the Lua getLoginExtendedData hooks return empty.
- The content-revision string is the decimal text of a u32 read from `assets/assets.json.sha256` or `things/1530/assets.json.sha256`. Whether Gunzodus actually validates it, and what value the live server expects, is not determinable from this tree — a Lua client will have to supply the same file/value the real client ships.
- Outbound compression is never exercised: `m_outboundCompressionMode` is hard-coded 0 and the in-tree comment argues the gunzotc expression can never be non-zero. If the server ever negotiates mode 1/2 outbound (extended opcode 8 sub-opcode 0), this client's behaviour is untested.
- Whether the server ever sets bit 31 (compressed inbound packets) on Gunzodus at all, and if so whether it uses PER_PACKET or STREAM mode, is not determinable statically — the client autodetects at runtime. A Lua client should implement both paths with the same autodetect.
- `g_game.getProtocolVersion()` is set by client_entergame, not by features.lua; it is assumed to be 1530 here but the exact value the entergame module writes was not traced (out of this area's scope).
- Whether Gunzodus enforces the `[0x32][0x0A][STR hwid]` frame that gunzotc sends right after enter-game (protocolgamesend.cpp:233-240) is marked UNVERIFIED in-tree.

## VERIFIER (confidence 0.92)

### Corrections (AUTHORITATIVE — these override the spec above)
- **Claim**: §1.6 / §6.1: "Incoming ceiling: remainingSize == 0 || remainingSize > 0xFFFF → rejected (protocol.cpp:226-230)" — implying a zero-length packet is rejected.
  - **Correction**: At clientVersion >= 1405 the `== 0` arm is UNREACHABLE, so a `blocks == 0` packet IS accepted and then throws an uncaught exception. The transform runs BEFORE the test: `remainingSize = remainingSize * 8U + 4U;` so the minimum value reaching the test is 4, never 0. A frame of `00 00` + 4 dword bytes therefore passes, `internalRecvData` runs with `encryptedSize = getUnreadSize() = (2+4) - 6 = 0`, `0 % 8 == 0` passes, `apply_rounds` is a no-op, and then `inputMessage->getU8()` (protocol.cpp:382) fails `canRead(1)` — `m_readPos(6) - m_headerPos(0) + 1 = 7 > m_messageSize(6)` (inputmessage.cpp:139) — and throws `stdext::exception("InputMessage eof reached")` out of the asio completion handler with no try/catch on the path. Same throw in the pre-XTEA case via `ProtocolGame::onRecv`'s `inputMessage->getU8()` (protocolgame.cpp:70). A Lua reimplementation MUST explicitly reject `blocks == 0` (and, when XTEA is on, `paddingCount + 1 > blocks*8`, which is likewise unvalidated: `decryptedSize = encryptedSize - paddingSize - 1` is uint16 and silently wraps).
  - Evidence: src/framework/net/protocol.cpp:217-238 — `uint32_t remainingSize = m_inputMessage->readSize(); if (g_game.getClientVersion() >= 1405) { remainingSize = remainingSize * 8U + 4U; } constexpr uint32_t MAX_PACKET = std::numeric_limits<uint16_t>::max(); if (remainingSize == 0 || remainingSize > MAX_PACKET) {` ; src/framework/net/inputmessage.cpp:137-147 `canRead`/`checkRead` throw ; src/framework/net/protocol.cpp:380-386 `const uint8_t paddingSize = inputMessage->getU8(); ... decryptedSize = encryptedSize - paddingSize - 1;`
- **Claim**: PSEUDOCODE `recvMessage`, non-XTEA branch comment: "first (pre-XTEA) message: ProtocolGame::onRecv skips one padding byte" — the pseudocode strips the padding byte and the tail on EVERY message while `xteaOn` is false.
  - **Correction**: That is a deliberate divergence from the C++, and the spec never says so. `m_firstRecv` is set true exactly once per connection (protocolgame.cpp:47) and cleared on the first `onRecv`; a SECOND pre-XTEA message (server sends e.g. `GameServerLoginAdvice`/`GameServerLoginWait` and then the 0x1F challenge, or an error after an advice) gets NO padding-byte skip in the C++ and `parseMessage` reads the padding count as an opcode. The pseudocode's behaviour (always strip while XTEA is off) is the correct one for a from-scratch client, but the spec must state the rule as "strip the leading padding byte and the `paddingCount` trailing bytes on every frame received while XTEA is off", not "on the first message". Otherwise an implementer following §6.3 literally will desync on the second pre-login packet.
  - Evidence: src/client/protocolgame.cpp:66-78 — `if (m_firstRecv) { m_firstRecv = false; if (g_game.getClientVersion() >= 1405) { inputMessage->getU8(); // padding }` — guarded by `m_firstRecv`, which is only ever set in `ProtocolGame::onConnect` (protocolgame.cpp:47)
- **Claim**: §4.3: `str "<contentRevision>"` is gated on "clientVersion >= 1334 && isGunzOs".
  - **Correction**: Wrong gate. The string field is emitted for ALL operating systems at `clientVersion >= 1334`; `isGunzOs` only selects WHICH string. A non-gunz OS still writes a string (`g_things.getAssetIdentifier()`), it does not omit the field. Correct statement: at cv >= 1334 write one `addString`; its content at OS 61 is the decimal text of `resolveGunzContentRevision()`. Also note the `else if (GameContentRevision)` fallback writes a **u16**, not a string — so "superseded by the >=1334 branch" in §0 is right, but the two branches are not the same width and an implementer must not conflate them.
  - Evidence: src/client/protocolgamesend.cpp:137-146 — `if (g_game.getClientVersion() >= 1334) { if (isGunzOs) msg->addString(std::to_string(resolveGunzContentRevision())); else msg->addString(g_things.getAssetIdentifier()); } else if (g_game.getFeature(Otc::GameContentRevision)) { msg->addU16(g_things.getContentRevision()); }`
- **Claim**: §5 mode autodetection, step 1/2: "If it returns Z_STREAM_END and produced >0 bytes → mode := PER_PACKET, inflateReset. Else, if mode was UNKNOWN → inflateReset, mode := STREAM, fall through."
  - **Correction**: Incomplete — there is a third outcome the spec omits. Once the mode has latched to PER_PACKET, a Z_FINISH inflate that does NOT return Z_STREAM_END drops the packet with an error and returns; it does NOT fall back to STREAM. So the mode decision is one-shot and irreversible, and a PER_PACKET connection that later receives a stream-style payload silently loses that packet (and `recv()` is not re-armed). A Lua client must replicate the latch (or, better, treat a PER_PACKET inflate failure as a fatal protocol error rather than a silent drop).
  - Evidence: src/framework/net/protocol.cpp:~299-311 — `} else if (m_compressionMode == COMPRESSION_MODE_UNKNOWN) { inflateReset(&m_zstream); m_compressionMode = COMPRESSION_MODE_STREAM; totalSize = 0; } else { g_logger.traceError("failed to decompress message - {}", m_zstream.msg); return; }`
- **Claim**: PSEUDOCODE: `local function u32(x) return band(x, 0xFFFFFFFF) end` and `local sum = u32(DELTA * 32)  -- delta << 5 == 0xC6EF3720`.
  - **Correction**: In LuaJIT `bit.band` returns a SIGNED 32-bit result, so `u32(0x13C6EF3720)` evaluates to -958005472, not 0xC6EF3720. The arithmetic happens to survive (Lua's `%` in `add32`/`sub32` is floored and therefore non-negative, and `bit.rshift` re-normalises the pattern), but the helper is a trap: any use of `u32()` whose result is compared, indexed, or formatted will be wrong, and `DELTA * 32` is computed as a double (84941944608) before truncation. Write `local sum = 0xC6EF3720` literally, and drop the unused `u32` helper (it is not used anywhere else in the pseudocode). The C++ value is correct: `delta << 5` with `delta = 0x9E3779B9` is 0xC6EF3720.
  - Evidence: src/framework/net/protocol.cpp:342 `constexpr uint32_t delta = 0x9E3779B9;` and :371 `for (uint32_t i = 0, sum = delta << 5, next_sum = sum - delta; i < 32; ++i, sum = next_sum, next_sum -= delta)`
- **Claim**: §4.4 table lists `str extendedData` as an unconditional field of the RSA block.
  - **Correction**: It is conditional: `if (!extended.empty()) msg->addString(extended);`. The field is present at 1530 only because the "261" substitution guarantees non-emptiness (isGunzOs && cv >= 1281). If an implementer parameterises `extendedData` and passes an empty string with the 261-fallback disabled, the whole u16-length+bytes field must vanish, not be written as a zero-length string. (Confirmed no Lua `getLoginExtendedData` provider exists for ProtocolGame — the only occurrence in modules/ is a *call site* in protocollogin.lua:83, a different protocol — so both lookups return empty and "261" always wins.)
  - Evidence: src/client/protocolgamesend.cpp:198-204 — `auto extended = callLuaField<std::string>("getLoginExtendedData"); if (extended.empty()) extended = g_lua.callGlobalField<std::string>("g_game", "getLoginExtendedData"); if (extended.empty() && isGunzOs && g_game.getClientVersion() >= 1281) extended = "261"; if (!extended.empty()) msg->addString(extended);`
- **Claim**: §0: "`Game::setClientVersion` (src/client/game.cpp:1727-1743) does nothing but `m_features.reset()` + `g_lua.callGlobalField(...)`."
  - **Correction**: Imprecise in a way that matters for the ordering argument. It also early-returns when the version is unchanged, throws if online, validates against `g_gameConfig.getLastSupportedVersion()`, and assigns `m_clientVersion`. Critically, it does NOT reset `m_clientCustomOs` and does NOT reset the RSA key — which is exactly why the `setRsa` → `setCustomOs` ordering inside the `version >= 1530` block survives the later `chooseRsa`. Also, `m_protocolVersion` is set separately by `setProtocolVersion` (game.cpp:1709), which resets nothing; at 1530 `g_game.getClientProtocolVersion(1530)` is the identity (no entry in the remap table), so protocolVersion == 1530.
  - Evidence: src/client/game.cpp:1727-1742 — `if (m_clientVersion == version) return; if (isOnline()) throw ...; if (version != 0 && (version < 740 || version > g_gameConfig.getLastSupportedVersion())) throw ...; m_features.reset(); m_clientVersion = version; g_lua.callGlobalField("g_game", "onClientVersionChange", version);` ; modules/gamelib/game.lua:91-104 `getClientProtocolVersion` remaps only 980-1002, `return clients[client] or client`

### Additions
- VERIFIED CORRECT (byte-critical claims I checked line by line and found accurate): the u16 size field is a BLOCK COUNT `(m_messageSize - 4) / 8` (outputmessage.cpp:158-162) and the inbound inverse `remainingSize * 8U + 4U` (protocol.cpp:221-223); `m_maxHeaderSize = cv >= 1405 ? 7 : 8` in BOTH OutputMessage (outputmessage.cpp:29,36) and InputMessage (inputmessage.cpp:29,36); recv headerSize = 2 + 4 + 1 = 7 so `setHeaderSize` gives headerPos = readPos = 0 (inputmessage.cpp:122-127); `paddingAmount = 8 - (m_messageSize % 8) - 1` with zero filler and a prepended count (outputmessage.cpp:151-156, default `uint8_t byte = 0` at outputmessage.h:51); prependCompressionHeader memmoves forward and writes [mode][0][0][0] at m_headerPos (outputmessage.cpp:164-181); the send order compression-header → padding → xtea → sequence(else-if checksum) → headerSize (protocol.cpp:130-171); sequence wins over checksum so no Adler-32 is ever emitted at 1530; inbound dword used only for bit 31 (`m_inputMessage->getU32() & 1 << 31`); XTEA delta 0x9E3779B9, 32 rounds, encrypt sum starts 0, decrypt sum starts `delta << 5` = 0xC6EF3720, little-endian word packing in apply_rounds (protocol.cpp:342-397); `getXteaEncryptionBuffer()` = `getHeaderBuffer()` at >=1405 (outputmessage.cpp:212-215); xteaEncrypt's own 8-alignment top-up is genuinely dead; adler32 seeded with `adler32(0,Z_NULL,0)` == 1 (math.cpp:39-44); RSA_NO_PADDING, decimal key parse, rsaGetSize 128, encrypt the last 128 bytes at `m_buffer + m_writePos - size` (crypt.cpp:188-199, 235-260, 289-297; outputmessage.cpp:115-123); zero RSA filler in ProtocolGame vs random in protocollogin.lua:89-92,120-125; login-packet field order including the `isGunzOs` `addU16(2)` marker and the `>=1281` "1530" string; `enableXteaEncryption()`/`enabledSequencedPackets()` AFTER the send; raw world-name + '\n' preamble at cv>=1200 then `enabledSequencedPackets()` unconditionally (protocol.cpp:422-433); login packet carries sequence 0; 0x1F challenge = u32 ts + u8 random + 1 skipped byte at >=1405 (protocolgameparse.cpp:1419-1429); first-message padding byte consumed without shrinking messageSize, trailing zeros swallowed by the `default:` arm's `skipBytes(unreadSize)` (protocolgameparse.cpp:680-699); const.h:38-40 OS 60/61/62; protocolcodes.h:260 ClientPendingGame = 10, :64 GameServerChallenge = 31; connection.h:36-39 and connection.cpp:191-209 / 273-286; no MAX_HEADER_SIZE constant exists anywhere in src/.
- VERIFIED CORRECT — feature flags at 1530. Every features.lua line number in the §0 table is exact: GameLoginPacketEncryption:28, GameProtocolChecksum:45, GameChallengeOnLogin:51, GameMessageSizeCheck:52, GamePreviewState:107, GameClientVersion:108, GameContentRevision:165, GameAuthenticator:169, GameSessionKey:173, GameSequencedPackets:225, `g_game.setRsa(GUNZODUS_RSA)`:304, `g_game.setCustomOs(61)`:305. No later version block disables any of them. `Game::getOs()` returns m_clientCustomOs whenever it is > CLIENTOS_NONE(0), so getOs() == 61 (game.cpp:1793-1804, const.h:28).
- VERIFIED CORRECT — RSA modulus. I concatenated the five string literals at modules/gamelib/const.lua:329-333 and compared byte-for-byte against the spec's decimal: identical, 309 digits, exactly 1024 bits, and the spec's convenience hex `0xb179acbd...df49e289` is an exact match for that integer. Exponent defaults to '65537' via `g_game.setRsa(rsa, e)` (modules/gamelib/game.lua:44-48). `g_game.chooseRsa` early-returns unless the current key is CIPSOFT_RSA/OTSERV_RSA, confirming it cannot clobber the key or OS (game.lua:19-22).
- OMISSION — TCP write coalescing. `Connection::write` does NOT write to the socket; it appends to a shared `asio::streambuf` flushed by a 0 ms `m_delayedWriteTimer`. Multiple framed packets emitted in the same frame arrive as ONE TCP segment. `ProtocolGame::sendEnterGame` exercises this: it sends TWO separately framed packets back-to-back — `[0x0F]` and, when OS is 60..62, `[0x32][0x0A][u16 len + hwid string]` — consuming TWO sequence numbers. A from-scratch client must frame them independently (do not merge them into one body), though concatenating them in one socket write is fine. Evidence: src/framework/net/connection.cpp:145-168; src/client/protocolgamesend.cpp:227-249; protocolcodes.h:276 ClientExtendedOpcode = 50.
- OMISSION — sequence counter lifetime. `m_packetNumber` is a plain `Protocol` member (protocol.h:92) and `Game::loginWorld` constructs a fresh `ProtocolGame` on every login (src/client/game.cpp:612), so the counter restarts at 0 on every reconnect. There is no persistence and no wrap handling; it is a plain uint32 post-increment.
- OMISSION — `addCompressionFooter` writes at `m_buffer + m_messageSize`, NOT `m_buffer + m_headerPos + m_messageSize` (inputmessage.h:106-125). That is only correct because `m_headerPos == 0` at 1530. Similarly the "already present" check inspects `m_buffer + m_messageSize - 4`. Do not generalise this address arithmetic; in Lua just append `\0\0\xFF\xFF` to the decrypted payload when its last four bytes are not already that.
- LATENT BUG, unreachable at 1530 but do not mirror it: if a packet arrives with bit 31 set while XTEA is still OFF, `m_zstream.next_in = getDataBuffer()` is `m_buffer + m_maxHeaderSize` = `m_buffer + 7` (a constant), while `avail_in = getUnreadSize()` is measured from `m_readPos`, which is 6 in that state (the padding byte has not been consumed). The inflate input is therefore shifted by one byte and reads one byte past the frame. It only lines up because `xteaDecrypt` advances readPos to 7. Evidence: inputmessage.h:136 `getDataBuffer() { return m_buffer + m_maxHeaderSize; }` vs :80 `getUnreadSize() { return m_messageSize - (m_readPos - m_headerPos); }`; protocol.cpp:279-283.
- CLARIFICATION on §1.3's "harmless" prependU8/prependU16 writePos quirk: it is harmless on the socket path because the write uses `getHeaderBuffer()` + `getMessageSize()` and `reset()` restores writePos. It is NOT harmless on the proxy path, which passes `outputMessage->getWriteBuffer()` (= m_buffer + m_writePos, now 3 short) to ProxyPacket. Irrelevant for a direct-TCP Lua client, but the spec's stated reason ("nothing appends afterwards") is not the whole reason. Evidence: src/framework/net/protocol.cpp:174; outputmessage.h:66.
- CLARIFICATION on §1.1: `ProtocolGame::sendLoginPacket` calls `enableChecksum()` a second time (protocolgamesend.cpp:215-216) — a no-op, since `ProtocolGame::onConnect` already enabled it (protocolgame.cpp:52-53) and `m_sequencedPackets` wins in `send()` regardless. It changes no byte. Likewise the post-send `enabledSequencedPackets()` (protocolgamesend.cpp:223-224) is redundant with `Protocol::onConnect`'s unconditional call.
- CLARIFICATION on §1.1's world-name guarantee: it holds only on the async TCP path. `Protocol::connect` calls `onConnect()` SYNCHRONOUSLY for host "proxy"/"0.0.0.0"/proxied "127.0.0.1" (protocol.cpp:56-66), and `Game::loginWorld` assigns `m_worldName` AFTER `m_protocolGame->login(...)` (game.cpp:617-619) — so on that path the preamble would be just "\n". Not reachable for a plain Lua TCP client, but it explains the sequencing and is worth stating rather than leaving as an unexplained ordering assumption.
- MINOR: §0 cites the two no-op `chooseRsa` sites (entergame.lua:1247, 1465) but there is a third `setClientVersion`/`setProtocolVersion` pair at entergame.lua:1604-1605 with no `chooseRsa` call at all. Harmless (chooseRsa is a no-op once GUNZODUS_RSA is installed), but the enumeration is incomplete.
- MINOR: §1.6's "m_messageSize is uint16_t → hard ceiling 65535 wire bytes" — the actual guard is `canWrite`: `m_writePos + bytes <= BUFFER_MAXSIZE (65536)` (outputmessage.cpp:183-186), and `m_messageSize` wraps at 65536, not 65535. The inbound cap the spec derives is right: `blocks*8 + 4 <= 65535` gives max 8191 blocks = 65528 encrypted bytes = 65534 wire bytes.
