#!/usr/bin/env bash
# Assert that every `-target=<address>` any script passes to terraform names a resource that
# actually exists in the configuration.
#
# WHY THIS EXISTS. A stale -target does not fail. Terraform prints
#
#     Warning: Resource targeting is in effect
#
# and then applies NOTHING -- so the script runs fast, exits 0, and creates none of what it was
# supposed to create. deploy.sh step 5 would report success having built no ECR repositories, and
# the failure surfaces later as an unrelated push error. This is the "a pattern that can never
# match" defect class from CLAUDE.md, whose empty result is indistinguishable from a correct
# negative, and the 2026-09-07 module refactor moved 101 resources behind module paths -- which is
# exactly the change that silently invalidates a -target.
#
# Offline: pure grep over scripts/ and terraform/. No terraform binary, no AWS, no network.
set -uo pipefail
cd "$(dirname "$0")/../.."

fail=0
note() { printf '  %s\n' "$*"; }

# Every -target=<addr> in every script, with the file it came from.
# The character class is spelled out rather than using a bracket range with escapes: an ERE bracket
# expression treats a backslash literally, so '[...\[\]...]' is malformed and silently matches
# nothing -- which is the very defect this test exists to catch, and it bit while writing it.
# --exclude this file: it contains the pattern itself, and would otherwise "find" its own regex
# text as an address and report it missing.
mapfile -t hits < <(grep -rhoE --exclude="$(basename "$0")" -- '-target=[][A-Za-z0-9_."-]+' scripts/ \
  | sed 's/^-target=//' | sort -u)

if [ "${#hits[@]}" -eq 0 ]; then
  echo "FAIL: found no -target= usages at all -- the extraction pattern is broken, not the scripts." >&2
  echo "      (deploy.sh and scripts/jenkins/*.sh are known to use them.)" >&2
  exit 1
fi

echo "Checking ${#hits[@]} distinct -target= address(es):"
for addr in "${hits[@]}"; do
  # strip any [index] / ["key"] suffix
  bare="${addr%%[*}"

  if [[ "$bare" == module.* ]]; then
    mod="${bare#module.}"; mod="${mod%%.*}"
    rest="${bare#module.$mod.}"
    dir="terraform/modules/$mod"
    if [ ! -d "$dir" ]; then
      note "MISSING MODULE  $addr -> no such directory $dir"; fail=1; continue
    fi
    search_path="$dir"
  else
    rest="$bare"
    # root addresses must be in a root .tf, NOT inside modules/
    search_path="terraform"
  fi

  # rest is now "<type>.<name>" or "data.<type>.<name>"
  if [[ "$rest" == data.* ]]; then
    r="${rest#data.}"; kind="data"
  else
    r="$rest"; kind="resource"
  fi
  type="${r%%.*}"; name="${r#*.}"

  if [ "$search_path" = "terraform" ]; then
    found=$(grep -lE "^$kind \"$type\" \"$name\"" terraform/*.tf 2>/dev/null | head -1)
  else
    found=$(grep -lE "^$kind \"$type\" \"$name\"" "$search_path"/*.tf 2>/dev/null | head -1)
  fi

  if [ -z "$found" ]; then
    note "NOT FOUND       $addr"
    note "                expected $kind \"$type\" \"$name\" under $search_path/"
    fail=1
  else
    note "ok              $addr  ($found)"
  fi
done

if [ "$fail" -ne 0 ]; then
  echo >&2
  echo "FAIL: at least one -target= names a resource that does not exist." >&2
  echo "      terraform would warn and apply NOTHING rather than erroring." >&2
  exit 1
fi
echo "PASS: every -target= address resolves."
