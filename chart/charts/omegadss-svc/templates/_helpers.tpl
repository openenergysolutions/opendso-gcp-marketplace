{{/*
Expand the name of the chart.
*/}}
{{- define "omegadss-svc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "omegadss-svc.fullname" -}}
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
{{- define "omegadss-svc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "omegadss-svc.labels" -}}
helm.sh/chart: {{ include "omegadss-svc.chart" . }}
{{ include "omegadss-svc.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "omegadss-svc.selectorLabels" -}}
app.kubernetes.io/name: {{ include "omegadss-svc.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "omegadss-svc.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "omegadss-svc.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create image reference - supports digest override
Usage: {{ include "omegadss-svc.image" (dict "imageRoot" .Values.global.images.omegadssSvc "registry" .Values.global.imageRegistry) }}
*/}}
{{- define "omegadss-svc.image" -}}
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
