-- proximity_chat: babble voices.
--
-- Mods can't hear microphones, so the voice is made up: each message is spoken
-- as a run of short synthesized syllables (sounds/, made by
-- tools/make_sounds.py), one per syllable of the text, with the vowels of the
-- words, pauses at commas and full stops, a rise at the end of a question and
-- a little more force on an exclamation. Every player has their own pitch.
--
-- Placement: the engine lets positional sounds fall off as 3/distance, which
-- would make a voice ten nodes away barely audible. So each syllable is played
-- to each listener on its own, a few nodes from their ears in the direction
-- of the speaker: they still hear which way it comes from, and the mod
-- decides how loud it is (by mode, by how clearly they hear the message, and
-- quieter and duller through walls, with low-passed samples).

local PC, config, text, acoustics, prefs = ...

local voice = {}

local SPACING = 0.085   -- seconds from one syllable to the next
local NEAR = 3          -- nodes: how far from the ears syllables are played
local queue = {}

local function sample(set, vowel, onset, muffled)
	if muffled then
		return "proximity_chat_muffled_" .. vowel
	elseif set == "talk" then
		return "proximity_chat_talk_" .. vowel .. onset
	end
	return "proximity_chat_" .. set .. "_" .. vowel
end
voice.sample = sample

local function now()
	return core.get_us_time() / 1e6
end

local function mouth_of(sp)
	if sp.object then
		return acoustics.head_pos(sp.object)
	end
	return sp.pos
end

-- Queue the syllables of `msg` said by `sp` for `listeners`
-- ({name, clarity, muffled}).
function voice.speak(sp, msg, mode, listeners, seed, pitch)
	local set = mode.babble
	if not set then
		return
	end
	local syllables = text.syllables(msg, 64)
	local n = #syllables
	if n == 0 then
		return
	end
	local base = pitch or (sp.player_name and prefs.get(sp.player_name, "pitch"))
		or prefs.default_pitch(sp.name)
	local random = text.rng((seed or 1) * 7919 + 17)
	local utterance = {sp = sp, set = set, gain = (mode.babble_gain or 0.7) * config.babble_volume,
		listeners = listeners}
	local start = now() + 0.03
	local t = start
	for i, syl in ipairs(syllables) do
		if t - start > config.babble_max_seconds then
			break
		end
		-- A little wobble on every syllable, the voice settling lower toward
		-- the end of the message, and up at the end of a question.
		local p = base * (1 + (random() - 0.5) * 0.12) * (1 - 0.07 * (i - 1) / math.max(1, n - 1))
		if syl.rise then
			p = p * 1.15
		end
		queue[#queue + 1] = {time = t, u = utterance, vowel = syl.vowel, onset = syl.onset,
			pitch = p, loud = syl.loud}
		t = t + SPACING * (0.9 + random() * 0.2) + syl.gap
	end
end

local function play(ev)
	local u = ev.u
	if u.dead then
		return
	end
	local mouth = mouth_of(u.sp)
	if not mouth then
		u.dead = true -- the speaker is gone; so is the rest of the sentence
		return
	end
	for _, l in ipairs(u.listeners) do
		local player = core.get_player_by_name(l.name)
		local ear = player and acoustics.head_pos(player)
		if ear then
			local dx, dy, dz = mouth.x - ear.x, mouth.y - ear.y, mouth.z - ear.z
			local d = math.sqrt(dx * dx + dy * dy + dz * dz)
			local v = math.min(d, NEAR)
			local pos = ear
			if d > 0.01 then
				pos = {x = ear.x + dx / d * v, y = ear.y + dy / d * v, z = ear.z + dz / d * v}
			end
			local loudness = u.gain * (0.35 + 0.65 * (l.clarity or 1))
				* (ev.loud and 1.2 or 1) * (l.muffled and 0.8 or 1)
			-- The engine plays a positional sound at 3 * gain / distance.
			local gain = loudness * math.max(v, 1) / 3
			core.sound_play(sample(u.set, ev.vowel, ev.onset, l.muffled), {
				to_player = l.name,
				pos = pos,
				gain = gain,
				pitch = math.max(0.3, math.min(3, ev.pitch)),
			}, true)
		end
	end
end

core.register_globalstep(function()
	if #queue == 0 then
		return
	end
	local t = now()
	local keep = {}
	for _, ev in ipairs(queue) do
		if ev.time <= t then
			play(ev)
		else
			keep[#keep + 1] = ev
		end
	end
	queue = keep
end)

-- Let a player hear what a pitch sounds like.
function voice.preview(name, pitch)
	local player = core.get_player_by_name(name)
	if not player then
		return
	end
	local sp = {object = player, name = name, player_name = name}
	voice.speak(sp, "Hello there! How does this sound?", PC.modes.say,
		{{name = name, clarity = 1}}, text.hash(name), pitch)
end

return voice
