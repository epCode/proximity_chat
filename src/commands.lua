-- proximity_chat: chat commands, the /pchat window, and taking over chat.

local PC, config, text, modes, prefs, speech, S = ...

local FORMNAME = "proximity_chat:settings"
local ranges = {}
for _, m in ipairs({"whisper", "say", "shout"}) do
	ranges[m] = math.floor(modes.ranges(modes.registered[m]) + 0.5)
end

local function can_global(name)
	if config.global == "off" then
		return false
	end
	return config.global == "all" or core.check_player_privs(name, {global_chat = true})
end
PC.can_global = can_global

-- One line telling a player how to be heard further away.
function PC.help_line(name)
	local parts = {S("Only players near you can hear you.")}
	if config.shout_prefix ~= "" then
		parts[#parts + 1] = S("Start a message with @1 to shout.", config.shout_prefix)
	end
	if can_global(name) and core.registered_chatcommands.g then
		parts[#parts + 1] = S("Use /g to talk to everyone.")
	end
	parts[#parts + 1] = S("More in /pchat.")
	return table.concat(parts, " ")
end

--------------------------------------------------------------------------------
-- Taking over chat
--------------------------------------------------------------------------------

-- Registered last, once every mod has loaded, so that mods which mute, filter,
-- count or log chat (xban, filter, awards...) still see each message first.
core.register_on_mods_loaded(function()
	local before = {}
	for _, callback in ipairs(core.registered_on_chat_messages) do
		local origin = core.callback_origins and core.callback_origins[callback]
		local mod = origin and origin.mod
		if mod and mod ~= "??" and mod ~= "*builtin*" and mod ~= "proximity_chat" then
			before[#before + 1] = mod
		end
	end
	core.register_on_chat_message(speech.on_chat_message)
	if #before > 0 then
		core.log("action", "[proximity_chat] these mods see chat messages before proximity "
			.. "chat does (if one of them consumes a message, it won't be proximity chat): "
			.. table.concat(before, ", "))
	end
end)

--------------------------------------------------------------------------------
-- Commands for the modes
--------------------------------------------------------------------------------

local function mode_command(mode)
	return function(name, param)
		if param:gsub("%s", "") == "" then
			return false
		end
		local heard, err = speech.speak(name, param, mode)
		if not heard and err ~= "cancelled" then
			return false, err
		end
		return true
	end
end

local function register_free(names, def)
	for _, cmd in ipairs(names) do
		if not core.registered_chatcommands[cmd] then
			core.register_chatcommand(cmd, table.copy(def))
		else
			core.log("info", "[proximity_chat] /" .. cmd .. " is taken by another mod; not registered")
		end
	end
end

if not core.registered_privileges.global_chat then
	core.register_privilege("global_chat", {
		description = S("Can talk to everyone on the server with /g"),
		give_to_singleplayer = true,
		give_to_admin = true,
	})
end

if not core.registered_privileges.chat_spy then
	core.register_privilege("chat_spy", {
		description = S("Can read all nearby chat (turn on with /pchat spy on)"),
		give_to_singleplayer = false,
		give_to_admin = true,
	})
end

if config.global ~= "off" then
	local privs = {shout = true}
	if config.global == "priv" then
		privs.global_chat = true
	end
	register_free({"g", "global"}, {
		params = S("<message>"),
		description = S("Say something to everyone on the server"),
		privs = privs,
		func = mode_command("global"),
	})
end

register_free({"shout"}, {
	params = S("<message>"),
	description = S("Shout, so people further away hear you (up to @1 nodes)", ranges.shout),
	privs = {shout = true},
	func = mode_command("shout"),
})

register_free({"whisper"}, {
	params = S("<message>"),
	description = S("Whisper, so only people right next to you hear (up to @1 nodes)", ranges.whisper),
	privs = {shout = true},
	func = mode_command("whisper"),
})

if config.override_me and core.registered_chatcommands.me and core.override_chatcommand then
	core.override_chatcommand("me", {
		description = S("Do something that people nearby see (e.g. /me waves)"),
		func = mode_command("emote"),
	})
end

--------------------------------------------------------------------------------
-- The /pchat window
--------------------------------------------------------------------------------

local function esc(s)
	return core.formspec_escape(s)
end

local function help_text(name)
	local lines = {
		S("Only people near you hear what you say. The further away they are, the "
			.. "less they make out, and walls muffle you like extra distance."),
		"",
		S("Talk: just type. Heard up to @1 nodes away.", ranges.say),
	}
	if config.shout_prefix ~= "" then
		lines[#lines + 1] = S("Shout: start with @1 (or /shout). Heard up to @2 nodes away.",
			config.shout_prefix, ranges.shout)
	end
	if config.whisper_prefix ~= "" then
		lines[#lines + 1] = S("Whisper: start with @1 (or /whisper). Heard up to @2 nodes away.",
			config.whisper_prefix, ranges.whisper)
	end
	if config.override_me then
		lines[#lines + 1] = S("Act: /me waves. Seen by people nearby who can see you.")
	end
	if can_global(name) and core.registered_chatcommands.g then
		lines[#lines + 1] = S("Everyone: /g message reaches the whole server.")
	end
	lines[#lines + 1] = S("Private: /msg name message, as always.")
	return table.concat(lines, "\n")
end

local function show_settings(name)
	local pitch = prefs.get(name, "pitch")
	local spy = core.check_player_privs(name, {chat_spy = true})
	local fs = {
		"formspec_version[6]",
		"size[11,10.4]",
		"label[0.5,0.6;", esc(S("Proximity chat")), "]",
		"textarea[0.5,1;10,4.6;;;", esc(help_text(name)), "]",
		"checkbox[0.5,6.1;bubbles;", esc(S("Show speech bubbles over people talking")), ";",
			tostring(prefs.get(name, "bubbles")), "]",
		"checkbox[0.5,6.7;voices;", esc(S("Hear people's voices")), ";",
			tostring(prefs.get(name, "voices")), "]",
		"checkbox[0.5,7.3;own_voice;", esc(S("Hear my own voice")), ";",
			tostring(prefs.get(name, "own_voice")), "]",
		"label[0.5,8.1;", esc(S("My voice: low to high")), "]",
		"scrollbaroptions[min=50;max=200;smallstep=5;largestep=25]",
		("scrollbar[0.5,8.4;6.8,0.6;horizontal;pitch;%d]"):format(math.floor(pitch * 100 + 0.5)),
		"button[7.7,8.3;2.8,0.8;test;", esc(S("Try it")), "]",
	}
	if spy then
		fs[#fs + 1] = "checkbox[0.5,9.8;spy;" .. esc(S("Spy: read all nearby chat on the server")) .. ";"
			.. tostring(prefs.get(name, "spy")) .. "]"
	end
	fs[#fs + 1] = "button_exit[8.3,9.4;2.2,0.8;close;" .. esc(S("Close")) .. "]"
	core.show_formspec(name, FORMNAME, table.concat(fs))
end
PC.show_settings = show_settings

core.register_on_player_receive_fields(function(player, formname, fields)
	if formname ~= FORMNAME then
		return false
	end
	local name = player:get_player_name()
	for _, key in ipairs({"bubbles", "voices", "own_voice"}) do
		if fields[key] then
			prefs.set(name, key, fields[key] == "true")
		end
	end
	if fields.spy and core.check_player_privs(name, {chat_spy = true}) then
		prefs.set(name, "spy", fields.spy == "true")
	end
	if fields.pitch then
		local value = tonumber(fields.pitch:match("^%u+:(%d+)$"))
		if value then
			prefs.set(name, "pitch", value / 100)
		end
	end
	if fields.test then
		PC.voice.preview(name, prefs.get(name, "pitch"))
	end
	return true
end)

local ON = {on = true, yes = true, ["true"] = true, ["1"] = true}
local OFF = {off = true, no = true, ["false"] = true, ["0"] = true}

local function toggle(name, key, arg, on_msg, off_msg)
	local value
	if ON[arg] then
		value = true
	elseif OFF[arg] then
		value = false
	elseif arg == "" then
		value = not prefs.get(name, key)
	else
		return false, S("Say on or off.")
	end
	if not prefs.set(name, key, value) then
		return false, S("You need to be online.")
	end
	return true, value and on_msg or off_msg
end

core.register_chatcommand("pchat", {
	params = "[bubbles|voices|ownvoice|spy [on|off]] | [pitch <50-200>] | [help]",
	description = S("Proximity chat: how it works, and your settings"),
	func = function(name, param)
		local cmd, arg = param:match("^%s*(%S*)%s*(.-)%s*$")
		cmd, arg = cmd:lower(), arg:lower()
		if cmd == "" then
			if not core.get_player_by_name(name) then
				return true, help_text(name)
			end
			show_settings(name)
			return true
		elseif cmd == "help" then
			return true, help_text(name)
		elseif cmd == "bubbles" then
			return toggle(name, "bubbles", arg, S("You see speech bubbles."),
				S("You don't see speech bubbles."))
		elseif cmd == "voices" or cmd == "voice" then
			return toggle(name, "voices", arg, S("You hear voices."), S("You don't hear voices."))
		elseif cmd == "ownvoice" then
			return toggle(name, "own_voice", arg, S("You hear your own voice."),
				S("You don't hear your own voice."))
		elseif cmd == "spy" then
			if not core.check_player_privs(name, {chat_spy = true}) then
				return false, S("You need the chat_spy privilege.")
			end
			return toggle(name, "spy", arg, S("You read all nearby chat."),
				S("You only read chat you can hear."))
		elseif cmd == "pitch" then
			if arg == "" then
				return true, S("Your voice pitch is @1.", math.floor(prefs.get(name, "pitch") * 100 + 0.5))
			end
			local value = tonumber(arg)
			if not value or value ~= value then
				return false, S("Give a number from 50 (low) to 200 (high).")
			end
			if value > 5 then
				value = value / 100 -- 120 means 1.2
			end
			if not core.get_player_by_name(name) then
				return false, S("You need to be online.")
			end
			prefs.set(name, "pitch", value)
			PC.voice.preview(name, prefs.get(name, "pitch"))
			return true, S("Your voice pitch is @1.", math.floor(prefs.get(name, "pitch") * 100 + 0.5))
		end
		return false
	end,
})

--------------------------------------------------------------------------------
-- Joining and leaving
--------------------------------------------------------------------------------

core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	if config.welcome and not prefs.get(name, "welcomed") then
		prefs.set(name, "welcomed", true)
		core.after(3, function()
			if core.get_player_by_name(name) then
				core.chat_send_player(name, core.colorize("#9ad0ff",
					S("This server has proximity chat.") .. " " .. PC.help_line(name)))
			end
		end)
	end
end)

core.register_on_leaveplayer(function(player)
	speech.forget(player:get_player_name())
end)
