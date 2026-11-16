# Lagrange prolog/epilog — per-job QPU tokens for SLURM

SLURM `Prolog`, `TaskProlog` and `Epilog` scripts that give every hybrid job
holding the `qpu` license its own QPU access token, published on the Redis bus
the [QC Gateway](https://github.com/LINKS-Foundation-CPE/QC-Gateway) reads.
Ordinary shell scripts: nothing is loaded into `slurmd` or `slurmstepd`, and no
package needs installing on the cluster.

Together with the gateway's `sqed` plugins they make up **Sqed**, the
*Slurm-based Quantum Execution Director*: users submit circuits from inside
their SLURM jobs, SLURM decides who may use the quantum computer and for how
long, and the gateway authenticates each job by its token and reports its work
under the job's SLURM account. These scripts are the scheduler half; the
gateway's `sqed` auth and site plugins are the other. Part of the
[Lagrange stack](https://links-foundation-cpe.github.io/Lagrange-stack-docs/),
developed in the context of the **QTech Piemonte** strategic initiative.

<a href="https://linksfoundation.com"><img src="docs/assets/logo-links.png" alt="LINKS Foundation" height="60"></a>&nbsp;&nbsp;&nbsp;<a href="https://www.polito.it"><img src="docs/assets/logo-polito.png" alt="Politecnico di Torino" height="60"></a>&nbsp;&nbsp;&nbsp;<a href="https://www.inrim.it"><img src="docs/assets/logo-inrim.jpg" alt="INRIM" height="60"></a>

---

The same job can be done by a SPANK plugin. These scripts are the implementation
we maintain because a SPANK plugin is compiled against SLURM's headers and
`dlopen`ed into privileged daemons, so every upgrade the cluster vendor ships
needs a rebuild, and a mismatch surfaces at runtime inside `slurmd`. These scripts have no ABI — they
consume documented environment variables, which are stable across versions.

The trade is a fork per job and per task rather than an in-process callback. On a
cluster with very high job throughput that is the reason to prefer the plugin.

## What it does

| Hook | Runs as | For a job holding the license |
|---|---|---|
| `prolog.d/50-qpu-token` | root, every allocated node | The **first node** mints a token, publishes the record the gateway authenticates against, accounts the licenses the job holds, and drops the token in a local file, mode 0600, owned by the job user. Other nodes do nothing. |
| `taskprolog/qpu-token` | the **job user**, every task | Reads that file and prints `export IQM_TOKEN=…`, which slurmd puts in the task's environment. No file ⇒ exits non-zero ⇒ the task dies before exec. |
| `epilog.d/50-qpu-token` | root, every allocated node | The first node invalidates the record and gives the licenses back; every node removes the file. |

For any job that does not hold the license, all three read a small config file,
test one environment variable and exit. No fork, no network, no Redis.

### Two properties worth understanding

**A job that cannot authenticate fails immediately.** If the record could not be
published — Redis unreachable, say — the prolog deliberately leaves no token
file, and `TaskProlog` then fails the task at first step launch. The alternative
is worse: a job that runs to completion burning its allocation while every
circuit submission comes back 401. Both prolog and epilog, by contrast, *always*
exit 0, because a failing prolog or epilog drains the node.

**The license hold is exactly-once.** A per-job marker key carries the amount, so
a re-run prolog cannot double-count and a re-run epilog cannot drive the counter
negative. The record's TTL (partition MaxTime + grace) is the backstop for an
epilog that never ran at all.

## Install

Copy `lib/`, `taskprolog/` and the config to the cluster — all nodes, plus
wherever the prolog runs:

```sh
install -d -m 0755 /opt/sqed /etc/sqed
cp -r lib taskprolog /opt/sqed/
install -m 0600 etc/qpu-token.conf.example   /etc/sqed/qpu-token.conf
install -m 0644 etc/qpu-token.public.example /etc/sqed/qpu-token.public
install -m 0755 prolog.d/50-qpu-token /etc/slurm/prolog.d/50-qpu-token
install -m 0755 epilog.d/50-qpu-token /etc/slurm/epilog.d/50-qpu-token
```

Then in `slurm.conf`:

```
Prolog=/etc/slurm/prolog.d/*
Epilog=/etc/slurm/epilog.d/*
TaskProlog=/opt/sqed/taskprolog/qpu-token
```

`Prolog` and `Epilog` accept a glob, so these are drop-ins alongside whatever the
site already runs. **`TaskProlog` does not** — it is a single pathname, so a site
that already has one must call ours from it:

```sh
/opt/sqed/taskprolog/qpu-token || exit $?
```

Edit `/etc/sqed/qpu-token.conf` — at minimum `REDIS_HOST`, and
`MAX_WALLTIME_SECONDS` to the MaxTime of the partition carrying the license.
Every setting is documented in the file.

### Requirements

- **bash** and coreutils on any node that runs the prolog or epilog.
  `TaskProlog` is POSIX `sh`.
- **Redis 7.4 or later**, reachable from wherever the prolog runs — the token
  records use per-field TTLs (`HPEXPIRE`), which do not exist before 7.4.
  Nothing else on the cluster needs to reach Redis; compute nodes do not.
- No `redis-cli`: `lib/qpu-redis` speaks just enough RESP over bash's `/dev/tcp`.
  Credentials are passed through the environment, never argv, so nothing secret
  shows up in `ps`.

### Multi-node jobs

By default the token exists only on the **first node** of the allocation, which
is where the batch step runs — so single-node jobs and the usual "submit circuits
from rank 0" pattern need nothing. To let every node of a job authenticate, set
`SHARED_TOKEN_DIR` to a root-owned directory on a shared filesystem: the first
node leaves a copy there, and the other nodes' **`TaskProlog`** picks it up. It
has to be read there rather than in their prologs, because prologs run
concurrently across the allocation and would race the write, whereas steps are
not launched until every node's prolog has finished. Put `SHARED_TOKEN_DIR` in
`qpu-token.public` as well, since `TaskProlog` is what reads it.

A task on a node with no token is told which of the two situations it is in
rather than just failing.

### Security notes

- `TOKEN_DIR` and `SHARED_TOKEN_DIR` **must be root-owned**, and must not be
  world-writable directories like `/tmp` or `/dev/shm`. A user who can create the
  path first can plant a symlink and have the root prolog write a token where
  they can read it.
- The token authorises circuits only against its own job, so a user reading their
  own token is harmless and expected.
- `/etc/sqed/qpu-token.conf` holds the Redis credentials: root-only, 0600.
  `TaskProlog` runs as the user and never reads it; the two non-secret values it
  needs live in `qpu-token.public`.
- Give the Redis user the narrowest grant that works — write on `qpu:*` and
  `licenses:hpc:*`, read-write on `licenses:in_use`, and `EVAL`. Write access to
  Redis is equivalent to minting tokens.
- Redis never holds a token, only its SHA-256 (see the contract below), so
  **read** access to Redis does not let anyone authenticate as a job.

## Redis contract

Read by the gateway's `SqedAuthPlugin`:

| Key | Written by | Contents |
|---|---|---|
| `qpu:token:<digest>` | prolog, first node | Hash, one field per job id, each a JSON record `{uid, username, account, n_licenses, issued_at, expires_at}`, with a per-field TTL. The gateway sums `n_licenses` over live fields. |
| `qpu:job:<job_id>` | prolog, first node | Reverse map to the token's **digest**, for the epilog and for operators |
| `licenses:hpc:<job_id>` | prolog / epilog | The amount this job holds: both the exactly-once guard and the value to give back |
| `licenses:in_use` | prolog / epilog | Licenses held by work running right now |

`<digest>` is the **lowercase hex SHA-256 of the full token string**, routing
prefix included. The token itself is never written to Redis. It reaches the job
only through the root-owned token file, and the gateway hashes the token a client
presents before looking it up. Test vector, also checked by the gateway's tests:

```
sha256("sqed_0123456789abcdef0123456789abcdef")
  = d076993cd936cbc3dd50a14d50a0cdeeabffd7146e6aa74bd956ee82be2cb02b
```

Field names are the gateway's contract — do not rename them.

Array elements are separate jobs, so each writes its own field under its own
token. Heterogeneous jobs hold their licenses on the leader component, which is
the only one that publishes a record.

## Tests

```sh
./tests/run.sh    # 58 cases against a real Redis, in Docker. No SLURM needed.
./tests/lint.sh   # shellcheck
```

The suite drives the scripts exactly as SLURM does — environment in, exit status
and side effects out — and verifies the Redis state with the same client the
scripts use. It covers the classical-job fast path, the record and its per-field
TTL, file ownership and mode, token injection and its exact output format,
exactly-once accounting on both sides, the first-node election,
`SHARED_TOKEN_DIR`, the fail-fast path with Redis unreachable, and
license-string parsing including remote (`qpu@server:N`) licenses, and that
no token is ever written to Redis.

### On a live cluster

Verified end to end on a containerised SLURM
test bed (SLURM 23.11.10, two workers, remote `qpu` licenses): token injected in
batch and `srun` steps, record and per-field TTL, file mode and ownership,
`licenses:in_use` matching SLURM's own `Used`, job arrays, both multi-node cases,
epilog cleanup, and a job failing 1:0 with Redis unreachable **without draining a
node**. Procedure, results and the fixtures are in
[tests/integration/](tests/integration/README.md).

That run caught two things the unit suite structurally could not: guidance written
to stderr never reaches the user (slurmd parses TaskProlog's merged output and
drops anything that is not `export`/`unset`/`print`), and reading the shared token
copy in a secondary node's *prolog* races the first node's write. Both fixed; see
the integration README.

## Why Redis holds digests

Until November 2026 the token was the key name of `qpu:token:<token>` and the
value of the reverse map, so read access to Redis was equivalent to token theft:
a reader could enumerate `qpu:token:*` and submit as any running job. Records are
now filed under the token's SHA-256. A leaked digest cannot be presented as a
bearer token, because the gateway hashes whatever it is given.

This does nothing about a Redis **write** leak, which is still equivalent to
minting tokens: keep the ACLs above.

**Upgrading** changes the contract on both sides, so upgrade these scripts and
the gateway together, with no licensed job running: a record written under the
old layout is not found by the new gateway, and the reverse is also true.

## Not yet done

- No wall-time accounting record is written; the epilog has
  `SLURM_JOB_START_TIME` available for one.
- Not tried: heterogeneous jobs (SLURM 23.11.10 rejects licenses on non-leader
  components, so only the leader should publish a record; these scripts rely on
  that behaviour, but it has not been tested here), and `salloc` interactive sessions.

## Citation

If you use these scripts in your research, please cite the Lagrange paper:

```bibtex
@misc{viviani2026lagrangeoperatingitalyspubliclyaccessible,
      title={Lagrange: Operating Italy's First Publicly-Accessible Quantum Computer for Research and Education},
      author={Paolo Viviani and Fabrizio Bertone and Giacomo Vitali and Emanuele Dri and Federico Stirano and Giuseppe Caragnano and Francesco Lubrano and Marco Cipollini and Martina Giovalli and Chiara Vercellino and Alberto Scionti and Virginia Ajani and Antonino Nespola and Olivier Terzo and Matteo Cocuzza and Bartolomeo Montrucchio and Giovanna Turvani and Gianluca Bertaina and Marco Coisson and Davide Calonico and Fabrizio Pirri and Pietro Asinari},
      year={2026},
      eprint={2604.21695},
      archivePrefix={arXiv},
      primaryClass={quant-ph},
      url={https://arxiv.org/abs/2604.21695},
}
```

## Licence

EUPL-1.2. See [LICENSE](LICENSE).
