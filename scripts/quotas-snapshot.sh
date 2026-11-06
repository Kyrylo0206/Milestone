#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/quotas-snapshot.sh

For each service code (vpc ec2 ebs lambda dynamodb apigateway ecs fargate elasticloadbalancing logs cloudformation)
saves list-service-quotas and list-aws-default-service-quotas as JSON, plus a short text summary.
Also saves lambda get-account-settings, dynamodb describe-limits and ec2 describe-account-attributes.
A denied or failing call saves an .error.txt file and the script goes on.

Env vars: SERVICES (override the list, space separated), AWS_REGION, EVIDENCE_DIR. Results go to docs/evidence/quotas/.
Then fill the "Actual" columns in docs/m1-budget-and-quotas.md.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
require_session

SERVICES="${SERVICES:-vpc ec2 ebs lambda dynamodb apigateway ecs fargate elasticloadbalancing logs cloudformation}"
D=quotas
SUMMARY="$(evidence_path "$D" summary.txt)"
: >"$SUMMARY"
for S in $SERVICES; do
  run_or_record "$(evidence_path "$D" "$S-applied.json")" aws service-quotas list-service-quotas --service-code "$S" --output json
  run_or_record "$(evidence_path "$D" "$S-default.json")" aws service-quotas list-aws-default-service-quotas --service-code "$S" --output json
  {
    echo "== $S (code, name, value, adjustable) =="
    aws service-quotas list-service-quotas --service-code "$S" \
      --query 'Quotas[].[QuotaCode,QuotaName,Value,Adjustable]' --output text 2>&1 || echo "(denied or failed)"
  } >>"$SUMMARY"
done
run_or_record "$(evidence_path "$D" lambda-account-settings.json)" aws lambda get-account-settings --output json
run_or_record "$(evidence_path "$D" dynamodb-limits.json)" aws dynamodb describe-limits --output json
run_or_record "$(evidence_path "$D" ec2-account-attributes.json)" aws ec2 describe-account-attributes --output json
info "Done. Summary: $SUMMARY"
