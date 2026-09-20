#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Optional helper for when you want to reuse a VPC you already have, instead of
# letting Terraform create one for you (its default). Required for the
# CloudFormation and CDK flavours, which always need an existing VPC.
#
#   ./scripts/discover-vpc.sh                        # list what you have
#   ./scripts/discover-vpc.sh --format tfvars        # terraform.tfvars snippet
#   ./scripts/discover-vpc.sh --format cdk           # cdk -c flags
#   ./scripts/discover-vpc.sh --format cfn           # params.json snippet
#   ./scripts/discover-vpc.sh --vpc-id vpc-0abc... --format tfvars
#
# A subnet counts as public when its route table sends 0.0.0.0/0 to an internet
# gateway, which is what the ALB needs and what lets tasks pull images without
# a NAT gateway.
# ---------------------------------------------------------------------------
#
# shellcheck disable=SC2016  # backticks throughout are JMESPath literals, not shell
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

VPC_ID=""
FORMAT="table"
WANT_SUBNETS=2

usage() {
  print_header_help "${BASH_SOURCE[0]}"
  cat <<'EOF'
Options
  --vpc-id ID       Use this VPC instead of auto selecting
  --format FORMAT   table (default) | tfvars | cdk | cfn | env
  --subnets N       How many public subnets to emit (default: 2)
  --region REGION   AWS region
  -h, --help        This help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --vpc-id) VPC_ID="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    --subnets) WANT_SUBNETS="$2"; shift 2 ;;
    --region) export AWS_REGION="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) err "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
done

case "$FORMAT" in
  table | tfvars | cdk | cfn | env) ;;
  *) die "unknown format: $FORMAT (use table, tfvars, cdk, cfn or env)" ;;
esac

require_tools aws jq
REGION="$(canary_region)"

# ---------------------------------------------------------------- pick a VPC --

vpcs_json() {
  awsx ec2 describe-vpcs \
    --query 'Vpcs[].{id:VpcId,cidr:CidrBlock,isDefault:IsDefault,state:State,name:(Tags[?Key==`Name`].Value | [0])}' \
    --output json
}

if [ -z "$VPC_ID" ]; then
  step "looking for VPCs in ${REGION}"
  VPCS="$(vpcs_json)"
  COUNT="$(printf '%s' "$VPCS" | jq 'length')"
  [ "$COUNT" -gt 0 ] || die "no VPCs found in ${REGION}. Pick another region with --region."

  if [ "$FORMAT" = "table" ] || [ "$COUNT" -gt 1 ]; then
    printf '%s' "$VPCS" | jq -r '
      .[] | "  \(.id)\t\(.cidr)\tdefault=\(.isDefault)\t\(.name // "-")"
    ' >&2
  fi

  # Prefer the default VPC, otherwise the first one.
  VPC_ID="$(printf '%s' "$VPCS" | jq -r '[.[] | select(.isDefault == true)][0].id // .[0].id')"
  if [ "$COUNT" -gt 1 ]; then
    note "using ${VPC_ID} (pass --vpc-id to choose another)"
  fi
fi

# ------------------------------------------------------------- inspect subnets --

SUBNETS="$(awsx ec2 describe-subnets \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].{id:SubnetId,az:AvailabilityZone,cidr:CidrBlock,autoPublicIp:MapPublicIpOnLaunch,available:AvailableIpAddressCount,name:(Tags[?Key==`Name`].Value | [0])}' \
  --output json)"

SUBNET_COUNT="$(printf '%s' "$SUBNETS" | jq 'length')"
[ "$SUBNET_COUNT" -gt 0 ] || die "VPC ${VPC_ID} has no subnets"

step "classifying subnets in ${VPC_ID}"

# All route tables in one call, then the public/private decision is made locally:
# a subnet is public when its associated route table (or the VPC main one, if it
# has no explicit association) sends 0.0.0.0/0 to an internet gateway.
ROUTE_TABLES="$(awsx ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables' \
  --output json)"

CLASSIFIED="$(
  jq -n \
    --argjson subnets "$SUBNETS" \
    --argjson routeTables "$ROUTE_TABLES" '
    def has_igw:
      (.Routes // []) | any(
        .DestinationCidrBlock == "0.0.0.0/0"
        and ((.GatewayId // "") | startswith("igw-"))
      );

    ($routeTables | map(select((.Associations // []) | any(.Main == true))) | any(has_igw)) as $mainIsPublic
    | $subnets
    | map(
        . as $subnet
        | ($routeTables | map(select((.Associations // []) | any(.SubnetId == $subnet.id)))) as $explicit
        | .public = (
            if ($explicit | length) > 0
            then ($explicit | any(has_igw))
            else $mainIsPublic
            end
          )
      )
    | sort_by(.az)
  '
)"

PUBLIC_ROWS="$(printf '%s' "$CLASSIFIED" | jq -r '
  .[] | select(.public)
  | "  \(.id)\t\(.az)\t\(.cidr)\tautoPublicIp=\(.autoPublicIp)\tfree=\(.available)\t\(.name // "-")"
')"
PRIVATE_ROWS="$(printf '%s' "$CLASSIFIED" | jq -r '
  .[] | select(.public | not)
  | "  \(.id)\t\(.az)\t\(.cidr)\tfree=\(.available)\t\(.name // "-")"
')"

if [ -n "$PUBLIC_ROWS" ]; then
  ok "public subnets (route 0.0.0.0/0 via an internet gateway)"
  printf '%s\n' "$PUBLIC_ROWS" >&2
fi
if [ -n "$PRIVATE_ROWS" ]; then
  info "private subnets (need NAT or VPC endpoints for ECR, Logs and DynamoDB)"
  printf '%s\n' "$PRIVATE_ROWS" >&2
fi

# One subnet per availability zone: an ALB needs two different AZs, and two
# subnets in the same AZ would not satisfy it.
SELECTED="$(printf '%s' "$CLASSIFIED" | jq -r --argjson want "$WANT_SUBNETS" '
  [.[] | select(.public)]
  | group_by(.az) | map(.[0]) | sort_by(.az)
  | .[0:$want] | map(.id) | join(" ")
')"

SELECTED_COUNT=0
for _subnet in $SELECTED; do
  SELECTED_COUNT=$((SELECTED_COUNT + 1))
done

PUBLIC_AZ_COUNT="$(printf '%s' "$CLASSIFIED" | jq '[.[] | select(.public) | .az] | unique | length')"

if [ "$SELECTED_COUNT" -lt 2 ]; then
  hr
  err "found only ${SELECTED_COUNT} public subnet(s) in ${PUBLIC_AZ_COUNT} availability zone(s)"
  info "an internet facing ALB needs two subnets in different AZs. Options:"
  info "  - pick a VPC that has them:        $0 --vpc-id vpc-...."
  info "  - use private subnets plus NAT:    set service_subnet_ids and assign_public_ip=false"
  exit 1
fi

CSV="$(printf '%s' "$SELECTED" | tr ' ' ',')"
JSON_LIST="$(printf '%s' "$SELECTED" | tr ' ' '\n' | jq -R . | jq -sc .)"

hr
case "$FORMAT" in
  table)
    ok "ready to use"
    info "vpc          ${VPC_ID}"
    info "subnets      ${CSV}"
    hr
    info "next, pick a flavour:"
    info "  $0 --vpc-id ${VPC_ID} --format tfvars"
    info "  $0 --vpc-id ${VPC_ID} --format cdk"
    info "  $0 --vpc-id ${VPC_ID} --format cfn"
    ;;
  tfvars)
    cat <<EOF
# paste into infra/terraform/terraform.tfvars
aws_region        = "${REGION}"
vpc_id            = "${VPC_ID}"
public_subnet_ids = ${JSON_LIST}
EOF
    ;;
  cdk)
    cat <<EOF
# run from infra/cdk
npx cdk deploy -c vpcId=${VPC_ID} -c publicSubnetIds=${CSV}
EOF
    ;;
  cfn)
    cat <<EOF
[
  { "ParameterKey": "VpcId", "ParameterValue": "${VPC_ID}" },
  { "ParameterKey": "PublicSubnetIds", "ParameterValue": "${CSV}" }
]
EOF
    ;;
  env)
    cat <<EOF
export CANARY_VPC_ID=${VPC_ID}
export CANARY_SUBNET_IDS=${CSV}
export AWS_REGION=${REGION}
EOF
    ;;
esac
