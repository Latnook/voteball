# Submission Evidence Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce current, captured evidence for every deliverable the EKS submission brief mandates, using a full `destroy.sh` → `deploy.sh` cycle as the vehicle.

**Architecture:** Six tasks, ordered by risk rather than by the spec's phase numbering. The zero-risk documentation work lands first so its value is banked before anything is torn down; Phase 0 evidence capture follows as insurance; only then does the destructive cycle run. Evidence is appended to `docs/eks/live-cluster-snapshot.md`, never edited into the frozen 2026-07-20/21 sections.

**Tech Stack:** bash, kubectl, AWS CLI, Terraform (via `scripts/deploy.sh` / `scripts/destroy.sh`), mermaid.

## Global Constraints

- **Do NOT run this in a git worktree.** Terraform state, `terraform/voteball.tfvars` and `backend.hcl` exist only where the command ran; a deleted worktree deletes them. Run everything from `/home/latnook/Documents/Voteball` on `master`.
- **Stream long-running infra commands live.** Never `| tail`, never silence output. When capturing a transcript, `cmd 2>&1 | tee file` returns **tee's** exit code — always set `pipefail` and read `${PIPESTATUS[0]}`, or a failed Terraform run reports success.
- **`deploy.sh` / `destroy.sh` need a TTY.** They prompt for `ADMIN_PASSWORD` and Terraform confirmation on `/dev/tty`. An agent shell has no TTY and the script aborts with *"no terminal is attached"*. Either the **user runs them via `! ./scripts/deploy.sh`**, or `ADMIN_PASSWORD` is exported and `VOTEBALL_AUTO_APPROVE=1` set (which skips the billing confirmation — user's call, not the agent's).
- **`DB_PASS` is read automatically** from `db_password` in `terraform/voteball.tfvars` (`tf_db_password` in `scripts/lib/config.sh`). Do not pass it manually unless overriding.
- **Append, never edit** `docs/eks/live-cluster-snapshot.md`. The 2026-07-20/21 sections are frozen evidence; "correcting" them destroys their value.
- **Never hand-edit the ten sync-managed fields** in `charts/voteball/values.yaml`. `scripts/sync-values-from-tf.sh` owns them.
- **Commit and push as you go.** Never force-push.
- Expected vote count through the whole cycle: **5** (`previous_party_id` 10 ×2, 5, 14, 4).
- Evidence transcripts (large, noisy) live in the scratchpad: `/tmp/claude-1000/-home-latnook-Documents-Voteball/10532548-f86c-4220-94a8-6ddcbccd91c6/scratchpad`. Only distilled excerpts are committed.

---

### Task 1: Add the four missing elements to the architecture diagram

Zero risk, pure documentation, and it closes the most checkable rubric gap. Done first so its value survives any later trouble.

**Files:**
- Modify: `docs/eks/architecture.md:20-32` (the `PRIV` subgraph) and `:53` (the request-flow edge)

**Interfaces:**
- Consumes: nothing.
- Produces: a diagram containing Kubernetes Services, the Ingress object, the managed node group with SPOT capacity, and NetworkPolicy/HPA/PDB. Task 6 references no identifiers from here.

- [ ] **Step 1: Confirm the elements exist before drawing them**

```bash
ls charts/voteball/templates/ | grep -E 'service|ingress|hpa|pdb|networkpolicy'
grep -n 'capacity_type' terraform/eks.tf
```

Expected: `backend-service.yaml`, `frontend-service.yaml`, `ingress.yaml`, `hpa.yaml`, `pdb.yaml`, `networkpolicy.yaml`; and `terraform/eks.tf:41: capacity_type = "SPOT"`.

- [ ] **Step 2: Widen the private-subnet label to name the node group**

Replace line 20 of `docs/eks/architecture.md`:

```
      subgraph PRIV["Private subnets (2 AZs) — EKS nodes/pods"]
```

with:

```
      subgraph PRIV["Private subnets (2 AZs) — EKS managed node group · SPOT · autoscaled"]
```

- [ ] **Step 3: Add Ingress, both Services, and the governance objects inside the namespace**

In the `NS` subgraph, insert these three lines immediately after the `subgraph NS[...]` line (before `fe[...]`):

```
          ing[/"Ingress: voteball<br/>ALB + ACM + WAF via annotations"/]
          fesvc(["Service: frontend<br/>ClusterIP :80"])
          besvc(["Service: backend<br/>ClusterIP :5000"])
```

and insert this line immediately after the `sa[...]` line:

```
          gov["NetworkPolicy: default-deny + allow-app-egress<br/>HPA: frontend + backend<br/>PDB: minAvailable"]
```

- [ ] **Step 4: Route the request flow through the Ingress and Services**

Replace line 53:

```
    alb -->|/*| fe -->|/api/*| be --> rds
```

with:

```
    alb --> ing --> fesvc --> fe
    fe -->|/api/*| besvc --> be --> rds
```

- [ ] **Step 5: Verify the mermaid still parses**

Run:

```bash
grep -c 'subgraph' docs/eks/architecture.md   # expect 5
awk '/^```mermaid/{f=1} f{n++} /^```$/{if(f&&n>1){print "fence closed at line " NR; exit}}' docs/eks/architecture.md
```

Expected: 5 subgraphs, and a closed fence. Then open the file in a markdown previewer (or GitHub) and confirm the graph renders with no parse error. A stray unmatched `[` or `"` is the usual failure.

- [ ] **Step 6: Update the prose to match the picture**

In the "Zones & exposure" section, change the NetworkPolicy sentence so it no longer carries the burden alone:

```
- **Private:** all pods + RDS are in private/DB subnets. Backend/worker/DB have no public entry;
  NetworkPolicies further restrict pod-to-pod (backend reachable only from frontend), and the
  frontend/backend Services are ClusterIP — only the ALB, via the Ingress, reaches in from outside.
```

- [ ] **Step 7: Commit and push**

```bash
git add docs/eks/architecture.md
git commit -m "docs: show Services, Ingress, node group and NetworkPolicy/HPA/PDB in the architecture diagram

The brief enumerates Services and node groups explicitly, and NetworkPolicy,
HPA and PDB are bonus-track items that were built but invisible in the diagram
a reader sees first."
git push origin master
```

If the push is rejected, Jenkins has pushed a tag-bump commit. Run `git pull --rebase origin master` and push again — never force-push.

---

### Task 2: Capture pre-teardown insurance evidence

The load-bearing safety step. After this, the rebuild is upside rather than a single point of failure.

**Files:**
- Create: `<scratchpad>/pre-teardown-2026-07-27.txt` (working capture)
- Modify: `docs/eks/live-cluster-snapshot.md` (append a new dated section)

**Interfaces:**
- Consumes: a healthy running cluster.
- Produces: a committed `## 2026-07-27 — pre-teardown capture` section containing all eight required `kubectl` outputs and the five demo results. Task 6 appends a sibling `post-rebuild` section and compares the vote count against this one.

- [ ] **Step 1: Confirm the cluster is healthy before capturing**

```bash
kubectl get pods -n devops-app
```

Expected: `backend` ×2, `frontend` ×2, `worker` ×1 all `1/1 Running`. If any pod is not Running, stop and diagnose — capturing a degraded cluster as evidence is worse than capturing nothing.

- [ ] **Step 2: Capture the eight required kubectl outputs**

```bash
EVID=/tmp/claude-1000/-home-latnook-Documents-Voteball/10532548-f86c-4220-94a8-6ddcbccd91c6/scratchpad
POD=$(kubectl get pods -n devops-app -l app=backend -o jsonpath='{.items[0].metadata.name}')
{
  for c in "get nodes" "get namespaces" "get pods -n devops-app" \
           "get deployments -n devops-app" "get services -n devops-app" \
           "get ingress -n devops-app"; do
    echo "### kubectl $c"; kubectl $c; echo
  done
  echo "### kubectl describe pod $POD -n devops-app"; kubectl describe pod "$POD" -n devops-app
  echo; echo "### kubectl logs $POD -n devops-app"; kubectl logs "$POD" -n devops-app --tail=25
} 2>&1 | tee "$EVID/pre-teardown-2026-07-27.txt"
```

Expected: all eight sections populated, nodes `Ready`, ingress showing an ALB hostname.

- [ ] **Step 3: Run demos 1–3 (HTTPS, frontend→backend, site→DB)**

```bash
curl -sI https://voteball.latnook.com | head -1
echo | openssl s_client -connect voteball.latnook.com:443 -servername voteball.latnook.com 2>/dev/null \
  | openssl x509 -noout -issuer -dates
curl -sf https://voteball.latnook.com/api/options | head -c 200; echo
curl -sf "https://voteball.latnook.com/api/results?by=all"; echo
```

Expected: `HTTP/2 200`; an Amazon-issued certificate with valid dates; `/api/options` returning leagues/clubs/parties (this proves frontend→backend→RDS in one call, since options come from the database); `/api/results?by=all` reporting **5 votes**.

- [ ] **Step 4: Run demo 4 (S3 + SNS via IRSA) and the NetworkPolicy isolation check**

```bash
kubectl create job --from=cronjob/voteball-backup evidence-backup -n devops-app
kubectl wait --for=condition=complete job/evidence-backup -n devops-app --timeout=180s
aws s3 ls s3://voteball-rollups-590183895228/backups/ --region il-central-1 | tail -2
kubectl exec -n devops-app deploy/worker -- sh -c \
  'wget -qO- --timeout=5 http://backend:5000/health || echo BLOCKED'
```

Expected: the job completes, a new `.sql.gz` object appears, and the worker→backend probe prints `BLOCKED` (the NetworkPolicy denying it is the demo succeeding, not failing).

- [ ] **Step 5: Run demo 5 (pod restart, site stays up)**

Open two shells. In the first, poll continuously:

```bash
while true; do
  printf '%s %s\n' "$(date +%T)" "$(curl -so /dev/null -w '%{http_code}' https://voteball.latnook.com/)"
  sleep 1
done
```

In the second, delete one frontend replica:

```bash
kubectl delete pod -n devops-app "$(kubectl get pods -n devops-app -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl get pods -n devops-app -l app=frontend -w
```

Expected: the poller shows an **unbroken run of `200`s** across the deletion; the second shell shows one pod `Terminating` while the other stays `Running`, then a replacement reaching `1/1`. Stop both loops with Ctrl-C and save the poller output — the unbroken 200s **are** the deliverable.

- [ ] **Step 6: Append the captured evidence to the snapshot doc**

Append to the **end** of `docs/eks/live-cluster-snapshot.md` (do not touch anything above):

````markdown
---

## 2026-07-27 — pre-teardown capture

_Captured from the cluster that had been running since the 2026-07-21 build, immediately before a
deliberate `destroy.sh` → `deploy.sh` cycle. Frozen like every section above it._

[paste the eight kubectl outputs from Step 2, each under its own `### kubectl ...` heading in a fenced block]

### Demos

[paste the Step 3-5 results: HTTPS status line and certificate issuer/dates, /api/options excerpt,
/api/results?by=all showing 5 votes, the backup object listing, the BLOCKED NetworkPolicy probe,
and the unbroken run of 200s spanning the frontend pod deletion]
````

- [ ] **Step 7: Verify nothing above the append point changed**

```bash
git diff --stat docs/eks/live-cluster-snapshot.md
git diff docs/eks/live-cluster-snapshot.md | grep '^-' | grep -v '^---' | head
```

Expected: insertions only. **Any deleted line is a bug** — the earlier sections are frozen evidence.

- [ ] **Step 8: Commit and push**

```bash
git add docs/eks/live-cluster-snapshot.md
git commit -m "docs: capture pre-teardown cluster evidence (2026-07-27)

All eight required kubectl outputs plus the five demos, captured from the
running cluster before a deliberate destroy/rebuild cycle so the rebuild is
not the only source of submission evidence."
git push origin master
```

---

### Task 3: Pre-flight checks

Verifies the things whose absence only hurts *after* a ~15-minute billed apply.

**Files:** none modified — verification only.

**Interfaces:**
- Consumes: Task 2's confirmed vote count.
- Produces: a go/no-go decision. Every check must pass before Task 4 runs.

- [ ] **Step 1: Confirm values.yaml on master carries a real image tag**

```bash
git fetch origin && git status -sb | head -1
grep -n '  tag:' charts/voteball/values.yaml
git show origin/master:charts/voteball/values.yaml | grep -n '  tag:'
```

Expected: local and `origin/master` agree, and the tag is a git SHA (e.g. `548241e`), **not** `FILLED-BY-SYNC` or `latest`. ArgoCD deploys from `master`; a placeholder here is what produced the 2026-07-20 `ImagePullBackOff`.

- [ ] **Step 2: Confirm the tagged image actually exists in ECR**

```bash
./scripts/sync-values-from-tf.sh --check
```

Expected: exit 0. This validates the ten managed fields against Terraform outputs *and* verifies `image.tag` names an image present in ECR.

- [ ] **Step 3: Confirm the database password is readable from tfvars**

```bash
grep -c '^db_password' terraform/voteball.tfvars
```

Expected: `1`. `deploy.sh` reads it via `tf_db_password`, so `DB_PASS` never needs passing by hand and cannot drift from what Terraform sets on RDS.

- [ ] **Step 4: Record the pre-teardown vote count**

```bash
curl -sf "https://voteball.latnook.com/api/results?by=all"
```

Expected: 5 votes. Write the exact JSON down — Task 6 compares against it.

- [ ] **Step 5: Confirm all three backup layers are current**

```bash
aws rds describe-db-instances --region il-central-1 \
  --query 'DBInstances[0].[LatestRestorableTime,BackupRetentionPeriod]' --output text
aws s3 ls s3://voteball-rollups-590183895228/backups/ --region il-central-1 | tail -1
grep -n 'skip_final_snapshot' terraform/database.tf
```

Expected: `LatestRestorableTime` within the last ~10 minutes with retention `7`; an S3 dump from today; and `skip_final_snapshot = false` at `terraform/database.tf:80` so teardown takes a fresh snapshot.

- [ ] **Step 6: Decide how the TTY-bound scripts will run**

`deploy.sh` and `destroy.sh` prompt on `/dev/tty`. Choose one and record it:

- **User-run (recommended):** the user executes `! ./scripts/destroy.sh` and `! ./scripts/deploy.sh` so both the Terraform billing confirmation and the `ADMIN_PASSWORD` prompt work normally.
- **Agent-run:** requires `ADMIN_PASSWORD` exported and `VOTEBALL_AUTO_APPROVE=1`, which **skips the confirmation before Terraform touches billed resources**. Only with explicit user instruction.

---

### Task 4: Destroy, captured as evidence

**Files:**
- Create: `<scratchpad>/destroy-2026-07-27.log`

**Interfaces:**
- Consumes: Task 3's go decision.
- Produces: a teardown transcript and a fresh final RDS snapshot named `voteball-eks-db-final-<timestamp>`, which Task 5 restores from.

- [ ] **Step 1: Run the teardown, streamed and captured**

```bash
EVID=/tmp/claude-1000/-home-latnook-Documents-Voteball/10532548-f86c-4220-94a8-6ddcbccd91c6/scratchpad
set -o pipefail
./scripts/destroy.sh 2>&1 | tee "$EVID/destroy-2026-07-27.log"
echo "destroy.sh exit=${PIPESTATUS[0]}"
```

Expected: exit `0`, and all six steps appearing in order — `1/6 Removing the ArgoCD Application`, `2/6 Removing the Ingress`, `3/6 Waiting for the ALB to de-provision`, `4/6 Uninstalling the Helm release`, `5/6 Removing this cluster's DNS records`, `6/6 Destroying AWS infrastructure`.

**The `PIPESTATUS` echo is not optional.** `tee` exits 0 even when the piped command fails, so without it a failed Terraform destroy reports success.

- [ ] **Step 2: If destroy hangs on a helm_release**

If Terraform stalls uninstalling a `helm_release` with `context deadline exceeded`, Helm cannot cleanly uninstall while the cluster is being deleted. Remove it from state and re-run — it dies with the cluster anyway:

```bash
terraform -chdir=terraform state rm '<the stuck helm_release address>'
./scripts/destroy.sh
```

- [ ] **Step 3: If subnet deletion retries for 10+ minutes**

`DependencyViolation` on `DeleteSubnet` means the VPC CNI left detached ENIs. `destroy.sh` runs a reaper in the background, but if it persists, see the manual command in `docs/deploy.md` troubleshooting. This is expected behaviour, not a failure.

- [ ] **Step 4: Verify the final snapshot was actually taken**

```bash
aws rds describe-db-snapshots --snapshot-type manual --region il-central-1 \
  --query 'reverse(sort_by(DBSnapshots,&SnapshotCreateTime))[:2].[DBSnapshotIdentifier,SnapshotCreateTime,Status]' \
  --output text
```

Expected: a **new** `voteball-eks-db-final-<today's timestamp>` at the top, `available` (or `creating`). If the newest is still `voteball-eks-db-final-20260721192838`, the final snapshot did not happen — **stop**, and do not proceed to Task 5 until the votes are accounted for. The S3 dump from Task 3 Step 5 is the fallback.

- [ ] **Step 5: Confirm the cluster is gone**

```bash
aws eks list-clusters --region il-central-1 --output text
```

Expected: no `voteball` entry.

---

### Task 5: Rebuild, captured as evidence

**Files:**
- Create: `<scratchpad>/deploy-2026-07-27.log`
- Modify: `charts/voteball/values.yaml` (by `sync-values-from-tf.sh`, via `deploy.sh` step 6 — never by hand)

**Interfaces:**
- Consumes: the final snapshot from Task 4.
- Produces: a running cluster with restored votes, and a deploy transcript. Task 6 captures evidence from it.

- [ ] **Step 1: Run the deploy, streamed and captured**

Per Task 3 Step 6, either the user runs `! ./scripts/deploy.sh`, or:

```bash
EVID=/tmp/claude-1000/-home-latnook-Documents-Voteball/10532548-f86c-4220-94a8-6ddcbccd91c6/scratchpad
set -o pipefail
./scripts/deploy.sh 2>&1 | tee "$EVID/deploy-2026-07-27.log"
echo "deploy.sh exit=${PIPESTATUS[0]}"
```

Expected: exit `0`, with all eight steps in order — `1/8 Resolving the newest DB snapshot`, `2/8 Building AWS infrastructure`, `3/8 Seeding app credentials into Secrets Manager`, `4/8 Pointing kubectl at the cluster`, `5/8 Building and pushing container images`, `6/8 Syncing values.yaml from Terraform outputs`, `7/8 Installing the app`, `8/8 Bootstrapping ArgoCD`.

Step 1 should name the snapshot Task 4 created. **Note:** step 3 reissues `ADMIN_SESSION_SECRET`, invalidating any live admin session — expected, not a fault.

- [ ] **Step 2: Commit whatever the sync script rewrote**

```bash
git diff --stat charts/voteball/values.yaml
git diff charts/voteball/values.yaml
```

The ACM certificate ARN changes on every rebuild, and RDS endpoint / WAF ARN / IRSA ARNs may too. If there is a diff:

```bash
git add charts/voteball/values.yaml
git commit -m "chore: sync values.yaml after the 2026-07-27 rebuild"
git push origin master
```

ArgoCD deploys from `master`, so an unpushed change here means the cluster and git disagree.

- [ ] **Step 3: Wait for all pods to be Running**

```bash
kubectl get pods -n devops-app -w
```

Expected: `backend` ×2, `frontend` ×2, `worker` ×1 reaching `1/1 Running`, plus a `voteball-migrate-*` pod reaching `Completed`. `ImagePullBackOff` means `values.yaml` on `master` carried a tag with no matching ECR image — re-check Task 3 Step 2.

- [ ] **Step 4: Re-confirm the SNS email subscription — the known silent failure**

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$(terraform -chdir=terraform output -raw sns_topic_arn)" \
  --region il-central-1 --query 'Subscriptions[].[Protocol,SubscriptionArn]' --output text
```

Expected: a real subscription ARN. **`PendingConfirmation` means no alert will ever arrive** — check the inbox and click the confirmation link, then re-run. This has already failed silently once (`Published: 2, Delivered: 0`, `docs/production-readiness.md` §6), and it is invisible precisely because it only matters when something else is already wrong.

- [ ] **Step 5: Verify the votes survived the restore**

```bash
curl -sf "https://voteball.latnook.com/api/results?by=all"
```

Expected: **5 votes**, matching Task 3 Step 4 byte for byte (`previous_party_id` 10 ×2, 5, 14, 4). A different count means the wrong snapshot was restored — investigate before capturing evidence.

---

### Task 6: Capture post-rebuild evidence and close out

**Files:**
- Modify: `docs/eks/live-cluster-snapshot.md` (append a second dated section)
- Modify: `README.submission.md:113-115` (point the demo claims at the evidence)

**Interfaces:**
- Consumes: the rebuilt cluster from Task 5.
- Produces: the final committed evidence set satisfying all five spec success criteria.

- [ ] **Step 1: Re-capture the eight kubectl outputs from the new cluster**

Identical to Task 2 Step 2, writing to `$EVID/post-rebuild-2026-07-27.txt`:

```bash
EVID=/tmp/claude-1000/-home-latnook-Documents-Voteball/10532548-f86c-4220-94a8-6ddcbccd91c6/scratchpad
POD=$(kubectl get pods -n devops-app -l app=backend -o jsonpath='{.items[0].metadata.name}')
{
  for c in "get nodes" "get namespaces" "get pods -n devops-app" \
           "get deployments -n devops-app" "get services -n devops-app" \
           "get ingress -n devops-app"; do
    echo "### kubectl $c"; kubectl $c; echo
  done
  echo "### kubectl describe pod $POD -n devops-app"; kubectl describe pod "$POD" -n devops-app
  echo; echo "### kubectl logs $POD -n devops-app"; kubectl logs "$POD" -n devops-app --tail=25
} 2>&1 | tee "$EVID/post-rebuild-2026-07-27.txt"
```

- [ ] **Step 2: Re-run all five demos on the new cluster**

Repeat Task 2 Steps 3–5 verbatim against the rebuilt cluster. Expected results are identical, with new pod names, a new ALB hostname and a newly issued ACM certificate.

- [ ] **Step 3: Append the post-rebuild section**

Append to the end of `docs/eks/live-cluster-snapshot.md`:

````markdown
---

## 2026-07-27 — post-rebuild capture

_Captured from a cluster built by `./scripts/deploy.sh` immediately after `./scripts/destroy.sh`,
restoring RDS from the final snapshot that teardown produced. Demonstrates the full delete/rebuild
lifecycle: the vote count below matches the pre-teardown section above._

[paste the eight kubectl outputs from Step 1 and the five demo results from Step 2]

### Lifecycle evidence

- Teardown: six ordered steps, ALB de-provisioned before `terraform destroy`, final snapshot
  `voteball-eks-db-final-<timestamp>` created.
- Rebuild: eight ordered steps, RDS restored from that snapshot.
- **Votes before: 5. Votes after: 5.**
````

- [ ] **Step 4: Verify the append touched nothing above it**

```bash
git diff docs/eks/live-cluster-snapshot.md | grep '^-' | grep -v '^---' | head
```

Expected: **no output.** Any deleted line means a frozen section was edited.

- [ ] **Step 5: Point the README's demo claims at the captured evidence**

`README.submission.md:113-115` currently asserts the demos. Replace the **Demos shown** paragraph so each claim cites evidence:

```markdown
**Demos shown** — captured output in
[`docs/eks/live-cluster-snapshot.md`](docs/eks/live-cluster-snapshot.md), pre-teardown and again on
the rebuilt cluster: HTTPS with a valid ACM certificate; frontend→backend→RDS (`/api/options`
returning seeded data); NetworkPolicy isolation (worker→backend probe returns `BLOCKED`); S3/SNS via
IRSA (backup object written, Alertmanager→SNS delivery); and pod-restart-stays-up (an unbroken run of
HTTP 200s spanning a deliberate `kubectl delete pod` of a frontend replica). The same document records
a full `destroy.sh` → `deploy.sh` cycle with the vote count preserved across it (5 before, 5 after).
```

- [ ] **Step 6: Check the plan's success criteria against reality**

```bash
grep -c 'subgraph' docs/eks/architecture.md                      # 5
grep -c '^## 2026-07-27' docs/eks/live-cluster-snapshot.md       # 2
grep -c '### kubectl' docs/eks/live-cluster-snapshot.md          # >= 16
curl -sf "https://voteball.latnook.com/api/results?by=all"       # 5 votes
```

All four must pass. If any fails, fix it before committing rather than noting it as known-broken.

- [ ] **Step 7: Commit and push**

```bash
git add docs/eks/live-cluster-snapshot.md README.submission.md
git commit -m "docs: capture post-rebuild evidence for the 2026-07-27 destroy/rebuild cycle

Full lifecycle evidenced end to end: six-step teardown with a final RDS
snapshot, eight-step rebuild restoring from it, and 5 votes preserved across
the cycle. README demo claims now cite captured output rather than asserting."
git push origin master
```

---

## Self-review

**Spec coverage.** Phase 0 → Task 2. Phase 1 → Task 3. Phase 2 → Task 4. Phase 3 → Task 5. Phase 4 → Tasks 1 and 6 (the diagram is pulled forward to Task 1 as the zero-risk deliverable; the spec's Phase 4 placement is otherwise preserved). All five success criteria are verified in Task 6 Step 6. The spec's five demos each appear in Task 2 Steps 3–5 and are repeated in Task 6 Step 2.

**Deviation from the spec, stated deliberately:** the spec orders the diagram work last; this plan runs it first. Rationale — it is pure documentation with no dependency on cluster state, and banking it before a destructive cycle strictly dominates. No other resequencing.

**Placeholder scan.** No TBD/TODO. The two `[paste ...]` markers in Tasks 2 and 6 are transcription instructions for output captured earlier in the same task, not deferred decisions.

**Consistency.** `$EVID` resolves to the same scratchpad path in Tasks 2, 4, 5 and 6. The vote count (5) and its distribution are stated identically in the Global Constraints and Tasks 2, 3, 5 and 6. Step names quoted in Tasks 4 and 5 are copied verbatim from `scripts/destroy.sh` and `scripts/deploy.sh`. `docs/production-readiness.md` §6 is the SNS/alerting section.
