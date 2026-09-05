# Shim API inventory — A2: the UI surface (`g_ui`, `UI.*`, UIWidget)

Scope: everything vBot 4.8 touches that lives behind `g_ui`, the `UI.*` helpers in
`mods/game_bot/functions/ui*.lua`, and widget objects. Sources scanned in full (ripgrep, no
sampling):

* `D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8` (live profile; `*.bak-*` excluded)
* `D:/Claude/otclient_mehah1530/otclient/mods/game_bot` (`bot.lua`, `executor.lua`, `functions/`, `panels/`, `ui/`)
* `D:/Claude/otclient_mehah1530/otclient/modules/corelib/ui/*.lua` (Lua half of the widget classes)
* `D:/Claude/otclient_mehah1530/otclient/src/framework/ui/*` + `src/framework/luafunctions.cpp`,
  `src/client/luafunctions.cpp` (C++ half)

Verdict legend: **IMPLEMENT** = real behaviour required · **STATEFUL STUB** = must remember a value,
no side effect · **INERT STUB** = may do nothing (return `self`/`0`/`nil`) · **BLOCKER** = cannot work
headless.

---

## 0. Executive summary — the four things that actually matter

1. **A minimal OTML/OTUI parser + style registry is mandatory, not optional.** 638 `id:` declarations
   across 24 profile `.otui` files build the widget trees that vBot then addresses by name
   (`healWindow.healer.spells.spellList`). Without style instantiation, ~every vBot file errors on
   the first line of its UI block. This is pure text processing — no rendering. See §2.
2. **Three widget lists are the runtime source of truth, not mirrors of config.** The CaveBot
   waypoint list, the TargetBot creature list, and the AttackBot attack list are *data structures*:
   ordering, `getChildIndex`, `getFocusedChild` (the CaveBot program counter) and arbitrary Lua
   fields hung on children (`.action`, `.value`, `.stayPos`, `.params`) drive the bot. See §6.
3. **Everything else is a mirror.** HealBot, AttackBot settings, Supplies, CaveBot.Config, extras,
   macros — the source of truth is a Lua table persisted to JSON; the widget is written to and (in
   the headless case) never read back. A stateful stub is exactly sufficient. See §5.
4. **Nothing that needs a real mouse, keyboard, font metric or pixel ever runs headless**, because
   every such path is inside an `onClick`/`onDoubleClick`/`onMouseRelease`/`onDragEnter` handler that
   only the input system fires. Those handlers must be *storable* (and a handful *callable*), never
   *fired*. See §8.

---

## 1. `g_ui.*` — every call site

Profile totals (`.bak` excluded): `createWidget` 10, `getRootWidget` 10, `loadUIFromString` 4,
`importStyle` 1. game_bot mod: `createWidget` 24, `importStyle` 7, `getRootWidget` 4, `loadUI` 1,
`displayUI` 1, `importStyleFromString` 1, `loadUIFromString` 1.

| Symbol | Signature as used | Sites | Must return / do | Verdict |
|---|---|---|---|---|
| `g_ui.createWidget(styleName, parent?)` | `(string, widget\|nil)` | 34 total. Profile: `vBot/playerlist.lua:194,220,271,321`, `vBot/xeno_menu.lua:5`, `vBot/training.lua:523`, `vBot/depositer_config.lua:41`, `vBot/Containers.lua:470`, `cavebot/minimap.lua:17`, `cavebot/antilost.lua:756`. Mod: `functions/ui.lua:11,20,27`, `functions/ui_legacy.lua:10,59,70,81,91,102`, `functions/ui_elements.lua:69`, `functions/icon.lua:32`, `executor.lua:24`, `bot.lua:504`, `panels/*` (9) | Instantiate the flattened style `styleName` (error if undefined), attach to `parent` (nil ⇒ orphan), recursively create the style's child nodes, apply properties, run `@onSetup`, return the widget | **IMPLEMENT** |
| `g_ui.getRootWidget()` | `()` | Profile: `vBot/HealBot.lua:316`, `vBot/BotServer.lua:43`, `vBot/combo.lua:67`, `vBot/Conditions.lua:73`, `vBot/Containers.lua:379`, `vBot/Sio.lua:61`, `vBot/pushmax.lua:53`, `vBot/playerlist.lua:145`, `vBot/analyzer.lua:91`, `vBot/vlib.lua:30`. Mod: `functions/ui.lua:27`, `bot.lua:129`, `panels/attacking.lua:5,317` | A singleton widget with id `"root"`; used as the parent of every `UI.createWindow` and as a namespace for `rootWidget.<windowId>` lookups (`vBot/extras.lua:38` reads `rootWidget.newHealer.targetSettings.vocations.title`) | **IMPLEMENT** (trivial: one root widget) |
| `g_ui.loadUIFromString(otml, parent?)` | `(string, widget\|nil)` | `vBot/training.lua:1`, `vBot/quiver_label.lua:4`, `vBot/cavebot_control_panel.lua:3`, `vBot/Containers.lua:98`; mod `functions/ui_legacy.lua:17` (`context.setupUI`, 15 call sites in profile) | Parse inline OTML. Nodes whose tag contains `<` are *style definitions* (import them); at most one non-`<` node is a *widget* to instantiate under `parent`. Returns the widget or nil. Matches `UIManager::loadUIFromString` (`src/framework/ui/uimanager.cpp:661`) | **IMPLEMENT** |
| `g_ui.importStyle(path)` | `(string)` | `_Loader.lua:8` (loops every `.otui` in `/bot/<cfg>/vBot`), `executor.lua:179` (loops every `.otui` under the config dir), `bot.lua:25-29` (the 5 base `ui/*.otui`), `functions/ui_legacy.lua:27` | Read the file, register each `Name < Base` as a flattened clone of `Base` merged with the node body. Case-insensitive name cache. Mirrors `UIManager::importStyleFromOTML` (`uimanager.cpp:467-514`) | **IMPLEMENT** |
| `g_ui.importStyleFromString(otml)` | `(string)` | `functions/ui_legacy.lua:29` (reached from `importStyle()` when the argument contains a newline) | Same as above from a string | **IMPLEMENT** |
| `g_ui.loadUI(name, parent)` | `('bot', leftPanel)` | `bot.lua:42` only | Not reached — the shim replaces `bot.lua` wholesale | **INERT STUB** |
| `g_ui.displayUI(name)` | `('edit')` | `bot.lua:83` only | Same | **INERT STUB** |

**Style-name resolution rule to copy verbatim** (`UIManager::getStyle`, `uimanager.cpp:527-547`): if
the name is not registered *and* starts with `"UI"`, auto-define it as a node whose `__class` is the
name itself. That is why `UIWidget`, `UIItem`, `UICreature`, `UIGraph` work with no style file.

**Flattening rule** (`uimanager.cpp:500-512`): `importStyle` does `clone(base) ; merge(node)` at
*import* time. Consequences for the shim: children declared on a base style are inherited by every
derived style (so `HealWindow < MainWindow` already owns `MainWindow`'s `closeButton`), and a later
redefinition of a base does *not* retro-apply to already-derived styles. Style names are stored twice
(exact + lowercase).

---

## 2. OTUI: what the shim must parse, and what it may discard

24 `.otui` files in the profile + 5 in `mods/game_bot/ui`. Property frequency across the profile's
`.otui` files (measured):

**Semantically load-bearing (must be applied):**

| Property | Count | Effect required |
|---|---|---|
| `id:` | 638 | `setId` → registers in the parent's id map **and** sets the Lua field `parent.<id>` (`UIWidget::setId`, `uiwidget.cpp:1056-1072`). This is what makes `healWindow.healer.spells.spellList` resolve. |
| `text:` / `!text:` | 324 / 61 | initial `getText()` value. A `!` prefix ⇒ evaluate the value as a Lua expression wrapped in `tostring(...)` (`uiwidget.cpp:711-721`); in this tree it is always `tr('...')`. |
| `tooltip:` / `!tooltip:` | 53 / 11 | stored string; nothing reads it back — needed only so `getTooltip` doesn't nil. |
| `@onSetup:` | 6 | **must execute.** All are `self:addOption(...)` blocks on ComboBoxes (`vBot/HealBot.otui:10,20`, `vBot/combo.otui:4,11`, `vBot/Conditions.otui:4`, `vBot/equipper.otui:35`, plus `mods/game_bot/ui/basic.otui:75` `SlotComboBox`). Without them `getCurrentOption()` returns nil and HealBot's add-spell path and Equipper's condition parsing break. |
| `visible:` | 13 | initial visibility (feeds `onVisibilityChange` propagation). |
| `checked:` | 2 | initial checked state. |
| `minimum:` / `maximum:` / `step:` / `value:` | 32 / 32 / 38 / 10 | scrollbar range — `setValue` clamps to it (`uiscrollbar.lua:372`). Getting this wrong silently changes numeric settings. |
| `focusable:` | 41 | gates auto-focus; see §6.3. |
| `auto-focus:` | on `TextList` / `Panel` | `first` \| `last` \| `none`. **Drives the CaveBot program counter.** See §6.3. |
| `&<name>:` | `&selectable`, `&editable`, `&menuScroll`, `&menuHeight`, `&menuScrollStep`, `&disableScroll`, `&parentWidth` | raw Lua field set on the widget instance. Set the field; the meanings are consumed only by scrollbar/combobox internals we stub. |
| `layout:` | 33 | `verticalBox` / `grid` / `fit-children` — **INERT**, no geometry headless. |

**Discardable (INERT):** `anchors.*` (1108), `margin-*` (738), `font` (199), `height`/`width`/`size`
(386), `text-align` (127), `color`/`background-color` (109), `image-*` (75), `padding*` (69),
`text-offset`, `text-wrap`, `phantom`, `vertical-scrollbar`, `pixels-scroll`, `fit-children`,
`cell-size`, `cell-spacing`, `num-columns`, `opacity`, `border-*`, `icon`, `placeholder`,
`multiline`, `editable`, `virtual`, `old-scaling`, `capacity`, `flow`, `image-clip`,
`text-auto-resize`.

**`$state:` sub-blocks** (`$on` 17, `$focus` 16, `$!on` 8, `$checked` 2, `$!checked` 1, `$mobile` 1):
every one in the vBot tree only changes `image-color` / `background-color` / `color`, except
`mods/game_bot/ui/config.otui:24-30` (`$on: text: On` / `$!on: text: Off`) and
`cavebot/cavebot.otui:43-57` / `targetbot/target.otui:66-75` (switch captions). **No vBot code reads
any of those texts back** (verified: there is no `switch:getText()` anywhere in the tree) ⇒ `$state`
blocks may be dropped entirely. **INERT STUB.**

**`__class` values that must exist** (from `< Base` roots): `UIWidget`, `UIButton`, `UILabel`,
`UITextEdit`, `UICheckBox`, `UIComboBox`, `UIScrollBar`, `UIScrollArea`, `UIWindow` (`MainWindow`,
22 derivations), `UIMiniWindow` (`MiniWindow`, 10 derivations), `UIItem`, `UICreature`, `UIGraph`,
`UIProgressBar`, `UISpinBox`, `UIPopupMenu`, `UITabBar`.

Base style tags actually instantiated inside profile `.otui` files: `Label` 141, `Button` 83,
`CheckBox` 50, `BotSwitch` 42, `TextEdit` 41, `HorizontalSeparator` 39, `VerticalScrollBar` 19,
`UIWidget` 19, `SpinBox` 19, `TextList` 16, `Panel` 15, `BotItem` 15, `BotTextEdit` 12,
`MiniWindowContents` 10, `HorizontalScrollBar` 7, `ScrollablePanel` 6, `ComboBox` 4, `UIItem` 3,
`ProgressBar` 2, `UICreature` 2, `BotContainer` 2, `TabBar` 1, `UIGraph` 1.

---

## 3. `UI.*` helpers — what each builds, and what is read back

Definitions: `mods/game_bot/functions/ui.lua` (33 lines), `ui_elements.lua` (408),
`ui_windows.lua` (49), `ui_legacy.lua` (134).

| Helper | Line | Builds | Values vBot reads back | Verdict |
|---|---|---|---|---|
| `UI.createWidget(name, parent?)` | `ui.lua:7` | `g_ui.createWidget(name, parent or context.panel)`, sets `.botWidget = true` | 74 call sites; everything about the returned tree | **IMPLEMENT** |
| `UI.createWindow(name)` | `ui.lua:26` | `g_ui.createWidget(name, g_ui.getRootWidget())` then `:show() :raise() :focus()` | 24 call sites (list below). Callers pass a 2nd arg (`rootWidget`) that the helper ignores | **IMPLEMENT** (`show/raise/focus` may be stubs) |
| `UI.createMiniWindow(name, parent?)` | `ui.lua:16` | `g_ui.createWidget(name, modules.game_interface.getRightPanel())` then `widget:setup()` | 10 sites, all `vBot/analyzer.lua:98-121`. Only `:setContentMaximumHeight`, `:close()`, `:open()` used afterwards | create **IMPLEMENT**; `setup/close/open/setContentMaximumHeight` **INERT STUB** |
| `UI.Button(text, cb, parent?)` | `ui_elements.lua:7` | `BotButton` + `setText` + `.onClick = cb` | 13 sites. `onClick` never fires headless; a few sites call it programmatically (§8.2) | **STATEFUL STUB** |
| `UI.Label(text, parent?)` | `:212` | `BotLabel` + `setText` | 6 sites | **STATEFUL STUB** |
| `UI.Separator(parent?)` | `:218` | `BotSeparator` | 33 sites | **INERT STUB** (must still return a widget) |
| `UI.TextEdit(text, cb, parent?)` | `:223` | `BotTextEdit`, `.onTextChange = cb`, **then** `setText(text)` — note the order: the callback fires once at construction | 1 site | **STATEFUL STUB** + fire `onTextChange` |
| `UI.Config(parent?)` | `:14` | `BotConfig` panel: `ComboBox id:list`, `Button id:switch`, `Button id:add/edit/remove` (`mods/game_bot/ui/config.otui`) | **`widget.switch:isOn()` is the CaveBot/TargetBot on-off source of truth** (`functions/config.lua:169,232-258`); `widget.list:getCurrentOption().text` is the selected profile name (`config.lua:164,176`) | **IMPLEMENT** (stateful) |
| `UI.Container(cb, unique, parent?, widget?)` | `:21` | wraps a `BotContainer` (`ScrollablePanel id:items` + scrollbar). Replaces `widget.setItems`/`widget.getItems`; fills `items` with `BotItem` children (`math.max(10,#items+2)`, rounded up to a multiple of 5) | **`widget:getItems()` → `{{id=,count=},…}` is the source of truth for TargetBot loot** (`targetbot/looting.lua:72,78,86`) and for Dropper / eat_food / tools / depositer_config | **IMPLEMENT** (needs `BotItem` children with `getItemId` / `getItemCountOrSubType`) |
| `UI.DualLabel(left, right, params?, parent?)` | `:282` | `DualLabelPanel` (`left`/`right` labels) + `setHeight` + a `left:getWidth()` clamp | 44 sites — display only. `getWidth()==0` just skips the clamp | **STATEFUL STUB** |
| `UI.LabelAndTextEdit(params, cb, parent?)` | `:309` | `LabelAndTextEditPanel`; `.right.onTextChange` writes `params.right` | 0 sites in this profile | **STATEFUL STUB** |
| `UI.SwitchAndButton(params, cbS, cbB, cb, parent?)` | `:351` | `SwitchAndButtonPanel` | 0 sites | **STATEFUL STUB** |
| `UI.DualScrollPanel` / `UI.DualScrollItemPanel` / `UI.TwoItemsAndSlotPanel` | `:103` / `:156` / `:230` | scroll pairs + item slots; write into `params`, call `callback(widget, params)` | 1 site (`UI.TwoItemsAndSlotPanel`) | **STATEFUL STUB** |
| `UI.EditorWindow` / `SinglelineEditorWindow` / `MultilineEditorWindow` | `ui_windows.lua:141-166` | delegates to `modules.client_textedit.edit(text, options, cb)` | 2 profile sites (`cavebot/editor.lua`, `cavebot/route_tools.lua`) + `functions/config.lua:187,210` | **BLOCKER** — needs a real modal editor. Unreachable headless (only from `onClick`). Return a dummy widget so `window.botWidget = true` does not error |
| `UI.ConfirmationWindow(title, q, cb)` | `ui_windows.lua:168` | `displayGeneralBox` | reached only from `widget.remove.onClick` | **BLOCKER / unreachable** |
| `context.addSwitch(id,text,cb,parent?)` | `ui_legacy.lua:55` | `BotSwitch` + `setId` + `setText` + `.onClick` | **used by `context.macro`** (`functions/main.lua:97`) for every named macro; `macro.switch:setOn(bool)` mirrors `storage._macros[name]` | **STATEFUL STUB** |
| `context.addButton/addLabel/addTextEdit/addSeparator` | `ui_legacy.lua:66/77/87/98` | `BotButton`/`BotLabel`/`BotTextEdit`/`BotSeparator` with an explicit id | 3 `addTextEdit`, 3 `addSeparator`, 1 `addSwitch` in the profile | **STATEFUL STUB** |
| `context.addTab(name)` / `getTab` / `setDefaultTab(name)` | `ui_legacy.lua:32/48/50` | `context.tabs:addTab(name, g_ui.createWidget('BotPanel')).tabPanel.content`; assigns `context.panel` | **34 `setDefaultTab` + 3 `addTab` + 2 `getTab` sites** — this is how every vBot file chooses its parent panel. Also iterates `context.tabs.tabs`, calling `tab:getText()` / `tab:setFont()` | **IMPLEMENT** as a name→panel map returning a plain container widget; `setOn`/`setFont` inert |
| `context.setupUI(otml, parent?)` | `ui_legacy.lua:13` | `g_ui.loadUIFromString(otml, parent or context.panel)` | 15 sites | **IMPLEMENT** |
| `context.importStyle(otml)` | `ui_legacy.lua:22` | a `.otui` path ⇒ `g_ui.importStyle(configDir.."/"..otml)`; otherwise `importStyleFromString` | 9 sites | **IMPLEMENT** |
| `context.addIcon(id, options, cb)` | `functions/icon.lua:5` | `BotIcon` on the game map panel, draggable, hotkey-bound | **0 sites in this profile** | **INERT STUB** |

Per-file `UI.createWidget` counts (profile): `vBot/analyzer.lua` 23, `vBot/training.lua` 6,
`vBot/new_healer.lua` 4, `vBot/extras.lua` 4, `vBot/AttackBot.lua` 4, `targetbot/creature_editor.lua`
4, `cavebot/config.lua` 4, `vBot/playerlist.lua` 3, `vBot/Equipper.lua` 3, `cavebot/imbuing.lua` 3,
`vBot/supplies.lua` 2, `vBot/Stances.lua` 2, `vBot/HealBot.lua` 2, `cavebot/editor.lua` 2, and one
each in `vBot/cavebot_control_panel.lua`, `vBot/alarms.lua`, `targetbot/target.lua`,
`targetbot/looting.lua`, `targetbot/creature.lua`, `cavebot/extension_template.lua`,
`cavebot/cavebot.lua`, `cavebot/actions.lua`.

`UI.createWindow` styles required (24): `NaviBotWindow`, `FeaturesWindow`, `ConditionsWindow`,
`ComboWindow`, `BotServerWindow`, `DepositerPanel`, `ContListsWindow`, `AttackBotWindow`,
`AttackBotSpellPicker`, `AlarmsWindow`, `TargetBotCreatureEditorWindow`, `EquipWindow`,
`CaveBotConfigWindow`, `HealWindow`, `ExtrasWindow`, `ImbuingConfigWindow`, `FriendHealer`,
`VocationThresholdWindow`, `PushMaxWindow`, `PlayerListWindow`, `SioListWindow`, `StancesWindow`,
`SuppliesWindow`, `TrainingWindow`.

---

## 4. Widget methods — full inventory with call counts

Counts are call sites in `profiles/bot/vBot_4.8` (`.bak` excluded). Where a name is shared with a
non-widget class the widget share is noted.

### 4.1 Text / value accessors

| Method | Count | Contract | Verdict |
|---|---|---|---|
| `setText(text, dontFireLuaCall?)` | 299 | Coerce to string (callers pass numbers: `targetbot/looting.lua:60-61`, `targetbot/target.lua:97`). If the value changed and `dontFireLuaCall` is falsy → fire `onTextChange(self, newText, oldText)` (`uiwidgettext.cpp:366-393`). **The 2nd arg is used by `cavebot/config.lua:108,138` to break a setter → `CaveBot.save()` recursion.** | **IMPLEMENT** |
| `getText()` | 75 | last stored string, `""` default | **IMPLEMENT** |
| `setColoredText(t, dontFire?)` | 3 | store plain text, ignore colours | **STATEFUL STUB** |
| `clearText()` | 1 | `setText("")` | **STATEFUL STUB** |
| `setValue(v)` | 37 | clamp to `[minimum,maximum]`; no-op if unchanged; else fire `onValueChange(self, math.round(v), delta)` **only when `setupDone`** (`uiscrollbar.lua:372-383`). Defaults `value=0, minimum=-999999, maximum=999999, step=1` | **IMPLEMENT** |
| `getValue()` | 29 | `math.round(value)` | **IMPLEMENT** |
| `setRange(min,max)` / `setMinimum` / `setMaximum` | 5 | clamps the current value into range, may fire `onValueChange` | **IMPLEMENT** |
| `setStep(n)` / `getStep()` | 5 | plain field | **STATEFUL STUB** |
| `setPercent` / `getPercent` | 4 / 2 | progress bar 0-100 | **STATEFUL STUB** |

### 4.2 Boolean state

| Method | Count | Contract | Verdict |
|---|---|---|---|
| `setOn(bool)` | 125 | set the `on` state. **Fires nothing** (`UIWidget::setOn`, `uiwidget.cpp:1297-1300`). The extra 2nd arg at `cavebot/config.lua:123` is ignored by C++ too | **STATEFUL STUB** |
| `isOn()` | 29 | the stored bool. **Load-bearing** at `functions/config.lua:169,232-258` (CaveBot/TargetBot on/off), `targetbot/looting.lua:13,21,105` (`everyItem` loot mode), `targetbot/target.lua:27,39` | **STATEFUL STUB** |
| `setOff()` | 1 | `setOn(false)` | **STATEFUL STUB** |
| `setChecked(bool)` | 132 | set `checked`; **fires `onCheckChange(checked)` on change** (`uiwidget.cpp:1302-1306`) | **STATEFUL STUB** |
| `isChecked()` | 13 | stored bool. Read at `vBot/AttackBot.lua:2056,2130,2239,2240`, `vBot/Stances.lua:254,285,375`, `vBot/Equipper.lua:300,306,307`, `vBot/new_healer.lua:719,722` | **STATEFUL STUB** |
| `setEnabled(b)` / `enable()` / `disable()` | 42 / 6 / 7 | stored bool | **STATEFUL STUB** |
| `setVisible(b)` / `show()` / `hide()` | 20 / 37 / 92 | store *explicit* visibility; recompute **effective** visibility (self ∧ all ancestors) for self and every descendant; fire `onVisibilityChange(effective)` on each transition (`uiwidget.cpp:1811-1817`, `1970-1975`). Hiding a focused widget re-focuses the previous sibling (`uiwidget.cpp:1277-1280`) | **IMPLEMENT** |
| `isVisible()` | 12 | effective visibility. Read at `vBot/HealBot.lua:332`, `cavebot/config.lua:77`, `vBot/Equipper.lua` (4), `cavebot/imbuing.lua` (2), `vBot/supplies.lua`, `navibot/navibot.lua`, `vBot/analyzer.lua` (2) | **IMPLEMENT** |
| `setMarked(color)` | 9 | **creature**, not widget (`playerlist.lua:53,81,103,133`, `extras.lua:654,662`, `stand_lure.lua:114`, `looting.lua:339`) — outside A2 | **INERT STUB** |

### 4.3 Identity, tree, ordering

| Method | Count | Contract | Verdict |
|---|---|---|---|
| `setId(id)` | 39 | store id; **remove the old / install the new Lua field on the parent**; update the parent's id map (`uiwidget.cpp:1056-1072`) | **IMPLEMENT** |
| `getId()` | 149 total, widget share ≈ 25 (the rest are `item:getId()` / `creature:getId()`) | stored id | **IMPLEMENT** |
| `getChildById(id)` | 5 (`vBot/training.lua` 2, `combo.lua`, `analyzer.lua`, `Containers.lua`) | exact-match lookup in the id map; nil if absent | **IMPLEMENT** |
| `recursiveGetChildById(id)` | 1 (`vBot/analyzer.lua:91`) + 4 in `bot.lua:44-63` | depth-first: own map first, then each child recursively (`uiwidget.cpp:1528-1541`) | **IMPLEMENT** |
| `getChildren()` | 47 | **ordered array** of children | **IMPLEMENT** |
| `getChildByIndex(i)` | 12 (`cavebot/cavebot.lua` 9, `cavebot/antilost.lua` 2, `new_healer.lua` 1) | **1-based** for `i>0`; for `i<=0` counts from the end (`index = size + i`, so `0`→last, `-1`→second-to-last) — `uiwidget.cpp:1509-1516`. `getLastChild()` is literally `getChildByIndex(-1)` | **IMPLEMENT (exact quirk)** |
| `getChildIndex(child?)` | 34 | 1-based index of `child`; `-1` if it is not our child; **`getChildIndex(nil)` returns the widget's own index in *its* parent** (`uiwidget.h:524`). `cavebot/cavebot.lua:214` relies on this when `getFocusedChild()` is nil | **IMPLEMENT (exact quirk)** |
| `getChildCount()` | 21 | `#children` | **IMPLEMENT** |
| `getFirstChild()` | 5 | `getChildByIndex(1)` | **IMPLEMENT** |
| `getLastChild()` | 2 | `getChildByIndex(-1)` | **IMPLEMENT** |
| `getParent()` | 21 (widget share ≈ 9) | parent or nil | **IMPLEMENT** |
| `moveChildToIndex(child, i)` | 19 | reorder in place, 1-based target (`uiwidget.cpp:552-575`); reindex siblings | **IMPLEMENT** |
| `destroy()` | 37 | detach from the parent (clearing the parent's Lua field and id entry), mark destroyed, destroy children; if it was the focused child and the parent's auto-focus policy ≠ `none`, re-focus the previous sibling (`uiwidget.cpp:349-350`) | **IMPLEMENT** |
| `destroyChildren()` | 21 | destroy all, clear focus | **IMPLEMENT** |
| `isDestroyed()` | 3 | flag | **STATEFUL STUB** |
| `addChild` / `insertChild` / `removeChild` | 0 direct in the profile (used internally by the shim) | — | **IMPLEMENT** |
| `getChildByPos` / `recursiveGetChildByPos` | 4 (`playerlist.lua:218,269`, …) | needs real geometry | **BLOCKER** (reached only from `onMouseRelease`) |

### 4.4 Focus

| Method | Count | Contract | Verdict |
|---|---|---|---|
| `focusChild(child, reason?)` | 11 (`cavebot/cavebot.lua` 7 — the program counter — plus `Containers`, `route_tools`, `imbuing`, `editor`) | no-op if already focused or `child` is not ours; set `focusedChild`; fire `child.onFocusChange(true, reason)`, the old child's `onFocusChange(false, reason)`, then `self.onChildFocusChange(newChild, oldChild, reason)` (`uiwidget.cpp:357-390`) | **IMPLEMENT** |
| `getFocusedChild()` | 32 | the stored child or nil | **IMPLEMENT** |
| `focus()` | 36 | `parent:focusChild(self, ActiveFocusReason)` — no-op when parentless | **IMPLEMENT** |
| `focusNextChild` / `focusPreviousChild` | 0 direct; required by the `destroy` / `setVisible` fallbacks | rotate through focusable, visible, enabled children | **IMPLEMENT** |
| `ensureChildVisible(child)` | 14 | scrolling only | **INERT STUB** |
| `raise()` | 30 | z-order | **INERT STUB** |

### 4.5 Items (UIItem)

| Method | Count | Contract | Verdict |
|---|---|---|---|
| `setItemId(id)` | 44 | store id; **always fires `onItemChange()`** — there is no `dontSignal` argument (`src/client/uiitem.cpp:107-122`); `cavebot/config.lua:159-175` works around this with its own `applyingItem` flag | **IMPLEMENT** |
| `getItemId()` | 38 | stored id, `0` when empty (`uiitem.cpp:171`) | **IMPLEMENT** |
| `setItem(item)` / `getItem()` | 1 / 1 | takes an `Item` object (`Item.create(id, count)`) | **IMPLEMENT** (needs an `Item` value object with `getId`/`getCount`) |
| `setItemCount(n)` / `getItemCount()` | 3 / 1 | count / subtype | **STATEFUL STUB** |
| `getItemCountOrSubType()` | 1 in the profile (+ `ui_elements.lua:90`, `training.lua:546`) | count for stackables, subtype otherwise; used to build `{id=,count=}` in `UI.Container:getItems()` | **IMPLEMENT** |
| `getItemSubType()` | 0 in the profile (`ui_elements.lua:185`) | subtype | **STATEFUL STUB** |
| `setShowCount(b)` / `setVirtual(b)` / `clearItem()` | 4 / 0 / 0 | — | **INERT STUB** |

### 4.6 ComboBox

| Method | Count | Contract | Verdict |
|---|---|---|---|
| `addOption(text, data?)` | 37 (8 in `HealBot.otui` `@onSetup`, 6 in `combo.otui`, 3 in `equipper.otui`, 2 in `Conditions.otui`, plus 18 in Lua) | append `{text=,data=}`; **if it is the first option, `setCurrentOption(text)`** (`uicombobox.lua:90-100`). This is what makes `getCurrentOption()` non-nil at load | **IMPLEMENT** |
| `getCurrentOption()` | 12 | `options[currentIndex]` or **nil**; callers immediately index `.text`. Sites: `_Loader.lua:2`, `vBot/configs.lua:5`, `cavebot/cavebot.lua:553`, `targetbot/target.lua:224` (bot config name); `vBot/HealBot.lua:479,480,516,517`; `vBot/combo.lua:114,119`; `vBot/Conditions.lua:148`; `vBot/Stances.lua:276` | **IMPLEMENT** |
| `setCurrentOption(text, dontSignal?)` / `setOption` | 4 | find by text; if the index changes, set it, `setText(text)`, and unless `dontSignal` fire `onOptionChange(self, text, data)` | **IMPLEMENT** |
| `setCurrentIndex(i)` | 3 (+ `functions/config.lua:163`) | if `1<=i<=#options`: set, `setText`, and **always** fire `onOptionChange` (`uicombobox.lua:75-82`) | **IMPLEMENT** |
| `clearOptions()` / `clear()` | 2 (+ `functions/config.lua:154`) | empty options, `currentIndex = -1`, `clearText()` | **IMPLEMENT** |
| `getCurrentIndex()` / `isOption()` / `removeOption()` | 0 in the profile | — | **STATEFUL STUB** |
| `.options` (raw field) | read at `bot.lua:214` | array of `{text,data}` | **IMPLEMENT** |

### 4.7 Cosmetic — all **INERT STUB** (must exist and return `self`/`0`)

`setColor` 61 · `setTooltip` 46 · `setImageSource` 18 · `setImageClip` 9 · `setWidth` 9 ·
`setHeight` 8 · `setBackgroundColor` 7 · `setImageColor` 6 · `setTitle` 5 · `setShowCount` 4 ·
`setImageSize` 3 · `setContentMaximumHeight` 3 · `setBorderWidth` 2 · `setBorderColor` 2 ·
`getSize` 2 · `setTextAutoResize` 1 · `setTTFFont` 1 · `setPosition` 1 · `setPhantom` 1 ·
`setLineWidth` 1 · `setLineColor` 1 · `setFont` 1 · `setContentWidget` 1 · `setContentHeight` 1 ·
`minimize` 1 · `breakAnchors` 1 · `clone` 1 · `addSeparator` 1 · `getWidth` 1 · `getHeight` 1 ·
`getBackgroundColor` 1 · `addTab` 1 · `getTabPanel` 1 · `getCurrentTab` 1 · `createGraph` 1 ·
`getGraphsCount` 1 · `addValue` 1 · `setCapacity` 1.

Caution: `getWidth()` returning `0` is *safer* than returning a fake number — the only readers
(`ui_elements.lua:303,328,373`) use it to decide whether to clamp a width, and `0 > 88` is false.

---

## 5. Where the source of truth actually lives — concrete cases

### 5.1 HealBot — **config table**, widget is a pure mirror

`vBot/HealBot.lua`. `HealBotConfig` is loaded from
`/bot/<cfg>/vBot_configs/profile_<n>/HealBot.json` in `vBot/configs.lua:22-39` and written by
`vBotConfigSave("heal")` (`configs.lua:63-97`). `currentSettings = HealBotConfig[healPanelName][n]`
(`HealBot.lua:284-289`).

* The healing macro reads **only** `currentSettings.spellTable` / `.itemTable`
  (`HealBot.lua:690`, `750`, `775`) — never a widget.
* Widgets are written *from* config: `refreshSpells()` (`:373-397`) and `refreshItems()` (`:399-421`)
  rebuild `healWindow.healer.spells.spellList` / `.items.itemList` from the tables.
* Checkbox handlers flip the *table* and then mirror to the widget: `HealBot.lua:348-370`
  (`currentSettings.Visible = not currentSettings.Visible ;
  healWindow.settings.list.Visible:setChecked(currentSettings.Visible)`).
* `ui.title:setOn(currentSettings.enabled)` (`:302`) and `ui[i]:setColor(...)` (`:292-299`) are
  display only.
* All read-backs (`:479-481`, `:516-518`) are inside `addSpell.onClick` / `addItem.onClick`, i.e.
  user-only.

⇒ **STATEFUL STUB is sufficient for HealBot's entire UI.**

### 5.2 AttackBot — **widget list is the runtime truth**, table is the persistence format

`vBot/AttackBot.lua`. `AttackBotConfig` ⇄ `AttackBot.json`, same mechanism as HealBot.

* `refreshAttacks()` (`:2210-2221`) builds `panel.entryList` children from
  `currentSettings.attackTable`, hanging the *same table reference* on each child:
  `label.params = entry`.
* **The attack loop iterates the widget list**: `AttackBot.lua:2783`
  `for i, child in ipairs(panel.entryList:getChildren()) do local entry = child.params …`,
  gated by `#currentSettings.attackTable == 0` at `:2727`.
* Write-back happens only on window hide: `mainWindow.onVisibilityChange` (`:1781-1789`) rebuilds
  `currentSettings.attackTable` from `panel.entryList:getChildren()` and saves.
* Settings checkboxes (`settingsUI.Rotate/.Kills/.CustomCooldown/.ServerCooldown/.Visible/.PvpMode/
  .PvpSafe/.BlackListSafe/.RuneDelayEnabled`, `:2316-2440`) flip `currentSettings.*` first, then
  mirror with `setChecked` — the table is truth.

⇒ Needs **ordered children + arbitrary per-child Lua fields**; ordering is the attack priority.

### 5.3 `CaveBot.Config` — **`CaveBot.Config.values` table**, widget is a mirror

`cavebot/config.lua`. `add(id, title, default)` (`:96-185`) creates one row widget per key plus a
`setter` closure. Every setter writes `CaveBot.Config.values[id]` **first**, then mirrors to the
widget (`:107-108`, `:122-123`, `:137-138`, `:165-167`). `CaveBot.Config.get(id)` (`:187-192`) reads
the table, never the widget; `CaveBot.Config.save()` (`:92`) returns the table.

Two exactness traps the shim must honour:
* `panel.value:setText(value, true)` and `panel.value:setOn(value, true)` — the `true` suppresses
  `onTextChange`; without it the setter re-enters `CaveBot.save()`.
* `panel.value:setItemId(value)` has **no** suppress argument, which is why `:159-175` guards it with
  `applyingItem`. Match the C++ and **always fire `onItemChange`** — `vBot/extras.lua:66-68` and
  `targetbot/creature_editor.lua:50-51` use the same widget type and would behave differently
  otherwise.

Row styles: `CaveBotConfigNumberValuePanel`, `CaveBotConfigBooleanValuePanel`,
`CaveBotConfigTextValuePanel`, `CaveBotConfigItemValuePanel` (`cavebot/config.otui:49-130`), each
with `title` and `value` children.

⇒ **STATEFUL STUB** for the rows, plus faithful `dontFireLuaCall` handling.

### 5.4 CaveBot waypoints — **widget list IS the truth** (no shadow table exists)

`cavebot/cavebot.lua`, `cavebot/actions.lua`.

* `CaveBot.actionList = ui.listPanel.list` (`cavebot.lua:62-63`), style `TextList` with
  `auto-focus: first` (`cavebot/cavebot.otui:23-29`).
* `CaveBot.addAction` (`actions.lua:185-227`) creates a `CaveBotAction` label,
  `setText(action..":"..value)`, then hangs **`widget.action`, `widget.value`, `widget.stayPos`** on
  it plus `widget.onDoubleClick`.
* `CaveBot.save()` (`cavebot.lua:578-610`) serialises by iterating `ui.list:getChildren()` and reading
  `child.action` / `child.value` / `child.stayPos`.
* The macro (`cavebot.lua:80-203`) uses `getChildCount`, `getFocusedChild`, `getFirstChild`,
  `getChildIndex`, `getChildByIndex`, `focusChild` — **`getFocusedChild()` is the program counter**
  and `focusChild(getChildByIndex(next))` is "advance".
* Other readers: `previousRoutePosition` (`:37-56`), `gotoNextWaypointInRange` (`:352-401`),
  `gotoFirstPreviousReachableWaypoint` (`:422-455`), `getFirstWaypointBeforeLabel` (`:457-496`),
  `getPreviousLabel` / `getNextLabel` (`:498-551`), `gotoLabel` (`:567-576`) — several match on
  `child:getText()` with `string.starts(text, "goto:")`.
* `cavebot/stand_lure.lua:167` does `modules.game_bot.connect(CaveBotList(), {onChildFocusChange=…})`,
  so the list must actually emit `onChildFocusChange(newChild, oldChild, reason)`.

### 5.5 TargetBot creature list — **widget list IS the truth**

`targetbot/target.lua`, `targetbot/creature.lua`.

* `TargetBot.targetList = ui.listPanel.list` (`target.lua:13-14`), `TextList` with
  `auto-focus: first` (`targetbot/target.otui:48-54`).
* `TargetBot.Creature.addConfig` (`creature.lua:15-51`) creates a `TargetBotEntry`,
  `setText(config.name)`, `widget.value = config` (the whole config table).
* `TargetBot.Creature.getConfigs` (`creature.lua:53-72`) — **runtime hot path** — iterates
  `TargetBot.targetList:getChildren()` and regex-matches `config.value.regex`.
* `TargetBot.save` (`target.lua:238-245`) iterates `ui.list:getChildren()` collecting `entry.value`.
* `resetConfigs` (`creature.lua:5-8`) = `destroyChildren()`.
* Status labels `ui.status.right` / `ui.target.right` / `ui.config.right` / `ui.danger.right`:
  `TargetBot.getStatus()` (`target.lua:194-196`) **reads `ui.status.right:getText()` back**, so
  `setText` must round-trip. `Config.setup`'s callback writes `"On"`/`"Off"` there
  (`target.lua:133,144`).

### 5.6 TargetBot looting — **`BotContainer` widget items are the truth**

`targetbot/looting.lua`. `TargetBot.Looting.save` (`:75-81`) reads `ui.items:getItems()`,
`ui.containers:getItems()`, `ui.maxDangerPanel.value:getText()`,
`ui.minCapacityPanel.value:getText()`, `ui.everyItem:isOn()`. `updateItemsAndContainers` (`:83-94`)
re-reads `getItems()` into the runtime `items`/`containers` tables; `TargetBot.Looting.process`
(`:105`) gates on `ui.everyItem:isOn()`. ⇒ the `BotItem` grid must faithfully store ids/counts, and
`getItems()` must filter `getItemId() >= 100` and de-duplicate when `unique`
(`ui_elements.lua:84-96`).

### 5.7 Macros / extras / supplies / training — **`storage` table is the truth**

* `context.macro` (`functions/main.lua:42-105`): `storage._macros[name]` is truth;
  `macro.switch:setOn(...)` mirrors (`:70-88`). The switch only exists for *named* macros.
* `vBot/extras.lua:35-102`: `storage.extras[id]` is truth; `addCheckBox` / `addItem` / `addTextEdit` /
  `addScrollBar` mirror. Note `addScrollBar` calls
  `widget.scroll.onValueChange(widget.scroll, widget.scroll:getValue())` **explicitly** at `:102`, so
  the setting is populated even when `setValue` suppresses the signal.
  `cavebot/cavebot.lua:366,387,443,489` then reads `storage.extras.gotoMaxDistance`.
* `vBot/training.lua:410-476` follows the same pattern.
* `vBot/supplies.lua:211-216` is the exception: it reads `panel.id:getItemId()` and
  `panel.min/max/avg:getValue()` back out of the widget tree ⇒ those must be genuinely stateful.

---

## 6. The list-like widgets, precisely

### 6.1 Which styles are used as lists

`TextList < UIScrollArea` (`data/styles/10-listboxes.otui:1-7`) with `layout: verticalBox` and
`auto-focus: none`; overridden to `auto-focus: first` for the two program-counter lists.

| List | Style / declaration | auto-focus | Child style | Fields hung on children |
|---|---|---|---|---|
| CaveBot waypoints | `cavebot/cavebot.otui:23` `TextList id:list` | **first** | `CaveBotAction < Label` (`focusable: true`) | `.action`, `.value`, `.stayPos`, `.stayPathStaleLogged`, `.onDoubleClick` |
| TargetBot creatures | `targetbot/target.otui:48` `TextList id:list` | **first** | `TargetBotEntry < Label` (`focusable: true`) | `.value` (full config table), `.onDoubleClick` |
| AttackBot attacks | `vBot/AttackBot.otui:144` `TextList id:entryList` | none (inherited) | `AttackEntry < UIWidget` (`focusable: true`, child `CheckBox id:enabled`) | `.params`, `.onClick`, `.onDoubleClick` |
| HealBot spells / items | `vBot/HealBot.otui:181,294` | none | `SpellEntry` / `ItemEntry < Label` | none (entries capture the table row in a closure) |
| Stances / Equipper / Supplies / new_healer / imbuing | `Stances.otui`, `equipper.otui:172,433`, `supplies.otui`, `new_healer.otui:250,273`, `imbuing.otui:144` | none | various | `.value`, `.params`, `.key`, `.enabled` |

### 6.2 Operations a headless list must support

`destroyChildren` · `getChildren` (ordered) · `getChildCount` · `getChildByIndex` (1-based, negative
from the end) · `getChildIndex(child)` (1-based; `-1` for a foreign child; own index for `nil`) ·
`focusChild(child)` · `getFocusedChild` · `getFirstChild` · `getLastChild` · `moveChildToIndex` ·
`ensureChildVisible` (no-op) · per-child `setText` / `getText` / `destroy` / `setColor` ·
**arbitrary Lua field get/set on children** — non-negotiable: that is how the payload travels.

### 6.3 Auto-focus — the exact rule (must be copied)

`UIWidget::applyStyle` (`src/framework/ui/uiwidget.cpp:727-736`), evaluated **once**, on the widget's
first style application (i.e. right after it is created and parented):

```
if firstOnStyle and isFocusable and isExplicitlyVisible and isExplicitlyEnabled and parent then
  if (parent.focusedChild == nil and parent.autoFocusPolicy == 'first')
     or parent.autoFocusPolicy == 'last' then
    self:focus()
  end
end
```

The default policy on a bare `UIWidget` is **`last`** (`uiwidget.h:373`); `Panel` and
`ScrollablePanel` declare `auto-focus: first` (`data/styles/10-panels.otui`); `TextList` declares
`auto-focus: none`.

Consequences that change bot behaviour if you get them wrong:
* CaveBot: loading a route focuses **waypoint 1** and nothing else; the macro then walks the list by
  `focusChild`. `cavebot.lua:285-288` (`if lastConfig == name then
  ui.list:focusChild(getChildByIndex(currentActionIndex))`) restores the position across a config
  reload and only behaves correctly with a real focus model.
* On `destroy` / `setVisible(false)` of the focused child, the parent re-focuses the **previous**
  sibling with rotation (`uiwidget.cpp:349-350`, `1277-1280`). `targetbot/target.lua:176`
  (`entry:destroy()`) and `HealBot.lua:388,414` (`label:destroy()`) rely on the list never being left
  pointing at a dead widget.

---

## 7. Widget event callbacks — inventory and firing policy

Assignment counts in the profile: `onClick` 248 · `onTextChange` 43 · `onValueChange` 16 ·
`onDoubleClick` 16 · `onItemChange` 15 · `onVisibilityChange` 9 · `onOptionChange` 8 ·
`onMouseRelease` 7 · `onMouseWheel` 5 · `onGeometryChange` 4 · `onHoverChange` 3 · `onStyleApply` 1 ·
`onKeyPress` 1 · `onEscape` 1 · `onClose` 1. (`onSave` / `onConfigChange` / `onItemsUpdate` /
`onCastEnabled` / … are vBot-internal tables, not widget signals.)

| Signal | Fired by the shim? | Why |
|---|---|---|
| `onTextChange(widget, newText, oldText)` | **YES** — from `setText` unless `dontFireLuaCall` | `cavebot/config.lua:111,141`, `targetbot/looting.lua:24,32`, `HealBot.lua:344`, `AttackBot.lua:2313`, `extras.lua:77` all install real logic here that must run when the shim programmatically populates fields |
| `onValueChange(scroll, value, delta)` | **YES** — from `setValue`/`setRange` when `setupDone` | `targetbot/creature_editor.lua:12`, `extras.lua:86`, `new_healer.lua:915`, `training.lua:447` |
| `onItemChange(widget)` | **YES** — from `setItemId`/`setItem`/`setItemCount` (always; no suppress argument exists) | `extras.lua:66`, `cavebot/config.lua:171`, `ui_elements.lua:79,183,264,272` |
| `onOptionChange(widget, text, data)` | **YES** — from `setCurrentOption` (unless `dontSignal`) and `setCurrentIndex` | `functions/config.lua:174`, `bot.lua:201,238` |
| `onCheckChange(checked)` | **YES** — from `setChecked` on change | matches C++ (`uiwidget.cpp:1302-1306`); no vBot handler installed, but harmless |
| `onVisibilityChange(widget, visible)` | **YES** — from `show`/`hide`/`setVisible`, propagated to descendants on transition | `HealBot.lua:321`, `AttackBot.lua:1781`, `cavebot/config.lua:19`, `Equipper`, `supplies` |
| `onFocusChange(focused, reason)` / `onChildFocusChange(new, old, reason)` | **YES** — from `focusChild` | `cavebot/stand_lure.lua:167` connects to `onChildFocusChange` on the CaveBot list |
| `onSetup()` | **YES** — after the widget's children are built (mirrors `createWidgetFromOTML`, `uimanager.cpp:733`) | the 7 `@onSetup` ComboBox blocks |
| `onStyleApply(styleName, node)` | optional | 1 site |
| `onClick`, `onDoubleClick`, `onMousePress/Release/Wheel`, `onDragEnter/Move/Drop`, `onHoverChange`, `onKeyDown/Press/Up`, `onEscape`, `onEnter`, `onGeometryChange`, `onClose` | **NO** — store only | nothing headless generates input, geometry or window-manager events |

**Signal storage must follow `connect()` semantics** (`modules/corelib/util.lua:43-88`): a signal
field holds either a single function *or an array of functions*; `disconnect` removes one and
collapses a 1-element array back to a bare function. The shim's internal `callLuaField(name, ...)`
must therefore be `signalcall`-shaped (`if type(f)=='table' then for _,fn in ipairs(f) do fn(...) end
else f(...) end`). This is required because `modules.game_bot.connect` is exposed to vBot and used on
a widget at `cavebot/stand_lure.lua:167`.

---

## 8. What CANNOT be satisfied by a stateful stub — BLOCKER list

### 8.1 Hard blockers (no headless equivalent)

| Site | Call | Why it blocks | Impact |
|---|---|---|---|
| `vBot/playerlist.lua:218,269` | `rootWidget:recursiveGetChildByPos(mousePos)` | needs real widget rectangles | none — inside `onMouseRelease` |
| `vBot/playerlist.lua:220,271,321`, `vBot/xeno_menu.lua:5`, `cavebot/minimap.lua:17` | `g_ui.createWidget('PopupMenu')` + `menu:display(pos)` | popup menus are input-driven and pixel-positioned | none — all inside mouse handlers |
| `cavebot/minimap.lua:20` | `minimap:createFlagWindow(mapPos)` | real minimap widget | none |
| `cavebot/antilost.lua:730-772` | `tile:attachEffect`, `tile:attachWidget(g_ui.createWidget('Label', getMapView()))`, `getAttachedWidgetById`, `detachEffectById` | attaches widgets/effects to map tiles for the on-map waypoint HUD | none — every call is inside `pcall`, and the whole block is gated by `CaveBot.Config.get("waypointHud")`, default **false** (`cavebot/config.lua:59`) |
| `vBot/vlib.lua:30` | `g_ui.getRootWidget().charactersWindow.characters` | the login/character-list window of `client_entergame` | used by the auto-relogin path (`vlib.lua:36` → `modules.client_entergame.CharacterList.doLogin`); the shim must own reconnect and stub this |
| `vBot/analyzer.lua:587,1718` | `modules.game_skills.skillsWindow.contentsPanel.level.percent:getPercent()` | reads level progress out of the skills UI | analyzer display only |
| `vBot/analyzer.lua:754` | `modules.game_skills…stamina.value:getText()` | same | analyzer display only |
| `vBot/analyzer.lua:958-987` | `modules.game_textmessage.messagesPanel.…:setColoredText` / `:setVisible` / `:getText` | the on-screen message overlay | analyzer display only |
| `vBot/quiver_label.lua:1-15` | `modules.game_inventory.getSlot5()` then `g_ui.loadUIFromString(..., quiverSlot)` | parents a label to a real inventory-slot widget | cosmetic; provide a stub slot widget so the parenting does not error |
| `vBot/analyzer.lua:198-205` | `modules.game_buttons.buttonsWindow…`, `modules.client_topmenu.getButton`, `modules.game_mainpanel.addToggleButton` | client chrome | analyzer toggle button only |
| `functions/ui_windows.lua:141-183` | `modules.client_textedit.edit(...)`, `displayGeneralBox(...)` | modal editors / dialogs | reachable only from `onClick`; return a dummy widget |
| `vBot/Containers.lua:414,552` | `containerWindow:setContentHeight`, `:minimize()` | real container windows from `game_containers` | cosmetic; the container *logic* uses `g_game`, not these |
| `vBot/analyzer.lua:524-591` | `UIGraph:createGraph/addValue/setTitle/setLineColor` | chart rendering | analyzer display only |
| any | `setFont` / `setTTFFont` / `getWidth` / `getHeight` / `getRect` / `getX` / `getY` | no font metrics, no layout engine | see the §4.7 caution |

### 8.2 Soft blockers — handlers that must be *callable* even though input never fires them

These sites invoke a stored handler directly. If handlers are stored as plain fields on the widget
table they all work with no extra machinery — but note `widget.switch:onClick()` passes the widget as
`self`.

| Site | Call |
|---|---|
| `mods/game_bot/functions/config.lua:241,246,252,257` | `widget.switch:onClick()` — **this is how `CaveBot.setOn()` / `TargetBot.setOff()` actually work**; the handler at `config.lua:181-184` toggles the switch and calls `refresh()`. **Load-bearing.** |
| `vBot/combo.lua:209` | `child:onClick()` |
| `vBot/Equipper.lua:317,319,325,327` | `inputPanel.condition.nex.onClick()` |
| `vBot/playerlist.lua:302` | `addButton.onClick()` |
| `vBot/supplies.lua:388,390` | `SuppliesWindow.increment.onClick()` |
| `vBot/training.lua:366` | `ui.title.onClick(ui.title)` |
| `targetbot/creature_editor.lua:22`, `vBot/extras.lua:102`, `vBot/new_healer.lua:920`, `vBot/training.lua:456` | `widget.scroll.onValueChange(widget.scroll, widget.scroll:getValue())` |
| `cavebot/config.lua:21` | `CaveBot.Config.onVisibilityChange(visible)` |
| `mods/game_bot/functions/icon.lua:108` | `widget:onClick()` (unused by this profile) |

### 8.3 Behaviour that silently *differs* headless (document, do not "fix")

* **AttackBot never writes `attackTable` back**, because `mainWindow.onVisibilityChange` (`:1781`)
  only runs on hide and nothing hides it headless. Harmless while no edits happen; matters if a
  control plane ever mutates the list.
* **`getWidth()` = 0** disables the label-width clamps in `UI.DualLabel` / `UI.LabelAndTextEdit` /
  `UI.SwitchAndButton`. Cosmetic.
* **`$state` text swaps do not happen** (`Show config` / `Hide config` captions). Nothing reads them.
* **`ensureChildVisible` and scrollbars are no-ops**, so `UI.Container`'s `scrollToBottom()`
  (`ui_elements.lua:28-33`) does nothing. It is already defensive
  (`if scrollbar and scrollbar.setValue and scrollbar.getMaximum`).

---

## 9. Design: the minimal stateful widget

One Lua class covers every style; per-`__class` behaviour is a small mixin table selected at creation
time. No inheritance chain from otclient is needed.

### 9.1 Instance state

```lua
W = {
  -- identity / tree
  id = "",  parent = nil,  children = {},      -- ordered array
  childrenById = {},                            -- id -> widget
  childIndex = -1,  destroyed = false,
  styleName = "",  class = "UIWidget",

  -- generic state
  text = "",  tooltip = "",
  on = false, checked = false, enabled = true,
  explicitVisible = true,                       -- what setVisible/show/hide set
  effectiveVisible = true,                      -- self AND all ancestors
  focusable = false, autoFocus = "last",        -- 'first' | 'last' | 'none'
  focusedChild = nil,  firstOnStyle = true,

  -- UIItem
  itemId = 0, itemCount = 1, itemSubType = 0,

  -- UIComboBox
  options = {}, currentIndex = -1,

  -- UIScrollBar / UISpinBox
  value = 0, minimum = -999999, maximum = 999999, step = 1, setupDone = false,
}
```

Everything else the tree carries (`.action`, `.value`, `.stayPos`, `.params`, `.botWidget`,
child-widget references, `&`-fields) is just an arbitrary key on the same table.

### 9.2 `__index` / `__newindex` — the one piece of real cleverness

otclient resolves `widget.foo` in this order (`LuaInterface::luaObjectGetEvent`,
`src/framework/luaengine/luainterface.cpp:200-240`): **1.** a `get_foo` field-method · **2.** a Lua
field set on the object (this is where child ids and `onClick` live) · **3.** a class method.

The shim inverts this into idiomatic Lua with **no lookup metatable magic at all**, provided child
ids and signals are stored as plain keys on the widget table and methods live on the metatable's
`__index`:

```lua
local mt = { __index = Methods }   -- methods are the FALLBACK, fields win
setmetatable(w, mt)
-- setId(child):  rawset(parent, childId, child)
-- widget.onClick = fn:  plain rawset
```

Collision rule to replicate exactly: `setId` installs the Lua field **only if the parent does not
already have a field of that name** (`UIWidget::addChild`, `uiwidget.cpp:222-227`,
`if (!hasLuaField(widgetId))`). vBot depends on this working for ids that collide with method names:
`healWindow.healer.items.itemList`, `panel.value`, `label.enabled`, `widget.items`,
`ui.status.right`, `ui.title`, `ui.list`.

Numeric ids: `HealBot.otui:219-255` declares `id: 1` … `id: 5` and `HealBot.lua:292-299` reads
`ui[i]` with a **number** `i`. OTML gives the string `"1"`. **In `setId`, if `tonumber(id)` is
non-nil, also set the numeric key** (or add an `__index` fallback that retries `tostring(k)`).

`getChildById(id)` uses the separate `childrenById` map, which — unlike the Lua field — is *always*
written, even on collision.

### 9.3 Methods that must be real (≈30)

`setId/getId` · `setText/getText` · `setValue/getValue/setRange/setMinimum/setMaximum` ·
`setOn/isOn/setOff` · `setChecked/isChecked` · `setEnabled/enable/disable` ·
`setVisible/show/hide/isVisible` ·
`setItemId/getItemId/setItem/getItem/getItemCountOrSubType` ·
`addOption/getCurrentOption/setCurrentOption/setCurrentIndex/clearOptions/clear` ·
`addChild/insertChild/removeChild/destroy/destroyChildren/isDestroyed` ·
`getChildren/getChildById/recursiveGetChildById/getChildByIndex/getChildIndex/getChildCount/getFirstChild/getLastChild/getParent` ·
`moveChildToIndex` · `focus/focusChild/getFocusedChild/focusPreviousChild/focusNextChild`.

### 9.4 Methods that may `return self` and do nothing (≈45)

`setColor setBackgroundColor getBackgroundColor setTooltip getTooltip setImageSource setImageClip
setImageColor setImageSize setImageOffset setWidth setHeight setSize getSize setPosition
setMarginTop setMarginLeft setMarginRight setMarginBottom setFont setTTFFont setTextAlign
setTextAutoResize setTextOffset setTextWrap setPhantom setDraggable setBorderWidth setBorderColor
setOpacity raise lower breakAnchors addAnchor removeAnchor fill ensureChildVisible updateLayout
getLayout setup close open minimize maximize setTitle setContentWidget setContentHeight
setContentMaximumHeight setShowCount setVirtual setPercent getPercent setStep getStep setMarked
clone applyStyle mergeStyle setFocusable setAutoFocusPolicy`.

Return-value contracts for the few that are actually *read*: `getWidth()/getHeight()/getX()/getY()`
→ `0`; `getSize()` → `{width=0,height=0}`; `getRect()` → `{x=0,y=0,width=0,height=0}`; `getLayout()`
→ `nil` (callers null-check, e.g. `bot.lua:159`).

### 9.5 Creation pipeline (mirror of `UIManager::createWidgetFromOTML`, `uimanager.cpp:706-738`)

```
createWidget(styleTag, parent):
  style = styles[styleTag]              -- flattened at import time; error if nil
  node  = clone(style) ; merge(inlineOverrides)
  w     = new Widget(class = node.__class)
  if parent then parent:addChild(w) end
  fire w.onCreate
  applyStyle(w, node):                  -- '!' tags evaluated as Lua first
      if node.id then w:setId(node.id) end
      apply base props (text, tooltip, on, checked, visible, enabled, focusable,
                        auto-focus, minimum, maximum, step, value, &fields)
      ignore every geometry/paint prop and every $state block
      compile @onXxx snippets as Lua chunks with `self` bound
      if firstOnStyle then apply the auto-focus rule (§6.3) end
  for each child node of `node`, in declaration order, skipping __unique:
      createWidget(childNode.tag, w)    -- recursive
  fire w.onSetup                        -- AFTER children exist
  return w
```

Ordering matters: `@onSetup` runs *after* the children are built, which is why `SpellSourceBox`'s
`self:addOption(...)` is safe and why `healWindow.healer` is already reachable when `HealWindow`'s own
`onSetup` runs.

### 9.6 What to build, in dependency order

1. **OTML parser** — indentation ⇒ tree; `tag: value`, `tag:` + block, `|` literal blocks,
   comments (`//`, `--`), duplicate tags, `$state` blocks (skip), `@`/`!`/`&`/`#` tag prefixes.
2. **Style registry** — `importStyle(file)` / `importStyleFromString`, `Name < Base` flattening
   (`clone(base) ; merge(node)`), lowercase alias, `UI*` auto-definition.
3. **Widget class** per §9.1-§9.4.
4. **`g_ui`** table per §1.
5. **Port `mods/game_bot/functions/ui.lua`, `ui_elements.lua`, `ui_windows.lua`, `ui_legacy.lua`
   verbatim** — they are pure Lua over `g_ui` and need no changes once `g_ui` exists.
6. **Preload the base styles** (read-only, from the otclient tree): `data/styles/10-*.otui`,
   `20-*.otui`, `30-miniwindow.otui`, `20-popupmenus.otui`, `20-spinboxes.otui`, `20-tabbars.otui`,
   plus `mods/game_bot/ui/{basic,panels,config,icons,container}.otui`. These supply `Label`,
   `Button`, `CheckBox`, `TextEdit`, `ComboBox`, `Panel`, `ScrollablePanel`, `TextList`,
   `MainWindow`, `MiniWindow`, `HorizontalSeparator`, `SpinBox`, `ProgressBar`, `Item`, `TabBar`,
   `BotSwitch`, `BotItem`, `BotConfig`, `BotPanel`, `BotContainer`, `DualLabelPanel`, … which every
   vBot style derives from.

### 9.7 Estimated size

OTML parser + style registry ≈ 300 lines; widget class ≈ 450 lines; `g_ui` ≈ 60 lines; the four
`ui*.lua` helper files are reused unchanged (824 lines). Total new code ≈ **800 lines of pure Lua**,
no external dependencies, no rendering.
