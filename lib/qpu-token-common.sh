# shellcheck shell=bash
# Shared helpers for the Sqed QPU token prolog/epilog scripts.
#
# Sourced, never executed. Every function here is safe to call from a SLURM
# prolog or epilog: nothing blocks without a timeout, and nothing writes to
# stdout (a prolog's stdout is not read, and TaskProlog's stdout is a protocol).

QPU_CONF="${QPU_CONF:-/etc/sqed/qpu-token.conf}"
QPU_LIBDIR="${QPU_LIBDIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"

qpu_log() { logger -t qpu-token -p daemon.info -- "$*" 2>/dev/null || true; }
qpu_warn() { logger -t qpu-token -p daemon.warning -- "$*" 2>/dev/null || true; }

# Loads the configuration and applies defaults. Returns non-zero if the file is
# unusable or a required value is missing — callers then go inert.
qpu_load_conf() {
	if [ ! -r "$QPU_CONF" ]; then
		qpu_warn "config $QPU_CONF is missing or unreadable"
		return 1
	fi
	# shellcheck disable=SC1090
	. "$QPU_CONF" || return 1

	: "${LICENSE_NAME:=qpu}"
	: "${TOKEN_DIR:=/run/qpu}"
	: "${TOKEN_PREFIX:=sqed_}"
	: "${GRACE_SECONDS:=600}"
	: "${MAX_WALLTIME_SECONDS:=86400}"
	: "${REDIS_PORT:=6379}"
	: "${REDIS_TIMEOUT:=2}"
	: "${SHARED_TOKEN_DIR:=}"

	if [ -z "${REDIS_HOST:-}" ]; then
		qpu_warn "config $QPU_CONF sets no REDIS_HOST"
		return 1
	fi
	return 0
}

# Prints the number of QPU licenses this job holds, or returns 1 for a job that
# holds none — the fast path for every classical job on the cluster, which must
# cost nothing but this string test.
#
# SLURM_JOB_LICENSES is a comma-separated list of `name`, `name:count` or
# `name@server:count`.
qpu_license_count() {
	local list=${SLURM_JOB_LICENSES:-} entry name count
	case ",$list," in
	*",${LICENSE_NAME}:"* | *",${LICENSE_NAME},"* | *",${LICENSE_NAME}@"*) ;;
	*) return 1 ;;
	esac

	local IFS=,
	for entry in $list; do
		name=${entry%%:*}
		count=${entry#"$name"}
		count=${count#:}
		name=${name%%@*}
		if [ "$name" = "$LICENSE_NAME" ]; then
			count=${count:-1}
			case $count in
			'' | *[!0-9]*) return 1 ;;
			esac
			printf '%s' "$count"
			return 0
		fi
	done
	return 1
}

# The first host of the allocation, which is where the batch step runs. Used to
# elect exactly one writer per job. Avoids forking `scontrol` in the common
# case where the nodelist needs no expansion.
qpu_first_node() {
	local list=${SLURM_JOB_NODELIST:-}
	[ -n "$list" ] || return 1
	case $list in
	*'['*) scontrol show hostnames "$list" 2>/dev/null | head -1 ;;
	*) printf '%s' "${list%%,*}" ;;
	esac
}

qpu_is_first_node() {
	local first
	first=$(qpu_first_node) || return 1
	[ -n "$first" ] && [ "$first" = "${SLURMD_NODENAME:-}" ]
}

# 128 bits of urandom, hex, with the prefix the gateway routes on.
qpu_mint_token() {
	local hex
	hex=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n') || return 1
	[ ${#hex} -eq 32 ] || return 1
	printf '%s%s' "$TOKEN_PREFIX" "$hex"
}

# The Redis key a token is filed under: its SHA-256, never the token itself.
#
# Anyone who can read Redis would otherwise read every live token and could
# submit as any user. The gateway hashes the token a client presents and looks
# the digest up, so a digest identifies a record but cannot be presented. The
# contract, shared with the gateway: lowercase hex SHA-256 of the full token
# string, routing prefix included.
qpu_token_digest() {
	local digest
	digest=$(printf '%s' "$1" | sha256sum 2>/dev/null) || return 1
	digest=${digest%% *}
	[ ${#digest} -eq 64 ] || return 1
	printf '%s' "$digest"
}

# Runs a fixed pipeline of Redis commands (stdin: one per line, TAB-separated
# arguments) under a hard timeout, because bash's /dev/tcp has no connect
# timeout and a prolog must finish inside MessageTimeout.
qpu_redis_run() {
	# `timeout` must read the value from this shell, not from the environment
	# prefix (which only the forked process sees), hence the local copy.
	local deadline=$REDIS_TIMEOUT
	REDIS_HOST="$REDIS_HOST" \
		REDIS_PORT="$REDIS_PORT" \
		REDIS_TIMEOUT="$deadline" \
		REDIS_AUTH_USER="${REDIS_AUTH_USER:-}" \
		REDIS_AUTH_PASS="${REDIS_AUTH_PASS:-}" \
		timeout "$deadline" "$QPU_LIBDIR/qpu-redis"
}

# Writes the token where the job's own tasks can read it and nobody else can.
#
# TOKEN_DIR must be root-owned: if a user can create the path first they can
# plant a symlink and have this function write the token somewhere they can
# read it. Created 0755 root here, and the file is 0600 owned by the job user.
qpu_write_token_file() {
	local token=$1 path="$TOKEN_DIR/${SLURM_JOB_ID}" tmp
	mkdir -p "$TOKEN_DIR" 2>/dev/null || return 1
	chmod 0755 "$TOKEN_DIR" 2>/dev/null || true
	tmp="${path}.$$"
	(
		umask 077
		printf '%s' "$token" >"$tmp"
	) || return 1
	chown "${SLURM_JOB_UID:-0}" "$tmp" 2>/dev/null || true
	chmod 0600 "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$path" 2>/dev/null || {
		rm -f "$tmp"
		return 1
	}
	return 0
}

qpu_read_token_file() {
	local path="$TOKEN_DIR/${SLURM_JOB_ID}"
	[ -r "$path" ] || return 1
	cat "$path" 2>/dev/null
}

qpu_remove_token_file() {
	rm -f "$TOKEN_DIR/${SLURM_JOB_ID}" 2>/dev/null || true
}

# Multi-node support, off unless SHARED_TOKEN_DIR is configured: the first node
# leaves a copy on a shared filesystem, which the OTHER NODES' TaskProlog reads.
# Deliberately not read by their prologs — those run concurrently with this one,
# so a secondary node would race the write; steps launch only after every node's
# prolog has finished. Same ownership rules as the local file, and the directory
# must likewise be root-owned.
qpu_share_token() {
	local token=$1 path="$SHARED_TOKEN_DIR/${SLURM_JOB_ID}" tmp
	[ -n "$SHARED_TOKEN_DIR" ] || return 0
	mkdir -p "$SHARED_TOKEN_DIR" 2>/dev/null || return 1
	tmp="${path}.$$"
	(
		umask 077
		printf '%s' "$token" >"$tmp"
	) || return 1
	chown "${SLURM_JOB_UID:-0}" "$tmp" 2>/dev/null || true
	mv -f "$tmp" "$path" 2>/dev/null || {
		rm -f "$tmp"
		return 1
	}
	return 0
}

qpu_remove_shared_token() {
	[ -n "$SHARED_TOKEN_DIR" ] || return 0
	rm -f "$SHARED_TOKEN_DIR/${SLURM_JOB_ID}" 2>/dev/null || true
}
