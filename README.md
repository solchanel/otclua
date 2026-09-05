# luaclient

A standalone **LuaJIT** worker client for **Gunzodus** (Tibia protocol **1530**, client OS id **61**).

No otclient at runtime, no C++, no OpenGL, no audio, no external Lua modules — one LuaJIT
interpreter, FFI for the Windows APIs, and the pure-Lua protocol stack in this directory.
It logs in over HTTPS, connects to the game world, completes the login handshake, keeps the
session alive and parses every server packet into a game state plus an event bus. On top of that
sits a **bot layer that reproduces vBot 4.8's behaviour** — HealBot, AttackBot, CaveBot,
TargetBot with looting and supplies — with no UI, reading the user's existing vBot config files
unchanged. See [Bot layer](#bot-layer).

The byte-level truth for every wire detail lives in [`docs/`](docs/); the module contract every
file is written against is [`API.md`](API.md). In each doc the **`## VERIFIER (Corrections)`
section overrides the spec body above it**.

**Current status (measured 2026-09-06, both OSes):** `--selftest` **2184 passed / 0 failed** on
Windows 11 x64 and on Debian 13 x64 (WSL2) — 401 client assertions plus 1783 in the bot layer
(`test/botsuite.lua`, which also embeds the six per-module suites). The offline end-to-end test — the real `main.lua`
logging into `test/fakeserver.lua` over a real loopback socket — is **37 checks / 0 failed** on
both. The live HTTPS login is verified against `www.gunzodus.net` with an invalid account on
both: it prints the server's own message and exits **2**. **No real authenticated game session
has ever been established** — that needs credentials. See [Status](#status).

---

## Running it

```
run.bat --account=you@example.com --password=... --character="Your Char"     # Windows
./run.sh --account=you@example.com --password=... --character="Your Char"    # Linux
```

Both launchers only locate LuaJIT, `cd` to the project root and run `main.lua`, passing your
flags through and propagating the exit code; set `LUACLIENT_LUAJIT` to use a different
interpreter. Equivalent direct invocations:

```
"D:\Claude\otclient_mehah1530\otclient\build\win-local\vcpkg_installed\x64-windows-static-release\tools\luajit\luajit.exe" main.lua --account=... --password=...
luajit main.lua --account=... --password=...
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
| `--bot` | enable the bot layer once the server says we are in the game |
| `--bot-profile=DIR` | vBot profile directory. Default: the `vBot_4.8` profile next to this checkout when it exists, else `./profiles`. `LUACLIENT_BOT_PROFILE` overrides |
| `--bot-vprofile=N` | selects `vBot_configs/profile_<N>` and `storage/profile_<N>.json` (default 1) |
| `--cavebot=NAME` | select `cavebot_configs/<NAME>.cfg` **and** enable CaveBot (implies `--bot`) |
| `--targetbot=NAME` | select `targetbot_configs/<NAME>.json` **and** enable TargetBot (implies `--bot`) |
| `--bot-status-interval=MS` | one-line bot status at info level, default `5000`, `0` turns it off |
| `--dry-run` | offline wiring check: no sockets, no HTTPS (with `--bot` it also builds, wires, ticks and stops the whole bot, read-only) |
| `--selftest` | run `test/selftest.lua` and exit with its status |
| `--replay=FILE` | run `test/replay.lua` over a capture and exit (path must not contain quotes) |
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

## Platforms

One source tree runs unchanged on **Windows 10/11 x64** and **Debian 12/13 x64**, both under
LuaJIT 2.1 with FFI and no external Lua modules. The OS is detected once per module with
`require('ffi').os` and everything below the public API branches internally — every function name
and signature in [`API.md`](API.md) is identical on both, including `socket.select(read, write,
timeoutMs)`, which is `select()` on Windows and `poll()` on Linux.

| | Windows | Linux |
|---|---|---|
| launcher | `run.bat` (vcpkg LuaJIT, else `luajit` on `PATH`) | `run.sh` (`luajit` on `PATH`) |
| monotonic clock | `QueryPerformanceCounter` | `clock_gettime(CLOCK_MONOTONIC)` |
| sleep | `Sleep(ms)` + `timeBeginPeriod(1)` | `nanosleep()`, retried on `EINTR` |
| CSPRNG | `BCryptGenRandom` → `RtlGenRandom` | `getrandom(2)` → `/dev/urandom` |
| sockets | `ws2_32` + `select()` + `ioctlsocket(FIONBIO)` | libc + `poll()` + `fcntl(O_NONBLOCK)` |
| failed connect seen in | `exceptfds` **only** | `POLLOUT` (+`POLLERR`/`POLLHUP`), then `getsockopt(SO_ERROR)` |
| errors | `WSAGetLastError()`, `WSAE*` | `errno`, `EAGAIN`/`EINPROGRESS`/`ECONNREFUSED`, `EINTR` retried |
| `SIGPIPE` | n/a | `MSG_NOSIGNAL` on every `send`, plus `SIG_IGN` at init |
| HTTPS | WinHTTP via FFI → `curl.exe` | `libcurl.so.4` via FFI → `curl` CLI |

`lib/http.lua` picks its backend at first use and `http.backend()` names the winner
(`winhttp` / `curl-ffi` / `curl-cli`). Neither CLI fallback ever puts the login body on a command
line — it is written to a temp file (created **0600** on Linux *before* anything is written into
it) and passed as `--data-binary @file`, then deleted. If Linux has neither libcurl nor the `curl`
binary, the error says `apt install curl`.

Linux prerequisites: `luajit` and `curl` (`apt install luajit curl`). `run.sh` must be executable
(`chmod +x run.sh`); on a fresh clone from a Windows checkout, git may not carry the bit — use
`git update-index --chmod=+x run.sh` or `sh run.sh`.

`tools/extract_appearances.py` takes the assets directory as a CLI argument
(`python3 tools/extract_appearances.py /path/to/data/things/1530`, or `$LUACLIENT_THINGS_DIR`)
rather than a hard-coded Windows path; with none given it still falls back to the reference
install on this machine.

Test hooks: `LUACLIENT_NO_GETRANDOM=1` forces the `/dev/urandom` CSPRNG path so the fallback can
be exercised on a glibc that does export `getrandom`.

Measured on both, same source tree, same commit:

| | Windows 11 x64 | Debian 13 x64 (WSL2) |
|---|---|---|
| `--selftest` | 2184 passed, 0 failed | 2184 passed, 0 failed |
| `test/fakeserver.lua` | 37 checks, 0 failed | 37 checks, 0 failed |
| live invalid-account login | server message + exit 2 | server message + exit 2 |
| `http.backend()` chosen | `winhttp` | `curl-ffi` |

WSL2 reaches the project through `/mnt/d`, which is slow (a selftest that takes ~0.1 s of CPU can
spend seconds on file I/O). That is 9p filesystem latency, not a client bug.

The full API-by-API mapping and the acceptance criteria are in
[`docs/portability.md`](docs/portability.md).

---

## Tests

Windows:

```
run.bat --selftest                                      2184 assertions, 23 suites
run.bat --dry-run                                       end-to-end wiring, offline
run.bat --replay=%TEMP%\some-capture.cam                replay a capture
"…\luajit.exe" test\fakeserver.lua                      OFFLINE END-TO-END (see below)
"…\luajit.exe" test\replay.lua --self                   synthesise a capture and replay it
```

Debian / any POSIX:

```
./run.sh --selftest
./run.sh --dry-run
luajit test/botsuite.lua                                the bot layer on its own
./run.sh --replay=/tmp/some-capture.cam
luajit test/fakeserver.lua
luajit test/replay.lua --self
luajit test/replay.lua FILE...                          replay real captures (.cam or .lcap)
```

`test/selftest.lua` runs **2184 assertions across 23 suites**: 401 for the client itself (crypto
vectors cross-checked against Python/zlib, buffer round-trips, framing round-trips including
byte-at-a-time chunked delivery, hwid, item lookups, the 11-thing tile trim, the event bus,
parser packet fixtures, a real 127.0.0.1 socket + scheduler round trip, and the whole offline
boot sequence) plus 1783 for the bot layer through `test/botsuite.lua`. It prints a PASS/FAIL
line per module and exits non-zero on any failure. Latest run: **2184 passed, 0 failed** on
Windows 11 x64 *and* on Debian 13 x64.

`test/botsuite.lua` can also be run on its own (`luajit test/botsuite.lua`), and with
`_G.BOTSUITE_ONLY_INTEGRATION = true` it skips the six embedded per-module suites.

### `test/fakeserver.lua` — the offline end-to-end proof

This is the strongest evidence available without live credentials. It binds an ephemeral port on
`127.0.0.1`, starts the **real `main.lua`** as a child process pointed at that port
(`--session-key=… --host=127.0.0.1:PORT`), and speaks the 1530 wire format back at it with its
**own** framing/padding/sequence/XTEA implementation — it deliberately does *not* call
`proto/transport.lua`, so a framing bug cannot cancel itself out.

It asserts, in order: the raw `Gunzodus\n` preamble is the first thing on the socket · the login
frame is 158 bytes / 19 blocks / sequence 0 with XTEA still off · its body decodes field by field
(opcode `0x0A`, os 61, protocol 1530, client version 1530, `"1530"`, the content-revision string,
the preview byte, exactly 128 non-zero RSA bytes, nothing left over) · after `PendingGame` the
client turns XTEA on and sends the **two** enter-game frames separately at sequences 1 and 2, each
carrying the gunz `00000000` compression header inside the encrypted region and the second the
FNV-1a hwid · `EnterGame`, `PlayerData` and a `TextMessage` all reach the state and the log ·
a server ping (`0x1D`) is answered with opcode `0x1C` at sequence 3 · `SessionEnd` makes the
client exit **0**. Latest run: **37 checks, 0 failed** on both OSes.

Because the fake server has no RSA private key it cannot read the session key out of the login
packet, so it starts the client with `LUACLIENT_TEST_XTEA=<fixed key>` (the documented test hook
in `main.lua`, which logs a loud warning). Everything else is the production path.
`luajit test/fakeserver.lua --serve=PORT` serves one session on a fixed port and prints the client
command line, for driving the client by hand from another shell.

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

## Bot layer

```
run.bat --account=... --password=... --character="Char" \
        --cavebot=teeest --targetbot=def_target --bot-status-interval=5000
```

The bot is **off unless you ask for it**. `--bot` turns it on; `--cavebot=NAME` and
`--targetbot=NAME` turn it on *and* select and enable that config. It is constructed and started
when the server says we are in the game (`gameStart` / `login`), stopped on any shutdown path —
which is also when its storage is persisted — and it ticks every 10 ms on the client's own
scheduler. Nothing about it touches the network directly: it reads `LC.state` and sends through
`LC.sender`, like every other consumer.

### What it does

| Module | Behaviour |
|---|---|
| `bot/healbot.lua` | Four independent polling loops (conditions 500 ms, conditions 50 ms, spells 50 ms, items 100 ms) driven by `HealBot.json`: spell rules, item rules, and the ConditionPanel cures/buffs (antidote, haste, utamo, utana, utura, paralysis). Priority is array order; the first matching rule fires. |
| `bot/attackbot.lua` | One 50 ms loop over `AttackBot.json`'s attack table: spells and area runes, monster counting inside the real spell patterns, wave/beam direction picking, best-tile picking for area runes, PvP and blacklist guards, per-entry cooldowns. It never *selects* a target — it is a passenger on whatever TargetBot is attacking. |
| `bot/cavebot.lua` | The waypoint engine for `cavebot_configs/*.cfg`: `goto label gotolabel delay node use usewith say npcsay follow function walkdelay turn exanihur poscheck opendoors cleartile lure supplycheck buysupplies sellall depositor stowdeposit bank travel`, plus Stay-Path, the anti-lost recovery machine and the supply-check → refill → return-to-hunt cycle. |
| `bot/targetbot.lua` | Candidate gathering, the full scoring function (priority, danger, distance bonuses, hysteresis), chase / keep-distance / lure / rePosition movement, the danger aggregate CaveBot consults, and the CaveBot interlock. |
| `bot/loot.lua` | Corpse discovery and the looting state machine: queueing, walking to the corpse, opening it, nested bags, stack merging, loot-bag selection. |
| `bot/supplies.lua` | `Supplies.json` thresholds and the 12-branch round gate (force refill, hunt-round limit, imbuements, stamina, soft boots, supply minima, capacity, loot-pouch pages). |
| `bot/walker.lua` | The step machine shared by CaveBot and TargetBot: one ledger, confirmation, refusal retries, `walkCancel` back-off, step duration from the ground speed and the server beat, floor-change geometry. |
| `bot/path.lua` | The pathfinder — a faithful port of `Map::findEveryPath` (pure Dijkstra, 3× diagonals, the exact neighbour order and tie-break), with `maxDistance` / `maxComplexity` and the unseen / creature / non-pathable flags. |
| `bot/api.lua` | The vBot-compatible script surface (`say use useWith findItem getMonsters canCast …`) that `function` waypoints run against. |

Arbitration is `bot:isActionAllowed(who)`: **TargetBot suspends CaveBot** while it has a target
or is looting (CaveBot yields by not advancing its waypoint), a lure grant re-opens the window
for 150 ms, and **healing never yields**. Macro registration order *is* priority order and
intra-tick send order: healbot → attackbot → targetbot → cavebot.

### Config compatibility

The bot reads the user's **existing vBot 4.8 files unchanged** — string thresholds, stale
`index` fields, the misspelled `curePosion` key and all:

```
<profile>/vBot_configs/profile_<N>/HealBot.json      healing rules + ConditionPanel
<profile>/vBot_configs/profile_<N>/AttackBot.json    attack entries
<profile>/vBot_configs/profile_<N>/Supplies.json     supply thresholds
<profile>/cavebot_configs/<name>.cfg                 waypoints, one "type:value" per line
<profile>/targetbot_configs/<name>.json              { targeting = [...], looting = {...} }
<profile>/storage/profile_<N>.json                   persisted runtime storage
```

Writes go through `bot/config.lua`, which preserves unknown fields and writes atomically
(temp + rename). `--dry-run --bot` opens the profile **read-only** so an offline wiring check can
never modify it.

### Proven offline

`test/botsuite.lua` (folded into `--selftest`) builds a synthetic world on the real
`game/state.lua`, with the real `assets/items1530.bin` metadata and an ASCII map compiled into
tiles, and drives the whole stack through `bot:tick()`. **1783 assertions, 0 failed, on Windows
and Debian**, of which 127 are the integration tests in `botsuite.lua` itself and the rest come
from the six embedded per-module suites:

| Suite | Assertions | Covers |
|---|---|---|
| `test/f1_metadata.lua` | 446 | the v2 item table and the tile flag cache |
| `test/bot_f2_path.lua` | 174 | the pathfinder and the walker |
| `test/bot_f3.lua` | 259 | the bot core (macros, schedule, delay, storage) and `bot/api.lua` |
| `test/bot_m1.lua` | 295 | HealBot + AttackBot against the user's real JSON |
| `test/bot_m2_cavebot.lua` | 220 | CaveBot + supplies against the user's real routes |
| `test/bot_m3_target.lua` | 259 | TargetBot selection/combat and the looting machine |

The integration assertions specifically pin: the eight macros and their periods in BOT.md's
registration order; one world / one pathfinder / one **walker** shared by CaveBot and TargetBot;
one `bot/shared.lua` cooldown slot shared by HealBot and AttackBot; a heal fired through a full
tick off the real `HealBot.json`; TargetBot attacking and AttackBot firing *because* of it; the
CaveBot freeze and the lure grant; a route walked end to end with a label jump; an unreachable
waypoint skipped; an unknown waypoint type warned about once; a corpse opened and emptied;
`function` waypoints calling `TargetBot.setOn()` with a dot; the BOT.md status object
json-encoding cleanly; and storage round-tripping without dropping unknown fields.

Every one of those runs offline. There is no network in the bot test path at all.

### Not proven — no live session has ever run the bot

* **Nothing in the bot layer has ever driven a real character.** Every packet it would send has
  been asserted against a capturing fake sender, never accepted by a server.
* **The refill family** (`buysupplies`, `sellall`, `depositor`, `bank`, `travel`) is implemented
  but only lightly exercised: the depot reach/open state machine has no synthetic fixture.
* **`stowdeposit`, `forge`, `imbuing`, `tasker`, `rushlure` and the withdraw family** are
  registered but log once and skip — they need `proto/sender.lua` builders that do not exist yet.
* **The five AttackBot spell optimizers** are implemented as a flag and a hook only; every
  optimized spell takes its legacy path. `opts.optimizers = true` is the switch.
* **`state.ping`** is measured from the 0x1E pong of our own keepalive, which no offline test can
  produce; the walker's use of it *is* tested by injecting the field.
* **Anti-lost recovery** is unit-tested for arming, classification and the 60 s bounce guard, but
  the full recovery walk across two floors is not driven end to end.

---

## Regenerating assets

`assets/items1530.bin` is the per-item attribute-flag table. The parser cannot decode a single map
description without it: every item on the wire is followed by a variable number of attribute bytes
and only these flags say which are present.

```
# Windows
cd D:/Claude/otclient_web/luaclient
python tools/extract_appearances.py

# Debian / any POSIX (needs python3 only — no third-party packages)
cd /mnt/d/Claude/otclient_web/luaclient
python3 tools/extract_appearances.py /path/to/otclient/data/things/1530
```

The things directory is resolved in this order: **positional argument** → `--things-dir DIR` →
`$LUACLIENT_THINGS_DIR` → the reference install on this machine
(`D:/Claude/otclient_mehah1530/otclient/data/things/1530`), so it is not a hard-coded Windows
path any more. Other options: `--out FILE` (default `assets/items1530.bin`),
`--dump ID [ID ...]`. The extractor is deterministic and only reads from the read-only reference
tree. Re-run it whenever the server ships new assets, i.e. whenever `appearances-*.dat` or
`assets.json.sha256` changes. Full format and provenance: [`assets/README.md`](assets/README.md).

The **content revision** in the login packet is re-read from
`<assets>/things/1530/assets.json.sha256` (or `<assets>/assets/assets.json.sha256`) at runtime —
not from the header of `items1530.bin`, which carries only a diagnostic copy. Neither file exists
under this project, so `proto/handshake.lua` currently falls back to the reference install's value
`42196`; pass `--assets=<otclient data dir>` or `--content-revision=N` to change it.

---

## Layout

```
main.lua              CLI, wiring, boot sequence, ping timer, status line, bot start/stop (_G.LC)
lib/    log sys socket sched buffer xtea adler32 bigint rsa inflate http json events
proto/  transport handshake login_http opcodes parser sender items
game/   state
bot/    init api config world path walker healbot attackbot cavebot targetbot loot supplies shared
data/   spells1530.lua attackpatterns1530.lua        (generated from the real vBot sources)
test/   selftest.lua botsuite.lua replay.lua fakeserver.lua
        f1_metadata.lua bot_f2_path.lua bot_f3.lua bot_m1.lua bot_m2_cavebot.lua bot_m3_target.lua
tools/  extract_appearances.py extract_vbot_data.lua
assets/ items1530.bin
docs/   the byte-level protocol specs, and docs/vbot/ for the bot behaviour specs
```

`_G.LC` is the only global: `LC.log/sys/sched/events/items/state/transport/parser/sender/config`,
plus `LC.bot` while the bot layer is running. The bot contract lives in [`BOT.md`](BOT.md).

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
* **Live socket path** — `test/fakeserver.lua` drives the real `main.lua` end to end over a real
  127.0.0.1 socket against a fake 1530 server that implements the wire format independently:
  connect → world preamble → challenge → 158-byte login frame (19 blocks, seq 0) → pending →
  enter-game frames (seq 1, 2) → `PlayerData` parsed into the state → text message → server ping
  answered with opcode 0x1C at seq 3 → `SessionEnd` → process exit 0. 37 checks, 0 failed, on
  Windows and on Debian.

* **Bot layer** — the whole vBot 4.8 behaviour set, driven end to end through `bot:tick()`
  against a synthetic world in `test/botsuite.lua` (1783 assertions on both OSes), consuming the
  user's real `HealBot.json` / `AttackBot.json` / `Supplies.json` / `cavebot_configs/*.cfg` /
  `targetbot_configs/*.json` unchanged. See [Bot layer](#bot-layer).

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
