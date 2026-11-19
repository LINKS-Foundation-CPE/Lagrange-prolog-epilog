#!/usr/bin/env bash
# Runs the test suite against a real Redis. Needs Docker and nothing else —
# no SLURM, because the scripts are driven by their environment and the suite
# supplies exactly what SLURM would.
#
#   ./tests/run.sh
#
# Redis 7.4 or later is required: the per-field TTL (HPEXPIRE/HTTL) the token
# records use does not exist before that.

set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NET=qpu-token-test-$$
REDIS=qpu-token-redis-$$
REDIS_IMAGE=${REDIS_IMAGE:-redis:7.4-alpine}
TEST_IMAGE=${TEST_IMAGE:-debian:stable-slim}

cleanup() {
	docker rm -f "$REDIS" >/dev/null 2>&1 || true
	docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker network create "$NET" >/dev/null
docker run -d --name "$REDIS" --network "$NET" "$REDIS_IMAGE" >/dev/null

# Wait for it rather than sleeping blind.
for _ in $(seq 1 30); do
	if docker exec "$REDIS" redis-cli PING 2>/dev/null | grep -q PONG; then break; fi
	sleep 0.5
done

docker run --rm --network "$NET" \
	-v "$REPO":/repo:ro \
	-e REPO=/repo \
	-e REDIS_HOST="$REDIS" \
	"$TEST_IMAGE" \
	bash -c 'bash /repo/tests/cases.sh && apt-get -qq update >/dev/null && apt-get -qq install -y curl >/dev/null && bash /repo/tests/availability.sh'
