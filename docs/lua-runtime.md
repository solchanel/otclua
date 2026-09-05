# Standalone LuaJIT runtime for the from-scratch Lua client on this Windows 11 machine — interpreter, sockets, TLS/HTTPS, crypto, RNG, clocks/scheduler, JSON, file IO

# Runtime substrate for the pure-Lua 1530 client (Windows 11 Pro, x64)

Everything below was **executed on this machine**; all numbers are measured, all outputs pasted.
Working scratch tree (reusable modules + tests): `C:\Users\solch\AppData\Local\Temp\claude\D--Claude\d2316c51-2c9d-4dca-8ccb-196012c2a787\scratchpad\lj\`

---

## 0. Verdict table

| Need | Decision | Why |
|---|---|---|
| Interpreter | `luajit.exe` (LuaJIT 2.1.1781602682, x64, FFI on) | already built, fully static, no DLL needed |
| TCP | FFI → `ws2_32.dll`, non-blocking + `select()` | proven end-to-end; ~15 API calls total |
| HTTPS login POST | **FFI → `winhttp.dll`** (primary), `curl.exe` via `io.popen` (fallback) | 525 ms vs 817 ms; in-process, no temp files, no child process, custom UA |
| XTEA | **pure Lua + `bit`** | byte-exact vs Python; 46.3 MiB/s — 100× more than needed |
| adler32 | **pure Lua** | byte-exact vs zlib (`0x16460E86` both) |
| RSA-1024/2048 e=65537 no padding | **pure Lua bignum, 16-bit limbs + Montgomery CIOS** | **1.23 ms** (1024) / **4.54 ms** (2048). bcrypt/CNG rejected: 300× the code for a once-per-login op |
| CSPRNG for the XTEA key | **`BCryptGenRandom(NULL,…,BCRYPT_USE_SYSTEM_PREFERRED_RNG)`** | 3 lines of FFI; `RtlGenRandom` (advapi32 `SystemFunction036`) verified as fallback |
| Monotonic clock | `QueryPerformanceCounter` (0.0001 ms resolution measured) | `GetTickCount64` kept for coarse/uptime |
| Scheduler | single-threaded `select()` reactor + timer list, **`timeBeginPeriod(1)` mandatory** | without it `select(10ms)` sleeps 15.95 ms |
| JSON | lift `modules/corelib/json.lua` verbatim (rxi json.lua 0.1.2, **MIT**) | `dofile()`s cleanly, decodes a full login response incl. `\uXXXX` |
| File IO | stock `io`/`os` | 5 MB asset slurped in 3.3 ms; dir listing via FFI `FindFirstFileA` |
| zlib / LZMA | `ffi.load` the DLLs already in the otclient root | `zd.dll` = zlib 1.3.2 (works), `liblzma.dll` = xz 5.8.3 (liblzma API only, no `LzmaUncompress`) |

---

## 1. The interpreter

```
$ luajit.exe -v
LuaJIT 2.1.1781602682 -- Copyright (C) 2005-2026 Mike Pall. https://luajit.org/
$ luajit.exe -e "print(jit.version, jit.arch, jit.os); print('ffi ok:', pcall(require,'ffi'))"
LuaJIT 2.1.1781602682   x64   Windows
ffi ok: true    table: 0x01c9e254d988
```

**Two copies exist and are byte-identical** (`md5 = f1521a5a905a136436fe1f7bc9a1647a`, 957 440 bytes):
* `D:/Claude/otclient_mehah1530/otclient/build/win-local/vcpkg_installed/x64-windows-static-release/tools/luajit/luajit.exe`
* `D:/Claude/otclient_web/otclient/build/win-local/vcpkg_installed/x64-windows-static-release/tools/luajit/luajit.exe`

Use the mehah1530 one. **Note both live under `build/`** — a `cmake --fresh` / clean would delete them. Copy the exe into the new client's own tree before depending on it.

### 1.1 No DLL is required next to it
Import table scraped from the PE — only OS libraries:
```
advapi32.dll  gdi32.dll  KERNEL32.dll  user32.dll  winmm.dll   (+ the loadall.dll string, which is only the package.cpath template)
```
There is **no `lua51.dll` import** — the VM is statically linked. Proof: copied `luajit.exe` alone into an empty directory and ran it:
```
$ cd .../scratchpad/isolated ; ls -la
-rwxr-xr-x 957440 luajit.exe          <- only file
$ ./luajit.exe -e "print('isolated ok', jit.version, package.path, package.cpath)"
isolated ok  LuaJIT 2.1.1781602682   .\?.lua;...\isolated\lua\?.lua;...  .\?.dll;...
```
(The `lua51.dll` in `otclient/` root is for the C++ client, not for this exe.)

### 1.2 Default module search paths (derived from the exe dir at runtime)
```
package.path  = .\?.lua ; <exedir>\lua\?.lua ; <exedir>\lua\?\init.lua ;
package.cpath = .\?.dll ; <exedir>\?.dll ; <exedir>\loadall.dll
```
Only `lua/jit/*.lua` (bc, bcsave, dis_*, dump, p, v, vmdef, zone) ships. **No luasocket, no LuaRocks, no lfs, no cjson, no ssl.** Everything must be pure Lua or FFI. Always set `package.path` explicitly at startup (verified working from a foreign cwd).

### 1.3 Exact command line (§7)
```
"D:\Claude\otclient_mehah1530\otclient\build\win-local\vcpkg_installed\x64-windows-static-release\tools\luajit\luajit.exe" main.lua arg1 arg2
```
* `arg[0]` = script name, `arg[1..n]` = args (verified: `argv: t_final.lua alpha beta`).
* `-e "chunk"` and `-l mod` work; `-b` (bytecode) available via `lua/jit/bcsave.lua`.
* `io.stdout:setvbuf("line")` returns true — do this first so logs interleave correctly when piped.
* Recommended launcher (`run.cmd`):
  ```
  @echo off
  set LJ=D:\Claude\...\tools\luajit\luajit.exe
  "%LJ%" -e "package.path=[[%~dp0?.lua;%~dp0?\init.lua;]]..package.path" "%~dp0main.lua" %*
  ```
* Standard Lua 5.1 semantics: **no `string.pack`/`string.unpack`** (verified `nil`) — all serialization is hand-rolled.

---

## 2. TCP sockets — FFI to ws2_32 (PROVEN)

Module: `…\scratchpad\lj\wsock.lua`. Test: `…\scratchpad\lj\t_sock.lua`. Real output:

```
== A) loopback listener + non-blocking client echo ==
listening on 127.0.0.1:62302
connect ->      pending nil
select: readable=1 writable=1   so_error=0
accept ->       296ULL
client send:    12
server recv:    12      [0A][00]HELLO-1530
client recv echo:
 HELLO-1530
== B) real internet TCP connect (example.com:80, raw HTTP) ==
resolve ->      0x9A171468      nil
connect ->      pending
writable:       1       so_error:       0
recv end:       closed
bytes received: 828
first line:     HTTP/1.1 200 OK
OK
```

So: `WSAStartup(0x0202)` → `socket` → `ioctlsocket(FIONBIO)` → `connect` (returns `WSAEWOULDBLOCK`, expected) → `select` for writability → `getsockopt(SOL_SOCKET,SO_ERROR)` == 0 → `send`/`recv` → `closesocket` — all working, plus `bind`/`listen`/`accept`/`getsockname` for the future control plane and `getaddrinfo` for DNS.

Constants actually used (hex where the SDK uses hex):
```
AF_INET=2  SOCK_STREAM=1  IPPROTO_TCP=6
FIONBIO = 0x8004667E   (= -2147195266 as a signed long; pass it as a Lua number)
INVALID_SOCKET = (SOCKET)(-1)      SOCKET_ERROR = -1
SOL_SOCKET = 0xFFFF   SO_ERROR = 0x1007   TCP_NODELAY = 1 (level IPPROTO_TCP=6)
WSAEWOULDBLOCK=10035 WSAEINPROGRESS=10036 WSAEALREADY=10037
WSAECONNRESET=10054  WSAEISCONN=10056     WSAECONNREFUSED=10061
MAKEWORD(2,2) = 0x0202
```
Struct layouts that matter (x64 Windows, verified by the working test):
```c
typedef uintptr_t SOCKET;                          /* 8 bytes on x64 */
struct sockaddr_in { short sin_family; u_short sin_port; u_long s_addr; char sin_zero[8]; }; /* 16 */
struct timeval     { long tv_sec; long tv_usec; }; /* long is 32-bit on Windows */
typedef struct fd_set { u_int fd_count; SOCKET fd_array[64]; } fd_set;  /* FD_SETSIZE=64 */
struct addrinfo { int ai_flags, ai_family, ai_socktype, ai_protocol;
                  size_t ai_addrlen; char *ai_canonname; struct sockaddr *ai_addr;
                  struct addrinfo *ai_next; };     /* NOTE: Windows order is canonname BEFORE addr
                                                      (the reverse of glibc) */
```
`WSAPoll` is also resolvable (`WSAPoll resolvable: true cdata<int ()>: 0x7ff8d9934860`) but `select()` is enough: FD_SETSIZE 64 vs. the 2–4 sockets this client will hold.

`htons`/`ntohs` are exported by ws2_32; IPv4 literals are easiest as network-order uint32 directly (`127.0.0.1` = `0x0100007F`).

---

## 3. HTTPS login POST — WinHTTP vs curl.exe (BOTH RUN)

### (a) FFI WinHTTP — `…\scratchpad\lj\winhttp.lua`  ✅ RECOMMENDED
```
status: 200     err:    nil
elapsed: 525 ms
body bytes: 792
{ "data": "{\"type\":\"login\",\"email\":\"a@b.c\",\"password\":\"p&w%d\\\"q\",...}",
  "headers": { "Content-Length": "158", "Content-Type": "application/json",
               "Host": "httpbin.org", "User-Agent": "OTCLua/1.0" },
  "json": { "client": { "os": 61, "type": "OTCLIENT", "version": 1530 }, ... } }
```
Call chain proven: `WinHttpOpen` → `WinHttpSetTimeouts` → `WinHttpConnect(host, 443)` → `WinHttpOpenRequest("POST", path, flags=WINHTTP_FLAG_SECURE=0x00800000)` → `WinHttpSendRequest(hdrs, 0xFFFFFFFF /* -1 = auto strlen */, NULL, 0, totalLength)` → `WinHttpWriteData(body)` → `WinHttpReceiveResponse` → `WinHttpQueryHeaders(WINHTTP_QUERY_STATUS_CODE|WINHTTP_QUERY_FLAG_NUMBER = 19|0x20000000)` → loop `WinHttpQueryDataAvailable`/`WinHttpReadData` → 3× `WinHttpCloseHandle`.

Notes:
* All WinHTTP strings are **UTF-16**; convert with `MultiByteToWideChar(CP_UTF8=65001, 0, s, -1, buf, n)` (helper `W()` in the module).
* Schannel does cert validation with the Windows root store — no `cacert.pem` needed (the one in the otclient root is for libcurl in the C++ client).
* Blocking-mode WinHTTP is fine: the login POST happens before the game socket exists.

### (b) curl.exe shell-out — `…\scratchpad\lj\httpcurl.lua`
```
$ C:\Windows\System32\curl.exe --version
curl 8.21.0 (Windows) libcurl/8.21.0 Schannel zlib/1.3.2 WinIDN WinLDAP
```
```
status: 200     err:    nil
elapsed: 817 ms
body bytes: 815
"data": "{\"type\":\"login\",\"email\":\"a@b.c\",\"password\":\"p&w%d\\\"q\",...}"
"User-Agent": "curl/8.21.0"
```
Works, and the body survived `&`, `%d` and an escaped quote **because the body goes through a temp file (`--data-binary @file`), never the command line**. Downsides: 292 ms slower, spawns a process, flashes a console window under `pythonw`-style hosts, needs `cmd /c` quoting hygiene, leaves temp files if killed.

**Decision: WinHTTP primary; keep `httpcurl.post()` behind the same `(status, body, err)` signature as a one-line fallback** if a proxy/TLS policy ever breaks WinHTTP.

Login target for reference (`init.lua:81`): `https://www.gunzodus.net/game/login/1530`, port 443, `httpLogin = true` (plain-HTTP retry permitted), `useAuthenticator = true`.

---

## 4. Crypto — all pure Lua, all byte-exact against Python

Module: `…\scratchpad\lj\otcrypto.lua`. Reference vectors generated by `ref.py` (independent Python implementations + `zlib.adler32` + `pow()`), compared by `t_crypto.lua`:

```
== XTEA ==
PASS xtea encrypt 32B
PASS xtea roundtrip
PASS xtea zero key/zero block
== adler32 ==
PASS adler32
== CSPRNG ==
BCryptGenRandom 32B:  ff3b6a8853d8f9aae64825d03a65e64887122e39159251406137a60c818a655c
second draw differs:  true
xtea key: 847546A2 0AA57450 67F030B2 90163761
== RSA modpow ==
1024 modulus bytes: 128
PASS rsa1024 e=65537 nopad
  1024-bit modpow: 1.57 ms
2048 modulus bytes: 256
PASS rsa2048 e=65537 nopad
  2048-bit modpow: 4.60 ms
  1024-bit modpow x20 (warm): 1.23 ms/op
  2048-bit modpow x20 (warm): 4.54 ms/op
== XTEA throughput ==
  xtea encrypt 20 x 64KiB: 27.03 ms  (46.3 MiB/s)
== clocks ==
now_ms(): 148.85639999807   GetTickCount64(): 20469765
Sleep(50) measured 50.23 ms

6 passed, 0 failed
```

### 4.1 Test vectors (reusable regression suite)
```
XTEA-32, delta 0x9E3779B9, LE u32 blocks, ECB
  key   = {0x01234567, 0x89ABCDEF, 0xFEDCBA98, 0x76543210}
  plain = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
  ct    = e490d158660e3f4f65cdd38e97a90d15fa7433f92a81faf2d424392f1c569b13
  key   = {0,0,0,0}, plain = 0000000000000000
  ct    = d8d4e9ded91e13f7
adler32("OTClient 1530 protocol test payload \0\1\xFE\xFF") = 0x16460E86
  (identical from pure Lua AND from zd.dll's zlib adler32 — cross-checked twice)
RSA-1024, n = 9b646903b45b07ac…5b7ff5 (the classic OTServ public modulus), e=65537, no padding
  msg    = 0102…80   (128 bytes)
  cipher = 1db59e5ea3e5daa6…c5da58c
RSA-2048 vector also passes (n/msg/cipher in scratchpad\lj\ref.json)
```

### 4.2 RSA decision: pure Lua wins outright
* **1.23 ms** for 1024-bit, **4.54 ms** for 2048-bit, on a run-once-per-login path with a 500 ms budget. That is 400× headroom.
* Implementation: 16-bit limbs (base 2^16) stored as a plain Lua array of doubles. Products stay ≤ 2^32 + 2^17 < 2^53, so double arithmetic is exact. Montgomery CIOS multiply, `R²  mod n` obtained by 32·k modular doublings (no long division anywhere), MSB-first square-and-multiply over the 17 bits of 65537 = 17 modmuls.
* **bcrypt/CNG rejected**: raw no-padding RSA through CNG needs a hand-built `BCRYPT_RSAPUBLIC_BLOB` (magic `RSA1`, BitLength, cbPublicExp, cbModulus, cbPrime1/2 + big-endian exponent + modulus), `BCryptOpenAlgorithmProvider`/`BCryptImportKeyPair`/`BCryptEncrypt(BCRYPT_PAD_NONE)`/`BCryptDestroyKey`/`BCryptCloseAlgorithmProvider` — ~120 lines of fiddly FFI with NTSTATUS handling, to save 1 ms once per login. Not worth it.

### 4.3 RNG
`BCryptGenRandom(NULL, buf, n, BCRYPT_USE_SYSTEM_PREFERRED_RNG = 0x00000002)` returns NTSTATUS 0 and produces distinct high-entropy draws (verified twice). Fallback verified too: `advapi32!SystemFunction036` (RtlGenRandom) → `3badb08e5b85decd7e3d9ab0049a8594`. `os.time()+math.random()` is never used.

### 4.4 END-TO-END COMPOSITION PROOF (the actual handshake shape)
`genkey.py` generated a real 1024-bit RSA keypair (deterministic, seed 0xC0FFEE1530). Lua then: drew a fresh XTEA key from BCryptGenRandom → built a 128-byte block `[00][00][16 key bytes][account\0][password\0][zero pad]` → RSA-encrypted it with the **public** modulus → XTEA-encrypted a body → adler32'd the ciphertext. Python decrypted with the **private** exponent:

```
RSA decrypt ok, 128 bytes
plaintext[:40] = 000016281254497804730520181b78dd53127573657240686f73742e636f6d004d79506173737730
byte0=00 byte1=00
recovered xtea key : 16281254497804730520181b78dd5312
lua-declared key   : 16281254497804730520181b78dd5312
KEY MATCH: True
credentials in block: b'user@host.com\x00MyPassw0rd\x00\x00\x00'
XTEA decrypt   : 060068656c6c6f210a003031323334353637383900000000
lua plain body : 060068656c6c6f210a003031323334353637383900000000
BODY MATCH: True
as text: b'\x06\x00hello!\n\x000123456789\x00\x00\x00\x00'
zlib adler32 of ciphertext: 8bef0af5   lua said: 8bef0af5   MATCH: True
rsa encrypt: 1.48 ms
```
Every crypto primitive the handshake needs is proven interoperable with a third-party implementation.

---

## 5. Clocks and the event loop

### 5.1 Measured granularity — `timeBeginPeriod(1)` is NOT optional
```
default granularity          select(10ms): mean 15.95 ms, worst 20.59 ms
default granularity          Sleep(10ms):  mean 15.57 ms, worst 17.23 ms
timeBeginPeriod(1) -> 0
timeBeginPeriod(1)           select(10ms): mean 10.30 ms, worst 10.85 ms
timeBeginPeriod(1)           Sleep(10ms):  mean 10.47 ms, worst 11.14 ms
timeBeginPeriod(1)           select(50ms): mean 50.55 ms, worst 51.09 ms
QPF-based now_ms resolution probe:
  smallest observable delta: 0.000100 ms
```
Call `winmm.timeBeginPeriod(1)` at startup and `timeEndPeriod(1)` at exit. Without it every wait rounds up to the 15.6 ms scheduler tick — fatal for a 50 ms walk cadence and for ping/latency accounting.

`QueryPerformanceCounter` gives 100 ns resolution → `now_ms()` returns a float millisecond count. `GetTickCount64()` (ms, monotonic, ~15 ms granularity) is kept for coarse "since boot" values.

### 5.2 Reactor — PROVEN multiplexing 3 sources at once
`…\scratchpad\lj\loop.lua` + `t_loop.lua`: a loopback control-plane **listener**, a control **client** on it, a real internet **game-like socket** (non-blocking connect + streamed response + graceful close), and **two repeating timers + one one-shot** — all in one `select()` loop:
```
[    0.0ms]  control plane listening on 127.0.0.1:51749
[   19.0ms]  CTRL client connected (so_error=0)
[   19.1ms]  CTRL accept, fd=456ULL
[   19.1ms]  CTRL rx: status
[   19.1ms]  CTRL client rx: pong:status
[   29.6ms]  GAME connected (so_error=0)
[   47.0ms]  GAME rx 828 bytes (total 828)
[   48.1ms]  GAME closed (closed), total=828
[  421.9ms]  timer tick, count=3
...
[ 2863.2ms]  timer tick, count=26
[ 3033.9ms]  shutdown timer
[ 3081.5ms]  loop exited. 100ms timer fired 27 times in ~3000ms
```
(27/30 ticks — this run **did not** call `timeBeginPeriod(1)` and rescheduled with `t.at = now + every`, which accumulates drift. Both bugs are fixed in the pseudocode below: `t.at = t.at + t.every` and `timeBeginPeriod(1)` at startup.)

### 5.3 Buffer strategy for packet build/parse (measured)
```
build 1000 packets of ~200 bytes:
  table.concat : 3.119 ms  (3.12 us/pkt)
  ffi buffer   : 0.152 ms  (0.15 us/pkt)     <- 20x faster
read 1000 packets of ~200 bytes:
  string.byte  : 0.222 ms  (0.22 us/pkt)
  ffi cast     : 0.189 ms  (0.19 us/pkt)     <- marginal
  unaligned uint16 load works on x64: true
```
→ **Build** outgoing packets into a preallocated `uint8_t[65536]` and `ffi.string()` once at send time. **Parse** with `string.byte(s, i, j)` (multi-return) — it is already fast enough and far less error-prone than pointer casts.

---

## 6. JSON — lift `modules/corelib/json.lua` verbatim

`D:/Claude/otclient_mehah1530/otclient/modules/corelib/json.lua` — **rxi json.lua v0.1.2, Copyright (c) 2020 rxi, MIT licence** (full text in the file header, lines 1–23). 377 lines, zero dependencies, pure Lua 5.1.

API: `json.encode(val) -> string` (line 131), `json.decode(str) -> value` (line 365). It **both** assigns the global `json` (line 24) **and** `return json` (line 377), so `local json = dofile(path)` or `require` both work; copying it into the new tree and adding nothing is enough (optionally delete the global assignment to keep the namespace clean).

Verified on a realistic Tibia-12+/1530 login response:
```
module type: table  version: 0.1.2  encode: function  decode: function
errorCode: 0
sessionkey (raw, note embedded newlines):
"user@host.com\
MyPassw0rd\
\
0"
world: Gunzodus  gunzodus.net:7172
characters: 2
  [1] Test Knight    lvl 250  Elite Knight  worldid=0  (bytes=11)
  [2] Test Máge      lvl 8    Sorcerer      worldid=0  (bytes=10)
utf8 decode of \u00e1 -> 54 65 73 74 20 4D C3 A1 67 65
errorCode/errorMessage: 3  Account name or password is not correct.
encoded request: {"type":"login","stayloggedin":true,"token":"","tokenChanged":false,"email":"user@host.com","password":"MyPassw0rd"}
round-trips: true
decode error is an error(): false  ...json.lua:179: expected string for key at line 1 col 2
```
Confirmed behaviours that matter:
* `\uXXXX` → correct UTF-8 (`\u00e1` → `C3 A1`). The session key's embedded `\n` separators survive intact — critical, they are fed verbatim into the RSA block.
* Nested `session` / `playdata.worlds[]` / `playdata.characters[]` decode into ordinary Lua tables with ipairs-able arrays.
* `decode` **raises** on malformed input with a line/col message — always wrap in `pcall`.
* `encode` emits an *object* for a table with string keys; key order is Lua-hash order (irrelevant for a login POST, but do not rely on field ordering).
* Also parses the shipped `data/things/1530/catalog-content.json` (5115 entries) with no trouble.

---

## 7. File IO and where the data lives

```
== binary read of a real asset ==
size=5017714 bytes, slurped in 3.3 ms
head16: 0A 93 01 08 64 12 78 08 02 10 02 1A 72 08 04 10
tail8 : 38 B2 96 01 40 F2 91 03
slurp length matches: true
adler32 of whole file: 0x277528BC
== text read (catalog-content.json) + json ==
catalog entries: 5115
  type sprite: 5109  |  appearances: 1  map: 1  fullmap: 1  staticdata: 1  staticmapdata: 1  proficiencies: 1
== write + append + delete ==
wrote/read back bytes: 15   ....hello..more     os.remove: true
== directory listing without LuaFileSystem ==
data/ entries: 10  (cursors fonts images json locales particles setup.otml sounds styles things)
data/things/1530 entries: 5117
file exists probe (GetFileAttributesA ~= 0xFFFFFFFF): true  false
== os.* surface ==
os.getenv APPDATA: C:\Users\solch\AppData\Roaming
os.date: 2026-09-05 19:47:35   os.time: 1788630455
os.rename/os.tmpname exist: function function
arg[0]: t_fileio.lua
```
Full `io`/`os` confirmed: `io.open("rb"/"wb"/"ab")`, `f:seek("end"/"set", n)`, `f:read(n)`/`"*a"`, `os.remove`, `os.rename`, `os.tmpname`, `os.getenv`, `os.date`, `os.time`. **Binary-safe** (`"rb"` avoids CRLF translation — mandatory on Windows). No LuaFileSystem: directory enumeration via FFI `FindFirstFileA`/`FindNextFileA`/`FindClose` on `WIN32_FIND_DATAA`, existence via `GetFileAttributesA(...) ~= 0xFFFFFFFF`.

### Asset locations (client root `D:/Claude/otclient_mehah1530/otclient/`)
| Path | Contents |
|---|---|
| `data/things/1530/` | **115 MB, 5117 files** — the Gunzodus 1530 asset set |
| `data/things/1530/catalog-content.json` | manifest: `[{type, file}, …]`, 5115 entries |
| `data/things/1530/assets.json.sha256` | **content revision `42196`** — the value `sendLoginPacket` transmits |
| `data/things/1530/appearances-17a72b3….dat` | 5 017 714 B protobuf appearances |
| `data/things/1530/sprites-*.bmp.lzma` | 5109 LZMA-compressed sprite sheets |
| `data/things/1530/map-*.dat`, `staticdata-*.dat`, `staticmapdata-*.dat`, `proficiencies-*.json`, `backdrop_map-*.jpg` | rest of the catalog |
| `data/{fonts,images,styles,sounds,locales,particles,json,cursors}`, `data/setup.otml` | UI resources — irrelevant to a headless client |
| `config.ini` (root) | graphics/font settings — irrelevant |
| `init.lua` (root) | `Services` (line 15/25) and `Servers_init` (line 81) — the login URL/port/protocol config to mirror |

### Compression libraries already on disk (usable via `ffi.load` with a full path)
```
ffi.load "D:/…/otclient/zd.dll"      -> zlibVersion: 1.3.2
  compress rc: 0 len 48 ; uncompress rc: 0 roundtrip ok: true
  zlib adler32: 0x16460E86   (== the pure-Lua adler32, cross-check)
ffi.load "D:/…/otclient/liblzma.dll" -> lzma_version_string: 5.8.3
  has LzmaUncompress (7z alone API): false — 'cannot resolve symbol LzmaUncompress'
```
zlib is available if the 1530 protocol ever needs packet inflate. LZMA is present but exposes the **liblzma** API (`lzma_alone_decoder`/`lzma_raw_decoder`/`lzma_stream_decoder`), not the 7-Zip `LzmaUncompress` that OTClient's sprite loader uses — flagged as an open question, and irrelevant unless the Lua client renders sprites.

---

## 8. Files produced (reusable, all runnable)
```
…\scratchpad\lj\wsock.lua       FFI Winsock2 module (startup/tcp/connect/bind_listen/accept/send/recv/select/resolve/nodelay/close)
…\scratchpad\lj\winhttp.lua     FFI WinHTTP one-shot HTTPS POST  -> (status, body, err)
…\scratchpad\lj\httpcurl.lua    curl.exe fallback, same signature
…\scratchpad\lj\otcrypto.lua    XTEA, adler32, RSA modpow (Montgomery), BCryptGenRandom, QPC clock, Sleep
…\scratchpad\lj\loop.lua        select() reactor: add_read/add_listener/add_write/after/every/cancel/run/stop
…\scratchpad\lj\t_*.lua         the tests whose output is pasted above
…\scratchpad\lj\ref.py, genkey.py, verify_e2e.py   Python cross-verification
```


## Pseudocode

-- =====================================================================
-- runtime/  — the substrate the 1530 Lua client sits on.
-- Every block below was executed on this machine; see spec for output.
-- =====================================================================

--=======================================================================
-- runtime/wsock.lua : TCP via ws2_32 (verified end-to-end)
--=======================================================================
local ffi, bit = require("ffi"), require("bit")

ffi.cdef[[
typedef uintptr_t SOCKET;  typedef unsigned short u_short;
typedef unsigned int u_int; typedef unsigned long u_long;
struct sockaddr    { u_short sa_family; char sa_data[14]; };
struct in_addr     { u_long s_addr; };
struct sockaddr_in { short sin_family; u_short sin_port; struct in_addr sin_addr; char sin_zero[8]; };
struct timeval     { long tv_sec; long tv_usec; };            /* Windows long = 32-bit */
typedef struct fd_set { u_int fd_count; SOCKET fd_array[64]; } fd_set;  /* FD_SETSIZE 64 */
struct addrinfo { int ai_flags, ai_family, ai_socktype, ai_protocol;
                  size_t ai_addrlen; char *ai_canonname;      /* Windows: canonname BEFORE addr */
                  struct sockaddr *ai_addr; struct addrinfo *ai_next; };
int  WSAStartup(unsigned short, void*);   int WSACleanup(void);   int WSAGetLastError(void);
SOCKET socket(int,int,int);               int closesocket(SOCKET);
int  connect(SOCKET, const struct sockaddr*, int);
int  bind(SOCKET, const struct sockaddr*, int);   int listen(SOCKET, int);
SOCKET accept(SOCKET, struct sockaddr*, int*);    int getsockname(SOCKET, struct sockaddr*, int*);
int  send(SOCKET, const char*, int, int);         int recv(SOCKET, char*, int, int);
int  ioctlsocket(SOCKET, long, u_long*);
int  setsockopt(SOCKET,int,int,const char*,int);  int getsockopt(SOCKET,int,int,char*,int*);
int  select(int, fd_set*, fd_set*, fd_set*, const struct timeval*);
int  shutdown(SOCKET,int);   u_short htons(u_short);   u_short ntohs(u_short);
int  getaddrinfo(const char*, const char*, const struct addrinfo*, struct addrinfo**);
void freeaddrinfo(struct addrinfo*);
]]
local ws2 = ffi.load("ws2_32")

local W = { AF_INET=2, SOCK_STREAM=1, IPPROTO_TCP=6,
            FIONBIO = -2147195266,               -- 0x8004667E
            INVALID_SOCKET = ffi.cast("SOCKET", -1), SOCKET_ERROR = -1,
            SOL_SOCKET=0xffff, SO_ERROR=0x1007, TCP_NODELAY=1,
            EWOULDBLOCK=10035, EINPROGRESS=10036, EALREADY=10037,
            ECONNRESET=10054, EISCONN=10056, ECONNREFUSED=10061 }

function W.startup()  local d = ffi.new("char[?]",512)
  local rc = ws2.WSAStartup(0x0202, d); return rc==0 or nil, rc end   -- MAKEWORD(2,2)
function W.cleanup()  ws2.WSACleanup() end
function W.err()      return ws2.WSAGetLastError() end

function W.tcp() local s = ws2.socket(2,1,6)
  if s == W.INVALID_SOCKET then return nil, W.err() end; return s end

function W.setnonblocking(s, on)
  local v = ffi.new("u_long[1]", on and 1 or 0)
  return ws2.ioctlsocket(s, W.FIONBIO, v) == 0 end

function W.nodelay(s) local v = ffi.new("int[1]",1)
  return ws2.setsockopt(s, 6, 1, ffi.cast("const char*", v), 4) == 0 end

function W.resolve(host, port)                    -- -> uint32 network order
  local h = ffi.new("struct addrinfo"); h.ai_family=2; h.ai_socktype=1; h.ai_protocol=6
  local r = ffi.new("struct addrinfo*[1]")
  if ws2.getaddrinfo(host, tostring(port), h, r) ~= 0 then return nil,"dns" end
  local a = ffi.cast("struct sockaddr_in*", r[0].ai_addr).sin_addr.s_addr
  ws2.freeaddrinfo(r[0]); return a end

local function sa_of(netaddr, port)
  local sa = ffi.new("struct sockaddr_in")
  sa.sin_family = 2; sa.sin_port = ws2.htons(port); sa.sin_addr.s_addr = netaddr; return sa end

-- non-blocking connect -> true | "pending" | nil,errno
function W.connect(s, netaddr, port)
  local sa = sa_of(netaddr, port)
  if ws2.connect(s, ffi.cast("struct sockaddr*", sa), ffi.sizeof(sa)) == 0 then return true end
  local e = W.err()
  if e==W.EWOULDBLOCK or e==W.EINPROGRESS or e==W.EALREADY then return "pending" end
  if e==W.EISCONN then return true end
  return nil, e end

-- after select() reports writable, THIS is how you learn if the connect really succeeded
function W.connect_error(s)
  local v,l = ffi.new("int[1]"), ffi.new("int[1]", 4)
  ws2.getsockopt(s, W.SOL_SOCKET, W.SO_ERROR, ffi.cast("char*", v), l); return v[0] end

function W.bind_listen(netaddr, port, backlog)    -- port 0 = ephemeral; returns sock, real_port
  local s = W.tcp(); local sa = sa_of(netaddr, port)
  if ws2.bind(s, ffi.cast("struct sockaddr*", sa), ffi.sizeof(sa)) ~= 0 then
    local e=W.err(); ws2.closesocket(s); return nil,"bind="..e end
  if ws2.listen(s, backlog or 8) ~= 0 then
    local e=W.err(); ws2.closesocket(s); return nil,"listen="..e end
  local g,gl = ffi.new("struct sockaddr_in"), ffi.new("int[1]", 16)
  ws2.getsockname(s, ffi.cast("struct sockaddr*", g), gl)
  return s, ws2.ntohs(g.sin_port) end

function W.accept(s)                              -- -> sock | "pending" | nil,errno
  local sa,l = ffi.new("struct sockaddr_in"), ffi.new("int[1]", 16)
  local c = ws2.accept(s, ffi.cast("struct sockaddr*", sa), l)
  if c == W.INVALID_SOCKET then
    local e=W.err(); if e==W.EWOULDBLOCK then return "pending" end; return nil,e end
  return c end

function W.send(s, str)                           -- loops on partial writes
  local n,total,buf = #str, 0, ffi.cast("const char*", str)
  while total < n do
    local w = ws2.send(s, buf+total, n-total, 0)
    if w == -1 then local e=W.err()
      if e==W.EWOULDBLOCK then return total, "partial" end   -- CALLER MUST QUEUE THE REST
      return nil, e end
    total = total + w end
  return total end

local rbuf = ffi.new("char[65536]")
function W.recv(s, maxn)                          -- string | "" (wouldblock) | nil,"closed" | nil,errno
  local n = ws2.recv(s, rbuf, math.min(maxn or 65536, 65536), 0)
  if n > 0 then return ffi.string(rbuf, n) end
  if n == 0 then return nil, "closed" end
  local e = W.err(); if e==W.EWOULDBLOCK then return "" end; return nil, e end

function W.close(s) ws2.closesocket(s) end

function W.select(rlist, wlist, timeout_ms)       -- -> readable[], writable[]
  local rs,wr = ffi.new("fd_set"), ffi.new("fd_set"); rs.fd_count=0; wr.fd_count=0
  local function put(set,s) if set.fd_count<64 then set.fd_array[set.fd_count]=s
                                                   set.fd_count=set.fd_count+1 end end
  local function has(set,s) for i=0,set.fd_count-1 do if set.fd_array[i]==s then return true end end end
  for _,s in ipairs(rlist or {}) do put(rs,s) end
  for _,s in ipairs(wlist or {}) do put(wr,s) end
  local tv
  if timeout_ms then tv = ffi.new("struct timeval")
    tv.tv_sec  = math.floor(timeout_ms/1000)
    tv.tv_usec = (timeout_ms % 1000) * 1000 end
  local n = ws2.select(0, rs.fd_count>0 and rs or nil, wr.fd_count>0 and wr or nil, nil, tv)
  if n == -1 then return nil, W.err() end
  local rr,ww = {},{}
  for _,s in ipairs(rlist or {}) do if has(rs,s) then rr[#rr+1]=s end end
  for _,s in ipairs(wlist or {}) do if has(wr,s) then ww[#ww+1]=s end end
  return rr, ww end
return W

--=======================================================================
-- runtime/winhttp.lua : the ONE HTTPS POST the login needs  (RECOMMENDED)
--=======================================================================
ffi.cdef[[
typedef void* HINTERNET; typedef unsigned long DWORD; typedef int BOOL;
typedef unsigned short WORD; typedef const wchar_t* LPCWSTR;
HINTERNET WinHttpOpen(LPCWSTR,DWORD,LPCWSTR,LPCWSTR,DWORD);
HINTERNET WinHttpConnect(HINTERNET,LPCWSTR,WORD,DWORD);
HINTERNET WinHttpOpenRequest(HINTERNET,LPCWSTR,LPCWSTR,LPCWSTR,LPCWSTR,LPCWSTR*,DWORD);
BOOL WinHttpSendRequest(HINTERNET,LPCWSTR,DWORD,void*,DWORD,DWORD,uintptr_t);
BOOL WinHttpWriteData(HINTERNET,const void*,DWORD,DWORD*);
BOOL WinHttpReceiveResponse(HINTERNET,void*);
BOOL WinHttpQueryDataAvailable(HINTERNET,DWORD*);
BOOL WinHttpReadData(HINTERNET,void*,DWORD,DWORD*);
BOOL WinHttpQueryHeaders(HINTERNET,DWORD,LPCWSTR,void*,DWORD*,DWORD*);
BOOL WinHttpSetTimeouts(HINTERNET,int,int,int,int);
BOOL WinHttpCloseHandle(HINTERNET);
DWORD GetLastError(void);
int MultiByteToWideChar(unsigned,DWORD,const char*,int,wchar_t*,int);
]]
local wh, k32 = ffi.load("winhttp"), ffi.load("kernel32")
local SECURE, QUERY_STATUS, FLAG_NUM = 0x00800000, 19, 0x20000000

local function W16(s)                             -- UTF-8 -> UTF-16LE, NUL-terminated
  local n = k32.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
  local b = ffi.new("wchar_t[?]", n); k32.MultiByteToWideChar(65001,0,s,-1,b,n); return b end

function http_post(url, body, headers, timeout_ms)          -- -> status, body, err
  local scheme, host, path = url:match("^(https?)://([^/]+)(.*)$")
  local port = tonumber(host:match(":(%d+)$")) or (scheme=="https" and 443 or 80)
  host = host:gsub(":%d+$",""); if path == "" then path = "/" end
  local S = wh.WinHttpOpen(W16("OTCLua/1.0"), 0, nil, nil, 0)     -- 0 = DEFAULT_PROXY
  wh.WinHttpSetTimeouts(S, timeout_ms, timeout_ms, timeout_ms, timeout_ms)
  local Cn = wh.WinHttpConnect(S, W16(host), port, 0)
  local R  = wh.WinHttpOpenRequest(Cn, W16("POST"), W16(path), nil, nil, nil,
                                   scheme=="https" and SECURE or 0)
  local hs = {}; for k,v in pairs(headers or {}) do hs[#hs+1] = k..": "..v end
  local hdr = #hs>0 and (table.concat(hs,"\r\n").."\r\n") or nil
  -- dwHeadersLength 0xFFFFFFFF == -1L == "measure the string yourself"
  wh.WinHttpSendRequest(R, hdr and W16(hdr) or nil, hdr and 0xFFFFFFFF or 0,
                        nil, 0, #body, 0)
  wh.WinHttpWriteData(R, body, #body, ffi.new("DWORD[1]"))
  wh.WinHttpReceiveResponse(R, nil)
  local code, cl = ffi.new("DWORD[1]"), ffi.new("DWORD[1]", 4)
  wh.WinHttpQueryHeaders(R, bit.bor(QUERY_STATUS, FLAG_NUM), nil, code, cl, nil)
  local parts, buf = {}, ffi.new("char[16384]")
  local avail, rd = ffi.new("DWORD[1]"), ffi.new("DWORD[1]")
  while true do
    avail[0] = 0
    if wh.WinHttpQueryDataAvailable(R, avail) == 0 or avail[0] == 0 then break end
    if wh.WinHttpReadData(R, buf, math.min(tonumber(avail[0]),16384), rd) == 0 then break end
    if rd[0] == 0 then break end
    parts[#parts+1] = ffi.string(buf, rd[0]) end
  wh.WinHttpCloseHandle(R); wh.WinHttpCloseHandle(Cn); wh.WinHttpCloseHandle(S)
  return tonumber(code[0]), table.concat(parts) end

-- FALLBACK (identical signature): body via a TEMP FILE so cmd.exe can never mangle it.
-- cmd = '""C:\\Windows\\System32\\curl.exe" -s -S --max-time 20 -X POST
--         --data-binary "@REQ" -H "Content-Type: application/json"
--         -D "HDR" -o "RESP" -w "%{http_code}" "URL""'
-- io.popen(cmd):read("*a") -> the 3-digit status; read RESP for the body.

--=======================================================================
-- runtime/crypto.lua : XTEA + adler32 + RSA + CSPRNG + clock
--=======================================================================
local band,bor,bxor,lsh,rsh,tobit = bit.band,bit.bor,bit.bxor,bit.lshift,bit.rshift,bit.tobit

---- CSPRNG ------------------------------------------------------------
ffi.cdef[[ long BCryptGenRandom(void*, unsigned char*, unsigned long, unsigned long); ]]
local bcrypt = ffi.load("bcrypt")
local BCRYPT_USE_SYSTEM_PREFERRED_RNG = 0x00000002
function random_bytes(n)
  local b = ffi.new("unsigned char[?]", n)
  local st = bcrypt.BCryptGenRandom(nil, b, n, BCRYPT_USE_SYSTEM_PREFERRED_RNG)
  if st ~= 0 then error(("BCryptGenRandom NTSTATUS=0x%08X"):format(st)) end
  return ffi.string(b, n) end
-- fallback if bcrypt ever missing:  advapi32!SystemFunction036(buf,len) (RtlGenRandom)

function random_xtea_key()                 -- -> {u32,u32,u32,u32}, raw16
  local s, k = random_bytes(16), {}
  for i=0,3 do local a,b,c,d = s:byte(i*4+1, i*4+4)
    k[i+1] = tobit(bor(a, lsh(b,8), lsh(c,16), lsh(d,24))) end   -- little-endian
  return k, s end

---- monotonic clock + 1 ms scheduler granularity ----------------------
ffi.cdef[[ int QueryPerformanceCounter(int64_t*); int QueryPerformanceFrequency(int64_t*);
           uint64_t GetTickCount64(void); void Sleep(unsigned long);
           unsigned timeBeginPeriod(unsigned); unsigned timeEndPeriod(unsigned); ]]
local k32, winmm = ffi.load("kernel32"), ffi.load("winmm")
winmm.timeBeginPeriod(1)                   -- MANDATORY: 15.95 ms -> 10.30 ms on select(10)
                                           -- winmm.timeEndPeriod(1) at exit
local qpf = ffi.new("int64_t[1]"); k32.QueryPerformanceFrequency(qpf)
local QPF, qpc, t0 = tonumber(qpf[0]), ffi.new("int64_t[1]"), nil
function now_ms()                          -- float ms, 0.0001 ms resolution, monotonic
  k32.QueryPerformanceCounter(qpc)
  local t = tonumber(qpc[0]) * 1000.0 / QPF
  if not t0 then t0 = t end; return t - t0 end
function sleep_ms(ms) k32.Sleep(ms) end

---- adler32 (== zlib, verified 0x16460E86) ----------------------------
function adler32(s, init)
  local a, b = band(init or 1, 0xFFFF), band(rsh(init or 1, 16), 0xFFFF)
  local i, n = 1, #s
  while i <= n do
    local stop = math.min(i + 5551, n)     -- 5552 = max before 32-bit overflow
    for j = i, stop do a = a + s:byte(j); b = b + a end
    a, b, i = a % 65521, b % 65521, stop + 1 end
  return tobit(bor(lsh(b,16), a)) end      -- SIGNED int32; use  % 2^32  to print unsigned

---- XTEA-32, delta 0x9E3779B9, little-endian u32 blocks, ECB ---------
local DELTA = tobit(0x9E3779B9)
local function u32le(s,p) local a,b,c,d = s:byte(p,p+3)
  return tobit(bor(a, lsh(b,8), lsh(c,16), lsh(d,24))) end
local function pu32le(v) return string.char(band(v,0xFF), band(rsh(v,8),0xFF),
                                            band(rsh(v,16),0xFF), band(rsh(v,24),0xFF)) end
local function enc_blk(v0,v1,k) local sum = 0
  for _=1,32 do
    v0  = tobit(v0 + bxor(bxor(lsh(v1,4), rsh(v1,5)) + v1, sum + k[band(sum,3)+1]))
    sum = tobit(sum + DELTA)
    v1  = tobit(v1 + bxor(bxor(lsh(v0,4), rsh(v0,5)) + v0, sum + k[band(rsh(sum,11),3)+1]))
  end return v0,v1 end
local function dec_blk(v0,v1,k) local sum = tobit(DELTA*32)      -- 0xC6EF3720
  for _=1,32 do
    v1  = tobit(v1 - bxor(bxor(lsh(v0,4), rsh(v0,5)) + v0, sum + k[band(rsh(sum,11),3)+1]))
    sum = tobit(sum - DELTA)
    v0  = tobit(v0 - bxor(bxor(lsh(v1,4), rsh(v1,5)) + v1, sum + k[band(sum,3)+1]))
  end return v0,v1 end
function xtea_encrypt(d,k) assert(#d % 8 == 0, "pad to 8 first")   -- caller pads!
  local o = {}
  for p = 1, #d, 8 do local a,b = enc_blk(u32le(d,p), u32le(d,p+4), k)
    o[#o+1] = pu32le(a)..pu32le(b) end
  return table.concat(o) end
function xtea_decrypt(d,k) ... same with dec_blk ... end
-- VECTOR: key {0x01234567,0x89ABCDEF,0xFEDCBA98,0x76543210}, plain 000102..1f
--         -> e490d158660e3f4f65cdd38e97a90d15fa7433f92a81faf2d424392f1c569b13

---- RSA public op, e = 65537, NO padding: 1.23 ms @1024, 4.54 ms @2048
-- 16-bit limbs (base B = 2^16) as plain Lua doubles; every intermediate
-- stays < 2^32 + 2^17 < 2^53, so double arithmetic is EXACT. No long division:
-- R^2 mod n is built by 32*k modular doublings.
local B = 65536
local function bn_from_be(s,k)  -- big-endian bytes -> limb[1..k], limb[1] = least significant
  local t={} for i=1,k do t[i]=0 end
  local li,i = 1,#s
  while i >= 1 do t[li] = s:byte(i) + ((i-1>=1) and s:byte(i-1) or 0)*256; li=li+1; i=i-2 end
  return t end
local function bn_to_be(t, nbytes)
  local o={} for i=#t,1,-1 do o[#o+1] = string.char(math.floor(t[i]/256), t[i]%256) end
  local s = table.concat(o):gsub("^%z+","")
  return string.rep("\0", nbytes-#s) .. s end                   -- zero-pad to modulus size
local function bn_cmp(a,b,k) for i=k,1,-1 do
    if a[i]~=b[i] then return a[i]>b[i] and 1 or -1 end end return 0 end
local function bn_sub(a,b,k) local br=0
  for i=1,k do local s=a[i]-b[i]-br
    if s<0 then s=s+B; br=1 else br=0 end; a[i]=s end end
local function bn_dbl_mod(a,n,k) local c=0
  for i=1,k do local s=a[i]*2+c; if s>=B then a[i]=s-B; c=1 else a[i]=s; c=0 end end
  if c==1 or bn_cmp(a,n,k)>=0 then bn_sub(a,n,k) end end
local function mont_n0inv(n0) local x=1                       -- -n0^-1 mod 2^16, Newton
  for _=1,4 do x = (x*(2 - n0*x)) % B end; return (B-x) % B end
local function montmul(a,b,n,n0inv,k)                          -- CIOS: a*b*R^-1 mod n
  local t={} for i=1,k+2 do t[i]=0 end
  for i=1,k do
    local bi,C = b[i],0
    for j=1,k do local s=t[j]+a[j]*bi+C; C=math.floor(s/B); t[j]=s-C*B end
    local s=t[k+1]+C; C=math.floor(s/B); t[k+1]=s-C*B; t[k+2]=t[k+2]+C
    local m = (t[1]*n0inv) % B
    s = t[1]+m*n[1]; C = math.floor(s/B)                       -- t[1] becomes 0, shift down
    for j=2,k do s=t[j]+m*n[j]+C; C=math.floor(s/B); t[j-1]=s-C*B end
    s=t[k+1]+C; C=math.floor(s/B); t[k]=s-C*B; t[k+1]=t[k+2]+C; t[k+2]=0
  end
  if t[k+1]~=0 or bn_cmp(t,n,k)>=0 then bn_sub(t,n,k); t[k+1]=0 end
  return t end
function rsa_modpow(msg_be, mod_be, exp)                       -- big-endian in, big-endian out
  local nbytes = #mod_be; local k = math.floor((nbytes+1)/2)
  local n = bn_from_be(mod_be,k); assert(n[1] % 2 == 1, "modulus must be odd")
  local n0inv = mont_n0inv(n[1])
  local r2 = {} for i=1,k do r2[i]=0 end; r2[1]=1
  for _=1, 32*k do bn_dbl_mod(r2,n,k) end                      -- R^2 mod n
  local one = {} for i=1,k do one[i]=0 end; one[1]=1
  local xm  = montmul(bn_from_be(msg_be,k), r2, n, n0inv, k)   -- into Montgomery domain
  local acc = montmul(one, r2, n, n0inv, k)
  local bits={} local e=exp while e>0 do bits[#bits+1]=e%2; e=math.floor(e/2) end
  for i=#bits,1,-1 do                                          -- 17 modmuls for e=65537
    acc = montmul(acc,acc,n,n0inv,k)
    if bits[i]==1 then acc = montmul(acc,xm,n,n0inv,k) end end
  return bn_to_be(montmul(acc, one, n, n0inv, k), nbytes) end  -- out of Montgomery domain

--=======================================================================
-- runtime/loop.lua : one select() reactor for game socket + control plane + timers
--=======================================================================
local Loop = {}; Loop.__index = Loop
local function key(s) return tonumber(s) end   -- !!! SOCKET is cdata; NEVER use it as a table key
function Loop.new() return setmetatable({rd={}, wr={}, timers={}, nextid=1, running=false}, Loop) end
function Loop:add_read(s, on_data, on_close) self.rd[key(s)] = {sock=s, on_data=on_data, on_close=on_close} end
function Loop:add_listener(s, on_accept)     self.rd[key(s)] = {sock=s, accept=on_accept} end
function Loop:add_write(s, on_writable)      self.wr[key(s)] = {sock=s, cb=on_writable} end  -- one-shot
function Loop:del(s) self.rd[key(s)]=nil; self.wr[key(s)]=nil end
function Loop:after(ms, fn) local t={at=now_ms()+ms, fn=fn, id=self.nextid}
  self.nextid=self.nextid+1; self.timers[#self.timers+1]=t; return t.id end
function Loop:every(ms, fn) local t={at=now_ms()+ms, fn=fn, every=ms, id=self.nextid}
  self.nextid=self.nextid+1; self.timers[#self.timers+1]=t; return t.id end
function Loop:cancel(id) for i,t in ipairs(self.timers) do
  if t.id==id then table.remove(self.timers,i); return true end end end

function Loop:tick(maxwait_ms)
  -- 1) fire due timers (drift-free reschedule)
  local now, i = now_ms(), 1
  while i <= #self.timers do local t = self.timers[i]
    if t.at <= now then
      if t.every then t.at = t.at + t.every                -- NOT now+every: avoids drift
        if t.at <= now then t.at = now + t.every end       -- catch up after a long stall
        i = i + 1
      else table.remove(self.timers, i) end
      local ok,e = pcall(t.fn); if not ok then log_err(e) end
    else i = i + 1 end end
  -- 2) compute the select() timeout = min(next timer deadline, maxwait)
  local wait = maxwait_ms or 50
  now = now_ms()
  for _,t in ipairs(self.timers) do local d=t.at-now; if d<wait then wait=d end end
  if wait < 0 then wait = 0 end
  -- 3) select()
  local rl,wl = {},{}
  for _,e in pairs(self.rd) do rl[#rl+1]=e.sock end
  for _,e in pairs(self.wr) do wl[#wl+1]=e.sock end
  if #rl == 0 and #wl == 0 then sleep_ms(math.max(1, math.floor(wait))); return end
  local rr, ww = W.select(rl, wl, wait)
  if not rr then return end
  -- 4) writable first: this is how a non-blocking connect completes, and how a
  --    backed-up send queue drains.
  for _,s in ipairs(ww) do local e = self.wr[key(s)]
    if e then self.wr[key(s)] = nil; pcall(e.cb, s, W.connect_error(s)) end end
  -- 5) readable
  for _,s in ipairs(rr) do local e = self.rd[key(s)]
    if e and e.accept then
      local c = W.accept(s); if c and c ~= "pending" then pcall(e.accept, c) end
    elseif e then
      local d, err = W.recv(s, 65536)
      if d == nil then self:del(s); if e.on_close then pcall(e.on_close, s, err) end
      elseif #d > 0 then pcall(e.on_data, s, d) end
    end end
end
function Loop:run(maxwait) self.running=true
  while self.running do self:tick(maxwait or 50) end end
function Loop:stop() self.running=false end

--=======================================================================
-- main.lua : how the pieces compose for one login
--=======================================================================
package.path = SCRIPT_DIR.."?.lua;"..SCRIPT_DIR.."?/init.lua;"..package.path
io.stdout:setvbuf("line")
local json = require("json")                       -- rxi json.lua 0.1.2, MIT, copied verbatim
assert(W.startup())                                 -- WSAStartup(0x0202)

-- 1) HTTPS login (blocking, once) --------------------------------------
local status, raw = http_post("https://www.gunzodus.net/game/login/1530",
        json.encode({ type="login", email=EMAIL, password=PASS, stayloggedin=true,
                      token="", tokenChanged=false }),
        { ["Content-Type"]="application/json" }, 20000)
local ok, resp = pcall(json.decode, raw)            -- decode RAISES on bad input
if not ok or (resp.errorCode or 0) ~= 0 then error(resp and resp.errorMessage or raw) end
local wcfg  = resp.playdata.worlds[1]               -- externaladdress / externalport
local skey  = resp.session.sessionkey               -- "acc\npass\n\n0"  -- keep the \n EXACTLY

-- 2) game socket, non-blocking connect ---------------------------------
local sock = W.tcp(); W.setnonblocking(sock, true); W.nodelay(sock)
W.connect(sock, W.resolve(wcfg.externaladdress, wcfg.externalport), wcfg.externalport)
local L = Loop.new()
L:add_write(sock, function(s, so_err)
  assert(so_err == 0, "connect failed WSA="..so_err)
  local xkey = random_xtea_key()                    -- from BCryptGenRandom, never math.random
  -- <<< protocol layer (other agent's spec) builds the 128-byte RSA block here >>>
  local rsa_block = build_login_block(xkey, skey)   -- exactly #MODULUS bytes, zero-padded
  W.send(s, frame(rsa_modpow(rsa_block, SERVER_MODULUS_BE, 65537)))
  L:add_read(s, function(_, chunk) inbuf:push(chunk); drain(inbuf, xkey) end,
                function(s2) L:del(s2); W.close(s2); L:stop() end)
end)
L:every(50, tick_walk)                              -- needs timeBeginPeriod(1) to be real
L:run(50)
W.cleanup(); winmm.timeEndPeriod(1)

--=======================================================================
-- packet buffers: build with FFI (20x faster), parse with string.byte
--=======================================================================
local OUT = ffi.new("uint8_t[65536]"); local op = 0
local function w8 (v) OUT[op]=band(v,0xFF); op=op+1 end
local function w16(v) OUT[op]=band(v,0xFF); OUT[op+1]=band(rsh(v,8),0xFF);   op=op+2 end
local function w32(v) OUT[op]=band(v,0xFF); OUT[op+1]=band(rsh(v,8),0xFF)
                      OUT[op+2]=band(rsh(v,16),0xFF); OUT[op+3]=band(rsh(v,24),0xFF); op=op+4 end
local function wstr(s) w16(#s); ffi.copy(OUT+op, s, #s); op=op+#s end
local function finish() local s = ffi.string(OUT, op); op = 0; return s end
-- reader over a plain Lua string (string.byte multi-return; 0.22 us / 200-byte packet)
local function reader(s) local p = 1; return {
  u8  = function() local v=s:byte(p); p=p+1; return v end,
  u16 = function() local a,b=s:byte(p,p+1); p=p+2; return a + b*256 end,
  u32 = function() local a,b,c,d=s:byte(p,p+3); p=p+4
                   return a + b*256 + c*65536 + d*16777216 end,   -- unsigned via arithmetic
  str = function() local a,b=s:byte(p,p+1); p=p+2; local n=a+b*256
                   local r=s:sub(p,p+n-1); p=p+n; return r end,
  pos = function() return p end, seek = function(n) p = n end } end

--=======================================================================
-- directory listing without LuaFileSystem
--=======================================================================
ffi.cdef[[
typedef struct { unsigned long lo, hi; } FILETIME;
typedef struct { unsigned long dwFileAttributes; FILETIME c,a,w;
                 unsigned long nFileSizeHigh, nFileSizeLow, r0, r1;
                 char cFileName[260]; char cAlternateFileName[14]; } WIN32_FIND_DATAA;
void* FindFirstFileA(const char*, WIN32_FIND_DATAA*);
int FindNextFileA(void*, WIN32_FIND_DATAA*); int FindClose(void*);
unsigned long GetFileAttributesA(const char*); ]]
function listdir(dir)                       -- dir uses BACKSLASHES
  local fd = ffi.new("WIN32_FIND_DATAA")
  local h = ffi.load("kernel32").FindFirstFileA(dir.."\\*", fd)
  if h == ffi.cast("void*", -1) then return nil end
  local out = {}
  repeat local n = ffi.string(fd.cFileName)
    if n ~= "." and n ~= ".." then
      out[#out+1] = { name = n, dir = band(fd.dwFileAttributes, 0x10) ~= 0,
                      size = tonumber(fd.nFileSizeLow) + tonumber(fd.nFileSizeHigh)*4294967296 } end
  until ffi.load("kernel32").FindNextFileA(h, fd) == 0
  ffi.load("kernel32").FindClose(h); return out end
function file_exists(p) return ffi.load("kernel32").GetFileAttributesA(p) ~= 0xFFFFFFFF end

--=======================================================================
-- optional: zlib already on disk, if the protocol ever needs inflate
--=======================================================================
-- local z = ffi.load("D:/Claude/otclient_mehah1530/otclient/zd.dll")   -- zlib 1.3.2, verified
-- ffi.cdef[[ int uncompress(unsigned char*, unsigned long*, const unsigned char*, unsigned long);
--            int compress  (unsigned char*, unsigned long*, const unsigned char*, unsigned long);
--            unsigned long adler32(unsigned long, const unsigned char*, unsigned); ]]


## Evidence
- D:/Claude/otclient_mehah1530/otclient/build/win-local/vcpkg_installed/x64-windows-static-release/tools/luajit/luajit.exe — LuaJIT 2.1.1781602682 x64 Windows, FFI present (`pcall(require,'ffi')` -> true); 957440 bytes
- D:/Claude/otclient_web/otclient/build/win-local/vcpkg_installed/x64-windows-static-release/tools/luajit/luajit.exe — SECOND COPY, byte-identical (md5 f1521a5a905a136436fe1f7bc9a1647a, same 957440 bytes)
- luajit.exe PE import scan — only advapi32.dll, gdi32.dll, KERNEL32.dll, user32.dll, winmm.dll; NO lua51.dll: the VM is statically linked, no DLL needs to sit next to it
- luajit.exe copied alone into an empty dir and run -> 'isolated ok LuaJIT 2.1.1781602682' — confirms zero sibling-file dependency
- package.path default = `.\?.lua;<exedir>\lua\?.lua;<exedir>\lua\?\init.lua;` / package.cpath = `.\?.dll;<exedir>\?.dll;<exedir>\loadall.dll` — derived from the exe dir at runtime
- tools/luajit/lua/jit/*.lua — the ONLY bundled Lua modules (bc, bcsave, dis_*, dump, p, v, vmdef, zone). No luasocket, no lfs, no cjson, no ssl, no LuaRocks
- C:/Windows/System32/curl.exe — present; `curl 8.21.0 (Windows) libcurl/8.21.0 Schannel zlib/1.3.2 WinIDN WinLDAP`
- ffi.load succeeds for ws2_32, winhttp, bcrypt, advapi32, kernel32 (all returned userdata)
- scratchpad/lj/wsock.lua + t_sock.lua — RUN: loopback bind/listen/accept + non-blocking connect (WSAEWOULDBLOCK -> select writable -> SO_ERROR 0) + send/recv echo; then real getaddrinfo('example.com') -> 0x9A171468, HTTP GET, 828 bytes, 'HTTP/1.1 200 OK'
- scratchpad/lj/winhttp.lua + t_winhttp.lua — RUN: HTTPS POST to httpbin.org/post, status 200, 525 ms, 792-byte echo, body byte-exact incl. `&`, `%d`, escaped quote; User-Agent OTCLua/1.0
- scratchpad/lj/httpcurl.lua + t_curl.lua — RUN: same POST via io.popen+curl.exe, status 200, 817 ms, 815 bytes; body passed via temp file (--data-binary @file), never the command line
- scratchpad/lj/otcrypto.lua + t_crypto.lua — RUN: 6/6 PASS vs Python reference. XTEA 32B vector, XTEA roundtrip, XTEA zero-key vector, adler32, rsa1024 e=65537 nopad, rsa2048 e=65537 nopad
- t_crypto.lua timings — RSA modpow warm: 1.23 ms @1024-bit, 4.54 ms @2048-bit (cold 1.57 / 4.60). Budget was 500 ms
- t_crypto.lua — XTEA throughput 20x64KiB in 27.03 ms = 46.3 MiB/s
- scratchpad/lj/ref.py + ref.json — independent Python XTEA/adler32/pow() reference vectors; key {0x01234567,0x89ABCDEF,0xFEDCBA98,0x76543210} / plain 000102..1f -> e490d158660e3f4f65cdd38e97a90d15fa7433f92a81faf2d424392f1c569b13
- BCryptGenRandom(NULL, buf, 32, 0x00000002) — RUN: NTSTATUS 0, ff3b6a88…655c, second draw differs. Fallback advapi32!SystemFunction036 (RtlGenRandom) also verified: 3badb08e5b85decd7e3d9ab0049a8594
- scratchpad/lj/genkey.py + t_e2e.lua + verify_e2e.py — END-TO-END: Lua RSA-encrypted a 128-byte block with a generated public modulus; Python decrypted with the private exponent and recovered the XTEA key byte-for-byte (16281254497804730520181b78dd5312) and `user@host.com\0MyPassw0rd\0`; Python XTEA-decrypted Lua's ciphertext to the exact plaintext; zlib adler32 8bef0af5 == Lua's
- scratchpad/lj/t_timer.lua — RUN: WITHOUT timeBeginPeriod(1) select(10ms) means 15.95 ms (worst 20.59); WITH timeBeginPeriod(1) means 10.30 ms (worst 10.85); select(50ms) -> 50.55 ms. QPC smallest observable delta 0.000100 ms
- scratchpad/lj/loop.lua + t_loop.lua — RUN: one select() loop multiplexing a loopback control-plane listener + its client + a real internet socket (non-blocking connect, 828-byte stream, graceful close) + a 100 ms and a 400 ms repeating timer + a 3000 ms one-shot
- scratchpad/lj/t_buf.lua — RUN: packet build table.concat 3.12 us/pkt vs FFI buffer 0.15 us/pkt (20x); parse string.byte 0.22 us vs ffi cast 0.19 us; unaligned uint16 load OK on x64
- t_buf.lua — GOTCHAS: bit.tobit(0xDEADBEEF) = -559038737 (signed), bit.band(x,0xFFFFFFFF) still signed, `x % 2^32` = 3735928559; two identical uintptr_t cdata used as table keys create TWO entries although `a == b` is true
- t_buf.lua — string.pack / string.unpack are nil (Lua 5.1): all serialization must be hand-rolled
- D:/Claude/otclient_mehah1530/otclient/modules/corelib/json.lua:1-23 — rxi json.lua, Copyright (c) 2020 rxi, MIT licence text in header
- modules/corelib/json.lua:25 `_version = '0.1.2'`; :131 `function json.encode(val)`; :365 `function json.decode(str)`; :377 `return json` — usable via dofile/require AND sets the global `json`
- scratchpad/lj/t_json.lua — RUN: decoded a full session/playdata/characters login response; sessionkey's embedded \n preserved; á -> UTF-8 C3 A1; errorCode/errorMessage shape; encode round-trips; json.decode RAISES on bad input (json.lua:179 'expected string for key at line 1 col 2')
- scratchpad/lj/t_fileio.lua — RUN: io.open('rb') slurped the 5,017,714-byte appearances .dat in 3.3 ms; seek end/set works; write/append/read/os.remove works; FindFirstFileA listed data/ (10 entries) and data/things/1530 (5117 entries); GetFileAttributesA existence probe true/false
- D:/Claude/otclient_mehah1530/otclient/data/things/1530/ — 115 MB, 5117 files: appearances-17a72b30…dat, map-*.dat, catalog-content.json (5115 entries: 5109 sprite + appearances/map/fullmap/staticdata/staticmapdata/proficiencies), sprites-*.bmp.lzma
- D:/Claude/otclient_mehah1530/otclient/data/things/1530/assets.json.sha256:1 — content revision `42196` (the value sendLoginPacket transmits)
- D:/Claude/otclient_mehah1530/otclient/init.lua:81 — `["https://www.gunzodus.net/game/login/1530"] = { name="Gunzodus", port=443, protocol=1530, httpLogin=true, useAuthenticator=true, order=1 }`
- D:/Claude/otclient_mehah1530/otclient/init.lua:15,25 — Services.status = https://www.gunzodus.net/game/client_service/1530?s.php ; clientAssets = false
- scratchpad/lj/t_zlib.lua — RUN: ffi.load('D:/…/otclient/zd.dll') -> zlibVersion 1.3.2, compress/uncompress roundtrip OK, zlib adler32 = 0x16460E86 identical to the pure-Lua adler32; ffi.load('…/liblzma.dll') -> lzma_version_string 5.8.3 but LzmaUncompress NOT exported
- scratchpad/lj/t_final.lua — RUN: arg[0]/arg[1]/arg[2] populated; io.stdout:setvbuf('line') true; WSAPoll resolvable in ws2_32; debug.traceback present

## Pitfalls
- luajit.exe lives under build/ in BOTH trees — a clean/reconfigure of the CMake build will delete it. Copy the 957 KB exe into the new client's own directory and depend on that copy.
- A SOCKET is a `uintptr_t` cdata. `t[sock] = x` creates a NEW table entry for every cdata object even when the numeric values are equal (proven: 2 entries for two identical uintptr_t keys), although `a == b` compares true. ALWAYS key tables by `tonumber(sock)`.
- Without `winmm.timeBeginPeriod(1)` every wait rounds up to the 15.6 ms Windows scheduler tick: select(10ms) measured 15.95 ms mean / 20.59 ms worst. With it: 10.30 / 10.85. A 50 ms game tick is impossible without it. Call timeEndPeriod(1) at exit.
- LuaJIT's bit library is SIGNED 32-bit: bit.tobit(0xDEADBEEF) = -559038737 and bit.band(x,0xFFFFFFFF) is STILL negative. To get an unsigned value use `x % 2^32` or `tonumber(ffi.cast('uint32_t', x))`. Formatting a u32 with %d will print a negative number.
- Lua 5.1 has NO string.pack/string.unpack (both nil). Every u8/u16/u32/string field must be hand-rolled; there is no shortcut.
- `connect()` on a non-blocking socket ALWAYS returns WSAEWOULDBLOCK (10035) — that is success, not failure. You must then select() for WRITABILITY and check `getsockopt(SOL_SOCKET=0xFFFF, SO_ERROR=0x1007)`: select reports a *failed* connect as writable too.
- `send()` can return short on a non-blocking socket (WSAEWOULDBLOCK after partial progress). The sketch returns `total, "partial"` — the real client MUST keep a per-socket output queue and re-arm add_write() to drain it, otherwise large outgoing packets are silently truncated.
- Windows `struct addrinfo` orders `ai_canonname` BEFORE `ai_addr`; glibc is the reverse. Copying a Linux cdef silently gives you a garbage sockaddr pointer.
- `struct timeval` uses `long` = 32-bit on Windows (not 64-bit as on Linux x64). A wrong cdef makes select() time out instantly or hang.
- fd_set on Windows is `{u_int fd_count; SOCKET fd_array[FD_SETSIZE];}` with FD_SETSIZE 64, NOT the Linux bitmask. Fine here (2-4 sockets) but do not port Linux FD_SET macros.
- The reactor sketch's first version rescheduled repeating timers as `t.at = now + every`, which accumulates drift: the 100 ms timer fired only 27 times in 3000 ms. Use `t.at = t.at + t.every` (with a catch-up clamp after a long stall).
- json.decode RAISES a Lua error on malformed input (json.lua:179) — it never returns nil. Always pcall it around the login response, which may be an HTML error page or a truncated body.
- json.encode key order is Lua hash order — do not rely on field ordering in the login POST, and do not build a signature over the encoded string.
- All WinHTTP string parameters are UTF-16. Passing a Lua (UTF-8/ANSI) string straight into an LPCWSTR parameter compiles fine under FFI and then fails at runtime in confusing ways. Convert with MultiByteToWideChar(CP_UTF8=65001,…).
- WinHttpSendRequest's dwHeadersLength must be 0xFFFFFFFF (== -1L, 'measure it yourself') when passing a header string; passing the byte length of the UTF-8 form is wrong because the string is wide.
- curl.exe fallback: NEVER put the JSON body on the command line. cmd.exe eats `&`, `%VAR%`, `^` and quotes. Use `--data-binary @tempfile` and `-o tempfile` (the proven form) and delete both files afterwards.
- io.open must use "rb"/"wb"/"ab" on Windows; text mode translates CRLF and corrupts binary assets and packet dumps.
- The RSA modulus must be ODD (asserted) and the plaintext block must be exactly #modulus bytes, zero-padded, and numerically less than n — 'no padding' means the caller owns the whole block layout, including the leading zero byte.
- liblzma.dll in the otclient root is xz-utils 5.8.3 and does NOT export the 7-Zip `LzmaUncompress` that OTClient's sprite loader calls; only the liblzma stream API is available. Sprite decoding is not a solved problem in this runtime.
- package.path/cpath are derived from the EXE directory, and `.\?.lua` is cwd-relative — a script launched from a different working directory will not find its own modules. Set package.path explicitly in the first lines of main.lua.
- `ffi.load('zd.dll')` etc. need a full path or the DLL on PATH; ffi.load does not search the script's directory.

## Open questions
- Where will the new client live, and should luajit.exe be copied out of `build/win-local/vcpkg_installed/...` into that tree so a CMake clean cannot delete it? (Strong recommendation: yes, plus a run.cmd wrapper.)
- Does the 1530 protocol negotiate packet compression (zlib deflate on the wire, as Tibia 12.x+ can)? If so, `ffi.load` on the shipped zd.dll (zlib 1.3.2, verified working) is the answer; otherwise no compression code is needed at all. The protocol agent must confirm from src/client/protocolgame.cpp / features.lua.
- Is the Gunzodus server modulus 1024-bit (classic OTServ) or 2048-bit? Both are proven working and both are far under budget (1.23 ms / 4.54 ms), so this only affects the block size constant — but the protocol agent must supply the exact modulus bytes and the exponent (assumed 65537).
- Does the client need a SECOND RSA key (the OTServ login-server key vs. a distinct game-server key)? The runtime supports any number; just a config question.
- Will the control-plane listener be exposed beyond 127.0.0.1? The bind_listen sketch binds an explicit address (0x0100007F) — if it must be reachable off-box, add an auth token, because the reactor accepts unconditionally.
- Should the client ever decode sprites? If yes, liblzma.dll's 7-Zip-style entry point is missing and a pure-Lua LZMA1 decoder (or lzma_alone_decoder with a hand-built 13-byte header) becomes a real work item. If the client is headless, this is moot.
- Is a graceful TCP shutdown (`shutdown(s, SD_SEND=1)`) needed before closesocket on logout, or does the protocol define its own logout packet that makes it irrelevant?
- Timer cadence: the client's walk/ping loop wants a fixed tick — confirm the exact period the protocol layer needs (50 ms assumed in the sketch) so the reactor's max select wait can be set to match.
- Should the login POST send an authenticator token field (init.lua:81 sets `useAuthenticator = true`)? That is a protocol-layer field, but it changes the JSON body the runtime posts.
- Logging/persistence policy: os.tmpname and %TEMP% are available, but where should packet dumps and the session log be written so they are not mixed into the read-only reference tree?

## VERIFIER (confidence 0.87)

### Corrections (AUTHORITATIVE — these override the spec above)
- **Claim**: Verdict table lists "adler32 — pure Lua — byte-exact vs zlib" as a required primitive, and §4.4 presents "adler32'd the ciphertext" as part of "THE ACTUAL HANDSHAKE SHAPE".
  - **Correction**: At client version 1530 the game socket carries NO adler32 checksum in either direction. Outgoing: `send()` prefers the sequence branch, and `Protocol::onConnect()` turns sequenced packets on for every version >= 1200 BEFORE the login packet is built, so even the login packet gets a 4-byte little-endian sequence counter (m_packetNumber starting at 0, incremented per non-raw packet), never a checksum. Incoming: the 4-byte word is consumed by `getU32()` and only bit 31 is examined (compression flag) — it is never verified as a checksum. adler32 survives only in `Crypt::_encrypt/_decrypt` for local settings blobs (crypt.cpp:155, :182). Keep the routine (it is byte-exact, I re-ran the vector: 0x16460E86) but do not put it on the wire.
  - Evidence: protocol.cpp:159-163 `if (m_sequencedPackets) { outputMessage->writeSequence(m_packetNumber++); } else if (m_checksumEnabled) { outputMessage->writeChecksum(); }`; protocol.cpp:423-431 `if (g_game.getClientVersion() >= 1200) { ... enabledSequencedPackets(); }` called from ProtocolGame::onConnect (protocolgame.cpp:47) before sendLoginPacket; protocol.cpp:251-252 `if (m_sequencedPackets) { decompress = (m_inputMessage->getU32() & 1 << 31); }`; modules/game_features/features.lua:224-225 `if version >= 1290 then g_game.enableFeature(GameSequencedPackets)`
- **Claim**: §4.4 "END-TO-END COMPOSITION PROOF (the actual handshake shape)": "built a 128-byte block `[00][00][16 key bytes][account\0][password\0][zero pad]`".
  - **Correction**: That is not the 1530 RSA block. Correct layout (all strings are u16-LE length-prefixed, never NUL-terminated): [u8 0x00] [u32 key0][u32 key1][u32 key2][u32 key3] (little-endian) [u8 0x00 = "is gm set?"] then, because GameSessionKey is on at >=1074, [str sessionKey][str characterName] — NOT accountName/password — then [u32 challengeTimestamp][u8 challengeRandom] (GameChallengeOnLogin, on at >=841), then [u16 2] (gunz OS marker, os in 60..62), then [str extended data] which is "261" for gunz at >=1281, then zero padding to exactly rsaGetSize() = 128 bytes. There is exactly ONE leading zero byte, not two; the second 0x00 the spec put before the key actually sits AFTER the 16 key bytes. Note also the padding byte value differs by protocol: the game protocol pads with ZEROS (`addPaddingBytes(paddingBytes)`, default byte 0) while protocollogin.lua pads with `math.random(0,0xff)`.
  - Evidence: protocolgamesend.cpp:153-216: `msg->addU8(0); // first RSA byte must be 0` / `generateXteaKey(); msg->addU32(m_xteaKey[0]); ...` / `msg->addU8(0); // is gm set?` / `if (g_game.getFeature(Otc::GameSessionKey)) { msg->addString(m_sessionKey); msg->addString(m_characterName); }` / `if (isGunzOs) msg->addU16(2);` / `const int paddingBytes = g_crypt.rsaGetSize() - (msg->getMessageSize() - offset); msg->addPaddingBytes(paddingBytes);`. outputmessage.cpp:84-94 `addString` = `addU16(len)` + raw bytes. modules/game_features/features.lua:172-174 enables GameSessionKey at >=1074, :50-51 GameChallengeOnLogin at >=841.
- **Claim**: §4.1: "RSA-1024, n = 9b646903b45b07ac…5b7ff5 (the classic OTServ public modulus), e=65537, no padding" — presented as the vector the handshake needs; §4.2 gives `rsa_modpow(msg_be, mod_be, exp)` taking a big-endian modulus.
  - **Correction**: At 1530 the modulus is GUNZODUS_RSA, not OTSERV_RSA, and it is stored as a 309-digit DECIMAL string (1024-bit, e=65537). The spec supplies no decimal→big-endian-bytes conversion, and its bignum layer has no long division, so a reimplementation has nothing to feed `mod_be` with. You must add a decimal-string→byte-array routine (repeated multiply-by-10-add-digit into the 16-bit-limb array is enough) or hard-code the 128 hex bytes. Also note `rsaGetSize()` is `RSA_size()` = 128 and `rsaEncrypt` refuses any size != 128, so the plaintext block must be exactly 128 bytes with a leading 0x00 (guaranteeing m < n).
  - Evidence: modules/gamelib/const.lua:329-333 `GUNZODUS_RSA = '1246273883242314476756177697013661178426967215489621567086238956' .. ...` with the comment "Gunzodus custom 1024-bit modulus, exponent 65537 ... it is what encrypts the 128-byte RSA login block"; modules/game_features/features.lua:295-305 `if version >= 1530 then g_game.setRsa(GUNZODUS_RSA); g_game.setCustomOs(61) end`; crypt.cpp:235-259 `bool Crypt::rsaEncrypt(uint8_t* msg, int size) { if (size != rsaGetSize()) return false; ... return RSA_public_encrypt(size, msg, msg, m_rsa, RSA_NO_PADDING) != -1; }`
- **Claim**: §7: "zlib is available if the 1530 protocol ever needs packet inflate" — treated as optional/nice-to-have.
  - **Correction**: Raw-deflate inflate is MANDATORY at 1530. Every incoming packet whose 4-byte sequence word has bit 31 set is deflate-compressed and must be inflated with a raw stream (`inflateInit2(&z, -15)`, i.e. windowBits -15, no zlib header). Two modes must be supported: PER_PACKET (inflate with Z_FINISH, then inflateReset) and STREAM (append the 4-byte footer 00 00 FF FF, then inflate with Z_SYNC_FLUSH on a persistent stream that is never reset). The mode is auto-detected on the first compressed packet: try Z_FINISH; if it does not return Z_STREAM_END with output, fall through to stream mode. Getting this wrong desynchronises every subsequent packet, because stream mode shares one history window across packets.
  - Evidence: protocol.cpp:41 `inflateInit2(&m_zstream, -15);`; protocol.cpp:274-325 (the `if (decompress)` block, COMPRESSION_MODE_UNKNOWN/PER_PACKET/STREAM); inputmessage.h:106-118 `addCompressionFooter()` → `static const uint8_t footer[] = { 0x00, 0x00, 0xFF, 0xFF };`
- **Claim**: §3(a) Notes: "Schannel does cert validation with the Windows root store — no cacert.pem needed (the one in the otclient root is for libcurl in the C++ client)."
  - **Correction**: Two errors. (1) cacert.pem is loaded by cpp-httplib's SSLClient in the login path, not by libcurl. (2) More importantly, the reference client DISABLES both certificate and hostname verification for the login POST. WinHTTP validates by default, so if gunzodus.net presents a self-signed, expired, or hostname-mismatched certificate the pure-Lua client will fail a login the C++ client completes. You need `WinHttpSetOption(hRequest, WINHTTP_OPTION_SECURITY_FLAGS=31, &flags, 4)` with SECURITY_FLAG_IGNORE_UNKNOWN_CA|IGNORE_CERT_DATE_INVALID|IGNORE_CERT_CN_INVALID|IGNORE_CERT_WRONG_USAGE (0x3300) available as a retry, or the curl fallback with -k, to match reference behaviour. The spec never mentions this and its httpbin.org test could not have exposed it.
  - Evidence: httplogin.cpp:410-412 `client.set_ca_cert_path("./cacert.pem"); client.enable_server_certificate_verification(false); client.enable_server_hostname_verification(false);`
- **Claim**: §6: "encoded request: {\"type\":\"login\",\"stayloggedin\":true,\"token\":\"\",\"tokenChanged\":false,\"email\":...,\"password\":...}" and §3 uses User-Agent "OTCLua/1.0" (praised as "custom UA").
  - **Correction**: The reference body has exactly four keys — email, password, stayloggedin (bool true), type ("login") — and, ONLY when the authenticator token is non-empty, two more keys carrying the same value: token and authenticatorToken. There is no `tokenChanged` key anywhere in this client, and `token` is never sent as an empty string. The header is `User-Agent: Mozilla/5.0` with Content-Type `application/json`; nlohmann emits keys in sorted order (authenticatorToken, email, password, stayloggedin, token, type). If Gunzodus's endpoint is at all strict about the UA or about unknown fields, the spec's body will be rejected.
  - Evidence: httplogin.cpp:413-425 `json body = { {"email", email}, {"password", password}, {"stayloggedin", true}, {"type", "login"} }; if (!token.empty()) { body["token"] = token; body["authenticatorToken"] = token; } const httplib::Headers headers = { {"User-Agent", "Mozilla/5.0"} };`; same shape at :220-223 and :460-475
- **Claim**: §2 / pseudocode `W.select(rlist, wlist, timeout_ms)` calls `ws2.select(0, rs, wr, nil, tv)` — exceptfds always NULL — and the connect flow is documented as "connect → select for writability → getsockopt(SO_ERROR)".
  - **Correction**: On Windows a FAILED non-blocking connect is signalled in exceptfds, not writefds. With exceptfds NULL, a refused/unreachable connect never makes the socket writable and the reactor blocks until its own timeout with no way to distinguish "still connecting" from "failed". Add a third fd_set containing every socket that is in the connect-pending write set, and read SO_ERROR when it fires. The spec's evidence only ever exercised successful connects (loopback and example.com:80), so this path was never tested.
  - Evidence: pseudocode runtime/wsock.lua `local n = ws2.select(0, rs.fd_count>0 and rs or nil, wr.fd_count>0 and wr or nil, nil, tv)`; spec §2 test output shows only `connect -> pending` followed by `select: readable=1 writable=1  so_error=0`
- **Claim**: Pseudocode `Loop:tick` uses `W.select` as the sole sleep mechanism, and `W.select` passes nil for a set whose fd_count is 0.
  - **Correction**: Winsock's `select()` requires at least one non-NULL fd_set containing at least one socket; with all three NULL it returns SOCKET_ERROR/WSAEINVAL immediately instead of sleeping. Any moment the client holds no sockets (before connect, after a disconnect, between reconnect attempts) the reactor becomes a 100%-CPU spin loop that also breaks the timer cadence the whole `timeBeginPeriod(1)` argument rests on. Fall back to `Sleep(wait)` when both lists are empty.
  - Evidence: pseudocode runtime/wsock.lua `ws2.select(0, rs.fd_count>0 and rs or nil, wr.fd_count>0 and wr or nil, nil, tv)` combined with runtime/loop.lua step 3 building `rl`/`wl` from possibly-empty `self.rd`/`self.wr`
- **Claim**: §4.2 / pseudocode: "MSB-first square-and-multiply over the 17 bits of 65537 = 17 modmuls".
  - **Correction**: The loop does 17 squarings plus 2 multiplies = 19 Montgomery multiplications (and the first squaring operates on acc = R mod n, so it is wasted work). Cosmetic only — no wire impact, and the measured 1.23 ms already includes it — but the comment should not be copied into the reimplementation as a correctness invariant.
  - Evidence: pseudocode `for i=#bits,1,-1 do acc = montmul(acc,acc,...); if bits[i]==1 then acc = montmul(acc,xm,...) end end` with #bits = 17 for e = 65537 and bits[17]=bits[1]=1
- **Claim**: §3 / pseudocode: `http_post(url, body, headers, timeout_ms) -> status, body, err`.
  - **Correction**: The implementation returns only two values and never produces `err`; worse, it checks no return value, so a NULL from WinHttpOpen/WinHttpConnect/WinHttpOpenRequest propagates into later calls and the function silently returns status 0 with an empty body. Since `httpcurl.post()` is supposed to be swapped in "behind the same (status, body, err) signature", the fallback contract is unimplemented. Check each handle, call GetLastError() (already cdef'd but never used), and close whatever handles were opened.
  - Evidence: pseudocode runtime/winhttp.lua ends `return tonumber(code[0]), table.concat(parts)`; no `if S == nil` / `if Cn == nil` guards, and `DWORD GetLastError(void);` is declared but never called
- **Claim**: Pseudocode `W.send` returns `total, "partial"` on WSAEWOULDBLOCK.
  - **Correction**: When the very first `send()` blocks, this returns `0, "partial"`, which is falsy-adjacent only by convention: the documented error contract is `nil, errno`, so a caller writing `local n, e = W.send(...) if not n then ...` treats a fully-blocked send as success and silently drops the packet. Return `nil, "wouldblock", total` or make the partial case unambiguous.
  - Evidence: pseudocode runtime/wsock.lua `if e==W.EWOULDBLOCK then return total, "partial" end   -- CALLER MUST QUEUE THE REST`

### Additions
- CORRECT AS WRITTEN, re-verified on this machine: luajit.exe at both paths, 957440 bytes, md5 f1521a5a905a136436fe1f7bc9a1647a (identical); `string.pack` is nil; `ffi.sizeof('long')` == 4 (so the `struct timeval`/`u_long` cdefs are right for Windows x64); `wchar_t` is a predefined ffi type (`ffi.new('wchar_t[4]')` -> `cdata<unsigned short [4]>`); ffi.load succeeds for bcrypt and winhttp. FIONBIO 0x8004667E == -2147195266 signed, correct. FD_SETSIZE 64 matches Winsock's default.
- CORRECT: the XTEA in the spec is byte-identical to the reference. I re-ran the spec's own enc_blk and reproduced both vectors exactly (e490d158660e3f4f65cdd38e97a90d15fa7433f92a81faf2d424392f1c569b13 and d8d4e9ded91e13f7) and adler32 = 0x16460E86. The C++ round function at protocol.cpp:414-419 is `left += ((right<<4 ^ right>>5) + right) ^ (sum + m_xteaKey[sum & 3]); right += ((left<<4 ^ left>>5) + left) ^ (next_sum + m_xteaKey[(next_sum >> 11) & 3]);` with sum starting at 0 and delta 0x9E3779B9 — identical. Worth stating explicitly for the reimplementer: the C++ loops ROUNDS OUTER / BLOCKS INNER (protocol.cpp:344-362 `apply_rounds`), which looks like a chained mode but is not — blocks never interact, so it is plain ECB and the spec's per-block loop is equivalent. Decrypt sum seed `delta << 5` == 0xC6EF3720 matches the spec's `tobit(DELTA*32)`.
- CORRECT: init.lua line citations are exact — :15 `status = "https://www.gunzodus.net/game/client_service/1530?s.php"`, :25 `clientAssets = false`, :81 `["https://www.gunzodus.net/game/login/1530"] = { name="Gunzodus", port=443, protocol=1530, httpLogin=true, useAuthenticator=true, order=1 }`. `data/things/1530/assets.json.sha256` does contain exactly `42196`. The spec's URL regex also matches entergame.lua's own splitter (entergame.lua:1271-1285 strips the scheme, `url:match("([^/]+)(/.*)")`, then pulls a trailing `:%d+` into G.port).
- CORRECT: `httpLogin = true` really does mean "plaintext retry PERMITTED", not "use plaintext" — TLS is always attempted first (httplogin.cpp:265-270 comment and control flow).
- OMISSION (load-bearing for §5.3's "build into a preallocated uint8_t[65536]"): headers are PREPENDED, so the build buffer must reserve exactly 7 bytes of head room at 1530 (`m_maxHeaderSize = g_game.getClientVersion() >= 1405 ? 7 : 8`, outputmessage.cpp:29/36) — 2 bytes size + 4 bytes sequence + 1 byte padding-amount. Final on-wire order for a normal game packet is: [u16 headerSize][u32 sequence][u8 paddingAmount][ ... XTEA-encrypted region ... ], where the encrypted region is [compression mode byte][0][0][0][opcode][body][pad bytes].
- OMISSION: the >=1405 size field is NOT a byte count. `writeHeaderSize()` (outputmessage.cpp:158-162) writes `(m_messageSize - 4) / 8` — i.e. the encrypted region's length in 8-byte units, with the 4 sequence bytes subtracted — and the receiver reverses it as `remainingSize = readSize() * 8U + 4U` (protocol.cpp:222-224). Treating it as a byte length desynchronises the very first read.
- OMISSION: padding rule at >=1405. `writePaddingAmount()` (outputmessage.cpp:151-156): `paddingAmount = 8 - (m_messageSize % 8) - 1`, append that many zero bytes, then PREPEND the count as one byte — so the encrypted region is always a multiple of 8 and the count is in [0,7]. On receive, after XTEA decrypt the first plaintext byte is the padding amount and `decryptedSize = encryptedSize - paddingSize - 1` (protocol.cpp:381-385). This replaces the pre-1405 "u16 decrypted size" convention entirely.
- OMISSION: the compression header. When XTEA is on AND the OS byte is in [60,62] (it is 61 at 1530, features.lua:305 `g_game.setCustomOs(61)`), every outgoing body is prefixed with [mode][0][0][0] INSIDE the encrypted region, ahead of the opcode; mode is always 0 in this client (protocol.h m_outboundCompressionMode). Implemented as a forward memmove because at >=1405 all 7 header bytes are already spoken for (outputmessage.cpp:164-181). Omitting it shifts every gameplay packet by 4 bytes.
- OMISSION: the FIRST bytes on the game socket are not a framed packet. At >=1200 `Protocol::onConnect()` sends the world name plus a trailing '\n' with raw=true — no size prefix, no sequence, no padding, no XTEA — and only then enables sequenced packets (protocol.cpp:422-431). The receive header size for 1530 is 2 + 4 + 1 = 7 (protocol.cpp:199-207: 2 size, +4 because GameProtocolChecksum is enabled at >=840, +1 padding at >=1405).
- OMISSION: the content revision is sent as TEXT, not a u16. At >=1334 with a gunz OS, `msg->addString(std::to_string(resolveGunzContentRevision()))` — i.e. u16 length 5 followed by "42196" (protocolgamesend.cpp:136-143). The `msg->addU16(g_things.getContentRevision())` branch is dead at 1530. Note also this field sits BEFORE the RSA block's `offset` mark, so it is transmitted in the clear.
- OMISSION: protocol version. `g_game.getClientProtocolVersion(1530)` returns 1530 unchanged (modules/gamelib/game.lua:91-104 — the remap table only covers 980..1002), so the login packet carries u16 os=61, u16 protocolVersion=1530, u32 clientVersion=1530, then addString("1530") at >=1281.
- OMISSION worth stating: the login-server response fields the client actually consumes are `errorCode`/`errorMessage`, and otherwise `session` and `playdata.characters` / `playdata.worlds` — all three are re-serialized back to strings and handed to Lua (httplogin.cpp:494-527). Missing `session` or `playdata` is a hard failure. The spec's §6 JSON handling is otherwise correct, including that the sessionkey's embedded newlines must survive — they do, because it goes into the RSA block via a u16-length-prefixed addString, not a NUL-terminated one.
- Note for the reimplementation: `zd.dll` (zlib 1.3.2) is the DEBUG-suffixed build that ships next to the debug otclient; do not assume it exists in a clean tree. Since raw inflate is mandatory (see correction 4), either vendor the DLL alongside the Lua client or write a pure-Lua raw-inflate. liblzma.dll matters only for sprites and is genuinely irrelevant headless.
- Minor, non-wire: the pseudocode's `key(s) = tonumber(s)` on a `uintptr_t` SOCKET is correct for Windows handle values but silently loses precision above 2^53; and `Loop:add_write` is documented one-shot but `Loop:tick` as excerpted never deletes the entry after firing (the excerpt is truncated mid-function, so this may be handled below the cut — flagging as an ambiguity to close, not a confirmed bug).
