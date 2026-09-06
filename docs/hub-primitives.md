# Hub primitives: HTTP, WebSocket and process supervision

`lib/httpserver.lua`, `lib/wsserver.lua`, `lib/sha1.lua` and `lib/process.lua` are the
server-side primitives the web panel described in `PANEL.md` is built on. They were
adversarially reviewed after they were first written; this page records the rules that
came out of that review, because most of them are rules the *caller* has to honour.

Suites: `test/httpserversuite.lua`, `test/wssuite.lua`, `test/processsuite.lua`.

---

## 1. Handing a socket to another protocol (WebSocket)

An HTTP connection that becomes a WebSocket must **leave** the HTTP server. Until it
does, the HTTP server still owns it: the idle sweep still counts it, and when the sweep
fires it writes a raw `HTTP/1.1 408` **into the middle of the established WebSocket byte
stream** and closes the TCP connection — while the WebSocket layer, whose socket
callbacks have just been removed, never learns that anything happened. Every panel
socket would die after `idleTimeoutMs` of WebSocket silence.

The hand-over is explicit:

```lua
local sock, pending = res:upgrade()
-- sock    : the raw lib/socket.lua socket, now YOURS (including closing it)
-- pending : every byte the peer already sent past the header block
wsserver.upgrade(sock, req, { pending = pending, allowedOrigins = ..., ... })
```

After `res:upgrade()` the HTTP server has forgotten the connection completely:

* it is out of `server.conns`, so the idle sweep never sees it;
* `stats().connections` / `stats().active` no longer count it (`stats().upgrades` does),
  so it is not charged against `maxConnections` either;
* nothing in `lib/httpserver.lua` will write to it or close it again — `fail()`,
  `destroy()`, `sweep()` and both socket callbacks are no-ops for a detached connection,
  so closing it from the new owner cannot double-close.

Because upgraded sockets stop counting against `maxConnections`, **the WebSocket layer
needs its own cap**: pass `maxConnections` to `wsserver` (it answers 503 above it).

`httpserver.websocketRoute(wsserver, opts)` wires the whole thing up and, importantly,
**refuses on the HTTP layer**: `wsserver.checkRequest()` runs first, and a refusal
(wrong version, a foreign Origin, the connection cap) is answered as an ordinary HTTP
response on a connection that stays a perfectly good keep-alive HTTP connection. Only an
accepted handshake detaches.

```lua
local route = httpserver.websocketRoute(require('lib.wsserver'), {
    allowedOrigins = { 'https://panel.example' },
    maxConnections = 256,
    onMessage = function (ws, msg) ... end,
})
```

## 2. Origin is mandatory, and the default is deny

A browser attaches the hub's session cookie to a WebSocket handshake **no matter which
page opened it**, and the WebSocket handshake is not subject to CORS. Without an Origin
check, any page the operator visits can drive an authenticated panel session — which in
`PANEL.md`'s terms means `exec {code}` inside every worker, `script.put`, and the
game-account credentials. So:

| `allowedOrigins` | meaning |
|---|---|
| *(absent)* | **same-origin only** — the Origin's host must equal the `Host` header's host, and their ports must agree whenever both state one |
| `{ 'https://panel.example', 'localhost:8080' }` | an explicit list; full origins or bare authorities, case-insensitive, default ports (80/443) normalised away |
| `function (origin, req) -> boolean` | any policy you like |
| `'*'` | allow everything. Say it out loud before you use it. |

`allowNoOrigin = true` additionally allows a handshake with **no** Origin header at all,
i.e. a non-browser client (curl, another Lua process, the test suites). It is off by
default: a browser always sends Origin, so a missing one is either a native client or an
attempt to dodge the check, and the hub has to opt into that deliberately.

A mismatch is **403 before the upgrade**. The scheme is deliberately not compared
(`PANEL.md` puts the hub behind nginx/Caddy terminating TLS, so the browser sees
`https://` and the hub sees `http://`), and a port is compared only when both sides state
one, for the same reason.

**Origin alone does not close DNS rebinding.** A page that points a hostname it controls
at `127.0.0.1` produces a request that is genuinely same-site (so the cookie is sent)
*and* same-origin (so the check above passes). Pinning the authority is what closes it,
on the HTTP server:

```lua
httpserver.new{ ..., allowedHosts = { '127.0.0.1', 'localhost', 'panel.example' } }
```

A `Host` outside the list is 400. The option is off by default because the right list is
a property of the deployment — **the hub must set it.**

## 3. Deadlines: sliding timers are not enough

`idleTimeoutMs` is a sliding window that any byte resets, so one byte per
`idleTimeout / 2` held a connection, and up to `maxBodyBytes` of buffered body, forever —
until `maxConnections` was exhausted and the hub stopped answering anybody. Two absolute
deadlines now run alongside it:

* `headerTimeoutMs` (default 10 s) — armed by the **first byte** of a request head and
  cleared when the head parses. An idle keep-alive connection between requests is
  therefore still governed by `idleTimeoutMs` alone.
* `requestTimeoutMs` (default 30 s) — armed when the head parses, cleared when the
  response starts. It covers the body and the handler, including a handler that answers
  from a later reactor turn. Once the response is being written, the write path is
  governed by `maxWriteBacklog` instead.

Both answer 408 and are counted in `stats().deadlines`.

The WebSocket layer has the same distinction. `idleTimeout` is reset by a **completed
frame**, not by a byte, and `awaitingPong` is cleared by a **PONG frame**, not by any
inbound byte — otherwise a peer dribbling one byte per `idleTimeout / 2` is immortal and
`pongTimeout` can never fire. A half-delivered frame additionally gets `frameTimeout`
(default 30 s), after which the connection is failed with 1008.

## 4. Framing is CRLF, and the server owns it

* A bare LF is **not** a line terminator — not in the head, not in a header line, not on
  a chunk-size line, not as a chunk terminator, not in the trailer section. A front end
  that requires CRLF and a hub that accepts LF disagree about where a message ends, and
  that disagreement is request smuggling (RFC 9112 §2.2). `opts.allowBareLF = true`
  restores the old tolerance for hand-typed clients.
* A chunk-size line is `<hex>` optionally followed by `;ext`. A prefix match accepted
  `5junk` as 5 and read `0x5` as `0` — the *last* chunk — after which the real body was
  swallowed as trailer lines and the bytes behind it were dispatched as a pipelined
  request.
* A repeated `Content-Length`, `Transfer-Encoding` or `Host` is 400, not a merge, so the
  value a handler reads is exactly the value the framing used.
* On the way out, `Content-Length` is written by the server and a handler cannot
  override it (response desync), and a single-valued response header set twice is
  emitted once, last writer wins. `Set-Cookie`, `WWW-Authenticate`,
  `Proxy-Authenticate`, `Vary` and `Link` may still repeat. This matters for the panel:
  a stray `res:header('Content-Type', 'text/html')` in front of `res:json()` used to put
  two `Content-Type` headers on the wire, and browsers honour the first — stored XSS in
  an authenticated admin page that echoes chat lines and worker log lines.

Decoding is linear in the bytes received: the parser reads at an offset and compacts
amortically instead of rebuilding the input buffer per token. A 128 KB body delivered as
131 072 one-byte chunks went from ~1.3 s of the single reactor thread to ~60 ms.

## 5. Secrets never go in argv

`PANEL.md`'s proxy section asks for `--proxy-auth=user:pass` on the worker's command
line. On Linux `/proc/<pid>/cmdline` is mode 0444: **every local user, and every
`ps aux`, reads that password for as long as the worker lives**, which defeats the
at-rest encryption `proxies.json` uses. On Windows it is not world-readable but it is
still in the PEB, in WMI, in ETW process-start events and in audit event 4688.
`h:describe()`'s `***` only ever affected the hub's own log line, never the argv the
kernel publishes.

`process.spawn` therefore **refuses** a command line carrying a recognised secret
(`--password=`, `--proxy-auth=`, `--proxyAuth:`, a value after a bare `--token`, … —
case-insensitively, with `=` or `:` as the separator) and says so:

```
process.spawn: refusing to place a secret in argv (--proxy-auth, argument 4)
               -- pass it on stdin with opts.stdinData
```

The supported path is the private anonymous pipe, which has exactly two ends:

```lua
local h = process.spawn{
    cmd       = { worker, '--headless', '--proxy=' .. host .. ':' .. port },
    stdinData = 'proxy-auth ' .. user .. ':' .. pass .. '\n',
    -- stdin stays open afterwards for the control protocol
}
```

and the worker reads that first line before anything else. `opts.secretArgs` (argv
indices and/or literal values) masks anything the denylist cannot recognise — `-p
hunter2` — in `h:describe()`; `opts.allowSecretsInArgv = true` is the deliberate,
documented override.

**This requires `PANEL.md` and the worker CLI to change**: the proxy section still
specifies `--proxy-auth=user:pass`, and the worker must learn to read the credential
from its first stdin line.

## 6. Supervision details worth knowing

* `stop(graceMs)` escalates to SIGKILL / `TerminateProcess` on a `lib/sched.lua` timer
  when a reactor is available, not only when someone happens to call `poll()` — a child
  that ignores SIGTERM used to outlive its grace window whenever the poll cadence
  lapsed. `poll()` remains the fallback for a program without a reactor.
* The escalation never signals a pid that has already been reaped. Between `waitpid()`
  and `_done` there is a drain window (a grandchild can hold the capture pipe open) in
  which the pid already belongs to the kernel again, and `kill(pid, SIGKILL)` would land
  on whatever process of this user had since been given that number.
* `Handle:write()` is bounded by `maxStdinQueue` (default 1 MiB) and returns
  `nil, 'stdin queue full'` — a worker that stops reading stdin cannot make the hub
  buffer for it without limit. `h:pendingStdin()` reports the depth.
* `maxLineBytes` is clamped to at least 1024. `0` is a plausible spelling of "no limit"
  and used to spin the reactor forever the first time a child wrote a byte without a
  newline.

## 7. What the hub still has to do

1. Set `allowedHosts` on the HTTP server and `allowedOrigins` on the WebSocket route
   from its own configuration (bind address, public origin), and set `maxConnections`
   on the WebSocket route.
2. Route `GET /ws` through `httpserver.websocketRoute` (or call `res:upgrade()` itself
   only after `wsserver.checkRequest()` has said yes).
3. Register `process.pollAll` on the reactor as usual, and treat a `nil, 'stdin queue
   full'` from `h:write()` as a reason to restart the worker.
4. Pass the proxy credential on stdin, per §5.
