{{/*
Expand the name of the chart.
*/}}
{{- define "opendso.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Resolve OpenDSO Apps DB connection settings with BYO/secret support.
Returns YAML with host, port, name, user, password.
*/}}
{{- define "opendso.appsDb.settings" -}}
{{- $vals := .Values | toYaml | fromYaml -}}
{{- $external := dig "opendso-apps-db" "externalDatabase" "enabled" false $vals -}}
{{- $nameOverride := dig "opendso-apps-db" "fullnameOverride" "" $vals -}}
{{- $port := dig "opendso-apps-db" "service" "port" 5432 $vals -}}
{{- $user := dig "opendso-apps-db" "auth" "username" "essuser" $vals -}}
{{- $pass := dig "opendso-apps-db" "auth" "password" "" $vals -}}
{{- $db := dig "opendso-apps-db" "auth" "database" "ess_tester" $vals -}}
{{- $host := "" -}}
{{- if $nameOverride -}}
{{- $host = printf "%s.%s.svc.cluster.local" $nameOverride .Release.Namespace -}}
{{- else -}}
{{- $host = printf "%s-opendso-apps-db.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}
{{- if $external -}}
{{- $user = dig "opendso-apps-db" "externalDatabase" "username" "" $vals -}}
{{- $pass = dig "opendso-apps-db" "externalDatabase" "password" "" $vals -}}
{{- $db = dig "opendso-apps-db" "externalDatabase" "database" "" $vals -}}
{{- $host = dig "opendso-apps-db" "externalDatabase" "host" "" $vals -}}
{{- $port = dig "opendso-apps-db" "externalDatabase" "port" 5432 $vals -}}
{{- end -}}
{{- $secretName := "" -}}
{{- if $external -}}
{{- $secretName = dig "opendso-apps-db" "externalDatabase" "existingSecret" "" $vals -}}
{{- else -}}
{{- $secretName = dig "opendso-apps-db" "auth" "existingSecret" "" $vals -}}
{{- end -}}
{{- if $secretName -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- if $secret -}}
{{- $userKey := ternary (dig "opendso-apps-db" "externalDatabase" "usernameKey" "username" $vals) (dig "opendso-apps-db" "auth" "usernameKey" "username" $vals) $external -}}
{{- $passKey := ternary (dig "opendso-apps-db" "externalDatabase" "passwordKey" "password" $vals) (dig "opendso-apps-db" "auth" "passwordKey" "password" $vals) $external -}}
{{- $dbKey := ternary (dig "opendso-apps-db" "externalDatabase" "databaseKey" "database" $vals) (dig "opendso-apps-db" "auth" "databaseKey" "database" $vals) $external -}}
{{- $rawUser := index $secret.data $userKey -}}
{{- if $rawUser }}{{- $user = ($rawUser | b64dec) }}{{- end -}}
{{- $rawPass := index $secret.data $passKey -}}
{{- if $rawPass }}{{- $pass = ($rawPass | b64dec) }}{{- end -}}
{{- $rawDb := index $secret.data $dbKey -}}
{{- if $rawDb }}{{- $db = ($rawDb | b64dec) }}{{- end -}}
{{- end -}}
{{- end -}}
host: {{ $host | quote }}
port: {{ $port }}
name: {{ $db | quote }}
user: {{ $user | quote }}
password: {{ $pass | quote }}
{{- end }}
{{/*
Resolve Citus DB connection settings with BYO/secret support.
Returns YAML with host, port, name, user, password.
*/}}
{{- define "opendso.citusDb.settings" -}}
{{- $vals := .Values | toYaml | fromYaml -}}
{{- $external := dig "citus-db" "externalDatabase" "enabled" false $vals -}}
{{- $nameOverride := dig "citus-db" "fullnameOverride" "" $vals -}}
{{- $port := dig "citus-db" "service" "port" 5432 $vals -}}
{{- $user := dig "citus-db" "auth" "username" "citususer" $vals -}}
{{- $pass := dig "citus-db" "auth" "password" "" $vals -}}
{{- $db := dig "citus-db" "auth" "database" "ofmb_db" $vals -}}
{{- $host := "" -}}
{{- if $nameOverride -}}
{{- $host = printf "%s.%s.svc.cluster.local" $nameOverride .Release.Namespace -}}
{{- else -}}
{{- $host = printf "%s-citus-db.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}
{{- if $external -}}
{{- $user = dig "citus-db" "externalDatabase" "username" "" $vals -}}
{{- $pass = dig "citus-db" "externalDatabase" "password" "" $vals -}}
{{- $db = dig "citus-db" "externalDatabase" "database" "" $vals -}}
{{- $host = dig "citus-db" "externalDatabase" "host" "" $vals -}}
{{- $port = dig "citus-db" "externalDatabase" "port" 5432 $vals -}}
{{- end -}}
{{- $secretName := "" -}}
{{- if $external -}}
{{- $secretName = dig "citus-db" "externalDatabase" "existingSecret" "" $vals -}}
{{- else -}}
{{- $secretName = dig "citus-db" "auth" "existingSecret" "" $vals -}}
{{- end -}}
{{- if $secretName -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- if $secret -}}
{{- $userKey := ternary (dig "citus-db" "externalDatabase" "usernameKey" "username" $vals) (dig "citus-db" "auth" "usernameKey" "username" $vals) $external -}}
{{- $passKey := ternary (dig "citus-db" "externalDatabase" "passwordKey" "password" $vals) (dig "citus-db" "auth" "passwordKey" "password" $vals) $external -}}
{{- $dbKey := ternary (dig "citus-db" "externalDatabase" "databaseKey" "database" $vals) (dig "citus-db" "auth" "databaseKey" "database" $vals) $external -}}
{{- $rawUser := index $secret.data $userKey -}}
{{- if $rawUser }}{{- $user = ($rawUser | b64dec) }}{{- end -}}
{{- $rawPass := index $secret.data $passKey -}}
{{- if $rawPass }}{{- $pass = ($rawPass | b64dec) }}{{- end -}}
{{- $rawDb := index $secret.data $dbKey -}}
{{- if $rawDb }}{{- $db = ($rawDb | b64dec) }}{{- end -}}
{{- end -}}
{{- end -}}
host: {{ $host | quote }}
port: {{ $port }}
name: {{ $db | quote }}
user: {{ $user | quote }}
password: {{ $pass | quote }}
{{- end }}
{{/*
Resolve MongoDB connection settings with BYO/secret support.
Returns YAML with host, port, name, user, password.
*/}}
{{- define "opendso.mongodb.settings" -}}
{{- $vals := .Values | toYaml | fromYaml -}}
{{- $external := dig "mongodb" "externalDatabase" "enabled" false $vals -}}
{{- $nameOverride := dig "mongodb" "fullnameOverride" "" $vals -}}
{{- $port := dig "mongodb" "service" "port" 27017 $vals -}}
{{- $user := dig "mongodb" "auth" "rootUsername" "root" $vals -}}
{{- $pass := dig "mongodb" "auth" "rootPassword" "" $vals -}}
{{- $db := dig "mongodb" "auth" "database" "settings_api" $vals -}}
{{- $host := "" -}}
{{- if $nameOverride -}}
{{- $host = printf "%s.%s.svc.cluster.local" $nameOverride .Release.Namespace -}}
{{- else -}}
{{- $host = printf "%s-mongodb.%s.svc.cluster.local" .Release.Name .Release.Namespace -}}
{{- end -}}
{{- if $external -}}
{{- $user = dig "mongodb" "externalDatabase" "username" "" $vals -}}
{{- $pass = dig "mongodb" "externalDatabase" "password" "" $vals -}}
{{- $db = dig "mongodb" "externalDatabase" "database" "" $vals -}}
{{- $host = dig "mongodb" "externalDatabase" "host" "" $vals -}}
{{- $port = dig "mongodb" "externalDatabase" "port" 27017 $vals -}}
{{- end -}}
{{- $secretName := "" -}}
{{- if $external -}}
{{- $secretName = dig "mongodb" "externalDatabase" "existingSecret" "" $vals -}}
{{- else -}}
{{- $secretName = dig "mongodb" "auth" "existingSecret" "" $vals -}}
{{- end -}}
{{- if $secretName -}}
{{- $secret := lookup "v1" "Secret" .Release.Namespace $secretName -}}
{{- if $secret -}}
{{- $userKey := ternary (dig "mongodb" "externalDatabase" "usernameKey" "username" $vals) (dig "mongodb" "auth" "usernameKey" "username" $vals) $external -}}
{{- $passKey := ternary (dig "mongodb" "externalDatabase" "passwordKey" "password" $vals) (dig "mongodb" "auth" "passwordKey" "password" $vals) $external -}}
{{- $dbKey := ternary (dig "mongodb" "externalDatabase" "databaseKey" "database" $vals) (dig "mongodb" "auth" "databaseKey" "database" $vals) $external -}}
{{- $rawUser := index $secret.data $userKey -}}
{{- if $rawUser }}{{- $user = ($rawUser | b64dec) }}{{- end -}}
{{- $rawPass := index $secret.data $passKey -}}
{{- if $rawPass }}{{- $pass = ($rawPass | b64dec) }}{{- end -}}
{{- $rawDb := index $secret.data $dbKey -}}
{{- if $rawDb }}{{- $db = ($rawDb | b64dec) }}{{- end -}}
{{- end -}}
{{- end -}}
host: {{ $host | quote }}
port: {{ $port }}
name: {{ $db | quote }}
user: {{ $user | quote }}
password: {{ $pass | quote }}
{{- end }}
{{/*
Create a default fully qualified app name.
*/}}
{{- define "opendso.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "opendso.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "opendso.labels" -}}
helm.sh/chart: {{ include "opendso.chart" . }}
{{ include "opendso.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "opendso.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opendso.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Compute the base URL for accessing services
Returns format: https://domain:port or https://domain (for standard ports)
*/}}
{{- define "opendso.baseUrl" -}}
{{- $domain := .Values.ingress.domain -}}
{{- $serviceType := .Values.ingress.serviceType -}}
{{- $httpsPort := .Values.ingress.ports.https -}}
{{- if eq $serviceType "LoadBalancer" -}}
https://{{ $domain }}
{{- else if eq $serviceType "NodePort" -}}
{{- if and $httpsPort (ne (toString $httpsPort) "443") -}}
https://{{ $domain }}:{{ $httpsPort }}
{{- else -}}
https://{{ $domain }}
{{- end -}}
{{- else -}}
https://{{ $domain }}
{{- end -}}
{{- end }}

{{/*
Compute the Keycloak URL
Uses global.keycloak.url if set, otherwise computes from ingress settings
*/}}
{{- define "opendso.keycloakUrl" -}}
{{- if .Values.global.keycloak.url -}}
{{- .Values.global.keycloak.url }}
{{- else -}}
{{- include "opendso.baseUrl" . }}
{{- end -}}
{{- end }}

{{/*
Compute CORS allow-origin list
Creates a comma-separated list of all service URLs
*/}}
{{- define "opendso.corsOrigins" -}}
{{- $domain := .Values.global.domain | default .Values.ingress.domain -}}
{{- $serviceType := .Values.ingress.serviceType -}}
{{- $httpsPort := .Values.ingress.ports.https -}}
{{- $origins := list -}}
{{- $formatOrigin := "" -}}
{{- if and $httpsPort (ne (toString $httpsPort) "443") (ne $serviceType "LoadBalancer") -}}
{{- $formatOrigin = "https://%s.%s:%s" -}}
{{- $origins = append $origins (printf "https://%s:%s" $domain (toString $httpsPort)) -}}
{{- else -}}
{{- $formatOrigin = "https://%s.%s" -}}
{{- $origins = append $origins (printf "https://%s" $domain) -}}
{{- end -}}
{{- if (index .Values.global "genesis-node-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "gms" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if .Values.global.keycloak.enabled -}}
{{- $origins = append $origins (printf $formatOrigin "keycloak" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "gis-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "gis" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "one-line-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "oneline" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "event-viewer-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "eventviewer" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "inventory-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "inventory" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "openfmb-event-creator-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "openfmbeventcreator" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "data-viewer-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "dataviewer" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "inspector-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "openfmb" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "der-dispatch-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "derdispatch" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "ess-manager-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "device" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "ess-tester-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "esstesting" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "historian-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "historian" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "schedule-dispatch-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "scheduledispatch" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "opendso-docs-app").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "docs" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "grafana").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "grafana" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- if (index .Values.global "gms-api").enabled -}}
{{- $origins = append $origins (printf $formatOrigin "api" $domain (toString $httpsPort)) -}}
{{- end -}}
{{- join ", " $origins -}}
{{- end }}

{{/*
Get the HTTPS port for external access
Returns the NodePort or LoadBalancer port depending on serviceType
*/}}
{{- define "opendso.httpsPort" -}}
{{- if eq .Values.ingress.serviceType "LoadBalancer" -}}
443
{{- else -}}
{{- .Values.ingress.ports.https | default 30308 }}
{{- end -}}
{{- end }}

{{/*
Shared Nginx configuration for frontend SPA applications.
This template provides a standard nginx config for Single Page Applications with:
- Health check endpoint for Kubernetes probes
- SPA routing support (try_files with index.html fallback)
- Optional TLS configuration

Usage in subchart configmap.yaml:
data:
  default.conf: |
{{ include "opendso.frontend.nginx" . | indent 4 }}

*/}}
{{- define "opendso.frontend.nginx" -}}
server {
    listen {{ .Values.containerPort }};
    server_name localhost;

    root /usr/share/nginx/html;
    index index.html;

    location /health {
        access_log off;
        return 200 "healthy\n";
    }

    location / {
        try_files $uri $uri/ /index.html;
    }

    {{- if .Values.tls.enabled }}
    listen {{ .Values.containerPort }} ssl;
    ssl_certificate /etc/nginx/certs/server-cert.pem;
    ssl_certificate_key /etc/nginx/certs/server-key.pem;
    {{- end }}
}
{{- end }}

{{/*
Get resource requests and limits from global resource profile.
This helper provides DRY resource management across all charts.

Parameters:
  - . (root context)
  - category: Resource category - "databases", "services", or "frontends"
  - explicit: Explicit resources from chart values (optional fallback)

Usage in chart templates:
  resources:
    {{- include "opendso.resources" (dict "root" . "category" "databases" "explicit" .Values.resources) | nindent 12 }}

Returns YAML:
  requests:
    cpu: 500m
    memory: 1Gi
  limits:
    cpu: 2000m
    memory: 4Gi
*/}}
{{- define "opendso.resources" -}}
{{- $root := .root -}}
{{- $category := .category -}}
{{- $explicit := .explicit -}}
{{- $profile := index $root.Values.global "resourceProfile" | default "default" -}}
{{- $profiles := index $root.Values.global "resourceProfiles" | default dict -}}
{{- $profileData := index $profiles $profile | default dict -}}
{{- $resources := index $profileData $category | default dict -}}
{{- if and $explicit (or $explicit.requests $explicit.limits) -}}
{{- toYaml $explicit -}}
{{- else if $resources -}}
{{- toYaml $resources -}}
{{- else -}}
{{- /* Fallback to empty resources if profile not found */ -}}
{}
{{- end -}}
{{- end }}

{{/*
Build a full image reference, optionally prefixed with a registry.
Usage: include "opendso.image" (dict "imageRoot" .Values.global.images.foo "registry" .Values.global.imageRegistry)
*/}}
{{- define "opendso.image" -}}
{{- $registry := .registry | default "" -}}
{{- $repository := .imageRoot.repository -}}
{{- $tag := .imageRoot.tag | default "latest" -}}
{{- $digest := .imageRoot.digest | default "" -}}
{{- if $registry -}}
{{- $repository = printf "%s/%s" $registry $repository -}}
{{- end -}}
{{- if $digest -}}
{{- printf "%s@%s" $repository $digest -}}
{{- else -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end }}
