#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/teardown.sh [--yes]

Without --yes the script only shows what exists and what it would delete.
With --yes it deletes kvs-app first (if present) and then kvs-network, waits for each, and prints the seconds.
It refuses to delete a stack that does not carry the stack tag Project=kvs-capstone.

Env vars: STACK_APP (default kvs-app), STACK_NETWORK (default kvs-network), AWS_REGION, EVIDENCE_DIR.
If delete fails with DependencyViolation, terminate manually launched instances in the VPC and try again.
USAGE
}
YES=0
for a in "$@"; do
  case "$a" in -h|--help) usage; exit 0 ;; --yes) YES=1 ;; *) usage >&2; die "unknown argument: $a" ;; esac
done
STACK_APP="${STACK_APP:-kvs-app}"; STACK_NETWORK="${STACK_NETWORK:-kvs-network}"
require_session

for s in "$STACK_APP" "$STACK_NETWORK"; do info "$s: $(stack_status "$s")"; done

VPC="$(stack_output "$STACK_NETWORK" VpcId 2>/dev/null || true)"
if [ -n "$VPC" ] && [ "$VPC" != "None" ]; then
  N="$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
       --query 'length(Reservations[].Instances[])' --output text 2>/dev/null || echo '?')"
  [ "$N" = "0" ] || warn "$N instance(s) still exist in $VPC. They block subnet deletion. Terminate them first."
fi

if [ "$YES" -ne 1 ]; then
  info "Dry run. Add --yes to delete."
  exit 0
fi

# Guard: STACK_APP/STACK_NETWORK can be overridden, so only delete stacks tagged Project=kvs-capstone.
for s in "$STACK_APP" "$STACK_NETWORK"; do
  [ "$(stack_status "$s")" = "NONE" ] && continue
  PROJ="$(aws cloudformation describe-stacks --stack-name "$s" --query "Stacks[0].Tags[?Key=='Project'].Value" --output text)"
  [ "$PROJ" = "kvs-capstone" ] || die "$s does not have the stack tag Project=kvs-capstone (got '$PROJ'). Refusing to delete it."
done

START="$(date +%s)"
for s in "$STACK_APP" "$STACK_NETWORK"; do
  if [ "$(stack_status "$s")" = "NONE" ]; then info "$s does not exist, skipping"; continue; fi
  info "Deleting $s ..."
  aws cloudformation delete-stack --stack-name "$s"
  aws cloudformation wait stack-delete-complete --stack-name "$s" \
    || { aws cloudformation describe-stack-events --stack-name "$s" \
         --query "StackEvents[?ResourceStatus=='DELETE_FAILED'].[LogicalResourceId,ResourceStatusReason]" --output table || true
         die "delete of $s failed"; }
  ok "$s deleted"
done
END="$(date +%s)"
echo "TEARDOWN_SECONDS=$((END - START))"
