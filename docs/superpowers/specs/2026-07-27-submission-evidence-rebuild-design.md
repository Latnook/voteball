# Submission evidence via a full destroy/rebuild cycle

_Spec written 2026-07-27. Process artifact, not an architectural design — it belongs here rather than
in `docs/design/`, which is reserved for feature and infrastructure decisions._

## Goal

Strengthen the graded submission by producing **current, captured evidence** for every deliverable the
requirements brief mandates, using a full `destroy.sh` → `deploy.sh` cycle as the vehicle. The cycle is
not incidental: "how to delete everything" and "how to run it" are themselves required sections, and
running them end to end turns two descriptions into two transcripts.

## Why this, and why now

The system is complete; the submission under-sells it. Every gap found on 2026-07-27 is presentation,
not engineering:

1. **The architecture diagram** (`docs/eks/architecture.md`) omits four elements the brief names —
   Kubernetes **Services**, the **node group** (and `capacity_type = "SPOT"`, `terraform/eks.tf:41`),
   the **Ingress** object itself, and **NetworkPolicy / HPA / PDB**. All four are built and working;
   three of them are bonus-track items. They are absent from the artifact a grader reads first.
2. **The evidence is stale.** `docs/eks/live-cluster-snapshot.md` satisfies all eight required
   `kubectl` outputs, but is dated 2026-07-20/21 and correctly declares itself frozen. The cluster has
   been rebuilt since, so its pod names, WAF id and ALB no longer resolve.
3. **The demos are asserted, not evidenced.** `README.submission.md:113-115` claims all five,
   including pod-restart-stays-up. `docs/images/` holds application screenshots only.

The cluster is up and healthy as of 2026-07-27 00:30 IDT (all pods `Running` ~95m), which makes this
the window to capture evidence rather than let a billed stack idle.

## Preconditions — verified, not assumed

The user's approval was conditional on a backup existing. Three independent layers were checked before
this spec was written:

| Layer | Verified state | Survives teardown? |
|---|---|---|
| RDS PITR / automated backups | `LatestRestorableTime` = `2026-07-26T21:31Z` (≈ now), 7-day retention | **yes** — `delete_automated_backups = false` keeps them in `retained` state after the instance is deleted |
| S3 nightly `pg_dump` | `backups/voteball-2026-07-26T02-00-02Z.sql.gz` downloaded and inspected: **5 `votes` rows, 17 `vote_clubs` rows** | **NO** — see the correction below |
| Final snapshot on destroy | `skip_final_snapshot = false` (`terraform/database.tf:80`); 5 prior snapshots available, newest `voteball-eks-db-final-20260721192838` | yes — snapshots outlive the stack |

> **Correction, verified during the 2026-07-27 teardown.** This spec originally called the S3 dump an
> *independent* third layer and named it as the fallback if the final snapshot failed. It is not
> independent of a teardown: `terraform/s3.tf:9` sets `force_destroy = true`, so `terraform destroy`
> deletes the rollups bucket **and every backup object in it** in the same run that would have failed
> to take the snapshot. Confirmed after the fact — `head-bucket` returned 404 and the backups prefix
> went from 5 objects to 0.
>
> The S3 dump is a real safeguard against *application*-level data loss (a bad migration, an errant
> DELETE) while the stack is up. It is worthless as insurance against the teardown itself. The layer
> actually covering that case is **retained automated backups**, which this spec had not credited:
> after the instance was deleted they persisted with a restore window ending `2026-07-27T06:01:00Z`,
> twelve minutes before the final snapshot at `06:13:54Z`.
>
> If the S3 dumps are wanted as genuine off-stack insurance, the bucket has to stop being owned by the
> stack that it insures — the same argument that already keeps `terraform/jenkins/` and the tfstate
> bucket out of `scripts/destroy.sh`.

The live API reports 5 votes; the S3 dump contains the same 5, with matching `previous_party_id`
values (10 ×2, 5, 14, 4). The backup is therefore current **and** provably complete — the distinction
matters, since a `Completed` CronJob proves a process ran, not that it captured data.

Stated plainly rather than buried: `MultiAZ = False` and `DeletionProtection = False`. Both are
deliberate — deletion protection is off precisely so `terraform destroy` works on a stack that is torn
down between sessions (`docs/production-readiness.md` §3, and item 4 of its suggested order).

## Design

Five phases. Phase 0 exists so that the teardown is never the single point of failure.

### Phase 0 — Insurance evidence from the current cluster

Capture all eight required `kubectl` outputs and run the five demos against the cluster running *now*,
before anything is destroyed. Read-only except one deliberate `kubectl delete pod` on a frontend
replica for the pod-restart demo, which two replicas and the PDB absorb.

The five demos, as the brief enumerates them:

1. HTTPS access to the site (valid ACM certificate)
2. frontend → backend communication
3. site → database
4. correct S3 and SNS use
5. pod restart while the site stays up

After this phase, the rebuild is upside rather than risk: if it goes badly, current evidence is
already in hand.

### Phase 1 — Pre-flight

Verify the things whose absence only hurts *after* a ~15-minute billed apply:

- `charts/voteball/values.yaml` committed and pushed to `master` — ArgoCD deploys from git, and
  bootstrapping against placeholders is what produced the 2026-07-20 `ImagePullBackOff`.
- `db_password` present in `terraform/voteball.tfvars`; `ADMIN_PASSWORD` available for the
  `deploy.sh` preflight prompt.
- Record the current vote count (5) so restoration can be proven rather than assumed.

### Phase 2 — Destroy, captured

`./scripts/destroy.sh`, streamed live (never piped through `tail` — that masks the exit code), output
saved as evidence. This produces the transcript for the brief's "delete everything" requirement: the
ordered teardown, the ALB wait, the orphaned-ENI reaper, and the final RDS snapshot.

### Phase 3 — Rebuild, captured

`./scripts/deploy.sh`, streamed live. Produces the "how to run it" evidence including the snapshot
restore.

**Known trap, handled explicitly:** re-confirm the SNS email subscription afterwards. `destroy.sh`
deletes the topic and the next apply recreates it in `PendingConfirmation`, where AWS delivers
nothing. This failed silently once already — `NumberOfMessagesPublished: 2`,
`NumberOfNotificationsDelivered: 0` (`docs/production-readiness.md` §6).

### Phase 4 — Fresh evidence and diagram

- **Append** a new dated section to `docs/eks/live-cluster-snapshot.md`. Append, never edit: the
  2026-07-20/21 sections are frozen evidence and "correcting" them destroys their value.
- Re-run the five demos on the new cluster and capture output.
- Verify the vote count survived the snapshot restore (expect 5).
- Patch the four diagram omissions in `docs/eks/architecture.md`.

## Evidence artifacts produced

| Artifact | Deliverable it serves |
|---|---|
| Pre-teardown `kubectl` capture (Phase 0) | fallback for all eight required outputs |
| `destroy.sh` transcript | "how to delete everything" |
| `deploy.sh` transcript | "how to run it" |
| New dated snapshot section | all eight required `kubectl` outputs, current |
| Five demo captures, incl. pod-restart | the brief's mandated demo list |
| Updated mermaid diagram | Services, node group + SPOT, Ingress, NetworkPolicy/HPA/PDB |

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Rebuild fails, leaving no cluster near a deadline | Phase 0 captures evidence first; three verified backup layers; the runbook has been executed successfully before |
| Votes lost | Final snapshot + **retained automated backups** (the S3 dump does *not* survive teardown — see the correction above); count verified before and after |
| SNS alerting silently dead after rebuild | Explicit re-confirmation step in Phase 3 |
| Live admin sessions invalidated | Expected — `deploy.sh` step 3 reissues `ADMIN_SESSION_SECRET`; no action needed |
| New ACM cert / WAF / ALB identifiers | Expected and documented; the frozen snapshot already explains why old identifiers do not resolve |

## Out of scope

- Frontend test harness, i18n replacement, Dockerfile `COPY` guard — real work, worth zero marks,
  deliberately deferred until after submission.
- Alembic (`production-readiness.md` §4 — the top of its open list), NAT/Spot redundancy (§5),
  RDS Multi-AZ (§3).
- Any change to application behaviour. This pass touches documentation and captures evidence; the
  only mutations are the deliberate teardown/rebuild and one demo pod deletion.

## Success criteria

1. `docs/eks/architecture.md` shows all elements the brief enumerates, including Services and the node
   group, with NetworkPolicy/HPA/PDB visible.
2. `docs/eks/live-cluster-snapshot.md` carries a 2026-07-27 section with all eight `kubectl` outputs
   from the rebuilt cluster, with the earlier sections untouched.
3. All five demos have captured output, not prose claims.
4. The rebuilt site serves traffic over HTTPS and reports **5 votes**, proving snapshot restore.
5. The SNS subscription is `Confirmed`, verified by command rather than assumed.
