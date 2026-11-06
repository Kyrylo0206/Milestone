#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/drift-check.sh <stack-name>

Starts detect-stack-drift, polls until it finishes, then prints the resources that are MODIFIED or DELETED.
detect-stack-drift only reads the live state and compares it with the stack, it changes nothing.
Exit code 0 means IN_SYNC, 10 means DRIFTED, 1 means the detection failed.

Defense demo: change the value of the VPC Name tag by hand in the console (the template sets it), run this
script (the VPC shows as MODIFIED), then run scripts/deploy-stack.sh and see that the default change set does
not show it. A default change set compares templates, not live state. Put the tag back after the demo.

Env vars: AWS_REGION, EVIDENCE_DIR, WAIT_SECONDS (default 600). Evidence goes to docs/evidence/drift/.
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; "") usage >&2; die "need <stack-name>" ;; esac
STACK="$1"
require_session

ID="$(aws cloudformation detect-stack-drift --stack-name "$STACK" --query StackDriftDetectionId --output text)"
info "Drift detection id $ID"
DEADLINE=$(( $(date +%s) + ${WAIT_SECONDS:-600} ))
while :; do
  ST="$(aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$ID" --query DetectionStatus --output text)"
  [ "$ST" != "DETECTION_IN_PROGRESS" ] && break
  [ "$(date +%s)" -lt "$DEADLINE" ] || die "timeout waiting for drift detection"
  sleep 4
done
aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$ID" --output json >"$(evidence_path drift "${STACK}-status.json")"
[ "$ST" = "DETECTION_COMPLETE" ] || die "drift detection ended as $ST"

DRIFT="$(aws cloudformation describe-stack-drift-detection-status --stack-drift-detection-id "$ID" --query StackDriftStatus --output text)"
aws cloudformation describe-stack-resource-drifts --stack-name "$STACK" \
  --stack-resource-drift-status-filters MODIFIED DELETED --output json >"$(evidence_path drift "${STACK}-drifts.json")"
echo "Stack drift status: $DRIFT"
aws cloudformation describe-stack-resource-drifts --stack-name "$STACK" \
  --stack-resource-drift-status-filters MODIFIED DELETED \
  --query 'StackResourceDrifts[].{Resource:LogicalResourceId,Type:ResourceType,Status:StackResourceDriftStatus}' --output table
aws cloudformation describe-stack-resource-drifts --stack-name "$STACK" \
  --stack-resource-drift-status-filters MODIFIED DELETED \
  --query 'StackResourceDrifts[].PropertyDifferences[].[PropertyPath,ExpectedValue,ActualValue,DifferenceType]' --output text || true
[ "$DRIFT" = "IN_SYNC" ] && exit 0
exit 10
