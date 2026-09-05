# Portability: Windows + Linux (Debian) from one source tree

Target: the same `.lua` files run unchanged on Windows 10/11 x64 and Debian 12/13 x64 under LuaJIT
2.1 with FFI. Verified environments on this machine:

| | Windows | Linux |
|---|---|---|
| interpreter | `D:\Claude\otclient_mehah1530\otclient\build\win-local\vcpkg_installed\x64-windows-static-release\tools\luajit\luajit.exe` (LuaJIT 2.1.1781602682) | Debian 13 trixie under WSL2, `apt install luajit` (LuaJIT 2.1.1737090214), run as `wsl -d Debian -e sh -c 'cd /mnt/d/Claude/otclient_web/luaclient && luajit …'` |
| detection | `require('ffi').os == 'Windows'` | `== 'Linux'` |

Baseline measured before porting: on Debian the pure-Lua half already passes — buffer, xtea, adler32,
inflate, events, items, login_http, transport, state, parser, sender = 218 assertions PASS. Only the
platform layer fails (`libws2_32.so` missing, `bcrypt` missing). So porting is confined to four files.

## What must change, and to what

### lib/sys.lua
| need | Windows | Linux |
|---|---|---|
| monotonic clock | `QueryPerformanceCounter`/`Frequency` (kernel32) | `clock_gettime(CLOCK_MONOTONIC=1, &ts)` from libc; `struct timespec { long tv_sec; long tv_nsec; }` (64-bit fields on x86_64) |
| sleep | `Sleep(ms)` (kernel32) | `nanosleep(&req, NULL)`, retry on `EINTR` |
| CSPRNG | `BCryptGenRandom(NULL, buf, n, 2)` | `getrandom(buf, n, 0)` via `syscall(318, …)` **or** simply read `/dev/urandom` with `io.open('/dev/urandom','rb')` — prefer `getrandom` when the symbol resolves (glibc ≥ 2.25 exposes it directly), fall back to `/dev/urandom`, and hard-error if neither works |
| timer resolution | `timeBeginPeriod(1)` / `timeEndPeriod(1)` (winmm) | not applicable — skip |
| exit hooks | keep as-is (pure Lua) | same |

Do not `ffi.cdef` a symbol on the wrong OS: cdefs are global and colliding declarations across
modules raise. Declare each OS's structs/functions inside its own branch.

### lib/socket.lua
The BSD API is nearly identical; the differences that matter:

| | Windows | Linux |
|---|---|---|
| library | `ffi.load('ws2_32')` | `ffi.C` (libc; no load needed) |
| startup | `WSAStartup(0x0202, &wsadata)` | none |
| handle type | `SOCKET` = `uintptr_t`, invalid = `~0` | `int` fd, invalid = `-1` |
| close | `closesocket` | `close` |
| non-blocking | `ioctlsocket(s, FIONBIO=0x8004667E, &1)` | `fcntl(fd, F_SETFL=4, O_NONBLOCK=04000)` |
| last error | `WSAGetLastError()` | `errno` — read via `ffi.errno()` |
| "would block" | `WSAEWOULDBLOCK` 10035 | `EAGAIN`/`EWOULDBLOCK` 11 |
| connect in progress | `WSAEWOULDBLOCK` 10035 | `EINPROGRESS` 115 |
| conn refused | `WSAECONNREFUSED` 10061 | `ECONNREFUSED` 111 |
| conn reset | `WSAECONNRESET` 10054 | `ECONNRESET` 104 |
| interrupted | n/a | `EINTR` 4 — **retry the call**, Windows never returns it |
| readiness | `select()` with `fd_set { u_int fd_count; SOCKET fd_array[64]; }` | `poll(struct pollfd*, nfds_t, int timeout_ms)` — use poll, it has no FD_SETSIZE limit and no bitmask packing |
| failed connect signalled via | **exceptfds only** | `POLLOUT` + `getsockopt(SO_ERROR)`; also `POLLERR`/`POLLHUP` |
| `sockaddr_in` | same layout (`sin_family` u16, `sin_port` u16 BE, `sin_addr` u32, 8 pad) | same |
| `getaddrinfo` | ws2_32, `struct addrinfo` has `ai_canonname` **before** `ai_addr` | libc, `ai_addr` **before** `ai_canonname` — the struct field order genuinely differs, declare per OS |
| SIGPIPE on send to a closed peer | n/a | would kill the process: pass `MSG_NOSIGNAL` (0x4000) to `send`, or `signal(SIGPIPE, SIG_IGN)` at init |

Keep the public API in `API.md` exactly as it is; only the internals branch. `socket.select(read,
write, timeoutMs)` stays the public name even though Linux implements it with `poll`.

### lib/sched.lua
Only its socket-readiness call touches the OS; once `lib/socket.lua` exposes a uniform
`socket.select`, sched needs at most a guard for "no sockets registered" (Windows `select` with three
empty sets returns `WSAEINVAL`; Linux `poll(NULL, 0, ms)` is a legal sleep). Keep the existing
sleep-instead-of-select path for both.

### lib/http.lua
| | Windows | Linux |
|---|---|---|
| preferred | WinHTTP FFI (already implemented, zero deps) | `libcurl` via FFI (`libcurl.so.4`) — present on Debian once `curl` is installed; use the easy interface (`curl_easy_init/setopt/perform/getinfo/cleanup`) with `CURLOPT_WRITEFUNCTION` into a Lua buffer |
| fallback | `curl.exe` (ships with Windows 10+) | `curl` CLI |
| last resort | — | error with an actionable message: `apt install curl` |

Selection is automatic at load: try the native binding, fall back to the CLI, and expose
`http.backend()` for the log line. The CLI fallback must not leak credentials into a command line
that other users can see in `ps`: write the JSON body to a temp file (`os.tmpname()`, mode 600 on
Linux) and pass `--data-binary @file`, then delete it.

## Other portability items

* **Paths**: build paths with `/` everywhere (Windows accepts them). `main.lua` derives the project
  root from `arg[0]`; handle both separators when splitting. No `\\` literals in path code.
* **Line endings**: read files in binary mode (`'rb'`) — already done for `items1530.bin`.
* **`os.tmpname()`** returns a bare name like `\s2ck.` on Windows: prefix it with `os.getenv('TEMP')`
  when it is not absolute.
* **run scripts**: keep `run.bat` and add `run.sh` (`#!/bin/sh`, finds `luajit` on `PATH`, `exec`s it
  with `"$@"`, propagates the exit code). Mark it executable in git (`git update-index --chmod=+x`).
* **`tools/extract_appearances.py`**: already pure Python 3; make its default input path a CLI
  argument rather than a Windows path.
* **No `\r\n` assumptions** in the HTTP/WebSocket code (the control plane, step 3) — always emit
  `\r\n` explicitly rather than relying on the platform.

## Acceptance

`test/selftest.lua` must print `TOTAL: … 0 failed -> PASS` on **both**:

```
run.bat --selftest                                    # Windows
wsl -d Debian -e sh -c 'cd /mnt/d/Claude/otclient_web/luaclient && ./run.sh --selftest'
```

and the live invalid-account login (`--account=zzz-not-a-real-account --password=x`) must print the
server's own error and exit 2 on both.
