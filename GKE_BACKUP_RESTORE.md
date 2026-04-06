# OpenDSO GCP Marketplace — Backup and Restore Notes

This document describes practical backup and restore considerations for the stateful parts of the OpenDSO Marketplace deployment on GKE.

## 1. Scope

The Marketplace package persists data in:

- MongoDB
- Citus DB
- opendso-apps-db
- Keycloak persistent volume
- Grafana persistent volume
- ESS Manager Redis
- topology-genesis PVC-backed data
- openfmb-event-service PVC-backed data
- asset-health-sim-svc PVC-backed data

No repo-level automation currently performs coordinated application-consistent backups across all components. The guidance here is operational rather than fully automated.

## 2. Recommended GKE Backup Options

Preferred options:

- GKE volume snapshots for PVC-backed storage
- database-native exports for MongoDB and PostgreSQL-derived services
- scheduled export jobs if you need application-level restore points

## 3. MongoDB Backup

Use `mongodump` from inside the MongoDB pod or from a temporary client pod.

Example:

```bash
kubectl exec -n <namespace> <release>-mongodb-0 -- \
  mongodump \
  --username <root-user> \
  --password '<root-password>' \
  --authenticationDatabase admin \
  --out /tmp/mongodump
```

Copy the dump out:

```bash
kubectl cp <namespace>/<release>-mongodb-0:/tmp/mongodump ./mongodump
```

Restore example:

```bash
kubectl cp ./mongodump <namespace>/<release>-mongodb-0:/tmp/mongodump
kubectl exec -n <namespace> <release>-mongodb-0 -- \
  mongorestore \
  --username <root-user> \
  --password '<root-password>' \
  --authenticationDatabase admin \
  /tmp/mongodump
```

## 4. PostgreSQL-Derived Backups

This applies to:

- Citus DB
- opendso-apps-db
- keycloak-db if enabled

Logical backup example:

```bash
kubectl exec -n <namespace> <release>-citus-db-0 -- \
  pg_dump -U <user> -d <database> > citus.sql
```

For `opendso-apps-db`, repeat per database such as `ess_tester` and `assets`.

Restore example:

```bash
cat citus.sql | kubectl exec -i -n <namespace> <release>-citus-db-0 -- \
  psql -U <user> -d <database>
```

## 5. PVC Snapshot Strategy

For components that rely mainly on PVC-backed application state, use GKE volume snapshots if your storage class and cluster policy support them.

Candidates:

- Keycloak
- Grafana
- ESS Manager Redis
- topology-genesis
- openfmb-event-service
- asset-health-sim-svc

Important:

- snapshot consistency depends on the application state at the time of capture
- database-native exports are safer than raw snapshots when you need logical consistency

## 6. Secrets and Configuration Backup

Back up the following separately:

- deployer-created secrets:
  - `<release>-nats-auth-keys`
  - `<release>-opendso-license`
  - `<release>-opendso-apps-db-secret`
  - `<release>-citus-db-secret`
  - `<release>-*-keycloak-env`
- release TLS secret and TLS alias secrets if chart-managed
- user-supplied values used for the deployment

Example:

```bash
kubectl get secret <secret-name> -n <namespace> -o yaml > <secret-name>.yaml
kubectl get configmap <configmap-name> -n <namespace> -o yaml > <configmap-name>.yaml
```

## 7. Restore Order

For a full environment rebuild, restore in this order:

1. namespace and prerequisites
2. TLS and required secrets
3. Helm release
4. stateful database content
5. Keycloak and Grafana persistent data if restoring from PVC snapshot path
6. application verification

## 8. Important Caveats

- Keycloak realm import from config is not the same as restoring a live Keycloak stateful environment
- deployer-generated secrets are not deleted by `helm uninstall`, so backup/restore plans should account for them separately from Helm state
- no repo-provided orchestration exists today for point-in-time recovery across MongoDB, PostgreSQL-derived databases, and Redis as one consistent unit
