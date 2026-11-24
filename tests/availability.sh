#!/usr/bin/env bash
# Cases for availability/qpu-availability. No network, no SLURM: curl and
# sacctmgr are stubs whose answers each case sets, and which record the
# license's state in a file the way slurmdbd would.
#
#   bash tests/availability.sh      (also run by tests/run.sh)

set -uo pipefail

REPO=${REPO:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
SCRIPT=$REPO/availability/qpu-availability
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$3', got '$2'"; fi; }
logged() { # logged <description> <text expected in the last run's output>
	if grep -qF -- "$2" "$WORK/out"; then ok "$1"; else no "$1" "$(cat "$WORK/out")"; fi
}

# curl stub: answers from $WORK/<gateway|machine>, "<code> <body>"; "down"
# means unreachable.
cat >"$WORK/curl" <<'EOF'
#!/usr/bin/env bash
url=${!#}
case $url in *quantum-computers*) f=machine ;; *) f=gateway ;; esac
read -r code body <"$STUB_DIR/$f"
if [ "$code" = down ]; then echo "curl: (7) Failed to connect to $url" >&2; printf '\n000'; exit 7; fi
printf '%s\n%s' "$body" "$code"
EOF
# sacctmgr stub: the license is "count|lastconsumed" in $WORK/license; every
# update is appended to $WORK/updates. $WORK/sacctmgr-fail makes it fail.
cat >"$WORK/sacctmgr" <<'EOF'
#!/usr/bin/env bash
[ -e "$STUB_DIR/sacctmgr-fail" ] && { echo "sacctmgr: error: Problem talking to the database" >&2; exit 1; }
case " $* " in
*" show "*) cat "$STUB_DIR/license" ;;
*" update "*)
	all="$*"; n=${all##*lastconsumed=}
	IFS='|' read -r count _ <"$STUB_DIR/license"
	echo "$count|$n" >"$STUB_DIR/license"
	echo "$n" >>"$STUB_DIR/updates" ;;
esac
EOF
chmod +x "$WORK/curl" "$WORK/sacctmgr"

export STUB_DIR=$WORK CURL=$WORK/curl SACCTMGR=$WORK/sacctmgr STATE_DIR=$WORK/state
export QPU_AVAILABILITY_CONF=$WORK/none.conf
export GATEWAY_HEALTH_URL=https://gw.test/health
export MACHINE_HEALTH_URL=https://gw.test/api/v1/quantum-computers/default/health
export FAIL_THRESHOLD=3 OK_THRESHOLD=2

reset() { # reset [count|lastconsumed]
	rm -rf "$WORK/state" "$WORK/updates" "$WORK/sacctmgr-fail"
	echo "${1:-4|0}" >"$WORK/license"
	healthy
}
healthy() { echo "200 {\"status\": \"healthy\"}" >"$WORK/gateway"; echo '200 {"healthy":true,"updated_at":"2026-11-18T10:00:00Z"}' >"$WORK/machine"; }
run() { "$SCRIPT" "$@" >"$WORK/out" 2>&1; echo $?; }
consumed() { cut -d'|' -f2 "$WORK/license"; }
updates() { if [ -e "$WORK/updates" ]; then wc -l <"$WORK/updates" | tr -d ' '; else echo 0; fi; }

echo "== qpu-availability"

reset
is "healthy: exit 0" "$(run)" 0
is "healthy: no update" "$(updates)" 0

reset
echo "503 unavailable" >"$WORK/machine"
run >/dev/null; run >/dev/null
is "two failures: not drained yet" "$(consumed)" 0
is "exit 0 after the third failure" "$(run)" 0
is "third failure drains every seat" "$(consumed)" 4
logged "the log says why" 'answered 503'
run >/dev/null
is "already drained: no second update" "$(updates)" 1

healthy
run >/dev/null
is "one good check: still drained" "$(consumed)" 4
run >/dev/null
is "second good check restores" "$(consumed)" 0
run >/dev/null
is "restored: no further update" "$(updates)" 2

reset
echo '200 {"healthy":false,"updated_at":"2026-11-18T10:00:00Z"}' >"$WORK/machine"
run >/dev/null; run >/dev/null; run >/dev/null
is "200 with healthy=false drains" "$(consumed)" 4

reset
echo '200 {"operational_status":"online","health":{"healthy":true,"updated_at":"2026-11-23T10:00:00Z"},"queue_length":0}' >"$WORK/machine"
run >/dev/null; run >/dev/null; run >/dev/null
is "IQM Server 3 shape, online and healthy: not drained" "$(consumed)" 0

reset
echo '200 {"operational_status":"online","health":{"healthy":false,"updated_at":"2026-11-23T10:00:00Z"}}' >"$WORK/machine"
run >/dev/null; run >/dev/null; run >/dev/null
is "IQM Server 3 shape, healthy=false: drained" "$(consumed)" 4

reset
echo '200 {"operational_status":"maintenance","queue_length":0}' >"$WORK/machine"
run >/dev/null; run >/dev/null; run >/dev/null
is "IQM Server 3 maintenance (no health object): drained" "$(consumed)" 4
logged "the log names the operational status" 'operational_status maintenance'

reset
echo '200 {"operational_status":"maintenance","health":{"healthy":true}}' >"$WORK/machine"
run >/dev/null; run >/dev/null; run >/dev/null
is "a non-online status drains even with healthy=true" "$(consumed)" 4

reset
echo "down" >"$WORK/gateway"
run >/dev/null; run >/dev/null; run >/dev/null
is "an unreachable gateway drains" "$(consumed)" 4
logged "the log names the connection error" 'unreachable (curl: (7)'

reset
echo "503 x" >"$WORK/machine"
run >/dev/null; run >/dev/null; healthy; run >/dev/null; echo "503 x" >"$WORK/machine"; run >/dev/null; run >/dev/null
is "a good check resets the failure count" "$(consumed)" 0

reset "4|1"
run >/dev/null; run >/dev/null; run >/dev/null
is "never restores what it did not drain" "$(consumed)" 1
is "...and makes no update" "$(updates)" 0

reset
echo "503 x" >"$WORK/machine"
run >/dev/null; run >/dev/null; run --dry-run >/dev/null
is "dry run changes nothing" "$(consumed)" 0
logged "dry run says what it would do" 'would set lastconsumed=4'

reset
echo "503 x" >"$WORK/machine"
run >/dev/null; run >/dev/null
touch "$WORK/sacctmgr-fail"
is "sacctmgr failing: exit 1" "$(run)" 1
rm "$WORK/sacctmgr-fail"
run >/dev/null
is "...and the drain is retried next run" "$(consumed)" 4

reset
unset MACHINE_HEALTH_URL
echo "503 x" >"$WORK/machine"
run >/dev/null; run >/dev/null; run >/dev/null
is "without MACHINE_HEALTH_URL only the gateway counts" "$(consumed)" 0
export MACHINE_HEALTH_URL=https://gw.test/api/v1/quantum-computers/default/health

reset
is "no GATEWAY_HEALTH_URL: exit 2" "$(GATEWAY_HEALTH_URL='' run)" 2

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
