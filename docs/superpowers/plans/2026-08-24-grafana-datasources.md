# Grafana Data Sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PostgreSQL, CloudWatch and GitHub data sources to the Grafana that `kube-prometheus-stack` already runs, each backing at least one real dashboard panel.

**Architecture:** Data sources ship as sidecar-discovered ConfigMaps in `charts/observability` on a `git push`, exactly as the three dashboards already do. Terraform owns only the pod-spec-level pieces it must: the one plugin, the secret-to-environment projection, the Grafana ServiceAccount's IRSA annotation and the IAM role behind it. Credentials come from one new Secrets Manager container projected by two ExternalSecrets; the `grafana_ro` Postgres role is created passwordless in `schema.sql` and given its password by `migrate.py`.

**Tech Stack:** Terraform (`aws ~> 5.0`), Helm, Grafana 13.1.1, External Secrets Operator, PostgreSQL 16 (RDS), bash test scripts.

**Spec:** `docs/design/2026-08-24-grafana-datasources-design.md`

## Global Constraints

- **No hardcoded AWS account, region, domain, ARN or registry anywhere.** Identity lives in `terraform/voteball.tfvars` and `terraform output`, read through `scripts/lib/config.sh`. A hardcoded value is a bug.
- **No `Claude-Session:` trailer and no `claude.ai/code/session_...` URL in any commit message.**
- **Never force-push.** Commit and push as work is made — but see the push hold in Task 0.
- **`terraform apply` is billed (~$8.50/day cluster).** No task in this plan runs it without an explicit human go-ahead. Tasks 1 and 2 stop at `terraform validate` + `terraform fmt -recursive` + `terraform plan`.
- **`charts/voteball/values.yaml`'s ten sync-managed fields are never hand-edited.** This plan touches none of them.
- **Grafana data source uids are stable identifiers.** Dashboards reference them by uid. The four in play: `prometheus` and `alertmanager` (chart-provisioned, do not redeclare), plus new `postgres`, `cloudwatch`, `github`.
- **`scripts/tests/run-ci-suite.sh`'s `PYTHON_GROUP` / `GIT_GROUP` / `SKIP` lists are exhaustive** and the runner fails if a file in `scripts/tests/` appears in none of them. Any new test must be added to exactly one.
- **`scripts/tests/test-observability-docs.sh` gates dashboard counts, uids and per-dashboard panel counts against `docs/observability.md`.** Any dashboard change requires the doc row in the same commit.
- **`services/backend/schema.sql` runs on every backend boot**, not only in the migrate Job — via `migrate.py`, `app.py`'s `__main__` guard and `gunicorn.conf.py`'s `on_starting` hook. Nothing in it may depend on state only the migrate Job creates.
- **Empty list literals (`to: []`) are banned** by `scripts/ci/validate-repo.sh` — the API server normalises them away and the manifest then conflicts with ArgoCD forever.

---

### Task 0: Confirm the push hold has expired

**Files:** none.

A peer Claude session is running Jenkins/CD drills in this same working tree and this session agreed to hold pushes to `master` until roughly 19:14 IDT on 2026-08-24. Commits are fine throughout; only the push is held.

- [ ] **Step 1: Check whether the drill window has closed**

Either the peer session has messaged that both drills are done, or the wall clock is past the hold. If neither, commit locally and push at the end.

- [ ] **Step 2: Confirm the tree is clean of other people's work before staging anything**

```bash
git status --porcelain
```

Expected: the peer's two untracked files may be present —
`docs/eks/evidence/2026-08-24-drill-1-controlled-5xx.txt` and `scripts/drills/drill-5-jenkins-queue-stuck.sh`.
**Never `git add -A` or `git add .` in this plan.** Stage explicit paths only, in every commit below.

---

### Task 1: Terraform — secret container, ESO allowlist entry, Grafana IRSA role

**Files:**
- Modify: `terraform/secrets.tf` (append)
- Modify: `terraform/addon-eso.tf:13-16` (the `external_secrets_secrets_manager_arns` list)
- Modify: `terraform/irsa.tf` (append)

**Interfaces:**
- Produces: `aws_secretsmanager_secret.grafana` (name `${var.cluster_name}/grafana`), `aws_iam_role.grafana` (name `${var.cluster_name}-grafana-irsa`). Task 2 consumes `aws_iam_role.grafana.arn`. Task 3 consumes the secret's name via `.Values.externalSecret.grafanaSecretName`.

- [ ] **Step 1: Add the secret container to `terraform/secrets.tf`**

Append. This mirrors the two existing containers exactly — placeholder value, `ignore_changes` forever, `recovery_window_in_days = 0` because this stack is destroyed and rebuilt routinely and a same-named secret pending deletion blocks the next apply.

```hcl
# ---- Grafana data source credentials ----
# Two values, one container: the grafana_ro Postgres password and a fine-grained GitHub PAT.
# Projected by TWO ExternalSecrets (charts/observability and charts/voteball) rather than one, so
# the GitHub token never enters the application namespace -- the migrate Job needs the DB password
# and has no business holding a repo credential.
#
# recovery_window_in_days = 0 for the same reason as the two above: this stack is destroyed and
# rebuilt routinely, and a same-named secret pending deletion blocks the next apply outright.
resource "aws_secretsmanager_secret" "grafana" {
  name                    = "${var.cluster_name}/grafana"
  description             = "Grafana data source credentials (grafana_ro DB password + GitHub PAT). Seeded by scripts/seed-grafana-secret.sh; synced to K8s by ESO."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "grafana_placeholder" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = jsonencode({ placeholder = "seed real values via scripts/seed-grafana-secret.sh" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
```

- [ ] **Step 2: Add the ARN to ESO's allowlist in `terraform/addon-eso.tf`**

This is silent-failure #1 from the design doc. The list is currently:

```hcl
  external_secrets_secrets_manager_arns = [
    "${aws_secretsmanager_secret.app.arn}*",
    "${aws_secretsmanager_secret.jenkins.arn}*",
  ]
```

Make it:

```hcl
  external_secrets_secrets_manager_arns = [
    "${aws_secretsmanager_secret.app.arn}*",
    "${aws_secretsmanager_secret.jenkins.arn}*",
    # Omit this and the ExternalSecrets in Task 3 fail while Grafana boots normally with an empty
    # password -- discovered when a panel loads, not at deploy time.
    "${aws_secretsmanager_secret.grafana.arn}*",
  ]
```

- [ ] **Step 3: Add the Grafana IRSA role to `terraform/irsa.tf`**

Append. Modelled on `alertmanager_trust` / `alertmanager_permissions` directly above it.

```hcl
data "aws_iam_policy_document" "grafana_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      # The chart's SA name is <release>-grafana. Changing the release name in addon-monitoring.tf
      # without changing this string breaks the CloudWatch data source silently: Grafana starts
      # fine and only the panels fail, with an AccessDenied nobody is watching for.
      values = ["system:serviceaccount:observability:kube-prometheus-stack-grafana"]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "grafana_permissions" {
  # Logs: resource-scoped to this cluster's three Fluent Bit log groups and nothing else.
  statement {
    sid    = "ReadClusterLogs"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/containerinsights/${var.cluster_name}/*",
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/containerinsights/${var.cluster_name}/*:log-stream:*",
    ]
  }

  # Metrics: CANNOT be resource-scoped. AWS publishes no IAM condition key for restricting
  # cloudwatch:GetMetricData or ListMetrics to a namespace, so these take Resource "*". The grant is
  # read-only and this is a single-purpose account; the asymmetry with the Logs statement above is
  # deliberate and is recorded in docs/security.md so it is not later read as an oversight.
  # See docs/design/2026-08-24-grafana-datasources-design.md decision 2.
  statement {
    sid    = "ReadMetrics"
    effect = "Allow"
    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "grafana" {
  name               = "${var.cluster_name}-grafana-irsa"
  assume_role_policy = data.aws_iam_policy_document.grafana_trust.json
}

resource "aws_iam_role_policy" "grafana" {
  name   = "${var.cluster_name}-grafana-permissions"
  role   = aws_iam_role.grafana.id
  policy = data.aws_iam_policy_document.grafana_permissions.json
}
```

- [ ] **Step 4: Verify `data.aws_caller_identity.current` already exists**

Run: `grep -rn 'data "aws_caller_identity"' terraform/`
Expected: exactly one declaration. If it returns nothing, add `data "aws_caller_identity" "current" {}` to `terraform/providers.tf` instead of duplicating it.

- [ ] **Step 5: Format and validate**

```bash
cd terraform && terraform fmt -recursive && terraform validate
```

Expected: `Success! The configuration is valid.` Do **not** run `terraform apply` — it is billed and gated on a human.

- [ ] **Step 6: Commit**

```bash
git add terraform/secrets.tf terraform/addon-eso.tf terraform/irsa.tf
git commit -m "terraform: Grafana data source secret container and CloudWatch IRSA role

One Secrets Manager container for the grafana_ro DB password and the GitHub
PAT, projected later by two ExternalSecrets so the token never reaches the
application namespace.

The IRSA role's Logs statement is scoped to this cluster's three Fluent Bit
log groups; the metrics statement cannot be scoped at all, because AWS
publishes no condition key for restricting GetMetricData to a namespace. The
asymmetry is deliberate and documented rather than quietly widened.

The ESO ARN allowlist entry is the load-bearing line: without it the
ExternalSecrets fail while Grafana boots normally with an empty password."
```

---

### Task 2: Terraform — Grafana plugin, secret projection, ServiceAccount annotation

**Files:**
- Modify: `terraform/addon-monitoring.tf` (the `values` yamlencode block)

**Interfaces:**
- Consumes: `aws_iam_role.grafana.arn` from Task 1.
- Produces: environment variables `GF_DATASOURCE_DB_PASSWORD` and `GF_DATASOURCE_GITHUB_TOKEN` inside the Grafana container, projected from the K8s Secret `grafana-datasources` that Task 3 creates. Task 4's ConfigMaps interpolate exactly these two names.

- [ ] **Step 1: Add a `grafana` block to the existing `values` yamlencode**

Insert a top-level `grafana = { ... }` key alongside the existing `kubeScheduler` / `alertmanager` keys. Do not add a second `values` entry.

```hcl
    grafana = {
      serviceAccount = {
        annotations = {
          # CloudWatch data source authentication. Grafana carried no AWS role until this change;
          # this is the same IRSA pattern alertmanager above uses to reach SNS.
          "eks.amazonaws.com/role-arn" = aws_iam_role.grafana.arn
        }
      }

      # The ONLY plugin here, and the only network-fetched component in the whole data source set.
      # Prometheus, CloudWatch and PostgreSQL are all compiled into grafana/grafana:13.1.1 --
      # verified at /usr/share/grafana/public/app/plugins/datasource/. This one is downloaded from
      # grafana.com into /var/lib/grafana, which is an emptyDir, so it is re-fetched on EVERY pod
      # start -- roughly daily on a 100% Spot node group. If the fetch fails Grafana comes up
      # healthy and the GitHub panels are simply absent. Nothing load-bearing depends on it.
      # See docs/design/2026-08-24-grafana-datasources-design.md decision 5.
      plugins = ["grafana-github-datasource"]

      # Projects every key of the K8s Secret as an environment variable. The data source
      # provisioning files in charts/observability interpolate $GF_DATASOURCE_DB_PASSWORD and
      # $GF_DATASOURCE_GITHUB_TOKEN by those exact names -- Grafana expands an UNSET variable to an
      # empty string rather than erroring, so a typo here is silent-failure #2 in the design doc.
      # scripts/tests/test-grafana-datasources.sh cross-checks the two sides.
      envFromSecret = "grafana-datasources"
    }
```

- [ ] **Step 2: Format and validate**

```bash
cd terraform && terraform fmt -recursive && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Confirm the key name against the chart, do not trust this plan**

Run:

```bash
helm show values prometheus-community/kube-prometheus-stack --version 87.21.0 \
  | sed -n '/^grafana:/,/^[a-z]/p' | grep -nE 'envFromSecret|^  plugins|serviceAccount'
```

Expected: `envFromSecret` and `plugins` appear as grafana sub-keys. If the sub-chart has renamed either, use the chart's name and note it in the commit message. If the `prometheus-community` repo is not added locally, run `helm repo add prometheus-community https://prometheus-community.github.io/helm-charts && helm repo update` first.

- [ ] **Step 4: Commit**

```bash
git add terraform/addon-monitoring.tf
git commit -m "terraform: give Grafana an IRSA role, the GitHub plugin and its secret env

Three pod-spec-level pieces that cannot live in a ConfigMap, so they stay on
the terraform side of the boundary while the data sources themselves ship by
git push.

The plugin list has exactly one entry. Prometheus, CloudWatch and PostgreSQL
are all compiled into grafana/grafana:13.1.1 -- checked in the running
container rather than inferred -- so only the GitHub data source is fetched
from grafana.com, into an emptyDir, on every pod start."
```

---

### Task 3: ExternalSecrets — one container, two projections

**Files:**
- Create: `charts/observability/templates/externalsecret.yaml`
- Modify: `charts/observability/values.yaml` (append an `externalSecret` block)
- Modify: `charts/voteball/templates/externalsecret.yaml` (append a second ExternalSecret)
- Modify: `charts/voteball/values.yaml` (add `grafanaSecretName` under the existing `externalSecret` block)

**Interfaces:**
- Consumes: the Secrets Manager secret name `voteball/grafana` from Task 1.
- Produces: K8s Secret `grafana-datasources` in `observability` with keys `GF_DATASOURCE_DB_PASSWORD` and `GF_DATASOURCE_GITHUB_TOKEN`; K8s Secret `grafana-db-secret` in `devops-app` with key `GRAFANA_DB_PASSWORD`. Task 5's migrate Job consumes the latter.

- [ ] **Step 1: Create `charts/observability/templates/externalsecret.yaml`**

```yaml
# Grafana data source credentials, synced from Secrets Manager by External Secrets Operator.
#
# A SecretStore per namespace, matching charts/voteball: ESO authenticates with the CONTROLLER's
# IRSA, whose policy is an explicit ARN allowlist in terraform/addon-eso.tf. If voteball/grafana is
# missing from that list this resource reports SecretSyncedError while Grafana boots normally with
# an EMPTY password -- the failure surfaces when a panel loads, not at deploy time.
#
# apiVersion v1: ESO 2.8.0 serves external-secrets.io/v1 (v1beta1 is no longer served).
{{- if .Values.externalSecret.enabled }}
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-secrets
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "observability.labels" . | nindent 4 }}
spec:
  provider:
    aws:
      service: SecretsManager
      region: {{ .Values.externalSecret.region | quote }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-datasources
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "observability.labels" . | nindent 4 }}
spec:
  refreshInterval: {{ .Values.externalSecret.refreshInterval | quote }}
  secretStoreRef:
    name: aws-secrets
    kind: SecretStore
  target:
    name: grafana-datasources   # projected into the Grafana pod by grafana.envFromSecret
    creationPolicy: Owner
    deletionPolicy: Retain      # ESO default -- stated explicitly so ArgoCD stays Synced
  # Named keys rather than dataFrom/extract: the environment variable names are a contract with the
  # provisioning files in templates/datasources.yaml, and a rename on either side must not silently
  # produce an empty string. Spelling them out here makes the contract greppable.
  data:
    - secretKey: GF_DATASOURCE_DB_PASSWORD
      remoteRef:
        key: {{ .Values.externalSecret.secretName | quote }}
        property: db_password
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
    - secretKey: GF_DATASOURCE_GITHUB_TOKEN
      remoteRef:
        key: {{ .Values.externalSecret.secretName | quote }}
        property: github_token
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
{{- end }}
```

- [ ] **Step 2: Append the values block to `charts/observability/values.yaml`**

```yaml
# Grafana data source credentials from AWS Secrets Manager via External Secrets Operator.
# Gated like everything else in this chart so `helm template` works with no ESO CRDs installed.
#
# The region is a literal for the same reason serviceCidr above is: this chart is ArgoCD-synced and
# cannot receive a Terraform output.
externalSecret:
  enabled: true
  secretName: "voteball/grafana"
  region: "il-central-1"
  refreshInterval: "1h"
```

- [ ] **Step 3: Append the second ExternalSecret to `charts/voteball/templates/externalsecret.yaml`**

The `aws-secrets` SecretStore in `devops-app` already exists at the top of that file; reuse it rather than declaring a second one.

```yaml
---
# The grafana_ro Postgres password, for the migrate Job's ALTER ROLE (services/backend/migrate.py).
#
# A SEPARATE ExternalSecret rather than another key in app-secret: this namespace has no business
# holding the GitHub token that sits in the same Secrets Manager container, and `data` with a named
# property is what keeps the two apart. Kept out of app-secret so backend/worker do not gain a
# credential they never use.
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: grafana-db-secret
  namespace: {{ .Release.Namespace }}
spec:
  refreshInterval: {{ .Values.externalSecret.refreshInterval | quote }}
  secretStoreRef:
    name: aws-secrets
    kind: SecretStore
  target:
    name: grafana-db-secret
    creationPolicy: Owner
    deletionPolicy: Retain
  data:
    - secretKey: GRAFANA_DB_PASSWORD
      remoteRef:
        key: {{ .Values.externalSecret.grafanaSecretName | quote }}
        property: db_password
        conversionStrategy: Default
        decodingStrategy: None
        metadataPolicy: None
```

- [ ] **Step 4: Add `grafanaSecretName` to `charts/voteball/values.yaml`**

Under the existing `externalSecret:` block at line 50, which currently holds `secretName` and `refreshInterval`:

```yaml
externalSecret:
  secretName: "voteball/app-secret"
  # The grafana_ro DB password lives in its OWN container so the observability namespace can read it
  # without also being handed the app's DB and admin credentials.
  grafanaSecretName: "voteball/grafana"
  refreshInterval: "1h"
```

- [ ] **Step 5: Render both charts to verify they template cleanly**

```bash
helm template obs charts/observability | grep -c "kind: ExternalSecret"
helm template vb  charts/voteball      | grep -c "kind: ExternalSecret"
```

Expected: `1` and `2` respectively. If `helm` is unavailable, skip and rely on Task 4's test plus CI.

- [ ] **Step 6: Confirm no empty list literal was introduced**

Run: `scripts/ci/validate-repo.sh`
Expected: pass. This is the check that catches `to: []`-style literals the API server normalises away.

- [ ] **Step 7: Commit**

```bash
git add charts/observability/templates/externalsecret.yaml charts/observability/values.yaml \
        charts/voteball/templates/externalsecret.yaml charts/voteball/values.yaml
git commit -m "charts: project the Grafana data source credentials into two namespaces

One Secrets Manager container, two ExternalSecrets. observability gets the
DB password and the GitHub token; devops-app gets the DB password alone, for
the migrate Job's ALTER ROLE. The GitHub token never enters the application
namespace, and backend/worker gain no credential they do not use.

Named data keys rather than dataFrom/extract: the environment variable names
are a contract with the provisioning files, and Grafana expands an unset
variable to an empty string rather than erroring, so the contract has to be
greppable from both ends."
```

---

### Task 4: The data source ConfigMaps and the test that keeps them honest

**Files:**
- Create: `charts/observability/templates/datasources.yaml`
- Create: `scripts/tests/test-grafana-datasources.sh`
- Modify: `scripts/tests/run-ci-suite.sh` (add the new test to `PYTHON_GROUP`)

**Interfaces:**
- Consumes: env var names `GF_DATASOURCE_DB_PASSWORD` / `GF_DATASOURCE_GITHUB_TOKEN` from Task 2, `config.DB_HOST` from `charts/voteball/values.yaml`.
- Produces: data source uids `postgres`, `cloudwatch`, `github`. Task 6's dashboards reference these exact strings.

- [ ] **Step 1: Write the failing test**

Create `scripts/tests/test-grafana-datasources.sh`:

```bash
#!/usr/bin/env bash
# Anti-drift gate for the Grafana data source provisioning files.
#
# WHY THIS EXISTS: Grafana expands an UNSET environment variable in a provisioning file to an EMPTY
# STRING rather than failing. So a renamed key on either side of the contract -- the ExternalSecret's
# secretKey, terraform's envFromSecret, or the $VAR in the ConfigMap -- produces a data source that
# provisions cleanly, reports no error at startup, and fails only when a human opens a panel. That is
# silent failure #2 in docs/design/2026-08-24-grafana-datasources-design.md.
#
# It also checks the uid contract in the other direction: a dashboard panel naming a data source uid
# that no data source declares renders an empty panel, not an error.
#
# Offline: reads the repository's own files, renders nothing, needs no cluster.
set -uo pipefail

cd "$(dirname "$0")/../.."   # repo root

DS=charts/observability/templates/datasources.yaml
TF=terraform/addon-monitoring.tf
ES=charts/observability/templates/externalsecret.yaml
DASHBOARD_DIR=charts/observability/dashboards

fails=0
fail() { echo "  FAIL $*"; fails=$((fails + 1)); }
ok()   { echo "  ok   $*"; }

for f in "$DS" "$TF" "$ES"; do
  [ -f "$f" ] || { echo "FAIL: $f not found -- has it been renamed?" >&2; exit 1; }
done

# --- 1. Every $VAR the ConfigMaps interpolate is actually projected -------------------------------
echo "1. environment variables referenced by $DS"
vars=$(grep -oE '\$GF_DATASOURCE_[A-Z_]+' "$DS" | sed 's/^\$//' | sort -u)
[ -n "$vars" ] || fail "no \$GF_DATASOURCE_* references found -- did the interpolation syntax change?"
for v in $vars; do
  if grep -q "secretKey: $v" "$ES"; then
    ok "$v is produced by an ExternalSecret"
  else
    fail "$v is interpolated in $DS but no ExternalSecret in $ES produces it"
  fi
done

# --- 2. The Secret those keys live in is projected into the pod -----------------------------------
echo "2. envFromSecret wiring"
if grep -q 'envFromSecret *= *"grafana-datasources"' "$TF"; then
  ok "terraform projects the grafana-datasources Secret"
else
  fail "$TF does not set grafana.envFromSecret to grafana-datasources"
fi
if grep -q 'name: grafana-datasources' "$ES"; then
  ok "the ExternalSecret targets that Secret name"
else
  fail "$ES does not target a Secret named grafana-datasources"
fi

# --- 3. No literal credential anywhere in the ConfigMaps ------------------------------------------
echo "3. no plaintext credential in $DS"
if grep -nE '(password|token):[[:space:]]*["'"'"']?[^$"'"'"'[:space:]][^"'"'"']*' "$DS" \
     | grep -vE '\$GF_DATASOURCE_' | grep -q .; then
  fail "a password/token field in $DS is not an environment reference"
else
  ok "every password/token field is a \$GF_DATASOURCE_* reference"
fi

# --- 4. Declared uids, and every dashboard panel referencing one that exists -----------------------
echo "4. data source uid contract"
# uids the chart declares, plus the two kube-prometheus-stack provisions for itself.
declared=$( { grep -oE '^[[:space:]]+uid:[[:space:]]*[a-z0-9-]+' "$DS" | sed -E 's/.*uid:[[:space:]]*//'
              printf 'prometheus\nalertmanager\n'; } | sort -u )
for u in $declared; do ok "declares uid $u"; done

if [ -d "$DASHBOARD_DIR" ]; then
  used=$(grep -rhoE '"uid":[[:space:]]*"[a-z0-9-]+"' "$DASHBOARD_DIR" \
           | sed -E 's/.*"uid":[[:space:]]*"([a-z0-9-]+)"/\1/' | sort -u)
  for u in $used; do
    # A dashboard's OWN uid also matches this pattern; only flag ones that look like data sources,
    # i.e. those appearing inside a "datasource" object. Grep the enclosing key to be sure.
    if grep -rqE "\"datasource\":[[:space:]]*\{[^}]*\"uid\":[[:space:]]*\"$u\"" "$DASHBOARD_DIR"; then
      if echo "$declared" | grep -qx "$u"; then
        ok "dashboard data source uid $u is declared"
      else
        fail "a dashboard panel uses data source uid \"$u\", which no data source declares"
      fi
    fi
  done
fi

echo
if [ "$fails" -gt 0 ]; then
  echo "FAILED: $fails check(s)" >&2
  exit 1
fi
echo "PASSED"
```

Then: `chmod +x scripts/tests/test-grafana-datasources.sh`

- [ ] **Step 2: Run it to verify it fails**

Run: `scripts/tests/test-grafana-datasources.sh`
Expected: FAIL — `charts/observability/templates/datasources.yaml not found -- has it been renamed?`, exit 1.

- [ ] **Step 3: Create `charts/observability/templates/datasources.yaml`**

```yaml
# Grafana data sources as code.
#
# The Grafana pod runs a `grafana-sc-datasources` sidecar watching for ConfigMaps labelled
# `grafana_datasource: "1"` and writing them into /etc/grafana/provisioning/datasources -- verified
# live on this cluster. So a committed file IS a data source, with no API call and nothing for a
# human to click. Same mechanism as templates/dashboards.yaml, and the same reason: Grafana has no
# persistent storage here, so anything clicked into the UI dies at the next Spot reclaim.
#
# NOT DECLARED HERE: Prometheus (uid `prometheus`) and Alertmanager (uid `alertmanager`).
# kube-prometheus-stack provisions both itself, correctly. Redeclaring them would create a second
# source of truth for something that already works.
#
# $GF_DATASOURCE_* are environment variables projected from the `grafana-datasources` Secret by
# terraform's grafana.envFromSecret. Grafana expands an UNSET variable to an EMPTY STRING rather
# than erroring, so a rename on either side is invisible until a panel is opened --
# scripts/tests/test-grafana-datasources.sh is what catches that.
{{- if .Values.datasources.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: datasource-postgres
  namespace: {{ .Release.Namespace }}
  labels:
    grafana_datasource: "1"
    {{- include "observability.labels" . | nindent 4 }}
data:
  datasource-postgres.yaml: |
    apiVersion: 1
    datasources:
      - name: "PostgreSQL"
        type: grafana-postgresql-datasource
        uid: postgres
        access: proxy
        url: {{ .Values.datasources.postgres.host | quote }}
        user: grafana_ro
        database: {{ .Values.datasources.postgres.database | quote }}
        # SELECT-only on the rollup and reference tables plus one view; the base `votes` table is
        # REVOKEd because it carries cookie_token and ip_hash. Never the `postgres` master user the
        # app connects as. See services/backend/schema.sql and the design doc's decision 3.
        secureJsonData:
          password: $GF_DATASOURCE_DB_PASSWORD
        jsonData:
          sslmode: require
          postgresVersion: 1600
          maxOpenConns: 5
          maxIdleConns: 2
          connMaxLifetime: 14400
          timescaledb: false
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: datasource-cloudwatch
  namespace: {{ .Release.Namespace }}
  labels:
    grafana_datasource: "1"
    {{- include "observability.labels" . | nindent 4 }}
data:
  datasource-cloudwatch.yaml: |
    apiVersion: 1
    datasources:
      - name: "CloudWatch"
        type: cloudwatch
        uid: cloudwatch
        access: proxy
        # No credential of any kind. authType `default` makes the AWS SDK use the pod's projected
        # service account token, i.e. the IRSA role annotated onto the Grafana ServiceAccount in
        # terraform/addon-monitoring.tf. This is the only data source here with nothing to seed,
        # rotate or leak.
        jsonData:
          authType: default
          defaultRegion: {{ .Values.datasources.cloudwatch.region | quote }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: datasource-github
  namespace: {{ .Release.Namespace }}
  labels:
    grafana_datasource: "1"
    {{- include "observability.labels" . | nindent 4 }}
data:
  datasource-github.yaml: |
    apiVersion: 1
    datasources:
      - name: "GitHub"
        type: grafana-github-datasource
        uid: github
        access: proxy
        # The ONLY data source here backed by a downloaded plugin. /var/lib/grafana is an emptyDir,
        # so the plugin is re-fetched from grafana.com on every pod start -- roughly daily on Spot.
        # A failed fetch leaves Grafana healthy and these panels absent. Nothing else depends on it.
        secureJsonData:
          accessToken: $GF_DATASOURCE_GITHUB_TOKEN
        jsonData:
          owner: {{ .Values.datasources.github.owner | quote }}
          repository: {{ .Values.datasources.github.repository | quote }}
{{- end }}
```

- [ ] **Step 4: Append the values block to `charts/observability/values.yaml`**

```yaml
# Grafana data sources (templates/datasources.yaml). Prometheus and Alertmanager are NOT here --
# kube-prometheus-stack provisions those itself.
#
# These are literals for the same reason serviceCidr is: this chart is ArgoCD-synced and cannot
# receive a Terraform output. The RDS host must match charts/voteball/values.yaml's config.DB_HOST,
# which IS sync-managed -- so on a rebuild, update this one by hand to match.
datasources:
  enabled: true
  postgres:
    host: "voteball-eks-db.cfew0a2ywspq.il-central-1.rds.amazonaws.com:5432"
    database: "postgres"
  cloudwatch:
    region: "il-central-1"
  github:
    owner: "Latnook"
    repository: "voteball"
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `scripts/tests/test-grafana-datasources.sh`
Expected: PASSED, exit 0. Every `$GF_DATASOURCE_*` is matched to an ExternalSecret `secretKey`, `envFromSecret` is wired, no plaintext credential, three new uids declared.

- [ ] **Step 6: Prove the test actually catches the failure it exists for**

Temporarily rename one key, confirm the failure, then restore:

```bash
sed -i 's/GF_DATASOURCE_DB_PASSWORD/GF_DATASOURCE_DB_PASSWD/' charts/observability/templates/datasources.yaml
scripts/tests/test-grafana-datasources.sh; echo "rc=$?"
git checkout -- charts/observability/templates/datasources.yaml
```

Expected: `FAIL GF_DATASOURCE_DB_PASSWD is interpolated in ... but no ExternalSecret ... produces it`, `rc=1`. A test that cannot fail is not a test — this step is the whole reason the file exists.

- [ ] **Step 7: Register the test in `scripts/tests/run-ci-suite.sh`**

Add `test-grafana-datasources.sh` to `PYTHON_GROUP`, in alphabetical position (after `test-frontend-seo.sh`, before `test-i18n-parity.sh`). The runner fails if a file in `scripts/tests/` appears in no group, so this is not optional.

The test is bash+grep only and would run in either container; it goes in `PYTHON_GROUP` because that group already carries the other doc/config anti-drift gates and keeps them together.

- [ ] **Step 8: Run the whole suite**

Run: `scripts/tests/run-ci-suite.sh`
Expected: all tests pass, and the final count line has increased by one from 24. Read the count off the output — do not assert it from this plan.

- [ ] **Step 9: Commit**

```bash
git add charts/observability/templates/datasources.yaml charts/observability/values.yaml \
        scripts/tests/test-grafana-datasources.sh scripts/tests/run-ci-suite.sh
git commit -m "charts: PostgreSQL, CloudWatch and GitHub data sources as code

Three ConfigMaps the Grafana sidecar discovers by label, the same mechanism
the three dashboards already use -- so a data source is a commit, not a click.
Prometheus and Alertmanager stay chart-provisioned; redeclaring them would
create a second source of truth for something already correct.

The new test exists because Grafana expands an unset environment variable to
an empty string rather than erroring: a renamed key on either side of the
contract provisions cleanly and fails only when someone opens a panel. It
checks the uid contract in the other direction too, since a dashboard naming
an undeclared data source renders an empty panel rather than an error."
```

---

### Task 5: The `grafana_ro` role, the view, and the password

**Files:**
- Modify: `services/backend/schema.sql` (append)
- Modify: `services/backend/migrate.py`
- Modify: `charts/voteball/templates/migrate-job.yaml` (add an `envFrom` entry)
- Test: `services/backend/tests/test_migration.py`

**Interfaces:**
- Consumes: K8s Secret `grafana-db-secret` from Task 3.
- Produces: Postgres role `grafana_ro`, view `v_grafana_votes`. Task 4's PostgreSQL data source authenticates as this role.

- [ ] **Step 1: Write the failing tests**

Append to `services/backend/tests/test_migration.py`:

```python
def test_grafana_ro_role_exists_after_init(db_conn):
    """schema.sql creates the read-only role, so a GRANT naming it never fails."""
    cur = db_conn.cursor()
    cur.execute("SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro'")
    assert cur.fetchone() is not None
    cur.close()


def test_grafana_ro_role_has_no_password_from_schema(db_conn):
    """schema.sql must NOT set a password. Only migrate.py does, from the environment.

    schema.sql runs on every backend boot (app.py's __main__ guard and gunicorn's on_starting hook,
    not just the migrate Job), so it can carry no secret and must not depend on one being present.
    A role with no password cannot authenticate under scram-sha-256, so the intermediate state
    fails closed.
    """
    cur = db_conn.cursor()
    cur.execute("SELECT rolpassword FROM pg_authid WHERE rolname = 'grafana_ro'")
    row = cur.fetchone()
    assert row is not None
    assert row[0] is None, 'schema.sql set a password on grafana_ro; only migrate.py may do that'
    cur.close()


def test_grafana_view_hides_voter_identifiers(db_conn):
    """v_grafana_votes must not expose cookie_token or ip_hash.

    Both link a ballot to a person. The site promises an anonymous poll, and a Grafana query box is
    exactly where that leaks. See the design doc's decision 3.
    """
    cur = db_conn.cursor()
    cur.execute("""
        SELECT column_name FROM information_schema.columns
        WHERE table_name = 'v_grafana_votes'
    """)
    cols = {r[0] for r in cur.fetchall()}
    assert cols, 'v_grafana_votes does not exist'
    assert 'cookie_token' not in cols
    assert 'ip_hash' not in cols
    assert {'id', 'created_at', 'previous_party_id'} <= cols
    cur.close()


def test_grafana_ro_cannot_read_raw_votes(db_conn):
    """The base votes table is REVOKEd; only the view is readable."""
    cur = db_conn.cursor()
    cur.execute("SELECT has_table_privilege('grafana_ro', 'votes', 'SELECT')")
    assert cur.fetchone()[0] is False, 'grafana_ro can read raw votes -- cookie_token is exposed'
    cur.execute("SELECT has_table_privilege('grafana_ro', 'v_grafana_votes', 'SELECT')")
    assert cur.fetchone()[0] is True
    cur.execute("SELECT has_table_privilege('grafana_ro', 'rollup_previous', 'SELECT')")
    assert cur.fetchone()[0] is True
    cur.close()


def test_grafana_ro_cannot_write(db_conn):
    """Read-only means read-only, on every table it can see."""
    cur = db_conn.cursor()
    for tbl in ('rollup_previous', 'leagues', 'clubs', 'upcoming_parties'):
        for priv in ('INSERT', 'UPDATE', 'DELETE'):
            cur.execute('SELECT has_table_privilege(%s, %s, %s)', ('grafana_ro', tbl, priv))
            assert cur.fetchone()[0] is False, f'grafana_ro has {priv} on {tbl}'
    cur.close()
```

Use whatever connection fixture `services/backend/tests/test_migration.py` already uses — read the top of that file and match it rather than inventing `db_conn`. If the existing fixture has a different name, rename these tests' parameter to match.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd services/backend && python -m pytest tests/test_migration.py -k grafana -v`
Expected: 5 FAILED — the role, the view and the grants do not exist yet.

- [ ] **Step 3: Append the role, view and grants to `services/backend/schema.sql`**

```sql
-- ---------------------------------------------------------------------------------------------
-- Grafana's read-only access. See docs/design/2026-08-24-grafana-datasources-design.md decision 3.
--
-- THE ROLE IS CREATED HERE, WITHOUT A PASSWORD, AND THAT SPLIT IS LOAD-BEARING.
-- This file runs on EVERY backend boot -- db.init_db() is called from migrate.py, from app.py's
-- __main__ guard AND from gunicorn.conf.py's on_starting hook -- not only from the migrate Job. So
-- a GRANT naming a role that only the migrate Job creates would fail every backend pod's startup,
-- turning a monitoring feature into an application outage. The role must therefore exist by the
-- time the grants run, in the same file.
--
-- The password is set separately, by migrate.py, from GRAFANA_DB_PASSWORD. A static SQL file has
-- nowhere to put a secret, and a Postgres role with no password cannot authenticate under
-- scram-sha-256 -- so the intermediate state (role created, password not yet set) fails CLOSED.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'grafana_ro') THEN
        CREATE ROLE grafana_ro LOGIN;
    END IF;
END
$$;

-- votes carries cookie_token (unique per voter) and ip_hash. Both link a ballot to a person, so the
-- base table is never readable by Grafana; this view is what the dashboards query instead. A view
-- rather than column-level grants for two reasons: a reviewer can read one object and know exactly
-- what the dashboard tool can see, and ALTER DEFAULT PRIVILEGES below does not apply to column
-- grants.
CREATE OR REPLACE VIEW v_grafana_votes AS
    SELECT id,
           created_at,
           previous_vote_status,
           upcoming_vote_status,
           previous_party_id
      FROM votes;

-- current_database(), not a literal: the database name comes from terraform/voteball.tfvars and a
-- forker's will differ. GRANT takes an identifier, not an expression, so this needs a DO block with
-- format(%I) rather than a plain statement -- the same reason the role creation above needs one.
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO grafana_ro', current_database());
END
$$;
GRANT USAGE ON SCHEMA public TO grafana_ro;

-- The eight rollup tables and the four reference tables.
GRANT SELECT ON rollup_previous, rollup_upcoming, rollup_previous_upcoming,
                rollup_national_previous, rollup_national_upcoming,
                rollup_national_previous_upcoming,
                rollup_vote_switch, rollup_national_vote_switch,
                leagues, clubs, previous_parties, upcoming_parties,
                v_grafana_votes
    TO grafana_ro;

-- Explicit and unconditional. A REVOKE that is merely "never granted" is one careless
-- GRANT ALL away from being wrong; stating it means the intent survives someone else's shortcut.
REVOKE ALL ON votes, vote_clubs, vote_leagues, vote_upcoming_parties FROM grafana_ro;

-- Without this, a rollup table added next month is a broken panel next month -- the grant list
-- above names tables that exist today and nothing updates it automatically.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO grafana_ro;
```

- [ ] **Step 4: Run the tests to verify four of five now pass**

Run: `cd services/backend && python -m pytest tests/test_migration.py -k grafana -v`
Expected: all 5 PASS. (`test_grafana_ro_role_has_no_password_from_schema` passes because `schema.sql` deliberately sets none.)

- [ ] **Step 5: Set the password from `migrate.py`**

Replace the body of `main()` in `services/backend/migrate.py`:

```python
"""Standalone schema-bootstrap entrypoint: `python migrate.py`."""
import os

import db


def _set_grafana_password(conn):
    """Give the grafana_ro role its password, from the environment.

    schema.sql creates the role with no password, because it runs on every backend boot and can
    carry no secret. This runs only in the migrate Job, which is the one place the password is
    projected -- see charts/voteball/templates/externalsecret.yaml.

    DELIBERATELY OPTIONAL. If GRAFANA_DB_PASSWORD is absent the Job prints a notice and succeeds.
    A missing monitoring credential must never block a release: this Job is a pre-upgrade Helm hook,
    so raising here would stop the application from deploying because a dashboard cannot log in.
    """
    password = os.environ.get('GRAFANA_DB_PASSWORD', '')
    if not password:
        print('GRAFANA_DB_PASSWORD not set; leaving grafana_ro without a password '
              '(the Grafana PostgreSQL data source will not authenticate until it is seeded).')
        return

    cur = conn.cursor()
    # Parameterised as a VALUE is not possible here -- ALTER ROLE takes a literal, not a bind
    # parameter -- so quote it with psycopg2's own literal quoting rather than an f-string.
    from psycopg2 import sql
    cur.execute(sql.SQL('ALTER ROLE grafana_ro WITH PASSWORD {}').format(sql.Literal(password)))
    conn.commit()
    cur.close()
    print('grafana_ro password set.')


def main():
    """Open a connection, apply schema + seed once, set the Grafana role's password, and close it."""
    conn = db.get_db()
    try:
        db.init_db(conn)
        print('Schema and seed applied.')
        _set_grafana_password(conn)
    finally:
        # try/finally so the connection is released even if init_db raises -- the same
        # close-on-every-exit-path discipline the app's request handlers follow.
        conn.close()


if __name__ == '__main__':
    main()
```

- [ ] **Step 6: Write and run a test for the optional-password behaviour**

Append to `services/backend/tests/test_migration.py`:

```python
def test_migrate_succeeds_without_grafana_password(db_conn, monkeypatch, capsys):
    """A missing monitoring credential must never block a release.

    migrate.py runs as a pre-upgrade Helm hook. Raising here would stop the application deploying
    because a dashboard cannot log in -- so an absent GRAFANA_DB_PASSWORD prints a notice and
    succeeds. This is what lets the GitHub/Postgres data sources be wired last, after the rest of
    the change is already live.
    """
    import migrate
    monkeypatch.delenv('GRAFANA_DB_PASSWORD', raising=False)
    migrate._set_grafana_password(db_conn)
    assert 'not set' in capsys.readouterr().out


def test_migrate_sets_grafana_password_when_present(db_conn, monkeypatch, capsys):
    import migrate
    monkeypatch.setenv('GRAFANA_DB_PASSWORD', 'test-password-not-a-real-secret')
    migrate._set_grafana_password(db_conn)
    assert 'password set' in capsys.readouterr().out
    cur = db_conn.cursor()
    cur.execute("SELECT rolpassword IS NOT NULL FROM pg_authid WHERE rolname = 'grafana_ro'")
    assert cur.fetchone()[0] is True
    cur.close()
```

Run: `cd services/backend && python -m pytest tests/test_migration.py -k grafana -v`
Expected: all 7 PASS.

- [ ] **Step 7: Project the secret into the migrate Job**

In `charts/voteball/templates/migrate-job.yaml`, the migrate container's `envFrom` currently reads:

```yaml
          envFrom:
            - configMapRef: { name: app-config }
            - secretRef: { name: app-secret }
```

Make it:

```yaml
          envFrom:
            - configMapRef: { name: app-config }
            - secretRef: { name: app-secret }
            # GRAFANA_DB_PASSWORD, for the grafana_ro ALTER ROLE in migrate.py. `optional: true` is
            # load-bearing: this Job is a pre-upgrade Helm hook, so a missing Secret would otherwise
            # block the whole release on a monitoring credential. migrate.py treats an absent value
            # as "skip and carry on" for the same reason.
            - secretRef: { name: grafana-db-secret, optional: true }
```

- [ ] **Step 8: Run the full backend suite**

Run: `cd services/backend && python -m pytest -q`
Expected: all pass. Read the count off the output. If any pre-existing test fails, stop and investigate — the `REVOKE`/`GRANT` statements run against the same test database.

- [ ] **Step 9: Run ruff, which CI runs before any test stage**

Run: `cd services/backend && ruff check .`
Expected: clean. Note the `from psycopg2 import sql` inside the function is deliberate but ruff may prefer it at module scope — if it flags it, move the import to the top of the file with the others.

- [ ] **Step 10: Commit**

```bash
git add services/backend/schema.sql services/backend/migrate.py \
        services/backend/tests/test_migration.py charts/voteball/templates/migrate-job.yaml
git commit -m "backend: a read-only Postgres role for Grafana, and a view that hides voters

votes carries cookie_token and ip_hash, both of which link a ballot to a
person, so Grafana reads v_grafana_votes and the base table is REVOKEd. A view
rather than column grants: one object tells a reviewer exactly what the
dashboard tool can see, and ALTER DEFAULT PRIVILEGES -- which stops a rollup
table added next month becoming a broken panel next month -- cannot cover
column grants.

The role is created WITHOUT a password in schema.sql and given one by
migrate.py. schema.sql runs on every backend boot, not just in the migrate
Job, so a GRANT naming a role only that Job creates would fail every pod's
startup. A role with no password cannot authenticate under scram-sha-256, so
the intermediate state fails closed.

The password is optional throughout: the Job is a pre-upgrade hook, and a
missing monitoring credential must not block an application release."
```

---

### Task 6: Dashboards

**Files:**
- Create: `charts/observability/dashboards/business-analytics.json`
- Create: `charts/observability/dashboards/aws-infrastructure.json`
- Modify: `charts/observability/dashboards/jenkins-delivery.json`
- Modify: `docs/observability.md` (the dashboard table at line ~317, the count sentence, and the `charts/observability` row of the table at line ~71)

**Interfaces:**
- Consumes: data source uids `postgres`, `cloudwatch`, `github` from Task 4.
- Produces: dashboard uids `voteball-business` and `voteball-aws`.

- [ ] **Step 1: Read an existing dashboard to match its shape exactly**

Run: `python3 -m json.tool charts/observability/dashboards/jenkins-delivery.json | head -60`

Top-level keys in use: `editable`, `panels`, `refresh`, `schemaVersion`, `tags`, `time`, `timezone`, `title`, `uid`. Panel keys: `datasource`, `fieldConfig`, `gridPos`, `id`, `targets`, `title`, `type`. Match this shape; do not introduce `templating` unless a dashboard genuinely needs a variable.

- [ ] **Step 2: Create `business-analytics.json`**

Top level: `"uid": "voteball-business"`, `"title": "Voteball Business Analytics"`, `"refresh": "5m"`,
`"time": {"from": "now-30d", "to": "now"}`, `"timezone": "browser"`, `"editable": false`,
`"schemaVersion": 39`, `"tags": ["voteball", "business"]`.

Every panel carries:

```json
"datasource": { "type": "grafana-postgresql-datasource", "uid": "postgres" }
```

Six panels. The exact `rawSql` for each — every one reads only objects `grafana_ro` was granted in
Task 5, so a query hitting `votes` directly is a bug, not a permissions problem to widen:

```sql
-- Panel 1 "Votes per day"  type: timeseries  gridPos: {h:8,w:16,x:0,y:0}  format: time_series
SELECT $__timeGroup(created_at, '1d') AS time, count(*) AS "ballots"
FROM v_grafana_votes
WHERE $__timeFilter(created_at)
GROUP BY 1 ORDER BY 1;

-- Panel 2 "Total ballots"  type: stat  gridPos: {h:8,w:8,x:16,y:0}  format: table
SELECT count(*) AS "ballots" FROM v_grafana_votes;

-- Panel 3 "Top previous parties"  type: barchart  gridPos: {h:9,w:12,x:0,y:8}  format: table
SELECT p.name_en AS "party", r.vote_count AS "ballots"
FROM rollup_national_previous r
JOIN previous_parties p ON p.id = r.previous_party_id
ORDER BY r.vote_count DESC
LIMIT 15;

-- Panel 4 "Top upcoming parties (weighted)"  type: barchart  gridPos: {h:9,w:12,x:12,y:8}  format: table
-- weight, NOT vote_count. vote_count counts PICKS and a ballot may name up to 3 parties, so
-- ordering on it gives a 3-party ballot triple the say. weight carries SUM(1.0/k) so each ballot
-- totals exactly 1 -- see the comment above rollup_upcoming.weight in schema.sql.
SELECT p.name_en AS "party", r.weight AS "weighted ballots"
FROM rollup_national_upcoming r
JOIN upcoming_parties p ON p.id = r.upcoming_party_id
ORDER BY r.weight DESC
LIMIT 15;

-- Panel 5 "Ballots by league"  type: piechart  gridPos: {h:9,w:12,x:0,y:17}  format: table
-- club_id IS NULL selects the LEAGUE-SCOPE row. Each rollup carries one league-scope row per
-- distinct league a ballot touched; summing club-scope rows instead would count a multi-team
-- ballot once per club.
SELECT l.name_en AS "league", sum(r.vote_count) AS "ballots"
FROM rollup_previous r
JOIN leagues l ON l.id = r.league_id
WHERE r.club_id IS NULL
GROUP BY 1 ORDER BY 2 DESC;

-- Panel 6 "Vote switching"  type: table  gridPos: {h:9,w:12,x:12,y:17}  format: table
SELECT pp.name_en AS "voted last time", up.name_en AS "considering now", s.vote_count AS "ballots"
FROM rollup_national_vote_switch s
JOIN previous_parties pp ON pp.id = s.previous_party_id
JOIN upcoming_parties up ON up.id = s.upcoming_party_id
ORDER BY s.vote_count DESC
LIMIT 50;
```

Each `targets` entry has the shape:

```json
"targets": [
  {
    "refId": "A",
    "format": "time_series",
    "rawQuery": true,
    "rawSql": "SELECT $__timeGroup(created_at, '1d') AS time, count(*) AS \"ballots\" FROM v_grafana_votes WHERE $__timeFilter(created_at) GROUP BY 1 ORDER BY 1",
    "datasource": { "type": "grafana-postgresql-datasource", "uid": "postgres" }
  }
]
```

`name_en` for display in every join: the entity tables carry `name_en`/`name_he`/`name_ru` and
`name_en` is the non-null fallback `localizedName()` uses.

- [ ] **Step 3: Create `aws-infrastructure.json`**

Top level: `"uid": "voteball-aws"`, `"title": "AWS Infrastructure"`, `"time": {"from": "now-6h", "to": "now"}`,
`"timezone": "browser"`, `"editable": false`, `"schemaVersion": 39`, `"tags": ["voteball", "aws"]`.

**`"refresh": "5m"` is mandatory and is not a style choice.** CloudWatch bills per metric returned.
This dashboard requests ~14 metrics per refresh: 5 minutes ≈ $0.05/month, Grafana's 10-second default
≈ $12/month, for identical information. JSON has no comment syntax, so put the reasoning in the first
panel's `description` field where a UI reader sees it:

```json
"description": "Refresh is pinned to 5m deliberately. CloudWatch bills per metric returned; at Grafana's 10s default these 14 metrics cost roughly $12/month instead of $0.05. See docs/design/2026-08-24-grafana-datasources-design.md decision 8."
```

First get the real dimension values — do not hardcode them:

```bash
cd terraform && terraform output 2>/dev/null | grep -iE 'db_|rds|alb|lb_'
aws cloudwatch list-metrics --namespace AWS/RDS --region "$(grep aws_region voteball.tfvars | cut -d'"' -f2)" \
  --query 'Metrics[0].Dimensions' --output json
```

If a dimension value has to appear in the JSON, add it to `charts/observability/values.yaml` under
`datasources.cloudwatch` and template it the way `datasources.postgres.host` is templated. An
account-specific string hardcoded into a dashboard file is a forkability bug.

Nine metric panels, every one `"datasource": {"type": "cloudwatch", "uid": "cloudwatch"}`:

| # | Title | namespace | metricName | stat | gridPos |
|---|---|---|---|---|---|
| 1 | RDS CPU | `AWS/RDS` | `CPUUtilization` | Average | h8 w8 x0 y0 |
| 2 | RDS connections | `AWS/RDS` | `DatabaseConnections` | Maximum | h8 w8 x8 y0 |
| 3 | RDS free storage | `AWS/RDS` | `FreeStorageSpace` | Minimum | h8 w8 x16 y0 |
| 4 | RDS freeable memory | `AWS/RDS` | `FreeableMemory` | Minimum | h8 w12 x0 y8 |
| 5 | RDS read/write latency | `AWS/RDS` | `ReadLatency` + `WriteLatency` | Average | h8 w12 x12 y8 |
| 6 | ALB request count | `AWS/ApplicationELB` | `RequestCount` | Sum | h8 w6 x0 y16 |
| 7 | ALB target 5xx | `AWS/ApplicationELB` | `HTTPCode_Target_5XX_Count` | Sum | h8 w6 x6 y16 |
| 8 | ALB ELB 5xx | `AWS/ApplicationELB` | `HTTPCode_ELB_5XX_Count` | Sum | h8 w6 x12 y16 |
| 9 | ALB target response time | `AWS/ApplicationELB` | `TargetResponseTime` | p95 | h8 w6 x18 y16 |

Target shape (RDS panels use dimension `DBInstanceIdentifier`, ALB panels use `LoadBalancer`):

```json
"targets": [
  {
    "refId": "A",
    "namespace": "AWS/RDS",
    "metricName": "CPUUtilization",
    "statistic": "Average",
    "period": "300",
    "region": "default",
    "dimensions": { "DBInstanceIdentifier": "voteball-eks-db" },
    "matchExact": true,
    "datasource": { "type": "cloudwatch", "uid": "cloudwatch" }
  }
]
```

One logs panel, and **it must not auto-refresh**. Logs Insights bills per GB *scanned*, so a
refreshing panel re-scans its whole window forever:

```json
{
  "id": 10,
  "type": "logs",
  "title": "Recent application logs (on demand)",
  "description": "Short range on purpose. CloudWatch Logs Insights bills per GB SCANNED, not stored, so a wide auto-refreshing log panel re-scans its whole window on every tick. Use Explore for real log investigation; this panel exists to prove the connection works and to catch an obvious burst.",
  "gridPos": { "h": 10, "w": 24, "x": 0, "y": 24 },
  "timeFrom": "15m",
  "datasource": { "type": "cloudwatch", "uid": "cloudwatch" },
  "targets": [
    {
      "refId": "A",
      "queryMode": "Logs",
      "region": "default",
      "logGroups": [{ "arn": "", "name": "/aws/containerinsights/voteball/application" }],
      "expression": "fields @timestamp, kubernetes.pod_name, log | sort @timestamp desc | limit 100",
      "datasource": { "type": "cloudwatch", "uid": "cloudwatch" }
    }
  ]
}
```

That is 10 panels. Confirm with `grep -c '"gridPos"' charts/observability/dashboards/aws-infrastructure.json`
and use the real number in Step 5 — `test-observability-docs.sh` compares against exactly that count.

- [ ] **Step 4: Append three GitHub panels to `jenkins-delivery.json`**

The file currently has 8 panels; the highest existing `gridPos.y` determines where these go. Panel
ids continue from the existing maximum. Every one carries:

```json
"datasource": { "type": "grafana-github-datasource", "uid": "github" }
```

```json
{
  "id": 9,
  "type": "timeseries",
  "title": "Commits",
  "description": "Commit volume next to the builds it caused -- the reason these panels live on the delivery dashboard rather than a GitHub one of their own.",
  "gridPos": { "h": 8, "w": 12, "x": 0, "y": 24 },
  "datasource": { "type": "grafana-github-datasource", "uid": "github" },
  "targets": [
    {
      "refId": "A",
      "queryType": "Commits",
      "owner": "Latnook",
      "repository": "voteball",
      "options": { "ref": "master" },
      "datasource": { "type": "grafana-github-datasource", "uid": "github" }
    }
  ]
},
{
  "id": 10,
  "type": "stat",
  "title": "Contributors",
  "gridPos": { "h": 8, "w": 4, "x": 12, "y": 24 },
  "datasource": { "type": "grafana-github-datasource", "uid": "github" },
  "targets": [
    {
      "refId": "A",
      "queryType": "Contributors",
      "owner": "Latnook",
      "repository": "voteball",
      "datasource": { "type": "grafana-github-datasource", "uid": "github" }
    }
  ]
},
{
  "id": 11,
  "type": "table",
  "title": "Open issues",
  "gridPos": { "h": 8, "w": 8, "x": 16, "y": 24 },
  "datasource": { "type": "grafana-github-datasource", "uid": "github" },
  "targets": [
    {
      "refId": "A",
      "queryType": "Issues",
      "owner": "Latnook",
      "repository": "voteball",
      "options": { "query": "is:open" },
      "datasource": { "type": "grafana-github-datasource", "uid": "github" }
    }
  ]
}
```

**No pull-request panel.** `Latnook/voteball` is a solo repo committed straight to `master`, so a PR
panel would be a permanently-empty box — the dead-connection failure this whole change exists to
avoid.

The `owner`/`repository` literals here duplicate `charts/observability/values.yaml`'s
`datasources.github` block. That is acceptable in a dashboard JSON (dashboards are not templated by
`.Files.Glob`), but if `terraform output` ever exposes the repo slug, template it instead.

- [ ] **Step 5: Update `docs/observability.md`**

Three edits, all forced by `test-observability-docs.sh`:

1. The `charts/observability` row of the homes table (~line 71): "The 3 dashboards" → "The 5 dashboards".
2. The count sentence near the dashboard table: "The 3 dashboards" → "The 5 dashboards".
3. Two new rows in the dashboard table (~line 317), plus an updated panel count for `voteball-delivery`:

```markdown
| Voteball Business Analytics | `voteball-business` | 6 | What is the poll actually saying? Votes per day, total ballots, top previous and upcoming parties, ballots by league, vote switching. Read from the rollup tables via `grafana_ro`, which cannot see raw `votes`. |
| AWS Infrastructure | `voteball-aws` | 10 | Is the fault below the cluster? RDS CPU, connections, free storage, freeable memory and latency; ALB request count, ELB and target 5xx, target response time; on-demand pod logs. Refresh is pinned to 5m because CloudWatch bills per metric returned — at Grafana's 10s default this dashboard alone costs ≈$12/month for identical information. |
```

Read the real panel counts off the files — `grep -c '"gridPos"' <file>` — and use those numbers, not the ones written here. The test compares against exactly that count.

- [ ] **Step 6: Add a data source section to `docs/observability.md` §2**

A short table under "Where the configuration lives", naming all five data sources, their uid, their auth mechanism and whether they need a plugin. State that only GitHub is network-fetched and what that means at pod start.

- [ ] **Step 7: Verify every dashboard still parses**

```bash
for f in charts/observability/dashboards/*.json; do
  python3 -m json.tool "$f" > /dev/null && echo "ok $f" || echo "BROKEN $f"
done
```

Expected: `ok` for all five.

- [ ] **Step 8: Run both gates**

```bash
scripts/tests/test-observability-docs.sh
scripts/tests/test-grafana-datasources.sh
```

Expected: both PASS. The first proves the doc matches the charts (dashboard count, both new uids, every panel count including the changed `voteball-delivery`); the second proves no dashboard references an undeclared data source uid.

- [ ] **Step 9: Commit**

```bash
git add charts/observability/dashboards/ docs/observability.md
git commit -m "dashboards: vote analytics from Postgres, RDS and ALB from CloudWatch

Two new dashboards and three panels appended to jenkins-delivery, so every
new data source backs something real rather than existing as a connection
nobody queries.

No pull-request panel: this is a solo repo committed straight to master, so
a PR panel would be a permanently-empty box -- exactly the dead connection
the change was meant to avoid.

The AWS dashboard pins refresh to 5m. CloudWatch bills per metric returned,
so at Grafana's 10s default the same fourteen metrics cost roughly \$12/month
instead of \$0.05."
```

---

### Task 7: The seeding script, the security docs, and the plan's own deletion

**Files:**
- Create: `scripts/seed-grafana-secret.sh`
- Modify: `docs/security.md`
- Modify: `docs/maintenance.md`
- Modify: `docs/deploy.md`
- Delete: `docs/superpowers/plans/2026-08-24-grafana-datasources.md` (this file)

- [ ] **Step 1: Write `scripts/seed-grafana-secret.sh`**

Model it on `scripts/seed-jenkins-secret.sh`, whose exit-early behaviour is the right one here — re-running `deploy.sh` must not silently rotate the DB password out from under the live `grafana_ro` role.

Requirements:
- `source scripts/lib/config.sh` (which sets `AWS_PAGER=""` — mandatory; a `--output text` call at a terminal hangs forever without it).
- Generate `db_password` itself if the secret does not already hold one. Never prompt for it: nothing human ever types it.
- Take `GITHUB_TOKEN` from the environment or a silent prompt on `/dev/tty`.
- **Exit early and change nothing if the secret already holds a real `db_password`**, unless `FORCE_ROTATE=1`. Print what it did.
- Under `FORCE_ROTATE=1`, warn that the new password reaches the live role only on the next release (the migrate Job runs as a pre-upgrade hook), so Grafana's PostgreSQL data source will fail to authenticate until then.
- Echo nothing secret and write nothing to disk.

- [ ] **Step 2: Verify the AWS pager guard covers the new script**

Run: `scripts/tests/test-aws-pager-guard.sh`
Expected: PASS. That test asserts **every** script calling the AWS CLI is covered, with an exemption list checked in both directions — so a new script that calls `aws` and does not source `config.sh` fails it. This is the check, not a reminder.

- [ ] **Step 3: Add the seeding step to `docs/deploy.md`**

Document it as a manual operation with its own numbered position, and state plainly that it is **optional**: skipping it leaves `grafana_ro` without a password and the Grafana PostgreSQL and GitHub data sources non-functional, while everything else — including all existing dashboards, alerts and the application itself — works normally.

Do not recite step numbers from memory. Run `grep -nE '^\s*step "' scripts/deploy.sh` and place it accordingly.

- [ ] **Step 4: Update `docs/security.md`**

Add a Grafana data sources subsection covering:
- The `grafana_ro` grant table from Task 5, and why `votes` is REVOKEd (`cookie_token`, `ip_hash`, re-identification in a poll that promises anonymity).
- **The CloudWatch IAM asymmetry, explicitly.** Logs are resource-scoped to `/aws/containerinsights/${cluster_name}/*`; metrics take `Resource: "*"` because AWS publishes no condition key for restricting `GetMetricData` to a namespace. Say it is read-only and deliberate, so a later reader does not mistake it for an oversight and does not "fix" it by breaking the panels.
- Where the two credentials live (`voteball/grafana`), that neither enters git or tfstate, and that the GitHub token never reaches `devops-app`.

- [ ] **Step 5: Add the token expiry to `docs/maintenance.md`**

A fine-grained GitHub PAT expires — GitHub enforces a maximum of one year. Record the actual expiry date next to the EKS standard-support deadline (2027-08-02), which is the only other date-bomb this repo tracks. State the symptom: the GitHub panels start erroring, nothing else changes, and no alert fires.

- [ ] **Step 6: Run the full CI suite one final time**

Run: `scripts/tests/run-ci-suite.sh`
Expected: every test passes. Read the final count line off the output.

- [ ] **Step 7: Delete this plan and commit everything together**

Per the root `CLAUDE.md`: *delete an implementation plan as soon as it is executed — same commit as the last task.* `docs/superpowers/` is the superpowers workflow's default output path and regenerates every time; deleting it once never fixes it, so the deletion happens at the end of every plan.

```bash
git rm -r docs/superpowers
git add scripts/seed-grafana-secret.sh docs/security.md docs/maintenance.md docs/deploy.md
git commit -m "docs: how to seed the Grafana credentials, and what the CloudWatch grant does not cover

The seeding script exits early rather than rewriting an existing password:
re-running deploy.sh must not rotate the credential out from under a live
grafana_ro role, and the new value would not reach the role until the next
release regardless, since the migrate Job is a pre-upgrade hook.

security.md now states the CloudWatch IAM asymmetry outright. Logs are scoped
to this cluster's three log groups; metrics cannot be scoped at all, because
AWS publishes no condition key for restricting GetMetricData to a namespace.
Recorded so it is not later read as an oversight, or 'fixed' into broken
panels.

Deletes the executed implementation plan in the same commit, per CLAUDE.md."
```

- [ ] **Step 8: Push, once the Task 0 hold has cleared**

```bash
git push origin master
```

---

## Deployment (human-gated, not part of the automated task list)

Nothing above reaches the cluster. Applying it needs, in order:

1. **`terraform apply -var-file=voteball.tfvars`** — billed. Creates the secret container, the IRSA role, and re-applies the Grafana release with the plugin, the SA annotation and `envFromSecret`. Grafana restarts.
2. **`scripts/seed-grafana-secret.sh`** — needs the fine-grained GitHub PAT (`Latnook/voteball`, read-only Contents + Metadata + Issues). Must run **after** step 1, since the secret container does not exist before it.
3. **`git push`** to `master`, then `application-ci` → `application-cd` promotes to `release`, and ArgoCD syncs both Applications. The migrate Job sets the `grafana_ro` password on this sync.
4. **Verify:**
   ```bash
   kubectl get externalsecret -n observability grafana-datasources
   kubectl get externalsecret -n devops-app   grafana-db-secret
   kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80
   # then check all five data sources report OK under Connections -> Data sources
   ```
   An ExternalSecret in `SecretSyncedError` means the ESO ARN allowlist entry from Task 1 did not apply.

**Order matters:** ESO copies a secret into the cluster at ExternalSecret creation and then only on `refreshInterval` (1h). Seeding after the ExternalSecret exists means up to an hour before Grafana sees the value — force it with `kubectl annotate externalsecret -n observability grafana-datasources force-sync=$(date +%s) --overwrite`.
