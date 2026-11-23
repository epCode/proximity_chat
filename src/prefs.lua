-- proximity_chat: each player's own choices, kept in their player metadata.
--
--   bubbles    see speech bubbles over other players
--   voices     hear the babble voices
--   own_voice  hear your own voice when you talk
--   pitch      how high your voice is (0.5 .. 2), chosen from your name at first
--   spy        (chat_spy privilege) read local chat from anywhere

local text = ...

local prefs = {}

local DEFAULTS = {
	bubbles = true,
	voices = true,
	own_voice = true,
	spy = false,
}

prefs.PITCH_MIN = 0.5
prefs.PITCH_MAX = 2

local PREFIX = "proximity_chat:"

-- The voice everyone gets until they pick one: between 0.8 and 1.25, decided
-- by the name, so the same player always sounds the same.
function prefs.default_pitch(name)
	return 0.8 + (text.hash(name) % 1000) / 1000 * 0.45
end

local function meta_of(name)
	local player = core.get_player_by_name(name)
	return player and player:get_meta()
end

function prefs.get(name, key)
	local meta = meta_of(name)
	if key == "pitch" then
		local v = meta and tonumber(meta:get_string(PREFIX .. "pitch"))
		if not v or v ~= v then -- missing, or NaN
			return prefs.default_pitch(name)
		end
		return math.min(prefs.PITCH_MAX, math.max(prefs.PITCH_MIN, v))
	end
	local raw = meta and meta:get_string(PREFIX .. key) or ""
	if raw == "" then
		return DEFAULTS[key]
	end
	return raw == "1"
end

function prefs.set(name, key, value)
	local meta = meta_of(name)
	if not meta then
		return false
	end
	if key == "pitch" then
		value = tonumber(value)
		if not value or value ~= value then -- "nan" is a number to tonumber
			return false
		end
		value = math.min(prefs.PITCH_MAX, math.max(prefs.PITCH_MIN, value))
		meta:set_string(PREFIX .. "pitch", ("%.2f"):format(value))
	elseif value == nil then
		meta:set_string(PREFIX .. key, "")
	else
		meta:set_string(PREFIX .. key, value and "1" or "0")
	end
	return true
end

return prefs
