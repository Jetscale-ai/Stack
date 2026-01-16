{{/*
Expand the name of the chart.
*/}}
{{- define "jetscale.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "jetscale.fullname" -}}
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
{{- define "jetscale.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "jetscale.labels" -}}
helm.sh/chart: {{ include "jetscale.chart" . }}
{{ include "jetscale.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "jetscale.selectorLabels" -}}
app.kubernetes.io/name: {{ include "jetscale.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "jetscale.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "jetscale.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
CORS allowed origins.
- Always allow localhost:3000 (local dev)
- For each ingress host, allow https://<host>
*/}}
{{- define "jetscale.corsAllowedOrigins" -}}
{{- $hosts := keys (default dict .Values.ingress.hosts) | sortAlpha -}}
{{- $origins := list -}}
{{- range $hosts -}}
{{- $origins = append $origins (printf "https://%s" .) -}}
{{- end -}}
{{- $origins = append $origins "http://localhost:3000" -}}
{{- join "," $origins -}}
{{- end -}}

{{/*
Frontend URL used for email links, etc.
- Prefer the first ingress host if present.
- Fall back to localhost for default chart renders.
*/}}
{{- define "jetscale.frontendUrl" -}}
{{- $hosts := keys (default dict .Values.ingress.hosts) | sortAlpha -}}
{{- if gt (len $hosts) 0 -}}
{{- printf "https://%s/" (index $hosts 0) -}}
{{- else -}}
http://localhost:3000/
{{- end -}}
{{- end -}}
