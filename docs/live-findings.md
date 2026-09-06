# Findings from the first live sessions (2026-09-06, GunzodusBR / Panjaweltrzeci)

Account supplied by the user for testing. **Ten live sessions in total** — four for the first
protocol pass, three for work item W (the walker), three for work item V (final verification);
nothing beyond logging in, standing still and walking tiles was ever performed. All four bugs
found live are now **closed**; what has never been exercised live is listed under
[What is still unproven](#what-is-still-unproven-after-ten-sessions).

## What is proven working against the real server

| | evidence |
|---|---|
| HTTPS login | `HTTP 200, 1188 bytes`, 1 character parsed, world `GunzodusBR` at `login-gunzbr.geo.gunzo.eu:7272` |
| TCP + world-name preamble | `connected …, world preamble sent` |
| challenge → login packet | `challenge: ts=… random=…`, `login packet sent (151 body bytes); XTEA enabled` |
| RSA block, gunz marker, `"261"`, content revision `42196` | the server accepted the login packet — every one of those fields was previously unverified |
| block-count framing, padding, sequence numbers, XTEA both ways | 80+ s of traffic parsed with zero desync |
| enter-game (both frames) | `login success (player id 268814903)`, `server accepted the login (pending)` |
| keepalive | `pong from server (latency 137-145 ms)` every 10 s, indefinitely |
| state parsing | hp 305/305, mana 155/155, level 20, position (32366,32242,6), skills, inventory, containers |
| map parsing | a full map description plus creature moves, parsed byte-exact |
| **outgoing gameplay packets** | the character actually walked: 32367 → 32365 → 32364 → 32366 → … |
| bot layer boots | all four modules wired from the user's real vBot profile, cavebot config loaded and advancing |
| **walking, paced correctly** | 195 s / **450 walk packets, 450 server moves, 0 wasted, 0 resyncs**, never more than one step in flight (work item V, run V-a) |
| **CaveBot running a route** | `v_loop.cfg` looped ~22 times in 195 s; waypoints advance, `gotolabel` jumps, 0 anti-lost, 0 blocked, 0 no-path |
| **long-distance pathing over the persisted minimap** | a 21-tile corridor walked end to end 10 times with waypoints far outside the aware area; the same route with `--minimap=off` stands still (V-b vs V-c) |
| **clean logout** | 0x14 `LeaveGame` on every shutdown path; every run since exits 0 and the next login is never answered with `session ended` |

Two real corpora are committed:

| file | records | bytes | opcodes | notes |
|---|---|---|---|---|
| `test/fixtures-first-session.cam` | 270 | 12,823 | 416 across 47 types | the first login |
| `test/fixtures-v-session.cam` | 992 | 87,892 | 1,645 | 195 s of walking: 438 map row slices, 517 creature moves |

`test/replay.lua` consumes every byte of both, and now replays both when given no arguments.

## Bug 1 — the challenge packet is 6 bytes (FIXED)

The C++ reference reads a 7th byte after `u32 timestamp` + `u8 random`, but that byte is the frame's
trailing padding, which it never trims. Our transport trims both ends, so the extra read ran off the
end and desynced on the very first packet. `proto/parser.lua` now consumes it only when a tail is
actually present, which is correct against either framing.

## Bug 2 — the walker paces steps wrongly, and the server disconnects (FIXED, work item W)

### What the instrumented run proved

`bot/walker.lua` now logs every outgoing walk and every observed position change at `debug`
level. Run 1 (2026-09-06, 45 s, `--cavebot=walktest --log-level=debug`) established the facts
before any fix was attempted:

```
[   839.3] DEBUG [walk] login serverBeat=50 speedA=1550.36 speedB=500 speedC=-9720.01
[   991.3] DEBUG [walk] SEND t=989  dir=1 from=32365,32242,6 pred=32366,32242,6 dur=200 gap=first
                  | speed=129(raw=0 src=creature) ground=100 beat=50 | outstanding=1
[  1210.4] DEBUG [walk] SEND t=1209 dir=3 from=32367,32242,6 pred=32366,32242,6 dur=200 gap=219.4
[  1419.4] DEBUG [walk] CB:doWalking t=1419 lookahead exhausted with 1 outstanding -> false
[  1419.9] DEBUG [walk] SEND t=1419 dir=3 from=32367,32242,6 pred=32366,32242,6 dur=200 gap=210.2
[  1531.1] DEBUG [walk] MOVE t=1529 32365,32242,6 -> 32364,32242,6 dir=3 sinceMove=409.8
[  1849.8] DEBUG [walk] SEND t=1849 dir=1 ... gap=219.7 | outstanding=2(expected=2 pending=0)
```

| fact | value |
|---|---|
| outgoing walk interval | **210–220 ms**, every step (`gap=` 210.2 219.4 210.6 219.7 220.1 …) |
| computed step duration | **200 ms** every time — `walker.STEP_FALLBACK_MS`, never the real one |
| why | `speed=129(raw=0 src=creature)`: **`state.player.speed` is 0 for the whole session** |
| server's real cadence | **~400 ms** per move (`sinceMove=` 399.7 400.3 389.8 409.8 400.7 …) |
| steps in flight | routinely **2** (`outstanding=2`), 98 occurrences in 45 s |
| packets vs moves | **206 walk packets → 112 moves**: 46 % of what we sent was thrown away |
| overshoot | route is 32365/32366/32367; the character cycled **32364 ↔ 32367** |

### Root cause, in two parts

**(a) The step duration collapsed to the 200 ms fallback.** Nothing ever writes
`state.player.speed`. The local player's speed arrives only on its **creature** record —
`proto/parser.lua:525` (creature block of a map description) and `:1665` (0x8F CreatureSpeed) —
and `state:addCreature` does not mirror it onto `state.player`. `walker:stepDuration` read
`state.player.speed`, found 0, and returned `STEP_FALLBACK_MS` for every step of every session.

The real number needs two things the walker did not have:

* the speed off the creature record (129), and
* `Creature::hasSpeedFormula()` — `GameNewSpeedLaw` is **on** here and the server sends
  `speedA=1550.36 speedB=500 speedC=-9720.01` in 0x17. `getStepDuration` then divides by
  `m_calculatedStepSpeed` (`creature.cpp:964-971`), **not** by the wire speed:
  `floor(1550.36 * ln(129 + 500) - 9720.01 + 0.5) = 271`.

  `ceil((1000 * 100 / 271) / 50) * 50 = 400 ms` — exactly the cadence the server was measured
  to grant. Dividing by the raw 129 would have given 800 ms, i.e. twice too slow.

**(b) An unconfirmed step was re-sent from the stale position.** `CB:doWalking()` returned
**false** as soon as the stored lookahead was exhausted, even with a step still in flight
(`bot/cavebot.lua`, the `dir == nil` branch). `CB:tick()` then fell through to
`resetWalking()` — which *discards the ledger* — and ran the `goto` action, which re-pathed
from a position the server had not moved yet and sent the **same direction again**. The log
line pair at `t=1419` above is exactly that. Two steps then land in the same server beat,
which is the "two tiles in the same millisecond" symptom and the waypoint overshoot.

### The fix (bot/walker.lua, bot/cavebot.lua, main.lua)

1. `walker:playerSpeed()` falls back to `state.creatures[state.player.id].speed`.
2. `walker:speedFormula()` / `walker:stepSpeed()` implement `hasSpeedFormula()` and
   `m_calculatedStepSpeed`. `main.lua` copies `speedA/B/C` from the 0x17 `login` event onto
   `state`.
3. `walker:paceDuration(dir)` = `stepDuration(dir) + 10 * max(1, outstanding)` — the
   `isCameraFollowing() && isLocalPlayer()` padding (`creature.cpp:1146-1150`) that a headless
   client is always entitled to. For one outstanding step it exactly cancels this fork's
   unconditional `-10 ms`, so the paced interval is the un-corrected duration.
4. **Strict pacing** (`cavebot.CONFIG_DEFAULTS.strictPacing = true`, on for every real route):
   at most **one** step outstanding; the next one waits for the server's position update **or**
   `walkDelay + paceDuration`, whichever is later. `CB:doWalking()` now *holds* while a step is
   unconfirmed instead of letting the tick re-path. The walker module's own default stays
   `false`, so `walker.CONFIG_DEFAULTS` still describes the vBot lookahead the spec documents.
5. `walker:pollConfirm()` resolves the outstanding step by **comparing `state.player.pos`
   against the tile we predicted**, not by matching the direction of the last `positionChange`.
   This is load-bearing: `positionChange` is not emitted for every server move (see Bug 4).
   A move to any other tile is a **resync**, not a confirmation.
6. Dropped-confirmation fallback: `min(max(stepDuration, ping) + 100, 1000)` ms
   (`localplayer.cpp:148-155`); on expiry the step is declared lost and the walker resyncs.
7. `walker:resyncToServer(why)` — walk-cancel (0xB5) and every void drop the in-flight ledger
   and the stored plan, so the next re-path starts from `state.player.pos`.
8. `main.lua` sends 0x14 `LeaveGame` before closing the socket, and gained
   `--exit-after=SECONDS` so a live test bounds itself instead of being killed. Without the
   logout the previous session lingers server-side and the *next* login is answered with
   `session ended (reason 0)` — which is how at least one earlier "disconnect" was manufactured
   (run 2 of this work item: one walk packet sent, kicked 370 ms later).

### After: run 3, 2026-09-06, 200 s, same route, same account

```
[   850.4] DEBUG [walk] SEND t=848 dir=3 from=32367,32242,6 pred=32366,32242,6 dur=400 gap=first
                  | speed=129(raw=0 src=creature) ground=100 beat=50 | outstanding=1
[  1268.x] DEBUG [walk] SEND ... dur=400 gap=419.97 | outstanding=1
[  1678.x] DEBUG [walk] SEND ... dur=400 gap=410.28 | outstanding=1
...
[199810.9] DEBUG [walk] MOVE t=199809 32365,32242,6 -> 32364,32242,6 dir=3 sinceMove=419.7
[200089.6] DEBUG [walk] SEND t=200089 dir=1 ... dur=400 gap=419.80 | outstanding=1
[200170.3] INFO  --exit-after elapsed -- disconnecting
```

| | before (run 1) | after (run 3) |
|---|---|---|
| walk packet interval | 210–220 ms | **410–420 ms** |
| computed step duration | 200 ms (fallback) | **400 ms** (speed 129 → 271 → 400) |
| max steps outstanding | 3 | **1** |
| walk packets / server moves | 206 / 112 (46 % wasted) | **480 / 480 (1:1)** |
| longest clean walk | 45 s (three earlier sessions died at 7–11 s) | **200 s, zero disconnects** |
| walk-cancels, lost steps | — | **0 / 0** |

Offline regressions: `test/botsuite.lua` section *work item W* (8 blocks, 56 assertions).
Simulating the pre-fix code (`strictPacing = false`, `playerSpeed` reading only
`state.player.speed`, no `pollConfirm`) fails 22 of them, including
*"never more than ONE walk packet in flight — got 3, want 1"* and
*"the tightest packet interval is 220 ms"* — the live numbers, reproduced on a fake clock.

## Bug 3 — long-distance waypoints cannot be pathed (CLOSED, work item M + verified live in V)

The `teeest` route's first waypoint is 26 tiles away and one floor down. The client only knows the
tiles the server has sent (the aware area, 18x14), so no path existed and CaveBot cycled through
waypoints without moving. The fix is option 1 of the two originally listed: `lib/minimap.lua` loads
the reference client's `profiles/minimap.otmm` read-only and `bot/world.lua` consults it for every
neighbour outside the aware range, exactly as `g_map.findEveryPath` does. `--minimap=PATH`
overrides the file, `--minimap=off` disables it.

```
minimap: ./../../otclient_mehah1530/otclient/profiles/minimap.otmm -- 11420 blocks loaded
         (46776320 tile slots) from 6984725 bytes in 2 ms
```

### Verified live, with the control run that proves it is the minimap doing the work

Route `scratch-profile/cavebot_configs/v_far.cfg` — two waypoints, each **outside the aware area**
from the other, on explored ground the server had not described in this session:

```
label:far
goto:32380,32243,6
goto:32359,32242,6
gotolabel:far
```

| run | flags | result |
|---|---|---|
| **V-b** (95 s) | minimap on (the default) | walked the **whole 21-tile corridor 32359 <-> 32380, five times in each direction**; 226 steps, 226 server moves, 0 no-path strikes, no disconnect |
| **V-c** (45 s) | `--minimap=off` | walked 4 tiles to 32359,32242 and then **stood still for the remaining 35 s**, cycling waypoints — bug 3 exactly as first reported |

That pair is the evidence: same account, same route, same binary, minutes apart; the only
difference is whether the pathfinder may see the persisted minimap.

Both extremes were actually reached (`MOVE -> 32380,32243,6` x5, `MOVE -> 32359,32242,6` x5), so
this is arrival on the waypoint tile, not an early "close enough".

## Bug 4 — the local player advanced TWO tiles per step (FIXED, work item V, proto/parser.lua)

Found while verifying bug 2 and proved from the wire in the run-3 capture. For one player step
the server sends **0x6D MoveCreature followed by the matching map-row slice in the same
message**:

```
6d 6e7e f27d 06 01  6d7e f27d 06  68 a411010500ffa3...
^^ MoveCreature      ^^ from 32366,32242,6 stack 1 -> to 32365,32242,6
                                                  ^^ 0x68 MapLeftRow, same message
```

`GameMapMovePosition` is **off** at 1530 — the row slice carries no position of its own, so
`P:movePos()` returns `P:centralPos()`. In the C++, `parseCreatureMove` moves the creature and
**never touches the camera**; the row slice is what calls `Map::setCentralPosition`, and it
therefore reads the *still-old* centre. Our parser advanced the centre in **both** handlers, so
every step did two wrong things:

* `P:setCentral` wrote `state.player.pos` a second time (`positionChange` fired from the row
  slice, carrying a position one tile past the truth), and — the half nobody had noticed —
* the row slice computed `movePos() - 1` from an **already advanced** centre, so
  `setMapDescription` stored the incoming column at `x - 1`: **every map row the server sent was
  written one tile off in the direction of travel**, and `setCentralPosition` then evicted the
  wrong column. The tile store the pathfinder reads was being corrupted on every single step.

### The fix

`proto/parser.lua` only. Three changes, all of them "do what the C++ does":

1. **`P:setCentral(p)` moves the camera and nothing else** — `self.central`, the aware-window
   eviction, and then `P:syncPlayerPos()`, which is `Map::setCentralPosition`'s deferred
   local-player fixup (`map.cpp`): adopt `creatures[playerId].pos` while we are on a tile, and
   snap to the new centre only when we are **not on the map at all**.
2. **0x6D is the only thing that walks the local player.** It writes `state.player.pos`, emits
   `positionChange` exactly once, and no longer calls `setCentral`. 0x64 FullMap (the login map
   and the answer to every teleport) and 0x4B stay position-authoritative through the new
   `P:setPlayerPos`.
3. **0x6C for *ourselves* no longer deletes our creature record.** `Map::removeThing` takes the
   LocalPlayer off its tile, but the object survives. TFS really does send us a 0x6C instead of a
   0x6D on the surface -> underground floor change (`protocolgame.cpp`,
   `oldPos.z == 7 && newPos.z >= 8`) and on a teleport; dropping the record there would lose the
   **creature speed the walker paces on** and silently reinstate bug 2's 200 ms fallback
   mid-hunt.

Offline regression: `test/botsuite.lua` section *WORK ITEM V: bug 4* — 25 assertions built on
real 0x6D / 0x66 / 0x68 / 0x6C byte sequences. Against the pre-fix parser 12 of them fail (and
the 0x6C block raises), including *"0x6D did NOT advance the camera"*, *"the empty column was
applied at x=91"* and *"six steps out and back land on the start tile — got 101,100,7"*.

### After: the difference on the wire

| | work item W (run 3, pre-fix) | work item V (run V-a, post-fix) |
|---|---|---|
| walk packets / server moves | 480 / 480 | **450 / 450** |
| moves whose observed tile matched the predicted tile | — | **450 / 450 (`match=true`)** |
| `RESYNC why=unexpected-move` | **479** | **0** |
| max steps in flight | 1 | 1 |
| walk-cancels, lost steps | 0 / 0 | 0 / 0 |

The 479 resyncs were the walker defending itself against bug 4. They are gone because the client
and the server now agree on where the character is, on every step.

## Work item V — final verification (2026-09-06, three sessions, 5 min 35 s in game)

### V-a — 195 s, bot on, short cavebot route inside the aware area

`scratch-profile/cavebot_configs/v_loop.cfg`: four waypoints round a corridor, `gotolabel` at the
end.

```
[     782.2] DEBUG [walk] login serverBeat=50 speedA=1550.36 speedB=500 speedC=-9720.01
[     939.2] DEBUG [walk] SEND t=937 dir=3 from=32365,32242,6 pred=32364,32242,6 dur=400 gap=first
                  | speed=129(raw=0 src=creature) ground=100 beat=50 | outstanding=1 readyIn=0 ping=100
[    1081.1] DEBUG [walk] MOVE t=1077 32365,32242,6 -> 32364,32242,6 dir=3 sinceSend=139.99 sinceMove=280.00
                  | outstanding=1(expected=3 pending=0) match=true
[    1349.0] DEBUG [walk] SEND t=1348 dir=3 from=32364,32242,6 pred=32363,32242,6 dur=400 gap=410.99 | outstanding=1
[    1494.4] DEBUG [walk] MOVE t=1487 32364,32242,6 -> 32363,32242,6 dir=3 sinceSend=139.00 sinceMove=410.00 | match=true
...
[  194943.1] DEBUG [walk] MOVE t=194937 32364,32243,6 -> 32365,32243,6 dir=1 sinceSend=139.33 sinceMove=410.08 | match=true
[  195219.4] INFO  --exit-after elapsed -- disconnecting
[  195225.5] INFO  [BOT] stopped
```

```
[   15798.1] INFO  bot: hp 305/305 mana 155/155 pos (32363,32243,6) | cavebot on v_loop wp 2/6 goto:32362,32242,6 | target none danger 0
[   30798.7] INFO  bot: ...                    pos (32363,32243,6) | cavebot on v_loop wp 4/6 goto:32370,32243,6 | target none danger 0
[  120800.7] INFO  bot: ...                    pos (32369,32243,6) | cavebot on v_loop wp 2/6 goto:32362,32242,6 | target none danger 0
[  180801.5] INFO  bot: ...                    pos (32366,32243,6) | cavebot on v_loop wp 4/6 goto:32370,32243,6 | target none danger 0
```

| | |
|---|---|
| duration | 195 s, **no disconnect** — the only "disconnecting" line is our own `--exit-after` |
| walk packets / server moves | **450 / 450**, every one `match=true` |
| steps in flight | never more than **1** (`outstanding=[2-9]` never appears in the log) |
| packet interval | 410-420 ms; step duration 400 ms (speed 129 -> `m_calculatedStepSpeed` 271 -> 400) |
| route looping | the two end waypoints were reached **22 and 23 times** — roughly 22 laps |
| tiles walked | 18 distinct tiles, x 32362..32370 on y 32242/32243, z 6 |
| anti-lost / blocked / no-path strikes | 0 |

One thing in that log is worth naming so nobody re-diagnoses it: the third waypoint
(`goto:32362,32243,6`) is reported arrived while the character stands on `32362,32242,6`. That is
not a walker defect — it is vBot's own asymmetric plain-goto arrival test
(`abs(dest.x - pp.x) == 0 and abs(dest.y - pp.y) <= 1`), reproduced deliberately and commented as
such in `bot/cavebot.lua`.

### V-b / V-c — the long-distance route, with and without the minimap

See bug 3 above.

### V-d — the capture, replayed

V-a ran with `--capture=test/fixtures-v-session.cam`. `test/replay.lua` consumes **every byte** of
it:

```
  PASS  test/fixtures-v-session.cam
        992 record(s): 992 inbound (87892 bytes, 1645 opcode(s)), 0 outbound
        opcodes: ... 0x65 MapTopRow x5, 0x66 MapRightRow x219, 0x67 MapBottomRow x6,
                 0x68 MapLeftRow x219, 0x6D MoveCreature x517, ...
replay: 1 file(s), 0 failure(s) -> PASS
```

It is the corpus the first capture did not have: 219 + 219 row slices and 517 creature moves —
the exact packets bug 4 lived in. `test/replay.lua` with no arguments now replays both committed
corpora alongside its synthetic one.

## What is still unproven after ten sessions

Everything below has **never been executed against the live server**. It is all covered offline by
`test/botsuite.lua`, which is not the same thing.

| | why it is unproven |
|---|---|
| **HealBot / AttackBot firing** | the test corridor has no monsters; no spell or rune has ever been cast live, and no live 0xA4/0xA5 cooldown has ever been observed |
| **TargetBot** | no creature has ever been attacked; `danger 0` on every status line of every session |
| **Looting** | no corpse has ever been opened live |
| **Supplies / refill / deposit** | no NPC trade, no bank and no depot live |
| **Floor changes** | every live session stayed on z=6. Stairs, ladders, ropes, holes and the 7 -> 8 `0x6C` path that fix item 3 above exists for are offline-only |
| **Anti-lost recovery** | never triggered live — nothing has gone wrong to trigger it |
| **A real hunting route** | the two routes used are hand-built one-floor corridors. None of the user's real routes (`dtseal_mk`, `feru_undead`, `true_asura`, ...) has been run live: they are all multi-floor |

So: the client **walks a real route on one floor, indefinitely, without desync or disconnect**.
It has not yet **hunted**.

## Operational notes

* `main.lua` now sends 0x14 `LeaveGame` on every shutdown path, so a run no longer leaves a
  ghost session behind server-side; `--exit-after=SECONDS` bounds a live test without killing
  the socket from outside. Do both before starting the next run.
* Only **one session per account** at a time: logging in again while a previous client is still
  connected produces `session ended by the server (reason 0)` for one of them. Two early disconnects
  were caused by my own overlapping runs, not by a client bug.
* The login POST is answered with `Content-Encoding: br`, which we cannot decode, so every login
  costs an extra round trip on the retry without `Accept-Encoding`. Sending no `br` in the first
  request would save ~300 ms.
* The routes used for live testing live in `scratch-profile/cavebot_configs/` (`v_loop.cfg`,
  `v_far.cfg`) and were laid out by reading the user's `minimap.otmm` offline with
  `lib/minimap.lua`, so no exploratory walking was needed to find walkable ground.
* `--minimap=off` is the switch that reproduces bug 3 on demand; keep it in mind before blaming
  the pathfinder for a route that will not start.
