# Runtime distribution

## Production policy

Set `DUNCKOPS_VERSION` to an actual published `X.Y.Z` release from the official
release catalog, without `v`. Examples leave it empty deliberately; do not invent
a release number. For first online install, export the selected version before
invoking the installer; it persists that version in the new `.env`. Existing
installations must update their `.env` pin before running update. Update does not
automatically select a newer release. Compose requires a nonempty pin; Agent and
install/update reject `latest` and non-release versions. Published `latest` and
family `-latest` aliases are discovery conveniences, not production deployment
references. Local development may use unsuffixed copy tags; explicit copy versions
must be `X.Y.Z`, matching install/update and publisher policy.

Bundled Compose explicitly sets `ENGINE_PROVISIONING_API_SHARED_NETWORK=true`
for API and Worker: both share `dunckops-platform_default` with the local Agent
and provisioned targets. This deployment-config opt-in is not autodetection or
runtime connectivity proof. Keep the default loopback bind for bundled deployment;
internal endpoints use the shared network instead of host-published loopback ports.
Remote/separate Agent deployments must set the flag to false and configure a
reachable published bind/external host. Verify name resolution and connectivity
from both consumers, especially when overriding the provisioning network.

Artifact endpoints authenticate using Agent configuration `AGENT_KEY`;
Compose maps operator `DOCKER_AGENT_KEY` to it. Do not configure a second key.

Production Compose resolves `ENGINE_ARTIFACTS_RUNTIME_IMAGE` to
`ghcr.io/${REGISTRY_OWNER}/dunckops-engine-artifacts-runtime:${DUNCKOPS_VERSION}`.
Pin `DUNCKOPS_VERSION` to the published release for reproducible deployment.
Only Docker Agent consumes this setting; API and Worker do not execute this tool.
The `engine-artifacts-runtime` service belongs to the `tools` profile and never
runs as a persistent platform service.

Online install/update pulls this helper only when
`MULTI_ENGINE_OPERATIONS_ENABLED=true`. Physical snapshots alone do not require
this artifact export helper. An explicit image override must already exist on
the Docker host; installers do not send local tags or IDs to a registry.
When MULTI is disabled, no new artifact helper is downloaded.

Development uses the root build context and `Dockerfile.engine-artifacts-runtime`.
`pnpm local:up` and `pnpm all` build the helper and four native copy variants only
with MULTI enabled. Copy variants use `Dockerfile.engine-copy-runtime` and explicit
`ENGINE_IMAGE` build args; they do not start database servers.
Manual preparation:

```sh
docker compose -f docker-compose.yml -f docker-compose.local.yml --profile tools build engine-artifacts-runtime engine-copy-mysql-8-0 engine-copy-mysql-8-4 engine-copy-mariadb-10-11 engine-copy-mariadb-11-4
```

Offline bundles include this helper and all four copy variants only with explicit build opt-in:

```powershell
# Set $PublishedRelease to an actual published release, not an illustrative number.
pnpm offline:bundle -Version $PublishedRelease -MultiEngineOperations -TrustedLicensePublicKeySha256 <trusted-SPKI-SHA256>
```

Offline installation checks local helper and all four copy image references when MULTI is enabled and
uses `up --pull never`. No installer or publisher accepts a SQL Server EULA.
SQL provisioning is separate from SQL operations opt-in: the operator must
confirm licensing outside the application, set
`SQLSERVER_PROVISIONING_LICENSE_CONFIRMED=true`, and explicitly choose
`SQLSERVER_PROVISIONING_PID`. Defaults remain false/empty. A Developer edition
does not grant production licensing rights.

## Offline Core server images

`-MultiEngineOperations` adds these exact Core target references alongside the
existing pinned restore profiles. Patch tags are not aliases for family tags:
having `mysql:8.4.11` alone does not install `mysql:8.4`.

| Purpose | Exact references |
| --- | --- |
| Core MySQL targets | mysql:8.0, mysql:8.4 |
| Core MariaDB targets | mariadb:10.11, mariadb:11.4 |
| Core MongoDB empty targets | mongo:6.0, mongo:7.0, mongo:8.0 |
| Existing operation restore profiles | mysql:8.4.11, mariadb:11.4.13 |

The seven new family references are included only with the bundle MULTI opt-in.
They do not start servers during packaging/install. Online install/update prepares
these same seven references only when BOTH `MULTI_ENGINE_OPERATIONS_ENABLED=true`
and `MULTI_ENGINE_RESTORE_SERVER_IMAGES_PULL=true`; existing images are skipped.
Default online downloads are unchanged. No SQL Server server image is added or
downloaded; SQL client tools are not a SQL Server/EULA approval.

With MULTI enabled, offline install requires all seven exact server tags plus
artifact/copy helpers locally before platform startup. An incomplete bundle
fails with the missing image reference, never silently attempts a network pull.
Every offline install persists and exports
`ENGINE_PROVISIONING_ALLOW_IMAGE_PULL=false`, overriding inherited online policy.
Online/development default is true; setting false must prohibit Core target pulls
at runtime too, not only Compose startup pulls. Agent enforcement and capability
inventory are a separate main-owned integration: see deployment coordination.
Until that integration is present, `up --pull never` alone does NOT guarantee
offline Core provisioning. Do not advertise offline family availability from a
static version list; exact installed image references must govern capabilities.
Nonadvertised patch versions require operator-provided local images and must fail
before target resources if unavailable. This inventory is not SQL offline support
or evidence of copy/restore/PITR correctness.

`ENGINE_PROVISIONING_BIND_ADDRESS=127.0.0.1` keeps newly provisioned ports local.
Remote access requires an explicit bind address and matching
`DOCKER_AGENT_EXTERNAL_HOST`; changing the latter alone does not expose ports.

## UI evidence

`GET /api/v1/databases/provisioning-capabilities` is an admin-only MediatR query
to the authenticated Agent's `GET /api/engine-instances/capabilities`.
Unknown/failed non-PG capabilities disable creation/copy. PostgreSQL versions
and provisioning remain independent. When `MULTI_ENGINE_OPERATIONS_ENABLED` is absent/false,
the proxy returns disabled non-PG modes without contacting the Agent in that case.
SQL empty creation is hidden unless the
Agent supplies both explicit support and accepted versions; operator confirmation
must remain enforced by the Agent, never a browser checkbox.

An HTTP 201 is not copy proof. UI reports copied data only with
`copyCompleted=true`; PostgreSQL restore jobs are reported as queued, not complete.
Source credentials from scanner and creation requests never enter React Query
caches. Native MySQL/MariaDB copy additionally requires the exact family-specific
`ENGINE_COPY_RUNTIME_IMAGE_PREFIX` images installed locally. Artifact helper is
not a substitute for native copy tools. Online install/update checks existing
copy images first and pulls missing GHCR references only with MULTI enabled.
Non-GHCR custom prefixes must be preinstalled locally and are never pulled by the
installer.

## Native copy image references

Production prefix is `ghcr.io/${REGISTRY_OWNER}/dunckops-engine-copy-runtime`,
without a tag. `ENGINE_COPY_RUNTIME_VERSION` defaults to `DUNCKOPS_VERSION` in
production; install/update require release `X.Y.Z`, never `latest`. The local
publisher also updates per-family `-latest` aliases; offline bundles pin and include
the exact release tags instead.
Published tags and build inputs are:

Replace `X.Y.Z` below with the actual published release selected by the operator.

| Tag for selected release X.Y.Z | ENGINE_IMAGE |
| --- | --- |
| mysql-8.0-X.Y.Z | mysql:8.0.46 |
| mysql-8.4-X.Y.Z | mysql:8.4.11 |
| mariadb-10.11-X.Y.Z | mariadb:10.11.19 |
| mariadb-11.4-X.Y.Z | mariadb:11.4.13 |

Development defaults to prefix `dunckops-engine-copy-runtime` and empty version,
retaining native tags `mysql-8.0`, `mysql-8.4`, `mariadb-10.11`, `mariadb-11.4`.
Nonempty version appends `-<version>` in development too. Prefix overrides must
be repository names, not tagged images; production overrides need matching
versioned family tags already installed. Publish-local and Docker Build matrix
build/push all four versioned tags and `-latest` aliases; release gating checks all four manifests.
Workflow files under `infra/workflows-backup` are templates, not active CI jobs.

Agent integration must use the same optional suffix in BOTH capability inventory
and native copy execution. Deployment changes do not prove that resolver change
works at runtime; latest source uses the shared suffix resolver in both places.
See `Docs/deployment-coordination.md`. No unsuffixed production alias is
created to conceal a missing version-aware resolver.

`ENGINE_PROVISIONING_NETWORK` defaults to `BACKUP_RUNTIME_NETWORK`, then
`dunckops-platform_default`. That Docker network must already exist when Agent
creates a target; this setting alone creates no network. SQL defaults remain
`SQLSERVER_PROVISIONING_ENCRYPT=true` and
`SQLSERVER_PROVISIONING_TRUST_SERVER_CERTIFICATE=false`. Stock self-signed bootstrap
is refused by the current stock-image capability gate unless operator explicitly
enables trust-server-certificate with encryption retained. This is isolated-lab
guidance, not verified production TLS: mounted-certificate provisioning is not
implemented in the current Agent. Explicit
trust bypass is not a production trust solution;
encryption must never be silently disabled. Licensing approval alone is not
evidence of reachable network, trusted TLS or successful native bootstrap.

Current Agent declarations are capabilities, not a release-wide smoke result:

| Engine | Empty creation families | Logical copy |
| --- | --- | --- |
| PostgreSQL | Independent runtime catalog | Existing asynchronous job |
| MySQL | 8.0, 8.4 | Single database, InnoDB base tables only |
| MariaDB | 10.11, 11.4 | Single database, InnoDB base tables only |
| MongoDB | 6.0, 7.0, 8.0 | Unavailable |
| SQL Server | Stock-image lab only, accepted versions and external license/PID plus explicit encrypted TLS trust policy | Unavailable |

MySQL/MariaDB views, routines, triggers and events are unsupported by this copy
mode. SQL Server operator licensing/PID and TLS policy are separate prerequisites,
not application consent. Linking existing containers does not prove provisioning,
copy, backup, restore or PITR readiness. Always use current server capabilities.

Offline bundle creation requires `-TrustedLicensePublicKeySha256`: SHA-256 of
the commercial RSA public key's DER SubjectPublicKeyInfo, obtained independently
from the trusted commercial issuer. A hash computed only from the local bundled
file is not trust evidence. A mismatch blocks packaging before downloads or staging.
Local publishing forwards the same required fingerprint. Release automation uses
repository variable `TRUSTED_LICENSE_PUBLIC_KEY_SHA256`; commercial trust has not
been verified by a build or by this repository's current public key alone.

`infra/scripts/setup-license.ps1` requires both `-DevelopmentOnly` and
`-ConfirmIsolatedDevelopment`, plus explicit company ID and host fingerprint. This fixture
generator writes an isolated temporary public key/token, expires in two hours,
discards the private key, and never changes `.env`, distributed public keys, or
company records. Production licensing uses Commercial API or official offline flow.
