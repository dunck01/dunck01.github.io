# SQL Server manual operations

## Recovery without a live source

Registration preflight uses authenticated
`GET /api/engine-registration/inspect?purpose=restore-target` with the existing
company/container/engine/scope/database parameters. Only SQL Server is supported
for this purpose; omitted purpose means the unchanged strict source profile.
Response remains exactly `agentId`, `containerId`, `engine`, `scope`, `databaseName`.
Target admission must explicitly request this profile before reserving jobs or
creating resources; do not retry rejected source inspection as a target.
Agent validates target tenant/role, configured backup volume RO, data volume RW
with tenant/restore-role ownership, exclusive data volume and unexposed `none`
network. Runtime restore validation remains mandatory. API registry integration
is owned separately; a build does not prove that caller integration is deployed.

PITR restore and delayed standby/promotion authorize snapshot ownership from the
signed manifest, verified against operator-configured
`SQLSERVER_OPERATIONS_SIGNING_PUBLIC_KEY_SHA256`, through the authorized target's
readonly backup mount. Company, snapshot, database, engine, scope, relative path
and full source container ID must match. Use that exact 64-character signed ID
in `sourceContainer` after source deletion; names still require Docker resolution,
but no running source. Transaction-log collection still requires a live authorized
source. Target tenant/role/volume ownership, exclusive data volume, stopped actor
before promotion, runtime signature/artifact checks and signed restore-state
ownership remain mandatory. This implementation is not native SQL smoke evidence.

## Delivery status

This module is independent of PostgreSQL and the commercial platform. Integration into routing, DI, API contracts, UI and deployment belongs to the main implementation. No existing files in those areas are changed.

| Operation | Status | Actual behavior |
| --- | --- | --- |
| `fullsnapshot` | Implemented, not SQL-homologated | Native single-database COPY_ONLY backup, CHECKSUM, HEADERONLY, FILELISTONLY, VERIFYONLY, SHA-256 and signed manifest |
| `transactionlogs` | Implemented, not SQL-homologated | Dedicated persistent ordinary BACKUP LOG collector, signed sealed catalog, health/status/stop/resume |
| `pitr` | Implemented, not SQL-homologated | Verified COPY_ONLY full + strict native log chain, fresh MOVE/NORecovery, UTC STOPAT and ONLINE verification on an operator-provisioned empty target |
| `delayedstandby` | Implemented, not SQL-homologated | Dedicated persistent delayed log apply, GUID-local STANDBY undo file, signed restore ownership, status/stop/resume and explicit RECOVERY promotion |

**Implementation exists, live SQL validation does not.** All mutation requires both `MULTI_ENGINE_OPERATIONS_ENABLED=true` and the dedicated `SQLSERVER_OPERATIONS_UNVERIFIED_OPT_IN=true`, each false by default. Operator opt-in permits lab execution; it does not certify production readiness. Success responses explicitly keep `implementationVerified=false`, `productionReady=false` and `seededDataVerified=false`. ONLINE verification uses native state/files and an actual metadata read, not a fabricated seeded-data pass. A snapshot's immutable manifest still has `restoreValidated=false`; separate restore records represent actual ONLINE verification if execution succeeds.

No licensed SQL Server environment was provisioned for this delivery. No SQL Server server container was started, no EULA was accepted, and no SQL backup/restore smoke was executed. The runtime image contains .NET and a SQL client, not SQL Server. The operator must independently provision and license every source or future target, accepting applicable Microsoft terms outside this application. No API boolean represents EULA acceptance; `consentBackupIo` authorizes operational cost only. Edition detection does not prove licensing rights.

## Integration contract

Class: `SqlServerOperations(IDockerClient docker, IConfiguration cfg)`.
Entry: `Task<IResult> ExecuteAsync(string operation, HttpRequest http, CancellationToken cancellationToken)`.

Register one long-lived instance to preserve its local concurrency gate. The integration must enforce authenticated company authorization, secret-safe HTTPS transport, rate limiting, body size limits, and sanitized audit records before invoking this method. A company UUID supplied in a request is not authentication. Never log request bodies or record DTOs containing credentials. Docker socket access remains highly privileged.

Request root has exactly three case-sensitive fields. Unknown, missing and duplicate fields are rejected. Limit: 16 KiB, depth 16, read deadline 15 seconds. Identifiers must be nonempty UUIDs.

```json
{
  "companyId": "11111111-1111-4111-8111-111111111111",
  "operationId": "22222222-2222-4222-8222-222222222222",
  "parameters": {
    "sourceContainer": "operator-sqlserver",
    "database": "ApplicationDb",
    "username": "operator_backup_login",
    "password": "<provided securely at request time>",
    "consentBackupIo": true
  }
}
```

`fullsnapshot` parameters are a strict typed object with exactly these five required fields. Database names use `\A[A-Za-z][A-Za-z0-9_]{0,127}\z`, are quoted with brackets, and must match native metadata exactly. System databases, read-only databases and offline databases are rejected. Credentials permit no control characters; username maximum 128, password maximum 4096 characters. They never become Docker environment, arguments, labels, files or logs. They travel through upgraded Docker attach stdin into a nonpooled SqlClient connection. Public JSON is bounded to 16 KiB; internal stdin JSON to 64 KiB to accommodate Unicode escaping. Managed strings cannot be guaranteed erased; byte buffers are zeroed. The operator controlling Docker/host process memory can still access secrets.

### Exact parameter schemas

Every row below lists ALL required fields. No extra fields, alternative casing or duplicate fields are accepted. `operation` is passed separately to `ExecuteAsync`, not included in request JSON. `action` belongs inside `parameters` for the three flows below; fullsnapshot has no action field.

| Operation / action | Exact parameter fields |
| --- | --- |
| `fullsnapshot` | `sourceContainer`, `database`, `username`, `password`, `consentBackupIo` |
| `transactionlogs` / `start`, `resume` | `action`, `sourceContainer`, `database`, `username`, `password`, `snapshotId`, `collectionId`, `intervalSeconds`, `consentLogChainChanges` |
| `transactionlogs` / `status`, `stop` | `action`, `collectionId` |
| `pitr` / `restore` | `action`, `sourceContainer`, `targetContainer`, `database`, `username`, `password`, `snapshotId`, `collectionId`, `restoreId`, `stopAtUtc`, `consentTargetRestore` |
| `delayedstandby` / `start`, `resume` | `action`, `sourceContainer`, `targetContainer`, `database`, `username`, `password`, `snapshotId`, `collectionId`, `restoreId`, `intervalSeconds`, `delaySeconds`, `consentTargetRestore` |
| `delayedstandby` / `status`, `stop` | `action`, `restoreId` |
| `delayedstandby` / `promote` | `action`, `sourceContainer`, `targetContainer`, `database`, `username`, `password`, `snapshotId`, `collectionId`, `restoreId`, `consentPromotion` |

All IDs are nonempty UUIDs. `snapshotId` is the fullsnapshot operation UUID. `collectionId` is an independent collector UUID. `restoreId` is an independent target ownership UUID; the database name is generated as `pitr_<restoreId N>` and cannot be supplied or changed by callers. `database` always means the original source database. Each new request uses its own operationId, including resume/status/stop/promotion.

Polling intervals are fixed, 30..3600 seconds. Standby delay is fixed, 60..604800 seconds. Resume must use the original interval and delay, same source/target container identities, database, snapshot and collection. All consent fields must be true. PITR `stopAtUtc` must have zero UTC offset, be in the past, year >= 2000 and exactly representable by SQL Server `datetime`; silently rounded subsecond boundaries are rejected. All credentials for PITR/standby/promotion belong to the TARGET, not source. Those clients read the shared sealed archive; no source SQL credentials are needed or copied into them.

Example collector parameters (inside the same three-field root):

```json
{
  "action": "start",
  "sourceContainer": "operator-sqlserver",
  "database": "ApplicationDb",
  "username": "operator_backup_login",
  "password": "<provided securely at request time>",
  "snapshotId": "22222222-2222-4222-8222-222222222222",
  "collectionId": "33333333-3333-4333-8333-333333333333",
  "intervalSeconds": 300,
  "consentLogChainChanges": true
}
```

No request boolean accepts Microsoft license terms. Consent flags concern I/O, ordinary log chain consumption, use of an empty dedicated target, or promotion only.

Every response root is exactly:

```json
{
  "operationId": "22222222-2222-4222-8222-222222222222",
  "engine": "sqlserver",
  "operation": "fullsnapshot",
  "state": "snapshot_verified",
  "details": {
    "relativePath": "sqlserver/11111111111141118111111111111111/22222222222242228222222222222222",
    "manifestSha256": "<64 lowercase hexadecimal characters>",
    "artifactSha256": "<64 lowercase hexadecimal characters>",
    "sizeBytes": 123456,
    "checksumVerified": true,
    "restoreValidated": false,
    "implementationVerified": false,
    "productionReady": false
  }
}
```

Errors use the same root and `details: {"code":"sqlserver.<reason>"}`. Success states additionally include `collecting`, `waiting_for_delay`, `standby`, `restored_online`, `promoted_online`, `running`, `stopped`. HTTP 400 malformed request, 403 unauthorized/missing source, 404 missing owned actor, 409 busy/actor conflict, 422 mount/protocol/metadata/native flow failure, 502 snapshot Docker/runtime/manifest failure, 503 disabled/opt-in/configuration/runtime unavailable, 504 timeout with unknown completion. No flow returns a hardcoded 501. Invalid requests without a recoverable operation UUID use the empty UUID. Unsupported operation strings are returned as `operation: "unknown"`, never echoed verbatim.

Flow success `details` has `actorId` (UUID for long-running actors, null for one-off restore/promotion), `relativePath`, `recordSha256`, `targetDatabase` (generated name for restore flows, null for a collector), `implementationVerified:false`, `productionReady:false`, `onlineVerified` and `seededDataVerified:false`. Collector startup returns only after sealing an actual initial native log backup. Standby startup can truthfully return `waiting_for_delay` with the target still RESTORING if no log is old enough. Status/stop details include actor UUID, actual Docker running/health state, generated target name for standby, signed record phase/hash and `completionUnknown` based on a pending SQL artifact. If an owned client is confirmed stopped but its signed record cannot be read/verified, stop still returns `stopped` with `recordVerified:false` and `completionUnknown:true`; it never fabricates record validity. Native messages, credentials, server paths and SQL text are not returned.

Startup/resume and one-off completion proofs are signed immutable records at
`<relativePath>/readiness/<operationId N>.json`. Their `recordSha256` is not the
periodically replaced `state.json` hash. Each proof binds the operation UUID,
ready state and observed actor-state hash; later cycles cannot invalidate that
startup proof. Status still reads the latest signed mutable actor state.

## Configuration

| Key | Default | Meaning |
| --- | --- | --- |
| `MULTI_ENGINE_OPERATIONS_ENABLED` | false | Explicit opt-in, shared multi-engine feature gate |
| `SQLSERVER_OPERATIONS_UNVERIFIED_OPT_IN` | false | Dedicated permission to execute unverified SQL implementations in an operator-approved licensed environment; NEVER a production-readiness claim |
| `SQLSERVER_OPERATIONS_RUNTIME_IMAGE` | none | Installed immutable Docker image ID `sha256:<64 hex>` |
| `SQLSERVER_OPERATIONS_BACKUP_VOLUME` | none | Existing explicit local named backup volume |
| `SQLSERVER_OPERATIONS_SIGNING_VOLUME` | none | Different existing local named signing volume, never mounted in SQL Server |
| `SQLSERVER_OPERATIONS_SIGNING_PUBLIC_KEY_SHA256` | none | SHA-256 of RSA public SubjectPublicKeyInfo DER, lowercase hex |
| `SQLSERVER_OPERATIONS_TIMEOUT_SECONDS` | 1800 | Clamped 60..7200; total snapshot/agent startup or one-off request budget, per native step budget inside actors; agent allows 30 extra seconds for transport |

### Deployment And Manual Image Approval

Deployment passes both opt-ins and timeout to API/agent, each opt-in false by
default. Install/update reject non-boolean flags, timeouts outside 60..7200,
mismatched API/agent values and nonempty SQL runtime references that are not
`sha256:<64 lowercase hex>`. An empty runtime remains unconfigured; downloading
tools does not approve an image or enable a SQL operation.

The `tools` service `sqlserver-operations-runtime` is a CLIENT, not SQL Server.
Its separate download reference `SQLSERVER_OPERATIONS_CLIENT_TOOLS_IMAGE` defaults
locally to `dunckops-sqlserver-operations-runtime:development` and in production to
`ghcr.io/${REGISTRY_OWNER:-dunck01}/dunckops-sqlserver-operations-runtime:${DUNCKOPS_VERSION}`.
Install/update pull it only with BOTH opt-ins true. Explicit client-tool overrides
must already exist locally, verified by inspect; missing overrides fail without
registry fallback. Published image download never populates the runtime setting.

After downloading an approved release, the operator must inspect its installed
identity and verify provenance, marker, entrypoint and trusted CA requirements:

```sh
docker compose --env-file .env -f docker-compose.prod.yml -f docker-compose.docker-ops.prod.yml --profile tools pull sqlserver-operations-runtime
docker image inspect 'ghcr.io/dunck01/dunckops-sqlserver-operations-runtime:REPLACE_WITH_APPROVED_RELEASE' --format '{{.Id}}'
```

Then manually set `SQLSERVER_OPERATIONS_RUNTIME_IMAGE` to the approved image ID,
never the tag shown in the download command. Local build uses repository-root
context and the existing client-only Dockerfile. Offline bundle ships the client
image but still leaves runtime ID, backup volume, signing volume and public-key
fingerprint empty. Provision distinct existing volumes and signing material
externally; no deployment service creates them or accepts Microsoft EULA.
No SQL Server server image is pulled or started. Lab opt-in and packaging preserve
`productionReady=false`; licensed live SQL validation remains required.

These public settings are included in deployment environment examples. No extra NuGet package is needed in the agent. `Microsoft.Data.SqlClient` 6.1.7 belongs exclusively to `infra/docker/sqlserver-operations/SqlServerOperations.Runtime.csproj`.

## Supported Operator Layout

Only standalone SQL Server 2022 Linux amd64, TDS port 1433 inside the source network namespace. Native protocol verifies ProductMajorVersion 16, host platform Linux and EngineEdition 2 or 3. Allowed native edition strings: Standard, Enterprise, Developer, Enterprise Evaluation and Web, each `Edition (64-bit)` except Evaluation's `Enterprise Evaluation Edition (64-bit)`. Express and other platforms/versions are rejected, regardless of image name or labels.

Log/restore/standby flows additionally require native `CURRENT_TIMEZONE_ID()` in UTC/Etc-UTC/GMT zero-offset equivalents AND DATEPART TZOFFSET = 0. The fullsnapshot records this native identity; an old snapshot lacking it is not accepted for these flows. Native backup header TimeZone must be a recognized zero-offset value; unknown formats are rejected, never guessed or converted. SQL Server 2022 LastValidRestoreTime must exist and be valid for each log. Other timezones and recovery fork transitions are intentionally unsupported.

Source must already be running and independently licensed, with exact labels:

```text
pitr.managed=true
pitr.company-id=<request company UUID in lowercase D format>
```

Exactly two explicitly declared, writable Docker named volumes must be mounted in the source:

```text
<operator-data-volume>   -> /var/opt/mssql
<configured-backups>    -> /var/opt/mssql/backup
```

Both volumes and the separate signing volume must already exist, use Docker's `local` driver without driver options, and use the complete volume root. Data, backup and signing volumes must differ. Anonymous/implicit image volumes, host bind paths, subpaths, extra source mounts, tmpfs overrides, Swarm/Kubernetes and container-network sources are rejected. The source's backup volume is simultaneously mounted in the client as `/backups`; source datadir is NEVER mounted in the client. BACKUP writes through the licensed SQL Server process to `/var/opt/mssql/backup/sqlserver/<company N>/<operation N>/database.bak`, not through a read-only datadir mount.

Operator-provisioned restore targets must carry `pitr.managed=true`, the exact `pitr.company-id`, and `pitr.role=sqlserver-restore-target`. Their NEW dedicated datadir volume must also carry the company and role labels and must not be mounted in any other container, even stopped containers. Source and target datadir volumes must differ. Target Docker network mode must be exactly `none`, no published ports, no privileged mode. Target mounts exactly a writable dedicated `/var/opt/mssql` named volume and the SAME backup volume READ-ONLY at `/var/opt/mssql/backup`. Tool client shares only the target network namespace and mounts backup RW solely for signed restore records, never the target datadir. The licensed target's own SQL process performs MOVE/STANDBY writes in its dedicated datadir.

Before INITIAL restore, the target must contain NO user database, not merely lack the generated requested name. VIEW ANY DATABASE permission is checked so an underprivileged login cannot hide other databases. Native file-existence checks reject preexisting GUID MOVE/undo paths; prior msdb restore history for the generated database name also rejects UUID reuse. Never reuse a restore UUID or target datadir after ambiguous execution. No `WITH REPLACE`, DROP DATABASE, ALTER recovery model, source restore, application-created SQL Server container or EULA environment exists in the implementation.

Provision the backup volume for UID 10001, and run SQL Server with its standard UID 10001. Created namespace directories use mode 0700. The client runs `10001:0`, all Linux capabilities dropped, no privileged mode, no published port, read-only root, no Docker socket, 512 MiB memory, one CPU and a 16 MiB tmpfs `/tmp`. It shares the source's network namespace solely to connect to `127.0.0.1:1433`; it mounts only backup and signing volumes. No volume is created automatically, no image is pulled automatically, and no source environment is inherited. Native backup uses BUFFERCOUNT 8 and MAXTRANSFERSIZE 1048576; these are not a source I/O quota. BACKUP can impose I/O, memory and locking costs despite COPY_ONLY. Obtain explicit operational consent and maintenance budget.

TLS is mandatory and certificates are verified. The SQL Server certificate must be trusted by the tool image and valid for `127.0.0.1`. Default self-signed SQL Server certificates will fail. Operators may build an approved derived runtime containing their public CA certificate and configure its immutable image ID. Do not disable verification or inject credentials into Docker configuration. The image must declare no Docker VOLUMEs, carry `pitr.sqlserver-operations-runtime=true`, and retain the exact dotnet/module entrypoint without a default Cmd or SQL Server/EULA/password environment. This guards accidental configuration of a SQL SERVER image as the client runtime. An approved immutable image ID is still essential; the marker alone is not a trust boundary.

Use operator-approved SQL logins with the necessary BACKUP DATABASE / BACKUP LOG or target RESTORE permissions, CONNECT to the requested source database, CREATE DATABASE for header metadata, `sys.dm_os_host_info`, native file-existence and database recovery visibility. Source collector also reads msdb.backupset to prove an existing non-COPY_ONLY FULL chain base. Target login needs VIEW ANY DATABASE, msdb.restorehistory/backupset and sys.master_files visibility. SQL Server 2022 DMV visibility may require VIEW SERVER PERFORMANCE STATE / VIEW SERVER STATE. Permission errors fail closed. Determine narrow grants in the licensed lab; the application neither grants privileges nor enables sysadmin automatically.

## Signing And Storage

Operator supplies `/keys/manifest-key.pem` in the dedicated named signing volume, readable by UID 10001, exact mode 0600, RSA private PEM key with at least 3072 bits. Provision outside the repository. Do not mount this signing volume in SQL Server. Do not put its private key in configuration, request JSON, argv or environment.

Derive the public fingerprint in an operator-controlled tool environment using the equivalent of:

```sh
openssl pkey -in /keys/manifest-key.pem -pubout -outform DER | openssl dgst -sha256
```

Key creation/provisioning is intentionally not executed by this module. Public-key fingerprint is nonsecret; private key must remain operator protected. RSA-PSS/SHA-256 signs exact payload bytes. The envelope contains base64 payload, base64 signature and PEM public key. The agent independently reads the persisted manifest through Docker archive, verifies its hash, pinned public-key fingerprint and signature, and checks company, snapshot, database, source container, runtime image, namespace and artifact identity. Pinning is essential; an embedded public key alone is not trustworthy.

Manifest records native HEADERONLY and FILELISTONLY metadata, including FirstLSN, LastLSN, CheckpointLSN, DatabaseBackupLSN, backup set/database/family/recovery fork GUIDs, checksums, file IDs/logical names/physical names/sizes and native encryption metadata. LSNs remain invariant decimal strings, not JS numbers or 64-bit truncated values. Native datetimes remain explicitly unzoned strings; server UTC offset is recorded. Runtime started/completed timestamps are UTC. API response excludes SQL messages, native server identity and physical paths; those operational metadata exist only inside the signed local manifest.

The runtime validates native backup type/database binding/copy-only/checksum flags and performs RESTORE VERIFYONLY WITH CHECKSUM before hashing the artifact. Manifest is staged with CreateNew, flushed to disk, then renamed without overwrite. Rename is atomic, but directory fsync is not implemented; storage/power-loss durability still requires operator procedures. There is no artifact encryption added by this module; protect volumes and exports independently, including TDE certificate/key handling when applicable. Hashes/signatures establish integrity, not confidentiality or restore compatibility.

Cooperative volume locks serialize every collector/snapshot for a source/container+database, and every restore actor/one-off restore/promotion for a target container. No stale lock file is deleted; OS advisory locks expire with the process. Stop the source collector before another fullsnapshot on that same source/database. Existing snapshot/collection/restore directories are not reused by INITIAL actions, overwritten or automatically removed. Only signed state pointers are atomically replaced. Archives use GUID-only namespaces, native CHECKSUM, signed immutable manifests, and read-only file mode after sealing. This is integrity sealing, NOT filesystem WORM against trusted host/SQL administrators.

Source SQL sessions switch into the requested database with ChangeDatabase before BACKUP, then verify current DB_ID()/named DB_ID(), database GUID and recovery fork on that SAME connection. Collectors keep that database context for their lifetime; snapshots keep it through backup/verification. An ordinary DROP cannot replace a database in use by this session. Forced DROP terminates the connection; ConnectRetryCount=0 and disabled pooling prevent transparent reconnection and backup of a replacement with the same name. Identity/model checks still run before each log backup and immediately before snapshot backup. No SINGLE_USER, connection killing or destructive lease is acquired. This race protection has been implemented and statically built, not exercised against live SQL Server.

Cancellation disconnects the SQL client, but server-side cancellation/completion cannot be guaranteed. Snapshot `incomplete.json` and actor `pendingArtifactId` preserve uncertainty. No artifact is deleted on failure. Before submitting a fresh operation after timeout, inspect source/target native activity. Agent cleanup removes only its labeled client runtime, never server/volume/data. Failure to confirm cleanup closes its local gate until reconciliation/restart. Docker socket, signing key and SQL Server filesystem administrators are trusted; symlink checks and signatures are not protection against a hostile host administrator or rollback of valid historical signed states. Atomic rename lacks directory fsync; handle storage/power-loss durability externally.

## Continuous Log Collector

`start` creates a dedicated owned CLIENT runtime, not a SQL Server instance. `resume` replaces only an exited owned client and reloads signed state with supplied ephemeral credentials. No Docker restart policy stores passwords or blindly starts a client without stdin. Docker/host restart requires explicit resume with credentials. Polling executes ordinary `BACKUP LOG ... WITH CHECKSUM` (NOT COPY_ONLY), which can truncate inactive log and advances/consumes the active operational backup chain. Explicit `consentLogChainChanges` is required. The app does not switch recovery models or manufacture the initial normal full backup. Native FULL recovery, database GUID, fork and a matching non-copy FULL msdb checkpoint are required. Purged/missing msdb initialization history is conservatively rejected. The tool whitelists persisted native metadata and omits HEADERONLY UserName/description; SQL Server's native backup media and msdb can inherently record the operator login, but request passwords are never persisted by this tool.

Collector runs continuously until stopped, failed, or bounded catalog capacity is reached (1000 sealed logs per collection). Use a new fullsnapshot/collection rather than allowing unbounded manifests. Fixed interval is a delay after completion, not wall-clock overlap scheduling. BUFFERCOUNT 8/MAXTRANSFERSIZE 1 MiB and client CPU/memory limits are not source server I/O quotas. An external normal log backup can create an archive hole; the collector rejects the gap rather than pretending it possesses that missing file. A new normal FULL backup may change DatabaseBackupLSN without breaking log continuity: reference changes are recorded and accepted when database/family/fork identities and advancing contiguous native LSN coverage remain valid. No artificial snapshot/collection rotation is required for that reference change alone. The initial snapshot-base msdb history proof is retained; purging that evidence is a separate preflight refusal before BACKUP. Recovery fork transitions are rejected rather than guessed.

Paths: `sqlserver/<company N>/collections/<collection N>/state.json`, and `artifacts/<artifact N>/{transaction.trn,manifest.json}` beneath that collection. Every signed artifact binds company, snapshot/manifest hash, source/container/database GUID, collection, native header, artifact hash/size and minimum/maximum restore coverage timestamps. Native LSNs remain exact decimal(25,0) strings. Endpoint must strictly advance; overlap is legal (`FirstLSN <= previous LastLSN < LastLSN`), a gap/redundant log/wrong binding/family/fork or bulk/incomplete/tail/snapshot log is rejected. DatabaseBackupLSN retains per-header numeric/checkpoint validation, not equality to the COPY_ONLY snapshot's older base reference. Catalog order is validated against native sort order. LastValidRestoreTime, not BACKUP start time, provides upper STOPAT coverage. Native VERIFYONLY, hashes/signatures and fixed FILELISTONLY layout checks remain mandatory. Native timestamps must remain monotonic under the supported UTC profile; missing or contradictory timestamps fail closed.

Every log also records verified native FILELISTONLY metadata. Supported profile keeps the snapshot's file layout fixed: FileID, logical/physical source names, type and UniqueID must remain identical; dropped files and ADD/DROP/RENAME/MOVE layout changes are rejected before SQL RESTORE. Auto-growth/size changes in the same file are allowed. This prevents applying logs that could introduce unmapped source physical paths rather than the target's generated MOVE namespace. Fresh snapshot/collection/target is required after a layout change. Live lab validation must cover log FILELISTONLY behavior and file-DDL edge cases; no unsupported metadata format is silently accepted.

SIGTERM saves a signed stopped or interrupted_unknown state. Resume can seal an already completed pending BACKUP using native HEADERONLY/VERIFYONLY + hashes without issuing another BACKUP over the pending path. Missing/incomplete/unverifiable pending files require operator reconciliation and remain blocked. Client tmpfs contains health expiry only; credentials live only in stdin/managed memory. Docker healthcheck reports bounded liveness and successful cycle progress. It does not prove current source connectivity between polls. `status` also reports actual Docker running/health and signed phase/pending state. `stop` is allowed even when both feature opt-ins are disabled and operates only on exact company/actor/operation labels. No secret is put in Docker Env/Cmd/logs or persistent catalog.

## Native PITR Restore

`restore` verifies source/container/company identity, target profile, snapshot signature/hash/native HEADERONLY and FILELISTONLY, full native log chain and all selected artifact hashes/HEADERONLY/VERIFYONLY BEFORE creating a user database. STOPAT must be at/after snapshot BackupFinishDate and at/before a selected log's LastValidRestoreTime. No file creation/backup-completion timestamp is substituted for native transaction time coverage. Timestamp formats and SQL datetime precision are validated.

Full RESTORE uses NORECOVERY and deterministic target-local MOVE paths `pitr_<restore N>_<native FileID>.mdf/.ldf`. Logical file names come from verified native metadata, are SQL-literal escaped, and never determine physical paths. Log backups are sorted/validated by native First/Last LSN. Every selected log receives bound SQL datetime STOPAT; intermediate restores use NORECOVERY, the covering final log uses RECOVERY. Actual ONLINE, writable/non-standby state, exact generated files and opening/reading sys.tables are checked. `nextRequiredLsn` is a chain cursor only for fully applied backup ranges; final PITR clears it and records the terminal log backup set, STOPAT, and `actualRecoveredLsnKnown=false`. A log backup's LastLSN is never falsely reported as the precise recovered LSN inside that log. No seeded customer data is invented, queried arbitrarily or claimed verified.

Signed record at `sqlserver/<company N>/restores/<restore N>/state.json` binds initial source/company/snapshot/database GUID and pinned manifest, target container, generated database/files/undo path, target database_id/create_date and database GUID when available, native msdb restore_history_id/backup_set_uuid provenance, applied logs and pending phase. NORECOVERY can leave database_guid NULL while the database is unstarted; in that state signed native history, database ID/create_date and exact files remain mandatory ownership evidence. Before every subsequent mutation, these identities, expected RESTORING or ONLINE-read-only-standby state and latest native restore history must match. No existing arbitrary database name is accepted. PITR INITIAL restore is nonretryable under the same restore UUID and has no unsafe automatic replay after unknown completion.

## Delayed Standby And Promotion

`start` uses the same EMPTY target full restore and signed ownership proof, then keeps a dedicated target-connected client alive. Each cycle reads an atomic sealed catalog, verifies its already-applied prefix, and applies only logs whose native BackupFinishDate AND LastValidRestoreTime are at/before UTC now minus delay. Other logs stay pending in the source archive, not applied early. Log restore uses WITH STANDBY and the generated local undo file `/var/opt/mssql/data/pitr_<restore N>.undo`. Never replace/reuse a customer undo path. In standby, native ONLINE/is_in_standby/is_read_only plus exact owned identity/files/provenance are checked. Existing readers can block RESTORE; no automatic KILL or SINGLE_USER data disruption is issued.

`resume` requires the original signed initialized standby record, same configuration, no unknown pending SQL step, and matching target native identity/history/files. Only cleanly established phases are resumed. An interrupted RESTORE with uncertain completion is NOT replayed or accepted as completed: stop, investigate native state and reconcile manually with an independently provisioned new empty target if needed. No existing database is dropped for recovery.

Promotion requires stopping the owned standby actor first, explicit `consentPromotion`, signed ownership, initialized actual standby, at least one applied log, matching native history/files/identity, and no pending step. Only then `RESTORE DATABASE [generated_owned_name] WITH RECOVERY` runs. ONLINE/file/read checks follow; promoted records cannot be resumed or reused. No EULA acceptance or target creation happens in any branch.

## Build And Verification

```sh
docker build --platform linux/amd64 -f Dockerfile.sqlserver-operations-runtime -t dunckops-sqlserver-operations-runtime:development .
docker image inspect dunckops-sqlserver-operations-runtime:development --format '{{.Id}}'
dotnet build apps/docker-agent/DunckOps.DockerAgent.csproj --no-restore
```

Base SDK/runtime images are digest-pinned. SQL client package version is pinned; transitive package lockfile is not supplied. Build validates compilation and NuGet audit, not SQL semantics. A no-input client run may check generic failure/redaction without creating a SQL Server instance. `--check-chain` reads a bounded JSON object with native `snapshot` header and `logs` header array from stdin, exercises the real native metadata parser/chain planner offline and emits `offline_metadata_checked` or `offline_metadata_rejected`, always `implementationVerified:false`. Optional `snapshotFiles` and `logFiles` (one native file-list array per log) exercise the same fixed-layout validator used by collector/restore. Use synthetic inline data only for parser checks; never report it as a SQL restore pass. No automated test files are introduced.

Release readiness still requires licensed SQL 2022 lab validation of TLS, permissions, edition strings, native metadata, backup I/O, cancellation and real restore/seeded-data verification. Never report artificial samples or static/build checks as a real SQL backup/PITR/standby pass.

Recorded verification on 2026-10-03:

- Linux amd64 runtime image built successfully, including restore/audit and warning-as-error compilation.
- Agent module compiled independently against net10.0 and Docker.DotNet 3.125.15, zero warnings/errors, using a temporary compilation project outside the repository.
- Inline synthetic native metadata exercised decimal LSN values beyond UInt64 and reverse-order overlapping logs; that chain passed. Gaps, fork mismatch, bulk-logged data, missing LastValidRestoreTime, non-UTC timezone and redundant endpoints were rejected. Final review corrected the earlier artificial rejection of DatabaseBackupLSN reference changes after normal FULL; valid reference changes now pass. These are OFFLINE parser results, not SQL Server backup/restore results.
- The same inline check validated unchanged file layout with size growth, and rejected added/moved/dropped/reused file identities. Total: 13 expected offline outcomes; no SQL connection, license acceptance or test files.
- Final review reran seven inline cases: original FULL reference and a new normal FULL reference passed; gaps, fork changes, wrong database GUID, wrong family GUID and an invalid per-header base/checkpoint range failed. Context pinning and forced-DROP behavior remain live-unverified; only compilation/static inspection verified that protection.
- No-input runtime smoke, network disabled, returned only `sqlserver.native_validation_or_backup_failed`; no SQL Server was started.
- The first complete agent build was blocked by concurrent errors in MongoOperations.cs and MySqlOperations.cs. A later build succeeded after concurrent changes, with only the existing Microsoft.OpenApi 2.0.0 NU1903 warning. This task did not modify those files/packages.
- Docker daemon listed no running SQL Server source. Native backup, metadata, restore and seeded-data smoke remain unverified and legally blocked pending an independently provisioned licensed lab.
