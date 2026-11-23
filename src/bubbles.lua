-- proximity_chat: speech bubbles over the speaker's head.
--
-- A bubble is the nametag of an invisible entity (a "carrier") attached to
-- the speaker. Players hear different versions of the same message (further
-- away, fewer letters), so a speaker has one carrier per version currently on
-- show, and each carrier is sent only to the players who heard that version
-- (set_observers). A carrier shows the speaker's last few messages, newest at
-- the bottom, each in its own color.
--
-- Placement: the engine draws a nametag as 2D text centred on a point just
-- above the object, so a nametag with more lines grows both up and down. The
-- carrier is attached so that its point is exactly the speaker's own nametag
-- point, and its text ends in as many empty lines as it has lines of text,
-- plus the lines of the speaker's own nametag, plus one. That puts the
-- message right on top of the speaker's name at any distance, on any screen,
-- with any font size, without ever overlapping it.

local PC, config, text = ...

local bubbles = {}

local ENTITY = "proximity_chat:bubble"
local WRAP = 30          -- characters per line
local LINES_PER_MESSAGE = 3
local MAX_MESSAGES = 3
local MAX_LINES = 6      -- per bubble, older messages make room
local TICK = 0.2

local speakers = {}      -- speaker key (player name or ObjectRef) -> state
local disabled = false   -- engine without set_observers

core.register_entity(ENTITY, {
	initial_properties = {
		visual = "sprite",
		textures = {"blank.png"},
		visual_size = {x = 0.01, y = 0.01, z = 0.01},
		use_texture_alpha = true,
		physical = false,
		collide_with_objects = false,
		pointable = false,
		collisionbox = {0, 0, 0, 0, 0, 0},
		selectionbox = {0, 0, 0, 0, 0, 0},
		static_save = false,
		show_on_minimap = false,
		nametag = "",
		nametag_color = "#ffffff",
		nametag_bgcolor = "#00000000",
		shaded = false,
	},
	_proximity_chat_bubble = true,
	on_activate = function(self)
		self.object:set_armor_groups({immortal = 1})
	end,
	on_punch = function()
		return true
	end,
})

local function now()
	return core.get_us_time() / 1e6
end

local function valid(object)
	return object and object:get_pos() ~= nil
end

local function line_count(s)
	return select(2, s:gsub("\n", "")) + 1
end

-- Where to attach a carrier on `parent` and how many lines the parent's own
-- nametag takes up.
local function layout(parent)
	local props = parent:get_properties()
	local box = props.selectionbox or props.collisionbox
	local top = box and box[5] or 0
	local tag_lines = 0
	local attr = parent.get_nametag_attributes and parent:get_nametag_attributes()
	local color = attr and attr.color
	if not color or (color.a or 255) > 0 then
		local tag = attr and attr.text or props.nametag
		if tag and tag ~= "" then
			tag_lines = line_count(tag)
		elseif parent:is_player() then
			tag_lines = 1 -- an empty player nametag shows the name
		end
	end
	-- The child's offset is in the parent's model units (x10), and the client
	-- scales it with the parent's scene node: by visual_size for meshes, cubes
	-- and nodes, by half of it for items, not at all for sprites. The nametag
	-- point is 0.3 above both origins either way.
	local vs = props.visual_size
	local scale = 1
	if vs and vs.y and vs.y ~= 0 then
		local visual = props.visual
		if visual == "mesh" or visual == "cube" or visual == "node" then
			scale = vs.y
		elseif visual == "item" or visual == "wielditem" then
			scale = vs.y / 2
		end
	end
	-- Same font as the parent's nametag, or the lines wouldn't line up.
	local font = {nametag_fontsize = props.nametag_fontsize or false,
		nametag_scale_z = props.nametag_scale_z or false}
	return top * 10 / scale, tag_lines, font
end

local function attach(carrier, parent, y)
	carrier:set_attach(parent, "", {x = 0, y = y, z = 0}, {x = 0, y = 0, z = 0})
end

local function spawn(parent, y)
	local pos = parent:get_pos()
	local obj = pos and core.add_entity(pos, ENTITY)
	if not obj then
		return nil
	end
	if not obj.set_observers then
		disabled = true
		obj:remove()
		core.log("warning", "[proximity_chat] this engine has no set_observers (Luanti 5.9+); "
			.. "speech bubbles are off")
		return nil
	end
	obj:set_observers({}) -- nobody, until refresh says who
	attach(obj, parent, y)
	return obj
end

local function set_key(names)
	local list = {}
	for name in pairs(names) do
		list[#list + 1] = name
	end
	table.sort(list)
	return table.concat(list, "\n")
end

local function clear(key, st)
	for _, c in pairs(st.carriers) do
		if valid(c.object) then
			c.object:remove()
		end
	end
	speakers[key] = nil
end

-- Work out who sees what, and make the carriers match.
local function refresh(key, st, t)
	local msgs = st.messages
	for i = #msgs, 1, -1 do
		if msgs[i].expires <= t then
			table.remove(msgs, i)
		end
	end
	local parent = st.parent
	if #msgs == 0 or not valid(parent) then
		clear(key, st)
		return
	end

	-- Everyone's bubble text, grouped by text.
	local viewers = {}
	for _, msg in ipairs(msgs) do
		for name in pairs(msg.views) do
			viewers[name] = true
		end
	end
	local groups = {}
	for name in pairs(viewers) do
		if core.get_player_by_name(name) then
			local chosen, count = {}, 0
			for i = #msgs, 1, -1 do
				local view = msgs[i].views[name]
				if view then
					if count > 0 and count + #view.lines > MAX_LINES then
						break
					end
					table.insert(chosen, 1, view)
					count = count + #view.lines
				end
			end
			local parts = {}
			for _, view in ipairs(chosen) do
				local color = core.get_color_escape_sequence(view.color)
				for _, line in ipairs(view.lines) do
					parts[#parts + 1] = color .. line
				end
			end
			if #parts > 0 then
				local content = table.concat(parts, "\n")
				local group = groups[content]
				if not group then
					group = {lines = count, names = {}}
					groups[content] = group
				end
				group.names[name] = true
			end
		end
	end

	local y, tag_lines, font = layout(parent)
	st.y, st.tag_lines = y, tag_lines
	st.font = tostring(font.nametag_fontsize) .. "/" .. tostring(font.nametag_scale_z)
	local pad = tag_lines > 0 and tag_lines + 1 or 0

	-- Keep carriers already showing the right text, reuse the others.
	local old, new, spare = st.carriers, {}, {}
	for content in pairs(groups) do
		local c = old[content]
		if c and valid(c.object) then
			new[content] = c
			old[content] = nil
		end
	end
	for _, c in pairs(old) do
		if valid(c.object) then
			spare[#spare + 1] = c
		end
	end
	-- A carrier that changes its text keeps its object on the clients that
	-- already have it, so each new text goes to the carrier most of its
	-- viewers are already looking at.
	local function take_spare(names)
		local best, best_i, best_n = nil, nil, -1
		for i, c in ipairs(spare) do
			local n = 0
			for name in pairs(names) do
				if c.observers and c.observers[name] then
					n = n + 1
				end
			end
			if n > best_n then
				best, best_i, best_n = c, i, n
			end
		end
		if best_i then
			table.remove(spare, best_i)
		end
		return best
	end
	local order = {}
	for content, group in pairs(groups) do
		local n = 0
		for _ in pairs(group.names) do
			n = n + 1
		end
		order[#order + 1] = {content = content, group = group, n = n}
	end
	table.sort(order, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n -- the biggest audience picks first
		end
		return a.content < b.content
	end)
	for _, entry in ipairs(order) do
		local content, group = entry.content, entry.group
		local c = new[content]
		if not c then
			c = take_spare(group.names)
			if not c then
				local obj = spawn(parent, y)
				c = obj and {object = obj, y = y}
			end
			new[content] = c
		end
		if c then
			local obj = c.object
			local who = set_key(group.names)
			if c.who ~= who then
				obj:set_observers(group.names)
				c.who, c.observers = who, group.names
			end
			local nametag = content .. ("\n"):rep(group.lines + pad)
			if c.nametag ~= nametag or c.font ~= st.font then
				obj:set_properties({
					nametag = nametag,
					nametag_fontsize = font.nametag_fontsize,
					nametag_scale_z = font.nametag_scale_z,
				})
				c.nametag, c.font = nametag, st.font
			end
			if c.y ~= y or obj:get_attach() ~= parent then
				attach(obj, parent, y)
				c.y = y
			end
		end
	end
	for _, c in ipairs(spare) do
		c.object:remove()
	end
	st.carriers = new
end

-- Show a message over `sp`'s head. `viewers`: player name -> {text, color}.
function bubbles.add(sp, mode, viewers, length)
	if disabled or not sp.object or not sp.key or next(viewers) == nil then
		return
	end
	local st = speakers[sp.key]
	if not st then
		st = {messages = {}, carriers = {}}
		speakers[sp.key] = st
	end
	st.parent = sp.object
	local t = now()
	local msg = {
		expires = t + math.min(12, 3.5 + 0.07 * length) * config.bubble_time,
		views = {},
	}
	for name, view in pairs(viewers) do
		local body = mode.format == "emote" and ("* " .. view.text) or view.text
		msg.views[name] = {lines = text.wrap(body, WRAP, LINES_PER_MESSAGE), color = view.color}
	end
	local msgs = st.messages
	msgs[#msgs + 1] = msg
	while #msgs > MAX_MESSAGES do
		table.remove(msgs, 1)
	end
	refresh(sp.key, st, t)
end

-- Remove everything a speaker has on show.
function bubbles.clear(key)
	local st = speakers[key]
	if st then
		clear(key, st)
	end
end

function bubbles.count(key)
	local st = speakers[key]
	if not st then
		return 0
	end
	local n = 0
	for _ in pairs(st.carriers) do
		n = n + 1
	end
	return n
end

-- Expire old messages, follow nametag and model changes, and re-attach any
-- carrier that something detached.
local acc = 0
core.register_globalstep(function(dtime)
	acc = acc + dtime
	if acc < TICK then
		return
	end
	acc = 0
	local t = now()
	for key, st in pairs(speakers) do
		local stale = not valid(st.parent)
		if not stale then
			for _, msg in ipairs(st.messages) do
				if msg.expires <= t then
					stale = true
					break
				end
			end
		end
		if not stale then
			local y, tag_lines, font = layout(st.parent)
			stale = y ~= st.y or tag_lines ~= st.tag_lines
				or tostring(font.nametag_fontsize) .. "/" .. tostring(font.nametag_scale_z) ~= st.font
			for _, c in pairs(st.carriers) do
				if not valid(c.object) or c.object:get_attach() ~= st.parent then
					stale = true
					break
				end
			end
		end
		if stale then
			refresh(key, st, t)
		end
	end
end)

core.register_on_leaveplayer(function(player)
	bubbles.clear(player:get_player_name())
end)

return bubbles
