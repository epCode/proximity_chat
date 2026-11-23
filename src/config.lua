-- proximity_chat: server settings (see settingtypes.txt for what each does).

local settings = core.settings

local function num(key, default, min, max)
	local v = tonumber(settings:get("proximity_chat_" .. key)) or default
	if min then v = math.max(min, v) end
	if max then v = math.min(max, v) end
	return v
end

local function bool(key, default)
	return settings:get_bool("proximity_chat_" .. key, default)
end

local function str(key, default)
	local v = settings:get("proximity_chat_" .. key)
	if v == nil then
		return default
	end
	return v
end

local global_mode = str("global", "priv")
if global_mode ~= "all" and global_mode ~= "priv" and global_mode ~= "off" then
	core.log("warning", "[proximity_chat] proximity_chat_global must be all, priv or off, not '"
		.. global_mode .. "'; using priv")
	global_mode = "priv"
end

return {
	whisper_range = num("whisper_range", 5, 1, 1000),
	say_range = num("say_range", 32, 1, 1000),
	shout_range = num("shout_range", 96, 1, 1000),
	clear_fraction = num("clear_fraction", 0.6, 0, 1),

	occlusion = bool("occlusion", true),
	wall_penalty = num("wall_penalty", 8, 0, 1000),

	shout_prefix = str("shout_prefix", "!"),
	whisper_prefix = str("whisper_prefix", "~"),
	global = global_mode,
	override_me = bool("override_me", true),

	direction_hints = bool("direction_hints", true),
	nobody_heard = bool("nobody_heard", true),
	welcome = bool("welcome", true),

	bubbles = bool("bubbles", true),
	bubbles_through_walls = bool("bubbles_through_walls", false),
	bubble_time = num("bubble_time", 1, 0.2, 10),

	babble = bool("babble", true),
	babble_volume = num("babble_volume", 1, 0, 2),
	babble_max_seconds = num("babble_max_seconds", 3, 0.5, 20),
}
