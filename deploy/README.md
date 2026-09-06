# deploy/

Everything needed to put this system on a Debian server and take it off again.
`INSTALL.md` at the project root is the operator's guide; this file documents the
scripts themselves — what each one owns, what it will and will not touch, and the
decisions behind the layout.

| file | what it is |
|---|---|
| `install.sh` | the one command. Idempotent, POSIX sh, `set -eu`. |
| `uninstall.sh` | removes it; `--purge` also removes the data, the config and the user. |
| `upgrade.sh` | stop → back up → swap → migrate → start, with a rollback on any failure. |
| `package.sh` | a versioned, reproducible tarball with a manifest and a sha256. |
| `filelist.sh` | the single definition of "what belongs in a runtime install". |
| `luaclient-hub.service` | the systemd unit and its sandbox. |
| `luaclient-hub.conf.example` | the seed for `/etc/luaclient/hub.conf`. |
| `nginx-luaclient.conf` | TLS termination, WebSocket upgrade, headers, rate limits. |

---

## The layout, and why it is split that way

```
/opt/luaclient          the application   root:root  0755/0644   READ-ONLY to the service
/var/lib/luaclient      state             luaclient  0700
/var/lib/luaclient/workers  worker cwd    luaclient  0700
/var/log/luaclient      logs              luaclient:adm 0750
/etc/luaclient/hub.conf configuration     root:luaclient 0640
```

`ProtectSystem=strict` makes the whole filesystem read-only except what
`ReadWritePaths=` names. That is the constraint the rest of the layout follows
from, and it has one consequence that is easy to get wrong:

**`--worker-script` is an absolute path into `/opt`, while `--workers-dir` is
under `/var/lib`.** A worker's `SCRIPT_DIR` — how it finds `assets/items1530.bin`
and its own modules — comes from the *script path*, so it resolves into the
read-only tree, which is right. Its *working directory* is what a relative
`--bot-profile` resolves against and where the bot writes its profile, so it must
be writable. Put both in `/opt` and the first instance you start dies trying to
create `profile_1` in a read-only tree; put both in `/var/lib` and the worker
cannot find its own code.

`/etc/luaclient/hub.conf` is an `EnvironmentFile`, not a shell script and not a
config format the hub itself parses — `hub/main.lua` takes flags only. So the
unit turns `HUB_BIND`, `HUB_PORT`, `HUB_LOG_LEVEL`, `HUB_BOT_PROFILE` and a
free-form `HUB_EXTRA_ARGS` into a command line. `$HUB_EXTRA_ARGS` is unbraced on
purpose: systemd word-splits `$VAR` and does not split `${VAR}`.

---

## install.sh

```
sudo sh deploy/install.sh [--port=N] [--bind=ADDR] [--source=DIR]
                          [--skip-apt] [--no-start] [--no-enable] [--force]
```

Nine steps, each announced: preflight, dependencies, service user, application
tree, directories, configuration, systemd unit, first run, next steps.

**Idempotence** is per-object, not "delete and redo":

* the application tree is staged in a temporary directory in `/opt` and swapped
  in with `mv`, so a failed install never leaves a half-written `/opt/luaclient`;
* the user, the group and every directory are created only if absent;
* `/etc/luaclient/hub.conf` and `/etc/logrotate.d/luaclient` are written **only
  when they do not exist**. Your edits survive;
* `/var/lib/luaclient` is never touched beyond `mkdir`, `chown` and `chmod`.

**The dependency check is a real check.** `luajit -v` must say 2.1, and a probe
program must be able to `ffi.cdef` a struct, allocate it, read a field back,
`ffi.cast` a string and see `ffi.C`. Debian's package has always been built with
the FFI, but a distribution *can* ship `LUAJIT_DISABLE_FFI`, and this program is
FFI from the sockets up. Guessing would produce a confusing runtime failure much
later; the check fails immediately and says what to install.

**What it will not do:** touch `/var/lib/luaclient`, overwrite a config file, put
anything secret on a command line, or open a port to the network.

---

## The unit and its sandbox

`systemd-analyze security luaclient-hub` scores it **1.4 OK** as shipped.

On: `NoNewPrivileges`, `PrivateTmp`, `PrivateDevices`, `ProtectSystem=strict`,
`ProtectHome`, `ProtectProc=invisible` + `ProcSubset=pid`, `ProtectKernelTunables
/Modules/Logs`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname`,
`RestrictNamespaces`, `RestrictRealtime`, `RestrictSUIDSGID`, `LockPersonality`,
`SystemCallArchitectures=native`, `SystemCallFilter=@system-service` minus
`@privileged @resources @obsolete`, an empty `CapabilityBoundingSet`,
`RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`, `UMask=0077`,
`MemoryMax=1G`, `TasksMax=512`, `Restart=on-failure`.

All of that is compatible with spawning workers — verified by starting one under
it, not by reading the manual. What is **off, and why**, is written into the unit
file itself next to each option; the short version:

* **`MemoryDenyWriteExecute=` is fatal.** LuaJIT's tracing compiler writes
  machine code into a page and then executes it. W^X enforcement kills the hub
  during startup and every worker with it. There is no LuaJIT build flag that
  keeps the compiler and satisfies this.
* **`PrivateUsers=` breaks it two ways.** The service's uid stops mapping to the
  host uid that owns the 0700 data directory, so `/var/lib/luaclient` becomes
  unreadable; and the supervisor spawns and reaps workers by pid.
* **`DynamicUser=` cannot work** with a persistent data directory whose files
  must stay owned by a stable uid — a fresh uid every start would orphan the
  whole thing, `secret.key` included.
* **`PrivateNetwork=` is obviously out**: the hub is a web server and workers
  dial a game server, usually through an HTTP CONNECT proxy.
* **`RestrictAddressFamilies=` must keep `AF_UNIX`**, or journald's stdout socket
  is unreachable and the service logs nothing — including the bootstrap token.

`KillMode=mixed` with `TimeoutStopSec=90` is also a deliberate choice rather than
a default. `SIGTERM` goes to the hub alone, because the hub answers it by asking
each worker to **log out** over the control socket and waiting. A worker that is
merely killed leaves the character online for the game server's own logout
timeout, and the next login on that account is refused with `session ended` — so
killing a worker costs the operator the next login too. systemd's `SIGKILL` of
the remaining cgroup after the timeout is the backstop for a wedged hub, not the
normal path.

**The sandbox is not an isolation boundary between the hub and its workers.**
Same user, same cgroup, same sandbox, `/var/lib/luaclient` readable. `canExec` is
therefore administrator-of-the-host equivalent, exactly as `PANEL.md` says. This
unit does not change that and does not pretend to.

---

## nginx

Read the comment block at the top of `nginx-luaclient.conf` before changing the
two `proxy_set_header` lines. Short version: the hub **pins the `Host` header**
(a loopback bind answers only to `127.0.0.1`, `localhost`, `[::1]`, and
`--allowed-host` does not extend that list for a loopback bind) and requires
`Origin`, when present, to be same-origin with `Host` **including the port**. A
browser on `https://panel.example.com` therefore cannot have either header passed
through unchanged, and the proxy rewrites both to the hub's own origin.

What that costs, said plainly: the hub's `Origin` check becomes a comparison of
two values nginx wrote, and stops being one of four *independent* CSRF checks.
The other three still work — `SameSite=Strict` means a cross-site request carries
no session at all, `Sec-Fetch-Site` arrives from the browser untouched, and
`X-CSRF-Token` can only be produced by having read a same-origin response. Set
`--csrf-strict` so that last one is mandatory. DNS rebinding is answered by nginx
serving this vhost only for its `server_name`, with a `default_server` returning
`444` for every other name.

---

## upgrade.sh

```
sudo sh deploy/upgrade.sh (--source=DIR | --tarball=FILE) [--keep=N] [--no-rollback]
```

The rollback is the point. It captures three things before it changes anything —
the previous `/opt/luaclient` (parked, not deleted), a `tar.gz` of
`/var/lib/luaclient`, and a copy of `hub.conf`, all under
`/var/backups/luaclient/` at 0600 — and any failure after the swap restores all
three and restarts the service that was running before.

The **migration dry run** is the interesting step. There is no migration script
to write: `hub/storage.lua` applies a collection's schema migrations when the
file is *loaded* and marks the result dirty so it persists at the next save. So
`upgrade.sh` opens the data directory with the new code, as the service user,
with nothing else running, and reads every collection. A corrupt or unreadable
file is a hard error at `storage.open()` — found here, before the service comes
back, while the backup is still fresh, instead of at 03:00 inside systemd's
restart loop.

A tarball with a `.sha256` beside it is verified and refused on mismatch.
`secret.key` is never touched.

---

## package.sh

```
sh deploy/package.sh [--version=V] [--out=DIR]
```

Produces `luaclient-<version>.tar.gz`, a `sha256sum -c`-readable `.sha256`, and a
manifest of every file with its size and digest (a copy travels inside the
tarball as `deploy/MANIFEST.sha256`). One top-level directory; exactly what
`filelist.sh` names.

Reproducible, and tested to be: entries added in `LC_ALL=C` sorted order, owner
and group forced to `0/0` with `--numeric-owner`, modes normalised to 644/755,
`gzip -9n` (no name, no timestamp), and every mtime clamped to
`SOURCE_DATE_EPOCH` — the git commit date when there is a git, otherwise the
newest mtime among the packaged files, which is still a function of the source
rather than of the clock. Two builds of an unchanged tree produce identical
bytes:

```
502ceaa028b6efecc64a888b0fe68a9979a3a5f81cc9a095ff11e28ef76e2797  dist/luaclient-2026.09.06.tar.gz
502ceaa028b6efecc64a888b0fe68a9979a3a5f81cc9a095ff11e28ef76e2797  dist2/luaclient-2026.09.06.tar.gz
```

---

## filelist.sh

One function, `lc_runtime_files ROOT`, used by both `install.sh` and
`package.sh`, so a file can never be in the tarball but missing from an install
or the other way round.

In: `assets bot control data deploy game hub lib panel proto shim` in full, plus
`main.lua`, `run-hub.sh`, `run.sh`, the root `*.md` operator docs and
`tools/extract_appearances.py`.

Out: `test/` (twelve suites — development only), `docs/` including `docs/vbot`
and `docs/shim`, `panel/test`, `panel/mock` and `panel/devhub.lua` (the panel's
own harness, which `hub/server.lua` answers `404` for in any case), scratch and
captured profiles, `__pycache__`, every `*.log`, dotfiles and `.git`.

`tools/extract_appearances.py` is the one tool that ships, because `INSTALL.md`
tells the operator to regenerate `assets/items1530.bin` with it when the game
server publishes a new asset set.
