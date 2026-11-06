#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage: OWNER=<handle> scripts/deploy-stack.sh <stack-name> <template> [params-file] [--plan-only] [--allow-destructive]

  <stack-name>         for example kvs-network
  <template>           for example infra/network.yaml
  [params-file]        JSON list of ParameterKey/ParameterValue, for example infra/params/network-sandbox.json
  --plan-only          create the change set and print it, then stop. Nothing is created or changed.
                       (For a new stack AWS leaves it in REVIEW_IN_PROGRESS. Run the script again without
                       --plan-only to execute, or delete the stack with: aws cloudformation delete-stack.)
  --allow-destructive  needed when the change set removes a resource or may replace one. Without it
                       the script prints the change set and stops with exit code 3.

Behaviour: create or update is detected with describe-stacks. Stack tags Project, Milestone, Environment,
Owner and ManagedBy are added. An empty change set is success (exit 0). IAM templates get
CAPABILITY_NAMED_IAM automatically.

Env vars: OWNER (required), AWS_REGION (default us-east-1), EVIDENCE_DIR, WAIT_SECONDS (default 1800).
Evidence goes to docs/evidence/deploy/.
USAGE
}

PLAN_ONLY=0; ALLOW_DESTRUCTIVE=0; POS=()
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --plan-only) PLAN_ONLY=1 ;;
    --allow-destructive) ALLOW_DESTRUCTIVE=1 ;;
    --*) usage >&2; die "unknown flag: $a" ;;
    *) POS+=("$a") ;;
  esac
done
[ "${#POS[@]}" -ge 2 ] && [ "${#POS[@]}" -le 3 ] || { usage >&2; die "need <stack-name> <template> [params-file]"; }
STACK="${POS[0]}"; TEMPLATE="${POS[1]}"; PARAMS="${POS[2]:-}"
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
[ -z "$PARAMS" ] || [ -f "$PARAMS" ] || die "params file not found: $PARAMS"
require_owner
require_session

CAPS=()
if grep -q 'AWS::IAM::' "$TEMPLATE"; then CAPS=(--capabilities CAPABILITY_NAMED_IAM); fi

STATUS="$(stack_status "$STACK")"
case "$STATUS" in
  NONE|REVIEW_IN_PROGRESS) CS_TYPE=CREATE ;;
  ROLLBACK_COMPLETE) die "$STACK is in ROLLBACK_COMPLETE. A failed create cannot be updated. Delete it first: aws cloudformation delete-stack --stack-name $STACK" ;;
  *_IN_PROGRESS) die "$STACK is $STATUS. Wait for the running operation to finish." ;;
  *) CS_TYPE=UPDATE ;;
esac

CS_NAME="${STACK}-cs-$(ts)"
info "Stack $STACK status $STATUS, change set type $CS_TYPE, change set $CS_NAME"

TAGS=(); while IFS= read -r t; do TAGS+=("$t"); done < <(stack_tags)
ARGS=(cloudformation create-change-set --stack-name "$STACK" --change-set-name "$CS_NAME"
      --change-set-type "$CS_TYPE" --template-body "file://$TEMPLATE" --tags "${TAGS[@]}")
[ -z "$PARAMS" ] || ARGS+=(--parameters "file://$PARAMS")
[ "${#CAPS[@]}" -eq 0 ] || ARGS+=("${CAPS[@]}")
aws "${ARGS[@]}" >/dev/null

# Poll the change set ourselves, because the built-in waiter fails on an empty change set.
DEADLINE=$(( $(date +%s) + ${WAIT_SECONDS:-1800} ))
while :; do
  CS_STATUS="$(aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$CS_NAME" --query Status --output text)"
  case "$CS_STATUS" in
    CREATE_COMPLETE) break ;;
    FAILED)
      REASON="$(aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$CS_NAME" --query StatusReason --output text)"
      if printf '%s' "$REASON" | grep -Eqi "didn't contain changes|No updates are to be performed"; then
        info "Empty change set. The stack already matches the template."
        aws cloudformation delete-change-set --stack-name "$STACK" --change-set-name "$CS_NAME"
        exit 0
      fi
      die "change set failed: $REASON"
      ;;
  esac
  [ "$(date +%s)" -lt "$DEADLINE" ] || die "timeout waiting for change set"
  sleep 3
done

EV_CS="$(evidence_path deploy "${STACK}-changeset.json")"
aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$CS_NAME" --output json >"$EV_CS"
info "Change set saved: $EV_CS"
echo
aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$CS_NAME" \
  --query 'Changes[].ResourceChange.{Action:Action,LogicalId:LogicalResourceId,Type:ResourceType,Replacement:Replacement}' \
  --output table
echo

RISKY="$(aws cloudformation describe-change-set --stack-name "$STACK" --change-set-name "$CS_NAME" \
  --query "length(Changes[?ResourceChange.Action=='Remove' || ResourceChange.Replacement=='True' || ResourceChange.Replacement=='Conditional'])" --output text)"

if [ "$PLAN_ONLY" -eq 1 ]; then
  [ "$RISKY" = "0" ] || warn "$RISKY change(s) remove or may replace a resource. Executing would need --allow-destructive."
  info "Plan only. Nothing was applied. Change set $CS_NAME is kept for inspection."
  exit 0
fi
if [ "$RISKY" != "0" ] && [ "$ALLOW_DESTRUCTIVE" -ne 1 ]; then
  warn "$RISKY change(s) remove or may replace a resource. Review the table, then run again with --allow-destructive."
  info "Change set $CS_NAME is kept. Delete it with: aws cloudformation delete-change-set --stack-name $STACK --change-set-name $CS_NAME"
  exit 3
fi

info "Executing change set..."
aws cloudformation execute-change-set --stack-name "$STACK" --change-set-name "$CS_NAME"
WAITER="stack-create-complete"; [ "$CS_TYPE" = UPDATE ] && WAITER="stack-update-complete"
EV_EVENTS="$(evidence_path deploy "${STACK}-events.json")"
if aws cloudformation wait "$WAITER" --stack-name "$STACK"; then
  aws cloudformation describe-stack-events --stack-name "$STACK" --output json >"$EV_EVENTS"
  ok "$STACK is $(stack_status "$STACK")"
  aws cloudformation describe-stacks --stack-name "$STACK" --query 'Stacks[0].Outputs' --output json >"$(evidence_path deploy "${STACK}-outputs.json")"
else
  aws cloudformation describe-stack-events --stack-name "$STACK" --output json >"$EV_EVENTS" || true
  warn "Deploy failed. Failed events:"
  aws cloudformation describe-stack-events --stack-name "$STACK" \
    --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatus,ResourceStatusReason]" --output table || true
  die "$STACK ended as $(stack_status "$STACK"). Events saved: $EV_EVENTS"
fi
