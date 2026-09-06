# Running otclient / vBot scripts under `luaclient`

**Status: the user's real vBot 4.8 profile boots and ticks under the standalone
LuaJIT client, unmodified.** 74/74 profile files, 27/27 `mods/game_bot` runtime
files, 47–48 macros, on Windows and on Debian, with no game client, no OpenGL and
no game server.

    luajit main.lua --vbot ...                 # instead of --bot
    luajit test/shim_compat_suite.lua          # the backward-compatibility proof
    luajit test/fakeserver.lua --vbot          # the same thing end-to-end over TCP

This document says what works, what does not, which APIs are stubs, and how to
port an otclient script. It is deliberately blunt about the gaps: a function that
silently returns a wrong value is worse than one that is absent and errors loudly,
and everything listed under *Stubs* below is loud.

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
| `--vbot-write` | allow the bot to save its storage and configs. **Off by default** — see §7. `--dry-run` always forces read-only. |

The native bot layer (`--bot`) is untouched and remains the default; every one of
its 2137 tests still passes.

---

## 3. What works

### Verified by running real code

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

### API areas

* **`g_game`** — all 34 mutators (`walk` with a real prewalk queue, `move`, `use`,
  `useWith`, `attack`, `follow`, `talk*`, `equipItem*`, `open`/`close`, the
  fight/chase/PVP modes, `buyItem`/`sellItem`, `stashStowItem`, `partyInvite`/
  `partyJoin`, `answerModalDialog`) and every accessor, all producing byte-exact
  1530 packets through `proto/sender.lua`.
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
* **Callbacks** — 25 parser events are bridged into the sandbox's own dispatchers
  (see §5).
* **Platform** — `g_clock` (frame-quantised, I5), `g_resources` (sorted listings,
  `readFileContents` raises on a miss, I6), `g_settings`, `regexMatch`, `json`,
  `base64`, `bit`, the corelib `string`/`table` extensions,
  `table.decodeStringPairList` / `encodeStringPairList`.

---

## 4. What does NOT work

### Structural — no client, no window, no server

| area | behaviour |
|---|---|
| **Keyboard / hotkeys** | `hotkey()` registers and is counted; nothing ever presses a key, so `onKeyDown`/`onKeyUp`/`onKeyPress` never fire. Drive a hotkey by calling its callback. |
| **Mouse, drawing, geometry** | Every `setWidth`/`setHeight`/anchor/margin setter is a recorded no-op; geometry getters return 0 and `getLayout()` returns nil. `getChildByPos`, `containsPoint`, `getTextSize` are stubs. This is deliberate: `ui_elements.lua` compares against a maximum width, and 0 correctly skips the clamp. |
| **`onAddThing` / `onRemoveThing`** | `game/state.lua` has no per-thing emit hook (gap G5). `g_game.enableTileThingLuaCallback()` exists as the gate; the hook does not. |
| **Imbuements** | `applyImbuement`, `clearImbuement`, `closeImbuingWindow`, `selectImbuementItem`, `imbuementDurations`, `onImbuementWindow` — there is no sender and no parser on either side (blocker B2). Loud stubs. |
| **`onGameEditText`, `onAnimatedText`, `onStaticText`, `onTurn`** | the parser does not surface these; a turn is folded into `creatureMove`. |
| **`modules.client_textedit.edit`, `displayGeneralBox`** | return a dummy hidden window and never call back. Every reachable call site is inside an `onClick`, so nothing headless reaches them today. |
| **Popup menus, graphs, mini-windows** | `UIPopupMenu:addOption/display`, `UIGraph:createGraph/addValue`, `UIMiniWindow:setup/open/close` are recorded no-ops. |
| **`client_entergame.CharacterList.doLogin`** | a loud no-op unless the host supplies an `onRelog` handler (blocker B4). |
| **`client_profiles`** | stays `nil`; `bot.lua:341` has a fallback path. |

### Divergences you should know about

1. **`Creature:isWalking()` is false for every remote creature.** There is no
   render-time walk timer headless. For the local player it means "has an
   unconfirmed prewalk". All 8 live call sites are on `player`, so this is
   currently invisible.
2. **`Tile:hasFloorChange()` always returns false.** That is the C++-exact answer
   at 1530: `ThingFlagAttrFloorChange` is only ever set from the legacy `.dat`
   path, so the live client also returns false. vBot itself says so at
   `cavebot/walking.lua:62`. It reports loudly on the first call.
3. **`Creature:getManaPercent()` returns 100** for other party members — the 0x8B
   party mana byte is discarded by the parser (gap G7).
4. **`g_game.getUnjustifiedPoints()` returns an all-zero struct** — opcode 0xB7 is
   not parsed (gap G3). `killsToRs()` therefore always answers the same number.
5. **`LocalPlayer:isSupplyStashAvailable()` returns false** — the byte is
   discarded at `parser.lua:909` (gap G4).
6. **`Item:getServerId()` returns the client id** — there is no client↔server id
   map offline (blocker B3).
7. **Signals fire ONCE.** The live client's `connect()` walks the metatable chain,
   so a `LocalPlayer` emit reaches both the `LocalPlayer` and the `Creature` slot
   and fires twice (blocker B9). Shim classes are plain tables; there is no double
   dispatch. Documented, not fixed.
8. **`getSpectators` order is the C++ tile scan** (`z → y → x`, top of stack
   first), which is deterministic. `bot/world.lua` iterates a hash; the two sets
   are asserted equal but only the shim's order is stable.
9. **An `Item` wrapper's location is refreshed when the wrapper is handed out**,
   like the C++ stamping `Thing::m_position` on add. A script that holds an `Item`
   across the tick in which the server moves it to a *different container* will
   address the old one until it re-queries. The slot index inside the recorded
   location is read live, so the common looting case is correct.

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

**Wired (25 events):** `talk` `textMessage` `loginAdvice` `creatureAppear`
`creatureDisappear` `creatureHealth` `creatureMove` `positionChange`
`containerOpen` `containerClose` `containerAddItem` `containerRemoveItem`
`containerUpdateItem` `inventoryChange` `channelList` `openChannel` `closeChannel`
`channelEvent` `modalDialog` `manaChange` `statesChange` `distanceEffect`
`spellCooldown` `spellGroupCooldown` `attackCancel`.

Those reach `onTalk`, `onTextMessage`, `onLoginAdvice`, `onCreatureAppear`,
`onCreatureDisappear`, `onCreatureHealthPercentChange`, `onCreaturePositionChange`,
`onWalk`, `onContainerOpen`, `onContainerClose`, `onContainerUpdateItem`,
`onAddItem`, `onRemoveItem`, `onInventoryChange`, `updateInventoryItems`,
`onChannelList`, `onOpenChannel`, `onCloseChannel`, `onChannelEvent`,
`onModalDialog`, `onManaChange`, `onStatesChange`, `onMissle`, `onSpellCooldown`,
`onGroupSpellCooldown`, `onAttackingCreatureChange`. `onUse` / `onUseWith` are a
client-side echo from the shim's own `g_game.use`/`useWith`, exactly as
`Game::use` emits them in C++.

**Never fired:** `onKeyDown` `onKeyUp` `onKeyPress` `onAddThing` `onRemoveThing`
`onImbuementWindow` `onGameEditText` `onAnimatedText` `onStaticText` `onTurn`.
The bridge declares these explicitly so a zero count reads as "cannot fire", not
"has not happened yet" — see `shim.status().callbackBridge.dropped`.

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

`--vbot-strict` turns every "not implemented headless" report into an `error()`,
which is the way to find out whether a script is quietly relying on a stub. Note
that four documented deviations (`getUnjustifiedPoints`, `isSupplyStashAvailable`,
`getManaPercent`, `Tile:hasFloorChange`) sit on live vBot paths and *will* raise
under `--vbot-strict`, so it is a diagnostic mode, not a production one, until
those four parser gaps are closed.

---

## 10. Tests

| suite | what it proves |
|---|---|
| `test/shim_platform_suite.lua` | 436 — corelib, regex, resources, settings, `g_clock` |
| `test/shim_game_suite.lua` | 371 — the object model and the four game singletons, incl. 6 fragments lifted verbatim from the user's profile |
| `test/shim_ui_suite.lua` | 260 — the OTML parser, style registry and widget model, incl. the real `functions/ui*.lua` |
| `test/shim_host_suite.lua` | 117 — the `modules.*` graph and the full boot of the real profile |
| **`test/shim_compat_suite.lua`** | **62 — every macro, 31 otclient snippets, the callback bridge, and every real `.cfg`/`.json` config** |
| `test/fakeserver.lua --vbot` | 44 — login over a real socket, shim boot, 240 in-game ticks |
| `test/selftest.lua`, `test/botsuite.lua` | 2538 / 2137 — the native client and bot layer, unchanged |

All pass on Windows LuaJIT and on Debian/WSL LuaJIT.
