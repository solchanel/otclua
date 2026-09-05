# luaclient

A standalone **LuaJIT** worker client for **Gunzodus** (Tibia protocol **1530**, client OS id **61**).

No otclient at runtime, no C++, no OpenGL, no audio, no external Lua modules — one LuaJIT
interpreter, FFI for the Windows APIs, and the pure-Lua protocol stack in this directory.
It logs in over HTTPS, connects to the game world, completes the login handshake, keeps the
session alive and parses every server packet into a game state plus an event bus.

The byte-level truth for every wire detail lives in [`docs/`](docs/); the module contract every
file is written against is [`API.md`](API.md). In each doc the **`## VERIFIER (Corrections)`
section overrides the spec body above it**.

---

## Running it

```
run.bat --account=you@example.com --password=... --character="Your Char"
```

`run.bat` just locates LuaJIT and runs `main.lua`; set `LUACLIENT_LUAJIT` to use a different
interpreter. Equivalent direct invocation:

```
"D:\Claude\otclient_mehah1530\otclient\build\win-local\vcpkg_installed\x64-windows-static-release\tools\luajit\luajit.exe" main.lua --account=... --password=...
```

### Flags

| Flag | Meaning |
|---|---|
| `--account=EMAIL` | account (email) for the HTTPS login |
| `--password=PASS` | account password — never logged, dropped from memory after the POST |
| `--token=DIGITS` | authenticator token (needed when the server answers `errorCode 6`) |
| `--character=NAME` | which character to enter with (default: the first one) |
| `--world=NAME` | restrict the character choice to one world |
| `--host=HOST[:PORT]`, `--port=N` | override the game address from the login reply |
| `--session-key=KEY` | skip the HTTPS login and reuse a session key (needs `--character` and `--host`) |
| `--assets=DIR` | directory (or file) holding `items1530.bin` — default `./assets` |
| `--content-revision=N` | override the content revision string in the login packet |
| `--log-level=LEVEL` | `debug` \| `info` \| `warn` \| `error` (default `info`) |
| `--log-file=PATH` | append every log line to a file as well (flushed per line) |
| `--capture=PATH` | append every inbound payload as a `.cam` `<` record (replayable) |
| `--ping=MS` | keepalive interval, default `10000` |
| `--dry-run` | offline wiring check: no sockets, no HTTPS |
| `--selftest` | run `test/selftest.lua` and exit with its status |
| `--replay=FILE` | run `test/replay.lua` over a capture and exit |
| `-h`, `--help` | flag list |

Exit codes: **0** ok / normal end of session · **1** usage or configuration error ·
**2** the login server refused the account · **3** protocol or runtime failure.

### Boot sequence

```
flags -> package.path -> items1530.bin -> HTTPS login -> pick world + character
      -> transport.new{worldName=...} (world name set BEFORE connect)
      -> connect  ->  raw "<world>\n" preamble
      -> 0x1F challenge  ->  login packet (sequence 0, XTEA still OFF)  ->  XTEA on
      -> 0x0A pending    ->  two SEPARATE enter-game frames (sequences 1 and 2)
      -> 0x0F / 0x17     ->  arm the 10 s keepalive ping
      -> sched.run() parse loop, status line on every hp/mana/level/pos change
```

Ping rules at 1530 (`GameClientPing` ON, so the classic mapping is inverted): server **0x1E** is
the *pong* for our ping (latency sample only); server **0x1D** is a ping *request* that we answer
immediately with opcode **28** (`ClientPingBackGunz`, because the OS is 61 and cv ≥ 1200); our own
keepalive is opcode **29** every 10 s.

---

## Tests

```
luajit test/selftest.lua        # or: luajit main.lua --selftest
luajit test/replay.lua          # synthesises a 1530 capture and replays it
luajit test/replay.lua FILE...  # replays real captures (.cam or .lcap)
luajit main.lua --dry-run       # end-to-end wiring, offline
```

`test/selftest.lua` runs 255 assertions across 16 suites (crypto vectors cross-checked against
Python/zlib, buffer round-trips, framing round-trips including byte-at-a-time chunked delivery,
hwid, item lookups, the 11-thing tile trim, the event bus, parser packet fixtures, a real
127.0.0.1 socket + scheduler round trip, and the whole offline boot sequence). It prints a
PASS/FAIL line per module and exits non-zero on any failure.

`test/replay.lua` reads a capture and asserts the parser consumes **every byte of every message**,
printing an opcode histogram. Two formats are understood:

* **`.cam`** — the OTClient `PacketRecorder` text format (`docs/offline-testbench.md` §1):
  `dir SP timeMs SP lowercase-hex`, `<` inbound / `>` outbound, CRLF or LF. Inbound payloads are
  already de-framed, decrypted, decompressed and de-padded, so byte 1 is a game opcode.
  `main.lua --capture=FILE` writes exactly this, so a live session can be replayed offline.
* **`.lcap`** — the length-prefixed binary format this repo also writes:
  `"LCAP" u8 version(1)` then records of `u8 dir, u32 LE timeMs, u32 LE length, length bytes`.

There is **no 1530 recording checked in** (the sample shipped with otclient is protocol 1098 and
would legitimately desync this parser), so `test/replay.lua` with no arguments generates one by
driving the real framing code and replays that.

---

## Regenerating assets

`assets/items1530.bin` is the per-item attribute-flag table. The parser cannot decode a single map
description without it: every item on the wire is followed by a variable number of attribute bytes
and only these flags say which are present.

```
cd D:/Claude/otclient_web/luaclient
python tools/extract_appearances.py
```

Options: `--things-dir DIR` (default `D:/Claude/otclient_mehah1530/otclient/data/things/1530`),
`--out FILE`, `--dump ID [ID ...]`. The extractor is deterministic and only reads from the
read-only reference tree. Re-run it whenever the server ships new assets, i.e. whenever
`appearances-*.dat` or `assets.json.sha256` changes. Full format and provenance:
[`assets/README.md`](assets/README.md).

The **content revision** in the login packet is re-read from
`<assets>/things/1530/assets.json.sha256` (or `<assets>/assets/assets.json.sha256`) at runtime —
not from the header of `items1530.bin`, which carries only a diagnostic copy. Neither file exists
under this project, so `proto/handshake.lua` currently falls back to the reference install's value
`42196`; pass `--assets=<otclient data dir>` or `--content-revision=N` to change it.

---

## Layout

```
main.lua              CLI, wiring, boot sequence, ping timer, status line   (_G.LC)
lib/    log sys socket sched buffer xtea adler32 bigint rsa inflate http json events
proto/  transport handshake login_http opcodes parser sender items
game/   state
test/   selftest.lua replay.lua
tools/  extract_appearances.py
assets/ items1530.bin
docs/   the byte-level protocol specs
```

`_G.LC` is the only global: `LC.log/sys/sched/events/items/state/transport/parser/sender/config`.

---

## Status

### Works, and is covered by a test that actually runs

* **Runtime** — QueryPerformanceCounter clock with `timeBeginPeriod(1)`, `BCryptGenRandom`,
  non-blocking `ws2_32` sockets with an outbox, a `select()` reactor (with the Windows
  `exceptfds` rule for failed connects), levelled logging with a file sink.
* **Crypto / bytes** — XTEA (vectors vs Python), adler32, RSA `m^65537 mod n` (~0.7 ms/op,
  vectors vs `pow()`), raw DEFLATE for both the `Z_FINISH` and the persistent `Z_SYNC_FLUSH`
  mode, little-endian reader/writer including `InputMessage::getDouble`.
* **HTTPS login** — WinHTTP via FFI with an automatic `curl.exe` fallback, the reference
  client's exact six headers and byte-exact JSON body, the `Content-Encoding: br` retry the live
  server forces, and the server's own error strings and numeric `errorCode` surfaced to the CLI.
  **Verified live** against `https://www.gunzodus.net/game/login/1530` with an invalid account:
  the process printed `login refused: Account name or password is not correct.` and exited 2.
* **Framing** — outgoing compression header / padding / XTEA / sequence / block count, incoming
  header, `blocks == 0` rejection, padding strip on *every* pre-XTEA frame, the bit-31 inflate
  path with a one-shot PER_PACKET/STREAM latch, and an accumulator that survives arbitrary chunk
  boundaries (proved one byte at a time).
* **Handshake** — the 151-byte login body (23-byte prefix + 128-byte RSA block) and its 158-byte
  frame at sequence 0, the two separate enter-game frames at sequences 1 and 2, FNV-1a hwid.
* **Parser** — all 183 server opcodes that are reachable at 1530, byte-exact consumption, and a
  desync report naming the opcode, the byte offset and the previous three opcodes.
* **Live socket path** — driven end to end over 127.0.0.1 against a fake 1530 server:
  connect → world preamble → challenge → 158-byte login frame (19 blocks, seq 0) → pending →
  enter-game frames (seq 1, 2) → `PlayerData` parsed into the state → text message → server ping
  answered with opcode 28 → keepalive ping → clean exit 0 when the peer closes.

### Not proven, and honest about it

* **No real authenticated session has ever been established.** Everything past the HTTPS reply
  has only been exercised against fixtures and a fake server. In particular the server may reject
  the login packet for reasons no offline test can see: the `u16 2` gunz marker and the `"261"`
  extended-data literal inside the RSA block are marked UNVERIFIED in the docs, the hwid is an
  FNV-1a of the account name rather than the real volume fingerprint the original binary sends,
  and the content revision falls back to `42196`.
* **Opcode 28 for the pong is flagged UNVERIFIED** in the reference source. If the keepalive is
  what drops the session, try 30 (`proto/sender.lua:pingBack`).
* **Inbound compression has never been seen from Gunzodus.** Both modes are implemented and
  tested against zlib-produced blobs, but whether the server ever sets bit 31 — and which mode it
  would use — is unknown.
* **No 1530 `.cam` corpus.** The replay path is proven on captures this repo generates. Record a
  real one with `--capture=` on the first successful login; that is the single highest-value
  artefact for validating the parser against the live server.
* **Map parsing at scale is untested against real data.** Tile descriptions, floor changes and
  creature appearances are implemented and unit-tested with hand-built packets, but no full map
  description from the live server has ever been parsed.
* **2FA (`--token`)** is byte-verified against the reference JSON only; it has not been exercised
  against an account with an authenticator.
* **TLS certificate and hostname verification are disabled** on the login POST, deliberately, to
  match `httplogin.cpp`. That is a real MITM exposure; a one-line warning is logged once.
* **IPv6 is not supported** (`getaddrinfo` is pinned to `AF_INET`).
* `LUACLIENT_TEST_XTEA=<32 hex chars>` pins the session's XTEA key so an offline fake server can
  decrypt our frames. It is a **testing hook only** and logs a loud warning; never set it against
  a real server.
