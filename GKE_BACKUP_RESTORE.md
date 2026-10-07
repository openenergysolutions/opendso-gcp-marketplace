# OpenDSO GCP Marketplace — Backup and Restore Notes

This document describes practical backup and restore considerations for the stateful parts of the OpenDSO Marketplace deployment on GKE.

## 1. Scope

The Marketplace package persists data in:

- Cloud SQL PostgreSQL (external — `ess_tester`, `ofmb_db`, `assets`, `settings_api`, `opendso`, `ess_manager` databases)
- Keycloak persistent volume
- topology-genesis PVC-backed data
- openfmb-event-service and asset-health-sim-svc PVC-backed data, only if you enabled them (both
  are off by default: `openfmb-event-service.persistence.enabled` and `global.asset-health-sim-svc.enabled`)

No repo-level automation currently performs coordinated application-consistent backups across all components. The guidance here is operational rather than fully automated.

## 2. Recommended GKE Backup Options

Preferred options:

- GKE volume snapshots for PVC-backed storage
- database-native exports for PostgreSQL-derived services
- scheduled export jobs if you need application-level restore points

## 3. Cloud SQL Backups

Cloud SQL is the external PostgreSQL provider for OpenDSO (`ess_tester`, `ofmb_db`, `assets`, `settings_api`, `opendso`, `ess_manager` databases). Use Cloud SQL's built-in automated backups or export manually:

```bash
# Export a database to Cloud Storage
gcloud sql export sql <instance-name> gs://<bucket>/opendso-backup.sql \
  --project=<project-id> \
  --database=ess_tester,ofmb_db,assets,settings_api,opendso,ess_manager
```

Restore example:

```bash
gcloud sql import sql <instance-name> gs://<bucket>/opendso-backup.sql \
  --project=<project-id> \
  --database=ess_tester
```

Alternatively, connect via a temporary pod with the Cloud SQL private IP and use `pg_dump`/`psql` directly. See `scripts/provision-cloud-sql.sh` with `--run-in-cluster` for the pattern.

For `keycloak-db` (if enabled as an in-cluster PostgreSQL instance):

```bash
kubectl exec -n <namespace> <release>-keycloak-db-0 -- \
  pg_dump -U <user> -d keycloak > keycloak-db.sql
```

## 4. PVC Snapshot Strategy

For components that rely mainly on PVC-backed application state, use GKE volume snapshots if your storage class and cluster policy support them.

Candidates:

- Keycloak (`<release>-keycloak`)
- topology-genesis (`<release>-topology-genesis`)
- openfmb-event-service and asset-health-sim-svc, only if their persistence is enabled

Important:

- Keycloak's volume holds its embedded H2 database (users, clients, and any realm changes made
  after the initial import). The in-cluster `keycloak-db` is disabled by default. Scale Keycloak to
  zero before snapshotting (`kubectl scale deploy/<release>-keycloak -n <namespace> --replicas=0`),
  then back to one. A snapshot of a live H2 file may not be consistent.
- snapshot consistency depends on the application state at the time of capture
- database-native exports are safer than raw snapshots when you need logical consistency

## 5. Secrets and Configuration Backup

Back up the following separately:

- deployer-created secrets:
  - `<release>-nats-auth-keys`
  - `<release>-opendso-license`
  - `<release>-*-keycloak-env`
- `<release>-apps-db-credentials`, if you created it with `scripts/provision-cloud-sql.sh`
- release TLS secret and TLS alias secrets if chart-managed
- user-supplied values used for the deployment

The `<release>-*-keycloak-env` secrets matter most when restoring Keycloak. Each one holds a
per-service client secret that is also stored inside Keycloak's own database. A fresh install
generates new values. If you restore Keycloak's data but not these secrets, services will fail to
authenticate to Keycloak and NATS. The deployer reuses any of these secrets that already exist, so
restore them before redeploying.

Example:

```bash
kubectl get secret <secret-name> -n <namespace> -o yaml > <secret-name>.yaml
kubectl get configmap <configmap-name> -n <namespace> -o yaml > <configmap-name>.yaml
```

## 6. Restore Order

For a full environment rebuild, restore in this order:

1. namespace and prerequisites
2. TLS and required secrets, including the deployer-created secrets from section 5, so the deployer reuses them instead of generating new ones
3. Helm release
4. stateful database content
5. Keycloak persistent data if restoring from PVC snapshot path
6. application verification

## 7. Important Caveats

- Keycloak realm import from config is not the same as restoring a live Keycloak stateful environment
- deployer-generated secrets are not deleted by `helm uninstall`, so backup/restore plans should account for them separately from Helm state
- no repo-provided orchestration exists today for point-in-time recovery across PostgreSQL-derived databases and PVC-backed volumes as one consistent unit
