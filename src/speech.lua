-- proximity_chat: who hears a message, and what they hear.
--
-- For every player online, work out the distance from the speaker's mouth to
-- their ears, add the walls in between (see acoustics.lua), and compare that
-- with the range of the mode. Close enough: they get the message, garbled as
-- much as the distance calls for. Listeners are rounded into a few clarity
-- bands, so players standing together read the very same words in chat and
-- in the bubble.

local PC, config, text, acoustics, modes, prefs, S = ...

local speech = {}

speech.on_speak = {}  -- function(info) -> false to cancel; may change info.message/mode
speech.on_hear = {}   -- function(listener_name, heard)
speech.modifiers = {} -- function(ctx); may change ctx.range, ctx.clear, ctx.effective

local next_id = 0
local hinted = {} -- players told this session how to be heard further away

--------------------------------------------------------------------------------
-- Colors and words
--------------------------------------------------------------------------------

local function rgb(hex)
	local r, g, b = hex:match("^#?(%x%x)(%x%x)(%x%x)")
	if not r then
		return 255, 255, 255
	end
	return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function mix(c1, c2, t)
	local r1, g1, b1 = rgb(c1)
	local r2, g2, b2 = rgb(c2)
	return ("#%02x%02x%02x"):format(
		math.floor(r1 + (r2 - r1) * t + 0.5),
		math.floor(g1 + (g2 - g1) * t + 0.5),
		math.floor(b1 + (b2 - b1) * t + 0.5))
end

local FADED = "#7c7c7c"
local MUFFLED = "#9fb0c8"

-- The color of a message: the mode's own, faded toward grey with distance and
-- tinted cold when it comes through a wall.
function speech.color(mode, band, muffled)
	local c = mode.color or "#ffffff"
	if muffled then
		c = mix(c, MUFFLED, 0.55)
	end
	if band < 1 then
		c = mix(c, FADED, (1 - band) * 0.85)
	end
	return c
end

local DIRECTIONS = {
	ahead = function() return S("ahead of you") end,
	right = function() return S("to your right") end,
	behind = function() return S("behind you") end,
	left = function() return S("to your left") end,
	above = function() return S("above you") end,
	below = function() return S("below you") end,
}

local function format_chat(name, message)
	local ok, line = pcall(core.format_chat_message, name, message)
	if ok and type(line) == "string" then
		return line
	end
	return "<" .. name .. "> " .. message
end
speech.format_chat = format_chat

-- The chat line one listener gets. `r` is what they heard: text, band,
-- muffled and (optionally) direction.
function speech.line(sp, mode, r)
	local body = r.text
	if mode.format == "emote" then
		return core.colorize(speech.color(mode, r.band, r.muffled), "* " .. sp.name .. " " .. body)
	elseif mode.format == "global" then
		return core.colorize(mode.color, "[" .. S("Global") .. "] " .. format_chat(sp.name, body))
	end
	local tags = {}
	local tag = mode.tag and mode.tag()
	if tag then
		tags[#tags + 1] = tag
	end
	if r.muffled then
		tags[#tags + 1] = S("muffled")
	elseif r.band < 1 then
		tags[#tags + 1] = S("far away")
	end
	if r.direction and (r.band < 1 or r.muffled) then
		tags[#tags + 1] = DIRECTIONS[r.direction]()
	end
	if #tags > 0 then
		body = "(" .. table.concat(tags, ", ") .. ") " .. body
	end
	local line = format_chat(sp.name, body)
	if r.band >= 1 and not r.muffled and (mode.color or "#ffffff"):lower() == "#ffffff" then
		return line -- plain talk looks exactly like ordinary chat
	end
	return core.colorize(speech.color(mode, r.band, r.muffled), line)
end

--------------------------------------------------------------------------------
-- Speakers
--------------------------------------------------------------------------------

-- A name given by a mod, made safe to show: no escapes, and no "@", which
-- core.format_chat_message would take for a placeholder.
local function clean_name(name)
	name = text.clean(name):gsub("@", "")
	return name ~= "" and name or nil
end

-- Who is talking: a player name, a player or entity ObjectRef, or a position.
-- Entities and positions go by the name the calling mod gives them (never by
-- their nametag, which players can often set: a pet named "admin" mustn't
-- look like a player talking), "Someone" otherwise.
local function resolve(speaker, opts)
	local kind = type(speaker)
	local given = opts.name and clean_name(tostring(opts.name))
	if kind == "string" then
		local player = core.get_player_by_name(speaker)
		if not player then
			return nil
		end
		return {object = player, name = given or speaker, player_name = speaker,
			key = speaker}
	elseif kind == "table" and type(speaker.x) == "number" and not speaker.get_pos then
		return {pos = vector.new(speaker), name = given or S("Someone"), key = false}
	elseif (kind == "userdata" or kind == "table") and speaker.get_pos and speaker:get_pos() then
		if speaker:is_player() then
			local pname = speaker:get_player_name()
			return {object = speaker, name = given or pname, player_name = pname, key = pname}
		end
		return {object = speaker, name = given or S("Someone"), key = speaker}
	end
	return nil
end

local function mouth_of(sp)
	if sp.object then
		return acoustics.head_pos(sp.object)
	end
	return sp.pos
end
speech.mouth_of = mouth_of

--------------------------------------------------------------------------------
-- Hearing
--------------------------------------------------------------------------------

-- What `player` (an ObjectRef, or nil with `ear` given) hears of something
-- said at `mouth`, or nil if nothing.
local function listen(sp, mode, mouth, player, range, clear, ear)
	ear = ear or acoustics.head_pos(player)
	if not ear then
		return nil
	end
	local r = {ear = ear, distance = vector.distance(mouth, ear), walls = 0}
	if mode.global then
		r.clarity, r.band, r.band_index, r.effective = 1, 1, 1, r.distance
		return r
	end

	local penalty, extra = config.wall_penalty, 0
	if #speech.modifiers > 0 then
		-- Other mods' say: megaphones, earmuffs, radios...
		local ctx = {speaker = sp.name, speaker_object = sp.object, listener = player,
			listener_name = player and player:get_player_name() or "", mode = mode.name,
			distance = r.distance, range = range, clear = clear, wall_penalty = penalty,
			extra = 0}
		for _, modifier in ipairs(speech.modifiers) do
			modifier(ctx)
		end
		if ctx.deaf then
			return nil
		end
		local new_range = tonumber(ctx.range) or range
		if ctx.clear == clear and new_range ~= range then
			clear = clear * new_range / range -- keep the same proportion
		else
			clear = tonumber(ctx.clear) or clear
		end
		range = new_range
		clear = math.min(clear, range)
		penalty = tonumber(ctx.wall_penalty) or penalty
		extra = tonumber(ctx.extra) or 0
	end
	if r.distance + extra > range then
		return nil
	end

	if mode.occlusion and config.occlusion and (mode.walls_block or penalty > 0) then
		local limit
		if mode.walls_block then
			limit = 0.99
		elseif penalty > 0 then
			limit = (range - r.distance - extra) / penalty
		end
		r.walls = acoustics.obstruction(mouth, ear, limit)
	end
	if mode.walls_block then
		if r.walls >= 1 then
			return nil
		end
		r.effective = r.distance + extra
	else
		r.effective = r.distance + extra + r.walls * penalty
	end

	r.clarity = acoustics.clarity(r.effective, range, clear)
	if not r.clarity then
		return nil
	end
	if not mode.garble then
		r.clarity = 1
	end
	r.band, r.band_index = acoustics.band(r.clarity)
	r.muffled = r.walls >= 0.5 and not mode.walls_block
	return r
end

--------------------------------------------------------------------------------
-- Speaking
--------------------------------------------------------------------------------

local function run_on_speak(info)
	for _, callback in ipairs(speech.on_speak) do
		if callback(info) == false then
			return false
		end
	end
	return true
end

-- Say `message` as `speaker` (see resolve) in mode `mode_name`. Returns how
-- many players heard it, or nil and a reason.
function speech.speak(speaker, message, mode_name, opts)
	opts = opts or {}
	local mode = modes.registered[mode_name or "say"]
	if not mode then
		return nil, "unknown mode: " .. tostring(mode_name)
	end
	local sp = resolve(speaker, opts)
	if not sp then
		return nil, "no such speaker"
	end
	local msg = text.clean(message)
	if msg == "" then
		return nil, "empty message"
	end

	local info = {name = sp.name, player_name = sp.player_name, object = sp.object,
		message = msg, mode = mode.name}
	if not run_on_speak(info) then
		return nil, "cancelled"
	end
	msg = text.clean(info.message)
	mode = modes.registered[info.mode] or mode
	if msg == "" then
		return nil, "empty message"
	end

	local mouth = mouth_of(sp)
	if not mouth then
		return nil, "speaker has no position"
	end
	next_id = next_id + 1
	local id = next_id
	local range, clear = modes.ranges(mode)
	if opts.range then
		range = opts.range
		clear = math.min(opts.clear or opts.range * config.clear_fraction, range)
	end

	-- An entity shown only to some players (set_observers) is only heard by
	-- them.
	local audience
	if sp.object and not sp.player_name and sp.object.get_observers
			and sp.object:get_observers() ~= nil then
		audience = sp.object:get_effective_observers()
	end

	-- Everyone who hears it, and the few versions they hear.
	local heard, heard_by = {}, {}
	local versions = {}
	local players = core.get_connected_players()
	for _, player in ipairs(players) do
		local lname = player:get_player_name()
		if lname ~= sp.player_name and (not audience or audience[lname]) then
			local r = listen(sp, mode, mouth, player, range, clear)
			if r then
				r.name, r.player = lname, player
				local vkey = r.band_index .. (r.muffled and "m" or "")
				if not versions[vkey] then
					local seed = id * 97 + r.band_index * 13 + (r.muffled and 5 or 0)
					versions[vkey] = text.garble(msg, r.band, seed, r.muffled)
				end
				r.text = versions[vkey]
				if config.direction_hints and not mode.global then
					r.direction = acoustics.direction(r.ear, player:get_look_horizontal(), mouth)
				end
				heard[#heard + 1] = r
				heard_by[lname] = r
			end
		end
	end

	for _, r in ipairs(heard) do
		core.chat_send_player(r.name, speech.line(sp, mode, r))
	end

	-- The speaker sees what they said, and whether anyone heard it.
	local own = {text = msg, band = 1, clarity = 1}
	if sp.player_name then
		local line = speech.line(sp, mode, own)
		if #heard == 0 and config.nobody_heard and not mode.global and #players > 1 then
			line = line .. core.colorize("#9a9a9a", "  (" .. S("nobody heard you") .. ")")
			if not hinted[sp.player_name] and mode.name ~= "shout" and modes.registered.shout then
				hinted[sp.player_name] = true
				core.after(0, core.chat_send_player, sp.player_name, core.colorize("#9a9a9a",
					PC.help_line(sp.player_name)))
			end
		end
		core.chat_send_player(sp.player_name, line)
	end

	-- Moderators reading along.
	if not mode.global then
		for _, player in ipairs(players) do
			local pname = player:get_player_name()
			local r = heard_by[pname]
			if pname ~= sp.player_name and (not r or r.band < 1 or r.muffled)
					and prefs.get(pname, "spy") and core.check_player_privs(pname, {chat_spy = true}) then
				core.chat_send_player(pname, core.colorize("#8a8a8a",
					"[" .. S("spy") .. "] " .. core.strip_colors(speech.line(sp, mode, own))))
			end
		end
	end

	if PC.bubbles and config.bubbles and mode.bubble and sp.object then
		local viewers = {}
		for _, r in ipairs(heard) do
			if (not r.muffled or config.bubbles_through_walls) and prefs.get(r.name, "bubbles") then
				viewers[r.name] = {text = r.text, color = speech.color(mode, r.band, r.muffled)}
			end
		end
		if sp.player_name and prefs.get(sp.player_name, "bubbles") then
			viewers[sp.player_name] = {text = msg, color = speech.color(mode, 1, false)}
		end
		PC.bubbles.add(sp, mode, viewers, text.length(msg))
	end

	if PC.voice and config.babble and mode.babble then
		local listeners = {}
		for _, r in ipairs(heard) do
			if prefs.get(r.name, "voices") then
				listeners[#listeners + 1] = {name = r.name, clarity = r.clarity, muffled = r.muffled}
			end
		end
		if sp.player_name and prefs.get(sp.player_name, "voices")
				and prefs.get(sp.player_name, "own_voice") then
			listeners[#listeners + 1] = {name = sp.player_name, clarity = 1, own = true}
		end
		if #listeners > 0 then
			PC.voice.speak(sp, msg, mode, listeners, id, opts.pitch)
		end
	end

	for _, r in ipairs(heard) do
		local heard_info = {speaker = sp.name, speaker_object = sp.object, message = r.text,
			original = msg, mode = mode.name, clarity = r.clarity, band = r.band,
			muffled = r.muffled, distance = r.distance}
		for _, callback in ipairs(speech.on_hear) do
			callback(r.name, heard_info)
		end
	end

	core.log("action", ("CHAT: %s [%s, heard by %d]"):format(
		core.strip_escapes(format_chat(sp.name, msg)), mode.name, #heard))
	return #heard
end

-- How well `listener` would hear `speaker` (each a player name, ObjectRef or
-- position) in a mode, by exactly the rules speak() uses: clarity (0..1, nil
-- if out of earshot), muffled, effective distance.
function speech.hearing(speaker, listener, mode_name)
	local mode = modes.registered[mode_name or "say"]
	local sp = mode and resolve(speaker, {})
	local mouth = sp and mouth_of(sp)
	if not mouth then
		return nil
	end
	local player, ear
	if type(listener) == "string" then
		player = core.get_player_by_name(listener)
	elseif type(listener) == "table" and type(listener.x) == "number" and not listener.get_pos then
		ear = listener
	else
		player = listener
	end
	if not ear and not (player and player.get_pos and player:get_pos()) then
		return nil
	end
	local range, clear = modes.ranges(mode)
	local r = listen(sp, mode, mouth, player, range, clear, ear)
	if not r then
		return nil, false
	end
	return r.clarity, r.muffled, r.effective
end

-- Split a typed message into its mode and the words: "!help" shouts "help".
function speech.parse(message)
	for _, p in ipairs({{config.shout_prefix, "shout"}, {config.whisper_prefix, "whisper"}}) do
		local prefix, mode = p[1], p[2]
		if prefix ~= "" and modes.registered[mode] and message:sub(1, #prefix) == prefix then
			local rest = message:sub(#prefix + 1):gsub("^%s+", "")
			if rest ~= "" then
				return mode, rest
			end
		end
	end
	return "say", message
end

-- The on_chat_message callback: everything typed that isn't a command.
function speech.on_chat_message(name, message)
	if message:sub(1, 1) == "/" then
		return false
	end
	if not core.get_player_by_name(name) then
		-- Not a player in the world: the server's terminal console. Let the
		-- engine send it to everyone as before.
		return false
	end
	if not core.check_player_privs(name, {shout = true}) then
		-- The engine checks this only after mods have had the message.
		core.chat_send_player(name, "-!- " .. S("You don't have permission to shout."))
		return true
	end
	local mode, words = speech.parse(message)
	speech.speak(name, words, mode)
	return true
end

function speech.forget(name)
	hinted[name] = nil
end

return speech
