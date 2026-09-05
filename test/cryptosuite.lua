--[[============================================================================
test/cryptosuite.lua -- known-answer tests for the panel's authentication crypto.

  luajit test/cryptosuite.lua            (from D:/Claude/otclient_web/luaclient)

Covers lib/sha2.lua, lib/hmac.lua, lib/pbkdf2.lua, lib/base64.lua, lib/authsecret.lua.
Exits non-zero if ANY check fails.

Every expected value below is a KNOWN-ANSWER vector from a published standard:

  SHA-256/224   FIPS 180-4 / NIST examples: "", "abc", the 448-bit and 896-bit messages and
                the 1,000,000 x 'a' message.  The extra length-boundary digests (54..129, 1000,
                3,000,000 bytes) were produced with Python's hashlib and are frozen here.
  HMAC-SHA256   RFC 4231 test cases 1-7 (short key, key == "Jefe", 20/25-byte keys, the
                truncation case, and the two 131-byte over-block-size keys).
  PBKDF2        RFC 7914 section 11 ("passwd"/"salt"/1/64 and "Password"/"NaCl"/80000/64) plus
                the RFC 6070 input set re-computed for SHA-256 with Python.
  Base64        RFC 4648 section 10 vectors, standard and URL-safe alphabets.
  ChaCha20      RFC 8439 section 2.3.2 (block function) and section 2.4.2 (encryption).  Both
                were independently reproduced with `openssl enc -chacha20` (OpenSSL 3.5.7)
                before being frozen here, so they do not rest on this repo's implementation.

The last suite additionally shells out to Python's hashlib/hmac/base64 for freshly generated
random inputs; it is skipped with a note (not a failure) when no interpreter is found.

No password, token or key material is ever printed: the vectors are public constants and the
authsecret suite prints only pass/fail.
============================================================================]]

local ROOT
do
    local src = debug.getinfo(1, 'S').source
    local dir = (src:sub(1, 1) == '@') and src:sub(2):match('^(.*)[/\\][^/\\]*$') or '.'
    ROOT = (dir .. '/..'):gsub('\\', '/')
    package.path = ROOT .. '/?.lua;' .. package.path
end

local sha2       = require('lib.sha2')
local hmac       = require('lib.hmac')
local pbkdf2     = require('lib.pbkdf2')
local base64     = require('lib.base64')
local authsecret = require('lib.authsecret')
local sys        = require('lib.sys')

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
    return ok
end

local function eq(got, want, desc)
    if got == want then return check(true, desc) end
    local g, w = tostring(got), tostring(want)
    if #g > 96 then g = g:sub(1, 93) .. '...' end
    if #w > 96 then w = w:sub(1, 93) .. '...' end
    return check(false, desc, 'got ' .. g .. ', want ' .. w)
end

local function note(s) notes[#notes + 1] = s end

local function unhex(h)
    return (h:gsub('%x%x', function (c) return string.char(tonumber(c, 16)) end))
end
local tohex = sha2.tohex

-- ===================================================================== sha2
suite('sha2 / SHA-256 NIST vectors')
do
    eq(sha2.sha256hex(''),
       'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'empty string')
    eq(sha2.sha256hex('abc'),
       'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', '"abc"')
    eq(sha2.sha256hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
       '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1', '448-bit message')
    eq(sha2.sha256hex('abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno' ..
                      'ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu'),
       'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1', '896-bit message')
    eq(sha2.sha256hex(string.rep('a', 1000000)),
       'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0', "1,000,000 x 'a'")
    eq(sha2.sha256(''):len(), 32, 'raw digest is 32 bytes')
    eq(tohex(sha2.sha256('abc')),
       sha2.sha256hex('abc'), 'raw and hex outputs agree')
end

suite('sha2 / padding boundaries')
do
    -- Message of length L is bytes (i*7+3) mod 256 for i = 0..L-1.  Digests from Python hashlib.
    local want = {
        [0]   = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        [1]   = '084fed08b978af4d7d196a7446a86b58009e636b611db16211b65a9aadff29c5',
        [54]  = '160bbf14b458c877b7049e7cb5771dd653930f97d20bdd8ee795c16062906233',
        [55]  = 'e7313d333c272e639f790978283f9eb392e843d0f29b7016828bb1daa4aac70b',
        [56]  = '4324d65f3c103567f5589c710bc08f8523f929a9272e3af36fc968e52abc6c27',
        [57]  = '35df609437dcfea3279283ab79fd554e2bf78f8f7ae2de532d8ee300b09e8f73',
        [63]  = '81c80242132f230c3bd41b3e63bbcff16107339549214a99614ff26664625055',
        [64]  = '39e3d7b6b5d075d37d053ad89b24b41bef4f3c29760c84447cab3f3be1882241',
        [65]  = 'aacca6ff74fdbb296d165a45cecfa04e5127bc008770fbbdd48006f2d2fae95e',
        [119] = '9ce7368e4daf32341631b492e80359dc9f594b48453cd0dd5bf0b19279cc177e',
        [120] = '7836b787757e95e58b3ca5aec90b1b004e8deba1e50e9675af9cabf1a13a04b5',
        [121] = '1189a98a00c71bc1848ea8bdc9700b442bee0be7c3f45172303f1ab0b6f1617e',
        [127] = 'a8d23e75d936f303d248888d9b165ee543f4cbafcad3c9dd2a79bd84faa11d07',
        [128] = 'd2742f1f4ac6bb7ca2b239ee18402ba8b3f9f8e652d2a72973c2b9ba11c08cf6',
        [129] = '307f8fc2c1622b92762e818d39a185d4d667ad49a4b07ceae1f4afa008a93ec4',
        [1000]= '1e9bc38cbf860b9ec31918b065f9b52476c549a782e0e7990bed8ce3868d2371',
    }
    local function msg(L)
        local t = {}
        for i = 0, L - 1 do t[i + 1] = string.char((i * 7 + 3) % 256) end
        return table.concat(t)
    end
    for _, L in ipairs{ 0, 1, 54, 55, 56, 57, 63, 64, 65, 119, 120, 121, 127, 128, 129, 1000 } do
        eq(sha2.sha256hex(msg(L)), want[L], ('length %d'):format(L))
    end
end

suite('sha2 / streaming API')
do
    local m = 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'
    local oneshot = sha2.sha256hex(m)
    for _, chunk in ipairs{ 1, 3, 7, 13, 32, 55, 64, 65, 1000 } do
        local d = sha2.new256()
        for i = 1, #m, chunk do d:update(m:sub(i, i + chunk - 1)) end
        eq(d:hexdigest(), oneshot, ('streamed in %d-byte chunks'):format(chunk))
    end

    local d = sha2.new256()
    d:update(''):update('a'):update(''):update('bc'):update('')
    eq(d:hexdigest(), sha2.sha256hex('abc'), 'empty updates are no-ops')

    d = sha2.new256():update('abc')
    local first = d:hexdigest()
    eq(d:hexdigest(), first, 'digest() is repeatable (non-destructive)')
    d:update('def')
    eq(d:hexdigest(), sha2.sha256hex('abcdef'), 'update() may continue after digest()')

    local c = sha2.new256():update('abc')
    local clone = c:clone():update('def')
    eq(c:hexdigest(), sha2.sha256hex('abc'), 'clone() does not disturb the original')
    eq(clone:hexdigest(), sha2.sha256hex('abcdef'), 'clone() continues independently')
    eq(sha2.new256():update('xyz'):reset():update('abc'):hexdigest(),
       sha2.sha256hex('abc'), 'reset()')

    -- 3 MB, streamed: exercises the multi-megabyte path and the 64-bit length field.
    local big = string.rep('abcdefghij0123456789', 150000)
    eq(#big, 3000000, '3 MB test message built')
    eq(sha2.sha256hex(big),
       '5c17558a12cc762eeb14fce7c20250e65345c558169ccc7789382dafe0170014', '3 MB one-shot')
    local sd = sha2.new256()
    for i = 1, #big, 65536 do sd:update(big:sub(i, i + 65535)) end
    eq(sd:hexdigest(),
       '5c17558a12cc762eeb14fce7c20250e65345c558169ccc7789382dafe0170014', '3 MB streamed')
    eq(sha2.sha224hex(big),
       'eb07a79b6e8ad4e09754586cca25c47c3a8ccc21af4709d0538573fa', '3 MB SHA-224')
    eq(hmac.sha256hex(string.rep('k', 100), big),
       'd1d5e7b26960330a0985d1502d16dd949b412e099662744b1717661abaede2a8', '3 MB HMAC')
end

suite('sha2 / SHA-224 NIST vectors')
do
    eq(sha2.sha224hex(''),
       'd14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f', 'empty string')
    eq(sha2.sha224hex('abc'),
       '23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7', '"abc"')
    eq(sha2.sha224hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
       '75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525', '448-bit message')
    eq(sha2.sha224hex('abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno' ..
                      'ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu'),
       'c97ca9a559850ce97a04a96def6d99a9e0e0e2ab14e6b8df265fc0b3', '896-bit message')
    eq(sha2.sha224hex(string.rep('a', 1000000)),
       '20794655980c91d8bbb4c1ea97618a4bf03f42581948b2ee4ee7ad67', "1,000,000 x 'a'")
    eq(#sha2.sha224(''), 28, 'raw digest is 28 bytes')
end

-- ===================================================================== hmac
suite('hmac / RFC 4231 cases 1-7')
do
    local cases = {
        { key = string.rep('\x0b', 20), data = 'Hi There',
          want = 'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7' },
        { key = 'Jefe', data = 'what do ya want for nothing?',
          want = '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843' },
        { key = string.rep('\xaa', 20), data = string.rep('\xdd', 50),
          want = '773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe' },
        { key = unhex('0102030405060708090a0b0c0d0e0f10111213141516171819'),
          data = string.rep('\xcd', 50),
          want = '82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b' },
        { key = string.rep('\x0c', 20), data = 'Test With Truncation',
          want = 'a3b6167473100ee06e0c796c2955552bfa6f7c0a6a8aef8b93f860aab0cd20c5' },
        { key = string.rep('\xaa', 131),
          data = 'Test Using Larger Than Block-Size Key - Hash Key First',
          want = '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54' },
        { key = string.rep('\xaa', 131),
          data = 'This is a test using a larger than block-size key and a larger than ' ..
                 'block-size data. The key needs to be hashed before being used by the ' ..
                 'HMAC algorithm.',
          want = '9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2' },
    }
    for i, c in ipairs(cases) do
        eq(hmac.sha256hex(c.key, c.data), c.want, ('case %d (key %d B, data %d B)')
           :format(i, #c.key, #c.data))
    end
    -- RFC 4231 case 5 also specifies the 128-bit truncation.
    eq(hmac.sha256hex(cases[5].key, cases[5].data):sub(1, 32),
       'a3b6167473100ee06e0c796c2955552b', 'case 5 truncated to 128 bits')
end

suite('hmac / key handling and streaming')
do
    local msg = 'the quick brown fox'
    eq(hmac.sha256hex('', msg), hmac.sha256hex(string.rep('\0', 64), msg),
       'empty key == 64 zero bytes')
    eq(hmac.sha256hex(string.rep('K', 64), msg),
       hmac.sha256hex(string.rep('K', 64), msg), 'exactly one block key is stable')
    eq(hmac.sha256hex(string.rep('K', 65), msg),
       hmac.sha256hex(sha2.sha256(string.rep('K', 65)), msg),
       'a 65-byte key is replaced by its SHA-256 (RFC 2104 K0 rule)')
    check(hmac.sha256hex(string.rep('K', 64), msg) ~= hmac.sha256hex(string.rep('K', 65), msg),
          '64-byte and 65-byte keys differ')

    local c = hmac.new('secretkeymaterial')
    c:update('the quick '):update('brown '):update('fox')
    eq(c:hexdigest(), hmac.sha256hex('secretkeymaterial', msg), 'streaming == one-shot')
    eq(c:hexdigest(), hmac.sha256hex('secretkeymaterial', msg), 'digest() is repeatable')
    eq(c:reset():update(msg):hexdigest(), hmac.sha256hex('secretkeymaterial', msg), 'reset()')

    check(hmac.equals('abcdef', 'abcdef'), 'equals: identical')
    check(not hmac.equals('abcdef', 'abcdeg'), 'equals: last byte differs')
    check(not hmac.equals('abcdef', 'Abcdef'), 'equals: first byte differs')
    check(not hmac.equals('abcdef', 'abcde'),  'equals: length differs')
    check(hmac.equals('', ''), 'equals: both empty')
    check(not hmac.equals('a', nil), 'equals: non-string is false, not an error')
end

-- =================================================================== pbkdf2
suite('pbkdf2 / RFC vectors')
do
    eq(pbkdf2.deriveHex('passwd', 'salt', 1, 64),
       '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc' ..
       '49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783',
       'RFC 7914 s.11: P="passwd" S="salt" c=1 dkLen=64')
    eq(pbkdf2.deriveHex('Password', 'NaCl', 80000, 64),
       '4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56' ..
       'a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d',
       'RFC 7914 s.11: P="Password" S="NaCl" c=80000 dkLen=64')

    -- RFC 6070's input set, re-computed for SHA-256 (RFC 6070 itself is HMAC-SHA1).
    eq(pbkdf2.deriveHex('password', 'salt', 1, 32),
       '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b', 'c=1 dkLen=32')
    eq(pbkdf2.deriveHex('password', 'salt', 2, 32),
       'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43', 'c=2 dkLen=32')
    eq(pbkdf2.deriveHex('password', 'salt', 4096, 32),
       'c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a', 'c=4096 dkLen=32')
    eq(pbkdf2.deriveHex('passwordPASSWORDpassword',
                        'saltSALTsaltSALTsaltSALTsaltSALTsalt', 4096, 40),
       '348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9',
       'dkLen=40 spans two blocks')
    eq(pbkdf2.deriveHex('pass\0word', 'sa\0lt', 4096, 16),
       '89b69d0516f829893c696226650a8687', 'embedded NUL bytes, dkLen=16 truncation')

    -- dkLen truncation must be a prefix of the longer output.
    local long = pbkdf2.deriveHex('password', 'salt', 100, 64)
    eq(pbkdf2.deriveHex('password', 'salt', 100, 20), long:sub(1, 40), 'dkLen=20 is a prefix')
    eq(pbkdf2.deriveHex('password', 'salt', 100, 33), long:sub(1, 66), 'dkLen=33 is a prefix')
end

suite('pbkdf2 / hash + verify')
do
    local stored = pbkdf2.hash('correct horse battery staple', { iterations = 1000 })
    local scheme, prf, iter, s64, h64 = stored:match('^(%w+)%$(%w+)%$(%d+)%$([^%$]+)%$([^%$]+)$')
    eq(scheme, 'pbkdf2', 'format: scheme field')
    eq(prf, 'sha256', 'format: prf field')
    eq(iter, '1000', 'format: iteration field')
    eq(#(base64.decode(s64) or ''), 16, 'format: 16-byte salt, base64')
    eq(#(base64.decode(h64) or ''), 32, 'format: 32-byte hash, base64')

    check(pbkdf2.verify('correct horse battery staple', stored), 'verify: right password')
    check(not pbkdf2.verify('correct horse battery stapl', stored), 'verify: wrong password')
    check(not pbkdf2.verify('', stored), 'verify: empty password')
    check(not (pbkdf2.verify('x', 'garbage')), 'verify: malformed stored string is false')
    check(not (pbkdf2.verify('x', 'pbkdf2$sha512$1000$AAAA$AAAA')), 'verify: unknown prf')
    check(not (pbkdf2.verify('x', 'bcrypt$sha256$1000$AAAA$AAAA')), 'verify: unknown scheme')
    check(not (pbkdf2.verify('x', 'pbkdf2$sha256$0$AAAAAAAAAAAAAAAAAAAAAA==$AAAA')),
          'verify: zero iterations')
    check(not (pbkdf2.verify('x', 'pbkdf2$sha256$1000$!!!!$AAAA')), 'verify: bad base64 salt')
    check(not (pbkdf2.verify('x', nil)), 'verify: nil stored string does not raise')

    local a = pbkdf2.hash('same password', { iterations = 1000 })
    local b = pbkdf2.hash('same password', { iterations = 1000 })
    check(a ~= b, 'two hashes of the same password differ (random salt)')
    check(pbkdf2.verify('same password', a) and pbkdf2.verify('same password', b),
          'both random-salt hashes verify')

    local p = pbkdf2.params(stored)
    eq(p and p.iterations, 1000, 'params: iterations')
    eq(p and p.saltLen, 16, 'params: saltLen')
    eq(p and p.dkLen, 32, 'params: dkLen')
    check(pbkdf2.needsRehash(stored), 'needsRehash: 1000 < default')
    check(not pbkdf2.needsRehash(pbkdf2.hash('x', { iterations = pbkdf2.DEFAULT_ITERATIONS,
                                                    salt = string.rep('s', 16) })),
          'needsRehash: default parameters are current')
    check(pbkdf2.needsRehash('nonsense'), 'needsRehash: unparseable means yes')

    -- Explicit salt path (used only by tests) must agree with derive().
    local fixed = pbkdf2.hash('pw', { iterations = 500, salt = 'sixteenbytesalt!' })
    eq(fixed, ('pbkdf2$sha256$500$%s$%s'):format(base64.encode('sixteenbytesalt!'),
       base64.encode(pbkdf2.derive('pw', 'sixteenbytesalt!', 500, 32))), 'hash() == derive()')
end

suite('pbkdf2 / cost')
do
    eq(pbkdf2.DEFAULT_ITERATIONS >= 200000, true,
       'DEFAULT_ITERATIONS meets the PANEL.md floor of 200k')
    local t0 = sys.nowMs()
    local stored = pbkdf2.hash('a benchmark password')
    local hashMs = sys.nowMs() - t0
    t0 = sys.nowMs()
    check(pbkdf2.verify('a benchmark password', stored), 'benchmark hash verifies')
    local verifyMs = sys.nowMs() - t0
    note(('pbkdf2: %d iterations -> hash %.1f ms, verify %.1f ms  (%s, %s)')
         :format(pbkdf2.DEFAULT_ITERATIONS, hashMs, verifyMs, sys.os, jit and jit.version or '?'))
    check(hashMs < 1000, ('one hash stays under 1000 ms (measured %.1f ms)'):format(hashMs))
    if hashMs > 300 then
        note(('WARNING: pbkdf2.hash took %.1f ms, above the ~300 ms budget -- lower ' ..
              'pbkdf2.DEFAULT_ITERATIONS on this machine'):format(hashMs))
    end
end

-- =================================================================== base64
suite('base64 / RFC 4648 vectors')
do
    local vec = {
        { '',       '',         ''         },
        { 'f',      'Zg==',     'Zg=='     },
        { 'fo',     'Zm8=',     'Zm8='     },
        { 'foo',    'Zm9v',     'Zm9v'     },
        { 'foob',   'Zm9vYg==', 'Zm9vYg==' },
        { 'fooba',  'Zm9vYmE=', 'Zm9vYmE=' },
        { 'foobar', 'Zm9vYmFy', 'Zm9vYmFy' },
    }
    for _, v in ipairs(vec) do
        local raw, std, url = v[1], v[2], v[3]
        eq(base64.encode(raw), std, ('encode(%q)'):format(raw))
        eq(base64.urlencode(raw, true), url, ('urlencode(%q, pad)'):format(raw))
        eq(base64.decode(std), raw, ('decode(%q)'):format(std))
        eq(base64.urldecode(url), raw, ('urldecode(%q)'):format(url))
        eq(base64.urldecode((url:gsub('=', ''))), raw, ('urldecode unpadded %q'):format(raw))
    end
    -- The two alphabets differ exactly on bytes that produce indices 62 and 63.
    eq(base64.encode(unhex('fbefbe')), '++++', 'standard alphabet uses + and /')
    eq(base64.urlencode(unhex('fbefbe'), true), '----', 'url alphabet uses - and _')
    eq(base64.encode(unhex('03effffa')), 'A+//+g==', 'standard: + and /')
    eq(base64.urlencode(unhex('03effffa'), true), 'A-__-g==', 'url-safe: - and _')
    eq(base64.urlencode(unhex('03effffa')), 'A-__-g', 'urlencode is unpadded by default')
end

suite('base64 / round trip and rejection')
do
    local all = {}
    for i = 0, 255 do all[i + 1] = string.char(i) end
    all = table.concat(all)
    for len = 0, 130 do
        local s = all:sub(1, len)
        if base64.decode(base64.encode(s)) ~= s then
            check(false, ('round trip at length %d'):format(len))
            break
        end
        if base64.urldecode(base64.urlencode(s)) ~= s then
            check(false, ('url round trip at length %d'):format(len))
            break
        end
        if len == 130 then check(true, 'round trip for every length 0..130, all 256 byte values') end
    end
    eq(base64.decode(base64.encode(all)), all, 'round trip of all 256 byte values')

    local bad = {
        { 'Zg=',       'wrong padding count'       },
        { 'Zg===',     'three padding characters'  },
        { 'Z',         'single trailing character' },
        { 'Zg',        'missing padding'           },
        { 'Zm9=',      'non-canonical trailing bits (2 chars would be 1 byte... 3 chars here)' },
        { 'Zm9vYh==',  'non-canonical trailing bits' },
        { 'Zm9vYmFy!!!!', 'character outside the alphabet' },
        { 'Zm 9vYmFy', 'embedded whitespace'       },
        { 'A-__-g==',  'url-safe input to the standard decoder' },
        { 'A+//+g==',  'standard input rejected by the url decoder', true },
    }
    for _, b in ipairs(bad) do
        local r
        if b[3] then r = base64.urldecode(b[1]) else r = base64.decode(b[1]) end
        check(r == nil, ('rejects %q (%s)'):format(b[1], b[2]))
    end
    eq(base64.decode('Zm9=', { lenient = true }), 'fo', 'lenient accepts non-canonical bits')
    eq(base64.decode('Zm 9v YmFy', { lenient = true }), 'foobar', 'lenient skips whitespace')
    eq(base64.decode('Zg', { nopad = true }), 'f', 'nopad accepts unpadded input')
    eq(base64.decode('A-__-g==', { anyAlphabet = true }), unhex('03effffa'),
       'anyAlphabet accepts both')
    check(select(2, base64.decode('!!!!')) ~= nil, 'error message is returned as second value')
    check(base64.isValid('Zm9vYmFy') and not base64.isValid('Zm9vYmF'), 'isValid')
end

-- ============================================================== authsecret
suite('authsecret / ChaCha20 RFC 8439 vectors')
do
    local key = unhex('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')
    eq(tohex(authsecret.chacha20Block(key, unhex('000000090000004a00000000'), 1)),
       '10f1e7e4d13b5915500fdd1fa32071c4c7d1f4c733c068030422aa9ac3d46c4e' ..
       'd2826446079faa0914c2d705d98b02a2b5129cd1de164eb9cbd083e8a2503c4e',
       'section 2.3.2 block function (counter 1)')

    local pt = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip " ..
               "for the future, sunscreen would be it."
    local ct = authsecret.chacha20(key, unhex('000000000000004a00000000'), 1, pt)
    eq(tohex(ct),
       '6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b' ..
       'f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8' ..
       '07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736' ..
       '5af90bbf74a35be6b40b8eedf2785e42874d',
       'section 2.4.2 encryption (114 bytes, spans two blocks)')
    eq(authsecret.chacha20(key, unhex('000000000000004a00000000'), 1, ct), pt,
       'XOR keystream is its own inverse')

    -- All-zero key/nonce, counter 0: the first block of the section 2.3.2 discussion.
    eq(#authsecret.chacha20Block(string.rep('\0', 32), string.rep('\0', 12), 0), 64,
       'block output is 64 bytes')
    eq(authsecret.chacha20(key, unhex('000000000000004a00000000'), 1, ''), '',
       'empty input yields empty output')
    for _, n in ipairs{ 1, 63, 64, 65, 127, 128, 129, 1000 } do
        local m = string.rep('m', n)
        eq(#authsecret.chacha20(key, unhex('000000000000004a00000000'), 1, m), n,
           ('length preserved at %d bytes (block boundary)'):format(n))
    end
end

suite('authsecret / record encryption')
do
    local box = authsecret.fromKey(string.rep('\x5a', 32))
    local rec = box:encrypt('a game account password', 'account:7:password')
    check(box:isRecord(rec), 'record is recognised')
    check(rec:match('^sbx%$1%$[%w%-_]+%$[%w%-_]+%$[%w%-_]+$') ~= nil,
          'record is sbx$1$<nonce>$<ct>$<tag>, url-safe base64, no padding')
    check(not rec:find('a game account password', 1, true), 'plaintext does not appear in it')
    eq(box:decrypt(rec, 'account:7:password'), 'a game account password', 'round trip')

    check(box:decrypt(rec, 'account:8:password') == nil, 'wrong aad fails to authenticate')
    check(box:decrypt(rec) == nil, 'missing aad fails to authenticate')

    local other = authsecret.fromKey(string.rep('\x5b', 32))
    check(other:decrypt(rec, 'account:7:password') == nil, 'a different master key cannot read it')

    -- Flip one ciphertext character (not the last, so base64 stays canonical).
    local v, nB, cB, tB = rec:match('^sbx%$(%d)%$([^%$]+)%$([^%$]+)%$([^%$]+)$')
    local flipped = cB:sub(1, 1) == 'A' and ('B' .. cB:sub(2)) or ('A' .. cB:sub(2))
    check(box:decrypt(('sbx$%s$%s$%s$%s'):format(v, nB, flipped, tB), 'account:7:password') == nil,
          'a flipped ciphertext byte is rejected by the MAC')
    local nflip = nB:sub(1, 1) == 'A' and ('B' .. nB:sub(2)) or ('A' .. nB:sub(2))
    check(box:decrypt(('sbx$%s$%s$%s$%s'):format(v, nflip, cB, tB), 'account:7:password') == nil,
          'a flipped nonce byte is rejected by the MAC')
    check(box:decrypt(('sbx$2$%s$%s$%s'):format(nB, cB, tB), 'account:7:password') == nil,
          'an unknown version is rejected')
    check(box:decrypt('sbx$1$x$y') == nil, 'a malformed record is rejected')
    check(box:decrypt('not a record') == nil, 'a non-record string is rejected')
    check(box:decrypt(nil) == nil, 'nil does not raise')

    -- Cross-record substitution: tags are bound to the nonce, so parts cannot be mixed.
    local rec2 = box:encrypt('another password', 'account:7:password')
    local _, nB2 = rec2:match('^sbx%$(%d)%$([^%$]+)%$')
    check(box:decrypt(('sbx$1$%s$%s$%s'):format(nB2, cB, tB), 'account:7:password') == nil,
          'nonce from one record + ciphertext from another is rejected')
    check(rec ~= rec2, 'two encryptions of different plaintexts differ')
    local recA = box:encrypt('same', 'aad')
    local recB = box:encrypt('same', 'aad')
    check(recA ~= recB, 'the same plaintext encrypts differently each time (random nonce)')

    for _, n in ipairs{ 0, 1, 15, 16, 63, 64, 65, 200, 4096 } do
        local m = string.rep('p', n)
        eq(box:decrypt(box:encrypt(m, 'x'), 'x'), m, ('round trip at %d bytes'):format(n))
    end
    local binary = {}
    for i = 0, 255 do binary[i + 1] = string.char(i) end
    binary = table.concat(binary)
    eq(box:decrypt(box:encrypt(binary, ''), ''), binary, 'round trip of all 256 byte values')

    local rewrapped = box:rewrap(rec, 'account:7:password', 'account:9:password')
    eq(box:decrypt(rewrapped, 'account:9:password'), 'a game account password', 'rewrap')
    check(box:decrypt(rewrapped, 'account:7:password') == nil, 'rewrap rebinds the aad')
    eq(#box:fingerprint(), 16, 'fingerprint is 16 hex chars')
    check(box:fingerprint() ~= other:fingerprint(), 'different keys have different fingerprints')
end

suite('authsecret / master key file')
do
    local path = sys.tempDir() .. '/lc_authsecret_test_' .. tostring(sys.randomU32()) .. '.key'
    os.remove(path)
    local box, created = authsecret.open(path)
    check(box ~= nil, 'open() creates a missing key file')
    eq(created, true, 'open() reports that it created the file')

    local f = io.open(path, 'rb')
    local raw = f and f:read('*a')
    if f then f:close() end
    eq(raw and #raw, 32, 'key file holds exactly 32 raw bytes')

    local box2, created2 = authsecret.open(path)
    eq(created2, false, 'the second open() loads the existing file')
    local rec = box:encrypt('roundtrip through the file', 'aad')
    eq(box2:decrypt(rec, 'aad'), 'roundtrip through the file', 'the reloaded box decrypts')
    eq(box:fingerprint(), box2:fingerprint(), 'same key file, same fingerprint')

    check(authsecret.create(path) == nil, 'create() refuses to overwrite an existing key')

    -- A truncated / wrong-size key file is refused rather than silently accepted.
    local bad = path .. '.bad'
    local bf = io.open(bad, 'wb'); bf:write('short'); bf:close()
    check(authsecret.load(bad) == nil, 'a wrong-size key file is refused')
    check(authsecret.load(path .. '.missing') == nil, 'a missing key file is refused')

    os.remove(path); os.remove(bad)
    check(io.open(path, 'rb') == nil, 'test key files cleaned up')
end

-- ==================================================== cross-check vs Python
suite('cross-check against Python hashlib/hmac/base64')
do
    local tmp = sys.tempDir()
    local tag = tostring(sys.randomU32())
    local scriptPath = tmp .. '/lc_crosscheck_' .. tag .. '.py'
    local reqPath    = tmp .. '/lc_crosscheck_' .. tag .. '.txt'

    local script = [[
import sys, hashlib, hmac, binascii, base64
def unhex(s):
    return b'' if s == '-' else binascii.unhexlify(s)
out = []
for line in open(sys.argv[1]).read().splitlines():
    p = line.split()
    if not p:
        continue
    op = p[0]
    if op == 'sha256':
        out.append(hashlib.sha256(unhex(p[1])).hexdigest())
    elif op == 'sha224':
        out.append(hashlib.sha224(unhex(p[1])).hexdigest())
    elif op == 'hmac':
        out.append(hmac.new(unhex(p[1]), unhex(p[2]), hashlib.sha256).hexdigest())
    elif op == 'pbkdf2':
        out.append(binascii.hexlify(hashlib.pbkdf2_hmac(
            'sha256', unhex(p[1]), unhex(p[2]), int(p[3]), int(p[4]))).decode())
    elif op == 'b64':
        out.append(base64.b64encode(unhex(p[1])).decode() or '-')
    elif op == 'b64url':
        out.append(base64.urlsafe_b64encode(unhex(p[1])).decode() or '-')
    else:
        out.append('?')
sys.stdout.write('\n'.join(out) + '\n')
]]
    local sf = io.open(scriptPath, 'wb')
    if sf then sf:write(script); sf:close() end

    -- Build the request: random inputs of assorted lengths.
    local reqs, expect = {}, {}
    local function hx(s) return (#s == 0) and '-' or tohex(s) end
    local inputs = {}
    for _, n in ipairs{ 0, 1, 17, 55, 56, 63, 64, 65, 100, 119, 120, 200, 1000 } do
        inputs[#inputs + 1] = sys.randomBytes(n)
    end
    for _, m in ipairs(inputs) do
        reqs[#reqs + 1] = 'sha256 ' .. hx(m); expect[#expect + 1] = { 'sha256', sha2.sha256hex(m) }
        reqs[#reqs + 1] = 'sha224 ' .. hx(m); expect[#expect + 1] = { 'sha224', sha2.sha224hex(m) }
    end
    for _, kn in ipairs{ 0, 1, 32, 63, 64, 65, 130 } do
        local k, m = sys.randomBytes(kn), sys.randomBytes(37)
        reqs[#reqs + 1] = ('hmac %s %s'):format(hx(k), hx(m))
        expect[#expect + 1] = { 'hmac key=' .. kn, hmac.sha256hex(k, m) }
    end
    for _, spec in ipairs{ { 1, 32 }, { 3, 20 }, { 17, 64 }, { 999, 40 }, { 2048, 33 } } do
        local pw, salt = sys.randomBytes(13), sys.randomBytes(16)
        reqs[#reqs + 1] = ('pbkdf2 %s %s %d %d'):format(hx(pw), hx(salt), spec[1], spec[2])
        expect[#expect + 1] = { ('pbkdf2 c=%d dk=%d'):format(spec[1], spec[2]),
                                pbkdf2.deriveHex(pw, salt, spec[1], spec[2]) }
    end
    for _, n in ipairs{ 0, 1, 2, 3, 4, 5, 6, 31, 32, 33 } do
        local m = sys.randomBytes(n)
        reqs[#reqs + 1] = 'b64 ' .. hx(m)
        expect[#expect + 1] = { 'b64 len=' .. n, base64.encode(m) ~= '' and base64.encode(m) or '-' }
        reqs[#reqs + 1] = 'b64url ' .. hx(m)
        expect[#expect + 1] = { 'b64url len=' .. n,
                                base64.urlencode(m, true) ~= '' and base64.urlencode(m, true) or '-' }
    end

    local rf = io.open(reqPath, 'wb')
    if rf then rf:write(table.concat(reqs, '\n'), '\n'); rf:close() end

    local function run(exe)
        local cmd = ('%s "%s" "%s"'):format(exe, scriptPath, reqPath)
        local p = io.popen(cmd, 'r')
        if not p then return nil end
        local out = p:read('*a')
        p:close()
        if not out or not out:match('%S') then return nil end
        local lines = {}
        for line in out:gmatch('[^\r\n]+') do lines[#lines + 1] = line end
        return (#lines == #expect) and lines or nil
    end

    -- On Windows `python3` is often a Microsoft Store stub that prints nothing, so try the
    -- name that actually works there first; on Linux `python` may not exist at all.
    local lines
    if sys.isWindows then lines = run('python') or run('python3')
    else                  lines = run('python3') or run('python') end
    if not lines then
        note('cross-check SKIPPED: no working python3/python interpreter found on PATH')
        check(true, 'python cross-check skipped (not a failure)')
    else
        local bad = 0
        for i, e in ipairs(expect) do
            if lines[i] ~= e[2] then
                bad = bad + 1
                check(false, ('python mismatch on %s (case %d)'):format(e[1], i),
                      'python=' .. tostring(lines[i]))
            end
        end
        if bad == 0 then
            check(true, ('%d random cases agree with Python (sha256, sha224, hmac, pbkdf2, base64)')
                  :format(#expect))
        end
        -- And the other direction: our decoder on Python's output must give back the bytes we
        -- asked Python to encode.
        local decodeOk = true
        for i, e in ipairs(expect) do
            local kind = e[1]:match('^(b64u?r?l?)')
            if kind and lines[i] then
                local text = (lines[i] == '-') and '' or lines[i]
                local got = (kind == 'b64') and base64.decode(text) or base64.urldecode(text)
                local want = (e[2] == '-') and '' or
                             ((kind == 'b64') and base64.decode(e[2]) or base64.urldecode(e[2]))
                if got ~= want then decodeOk = false end
            end
        end
        check(decodeOk, 'our decoder reproduces the bytes behind every Python-encoded string')
    end

    os.remove(scriptPath)
    os.remove(reqPath)
end

-- =================================================================== report
io.write('\n')
io.write('============== cryptosuite ==============\n')
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
io.write(('  TOTAL: %d passed, %d failed  -> %s\n'):format(
    totalPass, totalFail, totalFail == 0 and 'PASS' or 'FAIL'))

local code = (totalFail == 0) and 0 or 1
pcall(function() require('lib.sys').shutdown() end)
os.exit(code)
