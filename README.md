# Proximity Chat

What you say is heard by the people near you, not the whole server.

The further away someone is, the less of your message they make out: letters
drop out until only dots are left. Walls muffle your voice like extra
distance. What people say floats over their heads in a speech bubble, written
the way you heard it, and they say it out loud in a babble voice of their own
that comes from where they stand, so you can hear someone talking behind you
and turn around.

It's a plain server mod. Players don't install anything, there is no external
program, and it works in any game (tested with Minetest Game and VoxeLibre).
The server needs Luanti 5.9 or newer, and 5.10 or newer for speech bubbles (on
5.9 everything else works and bubbles stay off). Players can join with any
client that can connect to the server: they get the voice sounds
automatically, as with any mod.

## Talking

| | How | Reaches |
|---|---|---|
| Talk | just type | 32 nodes |
| Shout | `!message` or `/shout message` | 96 nodes |
| Whisper | `~message` or `/whisper message` | 5 nodes |
| Act | `/me waves` | 32 nodes, only people who can see you |
| Everyone | `/g message` (the `global_chat` privilege) | the whole server |
| Privately | `/msg name message` | as always |

Up to 60% of the range a message arrives word for word; beyond that it fades
out letter by letter. People standing together always read the very same
words, in chat and in the bubble.

Listeners see who shouted or whispered, and when a voice is faint or muffled
they also see which way it came from:

```
<alice> Hello everyone!
<alice> (shouts) Over here, come quick!
<alice> (far away, to your left) H.l.. .ver..ne!
<alice> (shouts, muffled, ahead of you) CAN YOU HEAR ME NOW?
```

If nobody was close enough to hear you, you're told so (and, the first time,
how to shout). New players get a one-line explanation when they first join,
and `/pchat` explains everything.

## Walls

Sound goes in a straight line from mouth to ear. Every solid node on the way
counts as 8 extra nodes of distance, so a wall between you and a friend 10
nodes away still lets them hear you, muffled; three walls and they won't. Glass,
leaves, fences, slabs, doors and water let more through (half a wall each),
wool soaks sound up (two walls). Mods can give their nodes a `soundproof`
group (in tenths of a wall: 10 is a normal wall, 0 lets sound through).

Acting with `/me` is something people see, not hear: it reaches as far as
talking, isn't garbled, and a wall hides it.

## Speech bubbles

What people say shows over their heads, right above their name, in the color of
how it was said (shouts amber, whispers lilac, faint voices grey). The last
three messages stack, newest at the bottom, and fade after a few seconds.
Everyone sees the bubble the way they heard the message, so someone far away
sees the dots too. By default nobody sees a bubble through a wall (it would
show where the speaker is).

## Voices

Everyone talks in a babble voice: one short syllable per syllable of the
message, with its vowels, pauses at commas and full stops, a rise at the end of
a question. Each player has a voice of their own (chosen from their name; they
can change its pitch in `/pchat`). Voices come from the speaker's direction,
fade with distance and sound dull through walls. Whispers are breathy and
shouts are loud. Each player can turn voices off for themselves.

The voice samples are made from scratch by `tools/make_sounds.py` (formant
synthesis); nothing is recorded.

## Commands and privileges

- `/pchat` opens a window with how it all works and your own settings: speech
  bubbles, voices, your own voice, your voice's pitch (with a button to try it).
- `/pchat bubbles|voices|ownvoice [on|off]`, `/pchat pitch <50-200>`,
  `/pchat help` do the same from chat.
- `/g`, `/global`, `/shout` and `/whisper` are only added if no other mod has
  them already.
- `global_chat` lets a player use `/g` (admins and singleplayer have it). The
  setting `proximity_chat_global` can open `/g` to everyone or turn it off.
- `chat_spy` lets a moderator read all nearby chat on the server with
  `/pchat spy on`. Admins have it, but it's off until they turn it on.
- Players without `shout` can't talk, as usual.

## Settings

| Setting | Default | |
|---|---|---|
| `proximity_chat_say_range` | `32` | How far talk carries |
| `proximity_chat_shout_range` | `96` | How far a shout carries |
| `proximity_chat_whisper_range` | `5` | How far a whisper carries |
| `proximity_chat_clear_fraction` | `0.6` | Part of the range heard perfectly (1: no garbling) |
| `proximity_chat_wall_penalty` | `8` | Extra distance per solid node in the way |
| `proximity_chat_occlusion` | `true` | Walls muffle voices at all |
| `proximity_chat_shout_prefix` | `!` | Start a message with this to shout (empty: off) |
| `proximity_chat_whisper_prefix` | `~` | Start a message with this to whisper (empty: off) |
| `proximity_chat_global` | `priv` | Who can use `/g`: `priv`, `all` or `off` |
| `proximity_chat_override_me` | `true` | `/me` reaches only people nearby |
| `proximity_chat_direction_hints` | `true` | Say which way faint voices came from |
| `proximity_chat_nobody_heard` | `true` | Tell players when nobody heard them |
| `proximity_chat_welcome` | `true` | Explain proximity chat on first join |
| `proximity_chat_bubbles` | `true` | Speech bubbles |
| `proximity_chat_bubbles_through_walls` | `false` | Show bubbles to people behind walls |
| `proximity_chat_bubble_time` | `1` | How long bubbles stay, relative to normal |
| `proximity_chat_babble` | `true` | Babble voices |
| `proximity_chat_babble_volume` | `1` | Voice volume |
| `proximity_chat_babble_max_seconds` | `3` | Longest a message babbles |

## Other chat mods

Proximity chat sees a message after every other mod, so mods that mute, filter,
count or log chat keep working. A mod that takes the message for itself first
(sending it to everyone in its own format, say) wins, and that message isn't
proximity chat; the server log lists the mods that see chat first. Bridges to
IRC, Discord or Matrix see local chat before it is limited, so they relay all
of it; messages coming in from them reach everyone as before.

Every message is logged as `CHAT: <name> message [mode, heard by N]`.

## API

```lua
-- Say something as a player (name or ObjectRef), an entity, or a position.
-- Mobs and NPCs get bubbles and voices just like players.
proximity_chat.speak(guard_object, "Halt! Who goes there?", "shout", {name = "Guard"})
proximity_chat.speak(pos, "Ding dong", "say", {name = "Bell", pitch = 0.6})
-- opts: name, pitch, range, clear. Returns the number of players who heard it.
-- Without opts.name an entity speaks as "Someone" (never by its nametag, which
-- players can often set), and an entity hidden from some players with
-- set_observers is only heard by the players who can see it.

-- A new way of talking (fields as in src/modes.lua):
proximity_chat.register_mode("radio", {range = 500, garble = false, occlusion = false,
	color = "#7fff7f", tag = function() return "on the radio" end, babble = false})

-- Change or stop messages (return false to stop):
proximity_chat.register_on_speak(function(info)
	-- info.name, info.player_name, info.object, info.message, info.mode
end)

-- Know who heard what:
proximity_chat.register_on_hear(function(listener_name, heard)
	-- heard.speaker, heard.message (as they read it), heard.original,
	-- heard.mode, heard.clarity (0..1), heard.muffled, heard.distance
end)

-- Megaphones, earmuffs, hearing aids... called per speaker and listener:
proximity_chat.register_hearing_modifier(function(ctx)
	-- ctx.speaker, ctx.speaker_object, ctx.listener, ctx.listener_name,
	-- ctx.mode, ctx.distance; change ctx.range (the clear part follows),
	-- ctx.clear, ctx.wall_penalty, ctx.extra (extra distance), or set ctx.deaf
end)

-- The hearing model on its own: clarity (nil if out of earshot), muffled,
-- effective distance, for any two objects or positions.
local clarity, muffled = proximity_chat.hearing(player_a, player_b, "say")

proximity_chat.get_pref(name, "voices")      -- bubbles, voices, own_voice, pitch, spy
proximity_chat.set_pref(name, "pitch", 1.2)
```

The bubble entity is `proximity_chat:bubble` (its Lua entity has
`_proximity_chat_bubble = true`).

## Tests

```
luajit tests/unit_text.lua     # garbling, wrapping, syllables
luajit tests/unit_chat.lua     # the whole chat path against a stubbed engine
tests/live.sh [gameid]         # a server and three real clients; checks what
                               # everyone gets and takes screenshots
```
