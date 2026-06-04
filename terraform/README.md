# OpenDSO — Terraform Kubernetes deployment

Deploys the [OpenDSO](https://github.com/openenergysolutions) platform onto a
Google Kubernetes Engine (GKE) cluster via the Helm provider. This module is the
deployment wrapper for the OpenDSO **Google Cloud Marketplace** "Kubernetes App
(using Terraform)" product.

Deploy chain: `customer Deploy → this module → Helm provider → opendso umbrella
chart (OCI, Artifact Registry) → workloads`.

The module installs the chart at
`oci://us-docker.pkg.dev/openenergysolutionsinc-public/oesinc/opendso`. The chart
is self-contained — it generates all deploy-time secrets (Keycloak client
secrets, database passwords, TLS material, license secret), so no external
scripting is required.

## Prerequisites

- An existing GKE cluster (this module does **not** create one).
- An NGINX ingress controller installed in the cluster.
- DNS: a wildcard `*.<domain>` pointing at the ingress load balancer address.
- The GKE node service account (or Workload Identity principal) granted
  `roles/artifactregistry.reader` on the registry hosting the OpenDSO images.
- A BYOL license key + installation key from OES.
- Terraform >= 1.3, and credentials with access to the target project/cluster
  (`gcloud auth application-default login`).

## Usage

```hcl
module "opendso" {
  source = "github.com/openenergysolutions/opendso-gcp-marketplace//terraform"

  project_id       = "my-project"
  cluster_name     = "my-gke-cluster"
  cluster_location = "us-central1"

  namespace         = "opendso"
  app_instance_name = "opendso"
  domain            = "opendso.example.com"

  # BYOL
  license_key      = var.license_key
  installation_key = var.installation_key

  # Service credentials
  keycloak_admin_password = var.keycloak_admin_password
  mongodb_root_password   = var.mongodb_root_password
  mongodb_app_password    = var.mongodb_app_password
  grafana_admin_password  = var.grafana_admin_password
}
```

## CLI deploy

```bash
cd terraform

# Provide the required values (example uses a tfvars file; keep secrets out of VCS)
cat > deploy.auto.tfvars <<'EOF'
project_id       = "my-project"
cluster_name     = "my-gke-cluster"
cluster_location = "us-central1"
namespace        = "opendso"
domain           = "opendso.example.com"
EOF

# Secrets via environment variables (TF_VAR_*) rather than a file:
export TF_VAR_license_key=...
export TF_VAR_installation_key=...
export TF_VAR_keycloak_admin_password=...
export TF_VAR_mongodb_root_password=...
export TF_VAR_mongodb_app_password=...
export TF_VAR_grafana_admin_password=...

terraform init
terraform plan
terraform apply
```

To uninstall: `terraform destroy`.

## Notes

- **GCP defaults** live in `values-gcp.yaml`, applied as the base Helm values
  layer. It is a copy of `chart/values-gcp.yaml`; keep the two in sync when the
  chart changes.
- **Image registry**: leave `image_registry` empty to use the chart defaults.
  Cloud Marketplace repoints this to its published image copies automatically.
- **Consumption label**: Google injects a `goog-partner-solution` label into
  provisioned resources; this module does not manage or remove it.
- **Resource profile**: `minimal` | `default` | `production` — sizing preset
  applied to all services. The GCP overlay defaults to `production`.

## Inputs

| Name | Description | Default | Required |
|------|-------------|---------|:--------:|
| `project_id` | GCP project containing the target GKE cluster | — | yes |
| `cluster_name` | Target GKE cluster name | — | yes |
| `cluster_location` | Region or zone of the cluster | — | yes |
| `namespace` | Namespace to deploy into | — | yes |
| `domain` | Base domain for all services | — | yes |
| `app_instance_name` | Helm release name | `opendso` | no |
| `create_namespace` | Create the namespace if absent | `true` | no |
| `chart_version` | opendso chart version (tag) | `0.1.0` | no |
| `image_registry` | Artifact Registry prefix for images | `""` | no |
| `resource_profile` | `minimal`/`default`/`production` | `default` | no |
| `storage_class` | StorageClass for all persistent volumes | `dynamic-rwo` | no |
| `license_key` | OpenDSO license key (BYOL) | — | yes |
| `installation_key` | OpenDSO installation key (BYOL) | — | yes |
| `keycloak_admin_user` | Keycloak admin username | `admin` | no |
| `keycloak_admin_password` | Keycloak admin password | — | yes |
| `mongodb_root_username` | MongoDB root username | `root` | no |
| `mongodb_root_password` | MongoDB root password | — | yes |
| `mongodb_app_username` | MongoDB app username | `opendso` | no |
| `mongodb_app_password` | MongoDB app password | — | yes |
| `grafana_admin_user` | Grafana admin username | `admin` | no |
| `grafana_admin_password` | Grafana admin password | — | yes |
| `additional_values` | Raw YAML merged last (highest precedence) | `""` | no |

## Outputs

| Name | Description |
|------|-------------|
| `release_name` | Helm release name |
| `namespace` | Deployment namespace |
| `chart_version` | Deployed chart version |
| `release_status` | Helm release status |
| `service_endpoints` | Map of externally-resolvable service URLs |
