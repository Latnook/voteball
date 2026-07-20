#!/usr/bin/env bash
# Single source of truth for this deployment's identity. Sourced by every script in scripts/.
#
# Nothing here is specific to one AWS account, region or domain: fork the repo, edit
# terraform-eks/voteball-eks.tfvars, and every script follows.
#
# Two phases, because find-latest-snapshot.sh runs BEFORE `terraform apply` exists:
#   pre-apply  -> parsed from voteball-eks.tfvars (falling back to the defaults in variables.tf)
#   post-apply -> read from `terraform output` (account id, ECR registry)

TF_DIR="${TF_DIR:-terraform-eks}"
TFVARS="${TFVARS:-$TF_DIR/voteball-eks.tfvars}"

# Read `name = "value"` out of the tfvars file. $2 is the fallback when the key is absent.
# Deliberately tolerant of spacing and of unquoted values.
tfvar() {
  local key="$1" fallback="${2:-}" val=""
  if [ -f "$TFVARS" ]; then
    val="$(sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"# ])\"?.*$/\1/p" "$TFVARS" | head -1)"
  fi
  printf '%s' "${val:-$fallback}"
}

# Defaults here MUST match the defaults in terraform-eks/variables.tf.
REGION="$(tfvar aws_region il-central-1)"
CLUSTER="$(tfvar cluster_name voteball)"
APP_DOMAIN="$(tfvar app_domain)"       # no default -- required variable
ZONE_NAME="$(tfvar route53_zone_name)" # no default -- required variable

# Post-apply lookup. Fails loudly rather than returning an empty string, which would otherwise be
# concatenated into a malformed ECR URL or ARN and fail much later with a confusing error.
tf_out() {
  local name="$1"
  if ! terraform -chdir="$TF_DIR" output -raw "$name" 2>/dev/null; then
    echo "ERROR: Terraform output '${name}' is unavailable." >&2
    echo "       Has the stack been applied? Try: terraform -chdir=${TF_DIR} output" >&2
    return 1
  fi
}

# Call from any script that needs the required (defaultless) variables.
require_config() {
  local missing=0
  [ -n "$APP_DOMAIN" ] || { echo "ERROR: app_domain is not set in $TFVARS" >&2; missing=1; }
  [ -n "$ZONE_NAME" ] || { echo "ERROR: route53_zone_name is not set in $TFVARS" >&2; missing=1; }
  if [ "$missing" != "0" ]; then
    echo "       Copy terraform-eks/voteball-eks.tfvars.example and fill it in." >&2
    exit 1
  fi
}
