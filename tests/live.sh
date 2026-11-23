#!/bin/bash
# Live test: a local server and three real clients (alice, bob, carol) talking
# on a platform in the sky. Checks what each player is sent and screenshots
# what bob and carol see. Needs an X11 display, xdotool and ImageMagick.
#   tests/live.sh [gameid] [outdir] [extra client.conf lines...]
# Exit status 0 when every check passes. Screenshots and sheet.jpg in outdir.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
MOD=$(dirname "$HERE")
LUANTI_DIR=${LUANTI_DIR:-$(cd "$MOD/../.." && pwd)}
GAME=${1:-minetest_game}
OUT=${2:-${TMPDIR:-/tmp}/proximity_chat_live_$GAME}
shift $(( $# < 2 ? $# : 2 ))
PORT=${PCHAT_PORT:-30189}
BIN=$LUANTI_DIR/bin/luanti
SRV=$LUANTI_DIR/bin/luantiserver
[ -x "$BIN" ] || BIN=$LUANTI_DIR/bin/minetest
[ -x "$SRV" ] || SRV=$LUANTI_DIR/bin/minetestserver

rm -rf "$OUT"; mkdir -p "$OUT/world/worldmods"
cp -r "$HERE/pchat_test" "$OUT/world/worldmods/"
cat > "$OUT/world/world.mt" <<EOW
gameid = $GAME
backend = sqlite3
player_backend = sqlite3
auth_backend = sqlite3
load_mod_proximity_chat = true
EOW
cat > "$OUT/server.conf" <<EOC
port = $PORT
default_privs = interact, shout, fly
enable_damage = false
mg_name = flat
fixed_map_seed = 1
EOC
cat > "$OUT/client.conf" <<EOC
screen_w = 800
screen_h = 500
fullscreen = false
pause_on_lost_focus = false
fps_max_unfocused = 60
sound_volume = 0
EOC
for line in "$@"; do echo "$line" >> "$OUT/client.conf"; done

LOG=$OUT/server.log; : > "$LOG"
"$SRV" --config "$OUT/server.conf" --world "$OUT/world" --logfile "$LOG" --port $PORT >/dev/null 2>&1 &
SPID=$!
sleep 3
declare -A PIDS
for name in alice bob carol; do
	"$BIN" --config "$OUT/client.conf" --logfile "$OUT/$name.log" --go --address 127.0.0.1 \
		--port $PORT --name $name >/dev/null 2>&1 &
	PIDS[$name]=$!
	sleep 1.5
done

end=$((SECONDS + 150))
tail -n +1 -F "$LOG" 2>/dev/null | while read -r line; do
	case $line in
	*"PCHAT_SHOT "*)
		set -- ${line##*PCHAT_SHOT }
		who=$1 label=$2
		wid=$(xdotool search --pid "${PIDS[$who]}" 2>/dev/null | tail -1)
		sleep 0.4
		import -window "$wid" "$OUT/${label}_$who.png" 2>/dev/null && echo "shot ${label}_$who";;
	*"PCHAT_CHECK "*) echo "  ${line##*PCHAT_CHECK }";;
	*PCHAT_DONE*) echo "${line##*: }"; break;;
	*ServerError*|*ModError*|*"ERROR["*) echo "$line";;
	esac
	[ $SECONDS -gt $end ] && { echo "timed out"; break; }
done

kill "${PIDS[@]}" $SPID 2>/dev/null; sleep 1; kill -9 "${PIDS[@]}" $SPID 2>/dev/null
grep -h "ERROR\[" "$OUT"/alice.log "$OUT"/bob.log "$OUT"/carol.log 2>/dev/null | sort | uniq -c | head
grep -h -i "proximity_chat" "$OUT"/*.log 2>/dev/null | grep -i "warn\|error\|not found" | sort | uniq -c | head
if ls "$OUT"/*.png >/dev/null 2>&1; then
	montage -label '%t' "$OUT"/*.png -tile 2x -geometry 800x500+4+4 -pointsize 16 png:- \
		| magick - -quality 88 "$OUT/sheet.jpg" && echo "sheet: $OUT/sheet.jpg"
fi
grep -q "PCHAT_DONE pass=[0-9]* fail=0" "$LOG"
