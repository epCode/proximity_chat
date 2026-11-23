-- proximity_chat: the ways a message can be said.
--
-- A mode decides how far a message carries and how it looks and sounds.
-- Other mods can add their own with proximity_chat.register_mode (see the
-- README for the fields).

local config, S = ...

local modes = {}

modes.registered = {}

local DEFAULTS = {
	range = 32,          -- nodes; nil or math.huge with global = true
	clear = nil,         -- heard perfectly up to here (default: range * clear_fraction)
	garble = true,       -- letters drop out beyond `clear`
	occlusion = true,    -- walls count as extra distance
	walls_block = false, -- any wall at all stops it (for things you see, not hear)
	global = false,      -- everyone on the server gets it, wherever they are
	color = "#ffffff",   -- chat and bubble text color
	tag = nil,           -- function returning e.g. "shouts", shown in brackets
	format = "say",      -- "say" (<name> text), "emote" (* name text) or "global"
	bubble = true,       -- show it over the speaker's head
	babble = "talk",     -- voice sample set (talk, shout, whisper) or false
	babble_gain = 0.7,
}

function modes.register(name, def)
	assert(type(name) == "string" and name ~= "", "mode name must be a string")
	local mode = {}
	for k, v in pairs(DEFAULTS) do
		mode[k] = v
	end
	for k, v in pairs(def or {}) do
		mode[k] = v
	end
	mode.name = name
	modes.registered[name] = mode
	return mode
end

-- Range and clear radius of a mode, with defaults filled in.
function modes.ranges(mode)
	local range = mode.range or math.huge
	local clear = mode.clear or range * config.clear_fraction
	return range, math.min(clear, range)
end

modes.register("say", {
	range = config.say_range,
	color = "#ffffff",
})

modes.register("whisper", {
	range = config.whisper_range,
	color = "#c9b8ff",
	tag = function() return S("whispers") end,
	babble = "whisper",
	babble_gain = 0.55,
})

modes.register("shout", {
	range = config.shout_range,
	color = "#ffc35c",
	tag = function() return S("shouts") end,
	babble = "shout",
	babble_gain = 0.95,
})

modes.register("emote", {
	range = config.say_range,
	garble = false,
	walls_block = true,
	color = "#f0e2a0",
	format = "emote",
	babble = false,
})

modes.register("global", {
	range = nil,
	global = true,
	garble = false,
	occlusion = false,
	color = "#8fd8ff",
	format = "global",
	bubble = false,
	babble = false,
})

return modes
