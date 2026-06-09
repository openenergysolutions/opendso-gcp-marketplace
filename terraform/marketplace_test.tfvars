# Used by Cloud Marketplace validation as terraform plan's --var-file.
#
# Do not include project_id, helm_chart_repo, helm_chart_name,
# helm_chart_version, or variables declared in schema.yaml. Marketplace
# provides or rewrites those during validation.

create_cluster       = true
cluster_name         = "marketplace-test"
cluster_location     = "us-central1"
namespace            = "opendso-marketplace-test"
install_helm_release = false
domain               = "opendso.example.com"
resource_profile     = "minimal"
storage_class        = "dynamic-rwo"

test_cluster_node_count   = 1
test_cluster_machine_type = "e2-standard-4"
test_cluster_disk_size_gb = 100

license_key      = "marketplace-validation-license-key"
installation_key = "marketplace-validation-installation-key"

keycloak_admin_password = "marketplace-validation-keycloak-password"
mongodb_root_password   = "marketplace-validation-mongodb-root-password"
mongodb_app_password    = "marketplace-validation-mongodb-app-password"
grafana_admin_password  = "marketplace-validation-grafana-password"
