#!/bin/sh
# Engine control for VisiGrid Scratch.
#   engine.sh <sheet> ensure   -> prints SESSION=<id> TOKEN=<token> PID=<pid>, or MISSING / FAILED
#   engine.sh <sheet> stop     -> prints STOPPED
#
# The engine (`vgrid serve`) runs in its own session, detached from the shell,
# so a shell restart never kills it mid-save. Its token and pid live next to
# the sheet (0600) so a new shell instance can adopt the running engine.
#
# The pid file is an identity record, not a bare pid: "<pid> <starttime> <boot_id>".
# A pid alone is not proof of anything once the engine has exited, because the
# kernel hands the number to the next process that needs one, and `kill -0`
# plus a `comm` containing "vgrid" would happily accept an unrelated vgrid run
# by the same user. Start time (field 22 of /proc/<pid>/stat, in clock ticks
# since boot) plus the boot id pins the record to one process lifetime. The
# record is written atomically and re-verified before every signal; a record
# that no longer matches is discarded without signalling anything.
set -u
SHEET=$1
ACTION=$2
STATE=$(dirname "$SHEET")
TOKEN_FILE="$STATE/scratch.token"
PID_FILE="$STATE/scratch.pid"
LOG="$STATE/scratch-engine.log"
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
mkdir -p "$STATE"
umask 077

# Start time of a live process, empty if it is gone. The comm field in
# /proc/<pid>/stat can contain spaces and parentheses, so cut after the
# closing paren: field 22 overall is field 20 from there.
start_time() {
  sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20
}

# Write "<pid> <starttime> <boot_id>" for a live pid, atomically.
record_pid() {
  st=$(start_time "$1")
  [ -n "$st" ] || return 1
  printf '%s %s %s\n' "$1" "$st" "$BOOT_ID" > "$PID_FILE.tmp" && mv -f "$PID_FILE.tmp" "$PID_FILE"
}

# Print the recorded pid if, and only if, the record still names the same
# process: same boot, same start time, and it is a vgrid binary.
# A record without an identity (the 0.1.0 format, a bare pid) is reported
# only with LEGACY=1 set, so `ensure` can adopt and upgrade it once; `stop`
# never signals on a bare pid.
live_pid() {
  [ -s "$PID_FILE" ] || return 1
  read -r pid st boot < "$PID_FILE" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  grep -q "vgrid" "/proc/$pid/comm" 2>/dev/null || return 1
  if [ -z "$st" ]; then
    [ "${LEGACY:-0}" = 1 ] || return 1
  else
    [ "$boot" = "$BOOT_ID" ] || return 1
    [ "$(start_time "$pid")" = "$st" ] || return 1
  fi
  echo "$pid"
}

session_for_pid() {
  vgrid sessions --json 2>/dev/null | jq -r --argjson p "$1" '.[] | select(.pid == $p) | .session_id' | head -1
}

# Was this live pid launched to serve THIS sheet? The only evidence a bare
# 0.1.0 pid can offer: it passed nothing stronger than "alive, comm contains
# vgrid", which any same-user vgrid process that inherited the number also
# passes. The engine was exec'd with the sheet path in its arguments, so the
# command line of the process now holding the pid says whether it is that
# engine or a stranger. The session list cannot say: a --new --save-as
# session reports no workbook path until its first save.
serves_sheet() {
  tr '\0' '\n' < "/proc/$1/cmdline" 2>/dev/null | grep -qxF -- "$SHEET"
}
case "$ACTION" in
ensure)
  command -v vgrid >/dev/null 2>&1 || { echo "MISSING"; exit 127; }
  command -v jq >/dev/null 2>&1 || { echo "MISSING jq"; exit 127; }
  [ -s "$TOKEN_FILE" ] || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE"
  TOKEN=$(cat "$TOKEN_FILE")
  PID=$(LEGACY=1 live_pid || true)
  if [ -n "$PID" ]; then
    read -r _ st _ < "$PID_FILE" || st=""
    if [ -z "$st" ] && ! serves_sheet "$PID"; then
      # A bare 0.1.0 pid whose process was not launched on this sheet is not
      # our engine, or no longer is. Forget it. Writing an identity record for
      # it first would turn a reused pid into exactly what `stop` trusts.
      PID=""
    else
      # Adopt: (re)write the identity record so a bare-pid file from an older
      # version is upgraded, and a current one is refreshed.
      record_pid "$PID" || PID=""
    fi
  fi
  if [ -z "$PID" ]; then
    rm -f "$PID_FILE"
    if [ -e "$SHEET" ] && ! vgrid peek "$SHEET" >/dev/null 2>&1; then
      mv -f "$SHEET" "$SHEET.unreadable-$(date +%s)"
      echo "RECOVER moved unreadable sheet aside"
    fi
    if [ -s "$SHEET" ]; then set -- "$SHEET"; else rm -f "$SHEET"; set -- --new --save-as "$SHEET"; fi
    # The child records its own identity before exec: exec keeps the pid and
    # the start time, so the record written here is the engine's.
    VISIGRID_SESSION_TOKEN=$TOKEN setsid sh -c '
      st=$(sed "s/^.*) //" "/proc/$$/stat" | cut -d" " -f20)
      printf "%s %s %s\n" "$$" "$st" "$1" > "$0.tmp" && mv -f "$0.tmp" "$0"
      shift
      exec vgrid serve "$@"' \
      "$PID_FILE" "$BOOT_ID" "$@" --autosave 5 --title "Omarchy Scratch" >>"$LOG" 2>&1 </dev/null &
    for _ in $(seq 1 50); do PID=$(live_pid || true); [ -n "$PID" ] && break; sleep 0.1; done
  fi
  [ -n "$PID" ] || { echo "FAILED engine did not start (see $LOG)"; exit 1; }
  SID=""
  for _ in $(seq 1 50); do SID=$(session_for_pid "$PID"); [ -n "$SID" ] && break; sleep 0.1; done
  [ -n "$SID" ] || { echo "FAILED no session for pid $PID"; exit 1; }
  echo "SESSION=$SID TOKEN=$TOKEN PID=$PID"
  ;;
stop)
  # Identity is re-checked immediately before each signal. If the engine has
  # already exited and the pid now belongs to something else, live_pid comes
  # back empty and nothing is signalled; the stale record is simply removed.
  PID=$(live_pid || true)
  if [ -n "$PID" ]; then
    kill -TERM "$PID" 2>/dev/null
    for _ in $(seq 1 100); do [ -n "$(live_pid || true)" ] || break; sleep 0.1; done
    if [ -n "$(live_pid || true)" ]; then kill -KILL "$PID" 2>/dev/null; fi
  fi
  rm -f "$PID_FILE" "$PID_FILE.tmp"
  echo "STOPPED"
  ;;
*)
  echo "usage: engine.sh <sheet> ensure|stop" >&2
  exit 2
  ;;
esac
