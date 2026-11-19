#!/usr/bin/env bash
# Static analysis. Needs Docker only.
#
#   ./tests/lint.sh
#
# --source-path=SCRIPTDIR lets shellcheck resolve the `source=` directives, so
# the drop-ins are checked against the library they actually source.
set -euo pipefail
REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
docker run --rm -v "$REPO":/mnt:ro -w /mnt "${SHELLCHECK_IMAGE:-koalaman/shellcheck:stable}" \
	-x --source-path=SCRIPTDIR \
	lib/qpu-redis \
	lib/qpu-token-common.sh \
	prolog.d/50-qpu-token \
	epilog.d/50-qpu-token \
	taskprolog/qpu-token \
	tests/run.sh \
	tests/cases.sh \
	tests/availability.sh \
	availability/qpu-availability
echo "shellcheck: clean"
