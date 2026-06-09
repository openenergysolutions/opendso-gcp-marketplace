# ---------------------------------------------------------------------------
# Cluster connection
#
# These identify the customer's GKE cluster. The module wires the kubernetes
# and helm providers from these via data sources (see main.tf). On Cloud
# Marketplace these are populated automatically for the customer's selected
# cluster; for CLI deploys you supply them.
# ---------------------------------------------------------------------------
variable "project_id" {
  type        = string
  description = "GCP project ID that contains the target GKE cluster."
}

variable "cluster_name" {
  type        = string
  description = "Name of the target GKE cluster to deploy OpenDSO into."
}

variable "cluster_location" {
  type        = string
  description = "Region or zone of the target GKE cluster (e.g. us-central1 or us-central1-a)."
}

variable "create_cluster" {
  type        = bool
  description = "Create a temporary GKE cluster for Cloud Marketplace validation. Customer deployments normally leave this false and select an existing cluster."
  default     = false
}

variable "test_cluster_node_count" {
  type        = number
  description = "Initial node count for the optional Marketplace validation cluster."
  default     = 1
}

variable "test_cluster_machine_type" {
  type        = string
  description = "Node machine type for the optional Marketplace validation cluster."
  default     = "e2-standard-4"
}

variable "test_cluster_disk_size_gb" {
  type        = number
  description = "Node boot disk size in GB for the optional Marketplace validation cluster."
  default     = 100
}

variable "test_cluster_min_master_version" {
  type        = string
  description = "Optional minimum master version for the Marketplace validation cluster. Leave empty to use the GKE default."
  default     = ""
}

# ---------------------------------------------------------------------------
# Release identity
# ---------------------------------------------------------------------------
variable "goog_cm_deployment_name" {
  type        = string
  description = "Cloud Marketplace deployment name. Marketplace UI deployments populate this automatically; CLI deployments may leave it empty."
  default     = ""
}

variable "app_instance_name" {
  type        = string
  description = "Application instance name; used as the Helm release name for CLI deployments when goog_cm_deployment_name is not set."
  default     = "opendso"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace to deploy into. No default — must be provided."
}

variable "create_namespace" {
  type        = bool
  description = "Create the namespace if it does not already exist."
  default     = true
}

variable "install_helm_release" {
  type        = bool
  description = "Install the OpenDSO Helm release. Marketplace validation can disable this when create_cluster is true because Helm cannot plan against a cluster that does not exist yet."
  default     = true
}

# ---------------------------------------------------------------------------
# Chart source
# ---------------------------------------------------------------------------
variable "chart_version" {
  type        = string
  description = "Version (tag) of the opendso umbrella chart to deploy."
  default     = "0.1.0"
}

# Standard Marketplace Helm chart variables. Producer Portal rewrites these
# defaults to point at the published Google-owned chart copy during validation
# and customer deployments.
variable "helm_chart_repo" {
  type        = string
  description = "OCI repository containing the OpenDSO Helm chart."
  default     = "oci://us-docker.pkg.dev/openenergysolutionsinc-public/oesinc"
}

variable "helm_chart_name" {
  type        = string
  description = "OpenDSO Helm chart name."
  default     = "opendso"
}

variable "helm_chart_version" {
  type        = string
  description = "OpenDSO Helm chart version/tag."
  default     = "0.1.0"
}

# Marketplace OCI artifact declaration compatibility. Producer Portal validates
# artifacts listed in schema.yaml and may pass these values to the module.
variable "opendso_image_repo" {
  type        = string
  description = "Marketplace-provided OpenDSO OCI artifact repository."
  default     = "us-docker.pkg.dev/openenergysolutionsinc-public/oesinc/opendso"
}

variable "opendso_image_tag" {
  type        = string
  description = "Marketplace-provided OpenDSO OCI artifact tag."
  default     = "0.1.0"
}

# ---------------------------------------------------------------------------
# Core configuration (mirrors schema.yaml)
# ---------------------------------------------------------------------------
variable "image_registry" {
  type        = string
  description = <<-EOT
    Artifact Registry prefix for all container images, e.g.
    us-central1-docker.pkg.dev/my-project/oesinc. Leave empty to use the
    chart defaults. Cloud Marketplace repoints this to its published image copies.
  EOT
  default     = ""
}

variable "domain" {
  type        = string
  description = <<-EOT
    Base domain for all OpenDSO services (e.g. opendso.example.com).
    Subdomains keycloak.<domain>, api.<domain>, nats.<domain> are derived from it.
  EOT
}

variable "resource_profile" {
  type        = string
  description = "Resource requests/limits profile applied to all services."
  default     = "default"

  validation {
    condition     = contains(["minimal", "default", "production"], var.resource_profile)
    error_message = "resource_profile must be one of: minimal, default, production."
  }
}

variable "storage_class" {
  type        = string
  description = <<-EOT
    StorageClass for all persistent volumes. Defaults to "dynamic-rwo" (balanced
    PD on current GKE Autopilot). Older clusters may use "standard-rwo"; "premium-rwo"
    gives SSD. Run `kubectl get storageclass` to see what your cluster exposes.
  EOT
  default     = "dynamic-rwo"
}

# ---------------------------------------------------------------------------
# Licensing (BYOL)
# ---------------------------------------------------------------------------
variable "license_key" {
  type        = string
  description = "OpenDSO license key obtained from OES. Required to activate the application."
  sensitive   = true
}

variable "installation_key" {
  type        = string
  description = "OpenDSO installation key obtained from OES. Required to activate the application."
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Keycloak admin
# ---------------------------------------------------------------------------
variable "keycloak_admin_user" {
  type        = string
  description = "Keycloak admin console username."
  default     = "admin"
}

variable "keycloak_admin_password" {
  type        = string
  description = "Keycloak admin console password."
  sensitive   = true
}

# ---------------------------------------------------------------------------
# MongoDB credentials
# ---------------------------------------------------------------------------
variable "mongodb_root_username" {
  type        = string
  description = "MongoDB root username."
  default     = "root"
}

variable "mongodb_root_password" {
  type        = string
  description = "MongoDB root password."
  sensitive   = true
}

variable "mongodb_app_username" {
  type        = string
  description = "MongoDB application username."
  default     = "opendso"
}

variable "mongodb_app_password" {
  type        = string
  description = "MongoDB application password."
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Grafana admin
# ---------------------------------------------------------------------------
variable "grafana_admin_user" {
  type        = string
  description = "Grafana admin username."
  default     = "admin"
}

variable "grafana_admin_password" {
  type        = string
  description = "Grafana admin password."
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Escape hatch
# ---------------------------------------------------------------------------
variable "additional_values" {
  type        = string
  description = <<-EOT
    Optional raw YAML merged into the Helm release after all other values
    (highest precedence). Use for chart settings not surfaced as variables.
  EOT
  default     = ""
}
