# Bot configuration API — contract for structured, panel-editable vBot config

> **STATUS: BUILT** (bot/stances.lua, bot/api.lua, bot/configschema.lua, control/commands.lua,
> hub/botconfig.lua, hub/api.lua, panel/ Bot Config tab). Verified end to end on both Windows and
> Debian/WSL: `config.get`/`config.set`/`config.list` for all six kinds, both against a running
> `--dry-run` worker over the REAL control socket / hub HTTP API and against a stopped instance's
> files directly; a HealBot threshold change proven to hot-apply on the very next bot tick with no
> restart; the cavebot `function`-body/`canExec` security rule proven live in both directions; every
> write round-trips through `tools/vbot_compat_check.lua` against a scratch copy of the real
> profile. See BOT.md's "As built" macro table (stances is macro #6) and PANEL.md's Bot Config
> section. Honest gaps: see "As built — corrections" below.

Extends BOT.md and PANEL.md. Goal (user's words): "attackbot, targeting, cavebot, conditions,
hp/mana healing, stances... should be configurable from the web panel as well." This is a
structured CRUD layer over the config files BOT.md already reads/writes, reachable from the panel
whether the instance is running or stopped, that keeps the files loadable by the real vBot
(`tools/vbot_compat_check.lua` is the acceptance test — nothing here may break it).

## The six config "kinds"

| kind | backing file(s) | shape | native module |
|---|---|---|---|
| `healbot` | `vBot_configs/profile_N/HealBot.json` → the ACTIVE `healbot[i]` profile's `itemTable`/`spellTable` | `{ itemTable: [{enabled,sign,origin,item,index,value}], spellTable: [...] }` (see bot/healbot.lua's `sourceValue`/`sign` for the exact operators: origin ∈ HP%\|HP\|MP%\|MP\|burst, sign ∈ = \| > \| < , both `>` and `<` are INCLUSIVE) | bot/healbot.lua |
| `conditions` | same `HealBot.json` → `ConditionPanel` block | the exact field set in bot/healbot.lua's `defaultConditionPanel()` — reproduce it verbatim, including the misspelled `curePosion` compat (read `curePoison` first, fall back to `curePosion`; WRITE `curePoison`, keep `curePosion` unset unless it was already present, then keep both in sync) | bot/healbot.lua (same module — conditions is a section, not a separate module) |
| `attackbot` | `AttackBot.json` → the ACTIVE profile's entries | bare array (not wrapped in an object) of attack entries; see bot/attackbot.lua / bot/configschema.lua's `ATTACKBOT_ENTRY_FIELDS` for the VERIFIED real field names: `category, patternCategory, pattern, spell, itemId, count, orMore?, minHp, maxHp, mana, cooldown, harmony?, monsters, augmented?, enabled` (+ widget-only `creatures/tooltip/description` persisted verbatim). Note the field is `mana`, not `minMana`; there is no per-entry `pvpSafe` — `PvpSafe` is a PROFILE-level flag (alongside `Kills`/`Rotate`/etc.), out of this kind's `data` | bot/attackbot.lua |
| `stances` | `storage/profile_N.json` → `stances` key (NOT a separate file — same as real vBot: `storage.stances = {enabled, ignoreInPz, entries:[{spell,spellId,enabled,minHp,maxHp,minMana,count,orMore,monsters,range,description}]}`) | see `vBot/Stances.lua` in the reference profile for the exact entry shape | **bot/stances.lua (new — build it)** |
| `targetbot` | `targetbot_configs/<name>.json` → `targeting` array + `looting` section | per docs/vbot/targetbot.md | bot/targetbot.lua |
| `cavebot` | `cavebot_configs/<name>.cfg` → the ordered waypoint list + the `config`/`extensions`/`staypositions` lines | array of `{type, value}` in file order, per docs/vbot/config-compat-cavebot.md's grammar (`type` is the vBot action keyword: goto/label/gotolabel/delay/use/usewith/say/npcsay/function/...) | bot/cavebot.lua |

For `attackbot`/`healbot`/`targetbot` there can be several named profiles/configs per instance
(vBot's numbered profiles for heal/attack, named `.json`/`.cfg` files for cavebot/targetbot). The
API always operates on **the currently selected one** (what `bot.listConfigs`/the instance's
`cavebotConfig`/`targetbotConfig`/`vprofile` fields already name); switching which one is active is
the existing `bot.setCavebot`/`bot.setTargetbot`/vprofile mechanism, unchanged by this contract.

## Security — decide this once, get it right everywhere

`cavebot`'s `function` waypoint type carries a **raw Lua chunk** that the bot executes verbatim
(BOT.md, docs/vbot/config-compat-cavebot.md). Writing one is equivalent to `exec`. Every other
field in every kind is DATA (numbers, item ids, spell words as plain strings, monster name
patterns) — none of it is ever passed to `load()`/`loadstring()`.

Rule: `config.set` for `cavebot` is gated exactly like `instance.exec` (hub/api.lua's
`EXEC_CAPABILITY` set — admin, or a user with `canExec`) **only when the diff adds or changes a
`function`-type waypoint's body**; every other cavebot edit (reordering, editing a `goto`/`delay`/
`use`/... value) needs only the normal instance-owner permission. `config.set` for the other five
kinds never needs `canExec`. Every `cavebot` write is audited; a write containing a `function` body
change is audited with the full new body (same treatment as `exec`'s audit record).

## control/commands.lua (worker side) — new commands

```
config.get  { kind }                    -> { kind, data, source }   -- source: 'profile'|'default'
config.set  { kind, data, reload=true } -> { kind, applied=true }   -- validates, writes, reload()s
config.list { kind }                    -> { names=[...], active=name }  -- attackbot/healbot profile
                                                                     -- numbers or cavebot/targetbot names
```
`config.set` validates `data` against the kind's schema (right field names and types; reject,
don't coerce, on a structural mismatch — a bad request must not corrupt the file) and calls the
owning module's existing `:reload(cfg)` so the change applies to the running bot immediately,
without restarting the worker or losing its walk/target state.

**`reload` is currently ALWAYS honored unconditionally** — every kind's `setX()` helper in
control/commands.lua calls `mod:reload(...)` regardless of what (or whether) the caller passes for
`reload`; the field is accepted (and echoed in the signature above for forward-compatibility) but
not read. This is intentional-by-default rather than a bug: it is the safer of the two behaviors,
since it means the running module's in-memory state can never drift from what was just validated
and written. A caller cannot currently get a validate-and-write-without-hot-apply request; if that
becomes a real need, honor `args.reload == false` in control/commands.lua's `cmds['config.set']`
rather than assuming this note is stale.

## hub side

`hub/botconfig.lua` (new) — pure functions over a resolved profile directory, built on
`bot/config.lua`'s `config.new(dir)` `Profile` object (already pure, no `LC` dependency — verified:
its only inputs are paths and strings). One function pair per kind: `getX(profile, ...)` /
`setX(profile, ..., data)`, used when the instance is **stopped**. Must produce byte-for-byte the
same file shape `bot/config.lua`'s own save path does (reuse its `encodeCfg`/`jsonEncode`/
`writeFileAtomic` — do not hand-roll a second encoder).

`hub/api.lua` — new routes, instance-scoped, owner-or-admin like every other instance route:
```
GET  /api/instances/:id/config/:kind        -> { kind, data, source, editable }
PUT  /api/instances/:id/config/:kind        (body: {data})  -> { kind, applied }
GET  /api/instances/:id/config/:kind/list   -> { names, active }   (attackbot/healbot profile #s,
                                                                     cavebot/targetbot file names)
```
Routing: if the instance is **running**, forward to the worker's `config.get`/`config.set` over the
control socket (so the change hot-applies and the in-memory bot state stays authoritative); if
**stopped**, read/write the files directly via `hub/botconfig.lua` (no worker needed to edit config
before first start). Both paths funnel through the SAME validation (control/commands.lua's schema
checks are mirrored — not reimplemented — in hub/botconfig.lua; factor the schema tables into a
file both sides can load, e.g. `bot/configschema.lua`, required by both `control/commands.lua` and
`hub/botconfig.lua`).

Every `PUT` writes an audit record (`instance.config`, target = instanceId, detail = kind + a short
diff summary; full body when it is a cavebot `function` change, per the Security section).

## panel/

A new **Bot Config** area on the instance view, one card per kind (Healing, Conditions, Attack,
Stances, Targeting, CaveBot), each a table editor:
* add / duplicate / remove row, up/down (or drag) reorder for ordered kinds (attackbot entries,
  stances entries — first-match-wins order matters; cavebot waypoints — execution order matters)
* inline fields matching the schema (a select for `sign`/`origin`/`category`, a number input for
  thresholds, a checkbox for `enabled`/`orMore`, a text input for spell words / monster patterns)
* a CaveBot waypoint row's `function` type shows a code textarea with a visible "this runs as Lua
  inside the bot" warning, and is only editable by an admin or a `canExec` user — mirror the
  Console tab's existing capability check, don't invent a new one
* a single **Save** button per card that PUTs the whole kind's data (simplicity over partial PATCH;
  the files are small); a **Revert** button re-fetches
* load the current data on tab open via GET; show `source: 'default'` distinctly (an empty/new
  profile) from `source: 'profile'` (loaded from a real file)
* never block the rest of the instance view — these load lazily when the card is opened

## Compatibility acceptance test

For every kind, round-trip: hub/panel writes a config → the real vBot (via
`tools/vbot_compat_check.lua`, extended to cover `storage.stances` and the `HealBot.json`
`ConditionPanel`/`itemTable` shapes if not already) still parses the file → values compare equal
(ints stay ints, arrays stay arrays, unknown fields the panel didn't touch survive unchanged).

## As built — corrections

Four work items (N1 stances, N2 schema + control commands, N3 hub API, N4 panel) built this
independently and were reconciled in an integration pass. Two real prose/reality mismatches this
document had were fixed above rather than left as silent drift, since the four builders all
independently verified the SAME real field names against bot/attackbot.lua and converged on
them anyway:

* **attackbot fields.** This document's original gloss said `minMana`/a per-entry `pvpSafe`.
  The real field is `mana`; `PvpSafe` is a profile-level flag, not part of this kind's `data`.
  Fixed above. `bot/configschema.lua`'s `ATTACKBOT_ENTRY_FIELDS` is the single source of truth
  now — read it, don't re-derive the field list from prose again.
* **attackbot `data` shape.** Confirmed to be the BARE array (schema `top = 'array'`), not an
  object wrapping it — worth calling out explicitly since it is the one kind that is not a
  `{...}` object, and it is easy to build a panel editor against the wrong assumption (N4's build
  report caught exactly this on its own).

Everything else in this document held up as written: the six kinds, the storage shapes, the
`config.get`/`config.set`/`config.list` command names and result shapes, the hub routes, and —
most importantly — the security rule (cavebot `function`-body changes need `canExec`; everything
else needs only ownership) landed exactly as specified and is proven live in both directions (a
denied plain edit, an allowed function-body edit once granted) against a real running worker.

Known, honest gaps (nothing here breaks the acceptance test, but a future pass could improve):
* No hub route exposes an item-id → name lookup, so the panel's item/rune id fields are plain
  numeric inputs (CONFIGAPI.md always permitted this fallback).
* `shim/creature.lua`'s local `stances()` helper and `bot/api.lua`'s `ctx.getStance()` /
  `ctx.getSecondaryStance()` are two independently-ported, PROVABLY IDENTICAL copies of the same
  protocolgameparse.cpp:5385-5404 derivation, not one shared function — a future refactor could
  have the shim delegate to `bot/api.lua` instead of carrying its own copy.
* Reorder in the panel is up/down buttons, not drag-and-drop (CONFIGAPI.md explicitly permits
  either).
