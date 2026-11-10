# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions use **CalVer**, `YYYY.MM.PATCH`, in step with the other Lagrange stack
components: `YYYY.MM` is the month the release was cut, and `.PATCH` counts
fix-only follow-ups within that month.

## [Unreleased]

## [2026.11.0] — 2026-11-10

First public release.

### Added
- `Prolog`, `TaskProlog` and `Epilog` hooks that mint a per-job QPU token for
  jobs holding the `qpu` license, publish its record on the gateway's Redis bus,
  and remove it when the job ends.
- **Records are filed under the token's SHA-256**, never the token:
  `qpu:token:<sha256>` and the reverse map `qpu:job:<id>`. Reading Redis does
  not reveal a usable token. Needs a QC Gateway at 2026.11.0 or later.
- Exactly-once license accounting (`licenses:in_use`) under re-run prologs and
  epilogs.
- Multi-node jobs: the token lives on the first node, or on every node with
  `SHARED_TOKEN_DIR` on a shared filesystem.
- A unit suite (`tests/run.sh`, 58 cases against a real Redis) and a lint step;
  a manual end-to-end procedure for a live cluster (`tests/integration/`).
