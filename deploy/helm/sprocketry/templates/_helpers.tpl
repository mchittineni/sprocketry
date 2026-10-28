{{- define "sprocketry.labels" -}}
app.kubernetes.io/part-of: sprocketry
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{- /* Services this release runs: those marked requiresAuth only when auth.enabled. Comma-separated. */ -}}
{{- define "sprocketry.apps" -}}
{{- $apps := list -}}
{{- range $name, $svc := .Values.services -}}
{{- if or (not $svc.requiresAuth) $.Values.auth.enabled -}}{{- $apps = append $apps $name -}}{{- end -}}
{{- end -}}
{{- join "," (sortAlpha $apps) -}}
{{- end -}}

{{- /* Keycloak's path with a trailing slash: "/" or "/auth/". */ -}}
{{- define "sprocketry.keycloakPath" -}}
{{- trimSuffix "/" .Values.auth.keycloakPath }}/
{{- end -}}

{{- /* The sprocketry realm at Keycloak's in-cluster address, for server-to-server calls. */ -}}
{{- define "sprocketry.realmInternalUrl" -}}
http://keycloak.{{ .Release.Namespace }}.svc.cluster.local:8080{{ include "sprocketry.keycloakPath" . }}realms/sprocketry
{{- end -}}
