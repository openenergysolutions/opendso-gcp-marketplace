# OpenDSO — GCP Marketplace

OpenDSO is an open-source Distribution System Operator (DSO) platform for managing
grid-edge devices, distributed energy resources (DERs), and microgrid operations
using the [OpenFMB](https://openfmb.org/) standard.

This repository contains the GCP Marketplace deployer package.

---

## What Gets Deployed

A single Helm release installs the full OpenDSO stack into your GKE cluster:

| Category | Components |
|---|---|
| **Infrastructure** | NATS (messaging), Keycloak (identity), Grafana (monitoring) |
| **Databases** | MongoDB, Citus (PostgreSQL), TimescaleDB |
| **Core Services** | GMS API, Historian, OpenFMB Event Service, NATS Auth |
| **Topology** | Topology Genesis, Topology Nodes |
| **Grid Applications** | DER Dispatch, ESS Manager, ESS Tester, Asset Health |
| **Frontend Apps** | One-Line, GIS, Historian, Inspector, Inventory, Data Viewer, and more |

After deployment, the following endpoints are available at your configured domain:

| Service | URL |
|---|---|
| GMS (One-Line) | `https://oneline.<domain>` |
| Keycloak Admin | `https://keycloak.<domain>/admin` |
| Grafana | `https://grafana.<domain>` |
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
   - **Grafana Admin Password**
   - **Resource Profile** — `minimal`, `default`, or `production`
5. Click **Deploy**

The deployer will:

- Generate fresh NATS authentication keys (NKeys) unique to your deployment
- Generate per-service Keycloak client secrets and pre-populate the realm
- Create all `*-keycloak-env` Kubernetes secrets before services start
- Deploy all services via Helm in a single pass (no post-install step required)
- Wait for all pods to reach Ready state (`helm --wait`) before marking the installation complete

---

## Prerequisites

The GCP Marketplace deployer assumes these are already in place before you click **Deploy**.
It does **not** create GKE clusters, install ingress controllers, configure DNS, or manage TLS.

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

    ```bash
    helm repo add jetstack https://charts.jetstack.io
    helm install cert-manager jetstack/cert-manager -n cert-manager \
      --create-namespace --set installCRDs=true
    ```

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

### What the deployer does NOT handle

| Responsibility | Who handles it |
|---|---|
| GKE cluster creation | You (before installing) |
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
├── chart/                  # Helm chart (mirrors opendso-helm-charts/opendso/)
│   ├── Chart.yaml
│   ├── values.yaml         # Default values
│   ├── values-gcp.yaml     # GCP-specific overrides
│   ├── charts/             # 38 subcharts
│   ├── templates/          # Parent chart templates
│   └── configs/            # Site-specific configuration (ieee13)
├── deployer/
│   ├── Dockerfile              # Custom deployer image (extends deployer_helm)
│   ├── deploy.sh               # NKey generation + Keycloak secret injection + helm install
│   └── deploy_with_tests.sh    # Wraps deploy.sh + runs verify.sh (used by mpdev verify)
├── scripts/
│   ├── verify.sh               # Post-deploy health checks (called by deploy_with_tests.sh)
│   ├── mpdev.sh                # Helper to run mpdev verify locally
│   └── provision-test-env.sh   # Provisions a local test cluster environment
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
  --parameters='{"name":"opendso-test","namespace":"test","license.key":"secret-license","installation.key":"secret-install","global.domain":"test.example.com","keycloak.config.adminPassword":"secret","mongodb.auth.rootPassword":"secret","mongodb.auth.password":"secret","grafana.adminPassword":"secret"}'
```

---

## Security Notes

- **NATS NKeys** are generated fresh on every deployment by `deployer/deploy.sh` — private seeds are never stored in this repository
- **Keycloak client secrets** are generated as UUIDs at deploy time — pre-populated into the realm JSON so Keycloak imports them on first boot, never stored in this repository
- All passwords are passed via GCP Marketplace's `MASKED_FIELD` mechanism and stored as Kubernetes Secrets
- Third-party images (NATS, Keycloak, MongoDB, etc.) should be mirrored to your Artifact Registry before submission to ensure supply chain control

---

## Support

- **Issues**: [opendso-gcp-marketplace](https://github.com/openenergysolutions/opendso-gcp-marketplace/issues)
- **Documentation**: [chart/README.md](chart/README.md)
- **Email**: <info@openenergysolutions.com>
