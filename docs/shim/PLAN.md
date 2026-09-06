# Shim implementation plan — running real vBot 4.8 under `luaclient`

Consolidates the four inventories (`api-game.md` = A1, `api-ui.md` = A2, `api-platform.md` = A3,
`feasibility.md` = A4) into an executable plan. Nothing here is new research: every fidelity call
below cites the inventory line that justifies it.

**Ground truth this plan is built on**

| Fact | Source |
|---|---|
| All 74 vBot files + 27 `game_bot` runtime files import and tick under plain LuaJIT with **zero source modification** | A4 §3 |
| 4194 distinct API paths touched at import; **4113 are widget paths, 20 are non-widget calls** | A4 §4.1 |
| The whole non-UI import surface is **15 symbols**; the tick-only surface is **5** | A4 §2b |
| otclient's `corelib/*` + `gamelib/*` + `game_spelllist` data load **verbatim** and must be reused, not reimplemented | A4 §4.2 |
| `mods/game_bot/functions/*` (20) + `panels/*` (7) + `executor.lua` are pure Lua and load **unchanged** — they *are* the vBot-facing API | A4 §4.2 |
| Nothing needs C++. There are no import-time blockers | A4 §4.6 |

**The one-sentence architecture.** The shim is *not* a reimplementation of vBot's API — it is a
reimplementation of the ~30 otclient primitives that vBot's own runtime (`executor.lua` +
`functions/` + `panels/`) is written against; that runtime is then loaded verbatim on top, and it
supplies the vBot-facing surface for free.

---

## 0. Invariants every agent must honour

These are cross-cutting. Violating any one produces code that *runs* and is silently wrong — the
single largest risk in this project (A4 §4.5).

| # | Invariant | Why | Source |
|---|---|---|---|
| **I1** | **Object identity is interned.** The same creature id / tile position / `tile.things[i]` / container id must return the *same Lua table* on every call, forever. vBot compares game objects with `==`/`~=`. | `spec ~= player`, `top ~= ground`; also `onPlayerPositionChange` compares `creature == context.player` by identity | A1 §0.1, A3 §6.2 |
| **I2** | **`LocalPlayer:getPosition()` returns the PREWALK position** — `#preWalks > 0 and preWalks[#preWalks] or player.pos`. | every cavebot waypoint test desyncs otherwise | A1 §0.2 |
| **I3** | **Items carry a synthetic position.** Container item ⇒ `{x=0xFFFF, y=containerId\|0x40, z=slot}`, `getStackPos()` ⇒ `position.z`. Equipped ⇒ `{x=0xFFFF, y=slot, z=0}`. Tile item ⇒ the tile position, `getStackPos()` ⇒ stack index. | every `g_game.move` and `stashStowItem` is built on it | A1 §0.3 |
| **I4** | **Extra arguments are silently tolerated.** `g_game.walk(dir, false)`, `g_map.getTile(pos, distance)`, `setOn(v, true)`. Never `error()` on arity. | A1 §0.5 | |
| **I5** | **`g_clock.millis()` is frame-quantised** — one cached value per scheduler turn, refreshed at the top of the tick. `context.now` and any in-tick `g_clock.millis()` must agree. | vBot compares `now - x` in hundreds of places | A3 §3.2, B10 |
| **I6** | **`g_resources.readFileContents` must `error()`** on a missing file (callers `pcall` it), and `listDirectoryFiles` must return a **lexicographically sorted** array. | sort order fixes `.otui` import order and load order | A3 B11, B12 |
| **I7** | **The sandbox has no `__index` to `_G`.** vBot sees only the ~319 keys `executor.lua` puts on `context`. Every `modules.X` is `setmetatable({own fields}, {__index = SHIM_G})`. | `modules.game_bot.connect` resolves through that fallback | A3 §1, §5 |
| **I8** | **Signals are `connect()`-shaped**: a field holds a bare function *or* an array of functions; firing must be `signalcall`-shaped and `pcall`-wrapped. | `modules.game_bot.connect(CaveBotList(), {onChildFocusChange=…})` | A2 §7, A3 §4.2 |
| **I9** | **The otclient tree is READ-ONLY.** Nothing under `D:/Claude/otclient_mehah1530` is ever written. Source-level fixes go through `shim/patches.lua` (§1.14), never through editing the source. | user constraint | |
| **I10** | **Only one bot engine runs at a time.** Track A (vBot macros) and Track B (`bot/cavebot.lua` etc.) both walk and both attack; running both fights over the same character. `--bot-engine=vbot\|native`, default `native` until the shim passes its acceptance tests. | see §6.4 | |

---

## 1. Module layout: `D:/Claude/otclient_web/luaclient/shim/`

One file per API area. Every file returns a table; no globals except the ones the shim deliberately
installs into its own `SHIM_G` (never into the real `_G`, except `_G.LC` which already exists).

```
shim/
  init.lua        the only entry point                      (§1.1)
  env.lua         SHIM_G + sandbox-env factory              (§1.2)
  stdlib.lua      string/table patches                      (§1.3)
  regex.lua       regexMatch                                (§1.4)
  platform.lua    g_clock g_window g_keyboard g_mouse
                  g_sounds g_platform g_app g_logger print tr(§1.5)
  resources.lua   g_resources VFS                           (§1.6)
  settings.lua    g_settings                                (§1.7)
  signals.lua     connect/disconnect/signalcall,
                  scheduleEvent/removeEvent/cycleEvent, G   (§1.8)
  otml.lua        OTML/OTUI parser                          (§1.9)
  styles.lua      style registry + flattening               (§1.10)
  widget.lua      the stateful UIWidget class               (§1.11)
  ui.lua          g_ui                                      (§1.12)
  otlua.lua       loads otclient's reusable pure Lua        (§1.13)
  patches.lua     audited source rewrites for vendored files(§1.14)
  objects.lua     the intern registry + Thing base          (§1.15)
  creature.lua    Creature + LocalPlayer                    (§1.16)
  tile.lua        Tile                                      (§1.17)
  item.lua        Item                                      (§1.18)
  container.lua   Container                                 (§1.19)
  game.lua        g_game                                    (§1.20)
  map.lua         g_map                                     (§1.21)
  things.lua      g_things                                  (§1.22)
  cooldown.lua    game_cooldown emulation                   (§1.23)
  npctrade.lua    game_npctrade emulation                   (§1.24)
  modules.lua     the whole modules.* graph                 (§1.25)
  callbacks.lua   parser events -> sandbox callbacks        (§1.26)
  executor.lua    replaces mods/game_bot/bot.lua            (§1.27)
  http.lua        g_http + HTTP (optional, BotServer only)  (§1.28)
```

Target: **~3 200 lines of new Lua** (widget 450, otml+styles 300, regex 400, object model 700,
g_game/g_map 400, executor+callbacks 400, platform+resources+stdlib+signals 350, modules 200),
plus **~1 900 lines reused verbatim** from otclient (`executor.lua` 193, `functions/` + `panels/`
~1 400, `corelib`/`gamelib` data ~300).

### 1.1 `shim/init.lua`

```lua
local shim = require('shim.init')
local h = shim.boot(LC, {
    otRoot     = "D:/Claude/otclient_mehah1530/otclient",  -- READ-ONLY
    writeDir   = "<otRoot>/profiles/",                     -- g_resources root
    config     = "vBot_4.8",                               -- the /bot/<config> dir name
    profile    = 1,                                        -- g_settings.getNumber('profile')
    tickMs     = 10,
    strict     = false,   -- true: any missing API errors instead of returning an inert stub
})
h:start()        -- installs callbacks, runs _Loader.lua, arms the tick
h:stop()         -- saves storage, cancels the tick, disconnects callbacks
h:tick()         -- one manual tick (tests)
h:status()       -- { loaded=n, failed={}, macros={{name,enabled,runs,fails}}, errors=n }
h.context        -- the sandbox table (tests reach into it)
h.G              -- SHIM_G
```
`boot` is idempotent per `LC`; `stop` must leave `LC` clean enough that `boot` can run again
(config reload).

### 1.2 `shim/env.lua`
```lua
env.newG()                  -- fresh SHIM_G table
env.sandbox(G, ownFields)   -- setmetatable(ownFields or {}, {__index = G})   -- I7
```

### 1.3 `shim/stdlib.lua`
```lua
stdlib.install()            -- patches the GLOBAL string/table tables in place, before executor runs
```
Must implement, with exact upstream semantics (A3 §4.4, §4.5):
`string.split(s, delim)` (plain find, **drops empty strings**), `string.trim`, `string.starts` ·
`table.find(t, v, ...)`, `table.removevalue`, `table.isList`, `table.isStringPairList`,
`table.encodeStringPairList`, `table.decodeStringPairList` (**calls `regexMatch`** — load order).
Everything else in corelib `string.lua`/`table.lua`/`math.lua` has **0 live sites**: omit.

### 1.4 `shim/regex.lua`
```lua
regex.match(subject, pattern) -> { {full, cap1, ...}, ... }   -- installed as global regexMatch
```
ECMAScript subset, backtracking: `|`, `(…)`, `(?:…)`, `[...]`/`[^...]`, `\s \d \w \b`, `.`,
`? * + {n,m}` greedy and lazy, `^ $`. **No lookaround, no backreferences** (A3 §4.7). Contract:
iterate over successive suffixes, max 10 000 matches; unmatched optional group ⇒ `""`; empty
subject or pattern ⇒ `{}`; **an invalid pattern returns `{}` and never raises** (C++ `catch(...)`).

### 1.5 `shim/platform.lua`
```lua
platform.install(G, LC, opts) -> { g_clock=, g_window=, g_keyboard=, g_mouse=,
                                   g_sounds=, g_platform=, g_app=, g_logger= }
platform.beginTick()        -- refresh the cached millis  (I5)
```
`g_clock.millis()` cached / `realMillis()` live · `g_logger.{debug,info,warning,error,fatal,log}` →
`lib/log.lua` · global `print` (args joined with **four spaces**), `pinfo/pwarning/perror/pdebug` ·
`tr = string.format` · `g_window.setTitle` (forward to the control-plane status line),
`setClipboardText` stateful, `flash` no-op, `getMousePosition` → `{x=0,y=0}`,
`isKeyPressed` → `false` · `g_keyboard.isKeyPressed/isCtrlPressed` → `false` ·
`g_platform.openUrl/openDir` no-op · `g_sounds.getChannel(_)` → a no-op channel object ·
`g_app.getOs()` → `"windows"`, `getVersion()`, `doScreenshot` no-op · `retranslateKeyComboDesc`
(canonicalise and return; key only) · `g_mouse = {}`.

### 1.6 `shim/resources.lua`
```lua
resources.new(writeDir) -> g_resources
```
`listDirectoryFiles(dir, fullPath, raw, recursive)` (**sorted**, dirs included) ·
`fileExists` (regular files only) · `directoryExists` · `makeDir` (recursive) ·
`readFileContents` (**throws on miss**) · `writeFileContents` (creates parents) ·
`deleteFile` (files *and* directory trees) · `getWriteDir()` (**trailing `/`**) ·
`createArchive`/`decompressArchive` inert.
Path model (A3 §2.1): leading `/` ⇒ write-dir-relative; otherwise prefix the *current chunk's*
directory; **collapse every `//` to `/`** — `_Loader.lua` fails on the first script otherwise.
Reuse the FFI `FindFirstFileA` listing from `tools/shim_probe.lua:66`; add a POSIX branch
(`io.popen('ls -1')` or `lfs` if present) so `--selftest` still runs on Debian.

### 1.7 `shim/settings.lua`
```lua
settings.new(defaults) -> g_settings   -- getNumber/getString/getBoolean/getNode/setNode/set/get/save
```
`getNumber('profile')` **must default to 1** — 0 silently resets every HealBot/AttackBot/Supplies
config (A3 §3.1). `getNode('bot')`/`setNode` inert (the shim owns config selection).

### 1.8 `shim/signals.lua`
```lua
signals.install(G, sched) -> { connect=, disconnect=, signalcall=, scheduleEvent=,
                               removeEvent=, cycleEvent=, G = <the cross-reload table> }
```
`connect(object, {sig=slot}, pushFront)` with the exact 4-step upstream semantics incl. the
metatable forwarder for class-level connects (A3 §4.2). `scheduleEvent(cb, ms)` on `lib/sched.after`
returning an object with `:cancel()` and `._callback`; `removeEvent(nil)` tolerated.
**Decision required from the owner** on B9 (LocalPlayer/Creature double-dispatch): the shim's
classes are plain Lua tables, so the inheritance walk does not apply — document that
`LocalPlayer` signals fire **once**, unlike the live client.

### 1.9 `shim/otml.lua`
```lua
otml.parse(text, sourceName) -> node          -- node = {tag=, value=, children={}, line=}
```
Indentation ⇒ tree; `tag: value`; `tag:` + block; `|` literal blocks; `//` and `--` comments;
duplicate tags preserved in order; `@`/`!`/`&`/`#`/`$` prefixes preserved on the tag.

### 1.10 `shim/styles.lua`
```lua
styles.new(g_resources) -> reg
reg:importStyle(path)  reg:importStyleFromString(text)
reg:get(name) -> flattened node | nil          -- exact then lowercase
```
`Name < Base` flattening at **import** time (`clone(base); merge(node)`), lowercase alias, and the
`UI*` auto-definition rule: an unregistered name starting with `"UI"` becomes a node whose
`__class` is that name (A2 §1).

### 1.11 `shim/widget.lua`
```lua
widget.new(class, styleName) -> w
widget.isWidget(v) -> bool
```
Instance state exactly as A2 §9.1. `__index` = methods (fields win — A2 §9.2). The **~30 real
methods** (A2 §9.3) and **~45 return-`self` methods** (A2 §9.4). Non-negotiable exactness:

* `setId` installs `parent[id]` **only if the parent has no field of that name**; also sets the
  numeric key when `tonumber(id)` is non-nil (`HealBot.lua:292-299` reads `ui[1]`).
* `getChildByIndex(i)`: 1-based; `i<=0` counts from the end (`0`→last).
* `getChildIndex(nil)` returns the widget's **own** index in its parent (`cavebot/cavebot.lua:214`).
* `setText(t, dontFireLuaCall)` — the 2nd arg breaks a `CaveBot.save()` recursion.
* `setItemId` **always** fires `onItemChange` (no suppress arg exists).
* `setValue` clamps and only fires when `setupDone`.
* `addOption`: the first option auto-selects.
* auto-focus rule verbatim (A2 §6.3), default policy `last`, `TextList` = `none`,
  `Panel`/`ScrollablePanel` = `first`.
* `destroy` / `setVisible(false)` on the focused child re-focuses the **previous** sibling.
* Signals fired: `onTextChange onValueChange onItemChange onOptionChange onCheckChange
  onVisibilityChange onFocusChange onChildFocusChange onSetup onCreate`. Everything input- or
  geometry-shaped is **stored and never fired**.

### 1.12 `shim/ui.lua`
```lua
ui.new(styles, widget) -> g_ui   -- createWidget, loadUIFromString, importStyle,
                                 -- importStyleFromString, getRootWidget, loadUI/displayUI inert
```
Creation pipeline = A2 §9.5 verbatim (children before `@onSetup`).

### 1.13 `shim/otlua.lua`
```lua
otlua.load(G, otRoot)   -- loads otclient's pure Lua into SHIM_G, in dependency order
```
Loads verbatim (A4 §4.2): `corelib/{const,bitwise,json}.lua`,
`gamelib/{const,position,player,creature,textmessages,spells,items,thing,tile,util}.lua`,
`game_spelllist/spelllist.lua` (data only). **`tr`, `Thing`, `Creature`, `Item`, `g_game`, … must
already exist in `G` before this runs** — that was blocker #5 in A4 §2. Supplies `PlayerStates`,
`Bit`, `MessageModes`, `SpellInfo`, `Spells`, `SpelllistSettings`, `Shield*`, `getDistanceBetween`,
`postoTable`.
`json`: use `lib/json.lua` — byte-identical to corelib's (A3 §4.3).

### 1.14 `shim/patches.lua`
```lua
patches.apply(sourceText, virtualPath) -> patchedText
```
An audited table of `{path, expected, replacement, why}`. Fails **loudly** if `expected` is absent
(upstream drifted). Current contents — exactly one entry:

| file | change | why |
|---|---|---|
| `mods/game_bot/functions/map.lua:22` | `type(x) == 'userdata'` → `type(x) == 'table' and x.getId ~= nil` | the `getSpectators(creature)` overload; Lua-table wrappers make the branch dead and a creature arg is then misread as a position (A1 §0.4) |

### 1.15 `shim/objects.lua`
```lua
objects.new(LC) -> reg
reg:creature(id) -> Creature|nil      reg:localPlayer() -> LocalPlayer
reg:tile(pos) -> Tile|nil             reg:container(id) -> Container|nil
reg:tileItem(pos, stackIdx) -> Item   reg:containerItem(cid, slot) -> Item
reg:inventoryItem(slot) -> Item       reg:detachedItem(id, count) -> Item   -- Item.create
reg:forget(kind, key)                 reg:sweep()   -- drop wrappers whose backing record is gone
```
**The first thing built and the load-bearing one (I1).** Every other object file takes `reg`.
Wrappers are thin: they hold `{reg=, key=}` and read `LC.state` live on every call — never snapshot.

### 1.16 `shim/creature.lua` — 30 methods
Real: `getId getName getPosition getHealthPercent isPlayer isMonster isNpc isLocalPlayer getType
getDirection getVocation getShield getEmblem getOutfit getSpeed getStepDuration isWalking isDead
canShoot isPartyMember isPartyLeader isSorcerer isDruid isKnight isPaladin isMonk`.
LocalPlayer adds: `getHealth getMaxHealth getMana getMaxMana getLevel getExperience getMagicLevel
getSoul getStamina getCapacity getFreeCapacity getTotalCapacity getStates getSkillLevel
getSkillBaseLevel getBlessings getRegenerationTime getInventoryItem getInventoryCount
hasEquippedItemId isPreWalking isSupplyStashAvailable getResourceBalance getStance
getSecondaryStance getHarmony getVirtues isSerene`.
Stubs: `getManaPercent`→100, `isTimedSquareVisible`→false, `setSpeed` stateful, all
render/`setMarked`/`attachEffect` inert.
Traps: `getRegenerationTime()` **is compared with a number** — must be a number, never nil
(A4 §4.4); `getPosition()` on the local player is the prewalk position (I2); `getStance` derives
from `player.virtues` with the exact C++ rule (A1 §4.2).

### 1.17 `shim/tile.lua` — thin adapters over `state:*`
`getPosition isWalkable getTopUseThing hasCreatures getCreatures getItems getTopThing getGround
canShoot isPathable isNotPathable hasFloorChange hasElevation getThings getTopMoveThing
getTopCreature getMinimapColorByte isLookPossible`. Keep the **reversal** in `getCreatures`.
`hasFloorChange` via `bot/world.lua:493 world:itemChangesFloor`.

### 1.18 `shim/item.lua`
`getId getCount getPosition getStackPos getSubType getCountOrSubType getItemCountOrSubType getTier
isContainer isStackable isNotMoveable isPickupable isFluidContainer isUsable isMultiUse isGround
isItem isCreature getMarketData getName`; `Item.create(id[,count])`; `getServerId()` → `getId()`
(documented deviation B3).
`getMarketData()` must **never** return nil — `{name=…, category=0, requiredLevel=0,
restrictVocation=0, showAs=id, tradeAs=id}` (A1 §4.4). `getPosition`/`getStackPos` per I3.

### 1.19 `shim/container.lua`
`getName getItems getContainerItem` (**both arities**) `getItemsCount getSlotPosition` (0-based
slot, `{0xFFFF, id|0x40, slot}`) `getCapacity getId hasPages getSize getFirstIndex hasParent
isClosed isUnlocked getItem`.

### 1.20 `shim/game.lua` — `g_game`
Mutators → `proto/sender.lua` (A1 §1.1). Accessors → `game/state.lua` (A1 §1.2).
**Must be added to `proto/sender.lua`** (they do not exist yet): `partyInvite`, `partyJoin`,
`stashStowItem` (opcode 0x28). Cached client-side: attacking/following creature id (set
**synchronously** in `attack()` — vBot polls `getAttackingCreature()` on the next line), the
feature table, `enableTileThingLuaCallback` flag, ping from `LC.state.ping`.
`getClientVersion`/`getProtocolVersion` → `1530`. `getUnjustifiedPoints()` must return a table with
`killsDayRemaining/killsWeekRemaining/killsMonthRemaining` — **nil crashes `vlib.lua:224`**.
`g_game.walk(dir)` must return **`false` when the step is refused** (`cavebot/walking.lua:294`).

### 1.21 `shim/map.lua` — `g_map`, 8 symbols, thin adapters
`getTile` (memoised wrapper, **nil for an undescribed tile**) · `getTiles(floor)` (**hot path — keep
a per-floor index invalidated by `setTile`/`cleanTile`, never rescan `state.map`**) ·
`getSpectators` / `getSpectatorsInRange` / `getSpectatorsByPattern` → `bot/world.lua` ·
`isSightClear` → `state:isSightClear` · `getMinimapColor` → `state:getMinimapColor` ·
`findEveryPath` → `bot/path.lua:300`, with the `functions/map.lua` string-param contract and the
`{totalCost, distance, dir, "prevX,prevY,prevZ"}` node shape.
**Sort spectator results by `(z, y, x, -stackIndex)`** — `pairs(state.creatures)` hash order makes
"the first spectator" nondeterministic (A1 §2.2).

### 1.22 `shim/things.lua`
`g_things.getThingType(id)` → a ThingType with `isFluidContainer()` and `getName()` over
`proto/items.lua`. The other 76 bound methods are unused.

### 1.23 `shim/cooldown.lua`
`isCooldownIconActive(iconId)` / `isGroupCooldownIconActive(groupId)` fed by the `spellCooldown` /
`spellGroupCooldown` parser events. **Record unconditionally** — the live client early-returns when
its window is hidden and under-reports (A3 B14). Hot path: `vlib.lua:368,374` → `canCast`.

### 1.24 `shim/npctrade.lua`
`sellAll(delayed, exceptions)` — **the only unguarded call** (`cavebot/sell_all.lua:73`), maps onto
`sender:sellItem` plus the parsed sell list. Plus `isTrading getSellItems getBuyItems
getSellQuantity canTradeItem closeNpcTrade getSellExceptions setSellExceptions
setSellExceptionsListener`.

### 1.25 `shim/modules.lua`
```lua
modules.build(G, deps) -> modulesTable        -- becomes both `modules` and `package.loaded`
```
Every entry is `env.sandbox(G, ownFields)` (I7). Must exist or `_Loader` aborts (A3 §5.2):
`game_bot` (with `contentsPanel.config:getCurrentOption() -> {text=<config>}`), `gamelib`,
`game_cooldown`, `game_textmessage` (with `messagesPanel.statusLabel` and
`messagesPanel.centerTextMessagePanel.highCenterLabel` — `getText()` must return a string),
`game_console` (with `channels` backed by `state.channels`, `isEnabledWASD()`→`false`),
`game_interface` (with `gameRootPanel` **assignable**, `getMapPanel()` object with
`lock/unlockVisibleFloor`, `forceExit()` = **real** disconnect + terminate), `game_minimap`
(`getMiniMapUi()` → an assignable table), `game_skills` (`…level.percent:getPercent()` → number
from `state.player.levelPercent`, `…stamina.value:getText()` → string), `game_buttons`
(`buttonsWindow`), `game_mainpanel` (`addToggleButton` → object with `setOn/isOn/destroy`),
`client_topmenu`, `client_terminal` (`addLine` → log), `client_entergame` (`CharacterList.doLogin`
stub), `client_textedit`, `game_npctrade`, `game_inventory` (`getSlot5()` may be nil),
`game_spelllist` (`getSpelllistProfile()` → `"Default"`).
**`client_profiles` must stay `nil`.**

### 1.26 `shim/callbacks.lua`
```lua
callbacks.install(LC, context, deps) -> handle   -- handle:remove()
```
Replaces `bot.lua:549-614`. Maps `LC.events` names → the 40 `context._callbacks.*` names, mostly
1:1 (A3 §6.3). Shim-side synthesis required for:

| sandbox callback | how |
|---|---|
| `onUse`, `onUseWith` | client-side echo from the shim's own `g_game.use/useWith` |
| `onAttackingCreatureChange` | fire from `attack()`/`cancelAttack()` and on the `attackCancel` event |
| `onAddThing`/`onRemoveThing` | **DONE (gap G5 closed).** `shim/object.lua` `Reg:_hookState` wraps `state:addThing` and `state:_removeAt` on the state INSTANCE (so `game/state.lua` itself is untouched) and fans out to `reg.onTileThing`; gated by `enableTileThingLuaCallback`, the same gate as `tile.cpp:374-376,420-422` |
| `onStatesChange` | old/new `player.states` diffing in `state.lua` |
| `onKeyDown/Up/Press` | never arrive from the wire (**B2**), but `shim.pressHotkey(desc)` drives the executor's own key path by hand — see COMPAT.md §4.1 |

`functions/callbacks.lua` is loaded verbatim on top and supplies `context.callback` and the 35
derived helpers — **do not reimplement it**. It needs `debug.getinfo`, which LuaJIT has.

### 1.27 `shim/executor.lua`
Replaces `mods/game_bot/bot.lua` (the client-side host: window, config manager, callback wiring).
It does **not** replace `mods/game_bot/executor.lua`, which is loaded verbatim.
```lua
exec.run(LC, deps, opts) -> { context=, script=, macros=, stop= }
```
Steps: locate `/bot/<config>` → read `storage/profile_<N>.json` → build the `botTabs` stub →
`dofile(otRoot.."/mods/game_bot/executor.lua")` (through `patches.apply`) → call
`executeBot(config, storage, tabs, msgCallback, saveConfigCallback, reloadCallback, websockets)`.
The tick is `res.script()`; storage is saved on stop and every 60 s.
`msgCallback(kind, text)` → `lib/log.lua`.

### 1.28 `shim/http.lua` (optional — `vBot/BotServer.lua` only)
`g_http` on `lib/http.lua` + a WebSocket client, then corelib `http.lua` verbatim (it calls
`connect(g_http, …)` and `g_http.setUserAgent` at load time, so `g_http` must exist first).
Ship as `nil`-tolerant: BotServer degrades gracefully.

---

## 2. Work breakdown — dependency ordered, parallelism marked

```
                     ┌─ W1-A stdlib ──┐
                     ├─ W1-B regex ───┤ (regex before table.decodeStringPairList)
   lib/ (exists) ────┼─ W1-C resources│
                     ├─ W1-D platform │
                     ├─ W1-E signals  │
                     └─ W1-F otml ────┘
                              │
        ┌─────────────────────┴──────────────────────┐
        │  UI TRACK (independent)                    │  GAME TRACK (independent)
   W2-A styles (otml)                           W2-D objects  ← game/state.lua
   W2-B widget                                  W2-E creature+localplayer
   W2-C g_ui   (styles+widget)                  W2-F tile+item+container
        │                                       W2-G otlua  (needs stubs of g_game/Creature/Item)
        │                                            │
        └──────────────┬────────────────────────┬────┘
                       │                        │
                 W3-A modules              W3-B g_game (sender)   W3-C g_map (bot/path+world)
                 W3-D cooldown+npctrade    W3-E things
                       └────────────┬───────────┘
                                    │
                              W4-A callbacks     W4-B executor+init+patches
                                    │
                              W5  tests (§5)
```

| ID | Deliverable | Depends on | Effort | Parallel with |
|---|---|---|---|---|
| **W0** | `shim/env.lua` + the skeleton of every file (empty tables, correct returns) so agents never block on a missing require | — | 0.25 d | — |
| **W1-A** | `stdlib.lua` | W0 | 0.25 d | all W1 |
| **W1-B** | `regex.lua` + its conformance test | W0 | **1.5 d** | all W1 |
| **W1-C** | `resources.lua` (+ POSIX branch) | W0 | 0.5 d | all W1 |
| **W1-D** | `platform.lua`, `settings.lua` | W0 | 0.5 d | all W1 |
| **W1-E** | `signals.lua` | W0, `lib/sched` | 0.25 d | all W1 |
| **W1-F** | `otml.lua` | W0 | 0.5 d | all W1 |
| **W2-A** | `styles.lua` | W1-F, W1-C | 0.5 d | game track |
| **W2-B** | `widget.lua` | W1-E | **1.5 d** | game track |
| **W2-C** | `ui.lua` | W2-A, W2-B | 0.25 d | game track |
| **W2-D** | `objects.lua` — **the critical path** (I1) | W0, `game/state.lua` | 0.5 d | UI track |
| **W2-E** | `creature.lua` | W2-D | 0.75 d | W2-F |
| **W2-F** | `tile.lua`, `item.lua`, `container.lua` | W2-D | **1.5 d** | W2-E |
| **W2-G** | `otlua.lua` | W0 + stub globals | 0.5 d | UI track |
| **W3-A** | `modules.lua` | W2-C, W2-G | 0.5 d | W3-B..E |
| **W3-B** | `game.lua` + the 3 new `proto/sender.lua` builders (partyInvite, partyJoin, stashStowItem) | W2-E/F, `proto/sender` | **1.5 d** | W3-C |
| **W3-C** | `map.lua` + the per-floor index | W2-F, `bot/path`, `bot/world` | 1 d | W3-B |
| **W3-D** | `cooldown.lua`, `npctrade.lua` | W3-A | 0.5 d | — |
| **W3-E** | `things.lua` | W2-D | 0.1 d | — |
| **W3-F** | `game/state.lua` gap fixes G1–G10 (§3.6) | — | 0.5 d | everything |
| **W4-A** | `callbacks.lua` | W3-A/B, W3-F | 1 d | W4-B |
| **W4-B** | `patches.lua`, `executor.lua`, `init.lua`, `main.lua` wiring | W3-* | 0.75 d | W4-A |
| **W5** | the test suite (§5) | W4 | 1.5 d | — |

**Critical path**: W0 → W2-D → W2-F → W3-B → W4-B → W5 ≈ **5 days serial**.
With 4–5 agents in parallel the whole "loads + ticks + sends real packets" milestone is
**~4 working days**, matching A4 §5's 3–4 day estimate. "Actually plays correctly" remains
**2–3 weeks**, dominated by `g_map`/Tile/Container fidelity, not by API count.

**Optional / defer:** `http.lua` (BotServer), `cooldown` fidelity beyond the two predicates,
`getUnjustifiedPoints` real parsing (G3), `isSupplyStashAvailable` (G4), imbuement (B2 — leave
disabled), analyzer-facing `game_skills`/`game_textmessage` fidelity.

---

## 3. Fidelity per API area, with the evidence

Legend: **REAL** = real behaviour · **STATEFUL** = remembers a value, no side effect ·
**INERT** = may do nothing · **BLOCKED** = cannot work headless.

### 3.1 Game (A1)
| Area | Fidelity | Evidence |
|---|---|---|
| `g_game` world mutators (open/move/close/use/useWith/attack/walk/autoWalk/talk*/equip/…) | **REAL** → `proto/sender.lua` | 25 `open`, 22 `move`, 13 `close`, 7 `use` T1 call sites (A1 §1.1) |
| `g_game` accessors (getLocalPlayer/getContainers/findPlayerItem/isOnline/getPing/…) | **REAL** over `state.lua` | A1 §1.2 |
| `g_game.getClientVersion/getProtocolVersion` | **INERT** → `1530` | all 25+1 sites are version gates (A1 §1.2) |
| `g_game.getUnjustifiedPoints/getFeature` | **STATEFUL** (zeros / latched features) | nil crashes `vlib.lua:224` (A1 §1.2) |
| `g_game` imbuement family (6 symbols) | **DONE (B2 closed)** | 0xD5/0xD6/0xD7/0xB2/0x60 out, 0x5D/0xEB/0xEC in; the opcode family in A1 §6 was misidentified as 0xF8/0xF9/0xFA |
| `g_map` — all 8 symbols | **REAL**, thin adapters over `state`/`bot/world`/`bot/path` | 37 `getTile`, 16 `getTiles`, 19 `findPath`-funnelled (A1 §2) |
| `g_map.getMinimapColor` unseen-tile fallback | **BLOCKED-with-data (B1)** — see §6.1 | `map.cpp` reads `g_minimap` for every tile outside the aware range (A1 §6) |
| `Tile` (18 methods) | **REAL** — `state.lua` already has verbatim C++ ports of all of them | A1 §4.3, §5 |
| `Creature` / `LocalPlayer` (30 + 26) | **REAL** — mostly one-line field reads | A1 §4.1, §4.2 |
| `Item` (22) | **REAL**; `getServerId` returns **0**, which is what the non-editor C++ build answers | A1 §4.4, B3 |
| `Container` (13) | **REAL** | second-hottest cluster; 35 `getName`, 27 `getItems` (A1 §4.5) |
| `g_things.getThingType` | **REAL** (2 methods only) | A1 §3 |
| `g_sprites/g_creatures/g_shaders/g_effects`, render/map-view methods | **INERT** | 0 call sites / B4 |

### 3.2 UI (A2)
| Area | Fidelity | Evidence |
|---|---|---|
| OTML parser + style registry | **REAL — mandatory** | 638 `id:` declarations across 24 profile `.otui`; vBot addresses widgets by name (A2 §0.1) |
| Widget tree, ids, ordering, focus, `getChildBy*` | **REAL** | 3 widget lists **are** the runtime data structures: CaveBot waypoints (`getFocusedChild` = program counter), TargetBot creatures, AttackBot attacks (A2 §0.2, §5.4–5.6, §6) |
| `setText/getText`, `setValue/getValue`, `isOn`, `isChecked`, combobox options, `setItemId/getItemId`, `getItems()` | **STATEFUL** (genuinely) | read back by `functions/config.lua:169`, `targetbot/looting.lua:72-105`, `vBot/supplies.lua:211-216` (A2 §4, §5.7) |
| Everything cosmetic: colour, font, image, anchors, margins, layout, `$state` blocks, `raise`, `ensureChildVisible` | **INERT** | no vBot code reads any of it back; `getWidth()`→0 is *safer* than a fake number (A2 §4.7, §2) |
| Widget signals `onTextChange onValueChange onItemChange onOptionChange onCheckChange onVisibilityChange onFocusChange onChildFocusChange onSetup` | **REAL (fired)** | the shim populates fields programmatically and real logic hangs off those handlers (A2 §7) |
| `onClick onDoubleClick onMouse* onKey* onDragEnter onGeometryChange onClose` | **STORED, never fired** | nothing headless generates input or geometry (A2 §0.4) — but must be *callable*: `config.lua:241-257 widget.switch:onClick()` is how `CaveBot.setOn()` works (A2 §8.2) |
| `recursiveGetChildByPos`, `PopupMenu:display`, `createFlagWindow`, `attachEffect`, modal editors | **BLOCKED** — reachable only from mouse handlers; `waypointHud` defaults to **false** | A2 §8.1 |

### 3.3 Platform (A3)
| Area | Fidelity | Evidence |
|---|---|---|
| `g_resources` (7 methods) | **REAL** — the most load-bearing platform singleton | every config, route and storage file (A3 §2) |
| `g_clock` | **REAL**, cached per tick | I5 / B10 |
| `g_logger` + `print` | **REAL** → `lib/log.lua` | ~90 `print` sites; the shim's only diagnostic channel (A3 §3.8) |
| `connect/disconnect/signalcall`, `scheduleEvent/removeEvent` | **REAL** | 3 live `modules.game_bot.connect` sites + all shim-internal wiring (A3 §4.2) |
| `string`/`table` extensions (10 functions) | **REAL, exact semantics** | 80 `table.find`, 38 `string.split` — `actions.lua:195` relies on the empty-string drop (A3 §4.4/4.5) |
| `regexMatch` | **REAL — the largest single item** | 44 sites incl. `targetbot/creature.lua:62` (per creature per tick) and every `.cfg` route parse (A3 §4.7) |
| `json` | **DROP-IN** `lib/json.lua` | byte-identical to corelib's (A3 §4.3) |
| `g_settings.getNumber('profile')` | **STATEFUL**, default **1** | 0 silently resets every vBot config (A3 §3.1) |
| `g_window`, `g_platform`, `g_sounds`, `g_app`, `g_mouse` | **INERT / STATEFUL** | 0 behavioural consumers (A3 §3.3–3.10) |
| `g_keyboard` + `onKeyDown/Up/Press` | **BLOCKED (B2)** | no keyboard headless; live impact = `extras.lua:209` useAll hotkey and `Equipper.lua:590` condition 9 |
| `modules.*` graph | **REAL structure, mostly INERT leaves** | 17 modules must exist or `_Loader` aborts (A3 §5.2) |
| `modules.game_cooldown.*` | **REAL** | `vlib.lua:368,374` → `canCast`, the heal/attack hot path (A3 §5.1) |
| `modules.game_npctrade.sellAll` | **REAL (thin)** | the only unguarded call — nil crashes the SellAll waypoint (A3 B13) |
| `modules.game_interface.forceExit` | **REAL** | `antiRs.lua:14` panic exit (A3 §5.1) |
| `modules.client_entergame.CharacterList.doLogin` | **BLOCKED (B4)** → replace `relogOnCharacter` with a shim-native reconnect | needs the char-list widget tree (A3 §5.1) |

### 3.4 Reused verbatim — do NOT reimplement
`mods/game_bot/executor.lua` · `functions/*.lua` (20) · `panels/*.lua` (7) ·
`modules/corelib/{const,bitwise,json}.lua` · `modules/gamelib/*.lua` (10) ·
`modules/game_spelllist/spelllist.lua` (data). **All 27 + 12 load unchanged** (A4 §3, §4.2).
Total ~1 900 lines the shim gets for free — and they *are* the vBot-facing API, so reimplementing
them is how you introduce drift.

### 3.5 Return-shape traps (proven by crashing the probe — A4 §4.4)
`Creature:getRegenerationTime()` compared with a number · `getSellExceptions()` `ipairs`'d ·
`getMiniMapUi()` indexed · `loadUIFromString()` indexed and `:setId()`'d ·
`Item.create()` passed to `setItem()` · `getSlot5()` → `.count:setText()` ·
`TabBar.buttonsPanel:getChildren()[v]` indexed beyond its array part ·
`getMarketData().name` · `getUnjustifiedPoints().killsDayRemaining`.

### 3.6 `game/state.lua` / `proto` gaps to close (A1 §5) — owner W3-F
| # | Gap | Fix |
|---|---|---|
| G1 | no attack/follow target tracked | cache the id in `shim/game.lua`, clear on `attackCancel` |
| G2 | no RTT | `LC.state.ping` already exists in `main.lua:455` — expose it |
| ~~G3~~ **CLOSED** | opcode 0xB7 parsed into `state.unjustified` | before the packet arrives the three `*Remaining` fields answer **255**, not 0 — see COMPAT.md §4 divergence 4 |
| G4 | `parser.lua:909` discards the supply-stash byte | store it |
| ~~**G5**~~ **CLOSED** | per-thing event emitted | from `state:addThing` / `state:_removeAt`, gated by `enableTileThingLuaCallback` — required by `BotServer.lua:221` |
| G6 | remote `getVocation()` | return 0 |
| G7 | party mana (0x8B) | return 100 |
| ~~G8~~ **CLOSED** | imbuement | B2 closed; senders and parsers both exist |
| G9 | party invite/join builders | add to `proto/sender.lua` |
| G10 | `stashStowItem` (0x28) | add to `proto/sender.lua` |

---

## 4. Load sequence and the tick

### 4.1 Boot (mirrors A3 §7.3; the numbers are the install order)

```
main.lua: parse flags → items.load → login → transport → parser/sender → LC ready
          on the `gameStart` event, if cfg.botEngine == 'vbot':

 1  G = env.newG()                                  -- SHIM_G
 2  stdlib.install()                                -- MUST precede executor: it copies the
                                                    --   GLOBAL string/table tables
 3  G.regexMatch = regex.match                      -- table.decodeStringPairList needs it
 4  platform.install(G, LC, opts)                   -- g_clock g_logger print tr g_window …
    G.g_resources = resources.new(opts.writeDir)
    G.g_settings  = settings.new{ profile = opts.profile }
 5  signals.install(G, sched)                       -- connect/signalcall/scheduleEvent/G
 6  [optional] http.install(G)                      -- g_http then corelib/http.lua verbatim
 7  reg      = objects.new(LC)
    G.g_game   = game.new(LC, reg)     G.g_map = map.new(LC, reg)
    G.g_things = things.new(LC)        G.Item  = item.class(reg)
    G.Creature, G.Tile, G.Container, G.Thing = …    -- class tables must EXIST before step 8
 8  otlua.load(G, otRoot)                           -- corelib + gamelib + spelllist DATA
                                                    --   (blocker #5 in A4 §2: order matters)
 9  styles = styles.new(G.g_resources)
    G.g_ui = ui.new(styles, widget)
    styles:importStyle(<otclient data/styles/10-*,20-*,30-miniwindow…>)
    styles:importStyle(<mods/game_bot/ui/{basic,panels,config,icons,container}.otui>)
10  G.modules = modules.build(G, deps)              -- also becomes package.loaded
    G.modules.game_bot.contentsPanel.config         -- must already answer getCurrentOption()
11  exec = executor.run(LC, deps, opts)             -- dofile mods/game_bot/executor.lua
                                                    --   (through patches.apply)
                                                    -- executeBot(config, storage, tabs, …)
                                                    --   → dofiles functions/ then panels/
                                                    --   → importStyle every profile .otui
                                                    --   → load('/bot/<cfg>/_Loader.lua', …)
12  callbacks.install(LC, exec.context, deps)       -- LC.events → context._callbacks.*
13  LC.shimTick = sched.every(opts.tickMs or 10, tick)
```

Step 11 is where the **real, unmodified** `_Loader.lua` runs and chains all 74 files in the fixed
order of A3 §7.2. By the time line 2 of `_Loader.lua` executes, all seven preconditions in A3 §7.2
must hold; that is exactly what steps 1–10 establish.

### 4.2 The tick

```lua
local function tick()
    if not LC.inGame then return end          -- bot.lua gates on g_game.isOnline()
    platform.beginTick()                      -- refresh the cached g_clock.millis()  (I5)
    local ok, err = pcall(exec.script)        -- executor.lua:194-221:
                                              --   context.now = context.time = g_clock.millis()
                                              --   run due macros in registration order
                                              --   drain context._scheduler
    if not ok then log.error('shim tick: %s', err) end
end
```
Every macro body is already `pcall`'d inside `functions/main.lua`; a failing macro logs and does not
stop the others. The outer `pcall` catches only executor-level faults.

**Where the tick is driven from**: `lib/sched.every(10, tick)`, armed on `gameStart` and cancelled
on `sessionEnd`/`stop`, exactly like the existing native bot in `main.lua:290 startBot`. The two
engines are mutually exclusive (I10).

### 4.3 `main.lua` additions
```
--bot-engine=vbot|native   (default native until §5 acceptance passes)
--shim-config=vBot_4.8     the /bot/<dir> name
--shim-otroot=<path>       default D:/Claude/otclient_mehah1530/otclient
--shim-strict              any missing API errors instead of returning an inert stub
```

---

## 5. Test strategy — proving vBot actually runs

Everything runs offline, no server, no account, under `luajit test/selftest.lua` and in
`--selftest`. Tests that need the real otclient tree must **skip with a printed reason** when
`otRoot` is absent, so the suite still passes on Debian (BOT.md mandates both platforms).

### 5.1 `test/shim_unit.lua` — no otclient tree needed (runs everywhere)
Pure-unit, table-driven:
* **otml**: indentation nesting, `tag: value`, block form, `|` literals, `//`/`--` comments,
  duplicate tags, `@`/`!`/`&`/`$` prefixes.
* **styles**: `Name < Base` flattening (children inherited), lowercase alias, `UI*` auto-definition,
  a later base redefinition **not** retro-applying.
* **widget** (the exactness quirks, one assert each):
  `getChildByIndex(0)` = last · `getChildByIndex(-1)` = second-to-last ·
  `getChildIndex(nil)` = own index in parent · `getChildIndex(foreign)` = -1 ·
  `setId` collision does not overwrite an existing parent field but *does* fill `childrenById` ·
  numeric id also set as a number key · `setText(t, true)` fires nothing ·
  `setItemId` always fires `onItemChange` · first `addOption` auto-selects ·
  auto-focus `first`/`last`/`none` · destroying the focused child re-focuses the previous sibling.
* **regex**: a ~60-row conformance table taken from the 44 live patterns (A3 §4.7), including
  `(?:^|\n)([^:^\n]{1,20}):?(.*)(?:$|\n)` from `table.lua:293` and the runtime-built
  `^name.*$|^other.?$` alternation from `targetbot/creature.lua:27`; plus invalid-pattern ⇒ `{}`.
* **stdlib**: `split` drops empty strings (assert `("goto:"):split(":")[2] == nil` semantics as
  `actions.lua:195` relies on), `trim`, `starts`, `table.find`, the StringPairList round-trip.
* **resources**: `//` collapse, relative-to-chunk resolution, sorted listing, `readFileContents`
  **raises** on a miss, `getWriteDir()` keeps its trailing `/`.
* **objects (I1)**: `reg:creature(id) == reg:creature(id)`, and still equal after the creature moves;
  `reg:tile(p) == reg:tile(copyOf(p))`.
* **item positions (I3)**: container item ⇒ `{0xFFFF, cid|0x40, slot}` and `getStackPos()==slot`;
  equipped ⇒ `{0xFFFF, slot, 0}`.

### 5.2 `test/shim_load.lua` — "every file loads" (needs the tree; skips otherwise)
The production path, not the probe's: `shim.boot{strict=true}` then `h:start()`.
Asserts:
1. **74/74** vBot files loaded, **0 failed** (compare against the manifest in A4 §3, so a missing
   file is a test failure, not a silent skip).
2. **27/27** `game_bot` runtime files loaded.
3. `#h.status().macros >= 48`.
4. `h.status().errors == 0`.
5. The user's real `storage/profile_1.json` (44 975 B) decoded and reachable as `context.storage`.
6. `targetbot_configs/<name>.json` was actually **read** — the one genuine load-time data
   dependency the probe could not supply (A4 §4.5.3). Assert a non-empty read.
7. `strict = true` produced **zero** "missing API" reports — this is the regression net that keeps
   the inventory honest as vBot is updated.

### 5.3 `test/shim_tick.lua` — "one tick with no errors", with teeth
A "no crash" tick is not evidence (A4 §5 is explicit about this). The test must assert *outbound
packets*, using the existing `test/botsuite.lua` synthetic-world + captured-transport pattern:

```
build LC.state directly: player at a known pos, hp/mana below a HealBot threshold,
  one monster 3 tiles away matching a targetbot entry, a corpse with loot,
  an open container, an ASCII map with a wall
capture LC.sender's transport (record every body string)
h:tick()  ×N
assert:  the exact opcode sequence, e.g.
   • HealBot fires   → 0x96 talk with the configured spell words (or 0x82 use of the item id)
   • TargetBot picks → 0xA1 attack with THAT creature id (not the other one)
   • CaveBot walks   → 0x65..0x68 in the direction bot/path.lua also returns
   • Looting         → 0x82 open on the corpse, then 0x78 move of the configured loot id
   • no packet at all when every macro is disabled in storage
```
Plus a **determinism** assert: run the same tick twice from the same state and require an identical
packet sequence (this is what catches the spectator hash-order bug, A1 §2.2).

### 5.4 `test/shim_diff.lua` — differential against Track B
The strongest available offline oracle: for the same synthetic world and the same user config,
assert that the shim (Track A) and the native modules (Track B) agree on:
* the next walk direction for a cavebot `goto`,
* the selected target id and the chase/keep-distance decision,
* which heal rule fires for a matrix of hp/mana values (BOT.md already mandates that matrix for the
  native HealBot — reuse the table).
Divergence is a finding in *one* of the two, and the test names which.

### 5.5 `test/shim_config_roundtrip.lua`
`tools/vbot_compat_check.lua` already round-trips the user's real config files through vBot's own
parser. Extend it: after a shim run that calls `CaveBot.save()` / `TargetBot.save()` /
`vBotConfigSave()`, re-parse the written files and assert byte-level compatibility with the real
vBot (ARCHITECTURE.md's hard constraint). **Write to a temp copy — never to the user's profile.**

### 5.6 Performance gate
Assert in `shim_tick.lua`: a full tick over the user's real 48 macros completes in **< 5 ms**
(half the 10 ms budget) on this machine, and `g_map.getTiles(z)` over a full aware area in
**< 1 ms** (it is called 16× per tick in T1 and is the obvious O(n) trap — hence the per-floor index
in §1.21). Report the measured numbers; do not silently regress.

### 5.7 Acceptance for flipping `--bot-engine` default to `vbot`
5.1 ✅ · 5.2 ✅ with `strict=true` · 5.3 ✅ including determinism · 5.4 no unexplained divergence ·
5.5 ✅ · 5.6 within budget. Until then the default stays `native`.

---

## 6. Risks, fallbacks, and where the two tracks meet

### 6.1 Highest risk — long-range CaveBot routing over unseen terrain (**B1**)
`Map::findEveryPath` reads the *persisted minimap* for every tile outside the aware range
(`wasSeen`, `NotWalkable`, `NotPathable`, colour, speed). Headless that store is empty, so unless
`allowUnseen` is set, every long `goto` hop across unloaded terrain **fails to find a path**
(A1 §6 B1). `bot/world.lua:206` already has the hook (`opts.known`, with
`KNOWN_WAS_SEEN/NOT_PATHABLE/NOT_WALKABLE/EMPTY` and the null-tile defaults) but **nothing populates
it**.

Mitigations, cheapest first — and the first one is unusually cheap here because this project already
has OTMM tooling and a restored map from earlier work:
1. **Load the user's `minimap.otmm` offline into `opts.known`.** Recommended; do it in W3-C.
2. Persist an aware-range trail as the bot walks (covers re-runs of the same route).
3. Accept `allowUnseen` paths and lean on `bot/walker.lua`'s anti-lost recovery.

This is the single largest "everything loads, nothing works" risk. Treat (1) as **required**, not
optional, before any live hunting test.

### 6.2 Ranked risk list
| # | Risk | Likelihood | Fallback |
|---|---|---|---|
| 1 | **B1 minimap-less pathing** breaks long `goto` hops | high | §6.1; else use Track B `bot/cavebot.lua`, which walks over `bot/path.lua` with its own known-tile policy |
| 2 | **`regexMatch` subtly wrong** — it decides target validity (`creature.lua:62`) and parses every `.cfg` route | medium | the §5.1 conformance table; if the engine proves unreliable, fall back to an FFI PCRE binding (adds a native dep) |
| 3 | **Silent wrongness** — everything runs, nothing is correct (the probe's own warning, A4 §5) | high | §5.3 packet asserts + §5.4 differential vs Track B; `strict=true` in CI |
| 4 | **Widget-list-as-truth semantics** (focus = CaveBot program counter) subtly off | medium | §5.1 quirk asserts; these are 10 one-line tests that cover it |
| 5 | **Spectator ordering nondeterminism** (`pairs` hash order) | medium | sort by `(z,y,x,-stackIndex)`; the §5.3 determinism assert catches regressions |
| 6 | **Item position/stackpos (I3)** silently corrupts every move and stow | medium | §5.1 item-position asserts before any looting test |
| 7 | **Tick budget** — 48 macros + per-creature regex in interpreted Lua at 10 ms | medium | §5.6 gate; raise `tickMs`, or disable macros via `storage._macros` (vBot's own mechanism) |
| 8 | **B2 keyboard** — `extras.lua:209` useAll hotkey, `Equipper.lua:590` condition 9 never fire | certain | accept; both are user-input features with no headless meaning |
| 9 | **B4 relog** — `CharacterList.doLogin` needs the char-list widget | certain | replace `relogOnCharacter` with a shim-native reconnect (`transport:close()` → supervisor re-login) |
| ~~10~~ | ~~**B2 imbuement** — no sender, no parser~~ **CLOSED** | — | senders (0xD5/0xD6/0xD7/0xB2/0x60) and parsers (0x5D/0xEB/0xEC) both exist; `cavebot/imbuing.lua` can run |
| 11 | **B9 `connect` double-dispatch** on LocalPlayer differs from the live client | low | document; assert dispatch counts in §5.1 |
| 12 | **Upstream drift** — vBot or otclient files change under us | low | `shim/patches.lua` fails loudly; §5.2's 74/27 manifest asserts |
| 13 | **Config corruption** — the shim writes a file the real vBot can no longer read | low but costly | §5.5 round-trip; never write to the user's live profile in tests |

### 6.3 What is least likely to work headless (honest list)
`analyzer.lua` (UIGraph charts, client chrome, `game_skills` widget reads) — *display only, harmless*.
`playerlist.lua` / `xeno_menu.lua` / `cavebot/minimap.lua` popup menus — *mouse only, never fire*.
`quiver_label.lua` — *cosmetic*. `BotServer.lua` — *needs `g_http` + WebSocket; optional*.
`imbuing.lua` — *B2*. `training.lua` hotkey paths — *B2*. The waypoint HUD in `antilost.lua` —
*already `pcall`'d and gated by `waypointHud`, default false*.
None of these are on the "log in, hunt, heal, attack, loot, refill" path.

### 6.4 Where Track A and Track B meet
```
vBot sources (unchanged)                     bot/healbot bot/attackbot bot/cavebot bot/targetbot
   |                                                            |   (Track B — fallback + oracle)
   |  shim/  (otclient API emulation)                           |
   |      g_map.findEveryPath  ────────────┐                    |
   |      g_map.getSpectators* ────────────┤                    |
   |      g_game.walk (prewalk) ───────────┤                    |
   +──────────────────────────────────────┐│                    |
                                          ▼▼                    ▼
                          bot/path.lua  bot/world.lua  bot/walker.lua   (SHARED primitives)
                                                |
                     game/state.lua   proto/sender.lua   proto/items.lua   lib/sched.lua
```
Three contract points, and they are the only ones:
* **`shim/map.lua` → `bot/path.lua:300 findEveryPath`** — must keep the `{totalCost, distance, dir,
  "prev"}` node shape and the string-param normalisation `functions/map.lua:80-113` performs.
* **`shim/map.lua` → `bot/world.lua:621 spectators` / `:678 spectatorsByPattern`** — plus the
  `(z,y,x,-stack)` sort the C++ implies.
* **`shim/game.lua:walk` → `bot/walker.lua`** — prewalk bookkeeping in `state.player.preWalks` (I2)
  and the `false` return on refusal.
Everything else is independent. **Track B is never loaded at the same time as Track A** (I10); it is
the fallback engine and the differential oracle of §5.4.

---

## 7. Scope recommendation

**Recommendation: load the full vBot tree; make only the hunting path *correct*; gate everything
else behind vBot's own macro switches.**

Rationale:

1. **Loading everything is already free.** All 74 files import in **31 ms** with zero failures
   (A4 §3). There is no import-time blocker. Cutting the tree down would mean editing
   `_Loader.lua`'s hard-coded file list — i.e. modifying the user's sources, which is the one thing
   this project exists not to do.
2. **The four-module subset is not actually separable.** `cavebot/*` chains from `vBot/cavebot.lua`,
   which needs `vlib.lua`, `items.lua`, `new_cavebot_lib.lua`, `configs.lua` and `extras.lua`
   (`storage.extras.gotoMaxDistance` is read by `cavebot.lua:366,387,443,489`). Once those are in,
   the remaining files cost only load time.
3. **The cost is *fidelity*, not *loading*.** The expensive work is the object model, not breadth:
   Tile + Container + Creature + Item + the `findEveryPath` adapter carry the hunt. That is the same
   work whether 4 files or 74 are loaded.
4. **vBot already ships the off switch.** `storage._macros[name] = false` is the user's own
   mechanism, is persisted in the profile the shim reads, and the user's live config already has
   most macros disabled (A4 §3: several macros only ran because the probe force-enabled them).
   Selective disabling costs zero code.

Concretely, for a headless worker whose job is *log in, hunt with cavebot+targetbot, heal, attack,
loot, refill*:

| Tier | Content | Fidelity target |
|---|---|---|
| **T0 — must be correct** | `g_map` (all 8) · Tile · Container · Creature/LocalPlayer · Item (incl. I3) · `g_game` mutators + accessors · `findEveryPath` adapter · widget lists + focus · `regexMatch` · `g_resources` · cooldown predicates · the CaveBot/TargetBot/HealBot/AttackBot files | **REAL**, covered by §5.3/§5.4 |
| **T1 — must not error** | every other vBot file: analyzer, playerlist, BotServer, quiver, training, Stances, Equipper, Containers, alarms, combo, Conditions, navibot | loads, macro may be disabled |
| **T2 — accepted non-function** | imbuing (B2), keyboard hotkeys (B2), relog via char list (B4), popup menus / map HUD / graphs (B4, A2 §8.1), sound (B5) | documented deviations |

**Effort**: ~4 days with 4–5 parallel agents to "loads, ticks, and sends the right packets against
the synthetic world"; **2–3 weeks** to "actually hunts", with the long pole being `g_map`/Tile
fidelity and §6.1's minimap data — *not* API breadth.

**Payoff**: every customisation in the user's AttackBot, every cavebot route, every personal script
keeps working, and future vBot edits port over for free. That is worth substantially more than the
~2 weeks of native-module work it partially duplicates — and the native modules are not wasted:
they are the shared primitives the shim calls, the fallback engine, and the only offline oracle
that can prove the shim is right rather than merely quiet.
