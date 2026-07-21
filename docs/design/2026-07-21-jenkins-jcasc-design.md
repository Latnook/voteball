# Jenkins Configuration as Code

Status: designed and implemented 2026-07-21. Closes the JCasC half of **§7** of
`docs/production-readiness.md`. Follow-on to `2026-07-20-jenkins-migration-design.md`, which
deliberately deferred this ("banking a green build first").

---

## Problem

The CI host's configuration existed **only on one EBS volume**, built by hand through the UI
following a 12-step runbook. Two distinct losses were possible:

1. **Re-doing the clicking.** Plugins, global properties, credentials, job definition, webhook
   secret. Tedious but recoverable.
2. **The deploy key.** Not recoverable at all. Its private half existed nowhere except Jenkins'
   credential store, encrypted with a key on the same volume. It is **not** the operator's SSH key —
   `~/.ssh/voteball-jenkins` logs into the EC2 instance and is a different key entirely. Verified by
   comparing public halves: the login key is `…GRQ1`, the GitHub deploy key `…Gvuk`.

§7 rated this "real but low-probability, accepted for now" on the strength of
`delete_on_termination = false`. That rating was wrong twice over. The volume protection does not
help, because a replacement instance does not attach the old volume — and on 2026-07-21 a plan
showed `terraform apply` *would* replace the instance, because `data.aws_ssm_parameter.al2023`
tracks the newest Amazon Linux image and `ami` forces replacement. The loss was one routine command
away, on Amazon's release schedule. (Fixed separately: `ami` added to `lifecycle.ignore_changes`.)

---

## Non-goals

- **Not** rebuilding the host. The whole point is that it need not be rebuilt to be reconfigured.
- **Not** managing the GitHub webhook itself. `manageHooks` stays off: this Jenkins' own URL is
  `http://localhost:8080/`, so it cannot register a hook GitHub can reach.
- **Not** notifications (G7) or SSM Session Manager. Both remain deferred.
- **Not** pinning plugin versions. See below.

---

## Design

### 1. Configuration in the repository, fetched at boot

`terraform/jenkins/casc/jenkins.yaml` + `plugins.txt`, cloned from **`master` over HTTPS** by
`user_data.sh` at boot. The repository is public, which is what makes this possible: cloning it
privately would need the deploy key, which is one of the credentials JCasC installs — a genuine
chicken-and-egg. **If this repo is ever made private, this step must change** to baking the files
into `user_data`.

The alternative — `templatefile()` over the whole bootstrap — was rejected: it interpolates every
`${...}` in the script, and escaping several hundred bash expansions to pass three values is a poor
trade in a script whose failures are invisible until something is missing. Instead a small generated
header (`user_data_env.sh.tftpl`) exports `VOTEBALL_REGION`, `VOTEBALL_CLUSTER` and
`VOTEBALL_GITHUB_REPO`, and is prepended to the static script.

### 2. Secrets in Secrets Manager, materialised as files

`voteball/jenkins` holds the admin username, the admin **bcrypt hash**, the deploy key and its
username, and the webhook secret. Terraform creates only the container (`ignore_changes` on
`secret_string`), so nothing enters git or tfstate. The instance role gains
`secretsmanager:GetSecretValue` on **one ARN** — no wildcard, no write. Verified on the host: it
reads its own secret and is denied both `voteball/app-secret` and `list-secrets`.

Storing the **hash** rather than the password means the plaintext admin password exists nowhere at
all; JCasC accepts `#jbcrypt:$2a$…` directly.

**Values are written as one file per secret, not into a systemd `EnvironmentFile`.** The deploy key
is multi-line and its trailing newline is load-bearing — a key without it cannot be *loaded* by
OpenSSH, which then reports `Permission denied (publickey)`, a message that reads like an
authorisation failure and is not (`docs/cicd.md`, failure mode 2). `EnvironmentFile` carries neither
newlines nor trailing whitespace faithfully. JCasC's file-based secret source does; this was
verified, not assumed (see Verification).

### 3. What JCasC cannot express, and why that is not a workaround

Two settings abort the **entire boot** with `UnknownAttributesException` rather than being ignored:

| Setting | Outcome |
|---|---|
| `crumbIssuer.standard.excludeClientIPFromCrumb` | No such attribute on Jenkins 2.568.1. **Removed** — Jenkins installs `DefaultCrumbIssuer` itself, which is exactly what the hand-built `config.xml` had. Configuring a default to its own default bought a version-coupled field for nothing. |
| `gitHubPluginConfig.manageHooks` | `GitHubPluginConfig` (github 1.47.0) is not data-bound. **Moved to `user_data.sh`**, which writes the plugin's XML directly. |

The second is the same missing-setter problem `docs/cicd.md` already records from the other
direction — `setHookSecretConfigs()` via the Groovy console "reports success but does not persist" —
and the fix recorded there (write the XML) is the fix here.

It also turns the migration's costliest bug from *avoided* into *impossible*. `getHookSecretConfigs()`
prefers the plural list **whenever present**, so an empty-but-present `<hookSecretConfigs/>` once
beat the working singular value, leaving zero secrets configured and returning 400 on every push,
signed and unsigned alike. Writing the **legacy singular** `hookSecretConfig` means the plural list
is never present at all. JCasC would have written the plural form.

### 4. Plugins: trimmed list, unpinned versions

`plugins.txt` names **8 top-level** plugins against the 94 "install suggested" left, each traceable
to something the `Jenkinsfile` does, with the exclusions argued rather than merely absent.
Dependencies are resolved by the plugin manager, so the file stays readable.

Versions are **deliberately unpinned**: this host is rebuilt rarely and always wants versions
matching the Jenkins LTS it boots with, and pinning would create a second silently-stale list beside
the Jenkins version itself. The trade-off — two builds of the same commit can install different
plugin versions — is acceptable for a single-operator host, and is why `jenkins-plugin-cli --list`
output belongs in any bug report.

---

## Verification (2026-07-21)

Applied to the live host by re-running the bootstrap. Two boots failed first, both loudly:

1. `crumbIssuer` → `UnknownAttributesException`, Jenkins refused to start.
2. `gitHubPluginConfig.manageHooks` → same.

**Both failures were the correct behaviour** and worth stating plainly: JCasC aborted rather than
applying a partial configuration. A tool that silently skipped the bad key would have produced a
Jenkins that looked configured and had no webhook secret — indistinguishable, from the outside, from
the working one.

After the fixes:

| Check | Result |
|---|---|
| Jenkins starts, no `SEVERE` after start | active, HTTP 200 |
| Both credentials carry the `managed by JCasC` marker | yes — JCasC wrote them, not leftovers |
| Job `voteball` carries the marker; SSH remote, `*/master`, `Jenkinsfile` | yes |
| Global env `AWS_REGION`, `CLUSTER_NAME` | present |
| `FORCE_BUILD` registered **without a build having run** | yes — **incidentally fixes G6** |
| GitHub plugin XML: `manageHooks=false`, singular hook secret | yes |
| Deploy key after Secrets Manager → file → JCasC | **411 chars, trailing newline intact**, header and footer intact — byte-identical to the original |
| Signed webhook → 200; unsigned → 400; wrong signature → 400 | yes |

The webhook result is the meaningful one. Signed and unsigned returning **different** codes is
exactly the discriminator `docs/cicd.md` records: when the secret was mis-wired, both failed
identically.

### What is NOT verified

**The rebuild path.** Everything above was applied to a host that was *already* configured, with 94
plugins and a populated `JENKINS_HOME`. A genuinely fresh instance — empty home, no plugins, plugin
manager installing the trimmed set from scratch — has **not** been booted from this configuration.
"The server is now rebuildable" is therefore a well-supported expectation, not a demonstrated fact.

Consequences, recorded rather than glossed:

- The running host still carries **95 plugins**, not the 8+dependencies in `plugins.txt`; nothing
  removes what is already installed. A rebuilt host would get the smaller, untested set.
- Keep the EBS snapshots (`snap-0bf101529baf8fd23` pre-OS-upgrade, `snap-05745dc9bd1bb669e`
  pre-JCasC) until a fresh boot is proven.

The test that closes this is cheap — launch a throwaway instance from the same Terraform config,
let `user_data` run, confirm it configures itself, terminate it. Roughly ten minutes and a few cents.
It is the obvious next step and was not done only because it belongs in its own session.

---

## Operational note

The deploy key was recovered by dropping a temporary script in `/var/lib/jenkins/init.groovy.d/`,
which runs at startup with full permissions and no authentication — so Jenkins decrypted its own
credentials rather than anyone reimplementing its crypto. The recovered private key was verified by
deriving its public half and matching it against the key registered on GitHub, then piped host →
Secrets Manager without touching a terminal or the operator's disk. Script and outputs were deleted.

Worth knowing for two reasons: it is the standard locked-out-of-Jenkins recovery path, and it means
**root on this host is admin on Jenkins**. That is the same trust boundary `user_data.sh` already
notes from the other side (`usermod -aG docker jenkins` makes anyone who can define a job root on
the machine).
