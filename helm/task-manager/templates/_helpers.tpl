{{/*Selector labels — minimal, immutable, used in matchLabels and pod template labels only*/}}

{{- define "task-manager.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*Common labels*/}}

{{- define "task-manager.labels" -}}
{{- include "task-manager.selectorLabels" . }}
helm.sh/chart: "{{ .Chart.Name }}-{{ .Chart.Version }}"
app.kubernetes.io/managed-by: Helm
{{- end }}
