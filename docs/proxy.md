# HTTP `CONNECT` proxy support

What the reference client (`D:/Claude/otclient_mehah1530/otclient`) actually puts on the wire, byte
for byte, and what `lib/proxy.lua` does with it. Everything below was read out of the reference
sources listed in **Sources**, not guessed.

**The `## VERIFIER` / "do NOT copy" notes override the descriptive text above them**, in the same
spirit as the other docs in this directory.

---

## 1. Why this exists

`docs/live-login-notes.md` records the evidence: the endpoint the user's real client is configured
with, `31.59.20.176:6754`, is **not a game server**. Probing it answers

```
HTTP/1.1 407 Proxy Authentication Required
Proxy-Authenticate: Basic realm="Invalid proxy credentials or missing IP Authorization."
```

so it is an HTTP proxy with Basic auth, and the account may be IP-restricted to the proxy's exit
address. Without a `CONNECT` tunnel a live login may be impossible no matter how correct our
framing is.

The stored entry lives in `otclient/profiles/config.otml`:

```otml
httpProxy/enabled: true
httpProxy/entries:
  1:
    port: 6754
    user: <redacted - see profiles/config.otml>
    pass: <redacted - see profiles/config.otml>
    name: 31.59.20.176:6754
    host: 31.59.20.176
httpProxy/selected: 31.59.20.176:6754
httpProxy/expanded: true
```

Five keys per entry: `name` (the combo-box label, conventionally `host:port`), `host`, `port`
(a number), `user`, `pass`. `pass` is stored **in clear text** in `config.otml`. `httpProxy/selected`
holds the `name` of the active entry and `httpProxy/enabled` is the "use proxy" checkbox.

> `panel`'s `proxies.json` (see `PANEL.md`) is the same shape plus an id and a label, with `pass`
> encrypted at rest instead of clear. Nothing in this repo may write a proxy password to a log.

---

## 2. The game socket: what the reference sends

`Connection::connect()` (`src/framework/net/connection.cpp:94`) latches
`g_http_proxy.isActive()` at the moment of the call and, when active, **resolves and TCP-connects to
the proxy instead of the game host**, remembering the real target in `m_proxyTargetHost` /
`m_proxyTargetPort`. `onConnect()` then does *not* fire the caller's connect callback; it calls
`startProxyHandshake()` (`connection.cpp:293`) instead — "the caller must not be told 'connected'
until the proxy answers 2xx to the CONNECT".

### 2.1 Exact request bytes

`target = m_proxyTargetHost + ":" + std::to_string(m_proxyTargetPort)` — the **game** host and port,
not the proxy's. The request is assembled by plain string concatenation, in exactly this order:

```
CONNECT <target> HTTP/1.1\r\n
Host: <target>\r\n
User-Agent: OTClient\r\n
Proxy-Connection: keep-alive\r\n
[Proxy-Authorization: Basic <base64(user ":" pass)>\r\n]     <- only when user is non-empty
\r\n
```

For a target of `game.example.net:7171` with no credentials, the literal 92 bytes are:

```
43 4F 4E 4E 45 43 54 20 67 61 6D 65 2E 65 78 61   CONNECT game.exa
6D 70 6C 65 2E 6E 65 74 3A 37 31 37 31 20 48 54   mple.net:7171 HT
54 50 2F 31 2E 31 0D 0A 48 6F 73 74 3A 20 67 61   TP/1.1..Host: ga
6D 65 2E 65 78 61 6D 70 6C 65 2E 6E 65 74 3A 37   me.example.net:7
31 37 31 0D 0A 55 73 65 72 2D 41 67 65 6E 74 3A   171..User-Agent:
20 4F 54 43 6C 69 65 6E 74 0D 0A 50 72 6F 78 79    OTClient..Proxy
2D 43 6F 6E 6E 65 63 74 69 6F 6E 3A 20 6B 65 65   -Connection: kee
70 2D 61 6C 69 76 65 0D 0A 0D 0A                  p-alive....
```

With credentials `bob` / `s3cr3t`, one more header is inserted between `Proxy-Connection` and the
terminating blank line:

```
Proxy-Authorization: Basic Ym9iOnMzY3IzdA==\r\n
```

There is **no** `Content-Length`, **no** `Connection`, **no** `Accept`, and no body. The header
block ends with a bare `\r\n` (i.e. `...keep-alive\r\n\r\n`).

### 2.2 How `Proxy-Authorization: Basic` is built

```cpp
const auto credentials = g_http_proxy.getUser() + ":" + g_http_proxy.getPass();
request += "Proxy-Authorization: Basic " + g_crypt.base64Encode(credentials) + "\r\n";
```

* Concatenate `user`, a single `:`, `pass` — **raw bytes, no URL-decoding, no trimming, no
  escaping**. A `:` inside the password is fine (only the first one is a separator when the proxy
  splits it back); a `:` inside the *username* would break the credential, and nothing checks.
* `Crypt::base64Encode` is `cppcodec::base64_rfc4648::encode` (`src/framework/util/crypt.cpp:90`):
  the standard `A–Z a–z 0–9 + /` alphabet, `=` padding, **no line breaks**.
* The header is emitted only when `hasAuth()`, which is `!m_user.empty()` — an **empty username with
  a non-empty password sends no header at all**.

RFC 4648 vectors this must match (`lib/proxy.lua` is tested against them):

| plaintext | base64 |
|---|---|
| `` | `` |
| `f` | `Zg==` |
| `fo` | `Zm8=` |
| `foo` | `Zm9v` |
| `foob` | `Zm9vYg==` |
| `fooba` | `Zm9vYmE=` |
| `foobar` | `Zm9vYmFy` |
| `bob:s3cr3t` | `Ym9iOnMzY3IzdA==` |

### 2.3 What responses are accepted

`onProxyHandshakeRead()` (`connection.cpp:354`) is driven by
`async_read_until(m_socket, m_inputStream, "\r\n\r\n", …)`, so asio delivers as soon as the byte
sequence `\r\n\r\n` appears; `recvSize` is the offset just past that terminator. Then:

```cpp
const std::string_view headers(buffer_cast<const char*>(m_inputStream.data()), recvSize);
const auto lineEnd  = headers.find("\r\n");
const std::string statusLine{ headers.substr(0, lineEnd == npos ? headers.size() : lineEnd) };

m_inputStream.consume(m_inputStream.size());          // <- see 2.5
m_proxyHandshakeBuf.reset();

const auto codeStart = statusLine.find(' ');
const bool ok = codeStart != npos && codeStart + 1 < statusLine.size() &&
                statusLine[codeStart + 1] == '2';
```

So the entire acceptance test is: **the character after the first space in the first line is `'2'`**.

* `HTTP/1.1 200 Connection established` → accepted. So is `HTTP/1.0 200 OK`, and so is any other
  `2xx` (`204`, `299`, …).
* Nothing else is examined: not the HTTP version, not the reason phrase, not any header.
* On success `m_connectCallback()` finally fires and the protocol layer starts — for us that is the
  point where the raw world-name preamble goes out. **The tunnelled protocol is unchanged**: the
  game bytes are the same as on a direct connection.

### 2.4 407 / 403 / timeout

There is exactly one failure path for all three:

* **Non-2xx (407, 403, 502, anything).** It logs
  `HTTP CONNECT proxy <phost>:<pport> rejected the tunnel to <thost>:<tport> - <statusLine>`
  and calls `handleError(asio::error::connection_refused)`, which surfaces to the client as an
  ordinary connection error. **The `Proxy-Authenticate` header — and therefore the realm string the
  proxy uses to explain *why* (`"Invalid proxy credentials or missing IP Authorization."`) — is
  parsed by nobody and shown to nobody.** There is no retry, no re-auth, no Digest support.
* **Timeouts.** The write of the request arms `m_writeTimer` for `WRITE_TIMEOUT`; the header read
  arms `m_readTimer` for `READ_TIMEOUT`. Both constants are `30` seconds
  (`connection.h`, and the same values `proto/transport.lua` already uses). Firing either calls
  `onTimeout` → `handleError`. A proxy that accepts the TCP connection and then says nothing stalls
  for the full 30 s and then reports a generic connection error.
* **TCP-level failure** to the proxy itself is indistinguishable from a game-server failure at the
  UI: the caller only ever asked for `host:port` and gets an error.

### 2.5 Things the reference does that we must NOT copy

1. **It throws away bytes that arrive after the header block.**
   `m_inputStream.consume(m_inputStream.size())` drops the *whole* input streambuf, not just the
   `recvSize` header bytes — and `async_read_until` is allowed to have read arbitrarily far past the
   delimiter. The comment argues it is safe because "a compliant proxy sends nothing else before the
   tunnel opens, and the game protocol has the client speak first". That is true for *this* protocol
   and *compliant* proxies, and false in general. `lib/proxy.lua` hands those bytes back as
   `leftover`, and the transport must prepend them to its receive accumulator.
2. **CRLF only.** `async_read_until(…, "\r\n\r\n")` cannot terminate on a bare-LF header block, and
   the status-line split uses `find("\r\n")`. A proxy answering with LF-only line endings hangs
   until the 30 s read timeout. `lib/proxy.lua` treats *any* empty line as the end of the headers.
3. **The acceptance test is far too loose.** `statusLine[codeStart+1] == '2'` accepts
   `HTTP/1.1 2`, `GARBAGE 2`, or `x 2junk`. We require `HTTP/<version> <3 digits>`.
4. **No cap on the header block.** A hostile or broken proxy can stream headers forever; asio's
   streambuf grows until the read timeout. `lib/proxy.lua` fails at `maxHeaderBytes` (32 KiB).
5. **1xx interim responses are rejected**, since `'1' ~= '2'`. RFC 9110 requires a client to be able
   to skip them. `lib/proxy.lua` skips them by default (`interim = 'skip'`).
6. **No IPv6 bracketing.** `host + ":" + port` produces `::1:7171`, which is not a valid authority.
   `lib/proxy.lua` emits `[::1]:7171`.
7. **No header-injection guard.** Host, user and pass go into the request unvalidated; a `\r\n` in
   any of them splices attacker-controlled headers into the request. `lib/proxy.lua` rejects CR, LF
   and NUL in every interpolated field.
8. **`Proxy-Connection: keep-alive` is a non-standard hop-by-hop hint** and is meaningless on a
   `CONNECT` that either opens a tunnel or fails. We keep it anyway, because matching the reference
   byte-for-byte is worth more than protocol purity here — the proxy in question is known to work
   with these exact bytes. It is switchable (`proxyConnection = false`).
9. **The state is global and latched mid-flight.** `g_http_proxy` is a process-wide singleton read
   by both the login HTTP client and every `Connection`; its own header warns "Do not mutate while a
   login is in flight". Our worker is one character per process, but the hub will run many, so the
   proxy settings belong to the *connection object*, never to a module-level global. `lib/proxy.lua`
   holds no state outside the handshake object it returns.

---

## 3. The HTTPS login POST: the same proxy, different bytes

**Yes — the same proxy fronts the login POST.** `EnterGame.applyHttpProxy()`
(`modules/client_entergame/entergame.lua:867`) is called from `doLogin()` and is "the single gate for
every proxied byte of a session": it reads the four UI fields (falling back to the saved entry when
they are blank), and calls `g_http_proxy.setProxy(host, port, user, pass)` or `g_http_proxy.clear()`.
`g_http_proxy` is then read by *both* `connection.cpp` (the game socket, above) and
`httplogin.cpp`.

`httplogin.cpp` applies it through cpp-httplib rather than by hand
(`applyHttpProxy<T>(T& client)`, `httplogin.cpp:155`, called at three sites — the debug
`startHttpLogin` SSLClient, `loginHttpsJson`'s SSLClient, and `loginHttpJson`'s plain Client):

```cpp
client.set_proxy(g_http_proxy.getHost(), g_http_proxy.getPort());
if (g_http_proxy.hasAuth())
    client.set_proxy_basic_auth(g_http_proxy.getUser(), g_http_proxy.getPass());
```

That means the tunnel for the **login POST is opened by httplib, not by the code in §2**, and the
bytes differ:

* For **HTTPS** (`SSLClient`, the real path — `loginHttpsJson`) httplib's
  `SSLClient::connect_with_proxy` (httplib 0.48.0) sends its own `CONNECT`:
  `CONNECT <host>:<port> HTTP/1.1` with httplib's default headers — `Host:`, `Accept: */*`,
  `Accept-Encoding: …`, `User-Agent: cpp-httplib/0.48.0` — plus
  `Proxy-Authorization: Basic <base64(user:pass)>` (`make_basic_authentication_header(..., true)`,
  identical construction to ours). It then requires **exactly 200**, not any 2xx, and on a 407 it
  will retry with *Digest* if digest credentials were set (they never are here).
* For **plain HTTP** (`Client`) httplib does not tunnel at all: it forwards the request by absolute
  URI with `Proxy-Authorization` on the request itself.
* `httplib` also honours `NO_PROXY` and only attaches `Proxy-Authorization` when the proxy is
  actually used for that host.

For `lib/http.lua` (owned by another agent) the equivalent is a backend option, not a re-use of this
module: WinHTTP takes `WINHTTP_ACCESS_TYPE_NAMED_PROXY` + `WINHTTP_OPTION_PROXY_USERNAME/PASSWORD`,
libcurl takes `CURLOPT_PROXY` + `CURLOPT_PROXYUSERPWD` (+ `CURLOPT_PROXYAUTH = CURLAUTH_BASIC`), and
`curl.exe` takes `-x host:port -U user:pass --proxy-basic`. `lib/proxy.lua` is **only** for the raw
game socket. See `crossFileRequests` in the P3 report.

Also worth copying from `httplogin.cpp`: it treats `proxy-authorization` (alongside `authorization`,
`cookie`, `set-cookie`, `x-auth-token`) as a **sensitive header key** and prints `<redacted>` for it
in its request/response logger. `lib/proxy.lua` exposes `handshake.requestRedacted` and
`proxy.redact(request)` for exactly this; log those, never `handshake.request`.

---

## 4. What `lib/proxy.lua` provides

Pure Lua, no sockets, no globals, no timers — you feed it bytes, it answers. The transport owns the
socket and the clock.

```lua
local proxy = require('lib.proxy')

-- one-shot builder (returns the request and a log-safe copy)
local req, redacted = proxy.buildConnect{ host = 'game.example.net', port = 7171,
                                          user = 'bob', pass = 's3cr3t' }

-- the state machine
local hs = proxy.newHandshake{
  host = 'game.example.net', port = 7171,      -- the CONNECT target (the GAME server)
  user = 'bob', pass = 's3cr3t',               -- proxy credentials, optional
  proxyHost = '31.59.20.176', proxyPort = 6754,-- informational: error messages only
  timeoutMs = 30000,                           -- default; matches Connection::READ_TIMEOUT
  maxHeaderBytes = 32768,                      -- default
  nowMs = sys.nowMs(),                         -- optional: starts the timeout clock
}

sock:send(hs.request)                          -- write these bytes first, unframed
log.debug('proxy > %s', hs.requestRedacted)    -- NEVER log hs.request

-- then, for every chunk that arrives:
local st, a, b = hs:feed(chunk, sys.nowMs())
--   st == 'need-more'   keep reading
--   st == 'connected'   a = leftover: early tunnel bytes, feed them to the framer FIRST
--   st == 'error'       a = message, b = kind
--                       kind ∈ 'auth-required'|'rejected'|'malformed'|'too-large'
--                              |'timeout'|'closed'
hs:tick(sys.nowMs())    -- same return shape; call from the 1 s watchdog to enforce timeoutMs
hs:eof()                -- the peer closed mid-handshake -> 'error', …, 'closed'
```

After a `407` the fields that matter for the operator are populated:
`hs.status == 407`, `hs.reason`, `hs.realm` (`"Invalid proxy credentials or missing IP
Authorization."` for this proxy), `hs.authSchemes = { 'Basic' }`, and `hs.headers` /
`hs.headerList` with every header the proxy sent (lower-cased keys; repeats joined with `", "`).

Guarantees, each covered by a test in `test/proxysuite.lua`:

* arbitrary TCP chunk boundaries, down to one byte at a time;
* extra response headers, duplicate headers, and `obs-fold` continuation lines;
* body/early bytes after the header block returned as `leftover`;
* `\r\n`, bare `\n`, and mixed line endings;
* leading blank lines before the status line (up to 4, RFC 9112 tolerance);
* 1xx interim responses skipped (`interim = 'error'` to reject them like the reference);
* `407` with the realm extracted;
* malformed status line, oversized header block, peer EOF, and timeout all reported with a kind;
* no credential ever appears in an error message, and `requestRedacted` masks the base64 blob.

Helpers for the CLI/panel plumbing: `proxy.parseEndpoint('host:port')` → `host, port` (handles
`[v6]:port`), `proxy.parseAuth('user:pass')` → `user, pass` (splits on the **first** colon, so
passwords may contain colons), `proxy.formatTarget(host, port)`, `proxy.base64(s)`,
`proxy.redact(request)`.

---

## 5. Where this plugs in (not owned by P3)

The reference orders it exactly like this and we must too:

```
TCP connect to PROXY  ->  write CONNECT  ->  read 2xx  ->  [tunnel open]
                                                          ->  world name + '\n'   (preamble)
                                                          ->  0x1F challenge, login packet, …
```

The world-name preamble is the **first byte of the tunnelled stream**, never before the CONNECT.
`proto/transport.lua` therefore needs one extra state between `connecting` and `connected`; the
precise wiring is listed in the P3 report's `crossFileRequests`.

---

## Sources

| what | where |
|---|---|
| tunnel state, request bytes, response check, error paths | `otclient/src/framework/net/connection.cpp:94-140, 264-400`, `connection.h:79-110` |
| the `g_http_proxy` singleton, `hasAuth()`, `testProxy()` | `otclient/src/framework/net/http_proxy.h`, `http_proxy.cpp` |
| base64 flavour | `otclient/src/framework/util/crypt.cpp:90` (`cppcodec::base64_rfc4648`) |
| login POST proxying + redaction of `proxy-authorization` | `otclient/src/framework/net/httplogin.cpp:85-95, 150-165, 215, 404, 455` |
| httplib's own CONNECT | `vcpkg_installed/.../include/httplib.h:9847, 12929, 13616, 16034` (0.48.0) |
| UI → `g_http_proxy`, settings keys | `otclient/modules/client_entergame/entergame.lua:566-700, 867-899` |
| the stored entry | `otclient/profiles/config.otml:1058-1066` |
| the 407 evidence | `docs/live-login-notes.md` |
