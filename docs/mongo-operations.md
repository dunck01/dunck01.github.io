# MongoDB Manual Operations

Independent self-hosted slice. Deployment opt-in is described below; no global
multi-engine production-readiness claim follows from packaging these tools.
Integration entry point: `MongoOperations(IDockerClient docker, IConfiguration cfg)`;
`Task<IResult> ExecuteAsync(string operation, HttpRequest http, CancellationToken ct)`.
Register this class as a singleton. Caller must authenticate/authorize the company;
Docker ownership labels are a second boundary, not HTTP authentication.

## Configuration

| Setting | Default | Meaning |
| --- | --- | --- |
| `MULTI_ENGINE_OPERATIONS_ENABLED` | `false` | Explicit opt-in |
| `MONGO_OPERATIONS_RUNTIME_IMAGE` | `dunckops-mongo-operations-runtime:development` | Preinstalled trusted runtime, resolved to image ID; never auto-pulled |
| `DUNCKOPS_LOCAL_BACKUP_VOLUME` | `dunckops-local-backups` | Precreated local named volume without driver options |

### Deployment Opt-In

Local Compose builds `Dockerfile.mongo-operations-runtime` from repository root.
Production profile `tools` uses
`ghcr.io/${REGISTRY_OWNER:-dunck01}/dunckops-mongo-operations-runtime:${DUNCKOPS_VERSION}`.
Install/update pull MySQL, MariaDB and Mongo operation tools only when
`MULTI_ENGINE_OPERATIONS_ENABLED=true`, identical on API and agent. Default false
downloads none of these new tools. Explicit helper image overrides must already
exist locally: inspect first, fail closed if missing, never pull an override from
an unintended registry. Empty override selects the published release image.
Offline bundles include these tools without enabling operations. Neither packaging
nor build announces global production readiness. Never start the tools profile as
database provisioning; operational containers remain agent-owned.

Build: `docker build -f Dockerfile.mongo-operations-runtime -t dunckops-mongo-operations-runtime:development .`.
Base image is official MongoDB Community `8.0.12`, digest-pinned. Database Tools
`100.12.2` are checked during build; PyMongo `4.13.2` and dnspython `2.8.0` are pinned.
Operator must evaluate MongoDB Community/SSPL and dependency license terms before
deployment. This slice neither accepts interactive license terms nor claims a
commercial MongoDB license.

## Request And Response

All operations accept exactly this envelope, with typed per-operation parameters:

```json
{
  "companyId": "9c6abe9c-573b-4932-a089-2d6bec68a8c3",
  "operationId": "4131d146-7260-40fb-8fc2-40b1ab2564d7",
  "parameters": {
    "sourceContainer": "managed-mongo-primary",
    "replicaSet": "rs0",
    "username": "operator",
    "password": "<transient secret>"
  }
}
```

Example above is `snapshot`. UUIDs must be nonempty. Unknown/duplicate JSON fields,
invalid parameter types, oversized bodies (>64 KiB) and control characters in
credentials are rejected. `operation` comes from the integration caller, not body.
Do not log request bodies. Credentials must travel over authenticated HTTPS or a
trusted local transport; never place them in shell history, command arguments,
Docker environment variables, or URLs logged by the caller.

Every HTTP result has this ROOT shape, including failures:

```json
{
  "operationId": "4131d146-7260-40fb-8fc2-40b1ab2564d7",
  "engine": "mongodb",
  "operation": "snapshot",
  "state": "completed",
  "details": {
    "snapshotId": "4131d146-7260-40fb-8fc2-40b1ab2564d7",
    "lastClusterTime": { "seconds": 1791027772, "increment": 8 },
    "manifestSha256": "<SHA-256>",
    "format": "mongodump-directory-with-oplog"
  }
}
```

Before envelope validation, failures use the empty UUID. Native stderr is discarded;
errors return fixed codes, not exceptions, URIs, documents or credentials.

| Operation | Exact required parameters | Optional parameters | Actual behavior |
| --- | --- | --- | --- |
| `snapshot` | `sourceContainer`, `replicaSet`, `username`, `password` | none | Consistent full logical dump with native oplog; snapshot ID = operation ID |
| `start-log-collection` | snapshot fields plus `snapshotId` | none | Dedicated persistent owned container; HTTP 202 means started, not full coverage verified |
| `stop-log-collection` | `collectionId` | none | Stop/remove only collector matching company/collection ownership labels; no source stop |
| `verify-restore` | `snapshotId` | none | Native base restore into disposable empty isolated target, dataset aggregates/hash |
| `restore-pitr` | `snapshotId`, `collectionId` | Exactly one non-null `targetClusterTime` or `targetTimeUtc` | Native base+contiguous oplog replay into disposable isolated target; report, not production cutover |
| `configure-standby` | snapshot fields plus `targetContainer`, `targetMemberHost`, `secondaryDelaySecs`, `allowReplicaSetReconfigure` | none | Change delay of existing managed hidden nonvoting secondary only |

`targetClusterTime` contains exactly unsigned 32-bit `seconds` and `increment`.

Stopping an owned collector remains available when the opt-in flag is disabled or
the commercial engine entitlement is no longer valid. Active company/admin/member
authorization and agent ownership checks still apply; no new operation is exempt.

Its boundary is EXCLUSIVE: only entries `< targetClusterTime` are replayed. An entry
exactly at the requested timestamp is excluded, as are all later entries.
`targetTimeUtc` must have exactly `YYYY-MM-DDTHH:mm:ssZ` format, within the BSON
unsigned 32-bit seconds range. Fractional seconds (including zero fractions) are
rejected: oplog increments are logical sequence numbers, not wall-clock fractions.
UTC maps to `(floor UTC seconds, 0)`, excluding ALL increments in that second, not
the end of that second. Use `targetClusterTime` to distinguish writes within a second.
The accepted interval is `baseLastClusterTime < target <= collectedLastClusterTime`.
Native baseline replay already includes its final entry and cannot undo it, so
`target == base` is rejected. Coverage must reach the requested exclusive boundary;
the runtime never guesses or clips it. To include a desired write, choose a known,
covered clusterTime strictly AFTER that write, not the write's own timestamp.

`verify-restore`/`restore-pitr` intentionally take no credentials: their target has
no external network, no published ports, fresh tmpfs storage and temporary local
authentication disabled. Source authentication is never disabled or modified.

## Source Boundary

Only local Docker standalone containers managed with `pitr.managed=true` and
`pitr.company-id=<canonical company UUID>` are accepted. "Standalone container"
does NOT mean a MongoDB standalone server: a running healthy writable PRIMARY in
an explicitly named unsharded replica set is mandatory. Mongos, config servers,
Swarm/Kubernetes, host/container networking, privileged sources, remote-driver
volumes, arbitrary bind mounts, alternative datadirs and source tmpfs are rejected.

Image must have an official `mongo:8.0.x` tag and official repository digest.
Authenticated driver preflight checks actual server version, stable FCV `8.0`,
authorization enabled, `/data/db`, replica set configuration/status and rollback ID.
The datadir must be an explicitly declared writable local named volume without
driver options; optional `/data/configdb` is the only other allowed local volume
and must also be explicitly declared (image-created anonymous volumes are rejected).
No datadir, keyfile, source environment or secret mount is inherited by the runtime.
Configure TLS-only, nonstandard ports and alternate auth mechanisms elsewhere;
this slice supports SCRAM credentials against `admin`, local port `27017` only.

Source account needs backup/read-oplog and cluster-monitor/config-read privileges,
plus explicit `find` on `local.system.rollback.id`. Even built-in `root` does not
grant this system-collection read in MongoDB 8.0. Provision a narrow custom role
with resource `{db:"local",collection:"system.rollback.id"}`, action `find`.
Standby also requires `replSetReconfig`. Provisioning privileges is an operator
task, never silently performed by the runtime. Credentials are supplied via Docker
stdin; Database Tools read a mode-0600 tmpfs YAML configuration. Both username and
password stay out of native argv, environment and container logs (`log-driver=none`).

## Snapshot And Collection Semantics

Backup is `mongodump-directory-with-oplog`, NOT a physical snapshot, disk image,
WiredTiger hot-copy, or generic volume archive. `mongodump --oplog` provides the
native consistency mechanism. No fsync lock, source shutdown or downtime consent
is needed because physical copying is not attempted. Full dump includes MongoDB
user/role material: backup volume is sensitive and **not encrypted by this slice**.
Protect it with host encryption, permissions and operator-controlled retention.

Paths inside the backup volume:

```text
mongodb/<company UUID>/snapshots/<snapshot operation UUID>/dump/
mongodb/<company UUID>/snapshots/<snapshot operation UUID>/manifest.json
mongodb/<company UUID>/collections/<collection operation UUID>/<batch number>.bson
mongodb/<company UUID>/collections/<collection operation UUID>/manifest.json
mongodb/<company UUID>/reports/<restore operation UUID>.json
mongodb/<company UUID>/topology/<standby operation UUID>/original-config.json
mongodb/<company UUID>/topology/<standby operation UUID>/intent.json
mongodb/<company UUID>/topology/<standby operation UUID>/report.json
```

Snapshot manifest includes UTC timestamps, first/last BSON clusterTime, oplog record count, server/tool
versions, source/image identities, rollback ID and every artifact's size/SHA-256.
Oplog validation and hashing stream from disk; the complete oplog is never retained
in memory. Validation keeps only current record, first/last timestamps and a counter.
Files and manifest are published from staging via rename; completed snapshots are
never overwritten. Snapshot `restoreValidated` remains false: subsequent validation
is a separate immutable report, not a mutation of historical manifest.

Empty dump oplog is rejected (`empty_dump_oplog_no_proven_boundary`). No synthetic
source write or post-dump timestamp is substituted. Operators must choose a period
with real activity if MongoDB produces an empty dump oplog. Staging is removed on
handled failure; host crash/SIGKILL may leave staging for operator cleanup.

Collector starts exactly after the snapshot's last oplog timestamp. It uses a
tailable oplog cursor, checks that the anchor still exists before and after each
batch, verifies unchanged rollback timeline/PRIMARY and only publishes entries
up to the observed majority-committed boundary. Timestamp increments are not
assumed numerically consecutive. Each atomic raw BSON batch records predecessor,
first/last clusterTime, size/hash; an atomic manifest commits the chain. SIGTERM
seals valid coverage. Source failover, rollover, rollback, transaction, cursor gap
or other error marks collection failed. Crashed/killed collections remain unsealed.
No automatic restart/resume or renewal of persisted credentials is implemented.
Collection can survive agent restart while Docker/source stay alive; it is not a
host-reboot guarantee. Stop it explicitly before PITR.

Restores require a cleanly stopped collection, exact snapshot manifest hash,
verified artifacts and the complete ordered predecessor-linked batch chain. Targets
at/before base or beyond collected coverage are rejected. Snapshot is replayed first
using native `mongorestore --oplogReplay --stopOnError`; selected subsequent BSON
entries strictly before the cutoff are replayed with native `--oplogFile`. Batch
validation/replay also streams and verifies the complete chain, including entries
at/after the cutoff. Target data is destroyed after
validation. Reports contain counts and deterministic document/collection-options
hashes, not document contents. Report distinguishes requested `targetClusterTime`, `targetBoundary`
(`exclusive` for PITR, `inclusive-base` for base verification), and actual
`lastAppliedClusterTime`. Hash excludes admin/config/local, views and system
collections; it is a data smoke, not exhaustive validation of indexes, validators,
all namespace types, application invariants or user permissions.
The PITR lower bound uses the native dump's LAST timestamp, not the dump's start:
all baseline oplog entries are replayed before additional logs. Choosing a cutoff
within that baseline would require undoing already restored data and is rejected.

**Transactions are NOT supported.** Transaction/prepare/commit/applyOps chains and
retryable-write oplog records (`txnNumber`/`prevOpTime`) are rejected before accepted
replay, rather than splitting transaction boundaries or advertising transaction-safe
PITR. Workloads using default retryable writes may therefore be rejected. Do not
change production write semantics merely to bypass this guard. No arbitrary tools
flags, namespace filtering, physical restores or sharded PITR are supported.

## Delayed Standby

Requires `allowReplicaSetReconfigure:true`, delay 0..86400 seconds, a healthy existing
SECONDARY in the same replica set, already `hidden:true`, `priority:0`, `votes:0`,
not an arbiter. Target also needs matching managed/company labels and
`pitr.mongo-standby=true`, official image/local volumes, and a single shared
user-defined Docker network with the source. `targetMemberHost` must match its
Docker hostname plus `:27017`; advertised names must resolve on that network.
Supplied credentials must authenticate to both members.
Observed source oplog history must span the requested delay. Operator must still
size oplog retention for peak write rate, outages and resynchronization; current
history length does not guarantee future retention.

Runtime preserves original BSON configuration as Extended JSON and records consent
before mutation. Source and target must have disjoint named volumes, including
`/data/configdb`. Both complete configurations and `settings.replicaSetId` are
compared before submitting reconfiguration; matching replica-set names alone do
not prove cluster identity. Cancellation is checked immediately before submission.
One non-force `replSetReconfig` is submitted. Only `secondaryDelaySecs` changes;
membership, quorum, priority and votes do not. It verifies committed primary config,
target config and SECONDARY status. Configured delay is a replication policy, not
proof the member is already exactly that far behind at configuration time.

Any timeout/failure after submission means **outcome may already have changed**.
Inspect actual topology and preserved original config. Do not blindly retry, force
reconfigure, or restore an old version over a newer configuration. No automatic
rollback is attempted. Adding/removing members, converting voting nodes, setting
up keyfiles, initial provisioning, automatic promotion and production failover are
not implemented. `promote-standby` and other unknown operations return unsupported;
hidden delayed nodes cannot safely be "promoted" without a separate quorum/topology
and rollback protocol.

## Limits And Verification

Manual single-operation agent gate, 60-minute request deadline; persistent collector
outlives start request. Runtime limits: 2 GiB memory, 128 processes, 1 GiB tmpfs for
restore target/replay and 64 MiB `/tmp`. Large datasets/oplog selections fail rather
than falling back to persistent unisolated targets. Runtime is trusted executable
code and backup volume contents are operator-controlled; hashes detect artifact
corruption, not an attacker who can rewrite manifests or control Docker daemon.
Cleanup never removes source/backup volumes. Unconfirmed owned runtime cleanup
closes the singleton gate until operator cleanup/restart.

Executed direct runtime manual Docker smokes (2026-10-03), only dedicated disposable
resources, removed after completion. C# dispatcher was build-verified, not HTTP-smoked:

- Built digest-pinned runtime and .NET agent successfully.
- MongoDB 8.0.12 SCRAM-authenticated one-member replica set; full dump under concurrent
  ordinary non-retryable writes; 20,000 seeded documents.
- Tailable collection produced three linked BSON batches and sealed cleanly.
- Native isolated PITR restored 20,000 documents with dataset SHA-256 exactly equal
  to the source at requested clusterTime under the original inclusive implementation,
  excluding a subsequent update. That cutoff behavior is superseded by the exclusive
  semantics above; historical results do not validate the new boundary.
- Native `verify-restore` reproduced the same base dataset hash; UTC end-of-second
  PITR reproduced the exact clusterTime target dataset hash under the original
  implementation. End-of-second UTC behavior is no longer supported.
- Rejected targets beyond coverage, broken predecessor chain, corrupted batch and
  snapshot hashes, and an injected transaction record before starting a target.
- Real runtime stdin startup stayed collecting until SIGTERM; manifest sealed and
  ephemeral credential file was removed on clean exit.
- Existing dedicated hidden/nonvoting secondary changed to 30-second delay; actual
  primary committed config and target SECONDARY/config verified; original config saved.

### Exclusive Cutoff Final Review

Additional direct runtime manual smokes after the exclusive-cutoff fix:

- New authenticated MongoDB 8.0.12 replica set, real native full dump/oplog and
  sealed collection; 5,000 baseline documents plus cutoff markers.
- Three ordinary writes at increments 1, 2 and 3 of the SAME second. Native PITR
  targeting increment 2 restored 5,002 documents: prior-second marker and increment
  1 included, increments 2 and 3 excluded. Seeded dataset SHA-256 matched expected.
- UTC cutoff mapped to that second's increment 0. Native PITR restored 5,001
  documents, preserving the prior-second marker and excluding every target-second
  increment. Seeded dataset SHA-256 matched expected.
- `target == base`, target before base and target beyond coverage rejected before
  creating any target/replay file. Fractional UTC `.1`, `.000`, `.0000001` and
  `.000000001` also rejected; no wall-microsecond/logical-increment conversion.
- OFFLINE execution of the production snapshot validation block over a synthetic
  4,096-record BSON file (537,108,480 bytes), with a 128 MiB container memory cap:
  peak process RSS 31.1 MiB, exact first/last timestamps/count and streamed SHA-256
  verified. Empty, out-of-order and transaction-containing oplogs rejected. This
  verifies bounded parser memory, NOT a 537 MB native MongoDB backup workload.
- Runtime image and .NET agent rebuilt. Only owned disposable resources used;
  no automated test files, production secrets, routes or frontend edits.

HTTP route registration/DI and deployed end-to-end authorization are intentionally
left to the integrating agent. Do not infer MySQL/PostgreSQL/SQL Server capabilities
from these MongoDB-only results. No automated test files were added or edited.
