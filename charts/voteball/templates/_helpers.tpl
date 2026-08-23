{{/*
Chart helpers.

TWO RULES, both load-bearing:

1. NOTHING here may be used in a `selector` -- not `spec.selector.matchLabels` on a Deployment, not
   `spec.selector` on a Service, not `matchLabels` in a NetworkPolicy or PDB. A Deployment's selector
   is IMMUTABLE after creation: change it and ArgoCD's sync fails with a field-immutable error
   instead of rolling, and the fix is deleting the Deployment in production. The selectors in this
   chart are the plain literal `app: <component>` and must stay that way.

2. For the same reason `voteball.labels` is applied to OBJECT metadata only, never to a pod
   template's `metadata.labels`. Adding a label to a pod template changes the pod hash and rolls
   every replica -- harmless here, but it would happen on every chart version bump, which is not.

`voteball.image` is a pure string helper: it renders byte-identical to the literals it replaced.
*/}}

{{/*
Common object labels. `helm.sh/chart` and the app.kubernetes.io/* set are the Helm conventions;
they make `kubectl get all -l app.kubernetes.io/instance=voteball` select the release.
Usage:  labels:
          app: backend
          {{- include "voteball.labels" . | nindent 4 }}
*/}}
{{- define "voteball.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Image reference for one of this project's four images. The repository name is `voteball-<arg>`,
which is what scripts/build-push-ecr.sh pushes and what sync-values-from-tf.sh pins the tag of.
Note the frontend image is `voteball-nginx`, not `voteball-frontend`.
Usage:  image: {{ include "voteball.image" (dict "root" $ "name" "backend") }}

DIGEST WHEN AVAILABLE, TAG OTHERWISE (2026-08-23, Task 4 review). `image.digests.<name>` is written
by application-cd's Promote stage (and by deploy.sh step 9 on a fresh cluster), resolved from ECR via
scripts/ci/resolve-digests.sh. When present it becomes the execution identity: repo@sha256:... is
what the kubelet pulls, so what runs is decided by content, not by a label.

THE FALLBACK IS NOT DECORATION -- do not "simplify" it away. A fresh fork has no digests yet, and a
reader running `helm template` must still get a valid manifest; charts/voteball/values.yaml is
committed with real values precisely so ArgoCD and a human see the same thing. An empty digests map
renders tags exactly as before.

`image.tag` also stays, and stays in the commit subject, as the READABLE release label. Rendering
only the digest would make `kubectl get pods -o jsonpath='{..image}'` a wall of hex during an
incident, which is the moment it matters most -- so the tag is kept as the human handle and the
digest carries the identity.
*/}}
{{- define "voteball.image" -}}
{{- $digest := "" -}}
{{- if .root.Values.image.digests -}}
{{-   $digest = index .root.Values.image.digests .name | default "" -}}
{{- end -}}
{{- if $digest -}}
{{ .root.Values.image.registry }}/voteball-{{ .name }}@{{ $digest }}
{{- else -}}
{{ .root.Values.image.registry }}/voteball-{{ .name }}:{{ .root.Values.image.tag }}
{{- end -}}
{{- end -}}
