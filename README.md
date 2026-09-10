# OpenDSO — GCP Marketplace

OpenDSO is an open-source Distribution System Operator (DSO) platform for managing
grid-edge devices, distributed energy resources (DERs), and microgrid operations
using the [OpenFMB](https://openfmb.org/) standard.

This repository contains the GCP Marketplace deployer package.

---

## What Gets Deployed

A single Helm release installs the full OpenDSO stack into your GKE cluster:

| Category | Components |
| --- | --- |
| **Infrastructure** | NATS (messaging), Keycloak (identity) |
| **Databases** | MongoDB, Cloud SQL PostgreSQL (external — provisioned separately) |
| **Core Services** | GMS API, Historian, OpenFMB Event Service, NATS Auth |
| **Topology** | Topology Genesis, Topology Nodes |
| **Grid Applications** | DER Dispatch, ESS Manager, ESS Tester, Asset Health |
| **Frontend Apps** | One-Line, GIS, Historian, Inspector, Inventory, Data Viewer, and more |

After deployment, the following endpoints are available at your configured domain:

| Service | URL |
| --- | --- |
| GMS (One-Line) | `https://oneline.<domain>` |
| Keycloak Admin | `https://keycloak.<domain>/admin` |
| GMS API | `https://api.<domain>` |
| NATS WebSocket | `wss://nats.<domain>` |

---

## Install from GCP Marketplace

1. Find **OpenDSO** in [GCP Marketplace](https://console.cloud.google.com/marketplace)
2. Click **Configure**
3. Select your GKE cluster and namespace
4. Fill in the required parameters:
   - **Domain Name** — base domain (e.g. `opendso.example.com`). DNS must point to your cluster's LoadBalancer IP.
   - **OpenDSO License Key** — obtained from OES; required to activate the application.
   - **OpenDSO Installation Key** — obtained from OES; required to activate the application.
   - **Keycloak Admin Password**
   - **MongoDB Root Password** and **MongoDB App Password**
   - **Apps DB Host** — Cloud SQL private IP (provisioned in the Cloud SQL prerequisite step below)
   - **Apps DB Password** — password for the `essuser` database user
   - **Resource Profile** — `minimal`, `default`, or `production`
5. Click **Deploy**

The deployer will:

- Generate fresh NATS authentication keys (NKeys) unique to your deployment
- Generate per-service Keycloak client secrets and pre-populate the realm
- Create all `*-keycloak-env` Kubernetes secrets before services start
- Deploy all services via Helm in a single pass (no post-install step required)
- Run post-deploy verification checks after Helm applies the manifests; readiness is validated by `scripts/verify.sh`, not by `helm --wait`

Licensing note:

- OpenDSO licensing in this package is handled by OES through the supplied `license.key` and `installation.key`
- this package does not implement GCP Marketplace metering-based entitlement enforcement
- `topology-nodes` performs runtime license validation against the configured license API using those credentials

---

## Prerequisites

The GCP Marketplace deployer assumes these are already in place before you click **Deploy**.
It does **not** create GKE clusters, install ingress controllers, configure DNS, manage TLS, or provision Cloud SQL.

### Cloud SQL

OpenDSO requires a Cloud SQL PostgreSQL 16 instance with four databases initialized before deployment.
Run the provisioning script once per environment:

```bash
./scripts/provision-cloud-sql.sh \
  --project   my-gcp-project \
  --region    us-central1 \
  --instance  opendso-db \
  --namespace opendso \
  --release   opendso
```

The script:

1. Creates the Cloud SQL instance (`--skip-create` to attach to an existing one)
2. Creates the `ess_tester`, `ofmb_db`, `assets`, and `opendso` databases
3. Applies the OpenDSO schema (via Cloud SQL Proxy + psql, or via `--run-in-cluster` for private-IP-only instances)
4. Writes a `<release>-apps-db-credentials` Kubernetes Secret

After the script completes, set the reported private IP in `values-gcp.yaml`:

```yaml
opendso-apps-db:
  externalDatabase:
    host: "<CLOUD-SQL-PRIVATE-IP>"
    existingSecret: "<release>-apps-db-credentials"
```

**Prerequisites for the script:** `gcloud` authenticated with `roles/cloudsql.admin` + `roles/cloudsql.client`, `cloud-sql-proxy`, and `psql` in PATH.

#### Materialized view refresh — pg_cron (recommended)

The Asset Health service (`asset-health-svc`) uses four PostgreSQL materialized views in the `assets` database. These views must be refreshed periodically to reflect new data. The recommended approach on Cloud SQL is **pg_cron**, which schedules the refresh inside the database itself — no Kubernetes CronJob needed.

Add `--pg-cron` when running the provisioning script:

```bash
./scripts/provision-cloud-sql.sh \
  --project   my-gcp-project \
  --region    us-central1 \
  --instance  opendso-db \
  --namespace opendso \
  --release   opendso \
  --pg-cron
# prompts for both the essuser password and the postgres superuser password
```

With `--pg-cron` the script:

1. Sets the `cloudsql.enable_pg_cron=on` database flag on the instance (at creation time, so no restart)
2. Creates the `pg_cron` extension in the `postgres` database (requires the `postgres` superuser password)
3. Grants the `essuser` application user the right to schedule cron jobs
4. Schedules `ahs-matview-refresh` — a `*/15 * * * *` job that runs `REFRESH MATERIALIZED VIEW` on all four views (`common_metrics`, `breaker_metrics`, `generator_metrics`, `asset_health_daily`) in the `assets` database as `essuser`

The job runs entirely inside Cloud SQL and persists across pod restarts. To inspect job history:

```sql
SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;
```

If you're attaching to an **existing** instance (`--skip-create`), the script will patch the `cloudsql.enable_pg_cron=on` flag. Note that `--database-flags` replaces all existing flags on the instance — if you have other custom flags set, include them alongside `cloudsql.enable_pg_cron=on` manually after provisioning.

The Cloud SQL instance must be on the same VPC as the GKE cluster (Private IP via VPC peering or Private Service Connect). The schema init scripts are in `chart/configs/ieee13/opendso-apps-db/schema/`.

### Cluster

- GKE cluster (Kubernetes 1.24+) with `kubectl` configured
- `nginx-ingress` controller installed:

  ```bash
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace
  ```

- Application CRD (`app.k8s.io/v1beta1`) installed — required by the GCP Marketplace deployer and `mpdev` tooling:

  ```bash
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/application/master/config/crd/bases/app.k8s.io_applications.yaml"
  ```

### DNS & TLS

- Wildcard DNS `*.yourdomain.com` pointing to the nginx LoadBalancer IP:

  ```bash
  # Get the LoadBalancer IP
  kubectl get svc -n ingress-nginx ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
  ```

- TLS certificate as a Kubernetes secret named `<release-name>-tls-secret`.
  Options:
  - **cert-manager + Let's Encrypt** (recommended):

    Use **DNS-01** for wildcard certificates such as `*.yourdomain.com`. `HTTP-01` is not suitable for a wildcard certificate. If you only want a single non-wildcard hostname, `HTTP-01` can work, but OpenDSO is designed around multiple subdomains and is best served by a wildcard certificate.

    ```bash
    helm repo add jetstack https://charts.jetstack.io
    helm install cert-manager jetstack/cert-manager -n cert-manager \
      --create-namespace --set installCRDs=true
    ```

    Practical production guidance on GKE:

    - use a DNS provider supported by cert-manager or an external DNS webhook solver
    - create a `ClusterIssuer` that uses `dns01`
    - request a certificate covering both `<domain>` and `*.<domain>`
    - wait for `<release-name>-tls-secret` to exist before deploying OpenDSO
    - on GKE with Cloud DNS, prefer a `dns01.cloudDNS` solver tied to the managed zone for your base domain

    `HTTP-01` can still be used for testing a single hostname, but it should not be treated as the production wildcard path for this package

  - **Chart-generated self-signed fallback** (non-production safety net):

    The chart can generate a self-signed `<release-name>-tls-secret` in the Marketplace path if no certificate exists yet. Treat this as a test/install-resilience mechanism only. It is suitable for `mpdev verify` and controlled non-production installs, but it is not the recommended long-term production TLS model.

  - **Self-signed** (for testing):

    ```bash
    mkcert "*.yourdomain.com" yourdomain.com
    kubectl create secret tls <release-name>-tls-secret \
      --cert=_wildcard.yourdomain.com.pem \
      --key=_wildcard.yourdomain.com-key.pem \
      -n <namespace>
    ```

### Image pull access

- Container images are served from GCP Artifact Registry. GKE nodes need pull access —
  configure Workload Identity or attach the Artifact Registry Reader role to the node service account.
- See `IMAGE_MIRRORING_ARTIFACT_REGISTRY.md` for the mirroring workflow and registry expectations.
- First-party OpenDSO app images can be mirrored with `scripts/mirror-app-images.sh`; that workflow can also add Marketplace annotations, add release tags, and refresh digests in `chart/values.yaml`.

### What the deployer does NOT handle

| Responsibility | Who handles it |
| --- | --- |
| GKE cluster creation | You (before installing) |
| Cloud SQL provisioning and schema init | You — run `scripts/provision-cloud-sql.sh` |
| nginx ingress controller | You (before installing) |
| Application CRD (app.k8s.io) | You (before installing) |
| cert-manager / TLS certificates | You (before installing) |
| DNS configuration | You (before installing) |
| Image pull authentication | GKE node service account / Workload Identity |
| Keycloak client provisioning | Handled automatically by the deployer |

---

## Repository Structure

```text
opendso-gcp-marketplace/
├── chart/                  # Helm chart
│   ├── Chart.yaml
│   ├── values.yaml         # Default values
│   ├── values-gcp.yaml     # GCP-specific overrides
│   ├── charts/             # Subcharts
│   ├── templates/          # Parent chart templates
│   └── configs/            # Site-specific configuration (ieee13)
│       └── ieee13/
│           └── opendso-apps-db/schema/   # SQL init scripts for Cloud SQL
├── deployer/
│   ├── Dockerfile              # Custom deployer image (extends deployer_helm)
│   ├── deploy.sh               # NKey generation + Keycloak secret injection + helm install
│   └── deploy_with_tests.sh    # Wraps deploy.sh + runs verify.sh (used by mpdev verify)
├── scripts/
│   ├── provision-cloud-sql.sh    # Create Cloud SQL instance, databases, schema, K8s Secret
│   ├── mirror-app-images.sh      # Mirror first-party app images into Artifact Registry
│   ├── mirror-k8s-marketplace-images.sh  # Mirror third-party images into Artifact Registry
│   ├── verify.sh                 # Post-deploy health checks (called by deploy_with_tests.sh)
│   ├── mpdev.sh                  # Helper to run mpdev verify locally
│   └── predeployment-setup.sh    # Automates cluster/DNS/TLS prerequisites
├── schema.yaml             # GCP Marketplace UI schema (parameters + images)
└── README.md               # This file
```

---

## Building the Deployer Image

```bash
# From the repo root
docker build -f deployer/Dockerfile -t gcr.io/<your-project>/opendso/deployer:1.0.0 .
docker push gcr.io/<your-project>/opendso/deployer:1.0.0
```

---

## Testing the Deployer Locally

Install [mpdev](https://github.com/GoogleCloudPlatform/marketplace-k8s-app-tools) (GCP Marketplace dev tools):

```bash
# Verify the schema
mpdev verify --deployer=gcr.io/<your-project>/opendso/deployer:1.0.0

# Test install into a real cluster
mpdev install \
  --deployer=gcr.io/<your-project>/opendso/deployer:1.0.0 \
  --parameters='{"name":"opendso-test","namespace":"test","license.key":"secret-license","installation.key":"secret-install","global.domain":"test.example.com","keycloak.config.adminPassword":"secret","opendso-apps-db.externalDatabase.host":"<CLOUD-SQL-IP>","opendso-apps-db.externalDatabase.password":"secret"}'
```

---

## Security Notes

- **NATS NKeys** are generated fresh on every deployment by `deployer/deploy.sh` — private seeds are never stored in this repository
- **Keycloak client secrets** are generated as UUIDs at deploy time — pre-populated into the realm JSON so Keycloak imports them on first boot, never stored in this repository
- Marketplace-supplied passwords are passed via GCP Marketplace `MASKED_FIELD` parameters and stored as Kubernetes Secrets; the production chart path no longer relies on shipped plaintext password defaults
- TLS is standardized around the release-scoped secret `<release-name>-tls-secret`; the chart can also create `root-ca`, `server-cert`, and `server-key` compatibility secrets for workloads that still mount those names
- Backend services that support numeric non-root execution are configured to run with explicit non-root security contexts; stateful infrastructure components are hardened more conservatively where image startup still requires root-like filesystem initialization
- `topology-nodes` validates `LICENSE_KEY` and `LICENSE_INSTALLATION_KEY` against the configured license API at startup and on a periodic revalidation interval
- Third-party images (NATS, Keycloak, Postgres, etc.) should be mirrored to your Artifact Registry before submission to ensure supply chain control

## GKE Runtime Notes

- `gms-api` manages pods (its orchestration feature) via the in-cluster Kubernetes API rather than a Docker daemon, since GKE uses containerd and does not expose a Docker socket
- its RBAC is namespace-scoped (`orchestration.rbac.scope: namespace`) rather than cluster-wide, so orchestration is limited to pods in the app's own release namespace

---

## Support

- **Issues**: [opendso-gcp-marketplace](https://github.com/openenergysolutions/opendso-gcp-marketplace/issues)
- **Documentation**: [chart/README.md](chart/README.md)
- **Customer Checklist**: [GKE_MARKETPLACE_PREDEPLOYMENT_CHECKLIST_CUSTOMER.md](GKE_MARKETPLACE_PREDEPLOYMENT_CHECKLIST_CUSTOMER.md)
- **Troubleshooting**: [GKE_MARKETPLACE_TROUBLESHOOTING.md](GKE_MARKETPLACE_TROUBLESHOOTING.md)
- **Image Mirroring**: [IMAGE_MIRRORING_ARTIFACT_REGISTRY.md](IMAGE_MIRRORING_ARTIFACT_REGISTRY.md)
- **Backup / Restore**: [GKE_BACKUP_RESTORE.md](GKE_BACKUP_RESTORE.md)
- **Email**: <info@openenergysolutions.com>
