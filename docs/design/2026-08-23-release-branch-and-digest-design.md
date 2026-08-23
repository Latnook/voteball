# Release branch + digest-pinned deployment

**Date:** 2026-08-23
**Supersedes:** the "ArgoCD watches `master`" decision in
`2026-08-04-cicd-split-design.md` §4. That document's text stays as a dated record of why the split
was built the way it was; this file records why its branch model changed.

## Why

Two findings from the 2026-08-23 teacher reviews, which turn out to have one shared root cause:

- **Task 4 finding P1 — the queued-build race.** A source commit pushed while `application-ci` is
  busy can be hidden behind `application-cd`'s later `[skip ci]` promotion commit. The queued build
  checks out the branch **tip**, not the commit that triggered it; the tip carries the marker, the
  Guard skips, and the triggering commit is never built by that build or any later one. Recorded
  live on 2026-08-21 (`docs/cicd.md`, "A commit is on `master`, CI shows `NOT_BUILT`"). Recovery is
  manual and the failure reports as `NOT_BUILT`, which reads like a pass.
- **Task 4 finding P2 — ungated chart changes.** Every stage gate in `Jenkinsfile-ci` is
  `changeset 'services/**'`, so a commit touching only `charts/voteball` skips CI entirely. ArgoCD's
  `syncPolicy.automated` then applies it directly. Manifest Validation, the CD job, the smoke test,
  the monitoring gate and automatic rollback are all bypassed for exactly the class of change most
  able to break the cluster.

The shared root cause is that **`master` is simultaneously the development branch and the deployment
branch.** CD has to push to the branch CI watches (creating the race), and anything a human pushes to
that branch deploys itself (creating the gap).

A third finding is resolved in the same pass because it lands in the same files:

- **Task 4 finding P2 — deploy by digest.** Workloads deploy by tag. Tags are immutable in ECR so the
  practical risk is low, but the execution identity should be the digest.

## Decisions

### 1. `master` develops, `release` deploys

| Branch | Written by | Read by | Contains |
|---|---|---|---|
| `master` | humans, `deploy.sh` step 9 | `application-ci` webhook | everything |
| `release` | `application-cd` only | both ArgoCD Applications | the tree of a promoted `master` commit, with image digests pinned |

Both ArgoCD Applications (`voteball` and `observability`) move their `targetRevision` from `master`
to `release`. Nothing else about ArgoCD changes — same AppProjects, same `selfHeal`, same
ServerSideApply.

**This removes the queue race at the root rather than working around it.** CD no longer pushes to
`master`, so CD's own commit can no longer appear as the tip of the branch CI watches, and no source
commit can hide behind it. The Guard stage stays (see decision 5), but as defence in depth rather
than as the only thing standing between the pipeline and an unbounded build loop.

**It also closes the chart gap**, because a chart edit on `master` now reaches the cluster only by
passing through `application-cd` — the same validate → promote → sync → verify → smoke → monitoring
gate → rollback path an image change takes. There is no longer a way to reach `devops-app` by pushing
to a branch.

### 2. `release` is built by `read-tree`, not by merge, and is never force-pushed

CD's Promote stage assembles each release commit as:

```
git checkout -B release origin/release      # keep release's history
git read-tree -u --reset "$PROMOTE_SHA"     # tree := master@PROMOTE_SHA, exactly
<rewrite the image block in charts/voteball/values.yaml>
git commit -m "release: <short-sha> (tag <tag>)"
git push origin release
```

`read-tree --reset` makes the working tree and index identical to the promoted `master` commit while
leaving `HEAD` on `release`. Three properties follow, and all three are the reason this is not a
`git merge`:

- **No conflict is possible, ever.** A merge would conflict on `values.yaml`'s image block on every
  single deploy — release holds the old tag, master holds whatever was last synced — and a CD stage
  that can stop for a conflict is a CD stage that will.
- **History is append-only, so `--force` is never needed.** The repo's no-force-push rule applies to
  `release` exactly as it does to `master`. A reset-and-force model would also destroy the history
  `scripts/ci/previous-tag.sh` reads to find the rollback target.
- **Every release commit's tree is a real `master` tree plus the pins.** `git diff master release`
  shows the image block and nothing else, so "what is deployed" is diffable against "what is
  developed" without reading a pipeline log.

Deleted files are handled correctly, which a `git checkout <sha> -- .` would not do — that leaves a
file removed on `master` still present on `release` forever.

### 3. Digests are resolved from ECR, not plumbed through parameters

`terraform/ecr.tf` sets `image_tag_mutability = "IMMUTABLE"` on the four application repositories, so
a tag names one manifest for the lifetime of the repository. A tag→digest lookup is therefore
authoritative and repeatable, and **there is no reason to pass digests between jobs.**

`scripts/ci/resolve-digests.sh` takes `TAG` and prints `name<TAB>sha256:...` per repository. It is
called from three places, all of which already know the tag and already have ECR access:

- `deploy.sh` step 9, after the images are pushed — so a fresh cluster is digest-pinned from its
  first deploy rather than from its first pipeline run.
- CD's Promote stage, for the tag being promoted.
- CD's rollback path, for the previous tag. **This is why `previous-tag.sh` does not change**:
  re-resolving the previous tag yields precisely the digests that tag always had.

The rejected alternative was passing four digests from CI to CD as build parameters. CI already
records them in `image-metadata.json`, but a parameter-passing design has to answer "what digests
does a chart-only promotion use?" — there is no upstream CI build with images in that case. Resolving
from the registry answers it without a special case.

### 4. The chart helper prefers a digest and falls back to the tag

`voteball.image` renders `registry/voteball-<name>@<digest>` when `image.digests.<name>` is non-empty
and `registry/voteball-<name>:<tag>` otherwise.

The fallback is not decoration. A fresh fork, or a `helm template` run by a reader, has no digests to
render and must still produce a valid manifest — and `charts/voteball/values.yaml` is committed with
real values precisely so that ArgoCD and a reader see the same thing. `image.tag` also stays in
`values.yaml` and in the commit subject as the **readable** release label; the digest is the
execution identity. Losing the SHA tag from the manifest would make `kubectl get pods -o
jsonpath='{..image}'` unreadable during an incident, which is when it matters most.

### 5. What deliberately does NOT change

- **The Guard stage and `should-skip-build.sh` stay.** `deploy.sh` step 9 still commits to `master`,
  so a `[skip ci]`-marked commit can still appear there. The Guard is also strengthened rather than
  relaxed — see decision 6.
- **ArgoCD stays the applier.** CD still never runs `helm upgrade`; it pushes to `release` and asks
  ArgoCD to reconcile. The reasoning in `2026-08-04-cicd-split-design.md` §5 is unchanged.
- **`sync-values-from-tf.sh` still owns exactly the same ten fields.** The digest map is CD-owned, not
  Terraform-owned. It nests two levels deeper than the script's `kv_re` matches, so it is invisible to
  both the writer and `--check` by construction rather than by exclusion list.

### 6. The Guard becomes range-aware

Even with CD off `master`, `should-skip-build.sh` reads exactly one commit subject and therefore
cannot tell "the tip is a promotion commit and nothing else is pending" from "the tip is a promotion
commit and three source commits are hiding behind it". The second case is the 2026-08-21 incident.

It now takes an optional commit **range** and skips only when *every* commit in it carries the marker
in its subject line. One marked commit in a range that also holds unmarked work builds. The
single-argument form is retained unchanged, because `test-ci-guards.sh` pins it and because a caller
that cannot determine a range must still fail safe.

## Verification outcome

Verified on the 2026-08-23 rebuild — a full `destroy`/`deploy` cycle plus five CI builds and three CD
builds. **The design held; five defects in its implementation did not, and every one of them was
found by running it rather than by reading it.**

### What worked first time

- `deploy.sh` step 9 created `release` from the promoted `master` commit and pushed it, with all four
  digests resolved against a registry that was minutes old.
- ArgoCD synced `charts/voteball` and `charts/observability` from `release`; both reached
  `Synced`/`Healthy`.
- The end state is digest-pinned: all three Deployments and the backup CronJob render
  `repo@sha256:...`.
- `git diff master release` is **exactly `charts/voteball/values.yaml`** — the property decision 2
  claims, confirmed against a real branch rather than asserted.
- The release branch **self-heals**: `read-tree` makes each promotion's tree equal master's, so the
  stray file described below disappeared on the next promotion with no manual repair.

### The five defects

1. **A prediction that was wrong, and a smaller real cost.** Master kept empty digests while
   `release` carried real ones, so Helm (step 10) and ArgoCD (step 11) applied *different* values to
   `.spec…containers[].image`. This was expected to be a server-side-apply **conflict**, on the rule
   step 10's own comment states. It was not — ArgoCD took ownership cleanly. The actual cost was that
   every workload rolled **twice** on first deploy (revision 2, revision-1 pods still terminating).
   Fixed by writing the digests into master's values.yaml before committing, so both branches agree.
   **Verified by a second rebuild the same day** — the fix only runs on a fresh deploy, and the deploy
   that found it could not test it (editing a running bash script corrupts execution). Result:
   `revision = 1` on all three, and `git diff master release` returns **nothing at all** — the
   branches are byte-identical, which is a stronger outcome than "they agree on image references".
   Captured in `docs/eks/evidence/2026-08-23-digest-pinned-bootstrap.txt`. That rebuild also took
   `promote-to-release.sh`'s `read-tree` **update** path (the release branch survives a teardown), so
   both of that mechanism's paths are now proven live, conflict-free.

2. **hadolint `DL3059` failed CI #1** before a single test ran. The `gosu` removal added a second
   consecutive `RUN`; that finding is *info*-level and hadolint's default failure threshold is info.
   The local script suite was green because it does not run hadolint, and Lint runs before Tests.

3. **CD Verify could never pass again.** It asserted the running image *ends in* the requested tag,
   and digest-pinned images carry no tag. CD #1 rolled back a healthy release — ArgoCD
   `Synced`/`Healthy`, pods Running, site serving 200. The rollback build failed identically and
   `ROLLBACK_DEPTH` stopped it rather than looping, so the safety machinery was correct and the
   assertion it acted on was stale. This is a coupling the digest decision implied and this document
   failed to state: **if you deploy by digest, verification must check the digest.** The check now
   lives in `scripts/ci/verify-deployed-image.sh` with nine offline tests, because
   `check-jenkinsfile-shell.sh` proved that block *parsed*, never that it *decided* correctly.

4. **`git add -A` made the deployed branch un-promotable.** It swept `image-digests.tsv` — an
   artifact the Input Validation stage writes into the workspace — onto `release`. The next
   promotion's `git checkout -B release` then aborted with "untracked working tree files would be
   overwritten", because the file existed on both sides. Decision 2's claim that a release commit is
   "a master tree plus the pins" was only true by accident; it is now enforced by staging
   `$VALUES_FILE` alone.

5. **That failure was swallowed.** The Jenkinsfile ran the promote as `… | tail -1 > /tmp/promote-sha`,
   and a pipeline's exit status is the last command's — so `tail` returned 0 and `set -eu` never saw
   it. The stage reported success with an empty `PROMOTE_SHA`, and Deploy, Rollout and Verify all ran
   against a branch that had never been updated. `post { failure }` then read that empty value and
   concluded production was unchanged, which was true only by accident. This is the same
   "`| tail` masks the exit code" trap the project already knew about for Terraform runs, reappearing
   in a Jenkinsfile.

Defects 4 and 5 are the pair worth remembering: one broke the promotion, the other hid that it had
broken. Either alone would have been caught quickly; together they produced a stage that reported
success while doing nothing.

### Proof of the fixed state

`application-cd` #3, SUCCESS, all nine stages: Promote wrote a `release` commit, Verify reported
`digest matches the one 365ff2d resolves to` for all three Deployments, the smoke test passed against
the public URL, and the monitoring gate measured p95 0.096s. Captured in
`docs/eks/evidence/2026-08-23-task4-cd-run.txt`, with the defect-3 failure kept alongside it in
`2026-08-23-task4-cd-digest-verify-regression.txt`.
