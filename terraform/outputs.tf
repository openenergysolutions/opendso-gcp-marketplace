output "release_name" {
  description = "Helm release name for the OpenDSO deployment."
  value       = var.install_helm_release ? helm_release.opendso[0].name : local.release_name
}

output "namespace" {
  description = "Namespace the release was deployed into."
  value       = var.install_helm_release ? helm_release.opendso[0].namespace : var.namespace
}

output "chart_version" {
  description = "Version of the opendso chart that was deployed."
  value       = var.install_helm_release ? helm_release.opendso[0].version : local.chart_version
}

output "release_status" {
  description = "Status of the Helm release after apply."
  value       = var.install_helm_release ? helm_release.opendso[0].status : "skipped"
}

output "service_endpoints" {
  description = "Externally-resolvable OpenDSO service URLs (require DNS for *.<domain> to point at the ingress load balancer)."
  value = {
    portal   = "https://${var.domain}"
    api      = "https://api.${var.domain}"
    keycloak = "https://keycloak.${var.domain}"
    nats     = "https://nats.${var.domain}"
    grafana  = "https://grafana.${var.domain}"
  }
}
