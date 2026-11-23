-- Proximity Chat: what you say is heard by the people near you.
--
-- Chat reaches only players within earshot. The further away they are, the
-- fewer letters they make out, and walls muffle your voice like extra
-- distance. You can whisper (~), talk, shout (!), act (/me) and, with the
-- right privilege, speak to everyone (/g). What people say also shows up as a
-- speech bubble over their head, written the way each onlooker heard it, and
-- they speak it out loud with a babble voice of their own that comes from
-- where they stand.
--
-- Everything is a plain server mod: no client mod, no external program, any
-- game.
--
--   src/text.lua       UTF-8 text: garbling, wrapping, syllables (no engine calls)
--   src/acoustics.lua  distance, walls and clarity
--   src/modes.lua      whisper, say, shout, emote, global (+ ones mods add)
--   src/speech.lua     who hears a message and what they read
--   src/bubbles.lua    speech bubbles
--   src/voice.lua      babble voices
--   src/commands.lua   commands, the /pchat window, taking over chat

proximity_chat = {}
local PC = proximity_chat

local modname = core.get_current_modname()
local modpath = core.get_modpath(modname)
local S = core.get_translator(modname)

local function load(file, ...)
	return assert(loadfile(modpath .. "/src/" .. file .. ".lua"))(...)
end

local text = load("text")
local config = load("config")
local acoustics = load("acoustics")
local prefs = load("prefs", text)
local modes = load("modes", config, S)
local speech = load("speech", PC, config, text, acoustics, modes, prefs, S)

PC.config = config
PC.text = text
PC.acoustics = acoustics
PC.modes = modes.registered
PC.bubbles = load("bubbles", PC, config, text)
PC.voice = load("voice", PC, config, text, acoustics, prefs)

--------------------------------------------------------------------------------
-- API (see README.md)
--------------------------------------------------------------------------------

-- Say something as a player (name or ObjectRef), any entity, or a position.
-- mode: "say" (default), "whisper", "shout", "emote", "global" or a mode a mod
-- registered. opts: name (who it's from, for entities and positions), pitch,
-- range, clear. Returns how many players heard it, or nil and a reason.
function PC.speak(speaker, message, mode, opts)
	return speech.speak(speaker, message, mode, opts)
end

function PC.register_mode(name, def)
	return modes.register(name, def)
end

-- function(info): info.name, info.player_name, info.object, info.message,
-- info.mode. Return false to stop the message; change info.message or
-- info.mode to change it.
function PC.register_on_speak(callback)
	table.insert(speech.on_speak, callback)
end

-- function(listener_name, heard): heard.speaker, heard.message (what they
-- read), heard.original, heard.mode, heard.clarity, heard.muffled, heard.distance.
function PC.register_on_hear(callback)
	table.insert(speech.on_hear, callback)
end

-- function(ctx), called for each speaker/listener pair: ctx.speaker,
-- ctx.speaker_object, ctx.listener, ctx.listener_name, ctx.mode,
-- ctx.distance. Change ctx.range, ctx.clear, ctx.wall_penalty or ctx.extra
-- (extra distance), or set ctx.deaf = true.
function PC.register_hearing_modifier(callback)
	table.insert(speech.modifiers, callback)
end

-- How well `listener` would hear `speaker` (player names, ObjectRefs or
-- positions) in a mode, by the same rules as speak(): clarity (0..1, nil if
-- out of earshot), muffled, effective distance.
function PC.hearing(speaker, listener, mode_name)
	return speech.hearing(speaker, listener, mode_name)
end

function PC.get_pref(name, key)
	return prefs.get(name, key)
end

function PC.set_pref(name, key, value)
	return prefs.set(name, key, value)
end

PC.parse = speech.parse

load("commands", PC, config, text, modes, prefs, speech, S)
