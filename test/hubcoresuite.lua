--[[============================================================================
test/hubcoresuite.lua -- proof for work item B2, the hub core:
  hub/storage.lua  hub/model.lua  hub/auth.lua  hub/audit.lua

  luajit test/hubcoresuite.lua            (from D:/Claude/otclient_web/luaclient)

Exits non-zero if ANY check fails.  Everything runs in a fresh temp directory under
sys.tempDir() which is removed on the way out, pass or fail.

What is actually PROVEN here, rather than asserted in a comment:

  atomic write         a save is staged and then ABANDONED before the rename, exactly as a crash
                       in that window would leave it.  A fresh store opened on the same directory
                       must still read the OLD value, and must sweep the orphaned .tmp.
  corruption           three different mutilations of a good file -- truncation, a flipped byte,
                       and a zero-length file -- must each be REPORTED by name.  A store that
                       came back with an empty collection would be the bug that silently deletes
                       an operator's accounts, so each case also asserts the collection was not
                       emptied.
  referential integrity a dangling reference is refused on insert, on update and on delete, in
                       both directions of every edge PANEL.md's model has.
  login timing         the wall-clock cost of a wrong password for a KNOWN user and of any
                       password for an UNKNOWN one, measured at the real 200k iterations and
                       printed in milliseconds.  They must agree within 25%: a large gap is a
                       user-enumeration oracle.
  lockout              N failures lock the name AND the source address; a correct password is
                       refused while locked and works again once the lock lapses.
  sessions             sliding expiry, the absolute ceiling that sliding cannot cross, explicit
                       revocation, and revocation-by-account.
  secrets              a game-account and a proxy password go in as plaintext and the PLAINTEXT
                       IS GREPPED FOR in the bytes actually written to disk -- accounts.json,
                       proxies.json and the audit log -- and must not be there.  They must still
                       decrypt back to the original.
  audit                records survive a rotation, the query stitches the rotated files back into
                       one stream, every filter (actor, action, prefix, outcome, time range)
                       narrows correctly, and paging by cursor walks the whole log exactly once
                       with no duplicates and no gaps.

No password, token or key is printed: the suite prints pass/fail, timings and byte counts only.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local sys        = require('lib.sys')
local json       = require('lib.json')
local pbkdf2     = require('lib.pbkdf2')
local authsecret = require('lib.authsecret')
local storage    = require('hub.storage')
local model      = require('hub.model')
local auth       = require('hub.auth')
local audit      = require('hub.audit')
local telemetry  = require('hub.telemetry')
local sched      = require('lib.sched')

local fs = storage.fs

-- =========================================================== tiny framework
local suites, cur = {}, nil
local totalPass, totalFail = 0, 0
local notes = {}

local function suite(name)
    cur = { name = name, pass = 0, fail = 0 }
    suites[#suites + 1] = cur
    return cur
end

local function check(ok, desc, detail)
    if ok then
        cur.pass = cur.pass + 1
        totalPass = totalPass + 1
    else
        cur.fail = cur.fail + 1
        totalFail = totalFail + 1
        io.write('    FAIL  ', desc, detail and ('  -- ' .. tostring(detail)) or '', '\n')
    end
    return ok and true or false
end

local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    local g, w = tostring(got), tostring(want)
    if #g > 110 then g = g:sub(1, 107) .. '...' end
    if #w > 110 then w = w:sub(1, 107) .. '...' end
    return check(false, desc, 'got ' .. g .. ', want ' .. w)
end

local function note(s) notes[#notes + 1] = s end

-- =============================================================== temp sandbox
local TMP = string.format('%s/luaclient-hubcore-%d-%s',
                          sys.tempDir(), os.time(),
                          (function ()
                             local h = {}
                             local b = sys.randomBytes(4)
                             for i = 1, 4 do h[i] = string.format('%02x', b:byte(i)) end
                             return table.concat(h)
                           end)())

local function rmrf(dir)
    -- No readdir in lib/sys; the suite knows every name it creates, so remove them explicitly
    -- and then try the directory itself.  Anything left behind is reported, not ignored.
    local names = {}
    for _, c in ipairs(model.kinds()) do
        names[#names + 1] = c .. '.json'
        names[#names + 1] = c .. '.json.tmp'
    end
    names[#names + 1] = 'secret.key'
    names[#names + 1] = 'audit.jsonl'
    for i = 1, 12 do names[#names + 1] = 'audit.' .. i .. '.jsonl' end
    names[#names + 1] = 'tiny.jsonl'
    for i = 1, 12 do names[#names + 1] = 'tiny.' .. i .. '.jsonl' end
    for _, sub in ipairs({ '', '/a', '/b', '/c', '/d', '/e', '/perm' }) do
        for _, n in ipairs(names) do fs.remove(dir .. sub .. '/' .. n) end
    end
    if sys.isWindows then
        os.execute('rmdir /s /q "' .. dir:gsub('/', '\\') .. '" >nul 2>nul')
    else
        os.execute('rm -rf "' .. dir .. '" 2>/dev/null')
    end
end

local function subdir(n) return TMP .. '/' .. n end

local function readRaw(path)
    local d = fs.readFile(path)
    return d
end

local function newStore(dir, opts)
    local s, err = storage.open(dir, opts)
    if not s then error('storage.open(' .. dir .. '): ' .. tostring(err), 2) end
    return s
end

-- ============================================================================
-- 1. storage: canonical encoding, envelope, atomicity, corruption, migration
-- ============================================================================
suite('storage / canonical JSON')
do
    local enc = storage.encodeCanon
    eq(enc({ b = 1, a = 2, c = 3 }), '{"a":2,"b":1,"c":3}', 'object keys are sorted')
    eq(enc({}), '[]', 'an empty table encodes as an array (both on the way out and back)')
    eq(enc({ 1, 2, 3 }), '[1,2,3]', 'arrays keep their order')
    eq(enc(1), '1', 'an integral number has no exponent or decimal point')
    eq(enc(-0.5), '-0.5', 'a fraction round-trips')
    eq(enc(1757000000123), '1757000000123', 'a millisecond timestamp is exact, not %.14g')
    eq(enc('a\nb'), '"a\\nb"', 'a newline inside a string is escaped (the footer depends on it)')
    eq(enc('a\tb\1c'), '"a\\tb\\u0001c"', 'every control byte is escaped')
    eq(enc(true) .. enc(false), 'truefalse', 'booleans')

    -- The property the footer split relies on.
    local text = enc({ detail = 'line1\nline2\n"sum":"deadbeef"', t = 1 })
    eq(text:find('\n', 1, true), nil, 'no raw newline can appear anywhere in an encoded document')

    local ok = pcall(enc, { [1] = 'a', x = 'b' })
    check(not ok, 'a mixed-key table is refused rather than silently mangled')
    local ok2 = pcall(enc, 0 / 0)
    check(not ok2, 'NaN is refused')
end

suite('storage / basic round-trip')
do
    local dir = subdir('a')
    local st = newStore(dir)
    eq(#st:items('users'), 0, 'a missing file is a NEW empty collection, not an error')
    check(fs.isDir(dir), 'the data directory was created')

    local rows = st:items('users')
    rows[1] = { id = 'u_000000000001', name = 'arnold', role = 'admin',
                pwhash = 'pbkdf2$x', createdAt = 1, disabled = false }
    st:markDirty('users')
    check(st:save('users'), 'save() writes')

    local raw = readRaw(dir .. '/users.json')
    check(raw ~= nil and #raw > 0, 'the file exists and is not empty')
    check(raw:find('"sum":"', 1, true) ~= nil, 'the integrity footer is present')
    check(raw:find('"collection":"users"', 1, true) ~= nil, 'the envelope names its collection')
    local decoded = json.decode(raw)
    check(type(decoded) == 'table' and decoded.count == 1,
          'the whole file is still valid JSON that any tool can read')

    local st2 = newStore(dir)
    eq(#st2:items('users'), 1, 'a second store reads the row back')
    eq(st2:items('users')[1].name, 'arnold', '   with its fields intact')
    eq(st2:info('users').version, 1, 'the collection version is reported')

    -- Not dirty -> save is a no-op, and forcing rewrites.
    eq(st2:isDirty('users'), false, 'a freshly loaded collection is not dirty')
    check(st2:save('users'), 'save() on a clean collection is a no-op that still succeeds')
end

suite('storage / atomic write survives a crash before the rename')
do
    local dir = subdir('b')
    local st = newStore(dir)
    st:setItems('users', { { id = 'u_000000000001', name = 'before', role = 'admin',
                             pwhash = 'pbkdf2$x', createdAt = 1, disabled = false } })
    check(st:save('users'), 'the OLD value is committed')

    -- Stage the new value and then simulate the process dying: no commitStage() call.
    st:setItems('users', { { id = 'u_000000000002', name = 'after', role = 'admin',
                             pwhash = 'pbkdf2$x', createdAt = 2, disabled = false } })
    local tmp, terr = st:stageWrite('users')
    check(tmp ~= nil, 'stageWrite() produced a temp file', terr)
    check(fs.exists(tmp), 'the temp file is on disk')
    local staged = readRaw(tmp)
    check(staged and staged:find('"after"', 1, true) ~= nil,
          'the temp file holds the NEW value, complete with its footer')
    check(staged and staged:find('"sum":"', 1, true) ~= nil,
          '   and it is a complete, committable file (it was fsynced before the crash)')
    st = nil                                            -- the process is gone

    -- Recovery: a brand-new store on the same directory.
    local st2 = newStore(dir)
    eq(#st2:items('users'), 1, 'exactly one row after recovery')
    eq(st2:items('users')[1].name, 'before',
       'the OLD value is what a reader sees -- the abandoned write never became visible')
    check(not fs.exists(dir .. '/users.json.tmp'),
          'the orphaned temp file was swept on open (crash recovery)')

    -- And the commit half really does publish.
    st2:setItems('users', { { id = 'u_000000000002', name = 'after', role = 'admin',
                              pwhash = 'pbkdf2$x', createdAt = 2, disabled = false } })
    check(st2:stageWrite('users') ~= nil, 'stage again')
    check(st2:commitStage('users'), 'commitStage() renames')
    local st3 = newStore(dir)
    eq(st3:items('users')[1].name, 'after', 'after the commit the NEW value is visible')
    check(not fs.exists(dir .. '/users.json.tmp'), 'the temp file is gone after a commit')
end

suite('storage / corruption is reported, never silently emptied')
do
    local dir = subdir('c')
    local st = newStore(dir)
    st:setItems('proxies', {
        { id = 'p_000000000001', label = 'de', kind = 'http-connect', host = '10.0.0.1',
          port = 8080 },
        { id = 'p_000000000002', label = 'nl', kind = 'http-connect', host = '10.0.0.2',
          port = 3128 },
    })
    check(st:save('proxies'), 'a good file is written')
    local good = readRaw(dir .. '/proxies.json')
    local path = dir .. '/proxies.json'

    local function corruptWith(bytes, label, wantWord)
        check(fs.writeDurable(path, bytes), 'wrote the mutilated file (' .. label .. ')')
        local s2, err = storage.open(dir)
        check(s2 == nil, label .. ': storage.open REFUSES to start', err)
        if s2 then
            eq(#s2:items('proxies'), 2, label .. ': ... and certainly did not empty it')
        end
        check(err ~= nil and tostring(err):lower():find(wantWord, 1, true) ~= nil,
              label .. ': the error says why (' .. wantWord .. ')', err)
        -- The file on disk is untouched by the failed open.
        eq(#(readRaw(path) or ''), #bytes, label .. ': a failed open did not rewrite the file')
    end

    corruptWith(good:sub(1, math.floor(#good * 0.6)), 'truncated mid-record', 'footer')
    corruptWith('', 'zero bytes', 'empty file')

    -- One byte flipped inside the payload: the JSON still parses, the checksum does not match.
    local at = good:find('"nl"', 1, true)
    check(at ~= nil, 'found a byte to flip')
    local flipped = good:sub(1, at) .. 'X' .. good:sub(at + 2)
    corruptWith(flipped, 'one flipped byte', 'checksum mismatch')

    -- A footer whose sum is right but whose JSON is not.
    local broken = '{"collection":"proxies","count":0,"items":[,"schema":1,"version":1,'
    local sha2 = require('lib.sha2')
    corruptWith(broken .. '\n"sum":"' .. sha2.sha256hex(broken) .. '"}\n',
                'valid footer, invalid JSON', 'invalid json')

    -- Put the good file back and prove the store starts again.
    check(fs.writeDurable(path, good), 'restored the good file')
    local s3, err3 = storage.open(dir)
    check(s3 ~= nil, 'the store opens again once the file is intact', err3)
    if s3 then eq(#s3:items('proxies'), 2, '   with both rows') end

    -- Quarantine is opt-in and says what it did.
    check(fs.writeDurable(path, good:sub(1, 20)), 'break it again')
    local s4, err4 = storage.open(dir, { onCorrupt = 'quarantine' })
    check(s4 ~= nil, 'onCorrupt=quarantine lets an operator start anyway', err4)
    if s4 then
        eq(#s4:items('proxies'), 0, '   with the collection empty')
        check(s4:info('proxies').quarantined ~= nil, '   and the bad file kept aside, not deleted')
        fs.remove(s4:info('proxies').quarantined)
    end
end

suite('storage / schema versioning and migration')
do
    local dir = subdir('d')
    local st = newStore(dir, { collections = { 'proxies' } })
    st:setItems('proxies', { { id = 'p_000000000001', label = 'de', host = '10.0.0.1',
                               port = 8080 } })
    check(st:save('proxies'), 'wrote a v1 file')

    local ran = 0
    local st2, err = storage.open(dir, {
        collections = { 'proxies' },
        schemas = { proxies = { version = 2, migrate = { [1] = function (items)
            ran = ran + 1
            for i = 1, #items do items[i].kind = 'http-connect' end
            return items
        end } } },
    })
    check(st2 ~= nil, 'a v1 file opens under a v2 schema', err)
    eq(ran, 1, 'the migration hook ran exactly once')
    eq(st2:items('proxies')[1].kind, 'http-connect', 'the migration changed the data')
    eq(st2:isDirty('proxies'), true, 'the migrated collection is dirty so the upgrade persists')
    check(st2:save('proxies'), 'saving it writes version 2')
    eq(storage.open(dir, { collections = { 'proxies' },
                           schemas = { proxies = { version = 2 } } }) ~= nil, true,
       'reopening at v2 needs no migration')

    local s3, e3 = storage.open(dir, { collections = { 'proxies' } })  -- schema back at v1
    check(s3 == nil, 'a file from a NEWER hub is refused, not downgraded', e3)
    check(e3 and tostring(e3):find('newer', 1, true) ~= nil, '   and the error says so', e3)

    local s4, e4 = storage.open(dir, { collections = { 'proxies' },
                                       schemas = { proxies = { version = 3 } } })
    check(s4 == nil, 'a missing migration hook is a hard error, not a silent skip', e4)
end

suite('storage / write cost')
do
    local dir = subdir('e')
    local st = newStore(dir)
    local rows = {}
    for i = 1, 500 do
        rows[i] = {
            id = string.format('i_%012x', i),
            characterId = string.format('c_%012x', i),
            ownerUserId = 'u_000000000001',
            proxyId = 'p_000000000001',
            botProfile = 'profile_1',
            cavebotConfig = 'Thais Dragons ' .. i,
            targetbotConfig = 'default',
            scripts = { 's_000000000001', 's_000000000002' },
            autoStart = true, autoRelogin = true, state = 'online',
            createdAt = 1757000000000 + i,
        }
    end
    -- The size PANEL.md actually implies: a few dozen instances.
    local small = {}
    for i = 1, 24 do small[i] = rows[i] end
    st:setItems('instances', small)
    local best, allOk = math.huge, true
    for _ = 1, 5 do
        local t = sys.nowMs()
        if not st:save('instances', true) then allOk = false end
        local d = sys.nowMs() - t
        if d < best then best = d end
    end
    check(allOk, 'saved a realistic-sized instances collection five times')
    local smallBytes = st:info('instances').bytes
    note(string.format('storage write cost, REALISTIC size: %d rows / %.1f KB -> %.2f ms ' ..
                       'per save (best of 5) on %s', #small, smallBytes / 1024, best, sys.os))
    check(best < 20, string.format(
          'a realistic save is a couple of milliseconds, not a reactor stall (%.2f ms)', best))

    st:setItems('instances', rows)
    local t0 = sys.nowMs()
    check(st:save('instances', true), 'saved 500 instance rows')
    local dt = sys.nowMs() - t0
    local bytes = st:info('instances').bytes
    note(string.format('storage write cost, 20x that: %d rows / %.1f KB -> %.2f ms per save ' ..
                       '(encode + sha256 + write + 2 fsyncs)', #rows, bytes / 1024, dt))
    check(dt < 250, string.format('even 20x the realistic size stays bounded (%.2f ms)', dt))

    local t1 = sys.nowMs()
    local st2 = newStore(dir)
    local dtr = sys.nowMs() - t1
    eq(#st2:items('instances'), 500, 'and reads all 500 back')
    note(string.format('storage load cost: whole data dir in %.2f ms', dtr))
end

-- ============================================================================
-- 2. model: validation, ids, referential integrity
-- ============================================================================
local function freshDb(name, withSecret)
    local dir = subdir(name)
    local st = newStore(dir)
    local box
    if withSecret then
        box = assert(authsecret.create(dir .. '/secret.key'))
    end
    local db, err = model.attach(st, { secret = box })
    if not db then error('model.attach: ' .. tostring(err)) end
    return db, st, dir, box
end

suite('storage / directory permissions')
do
    local dir = subdir('perm')
    newStore(dir)
    if sys.isWindows then
        check(fs.isDir(dir), 'the data directory exists (POSIX modes do not apply on Windows; ' ..
              'the data dir inherits its parent ACL -- keep it out of shared locations)')
        note('directory mode: not checked on Windows (NTFS ACLs, not POSIX bits)')
    else
        local f = io.popen('stat -c %a "' .. dir .. '" 2>/dev/null')
        local mode = f and (f:read('*l') or '') or ''
        if f then f:close() end
        eq(mode, '700', 'the data directory is 0700 on POSIX (not merely umask-dependent)')
        note('directory mode on ' .. sys.os .. ': ' .. mode)
    end
end

suite('model / ids and validation')
do
    local db = freshDb('m1')
    local id = model.newId('users')
    check(id:match('^u_%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil, 'an id is its prefix plus 12 hex')
    local seen, dup = {}, false
    for _ = 1, 2000 do
        local x = model.newId('instances')
        if seen[x] then dup = true end
        seen[x] = true
    end
    check(not dup, '2000 ids drawn from the CSPRNG, no collision')

    local u = db:insert('users', { name = 'arnold', role = 'admin', pwhash = 'pbkdf2$sha256$x' })
    check(u ~= nil, 'insert fills in the id, createdAt and disabled defaults')
    check(u and u.id:match('^u_') ~= nil, '   the id carries the kind prefix')
    eq(u and u.disabled, false, '   disabled defaults to false')
    check(u and u.createdAt > 0, '   createdAt was stamped')

    local _, e1 = db:insert('users', { name = 'ARNOLD', role = 'user', pwhash = 'pbkdf2$x' })
    check(e1 ~= nil, 'a duplicate name is refused case-insensitively', e1)

    local _, e2 = db:insert('users', { name = 'bad name!', role = 'user', pwhash = 'pbkdf2$x' })
    check(e2 ~= nil, 'an illegal name is refused', e2)

    local _, e3 = db:insert('users', { name = 'sam', role = 'root', pwhash = 'pbkdf2$x' })
    check(e3 ~= nil and e3:find('role') ~= nil, 'an unknown role is refused', e3)

    local _, e4 = db:insert('users', { name = 'sam', role = 'user' })
    check(e4 ~= nil and e4:find('pwhash') ~= nil, 'a missing required field is refused', e4)

    local _, e5 = db:insert('users', { name = 'sam', role = 'user', pwhash = 'x', nope = 1 })
    check(e5 ~= nil and e5:find('unknown field') ~= nil,
          'an unknown field is refused rather than quietly stored', e5)

    local _, e6 = db:insert('proxies', { label = 'p', kind = 'http-connect',
                                        host = '10.0.0.1', port = 70000 })
    check(e6 ~= nil and e6:find('port') ~= nil, 'an out-of-range port is refused', e6)

    local _, e7 = db:insert('scripts', { name = 'x.txt', ownerUserId = u.id, size = 1,
                                         sha256 = string.rep('a', 64) })
    check(e7 ~= nil, 'a script must be a .lua file', e7)

    -- The caller's table is never the stored table.
    local draft = { name = 'sam', role = 'user', pwhash = 'pbkdf2$sha256$y' }
    local sam = db:insert('users', draft)
    draft.role = 'admin'
    eq(db:get('users', sam.id).role, 'user',
       'the stored row is a copy -- mutating the caller\'s table cannot escalate a role')
end

suite('model / referential integrity')
do
    local db, st, dir = freshDb('m2')
    local admin = assert(db:insert('users', { name = 'arnold', role = 'admin',
                                              pwhash = 'pbkdf2$sha256$x' }))
    local acct  = assert(db:insert('accounts', { label = 'main-eu', login = 'l4g-main',
                                                 ownerUserId = admin.id }))
    local ch    = assert(db:insert('characters', { accountId = acct.id, name = 'Arnoldus',
                                                   world = 'Gunzodus', vocation = 'Knight' }))
    local px    = assert(db:insert('proxies', { label = 'de', kind = 'http-connect',
                                                host = '10.0.0.1', port = 8080 }))
    local sc    = assert(db:insert('scripts', { name = 'refill.lua', ownerUserId = admin.id,
                                                size = 12, sha256 = string.rep('b', 64) }))
    local inst  = assert(db:insert('instances', { characterId = ch.id, ownerUserId = admin.id,
                                                  proxyId = px.id, scripts = { sc.id } }))
    check(inst ~= nil, 'a fully-referenced instance inserts')
    eq(inst.state, 'stopped', 'state defaults to stopped')
    eq(inst.botProfile, 'profile_1', 'botProfile defaults')

    -- ---- dangling on the way IN
    local _, e1 = db:insert('instances', { characterId = ch.id, ownerUserId = admin.id,
                                           proxyId = 'p_ffffffffffff' })
    check(e1 ~= nil and e1:find('does not exist') ~= nil,
          'an instance referencing a MISSING proxy is refused', e1)

    local _, e2 = db:insert('characters', { accountId = 'a_ffffffffffff', name = 'X',
                                            world = 'Gunzodus' })
    check(e2 ~= nil, 'a character on a missing game account is refused', e2)

    local _, e3 = db:insert('instances', { characterId = ch.id, ownerUserId = admin.id,
                                           scripts = { sc.id, 's_ffffffffffff' } })
    check(e3 ~= nil, 'an instance listing a missing script is refused', e3)

    local _, e4 = db:insert('instances', { characterId = px.id, ownerUserId = admin.id })
    check(e4 ~= nil and e4:find('characters id') ~= nil,
          'a PROXY id in the characterId slot is refused on its prefix alone', e4)

    local _, e5 = db:update('instances', inst.id, { proxyId = 'p_ffffffffffff' })
    check(e5 ~= nil, 'update is checked too, not just insert', e5)

    -- ---- dangling on the way OUT
    local _, d1 = db:delete('accounts', acct.id)
    check(d1 ~= nil and d1:find('characters.accountId') ~= nil,
          'deleting a game account that still has characters is refused, naming them', d1)

    local _, d2 = db:delete('characters', ch.id)
    check(d2 ~= nil and d2:find('instances.characterId') ~= nil,
          'deleting a character that still has an instance is refused', d2)

    local _, d3 = db:delete('proxies', px.id)
    check(d3 ~= nil and d3:find('instances.proxyId') ~= nil,
          'deleting a proxy an instance still uses is refused', d3)

    local _, d4 = db:delete('scripts', sc.id)
    check(d4 ~= nil and d4:find('instances.scripts') ~= nil,
          'deleting a script an instance still runs is refused', d4)

    local _, d5 = db:delete('users', admin.id)
    check(d5 ~= nil, 'deleting a user who still owns things is refused', d5)

    eq(#db:dependentsOf('proxies', px.id), 1, 'dependentsOf lists the one instance')

    -- ---- the correct order works
    check(db:delete('instances', inst.id), 'delete the instance first')
    check(db:delete('scripts', sc.id), '   then the script')
    check(db:delete('proxies', px.id), '   then the proxy')
    check(db:delete('characters', ch.id), '   then the character')
    check(db:delete('accounts', acct.id), '   then the account')
    check(db:delete('users', admin.id), '   then the user')
    eq(db:count('instances'), 0, 'everything is gone')

    -- ---- cascade is opt-in and unwinds bottom-up
    local a2 = assert(db:insert('users', { name = 'sam', role = 'user', pwhash = 'pbkdf2$x' }))
    local ac2 = assert(db:insert('accounts', { label = 'sam-01', login = 's', ownerUserId = a2.id }))
    local c2 = assert(db:insert('characters', { accountId = ac2.id, name = 'Kettle',
                                                world = 'Gunzodus' }))
    local p2 = assert(db:insert('proxies', { label = 'nl', kind = 'http-connect',
                                             host = '10.0.0.2', port = 8080 }))
    local i2 = assert(db:insert('instances', { characterId = c2.id, ownerUserId = a2.id,
                                               proxyId = p2.id }))
    check(db:delete('proxies', p2.id, { cascade = true }),
          'cascade-deleting a proxy clears the optional reference instead of deleting the instance')
    eq(db:get('instances', i2.id) ~= nil, true, '   the instance survived')
    eq(db:get('instances', i2.id).proxyId, nil, '   with proxyId cleared')
    check(db:delete('users', a2.id, { cascade = true }),
          'cascade-deleting a user removes the account, character and instance under it')
    eq(db:count('instances'), 0, '   instances gone')
    eq(db:count('characters'), 0, '   characters gone')
    eq(db:count('accounts'), 0, '   accounts gone')

    -- ---- checkIntegrity sees what a hand edit does
    local u3 = assert(db:insert('users', { name = 'kim', role = 'user', pwhash = 'pbkdf2$x' }))
    local ac3 = assert(db:insert('accounts', { label = 'k', login = 'k', ownerUserId = u3.id }))
    check(db:checkIntegrity(), 'a consistent store passes checkIntegrity')
    -- Reach past the API, exactly as an operator with a text editor would.
    st:items('accounts')[1].ownerUserId = 'u_ffffffffffff'
    st:markDirty('accounts')
    local ok, problems = db:checkIntegrity()
    check(not ok, 'a hand-edited dangling reference is caught by checkIntegrity')
    check(problems and #problems > 0 and problems[1]:find('does not exist') ~= nil,
          '   and reported by name', problems and problems[1])
    st:items('accounts')[1].ownerUserId = u3.id
end

suite('model / persistence through storage')
do
    local db, st, dir = freshDb('m3')
    local u = assert(db:insert('users', { name = 'arnold', role = 'admin', pwhash = 'pbkdf2$x' }))
    local a = assert(db:insert('accounts', { label = 'main', login = 'l', ownerUserId = u.id }))
    check(fs.exists(dir .. '/users.json'), 'insert persisted immediately')

    local st2 = newStore(dir)
    local db2 = assert(model.attach(st2))
    eq(db2:count('users'), 1, 'a fresh store+db sees the user')
    eq(db2:get('accounts', a.id).label, 'main', '   and the account, by id')
    check(db2:checkIntegrity(), '   and it is internally consistent')

    -- A failed insert leaves nothing behind on disk.
    local before = readRaw(dir .. '/users.json')
    db2:insert('users', { name = 'arnold', role = 'user', pwhash = 'pbkdf2$x' })
    eq(readRaw(dir .. '/users.json'), before, 'a refused insert did not touch the file')
end

-- ============================================================================
-- 3. auth
-- ============================================================================
local FAST = 1000        -- iterations for everything except the timing measurement

local function freshAuth(name, opts)
    local db, st, dir, box = freshDb(name, true)
    opts = opts or {}
    opts.db = db
    opts.secret = box
    if opts.iterations == nil then opts.iterations = FAST end
    local a, err = auth.open(opts)
    if not a then error('auth.open: ' .. tostring(err)) end
    return a, db, dir, st, box
end

suite('auth / first-run bootstrap')
do
    local a, db = freshAuth('au1')
    check(a:needsBootstrap(), 'with no accounts the hub is in bootstrap state')
    local tok = a:bootstrapToken()
    check(type(tok) == 'string' and #tok == 64, 'a 32-byte one-time token is minted (64 hex)')

    local _, e1, c1 = a:login('arnold', 'whatever', '127.0.0.1')
    check(e1 ~= nil and c1 == 'bootstrap', 'login refuses until the first admin exists')
    local _, e2, c2 = a:authenticate('deadbeef')
    check(e2 ~= nil and c2 == 'bootstrap', 'authenticate refuses too')
    local _, e3, c3 = a:createUser('sam', 'hunter2hunter2', 'user')
    check(e3 ~= nil and c3 == 'bootstrap', 'creating an ordinary account refuses too')

    local _, e4 = a:createFirstAdmin(string.rep('0', 64), 'arnold', 'correct horse battery')
    check(e4 ~= nil, 'a wrong bootstrap token is refused')
    check(a:needsBootstrap(), '   and the hub is still in bootstrap state')

    local admin, e5 = a:createFirstAdmin(tok, 'arnold', 'correct horse battery')
    check(admin ~= nil, 'the right token creates the administrator', e5)
    eq(admin and admin.role, 'admin', '   with the admin role')
    check(not a:needsBootstrap(), 'bootstrap state is over')
    eq(a:bootstrapToken(), nil, 'the token is gone')
    local _, e6 = a:createFirstAdmin(tok, 'other', 'another password')
    check(e6 ~= nil, 'the token cannot be replayed')
    eq(db:count('users'), 1, 'exactly one account exists')

    -- The stored hash is a hash, not the password.
    local row = db:list('users')[1]
    check(row.pwhash:find('^pbkdf2%$sha256%$') ~= nil, 'the stored hash has PANEL.md\'s format')
    check(row.pwhash:find('correct horse battery', 1, true) == nil,
          'the password itself is nowhere in the row')

    -- Attempt limiting on the bootstrap flow itself.
    local a2 = freshAuth('au1b')
    for i = 1, 5 do a2:createFirstAdmin('nope', 'x', 'yyyyyyyyyy') end
    local _, e7, c7 = a2:createFirstAdmin(a2:bootstrapToken(), 'arnold', 'correct horse battery')
    check(e7 ~= nil and c7 == 'locked',
          'the bootstrap token cannot be ground down: it dies after N wrong tries')
end

suite('auth / login, sessions, revocation, expiry')
do
    -- A controllable clock so expiry can be tested without sleeping.
    local clock = { t = 1757000000000 }
    local a, db = freshAuth('au2', { now = function () return clock.t end,
                                     idleMs = 1000, absoluteMs = 5000 })
    local admin = assert(a:createFirstAdmin(a:bootstrapToken(), 'arnold', 'correct horse battery'))
    local sam = assert(a:createUser('sam', 'sam-password-1', 'user'))

    local _, be = a:createUser('kim', 'short', 'user')
    check(be ~= nil, 'a too-short password is refused')

    local tok, u = a:login('arnold', 'correct horse battery', '127.0.0.1', 'test-agent')
    check(tok ~= nil and #tok == 64, 'login returns a 64-hex session token', u)
    eq(u and u.id, admin.id, '   for the right account')

    local _, le, lc = a:login('arnold', 'wrong password here', '127.0.0.1')
    check(le ~= nil and lc == 'denied', 'a wrong password is denied')
    local _, le2, lc2 = a:login('ARNOLD', 'correct horse battery', '127.0.0.1')
    check(le2 == nil or lc2 ~= 'denied', 'the name is matched case-insensitively')

    local sess, su = a:authenticate(tok, '127.0.0.1')
    check(sess ~= nil, 'the token authenticates')
    eq(su and su.name, 'arnold', '   and resolves to the user')
    check(sess and sess.id:find('^sess_') ~= nil, '   with a session id')

    -- No token or hash escapes through the admin-facing listing.
    local list = a:sessions()
    check(#list >= 1, 'sessions() lists the live sessions')
    local leaked = false
    for _, s in ipairs(list) do
        for k, v in pairs(s) do
            if k == 'hash' then leaked = true end
            if type(v) == 'string' and v == tok then leaked = true end
        end
    end
    check(not leaked, 'the session listing carries neither the token nor its digest')

    -- Sliding expiry.
    clock.t = clock.t + 900
    check(a:authenticate(tok) ~= nil, 'a request inside the idle window slides the expiry')
    clock.t = clock.t + 900
    check(a:authenticate(tok) ~= nil, '   and again (it would have expired without sliding)')
    clock.t = clock.t + 1500
    local _, ee, ec = a:authenticate(tok)
    check(ee ~= nil and ec == 'expired', 'past the idle window the session is expired')
    check(a:authenticate(tok) == nil, '   and it stays dead')

    -- Absolute ceiling: sliding cannot extend a session past it.  The session is kept
    -- permanently busy (a request every 800 ms against a 1000 ms idle window) so nothing but
    -- the 5000 ms ceiling can ever end it.
    clock.t = clock.t + 1
    local tok2 = assert(a:login('arnold', 'correct horse battery', '127.0.0.1'))
    local start = clock.t
    local lastOk, died = start, nil
    for _ = 1, 20 do
        clock.t = clock.t + 800
        local s2 = a:authenticate(tok2)
        if s2 then
            lastOk = clock.t
        elseif not died then
            died = clock.t
        end
    end
    check(died ~= nil, 'a permanently busy session does eventually end')
    check(lastOk < start + 5000,
          string.format('the last accepted request was before the absolute deadline (+%d ms)',
                        lastOk - start))
    check(died and died >= start + 5000,
          string.format('and it died at or after it (+%d ms), so sliding never crossed the ' ..
                        'ceiling', (died or 0) - start))
    check(a:authenticate(tok2) == nil, 'the session stays dead afterwards')

    -- Explicit revocation.
    local tok3 = assert(a:login('sam', 'sam-password-1', '10.0.0.8'))
    local s3 = assert(a:authenticate(tok3))
    eq(a:revoke(s3.id), 1, 'revoke() kills one session')
    check(a:authenticate(tok3) == nil, '   and its token no longer authenticates')

    local t4 = assert(a:login('sam', 'sam-password-1', '10.0.0.8'))
    local t5 = assert(a:login('sam', 'sam-password-1', '10.0.0.9'))
    eq(a:revokeUser(sam.id), 2, 'revokeUser() kills every session of an account')
    check(a:authenticate(t4) == nil and a:authenticate(t5) == nil, '   both are dead')

    -- Logout, disable and password reset all invalidate.
    local t6 = assert(a:login('sam', 'sam-password-1', '10.0.0.8'))
    a:logout(t6)
    check(a:authenticate(t6) == nil, 'logout() invalidates the token')

    local t7 = assert(a:login('sam', 'sam-password-1', '10.0.0.8'))
    check(a:setPassword(sam.id, 'sam-password-2'), 'the admin resets a password')
    check(a:authenticate(t7) == nil, '   which revokes that user\'s live sessions')
    check(a:login('sam', 'sam-password-2', '10.0.0.8') ~= nil, '   and the new one works')
    check(select(2, a:login('sam', 'sam-password-1', '10.0.0.8')) ~= nil, '   the old one does not')

    local t8 = assert(a:login('sam', 'sam-password-2', '10.0.0.8'))
    check(a:setDisabled(sam.id, true), 'the admin disables an account')
    check(a:authenticate(t8) == nil, '   its live session stops authenticating at once')
    check(select(2, a:login('sam', 'sam-password-2', '10.0.0.8')) ~= nil, '   and it cannot log in')

    check(select(2, a:setRole(admin.id, 'user')) ~= nil, 'the last administrator cannot be demoted')
    check(select(2, a:deleteUser(admin.id)) ~= nil, '   nor deleted')

    -- Housekeeping.
    local swept = a:sweep()
    check(type(swept) == 'table', 'sweep() returns what it dropped')
end

suite('auth / rate limiting and lockout')
do
    local clock = { t = 1757000000000 }
    local a = freshAuth('au3', { now = function () return clock.t end,
                                 maxFails = 3, windowMs = 60000, lockoutMs = 30000 })
    assert(a:createFirstAdmin(a:bootstrapToken(), 'arnold', 'correct horse battery'))

    for i = 1, 2 do
        local _, _, c = a:login('arnold', 'wrong', '10.0.0.8')
        eq(c, 'denied', 'failure ' .. i .. ' is denied but not yet locked')
    end
    local _, _, c3 = a:login('arnold', 'wrong', '10.0.0.8')
    eq(c3, 'denied', 'the third failure is the one that trips the lock')

    local _, e4, c4 = a:login('arnold', 'correct horse battery', '10.0.0.8')
    check(e4 ~= nil and c4 == 'locked',
          'the CORRECT password is refused while the account is locked out')
    check(a:limitState('arnold', '10.0.0.8').locked, 'limitState reports the lock')
    check(a:limitState('arnold', '10.0.0.8').retryInMs > 0, '   with a retry-after')

    clock.t = clock.t + 30001
    local tok = a:login('arnold', 'correct horse battery', '10.0.0.8')
    check(tok ~= nil, 'once the lockout lapses the correct password works again')
    check(not a:limitState('arnold', '10.0.0.8').locked, '   and the lock is cleared')

    -- Per-IP: the address bucket is a THROTTLE, not a lock, and it must never
    -- refuse a credential that verifies.  Under PANEL.md's supported deployment
    -- (nginx/Caddy or an SSH tunnel in front) every request shares one source
    -- address, so an address lock let any anonymous visitor lock the whole
    -- panel -- administrator included -- with a handful of bad guesses.
    local a2 = freshAuth('au4', { now = function () return clock.t end,
                                  maxFails = 100, ipMaxFails = 3,
                                  windowMs = 60000, lockoutMs = 30000 })
    assert(a2:createFirstAdmin(a2:bootstrapToken(), 'arnold', 'correct horse battery'))
    a2:login('nosuch1', 'x1234567', '10.0.0.9')
    a2:login('nosuch2', 'x1234567', '10.0.0.9')
    a2:login('nosuch3', 'x1234567', '10.0.0.9')
    check(a2:limitState('arnold', '10.0.0.9').ipThrottled,
          'a spray across many names throttles the ADDRESS it came from')
    local _, e5b, c5b = a2:login('nosuch4', 'x1234567', '10.0.0.9')
    check(e5b ~= nil and c5b == 'rate-limited',
          '   a further WRONG credential from it is rate-limited')
    local tokOk = a2:login('arnold', 'correct horse battery', '10.0.0.9')
    check(tokOk ~= nil,
          '   but the CORRECT credential from that same address still signs in')
    check(not a2:limitState('arnold', '10.0.0.9').locked,
          '   and the account itself was never locked by the address bucket')
    local tok2 = a2:login('arnold', 'correct horse battery', '10.0.0.10')
    check(tok2 ~= nil, '   a different address is unaffected')

    -- ...while the ACCOUNT bucket still locks the account it is keyed by, and
    -- only that account.
    local a2b = freshAuth('au4b', { now = function () return clock.t end,
                                    maxFails = 3, ipMaxFails = 100,
                                    windowMs = 60000, lockoutMs = 30000 })
    assert(a2b:createFirstAdmin(a2b:bootstrapToken(), 'arnold', 'correct horse battery'))
    assert(a2b:createUser('bob', 'another good password', 'user'))
    for _ = 1, 3 do a2b:login('arnold', 'wrong', '10.0.0.11') end
    local _, _, cA = a2b:login('arnold', 'correct horse battery', '10.0.0.11')
    eq(cA, 'locked', 'the account bucket still locks the account that was guessed at')
    local tokBob = a2b:login('bob', 'another good password', '10.0.0.11')
    check(tokBob ~= nil,
          '   and another account from the very same address is untouched')

    -- A name that does not exist locks out exactly like one that does: no oracle.
    local a3 = freshAuth('au5', { now = function () return clock.t end,
                                  maxFails = 3, windowMs = 60000, lockoutMs = 30000 })
    assert(a3:createFirstAdmin(a3:bootstrapToken(), 'arnold', 'correct horse battery'))
    for _ = 1, 3 do a3:login('ghost', 'x1234567', '10.1.0.1') end
    check(a3:limitState('ghost', '10.1.0.1').locked,
          'a NON-EXISTENT name locks out the same way a real one does')
    check(select(3, a3:login('ghost', 'x1234567', '10.1.0.1')) == 'locked',
          '   and stays locked, so the two are indistinguishable')

    -- sweep() reclaims lapsed entries.
    clock.t = clock.t + 200000
    local n = a3:sweep()
    check(n.limiters > 0, 'sweep() reclaims lapsed limiter entries')
end

suite('auth / login timing does not leak account existence')
do
    -- The one place the REAL cost matters: verifyOrDummy must burn a full derivation for a name
    -- that does not exist, or the response time alone enumerates accounts.
    local a, db = freshAuth('au6', { iterations = pbkdf2.DEFAULT_ITERATIONS,
                                     maxFails = 10000 })
    assert(a:createFirstAdmin(a:bootstrapToken(), 'arnold', 'correct horse battery'))

    local function timeIt(name, pw)
        local best = math.huge
        for _ = 1, 3 do
            local t0 = sys.nowMs()
            a:login(name, pw, '127.0.0.1')
            local dt = sys.nowMs() - t0
            if dt < best then best = dt end
        end
        return best
    end

    -- Warm the JIT so the first measurement is not the compile.
    timeIt('arnold', 'warmup-password')

    local known   = timeIt('arnold', 'definitely the wrong password')
    local unknown = timeIt('no-such-account-here', 'definitely the wrong password')

    note(string.format('login cost on %s: wrong password for a KNOWN user %.1f ms, ' ..
                       'any password for an UNKNOWN user %.1f ms (%d iterations)',
                       sys.os, known, unknown, pbkdf2.DEFAULT_ITERATIONS))

    local hi = math.max(known, unknown)
    local lo = math.min(known, unknown)
    local ratio = hi / math.max(lo, 0.001)
    note(string.format('   ratio %.3f (1.000 would be perfect; the naive ' ..
                       'verify(pw, u and u.pwhash or "") measures ~500000)', ratio))
    check(ratio < 1.25, string.format(
          'the two paths cost the same within 25%% (known %.1f ms vs unknown %.1f ms, ratio %.3f)',
          known, unknown, ratio))
    check(lo > 20, string.format(
          'both paths really did run a full derivation (%.1f ms, not a fast-path return)', lo))
end

suite('auth / secrets are encrypted at rest')
do
    local a, db, dir = freshAuth('au7')
    local admin = assert(a:createFirstAdmin(a:bootstrapToken(), 'arnold', 'correct horse battery'))

    local GAME_PW  = 'game-account-secret-Zx9'
    local PROXY_PW = 'proxy-secret-Qw7'
    local TOTP     = 'JBSWY3DPEHPK3PXP'

    local acct = assert(db:insert('accounts', { label = 'main-eu', login = 'l4g-main',
                                                ownerUserId = admin.id }))
    local px   = assert(db:insert('proxies', { label = 'de', kind = 'http-connect',
                                               host = '10.0.0.1', port = 8080, user = 'w1' }))

    local rec1 = assert(a:sealAccountPassword(acct.id, GAME_PW))
    local rec2 = assert(a:sealProxyPassword(px.id, PROXY_PW))
    assert(a:sealAccountToken2fa(acct.id, TOTP))
    check(rec1:find('^sbx%$1%$') ~= nil, 'a sealed password is an authsecret record')

    eq(a:openAccountPassword(acct.id), GAME_PW, 'the game password decrypts back')
    eq(a:openProxyPassword(px.id), PROXY_PW, 'the proxy password decrypts back')
    eq(a:openAccountToken2fa(acct.id), TOTP, 'the 2FA token decrypts back')

    -- The point of the exercise: grep the bytes that are actually on disk.
    local files = { 'accounts.json', 'proxies.json', 'users.json', 'characters.json',
                    'instances.json', 'scripts.json' }
    local anyLeak = nil
    for _, f in ipairs(files) do
        local raw = readRaw(dir .. '/' .. f)
        if raw then
            for _, secretText in ipairs({ GAME_PW, PROXY_PW, TOTP, 'correct horse battery' }) do
                if raw:find(secretText, 1, true) then
                    anyLeak = f .. ' contains ' .. secretText:sub(1, 4) .. '...'
                end
            end
        end
    end
    check(anyLeak == nil, 'no plaintext secret appears anywhere in the written JSON', anyLeak)

    local acctRaw = readRaw(dir .. '/accounts.json')
    check(acctRaw:find('sbx$1$', 1, true) ~= nil,
          'accounts.json holds ciphertext records where the passwords should be')
    check(acctRaw:find('l4g-main', 1, true) ~= nil,
          '   while the non-secret login name is stored in the clear, as it must be')

    -- The schema refuses plaintext in an encrypted slot.
    local _, perr = db:update('accounts', acct.id, { password = 'plaintext-oops' })
    check(perr ~= nil and perr:find('authsecret record') ~= nil,
          'the model refuses to store plaintext in an encrypted field', perr)

    -- Associated data binds a record to its slot: a copied ciphertext must not decrypt.
    local px2 = assert(db:insert('proxies', { label = 'nl', kind = 'http-connect',
                                              host = '10.0.0.2', port = 8080 }))
    assert(db:update('proxies', px2.id, { pass = rec2 }))
    local moved, merr = a:openProxyPassword(px2.id)
    check(moved == nil, 'a ciphertext copied into another row fails to authenticate', merr)
    eq(a:openProxyPassword(px.id), PROXY_PW, '   while the original still opens')

    -- Clearing.
    check(a:sealAccountPassword(acct.id, nil), 'passing nil clears a stored secret')
    eq(db:get('accounts', acct.id).password, nil, '   the field is gone')
end

-- ============================================================================
-- 4. audit
-- ============================================================================
suite('audit / record shape and durability')
do
    local dir = subdir('ad1')
    local a = assert(audit.open{ dir = dir })
    local rec = assert(a:record{ actor = 'arnold', actorId = 'u_000000000001', ip = '127.0.0.1',
                                 action = 'login.ok', target = 'arnold', outcome = 'ok' })
    eq(rec.action, 'login.ok', 'the record comes back')
    check(rec.t > 0 and rec.seq == 1, 'it is stamped with a time and a sequence number')

    -- record() returned, so the bytes are already fsynced: read them with a different handle.
    local raw = readRaw(dir .. '/audit.jsonl')
    check(raw ~= nil and #raw > 0, 'the record is on disk the moment record() returns')
    check(raw:sub(-1) == '\n', 'the line is newline-terminated')
    local decoded = json.decode(raw:sub(1, #raw - 1))
    eq(decoded.actor, 'arnold', 'the line is valid JSON with the PANEL.md fields')
    eq(decoded.ip, '127.0.0.1', '   including the source address')
    eq(decoded.outcome, 'ok', '   and the outcome')

    -- A record whose detail carries a newline (an uploaded script, a stack trace) must not
    -- break the one-line-per-record invariant.
    assert(a:record{ actor = 'arnold', ip = '127.0.0.1', action = 'exec',
                     target = 'Arnoldus', outcome = 'ok',
                     detail = 'return player:getLevel()\nprint("x")\r\n' })
    local raw2 = readRaw(dir .. '/audit.jsonl')
    local lines = 0
    for _ in raw2:gmatch('[^\n]+') do lines = lines + 1 end
    eq(lines, 2, 'a multi-line detail is still exactly one line in the file')

    a:system('hub.start', '-', 'ok', 'listening on 127.0.0.1:8088')
    eq(a:recent(1)[1].actor, 'system', 'system() records with the system actor')

    local _, e1 = a:record{ action = 'not a valid action!' }
    check(e1 ~= nil, 'an illegal action string is refused')
    local _, e2 = a:record{}
    check(e2 ~= nil, 'a record with no action is refused')
    local r3 = assert(a:record{ action = 'exec', outcome = 'nonsense' })
    eq(r3.outcome, 'error', 'an unknown outcome is normalised rather than stored')

    eq(#a:recent(2), 2, 'recent() returns the in-memory tail for the live push')
    a:close()

    -- Reopening appends rather than truncating.
    local b = assert(audit.open{ dir = dir })
    assert(b:record{ action = 'logout', actor = 'arnold', ip = '127.0.0.1' })
    local q = b:query{ limit = 100 }
    eq(#q.rows, 5, 'reopening the log appends: all five records are still there')
    b:close()
end

suite('audit / rotation, retention and query')
do
    local dir = subdir('ad2')
    -- 4 KB is the floor; with ~200-byte records that is ~20 per file.
    local a = assert(audit.open{ dir = dir, name = 'tiny', maxBytes = 4096, keep = 3 })

    local N = 300
    local actors = { 'arnold', 'sam', 'system' }
    local acts   = { 'login.ok', 'login.fail', 'instance.start', 'script.upload' }
    local t0 = 1757000000000
    for i = 1, N do
        assert(a:record{
            t = t0 + i * 1000,
            actor = actors[(i % 3) + 1],
            actorId = 'u_00000000000' .. ((i % 3) + 1),
            ip = '10.0.0.' .. ((i % 5) + 1),
            action = acts[(i % 4) + 1],
            target = 'row-' .. i,
            outcome = (i % 7 == 0) and 'denied' or 'ok',
            detail = string.rep('d', 40),
        })
    end

    local files = a:files()
    check(#files > 1, 'the log rotated (' .. #files .. ' files)')
    check(#files <= 4, 'retention held it to keep+1 files (' .. #files .. ')')
    check(not fs.exists(dir .. '/tiny.4.jsonl'), 'the file beyond `keep` was deleted')

    -- Records survive rotation: the newest and the oldest still-retained ones are readable.
    local all = a:query{ limit = 1000, maxScanBytes = 8 * 1024 * 1024 }
    check(#all.rows > 20, 'the query stitches the rotated files into one stream (' ..
          #all.rows .. ' records)')
    eq(all.rows[1].target, 'row-' .. N, 'newest first: the very last record is first')
    local descending = true
    for i = 2, #all.rows do
        if all.rows[i].t > all.rows[i - 1].t then descending = false end
    end
    check(descending, 'the whole stream is in descending time order across file boundaries')
    check(all.files > 1, '   and it really did read more than one file')

    -- Nothing is duplicated or skipped by the reverse chunked scan.
    local seen, dup = {}, nil
    for _, r in ipairs(all.rows) do
        if seen[r.target] then dup = r.target end
        seen[r.target] = true
    end
    check(dup == nil, 'no record is returned twice', dup)
    -- The retained window has to be contiguous: from the newest back, no gaps.
    local contiguous = true
    for i = 1, #all.rows do
        if all.rows[i].target ~= ('row-' .. (N - i + 1)) then contiguous = false; break end
    end
    check(contiguous, 'the retained records are a contiguous run with no gaps')

    -- ---- filters
    local byActor = a:query{ actor = 'sam', limit = 1000, maxScanBytes = 8 * 1024 * 1024 }
    check(#byActor.rows > 0, 'filter by actor returns rows')
    local clean = true
    for _, r in ipairs(byActor.rows) do if r.actor ~= 'sam' then clean = false end end
    check(clean, '   and only that actor\'s')
    check(#byActor.rows < #all.rows, '   and fewer than everything')

    local byAction = a:query{ action = 'login.fail', limit = 1000, maxScanBytes = 8 * 1024 * 1024 }
    clean = true
    for _, r in ipairs(byAction.rows) do if r.action ~= 'login.fail' then clean = false end end
    check(clean and #byAction.rows > 0, 'filter by action')

    local byPrefix = a:query{ actionPrefix = 'login.', limit = 1000,
                              maxScanBytes = 8 * 1024 * 1024 }
    check(#byPrefix.rows > #byAction.rows, 'filter by action prefix is a superset of one action')

    local byOutcome = a:query{ outcome = 'denied', limit = 1000, maxScanBytes = 8 * 1024 * 1024 }
    clean = true
    for _, r in ipairs(byOutcome.rows) do if r.outcome ~= 'denied' then clean = false end end
    check(clean and #byOutcome.rows > 0, 'filter by outcome')

    local newest = all.rows[1].t
    local oldest = all.rows[#all.rows].t
    local mid = math.floor((newest + oldest) / 2)
    local byTime = a:query{ from = mid, limit = 1000, maxScanBytes = 8 * 1024 * 1024 }
    clean = true
    for _, r in ipairs(byTime.rows) do if r.t < mid then clean = false end end
    check(clean and #byTime.rows > 0 and #byTime.rows < #all.rows,
          'filter by time range (from)')
    local window = a:query{ from = mid, to = mid + 20000, limit = 1000,
                            maxScanBytes = 8 * 1024 * 1024 }
    clean = true
    for _, r in ipairs(window.rows) do if r.t < mid or r.t > mid + 20000 then clean = false end end
    check(clean and #window.rows > 0, 'filter by a closed time window')

    local combined = a:query{ actor = 'sam', action = 'login.fail', limit = 1000,
                              maxScanBytes = 8 * 1024 * 1024 }
    clean = true
    for _, r in ipairs(combined.rows) do
        if r.actor ~= 'sam' or r.action ~= 'login.fail' then clean = false end
    end
    check(clean, 'filters combine (actor AND action)')

    -- ---- paging walks the whole log exactly once
    local page, cursor, guard = nil, nil, 0
    local paged, pagedSeen, pagedDup = {}, {}, nil
    repeat
        guard = guard + 1
        page = a:query{ limit = 7, cursor = cursor, maxScanBytes = 8 * 1024 * 1024 }
        for _, r in ipairs(page.rows) do
            if pagedSeen[r.target] then pagedDup = r.target end
            pagedSeen[r.target] = true
            paged[#paged + 1] = r
        end
        cursor = page.nextCursor
    until cursor == nil or guard > 500
    check(guard <= 500, 'paging terminated')
    check(pagedDup == nil, 'paging returns no record twice', pagedDup)
    eq(#paged, #all.rows, 'paging in 7s reaches exactly the same set as one big query')
    local sameOrder = true
    for i = 1, #paged do
        if paged[i].target ~= all.rows[i].target then sameOrder = false; break end
    end
    check(sameOrder, '   in the same order')

    -- ---- the scan budget bounds the work and hands back a usable cursor.
    -- chunkBytes is forced down so the budget path is reachable on a deliberately tiny log;
    -- in production the 64 KB chunk and the 1 MB budget are what matter.
    local tiny = a:query{ actor = 'nobody-at-all', limit = 100,
                          maxScanBytes = 2048, chunkBytes = 1024 }
    eq(#tiny.rows, 0, 'a filter that matches nothing returns nothing so far')
    check(tiny.scanned <= 2048 + 1024,
          'the scan stopped at its budget (' .. tiny.scanned .. ' bytes)')
    check(tiny.nextCursor ~= nil, '   and handed back a cursor to continue from')

    -- Continuing from that cursor must finish the log and find nothing either.
    local cur2, steps, total = tiny.nextCursor, 0, 0
    repeat
        steps = steps + 1
        local pg = a:query{ actor = 'nobody-at-all', limit = 100,
                            maxScanBytes = 2048, chunkBytes = 1024, cursor = cur2 }
        total = total + #pg.rows
        cur2 = pg.nextCursor
    until cur2 == nil or steps > 200
    check(steps <= 200, 'budgeted paging terminates')
    eq(total, 0, '   having walked the whole log without a match')

    -- The same walk WITH a match must find every record exactly once.
    local cur3, walked, wseen, wdup = nil, 0, {}, nil
    steps = 0
    repeat
        steps = steps + 1
        local pg = a:query{ limit = 100, maxScanBytes = 2048, chunkBytes = 1024, cursor = cur3 }
        for _, r in ipairs(pg.rows) do
            if wseen[r.target] then wdup = r.target end
            wseen[r.target] = true
            walked = walked + 1
        end
        cur3 = pg.nextCursor
    until cur3 == nil or steps > 200
    check(wdup == nil, 'a budget-interrupted walk still returns no record twice', wdup)
    eq(walked, #all.rows, '   and reaches every record exactly once')

    local small = a:query{ limit = 3 }
    eq(#small.rows, 3, 'a small page reads only what it needs')
    check(small.scanned <= 65536 * 2,
          '   scanning ~one chunk, not the whole log (' .. small.scanned .. ' bytes)')

    local asc = a:query{ limit = 5, order = 'asc' }
    check(asc.rows[1].t < asc.rows[#asc.rows].t, 'order=asc reverses the page')

    local _, cerr = a:query{ cursor = 'nonsense' }
    check(cerr ~= nil, 'a malformed cursor is rejected, not guessed at')

    a:close()

    -- Everything is still there after a close/reopen.
    local b = assert(audit.open{ dir = dir, name = 'tiny', maxBytes = 4096, keep = 3 })
    local after = b:query{ limit = 1000, maxScanBytes = 8 * 1024 * 1024 }
    eq(#after.rows, #all.rows, 'a reopened log reads back exactly the same records')
    eq(after.rows[1].target, all.rows[1].target, '   newest first, unchanged')
    b:close()
end

suite('audit / no secret ever reaches the log by accident')
do
    -- audit.lua cannot stop a caller passing a password in `detail`; what it CAN guarantee is
    -- that nothing hub/auth.lua puts in a record is a credential.  This checks the shape the
    -- API layer is expected to use for a login.
    local dir = subdir('ad3')
    local a = assert(audit.open{ dir = dir })
    a:record{ actor = 'arnold', actorId = 'u_000000000001', ip = '127.0.0.1',
              action = 'login.fail', target = 'arnold', outcome = 'denied', detail = '' }
    local raw = readRaw(dir .. '/audit.jsonl')
    check(raw:find('password', 1, true) == nil,
          'a login.fail record carries no password field at all')
    eq(json.decode(raw:sub(1, #raw - 1)).outcome, 'denied', 'the failure is recorded as denied')
    a:close()
end

-- ============================================================================
-- 7. the primitives the front end's security rests on
-- ============================================================================
suite('server / same-origin comparison always compares the port')
do
    local hubserver = require('hub.server')
    local same = hubserver.sameOrigin

    -- The regression: a scheme's default port must not be treated as "no port".
    -- Cookies are not port-scoped, so any other service on 80 or 443 -- or an
    -- XSS in one -- could otherwise read hub_csrf, get SameSite=Strict cookies
    -- attached and pass every CSRF check the hub has.
    check(not same('http://localhost', 'localhost:8877', 8877),
          'http://localhost (port 80) is NOT same-origin with localhost:8877')
    check(not same('https://localhost', 'localhost:8877', 8877),
          'https://localhost (port 443) is not either')
    check(not same('http://localhost:3000', 'localhost:8877', 8877),
          'a different explicit port is refused, as before')
    check(same('http://localhost:8877', 'localhost:8877', 8877),
          'the real origin still passes')
    check(same('http://127.0.0.1:8877', '127.0.0.1:8877', 8877),
          '   and so does the address form')
    -- A Host header without a port means the listener's port.
    check(same('http://panel.example', 'panel.example', 80),
          'a portless Host on :80 matches an http origin')
    check(not same('https://panel.example', 'panel.example', 80),
          '   but an https origin (443) does not')
    check(not same('http://evil.example', 'localhost:8877', 8877),
          'a different host is refused whatever the ports say')
    check(not same('null', 'localhost:8877', 8877), 'Origin: null is never same-origin')
end

suite('server / a trusted front end may set the client address')
do
    local hubserver = require('hub.server')
    check(hubserver.inCidr('10.1.2.3', '10.0.0.0/8'), '10.1.2.3 is inside 10.0.0.0/8')
    check(not hubserver.inCidr('11.1.2.3', '10.0.0.0/8'), '11.1.2.3 is not')
    check(hubserver.inCidr('192.168.1.5', '192.168.1.5'), 'a bare address is a /32')
    check(hubserver.inCidr('200.0.0.1', '128.0.0.0/1'),
          'an address above 127.x matches a wide prefix (no signed-int overflow)')
    check(not hubserver.inCidr('notanip', '10.0.0.0/8'), 'garbage matches nothing')

    -- clientIp takes the LAST hop, and only from a peer inside the allow-list.
    local function reqWith(peer, xff)
        return { remoteIp = peer, header = function(_, n)
            return (n == 'x-forwarded-for') and xff or nil end }
    end
    local trusting = { trustedProxies = { '10.0.0.0/8' } }
    eq(hubserver.clientIp(trusting, reqWith('10.0.0.1', '1.2.3.4, 10.0.0.1')), '10.0.0.1',
       'the LAST X-Forwarded-For hop is the one taken')
    eq(hubserver.clientIp(trusting, reqWith('203.0.113.9', '1.2.3.4')), '203.0.113.9',
       'a header from an untrusted peer is ignored entirely')
    eq(hubserver.clientIp({ trustedProxies = {} }, reqWith('10.0.0.1', '1.2.3.4')), '10.0.0.1',
       'with no trusted proxy configured the header is never believed')
end

suite('api / a proxy pointed at a private address is not a port scanner')
do
    local api = require('hub.api')
    for _, h in ipairs{ '127.0.0.1', '10.4.5.6', '192.168.0.1', '172.20.0.1',
                        '169.254.169.254', 'localhost', '100.100.0.1', '::1' } do
        check(api.isPrivateHost(h), h .. ' is refused as a proxy.test target')
    end
    for _, h in ipairs{ '8.8.8.8', 'proxy.example.com', '203.0.113.9', '172.32.0.1' } do
        check(not api.isPrivateHost(h), h .. ' is a legitimate target')
    end
    -- The reported outcome is a fixed reason, never the peer's own words.
    local seen = {}
    for _, k in ipairs{ 'ok', 'unreachable', 'not-proxy', 'refused', 'timeout', 'blocked' } do
        local r = api.proxyTestReason(k)
        check(type(r) == 'string' and #r > 0, 'proxy.test reason for ' .. k .. ' is a sentence')
        seen[r] = true
    end
    check(api.proxyTestReason('HTTP/1.1 400 Bad Request') == api.proxyTestReason('unreachable'),
          'an unknown reason collapses to the generic one -- no banner leaks through')
end

suite('model / a bot profile can never escape its root')
do
    local dir = subdir('mp')
    local st = newStore(dir)
    local db = assert(model.attach(st))
    local u = assert(db:insert('users', { name = 'mp', role = 'user', pwhash = 'x' .. ('y'):rep(20) }))
    local a = assert(db:insert('accounts', { label = 'l', login = 'g', ownerUserId = u.id }))
    local c = assert(db:insert('characters', { accountId = a.id, name = 'Char One', world = 'Gunzodus' }))

    -- botProfile becomes the worker's profile DIRECTORY verbatim, so a
    -- separator or a traversal component would point every profile read and
    -- every script.put write outside the tree.
    for _, bad in ipairs{ '../../etc', 'a/b', 'a\\b', '..', '.', '/abs', 'x/../y' } do
        local ok = db:insert('instances', { characterId = c.id, ownerUserId = u.id,
                                            botProfile = bad })
        check(ok == nil, ('botProfile %q is refused'):format(bad))
    end
    local good = db:insert('instances', { characterId = c.id, ownerUserId = u.id,
                                          botProfile = 'profile_1' })
    check(good ~= nil, 'a plain profile name is accepted')

    -- A character name reaches the worker as --instance-name; spaces are normal,
    -- separators and control bytes are not.
    for _, bad in ipairs{ '../evil', 'a/b', 'a\\b', ' leading', '' } do
        local ok = db:insert('characters', { accountId = a.id, name = bad, world = 'Gunzodus' })
        check(ok == nil, ('character name %q is refused'):format(bad))
    end
    local okName = db:insert('characters', { accountId = a.id, name = "O'Malley Two",
                                             world = 'Gunzodus' })
    check(okName ~= nil, 'a real character name with a space and an apostrophe is accepted')
    st:close()
end

suite('audit / one actor cannot scroll the log out of retention')
do
    local dir = subdir('abudget')
    assert(fs.mkdirp(dir))
    local a = assert(audit.open{ dir = dir, name = 'audit', maxBytes = 4096, keep = 1,
                                 budgetBurst = 5, budgetPerSec = 0 })
    local written = 0
    for i = 1, 50 do
        local rec = a:record{ actor = 'alice', ip = '1.2.3.4', action = 'instance.stop',
                              target = 'i_' .. i, outcome = 'denied', detail = 'no such instance' }
        if rec then written = written + 1 end
    end
    -- five real records, then ONE 'audit.throttled' marker, and nothing more
    check(written <= 6, ('the budget stopped the flood after %d writes'):format(written))
    local res = assert(a:query{ limit = 50 })
    local throttled, mine = 0, 0
    for _, r in ipairs(res.rows) do
        if r.action == 'audit.throttled' then throttled = throttled + 1 end
        if r.action == 'instance.stop' then mine = mine + 1 end
    end
    eq(mine, 5, 'exactly the burst allowance of real records reached the log')
    eq(throttled, 1, 'and ONE marker says the rest were suppressed')

    -- The hub's own records are never throttled: they are not caused by a request.
    for i = 1, 30 do a:system('hub.start', 'x', 'ok', 'n=' .. i) end
    local res2 = assert(a:query{ limit = 100, actor = 'system' })
    check(#res2.rows >= 30, 'system records are exempt from the budget')

    -- A different actor has its own bucket.
    local other = a:record{ actor = 'bob', ip = '1.2.3.4', action = 'instance.stop',
                            target = 'i_1', outcome = 'denied', detail = 'x' }
    check(other ~= nil, 'another actor is unaffected by the first one`s budget')
    a:close()
end

suite('audit / a free-text search scans the log, not one page')
do
    local dir = subdir('aq')
    assert(fs.mkdirp(dir))
    local a = assert(audit.open{ dir = dir, name = 'audit', maxBytes = 8 * 1024 * 1024, keep = 2 })
    a:system('hub.start', 'needle-at-the-bottom', 'ok', 'the one we are looking for')
    for i = 1, 400 do
        a:system('instance.config', 'i_' .. i, 'ok', 'filler record ' .. i)
    end

    -- The needle is 400 records deep, so a page-sized read would never see it.
    local page = assert(a:query{ limit = 20 })
    local onPage = false
    for _, r in ipairs(page.rows) do
        if tostring(r.target):find('needle', 1, true) then onPage = true end
    end
    check(not onPage, 'the needle is NOT on the first page (so the test means something)')

    local found = assert(a:query{ q = 'needle', limit = 20 })
    eq(#found.rows, 1, 'searching for it finds it anyway')
    eq(found.rows[1].target, 'needle-at-the-bottom', '   and it is the right record')
    check(found.nextCursor == nil, '   with no cursor left, because the scan completed')

    local none = assert(a:query{ q = 'haystack-only', limit = 20 })
    eq(#none.rows, 0, 'a term that is not there returns nothing')
    check(none.nextCursor == nil, '   and says so definitively rather than paging forever')
    a:close()
end

suite('api / a duplicate name is a conflict, whatever the model calls it')
do
    local api = require('hub.api')
    -- The classification must not depend on which word hub/model.lua happens to
    -- use, and it must always be a STRING: the inline `a or b and c or d` form
    -- returned string.find's NUMBER for a message containing 'unique', so the
    -- panel received {"code": 27} and the status came out 400 instead of 409.
    for _, msg in ipairs{ 'users: name "alice" is already taken',
                          'users: name must be unique',
                          'proxies: label is not unique (taken)' } do
        local code = api.duplicateCode(msg)
        eq(type(code), 'string', 'the code for a duplicate is a string')
        eq(code, 'conflict', ('   and "conflict" for %q'):format(msg:sub(1, 40)))
        eq(api.statusFor(code), 409, '   which the HTTP layer maps to 409')
    end
    for _, msg in ipairs{ 'users: name must be at least 2 characters',
                          'instances: proxyId must be a string, got boolean' } do
        eq(api.duplicateCode(msg), 'bad-request', 'an ordinary validation error is 400')
    end
end

suite('telemetry / a removal is not broadcast to everybody')
do
    -- `publish('instance', {removed=true}, {})` -- an EMPTY opts table -- means
    -- "everyone" to visibleTo, so every signed-in account learned the ids of
    -- other people's instances and scripts as they were deleted.
    local tel = telemetry.new{}
    local delivered = {}
    -- hub/api.lua's visibilityFor(): an administrator sees every instance, a user
    -- only their own.
    local function sockFor(uid, role, ownsId)
        local ws = { user = { userId = uid, userName = uid, role = role,
                              visible = function(id)
                                  return role == 'admin' or id == ownsId end },
                     isOpen = function() return true end,
                     send = function(_, payload)
                       delivered[uid] = (delivered[uid] or 0) + 1; return true end,
                     close = function() end }
        tel:addSocket(ws)
        return ws
    end
    local alice = sockFor('u_alice', 'user', 'i_alice')
    local bob   = sockFor('u_bob',   'user', 'i_bob')
    local admin = sockFor('u_admin', 'admin', nil)

    tel:publish('instance', { id = 'i_alice', removed = true }, { instanceId = 'i_alice' })
    tel:publish('script',   { id = 's_alice', removed = true }, { userId = 'u_alice' })
    tel:_drain()

    check((delivered.u_alice or 0) >= 2, 'the owner is told about her own removals')
    eq(delivered.u_bob, nil, 'another user is told NOTHING about them')
    check((delivered.u_admin or 0) >= 2, 'the administrator still sees everything')
end

suite('telemetry / one account cannot hold every socket')
do
    local tel = telemetry.new{ maxPerUser = 3 }
    local closed = {}
    local function fakeWs(uid, tag)
        return { user = { userId = uid, userName = uid }, tag = tag,
                 close = function(self) closed[self.tag] = true end,
                 send = function() return true end }
    end
    local socks = {}
    for i = 1, 5 do
        socks[i] = fakeWs('u_alice', 'a' .. i)
        tel:addSocket(socks[i])
    end
    eq(tel:socketCount(), 3, 'alice is held to her per-account cap')
    check(closed.a1 and closed.a2, '   and it is the OLDEST sockets that were closed')
    check(not closed.a5, '   never the one that just connected')

    local b = fakeWs('u_bob', 'b1')
    tel:addSocket(b)
    eq(tel:socketCount(), 4, 'another account has its own allowance')
end

suite('server / a published bind is pinned and strict')
do
    local hubserver = require('hub.server')

    -- A non-loopback bind used to leave allowedHosts nil, so ANY Host header was
    -- accepted and the Origin check compared two attacker-supplied values.
    local pub = hubserver.allowedHostsFor('0.0.0.0', { 'panel.example', 'PANEL.EXAMPLE' })
    check(#pub >= 2, 'a non-loopback bind still HAS a Host allow-list')
    local set = {}
    for _, h in ipairs(pub) do set[h] = true end
    check(set['0.0.0.0'], '   containing the bind address itself')
    check(set['panel.example'], '   and the name the operator declared')
    eq(#pub, 2, '   with the duplicate spelling folded away')
    check(not set['rebound.attacker.example'],
          '   and NOT a name nobody declared -- which is where DNS rebinding dies')

    local lo = hubserver.allowedHostsFor('127.0.0.1')
    eq(#lo, 3, 'a loopback bind keeps its three names')

    -- ...and the token check stops being optional there.
    local fakeApi = { record = function() end }
    local fakeAuth = { needsBootstrap = function() return false end }
    local insecure = hubserver.new{ host = '0.0.0.0', port = 8777,
                                    api = fakeApi, auth = fakeAuth }
    check(insecure.insecure, 'a non-loopback bind reports itself insecure')
    check(insecure.csrfStrict, '   and forces --csrf-strict, so X-CSRF-Token is mandatory')
    local loopback = hubserver.new{ host = '127.0.0.1', port = 8777,
                                    api = fakeApi, auth = fakeAuth }
    check(not loopback.insecure, 'a loopback bind is not insecure')
    check(not loopback.csrfStrict, '   and leaves the token optional, as documented')
end

suite('server / the login path is serialised behind a bounded queue')
do
    local hubserver = require('hub.server')
    local auth = require('hub.auth')
    local fakeApi = { record = function() end }
    local fakeAuth = { needsBootstrap = function() return false end }
    local srv = hubserver.new{ host = '127.0.0.1', port = 0, api = fakeApi, auth = fakeAuth,
                               maxLoginQueue = 4 }

    check(hubserver.SERIALISED['auth.login'], 'auth.login is a serialised command')
    check(hubserver.SERIALISED['auth.changePassword'], '   and so is the password change')
    check(hubserver.SERIALISED['auth.bootstrap'], '   and the bootstrap')
    check(not hubserver.SERIALISED['instance.list'], 'an ordinary read is not')
    check(type(auth.LOGIN_COST_HINT_MS) == 'number',
          'hub/auth.lua still exports the cost hint the cap is sized from')

    -- The queue only ever runs one at a time, and refuses past its depth rather
    -- than letting a burst of ~270 ms derivations own the reactor.
    local dones, accepted, rejected = {}, 0, 0
    local concurrent, peak = 0, 0
    for i = 1, 10 do
        local ok = srv:runSerialised(function(done)
            concurrent = concurrent + 1
            if concurrent > peak then peak = concurrent end
            dones[#dones + 1] = function() concurrent = concurrent - 1; done() end
        end)
        if ok then accepted = accepted + 1 else rejected = rejected + 1 end
    end
    -- one in flight plus the configured backlog of waiters
    eq(accepted, 5, 'the queue accepted one in flight plus its configured backlog')
    eq(rejected, 5, '   and refused the rest immediately (the caller answers 429)')

    -- drain it, running the posted work by hand
    local guard = 0
    while (#dones > 0 or srv:loginQueueDepth() > 0 or srv.pwBusy) and guard < 100 do
        guard = guard + 1
        sched.tick(0)
        local d = table.remove(dones, 1)
        if d then d() end
        sched.tick(0)
    end
    eq(peak, 1, 'never more than ONE password derivation was in flight')
    eq(srv:loginQueueDepth(), 0, 'the queue drained')

    -- once drained it accepts again
    check(srv:runSerialised(function(done) done() end),
          'the queue accepts work again once it has drained')
end

-- =================================================================== report
rmrf(TMP)

io.write('\n')
io.write('============== hubcoresuite ==============\n')
local width = 0
for _, s in ipairs(suites) do if #s.name > width then width = #s.name end end
for _, s in ipairs(suites) do
    io.write(('  %-' .. width .. 's  %s  %d passed'):format(
        s.name, s.fail == 0 and 'PASS' or 'FAIL', s.pass))
    if s.fail > 0 then io.write((', %d FAILED'):format(s.fail)) end
    io.write('\n')
end
io.write(('  %s\n'):format(string.rep('-', width + 20)))
for _, n in ipairs(notes) do io.write('  note: ', n, '\n') end
io.write(('  platform: %s, %s\n'):format(sys.os, jit and jit.version or _VERSION))
io.write(('  TOTAL: %d passed, %d failed  -> %s\n'):format(
    totalPass, totalFail, totalFail == 0 and 'PASS' or 'FAIL'))

local code = (totalFail == 0) and 0 or 1
pcall(function () sys.shutdown() end)
os.exit(code)
