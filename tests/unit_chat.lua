-- Unit tests for the whole chat path against a stubbed engine. Run from the
-- mod directory:   luajit tests/unit_chat.lua
local here = (arg and arg[0] or ""):match("^(.*)/tests/") or "."
local t = dofile(here .. "/tests/lib.lua")
local stub = assert(loadfile(here .. "/tests/engine_stub.lua"))(here)
stub.load()
local PC = proximity_chat
local strip = stub.strip

local alice = stub.add_player("alice", 0, 0, 0)
local bob = stub.add_player("bob", 10, 0, 0)
local carol = stub.add_player("carol", 25, 0, 0)
local dave = stub.add_player("dave", 50, 0, 0)
stub.step(4) -- welcome messages
stub.clear()

local function last(name)
	local lines = stub.lines_for(name)
	return lines[#lines] and strip(lines[#lines])
end

t.section("plain talk")
t.eq(stub.say("alice", "hello there"), true, "the message is consumed, not broadcast")
t.eq(last("bob"), "<alice> hello there", "a listener nearby reads it word for word")
t.eq(stub.lines_for("bob")[1], "<alice> hello there", "plain talk nearby has no color codes at all")
local c = last("carol")
t.ok(c and c:find("^<alice> %(far away, to your left%) ") ~= nil, "further away: tagged far away, with a direction: " .. tostring(c))
t.ok(c and c:find("hello there", 1, true) == nil, "further away: garbled")
t.ok(c and #c:gsub("^<alice> %b() ", "") == #"hello there", "garbled text keeps its length")
t.eq(#stub.lines_for("dave"), 0, "out of range: nothing")
t.eq(last("alice"), "<alice> hello there", "the speaker sees their own message")
t.ok(stub.last_log:find("CHAT: <alice> hello there [say, heard by 2]", 1, true), "logged with mode and audience")

t.section("bands are shared")
stub.clear()
local erin = stub.add_player("erin", 25, 0, 1)
stub.say("alice", "the quick brown fox")
t.eq(strip(stub.lines_for("carol")[1]):gsub("%b()", ""), strip(stub.lines_for("erin")[1]):gsub("%b()", ""),
	"two listeners standing together read the same garbled words")
stub.remove_player("erin")

t.section("shout and whisper")
stub.clear()
stub.say("alice", "!over here")
t.ok((last("dave") or ""):find("^<alice> %(shouts") ~= nil, "a shout reaches 50 nodes: " .. tostring(last("dave")))
t.eq(last("bob"), "<alice> (shouts) over here", "shouts are tagged")
stub.clear()
stub.say("alice", "~psst")
t.eq(#stub.lines_for("bob"), 0, "a whisper doesn't reach 10 nodes")
t.ok(last("alice"):find("nobody heard you", 1, true) ~= nil, "the speaker learns nobody heard")
stub.step(0.1)
local hint = stub.lines_for("alice")
t.ok(strip(hint[#hint]):find("Start a message with ! to shout", 1, true) ~= nil, "and gets a hint, once")
stub.clear()
stub.say("alice", "~psst again")
stub.step(0.1)
t.eq(#stub.lines_for("alice"), 1, "the hint is not repeated")
bob.pos.x = 3
stub.clear()
stub.say("alice", "~psst")
t.eq(last("bob"), "<alice> (whispers) psst", "a whisper reaches 3 nodes")
bob.pos.x = 10
t.eq(select(1, PC.parse("!")), "say", "a lone prefix is just talk")
t.eq(select(2, PC.parse("!  help")), "help", "spaces after the prefix are dropped")

t.section("walls")
stub.clear()
stub.wall(5, -1, 3, -2, 2)
stub.say("alice", "can you hear me")
t.ok(last("bob"):find("^<alice> %(muffled, to your left%) can you hear me$") ~= nil,
	"one wall: muffled but readable: " .. last("bob"))
stub.wall(6, -1, 3, -2, 2)
stub.clear()
stub.say("alice", "can you hear me")
local b = last("bob")
t.ok(b:find("muffled", 1, true) and not b:find("can you hear me", 1, true), "two walls: muffled and garbled")
stub.wall(7, -1, 3, -2, 2)
stub.wall(8, -1, 3, -2, 2)
stub.clear()
stub.say("alice", "can you hear me")
t.eq(#stub.lines_for("bob"), 0, "four walls at 10 nodes: nothing")
stub.say("alice", "!can you hear me")
t.ok((last("bob") or ""):find("shouts, muffled", 1, true) ~= nil, "a shout still gets through")
stub.nodes = {}
stub.wall(5, -1, 3, -2, 2, "default:glass")
stub.clear()
stub.say("alice", "glass")
t.eq(last("bob"), "<alice> (muffled, to your left) glass", "glass muffles a little")
stub.nodes = {}

t.section("privileges and commands")
stub.clear()
stub.privs.bob.shout = nil
t.eq(stub.say("bob", "let me talk"), true, "a muted player's message is consumed")
t.eq(#stub.lines_for("alice"), 0, "and nobody gets it")
t.ok(last("bob"):find("don't have permission to shout", 1, true) ~= nil, "they are told why")
stub.privs.bob.shout = true
local seen
for _, f in ipairs(core.registered_on_chat_messages) do
	seen = seen or f("alice", "/help")
end
t.eq(seen, false, "commands are left alone")

t.section("global")
stub.clear()
t.eq(stub.say("alice", "/g hi all"), "no privs", "/g needs global_chat by default")
stub.privs.alice.global_chat = true
stub.say("alice", "/g hi all")
t.eq(last("dave"), "[Global] <alice> hi all", "everyone gets a global message")
t.eq(last("alice"), "[Global] <alice> hi all", "including the speaker")

t.section("emote")
stub.clear()
stub.say("alice", "/me waves")
t.eq(last("carol"), "* alice waves", "an emote isn't garbled by distance")
t.eq(#stub.lines_for("dave"), 0, "but has the talk range")
stub.wall(5, -1, 3, -2, 2)
stub.clear()
stub.say("alice", "/me waves")
t.eq(#stub.lines_for("bob"), 0, "a wall hides it")
stub.nodes = {}

t.section("escapes")
stub.clear()
stub.say("alice", "\27(c@#ff0000)red\27(T@x)fake")
t.eq(last("bob"), "<alice> redfake", "color and translation escapes are stripped")
stub.clear()
t.eq(stub.say("alice", "\27(c@#ff0000)"), true, "a message of only escapes is consumed")
t.eq(#stub.lines_for("bob"), 0, "and says nothing")

t.section("bubbles")
stub.step(20) -- let earlier bubbles expire
stub.clear()
stub.entities = {}
stub.say("alice", "hi everyone")
local live = {}
for _, e in ipairs(stub.entities) do
	if not e.removed then live[#live + 1] = e end
end
t.eq(#live, 2, "one carrier per version heard (clear, and garbled for carol)")
local clear_carrier, far_carrier
for _, e in ipairs(live) do
	if e.observers.alice then clear_carrier = e else far_carrier = e end
end
t.ok(clear_carrier and clear_carrier.observers.bob and clear_carrier.observers.alice
	and not clear_carrier.observers.carol, "the clear version goes to alice (the speaker) and bob")
t.ok(far_carrier and far_carrier.observers.carol and not far_carrier.observers.dave,
	"the garbled version only to carol")
t.eq(clear_carrier.attached.parent, alice, "carriers ride on the speaker")
t.ok(math.abs(clear_carrier.attached.pos.y - 17.7) < 1e-6, "at the speaker's nametag point (x10)")
local tag = clear_carrier.props.nametag
t.eq(strip(tag), "hi everyone\n\n\n", "text, then one empty line per text line, name line and gap")
t.ok(tag:find("\27(c@#ffffff)", 1, true) ~= nil, "lines are colored")
stub.say("alice", "second")
t.eq(strip(clear_carrier.props.nametag), "hi everyone\nsecond\n\n\n\n", "messages stack, newest at the bottom")
t.ok(clear_carrier.observers.alice and clear_carrier.observers.bob and not clear_carrier.removed,
	"the same carrier keeps its viewers when its text changes")
stub.step(20)
local alive = 0
for _, e in ipairs(stub.entities) do
	if not e.removed then alive = alive + 1 end
end
t.eq(alive, 0, "bubbles go away")
stub.entities = {}
PC.set_pref("carol", "bubbles", false)
stub.say("bob", "hey")
local carol_sees = false
for _, e in ipairs(stub.entities) do
	if not e.removed and e.observers.carol then carol_sees = true end
end
t.ok(not carol_sees, "players who turned bubbles off don't get them")
PC.set_pref("carol", "bubbles", true)
stub.remove_player("bob")
local left = 0
for _, e in ipairs(stub.entities) do
	if not e.removed then left = left + 1 end
end
t.eq(left, 0, "a speaker leaving takes their bubbles along")
bob = stub.add_player("bob", 10, 0, 0)
stub.step(4)
stub.wall(5, -1, 3, -2, 2)
stub.entities = {}
stub.say("alice", "behind the wall")
local bob_sees = false
for _, e in ipairs(stub.entities) do
	if not e.removed and e.observers.bob then bob_sees = true end
end
t.ok(not bob_sees, "no bubbles through walls")
stub.nodes = {}
stub.step(20)

t.section("voices")
stub.clear()
stub.say("alice", "hello world")
stub.step(3)
local by = {}
for _, s in ipairs(stub.sounds) do
	local to = s.params.to_player
	by[to] = by[to] or {}
	table.insert(by[to], s)
end
t.ok(by.bob and #by.bob == 3, "bob hears one syllable per vowel group (3): " .. (by.bob and #by.bob or 0))
t.ok(by.alice and #by.alice == 3, "alice hears her own voice")
t.ok(by.carol and by.carol[1].params.gain < by.bob[1].params.gain, "carol, further away, hears it quieter")
t.eq(by.dave, nil, "dave hears nothing")
local s = by.bob[1]
t.ok(s.name:find("^proximity_chat_talk_[aeiou][12]$") ~= nil, "talk samples: " .. s.name)
local ear = {x = 10, y = 1.625, z = 0}
t.ok(math.abs(vector.distance(s.params.pos, ear) - 3) < 1e-6, "played 3 nodes from the ear")
t.ok(s.params.pos.x < 10, "on the side the speaker is on")
stub.wall(5, -1, 3, -2, 2)
stub.clear()
stub.say("alice", "hello")
stub.step(3)
local muffled = false
for _, snd in ipairs(stub.sounds) do
	if snd.params.to_player == "bob" and snd.name:find("muffled") then muffled = true end
end
t.ok(muffled, "through a wall: muffled samples")
stub.nodes = {}
PC.set_pref("bob", "voices", false)
stub.clear()
stub.say("alice", "hello")
stub.step(3)
local bob_heard = false
for _, snd in ipairs(stub.sounds) do
	if snd.params.to_player == "bob" then bob_heard = true end
end
t.ok(not bob_heard, "voices can be turned off")
PC.set_pref("bob", "voices", true)
stub.clear()
stub.say("alice", "!hey")
stub.step(1)
t.ok(#stub.sounds > 0 and stub.sounds[1].name:find("shout") ~= nil, "shouts use shout samples")
stub.clear()
stub.say("alice", "/me waves")
stub.step(1)
t.eq(#stub.sounds, 0, "emotes are silent")
stub.clear()
stub.say("alice", ("la "):rep(200))
stub.step(10)
local count = 0
for _, snd in ipairs(stub.sounds) do
	if snd.params.to_player == "bob" then count = count + 1 end
end
t.ok(count > 10 and count < 40, "long messages babble for a few seconds only: " .. count)

t.section("spy")
stub.clear()
stub.privs.dave.chat_spy = true
PC.set_pref("dave", "spy", true)
stub.say("alice", "secret")
t.eq(last("dave"), "[spy] <alice> secret", "a spy reads what they couldn't hear")
PC.set_pref("dave", "spy", false)

t.section("API")
stub.clear()
local guard = stub.add_object(12, 0, 0, {collisionbox = {-0.3, 0, -0.3, 0.3, 1.8, 0.3}, nametag = ""})
t.eq(PC.speak(guard, "halt", "say", {name = "Guard"}), 3, "an entity can talk (heard by 3)")
t.eq(last("bob"), "<Guard> halt", "under the name it was given")
t.eq(PC.speak({x = 0, y = 1, z = 0}, "ding", "say", {name = "Bell"}), 3, "a position can talk (alice, bob, carol)")
t.eq(last("bob"), "<Bell> ding", "")
local cancel = true
PC.register_on_speak(function(info)
	if cancel and info.message == "forbidden" then return false end
	if info.message == "lower" then info.message = "LOWER" end
end)
stub.clear()
stub.say("alice", "forbidden")
t.eq(#stub.lines_for("bob") + #stub.lines_for("alice"), 0, "on_speak can stop a message")
stub.say("alice", "lower")
t.eq(last("bob"), "<alice> LOWER", "and change it")
local heard_by = {}
PC.register_on_hear(function(name, heard) heard_by[name] = heard end)
local modifier_on = true
PC.register_hearing_modifier(function(ctx)
	if not modifier_on then return end
	if ctx.listener_name == "bob" and ctx.mode == "say" then ctx.deaf = true end
	if ctx.listener_name == "dave" and ctx.mode == "say" then ctx.range = 100 end
end)
stub.clear()
stub.say("alice", "megaphone")
t.eq(#stub.lines_for("bob"), 0, "a modifier can make someone deaf")
t.eq(last("dave"), "<alice> megaphone", "or carry a voice further (the clear part grows with it)")
t.ok(heard_by.carol and heard_by.carol.original == "megaphone" and heard_by.carol.clarity < 1,
	"on_hear reports what was heard")
modifier_on = false
local clarity, muffled2 = PC.hearing(alice, carol, "say")
t.ok(clarity and clarity < 1 and not muffled2, "PC.hearing answers for any two places")

t.section("review fixes")
-- Where the bubble goes depends on how the client scales the parent's model.
stub.step(20)
local function carrier_y(props)
	for k, v in pairs(props) do alice.props[k] = v end
	stub.entities = {}
	stub.say("alice", "where am I")
	local y
	for _, e in ipairs(stub.entities) do
		if not e.removed and e.attached then y = e.attached.pos.y end
	end
	stub.step(20)
	return y
end
t.ok(math.abs(carrier_y({visual = "upright_sprite", visual_size = {x = 1, y = 2, z = 1}}) - 17.7) < 1e-6,
	"upright sprites aren't scaled: the engine's default player")
t.ok(math.abs(carrier_y({visual = "mesh", visual_size = {x = 2, y = 2, z = 2}}) - 8.85) < 1e-6,
	"meshes scale the offset by visual_size")
t.ok(math.abs(carrier_y({visual = "wielditem", visual_size = {x = 2, y = 2, z = 2}}) - 17.7) < 1e-6,
	"items by half of it")
alice.props.visual, alice.props.visual_size = nil, {x = 1, y = 1, z = 1}
alice.props.nametag_fontsize, alice.props.nametag_scale_z = 30, true
stub.entities = {}
stub.say("alice", "big font")
t.ok(stub.entities[1] and stub.entities[1].props.nametag_fontsize == 30
	and stub.entities[1].props.nametag_scale_z == true, "bubbles copy the speaker's nametag font")
alice.props.nametag_fontsize, alice.props.nametag_scale_z = nil, nil
stub.step(20)

-- wall_penalty 0: walls make no difference at all.
PC.config.wall_penalty = 0
stub.wall(5, -1, 3, -2, 2)
stub.clear()
stub.say("alice", "no walls")
t.eq(last("bob"), "<alice> no walls", "wall_penalty 0 leaves voices untouched")
PC.config.wall_penalty = 8
stub.nodes = {}

-- A spy who heard a garbled copy also gets the words.
stub.clear()
stub.privs.carol.chat_spy = true
PC.set_pref("carol", "spy", true)
stub.say("alice", "the password is swordfish")
local spy_lines = stub.lines_for("carol")
t.eq(#spy_lines, 2, "a spy in earshot gets their garbled copy and the clear one")
t.eq(strip(spy_lines[2] or ""), "[spy] <alice> the password is swordfish", "")
PC.set_pref("carol", "spy", false)

-- NaN can't sneak past the pitch limits.
local before = PC.get_pref("alice", "pitch")
local ok, msg = core.registered_chatcommands.pchat.func("alice", "pitch nan")
t.ok(not ok and PC.get_pref("alice", "pitch") == before, "/pchat pitch nan is refused")
t.eq(PC.set_pref("alice", "pitch", 0 / 0), false, "set_pref refuses NaN")
t.eq(select(1, core.registered_chatcommands.pchat.func("nobody", "bubbles off")), false,
	"toggles for players who aren't online say so")

-- Entities shown to some players only are heard by them only.
local ghost = stub.add_object(5, 0, 0, {collisionbox = {-0.3, 0, -0.3, 0.3, 1.8, 0.3}})
ghost.observers = {bob = true}
stub.clear()
t.eq(PC.speak(ghost, "boo", "say", {name = "Ghost"}), 1, "a ghost only bob can see is heard by bob only")
t.eq(#stub.lines_for("alice"), 0, "")

-- Entity names come from the calling mod, never from nametags.
local pet = stub.add_object(5, 0, 0, {collisionbox = {-0.3, 0, -0.3, 0.3, 1, 0.3}, nametag = "admin"})
stub.clear()
PC.speak(pet, "give me your password")
t.eq(last("bob"), "<Someone> give me your password", "a pet named admin doesn't talk as admin")
PC.speak(pet, "hi", "say", {name = "x@message"})
t.eq(last("bob"), "<xmessage> hi", "@ is taken out of given names")

-- hearing() follows the same rules as speaking.
stub.wall(5, -1, 3, -2, 2)
t.eq(PC.hearing(alice, bob, "emote"), nil, "hearing(): a wall hides an emote")
local cl, mu = PC.hearing("alice", "bob", "say")
t.ok(cl == 1 and mu == true, "hearing(): talk through one wall is clear but muffled")
stub.nodes = {}

-- The server console's chat goes through untouched.
local console = core.registered_on_chat_messages[#core.registered_on_chat_messages]
t.eq(console("admin_console", "hello from the terminal"), false, "chat from a non-player is left to the engine")

-- Try it can't be spammed.
stub.clear()
PC.voice.preview("alice", 1)
PC.voice.preview("alice", 1)
stub.step(5)
local n1 = #stub.sounds
stub.clear()
PC.voice.preview("alice", 1)
stub.step(5)
t.ok(n1 > 0 and #stub.sounds > 0, "previews play")
stub.clear()
for _ = 1, 20 do PC.voice.preview("alice", 1) end
stub.step(5)
t.ok(#stub.sounds <= n1, "twenty clicks in a row play it once")

os.exit(t.finish())
