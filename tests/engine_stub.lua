-- Just enough of the Luanti server API to load proximity_chat and drive it
-- from plain Lua: players are tables at positions, the map is a table of
-- nodes, and everything the mod sends (chat, sounds, entities) is recorded.
local here = ...
local stub = {
	chat = {},        -- {to = name, text = line}
	sounds = {},      -- {name = sample, params = table}
	entities = {},    -- every entity ever added
	formspecs = {},
	time = 1000,      -- seconds
	nodes = {},       -- "x,y,z" -> node name
	settings = {},
	privs = {},       -- name -> set
	globalsteps = {},
	afters = {},
}

local function key(x, y, z)
	return x .. "," .. y .. "," .. z
end

function stub.set_node(x, y, z, name)
	stub.nodes[key(x, y, z)] = name
end

function stub.wall(x, y1, y2, z1, z2, name)
	for y = y1, y2 do
		for z = z1, z2 do
			stub.set_node(x, y, z, name or "default:stone")
		end
	end
end

-- Object methods shared by players and entities.
local Object = {}
Object.__index = Object
function Object:get_pos()
	if self.removed then return nil end
	if self.attached then
		local p = self.attached.parent:get_pos()
		return p and {x = p.x, y = p.y, z = p.z}
	end
	return {x = self.pos.x, y = self.pos.y, z = self.pos.z}
end
function Object:is_player() return self.player_name ~= nil end
function Object:get_player_name() return self.player_name or "" end
function Object:get_properties() return self.props end
function Object:set_properties(p)
	for k, v in pairs(p) do self.props[k] = v end
	self.prop_updates = (self.prop_updates or 0) + 1
end
function Object:get_look_horizontal() return self.yaw or 0 end
function Object:get_meta() return self.meta end
function Object:get_nametag_attributes()
	return {text = self.props.nametag or "", color = self.nametag_color or {a = 255, r = 255, g = 255, b = 255}}
end
function Object:set_observers(set)
	local copy = {}
	for k in pairs(set or {}) do copy[k] = true end
	self.observers = copy
end
function Object:set_attach(parent, bone, pos, rot)
	self.attached = {parent = parent, bone = bone, pos = pos, rot = rot}
end
function Object:get_attach()
	if self.attached then return self.attached.parent end
end
function Object:remove() self.removed = true end
function Object:set_armor_groups() end
function Object:get_luaentity() return self.luaentity end

local function new_meta()
	local data = {}
	return {
		get_string = function(_, k) return data[k] or "" end,
		set_string = function(_, k, v) data[k] = v ~= "" and v or nil end,
	}
end

stub.players = {}

function stub.add_player(name, x, y, z, yaw)
	local p = setmetatable({
		player_name = name,
		pos = {x = x, y = y, z = z},
		yaw = yaw or 0,
		meta = new_meta(),
		props = {eye_height = 1.625, selectionbox = {-0.3, 0, -0.3, 0.3, 1.77, 0.3},
			visual_size = {x = 1, y = 1, z = 1}, nametag = ""},
	}, Object)
	stub.players[#stub.players + 1] = p
	stub.privs[name] = stub.privs[name] or {shout = true, interact = true}
	for _, cb in ipairs(stub.on_join) do cb(p) end
	return p
end

function stub.remove_player(name)
	for i, p in ipairs(stub.players) do
		if p.player_name == name then
			table.remove(stub.players, i)
			for _, cb in ipairs(stub.on_leave) do cb(p) end
			p.removed = true
			return
		end
	end
end

function stub.add_object(x, y, z, props)
	local o = setmetatable({pos = {x = x, y = y, z = z}, props = props or {}}, Object)
	return o
end

function stub.lines_for(name)
	local out = {}
	for _, c in ipairs(stub.chat) do
		if c.to == name then out[#out + 1] = c.text end
	end
	return out
end

function stub.clear()
	stub.chat, stub.sounds, stub.formspecs = {}, {}, {}
end

function stub.step(seconds, dt)
	dt = dt or 0.05
	local t = 0
	while t < seconds - 1e-9 do
		stub.time = stub.time + dt
		t = t + dt
		for _, f in ipairs(stub.globalsteps) do f(dt) end
		local due = stub.afters
		stub.afters = {}
		for _, a in ipairs(due) do
			if a.time <= stub.time then a.f(unpack(a.args)) else stub.afters[#stub.afters + 1] = a end
		end
	end
end

function stub.strip(s)
	return (s:gsub("\27%([^)]*%)", ""):gsub("\27.", ""))
end

stub.on_join, stub.on_leave = {}, {}
local chatcommands, privileges = {}, {}

unpack = unpack or table.unpack
table.copy = table.copy or function(t)
	local c = {}
	for k, v in pairs(t) do c[k] = type(v) == "table" and table.copy(v) or v end
	return c
end

vector = {
	new = function(a, b, c)
		if type(a) == "table" then return {x = a.x, y = a.y, z = a.z} end
		return {x = a, y = b, z = c}
	end,
	distance = function(a, b)
		local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
		return math.sqrt(dx * dx + dy * dy + dz * dz)
	end,
}

core = {
	settings = {
		get = function(_, k) return stub.settings[k] end,
		get_bool = function(_, k, d)
			local v = stub.settings[k]
			if v == nil then return d end
			return v == true or v == "true"
		end,
	},
	get_current_modname = function() return "proximity_chat" end,
	get_modpath = function() return here end,
	get_translator = function()
		return function(s, ...)
			local args = {...}
			return (s:gsub("@(%d)", function(n) return tostring(args[tonumber(n)]) end))
		end
	end,
	log = function(level, msg) stub.last_log = msg end,
	colorize = function(color, s) return "\27(c@" .. color .. ")" .. s .. "\27(c@#fff)" end,
	get_color_escape_sequence = function(color) return "\27(c@" .. color .. ")" end,
	strip_colors = function(s) return (s:gsub("\27%([bc]@[^)]+%)", "")) end,
	format_chat_message = function(name, msg) return "<" .. name .. "> " .. msg end,
	chat_send_player = function(name, s) stub.chat[#stub.chat + 1] = {to = name, text = s} end,
	get_connected_players = function()
		local t = {}
		for i, p in ipairs(stub.players) do t[i] = p end
		return t
	end,
	get_player_by_name = function(name)
		for _, p in ipairs(stub.players) do
			if p.player_name == name then return p end
		end
	end,
	check_player_privs = function(name, req)
		local have = stub.privs[name] or {}
		for k in pairs(req) do
			if not have[k] then return false end
		end
		return true
	end,
	get_node_or_nil = function(pos)
		return {name = stub.nodes[key(pos.x, pos.y, pos.z)] or "air"}
	end,
	registered_nodes = {
		["default:stone"] = {walkable = true, drawtype = "normal", groups = {}},
		["default:glass"] = {walkable = true, drawtype = "glasslike", groups = {}},
		["wool:white"] = {walkable = true, drawtype = "normal", groups = {wool = 1}},
		["default:water_source"] = {walkable = false, drawtype = "liquid", liquidtype = "source", groups = {}},
		air = {walkable = false, drawtype = "airlike", groups = {}},
	},
	register_entity = function(name, def) stub.entity_def = def end,
	add_entity = function(pos, name)
		local o = setmetatable({pos = {x = pos.x, y = pos.y, z = pos.z}, name = name,
			props = table.copy(stub.entity_def.initial_properties)}, Object)
		stub.entities[#stub.entities + 1] = o
		return o
	end,
	register_globalstep = function(f) stub.globalsteps[#stub.globalsteps + 1] = f end,
	register_on_joinplayer = function(f) stub.on_join[#stub.on_join + 1] = f end,
	register_on_leaveplayer = function(f) stub.on_leave[#stub.on_leave + 1] = f end,
	register_on_mods_loaded = function(f) stub.mods_loaded = stub.mods_loaded or {}; table.insert(stub.mods_loaded, f) end,
	registered_on_chat_messages = {},
	callback_origins = {},
	register_on_chat_message = function(f) table.insert(core.registered_on_chat_messages, f) end,
	register_on_player_receive_fields = function(f) stub.receive_fields = f end,
	registered_chatcommands = chatcommands,
	register_chatcommand = function(name, def) chatcommands[name] = def end,
	override_chatcommand = function(name, def)
		for k, v in pairs(def) do chatcommands[name][k] = v end
	end,
	registered_privileges = privileges,
	register_privilege = function(name, def) privileges[name] = def end,
	get_us_time = function() return math.floor(stub.time * 1e6) end,
	sound_play = function(name, params) stub.sounds[#stub.sounds + 1] = {name = name, params = params} end,
	after = function(t, f, ...) stub.afters[#stub.afters + 1] = {time = stub.time + t, f = f, args = {...}} end,
	show_formspec = function(name, formname, fs) stub.formspecs[#stub.formspecs + 1] = {to = name, name = formname, fs = fs} end,
	formspec_escape = function(s) return (s:gsub("[%[%];,\\]", "\\%0")) end,
}
core.strip_escapes = stub.strip

-- A builtin-like /me to override, and the builtin chat command handler.
chatcommands.me = {func = function() end, privs = {shout = true}}

function stub.load()
	dofile(here .. "/init.lua")
	for _, f in ipairs(stub.mods_loaded or {}) do f() end
end

-- Send a chat message the way the engine does: callbacks in order until one
-- returns true; otherwise it would be broadcast.
function stub.say(name, message)
	if message:sub(1, 1) == "/" then
		local cmd, param = message:match("^/(%S+)%s*(.*)$")
		local def = chatcommands[cmd]
		if not def then return "no command" end
		if def.privs and not core.check_player_privs(name, def.privs) then return "no privs" end
		local ok, msg = def.func(name, param)
		if msg then core.chat_send_player(name, msg) end
		return ok, msg
	end
	for _, f in ipairs(core.registered_on_chat_messages) do
		if f(name, message) then return true end
	end
	return "broadcast"
end

return stub
