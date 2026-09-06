--[[============================================================================
shim/regex.lua -- `regexMatch(subject, pattern)`, otclient's single hardest global.

WHAT IT REPLACES
  src/framework/luafunctions.cpp:95-113

      g_lua.bindGlobalFunction("regexMatch", [](std::string s, const std::string& exp) {
          int limit = 10000;
          std::vector<std::vector<std::string>> ret;
          if (s.empty() || exp.empty()) return ret;
          try {
              std::smatch m;
              const std::regex e(exp, std::regex::ECMAScript);
              while (std::regex_search(s, m, e)) {
                  ret.emplace_back();
                  for (auto x : m) ret[ret.size()-1].push_back(x);
                  s = m.suffix().str();
                  if (--limit == 0) return ret;
              }
          } catch (...) { }
          return ret;
      });

  Every observable property of that snippet is reproduced here, including the ones
  that look like bugs:

  R1  Return shape: an ARRAY OF ROWS.  Row = { wholeMatch, cap1, cap2, ... } with one
      entry per capture group DECLARED in the pattern (not per group that matched);
      a group that did not participate yields "" (std::sub_match::str() on an
      unmatched sub_match is the empty string).  #row == 1 + captureCount, always.
  R2  Iteration is over SUCCESSIVE SUFFIXES of a shrinking string, not over positions
      of the original.  So `^` re-anchors at the start of every suffix and `$` only
      ever matches the true end of the input.  (There is no std::regex_constants::
      match_prev_avail in the C++, so this is exactly what the real client does.)
  R3  An EMPTY match does not advance.  m.suffix() of a zero-length match at offset 0
      is the whole string again, so the loop spins until `limit` runs out.  vBot hits
      this for real: `vBot/combo.lua:232` matches "[a-zA-Z]*" against a party-invite
      message, and the live client returns 10 000 rows of which only the first is
      meaningful.  We do the same -- shortening the loop would change #regexData,
      which `cavebot/tasker.lua:166-169` compares with `== 1`.
  R4  limit = 10000 rows, hard.
  R5  Empty subject OR empty pattern -> {} (checked before anything else).
  R6  A pattern std::regex cannot compile is swallowed by `catch (...)` and yields {}.
      We return {} too, but LOUDLY: see "UNSUPPORTED PATTERNS" below.

SUPPORTED DIALECT (ECMAScript subset -- every construct vBot 4.8 actually uses)
  alternation            a|b|            (empty branch allowed: `(?:an |a |the |)`)
  groups                 (...)  capturing, numbered left-to-right by '('
  non-capturing groups   (?:...)
  char classes           [abc] [^abc] [a-z A-Z] [a-z 'A-z-]   ('-' literal first/last)
  class escapes          \d \D \s \S \w \W        (inside and outside classes)
  control escapes        \n \r \t \f \v \0 \xHH \uHHHH \cX
  identity escapes       \( \) \[ \] \. \* \+ \? \| \\ \/ \{ \} \- \^ \$ ...
  dot                    .   -- every byte EXCEPT \n and \r.  ECMAScript's
                             LineTerminator set also holds U+2028 and U+2029, but those
                             are multi-byte in UTF-8 and cannot be excluded by a
                             byte-oriented std::regex either, so this matches the C++.
  word boundaries        \b \B
  quantifiers            * + ? {n} {n,} {n,m}, each with a lazy `?` suffix
  Annex-B leniency       a lone `{` that does not start a valid quantifier is a literal

NOT SUPPORTED -- and deliberately loud (see R6)
  lookahead      (?=...) (?!...)
  lookbehind     (?<=...) (?<!...)
  backreferences \1 .. \9, \k<name>
  named groups   (?<name>...)
  flags/modifiers (?i) (?m) ...
  unicode property escapes \p{...}
  POSIX classes  [:alpha:]
  None of these appears in any of the 44 live call sites (docs/shim/api-platform.md
  section 4.7 enumerates the dialect actually exercised: "No lookaround, no
  backreferences").  If one ever does, `regex.match` still returns {} exactly like
  the C++ `catch (...)`, but it ALSO:
     * calls regex.onUnsupported(pattern, reason) -- default sink logs at ERROR, once
       per distinct pattern, so it cannot be lost in a per-tick flood;
     * records it in regex.failures[pattern] for tests / strict mode;
     * raises instead of returning {} when regex.strict == true.
  That is the "fail loudly rather than silently not match" rule: production keeps the
  client alive with C++-identical behaviour, the log and the test suite name the gap.

IMPLEMENTATION
  Recursive-descent parser -> AST -> backtracking matcher written in continuation
  style.  Repetition of a SINGLE-CHARACTER body (the common case: `.*`, `[0-9]+`,
  `\s*`, `[^,]+`) runs in a loop with O(1) stack; only a quantified group recurses.
  Compiled patterns are memoised (regex.CACHE_MAX entries) -- the C++ recompiles on
  every call, so the cache is observable only as speed.  A pattern whose top-level
  alternatives all begin with '^' is only ever tried at offset 0.

  MEASURED (identical on Windows LuaJIT 2.1.1781602682 and Debian 2.1.1737090214):
    * targetbot/creature.lua:62 shape -- a 5-branch anchored alternation against a
      creature name: 3.7-3.9 us per call.  At ~50 creatures a tick that is ~0.2 ms,
      inside the 5 ms tick budget of PLAN.md section 5.6.
    * corelib/table.lua:293 over the user's largest cavebot route (dtseal_mk.cfg,
      7663 bytes -> 357 pairs): 1.8 ms.  That runs at config LOAD, not per tick.
    * the R3 empty-match spin (vBot/combo.lua:232 on a party invite): 10 000 rows in
      4.4 ms, and only on a party-invite message.

  Lua 5.1 / LuaJIT: no goto, integer division via math.floor, string indices 1-based.
============================================================================]]

local regex = {}

local sbyte, ssub = string.byte, string.sub

regex.LIMIT     = 10000      -- R4: max rows, mirrors the C++ `int limit = 10000`
regex.CACHE_MAX = 256        -- compiled-pattern cache size

--- true: an unsupported/invalid pattern raises instead of returning {}.
regex.strict = false

--- pattern -> reason, for every pattern that failed to compile this process.
regex.failures = {}

regex.stats = { compiles = 0, cacheHits = 0, calls = 0, rows = 0 }

--- Loud sink for an unsupported or invalid pattern.  Replaceable (tests swap it).
--- Called AT MOST ONCE per distinct pattern string.
function regex.onUnsupported(pattern, reason)
    local ok, log = pcall(require, 'lib.log')
    local msg = ('regexMatch: unsupported pattern %q -- %s (returning {} like the C++ catch(...))')
                :format(tostring(pattern), tostring(reason))
    if ok then log.error('%s', msg) else io.stderr:write(msg, '\n') end
end

-- ===========================================================================
-- 1. character predicates
-- ===========================================================================

local function isDigit(b) return b >= 48 and b <= 57 end
local function isSpace(b)
    -- ECMAScript \s = WhiteSpace + LineTerminator.  Byte-wise: tab, LF, VT, FF, CR,
    -- space, and NBSP (0xA0) -- the multi-byte Unicode spaces cannot be expressed
    -- in a byte-oriented std::regex either, so this matches the C++.
    return b == 32 or (b >= 9 and b <= 13) or b == 160
end
local function isWord(b)
    return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95
end

-- ===========================================================================
-- 2. parser
-- ===========================================================================
-- AST nodes (plain tables, field `t` is the tag):
--   {t='char',  c=byte}
--   {t='any'}                                 -- . (not \n, not \r)
--   {t='class', neg=bool, ranges={lo,hi,...}, preds={fn,...}}
--   {t='seq',   items={...}}
--   {t='alt',   opts={<seq>,...}}
--   {t='group', idx=n|nil, body=<node>}
--   {t='rep',   min=, max=, greedy=, body=<node>, simple=bool}
--   {t='bol'} {t='eol'} {t='wordb', neg=bool}
--   {t='never'}                               -- [] : matches nothing

local Parser = {}
Parser.__index = Parser

local function perr(msg) error({ regexError = msg }, 0) end

local function newParser(src)
    return setmetatable({ s = src, i = 1, n = #src, ngroups = 0 }, Parser)
end

function Parser:peek()  return ssub(self.s, self.i, self.i) end
function Parser:eof()   return self.i > self.n end
function Parser:take()  local c = ssub(self.s, self.i, self.i); self.i = self.i + 1; return c end
function Parser:accept(c)
    if ssub(self.s, self.i, self.i) == c then self.i = self.i + 1; return true end
    return false
end

local CLASS_ESCAPES = {
    d = { pred = isDigit,                        neg = false },
    D = { pred = isDigit,                        neg = true  },
    s = { pred = isSpace,                        neg = false },
    S = { pred = isSpace,                        neg = true  },
    w = { pred = isWord,                         neg = false },
    W = { pred = isWord,                         neg = true  },
}

local CONTROL_ESCAPES = {
    n = 10, r = 13, t = 9, f = 12, v = 11, ['0'] = 0,
}

--- Parse one escape sequence, the backslash already consumed.
--- Returns either ('char', byte) or ('class', {pred=, neg=}) or ('assert', 'b'|'B').
--- `inClass` changes \b from a word boundary to a backspace, per ECMAScript.
function Parser:escape(inClass)
    if self:eof() then perr('trailing backslash') end
    local c = self:take()

    local ce = CLASS_ESCAPES[c]
    if ce then return 'class', ce end

    if c == 'b' then
        if inClass then return 'char', 8 end          -- [\b] is backspace
        return 'assert', 'b'
    end
    if c == 'B' then
        if inClass then perr('\\B is not valid inside a character class') end
        return 'assert', 'B'
    end

    local ctrl = CONTROL_ESCAPES[c]
    if ctrl then return 'char', ctrl end

    if c == 'x' then
        local h = ssub(self.s, self.i, self.i + 1)
        if #h == 2 and h:match('^%x%x$') then
            self.i = self.i + 2
            return 'char', tonumber(h, 16)
        end
        return 'char', 120                            -- Annex B: bare \x is 'x'
    end
    if c == 'u' then
        local h = ssub(self.s, self.i, self.i + 3)
        if #h == 4 and h:match('^%x%x%x%x$') then
            self.i = self.i + 4
            local cp = tonumber(h, 16)
            if cp > 255 then
                perr('\\u' .. h .. ' is outside the byte range this engine matches over')
            end
            return 'char', cp
        end
        return 'char', 117                            -- Annex B: bare \u is 'u'
    end
    if c == 'c' then
        local l = ssub(self.s, self.i, self.i)
        if l:match('^%a$') then
            self.i = self.i + 1
            return 'char', sbyte(l:upper()) - 64
        end
        return 'char', 99
    end
    if c == 'k' then perr('named backreferences (\\k) are not supported') end
    if c:match('^[1-9]$') then perr('backreferences (\\' .. c .. ') are not supported') end
    if c == 'p' or c == 'P' then perr('unicode property escapes (\\' .. c .. ') are not supported') end

    -- identity escape: \( \) \. \\ \/ \- \^ \$ \| \* \+ \? \{ \} \[ \] and friends
    return 'char', sbyte(c)
end

function Parser:classAtom()
    -- returns 'char', byte   |   'class', {pred=, neg=}
    local c = self:take()
    if c == '\\' then return self:escape(true) end
    return 'char', sbyte(c)
end

function Parser:charClass()
    -- '[' already consumed
    local node = { t = 'class', neg = false, ranges = {}, preds = {} }
    if self:accept('^') then node.neg = true end

    if ssub(self.s, self.i):match('^:%a+:') then
        perr('POSIX character classes ([:alpha:] ...) are not supported')
    end

    while true do
        if self:eof() then perr('unterminated character class') end
        if self:peek() == ']' then self.i = self.i + 1; break end

        local kind, v = self:classAtom()
        if kind == 'class' then
            node.preds[#node.preds + 1] = v
        else
            -- possible range: only when the '-' is not the last char before ']'
            if self:peek() == '-' and ssub(self.s, self.i + 1, self.i + 1) ~= ']'
               and self.i + 1 <= self.n then
                self.i = self.i + 1                        -- eat '-'
                local k2, v2 = self:classAtom()
                if k2 == 'class' then
                    -- ECMAScript makes this a SyntaxError; be lenient like Annex B and
                    -- treat all three as literals.
                    local r = node.ranges
                    r[#r + 1] = v;  r[#r + 1] = v
                    r[#r + 1] = 45; r[#r + 1] = 45
                    node.preds[#node.preds + 1] = v2
                else
                    if v2 < v then perr('character class range out of order') end
                    local r = node.ranges
                    r[#r + 1] = v; r[#r + 1] = v2
                end
            else
                local r = node.ranges
                r[#r + 1] = v; r[#r + 1] = v
            end
        end
    end

    if #node.ranges == 0 and #node.preds == 0 then
        -- [] never matches; [^] matches every byte
        if node.neg then return { t = 'anybyte' } end
        return { t = 'never' }
    end
    return node
end

function Parser:atom()
    local c = self:peek()

    if c == '(' then
        self.i = self.i + 1
        local idx = nil
        if self:accept('?') then
            local q = self:peek()
            if q == ':' then
                self.i = self.i + 1
            elseif q == '=' then
                perr('positive lookahead (?=...) is not supported')
            elseif q == '!' then
                perr('negative lookahead (?!...) is not supported')
            elseif q == '<' then
                local q2 = ssub(self.s, self.i + 1, self.i + 1)
                if q2 == '=' then perr('positive lookbehind (?<=...) is not supported') end
                if q2 == '!' then perr('negative lookbehind (?<!...) is not supported') end
                perr('named capture groups (?<name>...) are not supported')
            else
                perr('inline flags / unknown group modifier "(?' .. q .. '" are not supported')
            end
        else
            self.ngroups = self.ngroups + 1
            idx = self.ngroups
        end
        local body = self:disjunction()
        if not self:accept(')') then perr('missing )') end
        return { t = 'group', idx = idx, body = body }
    end

    if c == '[' then self.i = self.i + 1; return self:charClass() end
    if c == '.' then self.i = self.i + 1; return { t = 'any' } end

    if c == '\\' then
        self.i = self.i + 1
        local kind, v = self:escape(false)
        if kind == 'char' then return { t = 'char', c = v } end
        if kind == 'class' then
            return { t = 'class', neg = false, ranges = {}, preds = { v } }
        end
        return { t = 'wordb', neg = (v == 'B') }
    end

    if c == '^' then self.i = self.i + 1; return { t = 'bol' } end
    if c == '$' then self.i = self.i + 1; return { t = 'eol' } end

    if c == '*' or c == '+' or c == '?' then
        perr('quantifier "' .. c .. '" with nothing to repeat')
    end

    self.i = self.i + 1
    return { t = 'char', c = sbyte(c) }
end

--- Is this node a single-character matcher?  Drives the O(1)-stack repetition path.
local function isSimple(n)
    local t = n.t
    return t == 'char' or t == 'any' or t == 'class' or t == 'anybyte' or t == 'never'
end

function Parser:quantifier(node)
    local c = self:peek()
    local min, max

    if c == '*' then
        self.i = self.i + 1; min, max = 0, math.huge
    elseif c == '+' then
        self.i = self.i + 1; min, max = 1, math.huge
    elseif c == '?' then
        self.i = self.i + 1; min, max = 0, 1
    elseif c == '{' then
        -- Annex B: only a well-formed {n}, {n,}, {n,m} is a quantifier; otherwise '{'
        -- was already consumed as a literal char by atom().
        local a, b, rest = ssub(self.s, self.i):match('^{(%d+)(,?%d*)}()')
        if not a then return node end
        self.i = self.i + rest - 1
        min = tonumber(a)
        if b == '' then max = min
        elseif b == ',' then max = math.huge
        else max = tonumber(ssub(b, 2)) end
        if max < min then perr('quantifier {' .. min .. ',' .. max .. '} is out of order') end
    else
        return node
    end

    local greedy = true
    if self:accept('?') then greedy = false end

    if node.t == 'bol' or node.t == 'eol' or node.t == 'wordb' then
        perr('quantifier applied to an assertion')
    end
    return { t = 'rep', min = min, max = max, greedy = greedy, body = node,
             simple = isSimple(node) }
end

function Parser:alternative()
    local items = {}
    while not self:eof() do
        local c = self:peek()
        if c == '|' or c == ')' then break end
        local a = self:atom()
        items[#items + 1] = self:quantifier(a)
    end
    return { t = 'seq', items = items }
end

function Parser:disjunction()
    local opts = { self:alternative() }
    while self:accept('|') do
        opts[#opts + 1] = self:alternative()
    end
    if #opts == 1 then return opts[1] end
    return { t = 'alt', opts = opts }
end

-- ===========================================================================
-- 3. leading-anchor analysis (pure speed; `targetbot/creature.lua:62` is hot)
-- ===========================================================================

local function startsAnchored(n)
    local t = n.t
    if t == 'bol' then return true end
    if t == 'seq' then
        for i = 1, #n.items do
            local it = n.items[i]
            if startsAnchored(it) then return true end
            -- a zero-width non-anchor prefix (\b) can be skipped over; anything
            -- that can consume input or match empty ends the analysis
            if it.t ~= 'wordb' then return false end
        end
        return false
    end
    if t == 'alt' then
        for i = 1, #n.opts do if not startsAnchored(n.opts[i]) then return false end end
        return #n.opts > 0
    end
    if t == 'group' then return startsAnchored(n.body) end
    if t == 'rep'   then return n.min >= 1 and startsAnchored(n.body) end
    return false
end

-- ===========================================================================
-- 4. matcher
-- ===========================================================================
-- caps is a FLAT array: caps[2i-1] = start (1-based, inclusive),
--                       caps[2i]   = end   (1-based, exclusive).
-- nil in either slot means "group did not participate" -> "" in the result row.

local matchNode      -- forward
local function matchSeq(items, i, s, pos, caps, k)
    if i > #items then return k(pos) end
    return matchNode(items[i], s, pos, caps, function(p)
        return matchSeq(items, i + 1, s, p, caps, k)
    end)
end

--- Does the single-character node match the byte at `pos`?
local function single(n, s, pos, len)
    if pos > len then return false end
    local t = n.t
    if t == 'char'    then return sbyte(s, pos) == n.c end
    if t == 'any'     then local b = sbyte(s, pos); return b ~= 10 and b ~= 13 end
    if t == 'anybyte' then return true end
    if t == 'never'   then return false end
    -- class
    local b = sbyte(s, pos)
    local hit = false
    local r = n.ranges
    for i = 1, #r, 2 do
        if b >= r[i] and b <= r[i + 1] then hit = true; break end
    end
    if not hit then
        local p = n.preds
        for i = 1, #p do
            local e = p[i]
            if e.pred(b) ~= e.neg then hit = true; break end
        end
    end
    if n.neg then return not hit end
    return hit
end

local function snapshot(caps, n)
    local t = {}
    for i = 1, n do t[i] = caps[i] end
    return t
end
local function restore(caps, snap, n)
    for i = 1, n do caps[i] = snap[i] end
end

matchNode = function(n, s, pos, caps, k)
    local t = n.t
    local len = #s

    if t == 'char' or t == 'any' or t == 'class' or t == 'anybyte' or t == 'never' then
        if single(n, s, pos, len) then return k(pos + 1) end
        return nil
    end

    if t == 'seq' then return matchSeq(n.items, 1, s, pos, caps, k) end

    if t == 'bol' then
        if pos == 1 then return k(pos) end
        return nil
    end

    if t == 'eol' then
        if pos == len + 1 then return k(pos) end
        return nil
    end

    if t == 'wordb' then
        local before = pos > 1     and isWord(sbyte(s, pos - 1)) or false
        local after  = pos <= len  and isWord(sbyte(s, pos))     or false
        local atBoundary = (before ~= after)
        if atBoundary ~= n.neg then return k(pos) end
        return nil
    end

    if t == 'alt' then
        local ncap = caps.n
        local snap = snapshot(caps, ncap)
        for i = 1, #n.opts do
            local r = matchNode(n.opts[i], s, pos, caps, k)
            if r then return r end
            restore(caps, snap, ncap)
        end
        return nil
    end

    if t == 'group' then
        local idx = n.idx
        if not idx then return matchNode(n.body, s, pos, caps, k) end
        local a, b = idx * 2 - 1, idx * 2
        return matchNode(n.body, s, pos, caps, function(p)
            local oa, ob = caps[a], caps[b]
            caps[a], caps[b] = pos, p
            local r = k(p)
            if r then return r end
            caps[a], caps[b] = oa, ob
            return nil
        end)
    end

    if t == 'rep' then
        local body, min, max, greedy = n.body, n.min, n.max, n.greedy

        if n.simple then
            -- O(1) stack: consume greedily, then give characters back one at a time.
            if greedy then
                local p, cnt = pos, 0
                while cnt < max and single(body, s, p, len) do p = p + 1; cnt = cnt + 1 end
                while cnt >= min do
                    local r = k(p)
                    if r then return r end
                    if cnt == 0 then return nil end
                    p = p - 1; cnt = cnt - 1
                end
                return nil
            else
                local p, cnt = pos, 0
                while cnt < min do
                    if not single(body, s, p, len) then return nil end
                    p = p + 1; cnt = cnt + 1
                end
                while true do
                    local r = k(p)
                    if r then return r end
                    if cnt >= max or not single(body, s, p, len) then return nil end
                    p = p + 1; cnt = cnt + 1
                end
            end
        end

        -- General case: a quantified group.  Recurses once per iteration; the
        -- empty-body guard is the ECMAScript RepeatMatcher rule that stops an
        -- iteration which consumed nothing (otherwise `(a?)*` never terminates).
        local ncap = caps.n
        local step
        step = function(cnt, p)
            if greedy and cnt < max then
                local snap = snapshot(caps, ncap)
                local r = matchNode(body, s, p, caps, function(p2)
                    if p2 == p and cnt + 1 > min then return nil end   -- consumed nothing
                    return step(cnt + 1, p2)
                end)
                if r then return r end
                restore(caps, snap, ncap)
            end
            if cnt >= min then
                local r = k(p)
                if r then return r end
            end
            if (not greedy) and cnt < max then
                local snap = snapshot(caps, ncap)
                local r = matchNode(body, s, p, caps, function(p2)
                    if p2 == p and cnt + 1 > min then return nil end
                    return step(cnt + 1, p2)
                end)
                if r then return r end
                restore(caps, snap, ncap)
            end
            return nil
        end
        return step(0, pos)
    end

    error('regex: unknown AST node ' .. tostring(t))
end

-- ===========================================================================
-- 5. compile + cache
-- ===========================================================================

local cache, cacheCount = {}, 0

local function compile(pattern)
    local hit = cache[pattern]
    if hit ~= nil then
        regex.stats.cacheHits = regex.stats.cacheHits + 1
        return hit
    end

    local p = newParser(pattern)
    local ok, res = pcall(function()
        local root = p:disjunction()
        if not p:eof() then
            if p:peek() == ')' then perr('unmatched )') end
            perr('unparsed trailing input at offset ' .. p.i)
        end
        return root
    end)

    local prog
    if ok then
        prog = { root = res, ngroups = p.ngroups, anchored = startsAnchored(res) }
        regex.stats.compiles = regex.stats.compiles + 1
    else
        local reason = (type(res) == 'table' and res.regexError) or tostring(res)
        prog = { bad = true, reason = reason }
    end

    if cacheCount >= regex.CACHE_MAX then cache, cacheCount = {}, 0 end
    cache[pattern] = prog
    cacheCount = cacheCount + 1
    return prog
end

regex.compile = compile

--- Drop the compiled-pattern cache (tests that swap regex.strict use this).
function regex.clearCache() cache, cacheCount = {}, 0 end

-- ===========================================================================
-- 6. the public entry point
-- ===========================================================================

local function report(pattern, reason)
    if regex.failures[pattern] == nil then
        regex.failures[pattern] = reason
        local ok, err = pcall(regex.onUnsupported, pattern, reason)
        if not ok then io.stderr:write('regex.onUnsupported raised: ', tostring(err), '\n') end
    end
    if regex.strict then
        error(('regexMatch: pattern %q is not supported by shim/regex.lua -- %s')
              :format(tostring(pattern), tostring(reason)), 2)
    end
end

--- regexMatch(subject, pattern) -> { {full, cap1, ...}, ... }
function regex.match(subject, pattern)
    regex.stats.calls = regex.stats.calls + 1

    -- The C++ signature is (std::string, const std::string&); luavaluecasts converts a
    -- Lua number to a string, anything else raises.  Same here -- a nil subject is a
    -- caller bug and must not be silently swallowed into an empty result.
    local ts, tp = type(subject), type(pattern)
    if ts == 'number' then subject = tostring(subject); ts = 'string' end
    if tp == 'number' then pattern = tostring(pattern); tp = 'string' end
    if ts ~= 'string' then
        error('regexMatch: subject must be a string, got ' .. ts, 2)
    end
    if tp ~= 'string' then
        error('regexMatch: pattern must be a string, got ' .. tp, 2)
    end

    local ret = {}
    if subject == '' or pattern == '' then return ret end          -- R5

    local prog = compile(pattern)
    if prog.bad then report(pattern, prog.reason); return ret end   -- R6

    local root, ngroups, anchored = prog.root, prog.ngroups, prog.anchored
    local caps = { n = ngroups * 2 }
    local limit = regex.LIMIT
    local s = subject
    local identity = function(p) return p end

    while true do
        local len = #s
        local lastStart = anchored and 1 or (len + 1)
        local mstart, mend
        for start = 1, lastStart do
            for i = 1, caps.n do caps[i] = nil end
            local e = matchNode(root, s, start, caps, identity)
            if e then mstart, mend = start, e; break end
        end
        if not mstart then break end

        local row = { ssub(s, mstart, mend - 1) }                   -- R1: m[0] first
        for g = 1, ngroups do
            local a, b = caps[g * 2 - 1], caps[g * 2]
            row[g + 1] = (a and b) and ssub(s, a, b - 1) or ''      -- R1: "" when unset
        end
        ret[#ret + 1] = row
        regex.stats.rows = regex.stats.rows + 1

        s = ssub(s, mend)                                           -- R2/R3: m.suffix()
        limit = limit - 1
        if limit == 0 then return ret end                           -- R4
    end

    return ret
end

return regex
