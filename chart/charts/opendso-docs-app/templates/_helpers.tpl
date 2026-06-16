{{/*
Expand the name of the chart.
*/}}
{{- define "opendso-docs-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "opendso-docs-app.fullname" -}}
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
{{- define "opendso-docs-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "opendso-docs-app.labels" -}}
helm.sh/chart: {{ include "opendso-docs-app.chart" . }}
{{ include "opendso-docs-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "opendso-docs-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "opendso-docs-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "opendso-docs-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "opendso-docs-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create image reference - supports digest override
Usage: {{ include "opendso-docs-app.image" (dict "imageRoot" .Values.global.images.opendsoDocsApp "registry" .Values.global.imageRegistry) }}
*/}}
{{- define "opendso-docs-app.image" -}}
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
