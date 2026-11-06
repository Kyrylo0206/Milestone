#!/usr/bin/env bash
# Saves CLI evidence into docs/evidence/cli-views/. Read only; needs a live lab session and the kvs-network stack.
set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
STACK="${STACK_NETWORK:-kvs-network}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${EVIDENCE_DIR:-$ROOT/docs/evidence}/cli-views"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"

run() { # <file name> <command...>
  local name="$1"; shift
  local file="$OUT/$TS-$name.txt"
  { echo "COMMAND: $*"; echo; "$@" 2>&1; } > "$file"
  echo "saved  $file"
}

aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1 || { echo "No valid AWS session. Start the lab and refresh ~/.aws/credentials."; exit 1; }

VPC="$(aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text 2>/dev/null)"
[ -n "$VPC" ] && [ "$VPC" != "None" ] || { echo "Stack $STACK not found in $REGION."; exit 1; }

run 01-caller-identity aws sts get-caller-identity --region "$REGION" --output json
run 01-voclabs-attached-policies aws iam list-attached-role-policies --role-name voclabs --output table
run 01-voclabs-inline-policy-names aws iam list-role-policies --role-name voclabs --output table
run 02-labrole-lookup aws iam get-role --role-name LabRole --output json

run 03-stack-status aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].[StackName,StackStatus,CreationTime]" --output table
run 03-stack-resources aws cloudformation describe-stack-resources --stack-name "$STACK" --region "$REGION" \
  --query "StackResources[].[LogicalResourceId,ResourceType,ResourceStatus]" --output table
run 03-stack-outputs aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" \
  --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output table
run 04-stack-events aws cloudformation describe-stack-events --stack-name "$STACK" --region "$REGION" \
  --query "reverse(StackEvents)[].[Timestamp,LogicalResourceId,ResourceStatus]" --output table

run 05-vpc aws ec2 describe-vpcs --vpc-ids "$VPC" --region "$REGION" \
  --query "Vpcs[].[VpcId,CidrBlock,State,Tags[?Key=='Name']|[0].Value]" --output table
run 06-subnets aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --region "$REGION" \
  --query "Subnets[].[Tags[?Key=='Name']|[0].Value,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch,AvailableIpAddressCount]" --output table
run 07-route-tables aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" --region "$REGION" \
  --query "RouteTables[].[Tags[?Key=='Name']|[0].Value,Routes[].[DestinationCidrBlock||DestinationPrefixListId,GatewayId]]" --output json
run 08-internet-gateway aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" --region "$REGION" \
  --query "InternetGateways[].[InternetGatewayId,Attachments[0].State,Tags[?Key=='Name']|[0].Value]" --output table

run 09-quota-vpcs-per-region aws service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE --region "$REGION" \
  --query "Quota.[QuotaName,Value]" --output table
run 09-quota-subnets-per-vpc aws service-quotas get-service-quota --service-code vpc --quota-code L-407747CB --region "$REGION" \
  --query "Quota.[QuotaName,Value]" --output table
run 09-quota-igw-per-region aws service-quotas get-service-quota --service-code vpc --quota-code L-A4707A72 --region "$REGION" \
  --query "Quota.[QuotaName,Value]" --output table
run 09-quota-nat-per-az aws service-quotas get-service-quota --service-code vpc --quota-code L-FE5A380F --region "$REGION" \
  --query "Quota.[QuotaName,Value]" --output table

run 10-cost-this-month aws ce get-cost-and-usage --region us-east-1 \
  --time-period "Start=$(date -u +%Y-%m-01),End=$(date -u -v+1d +%Y-%m-%d 2>/dev/null || date -u -d tomorrow +%Y-%m-%d)" \
  --granularity MONTHLY --metrics UnblendedCost --output json

echo "Done. Files are in $OUT"
