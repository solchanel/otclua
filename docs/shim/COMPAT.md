# Running otclient / vBot scripts under `luaclient`

**Status: the user's real vBot 4.8 profile boots, ticks and BEHAVES under the
standalone LuaJIT client, unmodified.** 74/74 profile files, 27/27
`mods/game_bot` runtime files, 47–48 macros, on Windows and on Debian, with no
game client, no OpenGL and no game server — and, since the behaviour pass, with
the exact packets HealBot / AttackBot / CaveBot / TargetBot / the looter / Dropper
put on the wire asserted byte for byte (§3.2), cross-checked against the native engines,
and the whole tree run twice against the **live** server (§3.3).

    luajit main.lua --vbot ...                 # instead of --bot
    luajit test/shim_compat_suite.lua          # proves nothing CRASHES
    luajit test/shim_behaviour_suite.lua       # proves the bot does the RIGHT THING
    luajit test/fakeserver.lua --vbot          # the same thing end-to-end over TCP

This document says what works, what does not, which APIs are stubs, and how to
port an otclient script. It is deliberately blunt about the gaps: a function that
silently returns a wrong value is worse than one that is absent and errors loudly,
and everything listed under *Stubs* below is loud. **§3.5 is the list of what is
still unproven — read it before trusting any of the rest.**

---

## 1. What this is

`shim/` synthesises the otclient Lua API — `g_game`, `g_map`, `g_things`,
`g_ui`, `g_resources`, `g_settings`, `g_clock`, the `Creature`/`Tile`/`Item`/
`Container` object model, the corelib `string`/`table` extensions, and the
`modules.*` graph — on top of what `luaclient` already has: `game/state.lua`,
`proto/parser.lua`, `proto/sender.lua`, `proto/items.lua`, `lib/sched.lua`.

Nothing of vBot is reimplemented. `mods/game_bot/executor.lua`, its 19
`functions/` and 7 `panels/` files, and all 74 files of the user's profile are
loaded **verbatim from the user's own otclient checkout**, which is treated as
strictly read-only (invariant I9). The shim is only the layer underneath them.

    main.lua --vbot
      -> shim/bootstrap.lua        10 boot steps, in order
         1  SHIM_G                 a copied Lua base; never a metatable to _G
         2  shim/corelib.lua       string/table extensions, connect/signalcall/schedule
         4  shim/platform.lua      g_clock g_logger g_app g_window tr print
            shim/resources.lua     g_resources rooted at <otclient>/profiles
            shim/settings.lua      g_settings
         7  shim/object.lua        the interned object registry
            shim/g_game.lua  g_map.lua  g_things.lua  g_minimap.lua
         8  otclient's own corelib/ + gamelib/ + spelllist, loaded VERBATIM
         9  shim/g_ui.lua          -> shim/ui/{g_ui,widget}.lua: OTML parser,
                                      style registry, real widget tree
        10  shim/modules.lua       the modules.* graph
        11  shim/host.lua          dofile executor.lua -> executeBot() -> _Loader.lua
        12  shim/callbacks.lua     LC.events -> the sandbox callbacks
        13  the 10 ms executor tick

---

## 2. Command line

| flag | meaning |
|---|---|
| `--vbot` | run the real vBot tree through the shim. **Mutually exclusive with `--bot` / `--cavebot` / `--targetbot`** — both engines walk and both attack, so exactly one may be on (invariant I10). Trying both is a usage error, exit 1. |
| `--vbot-profile=DIR` | the `/bot/<config>` directory, e.g. `.../otclient/profiles/bot/vBot_4.8`. Implies `--vbot`. The config name, the `g_resources` write dir and the otclient checkout are all derived from it: `DIR` must sit under a `bot/` directory. |
| `--vbot-otroot=DIR` | override the otclient checkout the shim reads `mods/game_bot` and `modules/` from |
| `--vbot-vprofile=N` | `storage/profile_<N>.json` (default 1) |
| `--vbot-tick=MS` | executor tick, 1–1000 ms (default 10) |
| `--vbot-strict` | a missing API raises instead of returning an inert stub |
| `--vbot-safe` | **live smoke-test mode.** Boots and ticks the whole tree normally, then turns AttackBot, TargetBot and CaveBot **off** the moment it is up, so the session never attacks and never auto-walks a hunting route. HealBot is left on deliberately: it starts no fight and it is the one thing that keeps the character alive if something else does. Persists nothing. |
| `--vbot-write` | allow the bot to save its storage and configs. **Off by default** — see §7. `--dry-run` always forces read-only. |

The native bot layer (`--bot`) is untouched and remains the default; every one of
its 2137 tests still passes.

---

## 3. What works

### 3.1 Verified by running real code — the crash test

| what | result |
|---|---|
| the user's 74 profile files | 74 loaded, 0 failed |
| `mods/game_bot` runtime (`executor.lua` + 19 `functions/` + 7 `panels/`) | 27 loaded, 0 failed |
| macros registered | 48 (47 with the compat suite's fixture) |
| **every macro body, run in isolation** | **47/47 ran, 0 raised** |
| 10 executor ticks over all macros | 0 raised, 548 macro bodies |
| hand-written otclient/vBot snippets | 31/31 compiled and ran |
| the user's real `cavebot_configs/*.cfg` | 18/18 parse and round-trip |
| the user's real `targetbot_configs/*.json` | 11/11 parse and round-trip |
| end-to-end over a real socket (`test/fakeserver.lua --vbot`) | login → shim boot → 240 ticks, 0 raised |
| load time | 100–150 ms Windows, ~950 ms Debian |
| slowest tick | 2 ms (budget 10) |

**Read that table for what it is: it proves nothing crashes.** A HealBot that
never heals scores exactly the same as one that heals correctly — "loaded, ran,
0 errors" in both cases. §3.2 is the part that says the bot does the RIGHT thing.

### 3.2 Verified by BEHAVIOUR — `test/shim_behaviour_suite.lua`

    luajit test/shim_behaviour_suite.lua        -- 131 checks, 0 failed
                                                -- Windows LuaJIT and Debian/WSL LuaJIT

For each subsystem the suite builds a world in which the correct action is
unambiguous, ticks the **real vBot macro body** through the shim, and asserts
**the exact packet that reached `proto/sender.lua`** — the transport is captured,
so every assertion is on wire bytes (opcode, spell words, aim byte, item id,
creature id, container slot address), never on a Lua return value the shim could
have invented. Configuration comes from the user's own read-only profile
(`HealBot.json`, `AttackBot.json`); where it has to be synthetic (a CaveBot route,
TargetBot creature entries) it is built through vBot's **own** public API —
`CaveBot.addAction`, `TargetBot.Creature.addConfig`, `TargetBot.Looting.update` —
so the data structures under test are the ones vBot builds for itself.

Twenty-three of the scenarios are additionally run through the **native** bot
layer (`bot/healbot.lua`, `bot/attackbot.lua`, `bot/targetbot.lua`,
`bot/cavebot.lua`) over an identically furnished world and the packets compared
byte for byte. Two independent implementations of the same spec agreeing on the
wire is much stronger evidence than either agreeing with a hand-written guess.
**All 23 agree.**

| area | what is proved |
|---|---|
| **HealBot spells** | The user's real rules — `exura gran tio` at HP% ≤ 75 (210 mana), `exura gran` at HP% ≤ 95 (75 mana) — fire at the right threshold and *only* there: silence at 96%, `exura gran` from 95% down to 76%, `exura gran tio` from 75% down. Both boundaries are asserted, because vBot's `"<"` is really `<=`. The mana gate is asserted as the strict `cost < mana()` it is: at 208 mana the 210-cost heal is skipped and the cheap one fires (the bot degrades, it does not stall); at 72 mana nothing fires. A **real** 0xA4 + 0xA5 cooldown pair (2000 ms) holds every heal, is still holding at 1100 ms, and the cast resumes the tick the cooldown expires. |
| **HealBot items** | `ultimate spirit potion` (23374) goes out as **0x84 useOnCreature on the player** at HP% ≤ 75 and at MP% ≤ 75, and not at 76% of either. The disabled `HP% < 40` rule stays disabled. The shared 1 s use-cooldown that HealBot and AttackBot both consume is asserted: a second attempt 500 ms later is silent, one 1100 ms later drinks again. |
| **AttackBot** | Against the user's real 8-rule monk table: one monster in the pattern fires `exori mas pug` (Flurry of Blows, rule 7, count 1); two monsters fire `exori med pug` (Chained Penance, rule 3, count 2 — the earlier rule wins, which is what array order means here); a target 6 sqm away with nothing in the pattern **holds**, sending nothing at all. Auto-Turn is asserted on the wire: with the monster north and the player facing south the bot sends `0x6F turnN` and *then* the spell, in that order, in one tick. A real group-1 cooldown (2000 ms) holds the whole table and it resumes the moment the group clears. The scenario is forced on through **`AttackBot.setOn()`** (the same public toggle a click on the panel switch calls) rather than asserted off the profile's raw `enabled` flag — that flag mirrors the user's *live* in-game toggle, which has since flipped to off outside this suite's control, and this scenario proves the firing logic, not the toggle. |
| **Dropper** | `storage.dropper`'s cap/use/trash three-bucket scan (`vBot/Dropper.lua:127`), previously only crash-tested: a lone trash-listed item is dropped to the player's own tile (`0x78 move`); with a use-listed item *and* a trash-listed item both in the backpack the use-item wins (`0x82 use`), because the cap→use→trash scan checks bucket 2 before bucket 3; and a real starvation bug is caught and pinned down — a cap-listed item present while capacity is **fine** still consumes the macro's one `return` for that tick (the bucket's own `freecap() < 150` guard evaluates false, but the *match* already committed the return), so neither the use-item nor the trash-item one slot over gets touched that tick even though both are sitting right there. Lower capacity below the threshold on the next tick and the cap item drops as expected. |
| **CaveBot** | A four-waypoint route (`label` / `goto` / `goto` / `gotolabel`) built through `CaveBot.addAction`: the bot walks 4 × `0x66 walkE` to the first waypoint, the program counter (`getFocusedChild`) advances on arrival, it walks south to the second, a plain `goto` with no precision marker **arrives within 1 tile** (it stops at y+3 for a y+4 waypoint — the real tolerance), the `gotolabel` jumps the counter back behind the label, and the route loops (it walks north again). The native engine walks the same route with the same step counts. |
| **TargetBot** | With two monsters at **equal** distance — so vBot's +10 "path length 1" bonus cancels — the higher-priority config wins and `0xA1 attack` carries that creature's id. (At unequal distance the distance bonus can outrank the config priority; that is vBot's documented arithmetic, not a bug, which is why the test equalises distance.) With `keepDistance = 3` and the monster adjacent, the bot attacks and then steps **away** twice, and stops exactly 3 sqm out. |
| **Looting** | A monster dies next to the player: `onCreatureDisappear` queues the corpse (with the creature's name), the next tick sends `0x82 use` **on the corpse tile**, and once the server answers with the opened container the listed gold coin leaves it as `0x78 move` addressed `0xFFFF,0x40+1,slot → 0xFFFF,0x40+0,slot`. An **unlisted** mana potion in the same corpse is left where it is. |
| **otclient idioms** | 15 hand-written scripts, each compiled with `load(src, name, nil, context)` — byte for byte how `executor.lua:115` compiles the user's own files — and each asserting a behaviour rather than the absence of an error: `getLocalPlayer():getHealthPercent()`, `g_map.getSpectators` (membership *and* interning), `getSpectatorsInRange` (a creature 2 tiles out is excluded from a 1×1 query and included in a 3×3), `findPath` (3 north steps on clear ground, a **longer** path east because a creature blocks it, the straight line back with `ignoreCreatures`, `nil` across floors), `g_game.attack`, `useInventoryItemWith`, containers (`getItems` / `getSlotPosition` / `move` into a slot), `g_things.getThingType`, `connect(g_game, {onTextMessage=...})`, the sandbox `onTalk`/`onTextMessage` with translated modes, `Tile` accessors, and `g_game.walk` (packet + prewalk + untouched server position + `resetPreWalk`). |

### 3.3 Verified against the LIVE server

Two sequential sessions on the user's test account (`--vbot --vbot-safe`,
walking only, no combat, one at a time, ~90 s and ~100 s), logged verbatim to
`live-P-vbot-behaviour.log` and `live-P2-vbot-behaviour.log`:

* HTTPS login → character list → game socket → XTEA → enter game → the whole
  vBot tree booted **against the live world**: 74 profile files, 27 runtime
  files, 47 macros (41 enabled), 82 callbacks, real OTML UI backend;
* the second session ran **9500 executor ticks, 0 raised, slowest tick 1 ms**,
  with **38 of 47 macros actually executing** at least once;
* nothing was attacked, nothing walked, hp/mana never moved (305/305, 155/155),
  and the profile was never written (read-only is the default).

The first session found two live-only defects, both since fixed and both now
regression-tested (§3.4); the second session is clean end to end.

### 3.4 What the behaviour suite and the live run found and fixed

Every one of these passed the crash test and was still wrong.

| # | defect | consequence | fix |
|---|---|---|---|
| 1 | `Item`/`Thing` had no `setMarked` | `targetbot/looting.lua:339` `container:setMarked('#000088')` raised inside the scheduled callback that had *just* queued the corpse — every single corpse | `Thing:setMarked` / `getMarked` (`shim/object.lua`), stateful, matching `luafunctions.cpp:528` |
| 2 | `Creature` had no `getText` / `clearText`; `setText` was inert | `vBot/extras.lua:551`'s Check-Players pass (`spec:getText() == ""`) raised on every scheduled run | stateful `setText`/`getText`/`clearText` on `Creature` (`luafunctions.cpp:708-710`) |
| 3 | `Tile` had no `getText`; `setText` was inert | `vBot/extras.lua:537` (clear the "HOLD" markers) raised | stateful `Tile:setText`/`getText` (`luafunctions.cpp:1088-1089`) |
| 4 | `FindFirstFileA` was cdef'd twice with two different struct typedefs | **the shim could not boot at all** in a process that had already loaded `bot/config.lua` — i.e. exactly the worker + native-bot process. `pcall(ffi.cdef)` means the first declaration wins and the second module's struct pointer is then the wrong type | both call sites pass the FIND_DATA as `void*`, which converts to any pointer type (`shim/resources.lua`, `bot/config.lua`) |
| 5 | `connect(g_game, { onTextMessage = f })` never fired | a textbook otclient idiom was silently dead: the bridge fed only the executor's dispatcher, but the C++ emits these with `callGlobalField("g_game", …)` (`game.cpp:273,278`) | the chat / channel / cooldown family is now dispatched **twice**, exactly as in the real client — into the executor dispatcher *and* onto the `g_game` slot (§5) |
| 6 | with (5) in place, `gamelib/textmessages.lua` perror'd "Unhandled onTextMessage message mode N" for **every** server message | error spam per message on a live session | `shim/modules.lua` reproduces `game_textmessage.init()`'s `registerMessageMode` loop; an unregistered mode still reports itself, and that is asserted so the check is not vacuous |
| 7 | `onCreaturePositionChange` / `onWalk` passed **nil** for `oldPos` | `Thing::setPosition` (`thing.cpp:44-52`) passes a Position *by value*, so the client never passes nil. `vBot/extras.lua:565` does `if x.z ~= y.z` unguarded → **raised on the first position change of every live session** | both handlers coerce a missing position to `Position(65535,65535,255)`, the C++ default-constructed value |
| 8 | `bot/targetbot.lua:907` called `self._once(...)` with a dot | the walk watchdog — which trips exactly when a chase or keep-distance step loses its confirmation — took the whole native TargetBot tick down | `self:_once(...)` |
| 9 | the live status line always said `macros 0/47 ran` | 8500 clean ticks looked identical to a session in which nothing ever ran; the run counters are only installed by `instrumentMacros`, which only the tests called | `main.lua` instruments on the live path too (without `forceEnable`, so the user's on/off state is untouched) |

### API areas

* **`g_game`** — all 34 mutators (`walk` with a real prewalk queue, `move`, `use`,
  `useWith`, `attack`, `follow`, `talk*`, `equipItem*`, `open`/`close`, the
  fight/chase/PVP modes, `buyItem`/`sellItem`, `stashStowItem`, `partyInvite`/
  `partyJoin`, `answerModalDialog`) and every accessor, all producing byte-exact
  1530 packets through `proto/sender.lua`. `attack` reproduces all three
  `Game::attack` guards (`game.cpp:970-991`): attacking yourself is an early return,
  re-attacking the current target **cancels** and sends id 0, and the follow is cancelled
  with a real packet. The imbuement family (`applyImbuement`, `clearImbuement`,
  `closeImbuingWindow`, `selectImbuementItem`, `selectImbuementScroll`,
  `imbuementDurations`) is implemented on both sides.
* **`g_map`** — `getTile`, `getTiles` (per-floor index, 0.003 ms/call cached),
  `getSpectators`/`getSpectatorsInRange*`/`getSightSpectators` in the C++ tile-scan
  order, `getCreatureById`, `findPath`, `findEveryPath`, `isLookPossible`, the
  aware-range accessors, and the 8 inventory symbols.
* **`g_things`** — `getThingType` with 30 `ThingType` methods over
  `proto/items.lua`.
* **Object model** — `Thing < Creature < Player < LocalPlayer`, `Thing < Item`,
  plus `Tile`, `Container`, `ThingType`. **Identity is interned** (invariant I1):
  the same creature id / tile position / container id / thing table always returns
  the same Lua table, so `spec ~= player` and `top ~= ground` mean what vBot
  thinks they mean. `LocalPlayer:getPosition()` returns the **prewalk** position
  (I2). Items carry the synthetic container/inventory positions (I3).
* **UI** — a real widget class with a real parent/child/id/focus tree, a real OTML
  parser and style registry. 352 styles resolve from the 23 real `data/styles`
  files plus `mods/game_bot/ui/*.otui` plus all 24 profile `.otui` files. The
  CaveBot waypoint list, the TargetBot creature list and the AttackBot entry list
  — which *are* vBot's runtime data structures, with `getFocusedChild` as the
  CaveBot program counter — are real widget lists, not stubs.
* **Callbacks** — 31 parser events are bridged into the sandbox's own dispatchers and,
  where the C++ puts them there, onto `g_game` itself (see §5). Includes the gated
  per-thing tile hook, the imbuement family, `onGameEditText` and `onTurn`.
* **Platform** — `g_clock` (frame-quantised, I5), `g_resources` (sorted listings,
  `readFileContents` raises on a miss, I6), `g_settings`, `regexMatch`, `json`,
  `base64`, `bit`, the corelib `string`/`table` extensions,
  `table.decodeStringPairList` / `encodeStringPairList`.

---

### 3.5 What is still UNPROVEN

The behaviour suite closes the "no crashes ≠ correct" gap for the paths listed
above. It does not close it everywhere, and the honest list is this:

1. **Only eight scenario families in §3.2 are behaviour-tested.** 47 macros
   are registered; the suite drives 7 of them by their registration site
   (HealBot ×2, AttackBot, CaveBot, TargetBot, the looting path inside
   TargetBot's tick, and Dropper's cap/use/trash scan). The other ~40 —
   Conditions, Equipper, combo, Stances, Containers, the analyzer, NaviBot,
   the depositor, imbuing, the travel/bank/supply CaveBot extensions — are
   still only covered by the crash test. They run; nobody has asserted *what*
   they send.
2. **The worlds are synthetic.** Ground, walls, creatures and containers are
   built by hand from `items1530.bin`. Real map geometry — stacked items,
   elevation, blocking corner cases, multi-floor stairs, houses, PZ borders —
   is not exercised. A pathfinding or spectator bug that only appears on real
   terrain would not be caught here.
3. **Time is injected, not real.** The clock is a counter the test advances, so
   every cooldown, delay and use-window result is about the *arithmetic*, not
   about real scheduling under load. Ping is 0 in every scenario, so every
   ping-compensation branch (`getPingCompensation`, `getRawPing`, the
   predictive rune reservation) takes its zero-ping path.
4. **No packet ever comes back.** The fixtures synthesise the events the parser
   would emit, in the shapes the parser emits them, but nothing round-trips
   through a server. A behaviour that depends on the *server's* answer — a
   refused move, a "you are not the owner" corpse, a cancelled walk, a real
   spell rejection — is asserted only in the direction the client sends.
5. **The live proof is a smoke test, not a behaviour test.** The live sessions
   prove the tree boots, ticks 9500 times without raising, and that 38 macros
   really execute against a live world. They deliberately ran with combat and
   auto-walk **off** (`--vbot-safe`), so nothing about HealBot, AttackBot,
   TargetBot, CaveBot or looting was verified against the live server. Live
   combat correctness remains untested.
6. **Order dependence inside a tick is untested.** Each macro is driven in
   isolation so a failure is attributable. The interaction of the executor's
   real macro ordering — HealBot's potion racing AttackBot's rune for the shared
   1 s use-cooldown slot, CaveBot yielding to TargetBot — is exercised by the
   crash test only.
7. **The native cross-check is not an independent oracle for everything.** 23
   scenarios are checked against `bot/*.lua`, which was written from the same
   vBot sources; agreement rules out one side misreading the code, not both
   sides misreading it the same way. Where the two engines are paced differently
   under an instant-confirming fixture (the TargetBot keep-distance walk) the
   comparison is on the packet *sequence* and the resting tile, not on tick
   alignment — that difference is documented in the suite rather than hidden.
8. **Everything in §4 stays unproven by construction**: no keyboard, no mouse,
   no geometry, no rendering, and the divergences listed there
   (`Creature:isWalking()` for remote creatures, `Tile:hasFloorChange()`,
   party mana, the supply stash byte, single-dispatch signals).

## 4. What does NOT work

### Structural — no client, no window, no server

| area | behaviour |
|---|---|
| **Keyboard / hotkeys** | There is no keyboard, so no key event ever arrives from the wire. `shim.pressHotkey('Ctrl+F1')` fires one by hand: it drives the executor's own `onKeyDown` → `onKeyPress` → `onKeyUp` path (the same one `mods/game_bot/bot.lua:695-715` calls for a real key), so macro switches toggle, `single` hotkeys fire on the down edge, repeating ones on the press edge, and every `onKeyDown`/`onKeyPress`/`onKeyUp` callback the tree registered sees it. `shim.hotkeys()` lists what is bound. See §4.1. |
| **Mouse, drawing, geometry** | Every `setWidth`/`setHeight`/anchor/margin setter is a recorded no-op; geometry getters return 0 and `getLayout()` returns nil. `getChildByPos`, `containsPoint`, `getTextSize` are stubs. This is deliberate: `ui_elements.lua` compares against a maximum width, and 0 correctly skips the clamp. |
| **`onAnimatedText` / `onStaticText`** | Never fire — **and they do not fire in the reference client either.** There is no `callLuaField("onAnimatedText")` or `("onStaticText")` anywhere in mehah 1530's `src/`: `Map::addAnimatedText` is called from `protocolgameparse.cpp:2056,3127,3140,3151` and never tells Lua, so `bot.lua:611-612`'s `connect(g_map, ...)` is dead upstream. A zero count is C++-exact, not a gap. |
| **`modules.client_textedit.edit`, `displayGeneralBox`** | return a dummy hidden window and never call back. Every reachable call site is inside an `onClick`, so nothing headless reaches them today. |
| **Popup menus, graphs, mini-windows** | `UIPopupMenu:addOption/display`, `UIGraph:createGraph/addValue`, `UIMiniWindow:setup/open/close` are recorded no-ops. |
| **`client_entergame.CharacterList.doLogin`** | a loud no-op unless the host supplies an `onRelog` handler (blocker B4). |
| **`client_profiles`** | stays `nil`; `bot.lua:341` has a fallback path. |

### 4.1 Firing a hotkey by hand

`hotkey()` and `singlehotkey()` register normally (the user's profile binds one, `Space`),
but nothing headless ever presses a key. Two entry points close that:

```lua
local shim = require('shim.bootstrap')

shim.hotkeys()
--> { { keys = 'Space', name = '...', kind = 'hotkey', single = false }, ... }
--    kind = 'hotkey' for context._hotkeys, 'macro' for a macro's own `hotkey` binding

shim.pressHotkey('Ctrl+F1')   --> true when the combo is bound, false when nothing is
shim.pressHotkey('ctrl+f1')   --  spelling does not matter: the description is
                              --  canonicalised through retranslateKeyComboDesc, the
                              --  same function the registration side used
```

`pressHotkey` does **not** reach past the bot. It calls
`exec.callbacks.onKeyDown` → `onKeyPress` → `onKeyUp` — exactly what
`mods/game_bot/bot.lua:695-715` calls for a real key event — so everything downstream
behaves as if the key had been pressed:

* a macro whose `hotkey` matches gets its switch clicked (`executor.lua:226-229`),
  i.e. the macro toggles on or off;
* a `singlehotkey` fires on the **down** edge, an ordinary `hotkey` on the **press** edge
  (`executor.lua:230-238` / `:256-263`), which is the real client's split;
* a `hotkey.switch` is set on for the press and off for the release;
* every `onKeyDown` / `onKeyPress` / `onKeyUp` callback the tree registered sees the combo.

Pass `{ press = false }` or `{ up = false }` to send only some of the three edges (for a
hold, say). The mechanism is `shim/platform.lua`'s `determineKeyComboDesc`: a **string**
argument is canonicalised and returned, where a numeric key code stays the recorded no-op
it always was.

`shim.status().hotkeyList` carries the same list as `shim.hotkeys()`.

### Divergences you should know about

1. **`Creature:isWalking()` is false for every remote creature.** There is no
   render-time walk timer headless. For the local player it means "has an
   unconfirmed prewalk". All 8 live call sites are on `player`, so this is
   currently invisible.
2. **`Tile:hasFloorChange()` always returns false.** That is the C++-exact answer
   at 1530: `ThingFlagAttrFloorChange` is only ever set from the legacy `.dat`
   path, so the live client also returns false. vBot itself says so at
   `cavebot/walking.lua:62`. It reports loudly on the first call.
3. **`Creature:getManaPercent()` returns 100** for other party members — verified (work item
   R1) that opcode 0x8B never carries a genuine separate party-mana byte at 1530 in the first
   place (types 11/12/13 all funnel into the same `setCreatureVocation()` call in the real
   client); vBot's own party-mana reading comes from its self-hosted BotServer relay instead
   (gap G7, retitled — not a discarded byte).
4. **`g_game.getUnjustifiedPoints()` is real** (gap G3 closed): opcode 0xB7 is parsed
   into `state.unjustified` and the accessor reads it. **Until the packet arrives** the
   three `*Remaining` fields answer **255**, not 0. That choice is deliberate:
   `vBot/vlib.lua:223-227` `killsToRs()` is their minimum, and 0 is conservative for the
   AttackBot PvP gate (`killsToRs() > KillsAmount` stays false) but *inverts*
   `vBot/antiRs.lua:21` (`killsToRs() < 6`), which would then fire on every evaluation for
   the whole session. 255 is the only value that is safe in both directions.
5. **`LocalPlayer:isSupplyStashAvailable()` returns false** — the byte is
   discarded at `parser.lua:909` (gap G4).
6. **`Item:getServerId()` returns 0**, which is what the reference client returns.
   No client↔server id map can be derived offline — it exists only in `items.otb`,
   which `ThingTypeManager::loadOtb` (`thingtypemanager.cpp:653`) turns into
   `m_reverseItemTypes`, the 1530 data set does not ship one, and nothing in `src/`
   or `modules/` ever calls `g_things.loadOtb`. But it does not matter: `Item::m_serverId`
   is written in exactly one place (`item.cpp:273`), inside `#ifdef FRAMEWORK_EDITOR`,
   and `src/CMakeLists.txt:12` defaults `TOGGLE_FRAMEWORK_EDITOR` to **OFF** — so in the
   shipped client the field keeps its `item.h:193` initialiser `0` forever while the Lua
   binding (`luafunctions.cpp:853`) is compiled in unconditionally. The shim returns 0 and
   reports once.
7. **Signals fire ONCE.** The live client's `connect()` walks the metatable chain,
   so a `LocalPlayer` emit reaches both the `LocalPlayer` and the `Creature` slot
   and fires twice (blocker B9). Shim classes are plain tables; there is no double
   dispatch. Documented, not fixed.
8. **`getSpectators` order is the C++ tile scan** (`z → y → x`, top of stack
   first), which is deterministic. `bot/world.lua` iterates a hash; the two sets
   are asserted equal but only the shim's order is stable.
9. **An `Item` wrapper is interned per (thing, location) pair, not per thing.**
   One Lua thing table can be reachable from two addresses at once (a container's
   backing `item` field is also a slot entry of its parent), and a single shared
   wrapper let the last caller silently rewrite the wire address every earlier holder
   would report — and `Item:getPosition()`/`getStackPos()` are where `g_game.move` /
   `use` / `useWith` / `stashStowItem` get their `fromPos` and stackpos bytes.
   Consequence: `reg:item(t, L) == reg:item(t, L)` still holds (all `top ~= ground`
   needs), but a script that holds an `Item` across the tick in which the server moves
   it to a *different container* keeps addressing the **old** one until it re-queries,
   and the wrapper for the new address is a different table. The slot index inside a
   recorded location is read live, so the common looting case is correct.

### Long-range pathfinding (the biggest practical risk)

`Map::findEveryPath` consults the **persisted minimap** for every tile outside the
aware range. Headless that store is empty unless one is supplied, so a CaveBot
`goto` more than a screen away finds no path at all. `main.lua --vbot` loads the
reference client's `profiles/minimap.otmm` automatically (the same path the native
bot uses); `--minimap=off` disables it and `--minimap=PATH` overrides it. Without
a minimap, expect long hops to fail rather than to walk somewhere wrong.

---

## 5. Callbacks: what is bridged

`shim/callbacks.lua` maps `LC.events` (fed by `proto/parser.lua`) onto the
dispatchers `mods/game_bot/executor.lua` builds.

**Wired (31 events):** `talk` `textMessage` `loginAdvice` `creatureAppear`
`creatureDisappear` `creatureHealth` `creatureMove` `creatureTurn` `positionChange`
`containerOpen` `containerClose` `containerAddItem` `containerRemoveItem`
`containerUpdateItem` `inventoryChange` `channelList` `openChannel` `closeChannel`
`channelEvent` `modalDialog` `manaChange` `statesChange` `distanceEffect`
`spellCooldown` `spellGroupCooldown` `attackCancel` `editText` `unjustifiedPoints`
`imbuementTracker` `imbuementWindow` `imbuementWindowClose`, plus the gated per-thing
tile hook.

The imbuement events are re-signalled on **`g_game` itself** rather than through the
executor's dispatcher table, because that is where they live in the C++
(`g_lua.callGlobalField("g_game", "onUpdateImbuementTracker", ...)`) and where the user's
own `cavebot/imbuing.lua:151` connects: `onUpdateImbuementTracker`,
`onOpenImbuementWindow`, `onImbuementItem`, `onImbuementScroll`, `onCloseImbuementWindow`,
and `onEditText`. Dispatch goes through corelib's own `signalcall`, so a connected slot
*list* behaves like `modules/corelib/util.lua:42-119`.

**The plain chat / channel / cooldown family is re-signalled on `g_game` too**, for the
same reason and since the same review: `Game::processTextMessage` (`game.cpp:273`) and
`Game::processTalk` (`:278`) are `callGlobalField("g_game", ...)` calls in the C++, so
`connect(g_game, { onTextMessage = f })` is a working otclient idiom and has to keep
working here. `onTalk`, `onTextMessage`, `onLoginAdvice`, `onChannelList`,
`onOpenChannel`, `onCloseChannel`, `onChannelEvent`, `onModalDialog`, `onSpellCooldown`,
`onSpellGroupCooldown` and `onUnjustifiedPointsChange` are therefore dispatched **twice** —
once into the executor's own dispatcher (which is what `bot.lua`'s `connect` reaches in the
real client) and once onto the `g_game` slot. That is not double-firing: in the live client
`bot.lua` is simply one more subscriber to the same `g_game` signal.

One consequence worth knowing: `gamelib/textmessages.lua:3-8`, which the shim loads
verbatim, OWNS `g_game.onTextMessage` and `perror`s *"Unhandled onTextMessage message mode
N"* for any mode nobody registered. In the real client `modules/game_textmessage`'s
`init()` registers one display callback per mode; that client module is not loaded
headless, so `shim/modules.lua` reproduces the registration loop. A genuinely unregistered
mode still reports itself, exactly as upstream.

Those reach `onTalk`, `onTextMessage`, `onLoginAdvice`, `onCreatureAppear`,
`onCreatureDisappear`, `onCreatureHealthPercentChange`, `onCreaturePositionChange`,
`onWalk`, `onContainerOpen`, `onContainerClose`, `onContainerUpdateItem`,
`onAddItem`, `onRemoveItem`, `onInventoryChange`, `updateInventoryItems`,
`onChannelList`, `onOpenChannel`, `onCloseChannel`, `onChannelEvent`,
`onModalDialog`, `onManaChange`, `onStatesChange`, `onMissle`, `onSpellCooldown`,
`onGroupSpellCooldown`, `onAttackingCreatureChange`. `onUse` / `onUseWith` are a
client-side echo from the shim's own `g_game.use`/`useWith`, exactly as
`Game::use` emits them in C++.

**`onCreatureDisappear` keeps its creature.** The parser unlinks the record from
`state.creatures` before it emits, and `game/state.lua` clears `creature.pos` on the way
out, so the handler used to get a blank object — or, if nothing had wrapped that creature
during the session, nothing at all. Now `game/state.lua` moves the coordinates to
`creature.lastPos` instead of erasing them (`pos` still goes to `nil`, which
`bot/targetbot` and `test/bot_m3_target.lua:844` rely on), the bridge mints the wrapper
from the **record** (`Reg:creatureFromRecord`) rather than from the id, and the wrapper
pins it as `_lastRec`. A handler therefore still sees `getName()`, `getPosition()`,
`getOutfit()`, `getHealthPercent()` and `isMonster()` — which is what the live client's
still-alive `CreaturePtr` reports and what `targetbot/looting.lua:310-331` branches on.
`g_map.getCreatureById(id)` still answers `nil` for a removed id; that half was already
C++-exact. `onContainerClose` gets the same treatment via `Reg:containerFromRecord`, and
`onRemoveItem` now carries the item that left.

**`onAddThing` / `onRemoveThing` are gated, not absent.** They fire only while
`g_game.enableTileThingLuaCallback(true)` — the same gate as `tile.cpp:374-376,420-422` —
and cost one boolean test per thing otherwise. The hook wraps `state:addThing` and
`state:_removeAt`, which is the single removal funnel (`state:removeThing` and the
11-thing trim both go through it), so the trim's `onRemoveThing` fires before the outer
`onAddThing`, exactly as in `Tile::addThing`.

**`onTurn` is a deliberate superset.** The dedicated turn packet (the `Proto::Creature`
marker, `protocolgameparse.cpp:4483-4494`, "this is send creature turn") is now emitted as
its own `creatureTurn` event instead of being handled silently, and the bridge turns it
into `onTurn(creature, direction)`. Be aware that **the reference client emits no `onTurn`
at all** — there is no `callLuaField("onTurn", ...)` anywhere in mehah 1530's `src/` — so
`bot.lua:587`'s `connect(Creature, { onTurn = ... })` is dead upstream. The user's profile
registers no `onTurn` callback, so nothing behaves differently; it is documented here
because it is the one place the shim fires something the live client would not.

**Never fired:** `onKeyDown` `onKeyUp` `onKeyPress` (from the wire — see §4.1 for
`shim.pressHotkey`), `onAnimatedText` `onStaticText` (which the reference client does not
emit either). The bridge declares these explicitly so a zero count reads as "cannot fire",
not "has not happened yet" — see `shim.status().callbackBridge.dropped`.

**Message modes are translated.** `proto/opcodes.lua` names modes by their *wire*
byte; `Otc::MessageMode` numbers them differently, and vBot compares against the
*client* numbers (`mode == 20` is Look, `21` DamageDealed, `22` DamageReceived).
`shim/callbacks.lua:MODE_FROM_WIRE` is `protocolcodes.cpp:37-87` inverted. Passing
the wire byte through would make every one of those tests fire on the wrong
message.

---

## 6. The three source patches

The otclient tree is never edited. `shim/patches.lua` rewrites three files **in
memory** on the way to `load`, and every rewrite fails loudly if its expected text
is no longer present verbatim (the upstream-drift detector). All three are the
same bug class: upstream identifies a live widget or game object by its Lua
*type*, because in the real client those are `userdata` and every shim object is a
`table`.

| file | what breaks without it |
|---|---|
| `mods/game_bot/functions/map.lua:17,22` | `getSpectators(creature)` takes the *position* branch and reads `.x/.y/.z` off a creature — silently scanning the wrong tile. |
| `mods/game_bot/functions/ui_elements.lua:60` | `container:setItems(t)` throws `t` away, so every `UI.Container` loads **empty** — `targetbot/looting.lua:58`, `Dropper.lua:106`, `eat_food.lua:33`, `tools.lua:56`, `depositer_config.lua:239`, `Containers.lua:459`. |
| `profiles/bot/vBot_4.8/vBot/training.lua:511` | the user's private copy of the same bug; `training.lua:507,554` load nothing. |

A ripgrep over `mods/game_bot` and the whole profile confirms these are the only
three such tests in the tree.

---

## 7. Writing back (`--vbot-write`)

**Read-only is the default and the safe choice.** With it, every `g_resources`
write is intercepted, recorded in `status().blockedWrites` and refused, so a shim
bug cannot corrupt a config the real vBot still has to read.

The write path *has* been round-tripped against a full copy of the user's
profile: `CaveBot.save()` and `vBotConfigSave()` both succeed, all 33 top-level
storage keys survive, and `_macros` is preserved. Three differences remain after a
save, all of them vBot doing its own thing rather than shim damage:

* `navibot.chars.<name>` is added — NaviBot registering the character;
* three `newHealer.settings[*].text` labels change — vBot relabelling spells for
  the character's vocation;
* one unnamed macro's switch flips to `true`.

**One data-loss bug was found and fixed here, and it is worth knowing about.**
`vBot/depositer_config.lua:228` unconditionally mirrors
`modules.game_npctrade.getSellExceptions()` into `storage.cavebotSell` at load
time. In the real client that list lives in the *client's* own `g_settings`; the
shim has no access to it and a headless worker has never written it, so the list
started empty and **the user's seven sell exceptions became zero** on the first
write-mode run. `shim/bootstrap.lua` now seeds `modules.game_npctrade` from the
profile's own `storage.cavebotSell` mirror *before* the tree loads, and
`test/shim_compat_suite.lua` asserts the list survives. If you add another
`modules.*` list that vBot mirrors into storage, seed it the same way.

---

## 8. Porting an otclient script

Most scripts need no changes at all. The two things that catch people out are
both true of the **real** vBot as well — the vBot sandbox is not `_G`.

### The sandbox has no `__index` to `_G`

`executor.lua` builds `context` with an explicit list of ~490 names (invariant
I7). Anything not on that list is `nil` inside a bot script, *in the real client
too*. In particular these are **not** sandbox globals:

    connect  disconnect  signalcall  scheduleEvent  g_clock  g_app  Position
    rawget  rawset  rootWidget(as a global)  require

Reach them through `modules.game_bot` (whose `__index` falls through to the module
environment) or `modules.gamelib`:

```lua
-- otclient script                     -- vBot / shim equivalent
connect(list, {onChildFocusChange=f})  local connect = modules.game_bot.connect
                                       connect(list, {onChildFocusChange = f})

g_clock.millis()                       now            -- the frame-quantised value
                                       -- or: modules.game_bot.g_clock.millis()

scheduleEvent(fn, 200)                 schedule(200, fn)

Position.distance(a, b)                modules.gamelib.Position.distance(a, b)
                                       -- or: getDistanceBetween(a, b)
```

### Everything else is the same

```lua
-- reading the world: unchanged
local p    = g_game.getLocalPlayer()
local tile = g_map.getTile(p:getPosition())
for _, spec in ipairs(g_map.getSpectators(p:getPosition(), false)) do
    if spec ~= p and spec:isMonster() then
        g_game.attack(spec)                    -- 0xA1 on the wire
        break
    end
end

-- containers and items: unchanged
for _, container in pairs(g_game.getContainers()) do
    for _, item in ipairs(container:getItems()) do
        if item:getId() == 3031 then
            g_game.move(item, {x = 0xFFFF, y = 0x40 + 1, z = 0}, item:getCount())
        end
    end
end

-- thing types: unchanged
local tt = g_things.getThingType(3031, ThingCategoryItem)
if tt:isStackable() then ... end

-- UI: unchanged
local panel = g_ui.createWidget('Panel')
local label = g_ui.createWidget('Label', panel)
label:setId('greeting'); label:setText('hello')
assert(panel.greeting == label)                -- the parent Lua field is installed

-- inline OTUI: unchanged
local w = g_ui.loadUIFromString([[
Panel
  id: root
  Label
    id: title
    text: Compat
]])

-- macros and callbacks: unchanged
macro(500, 'my macro', function() ... end)
onTalk(function(name, level, mode, text) ... end)
onTextMessage(function(mode, text) if mode == 22 then ... end end)   -- 22 = DamageReceived
```

### Watch out for

* **`getMonsters()` / `getPlayers()` return a COUNT, not a list** (`vlib.lua:652`).
  Use `getSpectators()` for the list.
* **A macro callback receives the macro** (`functions/main.lua:114`:
  `macro.callback = function(macro)`). Call it as `m.callback(m)`, not `m.callback()`.
* **`getLeft()` / `getRight()` return `nil` for an empty slot.** The user's own
  "ripper spectre switch" macro does `getLeft():getId()` with no guard; it dies on
  an empty left hand here for exactly the reason it would die in the live client.
* **`LocalPlayer:getPosition()` is the prewalk position.** After
  `g_game.walk(North)` it already reports the destination tile. Use
  `getServerPosition()` for the confirmed one, or `resetPreWalk()`.
* **Widgets are Lua tables, not userdata.** `type(w) == 'userdata'` is false. Three
  places in the tree relied on that and are patched (§6); if you write new code,
  do not test a widget by its Lua type.
* **`g_game.getClientVersion()` is 1530** and `getProtocolVersion()` is 1530.

---

## 9. Diagnosing

```lua
local shim = require('shim.bootstrap')
local st = shim.status()
st.vbotLoaded, st.vbotFailed          -- per-file load verdicts
st.failures                            -- { {name=, err=}, ... }, first error per file
st.macros                              -- { {name=, enabled=, runs=, fails=, err=}, ... }
st.ticks, st.tickErrors, st.maxTickMs
st.stubs                               -- every modules.* symbol that resolved to a stub
st.callbackBridge                      -- { wired={}, fired={}, dropped={} }
st.blockedWrites                       -- every refused write, in read-only mode
st.patchNotes, st.patchFailures        -- the three source patches
st.ui                                  -- 'shim.g_ui' (real) or 'provisional' (a bug)
```

```lua
shim.hotkeys()                         -- every registered combo: {keys=, name=, kind=}
shim.pressHotkey('Ctrl+F1')            -- true = something was bound, false = nothing is
```

`--vbot-strict` turns every "not implemented headless" report into an `error()`,
which is the way to find out whether a script is quietly relying on a stub. Three
documented deviations still sit on live vBot paths and *will* raise under
`--vbot-strict`: `getManaPercent` (gap G7, no genuine wire byte exists) and
`Tile:hasFloorChange` (which is the C++-exact answer). `getUnjustifiedPoints` raises only
**before** opcode 0xB7 has arrived and goes quiet once it has. So `--vbot-strict` is still
a diagnostic mode rather than a production one, but the list is three items shorter than
it was and one of the three is C++-exact rather than missing.

---

## 10. Tests

| suite | what it proves |
|---|---|
| `test/shim_platform_suite.lua` | 452 — corelib, regex, resources, settings, `g_clock` |
| `test/shim_game_suite.lua` | 520 — the object model and the four game singletons, incl. 6 fragments lifted verbatim from the user's profile, §J the nine review findings and §K the closed gaps |
| `test/shim_ui_suite.lua` | 260 — the OTML parser, style registry and widget model, incl. the real `functions/ui*.lua` |
| `test/shim_host_suite.lua` | 118 — the `modules.*` graph and the full boot of the real profile |
| `test/shim_compat_suite.lua` | 89 — **that nothing crashes**: every macro, 31 otclient snippets, the callback bridge, hotkeys fired by hand, the closed gaps against the real profile, and every real `.cfg`/`.json` config |
| **`test/shim_behaviour_suite.lua`** | **131 — that the bot does the RIGHT THING: the exact packet the real vBot code puts on the wire for HealBot spells and items, AttackBot, CaveBot, TargetBot, looting, Dropper's cap/use/trash scan, and 15 otclient idioms; 25 of those scenarios cross-checked packet-for-packet against the native `bot/*.lua` engines. See §3.2, and §3.5 for what it still does not prove** |
| `test/fakeserver.lua --vbot` | 44 — login over a real socket, shim boot, 240 in-game ticks |
| `test/selftest.lua`, `test/botsuite.lua` | 2547 / 2137 — the native client and bot layer, unchanged |

All pass on Windows LuaJIT and on Debian/WSL LuaJIT.
