{{/*
Expand the name of the chart.
*/}}
{{- define "cvr-genetic-algorithm-svc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "cvr-genetic-algorithm-svc.fullname" -}}
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
{{- define "cvr-genetic-algorithm-svc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cvr-genetic-algorithm-svc.labels" -}}
helm.sh/chart: {{ include "cvr-genetic-algorithm-svc.chart" . }}
{{ include "cvr-genetic-algorithm-svc.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "cvr-genetic-algorithm-svc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cvr-genetic-algorithm-svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "cvr-genetic-algorithm-svc.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "cvr-genetic-algorithm-svc.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create image reference - supports digest override
Usage: {{ include "cvr-genetic-algorithm-svc.image" (dict "imageRoot" .Values.global.images.coordinationRegion "registry" .Values.global.imageRegistry) }}
*/}}
{{- define "cvr-genetic-algorithm-svc.image" -}}
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
