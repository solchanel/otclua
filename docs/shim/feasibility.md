# A4 — Feasibility probe: running real vBot 4.8 under plain LuaJIT

**Verdict: FEASIBLE.** Every one of the 74 Lua files in the user's live
`vBot_4.8` profile, plus all 27 files of the `game_bot` runtime that builds
the sandbox, **compile and run to completion under plain LuaJIT with zero
source modifications**, on top of an auto-generated permissive shim. 48 macros
register. Five forced ticks execute 45 of the 48 macro bodies without error.

Nothing in vBot needs C++. The load-time surface is almost entirely UI-widget
noise; the *game* surface (`g_game`, `g_map`, `Creature`, `Item`) is barely
touched at import and is small and well-bounded at tick time.

- Harness: `D:/Claude/otclient_web/luaclient/tools/shim_probe.lua`
- Full console output: `D:/Claude/otclient_web/luaclient/docs/shim/probe_run.txt`
- Machine-readable touch log: `D:/Claude/otclient_web/luaclient/docs/shim/probe_touched.txt`
  (4194 distinct API paths, tab-separated: `count / first-touch-phase / index|call / path`)
- Interpreter: `D:/Claude/otclient_mehah1530/otclient/build/win-local/vcpkg_installed/x64-windows-static-release/tools/luajit/luajit.exe`
  → `LuaJIT 2.1.1781602682`, `_VERSION == "Lua 5.1"`, `type(jit) == "table"`.

---

## 1. What the harness does

It reproduces the real load path, not an approximation of it:

1. `dofile`s the **real** `D:/Claude/otclient_mehah1530/otclient/mods/game_bot/executor.lua`,
   which defines the global `executeBot(config, storage, tabs, msgCallback, saveConfigCallback, reloadCallback, websockets)`.
2. Calls `executeBot("vBot_4.8", storage, tabs, …)` with the user's **real**
   `profiles/bot/vBot_4.8/storage/profile_1.json` (44 975 bytes) decoded through
   otclient's own `corelib/json.lua`.
3. `executeBot` then does exactly what it does in the client:
   `dofiles("functions")` → 20 files, `dofiles("panels")` → 7 files, then
   `load(g_resources.readFileContents(file), file, nil, context)` for every top-level
   `.lua` in `/bot/vBot_4.8` — which is just `_Loader.lua`, which `dofile`s the
   other 73.
4. Calls the returned `script()` five times, having first fast-forwarded the
   clock past the longest macro timeout (600 000 ms) and force-enabled every
   macro, so that all 48 macro bodies actually execute.

Two LuaJIT facts made this possible and both must be preserved in the real shim:

- **`load(chunk, name, mode, env)` works** in this LuaJIT build (5.2-compat env
  parameter is enabled), so `executor.lua` takes its non-`setfenv` branch
  unmodified. `setfenv` also exists, so the other branch is available as a fallback.
- **Lua 5.1 `ipairs`/`pairs`/`#` are raw.** That is why a metatable-based
  "anything" object iterates *zero* times instead of looping forever — the entire
  probe strategy depends on it.

### The permissive "anything" object

`mkany(path)` returns a table whose metatable makes it:

| operation | behaviour |
|---|---|
| `__index` | returns a **memoised** child `mkany(path..".k")` — so `w.foo` is stable across accesses and `w.a.b.c` works |
| `__call` | logs `path()`, then returns `RETURNS[leafName]` if registered, else a fresh `mkany(path.."()")` — so `w:foo(x)` and `f().g:h()` both work |
| `__newindex` | `rawset` — so `widget.onClick = fn` sticks |
| `__len`/`__eq`/`__lt`/`__le`/arith | 0 / identity / false / true / 0 |
| `ipairs`/`pairs` | zero iterations (raw in 5.1) |

Every index and every call is recorded with the file that was executing at the
time. That log *is* the deliverable.

---

## 2. The iteration log — what actually blocked, in order

This is the empirical part of the work item. Each row is a real crash in a real
vBot file, and the minimum thing that unblocked it.

| # | Crash | File:line | Root cause | Minimum fix |
|---|---|---|---|---|
| 1 | `bad argument #1 to 'ipairs' (table expected, got nil)` | `mods/game_bot/functions/player_conditions.lua:3` | `PlayerStates` is a **global defined in `modules/gamelib/player.lua`**, not in the sandbox — the bot's own `functions/` files read otclient globals directly | load otclient's pure-Lua `gamelib/*.lua` verbatim |
| 2 | `attempt to index local 'tabButton' (a nil value)` | `vBot/playerlist.lua:243` | `TabBar.buttonsPanel:getChildren()[v]` — `getChildren()` returning a plain `{}` is not enough; vBot indexes it by arbitrary key | `getChildren()` must return a table that is empty for `ipairs`/`#` **but yields a widget for any explicit index** |
| 3 | `attempt to call field 'loadUIFromString' (a nil value)` | `mods/game_bot/functions/ui_legacy.lua:17`, from `vBot/BotServer.lua:4` | `g_ui` implemented as a closed table → unknown members are `nil` | make the `g_*` singletons themselves permissive objects, not closed tables |
| 4 | `readFileContents: missing /bot/vBot_4.8/targetbot_configs/vBot_4.8.json` | `vBot/new_cavebot_lib.lua:31` (`CaveBotConfigParse`) | a **non-Lua data file** read at import; the name comes from a combobox `getCurrentOption().text` | soft-miss: return `""` for non-`.lua` misses, hard-error only for `.lua` |
| 5 | `attempt to call global 'tr' (a nil value)` / `attempt to index global 'Thing'` | `gamelib/player.lua:53`, `gamelib/thing.lua:52` | ordering — the reused otclient libs must be loaded **after** the globals they close over exist | define `tr`, `Thing`, … first, then load gamelib |

After fix 5 the whole tree imported and ticked. **Total: five distinct
blockers**, none of which is a game-state API.

### 2b. Mechanical enumeration of the non-UI import surface (`--strict-api`)

With `--strict` (any unimplemented call raises), the probe dies immediately at
`executor.lua:24` on `tabs:addTab(...)` — proof that *the widget layer is the
first and largest thing a shim must answer*, before anything game-related.

So the probe has a second mode, `--strict-api`, where **only non-widget** calls
raise. Iterating it to a fixpoint enumerates the complete set of non-UI APIs
that are load-bearing **at import time**. There are exactly **15**, and this is
the whole list (`tools/shim_probe.lua` section 5b, `IMPORT_REQUIRED`):

```lua
enableTileThingLuaCallback  = false   -- g_game.enableTileThingLuaCallback  (extras.lua)
isGroupCooldownIconActive   = false   -- modules.game_cooldown.*            (functions/player.lua:213)
isCooldownIconActive        = false   -- modules.game_cooldown.*            (functions/player.lua)
getMiniMapUi   = <widget>             -- modules.game_minimap               (cavebot/minimap.lua:26)
create         = <object>             -- Item.create(id[,count])            (targetbot/looting.lua, 185 calls)
isDead         = false                -- Creature:isDead()                  (vBot/playerlist.lua)
loadUIFromString = <widget>           -- g_ui.loadUIFromString(str, parent)  (functions/ui_legacy.lua:17)
getSlot5       = <widget>             -- modules.game_inventory.getSlot5()  (vBot/quiver_label.lua)
cancelAttackAndFollow = false         -- g_game.cancelAttackAndFollow()     (vBot/antiRs.lua)
displayGameMessage    = false         -- modules.game_textmessage           (vBot/training.lua)
destroy               = false         -- modules.game_buttons...destroy()   (vBot/analyzer.lua)
addToggleButton       = <widget>      -- modules.game_mainpanel             (vBot/analyzer.lua)
getPercent            = 0             -- modules.game_skills...:getPercent()(vBot/analyzer.lua)
getSellExceptions     = {}            -- modules.game_npctrade              (vBot/depositer_config.lua:185)
setSellExceptionsListener = false     -- modules.game_npctrade              (vBot/depositer_config.lua)
```

Note the shapes: four of these **must return a widget**, one must return an
`Item` object, one a table, one a number. Returning `false`/`nil` for those
produces `attempt to index a boolean` and `bad argument #1 to 'ipairs'`.

Running `--strict-api` *with* ticks then enumerates the tick-time non-UI
surface, which is equally small:

```
g_game.isAttacking()                 vBot/vlib.lua:1004   (function target())
g_window.setTitle()                  vBot/extras.lua:170
g_map.getSpectatorsByPattern()       vBot/new_healer.lua:1320
Creature:getRegenerationTime()       vBot/eat_food.lua:36  (compared with a number!)
modules.game_bot.connect()           cavebot/stand_lure.lua:167 (from a scheduled event)
```

---

## 3. Best run — real console output

Trimmed only where a block is a long uniform list (marked `…`); the untrimmed
file is `docs/shim/probe_run.txt`.

```
==============================================================================
PHASE 1 -- load mods/game_bot/executor.lua
==============================================================================
  executor.lua: compiled+ran OK (defines executeBot)

==============================================================================
PHASE 2 -- executeBot('vBot_4.8')
==============================================================================
  loaded real storage/profile_1.json (44975 bytes)
[01:14:22] [CONFIG] Changed Cooldown Time:  to: 0
[01:14:22] [CONFIG] Changed Search Range:  to: 0
[01:14:22] [SYSTEM] === AUTO TRAINING WEAPON SCRIPT LOADED ===
[01:14:22] [SYSTEM] Version: 2.2 - Enhanced with Error Handling
[01:14:22] [CONFIG] Target Object ID: 28559
[01:14:22] [SYSTEM] Status: Ready for training
[01:14:22] [SYSTEM] =====================================

==============================================================================
IMPORT OK in 31 ms
==============================================================================

==============================================================================
PHASE 3 -- ticks (res.script())
==============================================================================
  context recovered: true   macros=48  scheduler=1  hotkeys=1  callbacks(sum)=83
  tick 1: OK   (new bot-level errors: 0)
  tick 2: OK   (new bot-level errors: 0)
  tick 3: OK   (new bot-level errors: 0)
  tick 4: OK   (new bot-level errors: 0)
  tick 5: OK   (new bot-level errors: 0)

==============================================================================
REPORT
==============================================================================
bot messages: info=0 warn=1 error=0
   [warn] CaveBot[Imbuing]: cannot reach connect() - imbuement tracker data unavailable

-- files loaded via dofiles() (game_bot/functions, game_bot/panels) --
  mods/game_bot/executor.lua                 OK
  functions/callbacks.lua                    OK
  functions/config.lua                       OK
  functions/const.lua                        OK
  functions/icon.lua                         OK
  functions/main.lua                         OK
  functions/map.lua                          OK
  functions/npc.lua                          OK
  functions/player.lua                       OK
  functions/player_conditions.lua            OK
  functions/player_inventory.lua             OK
  functions/script_loader.lua                OK
  functions/server.lua                       OK
  functions/sound.lua                        OK
  functions/test.lua                         OK
  functions/tools.lua                        OK
  functions/ui.lua                           OK
  functions/ui_elements.lua                  OK
  functions/ui_legacy.lua                    OK
  functions/ui_windows.lua                   OK
  panels/attacking.lua                       OK
  panels/basic.lua                           OK
  panels/healing.lua                         OK
  panels/looting.lua                         OK
  panels/tools.lua                           OK
  panels/war.lua                             OK
  panels/waypoints.lua                       OK
  -> 27 ok, 0 failed

-- vBot 4.8 sources, in load order --
  /bot/vBot_4.8/_Loader.lua                      OK    1407B   31ms
    /vBot/main.lua                                 OK     190B    0ms
    /vBot/items.lua                                OK   42496B    0ms
    /vBot/vlib.lua                                 OK   36134B    0ms
    /vBot/new_cavebot_lib.lua                      OK   18249B    0ms
    /vBot/configs.lua                              OK    2984B    0ms
    /vBot/extras.lua                               OK   22856B    0ms
    /vBot/cavebot.lua                              OK    1905B    0ms
      /cavebot/actions.lua                           OK   21102B    0ms
      /cavebot/config.lua                            OK    7939B    0ms
      /cavebot/editor.lua                            OK    5935B    0ms
      /cavebot/example_functions.lua                 OK    2718B    0ms
      /cavebot/recorder.lua                          OK    2814B    0ms
      /cavebot/walking.lua                           OK   17195B    0ms
      /cavebot/minimap.lua                           OK     859B    0ms
      /cavebot/sell_all.lua                          OK    2442B    0ms
      /cavebot/depositor.lua                         OK    9039B    0ms
      /cavebot/buy_supplies.lua                      OK    3384B    0ms
      /cavebot/d_withdraw.lua                        OK    2830B    0ms
      /cavebot/supply_check.lua                      OK    6550B    0ms
      /cavebot/travel.lua                            OK    1007B    0ms
      /cavebot/doors.lua                             OK    1639B    0ms
      /cavebot/pos_check.lua                         OK    2594B    0ms
      /cavebot/withdraw.lua                          OK    1575B    0ms
      /cavebot/inbox_withdraw.lua                    OK    2631B    0ms
      /cavebot/lure.lua                              OK     704B    0ms
      /cavebot/bank.lua                              OK    2804B    0ms
      /cavebot/clear_tile.lua                        OK    3682B    0ms
      /cavebot/tasker.lua                            OK    5530B    0ms
      /cavebot/imbuing.lua                           OK   27201B    0ms
      /cavebot/stand_lure.lua                        OK    6165B    0ms
      /cavebot/antilost.lua                          OK   35049B    0ms
      /cavebot/route_tools.lua                       OK    9910B    0ms
      /cavebot/cavebot.lua                           OK   20691B    0ms
      /targetbot/creature.lua                        OK    3027B    0ms
      /targetbot/creature_attack.lua                 OK    8935B    0ms
      /targetbot/creature_editor.lua                 OK    4206B    0ms
      /targetbot/creature_priority.lua               OK    1727B    0ms
      /targetbot/looting.lua                         OK   11661B    0ms
      /targetbot/walking.lua                         OK    1855B    0ms
      /targetbot/target.lua                          OK    9340B    0ms
    /vBot/playerlist.lua                           OK   12073B    0ms
    /vBot/BotServer.lua                            OK    7467B    0ms
    /vBot/alarms.lua                               OK    5936B    0ms
    /vBot/Conditions.lua                           OK    9181B    0ms
    /vBot/Equipper.lua                             OK   24576B    0ms
    /vBot/pushmax.lua                              OK    7071B    0ms
    /vBot/combo.lua                                OK   14398B    0ms
    /vBot/HealBot.lua                              OK   33118B    0ms
    /vBot/new_healer.lua                           OK   47910B    0ms
    /vBot/AttackBot.lua                            OK  110054B    0ms
    /vBot/Stances.lua                              OK   16269B    0ms
    /vBot/ingame_editor.lua                        OK     914B    0ms
    /vBot/Dropper.lua                              OK    3178B    0ms
    /vBot/Containers.lua                           OK   19698B    0ms
    /vBot/quiver_manager.lua                       OK    3375B    0ms
    /vBot/quiver_label.lua                         OK    1270B    0ms
    /vBot/tools.lua                                OK    2144B    0ms
    /vBot/antiRs.lua                               OK     849B    0ms
    /vBot/depot_withdraw.lua                       OK    2023B    0ms
    /vBot/eat_food.lua                             OK    1414B    0ms
    /vBot/equip.lua                                OK    1334B    0ms
    /vBot/training.lua                             OK   27627B    0ms
    /vBot/exeta.lua                                OK     987B    0ms
    /vBot/analyzer.lua                             OK   56676B    0ms
    /vBot/spy_level.lua                            OK     578B    0ms
    /vBot/supplies.lua                             OK   12383B    0ms
    /vBot/depositer_config.lua                     OK    8185B    0ms
    /vBot/npc_talk.lua                             OK     209B    0ms
    /vBot/xeno_menu.lua                            OK    1174B    0ms
    /vBot/hold_target.lua                          OK     886B    0ms
    /vBot/cavebot_control_panel.lua                OK    1597B    0ms
    /vBot/navibot.lua                              OK     239B    0ms
      /navibot/navibot.lua                           OK   22044B    0ms
  -> 74 ok, 0 failed, 74 total

-- macros registered at import time --
  (anonymous)                              every    100ms  ON  runs=5   fails=0
  (anonymous)                              every   5000ms  ON  runs=5   fails=0
  …42 more, all runs=5 fails=0…
  ripper spectre switch                    every    100ms  off runs=5   fails=5   [string "macro(100, "ripper spectre switch", function(..."]:13: attempt to index a nil value
  Exchange money                           every   1000ms  ON  runs=5   fails=0
  Send message on trade                    every  60000ms  off runs=5   fails=5   functions/player.lua:74: attempt to call method 'lower' (a nil value)
  Eat Food                                 every  15000ms  off runs=5   fails=5   [string "/vBot/eat_food.lua"]:36: attempt to compare number with table
  Hold Target                              every    100ms  ON  runs=5   fails=0
  -> 48 macros

-- non-lua files the bot asked for but the probe could not supply --
     1  /bot/vBot_4.8/targetbot_configs/vBot_4.8.json

-- otclient pure-Lua libs reused verbatim --
  loaded: corelib/const.lua, corelib/bitwise.lua, gamelib/const.lua, gamelib/position.lua,
          gamelib/player.lua, gamelib/creature.lua, gamelib/textmessages.lua, gamelib/spells.lua,
          gamelib/items.lua, gamelib/thing.lua, gamelib/tile.lua, gamelib/util.lua

-- otui styles importStyle()'d --
  24 files

-- REAL implementations that were actually exercised --
     493  g_ui.createWidget
      77  g_resources.readFileContents
      37  g_ui.getRootWidget
      24  g_ui.importStyle
      21  g_game.getContainers
      15  g_resources.directoryExists
      11  g_map.getSpectators
      10  game_interface.getRightPanel
       6  g_resources.fileExists
       4  g_resources.listDirectoryFiles
       4  g_game.getClientVersion
       4  contentsPanel.config:getCurrentOption
       2  g_game.getLocalPlayer
       2  dofiles
       1  g_settings.getNumber
       1  g_game.getFeature
       1  g_resources.writeFileContents
       1  g_resources.makeDir
       1  regexMatch

-- SINGLETON / GLOBAL APIs reached through the permissive shim --
   these are the ones a real shim MUST provide.  [phase] = first touch
     185  [target      ] Item.create()
      10  [tick        ] g_game.isAttacking()
       6  [analyzer    ] modules.game_skills.skillsWindow.contentsPanel.level.percent.getPercent()
       5  [tick        ] Creature<ProbeChar>.getRegenerationTime()
       5  [extras      ] g_game.enableTileThingLuaCallback()
       5  [tick        ] g_map.getSpectatorsByPattern()
       5  [tick        ] g_window.setTitle()
       2  [cavebot     ] g_game.imbuementDurations()
       2  [depositer_config] modules.game_npctrade.getSellExceptions()
       1  [playerlist  ] Creature<ProbeChar>.isDead()
       1  [antiRs      ] g_game.cancelAttackAndFollow()
       1  [tick        ] modules.game_bot.connect()
       1  [analyzer    ] modules.game_buttons.buttonsWindow.contentsPanel.buttons.botAnalyzersButton.destroy()
       1  [functions   ] modules.game_cooldown.isCooldownIconActive()
       1  [functions   ] modules.game_cooldown.isGroupCooldownIconActive()
       1  [quiver_label] modules.game_inventory.getSlot5()
       1  [analyzer    ] modules.game_mainpanel.addToggleButton()
       1  [minimap     ] modules.game_minimap.getMiniMapUi()
       1  [depositer_config] modules.game_npctrade.setSellExceptionsListener()
       1  [training    ] modules.game_textmessage.displayGameMessage()
  -> 20 distinct global API call paths

-- WIDGET METHODS called on shim widgets (aggregated by method name) --
  setText(624)  setItem(185)  setColor(109)  setChecked(102)  setTooltip(96)  setOn(81)
  addOption(68)  setId(68)  setValue(53)  setHeight(51)  getWidth(44)  isOn(44)  hide(40)
  setWidth(40)  destroyChildren(35)  getChildren(35)  setTTFFont(35)  getTab(32)  addValue(30)
  getGraphsCount(30)  setItemId(26)  setVisible(24)  show(23)  focus(20)  raise(20)
  getBackgroundColor(19)  getMaximum(18)  loadUIFromString(17)  getValue(15)  setRange(15)
  getChildCount(12)  setStep(11)  destroy(10)  getChildById(10)  recursiveGetChildById(10)
  setup(10)  setCurrentIndex(8)  getChildByIndex(6)  getParent(6)  setEnabled(6)  setOutfit(6)
  setPercent(6)  getText(5)  isVisible(5)  setTitle(5)  addTab(4)  setImageColor(4)
  clearOptions(3)  setContentMaximumHeight(3)  setOption(3)  setShowCount(3)  clear(2)
  getCurrentOption(2)  getChildIndex(1)  getFocusedChild(1)  isChecked(1)  setContentWidget(1)
  -> 57 distinct widget methods

-- API paths FIRST touched during the tick phase (never at import) --
      10  g_game.isAttacking()
       5  g_window.setTitle()
       5  Creature<ProbeChar>.getRegenerationTime()
       5  g_map.getSpectatorsByPattern()
       1  modules.game_bot.connect()
  -> 5 tick-only API paths

  (4194 distinct touched paths total)

wrote docs/shim/probe_touched.txt
```

---

## 4. What this proves about the shim's shape

### 4.1 The load-time surface is UI, not game

Of 4194 distinct API paths touched, **4113 are widget paths** and only **20 are
non-widget calls**. Import is a UI-construction phase: vBot builds ~500 widgets
and wires callbacks. It reads almost no game state.

Consequence: the first thing to build is a **`UIWidget` stand-in with 57
methods** (list above, verbatim, with call counts). Almost all are setters that
may be **INERT STUBs** returning the widget. The load-bearing subset is small:

| must be real | why |
|---|---|
| `getChildren()` | indexed by arbitrary key (`playerlist.lua:243`), must be table-like |
| `getChildById(id)` / `recursiveGetChildById(id)` | must be *memoised* per id or assignments don't stick |
| `getChildByIndex(i)`, `getChildCount()`, `getChildIndex()` | list panels |
| `getText()`, `getValue()`, `isOn()`, `isChecked()`, `getCurrentOption()` | read back by config code; must be **STATEFUL STUBs** paired with their setters |
| `addTab(name, panel)` → object with `.tabPanel.content` | `executor.lua:24`, the very first widget call |
| `addOption(text, data)` / `clearOptions()` / `setOption()` / `setCurrentIndex()` | combobox state, read back |
| `getMaximum()`/`setValue()` on scrollbars | pure arithmetic, INERT is fine |

`g_ui.createWidget(style, parent)`, `g_ui.loadUIFromString(str, parent)`,
`g_ui.getRootWidget()` and `g_ui.importStyle(path)` must exist;
**`importStyle` can be fully INERT** — the probe imported 24 `.otui` files as
no-ops and nothing broke, because vBot only ever reaches widgets by *name*, and
a permissive widget answers any name.

### 4.2 Big win: otclient's own Lua is reusable verbatim

These files loaded unmodified into the probe's globals and are pure Lua with no
C++ dependency other than the singletons:

```
modules/corelib/string.lua   table.lua   math.lua   json.lua   const.lua   bitwise.lua
modules/gamelib/const.lua  position.lua  player.lua  creature.lua
                textmessages.lua  spells.lua  items.lua  thing.lua  tile.lua  util.lua
```

They supply `string:split/trim/starts/ends`, `table.find/copy/…`, `json.encode/decode`,
`PlayerStates`, `Bit`, `MessageModes`, `SpellInfo`, `Position` helpers, `postoTable`,
`getDistanceBetween` — all of which vBot and the `game_bot` `functions/` files
read directly from `_G`. **Do not re-implement these; load them.** Ordering
matters: define `tr`, `Thing`, `Creature`, `Item`, `g_game`, … *before* loading
gamelib (blocker #5 above).

Likewise `mods/game_bot/functions/*.lua` and `mods/game_bot/panels/*.lua`
(27 files: `macro`, `UI.*`, `storage`, `schedule`, `onPlayerPositionChange`, …)
are pure Lua and were loaded **unchanged**. The shim should keep doing that
rather than reimplementing the vBot-facing API — it *is* the vBot-facing API.

### 4.3 The game-state surface actually needed

Trivially small at import. At tick time (5 forced ticks over 48 macros) the
probe hit only:

- `g_game`: `isOnline`, `getLocalPlayer`, `getContainers` (21), `getClientVersion`,
  `getFeature`, `isAttacking` (10), `cancelAttackAndFollow`, `imbuementDurations`,
  `enableTileThingLuaCallback`
- `g_map`: `getSpectators` (11), `getSpectatorsByPattern`
- `Creature`: `getName`, `getPosition`, `getHealthPercent`, `isDead`, `getRegenerationTime`
- `Item.create(id[,count])` — 185 calls, all from UI item slots
- `g_settings.getNumber`, `g_resources.*`, `regexMatch`

That is far less than the full inventory the other work items are compiling,
because most macros short-circuit on the user's real (mostly disabled) config.
It is nevertheless the correct **priority order**: these are the ones that fire
on tick 1.

### 4.4 Return-shape traps found empirically

The probe proves these by crashing when the shape is wrong:

- `Creature:getRegenerationTime()` is **compared with a number** (`eat_food.lua:36`) → must be a number, not nil, not an object.
- `modules.game_npctrade.getSellExceptions()` is **`ipairs`'d** (`depositer_config.lua:185`) → must be a table.
- `modules.game_minimap.getMiniMapUi()` is **indexed** (`cavebot/minimap.lua:26`) → must be a widget.
- `g_ui.loadUIFromString()` is indexed by child name and `:setId()`/`:setColor()`'d → must be a widget.
- `Item.create()` result is passed to `widget:setItem()` → must be an object.
- `modules.game_inventory.getSlot5()` → `.count:setText()` → widget with a `count` child.
- `TabBar.buttonsPanel:getChildren()[v]` → getChildren must be indexable beyond its array part.

### 4.5 Silent-wrongness risks the probe surfaced (important)

An "anything" object makes code *run* while quietly producing garbage. Three
places where the real shim must supply real data or vBot will silently misbehave:

1. **`modules.game_spelllist.SpellInfo` / `.Spells` / `.SpelllistSettings` /
   `.getSpelllistProfile`, and `modules.gamelib.SpellInfo`** — read at
   `vBot/AttackBot.lua:182, 201-208, 2041-2047, 2097-2098` and `vBot/vlib.lua`.
   AttackBot reverse-looks-up a spell by its `.words` to get an icon/mana/exhaustion.
   With the permissive shim these silently resolve to empty tables and the spell
   picker degrades. Good news: `modules/game_spelllist/spelllist.lua` and
   `modules/gamelib/spells.lua` are **pure-Lua data** and can be loaded verbatim.
2. **`modules.game_console.channels`** — iterated by `functions/player.lua:73`
   (`getChannelId`). Must be a real `{id → name}` map; the client already has
   channels in `game/state.lua`.
3. **`configDir .. "/targetbot_configs/<name>.json"`** — read at *import* by
   `vBot/new_cavebot_lib.lua:31`. `g_resources.readFileContents` must be a real
   VFS over `profiles/bot/<config>/`, not a stub. This is the one file the probe
   failed to supply (because a combobox stub returned the wrong name), and it is
   a genuine load-time data dependency.

### 4.6 Nothing looks like a BLOCKER

No file needed a C++-only capability to *load*. The three macro failures under
forced ticks are all shim-shape issues, not headless impossibilities:

| macro | error | cause |
|---|---|---|
| `Eat Food` | `attempt to compare number with table` | `getRegenerationTime()` shape (§4.4) |
| `Send message on trade` | `functions/player.lua:74 attempt to call method 'lower'` | probe forced an *off* macro to run with an unset channel name; `getChannelId(nil)` |
| `ripper spectre switch` | `attempt to index a nil value` | a user-authored macro from `storage.ingame_hotkeys`, also force-enabled |

Two of the three only fired because the probe force-enables disabled macros.

---

## 5. Honest estimate of remaining work

What the probe did **not** do: it never connected, never had a real map, never
had real containers, and every widget getter returned a fixed value. So "45/48
macros ran without error" means "no crash", not "did the right thing".

| item | estimate | notes |
|---|---|---|
| `UIWidget` stand-in (57 methods, stateful for the ~12 getters that pair with setters, memoised children) | **1–1.5 days** | biggest single piece; mostly mechanical |
| `g_ui` (`createWidget`, `loadUIFromString`, `getRootWidget`, `importStyle` inert) + a `.otui`-name→style registry good enough that `getChildById` finds the right children | 0.5 day | `importStyle` can stay inert; only names matter |
| Wire otclient's pure Lua (corelib + gamelib + game_spelllist data) into the shim's `_G`, in the right order | 0.5 day | already proven to work verbatim |
| Load `mods/game_bot/functions/*` + `panels/*` unchanged and drive `executeBot` from `main.lua` | 0.5 day | already proven; needs `dofiles`, VFS, `g_clock`, `json` |
| `g_resources` VFS over `profiles/bot/<config>` incl. `listDirectoryFiles(dir, fullPath, raw, recursive)` and `writeFileContents` for config saves | 0.5 day | probe's FFI `FindFirstFileA` version is reusable |
| `g_game` / `g_map` / `Creature` / `Item` / `Tile` / `Container` over `game/state.lua` + `proto/sender.lua` | **3–5 days** | the real work; scope is the other work items' inventory, not this probe's 20 paths |
| Callback plumbing: map `proto/parser.lua` events onto the 40 `context._callbacks.*` names in `executor.lua:36-79` | 1 day | 1:1 rename mostly |
| `scheduleEvent`/`addEvent`/`removeEvent` over `lib/sched.lua`, `connect`/`signalcall`, `g_settings`, `HTTP`, `g_keyboard`/`g_mouse` inert | 0.5 day | |
| Get from "loads + ticks" to "actually plays" (walking, looting, healing verified against a live or replayed server) | **1–2 weeks** | dominated by g_map/pathfinding fidelity, not by API count |

**Load + tick: ~3–4 days.** Functionally correct bot: **2–3 weeks**, and the
long pole is `g_map`/`Tile`/`Container` fidelity, not the shim's breadth.

Recommended build order, straight from the evidence: widget → `g_ui` →
reuse otclient's pure Lua → VFS/`g_clock`/`json` → `executeBot` boot →
`g_game`+`Creature` → `g_map`+`Tile` → callbacks → `Item`/`Container`.
