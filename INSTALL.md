# Installing on Debian

One command on a fresh Debian 12 or 13 server gets you a running, sandboxed hub
serving the web panel on loopback, and workers it can spawn.

```sh
tar -xzf luaclient-<version>.tar.gz
sudo sh luaclient-<version>/deploy/install.sh
```

or, straight from a checkout:

```sh
sudo sh deploy/install.sh
```

`README-HUB.md` is the operator's guide to *using* the panel once it is up —
accounts, characters, proxies, instances, scripts. This file is about getting it
onto a machine and keeping it there. `deploy/README.md` documents the scripts
themselves.

---

## 1. What the installer does

It is **idempotent**: running it again reinstalls the application tree and leaves
your data, your master key, `/etc/luaclient/hub.conf` and the service user
exactly as they were.

| | |
|---|---|
| **Preflight** | refuses to run unless it is root; checks `/etc/os-release` for Debian 12/13 and the architecture for one Debian ships `luajit` on (`amd64`, `arm64`, `armhf`, `i386`). `--force` gets past both, deliberately loudly. |
| **Dependencies** | `apt-get install luajit curl ca-certificates`, then **verifies** that `luajit -v` says 2.1 and that the FFI is present and usable. A LuaJIT built with `LUAJIT_DISABLE_FFI` cannot run this program at all — every socket, every file descriptor and every spawn is FFI — so that check is a hard stop with a message that says what to do. |
| **Service user** | system user and group `luaclient`, shell `/usr/sbin/nologin`, home `/var/lib/luaclient` and no home created beyond it. |
| **Application** | `/opt/luaclient`, root-owned, `0755`/`0644`, **read-only to the service**. The installer prints the exact count — **115 files** from the current tarball (113 packaged files plus the `deploy/VERSION` and `deploy/MANIFEST.sha256` that `package.sh` adds; 113 when you install straight from a checkout), of which **87 are `.lua`**: the hub, the worker, the panel, `lib/`, `proto/`, `game/`, `bot/`, `control/`, `shim/`, `assets/`, `data/`, the docs, and `deploy/` itself. No tests, no `docs/`, no `panel/test`, `panel/mock` or `panel/devhub.lua`. |
| **State** | `/var/lib/luaclient`, mode **0700**, owned by `luaclient`. Everything the hub writes: `users.json`, `accounts.json`, `secret.key`, `audit.jsonl`, uploaded scripts, per-instance history. |
| **Worker directory** | `/var/lib/luaclient/workers`, 0700 — the cwd every worker gets, and where a relative `--bot-profile` lands. It is under the state directory precisely because `/opt/luaclient` is read-only. |
| **Logs** | `/var/log/luaclient`, 0750, owned by `luaclient:adm`, plus `/etc/logrotate.d/luaclient` (weekly, keep 8, compressed). |
| **Config** | `/etc/luaclient/hub.conf`, 0640 `root:luaclient`, written **once** — your edits survive re-installs and upgrades. |
| **Service** | `/etc/systemd/system/luaclient-hub.service`, enabled and started, validated with `systemd-analyze verify`. |

Options:

```
--port=N        listen port                              (default 8777)
--bind=ADDR     listen address                      (default 127.0.0.1)
--source=DIR    the tree to install from     (default: the script's ..)
--skip-apt      verify the dependencies, do not touch apt
--no-start      install everything but do not start the service
--no-enable     do not enable it at boot
--force         continue past the Debian-version and architecture checks
```

### Game assets

`assets/items1530.bin` (949,392 bytes) ships in the tarball and the installer
refuses to continue without it: `proto/parser.lua` cannot decode a single map
description without its FLAGS1 table, so a worker without it does not run at all.

Regenerate it when the server ships a new asset set — i.e. when
`data/things/1530/appearances-*.dat` changes:

```sh
python3 /opt/luaclient/tools/extract_appearances.py \
        --things-dir /path/to/otclient/data/things/1530 \
        --out /opt/luaclient/assets/items1530.bin
systemctl restart luaclient-hub
```

The extractor is deterministic — two runs over the same input give a
byte-identical file — and `assets/README.md` records the format, the expected
size and the sha256 of the current one. Regenerating in place is fine, but the
tidy way is to regenerate in your source tree and ship a new tarball, because
`upgrade.sh` will otherwise overwrite it on the next release.

---

## 2. First run — the bootstrap token

The hub refuses to serve anything but the bootstrap endpoint until an
administrator exists. On its first start it prints a one-time token **to stdout
only, never to the log file**, so under systemd it lands in the journal and
nowhere else:

```sh
journalctl -u luaclient-hub --no-pager --since '-5min' | grep -A4 'bootstrap token'
```

```
Sep 06 11:57:00 host luaclient-hub[1478]:  administrator with this one-time bootstrap token:
Sep 06 11:57:00 host luaclient-hub[1478]:      82dbfd39c9a1…64 hex…
Sep 06 11:57:00 host luaclient-hub[1478]:  It is printed here only, never to the log file.
```

The `--since` matters. journald keeps the *previous* installation's tokens too —
`uninstall.sh --purge` cannot rewrite the journal — so without it the grep prints
a pile of dead tokens from earlier attempts and the newest one is at the bottom.
Take the last block, or check the pid against `systemctl show luaclient-hub -p
MainPID`.

Open the panel, paste the token, choose a name and a password of at least ten
characters. The token is compared in constant time, dies after a few wrong
guesses, is refused with `409` once an administrator exists, and every attempt —
right or wrong — is audited.

Reach the panel before you have TLS with an SSH tunnel:

```sh
ssh -N -L 8777:127.0.0.1:8777 you@the-server      # then http://127.0.0.1:8777/
```

**Restarting the service mints a new token** while no account exists, so if you
miss it, `systemctl restart luaclient-hub` and read the journal again. If you
lose it *after* the admin exists, you do not need it — sign in normally.

---

## 3. Putting TLS in front

The hub speaks plain HTTP and binds loopback. It refuses any other bind without
`--allow-insecure`, and that flag is meant to be hard to type by accident: the
session cookie, every Lua chunk you run in a worker and every reply would cross
the network in clear text.

```sh
apt-get install nginx
cp /opt/luaclient/deploy/nginx-luaclient.conf /etc/nginx/sites-available/luaclient
# edit server_name (three places) and the upstream port if you changed it
ln -s ../sites-available/luaclient /etc/nginx/sites-enabled/luaclient
nginx -t && systemctl reload nginx

apt-get install certbot python3-certbot-nginx
certbot --nginx -d panel.example.com --agree-tos -m you@example.com --redirect
```

Then, in `/etc/luaclient/hub.conf`:

```
HUB_EXTRA_ARGS="--csrf-strict --trusted-proxy=127.0.0.1/32"
```

```sh
systemctl restart luaclient-hub
```

* `--csrf-strict` makes `X-CSRF-Token` mandatory on every write. Behind a
  terminator this is the check that still does full-strength work — read the
  comment at the top of `deploy/nginx-luaclient.conf` for exactly why the proxy
  has to rewrite `Host` and `Origin`, and what that costs.
* `--trusted-proxy` makes the hub believe `X-Forwarded-For` **from nginx and
  from nowhere else**. Without it every request behind the proxy shares one
  rate-limiter bucket.

The nginx example also carries HSTS, `X-Content-Type-Options`, `X-Frame-Options:
DENY`, a CSP, a `Referrer-Policy`, a WebSocket upgrade map for `GET /ws`, two
rate-limit zones (30 r/s general, 12 r/min on `/api/session` and
`/api/bootstrap`, which sit in front of a ~270 ms PBKDF2 in a single-threaded
process) and a `default_server` that answers `444` to every other name.

Leave `HUB_BIND=127.0.0.1`. nginx reaches the hub over loopback; nothing else
should.

Driven through nginx with a self-signed certificate, that configuration answers:

```
GET  /api/health                                        200
GET  /                                                  200, 1475 bytes
POST /api/bootstrap   Origin: https://panel.example.com 200   (admin created)
POST /api/accounts    + X-CSRF-Token                    200
POST /api/accounts    without X-CSRF-Token              csrf-invalid: missing X-CSRF-Token
POST /api/accounts    Origin: https://evil.example      csrf-invalid: cross-site request refused
GET  /ws              --http1.1, Upgrade: websocket     101 Switching Protocols
GET  https://other.example/                             444 (connection closed)
20 rapid POST /api/session                              401 ×5 then 429 ×15
```

If you test the WebSocket with plain `curl` and get a `400`, add `--http1.1`:
HTTP/2 has no `Upgrade` mechanism. A browser knows that and opens a separate
HTTP/1.1 connection for `GET /ws` by itself.

---

## 4. Backup and restore

Everything that matters is `/var/lib/luaclient`, and the file that matters most
inside it is `secret.key`.

> Every stored game-account password, 2FA token and proxy password is sealed
> with a key derived from `secret.key`. **A copy of the data directory without
> that file is not a backup** — it is a pile of ciphertext that nothing will ever
> open again. The hub knows this: if sealed records exist and the key is gone it
> refuses to start rather than mint a new one.

### Back up

```sh
systemctl stop luaclient-hub
tar -czf /root/luaclient-$(date -u +%Y%m%dT%H%M%SZ).tar.gz \
    -C /var/lib luaclient
cp /etc/luaclient/hub.conf /root/
systemctl start luaclient-hub
chmod 600 /root/luaclient-*.tar.gz
```

Stopping first is what makes it consistent, and it is also correct for the game:
the hub asks every worker to **log out** before it exits, and a character that
is merely killed stays online for the server's own logout timeout — the next
login on that account is then refused with `session ended`.

A hot copy is *nearly* safe — every JSON file is written atomically with a
SHA-256 footer, so you get the complete old file or the complete new one — but
the files are not consistent with each other. Use it only when a brief stop is
impossible.

`deploy/upgrade.sh` takes exactly this backup for you, into
`/var/backups/luaclient/`, before it touches anything.

### Restore

```sh
systemctl stop luaclient-hub
rm -rf /var/lib/luaclient
tar -xzf /root/luaclient-20260906T110531Z.tar.gz -C /var/lib
chown -R luaclient:luaclient /var/lib/luaclient
chmod 700 /var/lib/luaclient /var/lib/luaclient/workers
systemctl start luaclient-hub
curl -s http://127.0.0.1:8777/api/health
```

The archive contains `secret.key` in the clear. Treat it as a credential: 0600,
root-only, encrypted wherever it goes off the box.

---

## 5. Upgrading

```sh
sudo sh /opt/luaclient/deploy/upgrade.sh --tarball=/root/luaclient-2026.09.13.tar.gz
# or
sudo sh /opt/luaclient/deploy/upgrade.sh --source=/root/luaclient-2026.09.13
```

In order: sanity-check the new tree (it must contain `hub/main.lua`, `main.lua`,
`panel/`, `deploy/` and `assets/items1530.bin`, and must load under the installed
LuaJIT) → stop the service, so every worker logs out → back up
`/var/lib/luaclient` and `hub.conf` to `/var/backups/luaclient/` → park the old
tree at `/opt/luaclient.old-<stamp>` → install the new one → **migration dry
run** → start → wait for `/api/health`. Any failure from the swap onward puts
the old tree back, restores the data directory from the backup it just took, and
restarts the service that was running before.

The migration dry run deserves a word. `hub/storage.lua` applies a collection's
schema migrations **when the file is loaded**, and marks the result dirty so it
is persisted at the next save. So reading every collection with the new code
*is* the migration — `upgrade.sh` does it as the service user, with nothing else
running, before the service comes back, where a failure is still recoverable:

```
== Migration dry run
  users        rows=1     version=1   bytes=352
  accounts     rows=1     version=1   bytes=311
  ...
  data directory reads clean under the new code
```

A tarball is verified against its `.sha256` if one sits beside it, and refused
if it does not match. `--keep=N` controls how many backups are kept (default
10); `--no-rollback` leaves a failed upgrade in place for inspection.

`secret.key` is never touched, so every sealed credential still opens. Instances
flagged `autoStart` come back on their own.

---

## 6. Reading the logs

```sh
systemctl status luaclient-hub            # is it up, what is it running, memory
journalctl -u luaclient-hub -f            # live
journalctl -u luaclient-hub -n 200        # the last 200 lines
journalctl -u luaclient-hub --since '1 hour ago' -p warning
tail -f /var/log/luaclient/hub.log        # the same log, as a file
```

Three streams, and they are not the same thing:

* **the journal** — the hub's log *plus* its stdout, which is where the
  bootstrap token appears and the only place it ever does;
* **`/var/log/luaclient/hub.log`** — `--log-file`, the hub's own log lines,
  rotated weekly by logrotate, keep 8. The bootstrap token is deliberately not
  in here;
* **the audit log**, `/var/lib/luaclient/audit.jsonl` — the panel's activity
  record, readable in the Admin tab by an administrator and by no one else. It
  is append-only JSONL, fsynced per record and rotated by size. Read it in the
  panel; `jq` on the file works too when you are on the box.

Raise the hub's own verbosity with `HUB_LOG_LEVEL=debug` in `hub.conf` and a
restart. A worker's console output is not in the journal — it goes over the
control link into the hub's per-instance ring buffer, which is what the panel's
**Console** tab shows.

---

## 7. Troubleshooting

**The service will not start at all.**

```sh
systemctl status luaclient-hub -l
journalctl -u luaclient-hub -n 50 --no-pager
```

**`hub: cannot create secret.key` / the data directory is unwritable.**
`/var/lib/luaclient` must be `0700 luaclient:luaclient`, and `ReadWritePaths` in
the unit must name it — `ProtectSystem=strict` makes everything else read-only.

```sh
ls -ld /var/lib/luaclient
chown -R luaclient:luaclient /var/lib/luaclient && chmod 700 /var/lib/luaclient
```

**The hub refuses to start and says a sealed record exists but the key is
missing.** That is the guard, working. Restore `secret.key` from the backup that
goes with this data directory. Do not delete the data to get past it: a fresh
key over existing records makes every stored password permanently
undecryptable, and the failure would look exactly like tampering.

**Starting an instance answers `execvp "/usr/bin/luajit": No such file or
directory` — and luajit is obviously there.** It is the *working directory* that
is missing, not the interpreter: the worker is spawned with
`cwd=/var/lib/luaclient/workers`, and `execvp` reports the failed `chdir` with
that message. (Observed for real, by deleting the directory.)

```sh
mkdir -p /var/lib/luaclient/workers
chown luaclient:luaclient /var/lib/luaclient/workers
chmod 700 /var/lib/luaclient/workers
```

**A worker starts and immediately dies with a read-only filesystem error.** Its
bot profile is resolving into `/opt/luaclient`, which is read-only on purpose.
Check that the unit still passes `--workers-dir=/var/lib/luaclient/workers` and
that the instance's bot profile is a relative name (`profile_1`), not an
absolute path into `/opt`.

**The panel loads but every write answers `403 csrf-invalid`.** You are behind a
proxy that is not rewriting `Host` and `Origin` the way
`deploy/nginx-luaclient.conf` does. The hub pins the `Host` header and compares
`Origin` against it **including the port**. Use the shipped config, or make
yours match it.

**Sign-in answers `429 rate-limited`.** Two different limiters. Five failures
against one account name in fifteen minutes locks *that account*; the
source-address counter is much looser and is only consulted after a password has
already been found wrong. Behind a proxy without `--trusted-proxy`, every
request shares one address — set it. Note that the *self-service password
change* deliberately does not count against either, so a mistyped form cannot
lock you out.

**`404` on `/test/index.html`, `/mock/…` or `/devhub.lua`.** Working as
intended, and they are not installed anyway: the panel's own harness is
development-only and `hub/server.lua` refuses to serve it.

**Nothing answers on the port, and `ss` shows nothing listening.**

```sh
ss -ltnp | grep 8777
grep -E '^HUB_(BIND|PORT)' /etc/luaclient/hub.conf
```

A non-loopback `HUB_BIND` without `--allow-insecure` in `HUB_EXTRA_ARGS` is
refused at startup, by design, and the reason is in the journal.

**The panel shows "prices not loaded", or loot and waste are worth 0.** Not a
deployment failure: the worker found no price table. Prices come from the bot
profile's `vBot/items.lua`, so an instance whose `--bot-profile` directory has no
`vBot/items.lua` prices only the three coins. The live status says exactly which
case you are in — `pricesSource` reads `profile`, `file`, `profile+file` or
`coins-only`, `pricesLoaded` counts what came from a real source, and
`noDataFor` gains `itemPrices` when nothing did. To price items without touching
the profile, point every worker at your own table:

```sh
# /etc/luaclient/hub.conf
HUB_EXTRA_ARGS="--worker-arg=--dry-run --worker-env=LUACLIENT_PRICES=/etc/luaclient/prices.json"
```

That file is keyed by **item id**, not by name, and overrides the profile per id.
A name-keyed file (a copy of vBot's `LootItems`) is refused with a warning rather
than silently pricing everything at 0. Supply levels are separate: an empty
supplies column means the instance's profile has no `Supplies.json` with
thresholds in it, not that the feature is missing.

**The hub dies after a while with "too many open files".** Fixed — but check you
are not running a build from before it was. `lib/socket.lua` used to skip the
real `close()` on any socket whose peer hung up first, which is every ordinary
keep-alive request, so the hub leaked one descriptor per request until it hit
`LimitNOFILE=8192`. The symptom to look for:

```sh
ss -tan | grep -c 'CLOSE-WAIT.*:8777'      # should be 0, or a small number
ls /proc/$(systemctl show luaclient-hub -p MainPID --value)/fd | wc -l
```

On a healthy hub the descriptor count is a handful and does not grow with
traffic. `luajit test/fdleaksuite.lua` from a source checkout is the regression
test.

**Your own API client gets `415 state-changing requests must be
application/json` on a `DELETE`.** By design, and it applies to `DELETE` too even
though the id is in the path. Every state-changing request must carry
`Content-Type: application/json`; send `{}` as the body. (The shipped panel used
to get this wrong and could not delete anything or sign out; `panel/api.js` now
sends `{}`.)

**Check the sandbox is really on:**

```sh
systemd-analyze security luaclient-hub
# → Overall exposure level for luaclient-hub.service: 1.3 OK 🙂
```

---

## 8. Removing it

```sh
sudo sh /opt/luaclient/deploy/uninstall.sh            # keeps the data
sudo sh /opt/luaclient/deploy/uninstall.sh --purge    # removes it too
```

The default stops and disables the service, removes the unit,
`/opt/luaclient` and the logrotate snippet, and **keeps** `/var/lib/luaclient`,
`/var/log/luaclient`, `/etc/luaclient` and the `luaclient` user, so a re-install
picks the fleet back up exactly where it was. `--purge` removes those too and
asks you to type `purge` first; `--yes` skips the prompt.

Neither mode touches `/var/backups/luaclient`. Those archives are `upgrade.sh`'s
backups and one of them is very likely the last copy of `secret.key` in
existence; deleting a fleet's last backup as part of an uninstall would be
indefensible. `uninstall.sh --purge` lists what it left and tells you the
`rm -rf` to run when you are certain.

---

## 9. Building a release tarball

```sh
sh deploy/package.sh                      # -> dist/luaclient-<version>.tar.gz
sh deploy/package.sh --version=2026.09.06 --out=/tmp/dist
```

It writes the tarball, a `sha256sum -c`-readable `.sha256`, and a manifest
listing every file with its size and digest (a copy travels inside as
`deploy/MANIFEST.sha256`). The build is reproducible: files are added in
`LC_ALL=C` order, owner and group forced to 0, modes normalised, and every mtime
clamped to `SOURCE_DATE_EPOCH` — the git commit date, or the newest mtime in the
tree when there is no git. Two builds of an unchanged tree are byte-identical.

---

## 10. What was actually run, and on what

Everything in this file was executed on **Debian 13 (trixie), amd64, LuaJIT
2.1.1737090214**, on a machine where **systemd 257 is genuinely running**
(`systemctl is-system-running` → `running`). So `systemd-analyze verify`, the
sandbox, `enable`, `start`, `restart`, `stop`, cgroup membership and journal
capture are all real, not parsed or simulated.

The sequence that was run, start to finish, from a clean machine:

1. `deploy/package.sh --version=1.0.0` → a 113-file tarball plus `VERSION` and
   `MANIFEST.sha256`, digest verified with `sha256sum -c`, and `0` entries
   matching `test/`, `docs/`, `panel/test`, `panel/mock` or `panel/devhub`.
2. `tar -xzf` and `sh deploy/install.sh` **from the tarball** into an empty
   prefix — no `/opt/luaclient`, no `/var/lib/luaclient`, no `luaclient` user
   beforehand. 115 files staged, unit installed, enabled, started, `/api/health`
   answering `{"bootstrap":true,…}`, bootstrap token in the journal.
3. The REST API driven with `curl`, using the exact header set `panel/rpc.js`
   emits: bootstrap an administrator → create a `role=user` account → create a
   game account (password and 2FA token sealed) → a character → an instance →
   `{start}` with a `--dry-run` worker → read live status and the log ring →
   read the audit log as the administrator → sign in as the plain user → all
   eight admin routes refused `403 forbidden` → cross-tenant ids refused `404
   not-found`, and both `exec` and `script.upload` refused for lack of
   `canExec` → the refusals read back out of the audit log → `{stop}`, worker
   gone.
4. The security properties checked on that install: `/var/lib/luaclient` is
   `0700 luaclient:luaclient` with every file `0600`; another user gets
   `Permission denied` listing it and the service user gets `Permission denied`
   writing `/opt/luaclient`; the game password, the 2FA token and both web
   passwords appear in **zero** files under `/var/lib`, `/var/log` and `/etc`,
   and in **zero** journal lines; the worker's `/proc/<pid>/cmdline` and
   `/proc/<pid>/environ` contain none of them; and the worker inherits exactly
   three descriptors from the hub — 0, 1 and 2, the stdio pipes — with nothing
   else shared, no listening socket and no `audit.jsonl`.
5. `systemctl stop` with a worker running: the hub logged
   `hub.shutdown graceMs=8000 reason="signal 15" workers=1`, then
   `hub.workers.stopped graceful=1 killed=0 stopped=1`, exit status 0.
6. All seventeen test suites: **8746 assertions on Debian, 0 failures** (8732 on
   Windows). Plus, against the *installed* tree: all 87 `.lua` files compile,
   `hub/main.lua` and `main.lua` answer `--help`, the panel's files are served
   with correct content types, and `devhub.lua`, `panel/test/` and `panel/mock/`
   answer `404` to everyone.
7. `deploy/upgrade.sh` exercised both ways — a failed migration probe rolled the
   tree *and* the data back and restarted the previous service, and a clean run
   backed up, migrated and restarted. `deploy/uninstall.sh` exercised both
   default (data kept, re-install picks the fleet back up) and `--purge --yes`
   (machine clean).

**Not verified, and worth knowing:**

* **No browser.** The panel was driven only through its HTTP API. Browser access
  to loopback was unavailable in the verification environment, so nothing has
  been clicked through since `panel/api.js` was fixed to send a body on
  `DELETE`. `panel/app.js` was not exercised at all.
* **Not bare metal.** Debian 13 under WSL2. systemd is real, but WSL's lifecycle
  is not a machine boot, so behaviour across an actual reboot is untested even
  though the unit is `enable`d.
* **No real game server.** Workers ran with `--dry-run`: they wire the bot, load
  the item table and serve their control endpoint, but open no game socket. The
  real login path is covered offline by `test/hube2esuite.lua` against
  `test/fakeserver.lua`.
* **certbot has never run.** The nginx vhost was proven with a self-signed
  certificate placed at the exact path certbot writes to, so the config certbot
  rewrites is the config that was tested — but the machine has no public name
  and no issuance was attempted.
* **`MemoryMax=1G` and `TasksMax=512` are chosen, not measured.** The hub idled
  at a few megabytes with one worker; nobody has run a large fleet against those
  ceilings.
* **No schema migration has ever run.** No collection declares a version above 1
  yet, so `upgrade.sh`'s dry run has been exercised end to end but the
  `migrate[v]` path itself has not.

---

## 11. What this deployment does *not* fix

Stated here rather than left to be discovered:

* **The workers are not isolated from the hub.** They run as the same OS user,
  in the same cgroup, under the same sandbox, with `/var/lib/luaclient`
  readable. So the `canExec` capability — remote Lua and script upload — is
  administrator-of-the-host equivalent: code in a worker can read `secret.key`
  and decrypt every stored game credential, including other accounts'. Grant it
  only to someone you would also give a shell here. A separate OS user per
  worker, a systemd user slice or a container is the fix, and it is not built.
* **`MemoryDenyWriteExecute=` cannot be enabled.** LuaJIT's tracing compiler
  writes machine code and then executes it. The unit says so in place, next to
  every other hardening option that is off on purpose.
* **TLS is nginx's job, not the hub's.** There is no plan for it to be
  otherwise.
