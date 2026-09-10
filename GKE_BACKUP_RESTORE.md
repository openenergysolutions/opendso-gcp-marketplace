# OpenDSO GCP Marketplace — Backup and Restore Notes

This document describes practical backup and restore considerations for the stateful parts of the OpenDSO Marketplace deployment on GKE.

## 1. Scope

The Marketplace package persists data in:

- Cloud SQL PostgreSQL (external — `ess_tester`, `ofmb_db`, `assets`, `settings_api`, `opendso` databases)
- Keycloak persistent volume
- ESS Manager Redis
- topology-genesis PVC-backed data
- openfmb-event-service PVC-backed data
- asset-health-sim-svc PVC-backed data

No repo-level automation currently performs coordinated application-consistent backups across all components. The guidance here is operational rather than fully automated.

## 2. Recommended GKE Backup Options

Preferred options:

- GKE volume snapshots for PVC-backed storage
- database-native exports for PostgreSQL-derived services
- scheduled export jobs if you need application-level restore points

## 3. Cloud SQL Backups

Cloud SQL is the external PostgreSQL provider for OpenDSO (`ess_tester`, `ofmb_db`, `assets`, `settings_api`, `opendso` databases). Use Cloud SQL's built-in automated backups or export manually:

```bash
# Export a database to Cloud Storage
gcloud sql export sql <instance-name> gs://<bucket>/opendso-backup.sql \
  --project=<project-id> \
  --database=ess_tester,ofmb_db,assets,settings_api,opendso
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

- Keycloak
- ESS Manager Redis
- topology-genesis
- openfmb-event-service
- asset-health-sim-svc

Important:

- snapshot consistency depends on the application state at the time of capture
- database-native exports are safer than raw snapshots when you need logical consistency

## 5. Secrets and Configuration Backup

Back up the following separately:

- deployer-created secrets:
  - `<release>-nats-auth-keys`
  - `<release>-opendso-license`
  - `<release>-apps-db-credentials`
  - `<release>-*-keycloak-env`
- release TLS secret and TLS alias secrets if chart-managed
- user-supplied values used for the deployment

Example:

```bash
kubectl get secret <secret-name> -n <namespace> -o yaml > <secret-name>.yaml
kubectl get configmap <configmap-name> -n <namespace> -o yaml > <configmap-name>.yaml
```

## 6. Restore Order

For a full environment rebuild, restore in this order:

1. namespace and prerequisites
2. TLS and required secrets
3. Helm release
4. stateful database content
5. Keycloak persistent data if restoring from PVC snapshot path
6. application verification

## 7. Important Caveats

- Keycloak realm import from config is not the same as restoring a live Keycloak stateful environment
- deployer-generated secrets are not deleted by `helm uninstall`, so backup/restore plans should account for them separately from Helm state
- no repo-provided orchestration exists today for point-in-time recovery across PostgreSQL-derived databases and Redis as one consistent unit
