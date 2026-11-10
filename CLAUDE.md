# CLAUDE.md

Orientation for AI assistants (and new human contributors) working on
**prolog-epilog**. Read this before making changes.

## What this repository is

The SLURM `Prolog` / `TaskProlog` / `Epilog` scripts that mint a per-job QPU
access token for hybrid jobs holding the `qpu` license, and publish it on the
Redis bus the QC Gateway authenticates against. Plain shell — nothing is loaded
into `slurmd` or `slurmstepd`, nothing is installed on the cluster.

Together with the QC Gateway's `sqed` auth and site plugins, these scripts make
up **Sqed** (*Slurm-based Quantum Execution Director*). The name belongs to the
pair; no repository is branded with it. Anything else that writes the same
records (a SPANK plugin, say) must not run alongside these scripts: two
provisioners racing on the same keys is not a supported configuration.

[README.md](README.md) is the reference for what each hook does, the Redis
contract, installation and the test suite. It is current; do not restate it here.

## Invariants that must not be broken

1. **The prolog and the epilog always exit 0.** A failing prolog or epilog
   *drains the node*, which is a far worse outcome than a job that cannot
   authenticate. Handle every error and exit 0 anyway.

2. **`TaskProlog` fails when there is no token file.** This is the deliberate
   counterpart to the rule above: provisioning failures are surfaced by killing
   the task before `exec`, so the job fails immediately instead of burning its
   allocation while every circuit submission comes back 401.

3. **License accounting is exactly-once.** A per-job marker key carries the
   amount, so a re-run prolog cannot double-count and a re-run epilog cannot
   drive the counter negative. Any change to the accounting has to preserve that
   under re-entry, and the record TTL (partition MaxTime + grace) is the backstop
   for an epilog that never ran.

4. **The Redis contract is shared.** The key layout (records filed under the
   token's SHA-256, never the token), the per-field TTL and the reverse map are
   consumed by the gateway's auth plugin. Changing the shape here means
   changing the gateway in lockstep, or it stops authenticating jobs.
   `README.md` §Redis contract is the authoritative statement of it and is kept
   in this repository on purpose: the contract must be readable by anyone
   holding either side.

5. **The classical-job fast path stays free.** A job without the license reads a
   small config file, tests one environment variable and exits: no fork, no
   network, no Redis. Every hook runs for every job on the cluster.

## Before opening a merge request

```sh
./tests/lint.sh   # shellcheck, in Docker
./tests/run.sh    # 58 cases against a real Redis 7.4+, in Docker. No SLURM needed.
```

Both must pass. The suite drives the scripts the way SLURM does — environment
in, exit status and side effects out — so a behavioural change almost always
needs a case added. End-to-end verification on a live cluster is a separate,
manual procedure: [tests/integration/](tests/integration/README.md), run on the
`slurm-docker-compose` test bed.

## What NOT to do

- Don't add a runtime dependency. The hooks run as root on every node for every
  job; the only things they may need are a shell, `redis-cli` and coreutils.
- Don't log a token. The record is the secret; the file is mode 0600 for a
  reason.
- Don't make the hooks SLURM-version-specific. Their whole advantage over the
  SPANK plugin is that they consume documented environment variables and have no
  ABI.

## Working on this repository on its own

Clone it anywhere and it is workable: everything needed to build, test and change
it is in here. Nothing in this file depends on another repository being at hand,
or on any private document.

What it talks to, and where each contract is written down:

| Counterpart | Interface | Where the contract is |
|---|---|---|
| QC Gateway | The Redis token records its auth plugin reads to authenticate a job's submissions | `README.md` §Redis contract — the authoritative statement of the key layout, the per-field TTL and the reverse map |
| SLURM | `Prolog`, `TaskProlog`, `Epilog`, driven entirely by documented environment variables — no ABI, no linkage | `README.md` §What it does |

The Redis contract is the only cross-repository knowledge you need, and it is
written down here in full. If you change its shape, it changes here and in the
gateway's auth plugin at once, or jobs stop authenticating.

Every repository in the stack carries a `CLAUDE.md` in this same shape, so the
same is true read from the other side. If you find yourself needing a fact that
is not in one of them, that is a gap worth fixing in the repository that owns the
fact — not a reason to go looking for a central document.

## Public mirror

This repository is published on GitHub as
[LINKS-Foundation-CPE/Lagrange-prolog-epilog](https://github.com/LINKS-Foundation-CPE/Lagrange-prolog-epilog).
GitLab `main` is where work happens. The `public` branch holds one squashed
commit per release, with the same tree as `main` at that release, and is what
GitHub's `main` carries:

```bash
git checkout public
git rm -rq . && git checkout <release-tag> -- .   # exactly the release's tree
git commit -m "Release <version>"
git tag public/<version>
git push origin public public/<version>
git push github public:main
git push github public/<version>:refs/tags/<version>
```

Never push `main` to GitHub: it carries the private history.
