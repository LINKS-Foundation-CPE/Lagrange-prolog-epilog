#!/bin/bash
# In-container test cases. Run via tests/run.sh, which provides a real Redis.
#
# The scripts are driven exactly as SLURM drives them: environment in, exit
# status and side effects out. Nothing is stubbed except the SLURM environment
# itself, and the Redis client under test is the one the scripts use.

set -u

REPO=${REPO:-/repo}
export QPU_LIBDIR="$REPO/lib"
export QPU_CONF=/tmp/qpu-token.conf
export QPU_PUBLIC_CONF=/tmp/qpu-token.public
TOKEN_DIR=/tmp/qpu-tokens
SHARED_DIR=/tmp/qpu-shared

PROLOG="$REPO/prolog.d/50-qpu-token"
EPILOG="$REPO/epilog.d/50-qpu-token"
TASKPROLOG="$REPO/taskprolog/qpu-token"

pass=0
fail=0

ok() {
	pass=$((pass + 1))
	printf '  ok   %s\n' "$1"
}
no() {
	fail=$((fail + 1))
	printf '  FAIL %s\n' "$1"
	[ $# -gt 1 ] && printf '       %s\n' "$2"
}
is() {
	if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected '$3', got '$2'"; fi
}
isnt_empty() {
	if [ -n "$2" ]; then ok "$1"; else no "$1" "expected a value, got nothing"; fi
}

redis() { # redis CMD ARG... -> reply on stdout
	local args="" a
	for a in "$@"; do
		if [ -z "$args" ]; then args="$a"; else args="$args"$'\t'"$a"; fi
	done
	printf '%s\n' "$args" |
		REDIS_HOST="$REDIS_HOST" REDIS_PORT="${REDIS_PORT:-6379}" REDIS_TIMEOUT=2 \
			"$REPO/lib/qpu-redis"
}

write_conf() { # write_conf [extra lines...]
	cat >"$QPU_CONF" <<EOF
REDIS_HOST=${1:-$REDIS_HOST}
REDIS_PORT=${REDIS_PORT:-6379}
REDIS_TIMEOUT=2
LICENSE_NAME=qpu
MAX_WALLTIME_SECONDS=3600
GRACE_SECONDS=60
TOKEN_DIR=$TOKEN_DIR
TOKEN_PREFIX=sqed_
${2:-}
EOF
	chmod 600 "$QPU_CONF"

	# The non-secret half, as the job user's TaskProlog reads it.
	cat >"$QPU_PUBLIC_CONF" <<EOF
LICENSE_NAME=qpu
TOKEN_DIR=$TOKEN_DIR
${3:-}
EOF
	chmod 644 "$QPU_PUBLIC_CONF"
}

reset_state() {
	rm -rf "$TOKEN_DIR" "$SHARED_DIR"
	redis FLUSHALL >/dev/null
}

# The environment SLURM would provide. NODELIST has two nodes so the
# first-node election is actually exercised.
job_env() { # job_env <jobid> <licenses> <thisnode>
	export SLURM_JOB_ID="$1"
	export SLURM_JOB_LICENSES="$2"
	export SLURMD_NODENAME="$3"
	export SLURM_JOB_NODELIST="node01,node02"
	export SLURM_JOB_USER=alice
	export SLURM_JOB_UID=65534
	export SLURM_JOB_ACCOUNT=proj_quantum
}

echo "== a classical job is untouched"
reset_state
write_conf
job_env 1001 "scratch:1" node01
"$PROLOG"
is "prolog exits 0" "$?" "0"
is "no token record" "$(redis KEYS 'qpu:*')" "0"
is "no counter" "$(redis GET licenses:in_use)" ""
is "no token file" "$([ -e "$TOKEN_DIR/1001" ] && echo yes || echo no)" "no"
out=$("$TASKPROLOG" 2>/dev/null)
is "taskprolog exits 0" "$?" "0"
is "taskprolog prints nothing" "$out" ""

echo "== a licensed job on the first node"
reset_state
write_conf
job_env 1002 "qpu:2" node01
"$PROLOG"
is "prolog exits 0" "$?" "0"
token=$(cat "$TOKEN_DIR/1002" 2>/dev/null)
isnt_empty "the token file holds a token" "$token"
case $token in sqed_*) ok "token carries the routing prefix" ;; *) no "token carries the routing prefix" "$token" ;; esac
is "token is prefix + 32 hex" "${#token}" "37"
digest=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
is "the reverse map holds the digest, not the token" "$(redis GET qpu:job:1002)" "$digest"
is "the token itself appears in no key" "$(redis KEYS "*${token}*")" "0"
is "nothing is filed under the plaintext token" "$(redis HGET "qpu:token:$token" 1002)" ""
record=$(redis HGET "qpu:token:$digest" 1002)
isnt_empty "record exists under the job id" "$record"
case $record in *'"n_licenses":2'*) ok "record carries n_licenses" ;; *) no "record carries n_licenses" "$record" ;; esac
case $record in *'"username":"alice"'*) ok "record carries the username" ;; *) no "record carries the username" "$record" ;; esac
case $record in *'"account":"proj_quantum"'*) ok "record carries the account" ;; *) no "record carries the account" "$record" ;; esac
case $record in *'"uid":65534'*) ok "record carries the uid" ;; *) no "record carries the uid" "$record" ;; esac
ttl=$(redis HTTL "qpu:token:$digest" FIELDS 1 1002)
is "the field has a per-field TTL" "$ttl" "1"
is "licenses are accounted" "$(redis GET licenses:in_use)" "2"
is "the license marker holds the amount" "$(redis GET licenses:hpc:1002)" "2"
is "token file mode is 0600" "$(stat -c %a "$TOKEN_DIR/1002")" "600"
is "token file is owned by the job user" "$(stat -c %u "$TOKEN_DIR/1002")" "65534"
is "token directory is root-owned" "$(stat -c %u "$TOKEN_DIR")" "0"

echo "== taskprolog injects the token"
out=$("$TASKPROLOG")
is "taskprolog exits 0" "$?" "0"
is "exactly one line of output" "$(printf '%s' "$out" | wc -l)" "0"
is "the line is an unquoted export" "$out" "export IQM_TOKEN=$token"

echo "== the license hold is exactly-once"
"$PROLOG"
is "a second prolog run does not double-count" "$(redis GET licenses:in_use)" "2"

echo "== a secondary node has no token unless sharing is configured"
rm -f "$TOKEN_DIR/1002"
job_env 1002 "qpu:2" node02
"$PROLOG"
is "prolog exits 0" "$?" "0"
is "no token file on the secondary node" "$([ -e "$TOKEN_DIR/1002" ] && echo yes || echo no)" "no"
out=$("$TASKPROLOG" 2>&1)
is "taskprolog fails the task (fail-fast)" "$?" "1"
case $out in
'print qpu-token:'*) ok "the reason reaches the user as print lines" ;;
*) no "the reason reaches the user as print lines" "$out" ;;
esac
case $out in
*'export '*) no "no token is exported on the failure path" "$out" ;;
*) ok "no token is exported on the failure path" ;;
esac

echo "== with SHARED_TOKEN_DIR a secondary node authenticates"
reset_state
write_conf "$REDIS_HOST" "SHARED_TOKEN_DIR=$SHARED_DIR"
job_env 1003 "qpu:1" node01
"$PROLOG"
token=$(cat "$TOKEN_DIR/1003" 2>/dev/null)
isnt_empty "the job has a token" "$token"
digest=$(printf '%s' "$token" | sha256sum | cut -d' ' -f1)
is "the first node shared the token" "$(cat "$SHARED_DIR/1003")" "$token"
rm -f "$TOKEN_DIR/1003"
job_env 1003 "qpu:1" node02
"$PROLOG"
is "the secondary node's prolog writes nothing (it would race the first)" \
	"$([ -e "$TOKEN_DIR/1003" ] && echo yes || echo no)" "no"
export SHARED_TOKEN_DIR="$SHARED_DIR"
is "its taskprolog reads the shared copy instead" "$("$TASKPROLOG")" "export IQM_TOKEN=$token"
unset SHARED_TOKEN_DIR

echo "== the epilog invalidates and releases"
job_env 1003 "qpu:1" node01
"$EPILOG"
is "epilog exits 0" "$?" "0"
is "the record field is gone" "$(redis HGET "qpu:token:$digest" 1003)" ""
is "the reverse map is gone" "$(redis GET qpu:job:1003)" ""
is "the licenses are given back" "$(redis GET licenses:in_use)" "0"
is "the marker is consumed" "$(redis GET licenses:hpc:1003)" ""
is "the shared copy is removed" "$([ -e "$SHARED_DIR/1003" ] && echo yes || echo no)" "no"
is "the local token file is removed" "$([ -e "$TOKEN_DIR/1003" ] && echo yes || echo no)" "no"

echo "== the epilog finds the record through the reverse map when the token file is gone"
reset_state
write_conf
job_env 1005 "qpu:1" node01
"$PROLOG"
digest=$(redis GET qpu:job:1005)
rm -f "$TOKEN_DIR/1005"
"$EPILOG"
is "the record field is gone" "$(redis HGET "qpu:token:$digest" 1005)" ""
is "the licenses are given back" "$(redis GET licenses:in_use)" "0"

echo "== a re-run epilog does not drive the counter negative"
"$EPILOG"
is "counter unchanged" "$(redis GET licenses:in_use)" "0"

echo "== Redis unreachable: inert, and the job fails fast"
reset_state
write_conf "203.0.113.1"
job_env 1004 "qpu:1" node01
"$PROLOG"
is "prolog still exits 0 (never drains a node)" "$?" "0"
is "no token file, so the job cannot run half-authenticated" "$([ -e "$TOKEN_DIR/1004" ] && echo yes || echo no)" "no"
"$TASKPROLOG" >/dev/null 2>&1
is "taskprolog fails the task" "$?" "1"
write_conf

echo "== the digest matches the contract's test vector"
# A separate process, so the library's defaults don't leak into this shell.
vec=$(bash -c '. "$1" && qpu_token_digest "$2"' _ \
	"$REPO/lib/qpu-token-common.sh" "sqed_0123456789abcdef0123456789abcdef")
is "sha256 of the token string, lowercase hex" "$vec" "d076993cd936cbc3dd50a14d50a0cdeeabffd7146e6aa74bd956ee82be2cb02b"

echo "== license string parsing"
reset_state
write_conf
parse() { # parse <licenses> -> count or "none"
	(
		export SLURM_JOB_LICENSES="$1" LICENSE_NAME=qpu
		# shellcheck source=../lib/qpu-token-common.sh
		. "$REPO/lib/qpu-token-common.sh"
		qpu_license_count || printf 'none'
	)
}
is "qpu:2"            "$(parse 'qpu:2')" "2"
is "bare qpu means 1" "$(parse 'qpu')" "1"
is "second in a list" "$(parse 'scratch:4,qpu:3')" "3"
is "remote license"   "$(parse 'qpu@slurmdb:5')" "5"
is "remote, no count" "$(parse 'qpu@slurmdb')" "1"
is "qpux is not qpu"  "$(parse 'qpux:1')" "none"
is "empty"            "$(parse '')" "none"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
