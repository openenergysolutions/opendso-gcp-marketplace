output "release_name" {
  description = "Helm release name for the OpenDSO deployment."
  value       = helm_release.opendso.name
}

output "namespace" {
  description = "Namespace the release was deployed into."
  value       = helm_release.opendso.namespace
}

output "chart_version" {
  description = "Version of the opendso chart that was deployed."
  value       = helm_release.opendso.version
}

output "release_status" {
  description = "Status of the Helm release after apply."
  value       = helm_release.opendso.status
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
