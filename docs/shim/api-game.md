# Shim work item A1 — the GAME API surface

Inventory of every `g_game.*`, `g_map.*`, `g_things.*`, `g_minimap.*`, `g_sprites.*` symbol and every
game-object method that the **unmodified vBot 4.8 sources** and the **game_bot runtime** touch, with
the exact signature, the return shape vBot depends on, whether `game/state.lua` already holds the
data, and a difficulty verdict.

Verdicts: **IMPLEMENT** = real behaviour needed · **STATEFUL STUB** = must remember a value, has no
effect on the world · **INERT STUB** = may do nothing · **BLOCKER** = cannot work headless.

## Method

Two disjoint trees were swept exhaustively with ripgrep (no sampling):

* `T1 = D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8` — the user's live profile
  (`_Loader.lua`, `vBot/*.lua`, `cavebot/*.lua`, `targetbot/*.lua`, `navibot/*.lua`), `*.bak-*`
  excluded. **This is the code that must run verbatim.**
* `T2 = D:/Claude/otclient_mehah1530/otclient/mods/game_bot` **minus** `default_configs/` — the bot
  runtime that builds the sandbox (`bot.lua`, `executor.lua`, `functions/*.lua`, `panels/*.lua`).
  `mods/game_bot/default_configs/vBot_4.8/` is a byte-identical mirror of T1 and is excluded
  everywhere; counting it doubles every number.

Counts below are written `T1 / T2`. C++ ground truth read from
`D:/Claude/otclient_mehah1530/otclient/src/client/{game,map,tile,creature,localplayer,thing,container,staticdata}.{h,cpp}`
and `src/client/luafunctions.cpp`. Client-side capability read from
`D:/Claude/otclient_web/luaclient/{game/state.lua, proto/items.lua, proto/parser.lua, proto/sender.lua,
bot/world.lua, bot/path.lua}`.

---

## 0. The five cross-cutting constraints (read before implementing anything)

1. **Object identity must be stable.** vBot compares game objects with `~=` / `==`:
   `spec ~= player` (`vBot/AttackBot.lua:1233,1317,1477,2543,2966,3050`, `vBot/vlib.lua:671`),
   `top ~= ground` (`cavebot/walking.lua:148`), `tile ~= nil` everywhere.
   The shim must **memoise** its wrapper objects: the same creature id, the same tile position and
   the same `tile.things[i]` table must yield the *same* Lua table on every call. `state.creatures[id]`
   and `tile.things[i]` are already identity-stable in `game/state.lua`; a naive
   "build a fresh wrapper per call" adapter breaks vBot silently.
2. **`LocalPlayer:getPosition()` is the PREWALK position.** `src/client/localplayer.h:160`:
   `return isPreWalking() ? m_preWalks.back() : m_position;`. `state.player.preWalks` and
   `state.player.pos` already exist (`game/state.lua:139`). Getting this wrong desynchronises every
   cavebot waypoint test.
3. **Items carry a synthetic position.** `Thing::m_position` for an item in a container is
   `{x=0xFFFF, y=containerId|0x40, z=slot}` and `Thing::getStackPos()` returns `m_position.z` for
   those (`src/client/thing.cpp`, `src/client/container.h:37`). For an equipped item it is
   `{x=0xFFFF, y=slot, z=0}` (`mods/game_bot/functions/player_inventory.lua:44` relies on that shape).
   `g_game.move(item, ...)` and `stashStowItem(item:getPosition(), ...)` are built on it.
4. **`type(x) == 'userdata'` appears once** — `mods/game_bot/functions/map.lua:22`, the
   `getSpectators(creature)` overload. Lua-table wrappers make that branch dead and a creature
   argument is then misread as a position table. Patch that one line in the shim's own copy of the
   runtime; nothing in T1 tests `userdata`.
5. **Extra arguments are silently tolerated** by the C++ binder and vBot relies on it:
   `g_game.walk(dir, false)` (`cavebot/walking.lua:294,324,494`) against
   `bool Game::walk(Otc::Direction)`, and `g_map.getTile(pos, distance)`
   (`mods/game_bot/functions/map.lua:251`) against `Map::getTile(Position)`. Accept and ignore.

---

## 1. `g_game.*`

39 distinct symbols in T1, 36 in T2. Signatures from `src/client/game.h`; `findPlayerItem` is a
**Lua-level** function from `modules/gamelib/game.lua:5`, not a binding.

### 1.1 World-mutating actions (map to `proto/sender.lua`)

| symbol | C++ signature | T1/T2 | argument shapes actually passed | must return | verdict |
|---|---|---|---|---|---|
| `g_game.open(item, previousContainer)` | `int open(const ItemPtr&, const ContainerPtr&)` | 25/5 | `open(item)`, `open(item, nil)`, `open(item, container)`, `open(nextContainer, container)`, `open(bpItem)`, `open(findItem(23721))` | the container **index** it will open into (`int`); vBot ignores it in T1 but `targetbot/looting.lua:179,207,216,228,263` and `vBot/Containers.lua` rely on the container appearing in `g_game.getContainers()` a few ticks later | IMPLEMENT → `sender:openContainer(pos,itemId,stackpos,containerId)`; when `previousContainer` is non-nil reuse **its** id (that is what makes a container open *in place*) |
| `g_game.move(thing, toPos, count)` | `void move(const ThingPtr&, const Position&, int)` | 22/7 | `move(item, container:getSlotPosition(container:getItemsCount()), 1)`, `move(item, pos, item:getCount())`, `move(item, {x=65535,y=slot,z=0}, item:getCount())`, `move(creature, pos)` (**2 args**), `move(parcel, destTile:getPosition())` | nothing | IMPLEMENT → `sender:move(fromPos, itemId, stackpos, toPos, count)`; `fromPos`/`stackpos` come from `thing:getPosition()`/`thing:getStackPos()`, so §0.3 must be right. `count == nil` ⇒ 1 |
| `g_game.close(container)` | `void close(const ContainerPtr&)` | 13/1 | `close(container)`, `close(depotContainer)`, `close(inboxContainer)` | nothing | IMPLEMENT → `sender:closeContainer(id)` |
| `g_game.use(thing)` | `void use(const ThingPtr&)` | 7/2 | `use(item)`, `use(g_game.getLocalPlayer())` (the player used as a *thing*), `use(useThing)` | nothing | IMPLEMENT → `sender:use(pos,itemId,stackpos,index)` |
| `g_game.useWith(item, toThing)` | `void useWith(const ItemPtr&, const ThingPtr&)` | 4/1 | `useWith(converter, item)`, `useWith(item, item)`, `useWith(tmpItem, target, subType)` (3rd arg ignored by C++) | nothing | IMPLEMENT → `sender:useWith` / `sender:useOnCreature` depending on `toThing:isCreature()` |
| `g_game.useInventoryItemWith(itemId, toThing[, subType])` | `void useInventoryItemWith(uint16_t, const ThingPtr&)` | 6/1 | `useInventoryItemWith(item, target, subType)`, `(itemId, player)`, `(selectedItemId, targetObject)` | nothing | IMPLEMENT. **NB** the C++ resolves the id via `findPlayerItem` then sends an ordinary useWith; there is no "hotkey" opcode at 1530 |
| `g_game.useInventoryItem(itemId[, subType])` | `void useInventoryItem(uint16_t)` | 1/1 | from `context.use(number)` | nothing | IMPLEMENT (same resolution) |
| `g_game.equipItemId(id[, tier])` | `void equipItemId(uint16_t, uint8_t)` | 5/3 | `equipItemId(id)`, `equipItemId(weapon_normal)` | nothing | IMPLEMENT → `sender:equipItem(itemId, tier or 0)` |
| `g_game.attack(creature)` | `void attack(CreaturePtr)` | 6/4 | `attack(creature)`, `attack(getCreatureByName(name))`, `attack(nil)` | nothing | IMPLEMENT → `sender:attack(id)`; must also set what `getAttackingCreature()` returns **immediately** (vBot polls it on the next line) |
| `g_game.follow(creature)` | `void follow(CreaturePtr)` | 0/1 | — | nothing | IMPLEMENT → `sender:follow` |
| `g_game.cancelAttack()` / `cancelFollow()` / `cancelAttackAndFollow()` | `attack(nullptr)` / `follow(nullptr)` / dedicated | 0+1+6 / 2+1+1 | no args | nothing | IMPLEMENT → `sender:cancelAttackAndFollow()`; clear the cached attacking/following creature |
| `g_game.walk(dir[, ignored])` | `bool walk(Otc::Direction)` | 3/4 | `walk(nextDir, false)` | **`false` when the step was refused** — `cavebot/walking.lua:294` branches on `~= false` | IMPLEMENT → `sender:walk(dir)` + prewalk bookkeeping in `state.player.preWalks` |
| `g_game.autoWalk(dirs, startPos)` | `void autoWalk(const std::vector<Otc::Direction>&, const Position&)` | 0/2 | `autoWalk(path, {x=0,y=0,z=0})` — the zero startPos is the documented "no prewalk animation" trick | nothing | IMPLEMENT → `sender:autoWalk(dirs)`; honour the 127-step clamp `sender` reports |
| `g_game.stop()` | `void stop()` | 3/0 | no args | nothing | IMPLEMENT → `sender:stop()` |
| `g_game.turn(dir)` | `void turn(Otc::Direction)` | 0/1 | — | nothing | IMPLEMENT → `sender:turn(dir)` |
| `g_game.look(thing, isBattleList)` | `void look(const ThingPtr&, bool)` | 2/2 | `look(creature, true)`, `look(spec, true)` | nothing | IMPLEMENT → `sender:lookCreature(id)` (battle-list form) / `sender:look(pos,id,stack)` |
| `g_game.talk(text)` | `void talk(std::string_view)` | 0/1 | via `context.say` | nothing | IMPLEMENT → `sender:talk(Say, 0, '', text)` |
| `g_game.talkChannel(mode, channelId, text)` | `void talkChannel(Otc::MessageMode, uint16_t, std::string_view)` | 0/4 | `talkChannel(3,0,text)` yell · `talkChannel(7,channel,text)` · `talkChannel(11,0,text)` NPC | nothing | IMPLEMENT → `sender:talk(mode, channelId, '', text)` |
| `g_game.talkPrivate(mode, receiver, text)` | `void talkPrivate(Otc::MessageMode, std::string_view, std::string_view)` | 0/1 | `talkPrivate(5, receiver, text)` | nothing | IMPLEMENT → `sender:talk(5, 0, receiver, text)` |
| `g_game.talkSpell(text, aimMode, aimPos)` | `void talkSpell(std::string_view, uint8_t, const Position&)` | 1/2 | `talkSpell(text, SpellAimCursor(2), position)` — `functions/player.lua:113` | nothing | IMPLEMENT → `sender:talkSpell(text, aimMode, pos)`. **Load-bearing at 1530**: a plain `talk` for a 15.25+ spell is rejected server-side (`functions/player.lua:82-89`) |
| `g_game.setChaseMode(mode)` | `void setChaseMode(Otc::ChaseModes)` | 2/0 | `setChaseMode(1)` | nothing | IMPLEMENT → `sender:setFightMode(fight, chase, safe, pvp)` with the cached other three |
| `g_game.requestChannels()` / `joinChannel(id)` | `void()` / `void(uint16_t)` | 2+2 / 0 | ids from `modules.game_console.channels` | nothing | IMPLEMENT → `sender:requestChannels()` / `sender:joinChannel(id)` |
| `g_game.partyInvite(cid)` / `partyJoin(cid)` | `void(uint32_t)` | 1+1 / 1+1 | creature ids | nothing | IMPLEMENT — **not in `proto/sender.lua`**, must be added |
| `g_game.safeLogout()` / `forceLogout()` | `void()` | 1+0 / 1+1 | — | nothing | IMPLEMENT → `sender:logout()` |
| `g_game.stashStowItem(pos, id, count, stackpos, action)` | `void(const Position&, uint16_t, uint32_t, uint8_t, uint8_t)` | 2/0 | `cavebot/depositor.lua:251`: `stashStowItem(item:getPosition(), id, 0, item:getStackPos(), 2)` (action 2 = stow all of this id) | nothing | IMPLEMENT — **not in `proto/sender.lua`**, must be added (opcode 0x28) |
| `g_game.buyItem(item, amount, ignoreCap, withBackpack)` / `sellItem(item, amount, ignoreEquipped)` | `game.h:261-262` | 0/1 each | via `panels/` only | nothing | IMPLEMENT → `sender:buyItem` / `sender:sellItem` (already present) |
| `g_game.requestOutfit()` / `changeOutfit(outfit)` | `void()` / `void(const Outfit&)` | 0/1 each | `functions/player.lua:54-60` | nothing | IMPLEMENT → `sender:requestOutfit()` / `sender:changeOutfit{...}` |
| `applyImbuement(slot,id,protect)` · `clearImbuement(slot)` · `closeImbuingWindow()` · `selectImbuementItem(itemId,pos,stackpos)` · `selectImbuementScroll()` · `imbuementDurations(bool)` | `game.h:420-424` | 1+1+3+1+2 / same | `cavebot/imbuing.lua:237,238,648,668,712,727,738,752` | 0xD5 / 0xD6 / 0xD7 / 0xB2 / 0x60 out, 0x5D / 0xEB / 0xEC in | **IMPLEMENTED** — B2 closed, see §6 |
| `g_game.forgeRequest(actionType, ...)` | `game.h:416` | 1/0 | `cavebot/route_tools.lua:86` | nothing | INERT STUB acceptable (one decorative call site) |

### 1.2 Read-only accessors (map to `game/state.lua`)

| symbol | C++ | T1/T2 | must return | in `state.lua`? | verdict |
|---|---|---|---|---|---|
| `g_game.getLocalPlayer()` | `LocalPlayerPtr` | 6/1 | **the LocalPlayer object** (§4.2). Used as `g_game.use(g_game.getLocalPlayer())`, so it must also be a valid *Thing* | `state.player` | IMPLEMENT — one memoised wrapper over `state.player` |
| `g_game.getAttackingCreature()` | `CreaturePtr` | 6/6 | Creature or `nil`; identity-comparable against `getSpectators()` results | not stored | IMPLEMENT — cache the id on `attack()`, clear on the `attackCancel` event, expose `state.creatures[id]` |
| `g_game.getFollowingCreature()` | `CreaturePtr` | 0/2 | Creature or nil | not stored | same |
| `g_game.isAttacking()` | `bool` | 2/0 | bool | derived | IMPLEMENT (`getAttackingCreature() ~= nil`) |
| `g_game.getContainers()` | `stdext::map<int,ContainerPtr>` | 8/2 | a **table keyed by container id**, iterated with both `pairs()` and `ipairs()` in different files (`vBot/Containers.lua`, `targetbot/looting.lua:130`) — use contiguous integer keys where possible | `state.containers` | IMPLEMENT — memoised Container wrappers |
| `g_game.getContainer(index)` | `ContainerPtr` | 1/1 | Container or nil | `state.containers[id]` | IMPLEMENT |
| `g_game.findPlayerItem(itemId, subType, tier)` | **Lua**, `modules/gamelib/game.lua:5` | 3/1 | Item or nil. Order: `InventorySlotFirst..Last`, then `findItemInContainers` | inventory + containers both in state | IMPLEMENT — port verbatim; `subType == -1` means "any" |
| `g_game.findItemInContainers(id, subType, tier)` | `game.cpp` | 0 (via the above) | Item or nil; first match in container-id order | yes | IMPLEMENT |
| `g_game.getPing()` | `int` | 10/1 | ms; `vBot/AttackBot.lua:54` does `(type(g_game.getPing)=="function" and g_game.getPing()) or 0` and adds it to every timing budget | not stored | IMPLEMENT — time `ping`/`pingBack` in the transport; a constant is acceptable v1 |
| `g_game.getClientVersion()` | `int` | 25/5 | `1530`. Every use is a version gate (`>= 960`, `>= 860`, `< 780`, `>= 810`) | `LC.config` | INERT STUB returning `1530` |
| `g_game.getProtocolVersion()` | `int` | 1/1 | `1530`; `targetbot/target.lua:274` gates on `< 1090` | — | INERT STUB returning `1530` |
| `g_game.getCharacterName()` | `std::string` | 0/3 | the character name | `state.player.name` | IMPLEMENT |
| `g_game.isOnline()` | `bool` | 0/6 | bool; `mods/game_bot/bot.lua` gates the whole tick on it | transport | IMPLEMENT |
| `g_game.getFeature(f)` | `bool` | 1/1 | `getFeature(GameColorizedLootValue)` only (`vBot/analyzer.lua`) | — | STATEFUL STUB — table of features latched from opcode 0x43; unknown ⇒ `false` |
| `g_game.getUnjustifiedPoints()` | `UnjustifiedPoints` | 3/0 | a table with **`killsDayRemaining`, `killsWeekRemaining`, `killsMonthRemaining`** (`vBot/vlib.lua:224-226`); full struct also has `killsDay/Week/Month`, `skullTime` (`staticdata.h:330-342`) | not stored | STATEFUL STUB — all-zero fields unless opcode 0xB7 is parsed. **Returning `nil` crashes vlib** |
| `g_game.onMultiUseCooldown` | callback field | 2/0 | — | — | **INERT** — both T1 hits are comments (`vBot/AttackBot.lua:15`, `vBot/HealBot.lua:11`) saying it never fires on this client |
| `g_game.enableTileThingLuaCallback(bool)` | `void(bool)` | 0/2 | — | — | IMPLEMENT as a flag gating the `onAddThing`/`onRemoveThing` fan-out (`functions/callbacks.lua:8-9`, `bot.lua:115`) |

### 1.3 The `onAddThing` / `onRemoveThing` hole

`profiles/bot/vBot_4.8/vBot/BotServer.lua:221` registers `onAddThing(function(tile, thing) ... end)`.
`mods/game_bot/bot.lua:719` forwards it from the client's `Tile` callback. **`proto/parser.lua` emits
no per-thing event** — the documented set (API.md) stops at `tileUpdate` and `mapDescription`.
→ `game/state.lua:237 state:addThing` and `state:_removeAt` must gain an emit hook, or the shim must
diff tiles after every `tileUpdate`.

---

## 2. `g_map.*`

Only **7 distinct symbols**, but they carry the whole bot.

| symbol | C++ signature | T1/T2 | must return | already in `state.lua` / `bot/` ? | verdict |
|---|---|---|---|---|---|
| `g_map.getTile(pos[, ignored])` | `TilePtr getTile(const Position&)` | **37/9** | a **Tile object** (§4.3) or `nil` for a tile never described. `nil` is meaningful and vBot branches on it (`cavebot/walking.lua:135-140`) | `state:tile(pos)` returns the raw record | IMPLEMENT — memoised Tile wrapper per position key; `nil` when `state.map[key]` is absent |
| `g_map.getTiles(floor)` | `TileList getTiles(int8_t floor = -1)` | **16/0** | an **array** of every known Tile on that floor, iterated with both `ipairs` and `pairs` (`vBot/vlib.lua:925,947,971,986,1090`, `vBot/AttackBot.lua:1537,2581`, `vBot/extras.lua:211,294,536`, `cavebot/actions.lua:73`, `cavebot/clear_tile.lua:89`, `cavebot/doors.lua:24`, `cavebot/imbuing.lua:674`, `vBot/pushmax.lua:97`, `vBot/new_cavebot_lib.lua:340`). Always called as `getTiles(posz())` | `state.map` keys must be filtered by z | IMPLEMENT. **Hot path** — keep a per-floor index invalidated by `setTile`/`cleanTile`, do not rescan `state.map` per call |
| `g_map.getSpectatorsInRange(centerPos, multiFloor, xRange, yRange)` | `map.h:176` → `getSpectatorsInRangeEx(c,mf,r,r,r,r)` | 4/0 | array of Creature. `targetbot/target.lua:51` (6,6), `:59` (3,3), `targetbot/creature_attack.lua:69,87` (configurable radius) | `bot/world.lua:621 world:spectators` covers the aware-range form only | IMPLEMENT — a ranged variant of `world:spectators` |
| `g_map.getSpectators(centerPos, multiFloor)` | `map.h:166`, range = the aware range | 0/4 | array of Creature — the workhorse behind `context.getSpectators`, `getCreatureById`, `getCreatureByName`, `getPlayerByName` (`functions/map.lua:36,44,58,72`). **35 indirect call sites in T1** | `bot/world.lua:621` | IMPLEMENT |
| `g_map.getSpectatorsByPattern(centerPos, pattern, direction)` | `map.cpp` — odd width and height; cells `0/-`, `1/+`, `NnEeSsWw` | 0/1 | array of Creature | `bot/world.lua:678 world:spectatorsByPattern` — verbatim port incl. the grid cache and the "direction 8 disables every letter" rule | IMPLEMENT — thin adapter |
| `g_map.isSightClear(fromPos, toPos)` | `map.cpp:1181` | 2/0 | bool. `vBot/AttackBot.lua:1206` feature-detects it (`type(g_map.isSightClear) == "function"`), `:1209` calls it | `state:isSightClear` (`game/state.lua:915`) **and** `world:isSightClear` — both verbatim, incl. the "a missing tile is transparent" trap | IMPLEMENT — thin adapter |
| `g_map.getMinimapColor(pos)` | `map.cpp:1168` — the tile's colour byte, and **only if that is 0** the persisted minimap | **8/0** | an int; every site tests the 210..213 "stairs yellow" band (`cavebot/antilost.lua:81,428`, `cavebot/actions.lua:109,393`, `cavebot/walking.lua:141`, `vBot/pushmax.lua:214,221`, `vBot/vlib.lua:1092`) | `state:getMinimapColor(pos, fallback)` (`game/state.lua:829`) + `world:mapColorAt` | IMPLEMENT — see BLOCKER B1 |
| `g_map.findEveryPath(start, maxDist, params)` | `map.cpp` Dijkstra; `params` is `map<string,string>` | 0/1 | `{ ["x,y,z"] = {totalCost, distance, directionFromPrev, "prevX,prevY,prevZ"} }` — a **string-keyed** map of 4-element arrays; `functions/map.lua:116-140 translateAllPathsToPath` walks `node[3]`/`node[4]`, `findPath` compares `node[1]` | `bot/path.lua:300 P:findEveryPath` already implements this contract | IMPLEMENT — thin adapter. **19 `findPath` + 4 `getPath` + 5 `autoWalk` T1 sites funnel here** |

Never used anywhere: `g_map.findPath` (the C++ one), `getCreatureById`, `getCentralPosition`,
`setCentralPosition`, `getThing`, `findItemsById`, `getSize`, and everything OTBM/zone/ghost-mode.
The bot goes exclusively through `findEveryPath`.

### 2.1 `findEveryPath` params (`functions/map.lua:80-113` normalises them to `"0"`/`"1"` strings)

`ignoreLastCreature`, `ignoreCreatures`, `ignoreNonPathable`, `ignoreNonWalkable`, `ignoreStairs`,
`ignoreCost`, `allowUnseen`, `allowOnlyVisibleTiles`, `maxDistanceFrom` (`"x,y,z,dist"`),
`destination` (`"x,y,z"`), plus the Lua-side-only `precision`, `marginMin`/`minMargin`,
`marginMax`/`maxMargin`. Two rules to copy verbatim from `map.cpp`:

* a tile is a *stairs* tile only when `isNotPathable && 210 <= minimapColor <= 213` — **colour alone
  is not enough** (the in-tree comment explains that multi-tile staircases become unreachable
  otherwise);
* `ignoreLastCreature` does **not** open the tile: it writes a node with `totalCost + 100`, so the
  destination stays reachable but expensive.

### 2.2 Spectator ordering caveat

C++ `getSpectatorsInRangeEx` walks `z → y → x` and appends each tile's creatures **top-of-stack
first** (`Tile::appendSpectators` iterates in reverse). `bot/world.lua:621` iterates
`pairs(state.creatures)`, i.e. hash order. Any vBot code that takes "the first" spectator or relies
on a stable tie-break becomes nondeterministic. Sort the shim's result by `(z, y, x, -stackIndex)`.

---

## 3. `g_things.*`, `g_minimap.*`, `g_sprites.*`

| symbol | T1/T2 | usage | verdict |
|---|---|---|---|
| `g_things.getThingType(id[, category])` | 6/0 | `targetbot/target.lua:302,320` → `thing:isFluidContainer()`; `cavebot/imbuing.lua:76` → `thing:getName()` (wrapped in `pcall`, falls back to `"item <id>"`) | IMPLEMENT — a tiny ThingType wrapper over `proto/items.lua`: `isFluidContainer` = `items.isFluidContainer(id)`, `getName` = `items.name(id)`. The other 76 bound ThingType methods are unused |
| `g_minimap.*` | **0/0** | never called directly | not needed as a symbol — but see B1 |
| `g_sprites.*`, `g_creatures.*`, `g_shaders.*`, `g_effects.*` | **0/0** | never called | omit / INERT STUB |

---

## 4. The object model

### 4.1 `Creature` — from `getSpectators*`, `getAttackingCreature`, `getCreatureBy*`, `Tile:getCreatures`

Counts are raw T1 hits for the name; the receiver column disambiguates game objects from widgets.

| method | C++ | T1 | receivers | must return | `state.lua` field | verdict |
|---|---|---|---|---|---|---|
| `getId()` | `creature.h` | 160 total, ~14 on creatures | `spec`, `creature`, `c` | uint32 creature id | `c.id` | IMPLEMENT |
| `getName()` | `creature.h` | 99 total; 25 `spec`, 8 `c`, 4 `creature` | | string, compared `:lower()`-folded | `c.name` | IMPLEMENT |
| `getPosition()` | `Thing::getPosition` | 149 total; 20 `spec`, 15 `creature`, 3 `target`, 3 `npc` | | `{x,y,z}` table | `c.pos` | IMPLEMENT — return a copy; vBot stores positions |
| `getHealthPercent()` | `creature.h` | 28; 15 `spec`, 11 `creature` | | 0..100 int | `c.healthPercent` | IMPLEMENT |
| `isPlayer()` / `isMonster()` / `isNpc()` | `Thing` virtuals | 29 / 19 / 4 | `spec`, `creature` | bool | `c.isPlayer/isMonster/isNpc` — derived in `state:addCreature` from `c.type` (0 player, 1 monster, 2 npc, 3 own summon, 4 summon, 5 hidden; **3 and 4 count as monsters**, `game/state.lua:470-474`) | IMPLEMENT |
| `isLocalPlayer()` | `Thing` virtual | 14 | `spec`, `creature`, `p` | bool | `c.id == state.player.id` | IMPLEMENT |
| `getType()` | `creature.h:112` | 12; 9 `spec`, 3 `creature` | | raw `CreatureType` 0..5 (`modules/gamelib/creature.lua:11-16`) | `c.type` | IMPLEMENT |
| `getDirection()` | `creature.h` | 13; 10 `player` | | 0..3 (N,E,S,W) | `c.direction` | IMPLEMENT |
| `getVocation()` | `creature.h:206` | 10; 7 `player`, 1 `spec` | | uint8 **client** vocation id (`VocationsClient`, `modules/gamelib/creature.lua:33-43`) | `player.vocation`; **not recorded for other creatures** | IMPLEMENT for the local player, return 0 otherwise (gap G6) |
| `isSorcerer/isDruid/isKnight/isPaladin/isMonk()` | **Lua**, `modules/gamelib/creature.lua:205-229` | 3 each | `player` | bool from `getVocation()` | derived | IMPLEMENT — port the five one-liners |
| `isPartyMember()` / `isPartyLeader()` | **Lua**, `modules/gamelib/player.lua:614-625` | 9 / 1 | `spec`, `p`, `player` | bool derived from `getShield()` against the `Shield*` constants | `c.shield` | IMPLEMENT — port verbatim and export the `Shield*` constants |
| `getShield()` | `creature.h:110` | 3 | `creature`, `spec` | uint8 | `c.shield` | IMPLEMENT |
| `getEmblem()` | `creature.h:111` | 3 | `spec`, `p` | uint8; `vBot/vlib.lua:671` tests `== 1` | `c.emblem` | IMPLEMENT |
| `getOutfit()` | `creature.h` | 4 | `spec`, `player`, `creature` | table `{type,head,body,legs,feet,addons,mount,...}` | `c.outfit` | IMPLEMENT |
| `canShoot(distance)` | `creature.cpp` → `getTile():canShoot(d)` | 12 total; 5 `spec` | | bool: Chebyshev distance **from the local player** ≤ d **and** `isSightClear(playerPos, tilePos)` | derivable | IMPLEMENT |
| `getSpeed()` | `creature.h` | 0/1 | | uint16 | `c.speed` | IMPLEMENT |
| `getStepDuration([ignoreDiagonal, dir])` | `creature.h:119` | 5, all on `player` | | ms per step | derivable from `speed` and `groundSpeed` | IMPLEMENT — the walker needs it anyway; the C++ substitutes 150 for a zero result |
| `isWalking()` | `creature.h:147` | 8, all on `player` | | bool | walker state | IMPLEMENT |
| `isDead()` | `creature.h:153` = `healthPercent <= 0` | 2 | | bool | derived | IMPLEMENT |
| `isTimedSquareVisible()` | render-only | 1 | `spec` | bool | — | INERT STUB → `false` |
| `getManaPercent()` | `creature.h` | 1 | `spec` | 0..100 | only for party members (opcode 0x8B) | STATEFUL STUB → 100 (gap G7) |
| `setOutfit`, `setDirection`, `showStaticSquare`, `setText`, `setMarked`, `attachEffect`, … | render/UI | 0 on creatures in T1 | | | INERT STUB |

### 4.2 `LocalPlayer` — everything in `Creature`, plus:

| method | C++ | T1 | must return | `state.lua` | verdict |
|---|---|---|---|---|---|
| `getHealth()` / `getMaxHealth()` | `localplayer.h` | via `context.hp()`/`maxhp()` | int | `player.health/maxHealth` | IMPLEMENT |
| `getMana()` / `getMaxMana()` | | 1 direct + `context.mana()` | int; `context.manapercent()` guards `getMaxMana() <= 1` | `player.mana/maxMana` | IMPLEMENT |
| `getLevel()` / `getExperience()` / `getMagicLevel()` | | via `context.lvl/exp/mlev` | int | `player.level/exp/magicLevel` | IMPLEMENT |
| `getSoul()` / `getStamina()` | | via `context.soul/stamina` | int | `player.soul/stamina` | IMPLEMENT |
| `getCapacity()` (= free cap), `getFreeCapacity()`, `getTotalCapacity()` | `localplayer.h:81-82` | `context.cap/freecap/maxcap`; 1 direct `getFreeCapacity` | int, already **divided by 100** by the parser (`proto/parser.lua:1751`) | `player.freeCapacity`, `player.capacity`, `player.maxCapacity` | IMPLEMENT — mind which is which: `context.cap()` maps to `getCapacity()` |
| `getStates()` | `localplayer.h:110` | via `context.hasCondition` (33 derived predicates in `functions/player_conditions.lua`) | a bitmask; `Bit.band(states, cond) > 0` | `player.states` (+ `statesLo`/`statesHigh` for the 1405+ u64 split) | IMPLEMENT — expose the **combined** mask and the `PlayerStates` table |
| `getSkillLevel(skill)` / `getSkillBaseLevel(skill)` | `localplayer.h:101-102` | 3 / 4 on `player` | int for `Otc::Skill` 0..6 | `player.skills[i].level/.baseLevel` | IMPLEMENT |
| `getBlessings()` | `localplayer.h:105` | 2 | uint16 bitmask | `player.blessings` | IMPLEMENT |
| `getRegenerationTime()` | `localplayer.h:106` | 3 | seconds | `player.regeneration` (`proto/parser.lua:1765`) | IMPLEMENT |
| `getInventoryItem(slot)` | `localplayer.h:120` | 2 direct + all of `functions/player_inventory.lua` | Item or nil; `slot` = `InventorySlot*` 1..11 | `player.inventory[slot]` | IMPLEMENT |
| `getInventoryCount(itemId, tier)` | `localplayer.cpp` | 4 | total **count** across the 11 equipped slots **and every open container**; tier must match; `itemId == 0` ⇒ 0 | inventory + containers | IMPLEMENT — port the accumulator verbatim |
| `hasEquippedItemId(itemId, tier)` | `localplayer.cpp` | 0 | bool, equipped slots only | yes | IMPLEMENT (cheap) |
| `isPreWalking()` | `localplayer.h:140` | 4 | `#preWalks > 0` | `player.preWalks` | IMPLEMENT |
| `isSupplyStashAvailable()` | `localplayer.h:142` | 1 | bool | `proto/parser.lua:909` reads the byte and **discards** it | STATEFUL STUB — one-line parser change (gap G4) |
| `getResourceBalance(type)` | `localplayer.h:124` | 1 | uint64 for an `Otc::ResourceTypes_t` | `state.resources[t]` (`proto/parser.lua:2737-2741`) — **on `state`, not on `state.player`** | IMPLEMENT |
| `getStance()` / `getSecondaryStance()` | `localplayer.h:95-96` | 2 / 1 | uint16 spell ids | **not stored** — but `player.virtues` is (opcode 0xC1 sub 2) | IMPLEMENT — derive with the exact C++ rule (`protocolgameparse.cpp:5385-5404`): scan `virtues`; ids 311/312 ⇒ secondary; else the first id is primary and the next is secondary |
| `getHarmony()` | `localplayer.h:90` | 1 | uint8 | `player.harmony` (0xC1 sub 0) | IMPLEMENT |
| `getVirtues()` / `isSerene()` | `localplayer.h:92` | 0 | array / bool | `player.virtues`, `player.serene` | IMPLEMENT |
| `autoWalk`, `preWalk`, `lockWalk`, `canWalk`, `hasSight`, `isServerWalking` | walker internals | `canWalk` 4× in T2 only | | walker state | IMPLEMENT alongside `bot/walker.lua` |
| `setSpeed(v)` | `functions/player.lua:62` | 0 in T1 | | `player.speed` | STATEFUL STUB |

### 4.3 `Tile` — from `g_map.getTile` / `g_map.getTiles`

| method | C++ | T1 | must return | client support | verdict |
|---|---|---|---|---|---|
| `getPosition()` | `Tile` | 40 (`tile` receiver) | `{x,y,z}` | `tile.pos` | IMPLEMENT |
| `isWalkable([ignoreCreatures])` | `tile.cpp` — `!(NOT_WALKABLE) && getGround() && (ignoreCreatures or no non-passable *visible* creature)` | **19** (17 `tile`) | bool; **called with no argument at most sites**, i.e. creatures block | `state:isWalkable` (`game/state.lua:703`) — verbatim, incl. `canBeSeen()` | IMPLEMENT — thin adapter |
| `getTopUseThing()` | `tile.cpp:600` | **25** (18 `tile`) | a Thing (usually an Item). How looting finds the corpse (`targetbot/looting.lua`) and how `cavebot/walking.lua:150` finds floor-change items | `state:getTopUseThing` (`game/state.lua:843`) — verbatim 3-clause port | IMPLEMENT |
| `hasCreatures()` | `tile.h:94` | 11 | bool | `state:hasCreatures` | IMPLEMENT |
| `getCreatures()` | `tile.cpp` — `appendSpectators` then **reversed** | 8 | array of Creature, bottom-of-stack first | tile things | IMPLEMENT — keep the reversal |
| `getItems()` | `tile.cpp` | 14 (of the 66 `getItems` hits) | array of Item in stack order | tile things filtered `kind=='item'` | IMPLEMENT |
| `getTopThing()` | `tile.cpp` — first `isCommon()`, else the last thing | 4 | Thing | not in `state.lua` | IMPLEMENT — needs `items.isCommon` (present) |
| `getGround()` | `tile.cpp:537` — `things[0]` **only if it carries the GROUND flag** | 3 | Item or nil, then `:getId()` | `state:getGround` (`game/state.lua:774`) | IMPLEMENT |
| `canShoot(distance)` | `tile.cpp` | 12 total, 4 on `tile` | bool (see §4.1) | `state:isSightClear` | IMPLEMENT |
| `isPathable()` | `tile.h:77` | 1 (`cavebot/walking.lua:142`, the stairs test) | bool | `state:isPathable` | IMPLEMENT |
| `isNotPathable()` | **not a C++ binding** | 1 | bool | — | IMPLEMENT as `not isPathable()` — this call site already fails on the real client; keep it working |
| `hasFloorChange()` | `tile.cpp` — any thing with the floor-change flag | 2 | bool | no explicit bit in `proto/items.lua`; `world:itemChangesFloor` (`bot/world.lua:493`) approximates it from an id list | IMPLEMENT via `world:itemChangesFloor` |
| `hasElevation([n])` | `tile.h:181` | 1 | bool | `state:hasElevation` (`game/state.lua:762`) | IMPLEMENT |
| `getThings()` | `tile.h:66` | 0 in T1 | array | `tile.things` | IMPLEMENT (cheap) |
| `getTopMoveThing()` | `tile.cpp:654` | 1 | Thing | `state:getTopMoveThing` (`game/state.lua:872`) | IMPLEMENT |
| `getTopCreature([checkAround])` | `tile.cpp:617` | 0 in T1 | Creature | `state:getTopCreature` (`game/state.lua:895`), simplified (no walking-creature clauses) | IMPLEMENT |
| `getMinimapColorByte()` | `tile.cpp:571` | 0 direct (via `g_map.getMinimapColor`) | 1..255, **never 0** | `state:getMinimapColorByte` (`game/state.lua:802`) | IMPLEMENT |
| `isLookPossible()` | `tile.h:81` | 0 direct (via `isSightClear`) | bool | `state:tileFlags` BLOCK_PROJECTILE | IMPLEMENT |
| `getTimer`, `setText`, `setFill`, `select`, `overwriteMinimapColor`, `isHouseTile`, … | render/editor | the 3 `getTimer` hits are on UI widgets, not tiles | | | INERT STUB |

### 4.4 `Item` (and the `Thing` flags on it)

| method | C++ | T1 | must return | client support | verdict |
|---|---|---|---|---|---|
| `getId()` | `Thing` | 58 on `item` + 8 `thing` + 6 `topThing` + 3 `ground` | uint16 appearance id | `thing.id` | IMPLEMENT |
| `getCount()` | `item.h` | 25 (19 `item`) | 1..255 (or the subtype for fluids) | `thing.count` | IMPLEMENT |
| `getPosition()` | `Thing` | 2 on `item` | see §0.3 — `{0xFFFF, containerId\|0x40, slot}` for a container item, `{0xFFFF, slot, 0}` for equipped, the tile position otherwise | derivable | IMPLEMENT — **the single most error-prone method in the shim** |
| `getStackPos()` | `Thing::getStackPos` | 2 | tile stack index, or `position.z` (the container slot) when `position.x == 0xFFFF` | derivable | IMPLEMENT — verbatim |
| `getSubType()` / `getCountOrSubType()` / `getItemCountOrSubType()` | `item.h` | 0 / 0 / 1 | int | `thing.count` doubles as subtype for `items.CUMULATIVE` ids | IMPLEMENT |
| `getTier()` | `item.h` | 1 | uint8 | `thing.tier` | IMPLEMENT |
| `isContainer()` | `Thing` | 12 | bool | `items.isContainer(id)` | IMPLEMENT |
| `isStackable()` | `Thing` | 4 | bool | `items.isStackable(id)` | IMPLEMENT |
| `isNotMoveable()` | `Thing` | 6 | bool | `items.isNotMoveable(id)` | IMPLEMENT |
| `isPickupable()` | `Thing` | 2 | bool | `items.isPickupable(id)` | IMPLEMENT |
| `isFluidContainer()` | `Thing` | 2 | bool | `items.isFluidContainer(id)` | IMPLEMENT |
| `isUsable()` / `isMultiUse()` / `isGround()` / `isItem()` / `isCreature()` | `Thing` | 1 / 1 / 1 / 6 / 1 | bool | `items.*` plus `thing.kind` | IMPLEMENT |
| `getMarketData()` | `item.h` | **10** | a table; **only `.name` is read** (`vBot/depositer_config.lua:42,70`, `vBot/analyzer.lua:401,438,494,1118,1191`). Full struct `{name, category, requiredLevel, restrictVocation, showAs, tradeAs}` (`staticdata.h:230`) | `items.marketName(id)` and `items.name(id)` exist | IMPLEMENTED as specified: `{name = items.marketName(id) or items.name(id) or ('item '..id), category=0, requiredLevel=0, restrictVocation=0, showAs=id, tradeAs=id}`, plus a `marketName` field carrying the C++-exact value. **`nil` crashes analyzer and depositer_config.** NOTE — the `name` fallback is a KNOWN, deliberate deviation: `thingtype.cpp:340-357` copies `m_name` into `m_market.name` only inside `if has_market()`, so the live client hands back `''` for an item with no market block. The deviation is one-directional and safe: `.name` is only ever lowercased and string-matched (`vBot/depositer_config.lua:42,70`, `vBot/analyzer.lua:401,438,494,1118,1191`), so a real name can only ADD a classification the live client would have dropped, never mis-classify one. Use `.marketName` for the C++-exact answer. |
| `getName()` | `item.h` | 0 direct on items (see `g_things.getThingType(id):getName()`) | string | `items.name(id)` | IMPLEMENT |
| `getServerId()` | `item.h` | 1 | uint16 | no OTB headless — and the shipped client has none either | **return `0`** — that is what the non-editor C++ build answers (`Item::m_serverId` is only written under `#ifdef FRAMEWORK_EDITOR`, `item.cpp:273`; `TOGGLE_FRAMEWORK_EDITOR` is OFF by default). See B3. |
| `Item.create(id)` | class constructor | **8** | a detached Item; only `getId`/`getMarketData`/`getName` are used on it | — | IMPLEMENT — a 3-line factory: `id`, `count = 1`, no position |
| `Item.bottom` | field lookup | 4 | — | | INERT |
| `setCount`, `setTooltip`, `setTier`, `clone`, `setDescription`, `getDurationTime`, `getCharges` | | 0 in T1 | | | INERT STUB |

### 4.5 `Container` — from `g_game.getContainers()` / `getContainer(i)`

The second-hottest cluster after Tile; looting and the depositor live here.

| method | C++ | T1 | must return | `state.containers` field | verdict |
|---|---|---|---|---|---|
| `getName()` | `container.h:41` | **35** | string, `:lower()`-folded and matched against config names | `c.name` | IMPLEMENT |
| `getItems()` | `container.h` | 27 | array of Item in slot order | `c.items` | IMPLEMENT |
| `getContainerItem([slot])` | `container.h:40` | 17 | Item or nil. **Careful:** `Container::getContainerItem()` takes *no* argument in C++ (it is the backpack item the container was opened from, 13 sites); the indexed form vBot also uses is `Item::getContainerItem(index)` on the parent item. Disambiguate by receiver and support both arities | `c.item` | IMPLEMENT (both arities) |
| `getItemsCount()` | `container.h:36` | 14 | `#items` | derived | IMPLEMENT |
| `getSlotPosition(slot)` | `container.h:37` — `{0xFFFF, id\|0x40, slot}` | 13 | Position table; the destination of every `g_game.move` | derived from `c.id` | IMPLEMENT — verbatim, **0-based slot** |
| `getCapacity()` | `container.h:39` | 6 | int | `c.capacity` | IMPLEMENT |
| `getId()` | `container.h:38` | part of the 160 `getId` hits | 0..n | `c.id` | IMPLEMENT |
| `hasPages()` / `getSize()` / `getFirstIndex()` | `container.h:45-47` | 2 / 2 / 0 | bool / int / int | `c.hasPages`, `c.size`, `c.firstIndex` | IMPLEMENT |
| `hasParent()` / `isClosed()` / `isUnlocked()` / `getItem(slot)` | | 0 in T1 | | `c.hasParent` | IMPLEMENT (cheap) |

### 4.6 Positions

Positions are **plain Lua tables** `{x=,y=,z=}` on both sides (the C++ binder converts
`Position` ↔ table automatically). vBot builds them literally (`{x=65535, y=slot, z=0}`), reads
`.x/.y/.z` directly, and `functions/map.lua` serialises them as `x..","..y..","..z`. **No Position
class methods are used in T1** — `Position.getDistance` and friends never appear. Nothing to
implement beyond returning fresh tables. `state.lua` copies positions on store (`copyPos`), so
returning `tile.pos` / `c.pos` directly is safe only if vBot never mutates them; prefer a copy.

---

## 5. What `game/state.lua` already covers vs. what the parser must start recording

**Already there, verbatim C++ ports — the shim is a thin adapter:**
`state:tile` · `setTile` · `cleanTile` · `getCreature` · `addCreature` (incl. the type →
isPlayer/isMonster/isNpc derivation) · `isAwareOf` · `setCentralPosition` · `walkableAt` ·
`tileFlags` · `isWalkable` · `isPathable` · `isLookPossible` · `hasCreatures` ·
`hasBlockingCreature` · `hasElevation` · `getGround` · `getGroundSpeed` · `getMinimapColorByte` ·
`getMinimapColor` · `getTopUseThing` · `getTopMoveThing` · `getTopCreature` · `isSightClear` ·
containers and channels. Plus `bot/world.lua` (`spectators`, `spectatorsByPattern`, `isSightClear`,
`tileWalkable`, `classifyForPath`, `countInArea`) and `bot/path.lua` (`findEveryPath`, `getPath`),
which already match the `g_map` contracts.

**Gaps needing a parser or state change (each is small):**

| # | needed by | what is missing | fix |
|---|---|---|---|
| G1 | `getAttackingCreature`/`getFollowingCreature`/`isAttacking` (12 T1 sites) | no attack/follow target tracked | keep the id in the shim; clear on `attackCancel` |
| G2 | `g_game.getPing()` (10 T1 sites) | no RTT measurement | time `ping`/`pingBack` in `proto/transport.lua` |
| ~~G3~~ **CLOSED** | `g_game.getUnjustifiedPoints()` (3 sites) | ~~opcode 0xB7 not parsed~~ | **DONE** — `proto/parser.lua` `S[0xB7]` parses all seven bytes into `state.unjustified` and emits `unjustifiedPoints`; `g_game.getUnjustifiedPoints()` reads it. **Before the packet arrives** the three `*Remaining` fields answer **255**, not 0: `vBot/vlib.lua:223-227` `killsToRs()` is their minimum, and 0 is conservative for the AttackBot PvP gate (`AttackBot.lua:1573,2949,3001,3036,3046,3065,3083`, `killsToRs() > KillsAmount`) but INVERTS `vBot/antiRs.lua:21` (`killsToRs() < 6`), which would latch on for the whole session. 255 is the only value that is safe in both directions. |
| G4 | `player:isSupplyStashAvailable()` (1 site) | `proto/parser.lua:909` reads and discards the byte | store it |
| ~~G5~~ **CLOSED** | `onAddThing`/`onRemoveThing` (`vBot/BotServer.lua:221`) | ~~no per-thing event~~ | **DONE** — `shim/object.lua` `Reg:_hookState` wraps `state:addThing` and `state:_removeAt` (the single removal funnel: `state:removeThing` AND the 11-thing trim both go through it, which is the C++ ordering) and fans out to `reg.onTileThing`, which `shim/callbacks.lua` turns into `onAddThing(tile, thing)` / `onRemoveThing(tile, thing)`. **Gated** on `reg.tileThingCallback`, flipped by `g_game.enableTileThingLuaCallback` — the same gate as `tile.cpp:374-376,420-422` — so with the callback off it costs one boolean per thing and allocates nothing. |
| G6 | `Creature:getVocation()` on **remote** creatures (1 site) | only the local player's vocation is stored | store per creature, or return 0 |
| G7 | `Creature:getManaPercent()` (1 site) | opcode 0x8B (party mana) not stored | store, or return 100 |
| ~~G8~~ **CLOSED** | imbuement window (`cavebot/imbuing.lua`, 8 sites) | ~~neither senders nor parser exist~~ | **DONE** — see B2 below |
| G9 | party invite/join (2+2 sites) | no party builders in `proto/sender.lua` | add them |
| G10 | `g_game.stashStowItem` (2 sites) | no builder | add opcode 0x28 |

---

## 6. Blockers

**B1 — `g_minimap` / the persisted minimap is empty.** Two consumers:

* `Map::getMinimapColor` falls back to `g_minimap.getTile(pos).color` when the live tile's byte is 0
  (`map.cpp:1168-1179`). In practice unreachable for a *known* tile (`getMinimapColorByte` returns
  255, never 0), and all 8 T1 sites either guard with `g_map.getTile(p)` first
  (`cavebot/walking.lua:135-142`) or read a tile the player is standing on or beside. **Not a
  blocker for vBot.**
* `Map::findEveryPath` uses `g_minimap` for **every tile outside the aware range** (`map.cpp`, the
  `else if (!allowOnlyVisibleTiles)` branch): `wasSeen`, `NotWalkable`, `NotPathable`, `color` and
  `speed` all come from the persisted minimap. Headless that store is empty, so every out-of-range
  tile reads as *never seen* and — unless `allowUnseen` is set — is refused. **CaveBot's long `goto`
  hops across unloaded terrain will fail to find a path.** `bot/world.lua:206` already has the hook
  (`opts.known`, with `KNOWN_WAS_SEEN / NOT_PATHABLE / NOT_WALKABLE / EMPTY` and the null-tile
  defaults `flags 0, colour 255, speed byte 10`) but **nothing populates it** — `grep -rn "known"
  bot/init.lua main.lua` finds no wiring.
  *Mitigation, cheapest first:* (a) load the user's `minimap.otmm` offline into `opts.known`;
  (b) persist an aware-range trail as the bot walks; (c) accept `allowUnseen` paths and lean on
  `bot/walker.lua`'s anti-lost recovery.
  **Verdict: BLOCKER for long-range cavebot routing; IMPLEMENT-with-data otherwise.**

**B2 — imbuement (`cavebot/imbuing.lua`). CLOSED.** The opcodes were misidentified above: the
family is 0x5D / 0xEB / 0xEC inbound and 0x60 / 0xB2 / 0xD5 / 0xD6 / 0xD7 outbound
(`src/client/protocolcodes.h:94,235,236,285,358,375-377`), not 0xF8/0xF9/0xFA.

| direction | opcode | C++ | shim |
|---|---|---|---|
| out | 0xD5 `ApplyImbuement` | `protocolgamesend.cpp:1735` — u8 slot, u32 imbuementId; the `protectionCharm` byte is **cv < 1510 only**, so it is *not* written at 1530 | `sender:applyImbuement` → `g_game.applyImbuement` |
| out | 0xD6 `ClearImbuement` | `:1747` — u8 slot | `sender:clearImbuement` |
| out | 0xD7 `CloseImbuingWindow` | `:1755` — empty | `sender:closeImbuingWindow` |
| out | 0xB2 `ImbuementWindowAction` | `:1762` — u8 type; only type 1 (`SELECT_ITEM`) also writes Position(5) + u16 itemId + u8 stackpos | `sender:imbuementWindowAction` → `g_game.selectImbuementItem` / `selectImbuementScroll` |
| out | 0x60 `ImbuementDurations` | `:1887` — u8 isOpen | `sender:imbuementDurations` |
| in | 0x5D `ImbuementDurations` | `protocolgameparse.cpp:5596` → `g_game.onUpdateImbuementTracker(itemList)` | parsed into `state.imbuementTracker`, emitted as `imbuementTracker`, re-signalled as `onUpdateImbuementTracker` with a real `Item` on `entry.item` |
| in | 0xEB `SendImbuementWindow` | `:6893` — three window types → `onOpenImbuementWindow` (0), `onImbuementItem` (1), `onImbuementScroll` (2) | all three, plus the game_bot-facing `onImbuementWindow` (`bot.lua:566`) |
| in | 0xEC `SendCloseImbuementWindow` | `:6989` → `onCloseImbuementWindow` | wired |

`activeSlots` is a **0-based** map of slot index → `{ imbuement, duration, removalCost }`, which is
what `cavebot/imbuing.lua:190-200` reads as `tup[1]` / `tup[2]`. At cv ≥ 1510 the imbuement's
`group` is derived from its `tier` byte (`Basic` / `Intricate` / `Powerful`,
`protocolgameparse.cpp:6850`) rather than read as a string.

**B3 — `Item:getServerId()` (1 site). CLOSED, and the old answer was wrong.**
No client→server id map can be derived offline: it exists only in `items.otb`, which
`ThingTypeManager::loadOtb` (`thingtypemanager.cpp:653`) turns into `m_reverseItemTypes`
(`:566`), the 1530 data set does not ship one (`data/things/1530` is appearances + sprites), and
nothing in `src/` or `modules/` ever calls `g_things.loadOtb`.
More decisively, **the reference client does not answer the client id either.** `Item::m_serverId`
is assigned in exactly one place, `item.cpp:273`, and that line is inside `#ifdef FRAMEWORK_EDITOR`;
`src/CMakeLists.txt:12` defaults `TOGGLE_FRAMEWORK_EDITOR` to **OFF**, so in the shipped client the
field keeps its `item.h:193` initialiser `{ 0 }` forever while the Lua binding
(`luafunctions.cpp:853`) is compiled in unconditionally. A real `item:getServerId()` at 1530
returns **0** for every item. The shim now returns 0 too, and still reports once.

**B4 — everything render-, sprite- and widget-shaped** (`getTileUnderCursor` 3×, `getMapPanel`/
`getMapView` 4×, `zoomIn`/`zoomOut`, `lockVisibleFloor`/`unlockVisibleFloor` 2+1×,
`isTimedSquareVisible`, `showStaticSquare`, `attachEffect`). None affect bot decisions.
**INERT STUB** — but `getTileUnderCursor` must return `nil` rather than error, and the three
`getMapPanel()` sites need an object whose methods are all no-ops (work item A2's problem).

---

## 7. Priority for the implementer (by call volume in T1)

1. **Tile + `g_map.getTile`/`getTiles`** — 37 + 16 direct calls, and `isWalkable` (19),
   `getTopUseThing` (25), `hasCreatures` (11), `getItems` (14), `getCreatures` (8) hang off them.
2. **Container** — `getName` 35, `getItems` 27, `getContainerItem` 17, `getItemsCount` 14,
   `getSlotPosition` 13, plus `g_game.open` 25 / `move` 22 / `close` 13.
3. **Creature + `getSpectators*`** — 35 indirect spectator calls; `getHealthPercent` 28,
   `isPlayer` 29, `isMonster` 19, `isLocalPlayer` 14, `getType` 12.
4. **The `findEveryPath` adapter** — 19 `findPath` + 4 `getPath` + 5 `autoWalk`.
5. **Item position / stackpos semantics (§0.3)** — silently corrupts every move and stow otherwise.
6. **LocalPlayer accessors** — high count, but each is a one-line field read.
7. Everything in §6 as stubs, so nothing errors on the first tick.
