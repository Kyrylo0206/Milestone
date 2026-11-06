#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/verify-network.sh [stack-name]

Default stack is kvs-network. Reads the stack outputs and checks the VPC, subnets, AZs, route tables,
S3 gateway endpoint, exports and tags with describe-* calls. Only reads, changes nothing.
Exit code is 1 if any check fails. Output is saved to docs/evidence/verify/.

Env vars: AWS_REGION, EVIDENCE_DIR, EXPECTED_VPC_CIDR (default 10.20.0.0/16), OWNER (optional, also checks the Owner tag).
USAGE
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
STACK="${1:-kvs-network}"
EXPECTED_VPC_CIDR="${EXPECTED_VPC_CIDR:-10.20.0.0/16}"
require_session

LOG="$(evidence_path verify "${STACK}-verify.log")"
exec > >(tee "$LOG") 2>&1
echo "verify-network stack=$STACK region=$AWS_REGION time=$(ts)"

PASS=0; FAILN=0
check() { # <description> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS  $1"; else FAILN=$((FAILN+1)); echo "FAIL  $1 (expected '$2', got '$3')"; fi
}
check_true() { # <description> <condition result: 0 is true>
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); echo "PASS  $1"; else FAILN=$((FAILN+1)); echo "FAIL  $1"; fi
}

[ "$(stack_status "$STACK")" != "NONE" ] || { echo "FAIL  stack $STACK does not exist"; exit 1; }
STACK_STATE="$(stack_status "$STACK")"
case "$STACK_STATE" in CREATE_COMPLETE|UPDATE_COMPLETE) STACK_OK=yes ;; *) STACK_OK=no ;; esac
check "stack status is CREATE_COMPLETE or UPDATE_COMPLETE" "yes" "$STACK_OK"

out() { stack_output "$STACK" "$1"; }
VPC="$(out VpcId)"; PUB1="$(out PublicSubnet1Id)"; PUB2="$(out PublicSubnet2Id)"
PRV1="$(out PrivateSubnet1Id)"; PRV2="$(out PrivateSubnet2Id)"
RT_PUB="$(out PublicRouteTableId)"; RT_P1="$(out PrivateRouteTable1Id)"; RT_P2="$(out PrivateRouteTable2Id)"
NAT="$(aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Parameters[?ParameterKey=='EnableNatGateway'].ParameterValue" --output text)"
NAT="${NAT:-false}"
echo "VPC=$VPC NAT_ENABLED=$NAT"

check "VPC CIDR is $EXPECTED_VPC_CIDR" "$EXPECTED_VPC_CIDR" "$(aws ec2 describe-vpcs --vpc-ids "$VPC" --query 'Vpcs[0].CidrBlock' --output text)"
check "VPC DNS support on" "True" "$(aws ec2 describe-vpc-attribute --vpc-id "$VPC" --attribute enableDnsSupport --query 'EnableDnsSupport.Value' --output text | sed 's/^true$/True/')"
check "VPC DNS hostnames on" "True" "$(aws ec2 describe-vpc-attribute --vpc-id "$VPC" --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text | sed 's/^true$/True/')"

check "4 subnets in the VPC" "4" "$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'length(Subnets)' --output text)"
check "4 subnets span 2 distinct AZs" "2" "$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].AvailabilityZone' --output text | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')"
az() { aws ec2 describe-subnets --subnet-ids "$1" --query 'Subnets[0].AvailabilityZone' --output text; }
mapip() { aws ec2 describe-subnets --subnet-ids "$1" --query 'Subnets[0].MapPublicIpOnLaunch' --output text; }
check "public-a and private-a are in the same AZ" "$(az "$PUB1")" "$(az "$PRV1")"
check "public-b and private-b are in the same AZ" "$(az "$PUB2")" "$(az "$PRV2")"
check_true "public a and b are in different AZs" "$([ "$(az "$PUB1")" != "$(az "$PUB2")" ] && echo 0 || echo 1)"
check "public subnet 1 MapPublicIpOnLaunch" "True" "$(mapip "$PUB1")"
check "public subnet 2 MapPublicIpOnLaunch" "True" "$(mapip "$PUB2")"
check "private subnet 1 MapPublicIpOnLaunch" "False" "$(mapip "$PRV1")"
check "private subnet 2 MapPublicIpOnLaunch" "False" "$(mapip "$PRV2")"

assoc() { aws ec2 describe-route-tables --route-table-ids "$1" --query 'RouteTables[0].Associations[?SubnetId!=null].SubnetId' --output text | tr '\t' '\n' | sort | tr '\n' ' '; }
sorted() { printf '%s\n' "$@" | sort | tr '\n' ' '; }
check "public route table is associated with both public subnets" "$(sorted "$PUB1" "$PUB2")" "$(assoc "$RT_PUB")"
check "private route table 1 is associated with private subnet 1 only" "$(sorted "$PRV1")" "$(assoc "$RT_P1")"
check "private route table 2 is associated with private subnet 2 only" "$(sorted "$PRV2")" "$(assoc "$RT_P2")"

default_target() { # <rt> -> target of 0.0.0.0/0 or empty
  aws ec2 describe-route-tables --route-table-ids "$1" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].[GatewayId,NatGatewayId]" --output text | tr '\t' '\n' | grep -v '^None$' | head -n1 || true
}
all_targets() { aws ec2 describe-route-tables --route-table-ids "$1" --query 'RouteTables[0].Routes[].[GatewayId,NatGatewayId]' --output text | tr '\t' '\n' | grep -v '^None$' || true; }
has_prefix() { printf '%s' "$2" | grep -q "^$1" && echo 0 || echo 1; }

PUB_DEF="$(default_target "$RT_PUB")"
check_true "public route table has 0.0.0.0/0 to igw-* (got '$PUB_DEF')" "$(has_prefix igw- "$PUB_DEF")"

for pair in "1:$RT_P1" "2:$RT_P2"; do
  n="${pair%%:*}"; rt="${pair#*:}"
  igw_hits="$(all_targets "$rt" | grep -c '^igw-' || true)"
  check "private route table $n has no route to an igw-*" "0" "$igw_hits"
  def="$(default_target "$rt")"
  if [ "$NAT" = "true" ]; then
    check_true "private route table $n has 0.0.0.0/0 to nat-* (got '$def')" "$(has_prefix nat- "$def")"
  else
    check "private route table $n has no 0.0.0.0/0 route" "" "$def"
  fi
  s3="$(aws ec2 describe-route-tables --route-table-ids "$rt" --query 'RouteTables[0].Routes[?DestinationPrefixListId!=null].[DestinationPrefixListId,GatewayId]' --output text)"
  pl="$(printf '%s' "$s3" | awk '{print $1}')"; vp="$(printf '%s' "$s3" | awk '{print $2}')"
  check_true "private route table $n has S3 prefix list pl-* to vpce-* (got '$pl' '$vp')" "$([ "$(has_prefix pl- "$pl")" = 0 ] && [ "$(has_prefix vpce- "$vp")" = 0 ] && echo 0 || echo 1)"
done

EP="$(out S3GatewayEndpointId)"
check "S3 endpoint type is Gateway" "Gateway" "$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$EP" --query 'VpcEndpoints[0].VpcEndpointType' --output text)"
check "S3 endpoint service name" "com.amazonaws.${AWS_REGION}.s3" "$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$EP" --query 'VpcEndpoints[0].ServiceName' --output text)"
check "S3 endpoint is bound to both private route tables" "$(sorted "$RT_P1" "$RT_P2")" \
  "$(aws ec2 describe-vpc-endpoints --vpc-endpoint-ids "$EP" --query 'VpcEndpoints[0].RouteTableIds' --output text | tr '\t' '\n' | sort | tr '\n' ' ')"

EXPECTED_EXPORTS="VpcId VpcCidr PublicSubnet1Id PublicSubnet2Id PrivateSubnet1Id PrivateSubnet2Id PublicSubnetIds PrivateSubnetIds AvailabilityZones PublicRouteTableId PrivateRouteTable1Id PrivateRouteTable2Id S3GatewayEndpointId"
ALL_EXPORTS="$(aws cloudformation list-exports --query 'Exports[].Name' --output text | tr '\t' '\n')"
for e in $EXPECTED_EXPORTS; do
  check_true "export ${STACK}-$e exists" "$(printf '%s\n' "$ALL_EXPORTS" | grep -qx "${STACK}-$e" && echo 0 || echo 1)"
done

TAGS="$(aws ec2 describe-vpcs --vpc-ids "$VPC" --query 'Vpcs[0].Tags[].[Key,Value]' --output text | tr '\t' '=')"
for kv in "Project=kvs-capstone" "Milestone=m1" "Environment=sandbox" "ManagedBy=cloudformation"; do
  check_true "VPC tag $kv" "$(printf '%s\n' "$TAGS" | grep -qx "$kv" && echo 0 || echo 1)"
done
check_true "VPC has an Owner tag${OWNER:+ =$OWNER}" "$(printf '%s\n' "$TAGS" | grep -qx "Owner=${OWNER:-..*}" && echo 0 || echo 1)"
check_true "VPC has a Name tag" "$(printf '%s\n' "$TAGS" | grep -q '^Name=' && echo 0 || echo 1)"

echo "RESULT: $PASS passed, $FAILN failed"
echo "Evidence: $LOG"
[ "$FAILN" -eq 0 ]
