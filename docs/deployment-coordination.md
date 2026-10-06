# Deployment coordination

## Required Agent integration

Deployment publishes one repository with four versioned tags, not four repositories:
`ghcr.io/<owner>/dunckops-engine-copy-runtime:<engine>-<major.minor>-<release>`.
`ENGINE_COPY_RUNTIME_IMAGE_PREFIX` is repository-only; `ENGINE_COPY_RUNTIME_VERSION`
is optional and empty for existing development tags. Production Compose resolves
the version to `DUNCKOPS_VERSION`. Do not add unsuffixed aliases in production.

Main / provisioning owner must adapt both existing image reference construction
sites before release: capability inventory in `EngineProvisioning.cs` and native
execution in `EngineProvisioning.MySqlCopy.cs`. Required reference rule:

```text
prefix + ":" + engine + "-" + family + (version empty ? "" : "-" + version)
```

Default prefix remains `dunckops-engine-copy-runtime` for native development.
Inventory must inspect this exact reference locally and declare copy available
only for installed families. Native preflight still authenticates and validates
tool versions; image existence alone is not a successful-copy guarantee.
No provisioning-owner files were edited by the deployment change. If Agent
still inventories unsuffixed tags, versioned production images do not enable copy;
capability must remain false rather than claiming installation/readiness.
With a nonempty version, never fall back to legacy unsuffixed images, even if
already installed. Latest source now uses shared `CopyRuntimeImage` in BOTH
inventory and execution. This source check does not prove installed manifests or
successful runtime copy; deployment/provisioning-owner files remain separately owned.

## Required offline pull policy

Main must implement `ENGINE_PROVISIONING_ALLOW_IMAGE_PULL` in Core Agent paths.
Online default is true. Offline installer writes false to configuration and
exports false before Compose, so inherited true cannot override offline policy.
Malformed explicit values must fail closed rather than silently enabling pulls.

When false, inspect the exact target image before any image-create/pull request
or target resource. Missing images must return a safe unavailable-image result,
not attempt registry access. Apply this to empty creation and native copy targets;
source-selected family tags are not interchangeable with pinned restore tags.

Bundle MULTI opt-in provides these exact references:

| Engine | Core target images |
| --- | --- |
| MySQL | mysql:8.0, mysql:8.4 |
| MariaDB | mariadb:10.11, mariadb:11.4 |
| MongoDB | mongo:6.0, mongo:7.0, mongo:8.0 |

Pinned `mysql:8.4.11` / `mariadb:11.4.13` remain operation restore profiles.
SQL Server server images are deliberately absent; licensing defaults false/PID
empty remain unchanged. Do not derive offline SQL availability from helper tools.

When pull policy is false, capability versions/emptyProvisioning must reflect
installed exact Core server tags, not static supported-family lists. logicalCopy
also requires installed family-specific copy helper AND target server image.
No image existence checks may expose credentials. Missing source-selected patch
images must fail before target resources; do not fall back to another tag/family.
At time of this deployment edit, Agent still creates missing images automatically
and has no pull-policy guard; main integration is a release blocker. `up --pull
never` constrains Compose startup only, not Docker API calls from Agent.

## SQL prerequisites

Compose passes `ENGINE_PROVISIONING_NETWORK` with fallback to
`BACKUP_RUNTIME_NETWORK` / `dunckops-platform_default`. Provisioning owner must
use/validate existing network before resources and report capabilities accurately.
Defaults: encrypt true, trust-server-certificate false, licensing confirmation
false, PID empty. No application, installer or publisher accepts licensing for
the operator. Stock self-signed bootstrap is not proven with strict trust.

Capability owner must withhold SQL empty provisioning until prerequisites it can
actually verify are met. UI already requires explicit empty support AND a
nonempty accepted-version list; unknown/failed capabilities remain disabled.
Do not invent accepted versions or infer trusted TLS from license approval.
Latest stock-image gate also requires encryption and explicit certificate trust
override. Mounted-certificate provisioning is unavailable; default SQL capability
remains false. An isolated-lab trust override is not verified production TLS.

## Release evidence limits

Build scripts/matrices and offline packaging define exact image references.
Files in `infra/workflows-backup` are inactive templates until activated by owner.
No registry publication, image pull/build, database bootstrap or certificate trust
verification was performed by this deployment follow-up. Release needs matching
Agent suffix integration, published manifests and independently trusted licensing
public-key fingerprint. Source compatibility matrix remains owned by provisioning
owner in `Docs/core-provisioning.md`; this note does not widen supported scope.
