-- lib/rsa.lua -- textbook RSA public-key operation, RSA_NO_PADDING
--
-- Crypt::rsaEncrypt (src/framework/util/crypt.cpp:235-260) is
--     RSA_public_encrypt(size, msg, msg, m_rsa, RSA_NO_PADDING)
-- i.e. raw c = m^e mod n with NO padding scheme at all: the input is exactly rsaGetSize() == 128
-- bytes interpreted big-endian, and the output is exactly 128 bytes big-endian, left-zero-padded.
-- The modulus and exponent are parsed as DECIMAL strings (crypt.cpp:188-199, BN_dec2bn).
--
-- The protocol always sets the first plaintext byte to 0x00 (protocolgamesend.cpp:154-155), which
-- guarantees m < n for the 1024-bit Gunzodus modulus.

local bigint = require('lib.bigint')

local M = {}

M.SIZE = 128                -- Crypt::rsaGetSize() for the 1024-bit key

function M.size() return M.SIZE end

-- Gunzodus public key (modules/gamelib/const.lua:329-333, features.lua:304).
M.GUNZODUS_N =
    "124627388324231447675617769701366117842696721548962156708623895647474174346300521696190833" ..
    "934580287020164278359414195549510925428212676699226328012721269908075137544578076908574898" ..
    "562097520735449263292165722384481748538646580304452734750003927519095249000286367283230450" ..
    "217221784214070032637657596780069118601"
M.GUNZODUS_E = 65537

-- Building the Montgomery context (in particular R^2 mod n) costs ~2048 modular doublings, so it
-- is cached per modulus string. Logging in twice reuses it.
local ctxCache = {}

local function contextFor(modulusDecimal)
    local ctx = ctxCache[modulusDecimal]
    if not ctx then
        local n = bigint.fromDecimal(modulusDecimal)
        ctx = bigint.mont(n)
        ctxCache[modulusDecimal] = ctx
    end
    return ctx
end

--- @param plain string exactly rsa.size() (128) bytes, big-endian
--- @param modulusDecimal string decimal modulus (defaults to the Gunzodus key)
--- @param exponent number|string public exponent (defaults to 65537)
--- @return string exactly 128 bytes, big-endian, left-zero-padded
function M.encrypt(plain, modulusDecimal, exponent)
    if type(plain) ~= 'string' then
        error("rsa.encrypt: plaintext must be a string", 2)
    end
    if #plain ~= M.SIZE then
        error(string.format("rsa.encrypt: plaintext must be exactly %d bytes, got %d", M.SIZE, #plain), 2)
    end
    modulusDecimal = modulusDecimal or M.GUNZODUS_N
    exponent = tonumber(exponent or M.GUNZODUS_E)
    if not exponent then error("rsa.encrypt: exponent must be a number", 2) end

    local ctx = contextFor(modulusDecimal)
    local m = bigint.resize(bigint.fromBytes(plain), ctx.n)
    if bigint.cmp(m, ctx.m, ctx.n) >= 0 then
        error("rsa.encrypt: plaintext >= modulus (the first plaintext byte must be 0x00)", 2)
    end
    local c = ctx:powmod(m, exponent)
    return bigint.toBytes(c, M.SIZE)
end

--- Raw m^e mod n over an arbitrary-length big-endian block, output padded to `outLen` bytes.
--- Used by tests; the protocol path always goes through M.encrypt.
function M.powmodBytes(plain, modulusDecimal, exponent, outLen)
    local ctx = contextFor(modulusDecimal)
    local m = bigint.resize(bigint.fromBytes(plain), ctx.n)
    if bigint.cmp(m, ctx.m, ctx.n) >= 0 then error("rsa: plaintext >= modulus", 2) end
    local c = ctx:powmod(m, tonumber(exponent))
    return bigint.toBytes(c, outLen or M.SIZE)
end

return M
