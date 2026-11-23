-- Unit tests for src/text.lua. Run from the mod directory:
--   luajit tests/unit_text.lua      (or: lua tests/unit_text.lua)
local here = (arg and arg[0] or ""):match("^(.*)/tests/") or "."
local t = dofile(here .. "/tests/lib.lua")
core = core or {}
local text = dofile(here .. "/src/text.lua")

t.section("chars, length, codepoint")
t.eq(#text.chars("héllo"), 5, "counts characters, not bytes")
t.eq(text.length("Привет 你好"), 9, "Cyrillic and CJK lengths")
t.eq(text.codepoint("A"), 65, "ASCII code point")
t.eq(text.codepoint("é"), 0xE9, "2-byte code point")
t.eq(text.codepoint("你"), 0x4F60, "3-byte code point")
t.eq(text.codepoint("😀"), 0x1F600, "4-byte code point")
t.eq(table.concat(text.chars("a\128b\255c")), "abc", "broken bytes are dropped")

t.section("strip_escapes and clean")
t.eq(text.strip_escapes("\27(c@#f00)red\27(T@dom)x\27E!"), "redx!", "color, translation and short escapes")
t.eq(text.strip_escapes("\27(c@a\\)b)ok"), "ok", "backslash-escaped ) inside an escape")
t.eq(text.clean("  hi\tthere\n "), "hi there", "control characters become spaces, ends trimmed")
t.eq(text.clean(nil), "", "nil is empty")
t.eq(text.clean("\27(c@#ff0000)"), "", "an escape on its own is empty")

t.section("rng and hash")
local a, b = text.rng(42), text.rng(42)
local same = true
for _ = 1, 100 do
	if a() ~= b() then same = false end
end
t.ok(same, "same seed, same sequence")
local r = text.rng(7)
local lo, hi = 1, 0
for _ = 1, 1000 do
	local v = r()
	lo, hi = math.min(lo, v), math.max(hi, v)
end
t.ok(lo > 0 and hi < 1, "values stay inside (0, 1)")
t.ok(text.hash("alice") ~= text.hash("bob"), "different names hash differently")
t.eq(text.hash("alice"), text.hash("alice"), "hash is stable")

t.section("garble")
local msg = "Hello everyone, is anybody out there? Привет мир! 你好世界"
t.eq(text.garble(msg, 1, 1), msg, "clarity 1 leaves the message alone")
t.eq(text.garble(msg, 0.5, 99), text.garble(msg, 0.5, 99), "deterministic for a seed")
t.eq(text.length(text.garble(msg, 0.3, 5)), text.length(msg), "keeps the length in characters")
local g = text.garble(msg, 0.4, 5)
t.ok(g:find(",", 1, true) and g:find("?", 1, true) and g:find("!", 1, true), "punctuation survives")
local spaces = select(2, msg:gsub(" ", ""))
t.eq(select(2, g:gsub(" ", "")), spaces, "spaces survive")
local function kept(s)
	return select(2, s:gsub("[^%.%s%p]", ""))
end
local prev = math.huge
local monotonic = true
for _, c in ipairs({0.9, 0.7, 0.5, 0.3, 0.1}) do
	local n = kept(text.garble(msg, c, 1234))
	if n > prev then monotonic = false end
	prev = n
end
t.ok(monotonic, "less clarity never reveals more letters")
-- Every kept character is the original character at the same position.
local orig, garbled = text.chars(msg), text.chars(text.garble(msg, 0.5, 77))
local faithful = true
for i = 1, #orig do
	if garbled[i] ~= orig[i] and garbled[i] ~= "." then faithful = false end
end
t.ok(faithful, "kept letters are never changed, lost ones become dots")
-- Muffled speech loses consonants before vowels.
local long = ("the quick brown fox jumps over the lazy dog "):rep(20)
local function count(s, set)
	local n = 0
	for ch in s:gmatch(text.CHAR) do
		if set(ch) then n = n + 1 end
	end
	return n
end
local mg = text.chars(text.garble(long, 0.5, 3, true))
local lc = text.chars(long)
local vk, vt, ck, ct = 0, 0, 0, 0
for i = 1, #lc do
	if text.is_letter(lc[i]) then
		if text.VOWEL[lc[i]] then
			vt = vt + 1
			if mg[i] ~= "." then vk = vk + 1 end
		else
			ct = ct + 1
			if mg[i] ~= "." then ck = ck + 1 end
		end
	end
end
t.ok(vk / vt > ck / ct + 0.2, ("muffled keeps vowels (%.2f) over consonants (%.2f)"):format(vk / vt, ck / ct))

t.section("wrap")
local lines = text.wrap("the quick brown fox jumps over the lazy dog", 10)
t.eq(#lines, 5, "wraps into lines")
local fits = true
for _, l in ipairs(lines) do
	if text.length(l) > 10 then fits = false end
end
t.ok(fits, "no line is longer than the width")
t.eq(table.concat(lines, " "), "the quick brown fox jumps over the lazy dog", "no words lost or changed")
local split = text.wrap("abcdefghijklmnopqrstuvwxyz", 10)
t.eq(#split, 3, "long words are split")
t.eq(split[3], "uvwxyz", "split keeps every letter")
local cut = text.wrap("one two three four five six seven eight nine ten", 9, 2)
t.eq(#cut, 2, "max_lines caps the line count")
t.ok(cut[2]:sub(-3) == "...", "a cut message ends in ...")
t.ok(text.length(cut[2]) <= 9, "the ... still fits the width")
t.eq(#text.wrap("", 10), 0, "empty text has no lines")
t.eq(text.wrap("Привет мир", 6)[2], "мир", "wraps by characters in Cyrillic")

t.section("syllables")
local function shape(s)
	local out = {}
	for _, syl in ipairs(text.syllables(s)) do
		out[#out + 1] = syl.vowel .. syl.onset
	end
	return table.concat(out, " ")
end
t.eq(shape("banana"), "a1 a2 a2", "one syllable per vowel, b-like after a labial")
t.eq(shape("yes"), "e2", "the y in yes is a consonant")
t.eq(shape("happy"), "a2 i1", "a final y is a vowel")
t.eq(shape("brb"), "u1", "a word without vowels still gets a syllable")
t.eq(shape("ok 42"), "o1 u2 i2", "digits are one syllable each")
t.eq(#text.syllables("你好世界"), 4, "one syllable per CJK character")
t.eq(shape("Привет"), "i2 e1", "Cyrillic vowels and labials")
local q = text.syllables("are you there?")
t.ok(q[#q].rise, "a question rises at the end")
local e = text.syllables("watch out!")
t.ok(e[#e].loud and e[#e - 1].loud, "an exclamation gets loud")
local pauses = text.syllables("hi, so. yes")
t.ok(pauses[1].gap >= text.SYLLABLE_GAP.comma, "pause after a comma")
t.ok(pauses[2].gap >= text.SYLLABLE_GAP.stop, "longer pause after a full stop")
t.eq(#text.syllables(("la "):rep(100), 12), 12, "max_count caps the syllables")
t.eq(#text.syllables("... !!! ???"), 0, "punctuation alone says nothing")

os.exit(t.finish())
