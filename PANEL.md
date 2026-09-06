# Web panel + hub — requirements, and what was built

Requested: a web panel that runs and supervises **many worker instances / characters**, each
connecting **through a proxy**, where an operator can pick the cavebot config, upload scripts that
run inside the bot, and watch live stats (level, experience per hour, money per hour, and more).
The panel has **web accounts** with an **administrator** who creates and removes them; **only the
administrator sees the panel's activity log**.

**Status: built and green on Windows and Debian.** `README-HUB.md` is the operator's guide (how to
start it, first-run bootstrap, adding accounts and instances, and the security notes).
Requirements that are *not* met are marked **NOT DONE** in place; there is a summary at the end.

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
  survive the victim signing in again. **Sessions live in memory, so a hub restart signs everyone
  out.**
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
secret.key        the hub master key, 0600
```

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
| **money/h** | **PARTIAL** — gold/platinum/crystal on hand is counted exactly; **loot sold value needs a price table** |
| loot/h, waste/h, balance | **PARTIAL** — the *counts* are exact; the *values* are 0 unless the profile's `vBot/items.lua` price table loads. The snapshot says so in `noDataFor`, so the panel can print "prices not loaded" rather than a confident 0. Loot counts also need the TargetBot loot module to be wired with a container list. |
| supplies | **NOT DONE** — `bot/supplies.lua` reports rounds and pouch pages, not per-item counts against `Supplies.json`. The hub therefore sends no `supplies` array at all (the module's status object travels as `suppliesStatus`), and the panel's supplies column says "no supply data". |
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
answers `{event:'ready'}`; then `{type:'subscribe', logs, chat}` and `{type:'ping'}`. A wrong CSRF
token closes the socket with **4401**, which is what tells the panel to stop retrying. Log and chat
frames go **only** to sockets subscribed to that instance. `POST /api/rpc` and `GET /api/events`
remain as an older command-envelope surface for non-browser clients and the hub's own tests.

## Panel UI — BUILT

Single page, vanilla JS, served by the hub, dark theme, no build step and no CDN.

* **Login** screen; then a left rail of instances with live state pills.
* **Dashboard**: table of all instances — character, level, exp/h, money/h, hp/mana, state, target,
  waypoint, uptime — with bulk start/stop/restart/enable-bot actions.
* **Instance view**: tabs for Overview (stats + canvas charts), Bot (cavebot/targetbot/profile
  pickers, macro toggles, assigned scripts, auto-start/auto-relogin, reload), Console (log stream,
  Lua exec), Chat.
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

## Not done

* **Supplies vs thresholds.** `bot/supplies.lua` has no per-item ledger, so the panel's supplies
  column is empty. Needs a `supplies:levels() -> {[itemId]={have,threshold,name}}` in the bot.
* **Loot and waste *values*.** The counts are exact; the money needs the profile's price table
  (`vBot/items.lua`) to be present. With none, every non-coin item is worth 0 and the snapshot says
  so in `noDataFor`.
* **Config pickers before an instance has ever run.** The cavebot/targetbot/profile lists live in
  the worker's profile directory, so a stopped instance shows the last cached answer (empty on a
  fresh hub). A hub-side scan would need a directory-listing primitive the repo does not have.
* **Graceful shutdown on Windows Ctrl+C.** Linux has an orderly `sigtimedwait` path; Windows has no
  safe console-handler path from LuaJIT, so workers are reaped by the job object rather than by a
  `shutdown` command.
* **`login` blocks the reactor** for the duration of the HTTPS POST (`lib/http.lua` is synchronous,
  capped at 20 s). Status pushes and the bot tick pause for that request. A non-blocking TLS client
  would be needed.
* **No rate limiting on the worker control endpoint**, and no per-command authorisation there: the
  token is all-or-nothing.
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
* **Cross-browser and mobile.** The panel was driven only in Chromium.
