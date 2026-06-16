{{/*
Expand the name of the chart.
*/}}
{{- define "nats-auth-svc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "nats-auth-svc.fullname" -}}
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
{{- define "nats-auth-svc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "nats-auth-svc.labels" -}}
helm.sh/chart: {{ include "nats-auth-svc.chart" . }}
{{ include "nats-auth-svc.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "nats-auth-svc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "nats-auth-svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create image reference - supports digest override
Usage: {{ include "nats-auth-svc.image" (dict "imageRoot" .Values.global.images.natsAuthSvc "registry" .Values.global.imageRegistry) }}
*/}}
{{- define "nats-auth-svc.image" -}}
{{- $registry := .registry | default "" -}}
{{- $repository := .imageRoot.repository -}}
{{- $tag := .imageRoot.tag -}}
{{- $digest := .imageRoot.digest -}}
{{- if and $registry (not (hasPrefix $registry $repository)) -}}
{{- $repository = printf "%s/%s" $registry $repository -}}
{{- end -}}
{{- if $digest -}}
{{- printf "%s@%s" $repository $digest -}}
{{- else -}}
{{- printf "%s:%s" $repository $tag -}}
{{- end -}}
{{- end }}

{{/*
Compute the Keycloak realm URL — used as the OIDC issuer for discovery.
*/}}
{{- define "nats-auth-svc.realmUrl" -}}
{{- printf "%s/realms/%s" (include "opendso.keycloakInternalUrl" .) .Values.global.keycloak.realm -}}
{{- end }}

{{/*
Compute the JWKS URL — use override if set, otherwise derive from realm URL.
*/}}
{{- define "nats-auth-svc.jwksUrl" -}}
{{- if .Values.jwks.url -}}
{{- .Values.jwks.url -}}
{{- else -}}
{{- printf "%s/protocol/openid-connect/certs" (include "nats-auth-svc.realmUrl" .) -}}
{{- end -}}
{{- end }}
