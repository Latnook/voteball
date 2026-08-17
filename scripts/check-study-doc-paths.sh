#!/usr/bin/env bash
# Fail if the private study docs point at files that no longer exist.
#
# WHY THIS EXISTS: EXPLAINER.md and PROJECT-QA.md are exam-prep material -- their whole job is to say
# "the answer to that is in <file>" so a question can be answered by opening it. That makes a renamed
# or deleted file a silent, total failure of the document: the claim still reads fine, and you only
# find out standing in front of someone.
#
# It is not hypothetical. The 2026-08-04 CI/CD split deleted `Jenkinsfile` (into Jenkinsfile-ci and
# Jenkinsfile-cd) and retired the whole `terraform/jenkins/` stack. PROJECT-QA.md's "where everything
# is" table went on naming all three for two weeks. Nothing caught it, because nothing in this repo
# asserts that a path named in a markdown file exists -- least of all a GITIGNORED markdown file,
# which no test can even see on a fresh clone.
#
# WHY IT LIVES IN scripts/ AND NOT scripts/tests/: run-ci-suite.sh's group lists are exhaustive and
# fail on an unlisted file, so putting this in scripts/tests/ would force it into a group where it
# could only ever skip -- the docs are gitignored and absent from CI's checkout. A test that is
# structurally incapable of failing in CI is worse than no test: it reads as coverage. This is a
# local pre-exam utility and is shaped like one.
#
# Usage:  scripts/check-study-doc-paths.sh          # check both docs
#         scripts/check-study-doc-paths.sh FILE...  # check specific files
set -euo pipefail

cd "$(dirname "$0")/.."

DOCS=("$@")
if [ ${#DOCS[@]} -eq 0 ]; then
  DOCS=(EXPLAINER.md PROJECT-QA.md)
fi

# Paths that are MEANT to be absent: the docs discuss them as retired, as things not to recreate, or
# as generated-and-gitignored files that exist only after a deploy. Removing an entry here should
# require knowing why it was added.
is_allowed() {
  case "$1" in
    # Retired stacks, named so the reader knows not to look for or recreate them.
    terraform/jenkins/*|terraform/jenkins|ansible-project/*|ansible-project|terraform-eks/*|terraform-eks) return 0 ;;
    Jenkinsfile) return 0 ;;                       # split into Jenkinsfile-ci / Jenkinsfile-cd
    scripts/sync-seed-from-rds.sh) return 0 ;;     # removed 2026-07-20 with the k3s stack
    docs/superpowers/*|docs/superpowers) return 0 ;; # executed plans, deleted by policy
    # Generated + gitignored: real, but only after a bootstrap or a deploy.
    terraform/backend.hcl|terraform/voteball.tfvars|deploy.env) return 0 ;;
    terraform/terraform.tfstate*|*.tfstate) return 0 ;;
    # Paths inside containers or on remote hosts, not in this repo.
    /etc/*|/tmp/*|/var/*|/home/user/*|/images/*) return 0 ;;
  esac
  return 1
}

# Deciding what is a repo path is the whole difficulty here, and the failure mode that matters is a
# FALSE POSITIVE: a checker that cries wolf on `/api/results` or `nginxinc/nginx-unprivileged` gets
# ignored, and an ignored checker protects nothing. So the rule is deliberately narrow -- a token is
# only checked when it is unambiguously a reference to a file in THIS repo:
#
#   1. leading "/"        -> an HTTP route (/api/results) or a container path (/tmp/...). Never ours.
#   2. no "/" at all      -> a bare filename in prose (`queries.py`). Checked by basename, anywhere.
#   3. otherwise          -> the first segment must be a real top-level entry of this repo. That is
#                            what separates `services/worker/db.py` from `nginxinc/nginx-unprivileged`
#                            (an image), `voteball/jenkins` (a secret id) and `backups/` (an S3 prefix).
looks_like_path() {
  case "$1" in
    http://*|https://*|git@*|*.svc.cluster.local*) return 1 ;;
    [0-9]*.[0-9]*.[0-9]*) return 1 ;;              # IPs and CIDRs: 10.0.0.0/16
    *' '*|*'='*|*'('*|*'*'*'*'*) return 1 ;;       # command fragments
    -*) return 1 ;;                                # flags: --var-file=...
    /*) return 1 ;;                                # rule 1
  esac

  local first=${1%%/*}
  if [ "$first" = "$1" ]; then
    # Rule 2: bare token. Only meaningful if it carries a source extension.
    case "$1" in
      *.tf|*.py|*.sh|*.sql|*.js|*.html|*.css|*.md|*.yaml|*.yml|*.json) return 0 ;;
      *) return 1 ;;
    esac
  fi

  # Rule 3.
  [ -e "$first" ]
}

# Resolve a bare filename (rule 2) anywhere in the repo, ignoring vendored and generated trees.
BARE_INDEX=""
bare_exists() {
  # Present at the repo root. This is the case for the study docs themselves, which are GITIGNORED and
  # so are invisible to `git ls-files` below -- without this they could never cross-reference each
  # other, which is exactly what they need to do.
  [ -e "$1" ] && return 0

  if [ -z "$BARE_INDEX" ]; then
    BARE_INDEX=$(git ls-files | sed 's:.*/::' | sort -u)
  fi
  grep -qxF "$1" <<<"$BARE_INDEX"
}

fail=0
checked=0
missing_report=""

for doc in "${DOCS[@]}"; do
  if [ ! -f "$doc" ]; then
    echo "skip: $doc not present (it is gitignored; nothing to check)"
    continue
  fi

  # Pull every backticked span, one per line, with its line number.
  while IFS= read -r entry; do
    lineno=${entry%%:*}
    token=${entry#*:}

    # Trim trailing prose punctuation that commonly rides along inside the backticks.
    token=${token%%[,.;:)]}
    # Strip a file:line or file:line-line suffix. That form is the POINT of these docs -- it is how
    # you open the exact spot in front of someone -- so it must be checkable, not rejected.
    token=$(printf '%s' "$token" | sed -E 's/:[0-9]+(-[0-9]+)?$//')

    looks_like_path "$token" || continue
    is_allowed "$token" && continue

    checked=$((checked + 1))

    if [[ "$token" != */* ]]; then
      # Rule 2: bare filename, resolved by basename anywhere in the tree.
      bare_exists "$token" || {
        missing_report+="  $doc:$lineno  MISSING   $token"$'\n'
        fail=1
      }
    elif [[ "$token" == *[*{]* ]]; then
      # A glob or brace expansion must match at least one real file.
      # shellcheck disable=SC2086
      if ! compgen -G "$(eval echo $token)" >/dev/null 2>&1 && ! eval "ls -d $token" >/dev/null 2>&1; then
        missing_report+="  $doc:$lineno  no match  $token"$'\n'
        fail=1
      fi
    elif [ ! -e "${token%/}" ]; then
      missing_report+="  $doc:$lineno  MISSING   $token"$'\n'
      fail=1
    fi
  done < <(grep -n -o '`[^`]*`' "$doc" | sed 's/`//g')
done

echo "checked $checked path references in: ${DOCS[*]}"

if [ "$fail" -ne 0 ]; then
  echo
  echo "Dead paths in the study docs:"
  printf '%s' "$missing_report"
  echo
  echo "Fix the doc, or -- if the path is meant to be absent (a retired stack, a generated file)" >&2
  echo "-- add it to is_allowed() above with a comment saying why." >&2
  exit 1
fi

echo "OK: every path reference resolves."
