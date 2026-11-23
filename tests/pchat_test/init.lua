-- Live test driver for tests/live.sh. Once alice, bob and carol have joined, it
-- puts them on a platform in the sky (alice at x=0, bob 5 nodes away, carol
-- 24 nodes away, both facing alice), makes them talk through the real chat
-- callbacks, checks what each player was sent, and logs
--   PCHAT_SHOT <player> <label>   when a screenshot of <player>'s window is due
--   PCHAT_CHECK ok|FAIL <what>
--   PCHAT_DONE pass=<n> fail=<n>
local PC = proximity_chat
local Y = 100
local pass, fail = 0, 0

local function check(cond, what)
	if cond then
		pass = pass + 1
	else
		fail = fail + 1
	end
	core.log("action", ("PCHAT_CHECK %s %s"):format(cond and "ok" or "FAIL", what))
end

-- Everything sent to each player, escapes stripped.
local got = {}
local orig_send = core.chat_send_player
function core.chat_send_player(name, text)
	got[name] = got[name] or {}
	table.insert(got[name], core.strip_escapes(text))
	return orig_send(name, text)
end
local function last(name)
	local list = got[name] or {}
	return list[#list] or ""
end

-- Type a line the way the engine hands it to mods.
local function type_line(name, message)
	for _, callback in ipairs(core.registered_on_chat_messages) do
		if callback(name, message) then
			return true
		end
	end
	core.log("action", "PCHAT_CHECK FAIL message was not consumed: " .. message)
	fail = fail + 1
end

-- Bubble carriers riding on `speaker`, and how many each player sees.
local function carriers(speaker)
	local n, by = 0, {}
	for _, ent in pairs(core.luaentities) do
		local parent = ent.name == "proximity_chat:bubble" and ent.object:get_attach()
		if parent and parent:get_player_name() == speaker then
			n = n + 1
			for name in pairs(ent.object:get_observers() or {}) do
				by[name] = (by[name] or 0) + 1
			end
		end
	end
	return n, by
end

local function place(name, x, yaw, z)
	local p = core.get_player_by_name(name)
	p:set_pos({x = x, y = Y + 1, z = z or 0})
	p:set_look_horizontal(yaw)
	p:set_look_vertical(-0.08)
end

local function shot(who, label)
	core.after(1.2, core.log, "action", "PCHAT_SHOT " .. who .. " " .. label)
end

-- A solid block that exists in whatever game this is.
local STONE
core.register_on_mods_loaded(function()
	for _, name in ipairs({"default:stone", "mcl_core:stone", "mcl_deepslate:deepslate"}) do
		if core.registered_nodes[name] then
			STONE = name
			return
		end
	end
	for name, def in pairs(core.registered_nodes) do
		if def.walkable ~= false and (def.drawtype or "normal") == "normal" and name:find(":") then
			STONE = name
			return
		end
	end
end)

local function build()
	for x = -6, 40 do
		for z = -7, 7 do
			core.set_node({x = x, y = Y, z = z}, {name = STONE})
		end
	end
end

local function wall(name)
	for x = 12, 13 do
		for y = Y + 1, Y + 5 do
			for z = -7, 7 do
				core.set_node({x = x, y = y, z = z}, {name = name})
			end
		end
	end
end

local EAST, WEST = -math.pi / 2, math.pi / 2 -- look toward +x / -x

local steps = {
	function()
		build()
		place("alice", 0, EAST)
		place("bob", 5, WEST)
		place("carol", 24, math.atan2(24, -4), 4) -- off to the side, facing alice
		core.set_timeofday(0.5)
	end,
	function()
		got = {}
		type_line("alice", "Hello everyone, nice to see you here!")
		check(last("bob") == "<alice> Hello everyone, nice to see you here!", "bob reads alice word for word: " .. last("bob"))
		check(last("carol"):find("^<alice> %(far away, ahead of you%) ") ~= nil, "carol gets it far away, ahead: " .. last("carol"))
		check(not last("carol"):find("nice to see you", 1, true), "carol's copy is garbled")
		local n, by = carriers("alice")
		check(n == 2 and by.bob == 1 and by.carol == 1 and by.alice == 1, ("two bubble carriers, one each (n=%d)"):format(n))
		shot("bob", "say")
		shot("carol", "say")
	end,
	function()
		got = {}
		type_line("alice", "!Over here, come quick!")
		check(last("carol") == "<alice> (shouts) Over here, come quick!", "a shout is clear at 24 nodes: " .. last("carol"))
		shot("bob", "shout")
		shot("carol", "shout")
	end,
	function()
		got = {}
		type_line("bob", "/me waves at alice")
		check(last("alice") == "* bob waves at alice", "alice sees bob's emote: " .. last("alice"))
		type_line("bob", "hi alice :)")
		shot("carol", "emote")
	end,
	function()
		wall(STONE)
		got = {}
		type_line("alice", "Can you hear me through the wall?")
		check(#(got.carol or {}) == 0, "two nodes of stone at 24 nodes: carol hears nothing")
		type_line("alice", "!CAN YOU HEAR ME NOW?")
		check(last("carol"):find("^<alice> %(shouts, muffled, ahead of you%)") ~= nil, "a shout gets through, muffled: " .. last("carol"))
		local _, by = carriers("alice")
		check(not by.carol, "no bubble for carol through the wall")
		shot("carol", "wall")
	end,
	function()
		wall("air")
		got = {}
		type_line("alice", "~psst, bob")
		check(#(got.bob or {}) == 1 and last("bob"):find("^<alice> %(whispers, far away") ~= nil,
			"a whisper at 5 nodes is barely there: " .. last("bob"))
		check(last("alice"):find("psst, bob", 1, true) ~= nil, "alice sees her whisper")
		check(#(got.carol or {}) == 0, "carol doesn't hear the whisper")
		place("bob", 2.5, WEST)
	end,
	function()
		got = {}
		type_line("alice", "~psst, bob")
		check(last("bob") == "<alice> (whispers) psst, bob", "a whisper at 2.5 nodes: " .. last("bob"))
		shot("bob", "whisper")
	end,
	function()
		PC.show_settings("bob")
		shot("bob", "settings")
	end,
}

local function run(i)
	if i > #steps then
		core.log("action", ("PCHAT_DONE pass=%d fail=%d"):format(pass, fail))
		return
	end
	local ok, err = pcall(steps[i])
	if not ok then
		fail = fail + 1
		core.log("action", "PCHAT_CHECK FAIL step " .. i .. " errored: " .. tostring(err))
	end
	core.after(2.5, run, i + 1)
end

local started = false
core.register_globalstep(function()
	if started then
		return
	end
	for _, name in ipairs({"alice", "bob", "carol"}) do
		if not core.get_player_by_name(name) then
			return
		end
	end
	started = true
	core.after(4, run, 1)
end)
