# Web panel + hub — requirements and architecture

Requested: a web panel that runs and supervises **many worker instances / characters**, each
connecting **through a proxy**, where an operator can pick the cavebot config, upload scripts that
run inside the bot, and watch live stats (level, experience per hour, money per hour, and more).
The panel has **web accounts** with an **administrator** who creates and removes them; **only the
administrator sees the panel's activity log**.

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

* **Hub** = a new Lua program in this repo (`hub/`), reusing `lib/socket.lua`, `lib/sched.lua`,
  `lib/json.lua`, the HTTP/WebSocket server code and the crypto libs. One process, single-threaded,
  same LuaJIT runtime, Windows and Debian.
* **Worker** = today's `luaclient` with a local control endpoint bound to `127.0.0.1` on an
  ephemeral port, speaking the same JSON command/event protocol the earlier single-worker design
  defined. The worker never faces the internet; only the hub talks to it.
* One worker process per character, exactly as before.

## Web accounts and authorisation

* Roles: `admin` and `user`.
* The admin creates and deletes web accounts, resets passwords, and is the only role that can read
  the **audit log**.
* A `user` sees and controls the instances assigned to them (default: the ones they created);
  the admin sees everything.
* Passwords: PBKDF2-HMAC-SHA256, per-user random salt, ≥ 200k iterations, stored as
  `pbkdf2$sha256$<iter>$<salt_b64>$<hash_b64>`. No password is ever logged, echoed or stored in
  plain text.
* Sessions: 32-byte random token, HttpOnly cookie, sliding expiry, revocable by the admin. Rate
  limit failed logins per account and per source address.
* First run: if no accounts exist, the hub prints a one-time admin bootstrap token to stdout and
  refuses to serve anything else until the first admin account is created with it.
* **TLS is out of scope for the hub.** It binds `127.0.0.1` by default; exposing it means putting it
  behind nginx/Caddy or an SSH tunnel. Binding a non-loopback address without `--allow-insecure`
  is refused, and the UI shows a warning banner when the connection is not HTTPS.

## Audit log (admin only)

Append-only JSONL, one record per event: timestamp, actor (web account or `system`), source IP,
action, target, outcome. Logged actions include: login success/failure, account create/delete/
password reset, game account or character added/removed, instance created/started/stopped/deleted,
config changed, script uploaded/enabled/deleted, remote Lua executed (with the code), proxy changed.
The admin UI can filter by actor, action and time range. Retention and rotation are configurable.

## Data model (JSON files under the hub's data dir, atomic write-and-rename)

```
users.json        [ {id, name, role, pwhash, createdAt, disabled} ]
accounts.json     [ {id, label, login, password(enc), token2fa?, ownerUserId} ]   game accounts
characters.json   [ {id, accountId, name, world, vocation?, lastLevel?} ]
instances.json    [ {id, characterId, ownerUserId, proxyId, botProfile, cavebotConfig,
                     targetbotConfig, scripts:[scriptId], autoStart, autoRelogin, state} ]
proxies.json      [ {id, label, kind:'http-connect', host, port, user?, pass(enc)} ]
scripts/          uploaded .lua files, content-addressed, with meta.json (name, owner, size, sha256)
audit.jsonl       the admin-only activity log
```

Game-account passwords and proxy passwords are encrypted at rest with a key derived from a hub
master secret (file `secret.key`, 0600, generated on first run). This protects the file at rest; the
hub necessarily can decrypt them to log characters in.

## Worker control protocol (hub ⇄ worker)

Reuses the earlier JSON design: request `{id, cmd, args}` → `{id, ok, result|error}`, plus
`{event, data}` pushes. Commands the panel needs:

`status`, `login`, `logout`, `relogin`, `bot.enable {on}`, `bot.setCavebot {name}`,
`bot.setTargetbot {name}`, `bot.listConfigs`, `bot.reload`, `script.put {name, source}`,
`script.remove {name}`, `script.list`, `exec {code}`, `stats`, `shutdown`.

Events: `status` (1 Hz), `stats`, `log`, `chat`, `loginState`, `gameStart`, `gameEnd`, `death`,
`error`.

## Statistics the panel shows

Per instance, computed in the worker and pushed with `stats`:

| metric | how |
|---|---|
| level, experience | from the player-stats packet |
| **exp/h** | sliding window over experience samples (default 15 min, also session average) |
| **money/h** | value of gold/platinum/crystal gained plus loot sold value, over the same window |
| loot/h, waste/h, balance | loot value minus supply consumption, vBot-style |
| supplies | current counts vs thresholds from `Supplies.json` |
| kills/h, deaths | from combat and death events |
| hp/mana, position, target, cavebot waypoint | live state |
| uptime, online time, reconnects | supervisor bookkeeping |

The hub keeps a rolling history per instance (in memory plus periodic flush) so the panel can draw
short time series without a database.

## Script upload

* Upload a `.lua` file through the panel; the hub stores it and pushes it to the selected instances.
* The worker writes it into the bot profile it runs and loads it in the same environment the bot's
  own scripts use, so a script written for vBot works unchanged (this is the point of the
  compatibility shim described in `ARCHITECTURE.md`).
* Scripts are **arbitrary code inside the worker**: only authenticated web accounts can upload, every
  upload and execution is audited, and the worker sandboxes nothing beyond what vBot does. This is a
  deliberate trust decision, and the UI states it.

## Proxy support (worker side, prerequisite)

* Per-instance proxy from `proxies.json`, passed as `--proxy=host:port` and
  `--proxy-auth=user:pass`.
* The game socket is tunnelled with HTTP `CONNECT` before the world-name preamble (the reference
  client does exactly this); the HTTPS login POST uses the same proxy through WinHTTP/libcurl.
* Without it, an IP-restricted account cannot log in at all — see `docs/live-login-notes.md`.

## Panel UI

Single page, vanilla JS, served by the hub, dark theme, no build step and no CDN.

* **Login** screen; then a left rail of instances with live state pills.
* **Dashboard**: table of all instances — character, level, exp/h, money/h, hp/mana, state, target,
  waypoint, uptime — with bulk start/stop/enable-bot actions.
* **Instance view**: tabs for Overview (stats + charts), Bot (cavebot/targetbot config pickers,
  macro toggles, scripts assigned), Console (log stream, Lua exec), Chat.
* **Characters & accounts**: add/remove game accounts and characters, assign proxies.
* **Scripts**: upload, list, assign to instances.
* **Admin** (admin only): web accounts CRUD, sessions, and the audit log viewer.

## Build order

1. Worker: proxy support, control endpoint, stats computation, script loading. *(prerequisite)*
2. Hub: storage, auth, HTTP/WS server, worker supervision, audit log.
3. Panel UI.
4. End-to-end tests with fake workers, on Windows and Debian.
