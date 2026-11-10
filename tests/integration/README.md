# Integration test on a live SLURM cluster

Run against a containerised SLURM test bed (`slurm-docker-compose`): SLURM
**23.11.10**, two workers, remote `qpu` licenses registered in slurmdbd. First run: 2026-07-29, all scenarios below verified.

The unit suite (`tests/run.sh`) proves the scripts' logic against a real Redis
without SLURM. This proves the parts only SLURM can exercise: that the hooks are
called at all, in the contexts assumed, with the environment assumed, and that
failures land where intended.

## Setup

```sh
cd <slurm-docker-compose>

# 1. Install the scripts the way the README describes, on the headnode and both
#    workers. Paths inside are absolute, so run compose from the test bed dir.
docker compose -f docker-compose.yml \
               -f <prolog-epilog>/tests/integration/compose.sqed.yml up -d

# 2. Point slurm.conf at them, and disable the SPANK plugin so only one
#    provisioner is active (slurm-config/slurm.conf, then restart):
#      Prolog=/opt/sqed/prolog.d/*
#      Epilog=/opt/sqed/epilog.d/*
#      TaskProlog=/opt/sqed/taskprolog/qpu-token
#    and comment the qc_gateway_spank line in slurm-config/plugstack.conf

# 3. Register the remote license and give the test user an account — the account
#    is the billing entity, and without an association SLURM reports none.
docker exec slurm-headnode bash /tmp/setup-qpu-licenses.sh 4
docker exec slurm-headnode sacctmgr -i add account name=proj_quantum cluster=example-cluster
docker exec slurm-headnode sacctmgr -i add user name=user account=proj_quantum cluster=example-cluster

# 4. Submit as the unprivileged user
docker exec -u user slurm-headnode bash -lc 'cd /shared/user && sbatch --account=proj_quantum quantum.sh'
```

`qpu-token.conf` here points at `jobs-redis-dev`, the QC Gateway dev stack's
Redis (7.4.9), which the test bed's network is already attached to — so the
records land in the same Redis the gateway reads.

Job fixtures are in `jobs/`. Note the license is requested as
**`--licenses=qpu@qc_gateway:2`**: it is a *remote* license, and the bare name is
rejected with "Invalid license specification".

## What was verified

| Scenario | Result |
|---|---|
| Classical job | `IQM_TOKEN` unset, no Redis keys, no token file — the hooks are inert |
| Licensed batch job | `IQM_TOKEN` present **in the batch step**, and in `srun` steps |
| Record contents | `{"uid":1000,"username":"user","account":"proj_quantum","n_licenses":3,…}` |
| Per-field TTL | `HTTL` = 4177s of the configured 4200 (MaxTime 3600 + grace 600) |
| Token file | mode `0600`, owned by the job user, on tmpfs |
| License accounting | `licenses:in_use` = 3 exactly matching SLURM's own `Used=3` |
| Job array `0-2` | three job ids, three tokens, one hash field each, counter = 3 |
| Multi-node, no `SHARED_TOKEN_DIR` | node 1 works; the task on node 2 fails with the reason printed |
| Multi-node, `SHARED_TOKEN_DIR` set | both nodes get the same token, `srun` exits 0 |
| Epilog | records, markers, local and shared token files all gone; counter back to 0 |
| Redis unreachable | job **FAILED 1:0** at the batch step with the reason shown, and **neither node drained** |
| Recovery | reconnect Redis, next job succeeds |

`scontrol show hostnames` on a bracketed `SLURM_JOB_NODELIST`
(`slurm-worker[1-2]`) was exercised for real by the first-node election.

## Two bugs this caught that the unit suite could not

**1. Guidance written to stderr never reached the user.** slurmd runs `TaskProlog`
with stdout *and* stderr on one pipe (`run_command` dup2s both) and then parses
the result, discarding every line that is not `export`/`unset`/`print`. So the
"here is why your job died" message was silently swallowed and all the user saw
was slurmd's own `TaskProlog failed status=1`. Fixed by emitting `print` lines,
which slurmd writes to the step's stdout.

**2. `SHARED_TOKEN_DIR` was racy.** Prologs run **concurrently on every allocated
node**, so a secondary node's prolog could read the shared copy before the first
node had written it — which is exactly what happened: worker2 got no token, and
running its prolog by hand afterwards worked. Fixed by reading the shared copy in
`TaskProlog` instead, which SLURM does not run until the prolog has completed on
every node. Secondary-node prologs now do nothing at all.

## Notes for whoever runs this next

- **`sed -i` breaks a single-file bind mount.** It writes a new inode, and the
  container stays pinned to the old one, so config edits appear to be ignored.
  Truncate in place, or recreate the container. Two of my "failures" were this.
- Recreating the headnode resets slurmctld's state, so job ids restart at 1.
- To test the Redis-unreachable path, `docker network disconnect
  slurm-docker-compose_slurm-net jobs-redis-dev` is cleaner than editing config —
  and remember to reconnect.
- `jobs-redis-dev` is shared with the running dev stack. Never `FLUSHALL` it.
  `licenses:in_use` is shared state: record its value first and check it returns
  there. It did — 0 before, 0 after.
