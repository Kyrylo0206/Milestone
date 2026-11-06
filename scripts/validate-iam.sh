#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/validate-iam.sh [--attempt-create]

Steps (design decisions section 7):
  1  cfn-lint (if installed) and tests/test_readonly_policy.py (if pytest is installed)
  2  aws cloudformation validate-template
  3  scripts/extract-policy.py  ->  build/readonly-policy.json
  4  aws accessanalyzer validate-policy
  5  aws accessanalyzer check-access-not-granted (paid custom policy check, a fraction of a cent)
  6  aws iam simulate-custom-policy, compared with the expected decisions
  7  only with --attempt-create: create-stack kvs-iam-readonly with CAPABILITY_NAMED_IAM, wait for a terminal state,
     save describe-stack-events (the ResourceStatusReason shows the denied IAM action), then delete the stack.
     Needs OWNER. Uses PARAMS (default infra/params/iam-readonly-example.json, a placeholder account, so any
     success is still harmless, and the stack is deleted at the end either way).

Env vars: OWNER (for step 7), PARAMS, PYTHON (needs pyyaml for step 3), CFN_LINT, AWS_REGION, EVIDENCE_DIR.
Evidence goes to docs/evidence/iam/. Exit code is 1 only if a step that ran gave a wrong answer (for example a
simulator decision that differs from expected). A step that was denied is not an error.
USAGE
}
ATTEMPT=0
for a in "$@"; do
  case "$a" in -h|--help) usage; exit 0 ;; --attempt-create) ATTEMPT=1 ;; *) usage >&2; die "unknown argument: $a" ;; esac
done
cd "$REPO_ROOT"
TEMPLATE="infra/iam-readonly.yaml"
POLICY="build/readonly-policy.json"
BAD=0
P() { evidence_path iam "$1"; }

echo "== step 1: offline checks =="
CFN_LINT="${CFN_LINT:-$(command -v cfn-lint || true)}"
if [ -n "$CFN_LINT" ]; then "$CFN_LINT" "$TEMPLATE" && echo "cfn-lint clean" || BAD=1; else warn "cfn-lint not installed, skipped"; fi
if "$PYTHON" -c 'import pytest, yaml' 2>/dev/null; then (cd tests && "$PYTHON" -m pytest -q test_readonly_policy.py) || BAD=1; else warn "pytest or pyyaml missing, skipped"; fi

echo "== step 3 (needed by 4 to 6): extract policy =="
mkdir -p build
"$PYTHON" -I scripts/extract-policy.py "$TEMPLATE" >"$POLICY" || die "could not extract the policy (is pyyaml installed?)"
"$PYTHON" -I -c 'import json,sys; json.load(open(sys.argv[1])); print("policy JSON parses")' "$POLICY"
cp "$POLICY" "$(P extracted-policy.json)"

require_session

echo "== step 2: validate-template =="
run_or_record "$(P validate-template.json)" aws cloudformation validate-template --template-body "file://$TEMPLATE" --output json

echo "== step 4: access analyzer validate-policy =="
run_or_record "$(P accessanalyzer-validate-policy.json)" aws accessanalyzer validate-policy \
  --policy-type IDENTITY_POLICY --policy-document "file://$POLICY" --output json

echo "== step 5: access analyzer check-access-not-granted =="
ACCESS='[{"actions":["s3:PutObject","ec2:RunInstances","ec2:CreateVpc","iam:CreateRole","dynamodb:PutItem","dynamodb:Scan","s3:GetObject"]}]'
OUT5="$(P accessanalyzer-check-access-not-granted.json)"
run_or_record "$OUT5" aws accessanalyzer check-access-not-granted \
  --policy-type IDENTITY_POLICY --policy-document "file://$POLICY" --access "$ACCESS" --output json
if [ -f "$OUT5" ]; then
  # Read the saved answer. A second call would be a second paid check.
  R="$("$PYTHON" -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("result",""))' "$OUT5")"
  echo "check-access-not-granted result: $R"
  [ "$R" = "PASS" ] || { warn "expected PASS"; BAD=1; }
fi

echo "== step 6: simulate-custom-policy =="
ACTIONS="ec2:DescribeVpcs ec2:CreateVpc s3:ListAllMyBuckets s3:GetObject dynamodb:Scan iam:CreateRole"
EXPECT="ec2:DescribeVpcs=allowed ec2:CreateVpc=implicitDeny s3:ListAllMyBuckets=allowed s3:GetObject=explicitDeny dynamodb:Scan=explicitDeny iam:CreateRole=implicitDeny"
COMPACT="$("$PYTHON" -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",",":")))' "$POLICY")"
OUT6="$(P simulate-custom-policy.json)"
# shellcheck disable=SC2086
run_or_record "$OUT6" aws iam simulate-custom-policy --policy-input-list "$COMPACT" --action-names $ACTIONS \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output json
if [ -f "$OUT6" ]; then
  for pair in $EXPECT; do
    act="${pair%%=*}"; want="${pair#*=}"
    got="$("$PYTHON" -I -c 'import json,sys; d=dict(json.load(open(sys.argv[1]))); print(d.get(sys.argv[2],"missing"))' "$OUT6" "$act")"
    if [ "$got" = "$want" ]; then ok "$act is $got"; else warn "$act expected $want got $got"; BAD=1; fi
  done
else
  warn "Simulator call denied. Use the web Policy Simulator and take a screenshot as evidence."
fi

if [ "$ATTEMPT" -eq 1 ]; then
  echo "== step 7: attempt to create the stack (expected to be refused in the sandbox) =="
  require_owner
  PARAMS="${PARAMS:-infra/params/iam-readonly-example.json}"
  STACK="kvs-iam-readonly"
  [ "$(stack_status "$STACK")" = "NONE" ] || die "$STACK already exists ($(stack_status "$STACK")). Delete it first."
  TAGS=(); while IFS= read -r t; do TAGS+=("$t"); done < <(stack_tags)
  CREATE_RC=0
  aws cloudformation create-stack --stack-name "$STACK" --template-body "file://$TEMPLATE" \
    --parameters "file://$PARAMS" --capabilities CAPABILITY_NAMED_IAM --tags "${TAGS[@]}" \
    >"$(P create-stack.json)" 2>"$(P create-stack.error.txt)" || CREATE_RC=$?
  if [ "$CREATE_RC" -ne 0 ]; then
    warn "create-stack call itself was refused. Error text saved: $(P create-stack.error.txt)"
  else
    rm -f "$(P create-stack.error.txt)"
    DEADLINE=$(( $(date +%s) + 600 ))
    while :; do
      ST="$(stack_status "$STACK")"
      case "$ST" in *_IN_PROGRESS) ;; *) break ;; esac
      [ "$(date +%s)" -lt "$DEADLINE" ] || { warn "timeout waiting, last status $ST"; break; }
      sleep 5
    done
    echo "Final status: $ST"
    aws cloudformation describe-stack-events --stack-name "$STACK" --output json >"$(P describe-stack-events.json)" || true
    aws cloudformation describe-stack-events --stack-name "$STACK" \
      --query "StackEvents[?contains(ResourceStatus,'FAILED')].[LogicalResourceId,ResourceStatus,ResourceStatusReason]" --output table || true
    case "$ST" in
      CREATE_COMPLETE) warn "FINDING: the sandbox ALLOWED the IAM stack. Deleting it now." ;;
      *) echo "Expected result: ROLLBACK_COMPLETE with CREATE_FAILED on ReadOnlyViewPolicy." ;;
    esac
    aws cloudformation delete-stack --stack-name "$STACK"
    aws cloudformation wait stack-delete-complete --stack-name "$STACK" && ok "$STACK deleted" || warn "could not confirm delete, check the console"
  fi
else
  info "Step 7 skipped. Use --attempt-create to record the sandbox refusal."
fi

[ "$BAD" -eq 0 ] && echo "VALIDATE-IAM RESULT: no wrong answers" || { echo "VALIDATE-IAM RESULT: problems found"; exit 1; }
