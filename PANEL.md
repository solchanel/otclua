# Web panel + hub — requirements, and what was built

Requested: a web panel that runs and supervises **many worker instances / characters**, each
connecting **through a proxy**, where an operator can pick the cavebot config, upload scripts that
run inside the bot, and watch live stats (level, experience per hour, money per hour, and more).
The panel has **web accounts** with an **administrator** who creates and removes them; **only the
administrator sees the panel's activity log**.

**Status: built, packaged, and verified end to end on a real Debian 13 machine.** `README-HUB.md`
is the operator's guide (how to start it, first-run bootstrap, adding accounts and instances, and
the security notes); `INSTALL.md` is how to get it onto a server. Every requirement in this
document is now marked **BUILT**; what is still missing is smaller than a requirement and is
listed under *Not done*. *End-to-end verification on a real Debian machine*, at the end, records
exactly what was run against a real install, the two defects that found, and what remains
unproven — read that before believing any of the rest.

## Shape of the system

```
browser ──HTTP/WS──► hub (one process, Lua)
                        │  users, game accounts, characters, instances, audit log, script store
                        │  spawns + supervises workers, aggregates telemetry
                        ├─local control socket─► worker 1 (luaclient --headless, character A)
                        ├───────────────────────► worker 2 (character B)
                        └───────────────────────► worker N
                                                     └──proxy──► game server
```

* **Hub** = `hub/` — `main.lua` (CLI, bootstrap, signals), `server.lua` (HTTP/WS front end),
  `api.lua` (the endpoints and the authorisation), `supervisor.lua` (the worker children),
  `telemetry.lua` (live state and fan-out), `storage.lua`, `model.lua`, `auth.lua`, `audit.lua`.
  One process, single-threaded on `lib/sched.lua`, same LuaJIT runtime, Windows and Debian.
* **Worker** = today's `luaclient` with a control endpoint bound to `127.0.0.1` on an ephemeral
  port (`control/server.lua`, `control/commands.lua`). The worker never faces the internet; only
  the hub talks to it.
* One worker process per character, exactly as before.

## Web accounts and authorisation — BUILT

* Roles: `admin` and `user`.
* The admin creates and deletes web accounts, resets passwords, and is the only role that can read
  the **audit log**. Enforced in `hub/api.lua`'s `ADMIN_ONLY` set, server-side, whether or not the
  panel drew the button.
* A `user` sees and controls the instances assigned to them (the ones they created); the admin sees
  everything. Someone else's id answers `404`, never `403`, so an id probe is not an oracle.
* **Remote Lua is admin-equivalent, and is gated as such.** `instance.exec` and `script.upload` run
  unsandboxed code in a worker process that runs under the **hub's own user account**, with the
  hub's data directory readable. That code can therefore read `secret.key`, decrypt every stored
  game-account password and 2FA token (including other people's), read `users.json` for offline
  password cracking, and read the admin-only audit log. Granting it is granting the host.
  Both routes are therefore **administrator-only by default**. An administrator may grant a named
  account the `canExec` capability (Administration → Web accounts → *Grant Lua*), which is recorded
  in the audit log as `user.canExec`; every use is recorded with the full source. A plain account
  without it is refused with `403 forbidden` before ownership is even considered.
  **Residual risk:** an account with `canExec` is, in practice, an administrator of the host. Grant
  it only to someone you would also give a shell. Isolating the worker (a separate OS user, a
  systemd user slice, a container) is the fix that would make the capability merely powerful rather
  than total; it is not built.
* **Proxies are a shared pool to USE, not to mutate.** Any signed-in account may list a proxy and
  attach one to its own instance, and none of them can read the stored credential. Only the
  account that created it — or an administrator — may change its host, port, user or password, or
  delete it. Repointing somebody else's exit node would silently tunnel every instance attached to
  it through a machine of the attacker's choosing on its next start.
* Passwords: PBKDF2-HMAC-SHA256, per-user random salt, 200k iterations, stored as
  `pbkdf2$sha256$<iter>$<salt_b64>$<hash_b64>`. No password is ever logged, echoed or stored in
  plain text. The login path is constant-cost for an unknown account (measured ratio 1.00).
* Sessions: 32-byte random token, HttpOnly + SameSite=Strict cookie, sliding expiry under an
  absolute ceiling, revocable by the admin. Signing in **replaces** whatever session the client
  already held: the previous token is revoked at once, so a stolen-then-noticed session does not
  survive the victim signing in again. **Sessions survive a hub restart**: `hub/main.lua` persists
  them to `sessions.json` through a second `hub/storage.lua` store (atomic write-and-rename, SHA-256
  footer, 0600, `onCorrupt='quarantine'` so a damaged cache is moved aside rather than refusing to
  start). Only `SHA-256(token)` is stored, hex-encoded — never a token, so the file cannot be
  replayed into a login — along with the absolute deadline, which is re-checked on load, and the
  per-session CSRF token, without which every write would 403 after a restart. `logout`, `revoke`
  and `revokeUser` flush immediately, so revocation is authoritative; everything else rides a 30 s
  flush plus the shutdown flush. Verified on the real Debian install: the cookie held before
  `systemctl restart luaclient-hub` still drives the panel afterwards, and the live cookie value
  does not appear anywhere in `sessions.json`.
* Rate limiting has two counters with different jobs. The **account** counter (per submitted name,
  5 failures per 15 min) locks that account, and is checked before the password is verified. The
  **source-address** counter is a much looser throttle (50 failures) and is consulted *only after*
  a password has been found wrong, so a correct credential is never refused because of the address
  it came from. That matters here: the supported deployment puts a reverse proxy in front, every
  request then shares one address, and the old address lock let any anonymous visitor lock the
  whole panel — administrator included — with five bad guesses. `--trusted-proxy=CIDR` makes the
  hub believe `X-Forwarded-For` from a named front end (and only from there), which restores
  per-client buckets behind nginx/Caddy.
* The self-service password change proves the current password without touching either counter, so
  a mistyped form cannot lock the account it belongs to.
* **Login cost is serialised.** One PBKDF2 verification is ~270 ms of uninterruptible work on the
  single-threaded reactor. `hub/server.lua` runs the password-bearing commands one at a time, each
  on its own reactor turn, behind a bounded queue (`--`-free default: 8 waiters ≈ 2.4 s); past it
  the answer is `429 rate-limited` immediately. Without that, thirty concurrent logins stalled every
  other request — telemetry, bot ticks, health — for over seven seconds.
* First run: if no accounts exist, the hub prints a one-time admin bootstrap token to stdout (never
  to `--log-file`) and refuses to serve anything else until the first admin account is created.
* **TLS is out of scope for the hub.** It binds `127.0.0.1` by default; exposing it means putting it
  behind nginx/Caddy or an SSH tunnel. Binding a non-loopback address without `--allow-insecure`
  is refused, and the UI shows a warning banner when the connection is not HTTPS.
* CSRF: four independent checks on every write (JSON content type, same-origin `Origin`,
  `Sec-Fetch-Site`, and `X-CSRF-Token`). `--allow-insecure` **implies** `--csrf-strict`: on a
  published plaintext bind the token stops being optional, because it is the only one of the four
  that requires having actually read a same-origin response.
* **The Host header is always pinned.** A loopback bind answers to `127.0.0.1`, `localhost` and
  `[::1]`; a non-loopback bind answers to its own bind address plus whatever `--allowed-host=NAME`
  the operator declared, and to nothing else. Leaving it unpinned for a published bind was a
  complete CSRF bypass by DNS rebinding: with a name the attacker controls resolving to the hub's
  address, `Origin` and `Host` both come from the attacker and `Sec-Fetch-Site` honestly reads
  `same-origin`.
* **Origin comparison includes the port, always.** `http://localhost` (port 80) and
  `https://localhost` (443) are *not* same-origin with `Host: localhost:8877`. Cookies are not
  port-scoped, so treating them as equal let any other service on 80 or 443 — or an XSS in one —
  read `hub_csrf`, get the `SameSite=Strict` session cookie attached, pass all four checks and open
  an authenticated `/ws`. The same rule applies to the WebSocket handshake.
* **Only the panel is served.** `--panel-dir` also holds the development harness (`devhub.lua`, the
  mock backend, `panel/test/`); those paths answer `404` to everyone, signed in or not.
* **The `/ws` stream is capped**: 64 sockets per process and 8 per web account (the oldest of that
  account is closed when a ninth arrives), with a 512 KiB per-socket outbox. An upgraded socket
  stops counting against the HTTP connection cap, so without these it was limited only by the
  process descriptor table.
* **Bulk actions are bounded**: at most 100 ids per `POST /api/instances/actions`, and the failures
  in one request collapse into a single audit record. Unbounded, with one fsynced record per failing
  id, a handful of requests scrolled the entire audit retention away.

## Audit log (admin only) — BUILT

Append-only JSONL, one record per event: timestamp, actor (web account or `system`), source IP,
action, target, outcome, detail. Logged actions include login success/failure, account create/
delete/password reset, game account or character added/removed, instance created/started/stopped/
deleted, config changed, script uploaded/assigned/deleted, remote Lua executed (with the code),
proxy changed, every refused admin route and every CSRF refusal. Each record is fsynced before the
call that wrote it returns. The admin UI filters by actor, action, outcome, time range and free
text — and the free-text term is pushed **into** the backward scanner, so a search narrows the log
rather than the page it happened to return. Rotation is by size with a keep count; both are
configurable.

Also recorded: **a cross-tenant probe**. Deleting, patching or reading somebody else's instance,
game account, character or script is refused with `404` by the ownership helpers before any handler
runs, and one `denied` record is written naming the command and the id that was asked for. That is
the more interesting signal than a refused admin route, and it used to leave no trace at all.

**Per-actor write budget.** Each actor gets 200 records immediately and 20/s sustained. Going over
does not lose the fact that something happened — one `audit.throttled` record says how many were
suppressed, and normal recording resumes when the bucket refills — but it means no single account
can force a rotation and scroll genuine records out of retention. Records the hub writes about
itself (`system`) are exempt.

## Data model (JSON files under the hub's data dir, atomic write-and-rename) — BUILT

```
users.json        [ {id, name, role, pwhash, createdAt, disabled, canExec, lastLoginAt} ]
accounts.json     [ {id, label, login, password(enc), token2fa(enc), ownerUserId} ]  game accounts
characters.json   [ {id, accountId, name, world, vocation?, lastLevel?} ]
instances.json    [ {id, characterId, ownerUserId, proxyId, botProfile, cavebotConfig,
                     targetbotConfig, scripts:[scriptId], autoStart, autoRelogin, state} ]
proxies.json      [ {id, label, kind:'http-connect', host, port, user?, pass(enc),
                     ownerUserId?} ]
scripts.json      uploaded-script metadata (name, owner, size, sha256)
scripts/<id>.lua  the sources themselves
history/<id>.json a rolling stats history per instance, flushed every 60 s
audit.jsonl       the admin-only activity log
sessions.json     live web sessions -- SHA-256(token) only, never a token, plus the
                  absolute deadline and the per-session CSRF token
worklogs.json     the last 200 log and chat lines per instance, so the panel's Console
                  and Chat tabs are not blank after a hub restart
secret.key        the hub master key, 0600
```

`sessions.json` and `worklogs.json` are caches: deleting them is safe, and deleting `sessions.json`
only signs everyone out.

Every file is written atomically and carries a SHA-256 integrity footer; a truncated, empty or
corrupted file is reported by name and never silently emptied. Referential integrity is derived from
the field specs: a dangling reference is refused on insert and update, and a delete is refused while
anything still points at the row.

Game-account passwords, 2FA tokens and proxy passwords are encrypted at rest with a key derived from
`secret.key` and bound to their own row and field. The hub necessarily can decrypt them to log
characters in. **Proxies are a shared pool to use** — any signed-in account may list one and attach
it to its own instance, and none of them can read the credential. Mutating one is a different
question: `ownerUserId` records who created it, and only that account or an administrator may
change its host, port, user or password, or delete it. A row written before that field existed has
no owner and is administrator-only to change.

## How a hub-managed worker actually starts — BUILT

The credentials never appear in argv, and until the fix below the worker could not start at all
outside `--dry-run`. The sequence, all of it exercised offline by `test/hube2esuite.lua` §11
against `test/fakeserver.lua`:

1. `POST /api/instances/actions {start}` → `hub/api.lua`'s `launchSpec()` decrypts the stored
   game-account password. That is the **only** place a stored credential is decrypted.
2. `hub/supervisor.lua` spawns `luajit main.lua` with **no credential in argv** — only
   `--control-port=0 --control-bind=127.0.0.1 --control-token-fd=0 --instance-name=…` (and
   `--proxy=HOST:PORT --proxy-auth=fd:0` when the instance has a proxy). The control token and the
   proxy `user:pass` go down the child's private **stdin** pipe, in the order the flags appear.
   `process.spawn` refuses to place a secret in argv at all, and the supervisor additionally asserts
   that no argv element contains any plaintext this launch holds.
3. `main.lua` sees a control token and **no** account: it brings the control endpoint up and waits
   in the reactor. (It used to call `openSession()` first, fail with `--account is required`, exit 1
   and spin in the restart-backoff loop forever — so every non-`--dry-run` hub-managed instance was
   broken, and the suite never noticed because it only ever passed `--dry-run`.)
4. The supervisor connects to the announced ephemeral port and sends `login {account, password,
   token, character, world, host, port, loginUrl}` over the authenticated loopback socket. The
   worker performs the account login, selects the character and connects to the world; the bot
   configuration and the assigned scripts are pushed once that login has succeeded, because the bot
   environment does not exist until a session does.
5. The plaintext is dropped from the hub's memory as soon as the worker has it. A **restart**
   therefore re-derives the whole launch payload through `launchSpec()` (`sup.specProvider`) rather
   than replaying a spec whose password has been erased.

`--game-host` / `--game-port` / `--login-url` override where the worker logs in; `--worker-env=K=V`
adds environment for every worker (settings only — never a credential: an environment is readable
from `/proc` on some configurations, which is why the token goes on stdin instead).

Confirmed on the real Debian install with the worker running: `/proc/<pid>/cmdline` carries only
`--control-port=0 --control-bind=127.0.0.1 --control-token-fd=0 --instance-name=… --bot-profile=…`
— `--control-token-fd=0` is a *reference* to a descriptor, not a value — and `/proc/<pid>/environ`
carries only `HOME`, `PATH`, `LANG`, `USER`, the `HUB_*` settings from the unit's EnvironmentFile
and `LUACLIENT_BOT_PROFILE`. Grepping both for the game password, the 2FA token and both web
passwords finds nothing. `cmdline` is world-readable (`-r--r--r--`), which is exactly why nothing
is in it.

### Stopping a worker — BUILT

A stop is a three-rung ladder, not a blind timer, and it runs the same way on both platforms:
the control `shutdown` **command** first (with an acknowledgement, which is what makes the worker
send `0x14 LeaveGame` before dropping its socket); at 60 % of the grace window `proc:stop()` (stdin
EOF everywhere, `SIGTERM` on POSIX); at the deadline `proc:kill()`. `--stop-grace-ms=N` sets the
window (default 8000). `Sup:info(id).lastStop` records `{ms, acked, killed, code, signal, graceful}`
and the hub logs `event=hub.workers.stopped stopped=N graceful=N killed=N`, so an operator can see
when a worker did *not* get to log out — which matters, because a merely-killed worker leaves the
character online for the server's logout timeout and costs the next login too. On Windows the
console control handler is 39 bytes of position-independent machine code in a `VirtualAlloc` page
rather than an FFI callback, because a Lua callback fired from the thread Windows injects killed
the process outright when the main thread was on a JIT trace.

Observed on the Debian install under systemd, stopping the service with a worker running:

```
INFO event=hub.shutdown graceMs=8000 reason="signal 15" workers=1
INFO event=instance.state detail="shutting down"  state=stopping
INFO event=instance.state detail="exit code 0"    state=stopped
INFO event=hub.workers.stopped graceful=1 killed=0 stopped=1
INFO event=hub.stopped
```

### The login POST no longer blocks the reactor — BUILT

`lib/http.lua`'s `postAsync` runs the request in a short-lived child process driven by
`lib/process.lua`; the whole request — URL, headers, timeout, backend, proxy credential and body —
goes down that child's private stdin as one base64 line, so the account password never reaches
`/proc/<pid>/cmdline`. `http.post` is unchanged for every existing caller and only takes the async
route inside a coroutine created by `http.runAsync`, which `control/server.lua` uses for every
worker command. Measured against an endpoint that accepts and never answers: the longest reactor
gap fell from 5063 ms to 16 ms on Windows and from 2543 ms to 10 ms on Debian.

## Worker control protocol (hub ⇄ worker) — BUILT

Request `{id, cmd, args}` → `{id, ok, result|error}`, plus `{event, data}` pushes, over
`POST /rpc` and `GET /ws` on the worker's loopback endpoint.

`status`, `login`, `logout`, `relogin`, `bot.enable {on}`, `bot.setCavebot {name}`,
`bot.setTargetbot {name}`, `bot.setMacro {name, on}`, `bot.listConfigs`, `bot.reload`,
`script.put {name, source}`, `script.remove {name}`, `script.list`, `exec {code}`, `say {text}`,
`stats`, `shutdown`.

*(`bot.setMacro` and `say` were added during integration: the panel's Bot tab draws a toggle per
macro and its Chat tab has a send box, and neither had a command behind it.)*

Events: `status` (1 Hz), `stats`, `log`, `chat`, `loginState`, `gameStart`, `gameEnd`, `death`,
`error`.

The worker answers with its own natural shape — `player{}`, `bot{cavebot{},targetbot{}}`,
`stats{}` — and `hub/supervisor.lua`'s `flattenLive()` folds that into the flat `live` object the
panel draws. That translation happens once, in the hub.

## Statistics the panel shows

Per instance, computed in the worker and pushed with `stats`:

| metric | status |
|---|---|
| level, experience | **BUILT** — from the player-stats packet |
| **exp/h** | **BUILT** — 15-minute sliding window plus the session average |
| **money/h** | **BUILT** — `moneySource = 'gold+goods'`: d(gold on hand)/h plus d(loot − lootCash − waste)/h, sharing one baseline sample so the coins are not counted twice. `goldPerHour` and `goodsPerHour` break it out. It is a *valuation*, not realised cash: looted goods are priced at their list price the moment they are looted, exactly as vBot's own analyzer does, so a character that hoards shows money/h it has not banked. With no price table at all it falls back to the narrower `'gold'` answer. |
| loot/h, waste/h, balance | **BUILT** — counts and values. Prices come from the profile's `vBot/items.lua`, whose `LootItems` table is keyed by lowercase item *name* and is mapped onto item ids through `proto/items.lua`. The snapshot is honest about where they came from: `pricesSource` (`profile` / `file` / `profile+file` / `coins-only`), `pricesLoaded`, `pricesInTable`, `pricesFromProfile`, `pricesFromFile`, `pricesUnmapped`, `pricesPath`, `pricesFilePath`, `pricesFileError`, and `noDataFor` gains `itemPrices` when nothing real loaded. An operator can override per id with `--worker-env=LUACLIENT_PRICES=/etc/luaclient/prices.json`; a name-keyed file is refused loudly rather than silently pricing everything at 0. Loot counts still need the TargetBot loot module wired with a container list — a worker without one reports `lootContainers` in `noDataFor`. |
| supplies | **BUILT** — `bot/supplies.lua` has a per-item ledger against `Supplies.json`: `ledger()` returns `{itemId, item, name, count, threshold, min, max, ok, inInventory, inContainers, serverCount}` per row, where `count = max(inventory + open containers, the server's 0xC0 total)` so a closed-but-full backpack still counts. `levels()` is the same rows with **no named keys** — that shape matters, because a mixed-key Lua table encodes as a JSON *object* and the panel's `Array.isArray(L.supplies)` then drops it. The hub sends `supplies` (the array) and `suppliesStatus` (profile, rounds, pouch pages, low) side by side. |
| kills/h, deaths | **BUILT** — from `Loot of <name>` messages and the death event |
| hp/mana, position, target, cavebot waypoint | **BUILT** — live, in `status` |
| uptime, online time, reconnects | **BUILT** — supervisor bookkeeping |

Rates are `nil`, not 0, below 60 s of measured history — a deliberate refusal to extrapolate; the
panel renders that as `—`.

The hub keeps a 400-point rolling history per instance in memory and flushes it to
`history/<id>.json` every 60 s, so the panel can draw short time series without a database.

## Script upload — BUILT

* Upload a `.lua` file through the panel; the hub stores it and pushes it to the selected instances.
* The worker compiles it **first** (a syntax error is reported and nothing is written), then writes
  it into the bot profile it runs and loads it in the same environment the bot's own scripts use, so
  a script written for vBot works unchanged. Macros and event handlers the script registers are
  tracked, so removing or replacing it takes them back out.
* Scripts are **arbitrary code inside the worker**, and the worker runs under the **hub's own user
  account** with the hub's data directory readable — so uploading a script, like `instance.exec`,
  is equivalent to a shell on the host and to every other account's stored game credentials.
  Upload is therefore **administrator-only by default**; an administrator may grant a named account
  the `canExec` capability (see *Web accounts and authorisation*). Every upload and every execution
  is audited with the source. The worker sandboxes nothing beyond what vBot does. This is a
  deliberate trust decision, it is now an explicit and auditable one, and the UI states it.
* Limit: 512 KiB (`413 too-large` past it). Re-uploading the same name replaces it and refreshes
  every running instance that has it.
* **Caveat:** `bot.reload` drops the script environment, so uploaded scripts are not restored across
  a reload; re-assign them afterwards. The reply says so.

## Proxy support (worker side) — BUILT

Per-instance proxy from `proxies.json`. The hub passes the **endpoint** in argv and the
**credential out of band**:

```
--proxy=HOST:PORT      the HTTP CONNECT proxy
--proxy-auth           read "user:pass" from STDIN (one line)
--proxy-auth=@PATH     ... from a file (first line)
--proxy-auth=fd:N      ... from file descriptor N (0 = stdin)
```

`--proxy-auth=user:pass` **is refused** with a non-zero exit. A credential in argv is not
a credential: `/proc/<pid>/cmdline` is world-readable on Linux, and on Windows any process
running as the same user reads the PEB (`lib/process.lua`, "SECRETS IN argv" — which is
why `process.spawn` refuses to place one there at all). When more than one flag reads from
stdin, the lines are consumed **in the order the flags appear on the command line**.
`process.spawn` exempts a *reference* to a secret — a bare descriptor under a `...fd` flag, `fd:N`,
`@path`, or a flag named `...file` / `...path` — so the documented flags above spawn under the full
default denylist rather than a narrowed one.

What it does:

* **Game socket** — `proto/transport.lua` connects to the *proxy*, runs `lib/proxy.lua`'s
  CONNECT handshake to completion, and only then writes the raw world-name preamble; bytes
  the proxy already buffered past its `200` are game bytes and go straight into the frame
  accumulator. State machine: `idle -> connecting -> proxying -> connected`. A `407`, a
  malformed response or a timeout is an ordinary transport error, and not one game byte is
  written before the tunnel is up.
* **HTTPS login POST** — `lib/http.lua` routes it through the same proxy on all three
  backends (`http.setProxy{host, port, user, pass}`, set once at boot by `main.lua`):
  WinHTTP `WINHTTP_ACCESS_TYPE_NAMED_PROXY` plus the two proxy-credential options, libcurl
  `CURLOPT_PROXY` / `PROXYUSERPWD` / `HTTPPROXYTUNNEL`, and the curl **CLI** fallback via a
  temporary 0600 `--config` file holding `proxy-user` — never `--proxy-user` on the command
  line. `http.getProxy()` reports host, port and `hasAuth`, never the password.

Without it, an IP-restricted account cannot log in at all — see `docs/live-login-notes.md`.

## Control endpoint (worker side) — BUILT

```
--control-port=N            0 = ephemeral (and the default once a token is given)
--control-bind=ADDR         default 127.0.0.1
--control-allow-remote      required before a non-loopback bind is accepted
--control-token-file=PATH   read the endpoint's auth token from a file
--control-token-fd=N        ... or from a descriptor (0 = stdin)
--instance-name=NAME        the name the panel shows for this worker
```

The token never travels in argv either. On start-up the worker prints one machine-readable
line so the hub can learn an ephemeral port:

```
control-endpoint 127.0.0.1 51718 char-a
```

`POST /rpc` carries one request object; `GET /ws` carries requests **and** the event pushes;
`GET /health` is a liveness probe. All three require `Authorization: Bearer <token>` (or
`X-Control-Token:`, or `?token=` — the last only because a browser cannot set a header on a
WebSocket handshake). The comparison is constant-time over SHA-256 digests, so neither the
value nor its length leaks. `--dry-run --control-port=0` serves the endpoint with no
network at all, which is what `test/controlsuite.lua` and `test/hube2esuite.lua` drive.

## The hub's HTTP surface — BUILT

REST, not an RPC envelope: one path per resource, the verb carries the intent. `panel/api.js`'s
`ENDPOINTS` table and `hub/api.lua`'s `M.ROUTES` are the two halves of one contract, and
`test/hube2esuite.lua` asserts they match in **both** directions — no route the panel calls is
missing, and no route the hub serves is unused.

```
GET/POST/DELETE /api/session          POST /api/session/password   POST /api/bootstrap
GET/POST        /api/instances        POST /api/instances/actions  (start|stop|restart|botEnable)
GET/PATCH/DELETE/api/instances/:id    GET  /api/instances/:id/configs|history|logs|chat
PUT  /api/instances/:id/macros/:name  POST /api/instances/:id/reload|exec|chat
GET/PUT         /api/instances/:id/config/:kind        (CONFIGAPI.md -- BUILT, see below)
GET             /api/instances/:id/config/:kind/list
GET             /api/instances/:id/debug               (the Debug tab -- see below)
GET/POST        /api/accounts         PATCH/DELETE /api/accounts/:id
GET/POST        /api/characters       DELETE /api/characters/:id
GET/POST        /api/proxies          PATCH/DELETE /api/proxies/:id   POST /api/proxies/:id/test
GET/POST        /api/scripts          GET/DELETE /api/scripts/:id   PUT /api/scripts/:id/assignments
GET/POST        /api/admin/users      PATCH/DELETE /api/admin/users/:id
POST            /api/admin/users/:id/password
GET             /api/admin/sessions   DELETE /api/admin/sessions/:id
GET             /api/admin/audit      GET /api/health
GET             /ws                   the event stream
```

Errors are a non-2xx status with `{"error":{"code","message"}}`; codes are `bad-request`,
`unauthorized`, `forbidden`, `not-found`, `conflict`, `too-large`, `rate-limited`, `csrf-invalid`,
`internal`.

`GET /ws` speaks the panel's dialect: the client sends `{type:'auth', csrf}` first and the hub
answers `{event:'ready'}`; then `{type:'subscribe', logs, chat}`, `{type:'subscribeDebug', id}`
(the Debug tab, below -- a separate frame from `subscribe` on purpose, so the log/chat wire shape
and every test asserting its exact JSON stay untouched) and `{type:'ping'}`. A wrong CSRF token
closes the socket with **4401**, which is what tells the panel to stop retrying. Log, chat and
`debug` frames go **only** to sockets subscribed to that instance (and, for `debug`, only while a
Debug tab is actually open -- `subscribeDebug(null)` on tab close/switch). `POST /api/rpc` and
`GET /api/events` remain as an older command-envelope surface for non-browser clients and the
hub's own tests.

## Debug console (the Debug tab) — BUILT

A fourth instance-view tab, next to Console/Chat: tick health (a sparkline of the last 30 tick
durations, slow-tick counter, a per-macro table sortable by error count), network health (a
staleness warning once `lastPacketAgeMs` exceeds a threshold), a status card per bot module
(CaveBot/TargetBot/HealBot/AttackBot/Stances) with a "stuck" warning once a waypoint stalls past
`stuckThresholdMs`, and a structured, filterable event log (`resync`, `macro_error`, `slow_tick`,
`stuck`, `path_blocked`, `reconnect`, …).

Data comes from `control/commands.lua`'s `debug.snapshot` command (BOT.md §17), reshaped for the
panel by `hub/supervisor.lua`'s `flattenDebug()` — the same translation role `flattenLive()` plays
for the Overview tab's stats: the worker answers in its own natural shape, one function reshapes
it once, in the hub, into what `panel/app.js`'s `TabDebug` reads. That reshaping is also where a
genuine clock-domain fix lives: the worker's "moment" fields (a macro's last-ran time, a stuck
waypoint's start, an event's timestamp) are `sys.nowMs()` values — **monotonic since that worker
process started**, not Unix epoch (see BOT.md §17) — and `flattenDebug()` converts each one to an
epoch-comparable value (`wallNow - workerMonotonicNow` computed fresh per snapshot) before the
panel ever does `Date.now() - x` arithmetic on it. Two surfaces: `GET
/api/instances/:id/debug` (on-demand — a fresh pull from the worker while running, the last cached
push while stopped) and the `debug` WebSocket event pushed by `control/server.lua` every
`debugIntervalMs` (2000 ms) to sockets that sent `{type:'subscribeDebug', id}`.

Proven against the real hub HTTP API, not just the fake-worker test suites: a real
`luajit main.lua --dry-run` worker spawned under a real hub, a broken macro registered live over
`POST /api/instances/:id/exec`, its `errorCount`/`lastError` and a `macro_error` event both
visible moments later over `GET /api/instances/:id/debug` — on both Windows and Debian/WSL.

## Bot configuration API (CONFIGAPI.md) — BUILT

The six vBot config "kinds" (healbot, conditions, attackbot, stances, targetbot, cavebot) are
readable and writable from the panel whether the instance is running or stopped, through
`GET/PUT /api/instances/:id/config/:kind` and `GET .../config/:kind/list`. Routing:
**running** → forwarded over the worker's control socket to `control/commands.lua`'s
`config.get`/`config.set`/`config.list`, so the change applies to the live, in-memory bot
immediately (proven: a HealBot threshold PUT changes what the very next macro tick sends, no
restart); **stopped** → `hub/botconfig.lua` reads/writes the profile's files directly, through the
exact same `bot/config.lua` codec the running path's `:reload()`/save calls use, so the two paths
never diverge. Both paths validate against the one shared `bot/configschema.lua`.

Security: a cavebot `function`-type waypoint carries a raw Lua chunk (equivalent to `exec`), so a
`config.set` for `cavebot` needs the same `EXEC_CAPABILITY` (admin, or `canExec`) as `instance.exec`
**only when the diff adds or changes a function body** — every other cavebot edit, and every other
kind's edit, needs only the normal instance-owner permission. Proven live in both directions
against a real running worker: a plain user with no `canExec` is refused (403) adding a function
waypoint but can freely edit a `goto` value; granting `canExec` makes the identical PUT succeed.
Every PUT is audited as `instance.config`, with the full new body when a function changed.

See CONFIGAPI.md for the full contract (per-kind shapes, the schema module, the security rule) and
its "As built — corrections" section for the two prose/reality mismatches this build fixed.

## Panel UI — BUILT

Single page, vanilla JS, served by the hub, dark theme, no build step and no CDN.

* **Login** screen; then a left rail of instances with live state pills.
* **Dashboard**: table of all instances — character, level, exp/h, money/h, hp/mana, state, target,
  waypoint, uptime — with bulk start/stop/restart/enable-bot actions.
* **Instance view**: tabs for Overview (stats + canvas charts), Bot (cavebot/targetbot/profile
  pickers, macro toggles, assigned scripts, auto-start/auto-relogin, reload), **Bot Config**
  (CONFIGAPI.md, BUILT — six lazily-loaded cards: Healing, Conditions, Attack, Stances, Targeting,
  CaveBot; add/duplicate/remove/reorder rows, per-card Save/Revert, a CaveBot `function` waypoint
  gated on the same `canExec` check the Console tab already uses), Console (log stream, Lua exec),
  Chat, **Debug** (tick/network/per-module health + a structured event log — see "Debug console"
  above).
* **Characters & accounts**: add/remove game accounts and characters, assign proxies (with a Test
  button).
* **Scripts**: upload, view, assign to instances, delete.
* **Admin** (admin only): web accounts CRUD, sessions, and the audit log viewer with filters and a
  live tail. The Admin nav entry is not rendered for a non-admin and the route redirects — and the
  server refuses it regardless.

State pills cover the supervisor's full lifecycle: `stopped`, `starting`, `running` (the worker is
up and the control link is established, but the character is not in the game), `connecting`,
`online`, `stopping`, `backoff`, `error`.

## Build order — DONE

1. Worker: proxy support, control endpoint, stats computation, script loading. ✔
2. Hub: storage, auth, HTTP/WS server, worker supervision, audit log. ✔
3. Panel UI. ✔
4. End-to-end tests with real workers, on Windows and Debian. ✔ (`test/hube2esuite.lua`)

## Deployment — BUILT

`deploy/` packages the system for a Debian server and `INSTALL.md` is the operator's install guide.
`deploy/package.sh` builds a reproducible versioned tarball (two builds of the same source give
byte-identical output) with a `sha256sum -c`-readable digest and a per-file manifest; `test/`,
`docs/`, `panel/test`, `panel/mock` and `panel/devhub.lua` are deliberately excluded, so a
production install cannot serve the development harness. `deploy/install.sh` is idempotent and
creates a `luaclient` system user, `/opt/luaclient` (root-owned, read-only to the service),
`/var/lib/luaclient` (0700, the service user's), `/var/log/luaclient`, `/etc/luaclient/hub.conf`
and a hardened systemd unit. `deploy/upgrade.sh` backs the data up, runs a migration dry run and
rolls the whole thing back on failure; `deploy/uninstall.sh` keeps the data unless `--purge`.
`deploy/nginx-luaclient.conf` terminates TLS in front.

Verified end to end on a real Debian 13 machine that genuinely runs systemd (systemd 257): built
the tarball, purged the previous install, installed from the tarball into a clean prefix, and drove
the REST API with `curl` — bootstrap an administrator, create a `user` account, a game account, a
character and an instance, start it with a `--dry-run` worker, read its live status and log ring,
read the audit log as the administrator, and confirm that the plain account is refused every admin
route with `403` and every cross-tenant id with `404`. See *End-to-end verification* below.

## Not done

* **Config pickers still cannot list macros.** The cavebot, targetbot and profile lists *are* now
  answered for an instance that has never run: `hub/supervisor.lua` scans the profile directory
  through `bot/config.lua`'s `listDir`, and `GET /api/instances/:id/configs` reports which answer it
  gave in a `source` field (`worker` / `scan` / `cache` / `none`). Macros are the exception and are
  honestly empty from a scan — a macro is a Lua registration inside a running bot, not a file — so a
  stopped instance still shows whatever a worker last reported.
* **No rate limiting on the worker control endpoint**, and no per-command authorisation there: the
  token is all-or-nothing.
* **vBot's per-character price overrides are not read.** `analyzer.lua` checks
  `storage.analyzers.customPrices[name]` before scanning `LootItems`; only `vBot/items.lua` and the
  operator's own price file are read. On the reference profile 6 `LootItems` names match no item in
  `assets/items1530.bin`; they are counted in `pricesUnmapped` but not listed anywhere, so an
  operator cannot yet be told exactly which ones to price by hand.
* **The panel does not yet draw the honesty fields.** `pricesSource`, `pricesLoaded`, `moneySource`
  and `configs.source` are on the wire and asserted by the suites; rendering them is still to do.

## End-to-end verification on a real Debian machine

Everything in this section was executed on Debian 13 (trixie), amd64, LuaJIT 2.1.1737090214, with
systemd 257 genuinely running: the unit was installed, verified, enabled, started, restarted and
stopped for real. The tarball was built by `deploy/package.sh`, the machine was purged first, and
the install came from the tarball, not from the checkout.

What was driven with `curl` against the real REST API, in order: `GET /api/health` →
`POST /api/bootstrap` with the one-time token read out of the journal → `GET /api/session` →
`POST /api/admin/users` (role `user`) → `POST /api/accounts` → `POST /api/characters` →
`POST /api/instances` → `POST /api/instances/actions {start}` (a `--dry-run` worker, spawned as a
child of the hub inside the service's own cgroup) → `GET /api/instances/:id` for live status →
`GET /api/instances/:id/logs` → `GET /api/admin/audit` as the administrator → sign in as the plain
user → every admin route refused `403 forbidden` → every cross-tenant id refused `404 not-found`
→ the refusals read back out of the admin-only audit log → `{stop}`.

Security properties, checked on that install rather than argued from the source:

* `/var/lib/luaclient` is `0700 luaclient:luaclient`, every file in it `0600`; another user gets
  `Permission denied` even listing it, and the service user gets `Permission denied` writing to
  `/opt/luaclient` (`ProtectSystem=strict`).
* The game password, the 2FA token and both web passwords appear in **zero** files under
  `/var/lib/luaclient`, `/var/log/luaclient` and `/etc/luaclient`, and in **zero** journal lines.
  `accounts.json` holds `sbx$1$…` records; `users.json` holds `pbkdf2$sha256$200000$…`.
* The worker's `/proc/<pid>/cmdline` and `/proc/<pid>/environ` contain none of them.
* **The worker inherits exactly three descriptors — 0, 1 and 2** — and those are the stdio pipes to
  the hub. Comparing every entry of `/proc/<worker>/fd` against `/proc/<hub>/fd` finds no other
  shared object: not the hub's listening socket, not `audit.jsonl`, not `hub.log`. The worker does
  hold two more descriptors of its **own**, opened after `execve`: fd 3 is its control listener
  (`LISTEN 127.0.0.1:45857`) and fd 4 the hub's accepted connection to it. Both carry `O_CLOEXEC`.
  So "only 0, 1, 2" is true of what is *inherited*, which is the property that matters; it is not
  true of the running process, and this document should not be read as claiming otherwise.

### Two defects this pass found, and fixed

Both were invisible to all sixteen suites, and both needed a real install and a real browser-shaped
client to see.

* **Every `DELETE` the panel can issue answered `415`.** `panel/api.js` sent `null` as the body for
  a `DELETE` (the id is in the path, so there was nothing to say), `panel/rpc.js` sets
  `Content-Type` only when there *is* a body, and the first of the hub's four CSRF checks refuses
  any state-changing request that is not `application/json`. So deleting an instance, a game
  account, a character, a proxy, a script or a web account, revoking a session, and **Sign out**
  all failed. `test/hube2esuite.lua`'s `rest()` helper sets the header itself for every non-GET, so
  the suite could not reproduce what a browser sends. Fixed in `panel/api.js` by sending `{}` — the
  smallest thing that satisfies the check without weakening any of the four.
* **The hub leaked one file descriptor per HTTP connection, permanently.** `lib/socket.lua`'s
  `recv()` sets `state = 'closed'` when the peer sends FIN — a statement about the *protocol*; the
  socket is in `CLOSE-WAIT` and the descriptor is still ours. `Sock:close()` guarded on
  `state ~= 'closed'` and therefore skipped `P.close()` for every socket the peer closed first,
  which is every ordinary keep-alive request. `lib/httpserver.lua`'s `Conn:destroy()` decremented
  `stat.active` regardless, so `maxConnections` never noticed and the 30 s idle sweep could not
  help — the connection was already gone from `server.conns` while its fd stayed open forever.
  Measured on the installed hub: one request leaked exactly one descriptor; 100 requests left 100
  `CLOSE-WAIT` sockets that were still there 70 s later. At the unit's `LimitNOFILE=8192` the hub
  dies after a few thousand panel requests. It affected every socket in the program, not just the
  hub — the worker's control endpoint, the game transport and the proxy client all close this way.
  `Sock:close()` now keys on a separate `fdOpen` flag. After the fix, 500 requests and 30
  concurrent clients leave the hub at its idle 6 descriptors and 0 `CLOSE-WAIT`.
  `test/fdleaksuite.lua` is the regression test: it counts `/proc/<getpid()>/fd`, and reverting the
  one-line guard makes it fail with 205 descriptors after 200 rounds instead of 4.

### What was *not* verified

* **No browser.** The panel was driven only through its HTTP API with `curl`, using the exact
  headers `panel/rpc.js` emits. Browser navigation to loopback was unavailable in the verification
  environment, so no version of this system has been clicked through since the `DELETE` fix.
  `panel/app.js` was not exercised at all this pass.
* **Not a real machine.** Debian 13 under WSL2. systemd is genuinely running, so `enable`, `start`,
  `restart`, `stop`, the sandbox, cgroup membership, journal capture and `systemd-analyze` are all
  real — but behaviour across an actual host reboot was not tested, because WSL's lifecycle is not
  a boot.
* **No real game server.** The worker was started with `--dry-run`, so it wires the bot, loads the
  item table and serves its control endpoint, but never opens a game socket. The login path itself
  is covered offline by `test/hube2esuite.lua` against `test/fakeserver.lua`.
* **No TLS certificate issuance.** `deploy/nginx-luaclient.conf` was proven against a self-signed
  certificate at the exact path certbot uses; certbot itself has never run, because the machine has
  no public name.

### Test suites — Debian 13 and Windows, all green

| suite | Debian | Windows |
|---|---|---|
| selftest | 2538 | 2538 |
| botsuite | 2137 | 2137 |
| statsuite | 194 | 194 |
| cryptosuite | 278 | 277 |
| httpserversuite | 444 | 444 |
| wssuite | 309 | 309 |
| proxysuite | 235 | 235 |
| processsuite | 204 | 196 |
| controlsuite | 390 | 390 |
| hubcoresuite | 358 | 358 |
| hubapisuite | 259 | 259 |
| hube2esuite | 200 | 198 |
| fdleaksuite | 15 | 12 |
| shim_platform_suite | 436 | 436 |
| shim_host_suite | 118 | 118 |
| shim_game_suite | 371 | 371 |
| shim_ui_suite | 260 | 260 |
| **total** | **8746 passed, 0 failed** | **8732 passed, 0 failed** |

The counts differ where a suite has platform-specific checks: `cryptosuite` and `processsuite` do
more on Linux, `hube2esuite` has two Linux-only signal checks, and `fdleaksuite`'s descriptor
counting needs `/proc` and reports itself as skipped on Windows.

`test/` is not packaged, so the suites run from the source tree. What is checked against the
**installed** tree instead: every one of its 87 `.lua` files compiles, `hub/main.lua` and `main.lua`
answer `--help`, the panel's own files are served with the right content types, the development
harness (`devhub.lua`, `panel/test/`, `panel/mock/`) answers `404` to everyone, and the whole REST
and WebSocket surface above was driven against it.
* **The worker is not isolated from the hub.** It runs as the same OS user, so `canExec` is
  administrator-equivalent by construction (see *Web accounts and authorisation*). What a worker
  no longer inherits is the hub's **descriptors** and **signal mask**: `lib/process.lua` closes
  every fd above 2 between `fork()` and `execve()`, `lib/socket.lua` and `hub/storage.lua` create
  theirs close-on-exec (and non-inheritable on Windows, where `CreateProcess` must pass
  `bInheritHandles = TRUE` for the std pipes), and the child's signal mask is reset so
  `PR_SET_PDEATHSIG` and the supervisor's graceful `SIGTERM` are actually deliverable. Before that:
  a worker held the hub's listening socket (an orphan kept the port bound, so the hub could not
  restart) and the audit log's `O_APPEND` write handle (so code running in a worker could forge
  records in the admin-only log), and `kill -9` of the hub left every worker running and logged in.
  Real isolation — a separate OS user, a systemd user slice, a container — is still not built.
* **Cross-browser and mobile.** The panel was driven in Chromium once, before the `DELETE` fix
  below. No browser has opened it since; see *What was not verified*.
