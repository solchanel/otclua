-- lib/base64.lua -- Base64, standard and URL-safe (RFC 4648 sections 4 and 5).
--
-- API
--   base64.encode(s)              -> standard alphabet (+ /), always padded with '='
--   base64.decode(s [, opts])     -> raw string, or nil, err
--   base64.urlencode(s [, pad])   -> URL-safe alphabet (- _), UNPADDED unless pad == true
--   base64.urldecode(s)           -> raw string, or nil, err   (padding optional)
--   base64.isValid(s [, opts])    -> boolean
--
--   opts = { url = false,          -- use the URL-safe alphabet instead of the standard one
--            nopad = false,        -- accept input whose trailing '=' were omitted
--            lenient = false,      -- nopad, plus skip ASCII whitespace and accept
--                                  -- non-canonical trailing bits
--            anyAlphabet = false } -- accept + / and - _ interchangeably
--
-- The decoder is strict by default and returns `nil, message` -- never a partial result -- for:
--   * any character outside the selected alphabet (padding and, in lenient mode, whitespace aside)
--   * a length that is not a multiple of 4 (unless nopad/lenient)
--   * a wrong number of '=', a trailing group of one character, or '=' inside the body
--     (a '=' that is not at the very end is simply not in the alphabet, so it is rejected as an
--     invalid character)
--   * NON-CANONICAL trailing bits: RFC 4648 section 3.5.  "Zm9=" and "Zm9vYh==" decode "cleanly"
--     in sloppy decoders but carry bits that the encoder could never have produced, which makes
--     the encoding of a byte string non-unique.  We reject them, so decode(encode(x)) == x and
--     no two distinct strings decode to the same bytes.  Set opts.lenient to accept them.
--
-- Verified against the RFC 4648 section 10 vectors ("", f, fo, foo, foob, fooba, foobar) in both
-- alphabets and cross-checked against Python's base64 module -- see test/cryptosuite.lua.

local sbyte, schar, ssub, srep, gsub = string.byte, string.char, string.sub, string.rep, string.gsub
local concat, floor = table.concat, math.floor

local M = {}

local STD = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local URL = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'

local function encTable(alpha)
  local t = {}
  for i = 0, 63 do t[i] = ssub(alpha, i + 1, i + 1) end
  return t
end

local function decTable(alpha, extra)
  local t = {}
  for i = 0, 63 do t[sbyte(alpha, i + 1)] = i end
  if extra then for i = 0, 63 do t[sbyte(extra, i + 1)] = i end end
  return t
end

local E_STD, E_URL = encTable(STD), encTable(URL)
local D_STD, D_URL = decTable(STD), decTable(URL)
local D_ANY = decTable(STD, URL)

local WS = { [0x20] = true, [0x09] = true, [0x0a] = true, [0x0d] = true, [0x0b] = true, [0x0c] = true }

-- ------------------------------------------------------------------- encode
local function encodeWith(E, s, pad)
  if type(s) ~= 'string' then error('base64: expected a string, got ' .. type(s), 3) end
  local n = #s
  local out, k = {}, 0
  local i = 1
  while n - i >= 2 do                      -- at least 3 bytes left
    local a, b, c = sbyte(s, i, i + 2)
    local x = a * 65536 + b * 256 + c
    k = k + 1
    out[k] = E[floor(x / 262144)] .. E[floor(x / 4096) % 64] .. E[floor(x / 64) % 64] .. E[x % 64]
    i = i + 3
  end
  local rest = n - i + 1
  if rest == 1 then
    local a = sbyte(s, i)
    local x = a * 16                        -- 8 bits -> 2 chars, 4 zero bits of padding
    k = k + 1
    out[k] = E[floor(x / 64)] .. E[x % 64] .. (pad and '==' or '')
  elseif rest == 2 then
    local a, b = sbyte(s, i, i + 1)
    local x = (a * 256 + b) * 4             -- 16 bits -> 3 chars, 2 zero bits of padding
    k = k + 1
    out[k] = E[floor(x / 4096)] .. E[floor(x / 64) % 64] .. E[x % 64] .. (pad and '=' or '')
  end
  return concat(out)
end

function M.encode(s)            return encodeWith(E_STD, s, true) end
function M.urlencode(s, pad)    return encodeWith(E_URL, s, pad == true) end

-- ------------------------------------------------------------------- decode
--- `optionalPad`: accept input with the trailing '=' omitted (URL-safe style).
--- `lenient`: also skip ASCII whitespace and accept non-canonical trailing bits.
local function decodeWith(D, s, optionalPad, lenient)
  if type(s) ~= 'string' then return nil, 'base64: expected a string, got ' .. type(s) end
  if lenient then s = gsub(s, '[ \t\r\n\v\f]', '') end

  local n = #s
  -- Strip and validate padding.
  local padCount = 0
  while n > 0 and sbyte(s, n) == 61 do        -- '='
    padCount = padCount + 1
    n = n - 1
    if padCount > 2 then return nil, 'base64: more than two padding characters' end
  end
  local body = (n == #s) and s or ssub(s, 1, n)

  local rem = n % 4
  if rem == 1 then return nil, 'base64: truncated group' end
  local wantPad = (rem == 0) and 0 or (4 - rem)
  if padCount ~= 0 and padCount ~= wantPad then
    return nil, 'base64: wrong number of padding characters'
  end
  if padCount == 0 and wantPad ~= 0 and not (optionalPad or lenient) then
    return nil, 'base64: missing padding (length is not a multiple of 4)'
  end

  local out, k = {}, 0
  local i = 1
  while n - i >= 3 do                        -- a full group of 4
    local c1, c2, c3, c4 = sbyte(body, i, i + 3)
    local v1, v2, v3, v4 = D[c1], D[c2], D[c3], D[c4]
    if not (v1 and v2 and v3 and v4) then
      local bad = (not v1 and c1) or (not v2 and c2) or (not v3 and c3) or c4
      return nil, ('base64: invalid character 0x%02x at offset %d'):format(bad, i)
    end
    local x = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
    k = k + 1
    out[k] = schar(floor(x / 65536), floor(x / 256) % 256, x % 256)
    i = i + 4
  end

  local rest = n - i + 1
  if rest == 2 then
    local c1, c2 = sbyte(body, i, i + 1)
    local v1, v2 = D[c1], D[c2]
    if not (v1 and v2) then
      return nil, ('base64: invalid character 0x%02x at offset %d'):format((not v1 and c1) or c2, i)
    end
    if not lenient and (v2 % 16) ~= 0 then
      return nil, 'base64: non-canonical trailing bits (RFC 4648 section 3.5)'
    end
    k = k + 1
    out[k] = schar((v1 * 4 + floor(v2 / 16)) % 256)
  elseif rest == 3 then
    local c1, c2, c3 = sbyte(body, i, i + 2)
    local v1, v2, v3 = D[c1], D[c2], D[c3]
    if not (v1 and v2 and v3) then
      return nil, ('base64: invalid character 0x%02x at offset %d')
                  :format((not v1 and c1) or (not v2 and c2) or c3, i)
    end
    if not lenient and (v3 % 4) ~= 0 then
      return nil, 'base64: non-canonical trailing bits (RFC 4648 section 3.5)'
    end
    local x = v1 * 4096 + v2 * 64 + v3
    k = k + 1
    out[k] = schar(floor(x / 1024) % 256, floor(x / 4) % 256)
  elseif rest ~= 1 and rest ~= 0 then
    return nil, 'base64: internal group length error'
  end

  return concat(out)
end

--- opts: { url = bool, nopad = bool, lenient = bool, anyAlphabet = bool }
function M.decode(s, opts)
  opts = opts or {}
  local D = opts.anyAlphabet and D_ANY or (opts.url and D_URL or D_STD)
  return decodeWith(D, s, opts.nopad == true, opts.lenient == true)
end

--- URL-safe decode; trailing '=' padding is accepted but not required.
function M.urldecode(s)
  return decodeWith(D_URL, s, true, false)
end

function M.isValid(s, opts)
  return (M.decode(s, opts)) ~= nil
end

M.STD_ALPHABET = STD
M.URL_ALPHABET = URL

return M
