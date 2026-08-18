# Observability Gates and Drills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the pipeline defend the observability it now has — a CI stage that fails the build on
the mistakes this project has actually made, a CD gate that refuses a release the metrics say is bad,
and four drills proving the whole thing works when something breaks.

**Architecture:** Two new shell scripts under `scripts/ci/`, each with an offline test, wired into
`Jenkinsfile-ci` and `Jenkinsfile-cd`. Then four deliberate failures against the live system, captured
as evidence.

**Tech Stack:** Bash, promtool, Python 3, Jenkins declarative pipeline, PromQL, kubectl.

**Spec:** `docs/design/2026-08-17-observability-design.md` — sections 11, 12, 13.

## Global Constraints

- **Every pipeline decision must be testable without running the pipeline.** That is the standing rule
  in this repo: each script gets an offline test using the same stub pattern as
  `scripts/tests/test-ci-guards.sh` (`CI_STUB_*`) and `scripts/tests/test-argocd-sync-wait.sh`
  (`ARGOCD_STUB_*`).
- **`scripts/tests/run-ci-suite.sh` fails if a test file is in neither `PYTHON_GROUP` nor `GIT_GROUP`
  nor `SKIP`.** Adding a test forces a one-line decision. Determine a test's group by RUNNING IT in a
  bare container, never by reading it — build #7 established that the expensive way.
- **`check-jenkinsfile-shell.sh` extracts every `sh '''…'''` body and runs `bash -n` on it**, and
  rejects apostrophes, backticks and double quotes inside shell comments in those blocks. Run it after
  any Jenkinsfile edit.
- **Anything that can fail after CD's Promote stage is a rollback trigger.** Promote is the point of no
  return. A too-tight timeout or an over-strict check in the back half does not make the build noisier
  — it fires an automatic, production-affecting rollback of a deploy that was fine.
- CI never deploys and holds no cluster credentials. CD never builds.
- Commit with explicit paths (`git commit -m "…" -- <paths>`), never `git add -A`; the repo owner works
  in this tree. Never force-push. No `Claude-Session:` trailer.
- **Tasks 5-8 are the drills. Each one deliberately breaks something and each stops for approval.**

## Current state (verified 2026-08-18)

- `Jenkinsfile-ci` stages: Guard → Validation → Script tests → Lint → Tests → Resolve tag → Already
  built? → Build → Trivy → Push → Publish Metadata → Trigger CD.
- `Jenkinsfile-cd` stages: Checkout → Input Validation → Manifest Validation → Promote → Deploy →
  Rollout → Verify → Smoke Test, with rollback in `post > failure` gated on `env.PROMOTE_SHA`.
- `scripts/ci/` holds `images-exist.sh`, `previous-tag.sh`, `rollback-target.sh`,
  `should-skip-build.sh`, `smoke-test.sh`, `validate-repo.sh`.
- The `ci` → `observability` egress rule on 9090 already exists, so the CD gate can reach Prometheus.
- Live metrics the gate will query: `voteball:availability:ratio5m`, `voteball:latency:p95_5m`,
  `voteball:journey_requests:rate5m`, and `up`.

---

### Task 1: Close the two deferred SLI gaps

**Files:**
- Modify: `charts/voteball/templates/prometheusrule.yaml`

These were recommended by the previous plan's final review and deliberately deferred. Do them first,
because Task 2's CI check and Task 3's gate both reason about the SLIs.

- [ ] **Step 1: Make `journey_errors` default to zero**

Add `or vector(0)` to `voteball:journey_errors:rate5m`, so availability computes arithmetically
whenever traffic exists instead of riding the outer `or vector(1)`. Comment it: zero errors is a real
value, absence is not, and the outer fallback should be reserved for genuinely no traffic.

- [ ] **Step 2: Alert when the SLI itself disappears**

This is the one that matters. Both SLI rules share the same `endpoint` filter, so anything that breaks
the label — exactly what happened on 2026-08-18, when a target label silently renamed `endpoint` to
`exported_endpoint` — empties BOTH, and `voteball:availability:ratio5m` then reports a confident `1`
from its fallback. No threshold on availability can ever catch that, because the number looks perfect.

Add to the `voteball.slo` group:

```yaml
        - alert: VoteballSLIAbsent
          # The SLI itself has gone missing. This is NOT "the site is down" -- it is "we can no longer
          # tell". voteball.latnook.com is a public site with steady traffic, so journey_requests
          # having no value at all means the instrumentation, the scrape, or the label set broke.
          #
          # It exists because availability CANNOT self-report this failure: with the numerator and
          # denominator both empty, `or vector(1)` returns a confident 1 -- indistinguishable from a
          # perfect score. That is not hypothetical; it shipped on 2026-08-18 and a total outage would
          # have rendered as green 100%.
          expr: absent(voteball:journey_requests:rate5m)
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "The availability SLI has no data -- monitoring is blind, not healthy"
            description: "voteball:journey_requests:rate5m returned nothing for 15 minutes. Availability may still read 100%; do not trust it. Check that voteball_http_requests_total still carries an `endpoint` label with real route values rather than a target label."
            runbook_url: "https://github.com/Latnook/voteball/blob/master/docs/runbooks/VoteballSLIAbsent.md"
```

- [ ] **Step 3: Write its runbook**

`docs/runbooks/VoteballSLIAbsent.md`, in the same four-question shape as the other 14: what this means
(we cannot measure availability; the number you see is a fallback), what to check first
(`count by (endpoint) (voteball_http_requests_total)` — real route values or a single `http`?;
`label_values(exported_endpoint)`), how to fix (a target label is shadowing the app's; `honorLabels`
on the ServiceMonitor), and when to escalate.

- [ ] **Step 4: Validate and commit**

```bash
helm template voteball charts/voteball --namespace devops-app > /tmp/vb.yaml
python3 -c "
import yaml
docs=[d for d in yaml.safe_load_all(open('/tmp/vb.yaml')) if d and d.get('kind')=='PrometheusRule']
print(yaml.safe_dump({'groups':[g for d in docs for g in d['spec']['groups']]}))" > /tmp/rules.yaml
docker run --rm --entrypoint promtool -v /tmp/rules.yaml:/rules.yaml prom/prometheus:latest check rules /rules.yaml
```

Expected `SUCCESS`. Then push and confirm live that `VoteballSLIAbsent` loaded with `health: ok` and is
**not** firing (the SLI is present), and that `voteball:journey_errors:rate5m` now returns 0 rather
than empty.

---

### Task 2: `scripts/ci/validate-observability.sh`

**Files:**
- Create: `scripts/ci/validate-observability.sh`
- Create: `scripts/tests/test-validate-observability.sh`
- Modify: `scripts/tests/run-ci-suite.sh`

**Interfaces:**
- Produces: a script exiting non-zero on any observability-config mistake, callable as
  `scripts/ci/validate-observability.sh`

The four checks, in order of how much they have actually cost this project:

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# CI gate for observability configuration. Every check here corresponds to a mistake this repository
# has actually made, and each one failed SILENTLY when it was made -- the object applied cleanly, the
# dashboard rendered, the rule appeared in `kubectl get`, and nothing worked.
#
# Runs offline against rendered chart output. No cluster, no credentials.
set -euo pipefail

CHARTS="${CHARTS:-charts/voteball charts/observability}"
RENDER_DIR="$(mktemp -d)"
trap 'rm -rf "$RENDER_DIR"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Everything the Prometheus operator must SEE carries the release label.
#    Without it the object is created, `kubectl get` lists it, and Prometheus ignores it forever.
# 2. Every ServiceMonitor endpoint names a port that exists on the Service it selects.
#    A port name typo yields a monitor with zero targets, which looks identical to a healthy one.
# 3. No application metric label may collide with a prometheus-operator TARGET label.
#    On 2026-08-18 `endpoint` collided: the operator's target label won, the app's own label was
#    renamed `exported_endpoint`, every SLI matched nothing, and availability reported a constant 1
#    from its fallback. A total outage would have shown as green 100%.
# 4. Every dashboard parses, has a uid and title, and every panel has a non-empty query.
```

Write the implementation to match. The reserved target labels for check 3 are `endpoint`, `job`,
`namespace`, `pod`, `service`, `container`, `instance` — a `ServiceMonitor` without `honorLabels: true`
scraping a target whose `/metrics` emits any of those is the failure. Detect it from rendered output
plus the service's own metric names where available; where you cannot see the app's label set from the
chart alone, at minimum assert that any ServiceMonitor **without** `honorLabels: true` is flagged for
review, and let `honorLabels: true` satisfy the check.

Include `promtool check rules` over the extracted PrometheusRule groups when `promtool` is available,
and skip with a loud message when it is not — a skipped check must never read as a passing one.

- [ ] **Step 2: Write the offline test**

`scripts/tests/test-validate-observability.sh`, following `scripts/tests/test-validate-repo.sh`'s
shape: build fixture directories with deliberately broken renders and assert the script rejects each,
plus one good fixture it accepts. Cover all four checks. **Each negative fixture must fail for the
reason under test** — assert on the error message, not just the exit code, or a script that rejects
everything would pass the suite.

- [ ] **Step 3: Classify the test**

Add it to `PYTHON_GROUP`, `GIT_GROUP` or `SKIP` in `scripts/tests/run-ci-suite.sh`. Determine which by
RUNNING it in a bare container (`python:3.12-slim` has python3 and no git; the jnlp image has git and
no python3). Do not decide by reading it — several tests mention tools only in comments.

```bash
bash scripts/tests/run-ci-suite.sh          # must pass, and must not report an unclassified file
bash scripts/ci/validate-observability.sh   # must pass against the real charts
```

- [ ] **Step 4: Commit**

---

### Task 3: `scripts/ci/monitoring-gate.sh`

**Files:**
- Create: `scripts/ci/monitoring-gate.sh`
- Create: `scripts/tests/test-monitoring-gate.sh`
- Modify: `scripts/tests/run-ci-suite.sh`

- [ ] **Step 1: Write the script**

Contract:
- Reads `PROM_URL` (default `http://kube-prometheus-stack-prometheus.observability:9090`),
  `GATE_BASE_URL`, `GATE_REQUESTS` (default 40), `GATE_MAX_ERROR_RATIO` (default 0.01),
  `GATE_MAX_P95_SECONDS` (default 1.0), `GATE_MIN_SAMPLES` (default 20).
- Generates `GATE_REQUESTS` requests against the public URL's journey endpoints, spread over time so
  they land in one scrape window.
- Waits for at least one scrape interval so the counters reflect that traffic.
- Then asks Prometheus three questions: are all declared targets up; is the error ratio under the
  threshold; is p95 under the threshold.
- **Passes with a loud warning when fewer than `GATE_MIN_SAMPLES` requests were observed and all
  targets are up.** This is deliberate and load-bearing: anything failing after Promote triggers a
  rollback, so a gate that failed on missing data would roll back healthy releases whenever the metrics
  pipeline hiccuped. A genuinely broken scrape is caught by the targets-up check, which needs no
  traffic.
- Every query goes through `PROM_STUB_QUERY_CMD` when set, so the test can drive it offline.

- [ ] **Step 2: Write the offline test**

`scripts/tests/test-monitoring-gate.sh`, stubbing Prometheus via `PROM_STUB_QUERY_CMD`. Cover: all
healthy → pass; a target down → fail; error ratio over threshold → fail; p95 over threshold → fail;
fewer than `GATE_MIN_SAMPLES` with targets up → **pass with warning**; and Prometheus unreachable →
fail (that is not "insufficient data", it is a broken gate). Assert on messages, not just exit codes.

- [ ] **Step 3: Classify the test and run the suite**

- [ ] **Step 4: Commit**

---

### Task 4: Wire both into the pipelines

**Files:**
- Modify: `Jenkinsfile-ci`, `Jenkinsfile-cd`

- [ ] **Step 1: CI — add an Observability Validation stage**

Insert after the existing `Validation` stage, before `Lint`. It calls
`scripts/ci/validate-observability.sh`. Keep CI's contract: no cluster access, no credentials, fails
the build on a bad config rather than warning.

- [ ] **Step 2: CD — add a Monitoring Gate stage after Smoke Test**

It runs in the `deploy` container (which has kubectl and network access to the cluster), calls
`scripts/ci/monitoring-gate.sh` with `GATE_BASE_URL="https://$APP_DOMAIN"`, and fails the stage on a
gate failure — which trips the existing `post > failure` rollback, since `PROMOTE_SHA` is set by then.

Comment it with the reasoning that makes it safe: it runs only after ArgoCD reports Healthy, so the old
pods are gone and every request it measures is served by the new build — which is what lets the gate
attribute what it sees to this release without per-version metric filtering.

- [ ] **Step 3: Verify the Jenkinsfiles still parse**

```bash
bash scripts/tests/check-jenkinsfile-shell.sh
```

This extracts every `sh '''…'''` body, applies Groovy's own single-quoted-string unescaping, and runs
`bash -n`. It exists because on 2026-08-04 a shell script that did not parse passed the Jenkins
linter, this repo's structural check, and manual review.

- [ ] **Step 4: Commit, then watch the next real build**

Pushing this triggers `application-ci`. Watch it through to `application-cd` and confirm both new
stages run and pass on a healthy release. **A gate that fails on a good deploy rolls production back**,
so this first live run is the real test. If it fails, read the gate's output before assuming the deploy
was bad.

---

### Task 5: Drill — controlled 5xx  ⚠ STOPS FOR APPROVAL

**This one affects the live site.** The repo owner approved this class of drill on 2026-08-17 in
preference to a simulated endpoint, but confirm the timing before running it.

- [ ] **Step 1: Establish the baseline** — record availability, error rate and the alert state.

- [ ] **Step 2: Break the database path WITHOUT restarting pods**

Withdraw the RDS egress rule from `allow-app-egress` (pause ArgoCD auto-sync first, or it will heal
within seconds). Do NOT change `DB_HOST` or any env var: that triggers a rollout, new pods fail to boot
in `gunicorn.conf.py`'s `on_starting` hook, the rollout stalls, the OLD healthy pods keep serving, and
you get no 5xx at all — verified reasoning, do not retry it.

- [ ] **Step 3: Capture the chain** — `voteball_db_errors_total` rising, the 5xx ratio, the dashboard,
`VoteballHighErrorRate` firing, and **the SNS email arriving**. Note that pods stay `Ready` throughout;
that is the point of the drill.

- [ ] **Step 4: Recover by re-enabling ArgoCD self-heal** — GitOps performs the fix, which is itself
part of the evidence. Confirm the alert resolves.

---

### Task 6: Drill — pod readiness failure  ⚠ STOPS FOR APPROVAL

Delete one backend pod (2 replicas + a PDB, so the site stays up). Capture restart and rollout metrics
moving, service availability not dipping, and the alert behaviour. Lowest-risk of the four.

---

### Task 7: Drill — Jenkins agent loss  ⚠ STOPS FOR APPROVAL

Kill an agent pod mid-build. Capture the queue and agent metrics moving on the Jenkins & Delivery
dashboard, `JenkinsQueueStuck` behaviour, and that the website is untouched throughout.

---

### Task 8: Drill — failed release caught by the monitoring gate  ⚠ STOPS FOR APPROVAL

The drill the gate exists for. Deploy a build that is **slow, not broken**: add an artificial delay to
a journey endpoint so the smoke test still passes (it checks for 200) and only the gate's p95 check
fails. Capture the gate failing, the automatic rollback running, and the site recovering.

Build it with `scripts/build-push-ecr.sh` from a clean tree so the tag honestly describes the image.
Revert the delay immediately afterwards.

---

### Task 9: Evidence, docs, and close out

- [ ] Write `docs/eks/evidence/2026-08-18-gates-and-drills.txt` covering all four drills and both new
  pipeline stages, in the format of the existing evidence files.
- [ ] Add a "Verification outcome" entry to the design doc recording what the drills actually showed —
  including anything that did not behave as designed.
- [ ] Update `docs/cicd.md` with the two new stages and their failure modes.
- [ ] Update `README.submission.md`'s observability section with the drills.
- [ ] Delete this plan in its own final commit.
