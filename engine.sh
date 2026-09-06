#!/bin/sh
# Engine control for VisiGrid Scratch.
#   engine.sh <sheet> ensure   -> prints SESSION=<id> TOKEN=<token> PID=<pid>, or MISSING / FAILED
#   engine.sh <sheet> stop     -> prints STOPPED
#
# The engine (`vgrid serve`) runs in its own session, detached from the shell,
# so a shell restart never kills it mid-save. Its token and pid live next to
# the sheet (0600) so a new shell instance can adopt the running engine.
set -u
SHEET=$1
ACTION=$2
STATE=$(dirname "$SHEET")
TOKEN_FILE="$STATE/scratch.token"
PID_FILE="$STATE/scratch.pid"
LOG="$STATE/scratch-engine.log"
mkdir -p "$STATE"
umask 077

live_pid() {
  [ -s "$PID_FILE" ] || return 1
  pid=$(cat "$PID_FILE")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && grep -q "vgrid" "/proc/$pid/comm" 2>/dev/null && echo "$pid"
}

session_for_pid() {
  vgrid sessions --json 2>/dev/null | jq -r --argjson p "$1" '.[] | select(.pid == $p) | .session_id' | head -1
}

case "$ACTION" in
ensure)
  command -v vgrid >/dev/null 2>&1 || { echo "MISSING"; exit 127; }
  command -v jq >/dev/null 2>&1 || { echo "MISSING jq"; exit 127; }
  [ -s "$TOKEN_FILE" ] || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE"
  TOKEN=$(cat "$TOKEN_FILE")
  PID=$(live_pid || true)
  if [ -z "$PID" ]; then
    if [ -e "$SHEET" ] && ! vgrid peek "$SHEET" >/dev/null 2>&1; then
      mv -f "$SHEET" "$SHEET.unreadable-$(date +%s)"
      echo "RECOVER moved unreadable sheet aside"
    fi
    if [ -s "$SHEET" ]; then set -- "$SHEET"; else rm -f "$SHEET"; set -- --new --save-as "$SHEET"; fi
    VISIGRID_SESSION_TOKEN=$TOKEN setsid sh -c 'echo $$ > "$0"; exec vgrid serve "$@"' \
      "$PID_FILE" "$@" --autosave 5 --title "Omarchy Scratch" >>"$LOG" 2>&1 </dev/null &
    for _ in $(seq 1 50); do PID=$(live_pid || true); [ -n "$PID" ] && break; sleep 0.1; done
  fi
  [ -n "$PID" ] || { echo "FAILED engine did not start (see $LOG)"; exit 1; }
  SID=""
  for _ in $(seq 1 50); do SID=$(session_for_pid "$PID"); [ -n "$SID" ] && break; sleep 0.1; done
  [ -n "$SID" ] || { echo "FAILED no session for pid $PID"; exit 1; }
  echo "SESSION=$SID TOKEN=$TOKEN PID=$PID"
  ;;
stop)
  PID=$(live_pid || true)
  if [ -n "$PID" ]; then
    kill -TERM "$PID" 2>/dev/null
    for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null
  fi
  rm -f "$PID_FILE"
  echo "STOPPED"
  ;;
*)
  echo "usage: engine.sh <sheet> ensure|stop" >&2
  exit 2
  ;;
esac
