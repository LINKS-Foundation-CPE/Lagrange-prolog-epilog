# Contributing to Lagrange prolog/epilog

Thanks for your interest! If you are an AI assistant working here, also read
[CLAUDE.md](CLAUDE.md): it lists the invariants the hooks must keep.

## Before you change a hook

These scripts run as root on every node of a cluster, for every job. Three rules
are not negotiable:

- **The prolog and the epilog always exit 0.** A failing prolog or epilog drains
  the node.
- **No new runtime dependency.** A shell, `redis-cli` and coreutils, nothing else.
- **Never log a token.**

The Redis key layout is a contract shared with the
[QC Gateway](https://github.com/LINKS-Foundation-CPE/QC-Gateway)'s `sqed` auth
plugin. A change to it has to land in both repositories, in the same release.

## Testing a change

```bash
tests/lint.sh     # shellcheck
tests/run.sh      # the unit suite, against a throwaway Redis container
```

Both must pass. A behavioural change almost always needs a case in
`tests/cases.sh`. Changes to multi-node or license behaviour should also be run
through [tests/integration/](tests/integration/README.md) on a real cluster.

## Pull requests

1. Fork and branch with a descriptive name (`fix/epilog-reverse-map`).
2. Keep the change focused, and add a line to `CHANGELOG.md` under
   `[Unreleased]`.
3. Describe what you changed, why, and how you tested it.

By contributing you agree that your contribution is licensed under the
[EUPL-1.2](LICENSE), like the rest of the project.
