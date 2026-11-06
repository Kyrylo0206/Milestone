#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/labrole-dissect.sh [--include-write-probes]

Always (read only, or dry-run which creates nothing):
  9.1  sts get-caller-identity, configured region
  9.2  get-role, attached and inline policies and their documents, tags, instance profiles for LabRole and the caller role
  9.3  iam simulate-principal-policy for LabRole and the caller role
  9.4  ec2 dry-run probes (create-vpc, run-instances t3.micro and m5.4xlarge), other-region describe, organizations describe,
       decode-authorization-message for any encoded failure message found in the saved errors

Only with --include-write-probes (these try to create real IAM objects, and delete them at once if they succeed):
  iam create-policy kvs-probe, iam create-role kvs-probe

Env vars: LABROLE_NAME (default LabRole), CALLER_ROLE (default: taken from the caller ARN), PROBE_REGION (default eu-central-1),
AWS_REGION, EVIDENCE_DIR. Results go to docs/evidence/labrole/. Denied calls save <name>.error.txt next to the other files.
USAGE
}
WRITE=0
for a in "$@"; do
  case "$a" in -h|--help) usage; exit 0 ;; --include-write-probes) WRITE=1 ;; *) usage >&2; die "unknown argument: $a" ;; esac
done
require_session

LABROLE_NAME="${LABROLE_NAME:-LabRole}"
PROBE_REGION="${PROBE_REGION:-eu-central-1}"
if [ -z "${CALLER_ROLE:-}" ]; then
  case "$CALLER_ARN" in
    *:assumed-role/*) CALLER_ROLE="$(printf '%s' "$CALLER_ARN" | cut -d/ -f2)" ;;
    *) CALLER_ROLE="" ;;
  esac
fi
info "LabRole name: $LABROLE_NAME, caller role: ${CALLER_ROLE:-<not a role session>}"
D="labrole"
P() { evidence_path "$D" "$1"; }

run_or_record "$(P 01-caller-identity.json)" aws sts get-caller-identity --output json
printf '%s\n' "$AWS_REGION" >"$(P 01-region.txt)"

dissect_role() { # <role-name> <label>
  local R="$1" L="$2" arn name ver
  run_or_record "$(P "02-$L-get-role.json")" aws iam get-role --role-name "$R" --output json
  run_or_record "$(P "02-$L-attached-policies.json")" aws iam list-attached-role-policies --role-name "$R" --output json
  run_or_record "$(P "02-$L-inline-policy-names.json")" aws iam list-role-policies --role-name "$R" --output json
  run_or_record "$(P "02-$L-tags.json")" aws iam list-role-tags --role-name "$R" --output json
  run_or_record "$(P "02-$L-instance-profiles.json")" aws iam list-instance-profiles-for-role --role-name "$R" --output json
  local attached inline
  attached="$(P "02-$L-attached-policies.json")"
  if [ -f "$attached" ]; then
    for arn in $(aws iam list-attached-role-policies --role-name "$R" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
      name="$(printf '%s' "$arn" | awk -F/ '{print $NF}')"
      run_or_record "$(P "02-$L-policy-$name.json")" aws iam get-policy --policy-arn "$arn" --output json
      ver="$(aws iam get-policy --policy-arn "$arn" --query 'Policy.DefaultVersionId' --output text 2>/dev/null || true)"
      if [ -n "$ver" ]; then
        run_or_record "$(P "02-$L-policy-$name-$ver.json")" aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" --output json
      fi
    done
  fi
  inline="$(P "02-$L-inline-policy-names.json")"
  if [ -f "$inline" ]; then
    for name in $(aws iam list-role-policies --role-name "$R" --query 'PolicyNames[]' --output text 2>/dev/null); do
      run_or_record "$(P "02-$L-inline-$name.json")" aws iam get-role-policy --role-name "$R" --policy-name "$name" --output json
    done
  fi
}
dissect_role "$LABROLE_NAME" "labrole"
[ -z "$CALLER_ROLE" ] || dissect_role "$CALLER_ROLE" "caller"

# Simulation may not reflect the Vocareum SCP, so the live probes below count more.
ACTIONS="iam:CreateRole iam:CreatePolicy iam:AttachRolePolicy iam:PassRole cloudformation:CreateStack ec2:CreateVpc ec2:CreateNatGateway ec2:AllocateAddress ec2:RunInstances lambda:CreateFunction dynamodb:CreateTable ecs:CreateCluster s3:CreateBucket organizations:DescribeOrganization ce:GetCostAndUsage servicequotas:ListServiceQuotas access-analyzer:ValidatePolicy"
simulate() { # <role-name> <label>
  # Take the real ARN from get-role, because a role can have a path (role/some/path/name).
  local arn
  arn="$(aws iam get-role --role-name "$1" --query Role.Arn --output text 2>/dev/null || true)"
  [ -n "$arn" ] || arn="arn:aws:iam::$ACCOUNT_ID:role/$1"
  # shellcheck disable=SC2086
  run_or_record "$(P "03-$2-simulate.json")" aws iam simulate-principal-policy \
    --policy-source-arn "$arn" --action-names $ACTIONS \
    --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output json
}
simulate "$LABROLE_NAME" labrole
[ -z "$CALLER_ROLE" ] || simulate "$CALLER_ROLE" caller

# --dry-run creates nothing: DryRunOperation means allowed, UnauthorizedOperation means denied.
AMI="resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
run_or_record "$(P 04-dryrun-create-vpc.txt)" aws ec2 create-vpc --cidr-block 10.99.0.0/16 --dry-run
run_or_record "$(P 04-dryrun-run-t3micro.txt)" aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --dry-run
run_or_record "$(P 04-dryrun-run-m5-4xlarge.txt)" aws ec2 run-instances --image-id "$AMI" --instance-type m5.4xlarge --dry-run
run_or_record "$(P "04-describe-vpcs-$PROBE_REGION.json")" aws ec2 describe-vpcs --region "$PROBE_REGION" --output json
run_or_record "$(P 04-organizations-describe.json)" aws organizations describe-organization --output json

if [ "$WRITE" -eq 1 ]; then
  warn "Write probes on. Anything that gets created is deleted at once."
  POL_OUT="$(P 04-iam-create-policy.json)"
  run_or_record "$POL_OUT" aws iam create-policy --policy-name kvs-probe \
    --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}]}' --output json
  if [ -f "$POL_OUT" ]; then
    warn "FINDING: iam:CreatePolicy was ALLOWED. Deleting the probe policy."
    aws iam delete-policy --policy-arn "arn:aws:iam::$ACCOUNT_ID:policy/kvs-probe" || warn "delete-policy failed, delete kvs-probe by hand"
  fi
  ROLE_OUT="$(P 04-iam-create-role.json)"
  run_or_record "$ROLE_OUT" aws iam create-role --role-name kvs-probe \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' --output json
  if [ -f "$ROLE_OUT" ]; then
    warn "FINDING: iam:CreateRole was ALLOWED. Deleting the probe role."
    aws iam delete-role --role-name kvs-probe || warn "delete-role failed, delete kvs-probe by hand"
  fi
else
  info "Skipped iam create-policy and create-role probes. Use --include-write-probes to run them."
fi

for f in "$EVIDENCE_DIR/$D/$RUN_TS"-*.error.txt; do
  [ -f "$f" ] || continue
  MSG="$(sed -n 's/.*Encoded authorization failure message: \([A-Za-z0-9_-]*\).*/\1/p' "$f" | head -n1)"
  if [ -n "$MSG" ]; then
    run_or_record "${f%.error.txt}.decoded.json" aws sts decode-authorization-message --encoded-message "$MSG" --output json
  fi
done

info "Done. Files in $EVIDENCE_DIR/$D/ with prefix $RUN_TS"
info "Write docs/labrole.md from these files: for each action write allowed or denied, the source of the deny (SCP, identity policy or implicit, read it from the error text) and the method."
