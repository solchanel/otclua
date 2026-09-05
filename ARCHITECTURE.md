# Architecture: how the bot layer is being built

Direction set by the user: **port vBot itself, keeping the same functions, so existing vBot Lua
scripts stay compatible.** That is a stronger requirement than "reproduce vBot's behaviour", and it
changes the design.

## Two tracks, meeting in the middle

**Track A — the compatibility shim (primary).** Emulate, in pure Lua, the otclient API surface that
vBot runs on (`g_game`, `g_map`, `g_things`, the Creature/Tile/Item/Container object model, a
stateful-but-invisible widget model for `g_ui`/`UI.*`, `g_settings`, `g_resources`, `g_clock`,
`scheduleEvent`, `connect`/`signalcall`, the corelib string/table extensions, and the `modules.*`
functions vBot reaches into). Then load the user's real vBot tree — `_Loader.lua`, `vBot/*`,
`cavebot/*`, `targetbot/*` — unchanged, and drive its 10 ms tick from our scheduler.

Payoff: every customisation in the user's AttackBot, every cavebot route, every personal script
keeps working, and future vBot edits port over for free.

Cost: vBot reads its settings back out of widgets, so the widget model has to be genuinely
stateful, and every `modules.game_*` call site needs an answer. `docs/shim/` is the inventory of
exactly how big that surface is, measured rather than guessed, plus `tools/shim_probe.lua`, which
empirically finds what breaks first when the real files are loaded under LuaJIT.

**Track B — native modules (fallback, and the primitives Track A needs anyway).** `bot/path.lua`,
`bot/walker.lua`, `bot/world.lua`, `bot/init.lua`, `bot/api.lua`, `bot/config.lua` plus native
`healbot/attackbot/cavebot/targetbot`. The primitives are not optional: the shim's `g_map.findPath`,
its walking and its spectator queries are implemented by exactly these. The native modules are the
fallback if a part of vBot cannot run headless, and they give us offline tests for behaviour the
shim would otherwise only exercise through vBot's own code.

## Where they meet

```
vBot sources (unchanged)          bot/healbot.lua … (native fallback)
        |                                    |
   shim/ (otclient API emulation) -----------+
        |
   bot/path.lua  bot/walker.lua  bot/world.lua     (shared primitives)
        |
   game/state.lua  proto/sender.lua  proto/items.lua  lib/sched.lua
        |
   proto/transport.lua  (1530 protocol)  ->  the server
```

## Config compatibility is a hard constraint either way

The user keeps using the GUI client on the same files. Anything we write back —
`cavebot_configs/*.cfg`, `vBot_configs/profile_N/*.json`, `targetbot_configs/*.json`, `storage/*` —
must still load in the real vBot. `tools/vbot_compat_check.lua` proves that by round-tripping every
one of the user's real files through vBot's own parser, and `docs/vbot/config-compat-*.md` documents
the rules a foreign writer must follow (the multi-line `function:[[ ]]` bodies, the `config:` JSON
line, rxi-json's empty-table and number formatting quirks).

## Status

* Protocol client: done, 401 selftests green on Windows and Debian.
* Track B: in progress.
* Track A: inventory and feasibility probe in progress; the plan lands in `docs/shim/PLAN.md`.
* Not started: the web panel (step 3), and HTTP `CONNECT` proxy support, which the user's real
  client uses and which may be required for a live login (`docs/live-login-notes.md`).
