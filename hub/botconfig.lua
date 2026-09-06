--[[============================================================================
hub/botconfig.lua -- CONFIGAPI.md's hub-side CRUD layer over the vBot config
files, for an instance that is STOPPED (no worker to ask).

Work item N3.  Pure functions over a resolved profile directory, built on
bot/config.lua's config.new(dir) `Profile` object (already pure, no LC
dependency).  hub/api.lua is the only intended caller: it resolves the
directory (hub/supervisor.lua's `Sup:profileDir(inst.botProfile)`), wraps it in
a Profile with `botconfig.newProfile(dir)`, and calls the functions below --
routing here when the instance is stopped, or to the worker's `config.get` /
`config.set` / `config.list` control commands (work item N2,
control/commands.lua) when it is running.  Both paths validate against
bot/configschema.lua (work item N2) -- the SAME module control/commands.lua
uses, required directly here, not reimplemented.

------------------------------------------------------------------------------
THE SIX KINDS (CONFIGAPI.md's table -- names, backing files, shapes)
------------------------------------------------------------------------------
  healbot     vBot_configs/profile_N/HealBot.json -> the ACTIVE healbot[i]'s
              { itemTable, spellTable }.  Everything else on that profile
              object (name, enabled, Cooldown, Interval, Visible, Delay,
              MessageDelay, Conditions) is preserved untouched -- config.set
              replaces ONLY these two arrays on the active profile, never the
              profile object itself.
  conditions  same HealBot.json -> the ConditionPanel block (bot/healbot.lua's
              defaultConditionPanel(), verbatim field set).  The misspelled
              `curePosion` compat (bot/healbot.lua "BOTH POISON KEYS ARE READ"):
              GET exposes only the correctly-spelled `curePoison` (reading it
              first, falling back to `curePosion`); SET writes `curePoison`
              always, and additionally writes `curePosion` to the same value
              ONLY when the on-disk file already had a `curePosion` key before
              this write -- so a file that never had the misspelling does not
              grow it, and one that did stays in sync.
  attackbot   AttackBot.json -> the ACTIVE AttackBot[i]'s `attackTable` array.
              Same preserve-the-rest-of-the-profile rule as healbot.
  stances     storage/profile_N.json -> the `stances` key (NOT a separate
              file): { enabled, ignoreInPz, entries[] }.  bot/stances.lua (work
              item N2) is the native module that reads this at runtime; this
              file only reads/writes the same key as plain data.
  targetbot   targetbot_configs/<name>.json -> { targeting[], looting }.
  cavebot     cavebot_configs/<name>.cfg -> a FLAT array of `{type, value}`
              pairs, in file order -- exactly bot/config.lua's decodeCfg output
              (`key` renamed `type`), per bot/configschema.lua's own kind
              definition (`top = 'cavebot-pairs'`).  `config` / `extensions` /
              `staypositions` are just ordinary pairs in this same array whose
              `value` happens to be a JSON string (RESERVED_CFG_KEYS) -- they
              are never decoded here, so their exact bytes pass through
              untouched instead of risking a re-encode drifting from the
              original (whitespace, float formatting).  `type` is vBot's
              action keyword (goto/label/delay/.../function).

For attackbot/healbot there are always exactly 5 numbered profiles (vBot's own
invariant, reproduced by bot/healbot.lua's/bot/attackbot.lua's `normalise()`);
"the active one" is `cfg.currentHealBotProfile` / `cfg.currentBotProfile`.  For
cavebot/targetbot "the active one" is the NAME an hub/model.lua instance record
carries in `cavebotConfig` / `targetbotConfig` -- hub/api.lua passes it in, as
this module has no notion of "an instance" (CONFIGAPI.md: "switching which one
is active is the existing bot.setCavebot/.../vprofile mechanism, unchanged by
this contract").  `vprofile` is always 1 here: hub/supervisor.lua never passes
`--bot-vprofile` when it spawns a worker, so a hub-launched worker is always
vprofile 1 and this module matches that rather than inventing a second axis
nothing else in the system has a UI for yet.

------------------------------------------------------------------------------
API
------------------------------------------------------------------------------
  botconfig.newProfile(dir[, vprofile]) -> a bot/config.lua Profile

  -- one get/set pair per kind (all take a Profile as the first argument)
  botconfig.getHealbot(profile)              -> data, source | nil, err
  botconfig.setHealbot(profile, data)        -> true | nil, err
  botconfig.getConditions(profile)           -> data, source | nil, err
  botconfig.setConditions(profile, data)     -> true | nil, err
  botconfig.getAttackbot(profile)            -> data, source | nil, err
  botconfig.setAttackbot(profile, data)      -> true | nil, err
  botconfig.getStances(profile)              -> data, source | nil, err
  botconfig.setStances(profile, data)        -> true | nil, err
  botconfig.getTargetbot(profile, name)      -> data, source | nil, err
  botconfig.setTargetbot(profile, name, data)-> true | nil, err
  botconfig.getCavebot(profile, name)        -> data, source | nil, err   (data = pairs array)
  botconfig.setCavebot(profile, name, data)  -> true | nil, err

  -- generic, dispatching on `kind` (what hub/api.lua actually calls)
  botconfig.get(profile, kind[, name])         -> data, source | nil, err
  botconfig.set(profile, kind, data[, name])   -> true | nil, err
  botconfig.list(profile, kind)                -> { names=, active= } | nil, err
  botconfig.emptyFor(kind)                     -> a blank `data` shape for a
                                                   cavebot/targetbot kind with
                                                   nothing selected yet
  botconfig.validate(kind, data)               -> true | false, err
                                                   (bot/configschema.lua's own
                                                   M.validate, re-exported so
                                                   callers need only require
                                                   this one module)

  -- the ONE security-relevant helper (CONFIGAPI.md's "Security" section),
  -- re-exported from bot/configschema.lua so hub/api.lua and control/
  -- commands.lua run the exact same predicate:
  botconfig.cavebotFunctionBodyChanged(oldPairs, newPairs) -> changed(bool)

`source` is 'profile' when the backing file (or, for stances, the `stances`
key inside storage/profile_N.json) genuinely existed on disk, and 'default'
when it did not and this module built the same blank shape vBot itself would
have (CONFIGAPI.md/PANEL.md: "show source:'default' distinctly ... from
source:'profile'").

Lua 5.1 / LuaJIT: no goto, math.floor for integer division.
============================================================================]]

local botconfig = {}

local cfgmod    = require('bot.config')
local schema    = require('bot.configschema')  -- work item N2 -- the ONE validator both sides use
local healbot   = require('bot.healbot')       -- pure statics only: .normalise() -- never instantiated
local attackbot = require('bot.attackbot')     -- (no bot object, no LC; verified at the call sites)

--- botconfig.validate(kind, data) -> true | false, err
botconfig.validate = schema.validate

--- botconfig.cavebotFunctionBodyChanged(oldPairs, newPairs) -> bool
--- `oldPairs`/`newPairs` are the flat `{type=,value=}` arrays getCavebot returns
--- and setCavebot accepts -- bot/configschema.lua's `pairType`/`pairValue`
--- helpers read `.type`/`.value` (falling back to positional `[1]`/`[2]`), so
--- this shape is accepted directly, with no conversion.
botconfig.cavebotFunctionBodyChanged = schema.cavebotFunctionBodyChanged

--- botconfig.cavebotFunctionShapeChanged(oldPairs, newPairs) -> bool
--- Re-exported from bot/configschema.lua (security review follow-up): true
--- when a function-typed waypoint's INDEX or COUNT changed even though
--- cavebotFunctionBodyChanged says no body text changed -- lets hub/api.lua's
--- audit record call out a silent relocation instead of looking like an
--- ordinary value edit.
botconfig.cavebotFunctionShapeChanged = schema.cavebotFunctionShapeChanged

--- botconfig.diffSummary(kind, oldData, newData) -> a short "changed=..."
--- audit-detail string.  Re-exported from bot/configschema.lua so hub/api.lua
--- builds the SAME summary shape control/commands.lua's callers would (there
--- is currently only one caller, hub/api.lua, but this keeps the single
--- source of truth rule CONFIGAPI.md sets for the rest of this contract).
botconfig.diffSummary = schema.diffSummary

botconfig.KINDS = schema.kinds

--- botconfig.newProfile(dir[, vprofile]) -> a bot/config.lua Profile
function botconfig.newProfile(dir, vprofile)
  return cfgmod.new{ profileDir = dir, vprofile = vprofile or 1 }
end

-- ---- healbot / conditions (share HealBot.json) -----------------------------
local function loadHealTree(profile)
  local existed = cfgmod.fileExists(profile:healBotPath())
  local raw = profile:loadHealBot()
  if type(raw) ~= 'table' then raw = {} end
  healbot.normalise(raw)
  return raw, existed
end

function botconfig.getHealbot(profile)
  local cfg, existed = loadHealTree(profile)
  local p = cfg.healbot[cfg.currentHealBotProfile]
  return { itemTable = p.itemTable, spellTable = p.spellTable }, existed and 'profile' or 'default'
end

function botconfig.setHealbot(profile, data)
  local ok, verr = schema.validate('healbot', data)
  if not ok then return nil, verr end
  local cfg = loadHealTree(profile)
  local p = cfg.healbot[cfg.currentHealBotProfile]
  p.itemTable, p.spellTable = data.itemTable, data.spellTable
  return profile:saveHealBot(cfg)
end

function botconfig.getConditions(profile)
  local cfg = loadHealTree(profile)
  local existed = cfgmod.fileExists(profile:healBotPath())
  -- Mirrors control/commands.lua's own getConditions field for field --
  -- `curePosion` included, verbatim, alongside the canonical `curePoison`
  -- (bot/configschema.lua's CONDITIONS_FIELDS declares `curePosion` optional
  -- for exactly this reason: it is not hidden, only never required) -- so the
  -- running and stopped paths answer the identical object.  Merging onto the
  -- module's own defaults first (which a running module does not need, since
  -- it was already normalised at load time) only matters for a legacy
  -- on-disk ConditionPanel that predates a newer field.
  local base = healbot.defaultConditionPanel()
  for k, v in pairs(cfg.ConditionPanel) do base[k] = v end
  local out = {}
  for k, v in pairs(base) do out[k] = v end
  if out.curePoison == nil then out.curePoison = out.curePosion end
  return out, existed and 'profile' or 'default'
end

function botconfig.setConditions(profile, data)
  local ok, verr = schema.validate('conditions', data)
  if not ok then return nil, verr end
  local cfg = loadHealTree(profile)
  local old = cfg.ConditionPanel
  local C = {}
  for k, v in pairs(data) do C[k] = v end
  if old.curePosion ~= nil or data.curePosion ~= nil then
    C.curePosion = (data.curePosion ~= nil) and data.curePosion or data.curePoison
  else
    C.curePosion = nil
  end
  cfg.ConditionPanel = C
  return profile:saveHealBot(cfg)
end

-- ---- attackbot --------------------------------------------------------------
local function loadAttackTree(profile)
  local existed = cfgmod.fileExists(profile:attackBotPath())
  local raw = profile:loadAttackBot()
  if type(raw) ~= 'table' then raw = {} end
  attackbot.normalise(raw)
  return raw, existed
end

function botconfig.getAttackbot(profile)
  local cfg, existed = loadAttackTree(profile)
  local p = cfg.AttackBot[cfg.currentBotProfile]
  return p.attackTable, existed and 'profile' or 'default'
end

function botconfig.setAttackbot(profile, data)
  local ok, verr = schema.validate('attackbot', data)
  if not ok then return nil, verr end
  local cfg = loadAttackTree(profile)
  cfg.AttackBot[cfg.currentBotProfile].attackTable = data
  return profile:saveAttackBot(cfg)
end

-- ---- stances (storage/profile_N.json -> `stances`) --------------------------
local function defaultStances() return { enabled = false, ignoreInPz = true, entries = {} } end

local function loadStancesTree(profile)
  local st = profile:loadStorage()
  if type(st) ~= 'table' then st = {} end
  local had = type(st.stances) == 'table'
  if not had then st.stances = defaultStances() end
  local sc = st.stances
  if type(sc.entries) ~= 'table' then sc.entries = {} end
  if type(sc.enabled) ~= 'boolean' then sc.enabled = false end
  if type(sc.ignoreInPz) ~= 'boolean' then sc.ignoreInPz = true end
  return st, had
end

function botconfig.getStances(profile)
  local st, had = loadStancesTree(profile)
  local sc = st.stances
  return { enabled = sc.enabled, ignoreInPz = sc.ignoreInPz, entries = sc.entries },
         had and 'profile' or 'default'
end

function botconfig.setStances(profile, data)
  local ok, verr = schema.validate('stances', data)
  if not ok then return nil, verr end
  local st = loadStancesTree(profile)
  st.stances.enabled    = data.enabled and true or false
  st.stances.ignoreInPz = data.ignoreInPz and true or false
  st.stances.entries    = data.entries
  return profile:saveStorage(st)
end

-- ---- targetbot ---------------------------------------------------------------
function botconfig.getTargetbot(profile, name)
  if not name or name == '' then return nil, 'no targetbot config is selected' end
  local existed = cfgmod.fileExists(profile:path('targetbot_configs', name .. '.json'))
  local raw = profile:loadTargetbot(name)
  if type(raw) ~= 'table' then raw = {} end
  if type(raw.targeting) ~= 'table' then raw.targeting = {} end
  if raw.looting ~= nil and type(raw.looting) ~= 'table' then raw.looting = nil end
  return { targeting = raw.targeting, looting = raw.looting }, existed and 'profile' or 'default'
end

function botconfig.setTargetbot(profile, name, data)
  if not name or name == '' then return nil, 'no targetbot config is selected' end
  local ok, verr = schema.validate('targetbot', data)
  if not ok then return nil, verr end
  local raw = profile:loadTargetbot(name)
  if type(raw) ~= 'table' then raw = {} end
  raw.targeting = data.targeting
  if data.looting ~= nil then
    -- an EMPTY {} from the panel must stay an OBJECT on disk (targetbot.lua
    -- reads `looting.items`/`.containers` as fields, never as an array) --
    -- bot/config.lua's own encoder otherwise falls back to "[]" for a table it
    -- has never seen with no shape tag (see bot/config.lua's own header).
    if type(data.looting) == 'table' and next(data.looting) == nil then
      cfgmod.markObject(data.looting)
    end
    raw.looting = data.looting
  end
  return profile:saveTargetbot(name, raw)
end

-- ---- cavebot -----------------------------------------------------------------
--- data = a flat array of { type=, value= } pairs, in file order -- see the
--- header.  `config`/`extensions`/`staypositions` are ordinary entries here
--- (RESERVED_CFG_KEYS), never decoded, so their JSON text round-trips
--- byte-for-byte with no re-encode.
function botconfig.getCavebot(profile, name)
  if not name or name == '' then return nil, 'no cavebot config is selected' end
  local path = profile:path('cavebot_configs', name .. '.cfg')
  if not cfgmod.fileExists(path) then return {}, 'default' end
  local text, err = cfgmod.readFile(path)
  if not text then return nil, err end
  local decoded = cfgmod.decodeCfg(text)
  local out = {}
  for i, p in ipairs(decoded) do out[i] = { type = p[1], value = p[2] } end
  return out, 'profile'
end

function botconfig.setCavebot(profile, name, data)
  if not name or name == '' then return nil, 'no cavebot config is selected' end
  local ok, verr = schema.validate('cavebot', data)
  if not ok then return nil, verr end
  local pairs_ = {}
  for i, p in ipairs(data) do pairs_[i] = { p.type or p[1], p.value or p[2] } end
  return profile:saveCavebotRaw(name, pairs_)
end

--- A blank `data` shape for a cavebot/targetbot kind with nothing selected yet
--- -- not an error, just nothing to show (PANEL.md: "never block the rest of
--- the instance view").
function botconfig.emptyFor(kind)
  if kind == 'cavebot' then return {} end
  if kind == 'targetbot' then return { targeting = {}, looting = nil } end
  return {}
end

-- ---- list (config.list {kind} -> {names, active}) --------------------------
local function selectedOf(profile, dirKey)
  local st = profile:loadStorage()
  local c = type(st) == 'table' and type(st._configs) == 'table' and st._configs[dirKey]
  return (type(c) == 'table' and c.selected) or ''
end

-- NOTE: shapes below match control/commands.lua's `config.list` (work item N2)
-- exactly -- numbers for healbot/attackbot (not stringified), and an empty
-- {names={}, active=nil} for the two single-object kinds -- so a panel that
-- switches between a running and a stopped instance sees the identical shape.
function botconfig.listConfigs(profile, kind)
  if kind == 'healbot' then
    local cfg = loadHealTree(profile)
    return { names = { 1, 2, 3, 4, 5 }, active = cfg.currentHealBotProfile }
  elseif kind == 'conditions' then
    return { names = {}, active = nil }
  elseif kind == 'attackbot' then
    local cfg = loadAttackTree(profile)
    return { names = { 1, 2, 3, 4, 5 }, active = cfg.currentBotProfile }
  elseif kind == 'stances' then
    return { names = {}, active = nil }
  elseif kind == 'cavebot' then
    return { names = profile:listCavebots(), active = selectedOf(profile, 'cavebot_configs') }
  elseif kind == 'targetbot' then
    return { names = profile:listTargetbots(), active = selectedOf(profile, 'targetbot_configs') }
  end
  return nil, 'unknown config kind: ' .. tostring(kind)
end

-- ===========================================================================
-- generic dispatch -- what hub/api.lua actually calls
-- ===========================================================================

--- botconfig.get(profile, kind[, name]) -> data, source | nil, err
function botconfig.get(profile, kind, name)
  if kind == 'healbot'    then return botconfig.getHealbot(profile) end
  if kind == 'conditions' then return botconfig.getConditions(profile) end
  if kind == 'attackbot'  then return botconfig.getAttackbot(profile) end
  if kind == 'stances'    then return botconfig.getStances(profile) end
  if kind == 'targetbot'  then return botconfig.getTargetbot(profile, name) end
  if kind == 'cavebot'    then return botconfig.getCavebot(profile, name) end
  return nil, 'unknown config kind: ' .. tostring(kind)
end

--- botconfig.set(profile, kind, data[, name]) -> true | nil, err
function botconfig.set(profile, kind, data, name)
  if kind == 'healbot'    then return botconfig.setHealbot(profile, data) end
  if kind == 'conditions' then return botconfig.setConditions(profile, data) end
  if kind == 'attackbot'  then return botconfig.setAttackbot(profile, data) end
  if kind == 'stances'    then return botconfig.setStances(profile, data) end
  if kind == 'targetbot'  then return botconfig.setTargetbot(profile, name, data) end
  if kind == 'cavebot'    then return botconfig.setCavebot(profile, name, data) end
  return nil, 'unknown config kind: ' .. tostring(kind)
end

--- botconfig.list(profile, kind) -> { names=, active= } | nil, err
function botconfig.list(profile, kind) return botconfig.listConfigs(profile, kind) end

return botconfig
