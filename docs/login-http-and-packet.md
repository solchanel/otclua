# Complete login sequence for Gunzodus / protocol 1530 (mehah OTClient-Redemption fork at D:/Claude/otclient_mehah1530/otclient): HTTPS account login → TCP connect → world-name handshake → challenge → RSA/XTEA login packet → pending/enter-game → in-game keepalive and logout.

# Gunzodus 1530 login sequence — byte-exact specification

Reference tree: `D:/Claude/otclient_mehah1530/otclient` (read-only). All offsets/values below are for
**clientVersion = 1530, protocolVersion = 1530, OS = 61**.

---

## 0. Constants fixed for 1530

| Name | Value | Source |
|---|---|---|
| clientVersion | 1530 | `init.lua:84` (`protocol = 1530`) |
| protocolVersion | 1530 (`getClientProtocolVersion` has no 1530 entry → identity) | `modules/gamelib/game.lua:91-104` |
| OS (`g_game.getOs()`) | **61** = `CLIENTOS_GUNZ_WINDOWS` | `features.lua:305` `g_game.setCustomOs(61)`; `const.h:38-40` |
| isGunzOs test | `60 <= os <= 62` | `protocolgamesend.cpp:123-124` |
| RSA modulus | GUNZODUS_RSA (1024-bit, 309 decimal digits), e = 65537 | `features.lua:304`, `const.lua:329-333`, `game.lua:44-48` |
| `rsaGetSize()` | **128** | `crypt.cpp:289-297` (`RSA_size`) |
| Content revision | **"42196"** (text of `data/things/1530/assets.json.sha256`, 5 bytes, no newline) | `protocolgamesend.cpp:65-98`; file verified 5 bytes |
| Login extended data | **"261"** (no Lua override exists in this tree) | `protocolgamesend.cpp:198-204`; `grep getLoginExtendedData` finds only `protocollogin.lua` (the 7171 path) |
| Ping delay | 1000 ms | `game.h:534` `m_pingDelay{1000}` |
| Checksum algorithm | adler32 (unused outgoing — sequenced packets win) | `math.cpp:39-44` |

### Feature flags that gate login bytes (all evaluated at 1530)

| Flag | Enabled? | Gate | Effect on login |
|---|---|---|---|
| `GameLoginPacketEncryption` | **yes** (≥770) | `features.lua:28` | RSA block + XTEA |
| `GameProtocolChecksum` | **yes** (≥840) | `features.lua:45` | `enableChecksum()` → **incoming header size becomes 7** |
| `GameAccountNames` | yes (≥840) | `features.lua:46` | irrelevant (session-key branch wins) |
| `GameChallengeOnLogin` | **yes** (≥841) | `features.lua:51` | client does **not** send login on connect; waits for opcode 0x1F |
| `GameMessageSizeCheck` | yes (≥841) | `features.lua:52` | **dead at 1530** — the `>=1405` branch runs instead (`protocolgame.cpp:69-77`) |
| `GameClientPing` | **yes** (≥953) | `features.lua:90` | client pings with 0x1D; server 0x1E = pong |
| `GamePreviewState` | **yes** (≥980) | `features.lua:107` | one `u8 0x00` before the RSA block |
| `GameClientVersion` | **yes** (≥980) | `features.lua:108` | `u32 clientVersion` |
| `GameLoginPending` | **yes** (≥981) | `features.lua:112` | opcode 0x0A ⇒ *pending*, not *login-success* |
| `GameContentRevision` | yes (≥1071) | `features.lua:165` | **not reached** — `>=1334` branch takes precedence |
| `GameAuthenticator` | yes (≥1072) | `features.lua:169` | **not reached** (session-key branch) |
| `GameSessionKey` | **yes** (≥1074) | `features.lua:173` | RSA block carries sessionKey + characterName |
| `GameSequencedPackets` | **yes** (≥1290) | `features.lua:225` | irrelevant — `Protocol::onConnect` already enabled it at ≥1200 |
| `GameExtendedClientPing` | **NO** (never enabled) | — | ping is opcode 0x1D, not extended opcode 2 |
| `GameTournamentPackets` | **NO** (enabled ≥1200, disabled ≥1314) | `features.lua:200,241` | no tournament byte in 0x17 |
| `GameDynamicBugReporter` | **yes** (≥1320) | `features.lua:252` | **removes** the `canReportBugs` u8 from 0x17 |
| `GameTacticsWithoutFightMode` | **yes** (≥1525) | `features.lua:292` | changes the post-login fight-mode packet |

---

## 1. HTTPS account login

### 1.1 Where host/path/port come from

`init.lua:81-89`:
```lua
["https://www.gunzodus.net/game/login/1530"] = {
    name = "Gunzodus", port = 443, protocol = 1530,
    httpLogin = true, useAuthenticator = true, order = 1 }
```
The table **key is the full URL**. `EnterGame.tryHttpLogin` splits it (`entergame.lua:1271-1294`):
```lua
local host, path = G.host, "/"
if G.host:find("https?://") then
    local url = G.host:gsub("https?://", "")
    host, path = url:match("([^/]+)(/.*)")     -- host="www.gunzodus.net", path="/game/login/1530"
    ...
end
```
Result: **host `www.gunzodus.net`, path `/game/login/1530`, port `443`** (`G.port` from the widget = 443).

Routing decision (`entergame.lua:1443-1446`): `clientVersion >= 1281 and G.port ~= 7171` → HTTP login path.
Then `entergame.lua:1300`: `http:httpLogin(host, path, G.port, G.account, G.password, G.requestId, httpLogin, G.authenticatorToken)`.

### 1.2 The request, byte for byte

`httplogin.cpp:397-446` (`loginHttpsJson`) — the **only** variant used first; `startHttpLogin` is dead code.

* Transport: TLS via `httplib::SSLClient(host, 443)`.
  **Certificate verification is disabled**: `client.enable_server_certificate_verification(false)` and
  `enable_server_hostname_verification(false)` (`httplogin.cpp:410-411`). `set_ca_cert_path("./cacert.pem")` is set but moot.
* Method/path: `POST /game/login/1530 HTTP/1.1`
* Explicit header: `User-Agent: Mozilla/5.0` (`httplogin.cpp:425`)
* Content type argument: `application/json`
* httplib 0.48.0 adds (multimap → **case-insensitive alphabetical order on the wire**):
  `Accept: */*`, `Accept-Encoding: br` (vcpkg build: BROTLI=TRUE, ZLIB/ZSTD off — `httplibTargets.cmake:61`),
  `Connection: close` (client is non-keepalive), `Content-Length`, `Content-Type`, `Host: www.gunzodus.net` (port omitted, it is the TLS default).

Full request (no token):
```
POST /game/login/1530 HTTP/1.1\r\n
Accept: */*\r\n
Accept-Encoding: br\r\n
Connection: close\r\n
Content-Length: <n>\r\n
Content-Type: application/json\r\n
Host: www.gunzodus.net\r\n
User-Agent: Mozilla/5.0\r\n
\r\n
{"email":"<email>","password":"<password>","stayloggedin":true,"type":"login"}
```

JSON body construction (`httplogin.cpp:413-423`):
```cpp
json body = { {"email", email}, {"password", password},
              {"stayloggedin", true}, {"type", "login"} };
if (!token.empty()) { body["token"] = token; body["authenticatorToken"] = token; }
... client.Post(path, headers, body.dump(), "application/json");
```
`nlohmann::json`'s object is `std::map`, so `dump()` emits **keys in lexicographic order, compact, no spaces**.
Key types: `email` string, `password` string, `stayloggedin` **boolean true**, `type` string `"login"`,
and when a 2FA token is present **both** `token` and `authenticatorToken` (same string value):
```
{"authenticatorToken":"12345678","email":"...","password":"...","stayloggedin":true,"token":"12345678","type":"login"}
```

Fallback (`httplogin.cpp:255-259`): if the HTTPS attempt returns no response or status ≠ 200 **and** the server entry
has `httpLogin = true` (Gunzodus does), the *same* body is retried over **plain HTTP to the same host/path/port (443)**.
That retry is effectively a no-op against a TLS listener; TLS is always tried first.

### 1.3 The response and what is consumed

Accepted only if HTTP 200 **and** `parseJsonResponse` succeeds (`httplogin.cpp:494-528`):
1. must parse as JSON;
2. if `errorCode` exists and `!= 0` → failure, message from `errorMessage` (default `"Authenticator token required."`).
   `errorCode == 6` is special-cased in Lua → show the 2FA token dialog and retry (`entergame.lua:38-55`);
3. must contain **`session`** and **`playdata`**;
4. `playdata` must contain **`characters`** and **`worlds`**.

The three sub-documents are re-serialized to strings and handed to Lua:
```cpp
this->session    = to_string(responseJson["session"]);
this->characters = to_string(playdata["characters"]);
this->worlds     = to_string(playdata["worlds"]);
g_lua.callGlobalField("EnterGame","loginSuccess", request_id, session, worlds, characters);
```

`EnterGame.loginSuccess` (`entergame.lua:1315-1388`) consumes exactly:

* **worlds[]** (array): `id`, `name`, `externaladdressprotected` → *worldIp*, `externalportprotected` → *worldPort*,
  `previewstate` (compared `== 1`), `pvptype`.
* **characters[]** (array): `worldid` (joins to worlds), `name`, `level`, `ismaincharacter`, `dailyrewardstate`,
  `ishidden`, `vocation`, `outfitid`, `headcolor`, `torsocolor`, `legscolor`, `detailcolor`, `addonsflags`.
* **session** (object): **`sessionkey`** → `G.sessionKey` (`entergame.lua:1385`), `premiumuntil` (epoch seconds, premium days display only).

So: **session key = `response.session.sessionkey`**, **world host = `worlds[c.worldid].externaladdressprotected`**,
**world port = `worlds[c.worldid].externalportprotected`**, **character names = `characters[i].name`**,
**world name = `worlds[c.worldid].name`**.

Character entry (`characterlist.lua:404-443`):
```lua
g_game.loginWorld(G.account, G.password, charInfo.worldName, charInfo.worldHost, charInfo.worldPort,
                  charInfo.characterName, G.authenticatorToken, G.sessionKey)
```
(`charInfo.worldHost = characterInfo.worldIp`, `characterlist.lua:881-882`).
`Game::loginWorld` (`game.cpp:597-619`) stores `m_worldName`/`m_characterName` and calls
`ProtocolGame::login()` → `Protocol::connect(host, port)` (`protocolgame.cpp:27-43`).

---

## 2. TCP handshake — what is written immediately on connect

`Protocol::onConnect` (`protocol.cpp:422-433`):
```cpp
void Protocol::onConnect() {
    if (g_game.getClientVersion() >= 1200) {
        std::string sendWorldName(g_game.getWorldName());
        sendWorldName += '\n';
        const auto& msg = std::make_shared<OutputMessage>();
        msg->addBytes(std::string_view(sendWorldName));
        send(msg, true);           // raw == true
        enabledSequencedPackets();
    }
    callLuaField("onConnect");
}
```

* The very first bytes on the socket are the **plain ASCII world name followed by `0x0A` ('\n')**.
* `send(msg, /*raw=*/true)` **skips the entire framing pipeline** (`protocol.cpp:133-171`): no 2-byte size,
  no sequence, no padding byte, no XTEA, no compression header. It is **outside** the encrypted stream and
  outside the sequence numbering (`m_packetNumber` stays 0).
* `enabledSequencedPackets()` fires here, so the **login packet is sequence 0**.

`ProtocolGame::onConnect` (`protocolgame.cpp:45-59`) then runs:
```cpp
m_firstRecv = true;
Protocol::onConnect();                       // world name written here
m_localPlayer = g_game.getLocalPlayer();
if (g_game.getFeature(Otc::GameProtocolChecksum)) enableChecksum();   // TRUE at 1530
if (!g_game.getFeature(Otc::GameChallengeOnLogin)) sendLoginPacket(0,0);  // NOT taken at 1530
recv();
```

### 2.1 Frame format for every non-raw packet at clientVersion ≥ 1405 (so, 1530)

`OutputMessage` reserves `m_maxHeaderSize = 7` (`outputmessage.cpp:29`). `Protocol::send` (`protocol.cpp:133-171`) does,
in order:

1. **compression header** — only when XTEA is already enabled **and** `60 <= os <= 62`:
   `prependCompressionHeader(0)` inserts `00 00 00 00` **ahead of the opcode, inside the region that will be encrypted**
   (`outputmessage.cpp:164-181`). *Not present on the login packet* (XTEA is still off).
2. `writePaddingAmount()` (`outputmessage.cpp:151-156`): `p = 8 - (size % 8) - 1`; append `p` zero bytes;
   **prepend** the single byte `p`. Total is now a multiple of 8.
3. `xteaEncrypt()` if enabled — at ≥1405 it does **not** write a message size; it encrypts
   `getXteaEncryptionBuffer() == getHeaderBuffer()` (i.e. starting at the padding byte) for `m_messageSize` bytes.
4. `writeSequence(m_packetNumber++)` — prepend `u32 LE` (sequenced wins over checksum: `protocol.cpp:159-163`).
5. `writeHeaderSize()` (`outputmessage.cpp:158-162`): prepend `u16 LE = (m_messageSize - 4) / 8`.

**On the wire:** `[u16 LE blockCount][u32 LE sequence][u8 padAmount][body][padAmount zero bytes]`
where `blockCount = (1 + len(body) + padAmount) / 8` and the shaded region `[padAmount][body][pad]` is what XTEA covers.

### 2.2 Receive framing

`Protocol::recv` (`protocol.cpp:190-215`): `headerSize = 2 + 4 (checksum enabled) + 1 (>=1405) = 7`.
`internalRecvHeader` (`protocol.cpp:217-238`): read 2 bytes → `n`; **`remainingSize = n * 8 + 4`**; read that many.
`internalRecvData` (`protocol.cpp:240-331`):
* `m_sequencedPackets` → `seq = getU32()`; **`decompress = seq & (1<<31)`** (checksum is therefore never verified —
  the 4 "checksum" bytes reserved in `headerSize` are the sequence);
* if XTEA on → decrypt; then at ≥1405 read `padAmount = getU8()` and trim the message to `headerSize + (encSize - pad - 1)`;
* if `decompress` → raw-deflate inflate (`inflateInit2(&z, -15)`), per-packet `Z_FINISH` or stream `Z_SYNC_FLUSH` with a
  `00 00 FF FF` footer.

`ProtocolGame::onRecv` (`protocolgame.cpp:61-82`) — on the **first** packet only:
```cpp
if (m_firstRecv) { m_firstRecv = false;
    if (g_game.getClientVersion() >= 1405) inputMessage->getU8(); // padding
    else if (getFeature(GameMessageSizeCheck)) { ... } }
```
i.e. the challenge is unencrypted, so its `padAmount` byte is consumed here instead of inside `xteaDecrypt`.

---

## 3. The challenge packet

`parseLoginChallenge` (`protocolgameparse.cpp:1420-1430`), dispatched from
`case Proto::GameServerChallenge:` (`protocolgameparse.cpp:126-128`), `GameServerChallenge = 31 = 0x1F`
(`protocolcodes.h:64`):

```cpp
const uint32_t timestamp = msg->getU32();
const uint8_t  random    = msg->getU8();
if (g_game.getClientVersion() >= 1405) msg->skipBytes(1);
sendLoginPacket(timestamp, random);
```

* Opcode **0x1F**, payload `u32 LE timestamp`, `u8 random`, plus **one skipped byte at ≥1405** (purpose unknown).
* Body length 7 → `padAmount = 0`, so the whole frame is
  `[19?]` no — `blockCount = (1+7+0)/8 = 1`; wire = `01 00 | <u32 seq> | 00 | 1F tt tt tt tt rr xx` (14 bytes).
* Action: the two values go **verbatim into the RSA block** and the login packet is sent immediately.

---

## 4. `sendLoginPacket` — complete byte layout

Source: `protocolgamesend.cpp:115-225`. `Proto::ClientPendingGame = 10 = 0x0A` (`protocolcodes.h:260`).

### 4.1 Plaintext prefix (bytes 0..22 of the packet body)

| # | off | size | value @1530/Gunzodus | code |
|---|---|---|---|---|
| 1 | 0 | 1 | `0x0A` (`ClientPendingGame`) | `msg->addU8(Proto::ClientPendingGame);` :126 |
| 2 | 1 | 2 | `3D 00` — u16 LE OS **61** | `msg->addU16(g_game.getOs());` :127 |
| 3 | 3 | 2 | `FA 05` — u16 LE protocol version **1530** | `msg->addU16(g_game.getProtocolVersion());` :128 |
| 4 | 5 | 4 | `FA 05 00 00` — u32 LE client version **1530** (`GameClientVersion`) | :130-131 |
| 5 | 9 | 2+4 | `04 00 '1','5','3','0'` — `addString(std::to_string(clientVersion))`, gated `clientVersion >= 1281` | :133-135 |
| 6 | 15 | 2+5 | `05 00 '4','2','1','9','6'` — content revision string | :137-146 |
| 7 | 22 | 1 | `00` — preview state (`GamePreviewState`) | :148-149 |

**Content-revision branch (item 6) — the OS 60‑62 rule:**
```cpp
if (g_game.getClientVersion() >= 1334) {
    if (isGunzOs) msg->addString(std::to_string(resolveGunzContentRevision()));   // "42196"
    else          msg->addString(g_things.getAssetIdentifier());                  // raw sha256 file bytes
} else if (g_game.getFeature(Otc::GameContentRevision)) {
    msg->addU16(g_things.getContentRevision());
}
```
`resolveGunzContentRevision()` (`protocolgamesend.cpp:65-98`): probe `assets/assets.json.sha256`, then
`things/<clientVersion>/assets.json.sha256`; read, `trimSpacesAndNewlines`, `std::from_chars` a `uint32`,
**require the whole string consumed and `1 <= v <= 0xFFFF`**, else 0. Here → **42196**, sent as the decimal
text `"42196"` (length‑prefixed). The non-Gunz branch would send `g_things.getAssetIdentifier()`, which is the
**raw file contents** of `data/things/<v>/assets.json.sha256` (`thingtypemanager.cpp:171`) — for this install both
happen to be identical (`42196`, 5 bytes, no trailing newline), but the Gunz branch is the one that runs.

`const int offset = msg->getMessageSize();` → **offset = 23** (`protocolgamesend.cpp:151`).

### 4.2 The RSA block — exactly 128 plaintext bytes at body offset 23..150

| # | rel. off | size | content | code |
|---|---|---|---|---|
| 8 | +0 | 1 | `0x00` (mandatory first RSA byte) | :154-155 |
| 9 | +1 | 16 | XTEA key: `addU32(k0) addU32(k1) addU32(k2) addU32(k3)`, LE, from `generateXteaKey()` (`std::random_device` + `uniform_int_distribution<uint32_t>`, `protocol.cpp:333-338`) | :157-161 |
| 10 | +17 | 1 | `0x00` — "is gm set?" | :164 |
| 11 | +18 | 2+S | `addString(m_sessionKey)` — **`GameSessionKey` branch** | :166-168 |
| 12 | +20+S | 2+C | `addString(m_characterName)` | :168 |
| 13 | +22+S+C | 4 | `addU32(challengeTimestamp)` LE (`GameChallengeOnLogin`) | :183-185 |
| 14 | +26+S+C | 1 | `addU8(challengeRandom)` | :185 |
| 15 | +27+S+C | 2 | `02 00` — **u16 LE 2, Gunz-only marker** | :191-192 |
| 16 | +29+S+C | 2+3 | `03 00 '2','6','1'` — login extended data | :198-204 |
| 17 | +34+S+C | 128−(34+S+C) | zero padding | :207-209 |

The account-name/password/authenticator branch (`:171-181`) is **dead at 1530** because `GameSessionKey` is on.
The authenticator token is therefore **never sent on the game socket** — only in the HTTPS body.

Quoted, in order:
```cpp
if (g_game.getFeature(Otc::GameLoginPacketEncryption)) {
    msg->addU8(0);                       // first RSA byte must be 0
    generateXteaKey();
    msg->addU32(m_xteaKey[0]); ... msg->addU32(m_xteaKey[3]);
}
msg->addU8(0);                           // is gm set?
if (g_game.getFeature(Otc::GameSessionKey)) { msg->addString(m_sessionKey); msg->addString(m_characterName); }
else { ...account/char/password/authenticator... }
if (g_game.getFeature(Otc::GameChallengeOnLogin)) { msg->addU32(challengeTimestamp); msg->addU8(challengeRandom); }
if (isGunzOs) msg->addU16(2);
auto extended = callLuaField<std::string>("getLoginExtendedData");
if (extended.empty()) extended = g_lua.callGlobalField<std::string>("g_game","getLoginExtendedData");
if (extended.empty() && isGunzOs && g_game.getClientVersion() >= 1281) extended = "261";
if (!extended.empty()) msg->addString(extended);
const int paddingBytes = g_crypt.rsaGetSize() - (msg->getMessageSize() - offset);
msg->addPaddingBytes(paddingBytes);
if (g_game.getFeature(Otc::GameLoginPacketEncryption)) msg->encryptRsa();
```

**Nothing is appended after the RSA block.** The challenge bytes, the `u16 2` marker and the extended data are all
*inside* it, before the zero padding. `encryptRsa()` (`outputmessage.cpp:115-123`) encrypts the **last 128 bytes**
(`m_buffer + m_writePos - 128`) in place with `RSA_public_encrypt(..., RSA_NO_PADDING)` — textbook RSA:
big-endian integer `m` of the 128-byte block, `c = m^65537 mod n`, written back big-endian, left zero-padded to 128.

Constraint: `len(sessionKey) + len(characterName) <= 94`, else `paddingBytes` goes negative (`assert` at :208).

### 4.3 Resulting frame

Body = 23 + 128 = **151 bytes**. `padAmount = 8 - (151 % 8) - 1 = 0`; `blockCount = (1 + 151 + 0)/8 = 19`.

```
13 00              u16 LE 19                (blockCount)
00 00 00 00        u32 LE sequence 0
00                 padAmount = 0
0A                 opcode
3D 00              os 61
FA 05              protocol 1530
FA 05 00 00        client version 1530
04 00 31 35 33 30  "1530"
05 00 34 32 31 39 36   "42196"
00                 preview state
<128 bytes RSA ciphertext>
```
Total 158 bytes on the wire.

---

## 5. What enables XTEA and from where

`protocolgamesend.cpp:215-224`, immediately after `send(msg)`:
```cpp
if (g_game.getFeature(Otc::GameProtocolChecksum)) enableChecksum();
send(msg);
if (g_game.getFeature(Otc::GameLoginPacketEncryption)) enableXteaEncryption();
if (g_game.getFeature(Otc::GameSequencedPackets))      enabledSequencedPackets();
```

* The **login packet itself is sent in clear** (only its RSA tail is encrypted).
* From the **next** outgoing packet onward every non-raw packet is XTEA-encrypted, and (Gunz OS) carries the
  `00 00 00 00` compression header ahead of its opcode.
* `m_xteaEncryptionEnabled` is a single flag shared by both directions, so **the next inbound packet after the login
  packet is expected XTEA-encrypted too** — i.e. the challenge (0x1F) is the only plaintext packet from the server.
* XTEA: 32 rounds, `delta = 0x9E3779B9`, standard OTServ variant. Encrypt uses `sum` starting at 0 with key index
  `sum & 3` / `(next_sum >> 11) & 3`; decrypt starts at `delta << 5` with `(sum >> 11) & 3` / `next_sum & 3`
  (`protocol.cpp:340-420`). Blocks are little-endian u32 pairs.

---

## 6. Post-login server packets, in order

Dispatch table: `protocolgameparse.cpp:47-128`.

| Order | Opcode | Name | Payload | Client reaction |
|---|---|---|---|---|
| 1 | `0x1F` (31) | `GameServerChallenge` | `u32 timestamp`, `u8 random`, `u8 skipped (≥1405)` | send login packet (§4) |
| 2a | `0x0A` (10) | `GameServerLoginOrPendingState` → **`parsePendingGame`** because `GameLoginPending` is on | **no payload** | `Game::processPendingGame` (`game.cpp:153-158`): set pending, fire `onPendingGame`, then **`m_protocolGame->sendEnterGame()` synchronously** |
| 2b | `0x0B` (11) | `GameServerGMActions` | at ≥1200 it is a **string** ("secondary connection identifier") — `parseGMActions` reads `msg->getString()` and returns (`protocolgameparse.cpp:1358-1363`) | none |
| 3 | `0x17` (23) | `GameServerLoginSuccess` → `parseLogin` | see below | `Game::processLogin` → Lua `onLogin` |
| 4 | `0x0F` (15) | `GameServerEnterGame` | **no payload** | `parseEnterGame` (`:838-847`) → `processEnterGame` (`onEnterGame`) **and** `processGameStart` if not yet started |

Error/alternate first packets (any of them may arrive instead):

| Opcode | Handler | Payload |
|---|---|---|
| `0x11` (17) | `parseUpdateNeeded` (`:1382-1386`) | `string signature` |
| `0x14` (20) | `parseLoginError` (`:1388-1395`) | `string error`; **plus `u8 reason` if `clientVersion >= 1523` and bytes remain** |
| `0x15` (21) | `parseLoginAdvice` (`:1397-1401`) | `string message` |
| `0x16` (22) | `parseLoginWait` (`:1403-1409`) | `string message`, `u8 time` (seconds) |
| `0x18` (24) | `parseSessionEnd` (`:1411-1415`) | `u8 reason` |

**`0x17` payload at 1530** (`parseLogin`, `protocolgameparse.cpp:744-792`), in order:
1. `u32 playerId`
2. `u16 serverBeat`
3. `GameNewSpeedLaw` (on): three `getDouble()` = speedA, speedB, speedC. `getDouble` = `u8 precision` then
   `u32 raw`; value = `(int32)(raw - INT_MAX) / 10^precision` (`inputmessage.cpp:101-106`).
4. `GameDynamicBugReporter` is **on** at 1530 ⇒ the `canReportBugs` u8 is **NOT present**.
5. `clientVersion >= 1054`: `u8` (can change pvp frame)
6. `clientVersion >= 1058`: `u8` expert pvp mode
7. `GameIngameStore` (on): `string storeUrl`, `u16 coinsPacketSize`
8. `clientVersion >= 1281`: `u8` exiva enabled. `GameTournamentPackets` is **off** at 1530 ⇒ no extra byte.

**`sendEnterGame`** (`protocolgamesend.cpp:227-249`) — sent from `processPendingGame`, i.e. the instant 0x0A arrives:
```cpp
msg->addU8(Proto::ClientEnterGame);      // 0x0F
send(msg);
if (60 <= os && os <= 62) {              // Gunz only, unconditional, NOT via sendExtendedOpcode()
    hwidMsg->addU8(Proto::ClientExtendedOpcode);  // 0x32 (50)
    hwidMsg->addU8(10);
    hwidMsg->addString(getSystemVolumeFingerprint(m_accountName));
    send(hwidMsg);
}
```
`getSystemVolumeFingerprint` (`protocolgamesend.cpp:47-57`): FNV-1a-32 over the account name
(`h = 2166136261; h ^= byte; h *= 16777619`), formatted `"{:04X}-{:04X}"` of `h>>16` and `h & 0xFFFF`.
Both packets are XTEA-encrypted and carry the `00 00 00 00` compression header:
`enter-game` body on the wire (pre-encryption) is `00 00 00 00 0F`, sequence 1; the hwid frame is sequence 2.

**On `processGameStart`** (`game.cpp:168-191`), triggered by 0x0F:
* immediately sends `sendChangeFightModes` (opcode `0xA0` = 160, `protocolcodes.h:340`). Because
  `GameTacticsWithoutFightMode` is on at 1530, the layout is `A0 | u8 chaseMode | u8 safeFight | u8 pvpMode`
  (pvp byte because `GamePVPMode` ≥1000 is on) — **no fightMode byte** (`protocolgamesend.cpp:800-821`).
* schedules the first ping in `m_pingDelay` (1000 ms);
* starts a 1 s cycle that only drives a UI warning via `isConnectionOk()` (`game.cpp:1696`: last read < 5000 ms).

Extended opcodes: the server must send extended opcode 0 (`0x32 00 <string>`) before `sendExtendedOpcode()` will
transmit anything (`protocolgameparse.cpp:3986-3998`, `protocolgamesend.cpp:104-112`) — which is exactly why the
hwid frame above is hand-built instead of going through that helper.

---

## 7. Ping / pong

Values (`protocolcodes.h:62-63, 263-267`): `GameServerPingBack = 29 (0x1D)`, `GameServerPing = 30 (0x1E)`,
`ClientPing = 29 (0x1D)`, `ClientPingBack = 30 (0x1E)`, **`ClientPingBackGunz = 28 (0x1C)`**.

Routing (`protocolgameparse.cpp:117-125`):
```cpp
case GameServerPingBack: case GameServerPing:
  if ((opcode == GameServerPing && getFeature(GameClientPing)) ||
      (opcode == GameServerPingBack && !getFeature(GameClientPing))) parsePingBack(msg);
  else parsePing(msg);
```
`GameClientPing` is **on** at 1530, `GameExtendedClientPing` is **off**. Therefore:

* **Client → server ping:** opcode `0x1D`, empty body (`sendPing`, `protocolgamesend.cpp:258-267`;
  note it calls `Protocol::send(msg)` directly, which still applies the full framing).
* **Server → client `0x1E`** = pong for our ping → `parsePingBack` → `Game::processPingBack`
  (`game.cpp:254-269`): `++m_pingReceived`; if it matches `m_pingSent`, latency = `m_pingTimer.elapsed_millis()`,
  fire `onPingBack`; **reschedule the next ping in 1000 ms**.
* **Server → client `0x1D`** = server-initiated ping → `parsePing` → `Game::processPing` (`game.cpp:248-252`):
  fire `onPing` and reply with `sendPingBack()`.
* **`sendPingBack`** (`protocolgamesend.cpp:269-288`): `os in [60,62] && clientVersion >= 1200` ⇒ opcode **`0x1C` (28)**,
  otherwise `0x1E` (30). Gunzodus therefore gets `0x1C`.
* Cadence: first ping 1000 ms after game start; thereafter one ping per received pong.
  `Game::ping` (`game.cpp:1673-1684`) refuses to send while `m_pingReceived != m_pingSent`, so a lost pong stalls
  the pinger permanently until one arrives.
* The client never disconnects for a missing pong; it only shows a warning when nothing has been read for
  5000 ms (`game.cpp:1696`), and the socket read timeout is 30 s (`connection.h:36`). Whether **Gunzodus** drops
  a silent client is not observable from this tree.

---

## 8. Logout

`sendLogout` (`protocolgamesend.cpp:251-256`): a single byte, `Proto::ClientLeaveGame = 20 = 0x14`, no payload,
fully framed (sequence + padding + XTEA + compression header).

Callers (`game.cpp:645-669`):
* `Game::cancelLogin()` — sends 0x14 **even before the game has started**, then `processDisconnect()`;
* `Game::forceLogout()` — 0x14 + immediate local disconnect;
* `Game::safeLogout()` — 0x14 only, waits for the server to close/answer.

Server side of the teardown is `0x18` `GameServerSessionEnd` (`u8 reason`) and/or a plain TCP close.
There is no separate "logout ok" opcode.

---

## 9. Full sequence summary

```
HTTPS  POST https://www.gunzodus.net/game/login/1530   {"email","password","stayloggedin":true,"type":"login"}
       -> {"session":{"sessionkey",...},"playdata":{"worlds":[...],"characters":[...]}}

TCP    connect(worlds[c.worldid].externaladdressprotected, .externalportprotected)
  C->S "<worldName>\n"                        raw, unframed, unencrypted
  S->C 0x1F  u32 timestamp, u8 random, u8 ?   plain, framed (seq)
  C->S 0x0A  login packet (§4)                plain framing, RSA tail, seq 0   -> XTEA ON from here
  S->C 0x0A  (pending)                        XTEA
  C->S 0x0F  enter game                       XTEA + [00 00 00 00] hdr, seq 1
  C->S 0x32 0A <hwid string>                  XTEA + hdr, seq 2   (Gunz only)
  S->C 0x0B  string  (secondary conn id, optional)
  S->C 0x17  login success payload
  S->C 0x0F  enter game  -> processGameStart
  C->S 0xA0  chase, safe, pvp                 (fight modes, immediately)
  C->S 0x1D  ping every ~1s   <-  S->C 0x1E pong
       S->C 0x1D ping        ->   C->S 0x1C pong (Gunz)
  C->S 0x14  logout
```


## Pseudocode

-- =====================================================================
-- Pure-LuaJIT Gunzodus 1530 login. Requires: an LuaSocket/cqueues TCP
-- socket, an HTTPS client (or openssl s_client / luasec), a bignum
-- modpow, and bit ops (bit library in LuaJIT).
-- =====================================================================

local OS_ID            = 61          -- CLIENTOS_GUNZ_WINDOWS
local CLIENT_VERSION   = 1530
local PROTOCOL_VERSION = 1530
local CONTENT_REVISION = "42196"     -- decimal text of assets.json.sha256
local EXTENDED_DATA    = "261"
local RSA_N = "1246273883242314476756177697013661178426967215489621567086238956"
           .. "4747417434630052169619083393458028702016427835941419554951092542"
           .. "8212676699226328012721269908075137544578076908574898562097520735"
           .. "4492632921657223844817485386465803044527347500039275190952490002"
           .. "86367283230450217221784214070032637657596780069118601"
local RSA_E = 65537
local RSA_SIZE = 128

--------------------------------------------------------------------- 1
function httpLogin(email, password, token)
  local body = { '{"' }
  -- nlohmann emits keys ALPHABETICALLY, compact, no spaces:
  if token then
    body = string.format(
      '{"authenticatorToken":%q,"email":%q,"password":%q,"stayloggedin":true,"token":%q,"type":"login"}',
      token, email, password, token)
  else
    body = string.format(
      '{"email":%q,"password":%q,"stayloggedin":true,"type":"login"}', email, password)
  end
  local res = https_post{                     -- TLS verification is DISABLED upstream
    host = "www.gunzodus.net", port = 443, path = "/game/login/1530",
    verify_peer = false, verify_host = false,
    headers = { ["User-Agent"]="Mozilla/5.0", ["Content-Type"]="application/json",
                ["Accept"]="*/*", ["Connection"]="close" },
    body = body }
  assert(res.status == 200, "HTTP "..res.status)
  local j = json.decode(res.body)
  if j.errorCode and j.errorCode ~= 0 then error(j.errorMessage or "login failed") end  -- 6 == need 2FA
  assert(j.session and j.playdata and j.playdata.characters and j.playdata.worlds)
  local worlds = {}
  for _, w in ipairs(j.playdata.worlds) do
    worlds[w.id] = { name=w.name, host=w.externaladdressprotected, port=w.externalportprotected }
  end
  local chars = {}
  for i, c in ipairs(j.playdata.characters) do
    local w = worlds[c.worldid]
    chars[i] = { name=c.name, world=w.name, host=w.host, port=w.port, level=c.level }
  end
  return j.session.sessionkey, chars
end

--------------------------------------------------------------------- 2 framing
local Conn = {}          -- fields: sock, xtea (4 u32 or nil), seq = 0
function Conn:sendRaw(bytes) self.sock:send(bytes) end   -- world name path only

function Conn:send(body)                    -- body starts with the opcode byte
  if self.xtea then                         -- gunz compression header, INSIDE xtea, BEFORE opcode
    body = "\0\0\0\0" .. body
  end
  local pad = 8 - (#body % 8) - 1
  local region = string.char(pad) .. body .. string.rep("\0", pad)   -- multiple of 8
  if self.xtea then region = xtea_encrypt(region, self.xtea) end
  local frame = u16le((#region) / 8) .. u32le(self.seq) .. region
  self.seq = self.seq + 1
  self.sock:send(frame)
end

function Conn:recv()                        -- returns the decoded body (opcode first)
  local n    = readU16LE(self.sock:receive(2))
  local rest = self.sock:receive(n * 8 + 4)
  local seq  = readU32LE(rest:sub(1, 4))
  local compressed = bit.band(seq, 0x80000000) ~= 0
  local region = rest:sub(5)                              -- n*8 bytes
  if self.xtea then region = xtea_decrypt(region, self.xtea) end
  local pad  = region:byte(1)
  local body = region:sub(2, #region - pad)               -- drop pad byte + trailing pad
  if compressed then body = inflate_raw(body) end         -- inflateInit2(-15)
  return body
end

--------------------------------------------------------------------- 3 login
function loginWorld(host, port, worldName, charName, sessionKey)
  local c = setmetatable({ sock = tcp_connect(host, port), seq = 0 }, {__index=Conn})

  -- (a) the ONLY unframed write: world name + '\n', outside the encrypted stream
  c:sendRaw(worldName .. "\n")

  -- (b) challenge: the first inbound packet is PLAIN (xtea still nil)
  local msg = c:recv()
  assert(msg:byte(1) == 0x1F, "expected challenge")
  local ts   = readU32LE(msg:sub(2, 5))
  local rnd  = msg:byte(6)
  -- msg:byte(7) is skipped by the reference client at >=1405

  -- (c) login packet
  local xk = { rand32(), rand32(), rand32(), rand32() }
  local head = table.concat{
      string.char(0x0A),                     -- ClientPendingGame
      u16le(OS_ID),                          -- 61
      u16le(PROTOCOL_VERSION),               -- 1530
      u32le(CLIENT_VERSION),                 -- 1530   (GameClientVersion)
      addString(tostring(CLIENT_VERSION)),   -- "1530" (>=1281)
      addString(CONTENT_REVISION),           -- "42196" (>=1334, gunz branch)
      string.char(0x00) }                    -- preview state
  local rsa = table.concat{
      string.char(0x00),                     -- first RSA byte must be 0
      u32le(xk[1]), u32le(xk[2]), u32le(xk[3]), u32le(xk[4]),
      string.char(0x00),                     -- is gm
      addString(sessionKey),                 -- GameSessionKey branch
      addString(charName),
      u32le(ts), string.char(rnd),           -- challenge echo
      u16le(2),                              -- gunz-only marker
      addString(EXTENDED_DATA) }             -- "261"
  assert(#rsa <= RSA_SIZE, "session key + char name too long")
  rsa = rsa .. string.rep("\0", RSA_SIZE - #rsa)
  rsa = rsa_raw_encrypt(rsa, RSA_N, RSA_E)   -- textbook: big-endian m^e mod n, 128 bytes out

  c:send(head .. rsa)                        -- seq 0, NOT xtea encrypted
  c.xtea = xk                                -- everything from now on is encrypted, both ways

  -- (d) pending / enter game
  local started = false
  while true do
    local m, p = c:recv(), 1
    while p <= #m do
      local op = m:byte(p); p = p + 1
      if op == 0x0A then                            -- pending game, no payload
        c:send(string.char(0x0F))                   -- enter game
        c:send(string.char(0x32, 10) .. addString(hwid(accountName)))  -- gunz hwid
      elseif op == 0x0B then                        -- >=1200: string, ignore
        local len = readU16LE(m:sub(p, p+1)); p = p + 2 + len
      elseif op == 0x17 then                        -- login success
        local playerId = readU32LE(m:sub(p, p+3)); p = p + 4
        local beat     = readU16LE(m:sub(p, p+1)); p = p + 2
        for _ = 1, 3 do p = p + 5 end               -- speedA/B/C: u8 precision + u32
        p = p + 1                                   -- >=1054 pvp frame
        p = p + 1                                   -- >=1058 expert pvp
        local url; url, p = getString(m, p)         -- store url
        p = p + 2                                   -- coins packet size
        p = p + 1                                   -- >=1281 exiva  (NO tournament byte at 1530)
      elseif op == 0x0F then                        -- enter game -> we are IN GAME
        if not started then
          started = true
          c:send(string.char(0xA0, chase, safe, pvp))   -- GameTacticsWithoutFightMode layout
          schedule(1000, function() ping(c) end)
        end
      elseif op == 0x1D then c:send(string.char(0x1C))  -- server ping -> gunz pong
      elseif op == 0x1E then pongReceived(c)            -- our pong -> reschedule ping in 1000ms
      elseif op == 0x14 then error(getString(m, p))     -- login error (+u8 reason if >=1523)
      elseif op == 0x16 then local s; s,p = getString(m,p); local t = m:byte(p); p=p+1  -- login wait
      elseif op == 0x18 then p = p + 1                  -- session end (u8 reason)
      else  parseGameOpcode(op, m, p) end
    end
  end
end

function ping(c) c:send(string.char(0x1D)) end          -- only while pingSent == pingReceived
function logout(c) c:send(string.char(0x14)) end

-- helpers
function addString(s) return u16le(#s) .. s end
function hwid(acc)                                       -- FNV-1a 32, seeded by account name
  local h = 2166136261
  for i = 1, #acc do h = bit.band((bit.bxor(h, acc:byte(i))) * 16777619, 0xFFFFFFFF) end
  return string.format("%04X-%04X", bit.rshift(h,16), bit.band(h,0xFFFF))
end

## Evidence
- D:/Claude/otclient_mehah1530/otclient/init.lua:81-89 — Servers_init: key is the URL "https://www.gunzodus.net/game/login/1530", port 443, protocol 1530, httpLogin=true, useAuthenticator=true
- D:/Claude/otclient_mehah1530/otclient/init.lua:7-26 — Services table (status endpoint, clientAssets=false so the local 42196 revision is never overwritten)
- D:/Claude/otclient_mehah1530/otclient/modules/client_entergame/entergame.lua:1271-1294 — URL is split into host/path; port defaults 443 for https
- D:/Claude/otclient_mehah1530/otclient/modules/client_entergame/entergame.lua:1300 — http:httpLogin(host, path, port, account, password, requestId, httpLogin, token)
- D:/Claude/otclient_mehah1530/otclient/modules/client_entergame/entergame.lua:1443-1446 — clientVersion>=1281 and port~=7171 selects the HTTP login path
- D:/Claude/otclient_mehah1530/otclient/modules/client_entergame/entergame.lua:1339-1387 — loginSuccess: world fields externaladdressprotected/externalportprotected/name, character fields, G.sessionKey = session.sessionkey
- D:/Claude/otclient_mehah1530/otclient/modules/client_entergame/entergame.lua:38-55 — errorCode 6 triggers the authenticator-token dialog
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/httplogin.cpp:403-428 — SSLClient, cert+hostname verification DISABLED, JSON body keys, User-Agent: Mozilla/5.0, Post(path, headers, body.dump(), "application/json")
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/httplogin.cpp:255-259 — HTTPS first; plain-HTTP retry only when the server entry sets httpLogin=true
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/httplogin.cpp:494-528 — parseJsonResponse: errorCode!=0 fails; requires session + playdata{characters,worlds}; stores them as serialized strings
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/httplogin.cpp:261-267 — success dispatches EnterGame.loginSuccess(request_id, session, worlds, characters)
- D:/Claude/otclient_mehah1530/otclient/build/win-local/vcpkg_installed/x64-windows-static-release/include/httplib.h:12936-12979 — httplib default headers: Host, Accept: */*, Accept-Encoding, User-Agent, Content-Type, Content-Length
- D:/Claude/otclient_mehah1530/otclient/build/win-local/vcpkg_installed/x64-windows-static-release/share/httplib/httplibTargets.cmake:61 — BROTLI=TRUE, ZLIB/ZSTD off => Accept-Encoding: br
- D:/Claude/otclient_mehah1530/otclient/modules/client_entergame/characterlist.lua:427-428 — g_game.loginWorld(account, password, worldName, worldHost, worldPort, characterName, token, sessionKey)
- D:/Claude/otclient_mehah1530/otclient/modules/client_entergame/characterlist.lua:881-882 — widget.worldHost = characterInfo.worldIp
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:597-619 — Game::loginWorld sets m_worldName/m_characterName and calls ProtocolGame::login
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgame.cpp:27-43 — ProtocolGame::login stores sessionKey/characterName then connect(host, port)
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:422-433 — onConnect writes worldName + '\n' with send(msg, /*raw=*/true) and calls enabledSequencedPackets() at >=1200
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgame.cpp:45-59 — onConnect: enableChecksum when GameProtocolChecksum; sendLoginPacket skipped because GameChallengeOnLogin is on; recv()
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgame.cpp:61-82 — first received packet consumes one u8 padding byte at clientVersion>=1405
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:133-171 — send pipeline: gunz compression header (xtea && os in [60,62]) -> writePaddingAmount -> xteaEncrypt -> writeSequence -> writeHeaderSize
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:190-215 — recv header size = 2 + 4(checksum) + 1(>=1405) = 7
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:217-238 — remainingSize = readSize() * 8 + 4 at >=1405
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:250-270 — sequenced path reads u32 and takes bit31 as the compression flag; checksum is never verified
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:365-397 — xteaDecrypt; at >=1405 reads padding byte and trims the message
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/protocol.cpp:399-420 — xteaEncrypt (no size prefix at >=1405)
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:29,151-181 — maxHeaderSize 7 at >=1405; writePaddingAmount; writeHeaderSize = (size-4)/8; prependCompressionHeader inserts [mode][0][0][0] forward
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:84-94 — addString = u16 LE length + raw bytes
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/outputmessage.cpp:115-123 — encryptRsa encrypts the LAST rsaGetSize() bytes in place
- D:/Claude/otclient_mehah1530/otclient/src/framework/util/crypt.cpp:235-259 — RSA_public_encrypt with RSA_NO_PADDING (textbook, big-endian)
- D:/Claude/otclient_mehah1530/otclient/src/framework/util/crypt.cpp:289-297 — rsaGetSize() = RSA_size = 128 for the 1024-bit modulus
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:115-152 — login packet prefix: 0x0A, u16 os, u16 protocol, u32 clientVersion, addString("1530"), content revision, preview byte; offset captured
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:65-98 — resolveGunzContentRevision: probes assets/ then things/<ver>/assets.json.sha256, trims, parses u32, requires 1..0xFFFF
- D:/Claude/otclient_mehah1530/otclient/data/things/1530/assets.json.sha256 — exactly 5 bytes "42196", no trailing newline (verified with od -c / wc -c)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:153-209 — RSA block: 0x00, 4x u32 xtea, isGM 0x00, sessionKey, characterName, u32 timestamp, u8 random, u16(2) gunz marker, addString("261"), zero pad to 128
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:212-224 — encryptRsa; send; THEN enableXteaEncryption() and enabledSequencedPackets()
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:227-249 — sendEnterGame: 0x0F then, for os in [60,62], a hand-built [0x32][0x0A][string hwid] frame
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:47-57 — hwid = FNV-1a-32 over the account name formatted "%04X-%04X"
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:251-288 — sendLogout = 0x14; sendPing = 0x1D (GameExtendedClientPing off); sendPingBack = 0x1C for os 60-62 at >=1200 else 0x1E
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgamesend.cpp:800-821 — sendChangeFightModes: 0xA0 + chase + safe + pvp when GameTacticsWithoutFightMode (>=1525)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:49-64 — GameServerLoginOrPendingState=10, GMActions=11, EnterGame=15, UpdateNeeded=17, LoginError=20, LoginAdvice=21, LoginWait=22, LoginSuccess=23, SessionEnd=24, PingBack=29, Ping=30, Challenge=31
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolcodes.h:259-276,340 — ClientPendingGame=10, ClientEnterGame=15, ClientLeaveGame=20, ClientPing=29, ClientPingBack=30, ClientPingBackGunz=28, ClientExtendedOpcode=50, ClientChangeFightModes=160
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:74-128 — dispatch: 0x0A -> parsePendingGame (GameLoginPending on), 0x17 -> parseLogin, ping routing, 0x1F -> parseLoginChallenge
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1420-1430 — parseLoginChallenge: u32 timestamp, u8 random, skipBytes(1) at >=1405, then sendLoginPacket
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:744-792 — parseLogin (0x17) field order at 1530
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:832-847 — parsePendingGame / parseEnterGame both have empty payloads
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1358-1363 — parseGMActions reads a string and returns at clientVersion >= 1200
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:1388-1415 — parseLoginError (+u8 reason at >=1523), parseLoginAdvice, parseLoginWait (string + u8), parseSessionEnd (u8)
- D:/Claude/otclient_mehah1530/otclient/src/client/protocolgameparse.cpp:3986-3998 — extended opcode 0 enables sendExtendedOpcode; extended opcode 2 is treated as a pong
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:153-158 — processPendingGame calls m_protocolGame->sendEnterGame() immediately
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:168-191 — processGameStart: sendChangeFightModes, schedule first ping at m_pingDelay
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:248-269,1673-1684 — processPing -> sendPingBack; processPingBack -> reschedule; ping() refuses while pingSent != pingReceived
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:645-669 — cancelLogin/forceLogout/safeLogout all emit sendLogout (0x14)
- D:/Claude/otclient_mehah1530/otclient/src/client/game.h:534 — m_pingDelay default 1000 ms; game.cpp:1696 isConnectionOk = last read < 5000 ms; connection.h:36 READ_TIMEOUT = 30 s
- D:/Claude/otclient_mehah1530/otclient/src/client/game.cpp:1793-1805 — getOs() returns m_clientCustomOs when > CLIENTOS_NONE
- D:/Claude/otclient_mehah1530/otclient/src/client/const.h:38-40 — CLIENTOS_GUNZ_LINUX/WINDOWS/MAC = 60/61/62
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:295-306 — the 1530 block: g_game.setRsa(GUNZODUS_RSA); g_game.setCustomOs(61)
- D:/Claude/otclient_mehah1530/otclient/modules/game_features/features.lua:28,45-52,90,107-113,165-174,197-231,240-292 — every flag that gates a login byte at 1530
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/const.lua:326-333 — GUNZODUS_RSA 1024-bit decimal modulus, exponent 65537
- D:/Claude/otclient_mehah1530/otclient/modules/gamelib/game.lua:19-48,91-104 — chooseRsa early-returns once GUNZODUS_RSA is installed; setRsa default e=65537; getClientProtocolVersion(1530) == 1530
- D:/Claude/otclient_mehah1530/otclient/src/client/thingtypemanager.cpp:171-175 — non-gunz branch: getAssetIdentifier is the RAW contents of assets.json.sha256 (fallback "appearancesHash")
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/inputmessage.cpp:92-106 — getString = u16 length + bytes; getDouble = u8 precision + u32 (value - INT_MAX) / 10^precision
- D:/Claude/otclient_mehah1530/otclient/src/framework/net/connection.cpp:145-168 — writes are coalesced through a 0 ms delayed-write timer, so consecutive sends can share one TCP segment

## Pitfalls
- clientVersion 1530 is >= 1405, so the ENTIRE 1405 framing path applies. The frame is [u16 blockCount][u32 sequence][u8 paddingAmount][body][zero pad] and blockCount = (1 + len(body) + pad) / 8, NOT a byte count. Implementing the classic [u16 size][u32 checksum][u16 plainSize] OTServ framing will fail immediately.
- The padding-amount byte lives INSIDE the XTEA-encrypted region (it is the first byte of it), not in the clear header. On the single unencrypted packet (the challenge) it is consumed by the m_firstRecv branch instead.
- Incoming headerSize is 2+4+1=7 only because GameProtocolChecksum is enabled; the 4 reserved bytes are actually the SEQUENCE, and the checksum is never validated (the sequenced branch wins in internalRecvData). Outgoing packets carry a sequence, never an adler32.
- Sequence numbering starts at 0 with the LOGIN packet, because Protocol::onConnect calls enabledSequencedPackets() before it. The raw world-name write is send(msg, raw=true) and does NOT consume a sequence number or get framed at all.
- The world name + '\n' is written before anything else, unframed and unencrypted. Forgetting it (or framing it) makes the server drop the connection with no error packet.
- XTEA is enabled AFTER the login packet is sent. The login packet is plaintext apart from its 128-byte RSA tail; every subsequent packet in BOTH directions is encrypted, so the challenge is the only plaintext inbound packet.
- For OS 60-62 every outgoing packet after XTEA is on gets a [mode=0][0][0][0] prefix INSIDE the encrypted region, ahead of the opcode. Omitting it shifts every packet by 4 bytes: login and pings still appear to work, so the bug looks like 'actions are silently ignored'.
- Nothing is appended after the RSA block. The challenge timestamp/random, the gunz u16(2) marker and the "261" extended-data string are all inside the 128 encrypted bytes, before the zero padding.
- RSA is textbook (RSA_NO_PADDING): big-endian interpretation of exactly 128 bytes, c = m^65537 mod n, output left-zero-padded to 128. Do not use PKCS#1.
- len(sessionKey) + len(characterName) must be <= 94 or the RSA block overflows (the reference asserts on negative paddingBytes).
- The authenticator token is sent ONLY in the HTTPS JSON body (as both "token" and "authenticatorToken"). It is never sent on the game socket, because GameSessionKey selects the sessionKey/characterName branch.
- nlohmann::json serialises object keys in lexicographic order and compact (dump() with no indent in loginHttpsJson). If you are matching bytes, emit authenticatorToken, email, password, stayloggedin, token, type in that order. Note the dead startHttpLogin() uses dump(1) - do not copy it.
- stayloggedin is a JSON boolean true, not the string "true" and not the stayLoggedBox state (setUniqueServer forces that checkbox off for Gunzodus anyway).
- The reference client disables TLS certificate AND hostname verification for the login POST. A strict TLS client may fail where the reference succeeds.
- The 'httpLogin = true' flag does NOT mean plaintext: TLS is always tried first, and the flag only permits a plain-HTTP retry (to the same port 443, which cannot work in practice).
- Content revision must be the decimal TEXT "42196" as a length-prefixed string, not a u16, not a sha256 hex string. The u16 GameContentRevision branch and the getAssetIdentifier branch are both unreachable for OS 60-62 at >= 1334.
- Opcode 0x0A means PENDING GAME (payload-free) at 1530, not login-success, because GameLoginPending is on. Login-success is 0x17. Enter-game 0x0F is used in BOTH directions with the same value.
- 0x0B from the server at >= 1200 is a length-prefixed STRING (secondary connection identifier), not the legacy 20/23/32-byte GM action array.
- Ping naming is inverted relative to the constants: with GameClientPing on, server 0x1E is the pong to our 0x1D ping, and server 0x1D is a server-initiated ping that must be answered with 0x1C (gunz) rather than 0x1E.
- Game::ping() refuses to send a new ping while pingSent != pingReceived, so a single dropped pong stalls the keepalive forever - a Lua reimplementation should time out and resend rather than copying this.
- parseLogin (0x17) at 1530 has NO canReportBugs byte (GameDynamicBugReporter is on at >=1320) and NO tournament byte (GameTournamentPackets is disabled at >=1314). Copying an older 12.x parser desynchronises the rest of the packet.
- parseLoginError at clientVersion >= 1523 may carry a trailing u8 reason after the string, but only if unread bytes remain - read it conditionally.
- Incoming packets may be zlib-compressed: bit 31 of the sequence u32 is the flag, and the stream is RAW deflate (inflateInit2 window -15), with a per-packet mode and a stream mode that appends a 00 00 FF FF footer.
- One TCP read can contain several packets and one packet can contain several opcodes back to back - parseMessage loops until eof on the trimmed body.

## Open questions
- What is the extra byte the client skips in the challenge at clientVersion >= 1405 (protocolgameparse.cpp:1425-1427)? Its value and meaning are not read anywhere.
- What does the Gunz-only u16(2) inside the RSA block encode (protocolgamesend.cpp:188-192)? The in-tree comment explicitly marks the meaning as UNVERIFIED.
- What is "261" (the substituted login extended data, protocolgamesend.cpp:201-202)? It is a literal lifted from gunzotc (dword_140DF6A34); whether Gunzodus validates it, and whether it must change per build, is unknown.
- Does Gunzodus actually require the post-enter-game [0x32][0x0A][hwid] frame, and does it validate the fingerprint? The in-tree comment says UNVERIFIED; this client also substitutes an FNV-1a hash of the account name for gunzotc's real volume serial, so the value is definitely not what the original client sends.
- Is 0x1C really accepted as the pong opcode by Gunzodus (protocolgamesend.cpp:273-285 marks it UNVERIFIED)? If pings fail, 0x1E is the fallback to try.
- Does the server disconnect a client that stops pinging, and after how long? Nothing in this tree answers that; the client only warns after 5 s of silence and has a 30 s socket read timeout.
- Exact set of HTTP request headers depends on the vcpkg httplib build (Accept-Encoding: br here). Whether Gunzodus' login endpoint cares about any of Accept, Accept-Encoding or Connection is untested.
- Full shape of the login JSON response beyond the fields the client reads (extra session/world/character keys, and what values previewstate/pvptype take) is unknown - only the consumed subset is documented here.
- Whether the outbound compression header's mode byte can ever be non-zero: the in-tree analysis (protocol.h:113-125) argues it is provably 0 for every reachable input, but that is a static argument, not an observation.
- Whether the server ever compresses inbound packets in practice (bit 31 of the sequence), and if so which of the two zlib modes it uses.
- The login packet's exact byte count depends on len(sessionKey); the worked example (151-byte body, blockCount 19) assumes a session key short enough to fit - confirm against a real capture.

## VERIFIER (confidence 0.87)

### Corrections (AUTHORITATIVE — these override the spec above)
- **Claim**: PSEUDOCODE `hwid()`: `h = bit.band((bit.bxor(h, acc:byte(i))) * 16777619, 0xFFFFFFFF)` implements FNV-1a-32.
  - **Correction**: This produces the WRONG string on LuaJIT and therefore wrong bytes in the [0x32][0x0A][string] frame. `h` can be up to 2^32-1 and 16777619 is ~2^24, so the product reaches ~2^56, well past the 2^53 exact-integer range of a double; the low bits are rounded away before `bit.band` ever sees them. The multiply must be done in 32-bit pieces, e.g. `h = bit.band(bit.bxor(h,c),0xFFFFFFFF); local lo=bit.band(h,0xFFFF); local hi=bit.rshift(h,16); h = bit.band(lo*16777619 + bit.lshift(bit.band(hi*16777619,0xFFFF),16), 0xFFFFFFFF)`. The spec prose (FNV-1a-32 over the account name, `"{:04X}-{:04X}"` of h>>16 and h&0xFFFF, always a 9-char string) is correct — only the Lua is broken.
  - Evidence: src/client/protocolgamesend.cpp:47-57 — `uint32_t h = 2166136261u; for (const auto c : accountName) { h ^= static_cast<uint8_t>(c); h *= 16777619u; } return fmt::format("{:04X}-{:04X}", h >> 16, h & 0xFFFF);` (32-bit wraparound is load-bearing).
- **Claim**: SPEC §3: "Body length 7 → padAmount = 0, so the whole frame is ... wire = `01 00 | <u32 seq> | 00 | 1F tt tt tt tt rr xx` (14 bytes)."
  - **Correction**: State this as an inference, not a fact. Nothing in this tree fixes the server's padding; what the client actually *requires* is: exactly one pad byte at offset 6, and — because the plaintext first packet is never trimmed — padAmount must be 0 or the parse desynchronises (see additions). The derivation is consistent (n=1 ⇒ remaining = 1*8+4 = 12 ⇒ 14 total), but it is a prediction about the server. Also, the sentence contains leftover editing debris: "the whole frame is `[19?]` no — `blockCount = (1+7+0)/8 = 1`" should be deleted.
  - Evidence: src/framework/net/protocol.cpp:217-238 (`remainingSize = readSize() * 8U + 4U`) and src/client/protocolgame.cpp:66-71 (`if (m_firstRecv) { ... if (clientVersion >= 1405) inputMessage->getU8(); }` — one byte consumed, no trim).
- **Claim**: SPEC §0 feature table, row `GameProtocolChecksum`: "Effect on login: `enableChecksum()` → incoming header size becomes 7".
  - **Correction**: Conflates two independent terms. `headerSize = 2 (+4 if m_checksumEnabled) (+1 if clientVersion >= 1405, else +2 if xtea enabled)`. Checksum contributes +4; the +1 comes from the 1405 gate, not from the checksum. Also worth noting `enableChecksum()` is executed twice on the login path (once in ProtocolGame::onConnect, once inside sendLoginPacket) — it is idempotent.
  - Evidence: src/framework/net/protocol.cpp:196-205 — `int headerSize = 2; if (m_checksumEnabled) headerSize += 4; if (g_game.getClientVersion() >= 1405) { headerSize += 1; } else if (m_xteaEncryptionEnabled) { headerSize += 2; }`; src/client/protocolgame.cpp:53-54 and src/client/protocolgamesend.cpp:215-216.
- **Claim**: SPEC §0: "Checksum algorithm | adler32 ... | `math.cpp:39-44`".
  - **Correction**: Path is wrong: the file is `src/framework/stdext/math.cpp:39-44`. There is no `src/framework/util/math.cpp`. The claim itself (zlib adler32, and unused outgoing because the sequenced branch wins) is right.
  - Evidence: src/framework/stdext/math.cpp:39-44 — `uint32_t computeChecksum(std::span<const uint8_t> data) noexcept { ... return ::adler32(::adler32(0L, Z_NULL, 0), ...); }`; src/framework/net/protocol.cpp:158-163 — `if (m_sequencedPackets) { writeSequence } else if (m_checksumEnabled) { writeChecksum }`.
- **Claim**: SPEC §7: "`Game::ping` refuses to send while `m_pingReceived != m_pingSent`, so a lost pong stalls the pinger permanently until one arrives."
  - **Correction**: Understated. The ping timer is rescheduled ONLY inside `Game::processPingBack`, which runs only when a pong actually arrives. If a pong is lost there is no pending event at all, so the client never pings again — there is no retry, no timeout, and no later recovery unless the server spontaneously sends 0x1E. (The `m_pingReceived != m_pingSent` guard in `Game::ping` is a second, separate suppression.)
  - Evidence: src/client/game.cpp:255-269 — `void Game::processPingBack() { ++m_pingReceived; ... m_pingEvent = g_dispatcher.scheduleEvent([] { g_game.ping(); }, m_pingDelay); }` — the only rescheduler after the initial one at game.cpp:176-178.
- **Claim**: PSEUDOCODE `httpLogin`: JSON body built with Lua `%q` for `email`/`password`/`token`.
  - **Correction**: `%q` is Lua quoting, not JSON quoting: it emits a backslash followed by a real newline for `\n`, `\0` (not ` `) for NUL, and leaves other control characters raw — producing a body that differs byte-for-byte from `nlohmann::json::dump()` whenever a credential contains such a character. Use a JSON encoder (or escape `"`, `\`, and U+0000–U+001F as `\uXXXX`). The key set, key order (lexicographic: authenticatorToken, email, password, stayloggedin, token, type), compactness and `stayloggedin` being a bare boolean are all correct.
  - Evidence: src/framework/net/httplogin.cpp:413-428 — `json body = {{"email",email},{"password",password},{"stayloggedin",true},{"type","login"}}; if (!token.empty()) { body["token"]=token; body["authenticatorToken"]=token; } ... client.Post(path, headers, body.dump(), "application/json");`

### Additions
- VERIFIED CORRECT (spot-checked line by line, no wire-level error found): every feature-flag gate and its line number in modules/game_features/features.lua (770→28 GameLoginPacketEncryption, 840→45/46, 841→51/52, 953→90 GameClientPing, 980→107/108, 981→112/113, 1000→123 GamePVPMode, 1071→165, 1072→169, 1074→173, 1080→177 GameIngameStore, 1200→200 GameTournamentPackets, 1290→225 GameSequencedPackets, 1314→241 disable Tournament, 1320→252 GameDynamicBugReporter, 1525→292 GameTacticsWithoutFightMode, 1530→304/305 setRsa(GUNZODUS_RSA)+setCustomOs(61)); GameExtendedClientPing is never enabled anywhere (only 3 read sites, no enableFeature); protocolVersion==1530 (game.lua:91-104 has no 1530 entry); 1530 is in supportedClients (game.lua:64). Login-packet layout §4.1/§4.2 byte-for-byte including offset=23, the 34+S+C RSA fill and the S+C<=94 constraint; frame math §2.1 and the 158-byte total in §4.3; recv framing §2.2; parseLogin field order §6; ping/pong opcodes and the 0x1C Gunz pong; sendChangeFightModes layout; sendLogout and its three callers; the HTTPS request (SSLClient, verification disabled, User-Agent, ci-sorted header set incl. `Accept-Encoding: br` from CPPHTTPLIB_BROTLI_SUPPORT=TRUE, `Host: www.gunzodus.net` with :443 omitted for TLS, `Connection: close` from the non-keepalive path at httplib.h:13572-13577); parseJsonResponse and the errorCode-6 path; loginSuccess field names; the content-revision file is exactly 5 bytes `42196` with no newline and `data/assets/assets.json.sha256` does not exist, so the Gunz branch yields 42196; GUNZODUS_RSA in const.lua:329-333 matches the pseudocode's RSA_N digit for digit (309 digits) with e=65537.
- MISSING — the first (plaintext) inbound packet is NOT trimmed by the reference client. `ProtocolGame::onRecv` (src/client/protocolgame.cpp:64-71) only does `inputMessage->getU8();` for the pad byte; it never calls `setMessageSize`. So for the challenge the message still spans headerSize + n*8 - 1 bytes and `parseMessage` will keep looping past the body, reading trailing pad bytes as opcode 0x00, if padAmount != 0. Trimming happens only inside `xteaDecrypt` (protocol.cpp:381-386: `decryptedSize = encryptedSize - paddingSize - 1; setMessageSize(getHeaderSize() + decryptedSize)`), i.e. from the second inbound packet onward. The pseudocode's `Conn:recv` trims unconditionally, which is *safer* than the reference — keep it, but the spec should say the divergence exists and is masked only because the challenge's padAmount is 0.
- MISSING — `internalRecvHeader` rejects the packet outright (logs `invalid packet size` and drops the read, leaving the connection hung) when `remainingSize == 0 || remainingSize > 65535`. A reimplementation should apply the same clamp so an oversized/garbage length is not treated as a legitimate read. src/framework/net/protocol.cpp:227-232.
- MISSING — `Protocol::xteaEncrypt` still tops the buffer up to a multiple of 8 (`if ((encryptedSize % 8) != 0) { addPaddingBytes(8 - encryptedSize % 8); }`, protocol.cpp:405-410). At >=1405 this is dead because `writePaddingAmount()` already made the size a multiple of 8, but it is a silent divergence if anyone ever omits the pad byte. src/framework/net/protocol.cpp:399-420.
- MISSING — `Game::loginWorld` assigns `m_worldName` AFTER calling `m_protocolGame->login(...)` → `Protocol::connect()` (src/client/game.cpp:617-619: `m_protocolGame->login(...); m_characterName = characterName; m_worldName = worldName;`). This is only safe because asio's connect is asynchronous, so `Protocol::onConnect` — which reads `g_game.getWorldName()` for the very first bytes on the socket — runs later. A synchronous Lua port must set the world name before connecting, or the first write will be just `"\n"`.
- MISSING — inbound extended opcode 2 is treated as a pong unconditionally, independent of GameExtendedClientPing: `parseExtendedOpcode` does `if (opcode == 0) m_enableSendExtendedOpcode = true; else if (opcode == 2) parsePingBack(msg);` (src/client/protocolgameparse.cpp:3988-3997). So a server 0x32 0x02 <string> also drives the ping bookkeeping. Note also that `getString()` is read before the dispatch, so the string is consumed even for opcodes 0 and 2.
- MISSING — no Lua `ProtocolGame:onConnect` handler exists in this tree (`callLuaField("onConnect")` at protocol.cpp:432 hits nothing) and no module calls `ProtocolGame.registerOpcode` for any login opcode (only the generic plumbing in modules/gamelib/protocolgame.lua and modules/modulelib/controller.lua). Confirms the spec's implicit claim that nothing extra is written on connect and nothing intercepts 0x0A/0x0F/0x17/0x1D/0x1E before the C++ dispatch.
- CONFIRMED, worth stating explicitly — RSA is the OpenSSL path, not GMP: `USE_GMP` is never defined in any CMakeLists in this tree (only the `#ifdef` sites in src/framework/util/crypt.{h,cpp}). So `rsaEncrypt` is `RSA_public_encrypt(size, msg, msg, m_rsa, RSA_NO_PADDING)` (crypt.cpp:257) and `rsaGetSize()` is `RSA_size(m_rsa)` = 128 (crypt.cpp:289-297), i.e. exactly the textbook big-endian m^65537 mod n the spec describes. (Had USE_GMP been on, the GMP branch at crypt.cpp:240-252 would misbehave: it sizes the output from `mpz_sizeinbase(m,...)` — the plaintext — rather than `c`, so it would misplace and overrun the ciphertext.)
- MINOR, reference-code bug not spec bug — `EnterGame.loginSuccess` builds `worlds[id] = { ..., previewState = world.previewstate == 1, ... }` (entergame.lua:1339-1347) and then reads `previewState = world.previewstate` when filling each character (entergame.lua:1358), which is always nil because the rebuilt table uses the camel-cased key. Display-only; no effect on any byte sent.
- MINOR — `OutputMessage::prependU8`/`prependU16` decrement `m_writePos` as well as `m_headerPos` (outputmessage.cpp:194-209), so after `writePaddingAmount` + `writeHeaderSize` the write cursor sits 3 bytes below the real end of data. Harmless because the socket write uses `getHeaderBuffer()` + `getMessageSize()` (protocol.cpp:180-181) and `encryptRsa` (which does use `m_writePos`) runs earlier — but do not port the pointer arithmetic literally.
- MINOR — the pseudocode's opcode loop omits 0x11 GameServerUpdateNeeded (`string signature`) and 0x15 GameServerLoginAdvice (`string message`); both can arrive instead of 0x0A and both must be consumed to stay in sync. The spec's §6 error table lists them correctly.
- MINOR — the pseudocode's HTTP call omits `Host` and `Accept-Encoding` from its header table; the spec §1.2 request dump is the authoritative one. Also `u16le(#region / 8)` relies on Lua float division producing an exact integer — fine here, but floor it explicitly.
