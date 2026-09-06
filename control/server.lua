--[[============================================================================
control/server.lua -- the worker's local control endpoint (PANEL.md "Worker
control protocol") and the telemetry that feeds the panel's numbers.

    local control = require('control.server')
    local srv, err = control.new{
        LC    = _G.LC,
        host  = '127.0.0.1',       -- loopback unless allowRemote is set
        port  = 0,                 -- 0 = ephemeral; :start() returns the real one
        token = tokenString,       -- REQUIRED; the hub passes it by stdin or a file
        instanceName = 'char-a',
        pricesPath   = nil,        -- vBot items.lua for the loot/waste value model
        pricesFile   = nil,        -- operator override (else $LUACLIENT_PRICES)
    }
    local port, e = srv:start()
    srv:broadcast('status', {...})
    srv:stop()

------------------------------------------------------------------------------
WIRE PROTOCOL
------------------------------------------------------------------------------
Requests are JSON objects `{id, cmd, args}` and answers are `{id, ok, result}`
or `{id, ok:false, error}`.  Two transports, one command table (control/commands.lua)
-- this includes CONFIGAPI.md's `config.get` / `config.set` / `config.list`
(work item N2): they are dispatched exactly like every other command, no
transport-level change needed -- a rejected `config.set` (bad schema, or a
cavebot function-body change without `execCapability`) comes back as an
ordinary `{id, ok:false, error}` or `{id, ok:true, result={applied=false,...}}`
depending on which the command itself chose (see control/commands.lua's
config.* section for which is which).

  POST /rpc      body = one request object      -> one answer object
  GET  /ws       WebSocket; each TEXT message is one request object, each answer
                 comes back as one TEXT message, and the server also PUSHES
                 `{event, data}` objects at any time.
  GET  /health   `{ok:true, instance, uptimeMs}` -- still authenticated.

Events pushed on /ws: `status` (1 Hz), `stats` (every statsIntervalMs), `log`,
`chat`, `loginState`, `gameStart`, `gameEnd`, `death`, `error`.

------------------------------------------------------------------------------
AUTHENTICATION AND BINDING
------------------------------------------------------------------------------
* Every request needs the token: `Authorization: Bearer <token>`, or
  `X-Control-Token: <token>`, or -- for the WebSocket handshake only, because a
  browser cannot set a header on one -- `?token=<token>` in the query string.
  A missing or wrong token is 401 on HTTP and a refused (401) handshake on /ws.
  The comparison is constant-time in the length of the presented token.
* The token is never logged, never echoed in an error and never included in
  `status`.  A query-string token is REDACTED out of `req.target` / `req.rawQuery`
  / `req.query` the moment it is read, so nothing downstream -- a future access
  log, an error message, a handler that echoes the path -- can leak it.
  (lib/httpserver.lua logs no request target today; this keeps it true tomorrow.)
* The listener binds 127.0.0.1 unless `allowRemote = true` is passed explicitly,
  and `Host:` is pinned to the loopback names (httpserver's allowedHosts), which
  is what closes DNS rebinding against a browser on the same machine.
* The WebSocket Origin check is lib/wsserver.lua's default (same-origin), with
  `allowNoOrigin = true`: the hub is not a browser and sends no Origin at all.

------------------------------------------------------------------------------
TELEMETRY -- WHAT IS REAL AND WHAT IS ZERO
------------------------------------------------------------------------------
lib/stats.lua is fed from the live event stream:

  REAL, from the protocol:
    experience, level, level %   0xA0 PlayerData -> state.player.exp/level
                                 (sampled at 1 Hz; exp/h and the session average
                                 are then lib/stats.lua's sliding window)
    gold on hand                 gold/platinum/crystal counted across the
                                 inventory and every OPEN container, 1 Hz ->
                                 sampleBalance, which is what money/h uses
    deaths                       the `death` event
    kills                        "Loot of <name>" server messages (mode Loot),
                                 which is exactly where vBot's analyzer counts
                                 them (analyzer.lua:863-877)
    loot                         items entering a LOOT container
                                 (containerAddItem / containerUpdateItem, the
                                 destination filtered by the bot's loot-bag list)
    waste                        "Using one of the <item>s..." messages, vBot's
                                 analyzer.lua:1501-1540 rule

    loot / waste VALUE           vBot keeps prices keyed by NAME (`LootItems` in the
                                 profile's vBot/items.lua -- see buildPrices below for
                                 the citation); we map those names onto item ids
                                 through proto/items.lua's name index at start-up.
                                 An operator without a vBot profile can point
                                 `LUACLIENT_PRICES` at an id-keyed JSON or Lua file
                                 instead (the hub can set it for every worker with
                                 --worker-env), and it overrides the profile per id.
                                 With NEITHER, only the three coins are priced, the
                                 counts stay exact, every other value is 0, and the
                                 snapshot says `pricesLoaded == 0`,
                                 `pricesSource == 'coins-only'` and
                                 `noDataFor` contains `itemPrices` -- so the panel
                                 prints "prices not loaded" instead of a confident 0.
    money/h                      cash-on-hand delta PLUS the value of the non-coin
                                 loot MINUS the waste value (lib/stats.lua's
                                 'gold+goods' model; the coin ids are declared as
                                 cash so the gauge and the loot term cannot count the
                                 same coin twice).
    supplies vs thresholds       bot/supplies.lua's per-item ledger: the live count of
                                 each configured id (inventory + open containers, or
                                 the server's own 0xC0 total, whichever is larger)
                                 against its `min` from the profile's Supplies.json.
                                 It travels as the pure ARRAY `supplies`, with the
                                 profile/rounds/pouch context beside it in
                                 `suppliesStatus`.  With no supplies module at all,
                                 `noDataFor` contains `supplies`.

  ZERO WITHOUT A DATA SOURCE, and said so in the snapshot:
    reconnects                   the hub's supervisor bookkeeping, not the worker's.

Lua 5.1 / LuaJIT: no goto, math.floor for integer division.
============================================================================]]

local M = { VERSION = '1.0' }

local json       = require('lib.json')
local sys        = require('lib.sys')
local log        = require('lib.log')
local sched      = require('lib.sched')
local statsmod   = require('lib.stats')
local httpserver = require('lib.httpserver')
local wsserver   = require('lib.wsserver')
local commands   = require('control.commands')
local http       = require('lib.http')      -- runAsync only; see handleRequest

local floor = math.floor

-- lib/events.lua is BOTH a bus and a module: `events.on(name, fn)` on the module, but
-- `bus:on(name, fn)` on an independent bus from events.new().  The worker hands us the
-- module; a test may hand us its own bus.  One adapter, so both work.
local function busOn(bus, name, fn)
    if bus.new then return bus.on(name, fn) end
    return bus:on(name, fn)
end

local function busOff(bus, handle)
    if bus.new then return bus.off(handle) end
    return bus:off(handle)
end

-- ===========================================================================
-- constant-time token comparison
-- ===========================================================================
-- Both operands are hashed to a fixed length first, so the comparison itself
-- reveals nothing about the real token's length either.
local sha2 = require('lib.sha2')
local function tokenDigest(s)
    return sha2.sha256(tostring(s))
end

local function constantTimeEqual(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' then return false end
    local da, db = tokenDigest(a), tokenDigest(b)
    if #da ~= #db then return false end
    local diff = 0
    for i = 1, #da do
        diff = diff + (da:byte(i) == db:byte(i) and 0 or 1)
    end
    return diff == 0
end
M._constantTimeEqual = constantTimeEqual

-- ===========================================================================
-- telemetry
-- ===========================================================================
local COIN_VALUE = { [3031] = 1, [3035] = 100, [3043] = 10000 }   -- gold / platinum / crystal
M.COIN_VALUE = COIN_VALUE

local Telemetry = {}
Telemetry.__index = Telemetry

--- WHERE THE PRICES COME FROM.
---
--- The user's vBot keeps its price list in the profile's own `vBot/items.lua`, as a
--- single global table `LootItems` keyed by LOWERCASE ITEM NAME:
---
---     LootItems = { ["gold coin"] = 1, ["platinum coin"] = 100,
---                   ["crystal coin"] = 10000, ["abyss hammer"] = 20000, ... }
---
--- (verbatim from D:/Claude/otclient_mehah1530/otclient/profiles/bot/vBot_4.8/vBot/
--- items.lua:1-5; `vBot/analyzer.lua:645-672` getPrice() lowercases the looted name,
--- strips a leading "a "/"an " and the leading count, checks
--- `storage.analyzers.customPrices` first, then scans that table, and returns 0 for a
--- name it cannot find.)  Everything the panel needs is an id, not a name, so the
--- table is turned into `id -> price` here by walking proto/items.lua's own name
--- index once at start-up.  Names that no item in items1530.bin carries are counted
--- and reported as `pricesUnmapped` rather than silently dropped.
---
--- Returns table, loaded (ids priced), unmapped (LootItems names that matched no id).
local function buildPrices(pricesPath)
    if not pricesPath then return nil, 0, 0 end
    local f = io.open(pricesPath, 'r')
    if not f then return nil, 0, 0 end
    local text = f:read('*a') or ''
    f:close()
    -- items.lua is a plain sequence of `Name = { ... }` global assignments; run it in an
    -- empty environment and pick the table out, so nothing it does can touch us.
    local chunk, err = loadstring(text, '@vBot items.lua')
    if not chunk then
        log.warn('control: %s does not compile (%s) -- loot values will be 0',
                 pricesPath, tostring(err))
        return nil, 0, 0
    end
    local env = {}
    setfenv(chunk, setmetatable(env, { __index = {} }))
    local ok = pcall(chunk)
    if not ok then return nil, 0, 0 end
    local byName = env.LootItems
    if type(byName) ~= 'table' then return nil, 0, 0 end

    local okItems, items = pcall(require, 'proto.items')
    if not okItems or not items.name or not items.MAX_ID then return nil, 0, 0 end

    local prices, loaded = {}, 0
    local matchedName = {}
    for id = 100, items.MAX_ID do
        local okn, nm = pcall(items.name, id)
        if okn and type(nm) == 'string' and nm ~= '' then
            local low = nm:lower()
            local v = byName[nm]
            local key = nm
            if v == nil then v, key = byName[low], low end
            if type(v) == 'number' and v > 0 and prices[id] == nil then
                prices[id] = v
                loaded = loaded + 1
                matchedName[key] = true
            end
        end
    end
    -- REVIEW FIX: `unmapped` used to be `#names - #ids`, which is nonsense in both
    -- directions -- several ids share one name ("gold coin" is a handful of client
    -- ids), so the subtraction went NEGATIVE for the user's real file and was then
    -- clamped to 0, reporting "every price mapped" while names really had been
    -- dropped.  Count the NAMES that matched nothing instead; that is the number an
    -- operator can act on (it names items their items1530.bin does not have).
    local unmapped = 0
    for k in pairs(byName) do if not matchedName[k] then unmapped = unmapped + 1 end end
    return prices, loaded, unmapped
end
M._buildPrices = buildPrices

--- The operator's own price file, for a deployment that has no vBot profile beside
--- the worker (a bare Debian server, say).  Its path comes from the environment --
--- `LUACLIENT_PRICES` -- because the hub can already put one there for every worker
--- with `--worker-env=LUACLIENT_PRICES=/etc/luaclient/prices.json` and a settings
--- path is not a credential.  Accepts either JSON `{"3031": 1}` or a Lua table
--- `{ [3031] = 1 }`, both id-keyed; lib/stats.lua's decodePrices refuses a
--- name-keyed table outright rather than making every item silently worth 0.
--- Returns table, loaded, path, err.
local function loadOperatorPrices(explicitPath)
    local path = explicitPath or os.getenv('LUACLIENT_PRICES')
    if type(path) ~= 'string' or path == '' then return nil, 0, nil, nil end
    local tbl, loaded, err = statsmod.loadPrices(path, json.decode)
    if not tbl then
        log.warn('control: prices file %s could not be used (%s) -- ' ..
                 'falling back to the profile table', path, tostring(loaded or err))
        return nil, 0, path, tostring(loaded or err)
    end
    return tbl, loaded or 0, path, nil
end
M._loadOperatorPrices = loadOperatorPrices

function M.newTelemetry(opts)
    opts = opts or {}
    local prices, loaded, unmapped = buildPrices(opts.pricesPath)
    prices = prices or {}
    -- The operator's file wins over the profile: it is the more specific statement of
    -- what an item is worth on THIS server, and it is the only source a deployment
    -- without a vBot profile has at all.
    local extra, fromFile, filePath, fileErr = loadOperatorPrices(opts.pricesFile)
    if extra then
        for id, v in pairs(extra) do prices[id] = v end
    end
    -- COIN_VALUE is always right and never comes from a profile; make sure the three
    -- coins are priced even when neither source loaded.  These three are NOT counted
    -- as "prices loaded" -- pricing only the coins is exactly the state the panel has
    -- to be able to call "prices not loaded".
    for id, v in pairs(COIN_VALUE) do if prices[id] == nil then prices[id] = v end end

    local self = setmetatable({
        LC = opts.LC,
        engine = statsmod.new{ window = opts.windowMs or (15 * 60 * 1000), prices = prices,
                               cashItems = COIN_VALUE },
        pricesFromProfile = loaded,
        pricesFromFile    = fromFile,
        pricesUnmapped    = unmapped,
        pricesPath = opts.pricesPath,
        pricesFilePath = filePath,
        pricesFileError = fileErr,
        handles = {},
        lastGold = nil,
        sessionOpen = false,
        wasteSeen = {},          -- vBot's `useData`: the last "using one of N" count per name
        nameToId = nil,          -- lazily built, for the waste messages
    }, Telemetry)
    return self
end

--- Gold, platinum and crystal coins across the inventory and every OPEN container.
--- This is `money on hand`, which is what PANEL.md's money/h is defined over; loot the
--- character is carrying as items is counted by the loot model instead.
function Telemetry:goldOnHand()
    local st = self.LC and self.LC.state
    if not st then return nil end
    local pl = st.player
    local total = 0
    if pl and type(pl.inventory) == 'table' then
        for _, it in pairs(pl.inventory) do
            if type(it) == 'table' and COIN_VALUE[it.id] then
                total = total + COIN_VALUE[it.id] * (it.count or 1)
            end
        end
    end
    if type(st.containers) == 'table' then
        for _, c in pairs(st.containers) do
            local list = type(c) == 'table' and c.items or nil
            if type(list) == 'table' then
                for i = 1, #list do
                    local it = list[i]
                    if type(it) == 'table' and COIN_VALUE[it.id] then
                        total = total + COIN_VALUE[it.id] * (it.count or 1)
                    end
                end
            end
        end
    end
    return total
end

--- Is `containerId` one of the bot's loot bags?  vBot filters exactly this way
--- (analyzer.lua:1440 `table.find(containers, container:getContainerItem():getId())`):
--- the destination container's ITEM id has to be in the TargetBot looting container
--- list.  Without a running loot module nothing is counted -- which is honest: we
--- cannot tell a looted item from one the player moved.
function Telemetry:isLootContainer(containerId)
    local LC = self.LC
    local b = LC and LC.bot
    local tb = b and b.modules and b.modules.targetbot
    local lootm = tb and tb.loot
    if not lootm then return false end
    -- a corpse we are looting FROM is never a destination
    if lootm.isLootContainer and lootm.isLootContainer[containerId] then return false end
    local wanted = lootm.containers
    if type(wanted) ~= 'table' or #wanted == 0 then return false end
    local st = LC.state
    local c = st and st.containers and st.containers[containerId]
    local itemId = c and c.item and c.item.id
    if not itemId then return false end
    for i = 1, #wanted do
        local w = wanted[i]
        if w == itemId or (type(w) == 'table' and w.id == itemId) then return true end
    end
    return false
end

function Telemetry:nameToItemId(name)
    if not self.nameToId then
        local map = {}
        local okItems, items = pcall(require, 'proto.items')
        if okItems and items.name and items.MAX_ID then
            for id = 100, items.MAX_ID do
                local okn, nm = pcall(items.name, id)
                if okn and type(nm) == 'string' and nm ~= '' then
                    local key = nm:lower()
                    if map[key] == nil then map[key] = id end
                end
            end
        end
        self.nameToId = map
    end
    return self.nameToId[tostring(name):lower()]
end

--- "Loot of a rat: 12 gold coins" -> the monster name, vBot's analyzer regex
--- `Loot of (?:an |a |the |)([^:]+)` (analyzer.lua:863) as a Lua pattern.
function M.parseLootOf(text)
    if type(text) ~= 'string' then return nil end
    local rest = text:match('^Loot of%s+(.+)$') or text:match('Loot of%s+(.+)$')
    if not rest then return nil end
    local name = rest:match('^(.-):')
    if not name then return nil end
    name = name:gsub('^[Aa]n%s+', ''):gsub('^[Aa]%s+', ''):gsub('^[Tt]he%s+', '')
    name = name:gsub('^%s+', ''):gsub('%s+$', '')
    if name == '' then return nil end
    return name
end

--- "Using one of 24 mana potions..." -> count, name  (analyzer.lua:1501-1540).
function M.parseUsingOneOf(text)
    if type(text) ~= 'string' then return nil end
    local low = text:lower()
    if not low:find('using one of', 1, true) then return nil end
    local count = tonumber(low:match('(%d+)'))
    -- the plural noun phrase that follows the number, up to the trailing dots
    local name = low:match('using one of%s+%d+%s+([%a%s]+)')
    if not name then name = low:match('using one of%s+([%a%s]+)') end
    if not name then return nil end
    name = name:gsub('%s+$', '')
    if name == '' then return nil end
    -- vBot's regex captures the SINGULAR by dropping the trailing 's'
    local singular = name:gsub('s$', '')
    return count, singular, name
end

function Telemetry:attach()
    local LC = self.LC
    local bus = LC and LC.events
    if not bus then return end
    local T = self

    local function on(name, fn)
        self.handles[#self.handles + 1] = busOn(bus, name, fn)
    end

    on('textMessage', function(d)
        local text = d and d.text
        if type(text) ~= 'string' then return end
        local ms = sys.nowMs()
        local monster = M.parseLootOf(text)
        if monster then
            T.engine:addKill(ms, monster)
            return
        end
        local count, singular = M.parseUsingOneOf(text)
        if count and singular then
            -- vBot only counts a use when the reported stack fell by exactly one, which
            -- is what stops a re-print of the same message double-counting.
            local prev = T.wasteSeen[singular]
            T.wasteSeen[singular] = count
            if prev ~= nil and (prev - count) == 1 then
                local id = T:nameToItemId(singular) or T:nameToItemId(singular .. 's')
                if id then T.engine:addWaste(ms, id, 1) end
            end
        end
    end)

    local function lootFrom(d, delta)
        if not d or not d.item or not d.item.id then return end
        if not T:isLootContainer(d.containerId) then return end
        local n = delta or (d.item.count or 1)
        if n <= 0 then return end
        T.engine:addLoot(sys.nowMs(), d.item.id, n)
    end
    on('containerAddItem', function(d) lootFrom(d, d and d.item and (d.item.count or 1)) end)
    on('containerUpdateItem', function(d)
        -- Only a GROWING stack is loot; a shrinking one is the player spending it.
        local it = d and d.item
        local old = d and d.oldItem
        if not it then return end
        local delta = (it.count or 1) - (old and (old.count or 1) or 0)
        if delta > 0 then lootFrom(d, delta) end
    end)

    on('death', function() T.engine:addDeath(sys.nowMs()) end)
    on('gameStart', function() T:sessionStart() end)
    on('login', function() T:sessionStart() end)
end

function Telemetry:detach()
    local bus = self.LC and self.LC.events
    if bus then
        for i = 1, #self.handles do pcall(busOff, bus, self.handles[i]) end
    end
    self.handles = {}
end

function Telemetry:sessionStart()
    if self.sessionOpen then return end
    self.sessionOpen = true
    self.engine:sessionStart(sys.nowMs())
end

--- Called at 1 Hz from the server's status timer.
function Telemetry:sample()
    local st = self.LC and self.LC.state
    local pl = st and st.player
    local ms = sys.nowMs()
    if pl then
        if type(pl.exp) == 'number' and pl.exp > 0 then
            self.engine:sampleExperience(ms, pl.exp)
        end
        if type(pl.level) == 'number' and pl.level > 0 then
            self.engine:sampleLevel(ms, pl.level, pl.levelPercent)
        end
    end
    local gold = self:goldOnHand()
    if gold ~= nil then
        self.lastGold = gold
        self.engine:sampleBalance(ms, gold)
    end
end

function Telemetry:snapshot(full)
    local s = self.engine:snapshot(sys.nowMs())
    -- HONEST PRICE REPORTING.  The engine's own `pricesLoaded` counts every entry in
    -- the table it was handed, and that table ALWAYS has the three coins in it, so it
    -- can never be 0 and the panel could never tell "prices loaded" from "only the
    -- coins are". Overwrite it with the number that actually answers the question --
    -- how many item prices came from a real source -- and keep the engine's own count
    -- beside it under a name that says what it is.
    local real = (self.pricesFromProfile or 0) + (self.pricesFromFile or 0)
    s.pricesInTable     = s.pricesLoaded
    s.pricesLoaded      = real
    s.pricesFromProfile = self.pricesFromProfile
    s.pricesFromFile    = self.pricesFromFile
    s.pricesUnmapped    = self.pricesUnmapped
    s.pricesPath        = self.pricesPath
    s.pricesFilePath    = self.pricesFilePath
    s.pricesFileError   = self.pricesFileError
    s.pricesSource      = (real == 0) and 'coins-only'
                          or ((self.pricesFromFile or 0) > 0
                              and ((self.pricesFromProfile or 0) > 0 and 'profile+file' or 'file')
                              or 'profile')
    s.goldOnHand        = self.lastGold
    -- Say out loud which figures cannot be real yet, so the panel does not have to guess.
    local missing = {}
    if real == 0 then
        missing[#missing + 1] = 'itemPrices'
    end
    local b = self.LC and self.LC.bot
    local tb = b and b.modules and b.modules.targetbot
    if not (tb and tb.loot and type(tb.loot.containers) == 'table' and #tb.loot.containers > 0) then
        missing[#missing + 1] = 'lootContainers'
    end
    local sup = b and b.modules and b.modules.supplies
    if not sup then
        missing[#missing + 1] = 'supplies'
    end
    s.noDataFor = missing
    if not full then
        s.lootItems, s.wasteItems, s.killsByName = nil, nil, nil
    end
    if b then
        local oks, bst = pcall(b.status, b)
        if oks and type(bst) == 'table' and type(bst.supplies) == 'table' then
            -- the pure ARRAY, and its context beside it -- see control/commands.lua's
            -- botSnapshot for why the two must not share one table.
            if type(bst.supplies.levels) == 'table' then s.supplies = bst.supplies.levels end
            local ctx = {}
            for k, v in pairs(bst.supplies) do
                if type(k) == 'string' and k ~= 'levels' then ctx[k] = v end
            end
            s.suppliesStatus = ctx
        end
    end
    return s
end

-- ===========================================================================
-- the server
-- ===========================================================================
local Server = {}
Server.__index = Server
M.Server = Server

local LOOPBACK_HOSTS = { '127.0.0.1', 'localhost', '::1', '[::1]' }

function M.new(opts)
    opts = opts or {}
    local LC = opts.LC or _G.LC
    if type(LC) ~= 'table' then return nil, 'control.new: LC is required' end
    local token = opts.token
    if type(token) ~= 'string' or #token < 8 then
        return nil, 'control.new: a token of at least 8 characters is required ' ..
                    '(the hub passes it on stdin or in a file, never in argv)'
    end
    local host = opts.host or '127.0.0.1'
    local loopback = (host == '127.0.0.1' or host == 'localhost' or host == '::1')
    if not loopback and not opts.allowRemote then
        return nil, ('control.new: refusing to bind %s -- the control endpoint is ' ..
                     'loopback-only unless allowRemote is set explicitly'):format(host)
    end

    local self = setmetatable({
        LC = LC,
        host = host,
        port = tonumber(opts.port) or 0,
        token = token,
        instanceName = opts.instanceName or 'worker',
        allowRemote = opts.allowRemote and true or false,
        statusIntervalMs = tonumber(opts.statusIntervalMs) or 1000,
        statsIntervalMs  = tonumber(opts.statsIntervalMs) or 5000,
        maxLogQueue = tonumber(opts.maxLogQueue) or 200,
        clients = {},                    -- ws.id -> ws
        clientCount = 0,
        startedMs = sys.nowMs(),
        stat = { requests = 0, errors = 0, unauthorized = 0, events = 0, wsOpened = 0 },
    }, Server)

    self.telemetry = M.newTelemetry{ LC = LC, pricesPath = opts.pricesPath,
                                     pricesFile = opts.pricesFile,
                                     windowMs = opts.windowMs }
    self.ctx = { LC = LC, server = self, log = log }
    return self
end

-- ------------------------------------------------------------- auth ---------
--- Pull the presented token out of a request WITHOUT ever putting it in a log line.
local function presentedToken(req)
    local auth = req:header('authorization')
    if type(auth) == 'string' then
        local b = auth:match('^%s*[Bb]earer%s+(.+)%s*$')
        if b then return b end
    end
    local x = req:header('x-control-token')
    if type(x) == 'string' and x ~= '' then return x end
    -- Query string: the ONLY way a browser can authenticate a WebSocket handshake.
    -- Read it once and REDACT it, so the value cannot travel any further with the
    -- request object than this function.
    local q = req.query
    if type(q) == 'table' and type(q.token) == 'string' then
        local t = q.token
        q.token = '<redacted>'
        if type(req.rawQuery) == 'string' then
            req.rawQuery = req.rawQuery:gsub('([?&]?token=)[^&]*', '%1<redacted>')
        end
        if type(req.target) == 'string' then
            req.target = req.target:gsub('([?&]token=)[^&]*', '%1<redacted>')
        end
        return t
    end
    return nil
end

function Server:authorised(req)
    local t = presentedToken(req)
    if not t then return false end
    return constantTimeEqual(t, self.token)
end

-- ------------------------------------------------------------- replies ------
-- ---------------------------------------------------------------- JSON safety
-- Everything that leaves here is a Lua table someone else built: a bot module's status
-- (`supplies` is keyed by item id AND by name, which rxi-json refuses as "mixed key
-- types"), or whatever an `exec` chunk returned.  One un-encodable field must not cost
-- the panel the whole reply, so every payload is normalised first:
--
--   * a contiguous 1..n table with no other keys stays an ARRAY; anything else becomes
--     an OBJECT with stringified keys (so {[3031]=..., ammo=...} survives intact);
--   * functions, userdata, threads and NaN/infinity become their tostring();
--   * a cycle becomes '<cycle>' instead of recursing forever;
--   * depth and node count are capped, so a hostile or merely huge structure cannot
--     stall the reactor or blow the frame size.
local MAX_JSON_DEPTH = 12
local MAX_JSON_NODES = 20000

local function jsonSafe(v, depth, seen, budget)
    depth = depth or 0
    seen = seen or {}
    budget = budget or { n = MAX_JSON_NODES }
    local t = type(v)
    if t == 'string' or t == 'boolean' then return v end
    if t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
        return v
    end
    if t == 'nil' then return nil end
    if t ~= 'table' then return tostring(v) end
    if depth >= MAX_JSON_DEPTH then return '<depth>' end
    if seen[v] then return '<cycle>' end
    budget.n = budget.n - 1
    if budget.n <= 0 then return '<truncated>' end
    seen[v] = true

    -- array or object?
    local n, isArray = 0, true
    for k in pairs(v) do
        n = n + 1
        if type(k) ~= 'number' or k < 1 or k ~= floor(k) then isArray = false end
    end
    if isArray then
        for i = 1, n do if v[i] == nil then isArray = false; break end end
    end

    local out = {}
    if isArray then
        for i = 1, n do out[i] = jsonSafe(v[i], depth + 1, seen, budget) end
    else
        for k, val in pairs(v) do
            local sv = jsonSafe(val, depth + 1, seen, budget)
            if sv ~= nil then out[tostring(k)] = sv end
        end
    end
    seen[v] = nil
    return out
end
M._jsonSafe = jsonSafe

local function encode(v)
    local ok, s = pcall(json.encode, jsonSafe(v))
    if ok then return s end
    -- Should be unreachable now, but a reply the panel can read beats a dropped socket.
    return json.encode{ ok = false, error = 'the result is not JSON-encodable: ' .. tostring(s) }
end

local function answer(id, ok, payload)
    if ok then return { id = id, ok = true, result = payload } end
    return { id = id, ok = false, error = tostring(payload) }
end
M._answer = answer

--- One request object in, one answer object out.  `obj` is whatever JSON decoded to.
-- ------------------------------------------------------- deferred dispatch --
-- `login` is the reason this exists.  It runs an HTTPS POST, every HTTP backend
-- in lib/http.lua is blocking, and the request is allowed 20 s: for that whole
-- time lib/sched.lua does not turn, so the 1 Hz status push stops, the bot tick
-- stops and the keepalive stops -- for every instance in this process.  Measured
-- against an endpoint that never answers, one login pinned the reactor for
-- 5045 ms and let exactly ONE 10 ms heartbeat fire in that window.
--
-- So a command runs on a coroutine (lib/http.lua's runAsync), and lib/http.lua's
-- post() suspends it while a short-lived child process performs the request.
-- The answer is written from a later reactor turn, which both transports here
-- already allow: lib/httpserver.lua treats a handler that returns without
-- answering as asynchronous, and a WebSocket reply is simply another frame.
-- Same measurement afterwards: 20 ms, 432 heartbeats.
--
-- Two consequences, both deliberate:
--   * answers may arrive OUT OF ORDER on /ws.  Every answer carries the request
--     id and hub/supervisor.lua matches on it -- which is the entire point: a
--     slow login must stop holding up the `status` queued behind it.
--   * only `maxDeferred` commands may be in flight at once.  Past that the
--     answer is an immediate error rather than an unbounded fan of children.
Server.maxDeferred = 16

--- One request object in, one answer object out.  `obj` is whatever JSON decoded to.
---
--- With a `done` callback the command may finish on a LATER reactor turn and
--- done(answer) is called exactly once, whenever that is.  Without one the old,
--- fully synchronous contract applies: the answer is the return value and the
--- command cannot suspend, because lib/http.lua only ever yields inside a
--- coroutine it was itself asked to create.
function Server:handleRequest(obj, done)
    self.stat.requests = self.stat.requests + 1
    local function reply(a)
        if done then done(a) end
        return a
    end
    if type(obj) ~= 'table' then
        self.stat.errors = self.stat.errors + 1
        return reply(answer(nil, false, 'a request must be a JSON object {id, cmd, args}'))
    end
    local id = obj.id
    if id ~= nil and type(id) ~= 'number' and type(id) ~= 'string' then
        self.stat.errors = self.stat.errors + 1
        return reply(answer(nil, false, 'id must be a number or a string'))
    end
    if not done then
        local ok, res = commands.dispatch(self.ctx, obj.cmd, obj.args)
        if not ok then self.stat.errors = self.stat.errors + 1 end
        return answer(id, ok, res)
    end

    self.deferred = self.deferred or 0
    if self.deferred >= (self.maxDeferred or 16) then
        self.stat.errors = self.stat.errors + 1
        return reply(answer(id, false, 'too many commands are in flight; try again'))
    end

    local S, ctx = self, self.ctx
    self.deferred = self.deferred + 1
    local settled = false
    local function settle(a)
        if settled then return end
        settled = true
        S.deferred = S.deferred - 1
        done(a)
    end
    local okRun, runErr = pcall(function()
        http.runAsync(function()
            return commands.dispatch(ctx, obj.cmd, obj.args)
        end, function(ranOk, a, b)
            if not ranOk then
                S.stat.errors = S.stat.errors + 1
                return settle(answer(id, false, 'command failed: ' .. tostring(a)))
            end
            if not a then S.stat.errors = S.stat.errors + 1 end
            settle(answer(id, a, b))
        end)
    end)
    if not okRun and not settled then
        S.stat.errors = S.stat.errors + 1
        settle(answer(id, false, 'command failed: ' .. tostring(runErr)))
    end
end

-- ------------------------------------------------------------- events -------
function Server:broadcast(event, data)
    if self.clientCount == 0 then return 0 end
    local msg = encode{ event = event, data = data }
    local n = 0
    for id, ws in pairs(self.clients) do
        if ws:isOpen() then
            local ok = ws:send(msg)
            if ok then n = n + 1 end
        else
            self.clients[id] = nil
            self.clientCount = self.clientCount - 1
        end
    end
    self.stat.events = self.stat.events + 1
    return n
end

-- ------------------------------------------------------------- wiring -------
--- Subscribe to everything the panel's event list needs.  All of it is torn down in
--- :stop(), so a worker that starts and stops the endpoint twice does not double-emit.
function Server:_wireEvents()
    local LC, S = self.LC, self
    local bus = LC.events
    self._busHandles = {}
    local function on(name, fn)
        if not bus then return end
        self._busHandles[#self._busHandles + 1] = busOn(bus, name, fn)
    end

    local function setLoginState(s, extra)
        if LC.loginState == s then return end
        LC.loginState = s
        local d = { state = s }
        if extra then for k, v in pairs(extra) do d[k] = v end end
        S:broadcast('loginState', d)
    end
    self.setLoginState = setLoginState

    on('challenge', function() setLoginState('connecting') end)
    on('pending',   function() setLoginState('pending') end)
    on('login', function(d)
        setLoginState('online', { playerId = d and d.playerId })
        S:broadcast('gameStart', { playerId = d and d.playerId })
    end)
    on('gameStart', function()
        setLoginState('online')
        S:broadcast('gameStart', {})
    end)
    on('loginError', function(d)
        setLoginState('error', { message = d and d.message })
        S:broadcast('error', { kind = 'login', message = d and d.message })
    end)
    on('loginWait', function(d)
        setLoginState('waiting', { message = d and d.message, time = d and d.time })
    end)
    on('sessionEnd', function(d)
        setLoginState('offline', { reason = d and d.reason })
        S:broadcast('gameEnd', { reason = d and d.reason })
    end)
    on('death', function(d) S:broadcast('death', d or {}) end)
    on('serverError', function(d) S:broadcast('error', { kind = 'server', message = d and d.message }) end)
    on('talk', function(d)
        S:broadcast('chat', { mode = d and d.mode, name = d and d.name,
                              level = d and d.level, text = d and d.text,
                              channelId = d and d.channelId })
    end)
    on('textMessage', function(d)
        S:broadcast('chat', { mode = d and d.mode, text = d and d.text, system = true })
    end)

    -- log lines.  The subscriber runs INSIDE log.info(), so it must never log itself
    -- and never raise; broadcast is already pcall-free but ws:send only queues.
    self._logSub = log.onLine(function(level, text, ms)
        if S._inLog then return end
        S._inLog = true
        pcall(function() S:broadcast('log', { level = level, text = text, ms = ms }) end)
        S._inLog = false
    end)
end

function Server:_unwireEvents()
    local bus = self.LC.events
    if bus and self._busHandles then
        for i = 1, #self._busHandles do pcall(busOff, bus, self._busHandles[i]) end
    end
    self._busHandles = nil
    if self._logSub then pcall(log.offLine, self._logSub); self._logSub = nil end
end

-- ------------------------------------------------------------- routes -------
function Server:_onRequest(req, res)
    local path = req.path or '/'

    if not self:authorised(req) then
        self.stat.unauthorized = self.stat.unauthorized + 1
        -- No hint about which part was wrong, and never the presented value.
        return res:send(401, encode{ ok = false, error = 'unauthorized' } .. '\n',
                        { ['Content-Type'] = 'application/json; charset=utf-8',
                          ['WWW-Authenticate'] = 'Bearer' })
    end

    if path == '/health' then
        return res:send(200, encode{ ok = true, instance = self.instanceName,
                                     uptimeMs = sys.nowMs() - self.startedMs,
                                     commands = commands.names() } .. '\n',
                        { ['Content-Type'] = 'application/json; charset=utf-8' })
    end

    if path == '/rpc' then
        if req.method ~= 'POST' then
            return res:send(405, encode{ ok = false, error = 'POST only' } .. '\n',
                            { ['Content-Type'] = 'application/json; charset=utf-8',
                              ['Allow'] = 'POST' })
        end
        local obj = nil
        local body = req.body or ''
        if #body > 0 then
            local okd, decoded = pcall(json.decode, body)
            if okd then obj = decoded end
            if not okd then
                return res:send(400, encode(answer(nil, false,
                        'body is not valid JSON: ' .. tostring(decoded))) .. '\n',
                        { ['Content-Type'] = 'application/json; charset=utf-8' })
            end
        end
        -- The answer may come from a later reactor turn (see handleRequest);
        -- lib/httpserver.lua's dispatcher explicitly allows that, and the
        -- connection's idle timeout is the backstop if the command never ends.
        self:handleRequest(obj, function(rep)
            if res.done then return end
            pcall(function()
                res:send(200, encode(rep) .. '\n',
                         { ['Content-Type'] = 'application/json; charset=utf-8' })
            end)
        end)
        return true
    end

    if path == '/ws' then
        return self._wsRoute(req, res)
    end

    return res:send(404, encode{ ok = false, error = 'no such endpoint' } .. '\n',
                    { ['Content-Type'] = 'application/json; charset=utf-8' })
end

function Server:_adoptWs(ws)
    self.clients[ws.id] = ws
    self.clientCount = self.clientCount + 1
    self.stat.wsOpened = self.stat.wsOpened + 1
    local S = self
    ws.onMessage = function(sock, msg, isBinary)
        if isBinary then
            return sock:send(encode(answer(nil, false, 'binary frames are not accepted')))
        end
        local okd, obj = pcall(json.decode, msg)
        if not okd then
            return sock:send(encode(answer(nil, false,
                    'not valid JSON: ' .. tostring(obj))))
        end
        -- Deferred: a slow command (login) answers later and does NOT hold the
        -- socket, the status pushes or anything else queued behind it.
        S:handleRequest(obj, function(rep)
            if not sock:isOpen() then return end
            pcall(function() sock:send(encode(rep)) end)
        end)
        return true
    end
    ws.onClose = function(sock)
        if S.clients[sock.id] then
            S.clients[sock.id] = nil
            S.clientCount = S.clientCount - 1
        end
    end
    -- A fresh client gets one status push immediately, so the panel is never blank
    -- for up to a second after it connects.
    pcall(function()
        ws:send(encode{ event = 'status', data = commands.statusSnapshot(S.ctx) })
    end)
end

-- ------------------------------------------------------------ lifecycle -----
function Server:start()
    if self.http then return self.boundPort end
    local S = self

    local hosts = {}
    for i = 1, #LOOPBACK_HOSTS do hosts[i] = LOOPBACK_HOSTS[i] end
    if self.allowRemote then hosts = nil end

    -- websocketRoute answers a refused handshake on the HTTP layer and otherwise
    -- returns the live ws object; there is no onOpen callback, so the connection is
    -- adopted from the return value.
    local rawRoute = httpserver.websocketRoute(wsserver, {
        -- The hub is not a browser: it sends no Origin.  Same-origin is still the rule
        -- for anything that DOES send one (i.e. a page in the operator's browser).
        allowNoOrigin = true,
        maxMessage = 8 * 1024 * 1024,        -- script.put carries whole .lua files
        maxConnections = 32,
    })
    self._wsRoute = function(req, res)
        local ws, err = rawRoute(req, res)
        if type(ws) == 'table' and type(ws.isOpen) == 'function' then S:_adoptWs(ws) end
        return ws, err
    end

    self.http = httpserver.new{
        host = self.host, port = self.port,
        sched = sched,
        allowedHosts = hosts,
        maxBodyBytes = 8 * 1024 * 1024,      -- script.put carries whole .lua files
        maxRequests = 10000,
        serverName = 'luaclient-control/' .. M.VERSION,
        onRequest = function(req, res) return S:_onRequest(req, res) end,
    }
    local port, err = self.http:start()
    if not port then
        self.http = nil
        return nil, err
    end
    self.boundPort = port

    self:_wireEvents()
    self.telemetry:attach()
    if self.LC.inGame then self.telemetry:sessionStart() end

    self._statusTimer = sched.every(self.statusIntervalMs, function()
        S.telemetry:sample()
        if S.clientCount > 0 then
            S:broadcast('status', commands.statusSnapshot(S.ctx))
        end
    end)
    self._statsTimer = sched.every(self.statsIntervalMs, function()
        if S.clientCount > 0 then S:broadcast('stats', S.telemetry:snapshot()) end
    end)

    log.info('control: listening on %s:%d (instance %s, token required)',
             self.host, port, self.instanceName)
    return port
end

function Server:stop()
    if self._statusTimer then pcall(sched.cancel, self._statusTimer); self._statusTimer = nil end
    if self._statsTimer  then pcall(sched.cancel, self._statsTimer);  self._statsTimer  = nil end
    self:_unwireEvents()
    if self.telemetry then self.telemetry:detach() end
    for id, ws in pairs(self.clients) do
        pcall(function() ws:close(1001, 'worker shutting down') end)
        self.clients[id] = nil
    end
    self.clientCount = 0
    if self.http then pcall(function() self.http:stop() end); self.http = nil end
    self.boundPort = nil
    return true
end

function Server:stats()
    return { instance = self.instanceName, port = self.boundPort,
             clients = self.clientCount, uptimeMs = sys.nowMs() - self.startedMs,
             requests = self.stat.requests, errors = self.stat.errors,
             unauthorized = self.stat.unauthorized, events = self.stat.events,
             wsOpened = self.stat.wsOpened }
end

M.Telemetry = Telemetry
return M
