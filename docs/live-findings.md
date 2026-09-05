# Findings from the first live sessions (2026-09-06, GunzodusBR / Panjaweltrzeci)

Account supplied by the user for testing. Four live sessions were run; nothing beyond logging in,
standing still and walking a few tiles was performed.

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

`test/fixtures-first-session.cam` is the first real corpus: 270 records, 12,823 bytes, 416 opcodes
across 47 distinct types. `test/replay.lua` consumes every byte of it.

## Bug 1 — the challenge packet is 6 bytes (FIXED)

The C++ reference reads a 7th byte after `u32 timestamp` + `u8 random`, but that byte is the frame's
trailing padding, which it never trims. Our transport trims both ends, so the extra read ran off the
end and desynced on the very first packet. `proto/parser.lua` now consumes it only when a tail is
actually present, which is correct against either framing.

## Bug 2 — the walker paces steps wrongly, and the server disconnects (OPEN)

Symptoms, reproduced in three of four sessions:

* Position advances **two tiles in the same millisecond**: `32365,32242` then `32364,32242` at
  +0.2 ms, repeatedly. Two walk steps are in flight at once.
* The walker overshoots its target and oscillates around it instead of stopping.
* **`session ended by the server (reason 0)` after 7–11 s of walking.** With the bot disabled, or
  with the bot enabled but no cavebot route, the same client stays connected indefinitely
  (verified 90 s). The disconnect only ever happens while walking.

Diagnosis: the walker sends the next step without waiting for the current one to complete, so it
exceeds the server's movement rate and is kicked as a flood. The client must pace steps by the real
step duration and must not have more than one step outstanding.

What the fix needs (all documented in `docs/vbot/pathfinding.md` and `docs/state-events.md`):

1. Compute the step duration from the player's speed and the **destination tile's ground speed**,
   the way `Creature::getStepDuration` does — including this fork's unconditional `-10 ms` and the
   camera-following `+10 ms` padding, which for a headless client must be applied for the local
   player (`docs/vbot/pathfinding.md`).
2. Send one step, then wait for the server's position update (or the duration, whichever is later)
   before sending the next. Track an outstanding-step flag; never re-send while it is set.
3. Handle the walk-cancel packet by clearing the outstanding step and resyncing to the server's
   position rather than continuing from the predicted one.
4. Stop when the target tile is reached; do not step past it. The oscillation suggests arrival is
   being judged against a stale position.

Until this is fixed, **do not run the bot with a cavebot route on a real account** — it will be
disconnected repeatedly.

## Bug 3 — long-distance waypoints cannot be pathed (OPEN, by design for now)

The `teeest` route's first waypoint is 26 tiles away and one floor down. The client only knows the
tiles the server has sent (the aware area), so no path exists and CaveBot cycles through waypoints
without moving. The real vBot solves this with the client's **minimap knowledge** (`minimap.otmm`,
walkability and stair colours for everything explored).

Options, in order of preference:
1. Load the user's `profiles/minimap.otmm` (format already documented in earlier work) and use it as
   the pathfinding fallback for tiles outside the aware area, exactly as `g_map.findEveryPath` does.
2. Restrict routes to consecutive waypoints inside the aware area (how cavebot routes are normally
   recorded — roughly 5 tiles apart), which works today once bug 2 is fixed.

## Operational notes

* Only **one session per account** at a time: logging in again while a previous client is still
  connected produces `session ended by the server (reason 0)` for one of them. Two early disconnects
  were caused by my own overlapping runs, not by a client bug.
* The login POST is answered with `Content-Encoding: br`, which we cannot decode, so every login
  costs an extra round trip on the retry without `Accept-Encoding`. Sending no `br` in the first
  request would save ~300 ms.
