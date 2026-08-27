{{/*
Common object labels. NEVER routed into a selector or a pod template's labels: a Deployment's
selector is immutable after creation, so a helper whose output changes on a version bump would make
every future sync fail with a field-immutable error, fixable only by deleting the object.
*/}}
{{- define "logging.labels" -}}
app.kubernetes.io/name: logging
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
