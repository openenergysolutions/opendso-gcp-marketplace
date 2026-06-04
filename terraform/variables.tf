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

# ---------------------------------------------------------------------------
# Release identity
# ---------------------------------------------------------------------------
variable "app_instance_name" {
  type        = string
  description = "Application instance name; used as the Helm release name."
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

# ---------------------------------------------------------------------------
# Chart source
# ---------------------------------------------------------------------------
variable "chart_version" {
  type        = string
  description = "Version (tag) of the opendso umbrella chart to deploy."
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
