{{/*
Expand the name of the chart.
*/}}
{{- define "orb-agent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "orb-agent.fullname" -}}
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
{{- define "orb-agent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "orb-agent.labels" -}}
helm.sh/chart: {{ include "orb-agent.chart" . }}
{{ include "orb-agent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "orb-agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "orb-agent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "orb-agent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "orb-agent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the name of the secret to use
*/}}
{{- define "orb-agent.secretName" -}}
{{- if .Values.credentials.create }}
{{- default (printf "%s-credentials" (include "orb-agent.fullname" .)) .Values.credentials.secretName }}
{{- else }}
{{- .Values.credentials.secretName }}
{{- end }}
{{- end }}

{{/*
Extract hostname from Diode target URL
*/}}
{{- define "orb-agent.diodeHost" -}}
{{- if .Values.networkPolicy.egress.diodeEndpoint.host }}
{{- .Values.networkPolicy.egress.diodeEndpoint.host }}
{{- else }}
{{- $url := .Values.diode.target | replace "grpc://" "" | replace "grpcs://" "" }}
{{- $parts := split "/" $url }}
{{- $hostPort := index $parts 0 }}
{{- $host := split ":" $hostPort | first }}
{{- $host }}
{{- end }}
{{- end }}

{{/*
Extract port from Diode target URL
*/}}
{{- define "orb-agent.diodePort" -}}
{{- if .Values.networkPolicy.egress.diodeEndpoint.port }}
{{- .Values.networkPolicy.egress.diodeEndpoint.port }}
{{- else }}
{{- $url := .Values.diode.target | replace "grpc://" "" | replace "grpcs://" "" }}
{{- $parts := split "/" $url }}
{{- $hostPort := index $parts 0 }}
{{- if contains ":" $hostPort }}
{{- $port := split ":" $hostPort | last }}
{{- $port }}
{{- else }}
{{- "80" }}
{{- end }}
{{- end }}
{{- end }}
