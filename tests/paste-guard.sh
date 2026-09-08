#!/bin/sh
# Coverage for the `paste` action's clipboard bounds. Runs engine.sh against a
# fake wl-paste on PATH; needs no engine, no display and no real clipboard.
#
#   sh tests/paste-guard.sh
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
SHEET="$T/state/scratch.sheet"
fail=0
check() { # check NAME EXPECTED_CODE ACTUAL_CODE
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: exit $3, expected $2"; fail=1; fi
}
fake() { printf '#!/bin/sh\n%s\n' "$1" > "$T/bin/wl-paste"; chmod +x "$T/bin/wl-paste"; }
run() { PATH="$T/bin:$PATH" sh "$HERE/engine.sh" "$SHEET" paste > "$T/out" 2> "$T/err"; echo "$?"; }

fake 'printf "a\tb\n1\t2"'
rc=$(run); check "normal clipboard passes through" 0 "$rc"
[ "$(cat "$T/out")" = "$(printf 'a\tb\n1\t2')" ] || { echo "FAIL normal: output differs"; fail=1; }

fake 'exit 1'
rc=$(run); check "empty clipboard is an empty paste" 0 "$rc"
[ ! -s "$T/out" ] || { echo "FAIL empty: produced output"; fail=1; }

fake 'head -c 200000 /dev/zero | tr "\0" x'
rc=$(run); check "oversized clipboard is refused" 3 "$rc"
[ ! -s "$T/out" ] || { echo "FAIL oversized: partial data reached stdout"; fail=1; }
grep -q "too large" "$T/err" || { echo "FAIL oversized: no report on stderr"; fail=1; }

fake "echo \$\$ > '$T/producer.pid'; exec sleep 30"
start=$(date +%s); rc=$(run); took=$(( $(date +%s) - start ))
check "non-terminating producer hits the deadline" 4 "$rc"
[ "$took" -le 4 ] || { echo "FAIL deadline: took ${took}s"; fail=1; }
[ ! -s "$T/out" ] || { echo "FAIL deadline: data reached stdout"; fail=1; }
sleep 0.2
if kill -0 "$(cat "$T/producer.pid")" 2>/dev/null; then
  echo "FAIL deadline: producer left running"; fail=1; kill "$(cat "$T/producer.pid")" 2>/dev/null
fi

fake 'printf "partial"; exec sleep 30'
rc=$(run); check "stalled producer with partial data is refused" 4 "$rc"
[ ! -s "$T/out" ] || { echo "FAIL stalled: partial data reached stdout"; fail=1; }

fake 'yes x'
start=$(date +%s); rc=$(run); took=$(( $(date +%s) - start ))
check "infinite producer is cut at the cap" 3 "$rc"
[ "$took" -le 4 ] || { echo "FAIL infinite: took ${took}s"; fail=1; }

[ -z "$(ls "$T/state" | grep '^paste\.')" ] || { echo "FAIL temp files left in state dir"; fail=1; }
exit $fail
