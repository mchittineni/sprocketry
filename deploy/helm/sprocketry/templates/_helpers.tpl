{{- define "sprocketry.labels" -}}
app.kubernetes.io/part-of: sprocketry
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
