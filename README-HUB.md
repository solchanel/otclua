# The hub and the web panel

The hub is one Lua process. It serves the panel, keeps the accounts, spawns and
supervises one worker per character, and writes the audit log. Everything below
runs identically on Windows and Debian.

```
browser ──HTTP/WS──► hub (hub/main.lua)
                        │  users, game accounts, characters, proxies,
                        │  instances, uploaded scripts, audit log
                        ├─loopback control socket─► worker 1 (main.lua, character A)
                        ├──────────────────────────► worker 2 (character B)
                        └──────────────────────────► worker N
                                                        └──proxy──► game server
```

---

## 1. Start it

```sh
./run-hub.sh                       # Debian / any POSIX shell
run-hub.bat                        # Windows
```

Both launchers pass their own interpreter to the hub as `--luajit`, so every
worker the hub spawns runs on exactly the build that is running the hub. Set
`LUACLIENT_LUAJIT` (POSIX) or `LUACLIENT_LUAJIT` in the environment (Windows) to
choose a different one.

Useful flags (`--help` prints them all):

| flag | default | what it does |
|---|---|---|
| `--port=N` | 8777 | TCP port |
| `--bind=ADDR` | 127.0.0.1 | bind address; anything else needs `--allow-insecure` |
| `--data-dir=DIR` | `./hub-data` | where everything below is stored |
| `--panel-dir=DIR` | `./panel` | the static files it serves |
| `--workers-dir=DIR` | `.` | the working directory each worker gets |
| `--worker-script=PATH` | `main.lua` | the worker entry point |
| `--worker-arg=FLAG` | — | an extra flag for **every** worker; repeatable |
| `--worker-env=K=V` | — | extra environment for **every** worker; repeatable. Settings only — never a credential |
| `--game-host=H` `--game-port=N` | — | the game server the workers log in to |
| `--login-url=URL` | — | the account-login endpoint the workers POST to |
| `--csrf-strict` | off | make `X-CSRF-Token` mandatory on every write (implied by `--allow-insecure`) |
| `--allowed-host=NAME` | — | an extra `Host` header a non-loopback bind answers to; repeatable |
| `--trusted-proxy=CIDR` | — | believe `X-Forwarded-For` from this front end (IPv4); repeatable |
| `--no-autostart` | off | ignore each instance's `autoStart` flag on boot |
| `--log-file=PATH` | — | append the hub log to a file as well as stdout |
| `--proxy-test-target=H:P` | `example.com:443` | what the **Test** button CONNECTs to |

To try the whole thing with no game server, give the workers `--dry-run`:

```sh
./run-hub.sh --port=8791 --worker-arg=--dry-run
```

A worker started that way boots the client, starts the bot layer and serves its
control endpoint without touching the network. That is the mode
`test/hube2esuite.lua` drives.

---

## 2. First run — the bootstrap token

The hub refuses to serve anything but the bootstrap endpoint until an
administrator exists. On the first start it prints a one-time token **to stdout
only** — never to `--log-file`:

```
================================================================
 FIRST RUN -- no web accounts exist yet.
 Open  http://127.0.0.1:8777/  and create the
 administrator with this one-time bootstrap token:

     b50361628606d339e433f2abef44b4772047abc6fa1adec4516921d183e74968

 It is printed here only, never to the log file.
================================================================
```

Open the panel, paste the token, choose a name and a password of at least ten
characters. The token is compared in constant time, dies after a few wrong
guesses, and cannot be used again once the first administrator exists (a second
attempt is a `409`). Every attempt, right or wrong, is audited.

If you lose the token before using it, stop the hub, delete `users.json` from the
data directory and start it again — that is safe only while no account exists.

---

## 3. Add a web account

**Admin → Web accounts → + Account.** Name, role (`admin` or `user`) and a
password of at least ten characters.

* An `admin` sees every instance, every game account and the audit log.
* A `user` sees only the rows they own — the instances, game accounts, characters
  and scripts they created. Asking for someone else's id returns `404`, not
  `403`, so an id probe cannot tell "not yours" from "gone".
* Only an admin can create or delete web accounts, reset a password, revoke a
  session or read the audit log. All four gates are enforced in the hub, not in
  the page.
* Only an admin can **run Lua in a worker or upload a script**. Those two routes
  are administrator-only by default because the code runs unsandboxed under the
  hub's own user account — see §7. The **Remote Lua** column in the account table
  says who has it, and **Grant Lua** / **Revoke Lua** changes it; both are written
  to the audit log as `user.canExec`. A plain account without it gets `403` from
  `POST /api/instances/:id/exec` and `POST /api/scripts`.
* Passwords are PBKDF2-HMAC-SHA256 at 200 000 iterations with a per-user salt.
  Nothing ever logs, echoes or stores one in the clear.
* Sessions live in memory, so **restarting the hub signs everyone out.** That is
  deliberate: a bearer credential on disk buys nothing.

A user changes their own password with the **Password** button in the header; an
admin resets someone else's with **Reset password**. Either revokes that
account's live sessions immediately. Getting the current password wrong in that
form does **not** count against the login limiter, so a mistyped form cannot lock
you out of the panel. Signing in also revokes whatever session that browser
already held, so a session you have noticed as stolen dies when you sign in again.

---

## 4. Add a game account, a character, a proxy and an instance

All four live on **Characters & Accounts**.

1. **Game account** (`+ Account`): a label, the login, the password, and the 2FA
   token if the account has one. The password is **write-only** — it is sealed
   with the hub master key the moment the row exists, and no endpoint ever
   returns it. Leave the field empty when editing to keep the stored one.
2. **Character** (`+ Character`): pick the game account, then the character name,
   the world, and optionally the vocation.
3. **Proxy** (`+ Proxy`): a label, `http-connect`, host, port, and the
   credentials if the proxy wants them. The password is write-only in the same
   way. **Test** dials a real `CONNECT` through it (to `--proxy-test-target`) and
   reports the latency — it is the one button in the panel that touches the
   network by itself. Proxies are a **shared pool**: any signed-in account may
   attach one, and none of them can read the stored credential.
4. **Instance**: the row in the Characters table has an **instance** cell; create
   one there, then pick its proxy from that row's dropdown. One instance per
   character. Its bot profile, cavebot config, targetbot config, auto-start and
   auto-relogin are on the instance's **Bot** tab.

Then **Start** it — from the dashboard, the left rail, or the instance header.
The hub spawns `luajit main.lua`, hands it a control token down a private stdin
pipe, learns the ephemeral port from the worker's own
`control-endpoint 127.0.0.1 <port> <name>` line, opens an authenticated control
WebSocket, starts the bot layer, pushes the configs and the assigned scripts, and
then logs the character in. A worker that dies is restarted with exponential
backoff (1 s → 60 s, jittered, reset after a minute of health).

**No credential is ever placed in argv.** The control token and the proxy
credential go down stdin; the game-account password goes in the `login` command
over the loopback control socket, after which the hub drops its copy.
`lib/process.lua` refuses to spawn a command line that carries a secret, and the
supervisor additionally checks this launch's actual plaintexts against every
argument.

---

## 5. Upload a script

**Scripts → Upload .lua…** picks a `.lua` file. The hub stores the
source under `<data-dir>/scripts/<id>.lua` with its metadata (name, owner, size,
sha256), and **Assign** pushes it to the instances you pick. Uploading the same
name again replaces it, and any running instance that already has it gets the new
source immediately.

The worker compiles the script **before** writing it — a syntax error is reported
and nothing is stored — then writes it into the bot profile it is running and
loads it in the same environment the bot's own scripts use, so a script written
for vBot works unchanged. Every macro and event handler the script registers is
remembered, so removing or replacing it takes them back out again.

Two things to know:

* An uploaded script is **arbitrary Lua inside the worker**, and the worker runs
  as the same OS user as the hub with the hub's data directory readable. There is
  no sandbox — vBot has none either. Uploading is therefore **administrator-only
  by default**; an admin may grant a named account the remote-Lua capability
  (§3). Every upload, assignment and execution is audited, an execution with its
  full source. Read §7 before you grant it: that account can read `secret.key` and
  decrypt every other account's stored game password.
* `bot.reload` (the **Reload bot** button) drops the script environment, so
  uploaded scripts are **not** restored across a reload. Re-assign them after
  one.

The **Console** tab runs one-off Lua in the same environment, and is gated by the
same capability — an account without it sees the tab explain why the box is not
there. The code, the account that ran it and the result all go in the audit log.

---

## 6. What is stored, and where

Everything sits under `--data-dir`:

```
users.json        web accounts (name, role, PBKDF2 hash, canExec, lastLoginAt, disabled)
accounts.json     game accounts (label, login, sealed password, sealed 2FA token)
characters.json   name, world, vocation, account
proxies.json      label, kind, host, port, user, sealed password, owner
instances.json    character, owner, proxy, bot profile, configs, scripts, flags
scripts.json      uploaded-script metadata
scripts/<id>.lua  the sources themselves
history/<id>.json a rolling stats history per instance, flushed every 60 s
audit.jsonl       the admin-only activity log (rotated, `audit.1.jsonl`, ...)
secret.key        the hub master key, 0600
```

Each JSON file is written atomically (write a temp file, fsync, rename) and
carries a SHA-256 integrity footer. A truncated, empty, corrupted or
unparsable file is **reported by name and never silently emptied**. Two hub
processes must not share a data directory; there is no lock file.

Keep the path ASCII on Windows: the filesystem layer uses the ANSI API so that
it and Lua's own `io.open` never disagree about a name.

---

## 7. Security notes

**Loopback by default.** The hub binds `127.0.0.1` and **refuses** any other
address unless you pass `--allow-insecure`. It speaks plain HTTP and has no TLS:
the session cookie, every `exec` chunk and every reply would cross the network in
the clear. The supported way to expose it is a TLS terminator — nginx, Caddy — or
an SSH tunnel:

```sh
ssh -N -L 8777:127.0.0.1:8777 you@the-box      # then open http://127.0.0.1:8777/
```

With `--allow-insecure` the hub logs a four-line warning, sets `Secure` on its
cookies, and the panel draws a permanent "Not HTTPS" banner.

**Encrypted at rest:** game-account passwords, game-account 2FA tokens and proxy
passwords. Each is sealed with a key derived from `secret.key`, bound to its own
row and field, so a ciphertext copied into another row will not decrypt. The hub
can necessarily decrypt them — it has to, to log a character in.

**Not encrypted:** everything else. Account labels and logins, character names,
proxy hosts, ports and usernames, instance configuration, uploaded script
sources and the whole audit log are plain JSON on disk. Web-account passwords are
not encrypted either — they are PBKDF2 hashes, which is stronger, because nothing
ever needs to read them back.

`secret.key` is created 0600 on the first run, and **only** when the data
directory holds no sealed record. If `accounts.json` or `proxies.json` already
contains one and the key is missing, the hub refuses to start rather than mint a
new key — a fresh key over existing records would make every stored password
permanently undecryptable, and the failure would look exactly like tampering.
Back `secret.key` up with the data directory; it is useless without it.

**CSRF.** Four independent checks on every write: the body must be
`application/json`; `Origin`, when present, must be same-origin; `Sec-Fetch-Site`,
when present, must be `same-origin` or `none`; and `X-CSRF-Token`, when present,
must match the session's token. `--csrf-strict` makes that last header mandatory,
and `--allow-insecure` turns it on for you — on a published plaintext bind the
token is the only one of the four that a rebound or cross-origin page cannot
produce, because producing it means having *read* a same-origin response.
The session cookie is `HttpOnly`, `SameSite=Strict`, `Path=/`, and `Secure`
whenever the bind is not loopback.

The same-origin comparison **includes the port**: `http://localhost` (port 80)
and `https://localhost` (443) are not same-origin with `Host: localhost:8877`.
Cookies are not port-scoped, so treating a missing port as "any port" let any
other service on 80 or 443 — or an XSS in one — read `hub_csrf`, have the session
cookie attached and pass every check.

**The `Host` header is pinned, always.** A loopback bind answers to `127.0.0.1`,
`localhost` and `[::1]`. A non-loopback bind answers to its own bind address plus
whatever you list with `--allowed-host=NAME`, and to nothing else — that is what
stops DNS rebinding, where a name the attacker controls resolves to your hub and
makes `Origin`, `Host` and `Sec-Fetch-Site` all agree. If you put a name in front
of the hub, name it:

```sh
./run-hub.sh --bind=0.0.0.0 --allow-insecure --allowed-host=panel.internal \
             --trusted-proxy=10.0.0.0/8
```

**Sign-ins are serialised and bounded.** One password check is ~270 ms of
uninterruptible work, so the hub runs them one at a time behind a short queue and
answers `429` past it rather than letting a burst of logins stall telemetry and
the bot ticks. Failed logins lock the **account** they were aimed at (5 in 15
minutes); the per-address counter is a much looser throttle that is consulted only
after a password has been found wrong, so a correct credential is never refused
because of the address it came from. Behind a reverse proxy every request shares
one address, which is why that distinction matters and why `--trusted-proxy=CIDR`
exists.

**Only the panel is served.** `--panel-dir` also holds the development harness —
`devhub.lua`, `panel/mock/`, `panel/test/` — and those answer `404` to everyone.
To run the panel's own unit tests, open `panel/test/index.html` from the file
system or from `panel/devhub.lua`, not from the hub.

**The event stream** (`GET /ws`) is Origin-checked, needs the session cookie for
the handshake **and** a first frame carrying the CSRF token, and receives log and
chat lines only for the instances that socket has subscribed to. An unknown or
expired cookie authenticates nothing at all.

**The workers never face the internet.** Each binds `127.0.0.1` on an ephemeral
port and requires a 32-byte bearer token compared in constant time. Only the hub
talks to them.

**The trust model, stated plainly — and the one capability that carries it.**
A worker runs unsandboxed, **as the same OS user as the hub**, with the hub's data
directory readable. So `exec` and `script.upload` are not "power over your own
bot": code running in a worker can read `secret.key`, decrypt every stored
game-account password and 2FA token — *including other accounts'* — read
`users.json` for offline password cracking, and read the admin-only audit log.

Both routes are therefore **administrator-only by default**. An administrator can
grant a named web account the remote-Lua capability (Administration → Web
accounts → **Grant Lua**, or `PATCH /api/admin/users/:id {"canExec": true}`);
the grant and the revocation are both written to the audit log as `user.canExec`,
and every use is recorded with the full source.

> **Residual risk.** An account with `canExec` is, in practice, an administrator of
> the host this hub runs on. Grant it only to someone you would also give a shell
> account. There is no sandbox and there is no per-worker OS user; isolating the
> worker (a separate account, a systemd user slice, a container) is the change that
> would make the capability merely powerful rather than total, and it is not built.

What a worker does **not** get is the hub's own descriptors or its signal mask:
every fd above 2 is closed between `fork()` and `execve()`, the sockets and data
files are created close-on-exec (non-inheritable on Windows), and the child's
signal mask is reset so `PR_SET_PDEATHSIG` and a graceful `SIGTERM` really work.
Without that a worker held the hub's listening socket — an orphan kept the port
bound, so the hub could not restart — and the audit log's append handle, which
made the "append-only, tamper-evident" log forgeable from inside a worker.

**Proxies are shared to use, owned to change.** Any signed-in account may list a
proxy and attach it to its own instance, and none of them can read the stored
credential. Only the account that created it, or an administrator, may change its
host, port, user or password, or delete it — repointing somebody else's exit node
would tunnel every instance attached to it through a machine of the attacker's
choosing. `proxy.test` reports a fixed reason (`unreachable` / `not a proxy` /
`refused` / `timeout`), never the peer's own banner, refuses loopback and private
addresses, and is rate-limited: otherwise it is a port scanner for the hub's whole
network position.

**The audit log** records login success and failure, account and password
changes, every game account, character, proxy, instance and script change, every
start, stop and config change, every refused admin route, every CSRF refusal, and
every `exec` **with its code**. Each record carries the actor, the source IP, the
action, the target and the outcome. It is fsynced before the call that wrote it
returns, rotated by size, and only an administrator can read it.

It also records a **cross-tenant probe**: an attempt on another account's
instance, game account, character or script is refused with `404` and written as
`denied`, naming the command and the id that was asked for. And it holds a
**per-actor write budget** — 200 records immediately, 20/s sustained — so no one
account can force a rotation and scroll genuine records out of retention. When the
budget bites, one `audit.throttled` record says how many were suppressed; the
hub's own `system` records are exempt. Bulk actions are capped at 100 ids, and the
failures in one request collapse into a single record.

---

## 8. Testing it

```sh
luajit test/hube2esuite.lua       # the whole stack against REAL workers
luajit test/hubapisuite.lua       # the hub internals against a fake worker
luajit test/hubcoresuite.lua      # storage, model, auth, audit
luajit test/controlsuite.lua      # the worker's control endpoint
luajit test/processsuite.lua      # spawning, and what a child does NOT inherit
luajit test/probe_roles.lua       # drive every admin route as a plain user, and print
luajit test/selftest.lua          # everything below the hub
```

`probe_roles.lua` is a report rather than a test: it starts a throwaway hub, makes
an administrator and a plain user, drives every administrator-only route plus
`exec` and `script.upload` as that plain user, and prints the status line the hub
really answered with. It leaves its data directory behind so you can grep it for
plaintext credentials — there should not be any.

`hube2esuite` builds a real hub on a temporary data directory, bootstraps it over
REST, creates the whole fleet, starts `luajit main.lua --dry-run` as a real child
process, drives the panel's own WebSocket dialect, runs Lua in the worker, uploads
a script and watches it execute, stops the worker and checks the pid is gone, and
then reads the audit log back. It also asserts the API contract in both
directions: every route the hub serves is one `panel/api.js` calls, and every
endpoint `panel/api.js` calls is one the hub serves.

Its §11 runs the **real** launch with no `--dry-run` anywhere: a second hub, a
fake account-login endpoint in-process, and `test/fakeserver.lua --serve=PORT` —
an independent implementation of the 1530 wire format — as the game server. The
hub decrypts the stored password, spawns a worker with nothing secret in argv,
sends `login` over the control socket, and the worker completes the whole login
handshake and reports **online** in the panel. On Linux it then reads
`/proc/<pid>/cmdline`, `/proc/<pid>/environ` and `/proc/<pid>/fd` of that live
worker and asserts the password is in none of them.

The panel's own unit tests are `panel/test/index.html` — open it from
`panel/devhub.lua` (a standalone fixture) or straight off the file system, and it
runs 32 DOM-free tests of the HTTP and WebSocket clients. The **hub does not serve
that directory**, so it is a development tool, not part of the deployed surface.
`?mock=1` runs the whole panel against a fake network with no hub at all;
`?mock=1&fleet=40` gives it forty instances.
