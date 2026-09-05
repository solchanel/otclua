# A3 — Platform / framework surface + module graph (vBot 4.8 shim inventory)

Scope of this document (work item **A3**): everything vBot 4.8 and the `game_bot` runtime need from the
**platform singletons** (`g_settings`, `g_resources`, `g_clock`, `g_platform`, `g_window`, `g_keyboard`,
`g_mouse`, `g_sounds`, `g_logger`, `g_crypt`, `g_http`/`HTTP`, `g_configs`, `g_app`), the **corelib global
helpers** (event scheduling, `connect`/`disconnect`/`signalcall`, `json`, `string.*`/`table.*`/`math.*`
extensions, `regexMatch`, `tr`, `print`), the **`modules.*` module graph**, the **client-callback wiring in
`bot.lua` / `functions/callbacks.lua`**, and the **load order** the shim must reproduce.

Out of scope here (other work items): `g_game`, `g_map`, `g_things`, `g_ui` / `UIWidget`, `Creature`/`Item`/
`Tile`/`Container` classes, the `Position`/`Directions` constants, and the sandbox game helpers
(`macro`, `schedule`, `findItem`, …) except where they touch a platform primitive.

## 0. Search corpus and counting rules

| Root | Meaning |
|---|---|
| `D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8` | the user's live profile — **the code that must run verbatim** |
| `D:/Claude/otclient_mehah1530/otclient/mods/game_bot` | the runtime that builds the sandbox — **the code the shim replaces** |
| `D:/Claude/otclient_mehah1530/otclient/modules` | otclient Lua modules vBot reaches into |
| `D:/Claude/otclient_mehah1530/otclient/src` | the C++ behind every `g_*` |

Two exclusions applied to every count below, because these files are **never executed**:

* `profiles/bot/vBot_4.8/**/*.bak-*` — `_Loader.lua` dofiles a hard-coded name list
  (`profiles/bot/vBot_4.8/_Loader.lua:16-59`); `.bak-*` files are not in it, and `executor.lua:3` only
  scans the **top level** of `/bot/<config>` (non-recursive), which contains only `_Loader.lua`.
* `mods/game_bot/default_configs/vBot_4.8/**` — a stale byte-copy of the profile, only used to seed a
  fresh `/bot` dir (`bot.lua:392-404`). The shim does not need `createDefaultConfigs` at all.

Raw `g_*` token counts over the executed corpus:

| symbol | vBot_4.8 | game_bot | owned by |
|---|---:|---:|---|
| `g_game` | 232 | 314 | other item |
| `g_map` | 81 | 100 | other item |
| `g_ui` | 28 | 69 | other item |
| `g_resources` | 16 | 89 | **A3** |
| `g_window` | 10 | 13 | **A3** |
| `g_things` | 8 | 10 | other item |
| `g_platform` | 7 | 16 | **A3** |
| `g_console` (local alias of `modules.game_console`) | 6 | 6 | **A3** |
| `g_attachedEffects` | 4 | 4 | other item |
| `g_clock` | 0 | 15 | **A3** |
| `g_settings` | 1 | 11 | **A3** |
| `g_keyboard` | 1 | 4 | **A3** |
| `g_app` | 1 | 5 | **A3** |
| `g_sounds` | 0 | 6 | **A3** |
| `g_logger` | 0 | 4 | **A3** |
| `g_http` | 0 | 2 | **A3** |
| `g_mouse` | 0 | 2 | **A3** |
| `g_crypt` | 0 | 0 | — (unused) |
| `g_configs` | 0 | 0 | — (only `modules/corelib/settings.lua:1`) |

---

## 1. Hard structural fact: the sandbox has **no** `__index` to `_G`

`mods/game_bot/executor.lua:114-116` builds every bot chunk with
`load(source, name, nil, context)` where `context` is a **plain table with no metatable**. Therefore the
only globals vBot can see are the ~319 keys explicitly assigned onto `context` by `executor.lua`,
`functions/*.lua` and `panels/*.lua`.

Consequences the shim must honour exactly:

* `connect`, `disconnect`, `signalcall`, `scheduleEvent`, `removeEvent`, `cycleEvent`, `rootWidget`,
  `SpellInfo`, `Spells`, `SpelllistSettings`, `getSpelllistProfile`, `g_clock`, `g_logger`, `g_http`,
  `g_app`, `g_console` are **NOT** visible to vBot as bare globals.
* vBot therefore reaches the real ones through the module graph
  (`modules.game_bot.connect`, `modules.game_bot.g_app`, `modules.game_spelllist.SpellInfo`,
  `modules.gamelib.SpellInfo`, …) — see §5. Every `modules.<name>` table in otclient is a
  *sandbox env* whose metatable `__index` points at the global environment
  (`src/framework/luaengine/luainterface.cpp:554-562` `newSandboxEnv()`, used by
  `src/framework/core/module.cpp:30`), and `modules` itself is `package.loaded`
  (`modules/corelib/globals.lua:4`).
  **The shim must reproduce that: `modules.X` = table with `setmetatable({}, {__index = SHIM_G})`.**
* Anything vBot assigns at top level lands in `context`, not in `_G`.

---

## 2. `g_resources` — virtual filesystem

vBot stores **every** persistent thing through `g_resources`: bot storage, HealBot/AttackBot/Supplies
configs, cavebot `.cfg` routes, targetbot `.json` profiles. This is the single most load-bearing
platform singleton in A3's scope.

### 2.1 Path model

* PhysFS virtual FS. `/bot/...` resolves under the **write dir**.
  `ResourceManager::setupUserWriteDir` (`src/framework/core/resourcemanager.cpp:385-410`) honours
  `--user-dir`; for this user the write dir is `…/otclient/profiles/`, so
  `/bot/vBot_4.8` == `D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8`.
  `g_resources.getWriteDir()` **keeps its trailing `/`** (comment at resourcemanager.cpp:403-408) because
  callers concatenate directly (`mods/game_bot/edit.otui:158,168`).
* `resolvePath` (`resourcemanager.cpp:~"std::string ResourceManager::resolvePath"`):
  * path starting with `/` → used as-is;
  * otherwise prefixed with `"/" + g_lua.getCurrentSourcePath() + "/"` (the *directory of the currently
    executing chunk*);
  * finally **all `//` are collapsed to `/`**.
  The `//` rule is load-bearing: `_Loader.lua:13` calls `dofile("/vBot/main.lua")` and
  `executor.lua:115` builds `"/bot/" .. config .. "/" .. file` → `"/bot/vBot_4.8//vBot/main.lua"`.
  A shim that does not collapse `//` fails at the very first script.
  The relative branch matters for exactly one live call: `vBot/alarms.lua:122`
  `g_resources.fileExists("sounds/magnum.ogg")` — chunkname is `/vBot/alarms.lua`, so it resolves to
  `/vBot/sounds/magnum.ogg`, which does not exist. Returning `false` is correct and is what the real
  client does.

### 2.2 Inventory

| Symbol | Signature (C++ `resourcemanager.h`) | Call sites | Must return | Verdict |
|---|---|---|---|---|
| `g_resources.listDirectoryFiles(dir, fullPath=false, raw=false, recursive=false)` | `std::list<std::string>` | `_Loader.lua:4`; `executor.lua:3`; `bot.lua:180,359,372,393,459,464`; `functions/config.lua:26` (vBot 1 / game_bot 8) | Lua array of names (or full paths when `fullPath`), **`files.sort()`-ed lexicographically** (resourcemanager.cpp `listDirectoryFiles`), directories included as bare entries; empty table when dir missing | **IMPLEMENT** (sort order is load-bearing: it fixes `.otui` import order in `_Loader.lua:4-9` and the top-level lua order in `executor.lua:3-14`) |
| `g_resources.fileExists(path)` | `bool` | vBot 6 (`alarms.lua:122`, `targetbot/target.lua:226`, `cavebot/cavebot.lua:555`, `vBot/configs.lua:31,42,53`), game_bot 12 | `true` only for **regular files** | **IMPLEMENT** |
| `g_resources.directoryExists(path)` | `bool` | vBot 2 (`vBot/configs.lua:8,15`), game_bot 13 | `true` only for **directories** — `bot.lua:461-469` and `bot.lua:377` rely on `fileExists` vs `directoryExists` discriminating | **IMPLEMENT** |
| `g_resources.makeDir(path)` | `bool` | vBot 2 (`configs.lua:9,16`), game_bot 7 | create dir recursively, `true` on success | **IMPLEMENT** |
| `g_resources.readFileContents(path)` | `std::string`, **throws** on missing file | vBot 4 (`configs.lua:33,44,55`, `new_cavebot_lib.lua:31`), game_bot 14 (incl. `executor.lua:109,115,185,189`, `script_loader.lua:15,19`) | file bytes as a Lua string; **must raise a Lua error when the file is absent** (callers wrap in `pcall`, e.g. `bot.lua:275`, `configs.lua:32`) | **IMPLEMENT** |
| `g_resources.writeFileContents(path, data)` | `bool` | vBot 1 (`configs.lua:96`), game_bot 7 | write + create parents; `true` on success | **IMPLEMENT** |
| `g_resources.deleteFile(path)` | `bool` | game_bot 3 (`bot.lua:477`, `functions/config.lua:117,122`) | delete file **or directory tree** (`bot.lua:477` comment "also delete dirs") | **IMPLEMENT** |
| `g_resources.getWriteDir()` | `std::string` (trailing `/`) | game_bot 5 (`bot.lua:216,482,494`, `edit.otui:158,168`) | the writable root, trailing `/` | **STATEFUL STUB** (constant string) |
| `g_resources.createArchive(map)` | `std::string` (zip) | `bot.lua:472` only | zip blob | **INERT STUB** — only reachable from the config-upload UI the shim drops |
| `g_resources.decompressArchive(dataOrPath)` | `map<string,string>` | `bot.lua:479` only | — | **INERT STUB** — same |
| `g_resources.getRealDir/getRealPath/resolvePath/getFileTime/fileChecksum/...` | — | **0 call sites** in the executed corpus | — | omit |

### 2.3 Concrete on-disk layout the shim must serve

```
/bot/vBot_4.8/_Loader.lua
/bot/vBot_4.8/vBot/*.lua  *.otui           (loaded by _Loader)
/bot/vBot_4.8/cavebot/*.lua *.otui         (chained from vBot/cavebot.lua)
/bot/vBot_4.8/targetbot/*.lua *.otui       (chained from vBot/cavebot.lua)
/bot/vBot_4.8/navibot/*.lua *.otui         (chained from vBot/navibot.lua)
/bot/vBot_4.8/storage/profile_1.json       (bot storage; bot.lua:268-282,320)
/bot/vBot_4.8/vBot_configs/profile_1..10/{HealBot,AttackBot,Supplies}.json   (vBot/configs.lua:13-27)
/bot/vBot_4.8/cavebot_configs/*.cfg        (Config.load; cavebot/cavebot.lua:555)
/bot/vBot_4.8/targetbot_configs/*.json     (Config.load; targetbot/target.lua:226, new_cavebot_lib.lua:30)
```

---

## 3. Platform singletons other than `g_resources`

### 3.1 `g_settings`

`g_settings = makesingleton(g_configs.getSettings())` (`modules/corelib/settings.lua:1`) —
a `Config` userdata wrapped by `makesingleton` (`modules/corelib/util.lua:376-388`), with the Lua-side
sugar in `modules/corelib/config.lua` layered on the C++ `Config` bindings
(`src/framework/luafunctions.cpp:330-344`).

| Call | Site | Must return | Verdict |
|---|---|---|---|
| `g_settings.getNumber('profile')` | **`vBot/configs.lua:20`** (the only vBot call), `bot.lua:273` | **`1`** by default — `modules/client_options/data_options.lua:616-618` declares `profile = {value = 1}`; `Config:getNumber` = `tonumber(get(k,default)) or 0` (`config.lua:48-51`). Returning 0 would point vBot at a non-existent `profile_0` dir and silently reset every HealBot/AttackBot/Supplies config. | **STATEFUL STUB** — return a configurable integer, default **1** |
| `g_settings.getNode('bot')` / `setNode('bot', t)` / `save()` | `bot.lua:186,221,241-249,303` | the per-character `{[charName_version] = {enabled=, config=}}` node | **INERT** — the shim replaces `bot.lua`; the config name comes from CLI/config instead |

### 3.2 `g_clock`

| Call | Sites | Semantics | Verdict |
|---|---|---|---|
| `g_clock.millis()` | `executor.lua:166,167,196,197,212`; `bot.lua:505,543`; `functions/main.lua:197`; `functions/player.lua:55`; `game_cooldown/cooldown.lua:64,524,533,589` | **frame-quantised**: `Clock::millis()` returns `m_currentMillis`, updated once per application frame by `Clock::update()` (`src/framework/core/clock.h:32`). It is *constant for the whole bot tick*. | **IMPLEMENT** — cache a monotonic ms value refreshed once per scheduler turn (`lib/sys.lua:nowMs`), so `context.now` and any direct `g_clock.millis()` inside the same tick agree |
| `g_clock.realMillis()` | `functions/callbacks.lua:23,25`; `functions/main.lua:116,118,170,172` | live wall clock; used only for the "Slow macro (Nms)" warnings | **IMPLEMENT** — direct `sys.nowMs()` |
| `g_clock.micros/seconds/realMicros` | 0 sites | — | omit |

`context.now` / `context.time` are set from `g_clock.millis()` at the top of every executor tick
(`executor.lua:196-197`), and the tick is driven by `scheduleEvent(check, 10)` (`bot.lua:531`).
**vBot compares `now - x` in hundreds of places and assumes `now` is stable for the duration of one
tick** — do not make `now` a live read.

### 3.3 `g_platform`

The sandbox only exposes two of its methods (`executor.lua:141-144`):
`context.g_platform = { openUrl = g_platform.openUrl, openDir = g_platform.openDir }`.

| Call | Sites | Verdict |
|---|---|---|
| `g_platform.openUrl(url)` | `vBot/main.lua:4`, `vBot/playerlist.lua:225,277,327`, plus 6 `.otui` `@onClick` handlers | **INERT STUB** (no browser headless) |
| `g_platform.openDir(path)` | `mods/game_bot/edit.otui:168` only | **INERT STUB** |
| everything else (`isMobile`, `getOSName`, …) | 0 sites in the sandbox | omit |

### 3.4 `g_window`

| Call | Sites | Verdict |
|---|---|---|
| `g_window.setTitle(text)` | `vBot/alarms.lua:130`, `vBot/extras.lua:165,167,170` | **INERT STUB** (or forward to the control-plane status line — cheap and useful) |
| `g_window.setClipboardText(text)` | `vBot/analyzer.lua:194`, `vBot/playerlist.lua:228,280,330` | **STATEFUL STUB** — keep the last value; nothing reads it back except `getClipboardText`, which has 0 sites |
| `g_window.flash()` | `vBot/alarms.lua:128` | **INERT STUB. NOTE: this method does not exist in this otclient fork** (no `flash` binding in `src/framework/luafunctions.cpp` and no `PlatformWindow::flash`), so the live client *errors* on this line whenever `config.flashClient.enabled` and `getOs()=="windows"`. Providing a no-op is strictly a fix. |
| `g_window.getMousePosition()` | `mods/game_bot/functions/map.lua:240` (`getTileUnderCursor`) | **INERT STUB** returning `{x=0,y=0}` — headless there is no cursor; `getTileUnderCursor` then yields `nil` |
| `g_window.isKeyPressed(code)` | via `g_keyboard.isKeyPressed` (`modules/corelib/keyboard.lua:324-329`) | **INERT STUB** returning `false` |
| `g_window.setKeyDelay` | via `g_keyboard.setKeyDelay`, 0 live sites | omit |

### 3.5 `g_keyboard`

| Call | Sites | Verdict |
|---|---|---|
| `g_keyboard.isKeyPressed(v)` | **`vBot/Equipper.lua:590`** (Equipper condition type 9 "key pressed") | **INERT STUB → `false`**. Condition 9 simply never fires headless. |
| `g_keyboard.isCtrlPressed()` | `mods/game_bot/functions/icon.lua:116` (icon drag) | **INERT STUB → `false`** |

Related corelib globals (used by `macro`/`hotkey`, not by vBot directly):

| Symbol | Where | Verdict |
|---|---|---|
| `retranslateKeyComboDesc(desc)` | `functions/main.lua:34,140` — invoked for named-with-hotkey macros and for `hotkey()`. In the live profile there are **0 macros with a hotkey** and exactly **1 `hotkey()` call**: `vBot/extras.lua:209` `hotkey(settings.useAll, …)` with default `"space"`. | **STATEFUL STUB** — canonicalise the string (uppercase, `Ctrl+`/`Shift+`/`Alt+` ordering) and return it; it is only used as a table key. Requires `KeyCodeDescs`/`resolveKeyAlias` only if you want fidelity. |
| `determineKeyComboDesc(keyCode, mods)` | `executor.lua:224,246,258` — only reached from `botKeyDown/Up/Press` | **INERT** — the shim never delivers key events (no `rootWidget`) |

### 3.6 `g_mouse`

`context.g_mouse = g_mouse` (`executor.lua:137`) but there are **0 `g_mouse.*` call sites** in either the
profile or the runtime. **Omit** (or bind an empty table).

### 3.7 `g_sounds`

| Call | Sites | Verdict |
|---|---|---|
| `g_sounds.getChannel(SoundChannels.Bot)` | `bot.lua:153`, `functions/sound.lua:7` | **INERT STUB**. **`SoundChannels` (`modules/corelib/const.lua:338-342`) only defines `Music=1, Ambient=2, Effect=3` — there is no `Bot` key**, so the live client already passes `nil`. Return a table with no-op `play/stop/setEnabled/setGain/isEnabled`. |
| `channel:play(file, fadetime, gain)` / `:stop([fade])` / `:setEnabled(b)` | `functions/sound.lua:15-27` | **INERT** |
| `playSound(file)` (sandbox global) | **`vBot/alarms.lua:131`** — the only vBot audio call | **INERT** |
| `playAlarm`, `stopSound`, `getSoundChannel` | 0 vBot sites | **INERT** |

### 3.8 `g_logger`

Bindings: `src/framework/luafunctions.cpp:195-205` (`log(level,msg)`, `debug/info/warning/error/fatal`,
`setLevel`, `getLevel`, `setLogFile`, `setOnLog`).

| Call | Sites | Verdict |
|---|---|---|
| `g_logger.error/warning/info(msg)` | `bot.lua:355,509,513,517` (the `message()` sink behind sandbox `error()`/`warn()`/`info()`) | **IMPLEMENT** — map straight onto `lib/log.lua` (`log.error/warn/info`). vBot calls `warn()`/`error()`/`info()` constantly; this is the shim's only diagnostic channel. |
| `g_logger.log(LogInfo, msg)` via corelib `print` (`modules/corelib/util.lua:2-13`) | `context.print = print` (`executor.lua:83`); **~90 `print(` call sites across the profile** | **IMPLEMENT** — `print` must join the same log; note corelib's `print` joins multiple args with **four spaces**, not a tab |
| `pinfo/perror/pwarning/pdebug` | used by `signalcall`/`connect` error paths | **IMPLEMENT** (thin wrappers) |

### 3.9 `g_crypt`, `g_configs`

**0 call sites** anywhere in the executed corpus (`g_configs` appears only inside
`modules/corelib/settings.lua:1`, which the shim replaces with a literal table). **Omit both.**

### 3.10 `g_app`

| Call | Sites | Real binding | Verdict |
|---|---|---|---|
| `g_app.getOs()` — reached as **`modules.game_bot.g_app.getOs()`** | **`vBot/alarms.lua:127`** | `luafunctions.cpp:157` → `Application::getOs()`, string | **STATEFUL STUB** → `"windows"` |
| `g_app.getVersion()` | `executor.lua:128`, `functions/tools.lua:18` | `luafunctions.cpp:150` | **STATEFUL STUB** → version string |
| `g_app.doScreenshot(file)` | `functions/tools.lua:13` | `luafunctions.cpp:408` (GraphicalApplication) | **INERT STUB** |
| `g_app.isMobile` | `executor.lua:127` | **not bound on `g_app`** (it is `g_platform.isMobile`) → already `nil` in the live client | **omit / nil** |

---

## 4. corelib globals and stdlib extensions

### 4.1 Event scheduling (`modules/corelib/globals.lua`)

| Symbol | Definition | Sites in executed corpus | Verdict |
|---|---|---|---|
| `scheduleEvent(cb, delayMs)` | `globals.lua:23-34` → `g_dispatcher.scheduleEventEx`; returns an **event object with `:cancel()`** and a `_callback` field | `bot.lua:342,531`; `functions/server.lua:36`; `modules/game_textmessage/textmessage.lua:307`; `modules/client_terminal/terminal.lua:368` | **IMPLEMENT** on `lib/sched.lua:after` — must return an object supporting `:cancel()` |
| `removeEvent(event)` | `globals.lua:110-115` — `event:cancel(); event._callback = nil`; **tolerates `nil`** | `bot.lua:112,526` and throughout otclient modules the shim reimplements | **IMPLEMENT** |
| `cycleEvent(cb, intervalMs)` | `globals.lua:49-60` | **0 sites** in the executed corpus | omit (or trivial `sched.every`) |
| `addEvent`, `deferEvent`, `periodicalEvent` | `globals.lua:36-108` | 0 sites | omit |

vBot itself never calls these — it uses the sandbox `schedule(ms, fn)`
(`functions/main.lua:196-203`), which is a plain sorted array drained inside `executor.lua:212-220`.
The shim must still provide `scheduleEvent`/`removeEvent` as **real globals** (not sandbox keys) because
they are used by the shim's own replacements for `bot.lua` and `functions/server.lua`.

### 4.2 `connect` / `disconnect` / `signalcall`

`modules/corelib/util.lua:42-119` (`connect`/`disconnect`) and `util.lua:330-353` (`signalcall`).

`connect(object, {signal = slot, …}, pushFront)` semantics the shim must reproduce **exactly**:

1. If `object[signal]` is nil **and** `object` is userdata with a metatable, it first installs a
   forwarder `function(...) return signalcall(mt[signal], ...) end` (util.lua:59-66) — this is what makes
   *class-level* `connect(Creature, {...})` work.
2. Then: nil → store the slot as a bare function; already a function → promote to a one-element list;
   list → `table.insert` (front if `pushFront`).
3. `disconnect` reverses it, collapsing a 1-element list back to a bare function (util.lua:107-114).
4. `signalcall(param, ...)` pcalls a function or every entry of a list; returns `true` as soon as any
   slot returns truthy; `perror`s on failure and keeps going.

| Site | What connects | Verdict |
|---|---|---|
| `bot.lua:31,98` | `g_game` `onGameStart/onGameEnd` | shim replaces `bot.lua` — **IMPLEMENT** the primitive, rewrite the caller |
| `bot.lua:550-613` / `616-675` | the whole client-callback wiring (see §6) | **IMPLEMENT** |
| **`vBot/AttackBot.lua:86`** `modules.game_bot.connect(g_game, {onSpellCooldown=…, onSpellGroupCooldown=…})` | vBot's real-cooldown cache | **IMPLEMENT** — `modules.game_bot.connect` must resolve (via the sandbox-env `__index`) to the real `connect`; the file explicitly notes `connect` is not a sandbox global |
| **`cavebot/imbuing.lua:145`** `modules.game_bot.connect(g_game, {onUpdateImbuementTracker=…})` | imbuement tracker cache | **IMPLEMENT**; `g_game.onUpdateImbuementTracker` must be a signal slot the parser fires (opcode 0xEE-family) or the tracker stays empty (the file already warns and degrades) |
| **`cavebot/stand_lure.lua:167`** `modules.game_bot.connect(CaveBotList(), {onChildFocusChange=…})` | UI widget signal | **IMPLEMENT** the primitive; the widget signal itself is a UI item |
| `disconnect` | 0 vBot sites | **IMPLEMENT** anyway (used by shim teardown) |
| `signalcall` | 0 direct sites; reached from `connect`'s forwarder | **IMPLEMENT** |

### 4.3 `json`

`modules/corelib/json.lua` is **rxi/json.lua 0.1.2, byte-identical to
`D:/Claude/otclient_web/luaclient/lib/json.lua`** except that corelib assigns a global `json` while the
luaclient version returns a local module table (verified by `diff` — the only differences are the
declaration line and an added comment). `json.encode(val)` ignores a second argument, so the
`json.encode(x, 2)` calls (`bot.lua:310`, `functions/config.lua:108`, `vBot/configs.lua:86`,
`functions/tools.lua:3`) behave identically.

**Verdict: DROP-IN.** `context.json = require('lib.json')`. Same `decode` error messages, same
`"sparse array"`/`"unexpected type"` errors that the surrounding `pcall`s expect.

### 4.4 `string.*` extensions (`modules/corelib/string.lua`)

Plain LuaJIT has none of these. The sandbox receives the **patched global `string` table**
(`executor.lua:92`), so the shim must patch `string` **before** building the context.

| Extension | Definition | Live call sites | Verdict |
|---|---|---|---|
| `string:split(delim)` (plain find, **drops empty strings** via `table.removevalue(results,'')`) | `string.lua:2-16` | 38 total — `string.split(...)` ×30 (`navibot.lua:322`; `analyzer.lua:638,883,1329`; `alarms.lua:145,208`; `AttackBot.lua:2229`; `combo.lua:282,290`; `new_healer.lua:652`; `playerlist.lua:247,345,346`; `Stances.lua:351`; `cavebot/{buy_supplies:24,actions:283,clear_tile:5,bank:7,d_withdraw:6,doors:5,inbox_withdraw:5,pos_check:8,route_tools:61,130,sell_all:6,supply_check:64,stand_lure:50,travel:5,withdraw:6,tasker:39}`) and `x:split(...)` ×8 (`_Loader.lua:6`; `executor.lua:7`; `bot.lua:374,486`; `cavebot/actions.lua:197,244`) | **IMPLEMENT — exact semantics.** `cavebot/actions.lua:195-197` has an explicit comment relying on the empty-string drop making `[1]` nil. |
| `string:trim()` (`string.match(s,'^%s*(.*%S)') or ''`) | `string.lua:26-28` | 20 (`navibot.lua:112,144,200,322,602`; `alarms.lua:149,211`; `AttackBot.lua:1299,1586,1974,2055,2250,2252`; `targetbot/creature_editor.lua:71`, `targetbot/creature.lua:27,55`; `game_bot/panels/{attacking:564,waypoints:179,looting:107}`; `functions/server.lua:186`) | **IMPLEMENT** |
| `string.starts(s, prefix)` | `string.lua:18-20` | 9 (dotted form only) | **IMPLEMENT** |
| `string.empty`, `string.capitalize`, `string:ends`, `string:explode`, `string:contains`, `string:wrap`, `string.pack_custom`, `string.unpack_custom` | `string.lua:22-24,29-77,78-190` | **0 live sites** | omit |

### 4.5 `table.*` extensions (`modules/corelib/table.lua`)

| Extension | Live count | Verdict |
|---|---:|---|
| `table.find(t, value[, ...])` (`table.lua:74-86`) | **80** — the single most used corelib extension in vBot | **IMPLEMENT** |
| `table.removevalue(t, v)` (`table.lua:118-127`) | 3 (+ used internally by `string:split` and `game_walk`) | **IMPLEMENT** |
| `table.decodeStringPairList(str)` (`table.lua:291-...`) | 2 (`functions/config.lua:72,47`) — **parses the `.cfg` cavebot route format** | **IMPLEMENT** — note it calls `regexMatch(l, "(?:^|\\n)([^:^\n]{1,20}):?(.*)(?:$|\\n)")` at `table.lua:293`, so it inherits the `regexMatch` dependency (§4.7) |
| `table.encodeStringPairList(t)` (`table.lua:279-290`) | 1 (`functions/config.lua:106`) | **IMPLEMENT** |
| `table.isStringPairList(t)` (`table.lua:269-278`) | 1 (`functions/config.lua:105`) — decides `.cfg` vs `.json` on save | **IMPLEMENT** |
| `table.isList` (`table.lua:254-258`) | 1 | **IMPLEMENT** |
| `table.copy`, `table.merge`, `table.contains`, `table.size`, `table.empty`, `table.equals`, `table.dump`, `table.compare`, `table.recursivecopy`, `table.insertall`, `table.remove_if`, … | **0 live sites** | omit |

Stock LuaJIT `table.insert` (129), `table.remove` (32), `table.sort` (10), `table.concat` (8) are used
as-is.

### 4.6 `math.*`

Only stock functions are used: `abs` 68, `max` 49, `floor` 42, `min` 22, `ceil` 14, `random` 11,
`huge` 3, `randomseed` 1, `fmod` 1. corelib's `math.round/isu8/isu16/isu32/isu64/isinteger`
(`modules/corelib/math.lua`) have **0 live sites**. **No work needed.**

### 4.7 `regexMatch` — the one genuinely hard global

`src/framework/luafunctions.cpp:95-113`:

```
regexMatch(subject, pattern) -> { {full, cap1, cap2, ...}, {full, cap1, ...}, ... }
```
* `std::regex` with `std::regex::ECMAScript`.
* Iterates `regex_search` over successive suffixes, **max 10 000 matches**.
* Each result row is `m[0]` (the whole match) followed by every capture group, **as strings**;
  an unmatched optional group yields `""`.
* Empty subject or empty pattern → empty table.
* **Wrapped in `catch (...)`: an invalid pattern returns an empty table and never raises.**

44 live call sites. vBot: `targetbot/creature.lua:62` (creature-name matching — the hottest one, called
per creature per tick), `cavebot/antilost.lua:213,219,227,253,257,262,639,644`,
`cavebot/actions.lua:346,546,583`, `cavebot/cavebot.lua:43,48,362,383,439,485`,
`cavebot/tasker.lua:166-169`, `vBot/analyzer.lua:290,871,907,912,1275,1506`,
`vBot/BotServer.lua:132,183`, `vBot/AttackBot.lua:2250,2252`, `vBot/combo.lua:232`,
`vBot/extras.lua:582`. game_bot: `panels/{waypoints:177,217,648,700,717, looting:105,161,
attacking:562,596}` and `modules/corelib/table.lua:293`.

Dialect actually exercised: `\s \d`, `[^...]` classes, `{n,m}`, `?`, `*`, `+`, `^`/`$` anchors,
capture groups, **non-capturing groups `(?:…)`** (`cavebot/cavebot.lua:362`, `table.lua:293`), and
**alternation of anchored globs** built at runtime in `targetbot/creature.lua:27` /
`creature_editor.lua:71` (`^name.*$|^other.?$`). No lookaround, no backreferences.

**Verdict: IMPLEMENT — the largest single item in A3.** Options, in order of preference:
1. A small pure-Lua ECMAScript-subset regex engine (backtracking; needs `|`, `(?:)`, classes,
   `{n,m}`, anchors, greedy/lazy quantifiers). ~400 lines.
2. LuaJIT FFI onto a bundled PCRE/`std::regex` — adds a native dependency the project has so far avoided.
3. A translator to Lua patterns — **insufficient**: Lua patterns have no alternation and no
   non-capturing groups, both of which are used.

Do **not** stub it: `targetbot/creature.lua:62` decides whether a creature is a valid target at all, and
`table.decodeStringPairList` (hence every `.cfg` cavebot route) goes through it.

### 4.8 Other corelib globals in the sandbox

| Symbol | Definition | Live use | Verdict |
|---|---|---|---|
| `tr(s, ...)` | `modules/corelib/util.lua:355-357` — **exactly `string.format`** in this fork (no locale module overrides it) | `context.tr` (`executor.lua:120`); many `.otui` handlers; a handful of Lua sites | **IMPLEMENT** = `string.format` |
| `print(...)` | `util.lua:2-13` → `g_logger.log(LogInfo, msg)`, args joined with 4 spaces | `context.print` (`executor.lua:83`); ~90 vBot sites | **IMPLEMENT** (§3.8) |
| `base64` | `modules/corelib/base64.lua` (`base64.encode/decode/...`) | `context.base64` (`executor.lua:122`); **0 vBot sites** | **INERT STUB** / omit |
| `bit` / `bit32` | LuaJIT `bit` / `bit32` | `executor.lua:84-85`; **0 vBot sites** (LuaJIT has `bit` natively; `bit32` is nil) | pass through |
| `gcinfo` | Lua 5.1 builtin | `executor.lua:119`; 0 vBot sites | pass through (LuaJIT has it) |
| `os.{time,difftime,date,clock}` | whitelisted subset (`executor.lua:96-101`) | vBot: `os.time` 20, `os.date` 6, `os.difftime` 3 | pass through unchanged |
| `dofiles(dir[, recursive[, contains]])` | `src/framework/luaengine/luainterface.cpp:599-617` — loads every `.lua` in `dir` in **sorted** order | `executor.lua:172,174` | **IMPLEMENT** (shim-internal only — used to load its own `functions/`+`panels/` replacements) |
| `makesingleton`, `resolvepath`, `toboolean`, `newclass`, `extends` | `util.lua` | 0 live sites in the sandbox | omit |
| `G` | `modules/corelib/globals.lua:7` — cross-reload global table | `executor.lua:171,175` (`G.botContext`), read by every `functions/*.lua` and `panels/*.lua` as `local context = G.botContext` | **IMPLEMENT** — a plain global table; the shim's own function modules must keep the same idiom or be rewritten together |
| `rootWidget` | `globals.lua:3` = `g_ui.getRootWidget()` | `bot.lua:550,617`; vBot **reassigns it as a sandbox key itself** (`BotServer.lua:43`, `combo.lua:67`, `Containers.lua:379`, `HealBot.lua:316`, `playerlist.lua:145`, `pushmax.lua:53`, `Sio.lua:61`) | UI item; A3 note: the *real global* `rootWidget` is only needed by the key-event wiring the shim drops |

---

## 5. The `modules.*` graph

`modules == package.loaded` (`modules/corelib/globals.lua:4`). Each `modules.<name>` is that module's
sandbox env: a table whose metatable `__index` is the global environment
(`luainterface.cpp:554-562`). **Every `modules.X.Y` lookup therefore falls back to a global `Y` when the
module itself does not define `Y`** — that is precisely how `modules.game_spelllist.SpellInfo` and
`modules.gamelib.SpellInfo` both resolve to the single global table defined in
`modules/gamelib/spells.lua:34`, and how `modules.game_bot.connect` / `modules.game_bot.g_app` resolve
to corelib/C++ globals.

**Shim rule:** build one shared globals table `SHIM_G` holding `connect`, `disconnect`, `signalcall`,
`scheduleEvent`, `removeEvent`, `g_app`, `g_clock`, `g_logger`, `SpellInfo`, `Spells`,
`SpelllistSettings`, `getSpelllistProfile`, `json`, `tr`, `regexMatch`, … and create every
`modules.<name>` as `setmetatable(<own fields>, {__index = SHIM_G})`.

### 5.1 Inventory (live profile + shim-relevant runtime sites)

| Symbol | Exact call | Sites | What the shim must do | Verdict |
|---|---|---|---|---|
| `modules.game_bot.contentsPanel.config:getCurrentOption()` `.text` | returns the config **directory name** (`"vBot_4.8"`), populated in `bot.lua:180-185` from `listDirectoryFiles("/bot")` | `_Loader.lua:2`; `vBot/configs.lua:5`; `cavebot/cavebot.lua:553`; `targetbot/target.lua:224` (4) | expose a stub combobox object whose `getCurrentOption()` returns `{text = <configName>}` | **STATEFUL STUB** |
| `modules.game_bot.connect` | corelib `connect` via env `__index` | `vBot/AttackBot.lua:86`; `cavebot/imbuing.lua:145`; `cavebot/stand_lure.lua:167` (3) | falls out of the `__index = SHIM_G` rule | **IMPLEMENT** (§4.2) |
| `modules.game_bot.g_app.getOs()` | `"windows"` | `vBot/alarms.lua:127` (1) | same `__index` rule + `g_app` stub | **STATEFUL STUB** |
| `modules.game_bot.{edit,uploadConfig,downloadConfig,onMiniWindowClose}` | — | only `mods/game_bot/*.otui` | not needed | **INERT** |
| `modules.gamelib.SpellInfo['Default']` | the global spell table (`modules/gamelib/spells.lua:34`) | **`vBot/vlib.lua:278`** — *unguarded*, at load time; `vBot/AttackBot.lua:2042` (fallback) | ship `modules/gamelib/spells.lua` verbatim as a data table in `SHIM_G` (`SpellInfo`, `Spells`, `SpelllistSettings`) | **IMPLEMENT (data port)** — a load-time BLOCKER if missing |
| `modules.game_spelllist.SpellInfo` / `.Spells` / `.SpelllistSettings` / `.getSpelllistProfile()` | same globals + `getSpelllistProfile()` (`modules/game_spelllist/spelllist.lua:64-66`, returns `SpelllistProfile`, default `'Default'`) | `vBot/AttackBot.lua:182,201,202,203,208,2041,2047,2097,2098`; `vBot/HealBot.lua:143,163,164,165,170` (24 tokens) | provide `getSpelllistProfile()` → `"Default"`; everything else via `__index` | **STATEFUL STUB** |
| `modules.game_cooldown.isCooldownIconActive(iconId)` | `cooldown.lua:530-537` | **`vBot/vlib.lua:368`** (inside `getSpellCoolDown`, called from `canCast` — the hot path for every heal/attack) + `AttackBot`/`HealBot` comments | keep a `cooldown[iconId] = millis()+duration` map fed by the `spellCooldown` event; return `millis() < deadline` | **IMPLEMENT** |
| `modules.game_cooldown.isGroupCooldownIconActive(groupId)` | `cooldown.lua:521-528` | **`vBot/vlib.lua:374`**; `vBot/exeta.lua:11`; `vBot/Sio.lua:219`; `vBot/Conditions.lua:239`; `vBot/AttackBot.lua:2840` (9 tokens) | same, keyed by group id, fed by `spellGroupCooldown` | **IMPLEMENT** |
| — *gotcha* | `cooldown.lua:542` and `:562` **`return` early when the cooldown window is not visible`**, so the live client silently never populates these tables with the window hidden | | the shim must record **unconditionally** | behaviour fix |
| `modules.game_textmessage.displayGameMessage(text)` | `textmessage.lua:320` | `vBot/vlib.lua:83` (`whiteInfoMessage`), `vBot/training.lua:322` | log at info | **INERT STUB** (log) |
| `modules.game_textmessage.displayStatusMessage / displayFailureMessage` | `textmessage.lua:312,316` | `vBot/vlib.lua:87` (`statusMessage`, 7 vBot callers) | log | **INERT STUB** |
| `modules.game_textmessage.displayBroadcastMessage` | `textmessage.lua:324` | `vBot/vlib.lua:92` (`broadcastMessage`, 2 callers) | log | **INERT STUB** |
| `modules.game_textmessage.clearMessages()` | `textmessage.lua:328` | `vBot/extras.lua:609` | no-op | **INERT STUB** |
| `modules.game_textmessage.messagesPanel.statusLabel:setVisible/:setColoredText` | widget | `vBot/analyzer.lua:958,959,965` | needs an object with `setVisible(bool)` and `setColoredText(table)` | **INERT STUB (object must exist)** |
| `modules.game_textmessage.messagesPanel.centerTextMessagePanel.highCenterLabel:getText/:setColoredText/:setVisible` | widget | `vBot/analyzer.lua:984,985,987` | `getText()` must return a string (compared with `==`) | **INERT STUB (object must exist)** |
| `modules.game_console.isEnabledWASD()` | `console.lua:565-567` → `consoleToggleChat.isChecked` | `vBot/extras.lua:210,364,505,528` (4) — gates the WASD/`useAll` hotkey handlers | return `true` (chat off ⇒ hotkeys live) or `false` (hotkeys inert). Recommend **`false`** headless, since all four sites are keyboard-driven and never fire anyway | **STATEFUL STUB** |
| `modules.game_console.channelsWindow` | widget | `vBot/combo.lua:205` — **guarded** (`if channelsWindow then`) | may be `nil` | **INERT** |
| `modules.game_console.{getTab,addTab,addPrivateText,applyMessagePrefixies,SpeakTypesSettings}` | `console.lua:853,783,889,1772,2` | `vBot/extras.lua:180-185` (aliased to a local `g_console`), inside an `onTalk` handler when `settings.separatePm` | make `getTab(name)` return non-nil (or provide all four as no-ops) so the PM branch does not error | **INERT STUB** |
| `modules.game_interface.getMapPanel()` | `interface.lua:1818-1820` | `vBot/spy_level.lua:13,19,22` — then `:unlockVisibleFloor()` / `:lockVisibleFloor(z)`; also `bot.lua:147` | return a stub with `lockVisibleFloor(z)` / `unlockVisibleFloor()` | **INERT STUB (object must exist)** |
| `modules.game_interface.getLeftPanel()/getRightPanel()/getRootPanel()/checkAndOpenLeftPanel()` | `interface.lua:1830,1822,1814,2106` | `bot.lua:42,134-145,335`; `functions/ui.lua:18` | UI containers | **INERT STUB** |
| `modules.game_interface.gameRootPanel` | widget | **`vBot/xeno_menu.lua:1`** assigns `.onMouseRelease` at **load time** — must be an assignable table or the file errors | provide a table | **INERT STUB (object must exist)** |
| `modules.game_interface.gameMapPanel` | widget | `bot.lua:134` | — | **INERT STUB** |
| `modules.game_interface.forceExit()` | `interface.lua:351-355` → `g_game.cancelLogin(); scheduleEvent(exit,10)` | **`vBot/antiRs.lua:14`** — the anti-RS panic exit | **IMPLEMENT**: disconnect + terminate the worker process | **IMPLEMENT** |
| `modules.game_interface.startUseWith(thing)` | `interface.lua:647` | `vBot/extras.lua:427` (mouse "use with" flow) | no-op | **INERT STUB** |
| `modules.game_interface.addMenuHook / removeMenuHook` | — | `vBot/analyzer.lua:1129,1131` (via `local interface = modules.game_interface`, line 1105) | no-op | **INERT STUB** |
| `modules.game_interface.lastManualWalk`, `.tryCastSpellMessage` | `interface.lua:25,479` | game_bot runtime only (`functions/player.lua`, `functions/map.lua`) | see the walking work item | **STATEFUL STUB** (`lastManualWalk` is a number) |
| `modules.game_minimap.getMiniMapUi()` | `minimap.lua:254-256` | **`cavebot/minimap.lua:1`** at load time; result gets `.onMouseRelease` assigned and `.allowNextRelease`, `.autowalk` read | return a table (assignable); the handler never fires headless | **INERT STUB (object must exist)** |
| `modules.game_inventory.getSlot5()` | `inventory.lua:512-514` | **`vBot/quiver_label.lua:1`** at load time — `local quiverSlot = modules.game_inventory.getSlot5() or ""` — already `or ""`-guarded | may return `nil` | **INERT** |
| `modules.game_skills.skillsWindow.contentsPanel.level.percent:getPercent()` | widget | `vBot/analyzer.lua:587,1718` — **unguarded, at load time** | object with `getPercent() -> number` | **STATEFUL STUB (object must exist)** — better: back it with `state.player.levelPercent` |
| `modules.game_skills.skillsWindow.contentsPanel.stamina.value:getText()` | widget | `vBot/analyzer.lua:754` | `getText() -> string` | **STATEFUL STUB** — back it with `state.player.stamina` |
| `modules.game_npctrade.getSellExceptions()` | `sell_exceptions.lua:122-130`, returns a copy of an id array | `cavebot/sell_all.lua:57-58` (guarded), `vBot/depositer_config.lua:141` (guarded) | return `{}` or a persisted list | **STATEFUL STUB** |
| `modules.game_npctrade.setSellExceptions(list)` | `sell_exceptions.lua` | `vBot/depositer_config.lua:142` (guarded) | store it | **STATEFUL STUB** |
| `modules.game_npctrade.sellAll(delayed, exceptions)` | `game_npctrader.lua:128-168` | **`cavebot/sell_all.lua:73` — UNGUARDED** | sell every sellable item in the open NPC trade, honouring `exceptions`; maps onto `sender:sellItem(id, subType, amount, ignoreEquipped)` (0x7B) plus the parsed sell list | **IMPLEMENT (thin)** — a nil `modules.game_npctrade` crashes the SellAll cavebot action |
| `modules.game_npctrade.{isTrading,getSellItems,getBuyItems,getSellQuantity,canTradeItem,closeNpcTrade}` | `game_npctrader.lua:170,178,186,194,206,241` | game_bot runtime (`functions/npc.lua`) only | back with the NPC-trade parser state | **IMPLEMENT (thin)** |
| `modules.client_textedit.show(text, options, callback)` | **`mods/client_textedit/textedit.lua:23`** (a *mod*, not a module) | `vBot/depositer_config.lua:72,90`; `vBot/new_healer.lua:1036`; `vBot/supplies.lua:250`; `vBot/analyzer.otui:39`; `cavebot/*` editors via `UI.*EditorWindow` | modal text prompt | **INERT STUB** — never invoke the callback (all sites are user-initiated UI) |
| `modules.client_textedit.{edit,singlelineEditor,multilineEditor}` | `textedit.lua:154,159,164` | `functions/ui_windows.lua`, `functions/ui_legacy.lua` | same | **INERT STUB** |
| `modules.client_terminal.addLine(text, color)` | `terminal.lua:360-368` | **`vBot/vlib.lua:17`** (`logInfo`) | forward to `lib/log.lua` at info | **INERT STUB (log)** |
| `modules.client_entergame.CharacterList.doLogin` | `characterlist.lua:973` | **`vBot/vlib.lua:36`** inside `relogOnCharacter(charName)` | needs the char-list widget tree too (`g_ui.getRootWidget().charactersWindow.characters`) | **BLOCKER (partial)** — headless relog cannot go through the char-list widget. Provide `relogOnCharacter` as a shim-native reconnect (`transport:close()` → supervisor re-login) and leave `doLogin` as a stub, or accept that `relogOnCharacter` is a no-op. |
| `modules.client_topmenu.getButton(id)` | `topmenu.lua:467-469` | `vBot/analyzer.lua:199` | return `nil` | **INERT STUB** |
| `modules.game_mainpanel.addToggleButton(id, desc, image, cb, front, index)` | `mainpanel.lua:250-252` | **`vBot/analyzer.lua:205`** — result gets `:setOn(false)` and `:destroy()` | return a stub button object with `setOn/isOn/destroy/setVisible/show/hide` | **INERT STUB (object must exist)** |
| `modules.game_mainpanel.getButton(id)` | `mainpanel.lua:262-264` | `bot.lua:256` | `nil` | **INERT STUB** |
| `modules.game_buttons.buttonsWindow.contentsPanel` | `mods/game_buttons` | **`vBot/analyzer.lua:198`** — `modules.game_buttons.buttonsWindow.contentsPanel and …` — indexes **two** levels unguarded | `modules.game_buttons = { buttonsWindow = {} }` is enough (`contentsPanel` may be nil) | **INERT STUB (object must exist)** |
| `modules.client_profiles` / `.ChangedProfile` | **module does not exist in this tree** | `bot.lua:341` (`if not (modules.client_profiles and …)`) | leave `nil` | **omit** |
| `modules.game_walk.smartWalk(dir)` | `game_walk` `walk.lua:168-170` | `mods/game_bot/functions/player.lua` (`context.walk`) | map to `sender:walk(dir)` | walking work item |
| `modules.game_outfit.ignoreNextOutfitWindow` | field | `functions/player.lua:55` (`= g_clock.millis()`) | plain assignable field | **STATEFUL STUB** |
| `modules.game_console.channels` | `console.lua:154` | `functions/player.lua` (`getChannels`) | back with `state.channels` | other item |

### 5.2 Modules that must simply **exist** (indexed unguarded at load time)

Failing to create any of these makes `_Loader` abort:

`game_bot` (with `contentsPanel.config`), `gamelib` (with `SpellInfo`), `game_cooldown`,
`game_textmessage` (with `messagesPanel.statusLabel` and
`messagesPanel.centerTextMessagePanel.highCenterLabel`), `game_console`, `game_interface`
(with `gameRootPanel`), `game_minimap`, `game_skills`
(with `skillsWindow.contentsPanel.level.percent` and `.stamina.value`), `game_buttons`
(with `buttonsWindow`), `game_mainpanel`, `client_topmenu`, `client_terminal`, `client_entergame`
(with `CharacterList`), `client_textedit`, `game_npctrade`, `game_inventory`, `game_spelllist`.

`client_profiles` must be **absent** (nil) so `bot.lua:341`'s fallback path is taken.

---

## 6. The bot's client-callback wiring

### 6.1 What `bot.lua` subscribes to

`initCallbacks()` (`mods/game_bot/bot.lua:549-614`), torn down in `terminateCallbacks()`
(`bot.lua:616-675`). Every handler is `function(...) if botExecutor == nil then return false end
safeBotCall(function() botExecutor.callbacks.<name>(...) end) end` (`bot.lua:684-879`); `safeBotCall`
(`bot.lua:677-682`) pcalls and routes failures to `onError`.

| Emitter | Signals | Handler → sandbox callback | Argument shape |
|---|---|---|---|
| `rootWidget` (`bot.lua:550`) | `onKeyDown`, `onKeyUp`, `onKeyPress` | `botKeyDown/Up/Press` (`bot.lua:684-700`) → `onKeyDown/Up/Press` | `(widget, keyCode, keyboardModifiers[, autoRepeatTicks])`; the executor converts to `keyDesc` via `determineKeyComboDesc` (`executor.lua:224,246,258`). `KeyUnknown` is filtered out. **BLOCKER-by-design headless: no key events exist.** |
| `g_game` (`bot.lua:556`) | `onTalk` | `(name, level, mode, text, channelId, pos)` | maps to parser event `talk` |
| | `onTextMessage` | `(mode, text)` | `textMessage` |
| | `onLoginAdvice` | `(message)` | `loginAdvice` |
| | `onUse` | `(pos, itemId, stackPos, subType)` | **client-side echo**, emitted by `g_game.use()`, not by the server |
| | `onUseWith` | `(pos, itemId, target, subType)` | same |
| | `onChannelList` | `(channels)` — flat `{id, name, id, name, …}` list | `channelList` |
| | `onOpenChannel` | `(channelId, channelName)` | `openChannel` |
| | `onCloseChannel` | `(channelId)` | `closeChannel` |
| | `onChannelEvent` | `(channelId, name, event)` | 0xF3 |
| | `onImbuementWindow` | `(itemId, slots, activeSlots, imbuements, needItems)` | 0xEB |
| | `onModalDialog` | `(id, title, message, buttons, enterButton, escapeButton, choices, priority)` | `modalDialog` |
| | `onAttackingCreatureChange` | `(creature, oldCreature)` | client-side |
| | `onAddItem` / `onRemoveItem` | `(container, slot, item[, oldItem])` | container ops |
| | `onEditText` | `(id, itemId, maxLength, text, writer, time)` → sandbox `onGameEditText` | 0x96 |
| | `onSpellCooldown` | `(iconId, duration)` | `spellCooldown` |
| | `onSpellGroupCooldown` | `(groupId, duration)` → sandbox `onGroupSpellCooldown` | `spellGroupCooldown` |
| | `updateInventoryItems` | `()` — fired after opcode **0xF5** | `bot.lua:872-879` |
| `Tile` (class) (`bot.lua:577`) | `onAddThing`, `onRemoveThing` | `(tile, thing)` | **gated**: `g_game.enableTileThingLuaCallback(true)` is only switched on when a script registers one (`functions/callbacks.lua:8-10`), and switched off in `clear()` (`bot.lua:115`) |
| `Creature` (class) (`bot.lua:582`) | `onAppear`, `onDisappear`, `onPositionChange`, `onHealthPercentChange`, `onTurn`, `onWalk` | `(creature)`, `(creature)`, `(creature,newPos,oldPos)`, `(creature,healthPercent)`, `(creature,direction)`, `(creature,oldPos,newPos)` | |
| `LocalPlayer` (class) (`bot.lua:595`) | `onManaChange`, `onStatesChange`, `onInventoryChange` | `(player,mana,maxMana,oldMana,oldMaxMana)`, `(player,states,oldStates)`, `(player,slot,item,oldItem)` | **`bot.lua:591-594` documents a real trap: `LocalPlayer`'s class table inherits from `Creature`'s through the metatable chain that `connect` walks (`util.lua:59-84`), so re-listing a `Creature` signal on `LocalPlayer` turns Creature's single slot into a two-entry list and every local-player emit fires twice.** The shim's signal model must preserve or explicitly avoid this. |
| `Container` (class) (`bot.lua:601`) | `onOpen`, `onClose`, `onUpdateItem`, `onAddItem`, `onRemoveItem` | `(container, previousContainer)`, `(container)`, `(container, slot, item, oldItem)`, `(container, slot, item, oldItem)`, `(container, slot, item)` | note `onAddItem`/`onRemoveItem` are connected on **both** `g_game` and `Container` and land on the same sandbox callback |
| `g_map` (`bot.lua:609`) | `onMissle`, `onAnimatedText`, `onStaticText` | `(missle)`, `(thing, text)`, `(thing, text)` | `distanceEffect`, `animatedText`, `staticText` |

### 6.2 What `functions/callbacks.lua` adds

`context.callback(type, cb)` (`callbacks.lua:4-46`) is the sandbox registration primitive:

* validates the type against `context._callbacks` (the 40-key table at `executor.lua:39-80`);
* auto-enables tile callbacks for `onAddThing`/`onRemoveThing` (`callbacks.lua:8-10`);
* captures `debug.getinfo(2,"Sl")` for the slow-callback warning — **the shim needs `debug.getinfo`**;
* wraps the user callback so it is **skipped while `callbackData.delay >= context.now`**
  (this is what sandbox `delay()` manipulates, `functions/main.lua:206-211`);
* sets `context._currentExecution` around the call (save/restore — note macros *do not* restore, they
  set it to `nil`, `main.lua:122`);
* times it with `g_clock.realMillis()` and warns above 100 ms;
* returns `{ remove = function() … end }` — **but the removal is buggy upstream**: it compares the
  *callback list* `cb` against each element (`callbacks.lua:32,37-39`), so `remove()` never matches.
  Reproduce as-is unless you intend to fix it.

Derived sugar (`callbacks.lua:49-280`): `onKeyDown/onKeyPress/onKeyUp`, `onTalk`, `onTextMessage`,
`onLoginAdvice`, `onAddThing`, `onRemoveThing`, `onCreatureAppear`, `onCreatureDisappear`,
`onCreaturePositionChange`, `onCreatureHealthPercentChange`, `onUse`, `onUseWith`, `onContainerOpen`,
`onContainerClose`, `onContainerUpdateItem`, `onMissle`, `onAnimatedText`, `onStaticText`,
`onChannelList`, `onOpenChannel`, `onCloseChannel`, `onChannelEvent`, `onTurn`, `onWalk`,
`onImbuementWindow`, `onModalDialog`, `onAttackingCreatureChange`, `onManaChange`, `onAddItem`,
`onRemoveItem`, `onStatesChange`, `onGameEditText`, `onSpellCooldown`, `onGroupSpellCooldown`,
`onInventoryChange`, `onInventoryItemsUpdate`, plus the composites
`listen(name, cb)`, `onPlayerPositionChange`, `onPlayerHealthChange`, `onPlayerInventoryChange`
(these compare `creature == context.player` by **identity** — the shim's creature objects must be
stable, interned per creature id).

### 6.3 Mapping onto `luaclient`

Every one of these has a matching `proto/parser.lua` event name (see `API.md`): `talk`, `textMessage`,
`loginAdvice`, `channelList`, `openChannel`, `closeChannel`, `modalDialog`, `spellCooldown`,
`spellGroupCooldown`, `creatureAppear`, `creatureDisappear`, `creatureMove`, `creatureHealth`,
`positionChange`, `manaChange`, `containerOpen`, `containerClose`, `containerAddItem`,
`containerUpdateItem`, `containerRemoveItem`, `inventoryChange`, `distanceEffect`, `animatedText`,
`staticText`. The gaps that need shim-side synthesis rather than a parser event:

| Sandbox callback | Gap |
|---|---|
| `onUse`, `onUseWith` | client-side echoes — fire them from the shim's `use()`/`useWith()` wrappers |
| `onAttackingCreatureChange` | client-side — fire from `attack()`/`cancelAttack()` and on `attackCancel` |
| `onAddThing`/`onRemoveThing` | must be emitted from `state.lua`'s tile mutation path, gated by an `enableTileThingLuaCallback` flag |
| `onStatesChange` | needs old/new `player.states` diffing in `state.lua` |
| `updateInventoryItems` | opcode 0xF5 — confirm `proto/parser.lua` raises an event for it |
| `onImbuementWindow`, `onGameEditText`, `onChannelEvent` | confirm parser coverage (0xEB, 0x96, 0xF3) |
| `onKeyDown/Up/Press` | **BLOCKER** — no keyboard headless. Register-and-never-fire. Only live consumer: `vBot/extras.lua:209`. |

---

## 7. Load order — what must exist before `_Loader.lua` runs

### 7.1 Real-client order (the thing being reproduced)

1. C++ boots, binds every `g_*` singleton (`src/framework/luafunctions.cpp`).
2. `modules/corelib` loads: `globals.lua` (sets `modules = package.loaded`, `G`, `rootWidget`,
   `scheduleEvent`/`removeEvent`/`cycleEvent`), `util.lua` (`print`, `connect`, `disconnect`,
   `signalcall`, `tr`), `string.lua`, `table.lua`, `math.lua`, `json.lua`, `base64.lua`,
   `keyboard.lua`, `settings.lua` (`g_settings`), `http.lua` (`HTTP`, and it **calls
   `connect(g_http, …)` and `g_http.setUserAgent` at load time** — corelib/http.lua:295-310).
3. `modules/gamelib` loads → defines the globals `SpellInfo`, `Spells`, `SpelllistSettings`.
4. Game modules load, each into its own sandbox env registered in `package.loaded`:
   `game_console`, `game_cooldown`, `game_textmessage`, `game_interface`, `game_skills`,
   `game_minimap`, `game_inventory`, `game_npctrade`, `game_spelllist`, `game_mainpanel`,
   `client_topmenu`, `client_terminal`, `client_entergame`, plus the mods `client_textedit`,
   `game_buttons`, `game_bot`.
5. `mods/game_bot/bot.lua:init()` → `dofile("executor")`, imports its `.otui`, `connect(g_game, {onGameStart=online,…})`, `initCallbacks()`, builds its window, `loadConfigsList()`.
6. Login → `online()` (`bot.lua:339-344`) → `scheduleEvent(refresh, 20)`.
7. `refresh()` (`bot.lua:208-296`): reads `g_settings.getNode('bot')`, resolves the config name,
   ensures `/bot/<config>/storage/`, loads `storage/profile_<N>.json` into `botStorage`, then calls
   `executeBot(configName, botStorage, botTabs, message, save, refresh, botWebSockets)`.
8. `executeBot` (`executor.lua:1-193`):
   a. `listDirectoryFiles("/bot/<config>", true, false)` → **top level only** → `luaFiles = {_Loader.lua}`, `uiFiles = {}`;
   b. builds `context` (§1), including `context.storage = storage` and `context.player = g_game.getLocalPlayer()`;
   c. `context.now = context.time = g_clock.millis()`;
   d. `G.botContext = context; dofiles("functions"); context.Panels = {}; dofiles("panels"); G.botContext = nil`
      — sorted order: `callbacks, config, const, icon, main, map, npc, player, player_conditions,
      player_inventory, script_loader, server, sound, test, tools, ui, ui_elements, ui_legacy,
      ui_windows`, then `attacking, basic, healing, looting, tools, war, waypoints`;
   e. `g_ui.importStyle` for each ui file;
   f. `load(readFileContents(f), f, nil, context)()` for each lua file → **`_Loader.lua`**;
   g. returns `{script = <tick>, callbacks = {…}}`.
9. `check()` (`bot.lua:525-546`) re-arms `scheduleEvent(check, 10)` and calls `botExecutor.script()`
   — which refreshes `context.now`/`context.time`, runs due macros, then drains `context._scheduler`.

### 7.2 What `_Loader.lua` itself needs, in order

At the moment `_Loader.lua` line 2 executes, all of the following must already be true:

1. `modules.game_bot.contentsPanel.config:getCurrentOption().text` returns the config dir name.
2. `g_resources.listDirectoryFiles("/bot/<cfg>/vBot", true, false)` returns **sorted full paths**
   (line 4), and `file:split(".")` works (`string.split` patched).
3. `g_ui.importStyle(path)` accepts every `.otui` in `/vBot` (line 7).
4. `context.dofile` works with `//`-collapsing paths (line 13).
5. The sandbox globals used by the very first scripts exist: `storage`, `now`, `time`, `player`,
   `macro`, `schedule`, `setDefaultTab`, `UI`, `Config`, `BotServer`, `json`, `modules`, `g_game`,
   `g_map`, `g_resources`, `g_settings`, `table`/`string`/`math` (patched), `print`, `warn`, `info`,
   `error`, `regexMatch`, `getDistanceBetween`, and the direction/slot constants.
6. `modules.gamelib.SpellInfo` (needed by `vBot/vlib.lua:278`, the third file loaded).
7. `g_settings.getNumber('profile')` → 1 (needed by `vBot/configs.lua:20`, the fifth file).

Then `_Loader.lua:16-59` dofiles, **in this exact order**:

```
main, items, vlib, new_cavebot_lib, configs,        <- libraries; order fixed by comment "do not change"
extras, cavebot, playerlist, BotServer, alarms, Conditions, Equipper, pushmax, combo,
HealBot, new_healer, AttackBot, Stances, ingame_editor, Dropper, Containers,
quiver_manager, quiver_label, tools, antiRs, depot_withdraw, eat_food, equip, training,
exeta, analyzer, spy_level, supplies, depositer_config, npc_talk, xeno_menu, hold_target,
cavebot_control_panel, navibot
```

and `vBot/cavebot.lua` (7th entry) chains, in order (`profiles/bot/vBot_4.8/vBot/cavebot.lua:9-56`):

```
importStyle /cavebot/{cavebot,config,editor,imbuing}.otui
dofile /cavebot/{actions, config, editor, example_functions, recorder, walking, minimap,
                 sell_all, depositor, buy_supplies, d_withdraw, supply_check, travel, doors,
                 pos_check, withdraw, inbox_withdraw, lure, bank, clear_tile, tasker, imbuing,
                 stand_lure, antilost, route_tools, cavebot}.lua      <- cavebot.lua MUST be last
importStyle /targetbot/{looting,target,creature_editor}.otui
dofile /targetbot/{creature, creature_attack, creature_editor, creature_priority, looting,
                   walking, target}.lua                              <- target.lua MUST be last
```

`vBot/navibot.lua:4-5` chains `importStyle("/navibot/navibot.otui")` + `dofile("/navibot/navibot.lua")`.

### 7.3 Prescribed shim install order

```
1.  lib/*        (sys, sched, log, json, socket, …) — already present
2.  SHIM_G       create the shared globals table
3.  stdlib patch string.split/starts/trim, table.find/removevalue/
                 encodeStringPairList/decodeStringPairList/isStringPairList/isList
                 (MUST precede step 8: executor copies the *global* string/table tables)
4.  regexMatch   (table.decodeStringPairList depends on it)
5.  platform     g_clock, g_logger, print/pinfo/perror/pwarning, g_resources (writeDir bound),
                 g_settings, g_platform, g_window, g_keyboard, g_mouse, g_sounds, g_app, tr
6.  events       scheduleEvent/removeEvent/cycleEvent on lib/sched; connect/disconnect/signalcall; G
7.  http         g_http (on lib/http + a WebSocket client) then HTTP (corelib/http.lua verbatim —
                 it calls connect(g_http,…) and g_http.setUserAgent at load time, so g_http first)
8.  gamelib data SpellInfo / Spells / SpelllistSettings / getSpelllistProfile into SHIM_G
9.  modules      build the `modules` table; every entry setmetatable({...},{__index=SHIM_G});
                 game_bot.contentsPanel.config must already answer getCurrentOption()
10. game layer   g_game, g_map, g_things, g_ui, Creature/Item/Tile/Container classes   (other items)
11. executor     build `context` exactly as executor.lua:21-167 does
12. G.botContext = context; load the functions/ + panels/ replacements in sorted order;
    G.botContext = nil
13. run          load('/bot/<cfg>/_Loader.lua', chunkname, nil, context)()
14. tick         every 10 ms: context.now = context.time = g_clock.millis(); run macros;
                 drain context._scheduler   (executor.lua:194-221)
```

---

## 8. Blockers and behaviour deltas

| # | Item | Nature |
|---|---|---|
| B1 | **`regexMatch`** — ECMAScript regex with alternation and `(?:…)`; 44 live call sites incl. the target-selection hot path (`targetbot/creature.lua:62`) and every `.cfg` route parse (`corelib/table.lua:293`) | Not a blocker, but the single largest implementation item; cannot be reduced to Lua patterns |
| B2 | **Keyboard callbacks** (`onKeyDown/onKeyUp/onKeyPress`) and `g_keyboard.isKeyPressed` | Cannot work headless. Register-and-never-fire. Live impact: `vBot/extras.lua:209` `useAll` hotkey and `vBot/Equipper.lua:590` condition type 9 never trigger. |
| B3 | **`g_window.getMousePosition` / `getTileUnderCursor` / `startUseWith` / all `onMouseRelease` handlers** (`vBot/xeno_menu.lua`, `cavebot/minimap.lua`, `vBot/playerlist.lua:218,269,319`) | No cursor. Objects must exist so load-time assignment succeeds; handlers never fire. |
| B4 | **`modules.client_entergame.CharacterList.doLogin`** (`vBot/vlib.lua:36`, `relogOnCharacter`) | Needs the char-list widget tree. Replace `relogOnCharacter` with a shim-native reconnect, or accept a no-op. |
| B5 | **`g_sounds` / `SoundChannels.Bot`** | `SoundChannels` (`modules/corelib/const.lua:338-342`) has no `Bot` key even in the live client — audio is already effectively dead. Inert. |
| B6 | **`g_window.flash()`** (`vBot/alarms.lua:128`) | **Does not exist in this otclient fork** — the live client throws on that line. A no-op shim is a fix, not a regression. |
| B7 | **`g_resources.createArchive` / `decompressArchive` / `HTTP.download` / config up/download** (`bot.lua:406-500`) | Only reachable from the bot's config-manager UI, which the shim drops entirely. Inert. |
| B8 | **`context.callback(...).remove()`** (`functions/callbacks.lua:32-44`) | Upstream bug: compares the callback *list* to each element, so removal never matches. Decide explicitly whether to reproduce or fix. |
| B9 | **`connect` on `LocalPlayer` double-dispatch** (`bot.lua:591-594`) | The class-inheritance behaviour of `connect` (`util.lua:59-84`) is load-bearing; a naive per-object signal table changes dispatch counts. |
| B10 | **`g_clock.millis()` is frame-quantised** (`src/framework/core/clock.h:32`) | If the shim makes it a live read, `context.now` and `game_cooldown`'s internal comparisons drift within a tick. Cache per scheduler turn. |
| B11 | **`g_resources.readFileContents` must throw** on a missing file | Callers depend on it (`bot.lua:275`, `vBot/configs.lua:32`, `functions/config.lua:58`) — returning `nil` silently changes error handling. |
| B12 | **`listDirectoryFiles` must sort** (`resourcemanager.cpp` `files.sort()`) | Determines `.otui` import order and top-level lua order. |
| B13 | **`modules.game_npctrade.sellAll`** (`cavebot/sell_all.lua:73`) | The only *unguarded* `game_npctrade` call — a nil module crashes the SellAll cavebot action. |
| B14 | **`game_cooldown` early-returns when its window is hidden** (`cooldown.lua:542,562`) | Live client silently keeps `cooldown[]`/`groupCooldown[]` empty with the window closed, so `canCast` over-reports readiness. The shim must record unconditionally. |
