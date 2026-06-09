# =============================================================================
# OpenDSO — Google Cloud Marketplace Terraform Kubernetes deployment
#
# Deploy chain: customer clicks Deploy → this module → Helm provider →
# the opendso umbrella chart (OCI, Artifact Registry) → workloads.
#
# The module is self-contained: it wires the kubernetes/helm providers to the
# customer's GKE cluster from data sources, then installs the chart. The chart
# itself generates all deploy-time secrets (Keycloak client secrets, DB
# passwords, TLS, license secret), so no out-of-band scripting is required.
# =============================================================================

# --- Cluster connection -------------------------------------------------------
data "google_client_config" "default" {}

resource "google_container_cluster" "marketplace_test" {
  count = var.create_cluster ? 1 : 0

  name     = var.cluster_name
  location = var.cluster_location
  project  = var.project_id

  initial_node_count  = var.test_cluster_node_count
  min_master_version  = var.test_cluster_min_master_version == "" ? null : var.test_cluster_min_master_version
  deletion_protection = false

  node_config {
    machine_type = var.test_cluster_machine_type
    disk_size_gb = var.test_cluster_disk_size_gb
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}

data "google_container_cluster" "target" {
  count = var.create_cluster ? 0 : 1

  name     = var.cluster_name
  location = var.cluster_location
  project  = var.project_id
}

locals {
  cluster_endpoint_value = one(concat(
    google_container_cluster.marketplace_test[*].endpoint,
    data.google_container_cluster.target[*].endpoint,
  ))
  cluster_ca_value = one(concat(
    google_container_cluster.marketplace_test[*].master_auth[0].cluster_ca_certificate,
    data.google_container_cluster.target[*].master_auth[0].cluster_ca_certificate,
  ))

  cluster_endpoint = "https://${local.cluster_endpoint_value}"
  cluster_ca       = base64decode(local.cluster_ca_value)
  release_name     = var.goog_cm_deployment_name == "" ? var.app_instance_name : var.goog_cm_deployment_name

  # Release-/domain-dependent values that the old deployer set via --set.
  # Derived here so the chart receives exactly what it expects.
  keycloak_internal_url = "http://${local.release_name}-keycloak-svc:8080"
  keycloak_external_url = "https://keycloak.${var.domain}"
  api_url               = "https://api.${var.domain}"
  tls_secret_name       = "${local.release_name}-tls-secret"
  grafana_secret_name   = "${local.release_name}-grafana-credentials"

  # Producer Portal rewrites helm_chart_* defaults to the published Google-owned
  # chart copy. opendso_image_* remains declared for schema.yaml replacement.
  chart_repository = var.helm_chart_repo
  chart_name       = var.helm_chart_name
  chart_version    = var.helm_chart_version
}

provider "google" {
  project = var.project_id
}

provider "kubernetes" {
  host                   = local.cluster_endpoint
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = local.cluster_ca
}

provider "helm" {
  kubernetes {
    host                   = local.cluster_endpoint
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = local.cluster_ca
  }
}

# --- Release ------------------------------------------------------------------
resource "helm_release" "opendso" {
  count = var.install_helm_release ? 1 : 0

  name             = local.release_name
  namespace        = var.namespace
  create_namespace = var.create_namespace

  repository = local.chart_repository
  chart      = local.chart_name
  version    = local.chart_version

  timeout = 900 # 15m, matches the chart's heaviest workloads
  atomic  = false

  # GCP-specific defaults (security contexts, storage class, ingress, per-service
  # tuning). Sourced from chart/values-gcp.yaml — keep in sync when the chart changes.
  values = compact([
    file("${path.module}/values-gcp.yaml"),
    var.additional_values,
  ])

  # --- Core configuration (mirrors schema.yaml) ---
  set {
    name  = "global.namespace"
    value = var.namespace
  }
  set {
    name  = "global.domain"
    value = var.domain
  }
  set {
    name  = "global.resourceProfile"
    value = var.resource_profile
  }
  set {
    name  = "global.storageClass"
    value = var.storage_class
  }
  # Grafana is an upstream subchart and does not read global.storageClass.
  set {
    name  = "grafana.persistence.storageClassName"
    value = var.storage_class
  }

  # Image registry — left overridable so Marketplace can repoint to its copies.
  dynamic "set" {
    for_each = var.image_registry == "" ? [] : [var.image_registry]
    content {
      name  = "global.imageRegistry"
      value = set.value
    }
  }

  # --- Release-/domain-dependent wiring (was deploy.sh --set) ---
  set {
    name  = "global.keycloak.internalUrl"
    value = local.keycloak_internal_url
  }
  set {
    name  = "global.keycloak.url"
    value = local.keycloak_external_url
  }
  set {
    name  = "global.environment.apiUrl"
    value = local.api_url
  }
  set {
    name  = "global.tls.createSecrets"
    value = "true"
  }
  set {
    name  = "global.tls.existingSecret"
    value = local.tls_secret_name
  }
  set {
    name  = "ingress.tls.secretName"
    value = local.tls_secret_name
  }
  set {
    name  = "nats.tls.secretName"
    value = local.tls_secret_name
  }
  set {
    name  = "historian-svc.tls.existingSecret"
    value = local.tls_secret_name
  }
  set {
    name  = "keycloak.tls.existingSecret"
    value = local.tls_secret_name
  }
  set {
    name  = "grafana.admin.existingSecret"
    value = local.grafana_secret_name
  }
  set {
    name  = "grafana.envValueFrom.CITUS_PASSWORD.secretKeyRef.name"
    value = local.grafana_secret_name
  }
  set {
    name  = "grafana.envValueFrom.OPENDSO_APPS_DB_PASSWORD.secretKeyRef.name"
    value = local.grafana_secret_name
  }

  # --- Non-secret accounts ---
  set {
    name  = "keycloak.config.adminUser"
    value = var.keycloak_admin_user
  }
  set {
    name  = "mongodb.auth.rootUsername"
    value = var.mongodb_root_username
  }
  set {
    name  = "mongodb.auth.username"
    value = var.mongodb_app_username
  }
  set {
    name  = "grafana.adminUser"
    value = var.grafana_admin_user
  }

  # --- Secrets (BYOL license + service credentials) ---
  set_sensitive {
    name  = "license.key"
    value = var.license_key
  }
  set_sensitive {
    name  = "installation.key"
    value = var.installation_key
  }
  set_sensitive {
    name  = "keycloak.config.adminPassword"
    value = var.keycloak_admin_password
  }
  set_sensitive {
    name  = "mongodb.auth.rootPassword"
    value = var.mongodb_root_password
  }
  set_sensitive {
    name  = "mongodb.auth.password"
    value = var.mongodb_app_password
  }
  set_sensitive {
    name  = "grafana.adminPassword"
    value = var.grafana_admin_password
  }
}
