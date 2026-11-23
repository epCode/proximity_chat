-- proximity_chat: text helpers.
--
-- Everything here works on UTF-8 characters, never bytes, so messages in any
-- script survive garbling and wrapping intact. There are no engine calls in
-- this file, so the unit tests can load it without a server.

local text = {}

-- One UTF-8 character: a lead byte and its continuation bytes. Only safe on
-- strings that are already valid UTF-8 (see text.chars for untrusted input).
local CHAR = "[%z\1-\127\194-\244][\128-\191]*"
text.CHAR = CHAR

-- Split into characters, dropping any byte that isn't part of a well-formed
-- UTF-8 sequence (stray continuation bytes, truncated sequences, bad leads).
function text.chars(s)
	local out, i, n = {}, 1, #s
	while i <= n do
		local b = s:byte(i)
		local len = b < 0x80 and 1
			or (b >= 0xC2 and b <= 0xDF) and 2
			or (b >= 0xE0 and b <= 0xEF) and 3
			or (b >= 0xF0 and b <= 0xF4) and 4
			or 0
		local ok = len > 0 and i + len - 1 <= n
		for j = i + 1, ok and i + len - 1 or 0 do
			local c = s:byte(j)
			if c < 0x80 or c > 0xBF then
				ok = false
				break
			end
		end
		if ok then
			out[#out + 1] = s:sub(i, i + len - 1)
			i = i + len
		else
			i = i + 1
		end
	end
	return out
end

function text.length(s)
	return #text.chars(s)
end

-- The code point of one UTF-8 character.
function text.codepoint(ch)
	local b1, b2, b3, b4 = ch:byte(1, 4)
	if b1 < 0x80 then
		return b1
	elseif b1 < 0xE0 then
		return (b1 - 0xC0) * 0x40 + ((b2 or 0x80) - 0x80)
	elseif b1 < 0xF0 then
		return (b1 - 0xE0) * 0x1000 + ((b2 or 0x80) - 0x80) * 0x40 + ((b3 or 0x80) - 0x80)
	end
	return (b1 - 0xF0) * 0x40000 + ((b2 or 0x80) - 0x80) * 0x1000
		+ ((b3 or 0x80) - 0x80) * 0x40 + ((b4 or 0x80) - 0x80)
end

-- Remove escape sequences (colors, translations) the way the engine does.
-- Uses the engine's own function when there is one.
function text.strip_escapes(s)
	if core and core.strip_escapes then
		return core.strip_escapes(s)
	end
	local out, i, n = {}, 1, #s
	while i <= n do
		local c = s:sub(i, i)
		if c == "\27" then
			i = i + 1
			if s:sub(i, i) == "(" then
				i = i + 1
				while i <= n and s:sub(i, i) ~= ")" do
					if s:sub(i, i) == "\\" then
						i = i + 1
					end
					i = i + 1
				end
			end
			i = i + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

-- What a player typed, made safe to show: no escape sequences (nobody can
-- fake colors or translations), no control characters, valid UTF-8, trimmed.
function text.clean(s)
	s = text.strip_escapes(tostring(s or ""))
	s = s:gsub("%c", " ")
	s = table.concat(text.chars(s))
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--------------------------------------------------------------------------------
-- Deterministic randomness
--------------------------------------------------------------------------------

-- A Park-Miller generator. Everything stays an exact integer in a double, so
-- it gives the same numbers on LuaJIT and PUC Lua, and it leaves math.random
-- alone (other mods may rely on its sequence).
function text.rng(seed)
	local state = math.floor(math.abs(seed or 1)) % 2147483646 + 1
	return function()
		state = (state * 16807) % 2147483647
		return state / 2147483647
	end
end

function text.hash(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 2147483647
	end
	return h
end

--------------------------------------------------------------------------------
-- Character classes
--------------------------------------------------------------------------------

-- Punctuation outside ASCII. Everything else non-ASCII counts as a letter.
local PUNCT = {}
for _, ch in ipairs({
	"…", "—", "–", "«", "»", "„", "“", "”", "‘", "’", "¿", "¡", "·", "•",
	"，", "。", "！", "？", "、", "：", "；", "「", "」", "『", "』", "・", "～",
	"\194\160", -- no-break space
	"\227\128\128", -- ideographic space
}) do
	PUNCT[ch] = true
end

local function is_letter(ch)
	if #ch == 1 then
		return ch:find("^%w$") ~= nil
	end
	return not PUNCT[ch]
end
text.is_letter = is_letter

local VOWEL = {}
local function vowels(list, v)
	for ch in list:gmatch(CHAR) do
		VOWEL[ch] = v
	end
end
vowels("aAáÁàÀâÂäÄãÃåÅæÆаАяЯαΑάΆ", "a")
vowels("eEéÉèÈêÊëËеЕэЭεΕέΈ", "e")
vowels("iIíÍìÌîÎïÏyYýÝÿиИыЫіІїЇιΙίΊηΗήΉ", "i")
vowels("oOóÓòÒôÔöÖõÕøØœŒоОёЁοΟόΌωΩώΏ", "o")
vowels("uUúÚùÙûÛüÜуУюЮυΥύΎ", "u")
text.VOWEL = VOWEL

local LABIAL = {}
for ch in ("bBpPmMfFvVwWбБпПмМфФвВ"):gmatch(CHAR) do
	LABIAL[ch] = true
end

-- Scripts where one character is one syllable.
local function is_syllabic(cp)
	return (cp >= 0x3040 and cp <= 0x30FF) -- kana
		or (cp >= 0x3400 and cp <= 0x9FFF) -- CJK ideographs
		or (cp >= 0xAC00 and cp <= 0xD7AF) -- Hangul
		or (cp >= 0xF900 and cp <= 0xFAFF)
end

local VOWEL_LIST = {"a", "e", "i", "o", "u"}

--------------------------------------------------------------------------------
-- Garbling
--------------------------------------------------------------------------------

-- How a message reads from too far away: letters drop out at random and are
-- replaced with dots, more of them the lower the clarity (0..1). Spaces and
-- punctuation stay, so you can still see the shape of what was said, and the
-- first letter of each word holds on a little longer. Through a wall
-- (muffled), consonants go first and vowels last, the way a muffled voice
-- sounds. The same seed gives the same result, so listeners standing in the
-- same spot read the same thing in chat and in the bubble.
function text.garble(s, clarity, seed, muffled)
	if clarity >= 1 then
		return s
	end
	local random = text.rng(seed)
	local keep = math.max(0, clarity) ^ 1.25
	local out = {}
	local word_start = true
	for _, ch in ipairs(text.chars(s)) do
		if is_letter(ch) then
			local p = keep
			if muffled then
				p = VOWEL[ch] and math.min(1, p * 1.6) or p * 0.55
			end
			if word_start then
				p = p + (1 - p) * 0.35
			end
			out[#out + 1] = random() < p and ch or "."
			word_start = false
		else
			out[#out + 1] = ch
			word_start = true
		end
	end
	return table.concat(out)
end

--------------------------------------------------------------------------------
-- Wrapping
--------------------------------------------------------------------------------

local function sub_chars(chars, i, j)
	return table.concat(chars, "", i, math.min(j, #chars))
end

-- Word-wrap to lines of at most `width` characters. Words longer than a line
-- are split. Past `max_lines`, the last line ends in "...".
function text.wrap(s, width, max_lines)
	local lines = {}
	local line, line_len = {}, 0
	local function push()
		lines[#lines + 1] = table.concat(line)
		line, line_len = {}, 0
	end
	for word in s:gmatch("%S+") do
		local chars = text.chars(word)
		local wlen = #chars
		if line_len > 0 and line_len + 1 + wlen > width then
			push()
		end
		if wlen > width then
			local i = 1
			if line_len > 0 then
				-- Fill the rest of the current line first.
				local room = width - line_len - 1
				if room >= 4 then
					line[#line + 1] = " " .. sub_chars(chars, 1, room)
					i = room + 1
				end
				push()
			end
			while wlen - i + 1 > width do
				line[1] = sub_chars(chars, i, i + width - 1)
				push()
				i = i + width
			end
			line[1] = sub_chars(chars, i, wlen)
			line_len = wlen - i + 1
		else
			if line_len > 0 then
				line[#line + 1] = " "
				line_len = line_len + 1
			end
			line[#line + 1] = word
			line_len = line_len + wlen
		end
	end
	if line_len > 0 then
		push()
	end
	if max_lines and #lines > max_lines then
		local last = text.chars(lines[max_lines])
		local keep = math.min(#last, width - 3)
		while keep > 0 and last[keep] == " " do
			keep = keep - 1
		end
		for i = #lines, max_lines + 1, -1 do
			lines[i] = nil
		end
		lines[max_lines] = sub_chars(last, 1, keep) .. "..."
	end
	return lines
end

--------------------------------------------------------------------------------
-- Syllables, for the babble voice
--------------------------------------------------------------------------------

text.SYLLABLE_GAP = {
	word = 0.05,  -- extra pause after a word
	comma = 0.14, -- after , ; :
	stop = 0.24,  -- after . ! ? and friends
}

local COMMA = {[","] = true, [";"] = true, [":"] = true, ["，"] = true,
	["、"] = true, ["；"] = true, ["："] = true}
local STOP = {["."] = true, ["!"] = true, ["?"] = true, ["…"] = true,
	["。"] = true, ["！"] = true, ["？"] = true, ["¡"] = true, ["¿"] = true}
local QUESTION = {["?"] = true, ["？"] = true}
local EXCLAIM = {["!"] = true, ["！"] = true}

-- Turn a message into the syllables its babble speaks: one per vowel group
-- (or per character in syllabic scripts), each with the vowel to say, a "b"
-- (1) or "d" (2) like onset from the consonant before it, and the pause that
-- follows. Questions rise at the end, exclamations get louder. At most
-- `max_count` syllables.
function text.syllables(s, max_count)
	max_count = max_count or math.huge
	local out = {}
	local chars = text.chars(s)
	local prev_consonant
	local in_vowels = false
	local word_letters, word_syllables = 0, 0
	local sentence_start = 1

	local function add(vowel, onset)
		word_syllables = word_syllables + 1
		if #out < max_count then
			out[#out + 1] = {vowel = vowel, onset = onset, gap = 0}
		end
	end
	local function pause(gap)
		local last = out[#out]
		if last and last.gap < gap then
			last.gap = gap
		end
	end
	local function end_word()
		if word_letters > 0 and word_syllables == 0 then
			-- "hmm", "brb", "shh": still worth one syllable
			add("u", prev_consonant and LABIAL[prev_consonant] and 1 or 2)
		end
		if word_letters > 0 then
			pause(text.SYLLABLE_GAP.word)
		end
		word_letters, word_syllables = 0, 0
		in_vowels = false
		prev_consonant = nil
	end

	for i, ch in ipairs(chars) do
		local vowel = VOWEL[ch]
		if vowel and (ch == "y" or ch == "Y") and chars[i + 1] and VOWEL[chars[i + 1]] then
			vowel = nil -- the y in "yes" is a consonant
		end
		if vowel then
			if not in_vowels then
				add(vowel, prev_consonant and (LABIAL[prev_consonant] and 1 or 2) or 1)
			end
			in_vowels = true
			prev_consonant = nil
			word_letters = word_letters + 1
		elseif is_letter(ch) then
			local cp = text.codepoint(ch)
			if is_syllabic(cp) then
				add(VOWEL_LIST[cp % 5 + 1], cp % 2 + 1)
			elseif ch:find("^%d$") then
				add(VOWEL_LIST[tonumber(ch) % 5 + 1], 2)
			else
				prev_consonant = ch
			end
			in_vowels = false
			word_letters = word_letters + 1
		else
			end_word()
			if COMMA[ch] then
				pause(text.SYLLABLE_GAP.comma)
			elseif STOP[ch] then
				pause(text.SYLLABLE_GAP.stop)
				local last = out[#out]
				if last and #out >= sentence_start then
					if QUESTION[ch] then
						last.rise = true
					elseif EXCLAIM[ch] then
						for j = math.max(sentence_start, #out - 2), #out do
							out[j].loud = true
						end
					end
				end
				sentence_start = #out + 1
			end
		end
	end
	end_word()
	return out
end

return text
