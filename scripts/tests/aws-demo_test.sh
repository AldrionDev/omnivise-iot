#!/usr/bin/env bash

suite "aws-demo CLI contract"

assert_rc() {
  local name="$1" expected="$2"
  shift 2

  run_capture "$@"

  if [ "$RC" -eq "$expected" ]; then
    _pass "$name"
  else
    _fail "$name" "expected exit $expected, got $RC; stdout=[$OUT] stderr=[$ERR]"
  fi
}

# Six-state purity: at most one STATE line, and when present its value must be
# one of the six lifecycle states. Pass "required" when a STATE line must exist.
assert_lifecycle_state() {
  local name="$1" output="$2" requirement="${3:-optional}"
  local states="" count=0 value=""

  states="$(printf '%s\n' "$output" | sed -n 's/^STATE: //p')"
  [ -z "$states" ] || count="$(printf '%s\n' "$states" | wc -l)"

  if [ "$count" -gt 1 ]; then
    _fail "$name" "expected at most one STATE line, got: $output"
    return
  fi

  if [ "$count" -eq 0 ]; then
    if [ "$requirement" = "required" ]; then
      _fail "$name" "expected a STATE line, got: $output"
    else
      _pass "$name"
    fi
    return
  fi

  value="$states"
  case "$value" in
    DOWN-CLEAN|DOWN-DIRTY|UP-NO-CREDENTIAL|UP-RESTART-REQUIRED|READY|VIOLATION)
      _pass "$name"
      ;;
    *)
      _fail "$name" "STATE [$value] is not one of the six lifecycle states"
      ;;
  esac
}

assert_rc "no command is usage error" 3 \
  bash "$AWS_DEMO_SH"

assert_contains "no command prints usage" "$ERR" "Usage:"

assert_rc "unknown command is usage error" 3 \
  bash "$AWS_DEMO_SH" definitely-not-a-command

assert_contains "unknown command names the bad command" "$ERR" "definitely-not-a-command"

assert_rc "status rejects unexpected arguments" 3 \
  bash "$AWS_DEMO_SH" status unexpected

assert_contains "status argument error prints usage" "$ERR" "Usage:"

suite "aws-demo security preflight"

fake_bin_dir="$TEST_TMP_ROOT/preflight-bin"
mkdir -p "$fake_bin_dir"

cat > "$fake_bin_dir/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ge 3 ] && [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' "${FAKE_AWS_CLI_HISTORY:-disabled}"
  exit 0
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$fake_bin_dir/aws"

run_capture env \
  PATH="$fake_bin_dir:$PATH" \
  FAKE_AWS_CLI_HISTORY=enabled \
  bash "$AWS_DEMO_SH" status

assert_eq "cli_history enabled exits 3" "3" "$RC"
assert_contains "cli_history enabled explains failure" "$ERR" "cli_history"
assert_not_contains "cli_history failure emits no lifecycle state" "$OUT$ERR" "DOWN-CLEAN"
assert_not_contains "cli_history failure emits no READY state" "$OUT$ERR" "READY"

run_capture env \
  PATH="$fake_bin_dir:$PATH" \
  FAKE_AWS_CLI_HISTORY=disabled \
  AWS_ENDPOINT_URL="http://127.0.0.1:4566" \
  bash "$AWS_DEMO_SH" status

assert_eq "AWS_ENDPOINT_URL override exits 3" "3" "$RC"
assert_contains "endpoint override explains failure" "$ERR" "AWS_ENDPOINT_URL"

run_capture bash -x "$AWS_DEMO_SH" status

assert_eq "xtrace exits 3" "3" "$RC"
assert_contains "xtrace explains failure" "$ERR" "xtrace"

suite "aws-demo AWS region and absence contract"

region_bin="$TEST_TMP_ROOT/region-bin"
mkdir -p "$region_bin"

cat > "$region_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AIDAEXAMPLE"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  case "${FAKE_CLUSTER_RESULT:-notfound}" in
    notfound)
      printf 'An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found\n' >&2
      exit 254
      ;;
    denied)
      printf 'An error occurred (AccessDeniedException) when calling the DescribeCluster operation: denied\n' >&2
      exit 254
      ;;
    network)
      printf 'Could not connect to the endpoint URL\n' >&2
      exit 255
      ;;
  esac
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$region_bin/aws"

region_log="$TEST_TMP_ROOT/region-aws.log"
: > "$region_log"

run_capture env \
  PATH="$region_bin:$PATH" \
  FAKE_AWS_LOG="$region_log" \
  FAKE_CLUSTER_RESULT=notfound \
  bash "$AWS_DEMO_SH" status

assert_contains "describe-cluster pins eu-north-1" \
  "$(cat "$region_log")" \
  "eks describe-cluster --region eu-north-1"

run_capture env \
  PATH="$region_bin:$PATH" \
  FAKE_AWS_LOG="$region_log" \
  FAKE_CLUSTER_RESULT=denied \
  bash "$AWS_DEMO_SH" status

assert_eq "cluster AccessDenied is environment failure" "3" "$RC"
assert_not_contains "cluster AccessDenied is not DOWN-CLEAN" "$OUT$ERR" "DOWN-CLEAN"

run_capture env \
  PATH="$region_bin:$PATH" \
  FAKE_AWS_LOG="$region_log" \
  FAKE_CLUSTER_RESULT=network \
  bash "$AWS_DEMO_SH" status

assert_eq "cluster network failure exits 3" "3" "$RC"
assert_not_contains "cluster network failure is not DOWN-CLEAN" "$OUT$ERR" "DOWN-CLEAN"

suite "aws-demo DOWN state classification"

down_bin="$TEST_TMP_ROOT/down-bin"
mkdir -p "$down_bin"

cat > "$down_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AIDAEXAMPLE"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  printf 'An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found\n' >&2
  exit 254
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-vpcs" ]; then
  case "${FAKE_VPC_LEFTOVER:-0}" in
    0)
      printf '%s\n' '{"Vpcs":[]}'
      ;;
    1)
      printf '%s\n' '{"Vpcs":[{"VpcId":"vpc-123"}]}'
      ;;
  esac
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-subnets" ]; then
  printf '%s\n' '{"Subnets":[]}'
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-internet-gateways" ]; then
  printf '%s\n' '{"InternetGateways":[]}'
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-route-tables" ]; then
  printf '%s\n' '{"RouteTables":[]}'
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-volumes" ]; then
  printf '%s\n' '{"Volumes":[]}'
  exit 0
fi

if [ "$1" = "elbv2" ] && [ "$2" = "describe-load-balancers" ]; then
  printf '%s\n' '{"LoadBalancers":[]}'
  exit 0
fi

if [ "$1" = "elbv2" ] && [ "$2" = "describe-tags" ]; then
  printf '%s\n' '{"TagDescriptions":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  case "${FAKE_USER_RESULT:-missing}" in
    missing)
      printf 'An error occurred (NoSuchEntity) when calling the GetUser operation: missing\n' >&2
      exit 254
      ;;
    present)
      printf '%s\n' '{"User":{"UserName":"omnivise-iot-jenkins-bootstrap"}}'
      exit 0
      ;;
    denied)
      printf 'An error occurred (AccessDenied) when calling the GetUser operation: denied\n' >&2
      exit 254
      ;;
  esac
fi

if [ "$1" = "iam" ] && [ "$2" = "get-policy" ]; then
  printf 'An error occurred (NoSuchEntity) when calling the GetPolicy operation: missing\n' >&2
  exit 254
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  printf 'An error occurred (NoSuchEntity) when calling the GetRole operation: missing\n' >&2
  exit 254
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$down_bin/aws"

down_log="$TEST_TMP_ROOT/down-aws.log"

: > "$down_log"
run_capture env \
  PATH="$down_bin:$PATH" \
  FAKE_AWS_LOG="$down_log" \
  FAKE_VPC_LEFTOVER=0 \
  FAKE_USER_RESULT=missing \
  bash "$AWS_DEMO_SH" status

assert_eq "clean teardown exits 0" "0" "$RC"
assert_contains "clean teardown reports DOWN-CLEAN" "$OUT" "DOWN-CLEAN"
assert_contains "clean teardown prints NEXT" "$OUT" "NEXT:"
assert_lifecycle_state "clean teardown STATE is a lifecycle state" "$OUT" required

: > "$down_log"
run_capture env \
  PATH="$down_bin:$PATH" \
  FAKE_AWS_LOG="$down_log" \
  FAKE_VPC_LEFTOVER=1 \
  FAKE_USER_RESULT=missing \
  bash "$AWS_DEMO_SH" status

assert_eq "VPC leftover exits 1" "1" "$RC"
assert_contains "VPC leftover reports DOWN-DIRTY" "$OUT" "DOWN-DIRTY"
assert_lifecycle_state "VPC leftover STATE is a lifecycle state" "$OUT" required

: > "$down_log"
run_capture env \
  PATH="$down_bin:$PATH" \
  FAKE_AWS_LOG="$down_log" \
  FAKE_VPC_LEFTOVER=0 \
  FAKE_USER_RESULT=present \
  bash "$AWS_DEMO_SH" status

assert_eq "bootstrap user leftover exits 1" "1" "$RC"
assert_contains "bootstrap user leftover reports DOWN-DIRTY" "$OUT" "DOWN-DIRTY"

: > "$down_log"
run_capture env \
  PATH="$down_bin:$PATH" \
  FAKE_AWS_LOG="$down_log" \
  FAKE_VPC_LEFTOVER=0 \
  FAKE_USER_RESULT=denied \
  bash "$AWS_DEMO_SH" status

assert_eq "IAM AccessDenied while checking absence exits 3" "3" "$RC"
assert_not_contains "IAM AccessDenied is not DOWN-CLEAN" "$OUT$ERR" "DOWN-CLEAN"

suite "aws-demo complete DOWN leftover scan"

full_down_bin="$TEST_TMP_ROOT/full-down-bin"
mkdir -p "$full_down_bin"

cat > "$full_down_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '{"Account":"554422868760","Arn":"%s","UserId":"AIDAEXAMPLE"}\n' \
    "${FAKE_OPERATOR_ARN:-arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session}"
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  printf 'An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found\n' >&2
  exit 254
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-vpcs" ]; then
  case "${FAKE_VPC_RESPONSE:-empty}" in
    empty) printf '%s\n' '{"Vpcs":[]}' ;;
    missing-key) printf '%s\n' '{}' ;;
  esac
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-subnets" ]; then
  case "${FAKE_SUBNET_LEFTOVER:-0}" in
    0) printf '%s\n' '{"Subnets":[]}' ;;
    1) printf '%s\n' '{"Subnets":[{"SubnetId":"subnet-123"}]}' ;;
  esac
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-internet-gateways" ]; then
  case "${FAKE_IGW_LEFTOVER:-0}" in
    0) printf '%s\n' '{"InternetGateways":[]}' ;;
    1) printf '%s\n' '{"InternetGateways":[{"InternetGatewayId":"igw-123"}]}' ;;
  esac
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-route-tables" ]; then
  case "${FAKE_ROUTE_TABLE_LEFTOVER:-0}" in
    0) printf '%s\n' '{"RouteTables":[]}' ;;
    1) printf '%s\n' '{"RouteTables":[{"RouteTableId":"rtb-123"}]}' ;;
  esac
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-volumes" ]; then
  case "${FAKE_EBS_LEFTOVER:-0}" in
    0) printf '%s\n' '{"Volumes":[]}' ;;
    1) printf '%s\n' '{"Volumes":[{"VolumeId":"vol-123"}]}' ;;
  esac
  exit 0
fi

if [ "$1" = "elbv2" ] && [ "$2" = "describe-load-balancers" ]; then
  case "${FAKE_ALB_LEFTOVER:-0}" in
    0) printf '%s\n' '{"LoadBalancers":[]}' ;;
    missing-key) printf '%s\n' '{}' ;;
    1)
      printf '%s\n' '{"LoadBalancers":[{"LoadBalancerArn":"arn:aws:elasticloadbalancing:eu-north-1:554422868760:loadbalancer/app/example/123"}]}'
      ;;
  esac
  exit 0
fi

if [ "$1" = "elbv2" ] && [ "$2" = "describe-tags" ]; then
  if [ "${FAKE_ALB_TAGS_RESPONSE:-valid}" = "missing-key" ]; then
    printf '%s\n' '{}'
    exit 0
  fi

  case "${FAKE_ALB_TAGS:-default}" in
    live)
      tags='[{"Key":"elbv2.k8s.aws/cluster","Value":"omnivise-iot"},{"Key":"ingress.k8s.aws/stack","Value":"omnivise-iot/frontend"},{"Key":"ingress.k8s.aws/resource","Value":"LoadBalancer"}]'
      ;;
    other-ingress)
      tags='[{"Key":"elbv2.k8s.aws/cluster","Value":"omnivise-iot"},{"Key":"ingress.k8s.aws/stack","Value":"omnivise-iot/other-ingress"}]'
      ;;
    service-nlb)
      tags='[{"Key":"elbv2.k8s.aws/cluster","Value":"omnivise-iot"}]'
      ;;
    foreign)
      tags='[{"Key":"elbv2.k8s.aws/cluster","Value":"other-cluster"},{"Key":"ingress.k8s.aws/stack","Value":"omnivise-iot/frontend"}]'
      ;;
    untagged)
      tags='[]'
      ;;
    *)
      tags='[{"Key":"elbv2.k8s.aws/cluster","Value":"omnivise-iot"},{"Key":"ingress.k8s.aws/stack","Value":"omnivise-iot/frontend"}]'
      ;;
  esac
  printf '{"TagDescriptions":[{"ResourceArn":"arn:aws:elasticloadbalancing:eu-north-1:554422868760:loadbalancer/app/example/123","Tags":%s}]}\n' "$tags"
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  printf 'An error occurred (NoSuchEntity) when calling the GetUser operation: missing\n' >&2
  exit 254
fi

if [ "$1" = "iam" ] && [ "$2" = "get-policy" ]; then
  if [ "${FAKE_POLICY_LEFTOVER:-0}" = "1" ]; then
    printf '%s\n' '{
      "Policy":{
        "PolicyName":"omnivise-iot-aws-aws-load-balancer-controller",
        "Arn":"arn:aws:iam::554422868760:policy/omnivise-iot-aws-aws-load-balancer-controller"
      }
    }'
    exit 0
  fi

  printf 'An error occurred (NoSuchEntity) when calling the GetPolicy operation: policy not found\n' >&2
  exit 254
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  role_name=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--role-name" ]; then
      role_name="$2"
      break
    fi
    shift
  done

  if [ "${FAKE_ROLE_LEFTOVER:-}" = "$role_name" ]; then
    printf '{"Role":{"RoleName":"%s"}}\n' "$role_name"
    exit 0
  fi

  printf 'An error occurred (NoSuchEntity) when calling the GetRole operation: missing\n' >&2
  exit 254
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$full_down_bin/aws"

full_down_log="$TEST_TMP_ROOT/full-down-aws.log"

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  bash "$AWS_DEMO_SH" status

assert_eq "complete clean scan exits 0" "0" "$RC"
assert_contains "complete clean scan is DOWN-CLEAN" "$OUT" "DOWN-CLEAN"

log_contents="$(cat "$full_down_log")"
assert_contains "subnet scan pins region" \
  "$log_contents" \
  "ec2 describe-subnets --region eu-north-1"

assert_contains "EBS scan pins cluster tag selector" \
  "$log_contents" \
  "ec2 describe-volumes --region eu-north-1 --filters Name=tag:ebs.csi.aws.com/cluster-name,Values=omnivise-iot"

assert_contains "ALB scan pins region" \
  "$log_contents" \
  "elbv2 describe-load-balancers --region eu-north-1"


assert_contains "Internet Gateway scan pins region and Terraform ownership tags" \
  "$log_contents" \
  "ec2 describe-internet-gateways --region eu-north-1"

assert_contains "route table scan pins region and Terraform ownership tags" \
  "$log_contents" \
  "ec2 describe-route-tables --region eu-north-1"

assert_contains "DOWN scan checks ALB controller managed IAM policy" \
  "$log_contents" \
  "iam get-policy --policy-arn arn:aws:iam::554422868760:policy/omnivise-iot-aws-aws-load-balancer-controller"

for role in \
  omnivise-iot-aws-eks-cluster \
  omnivise-iot-aws-eks-node \
  omnivise-iot-aws-ebs-csi \
  omnivise-iot-aws-aws-load-balancer-controller
do
  assert_contains "DOWN scan checks role $role" \
    "$log_contents" \
    "iam get-role --role-name $role"
done

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  FAKE_SUBNET_LEFTOVER=1 \
  bash "$AWS_DEMO_SH" status

assert_eq "subnet leftover exits 1" "1" "$RC"
assert_contains "subnet leftover is DOWN-DIRTY" "$OUT" "DOWN-DIRTY"

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  FAKE_EBS_LEFTOVER=1 \
  bash "$AWS_DEMO_SH" status

assert_eq "EBS leftover exits 1" "1" "$RC"
assert_contains "EBS leftover is DOWN-DIRTY" "$OUT" "DOWN-DIRTY"

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  FAKE_ALB_LEFTOVER=1 \
  bash "$AWS_DEMO_SH" status

assert_eq "attributable ALB leftover exits 1" "1" "$RC"
assert_contains "attributable ALB leftover is DOWN-DIRTY" "$OUT" "DOWN-DIRTY"

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  FAKE_ROLE_LEFTOVER=omnivise-iot-aws-ebs-csi \
  bash "$AWS_DEMO_SH" status

assert_eq "platform IAM role leftover exits 1" "1" "$RC"
assert_contains "platform IAM role leftover is DOWN-DIRTY" "$OUT" "DOWN-DIRTY"

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  FAKE_IGW_LEFTOVER=1 \
  bash "$AWS_DEMO_SH" status

assert_eq "Internet Gateway leftover exits 1" "1" "$RC"
assert_contains "Internet Gateway leftover is DOWN-DIRTY" "$OUT" "STATE: DOWN-DIRTY"

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  FAKE_ROUTE_TABLE_LEFTOVER=1 \
  bash "$AWS_DEMO_SH" status

assert_eq "route table leftover exits 1" "1" "$RC"
assert_contains "route table leftover is DOWN-DIRTY" "$OUT" "STATE: DOWN-DIRTY"

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  FAKE_POLICY_LEFTOVER=1 \
  bash "$AWS_DEMO_SH" status

assert_eq "ALB controller managed IAM policy leftover exits 1" "1" "$RC"
assert_contains \
  "ALB controller managed IAM policy leftover is DOWN-DIRTY" \
  "$OUT" \
  "STATE: DOWN-DIRTY"

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  FAKE_VPC_RESPONSE=missing-key \
  bash "$AWS_DEMO_SH" status

assert_eq "describe-vpcs without Vpcs array exits 3" "3" "$RC"
assert_not_contains \
  "describe-vpcs without Vpcs array is never DOWN-CLEAN" \
  "$OUT" \
  "STATE: DOWN-CLEAN"

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  FAKE_ALB_LEFTOVER=missing-key \
  bash "$AWS_DEMO_SH" status

assert_eq "describe-load-balancers without LoadBalancers array exits 3" "3" "$RC"
assert_not_contains \
  "describe-load-balancers without LoadBalancers array is never DOWN-CLEAN" \
  "$OUT" \
  "STATE: DOWN-CLEAN"

: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  FAKE_ALB_LEFTOVER=1 \
  FAKE_ALB_TAGS_RESPONSE=missing-key \
  bash "$AWS_DEMO_SH" status

assert_eq "describe-tags without TagDescriptions array exits 3" "3" "$RC"
assert_not_contains \
  "describe-tags without TagDescriptions array is never DOWN-CLEAN" \
  "$OUT" \
  "STATE: DOWN-CLEAN"

# M13: ELBv2 attribution is the controller cluster tag alone (live evidence:
# elbv2.k8s.aws/cluster, ingress.k8s.aws/stack, ingress.k8s.aws/resource).
for m13_case in \
  "live:1:DOWN-DIRTY:exact live frontend ALB tags" \
  "other-ingress:1:DOWN-DIRTY:ALB of another Ingress in the cluster" \
  "service-nlb:1:DOWN-DIRTY:controller Service/NLB without ingress stack tag" \
  "foreign:0:DOWN-CLEAN:foreign-cluster load balancer" \
  "untagged:0:DOWN-CLEAN:untagged unrelated load balancer"
do
  IFS=: read -r m13_tags m13_rc m13_state m13_label <<< "$m13_case"
  : > "$full_down_log"
  run_capture env \
    PATH="$full_down_bin:$PATH" \
    FAKE_AWS_LOG="$full_down_log" \
    FAKE_ALB_LEFTOVER=1 \
    FAKE_ALB_TAGS="$m13_tags" \
    bash "$AWS_DEMO_SH" status

  assert_eq "M13 $m13_label exits $m13_rc" "$m13_rc" "$RC"
  assert_contains "M13 $m13_label reports $m13_state" "$OUT" "STATE: $m13_state"
done

suite "aws-demo UP-NO-CREDENTIAL happy path"

up_bin="$TEST_TMP_ROOT/up-bin"
mkdir -p "$up_bin"

cat > "$up_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AROAEXAMPLE"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  printf '%s\n' '{
    "cluster":{
      "name":"omnivise-iot",
      "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
      "status":"ACTIVE"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  printf '%s\n' '{
    "User":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-groups-for-user" ]; then
  printf '%s\n' '{"Groups":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-user-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-user-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-bootstrap-assume-delivery"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user-policy" ]; then
  printf '%s\n' '{
    "UserName":"omnivise-iot-jenkins-bootstrap",
    "PolicyName":"omnivise-iot-jenkins-bootstrap-assume-delivery",
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"sts:AssumeRole",
        "Resource":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  printf '%s\n' '{
    "Role":{
      "RoleName":"omnivise-iot-jenkins-delivery",
      "Arn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "AssumeRolePolicyDocument":{
        "Version":"2012-10-17",
        "Statement":[{
          "Effect":"Allow",
          "Principal":{
            "AWS":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
          },
          "Action":"sts:AssumeRole"
        }]
      }
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-role-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-role-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-delivery-describe-cluster"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role-policy" ]; then
  printf '%s\n' '{
    "RoleName":"omnivise-iot-jenkins-delivery",
    "PolicyName":"omnivise-iot-jenkins-delivery-describe-cluster",
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"eks:DescribeCluster",
        "Resource":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-access-entry" ]; then
  principal=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--principal-arn" ]; then
      principal="$2"
      break
    fi
    shift
  done

  case "$principal" in
    arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap)
      printf 'An error occurred (ResourceNotFoundException) when calling the DescribeAccessEntry operation: not found\n' >&2
      exit 254
      ;;
    arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery)
      printf '%s\n' '{
        "accessEntry":{
          "principalArn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
          "type":"STANDARD",
          "kubernetesGroups":[]
        }
      }'
      exit 0
      ;;
  esac
fi

if [ "$1" = "eks" ] && [ "$2" = "list-associated-access-policies" ]; then
  printf '%s\n' '{
    "associatedAccessPolicies":[{
      "policyArn":"arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy",
      "accessScope":{
        "type":"namespace",
        "namespaces":["omnivise-iot"]
      }
    }]
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
  printf '%s\n' '{"AccessKeyMetadata":[]}'
  exit 0
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$up_bin/aws"

up_log="$TEST_TMP_ROOT/up-aws.log"
: > "$up_log"

run_capture env \
  PATH="$up_bin:$PATH" \
  FAKE_AWS_LOG="$up_log" \
  HOME="$TEST_TMP_ROOT/up-home" \
  bash "$AWS_DEMO_SH" status

assert_eq "ACTIVE exact identity with zero keys exits 1" "1" "$RC"
assert_contains "zero-key state is UP-NO-CREDENTIAL" "$OUT" "UP-NO-CREDENTIAL"
assert_contains "zero-key state points to issue-credential" "$OUT" "issue-credential"
assert_lifecycle_state "zero-key STATE is a lifecycle state" "$OUT" required

up_log_contents="$(cat "$up_log")"

assert_contains "UP check inspects bootstrap access keys" \
  "$up_log_contents" \
  "iam list-access-keys --user-name omnivise-iot-jenkins-bootstrap"

assert_contains "UP check inspects delivery access entry" \
  "$up_log_contents" \
  "eks describe-access-entry --region eu-north-1 --cluster-name omnivise-iot --principal-arn arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"

assert_contains "UP check verifies bootstrap has no EKS access entry" \
  "$up_log_contents" \
  "eks describe-access-entry --region eu-north-1 --cluster-name omnivise-iot --principal-arn arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"

assert_contains "UP check inspects associated access policies" \
  "$up_log_contents" \
  "eks list-associated-access-policies --region eu-north-1 --cluster-name omnivise-iot --principal-arn arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"

suite "aws-demo UP invariant violations"

violation_bin="$TEST_TMP_ROOT/up-violation-bin"
mkdir -p "$violation_bin"

cat > "$violation_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AROAEXAMPLE"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  status="${FAKE_CLUSTER_STATUS:-ACTIVE}"
  printf '{
    "cluster":{
      "name":"omnivise-iot",
      "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
      "status":"%s"
    }
  }\n' "$status"
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  if [ "${FAKE_BOOTSTRAP_ABSENT:-0}" = "1" ]; then
    printf 'An error occurred (NoSuchEntity) when calling the GetUser operation: missing\n' >&2
    exit 254
  fi
  case "${FAKE_BOOTSTRAP_GET_USER_ERROR:-none}" in
    access-denied)
      printf 'An error occurred (AccessDenied) when calling the GetUser operation: not authorized\n' >&2
      exit 254
      ;;
    throttling)
      printf 'An error occurred (Throttling) when calling the GetUser operation: Rate exceeded\n' >&2
      exit 254
      ;;
    network)
      printf 'Could not connect to the endpoint URL: "https://iam.amazonaws.com/"\n' >&2
      exit 255
      ;;
  esac
  case "${FAKE_BOOTSTRAP_GET_USER_MALFORMED:-none}" in
    missing-user)
      printf '%s\n' '{"Unexpected":{}}'
      exit 0
      ;;
    not-json)
      printf '%s\n' 'this is not json'
      exit 0
      ;;
  esac
  if [ "${FAKE_BOOTSTRAP_ARN_DRIFT:-0}" = "1" ]; then
    printf '%s\n' '{"User":{"UserName":"omnivise-iot-jenkins-bootstrap","Arn":"arn:aws:iam::554422868760:user/other/omnivise-iot-jenkins-bootstrap"}}'
    exit 0
  fi
  if [ "${FAKE_BOOTSTRAP_BOUNDARY:-0}" = "1" ]; then
    printf '%s\n' '{
      "User":{
        "UserName":"omnivise-iot-jenkins-bootstrap",
        "Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap",
        "PermissionsBoundary":{
          "PermissionsBoundaryArn":"arn:aws:iam::554422868760:policy/unexpected"
        }
      }
    }'
  else
    printf '%s\n' '{
      "User":{
        "UserName":"omnivise-iot-jenkins-bootstrap",
        "Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
      }
    }'
  fi
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-groups-for-user" ]; then
  printf '%s\n' '{"Groups":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-user-policies" ]; then
  if [ "${FAKE_BOOTSTRAP_MANAGED_POLICY:-0}" = "1" ]; then
    printf '%s\n' '{"AttachedPolicies":[{"PolicyName":"Unexpected","PolicyArn":"arn:aws:iam::aws:policy/ReadOnlyAccess"}]}'
  else
    printf '%s\n' '{"AttachedPolicies":[]}'
  fi
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-user-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-bootstrap-assume-delivery"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user-policy" ]; then
  extra=""
  if [ "${FAKE_BOOTSTRAP_POLICY_CONDITION:-0}" = "1" ]; then
    extra=',"Condition":{"StringEquals":{"aws:RequestedRegion":"eu-north-1"}}'
  fi
  printf '{
    "UserName":"omnivise-iot-jenkins-bootstrap",
    "PolicyName":"omnivise-iot-jenkins-bootstrap-assume-delivery",
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"sts:AssumeRole",
        "Resource":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"%s
      }]
    }
  }\n' "$extra"
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  trusted_arn="arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"

  if [ "${FAKE_BAD_DELIVERY_TRUST:-0}" = "1" ]; then
    trusted_arn="arn:aws:iam::554422868760:root"
  fi

  trust_extra=""
  if [ "${FAKE_DELIVERY_TRUST_CONDITION:-0}" = "1" ]; then
    trust_extra=',"Condition":{"Bool":{"aws:MultiFactorAuthPresent":"false"}}'
  fi

  principal_extra=""
  if [ "${FAKE_DELIVERY_TRUST_EXTRA_PRINCIPAL:-0}" = "1" ]; then
    principal_extra=',"Service":"ec2.amazonaws.com"'
  fi

  printf '{
    "Role":{
      "RoleName":"omnivise-iot-jenkins-delivery",
      "Arn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "AssumeRolePolicyDocument":{
        "Version":"2012-10-17",
        "Statement":[{
          "Effect":"Allow",
          "Principal":{"AWS":"%s"%s},
          "Action":"sts:AssumeRole"%s
        }]
      }
    }
  }\n' "$trusted_arn" "$principal_extra" "$trust_extra"
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-role-policies" ]; then
  if [ "${FAKE_DELIVERY_MANAGED_POLICY:-0}" = "1" ]; then
    printf '%s\n' '{"AttachedPolicies":[{"PolicyName":"AdministratorAccess","PolicyArn":"arn:aws:iam::aws:policy/AdministratorAccess"}]}'
  else
    printf '%s\n' '{"AttachedPolicies":[]}'
  fi
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-role-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-delivery-describe-cluster"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role-policy" ]; then
  extra=""
  if [ "${FAKE_DELIVERY_POLICY_NOTRESOURCE:-0}" = "1" ]; then
    extra=',"NotResource":"arn:aws:eks:eu-north-1:554422868760:cluster/other"'
  fi
  printf '{
    "RoleName":"omnivise-iot-jenkins-delivery",
    "PolicyName":"omnivise-iot-jenkins-delivery-describe-cluster",
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"eks:DescribeCluster",
        "Resource":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"%s
      }]
    }
  }\n' "$extra"
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-access-entry" ]; then
  principal=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--principal-arn" ]; then
      principal="$2"
      break
    fi
    shift
  done

  case "$principal" in
    arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap)
      printf 'An error occurred (ResourceNotFoundException) when calling the DescribeAccessEntry operation: not found\n' >&2
      exit 254
      ;;
    arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery)
      group_json='[]'
      if [ "${FAKE_DELIVERY_K8S_GROUP:-0}" = "1" ]; then
        group_json='["unexpected"]'
      fi

      printf '{
        "accessEntry":{
          "principalArn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
          "type":"STANDARD",
          "kubernetesGroups":%s
        }
      }\n' "$group_json"
      exit 0
      ;;
  esac
fi

if [ "$1" = "eks" ] && [ "$2" = "list-associated-access-policies" ]; then
  namespace="omnivise-iot"

  if [ "${FAKE_BAD_ACCESS_SCOPE:-0}" = "1" ]; then
    namespace="default"
  fi

  printf '{
    "associatedAccessPolicies":[{
      "policyArn":"arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy",
      "accessScope":{
        "type":"namespace",
        "namespaces":["%s"]
      }
    }]
  }\n' "$namespace"
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
  case "$(cat "${FAKE_VIOLATION_KEY_STATE_FILE:-/dev/null}" 2>/dev/null || true)" in
    one)
      printf '%s\n' '{"AccessKeyMetadata":[{"UserName":"omnivise-iot-jenkins-bootstrap","AccessKeyId":"AKIA1234567890ABCDEF","Status":"Active"}]}'
      ;;
    *)
      printf '%s\n' '{"AccessKeyMetadata":[]}'
      ;;
  esac
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "delete-access-key" ]; then
  printf '%s\n' zero > "${FAKE_VIOLATION_KEY_STATE_FILE:?}"
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "create-access-key" ]; then
  printf 'create-access-key must never be reached in drift tests\n' >&2
  exit 99
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$violation_bin/aws"

violation_log="$TEST_TMP_ROOT/up-violation-aws.log"

run_violation_case() {
  : > "$violation_log"
  run_capture env \
    PATH="$violation_bin:$PATH" \
    FAKE_AWS_LOG="$violation_log" \
    HOME="$TEST_TMP_ROOT/up-violation-home" \
    "$@" \
    bash "$AWS_DEMO_SH" status
}

run_violation_case FAKE_CLUSTER_STATUS=CREATING
assert_eq "non-ACTIVE cluster exits 2" "2" "$RC"
assert_contains "non-ACTIVE cluster is VIOLATION" "$OUT" "VIOLATION"
assert_lifecycle_state "non-ACTIVE cluster STATE is a lifecycle state" "$OUT" required
assert_contains "non-ACTIVE cluster prints NEXT" "$OUT" "NEXT:"

run_violation_case FAKE_BOOTSTRAP_BOUNDARY=1
assert_eq "bootstrap permissions boundary exits 2" "2" "$RC"
assert_contains "bootstrap permissions boundary is VIOLATION" "$OUT" "VIOLATION"
assert_lifecycle_state "bootstrap permissions boundary STATE is a lifecycle state" "$OUT" required
assert_contains "bootstrap permissions boundary prints NEXT" "$OUT" "NEXT:"

run_violation_case FAKE_BOOTSTRAP_MANAGED_POLICY=1
assert_eq "bootstrap managed policy exits 2" "2" "$RC"
assert_contains "bootstrap managed policy is VIOLATION" "$OUT" "VIOLATION"

run_violation_case FAKE_BAD_DELIVERY_TRUST=1
assert_eq "wrong delivery trust exits 2" "2" "$RC"
assert_contains "wrong delivery trust is VIOLATION" "$OUT" "VIOLATION"
assert_lifecycle_state "wrong delivery trust STATE is a lifecycle state" "$OUT" required
assert_contains "wrong delivery trust prints NEXT" "$OUT" "NEXT:"

run_violation_case FAKE_DELIVERY_K8S_GROUP=1
assert_eq "delivery kubernetesGroups mismatch exits 2" "2" "$RC"
assert_contains "delivery kubernetesGroups mismatch is VIOLATION" "$OUT" "VIOLATION"

run_violation_case FAKE_BAD_ACCESS_SCOPE=1
assert_eq "wrong namespace access scope exits 2" "2" "$RC"
assert_contains "wrong namespace access scope is VIOLATION" "$OUT" "VIOLATION"

# L5: exact policy/trust document shape; extra semantic keys are drift.
for l5_case in \
  "FAKE_BOOTSTRAP_POLICY_CONDITION=1:bootstrap inline policy with Condition" \
  "FAKE_DELIVERY_TRUST_CONDITION=1:delivery trust with Condition" \
  "FAKE_DELIVERY_TRUST_EXTRA_PRINCIPAL=1:delivery trust with extra principal type" \
  "FAKE_DELIVERY_POLICY_NOTRESOURCE=1:delivery inline policy with NotResource"
do
  run_violation_case "${l5_case%%:*}"
  assert_eq "${l5_case#*:} exits 2" "2" "$RC"
  assert_contains "${l5_case#*:} is VIOLATION" "$OUT" "STATE: VIOLATION"
done

run_violation_case
assert_eq "exact Terraform-shaped policies remain UP-NO-CREDENTIAL" "1" "$RC"
assert_contains "exact Terraform-shaped policies are not VIOLATION" "$OUT" "STATE: UP-NO-CREDENTIAL"

suite "aws-demo credential state classification"

credential_bin="$TEST_TMP_ROOT/credential-bin"
mkdir -p "$credential_bin"

cat > "$credential_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AROAEXAMPLE"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  printf '%s\n' '{
    "cluster":{
      "name":"omnivise-iot",
      "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
      "status":"ACTIVE"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  printf '%s\n' '{
    "User":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-groups-for-user" ]; then
  case "${FAKE_GROUPS_RESPONSE:-empty}" in
    empty) printf '%s\n' '{"Groups":[]}' ;;
    missing-key) printf '%s\n' '{}' ;;
  esac
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-user-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-user-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-bootstrap-assume-delivery"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user-policy" ]; then
  printf '%s\n' '{
    "UserName":"omnivise-iot-jenkins-bootstrap",
    "PolicyName":"omnivise-iot-jenkins-bootstrap-assume-delivery",
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"sts:AssumeRole",
        "Resource":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  printf '%s\n' '{
    "Role":{
      "RoleName":"omnivise-iot-jenkins-delivery",
      "Arn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "AssumeRolePolicyDocument":{
        "Version":"2012-10-17",
        "Statement":[{
          "Effect":"Allow",
          "Principal":{
            "AWS":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
          },
          "Action":"sts:AssumeRole"
        }]
      }
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-role-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-role-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-delivery-describe-cluster"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role-policy" ]; then
  printf '%s\n' '{
    "RoleName":"omnivise-iot-jenkins-delivery",
    "PolicyName":"omnivise-iot-jenkins-delivery-describe-cluster",
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"eks:DescribeCluster",
        "Resource":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-access-entry" ]; then
  principal=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--principal-arn" ]; then
      principal="$2"
      break
    fi
    shift
  done

  case "$principal" in
    arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap)
      printf 'An error occurred (ResourceNotFoundException) when calling the DescribeAccessEntry operation: not found\n' >&2
      exit 254
      ;;
    arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery)
      printf '%s\n' '{
        "accessEntry":{
          "principalArn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
          "type":"STANDARD",
          "kubernetesGroups":[]
        }
      }'
      exit 0
      ;;
  esac
fi

if [ "$1" = "eks" ] && [ "$2" = "list-associated-access-policies" ]; then
  printf '%s\n' '{
    "associatedAccessPolicies":[{
      "policyArn":"arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy",
      "accessScope":{
        "type":"namespace",
        "namespaces":["omnivise-iot"]
      }
    }]
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
  case "${FAKE_KEY_STATE:-zero}" in
    zero)
      printf '%s\n' '{"AccessKeyMetadata":[]}'
      ;;
    one-active)
      printf '%s\n' '{
        "AccessKeyMetadata":[{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIAEXAMPLE000000001",
          "Status":"Active"
        }]
      }'
      ;;
    one-inactive)
      printf '%s\n' '{
        "AccessKeyMetadata":[{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIAEXAMPLE000000001",
          "Status":"Inactive"
        }]
      }'
      ;;
    two-active)
      printf '%s\n' '{
        "AccessKeyMetadata":[
          {
            "UserName":"omnivise-iot-jenkins-bootstrap",
            "AccessKeyId":"AKIAEXAMPLE000000001",
            "Status":"Active"
          },
          {
            "UserName":"omnivise-iot-jenkins-bootstrap",
            "AccessKeyId":"AKIAEXAMPLE000000002",
            "Status":"Active"
          }
        ]
      }'
      ;;
  esac
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "create-access-key" ]; then
  printf '%s\n' '{
    "AccessKey":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "AccessKeyId":"AKIAEXAMPLE000000099",
      "Status":"Active",
      "SecretAccessKey":"exampleSecretThatMustNeverAppearInLogs0000"
    }
  }'
  exit 0
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$credential_bin/aws"

credential_log="$TEST_TMP_ROOT/credential-aws.log"

run_credential_status() {
  : > "$credential_log"
  run_capture env \
    PATH="$credential_bin:$PATH" \
    FAKE_AWS_LOG="$credential_log" \
    HOME="$TEST_TMP_ROOT/credential-home" \
    "$@" \
    bash "$AWS_DEMO_SH" status
}

run_credential_status FAKE_KEY_STATE=one-inactive
assert_eq "one inactive key exits 2" "2" "$RC"
assert_contains "one inactive key is VIOLATION" "$OUT" "VIOLATION"

run_credential_status FAKE_KEY_STATE=two-active
assert_eq "two access keys exit 2" "2" "$RC"
assert_contains "two access keys are VIOLATION" "$OUT" "VIOLATION"

run_credential_status FAKE_KEY_STATE=one-active
assert_eq "one active key proceeds into local readiness" "2" "$RC"
assert_contains \
  "one active key reaches local readiness layer" \
  "$OUT" \
  "VIOLATION"

: > "$credential_log"
run_capture env \
  PATH="$credential_bin:$PATH" \
  FAKE_AWS_LOG="$credential_log" \
  HOME="$TEST_TMP_ROOT/credential-home" \
  FAKE_KEY_STATE=two-active \
  bash "$AWS_DEMO_SH" issue-credential

assert_eq "issue-credential with two keys is violation" "2" "$RC"
assert_not_contains \
  "issue-credential with two keys does not create another key" \
  "$(cat "$credential_log")" \
  "iam create-access-key"

issue_one_key_root="$TEST_TMP_ROOT/issue-one-key"
mkdir -p "$issue_one_key_root"
issue_one_key_id_file="$issue_one_key_root/secrets/omnivise_iot_aws_access_key_id"
mkdir -p "$issue_one_key_root/secrets"

run_issue_one_active_key() {
  : > "$credential_log"
  run_capture env \
    PATH="$credential_bin:$PATH" \
    FAKE_AWS_LOG="$credential_log" \
    HOME="$TEST_TMP_ROOT/credential-home" \
    FAKE_KEY_STATE=one-active \
    OMNIVISE_JENKINS_PLATFORM_DIR="$issue_one_key_root" \
    bash "$AWS_DEMO_SH" issue-credential
}

# A: sole active key, local access-key ID file missing.
rm -f "$issue_one_key_id_file"
run_issue_one_active_key

assert_eq "issue one active key with missing local ID exits 2" "2" "$RC"
assert_contains "issue one active key with missing local ID is VIOLATION" "$OUT" "STATE: VIOLATION"
assert_lifecycle_state "issue one active key with missing local ID STATE is a lifecycle state" "$OUT" required
assert_contains "issue one active key with missing local ID prints NEXT" "$OUT" "NEXT:"
assert_not_contains \
  "issue one active key with missing local ID does not create a key" \
  "$(cat "$credential_log")" \
  "iam create-access-key"
assert_not_contains \
  "issue one active key with missing local ID emits no seventh state" \
  "$OUT" \
  "CREDENTIAL-ALREADY-ISSUED"

# B: sole active key, local access-key ID does not match.
printf '%s' "AKIAEXAMPLE000000777" > "$issue_one_key_id_file"
chmod 600 "$issue_one_key_id_file"
run_issue_one_active_key

assert_eq "issue one active key with mismatched local ID exits 2" "2" "$RC"
assert_contains "issue one active key with mismatched local ID is VIOLATION" "$OUT" "STATE: VIOLATION"
assert_lifecycle_state "issue one active key with mismatched local ID STATE is a lifecycle state" "$OUT" required
assert_contains "issue one active key with mismatched local ID prints NEXT" "$OUT" "NEXT:"
assert_not_contains \
  "issue one active key with mismatched local ID does not create a key" \
  "$(cat "$credential_log")" \
  "iam create-access-key"
assert_not_contains \
  "issue one active key with mismatched local ID emits no seventh state" \
  "$OUT" \
  "CREDENTIAL-ALREADY-ISSUED"

# B2: matching content but local ID file mode is not 0600.
printf '%s' "AKIAEXAMPLE000000001" > "$issue_one_key_id_file"
chmod 644 "$issue_one_key_id_file"
run_issue_one_active_key

assert_eq "issue one active key with non-0600 local ID exits 2" "2" "$RC"
assert_contains "issue one active key with non-0600 local ID is VIOLATION" "$OUT" "STATE: VIOLATION"
assert_lifecycle_state "issue one active key with non-0600 local ID STATE is a lifecycle state" "$OUT" required
assert_contains "issue one active key with non-0600 local ID prints NEXT" "$OUT" "NEXT:"

# C: sole active key matches the local ID. Secret file and Jenkins container
# are deliberately absent: they are not needed to decide issue idempotency.
chmod 600 "$issue_one_key_id_file"
run_issue_one_active_key

assert_eq "issue one active key with matching local ID is idempotent" "0" "$RC"
assert_not_contains \
  "idempotent issue-credential does not create another key" \
  "$(cat "$credential_log")" \
  "iam create-access-key"
assert_not_contains \
  "idempotent issue-credential emits no seventh state" \
  "$OUT" \
  "CREDENTIAL-ALREADY-ISSUED"
assert_not_contains \
  "idempotent issue-credential does not claim an unverified lifecycle state" \
  "$OUT" \
  "STATE:"
assert_contains "idempotent issue-credential points to status" "$OUT" "NEXT:"
assert_lifecycle_state "idempotent issue-credential output has no invalid STATE" "$OUT"

run_credential_status FAKE_GROUPS_RESPONSE=missing-key
assert_eq "list-groups-for-user without Groups array exits 3" "3" "$RC"
assert_not_contains \
  "list-groups-for-user without Groups array is never READY" \
  "$OUT" \
  "READY"
assert_not_contains \
  "list-groups-for-user without Groups array is never UP-NO-CREDENTIAL" \
  "$OUT" \
  "UP-NO-CREDENTIAL"

suite "aws-demo issue-credential pre-create gate"

gate_bin="$TEST_TMP_ROOT/gate-bin"
mkdir -p "$gate_bin"

cat > "$gate_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

# Runtime verification after credential creation.
case "${AWS_ACCESS_KEY_ID:-}" in
  AKIA1234567890ABCDEF)
    if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
      printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap","UserId":"AIDABOOTSTRAP"}'
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
      printf 'An error occurred (AccessDeniedException) when calling the DescribeCluster operation: not authorized\n' >&2
      exit 254
    fi

    if [ "$1" = "sts" ] && [ "$2" = "assume-role" ]; then
      role_arn=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--role-arn" ]; then
          role_arn="$2"
          break
        fi
        shift
      done

      case "$role_arn" in
        arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery)
          printf '%s\n' '{
            "Credentials":{
              "AccessKeyId":"ASIADELIVERY00000001",
              "SecretAccessKey":"deliverySecret0123456789abcdefghijklMN",
              "SessionToken":"delivery-session-token",
              "Expiration":"2099-01-01T00:00:00Z"
            },
            "AssumedRoleUser":{
              "Arn":"arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/aws-demo-runtime"
            }
          }'
          exit 0
          ;;
        arn:aws:iam::554422868760:role/AdminAssumeRole)
          printf 'An error occurred (AccessDenied) when calling the AssumeRole operation: not authorized\n' >&2
          exit 254
          ;;
      esac
    fi
    ;;

  ASIADELIVERY00000001)
    if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
      printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/aws-demo-runtime","UserId":"AROAX:aws-demo-runtime"}'
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
      printf '%s\n' '{
        "cluster":{
          "name":"omnivise-iot",
          "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
          "status":"ACTIVE",
          "endpoint":"https://example.eks.local",
          "certificateAuthority":{"data":"RkFLRS1DQQ=="}
        }
      }'
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "list-clusters" ]; then
      printf 'An error occurred (AccessDeniedException) when calling the ListClusters operation: not authorized\n' >&2
      exit 254
    fi

    if [ "$1" = "iam" ] && [ "$2" = "list-users" ]; then
      printf 'An error occurred (AccessDenied) when calling the ListUsers operation: not authorized\n' >&2
      exit 254
    fi
    ;;
esac


if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AROAEXAMPLE"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  printf '%s\n' '{
    "cluster":{
      "name":"omnivise-iot",
      "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
      "status":"ACTIVE"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  printf '%s\n' '{
    "User":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-groups-for-user" ]; then
  printf '%s\n' '{"Groups":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-user-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-user-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-bootstrap-assume-delivery"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user-policy" ]; then
  printf '%s\n' '{
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"sts:AssumeRole",
        "Resource":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  printf '%s\n' '{
    "Role":{
      "RoleName":"omnivise-iot-jenkins-delivery",
      "Arn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "AssumeRolePolicyDocument":{
        "Version":"2012-10-17",
        "Statement":[{
          "Effect":"Allow",
          "Principal":{"AWS":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"},
          "Action":"sts:AssumeRole"
        }]
      }
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-role-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-role-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-delivery-describe-cluster"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role-policy" ]; then
  printf '%s\n' '{
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"eks:DescribeCluster",
        "Resource":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-access-entry" ]; then
  principal=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--principal-arn" ]; then
      principal="$2"
      break
    fi
    shift
  done

  if [ "$principal" = "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap" ]; then
    printf 'An error occurred (ResourceNotFoundException) when calling the DescribeAccessEntry operation: not found\n' >&2
    exit 254
  fi

  printf '%s\n' '{
    "accessEntry":{
      "principalArn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "type":"STANDARD",
      "kubernetesGroups":[]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "list-associated-access-policies" ]; then
  printf '%s\n' '{
    "associatedAccessPolicies":[{
      "policyArn":"arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy",
      "accessScope":{"type":"namespace","namespaces":["omnivise-iot"]}
    }]
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
  if [ -n "${OMNIVISE_JENKINS_PLATFORM_DIR:-}/secrets/omnivise_iot_aws_secret_access_key" ] &&
     [ -s "${OMNIVISE_JENKINS_PLATFORM_DIR:-}/secrets/omnivise_iot_aws_secret_access_key" ]; then
    printf '%s\n' '{
      "AccessKeyMetadata":[{
        "UserName":"omnivise-iot-jenkins-bootstrap",
        "AccessKeyId":"AKIA1234567890ABCDEF",
        "Status":"Active"
      }]
    }'
  else
    printf '%s\n' '{"AccessKeyMetadata":[]}'
  fi
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "create-access-key" ]; then
  printf '%s\n' '{
    "AccessKey":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "AccessKeyId":"AKIA1234567890ABCDEF",
      "Status":"Active",
      "SecretAccessKey":"0123456789abcdefghijklmnopqrstuvwxYZAB12"
    }
  }'
  exit 0
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$gate_bin/aws"

cat > "$gate_bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"

if [ "$1" = "inspect" ]; then
  case "${FAKE_CONTAINER_STATE:-ok}" in
    missing)
      printf 'Error: No such object\n' >&2
      exit 1
      ;;
    stopped)
      printf '%s\n' 'false'
      exit 0
      ;;
    ok|bad-mount)
      if [[ "$*" == *'.State.Running'* ]]; then
        printf '%s\n' 'true'
        exit 0
      fi

      if [[ "$*" == *'.Mounts'* ]]; then
        id_source="${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_access_key_id"
        secret_source="${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_secret_access_key"

        if [ "${FAKE_CONTAINER_STATE:-ok}" = "bad-mount" ]; then
          id_source="${id_source}.wrong"
        fi

        printf '[{"Destination":"/run/secrets/omnivise_iot_aws_access_key_id","Source":"%s"},{"Destination":"/run/secrets/omnivise_iot_aws_secret_access_key","Source":"%s"}]\n' \
          "$id_source" \
          "$secret_source"
        exit 0
      fi
      ;;
  esac
fi

printf 'unexpected fake docker call: %s\n' "$*" >&2
exit 99
FAKEDOCKER
chmod +x "$gate_bin/docker"

cat > "$gate_bin/kubectl" <<'FAKEKUBECTL'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"auth can-i create deployments"*"-n omnivise-iot"* ]]; then
  printf '%s\n' yes
  exit 0
fi

if [[ "$*" == *"auth can-i create namespaces"* ]]; then
  printf '%s\n' no
  exit 1
fi

if [[ "$*" == *"auth can-i get secrets"*"-n kube-system"* ]]; then
  printf '%s\n' no
  exit 1
fi

if [[ "$*" == *"auth can-i create clusterrolebindings"* ]]; then
  printf '%s\n' no
  exit 1
fi

printf 'unexpected fake kubectl call: %s\n' "$*" >&2
exit 99
FAKEKUBECTL
chmod +x "$gate_bin/kubectl"


gate_root="$TEST_TMP_ROOT/gate-files"
mkdir -p "$gate_root"

gate_id_file="$gate_root/secrets/omnivise_iot_aws_access_key_id"
gate_secret_file="$gate_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$gate_root/secrets"

prepare_gate_files() {
  rm -f "$gate_id_file" "$gate_secret_file"
  : > "$gate_id_file"
  : > "$gate_secret_file"
  chmod 600 "$gate_id_file" "$gate_secret_file"
}

run_gate_issue() {
  : > "$TEST_TMP_ROOT/gate-aws.log"
  : > "$TEST_TMP_ROOT/gate-docker.log"

  run_capture env \
    PATH="$gate_bin:$PATH" \
    FAKE_AWS_LOG="$TEST_TMP_ROOT/gate-aws.log" \
    FAKE_DOCKER_LOG="$TEST_TMP_ROOT/gate-docker.log" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$gate_root" \
    "$@" \
    bash "$AWS_DEMO_SH" issue-credential
}

prepare_gate_files
rm -f "$gate_secret_file"

run_gate_issue FAKE_CONTAINER_STATE=ok

assert_eq "missing secret file is violation" "2" "$RC"
assert_not_contains \
  "missing secret file blocks access-key creation" \
  "$(cat "$TEST_TMP_ROOT/gate-aws.log")" \
  "iam create-access-key"

prepare_gate_files
chmod 644 "$gate_secret_file"

run_gate_issue FAKE_CONTAINER_STATE=ok

assert_eq "wrong secret mode is violation" "2" "$RC"
assert_not_contains \
  "wrong secret mode blocks access-key creation" \
  "$(cat "$TEST_TMP_ROOT/gate-aws.log")" \
  "iam create-access-key"

prepare_gate_files

run_gate_issue FAKE_CONTAINER_STATE=missing

assert_eq "missing Jenkins container is violation before create" "2" "$RC"
assert_not_contains \
  "missing container blocks access-key creation" \
  "$(cat "$TEST_TMP_ROOT/gate-aws.log")" \
  "iam create-access-key"

prepare_gate_files

run_gate_issue FAKE_CONTAINER_STATE=bad-mount

assert_eq "wrong Jenkins mount source is violation" "2" "$RC"
assert_not_contains \
  "wrong mount blocks access-key creation" \
  "$(cat "$TEST_TMP_ROOT/gate-aws.log")" \
  "iam create-access-key"

prepare_gate_files

run_gate_issue FAKE_CONTAINER_STATE=ok

assert_eq "valid pre-create gate reaches creation layer" "1" "$RC"
assert_contains \
  "valid pre-create gate invokes create-access-key" \
  "$(cat "$TEST_TMP_ROOT/gate-aws.log")" \
  "iam create-access-key --user-name omnivise-iot-jenkins-bootstrap"

suite "aws-demo lock contract"

lock_bin="$TEST_TMP_ROOT/lock-bin"
mkdir -p "$lock_bin"

cat > "$lock_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$lock_bin/aws"

lock_root="$TEST_TMP_ROOT/lock-files"
mkdir -p "$lock_root"

lock_id_file="$lock_root/secrets/omnivise_iot_aws_access_key_id"
lock_secret_file="$lock_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$lock_root/secrets"

: > "$lock_id_file"
: > "$lock_secret_file"
chmod 600 "$lock_id_file" "$lock_secret_file"

lock_log="$TEST_TMP_ROOT/lock-aws.log"

exec {holder_fd}<>"$lock_id_file"
flock -n -x "$holder_fd"

: > "$lock_log"
run_capture env \
  PATH="$lock_bin:$PATH" \
  FAKE_AWS_LOG="$lock_log" \
  OMNIVISE_JENKINS_PLATFORM_DIR="$lock_root" \
  bash "$AWS_DEMO_SH" issue-credential

assert_eq "issue lock contention exits 3" "3" "$RC"
assert_contains "issue lock contention explains failure" "$ERR" "lock"
assert_not_contains \
  "issue lock contention performs no access-key mutation" \
  "$(cat "$lock_log")" \
  "create-access-key"

: > "$lock_log"
run_capture env \
  PATH="$credential_bin:$PATH" \
  FAKE_AWS_LOG="$lock_log" \
  FAKE_KEY_STATE="one-active" \
  OMNIVISE_JENKINS_PLATFORM_DIR="$lock_root" \
  bash "$AWS_DEMO_SH" status

assert_eq "status lock contention exits 3" "3" "$RC"
assert_contains "status lock contention explains failure" "$ERR" "lock"

flock -u "$holder_fd"
exec {holder_fd}>&-

suite "aws-demo credential creation safety"

create_bin="$TEST_TMP_ROOT/create-bin"
mkdir -p "$create_bin"

cat > "$create_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

# Runtime verification after credential creation.
case "${AWS_ACCESS_KEY_ID:-}" in
  AKIA1234567890ABCDEF)
    if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
      printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap","UserId":"AIDABOOTSTRAP"}'
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
      printf 'An error occurred (AccessDeniedException) when calling the DescribeCluster operation: not authorized\n' >&2
      exit 254
    fi

    if [ "$1" = "sts" ] && [ "$2" = "assume-role" ]; then
      role_arn=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--role-arn" ]; then
          role_arn="$2"
          break
        fi
        shift
      done

      case "$role_arn" in
        arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery)
          printf '%s\n' '{
            "Credentials":{
              "AccessKeyId":"ASIADELIVERY00000001",
              "SecretAccessKey":"deliverySecret0123456789abcdefghijklMN",
              "SessionToken":"delivery-session-token",
              "Expiration":"2099-01-01T00:00:00Z"
            },
            "AssumedRoleUser":{
              "Arn":"arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/aws-demo-runtime"
            }
          }'
          exit 0
          ;;
        arn:aws:iam::554422868760:role/AdminAssumeRole)
          printf 'An error occurred (AccessDenied) when calling the AssumeRole operation: not authorized\n' >&2
          exit 254
          ;;
      esac
    fi
    ;;

  ASIADELIVERY00000001)
    if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
      printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/aws-demo-runtime","UserId":"AROAX:aws-demo-runtime"}'
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
      printf '%s\n' '{
        "cluster":{
          "name":"omnivise-iot",
          "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
          "status":"ACTIVE",
          "endpoint":"https://example.eks.local",
          "certificateAuthority":{"data":"RkFLRS1DQQ=="}
        }
      }'
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "list-clusters" ]; then
      printf 'An error occurred (AccessDeniedException) when calling the ListClusters operation: not authorized\n' >&2
      exit 254
    fi

    if [ "$1" = "iam" ] && [ "$2" = "list-users" ]; then
      printf 'An error occurred (AccessDenied) when calling the ListUsers operation: not authorized\n' >&2
      exit 254
    fi
    ;;
esac


if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AROAEXAMPLE"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  printf '%s\n' '{
    "cluster":{
      "name":"omnivise-iot",
      "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
      "status":"ACTIVE"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  printf '%s\n' '{
    "User":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-groups-for-user" ]; then
  printf '%s\n' '{"Groups":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-user-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-user-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-bootstrap-assume-delivery"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user-policy" ]; then
  printf '%s\n' '{
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"sts:AssumeRole",
        "Resource":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  printf '%s\n' '{
    "Role":{
      "RoleName":"omnivise-iot-jenkins-delivery",
      "Arn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "AssumeRolePolicyDocument":{
        "Version":"2012-10-17",
        "Statement":[{
          "Effect":"Allow",
          "Principal":{"AWS":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"},
          "Action":"sts:AssumeRole"
        }]
      }
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-role-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-role-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-delivery-describe-cluster"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role-policy" ]; then
  printf '%s\n' '{
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"eks:DescribeCluster",
        "Resource":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-access-entry" ]; then
  principal=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--principal-arn" ]; then
      principal="$2"
      break
    fi
    shift
  done

  if [ "$principal" = "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap" ]; then
    printf 'An error occurred (ResourceNotFoundException) when calling the DescribeAccessEntry operation: not found\n' >&2
    exit 254
  fi

  printf '%s\n' '{
    "accessEntry":{
      "principalArn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "type":"STANDARD",
      "kubernetesGroups":[]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "list-associated-access-policies" ]; then
  printf '%s\n' '{
    "associatedAccessPolicies":[{
      "policyArn":"arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy",
      "accessScope":{"type":"namespace","namespaces":["omnivise-iot"]}
    }]
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
  count_file="${FAKE_LIST_COUNT_FILE:?}"
  count=0
  [ -f "$count_file" ] && count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s' "$count" > "$count_file"

  if [ "${FAKE_KEYS_RESPONSE:-valid}" = "missing-key" ]; then
    printf '%s\n' '{}'
    exit 0
  fi

  if [ "$count" -le "${FAKE_ZERO_LISTS:-1}" ]; then
    printf '%s\n' '{"AccessKeyMetadata":[]}'
  else
    printf '%s\n' '{
      "AccessKeyMetadata":[{
        "UserName":"omnivise-iot-jenkins-bootstrap",
        "AccessKeyId":"AKIA1234567890ABCDEF",
        "Status":"Active"
      }]
    }'
  fi
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "create-access-key" ]; then
  # Deterministic local write failure after a successful IAM create: replace
  # the target file with a directory so the in-place write fails even as root.
  case "${FAKE_CREATE_BREAK:-none}" in
    secret-file)
      rm -f "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_secret_access_key"
      mkdir "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_secret_access_key"
      ;;
    id-file)
      rm -f "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_access_key_id"
      mkdir "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_access_key_id"
      ;;
  esac

  case "${FAKE_CREATE_RESULT:-valid}" in
    missing-secret)
      printf '%s\n' '{
        "AccessKey":{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIA1234567890ABCDEF",
          "Status":"Active"
        }
      }'
      ;;
    inactive-status)
      printf '%s\n' '{
        "AccessKey":{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIA1234567890ABCDEF",
          "Status":"Inactive",
          "SecretAccessKey":"0123456789abcdefghijklmnopqrstuvwxYZAB12"
        }
      }'
      ;;
    wrong-user)
      printf '%s\n' '{
        "AccessKey":{
          "UserName":"someone-else",
          "AccessKeyId":"AKIA1234567890ABCDEF",
          "Status":"Active",
          "SecretAccessKey":"0123456789abcdefghijklmnopqrstuvwxYZAB12"
        }
      }'
      ;;
    not-json)
      printf '%s\n' 'this is not json'
      ;;
    valid)
      printf '%s\n' '{
        "AccessKey":{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIA1234567890ABCDEF",
          "Status":"Active",
          "SecretAccessKey":"0123456789abcdefghijklmnopqrstuvwxYZAB12"
        }
      }'
      ;;
    malformed-id)
      printf '%s\n' '{
        "AccessKey":{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"BAD",
          "Status":"Active",
          "SecretAccessKey":"0123456789abcdefghijklmnopqrstuvwxYZAB12"
        }
      }'
      ;;
    malformed-secret)
      printf '%s\n' '{
        "AccessKey":{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIA1234567890ABCDEF",
          "Status":"Active",
          "SecretAccessKey":"short"
        }
      }'
      ;;
  esac
  exit 0
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$create_bin/aws"

cat > "$create_bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "inspect" ]; then
  if [[ "$*" == *'.State.Running'* ]]; then
    printf '%s\n' true
    exit 0
  fi

  if [[ "$*" == *'.Mounts'* ]]; then
    printf '[{"Destination":"/run/secrets/omnivise_iot_aws_access_key_id","Source":"%s"},{"Destination":"/run/secrets/omnivise_iot_aws_secret_access_key","Source":"%s"}]\n' \
      "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_access_key_id" \
      "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_secret_access_key"
    exit 0
  fi
fi

printf 'unexpected fake docker call: %s\n' "$*" >&2
exit 99
FAKEDOCKER
chmod +x "$create_bin/docker"

cat > "$create_bin/kubectl" <<'FAKEKUBECTL'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"auth can-i create deployments"*"-n omnivise-iot"* ]]; then
  printf '%s\n' yes
  exit 0
fi

if [[ "$*" == *"auth can-i create namespaces"* ]]; then
  printf '%s\n' no
  exit 1
fi

if [[ "$*" == *"auth can-i get secrets"*"-n kube-system"* ]]; then
  printf '%s\n' no
  exit 1
fi

if [[ "$*" == *"auth can-i create clusterrolebindings"* ]]; then
  printf '%s\n' no
  exit 1
fi

printf 'unexpected fake kubectl call: %s\n' "$*" >&2
exit 99
FAKEKUBECTL
chmod +x "$create_bin/kubectl"


create_root="$TEST_TMP_ROOT/create-files"
mkdir -p "$create_root"

create_id_file="$create_root/secrets/omnivise_iot_aws_access_key_id"
create_secret_file="$create_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$create_root/secrets"

prepare_create_files() {
  rm -rf "$create_id_file" "$create_secret_file"
  printf '%s' OLD-ID > "$create_id_file"
  printf '%s' OLD-SECRET > "$create_secret_file"
  chmod 600 "$create_id_file" "$create_secret_file"
}

run_create_issue() {
  local list_count_file="$TEST_TMP_ROOT/create-list-count"
  rm -f "$list_count_file"

  : > "$TEST_TMP_ROOT/create-aws.log"

  run_capture env \
    PATH="$create_bin:$PATH" \
    FAKE_AWS_LOG="$TEST_TMP_ROOT/create-aws.log" \
    FAKE_LIST_COUNT_FILE="$list_count_file" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$create_root" \
    "$@" \
    bash "$AWS_DEMO_SH" issue-credential
}

prepare_create_files
id_inode_before="$(stat -c '%d:%i' "$create_id_file")"
secret_inode_before="$(stat -c '%d:%i' "$create_secret_file")"

run_create_issue FAKE_CREATE_RESULT=malformed-id FAKE_ZERO_LISTS=99

assert_eq "malformed access-key ID is VIOLATION exit 2" "2" "$RC"
assert_contains "malformed access-key ID reports VIOLATION" "$OUT" "STATE: VIOLATION"
assert_not_contains \
  "malformed access-key ID exposes no recovery suffix" \
  "$OUT" \
  "--key-id BAD"
assert_contains \
  "malformed access-key ID points to key listing for recovery" \
  "$OUT" \
  "aws iam list-access-keys"
assert_eq "malformed ID leaves ID file unchanged" "OLD-ID" "$(cat "$create_id_file")"
assert_eq "malformed ID leaves secret file unchanged" "OLD-SECRET" "$(cat "$create_secret_file")"

prepare_create_files

run_create_issue FAKE_CREATE_RESULT=malformed-secret FAKE_ZERO_LISTS=99

assert_eq "malformed secret is VIOLATION exit 2" "2" "$RC"
assert_contains "malformed secret reports VIOLATION" "$OUT" "STATE: VIOLATION"
assert_contains \
  "malformed secret gives masked recovery selector" \
  "$OUT" \
  "NEXT: run scripts/aws-demo.sh revoke-credential --key-id CDEF"
assert_not_contains "malformed secret never prints full key ID" "$OUT$ERR" "AKIA1234567890ABCDEF"
assert_eq \
  "malformed secret performed exactly one create" \
  "1" \
  "$(grep -c 'create-access-key' "$TEST_TMP_ROOT/create-aws.log")"
assert_not_contains \
  "malformed secret does not roll back" \
  "$(cat "$TEST_TMP_ROOT/create-aws.log")" \
  "delete-access-key"
assert_eq "malformed secret leaves ID file unchanged" "OLD-ID" "$(cat "$create_id_file")"
assert_eq "malformed secret leaves secret file unchanged" "OLD-SECRET" "$(cat "$create_secret_file")"

# M6: further malformed create responses after a successful IAM create.
m6_case() {
  local label="$1" expect_suffix="$2"
  shift 2

  prepare_create_files
  local id_inode secret_inode
  id_inode="$(stat -c '%d:%i' "$create_id_file")"
  secret_inode="$(stat -c '%d:%i' "$create_secret_file")"

  run_create_issue "$@" FAKE_ZERO_LISTS=99

  assert_eq "$label is VIOLATION exit 2" "2" "$RC"
  assert_contains "$label reports VIOLATION" "$OUT" "STATE: VIOLATION"
  assert_eq "$label leaves ID file content unchanged" "OLD-ID" "$(cat "$create_id_file")"
  assert_eq "$label leaves secret file content unchanged" "OLD-SECRET" "$(cat "$create_secret_file")"
  assert_eq "$label preserves ID file inode" "$id_inode" "$(stat -c '%d:%i' "$create_id_file")"
  assert_eq "$label preserves secret file inode" "$secret_inode" "$(stat -c '%d:%i' "$create_secret_file")"
  assert_eq \
    "$label performed exactly one create" \
    "1" \
    "$(grep -c 'create-access-key' "$TEST_TMP_ROOT/create-aws.log")"
  assert_not_contains \
    "$label does not roll back" \
    "$(cat "$TEST_TMP_ROOT/create-aws.log")" \
    "delete-access-key"
  assert_not_contains "$label never prints full key ID" "$OUT$ERR" "AKIA1234567890ABCDEF"
  assert_not_contains \
    "$label never prints the secret" \
    "$OUT$ERR" \
    "0123456789abcdefghijklmnopqrstuvwxYZAB12"

  if [ "$expect_suffix" = "suffix" ]; then
    assert_contains \
      "$label gives masked recovery selector" \
      "$OUT" \
      "NEXT: run scripts/aws-demo.sh revoke-credential --key-id CDEF"
  else
    assert_not_contains "$label exposes no recovery suffix" "$OUT" "--key-id CDEF"
    assert_contains "$label points to key listing for recovery" "$OUT" "aws iam list-access-keys"
  fi
}

m6_case "missing SecretAccessKey" suffix FAKE_CREATE_RESULT=missing-secret
m6_case "non-Active created key" suffix FAKE_CREATE_RESULT=inactive-status
m6_case "create response for another user" no-suffix FAKE_CREATE_RESULT=wrong-user
m6_case "non-JSON create response" no-suffix FAKE_CREATE_RESULT=not-json

# M6 C: secret-file write fails after successful create.
prepare_create_files
id_inode_before="$(stat -c '%d:%i' "$create_id_file")"
run_create_issue FAKE_CREATE_RESULT=valid FAKE_CREATE_BREAK=secret-file FAKE_ZERO_LISTS=99

assert_eq "secret write failure after create is VIOLATION exit 2" "2" "$RC"
assert_contains "secret write failure after create reports VIOLATION" "$OUT" "STATE: VIOLATION"
assert_contains \
  "secret write failure after create gives masked recovery selector" \
  "$OUT" \
  "NEXT: run scripts/aws-demo.sh revoke-credential --key-id CDEF"
assert_eq "secret write failure leaves ID file content unchanged" "OLD-ID" "$(cat "$create_id_file")"
assert_eq "secret write failure preserves ID file inode" "$id_inode_before" "$(stat -c '%d:%i' "$create_id_file")"
if [ -d "$create_secret_file" ] && [ -z "$(ls -A "$create_secret_file")" ]; then
  _pass "secret write failure did not recreate or populate the secret path"
else
  _fail "secret write failure did not recreate or populate the secret path" "secret path changed"
fi
assert_eq \
  "secret write failure performed exactly one create" \
  "1" \
  "$(grep -c 'create-access-key' "$TEST_TMP_ROOT/create-aws.log")"
assert_not_contains \
  "secret write failure does not roll back" \
  "$(cat "$TEST_TMP_ROOT/create-aws.log")" \
  "delete-access-key"
assert_not_contains "secret write failure never prints full key ID" "$OUT$ERR" "AKIA1234567890ABCDEF"
assert_not_contains \
  "secret write failure never prints the secret" \
  "$OUT$ERR" \
  "0123456789abcdefghijklmnopqrstuvwxYZAB12"

# M6 D: ID-file write fails after the secret write succeeded.
prepare_create_files
secret_inode_before="$(stat -c '%d:%i' "$create_secret_file")"
run_create_issue FAKE_CREATE_RESULT=valid FAKE_CREATE_BREAK=id-file FAKE_ZERO_LISTS=99

assert_eq "ID write failure after secret write is VIOLATION exit 2" "2" "$RC"
assert_contains "ID write failure after secret write reports VIOLATION" "$OUT" "STATE: VIOLATION"
assert_not_contains "ID write failure never claims readiness" "$OUT" "READY"
assert_not_contains "ID write failure never claims restart-required" "$OUT" "UP-RESTART-REQUIRED"
assert_contains \
  "ID write failure gives masked recovery selector" \
  "$OUT" \
  "NEXT: run scripts/aws-demo.sh revoke-credential --key-id CDEF"
assert_eq \
  "ID write failure leaves the new secret written in place" \
  "0123456789abcdefghijklmnopqrstuvwxYZAB12" \
  "$(cat "$create_secret_file")"
assert_eq "ID write failure preserves secret file inode" "$secret_inode_before" "$(stat -c '%d:%i' "$create_secret_file")"
if [ -d "$create_id_file" ] && [ -z "$(ls -A "$create_id_file")" ]; then
  _pass "ID write failure did not recreate or populate the ID path"
else
  _fail "ID write failure did not recreate or populate the ID path" "ID path changed"
fi
assert_eq \
  "ID write failure performed exactly one create" \
  "1" \
  "$(grep -c 'create-access-key' "$TEST_TMP_ROOT/create-aws.log")"
assert_not_contains \
  "ID write failure does not roll back" \
  "$(cat "$TEST_TMP_ROOT/create-aws.log")" \
  "delete-access-key"
assert_not_contains "ID write failure never prints full key ID" "$OUT$ERR" "AKIA1234567890ABCDEF"
assert_not_contains \
  "ID write failure never prints the secret" \
  "$OUT$ERR" \
  "0123456789abcdefghijklmnopqrstuvwxYZAB12"
assert_not_contains \
  "M6 cases never place the secret in AWS argv" \
  "$(cat "$TEST_TMP_ROOT/create-aws.log")" \
  "0123456789abcdefghijklmnopqrstuvwxYZAB12"

prepare_create_files
run_create_issue FAKE_KEYS_RESPONSE=missing-key

assert_eq "issue-credential with list-access-keys missing array exits 3" "3" "$RC"
assert_not_contains \
  "issue-credential with list-access-keys missing array does not create a key" \
  "$(cat "$TEST_TMP_ROOT/create-aws.log")" \
  "iam create-access-key"
assert_not_contains \
  "issue-credential with list-access-keys missing array emits no lifecycle state" \
  "$OUT" \
  "STATE:"

prepare_create_files
id_inode_before="$(stat -c '%d:%i' "$create_id_file")"
secret_inode_before="$(stat -c '%d:%i' "$create_secret_file")"

run_create_issue FAKE_CREATE_RESULT=valid FAKE_ZERO_LISTS=1

assert_eq "valid credential creation returns temporary lifecycle exit 1" "1" "$RC"
assert_eq "created access-key ID written in place" "AKIA1234567890ABCDEF" "$(cat "$create_id_file")"
assert_eq "created secret written in place" "0123456789abcdefghijklmnopqrstuvwxYZAB12" "$(cat "$create_secret_file")"
assert_eq "ID file inode preserved" "$id_inode_before" "$(stat -c '%d:%i' "$create_id_file")"
assert_eq "secret file inode preserved" "$secret_inode_before" "$(stat -c '%d:%i' "$create_secret_file")"

assert_not_contains \
  "secret is absent from stdout" \
  "$OUT" \
  "0123456789abcdefghijklmnopqrstuvwxYZAB12"

assert_not_contains \
  "secret is absent from stderr" \
  "$ERR" \
  "0123456789abcdefghijklmnopqrstuvwxYZAB12"

assert_not_contains \
  "secret is absent from AWS argv log" \
  "$(cat "$TEST_TMP_ROOT/create-aws.log")" \
  "0123456789abcdefghijklmnopqrstuvwxYZAB12"

assert_contains \
  "creation uses only bootstrap create-access-key mutation" \
  "$(cat "$TEST_TMP_ROOT/create-aws.log")" \
  "iam create-access-key --user-name omnivise-iot-jenkins-bootstrap"

assert_contains \
  "post-create retry re-lists bootstrap keys" \
  "$(cat "$TEST_TMP_ROOT/create-aws.log")" \
  "iam list-access-keys --user-name omnivise-iot-jenkins-bootstrap"

suite "aws-demo credential creation hardening"

hardening_bin="$TEST_TMP_ROOT/create-hardening-bin"
mkdir -p "$hardening_bin"

cat > "$hardening_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

# Runtime verification after credential creation.
case "${AWS_ACCESS_KEY_ID:-}" in
  AKIA1234567890ABCDEF)
    if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
      printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap","UserId":"AIDABOOTSTRAP"}'
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
      printf 'An error occurred (AccessDeniedException) when calling the DescribeCluster operation: not authorized\n' >&2
      exit 254
    fi

    if [ "$1" = "sts" ] && [ "$2" = "assume-role" ]; then
      role_arn=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--role-arn" ]; then
          role_arn="$2"
          break
        fi
        shift
      done

      case "$role_arn" in
        arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery)
          printf '%s\n' '{
            "Credentials":{
              "AccessKeyId":"ASIADELIVERY00000001",
              "SecretAccessKey":"deliverySecret0123456789abcdefghijklMN",
              "SessionToken":"delivery-session-token",
              "Expiration":"2099-01-01T00:00:00Z"
            },
            "AssumedRoleUser":{
              "Arn":"arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/aws-demo-runtime"
            }
          }'
          exit 0
          ;;
        arn:aws:iam::554422868760:role/AdminAssumeRole)
          printf 'An error occurred (AccessDenied) when calling the AssumeRole operation: not authorized\n' >&2
          exit 254
          ;;
      esac
    fi
    ;;

  ASIADELIVERY00000001)
    if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
      printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/aws-demo-runtime","UserId":"AROAX:aws-demo-runtime"}'
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
      printf '%s\n' '{
        "cluster":{
          "name":"omnivise-iot",
          "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
          "status":"ACTIVE",
          "endpoint":"https://example.eks.local",
          "certificateAuthority":{"data":"RkFLRS1DQQ=="}
        }
      }'
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "list-clusters" ]; then
      printf 'An error occurred (AccessDeniedException) when calling the ListClusters operation: not authorized\n' >&2
      exit 254
    fi

    if [ "$1" = "iam" ] && [ "$2" = "list-users" ]; then
      printf 'An error occurred (AccessDenied) when calling the ListUsers operation: not authorized\n' >&2
      exit 254
    fi
    ;;
esac


if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AROAEXAMPLE"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  printf '%s\n' '{
    "cluster":{
      "name":"omnivise-iot",
      "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
      "status":"ACTIVE"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  printf '%s\n' '{
    "User":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-groups-for-user" ]; then
  printf '%s\n' '{"Groups":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-user-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-user-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-bootstrap-assume-delivery"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user-policy" ]; then
  printf '%s\n' '{
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"sts:AssumeRole",
        "Resource":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  printf '%s\n' '{
    "Role":{
      "RoleName":"omnivise-iot-jenkins-delivery",
      "Arn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "AssumeRolePolicyDocument":{
        "Version":"2012-10-17",
        "Statement":[{
          "Effect":"Allow",
          "Principal":{"AWS":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"},
          "Action":"sts:AssumeRole"
        }]
      }
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-role-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-role-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-delivery-describe-cluster"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role-policy" ]; then
  printf '%s\n' '{
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"eks:DescribeCluster",
        "Resource":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-access-entry" ]; then
  principal=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--principal-arn" ]; then
      principal="$2"
      break
    fi
    shift
  done

  if [ "$principal" = "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap" ]; then
    printf 'An error occurred (ResourceNotFoundException) when calling the DescribeAccessEntry operation: not found\n' >&2
    exit 254
  fi

  printf '%s\n' '{
    "accessEntry":{
      "principalArn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "type":"STANDARD",
      "kubernetesGroups":[]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "list-associated-access-policies" ]; then
  printf '%s\n' '{
    "associatedAccessPolicies":[{
      "policyArn":"arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy",
      "accessScope":{"type":"namespace","namespaces":["omnivise-iot"]}
    }]
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
  count_file="${FAKE_LIST_COUNT_FILE:?}"
  count=0
  [ -f "$count_file" ] && count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s' "$count" > "$count_file"

  if [ "${FAKE_NEVER_PROPAGATE:-0}" = "1" ]; then
    printf '%s\n' '{"AccessKeyMetadata":[]}'
    exit 0
  fi

  if [ "${FAKE_POST_CREATE_LIST_MALFORMED:-0}" = "1" ] && [ "$count" -ge 2 ]; then
    printf '%s\n' '{}'
    exit 0
  fi

  if [ "${FAKE_POST_CREATE_LIST_NON_ARRAY:-0}" = "1" ] && [ "$count" -ge 2 ]; then
    printf '%s\n' '{"AccessKeyMetadata":{"AccessKeyId":"AKIA1234567890ABCDEF"}}'
    exit 0
  fi

  if [ "${FAKE_POST_CREATE_LIST_FAIL:-0}" = "1" ] && [ "$count" -ge 2 ]; then
    printf 'An error occurred (Throttling) when calling the ListAccessKeys operation: Rate exceeded\n' >&2
    exit 254
  fi

  if [ "$count" -eq 1 ]; then
    printf '%s\n' '{"AccessKeyMetadata":[]}'
  else
    printf '%s\n' '{
      "AccessKeyMetadata":[{
        "UserName":"omnivise-iot-jenkins-bootstrap",
        "AccessKeyId":"AKIA1234567890ABCDEF",
        "Status":"Active"
      }]
    }'
  fi
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "create-access-key" ]; then
  printf '%s\n' '{
    "AccessKey":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "AccessKeyId":"AKIA1234567890ABCDEF",
      "Status":"Active",
      "SecretAccessKey":"0123456789abcdefghijklmnopqrstuvwxYZAB12"
    }
  }'
  exit 0
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$hardening_bin/aws"

cat > "$hardening_bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "inspect" ]; then
  if [[ "$*" == *'.State.Running'* ]]; then
    printf '%s\n' true
    exit 0
  fi

  if [[ "$*" == *'.Mounts'* ]]; then
    printf '[{"Destination":"/run/secrets/omnivise_iot_aws_access_key_id","Source":"%s"},{"Destination":"/run/secrets/omnivise_iot_aws_secret_access_key","Source":"%s"}]\n' \
      "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_access_key_id" \
      "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_secret_access_key"
    exit 0
  fi
fi

printf 'unexpected fake docker call: %s\n' "$*" >&2
exit 99
FAKEDOCKER
chmod +x "$hardening_bin/docker"

cat > "$hardening_bin/kubectl" <<'FAKEKUBECTL'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"auth can-i create deployments"*"-n omnivise-iot"* ]]; then
  printf '%s\n' yes
  exit 0
fi

if [[ "$*" == *"auth can-i create namespaces"* ]]; then
  printf '%s\n' no
  exit 1
fi

if [[ "$*" == *"auth can-i get secrets"*"-n kube-system"* ]]; then
  printf '%s\n' no
  exit 1
fi

if [[ "$*" == *"auth can-i create clusterrolebindings"* ]]; then
  printf '%s\n' no
  exit 1
fi

printf 'unexpected fake kubectl call: %s\n' "$*" >&2
exit 99
FAKEKUBECTL
chmod +x "$hardening_bin/kubectl"


hardening_root="$TEST_TMP_ROOT/create-hardening-files"
mkdir -p "$hardening_root"

hardening_id_file="$hardening_root/secrets/omnivise_iot_aws_access_key_id"
hardening_secret_file="$hardening_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$hardening_root/secrets"
hardening_home="$TEST_TMP_ROOT/create-hardening-home"
hardening_tmp="$TEST_TMP_ROOT/create-hardening-tmp"

mkdir -p "$hardening_home" "$hardening_tmp"

prepare_hardening_files() {
  printf '%s' OLD-ID > "$hardening_id_file"
  printf '%s' OLD-SECRET > "$hardening_secret_file"
  chmod 600 "$hardening_id_file" "$hardening_secret_file"
}

run_hardening_issue() {
  local list_count_file="$TEST_TMP_ROOT/create-hardening-list-count"
  rm -f "$list_count_file"

  : > "$TEST_TMP_ROOT/create-hardening-aws.log"

  run_capture env \
    PATH="$hardening_bin:$PATH" \
    HOME="$hardening_home" \
    TMPDIR="$hardening_tmp" \
    FAKE_AWS_LOG="$TEST_TMP_ROOT/create-hardening-aws.log" \
    FAKE_LIST_COUNT_FILE="$list_count_file" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$hardening_root" \
    "$@" \
    bash "$AWS_DEMO_SH" issue-credential
}

prepare_hardening_files
run_hardening_issue

assert_eq "hardening happy path exits 1" "1" "$RC"

secret_value="0123456789abcdefghijklmnopqrstuvwxYZAB12"

unexpected_secret_paths="$(
  grep -RIl --exclude="$(basename "$hardening_secret_file")" \
    "$secret_value" \
    "$hardening_home" \
    "$hardening_tmp" \
    "$hardening_root" \
    2>/dev/null || true
)"

assert_eq \
  "secret appears only in designated secret file" \
  "" \
  "$unexpected_secret_paths"

mutation_lines="$(
  grep -E \
    '(^| )(create-access-key|delete-access-key|create-|delete-|put-|update-|attach-|detach-|associate-|disassociate-)' \
    "$TEST_TMP_ROOT/create-hardening-aws.log" \
    || true
)"

assert_eq \
  "creation mutation allowlist contains exactly one allowed mutation" \
  "iam create-access-key --user-name omnivise-iot-jenkins-bootstrap --output json" \
  "$mutation_lines"

prepare_hardening_files
run_hardening_issue FAKE_NEVER_PROPAGATE=1

assert_eq "bounded propagation timeout exits 1" "1" "$RC"
assert_not_contains \
  "bounded propagation timeout claims no unproven lifecycle state" \
  "$OUT" \
  "STATE:"
assert_contains \
  "bounded propagation timeout points to status" \
  "$OUT" \
  "NEXT: rerun scripts/aws-demo.sh status"

list_call_count="$(
  grep -c '^iam list-access-keys --user-name omnivise-iot-jenkins-bootstrap --output json$' \
    "$TEST_TMP_ROOT/create-hardening-aws.log" \
    || true
)"

assert_eq \
  "post-create propagation retry is bounded" \
  "6" \
  "$list_call_count"

# After create-access-key succeeded the key exists: a failed or malformed
# verification list is a post-create VIOLATION with masked recovery guidance,
# never a generic exit 3 and never a rollback. The written files are kept.
for post_create_case in \
  "FAKE_POST_CREATE_LIST_MALFORMED=1:malformed post-create key list" \
  "FAKE_POST_CREATE_LIST_NON_ARRAY=1:non-array post-create key list" \
  "FAKE_POST_CREATE_LIST_FAIL=1:failed post-create key list"
do
  post_create_knob="${post_create_case%%:*}"
  post_create_label="${post_create_case#*:}"

  prepare_hardening_files
  post_create_id_inode="$(stat -c %i "$hardening_id_file")"
  post_create_secret_inode="$(stat -c %i "$hardening_secret_file")"
  run_hardening_issue "$post_create_knob"

  assert_eq "$post_create_label exits 2" "2" "$RC"
  assert_lifecycle_state "$post_create_label emits one valid lifecycle state" "$OUT" required
  assert_contains "$post_create_label is VIOLATION" "$OUT" "STATE: VIOLATION"
  assert_contains "$post_create_label shows only the masked suffix" "$OUT" "created bootstrap key suffix ****CDEF"
  assert_contains \
    "$post_create_label gives explicit recovery guidance" \
    "$OUT" \
    "NEXT: run scripts/aws-demo.sh revoke-credential --key-id CDEF, then scripts/aws-demo.sh issue-credential"
  assert_not_contains "$post_create_label leaks no full access key ID" "$OUT$ERR" "AKIA1234567890ABCDEF"
  assert_not_contains "$post_create_label leaks no secret" "$OUT$ERR" "$secret_value"
  assert_not_contains "$post_create_label is not a generic environment error" "$ERR" "ENVIRONMENT_ERROR"
  assert_eq \
    "$post_create_label is not retried as propagation" \
    "2" \
    "$(grep -c '^iam list-access-keys --user-name omnivise-iot-jenkins-bootstrap --output json$' "$TEST_TMP_ROOT/create-hardening-aws.log" || true)"
  assert_not_contains \
    "$post_create_label does not roll back credential" \
    "$(cat "$TEST_TMP_ROOT/create-hardening-aws.log")" \
    "delete-access-key"
  assert_eq "$post_create_label keeps the written secret file" "$secret_value" "$(cat "$hardening_secret_file")"
  assert_eq "$post_create_label keeps the written ID file" "AKIA1234567890ABCDEF" "$(cat "$hardening_id_file")"
  assert_eq \
    "$post_create_label preserves both file inodes" \
    "$post_create_id_inode $post_create_secret_inode" \
    "$(stat -c %i "$hardening_id_file") $(stat -c %i "$hardening_secret_file")"
done

suite "aws-demo exact operator principal"

operator_log="$TEST_TMP_ROOT/operator-aws.log"

run_operator_status() {
  : > "$operator_log"
  run_capture env \
    PATH="$full_down_bin:$PATH" \
    FAKE_AWS_LOG="$operator_log" \
    FAKE_OPERATOR_ARN="$1" \
    bash "$AWS_DEMO_SH" status
}

for operator_arn in \
  "arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session" \
  "arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/botocore-session-1758500000"
do
  run_operator_status "$operator_arn"
  assert_eq "approved AdminAssumeRole session passes ($operator_arn)" "0" "$RC"
  assert_contains "approved AdminAssumeRole session reaches DOWN-CLEAN ($operator_arn)" "$OUT" "STATE: DOWN-CLEAN"
done

for operator_case in \
  "arn:aws:sts::554422868760:assumed-role/OtherRole/operator-session|another assumed role in the account" \
  "arn:aws:sts::554422868760:assumed-role/AdminAssumeRoleX/operator-session|role-name prefix lookalike" \
  "arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/|AdminAssumeRole with empty session name" \
  "arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/a/b|AdminAssumeRole with extra path segment" \
  "arn:aws:sts::111122223333:assumed-role/AdminAssumeRole/operator-session|AdminAssumeRole session of another account" \
  "arn:aws:iam::554422868760:role/AdminAssumeRole|AdminAssumeRole IAM role ARN instead of a session" \
  "arn:aws:iam::554422868760:user/operator|arbitrary IAM user in the account" \
  "arn:aws:iam::554422868760:root|account root"
do
  operator_arn="${operator_case%%|*}"
  operator_label="${operator_case#*|}"

  run_operator_status "$operator_arn"
  assert_eq "$operator_label is rejected with exit 3" "3" "$RC"
  assert_contains "$operator_label names the required principal" "$ERR" "operator caller must be an AdminAssumeRole session"
  assert_not_contains "$operator_label claims no lifecycle state" "$OUT" "STATE:"
  assert_not_contains "$operator_label stops before cluster classification" "$(cat "$operator_log")" "eks describe-cluster"
done

for operator_case in \
  "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap|Jenkins bootstrap user" \
  "arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery|Jenkins delivery role ARN" \
  "arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/aws-demo-runtime|Jenkins delivery session"
do
  operator_arn="${operator_case%%|*}"
  operator_label="${operator_case#*|}"

  run_operator_status "$operator_arn"
  assert_eq "$operator_label as operator is rejected with exit 3" "3" "$RC"
  assert_contains "$operator_label as operator is named a Jenkins identity" "$ERR" "must not be a Jenkins delivery identity"
  assert_not_contains "$operator_label as operator claims no lifecycle state" "$OUT" "STATE:"
  assert_not_contains "$operator_label as operator stops before cluster classification" "$(cat "$operator_log")" "eks describe-cluster"
done

suite "aws-demo pinned AWS CLI JSON output"

# Simulates the real AWS CLI output precedence (--output, then
# AWS_DEFAULT_OUTPUT, then the config file). Without the pinned flag it answers
# in a non-JSON format, which the script could not parse.
format_bin="$TEST_TMP_ROOT/format-bin"
mkdir -p "$format_bin"

cat > "$format_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

output=""
previous=""
for arg in "$@"; do
  [ "$previous" != "--output" ] || output="$arg"
  previous="$arg"
done

[ -n "$output" ] || output="${AWS_DEFAULT_OUTPUT:-}"

if [ -z "$output" ] && [ -f "${AWS_CONFIG_FILE:-}" ]; then
  output="$(sed -n 's/^output *= *//p' "$AWS_CONFIG_FILE" | head -n 1)"
fi

if [ "$1" != "configure" ] && [ "${output:-json}" != "json" ]; then
  printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"
  printf 'NON-JSON-%s\t%s\t%s\n' "$output" "$1" "$2"
  exit 0
fi

exec "${FORMAT_BASE_FAKE_AWS:?}" "$@"
FAKEAWS
chmod +x "$format_bin/aws"

format_config="$TEST_TMP_ROOT/format-aws-config"
printf '[default]\noutput = text\nregion = eu-north-1\n' > "$format_config"
format_log="$TEST_TMP_ROOT/format-aws.log"

# Control: the simulated operator configuration really yields non-JSON.
assert_contains \
  "format fake answers text for the operator config when --output is absent" \
  "$(env AWS_CONFIG_FILE="$format_config" FAKE_AWS_LOG=/dev/null \
      FORMAT_BASE_FAKE_AWS="$full_down_bin/aws" \
      "$format_bin/aws" sts get-caller-identity)" \
  "NON-JSON-text"

for format_case in \
  "AWS_CONFIG_FILE=$format_config|config file output = text" \
  "AWS_DEFAULT_OUTPUT=yaml|AWS_DEFAULT_OUTPUT=yaml"
do
  format_env="${format_case%%|*}"
  format_label="${format_case#*|}"

  : > "$format_log"
  run_capture env \
    PATH="$format_bin:$full_down_bin:$PATH" \
    FAKE_AWS_LOG="$format_log" \
    FORMAT_BASE_FAKE_AWS="$full_down_bin/aws" \
    "$format_env" \
    bash "$AWS_DEMO_SH" status

  assert_eq "status parses JSON despite $format_label" "0" "$RC"
  assert_contains "status reaches DOWN-CLEAN despite $format_label" "$OUT" "STATE: DOWN-CLEAN"
  assert_eq \
    "every parsed status AWS call pins --output json once ($format_label)" \
    "" \
    "$(grep -v '^configure get cli_history' "$format_log" | grep -v -- ' --output json$' || true)"
  assert_eq \
    "no status AWS call carries a second --output ($format_label)" \
    "" \
    "$(grep -E -- '--output .*--output' "$format_log" || true)"

  prepare_hardening_files
  rm -f "$TEST_TMP_ROOT/create-hardening-list-count"
  : > "$TEST_TMP_ROOT/create-hardening-aws.log"
  run_capture env \
    PATH="$format_bin:$hardening_bin:$PATH" \
    HOME="$hardening_home" \
    TMPDIR="$hardening_tmp" \
    FAKE_AWS_LOG="$TEST_TMP_ROOT/create-hardening-aws.log" \
    FAKE_LIST_COUNT_FILE="$TEST_TMP_ROOT/create-hardening-list-count" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$hardening_root" \
    FORMAT_BASE_FAKE_AWS="$hardening_bin/aws" \
    "$format_env" \
    bash "$AWS_DEMO_SH" issue-credential

  assert_eq "issue-credential parses create-access-key JSON despite $format_label" "1" "$RC"
  assert_contains "issue-credential reaches UP-RESTART-REQUIRED despite $format_label" "$OUT" "STATE: UP-RESTART-REQUIRED"
  assert_contains \
    "create-access-key pins --output json ($format_label)" \
    "$(cat "$TEST_TMP_ROOT/create-hardening-aws.log")" \
    "iam create-access-key --user-name omnivise-iot-jenkins-bootstrap --output json"
  assert_eq \
    "every parsed issue AWS call pins --output json ($format_label)" \
    "" \
    "$(grep -v '^configure get cli_history' "$TEST_TMP_ROOT/create-hardening-aws.log" | grep -v -- ' --output json$' || true)"
done

suite "aws-demo credential revocation contract"

revoke_bin="$TEST_TMP_ROOT/revoke-bin"
mkdir -p "$revoke_bin"

cat > "$revoke_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AROAEXAMPLE"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  printf '%s\n' '{
    "cluster":{
      "name":"omnivise-iot",
      "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
      "status":"ACTIVE"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  printf '%s\n' '{
    "User":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-groups-for-user" ]; then
  printf '%s\n' '{"Groups":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-user-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-user-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-bootstrap-assume-delivery"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user-policy" ]; then
  printf '%s\n' '{
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"sts:AssumeRole",
        "Resource":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  printf '%s\n' '{
    "Role":{
      "RoleName":"omnivise-iot-jenkins-delivery",
      "Arn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "AssumeRolePolicyDocument":{
        "Version":"2012-10-17",
        "Statement":[{
          "Effect":"Allow",
          "Principal":{"AWS":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"},
          "Action":"sts:AssumeRole"
        }]
      }
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-role-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-role-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-delivery-describe-cluster"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role-policy" ]; then
  printf '%s\n' '{
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"eks:DescribeCluster",
        "Resource":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-access-entry" ]; then
  principal=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--principal-arn" ]; then
      principal="$2"
      break
    fi
    shift
  done

  if [ "$principal" = "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap" ]; then
    printf 'An error occurred (ResourceNotFoundException) when calling the DescribeAccessEntry operation: not found\n' >&2
    exit 254
  fi

  printf '%s\n' '{
    "accessEntry":{
      "principalArn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "type":"STANDARD",
      "kubernetesGroups":[]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "list-associated-access-policies" ]; then
  printf '%s\n' '{
    "associatedAccessPolicies":[{
      "policyArn":"arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy",
      "accessScope":{"type":"namespace","namespaces":["omnivise-iot"]}
    }]
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
  state_file="${FAKE_REVOKE_STATE_FILE:?}"
  state="$(cat "$state_file")"

  case "$state" in
    zero)
      printf '%s\n' '{"AccessKeyMetadata":[]}'
      ;;
    one)
      printf '%s\n' '{
        "AccessKeyMetadata":[{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIA1234567890ABCDEF",
          "Status":"Active"
        }]
      }'
      ;;
    two)
      printf '%s\n' '{
        "AccessKeyMetadata":[
          {
            "UserName":"omnivise-iot-jenkins-bootstrap",
            "AccessKeyId":"AKIA1234567890ABCDEF",
            "Status":"Active"
          },
          {
            "UserName":"omnivise-iot-jenkins-bootstrap",
            "AccessKeyId":"AKIA0987654321FEDCBA",
            "Status":"Active"
          }
        ]
      }'
      ;;
    one-inactive)
      printf '%s\n' '{
        "AccessKeyMetadata":[{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIA1234567890ABCDEF",
          "Status":"Inactive"
        }]
      }'
      ;;
    remaining-second)
      printf '%s\n' '{
        "AccessKeyMetadata":[{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIA0987654321FEDCBA",
          "Status":"Active"
        }]
      }'
      ;;
    shared-suffix)
      printf '%s\n' '{
        "AccessKeyMetadata":[
          {
            "UserName":"omnivise-iot-jenkins-bootstrap",
            "AccessKeyId":"AKIA1111111111110000",
            "Status":"Active"
          },
          {
            "UserName":"omnivise-iot-jenkins-bootstrap",
            "AccessKeyId":"AKIA2222222222220000",
            "Status":"Active"
          }
        ]
      }'
      ;;
    malformed)
      printf '%s\n' '{}'
      ;;
  esac
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "delete-access-key" ]; then
  key_id=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--access-key-id" ]; then
      key_id="$2"
      break
    fi
    shift
  done

  case "${FAKE_REVOKE_DELETE_MODE:-normal}" in
    fail-echo)
      printf 'An error occurred (ServiceFailure) when calling the DeleteAccessKey operation: could not delete access key %s for user omnivise-iot-jenkins-bootstrap\n' "$key_id" >&2
      exit 254
      ;;
    stuck)
      # Deleted, but IAM list never reflects it within the retry bound.
      ;;
    malformed-after)
      printf '%s\n' malformed > "${FAKE_REVOKE_STATE_FILE:?}"
      ;;
    normal)
      if [ "$(cat "${FAKE_REVOKE_STATE_FILE:?}")" = "two" ] &&
         [ "$key_id" = "AKIA1234567890ABCDEF" ]; then
        printf '%s\n' remaining-second > "${FAKE_REVOKE_STATE_FILE:?}"
      else
        printf '%s\n' zero > "${FAKE_REVOKE_STATE_FILE:?}"
      fi
      ;;
  esac
  exit 0
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$revoke_bin/aws"

cat > "$revoke_bin/sleep" <<'FAKESLEEP'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SLEEP_LOG:-/dev/null}"
FAKESLEEP
chmod +x "$revoke_bin/sleep"

revoke_root="$TEST_TMP_ROOT/revoke-files"
mkdir -p "$revoke_root"

revoke_id_file="$revoke_root/secrets/omnivise_iot_aws_access_key_id"
revoke_secret_file="$revoke_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$revoke_root/secrets"
revoke_state_file="$TEST_TMP_ROOT/revoke-state"
revoke_log="$TEST_TMP_ROOT/revoke-aws.log"
revoke_sleep_log="$TEST_TMP_ROOT/revoke-sleep.log"

prepare_revoke_files() {
  printf '%s' "$1" > "$revoke_id_file"
  printf '%s' "PRESERVE-SECRET" > "$revoke_secret_file"
  chmod 600 "$revoke_id_file" "$revoke_secret_file"
}

run_revoke() {
  : > "$revoke_log"
  : > "$revoke_sleep_log"

  # Leading VAR=value arguments are environment overrides; the rest are CLI args.
  local -a env_overrides=()
  while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
    env_overrides+=("$1")
    shift
  done

  run_capture env \
    PATH="$revoke_bin:$PATH" \
    FAKE_AWS_LOG="$revoke_log" \
    FAKE_SLEEP_LOG="$revoke_sleep_log" \
    FAKE_REVOKE_STATE_FILE="$revoke_state_file" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$revoke_root" \
    "${env_overrides[@]}" \
    bash "$AWS_DEMO_SH" revoke-credential "$@"
}

printf '%s\n' zero > "$revoke_state_file"
prepare_revoke_files "OLD-ID"

run_revoke

assert_eq "revoke with zero keys is idempotent" "0" "$RC"
assert_not_contains \
  "zero-key revoke performs no delete" \
  "$(cat "$revoke_log")" \
  "delete-access-key"
assert_eq \
  "zero-key revoke preserves secret file" \
  "PRESERVE-SECRET" \
  "$(cat "$revoke_secret_file")"

printf '%s\n' one > "$revoke_state_file"
prepare_revoke_files "AKIA1234567890ABCDEF"

run_revoke

assert_eq "matching sole key revoke succeeds" "0" "$RC"
assert_contains \
  "matching sole key is deleted" \
  "$(cat "$revoke_log")" \
  "iam delete-access-key --user-name omnivise-iot-jenkins-bootstrap --access-key-id AKIA1234567890ABCDEF"
assert_eq \
  "successful revoke preserves secret file" \
  "PRESERVE-SECRET" \
  "$(cat "$revoke_secret_file")"

printf '%s\n' one > "$revoke_state_file"
prepare_revoke_files "AKIA0000000000000000"

run_revoke

assert_eq "local key mismatch is violation" "2" "$RC"
assert_not_contains \
  "local key mismatch performs no delete" \
  "$(cat "$revoke_log")" \
  "delete-access-key"

printf '%s\n' two > "$revoke_state_file"
prepare_revoke_files "AKIA1234567890ABCDEF"

run_revoke

assert_eq "default revoke with two keys is violation" "2" "$RC"
assert_not_contains \
  "default revoke with two keys performs no delete" \
  "$(cat "$revoke_log")" \
  "delete-access-key"

printf '%s\n' two > "$revoke_state_file"
prepare_revoke_files "STALE-LOCAL-ID"

: > "$revoke_log"
run_capture env \
  PATH="$revoke_bin:$PATH" \
  FAKE_AWS_LOG="$revoke_log" \
  FAKE_REVOKE_STATE_FILE="$revoke_state_file" \
  OMNIVISE_JENKINS_PLATFORM_DIR="$revoke_root" \
  bash "$AWS_DEMO_SH" revoke-credential --key-id CDEF

assert_eq "unique suffix recovery revoke succeeds" "0" "$RC"
assert_contains \
  "unique suffix resolves exact key" \
  "$(cat "$revoke_log")" \
  "iam delete-access-key --user-name omnivise-iot-jenkins-bootstrap --access-key-id AKIA1234567890ABCDEF"

printf '%s\n' two > "$revoke_state_file"

: > "$revoke_log"
run_capture env \
  PATH="$revoke_bin:$PATH" \
  FAKE_AWS_LOG="$revoke_log" \
  FAKE_REVOKE_STATE_FILE="$revoke_state_file" \
  OMNIVISE_JENKINS_PLATFORM_DIR="$revoke_root" \
  bash "$AWS_DEMO_SH" revoke-credential --key-id DEF

assert_eq "recovery suffix shorter than four chars is usage error" "3" "$RC"
assert_not_contains \
  "short recovery suffix performs no delete" \
  "$(cat "$revoke_log")" \
  "delete-access-key"

# M5a: default revoke never deletes a sole Inactive key.
printf '%s\n' one-inactive > "$revoke_state_file"
prepare_revoke_files "AKIA1234567890ABCDEF"

run_revoke

assert_eq "default revoke of sole inactive key is violation" "2" "$RC"
assert_contains "default revoke of sole inactive key reports VIOLATION" "$OUT" "STATE: VIOLATION"
assert_contains \
  "default revoke of sole inactive key points to explicit selector" \
  "$OUT" \
  "--key-id"
assert_not_contains \
  "default revoke of sole inactive key performs no delete" \
  "$(cat "$revoke_log")" \
  "delete-access-key"

printf '%s\n' one-inactive > "$revoke_state_file"
prepare_revoke_files "AKIA1234567890ABCDEF"

run_revoke --key-id CDEF

assert_eq "explicit revoke of sole inactive key succeeds" "0" "$RC"
assert_contains \
  "explicit revoke of sole inactive key deletes it" \
  "$(cat "$revoke_log")" \
  "iam delete-access-key --user-name omnivise-iot-jenkins-bootstrap --access-key-id AKIA1234567890ABCDEF"

# M5d: selector shape, no match, ambiguity, full ID; no full-ID diagnostics.
for bad_selector in abcd AKIA1234567890ABCDEF1 'CD*F' 'cdef'; do
  printf '%s\n' two > "$revoke_state_file"
  prepare_revoke_files "STALE-LOCAL-ID"
  run_revoke --key-id "$bad_selector"

  assert_eq "invalid selector shape [$bad_selector] is usage error" "3" "$RC"
  assert_not_contains \
    "invalid selector shape [$bad_selector] performs no delete" \
    "$(cat "$revoke_log")" \
    "delete-access-key"
done

printf '%s\n' two > "$revoke_state_file"
prepare_revoke_files "STALE-LOCAL-ID"
run_revoke --key-id ZZZZ

assert_eq "selector with no matching key exits 3" "3" "$RC"
assert_not_contains "selector with no matching key emits no lifecycle state" "$OUT" "STATE:"
assert_not_contains \
  "selector with no matching key performs no delete" \
  "$(cat "$revoke_log")" \
  "delete-access-key"
assert_not_contains \
  "selector with no match does not reveal existing key IDs" \
  "$OUT$ERR" \
  "AKIA1234567890ABCDEF"
assert_not_contains \
  "selector with no match does not reveal second key ID" \
  "$OUT$ERR" \
  "AKIA0987654321FEDCBA"

printf '%s\n' shared-suffix > "$revoke_state_file"
prepare_revoke_files "STALE-LOCAL-ID"
run_revoke --key-id 0000

assert_eq "ambiguous selector exits 3" "3" "$RC"
assert_not_contains "ambiguous selector emits no lifecycle state" "$OUT" "STATE:"
assert_not_contains \
  "ambiguous selector performs no delete" \
  "$(cat "$revoke_log")" \
  "delete-access-key"
assert_not_contains \
  "ambiguous selector does not reveal first candidate key ID" \
  "$OUT$ERR" \
  "AKIA1111111111110000"
assert_not_contains \
  "ambiguous selector does not reveal second candidate key ID" \
  "$OUT$ERR" \
  "AKIA2222222222220000"

printf '%s\n' two > "$revoke_state_file"
prepare_revoke_files "STALE-LOCAL-ID"
run_revoke --key-id AKIA1234567890ABCDEF

assert_eq "full 20-character key ID selector is accepted" "0" "$RC"
assert_contains \
  "full key ID selector deletes exactly that key" \
  "$(cat "$revoke_log")" \
  "iam delete-access-key --user-name omnivise-iot-jenkins-bootstrap --access-key-id AKIA1234567890ABCDEF"
assert_not_contains \
  "full key ID selector never deletes the other key" \
  "$(cat "$revoke_log")" \
  "AKIA0987654321FEDCBA"

# M5b: targeted recovery revoke while another key remains.
printf '%s\n' two > "$revoke_state_file"
prepare_revoke_files "STALE-LOCAL-ID"
run_revoke --key-id CDEF

assert_eq "targeted revoke with remaining key succeeds" "0" "$RC"
assert_not_contains \
  "targeted revoke with remaining key never claims UP-NO-CREDENTIAL" \
  "$OUT" \
  "UP-NO-CREDENTIAL"
assert_not_contains "targeted revoke with remaining key claims no unproven state" "$OUT" "STATE:"
assert_contains \
  "targeted revoke with remaining key points to status" \
  "$OUT" \
  "NEXT: rerun scripts/aws-demo.sh status"
assert_not_contains \
  "targeted revoke with remaining key does not reveal remaining key ID" \
  "$OUT$ERR" \
  "AKIA0987654321FEDCBA"
assert_eq \
  "targeted revoke deletes exactly one key" \
  "1" \
  "$(grep -c 'delete-access-key' "$revoke_log")"
assert_eq "targeted revoke keeps the unselected key" "remaining-second" "$(cat "$revoke_state_file")"

# M5c: malformed key list after a completed delete.
printf '%s\n' one > "$revoke_state_file"
prepare_revoke_files "AKIA1234567890ABCDEF"
run_revoke FAKE_REVOKE_DELETE_MODE=malformed-after

assert_eq "malformed post-revoke key list exits 3" "3" "$RC"
assert_not_contains "malformed post-revoke key list emits no lifecycle state" "$OUT" "STATE:"
assert_eq \
  "malformed post-revoke key list never repeats the delete" \
  "1" \
  "$(grep -c 'delete-access-key' "$revoke_log")"
assert_eq \
  "malformed post-revoke key list is not retried as propagation" \
  "0" \
  "$(grep -c . "$revoke_sleep_log" || true)"

# M5c: valid key list that never converges within the bound.
printf '%s\n' one > "$revoke_state_file"
prepare_revoke_files "AKIA1234567890ABCDEF"
run_revoke FAKE_REVOKE_DELETE_MODE=stuck

assert_eq "post-revoke propagation exhaustion exits 1" "1" "$RC"
assert_not_contains "post-revoke propagation exhaustion claims no lifecycle state" "$OUT" "STATE:"
assert_contains \
  "post-revoke propagation exhaustion points to status" \
  "$OUT" \
  "NEXT: rerun scripts/aws-demo.sh status"
assert_eq \
  "post-revoke propagation exhaustion deletes only once" \
  "1" \
  "$(grep -c 'delete-access-key' "$revoke_log")"
assert_eq \
  "post-revoke propagation retry is bounded" \
  "4" \
  "$(grep -c . "$revoke_sleep_log")"

# L4: a failing delete must not echo the full access-key ID.
printf '%s\n' one > "$revoke_state_file"
prepare_revoke_files "AKIA1234567890ABCDEF"
run_revoke FAKE_REVOKE_DELETE_MODE=fail-echo

assert_eq "failed delete-access-key is an operational error" "3" "$RC"
assert_not_contains "failed delete never reports success" "$OUT" "UP-NO-CREDENTIAL"
assert_not_contains "failed delete stdout never contains the full key ID" "$OUT" "AKIA1234567890ABCDEF"
assert_not_contains "failed delete stderr never contains the full key ID" "$ERR" "AKIA1234567890ABCDEF"
assert_contains "failed delete stderr identifies the key only by masked suffix" "$ERR" "****CDEF"
assert_eq "failed delete is attempted exactly once" "1" "$(grep -c 'delete-access-key' "$revoke_log")"
assert_eq "failed delete leaves the key state unchanged" "one" "$(cat "$revoke_state_file")"
assert_eq \
  "failed delete performs no other mutation" \
  "" \
  "$(grep -E '^iam (create|update|put|attach|detach)' "$revoke_log" || true)"

suite "aws-demo DOWN precedence over local lock"

down_lock_root="$TEST_TMP_ROOT/down-lock-platform"
down_lock_id_file="$down_lock_root/secrets/omnivise_iot_aws_access_key_id"
down_lock_secret_file="$down_lock_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$down_lock_root/secrets"

printf '%s' "STALE-ID" > "$down_lock_id_file"
printf '%s' "STALE-SECRET" > "$down_lock_secret_file"
chmod 600 "$down_lock_id_file" "$down_lock_secret_file"

exec {down_lock_holder_fd}<>"$down_lock_id_file"
flock -n -x "$down_lock_holder_fd"

: > "$TEST_TMP_ROOT/down-lock-aws.log"

run_capture env \
  PATH="$down_bin:$PATH" \
  FAKE_AWS_LOG="$TEST_TMP_ROOT/down-lock-aws.log" \
  OMNIVISE_JENKINS_PLATFORM_DIR="$down_lock_root" \
  bash "$AWS_DEMO_SH" status

assert_eq \
  "DOWN-CLEAN ignores local key-file lock" \
  "0" \
  "$RC"

assert_contains \
  "DOWN-CLEAN still reports clean state while local key file is locked" \
  "$OUT" \
  "DOWN-CLEAN"

flock -u "$down_lock_holder_fd"
exec {down_lock_holder_fd}>&-

suite "aws-demo one-key local readiness"

local_ready_root="$TEST_TMP_ROOT/local-ready"
mkdir -p "$local_ready_root"

local_ready_id="$local_ready_root/secrets/omnivise_iot_aws_access_key_id"
local_ready_secret="$local_ready_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$local_ready_root/secrets"

prepare_local_ready_files() {
  printf '%s' "AKIAEXAMPLE000000001" > "$local_ready_id"
  printf '%s' "0123456789abcdefghijklmnopqrstuvwxYZAB12" > "$local_ready_secret"
  chmod 600 "$local_ready_id" "$local_ready_secret"
}

local_ready_bin="$TEST_TMP_ROOT/local-ready-bin"
mkdir -p "$local_ready_bin"

cp "$credential_bin/aws" "$local_ready_bin/aws"
chmod +x "$local_ready_bin/aws"

cat > "$local_ready_bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
set -euo pipefail

case "${FAKE_DOCKER_STATE:-running}" in
  missing)
    exit 1
    ;;
  stopped)
    if [[ "$*" == *'.State.Running'* ]]; then
      printf '%s\n' false
      exit 0
    fi
    ;;
  running)
    if [[ "$*" == *'.State.Running'* ]]; then
      printf '%s\n' true
      exit 0
    fi
    ;;
esac

if [[ "$*" == *'.Mounts'* ]]; then
  id_source="${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_access_key_id"
  secret_source="${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_secret_access_key"

  if [ "${FAKE_WRONG_MOUNT:-0}" = "1" ]; then
    secret_source="${secret_source}.wrong"
  fi

  printf '[{"Destination":"/run/secrets/omnivise_iot_aws_access_key_id","Source":"%s"},{"Destination":"/run/secrets/omnivise_iot_aws_secret_access_key","Source":"%s"}]\n' \
    "$id_source" \
    "$secret_source"
  exit 0
fi

printf 'unexpected fake docker call: %s\n' "$*" >&2
exit 99
FAKEDOCKER
chmod +x "$local_ready_bin/docker"

run_local_ready_status() {
  : > "$TEST_TMP_ROOT/local-ready-aws.log"

  run_capture env \
    PATH="$local_ready_bin:$PATH" \
    FAKE_AWS_LOG="$TEST_TMP_ROOT/local-ready-aws.log" \
    FAKE_KEY_STATE="one-active" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$local_ready_root" \
    "$@" \
    bash "$AWS_DEMO_SH" status
}

prepare_local_ready_files
printf '%s' "AKIA0000000000000000" > "$local_ready_id"

run_local_ready_status

assert_eq "one-key local ID mismatch is violation" "2" "$RC"
assert_contains \
  "one-key local ID mismatch reports violation" \
  "$OUT" \
  "VIOLATION"

prepare_local_ready_files
rm -f "$local_ready_secret"

run_local_ready_status

assert_eq "one-key missing secret file is violation" "2" "$RC"

prepare_local_ready_files
chmod 644 "$local_ready_secret"

run_local_ready_status

assert_eq "one-key wrong secret mode is violation" "2" "$RC"

prepare_local_ready_files

run_local_ready_status FAKE_DOCKER_STATE=missing

assert_eq "one-key missing Jenkins container requires restart" "1" "$RC"
assert_contains \
  "missing Jenkins container reports restart-required" \
  "$OUT" \
  "UP-RESTART-REQUIRED"

prepare_local_ready_files

run_local_ready_status FAKE_DOCKER_STATE=stopped

assert_eq "one-key stopped Jenkins container requires restart" "1" "$RC"
assert_contains \
  "stopped Jenkins container reports restart-required" \
  "$OUT" \
  "UP-RESTART-REQUIRED"

prepare_local_ready_files
chmod 400 "$local_ready_id"

run_local_ready_status

assert_eq "status with read-only (0400) key-ID file reports mode VIOLATION" "2" "$RC"
assert_contains \
  "status with read-only key-ID file explains the 0600 requirement" \
  "$OUT" \
  "file mode must be 0600"
chmod 600 "$local_ready_id"

prepare_local_ready_files

run_local_ready_status FAKE_WRONG_MOUNT=1

assert_eq "one-key wrong Jenkins mount is violation" "2" "$RC"
assert_contains \
  "wrong Jenkins mount reports violation" \
  "$OUT" \
  "VIOLATION"

prepare_local_ready_files

run_local_ready_status

# The base credential fake answers the bootstrap-credential identity probe with
# the operator ARN, so reaching the runtime chain surfaces as a caller
# mismatch, which the contract classifies as VIOLATION.
assert_eq \
  "valid one-key local readiness reaches runtime-chain layer" \
  "2" \
  "$RC"

assert_contains \
  "valid local readiness reaches runtime-chain marker" \
  "$OUT" \
  "does not authenticate as the bootstrap IAM user"

suite "aws-demo AWS runtime credential chain"

runtime_bin="$TEST_TMP_ROOT/runtime-bin"
mkdir -p "$runtime_bin"

cat > "$runtime_bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *'.State.Running'* ]]; then
  printf '%s\n' true
  exit 0
fi

if [[ "$*" == *'.Mounts'* ]]; then
  printf '[{"Destination":"/run/secrets/omnivise_iot_aws_access_key_id","Source":"%s"},{"Destination":"/run/secrets/omnivise_iot_aws_secret_access_key","Source":"%s"}]\n' \
    "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_access_key_id" \
    "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_secret_access_key"
  exit 0
fi

if [[ "$*" == *'.State.StartedAt'* ]]; then
  printf '%s\n' "2099-01-01T00:00:00Z"
  exit 0
fi

printf 'unexpected fake docker call: %s\n' "$*" >&2
exit 99
FAKEDOCKER
chmod +x "$runtime_bin/docker"

cat > "$runtime_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

# Preflight.
if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

# Operator identity before the runtime credential subshell.
if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ] &&
   [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AROAOPERATOR"}'
  exit 0
fi

# Normal ACTIVE-cluster / IAM invariant fixture calls delegate to the existing
# credential fake until runtime credentials are installed.
if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  exec "${BASE_FAKE_AWS:?}" "$@"
fi

# Every runtime credential-bearing call must carry the exact isolated
# credential context. Violations fail the call; only variable names and
# presence markers are ever logged, never values.
ctx_fail() {
  printf 'runtime credential context violation: %s\n' "$1" >&2
  exit 97
}

presence() {
  if [ -n "${!1+x}" ]; then printf 'present'; else printf 'unset'; fi
}

for var in \
  AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE \
  AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI \
  AWS_CONTAINER_AUTHORIZATION_TOKEN AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE \
  AWS_SECURITY_TOKEN
do
  [ -z "${!var+x}" ] || ctx_fail "$var must be unset"
done

[ "${AWS_CONFIG_FILE-}" = "/dev/null" ] || ctx_fail "AWS_CONFIG_FILE must be /dev/null"
[ "${AWS_SHARED_CREDENTIALS_FILE-}" = "/dev/null" ] || ctx_fail "AWS_SHARED_CREDENTIALS_FILE must be /dev/null"
[ "${AWS_EC2_METADATA_DISABLED-}" = "true" ] || ctx_fail "AWS_EC2_METADATA_DISABLED must be true"
[ "${AWS_REGION-}" = "eu-north-1" ] || ctx_fail "AWS_REGION must be eu-north-1"
[ "${AWS_DEFAULT_REGION-}" = "eu-north-1" ] || ctx_fail "AWS_DEFAULT_REGION must be eu-north-1"
{ [ -n "${AWS_PAGER+x}" ] && [ -z "$AWS_PAGER" ]; } || ctx_fail "AWS_PAGER must be set and empty"
[ "${AWS_CLI_AUTO_PROMPT-}" = "off" ] || ctx_fail "AWS_CLI_AUTO_PROMPT must be off"

case "${AWS_ACCESS_KEY_ID:-}" in
  ASIADELIVERY00000001)
    credential_mode="delivery"
    [ "${AWS_SECRET_ACCESS_KEY-}" = "deliverySecret0123456789abcdefghijklMN" ] ||
      ctx_fail "delivery AWS_SECRET_ACCESS_KEY"
    [ "${AWS_SESSION_TOKEN-}" = "${FAKE_EXPECT_DELIVERY_TOKEN:-delivery-session-token}" ] ||
      ctx_fail "delivery AWS_SESSION_TOKEN"
    ;;
  *)
    credential_mode="bootstrap"
    [ "${AWS_ACCESS_KEY_ID:-}" = "$(cat "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_access_key_id")" ] ||
      ctx_fail "bootstrap AWS_ACCESS_KEY_ID"
    [ "${AWS_SECRET_ACCESS_KEY-}" = "${FAKE_EXPECT_BOOTSTRAP_SECRET:-$(cat "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_secret_access_key")}" ] ||
      ctx_fail "bootstrap AWS_SECRET_ACCESS_KEY"
    [ -z "${AWS_SESSION_TOKEN+x}" ] || ctx_fail "bootstrap AWS_SESSION_TOKEN must be unset"
    ;;
esac

{
  printf 'credential-mode=%s\n' "$credential_mode"
  for var in AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE \
             AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI \
             AWS_SECURITY_TOKEN AWS_SESSION_TOKEN; do
    printf '%s:%s=%s\n' "$credential_mode" "$var" "$(presence "$var")"
  done
  printf '%s\n' ---
} >> "${FAKE_RUNTIME_ENV_LOG:?}"

# kubectl exec plugin token command. Only the delivery session may call it,
# with exactly the kubeconfig-declared arguments. The token is a canary that
# must never persist.
if [ "$1" = "eks" ] && [ "${2:-}" = "get-token" ]; then
  [ "$credential_mode" = "${FAKE_EXPECT_GET_TOKEN_MODE:-delivery}" ] ||
    ctx_fail "eks get-token credential mode"
  [ "$*" = "eks get-token --region eu-north-1 --cluster-name omnivise-iot" ] ||
    ctx_fail "eks get-token arguments"
  printf 'credential-mode=%s operation=eks-get-token\n' "$credential_mode" >> "${FAKE_RUNTIME_ENV_LOG:?}"
  printf '{"kind":"ExecCredential","apiVersion":"client.authentication.k8s.io/v1beta1","spec":{},"status":{"expirationTimestamp":"2099-01-01T00:00:00Z","token":"%s"}}\n' \
    "${FAKE_EXEC_TOKEN:-k8s-aws-v1.default-fake-exec-token}"
  exit 0
fi

case "${AWS_ACCESS_KEY_ID:-}" in
  AKIAEXAMPLE000000001)
    # Bootstrap identity.
    if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
      printf '{"Account":"554422868760","Arn":"%s","UserId":"AIDABOOTSTRAP"}\n' \
        "${FAKE_BOOTSTRAP_CALLER_ARN:-arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap}"
      exit 0
    fi

    # Bootstrap must not call EKS directly.
    if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
      if [ "${FAKE_BOOTSTRAP_DESCRIBE_ALLOWED:-0}" = "1" ]; then
        printf '%s\n' '{"cluster":{"name":"omnivise-iot","status":"ACTIVE"}}'
        exit 0
      fi
      printf 'An error occurred (AccessDeniedException) when calling the DescribeCluster operation: not authorized\n' >&2
      exit 254
    fi

    if [ "$1" = "sts" ] && [ "$2" = "assume-role" ]; then
      role_arn=""
      while [ "$#" -gt 0 ]; do
        if [ "$1" = "--role-arn" ]; then
          role_arn="$2"
          break
        fi
        shift
      done

      case "$role_arn" in
        arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery)
          printf '%s\n' '{
            "Credentials":{
              "AccessKeyId":"ASIADELIVERY00000001",
              "SecretAccessKey":"deliverySecret0123456789abcdefghijklMN",
              "SessionToken":"delivery-session-token",
              "Expiration":"2099-01-01T00:00:00Z"
            },
            "AssumedRoleUser":{
              "Arn":"arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/aws-demo-runtime"
            }
          }'
          exit 0
          ;;
        arn:aws:iam::554422868760:role/AdminAssumeRole)
          printf 'An error occurred (AccessDenied) when calling the AssumeRole operation: not authorized\n' >&2
          exit 254
          ;;
      esac
    fi
    ;;

  ASIADELIVERY00000001)
    if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
      printf '{"Account":"554422868760","Arn":"%s","UserId":"AROAX:aws-demo-runtime"}\n' \
        "${FAKE_DELIVERY_CALLER_ARN:-arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/aws-demo-runtime}"
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
      printf '%s\n' '{
        "cluster":{
          "name":"omnivise-iot",
          "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
          "status":"ACTIVE",
          "endpoint":"https://example.eks.local",
          "certificateAuthority":{"data":"RkFLRS1DQQ=="}
        }
      }'
      exit 0
    fi

    if [ "$1" = "eks" ] && [ "$2" = "list-clusters" ]; then
      if [ "${FAKE_GENERIC_LIST_CLUSTERS_FAILURE:-0}" = "1" ]; then
        printf 'network exploded\n' >&2
        exit 255
      fi

      printf 'An error occurred (AccessDeniedException) when calling the ListClusters operation: not authorized\n' >&2
      exit 254
    fi

    if [ "$1" = "iam" ] && [ "$2" = "list-users" ]; then
      printf 'An error occurred (AccessDenied) when calling the ListUsers operation: not authorized\n' >&2
      exit 254
    fi
    ;;
esac

printf 'unexpected runtime fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$runtime_bin/aws"

cat > "$runtime_bin/kubectl" <<'FAKEKUBECTL'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"auth can-i create deployments"*"-n omnivise-iot"* ]]; then
  printf '%s\n' yes
  exit 0
fi

if [[ "$*" == *"auth can-i create namespaces"* ]]; then
  printf '%s\n' no
  exit 1
fi

if [[ "$*" == *"auth can-i get secrets"*"-n kube-system"* ]]; then
  printf '%s\n' no
  exit 1
fi

if [[ "$*" == *"auth can-i create clusterrolebindings"* ]]; then
  printf '%s\n' no
  exit 1
fi

printf 'unexpected fake kubectl call: %s\n' "$*" >&2
exit 99
FAKEKUBECTL
chmod +x "$runtime_bin/kubectl"

runtime_root="$TEST_TMP_ROOT/runtime-files"
mkdir -p "$runtime_root"

runtime_id_file="$runtime_root/secrets/omnivise_iot_aws_access_key_id"
runtime_secret_file="$runtime_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$runtime_root/secrets"
runtime_aws_log="$TEST_TMP_ROOT/runtime-aws.log"
runtime_env_log="$TEST_TMP_ROOT/runtime-env.log"

prepare_runtime_files() {
  printf '%s' "AKIAEXAMPLE000000001" > "$runtime_id_file"
  printf '%s' "0123456789abcdefghijklmnopqrstuvwxYZAB12" > "$runtime_secret_file"
  chmod 600 "$runtime_id_file" "$runtime_secret_file"
}

run_runtime_status() {
  : > "$runtime_aws_log"
  : > "$runtime_env_log"

  run_capture env \
    PATH="$runtime_bin:$PATH" \
    BASE_FAKE_AWS="$credential_bin/aws" \
    FAKE_AWS_LOG="$runtime_aws_log" \
    FAKE_RUNTIME_ENV_LOG="$runtime_env_log" \
    FAKE_KEY_STATE="one-active" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$runtime_root" \
    AWS_PROFILE="host-profile-must-not-leak" \
    AWS_DEFAULT_PROFILE="host-default-profile-must-not-leak" \
    AWS_ROLE_ARN="arn:aws:iam::000000000000:role/must-not-leak" \
    AWS_WEB_IDENTITY_TOKEN_FILE="/tmp/must-not-leak" \
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI="/must-not-leak" \
    AWS_CONTAINER_CREDENTIALS_FULL_URI="http://127.0.0.1/must-not-leak" \
    "$@" \
    bash "$AWS_DEMO_SH" status
}

prepare_runtime_files
run_runtime_status

assert_eq \
  "successful AWS runtime chain completes readiness" \
  "0" \
  "$RC"

assert_contains \
  "successful AWS runtime chain reports READY" \
  "$OUT" \
  "STATE: READY"
assert_lifecycle_state "READY STATE is a lifecycle state" "$OUT" required

assert_contains \
  "runtime chain assumes delivery role" \
  "$(cat "$runtime_aws_log")" \
  "sts assume-role --region eu-north-1 --role-arn arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"

assert_contains \
  "runtime chain probes bootstrap direct DescribeCluster denial" \
  "$(cat "$runtime_aws_log")" \
  "eks describe-cluster --region eu-north-1 --name omnivise-iot"

assert_contains \
  "runtime chain probes forbidden AdminAssumeRole" \
  "$(cat "$runtime_aws_log")" \
  "sts assume-role --region eu-north-1 --role-arn arn:aws:iam::554422868760:role/AdminAssumeRole"

assert_contains \
  "runtime chain probes delivery ListClusters denial" \
  "$(cat "$runtime_aws_log")" \
  "eks list-clusters --region eu-north-1"

assert_contains \
  "runtime chain probes delivery IAM ListUsers denial" \
  "$(cat "$runtime_aws_log")" \
  "iam list-users"

assert_not_contains \
  "runtime probes clear ambient AWS_PROFILE" \
  "$(cat "$runtime_env_log")" \
  "host-profile-must-not-leak"

assert_not_contains \
  "runtime probes clear ambient role and web identity auth" \
  "$(cat "$runtime_env_log")" \
  "must-not-leak"

prepare_runtime_files
run_runtime_status FAKE_GENERIC_LIST_CLUSTERS_FAILURE=1

assert_eq \
  "generic delivery ListClusters failure is environment error, not accepted denial" \
  "3" \
  "$RC"

assert_not_contains \
  "generic AWS failure does not produce READY" \
  "$OUT" \
  "READY"

prepare_runtime_files
run_runtime_status FAKE_BOOTSTRAP_DESCRIBE_ALLOWED=1

assert_eq "bootstrap direct DescribeCluster success is VIOLATION exit 2" "2" "$RC"
assert_contains "bootstrap direct DescribeCluster success is VIOLATION" "$OUT" "STATE: VIOLATION"
assert_contains "bootstrap direct DescribeCluster success prints NEXT" "$OUT" "NEXT:"
assert_lifecycle_state "bootstrap direct DescribeCluster success STATE is a lifecycle state" "$OUT" required

prepare_runtime_files
run_runtime_status FAKE_BOOTSTRAP_CALLER_ARN="arn:aws:iam::554422868760:user/someone-else"

assert_eq "bootstrap caller ARN mismatch exits 2" "2" "$RC"
assert_contains "bootstrap caller ARN mismatch is VIOLATION" "$OUT" "STATE: VIOLATION"
assert_contains "bootstrap caller ARN mismatch prints NEXT" "$OUT" "NEXT:"

prepare_runtime_files
run_runtime_status FAKE_DELIVERY_CALLER_ARN="arn:aws:sts::554422868760:assumed-role/other-role/aws-demo-runtime"

assert_eq "delivery caller ARN mismatch exits 2" "2" "$RC"
assert_contains "delivery caller ARN mismatch is VIOLATION" "$OUT" "STATE: VIOLATION"
assert_contains "delivery caller ARN mismatch prints NEXT" "$OUT" "NEXT:"

# M12 A/E: ambient session/security/container auth never reaches probes.
prepare_runtime_files
run_runtime_status \
  AWS_SESSION_TOKEN="ambient-session-must-not-leak" \
  AWS_SECURITY_TOKEN="ambient-security-must-not-leak" \
  AWS_CONTAINER_AUTHORIZATION_TOKEN="ambient-container-token-must-not-leak" \
  AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE="/must-not-leak"

assert_eq "runtime chain with ambient session auth still reaches READY" "0" "$RC"
assert_contains "runtime fake validated a bootstrap credential context" "$(cat "$runtime_env_log")" "credential-mode=bootstrap"
assert_contains "runtime fake validated a delivery credential context" "$(cat "$runtime_env_log")" "credential-mode=delivery"
assert_contains "bootstrap probe sees AWS_SESSION_TOKEN unset" "$(cat "$runtime_env_log")" "bootstrap:AWS_SESSION_TOKEN=unset"
assert_contains "delivery probe sees AWS_SESSION_TOKEN present" "$(cat "$runtime_env_log")" "delivery:AWS_SESSION_TOKEN=present"
assert_not_contains "runtime env log never records ambient token values" "$(cat "$runtime_env_log")" "must-not-leak"

runtime_all_logs="$(cat "$runtime_env_log" "$runtime_aws_log")"
assert_not_contains "runtime logs never contain the bootstrap secret" "$runtime_all_logs" "0123456789abcdefghijklmnopqrstuvwxYZAB12"
assert_not_contains "runtime logs never contain the delivery secret" "$runtime_all_logs" "deliverySecret0123456789abcdefghijklMN"
assert_not_contains "runtime logs never contain the delivery session token" "$runtime_all_logs" "delivery-session-token"

# M12 B/D: guard-activity checks. A deliberately wrong fake expectation must
# make the otherwise-correct flow fail, proving the fake validates the value.
prepare_runtime_files
run_runtime_status FAKE_EXPECT_BOOTSTRAP_SECRET="deliberately-wrong-expectation"

assert_eq "wrong bootstrap secret expectation makes the runtime fake fail" "3" "$RC"
assert_contains \
  "runtime fake names the bootstrap secret mismatch" \
  "$ERR" \
  "runtime credential context violation: bootstrap AWS_SECRET_ACCESS_KEY"
assert_not_contains "wrong bootstrap secret expectation is never READY" "$OUT" "READY"

prepare_runtime_files
run_runtime_status FAKE_EXPECT_DELIVERY_TOKEN="deliberately-wrong-expectation"

assert_eq "wrong delivery token expectation makes the runtime fake fail" "3" "$RC"
assert_contains \
  "runtime fake names the delivery session token mismatch" \
  "$ERR" \
  "runtime credential context violation: delivery AWS_SESSION_TOKEN"
assert_not_contains "wrong delivery token expectation is never READY" "$OUT" "READY"

# M3: production AWS call sites. Only aws_ro/aws_mutate may invoke the AWS
# CLI directly; the sole other exception is the local `aws configure get
# cli_history` preflight. Comments and heredoc bodies (e.g. the kubeconfig
# exec plugin) are not call sites.
aws_call_site_violations() {
  awk '
    heredoc != "" {
      if ($0 ~ ("^[[:space:]]*" heredoc "$")) heredoc = ""
      next
    }
    /^[a-z_]+\(\) \{$/ { fn = $1; sub(/\(\)/, "", fn); next }
    /^\}$/ { fn = ""; next }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (match(line, /<<-?'\''?[A-Za-z_]+'\''?/)) {
        heredoc = substr(line, RSTART, RLENGTH)
        gsub(/[<'\''-]/, "", heredoc)
      }
    }
    /(^[[:space:]]*|\$\()aws ([a-z]|")/ {
      if (fn == "aws_cli") next
      if (fn == "security_preflight" && $0 ~ /aws configure get cli_history/) next
      print NR ": " (fn == "" ? "<top-level>" : fn)
    }
    /(^[[:space:]]*|\$\()aws_cli / {
      if (fn == "aws_ro" || fn == "aws_mutate") next
      print NR ": " (fn == "" ? "<top-level>" : fn)
    }
  ' "$1"
}

aws_cli_guard_probe="$TEST_TMP_ROOT/aws-cli-guard-probe.sh"
cat > "$aws_cli_guard_probe" <<'PROBE'
aws_cli() {
  aws "$@" --output json
}
aws_ro() {
  aws_cli sts get-caller-identity "$@"
}
bad_wrapper_bypass() {
  x="$(aws_cli iam list-users)"
  aws "$@"
}
PROBE
assert_eq \
  "AWS call-site guard allows raw aws only in aws_cli and aws_cli only in aws_ro/aws_mutate" \
  "$(printf '%s\n' "8: bad_wrapper_bypass" "9: bad_wrapper_bypass")" \
  "$(aws_call_site_violations "$aws_cli_guard_probe")"

m3_guard_probe="$TEST_TMP_ROOT/m3-guard-probe.sh"
cat > "$m3_guard_probe" <<'PROBE'
aws_cli() {
  aws sts get-caller-identity "$@"
}
bad_direct() {
  # aws sts get-caller-identity  (comment, ignored)
  x="$(aws iam list-users)"
  cat <<EOF
command: aws
- eks
aws eks get-token
EOF
  printf 'NEXT: run aws iam list-access-keys\n'
}
PROBE
assert_eq \
  "AWS call-site guard detects exactly the direct call and ignores comments/heredocs/strings" \
  "6: bad_direct" \
  "$(aws_call_site_violations "$m3_guard_probe")"

assert_eq \
  "production AWS CLI calls go only through aws_ro/aws_mutate -> aws_cli (plus cli_history preflight)" \
  "" \
  "$(aws_call_site_violations "$AWS_DEMO_SH")"

# M3: every STS call is regional in AWS CLI v2 and must pin eu-north-1.
prepare_runtime_files
run_runtime_status
assert_eq "M3 runtime chain still reaches READY" "0" "$RC"
assert_eq \
  "every STS call (operator, bootstrap, delivery) pins --region eu-north-1" \
  "" \
  "$(grep '^sts ' "$runtime_aws_log" | grep -v -- '--region eu-north-1' || true)"
assert_contains \
  "operator caller identity pins the region" \
  "$(cat "$runtime_aws_log")" \
  "sts get-caller-identity --region eu-north-1"

suite "aws-demo Kubernetes runtime authorization chain"

cat > "$runtime_bin/kubectl" <<'FAKEKUBECTL'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_KUBECTL_LOG:?}"
printf 'KUBECONFIG=%s\n' "${KUBECONFIG-<unset>}" >> "${FAKE_KUBECTL_ENV_LOG:?}"

# Mimic kubectl discovery caching: without --cache-dir it writes below
# $HOME/.kube/cache, with it below the given directory.
cache_dir=""
args=("$@")
for (( i = 0; i < ${#args[@]}; i++ )); do
  if [ "${args[$i]}" = "--cache-dir" ]; then
    cache_dir="${args[$((i + 1))]:-}"
  fi
done
# Only simulated when a test opts in, so the real $HOME is never touched.
if [ -n "${FAKE_KUBECTL_CACHE_LOG:-}" ]; then
  printf '%s|%s\n' "${cache_dir:-<none>}" "$(dirname "${KUBECONFIG:-/nonexistent/config}")/cache" \
    >> "$FAKE_KUBECTL_CACHE_LOG"
  mkdir -p "${cache_dir:-${HOME:?}/.kube/cache}/discovery"
fi

# Exec plugin: like kubectl, read users[].user.exec from $KUBECONFIG and run
# it in every process (client-go caches the credential in memory only).
kubeconfig="${KUBECONFIG:?}"
[ -f "$kubeconfig" ] || { printf 'error: kubeconfig not found\n' >&2; exit 1; }

exec_api="$(awk '/^ *exec:$/ { f = 1; next } f && /^ *apiVersion:/ { print $2; exit }' "$kubeconfig")"
exec_cmd="$(awk '/^ *exec:$/ { f = 1; next } f && /^ *command:/ { print $2; exit }' "$kubeconfig")"
exec_args=()
while IFS= read -r arg; do
  exec_args+=("$arg")
done < <(awk '
  /^ *exec:$/ { f = 1; next }
  f && /^ *args:$/ { a = 1; next }
  a && /^ *- / { sub(/^ *- /, ""); print; next }
  a { exit }
' "$kubeconfig")

expected_args=(eks get-token --region eu-north-1 --cluster-name "${FAKE_EXPECT_EXEC_CLUSTER:-omnivise-iot}")
if [ "$exec_api" != "client.authentication.k8s.io/v1beta1" ] ||
   [ "$exec_cmd" != "aws" ] ||
   [ "${#exec_args[@]}" -ne "${#expected_args[@]}" ] ||
   [ "${exec_args[*]}" != "${expected_args[*]}" ]; then
  printf 'error: kubeconfig exec stanza mismatch\n' >&2
  exit 1
fi

case "${FAKE_KUBECTL_EXEC_MUTATION:-none}" in
  drop-region) exec_args=(eks get-token --cluster-name omnivise-iot) ;;
  wrong-cluster) exec_args=(eks get-token --region eu-north-1 --cluster-name other-cluster) ;;
esac

if ! exec_credential="$("$exec_cmd" "${exec_args[@]}")"; then
  printf 'error: exec plugin failed\n' >&2
  exit 1
fi

if ! printf '%s' "$exec_credential" | jq -e '
    .kind == "ExecCredential"
    and .apiVersion == "client.authentication.k8s.io/v1beta1"
    and (.status.token | type == "string" and length > 0)
  ' >/dev/null 2>&1; then
  printf 'error: exec plugin returned an invalid ExecCredential\n' >&2
  exit 1
fi
unset exec_credential

if [ "${FAKE_KUBECTL_GENERIC_FAILURE:-0}" = "1" ] &&
   [[ "$*" == *"create namespaces"* ]]; then
  printf 'transport failure\n' >&2
  exit 2
fi

if [[ "$*" == *"auth can-i create deployments"*"-n omnivise-iot"* ]]; then
  case "${FAKE_KUBECTL_DEPLOYMENTS:-yes}" in
    yes)
      printf '%s\n' yes
      exit 0
      ;;
    no)
      printf '%s\n' no
      exit 1
      ;;
    error)
      printf 'Unable to connect to the server: dial tcp: i/o timeout\n' >&2
      exit 2
      ;;
  esac
fi

if [[ "$*" == *"auth can-i create namespaces"* ]]; then
  printf '%s\n' no
  exit 1
fi

if [[ "$*" == *"auth can-i get secrets"*"-n kube-system"* ]]; then
  printf '%s\n' no
  exit 1
fi

if [[ "$*" == *"auth can-i create clusterrolebindings"* ]]; then
  printf '%s\n' no
  exit 1
fi

printf 'unexpected fake kubectl call: %s\n' "$*" >&2
exit 99
FAKEKUBECTL
chmod +x "$runtime_bin/kubectl"

kube_runtime_tmp="$TEST_TMP_ROOT/kube-runtime-tmp"
mkdir -p "$kube_runtime_tmp"

run_kube_runtime_status() {
  : > "$runtime_aws_log"
  : > "$runtime_env_log"
  : > "$TEST_TMP_ROOT/runtime-kubectl.log"
  : > "$TEST_TMP_ROOT/runtime-kubectl-env.log"

  run_capture env \
    PATH="$runtime_bin:$PATH" \
    BASE_FAKE_AWS="$credential_bin/aws" \
    FAKE_AWS_LOG="$runtime_aws_log" \
    FAKE_RUNTIME_ENV_LOG="$runtime_env_log" \
    FAKE_KUBECTL_LOG="$TEST_TMP_ROOT/runtime-kubectl.log" \
    FAKE_KUBECTL_ENV_LOG="$TEST_TMP_ROOT/runtime-kubectl-env.log" \
    FAKE_KEY_STATE="one-active" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$runtime_root" \
    TMPDIR="$kube_runtime_tmp" \
    "$@" \
    bash "$AWS_DEMO_SH" status
}

prepare_runtime_files
run_kube_runtime_status

assert_eq \
  "successful Kubernetes runtime chain completes readiness" \
  "0" \
  "$RC"

assert_contains \
  "successful Kubernetes runtime chain reports READY" \
  "$OUT" \
  "STATE: READY"

kubectl_log="$(cat "$TEST_TMP_ROOT/runtime-kubectl.log")"

assert_contains \
  "Kubernetes runtime allows namespace deployment creation" \
  "$kubectl_log" \
  "auth can-i create deployments -n omnivise-iot"

assert_contains \
  "Kubernetes runtime denies namespace creation" \
  "$kubectl_log" \
  "auth can-i create namespaces"

assert_contains \
  "Kubernetes runtime denies kube-system secret reads" \
  "$kubectl_log" \
  "auth can-i get secrets -n kube-system"

assert_contains \
  "Kubernetes runtime denies clusterrolebinding creation" \
  "$kubectl_log" \
  "auth can-i create clusterrolebindings"

kubeconfig_paths="$(
  sed -n 's/^KUBECONFIG=//p' "$TEST_TMP_ROOT/runtime-kubectl-env.log" |
    sort -u
)"

assert_not_contains \
  "runtime kubectl never uses ambient/default kubeconfig" \
  "$kubeconfig_paths" \
  "<unset>"

while IFS= read -r kubeconfig_path; do
  [ -n "$kubeconfig_path" ] || continue

  case "$kubeconfig_path" in
    "$kube_runtime_tmp"/*)
      ;;
    *)
      _fail \
        "runtime kubeconfig is confined to TMPDIR" \
        "unexpected kubeconfig path: $kubeconfig_path"
      ;;
  esac
done <<< "$kubeconfig_paths"

remaining_runtime_files="$(
  find "$kube_runtime_tmp" -mindepth 1 -print 2>/dev/null || true
)"

assert_eq \
  "runtime kubeconfig temp material is cleaned up" \
  "" \
  "$remaining_runtime_files"

# M1: kubectl cache stays below the temporary runtime directory.
kube_cache_home="$TEST_TMP_ROOT/kube-cache-home"
kube_cache_log="$TEST_TMP_ROOT/kube-cache.log"
rm -rf "$kube_cache_home"
mkdir -p "$kube_cache_home"
: > "$kube_cache_log"
rm -rf "$kube_runtime_tmp"
mkdir -p "$kube_runtime_tmp"

prepare_runtime_files
run_kube_runtime_status HOME="$kube_cache_home" FAKE_KUBECTL_CACHE_LOG="$kube_cache_log"

assert_eq "cache-isolated Kubernetes runtime chain is READY" "0" "$RC"

for probe in \
  "auth can-i create deployments -n omnivise-iot" \
  "auth can-i create namespaces" \
  "auth can-i get secrets -n kube-system" \
  "auth can-i create clusterrolebindings"
do
  probe_line="$(grep -F -- "$probe" "$TEST_TMP_ROOT/runtime-kubectl.log" || true)"
  assert_contains "kubectl probe [$probe] passes --cache-dir" "$probe_line" "--cache-dir $kube_runtime_tmp/"
done

assert_eq "all four kubectl probes report a cache directory" "4" "$(grep -c . "$kube_cache_log")"
assert_eq \
  "every kubectl cache dir is <KUBECONFIG dir>/cache" \
  "" \
  "$(awk -F'|' '$1 != $2' "$kube_cache_log")"

if [ -e "$kube_cache_home/.kube" ]; then
  _fail "kubectl never writes the default HOME kube cache" "$kube_cache_home/.kube exists"
else
  _pass "kubectl never writes the default HOME kube cache"
fi

assert_eq \
  "cache-isolated runtime temp directory is fully cleaned up" \
  "" \
  "$(find "$kube_runtime_tmp" -mindepth 1 -print 2>/dev/null || true)"

# M11: the kubeconfig exec plugin is exercised with delivery credentials.
m11_token="k8s-aws-v1.M11CANARYEXECTOKEN-must-not-persist"

prepare_runtime_files
run_kube_runtime_status FAKE_EXEC_TOKEN="$m11_token"

assert_eq "exec-plugin Kubernetes runtime chain is READY" "0" "$RC"
assert_eq \
  "every kubectl probe invoked aws eks get-token with exact arguments" \
  "4" \
  "$(grep -cx 'eks get-token --region eu-north-1 --cluster-name omnivise-iot' "$runtime_aws_log" || true)"
assert_eq \
  "every eks get-token call ran with delivery credentials" \
  "4" \
  "$(grep -cx 'credential-mode=delivery operation=eks-get-token' "$runtime_env_log" || true)"
assert_not_contains \
  "eks get-token never ran with bootstrap credentials" \
  "$(cat "$runtime_env_log")" \
  "credential-mode=bootstrap operation=eks-get-token"

m11_all_text="$OUT$ERR$(cat "$runtime_aws_log" "$runtime_env_log" "$TEST_TMP_ROOT/runtime-kubectl.log" "$TEST_TMP_ROOT/runtime-kubectl-env.log")"
if [[ "$m11_all_text" == *"$m11_token"* ]]; then
  _fail "ExecCredential token never reaches stdout/stderr/logs" "exec token canary leaked"
else
  _pass "ExecCredential token never reaches stdout/stderr/logs"
fi
if grep -rqF -e "$m11_token" -- "$kube_runtime_tmp" "$TEST_TMP_ROOT/credential-home" 2>/dev/null; then
  _fail "ExecCredential token never persists under TMPDIR or HOME" "exec token canary persisted"
else
  _pass "ExecCredential token never persists under TMPDIR or HOME"
fi

# M11 D: guard activity - a wrong expected credential mode must fail.
prepare_runtime_files
run_kube_runtime_status FAKE_EXPECT_GET_TOKEN_MODE=bootstrap

assert_eq "wrong get-token credential-mode expectation fails the runtime chain" "3" "$RC"
assert_not_contains "wrong get-token credential-mode expectation is never READY" "$OUT" "READY"

# M11 E: argument guard - a mutated exec command must fail.
for m11_mutation in drop-region wrong-cluster; do
  prepare_runtime_files
  run_kube_runtime_status FAKE_KUBECTL_EXEC_MUTATION="$m11_mutation"

  assert_eq "exec args mutation [$m11_mutation] fails the runtime chain" "3" "$RC"
  assert_not_contains "exec args mutation [$m11_mutation] is never READY" "$OUT" "READY"
done

# M11 A: structural guard - kubeconfig exec stanza mismatch must fail.
prepare_runtime_files
run_kube_runtime_status FAKE_EXPECT_EXEC_CLUSTER=some-other-cluster

assert_eq "kubeconfig exec stanza structural mismatch fails the runtime chain" "3" "$RC"
assert_not_contains "kubeconfig exec stanza mismatch is never READY" "$OUT" "READY"

prepare_runtime_files
run_kube_runtime_status FAKE_KUBECTL_GENERIC_FAILURE=1

assert_eq \
  "generic kubectl failure is environment error, not accepted denial" \
  "3" \
  "$RC"

assert_not_contains \
  "generic kubectl failure does not produce READY" \
  "$OUT" \
  "READY"

prepare_runtime_files
run_kube_runtime_status FAKE_KUBECTL_DEPLOYMENTS=no

assert_eq "Kubernetes deployment authorization no is VIOLATION exit 2" "2" "$RC"
assert_contains "Kubernetes deployment authorization no is VIOLATION" "$OUT" "STATE: VIOLATION"
assert_contains "Kubernetes deployment authorization no prints NEXT" "$OUT" "NEXT:"

prepare_runtime_files
run_kube_runtime_status FAKE_KUBECTL_DEPLOYMENTS=error

assert_eq "Kubernetes deployment authorization operational failure exits 3" "3" "$RC"
assert_not_contains \
  "Kubernetes deployment authorization operational failure is not VIOLATION" \
  "$OUT" \
  "VIOLATION"

suite "aws-demo temp directory containment"

temp_tmpdir="$TEST_TMP_ROOT/temp-containment-tmpdir"

reset_temp_tmpdir() {
  rm -rf "$temp_tmpdir"
  mkdir -p "$temp_tmpdir"
}

temp_leftovers() {
  find "$temp_tmpdir" -mindepth 1 -print 2>/dev/null || true
}

# A: DOWN status path.
reset_temp_tmpdir
: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  TMPDIR="$temp_tmpdir" \
  bash "$AWS_DEMO_SH" status
assert_eq "temp containment DOWN status exits 0" "0" "$RC"
assert_eq "DOWN status leaves no temp artifacts" "" "$(temp_leftovers)"

# B: READY runtime path.
reset_temp_tmpdir
prepare_runtime_files
run_kube_runtime_status TMPDIR="$temp_tmpdir"
assert_eq "temp containment READY status exits 0" "0" "$RC"
assert_eq "READY status leaves no temp artifacts" "" "$(temp_leftovers)"

# C: operational failure paths (AWS runtime and Kubernetes runtime).
reset_temp_tmpdir
prepare_runtime_files
run_kube_runtime_status TMPDIR="$temp_tmpdir" FAKE_GENERIC_LIST_CLUSTERS_FAILURE=1
assert_eq "temp containment AWS runtime failure exits 3" "3" "$RC"
assert_eq "AWS runtime failure leaves no temp artifacts" "" "$(temp_leftovers)"

reset_temp_tmpdir
prepare_runtime_files
run_kube_runtime_status TMPDIR="$temp_tmpdir" FAKE_KUBECTL_DEPLOYMENTS=error
assert_eq "temp containment Kubernetes runtime failure exits 3" "3" "$RC"
assert_eq "Kubernetes runtime failure leaves no temp artifacts" "" "$(temp_leftovers)"

# D/E: SIGTERM while blocked inside the Kubernetes probe.
term_bin="$TEST_TMP_ROOT/term-bin"
mkdir -p "$term_bin"
term_marker="$TEST_TMP_ROOT/term-marker"

cat > "$term_bin/kubectl" <<'FAKEKUBECTL'
#!/usr/bin/env bash
# Signal readiness with our process group, then block until killed.
ps -o pgid= -p "$$" | tr -d ' ' > "${FAKE_BLOCK_MARKER:?}.tmp"
mv "${FAKE_BLOCK_MARKER:?}.tmp" "${FAKE_BLOCK_MARKER:?}"
sleep 30
FAKEKUBECTL
chmod +x "$term_bin/kubectl"

reset_temp_tmpdir
prepare_runtime_files
rm -f "$term_marker"
: > "$runtime_aws_log"
: > "$runtime_env_log"

(
  env \
    PATH="$term_bin:$runtime_bin:$PATH" \
    BASE_FAKE_AWS="$credential_bin/aws" \
    FAKE_AWS_LOG="$runtime_aws_log" \
    FAKE_RUNTIME_ENV_LOG="$runtime_env_log" \
    FAKE_BLOCK_MARKER="$term_marker" \
    FAKE_KEY_STATE="one-active" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$runtime_root" \
    TMPDIR="$temp_tmpdir" \
    setsid bash "$AWS_DEMO_SH" status \
    > "$TEST_TMP_ROOT/term-out" 2> "$TEST_TMP_ROOT/term-err"
) &
term_bg=$!

for _ in $(seq 1 200); do
  [ -s "$term_marker" ] && break
  sleep 0.05
done

if [ -s "$term_marker" ]; then
  _pass "TERM fixture reached blocked Kubernetes probe"
else
  _fail "TERM fixture reached blocked Kubernetes probe" "marker not written"
fi

# E: while alive, everything aws-demo created sits under one runtime root.
top_level="$(find "$temp_tmpdir" -mindepth 1 -maxdepth 1 -print)"
assert_eq "exactly one top-level temp root exists while running" "1" "$(printf '%s\n' "$top_level" | grep -c .)"
assert_contains "top-level temp root is the aws-demo runtime root" "$top_level" "$temp_tmpdir/aws-demo."
assert_contains \
  "kubeconfig lives below the runtime root while running" \
  "$(find "$temp_tmpdir" -name config -print)" \
  "$top_level/"

term_pgid="$(cat "$term_marker" 2>/dev/null || true)"
if [ -n "$term_pgid" ]; then
  kill -TERM -- "-$term_pgid" 2>/dev/null || true
fi

term_rc=0
wait "$term_bg" || term_rc=$?

assert_eq "SIGTERM terminates aws-demo with exit 143" "143" "$term_rc"
assert_not_contains "SIGTERM never reports READY" "$(cat "$TEST_TMP_ROOT/term-out")" "READY"
assert_eq "SIGTERM leaves no temp artifacts" "" "$(temp_leftovers)"

# D2: SIGTERM while blocked inside a DOWN-scan absence probe, when a
# stderr capture file exists and only a main-shell trap can clean it up.
term_down_bin="$TEST_TMP_ROOT/term-down-bin"
mkdir -p "$term_down_bin"

cat > "$term_down_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
if [ "${1:-}" = "iam" ] && [ "${2:-}" = "get-role" ]; then
  ps -o pgid= -p "$$" | tr -d ' ' > "${FAKE_BLOCK_MARKER:?}.tmp"
  mv "${FAKE_BLOCK_MARKER:?}.tmp" "${FAKE_BLOCK_MARKER:?}"
  sleep 30
fi
exec "${FULL_DOWN_FAKE_AWS:?}" "$@"
FAKEAWS
chmod +x "$term_down_bin/aws"

reset_temp_tmpdir
rm -f "$term_marker"
: > "$full_down_log"

(
  env \
    PATH="$term_down_bin:$PATH" \
    FULL_DOWN_FAKE_AWS="$full_down_bin/aws" \
    FAKE_AWS_LOG="$full_down_log" \
    FAKE_BLOCK_MARKER="$term_marker" \
    TMPDIR="$temp_tmpdir" \
    setsid bash "$AWS_DEMO_SH" status \
    > "$TEST_TMP_ROOT/term-down-out" 2> "$TEST_TMP_ROOT/term-down-err"
) &
term_bg=$!

for _ in $(seq 1 200); do
  [ -s "$term_marker" ] && break
  sleep 0.05
done

if [ -s "$term_marker" ]; then
  _pass "TERM fixture reached blocked DOWN absence probe"
else
  _fail "TERM fixture reached blocked DOWN absence probe" "marker not written"
fi

top_level="$(find "$temp_tmpdir" -mindepth 1 -maxdepth 1 -print)"
assert_contains \
  "DOWN absence probe temp file lives below the runtime root" \
  "$top_level" \
  "$temp_tmpdir/aws-demo."
assert_eq \
  "DOWN absence probe creates exactly one top-level temp root" \
  "1" \
  "$(printf '%s\n' "$top_level" | grep -c .)"

term_pgid="$(cat "$term_marker" 2>/dev/null || true)"
if [ -n "$term_pgid" ]; then
  kill -TERM -- "-$term_pgid" 2>/dev/null || true
fi

term_rc=0
wait "$term_bg" || term_rc=$?

assert_eq "SIGTERM during DOWN scan exits 143" "143" "$term_rc"
assert_not_contains "SIGTERM during DOWN scan never reports DOWN-CLEAN" "$(cat "$TEST_TMP_ROOT/term-down-out")" "DOWN-CLEAN"
assert_eq "SIGTERM during DOWN scan leaves no temp artifacts" "" "$(temp_leftovers)"

suite "aws-demo Jenkins credential freshness"

cat > "$runtime_bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *'.State.Running'* ]]; then
  printf '%s\n' true
  exit 0
fi

if [[ "$*" == *'.Mounts'* ]]; then
  printf '[{"Destination":"/run/secrets/omnivise_iot_aws_access_key_id","Source":"%s"},{"Destination":"/run/secrets/omnivise_iot_aws_secret_access_key","Source":"%s"}]\n' \
    "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_access_key_id" \
    "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_secret_access_key"
  exit 0
fi

if [[ "$*" == *'.State.StartedAt'* ]]; then
  printf '%s\n' "${FAKE_JENKINS_STARTED_AT:?}"
  exit 0
fi

printf 'unexpected fake docker call: %s\n' "$*" >&2
exit 99
FAKEDOCKER
chmod +x "$runtime_bin/docker"

run_freshness_status() {
  : > "$runtime_aws_log"
  : > "$runtime_env_log"
  : > "$TEST_TMP_ROOT/runtime-kubectl.log"
  : > "$TEST_TMP_ROOT/runtime-kubectl-env.log"

  rm -rf "$kube_runtime_tmp"
  mkdir -p "$kube_runtime_tmp"

  run_capture env \
    PATH="$runtime_bin:$PATH" \
    BASE_FAKE_AWS="$credential_bin/aws" \
    FAKE_AWS_LOG="$runtime_aws_log" \
    FAKE_RUNTIME_ENV_LOG="$runtime_env_log" \
    FAKE_KUBECTL_LOG="$TEST_TMP_ROOT/runtime-kubectl.log" \
    FAKE_KUBECTL_ENV_LOG="$TEST_TMP_ROOT/runtime-kubectl-env.log" \
    FAKE_KEY_STATE="one-active" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$runtime_root" \
    TMPDIR="$kube_runtime_tmp" \
    "$@" \
    bash "$AWS_DEMO_SH" status
}

prepare_runtime_files

id_before="$(cat "$runtime_id_file")"
secret_before="$(cat "$runtime_secret_file")"

run_freshness_status FAKE_JENKINS_STARTED_AT="2099-01-01T00:00:00Z"

assert_eq \
  "Jenkins started after latest credential metadata change is READY" \
  "0" \
  "$RC"

assert_contains \
  "fresh Jenkins reports READY" \
  "$OUT" \
  "STATE: READY"

assert_eq \
  "freshness check preserves access-key ID file" \
  "$id_before" \
  "$(cat "$runtime_id_file")"

assert_eq \
  "freshness check preserves secret file" \
  "$secret_before" \
  "$(cat "$runtime_secret_file")"

prepare_runtime_files

run_freshness_status FAKE_JENKINS_STARTED_AT="2000-01-01T00:00:00Z"

assert_eq \
  "Jenkins started before credential metadata change requires restart" \
  "1" \
  "$RC"

assert_contains \
  "stale Jenkins reports restart-required" \
  "$OUT" \
  "UP-RESTART-REQUIRED"
assert_lifecycle_state "stale Jenkins STATE is a lifecycle state" "$OUT" required

prepare_runtime_files

latest_secret_epoch="$(
  {
    stat -c '%Y' "$runtime_id_file"
    stat -c '%Z' "$runtime_id_file"
    stat -c '%Y' "$runtime_secret_file"
    stat -c '%Z' "$runtime_secret_file"
  } | sort -nr | head -n1
)"

equal_started_at="$(
  date -u -d "@$latest_secret_epoch" '+%Y-%m-%dT%H:%M:%SZ'
)"

run_freshness_status FAKE_JENKINS_STARTED_AT="$equal_started_at"

assert_eq \
  "Jenkins StartedAt equal to latest credential change is not fresh" \
  "1" \
  "$RC"

assert_contains \
  "equal freshness timestamp requires restart" \
  "$OUT" \
  "UP-RESTART-REQUIRED"

prepare_runtime_files

run_freshness_status FAKE_JENKINS_STARTED_AT="not-a-timestamp"

assert_eq \
  "unparseable Jenkins StartedAt is not considered fresh" \
  "1" \
  "$RC"

assert_contains \
  "unparseable StartedAt requires restart" \
  "$OUT" \
  "UP-RESTART-REQUIRED"

# M9: file metadata acquisition must fail closed (never READY).
freshness_stat_bin="$TEST_TMP_ROOT/freshness-stat-bin"
mkdir -p "$freshness_stat_bin"
real_stat="$(command -v stat)"

cat > "$freshness_stat_bin/stat" <<'FAKESTAT'
#!/usr/bin/env bash
# Fails or corrupts only timestamp formats for one selected file; every other
# stat use (owner, mode, device:inode) passes through to the real stat.
target="${FAKE_STAT_TARGET:-}"
if [ -n "$target" ] && [[ "$*" =~ %(\.[0-9])?[YyZz] ]] && [[ " $* " == *" $target "* ]]; then
  case "${FAKE_STAT_MODE:-fail}" in
    fail)
      printf 'stat: cannot statx: Input/output error\n' >&2
      exit 1
      ;;
    garbage)
      printf '%s\n' 'not-a-timestamp'
      exit 0
      ;;
  esac
fi
exec "${REAL_STAT:?}" "$@"
FAKESTAT
chmod +x "$freshness_stat_bin/stat"

run_freshness_stat_case() {
  run_freshness_status \
    PATH="$freshness_stat_bin:$runtime_bin:$PATH" \
    REAL_STAT="$real_stat" \
    FAKE_JENKINS_STARTED_AT="2099-01-01T00:00:00Z" \
    "$@"
}

for m9_case in "access-key ID:$runtime_id_file:fail" \
               "secret:$runtime_secret_file:fail" \
               "access-key ID:$runtime_id_file:garbage"; do
  m9_label="${m9_case%%:*}"
  m9_rest="${m9_case#*:}"
  m9_file="${m9_rest%:*}"
  m9_mode="${m9_rest##*:}"

  prepare_runtime_files
  id_before="$(cat "$runtime_id_file")"
  secret_before="$(cat "$runtime_secret_file")"

  run_freshness_stat_case FAKE_STAT_TARGET="$m9_file" FAKE_STAT_MODE="$m9_mode"

  assert_eq "$m9_label file metadata $m9_mode exits 3" "3" "$RC"
  assert_not_contains "$m9_label file metadata $m9_mode is never READY" "$OUT" "READY"
  assert_not_contains \
    "$m9_label file metadata $m9_mode does not guess restart-required" \
    "$OUT" \
    "UP-RESTART-REQUIRED"
  assert_contains "$m9_label file metadata $m9_mode explains metadata failure" "$ERR" "metadata"
  assert_eq "$m9_label metadata $m9_mode preserves ID file" "$id_before" "$(cat "$runtime_id_file")"
  assert_eq "$m9_label metadata $m9_mode preserves secret file" "$secret_before" "$(cat "$runtime_secret_file")"
  assert_not_contains "$m9_label metadata $m9_mode never prints the secret" "$OUT$ERR" "$secret_before"
  assert_not_contains "$m9_label metadata $m9_mode never prints the key ID" "$OUT$ERR" "$id_before"
done

# M9: exact nanosecond equality is not fresh; one nanosecond later is fresh.
m9_ns_to_started_at() {
  local ns="$1"
  printf '%s.%sZ' \
    "$(date -u -d "@${ns:0:${#ns}-9}" '+%Y-%m-%dT%H:%M:%S')" \
    "${ns: -9}"
}

prepare_runtime_files
latest_ns="$(
  for f in "$runtime_id_file" "$runtime_secret_file"; do
    LC_ALL=C stat -c '%.9Y' "$f"
    LC_ALL=C stat -c '%.9Z' "$f"
  done | tr -d '.' | sort -n | tail -n1
)"

run_freshness_status FAKE_JENKINS_STARTED_AT="$(m9_ns_to_started_at "$latest_ns")"
assert_eq "StartedAt exactly equal to latest metadata (ns) is not fresh" "1" "$RC"
assert_contains "exact-equality StartedAt requires restart" "$OUT" "STATE: UP-RESTART-REQUIRED"

run_freshness_status FAKE_JENKINS_STARTED_AT="$(m9_ns_to_started_at "$((10#$latest_ns + 1))")"
assert_eq "StartedAt one nanosecond after latest metadata is fresh" "0" "$RC"
assert_contains "one-nanosecond-later StartedAt is READY" "$OUT" "STATE: READY"

suite "aws-demo post-create runtime verification"

post_create_bin="$TEST_TMP_ROOT/post-create-bin"
mkdir -p "$post_create_bin"

cat > "$post_create_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

# Optional IAM propagation simulation for the bootstrap caller-identity probe.
if [ "${AWS_ACCESS_KEY_ID:-}" = "AKIAEXAMPLE000000001" ] &&
   [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ] &&
   [ -n "${FAKE_BOOTSTRAP_CALLER_MODE:-}" ]; then
  count_file="${FAKE_BOOTSTRAP_CALLER_COUNT_FILE:?}"
  count=0
  [ -f "$count_file" ] && count="$(cat "$count_file")"
  count=$((count + 1))
  printf '%s' "$count" > "$count_file"
  printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

  case "$FAKE_BOOTSTRAP_CALLER_MODE" in
    propagating)
      if [ "$count" -le "${FAKE_PROPAGATION_FAILURES:?}" ]; then
        printf 'An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.\n' >&2
        exit 254
      fi
      ;;
    always-invalid)
      printf 'An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.\n' >&2
      exit 254
      ;;
    network)
      printf 'Could not connect to the endpoint URL: "https://sts.eu-north-1.amazonaws.com/"\n' >&2
      exit 255
      ;;
  esac

  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap","UserId":"AIDABOOTSTRAP"}'
  exit 0
fi

# Runtime credential-bearing calls are handled by the already-tested
# runtime AWS fixture.
if [ -n "${AWS_ACCESS_KEY_ID:-}" ]; then
  exec "${RUNTIME_FAKE_AWS:?}" "$@"
fi

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

# Before creation there must be zero bootstrap keys; after creation,
# exactly the newly-created active key must be visible.
if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
  if [ "$(cat "${FAKE_POST_CREATE_STATE_FILE:?}")" = "created" ]; then
    printf '%s\n' '{
      "AccessKeyMetadata":[{
        "UserName":"omnivise-iot-jenkins-bootstrap",
        "AccessKeyId":"AKIAEXAMPLE000000001",
        "Status":"Active"
      }]
    }'
  else
    printf '%s\n' '{"AccessKeyMetadata":[]}'
  fi
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "create-access-key" ]; then
  printf '%s\n' created > "${FAKE_POST_CREATE_STATE_FILE:?}"

  printf '%s\n' '{
    "AccessKey":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "AccessKeyId":"AKIAEXAMPLE000000001",
      "Status":"Active",
      "SecretAccessKey":"0123456789abcdefghijklmnopqrstuvwxYZAB12"
    }
  }'
  exit 0
fi

# All normal operator-side cloud invariant calls delegate to the existing
# credential fixture.
exec "${BASE_FAKE_AWS:?}" "$@"
FAKEAWS
chmod +x "$post_create_bin/aws"

# Reuse the already-tested Docker and kubectl runtime fixtures.
ln -sf "$runtime_bin/docker" "$post_create_bin/docker"
ln -sf "$runtime_bin/kubectl" "$post_create_bin/kubectl"

# Fast, observable sleep for bounded retry tests.
cat > "$post_create_bin/sleep" <<'FAKESLEEP'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SLEEP_LOG:?}"
FAKESLEEP
chmod +x "$post_create_bin/sleep"

post_create_root="$TEST_TMP_ROOT/post-create-files"
mkdir -p "$post_create_root"

post_create_id="$post_create_root/secrets/omnivise_iot_aws_access_key_id"
post_create_secret="$post_create_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$post_create_root/secrets"
post_create_state="$TEST_TMP_ROOT/post-create-state"
post_create_aws_log="$TEST_TMP_ROOT/post-create-aws.log"
post_create_runtime_env_log="$TEST_TMP_ROOT/post-create-runtime-env.log"
post_create_kubectl_log="$TEST_TMP_ROOT/post-create-kubectl.log"
post_create_kubectl_env_log="$TEST_TMP_ROOT/post-create-kubectl-env.log"
post_create_caller_count="$TEST_TMP_ROOT/post-create-caller-count"
post_create_sleep_log="$TEST_TMP_ROOT/post-create-sleep.log"

run_post_create_issue() {
  printf '%s\n' empty > "$post_create_state"
  : > "$post_create_aws_log"
  : > "$post_create_runtime_env_log"
  : > "$post_create_kubectl_log"
  : > "$post_create_kubectl_env_log"
  : > "$post_create_sleep_log"
  rm -f "$post_create_caller_count"

  printf '%s' OLD-ID > "$post_create_id"
  printf '%s' OLD-SECRET > "$post_create_secret"
  chmod 600 "$post_create_id" "$post_create_secret"

  run_capture env \
    PATH="$post_create_bin:$PATH" \
    BASE_FAKE_AWS="$credential_bin/aws" \
    RUNTIME_FAKE_AWS="$runtime_bin/aws" \
    FAKE_AWS_LOG="$post_create_aws_log" \
    FAKE_RUNTIME_ENV_LOG="$post_create_runtime_env_log" \
    FAKE_POST_CREATE_STATE_FILE="$post_create_state" \
    FAKE_KEY_STATE="one-active" \
    FAKE_KUBECTL_LOG="$post_create_kubectl_log" \
    FAKE_KUBECTL_ENV_LOG="$post_create_kubectl_env_log" \
    FAKE_JENKINS_STARTED_AT="2000-01-01T00:00:00Z" \
    FAKE_BOOTSTRAP_CALLER_COUNT_FILE="$post_create_caller_count" \
    FAKE_SLEEP_LOG="$post_create_sleep_log" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$post_create_root" \
    "$@" \
    bash "$AWS_DEMO_SH" issue-credential
}

run_post_create_issue

assert_eq \
  "successful post-create runtime verification remains restart-required" \
  "1" \
  "$RC"

assert_contains \
  "post-create success reports restart-required" \
  "$OUT" \
  "UP-RESTART-REQUIRED"

assert_contains \
  "post-create verification assumes delivery role" \
  "$(cat "$post_create_aws_log")" \
  "sts assume-role --region eu-north-1 --role-arn arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"

assert_contains \
  "post-create verification runs Kubernetes deployment authorization probe" \
  "$(cat "$post_create_kubectl_log")" \
  "auth can-i create deployments -n omnivise-iot"

assert_contains \
  "post-create verification runs Kubernetes namespace denial probe" \
  "$(cat "$post_create_kubectl_log")" \
  "auth can-i create namespaces"

assert_not_contains \
  "successful post-create verification never rolls back credential" \
  "$(cat "$post_create_aws_log")" \
  "delete-access-key"

# Once the key exists, an operational runtime failure (exit 3 from either
# chain) becomes one post-create VIOLATION with masked recovery guidance.
assert_post_create_runtime_violation() {
  local label="$1" chain="$2"

  assert_eq "$label exits 2" "2" "$RC"
  assert_lifecycle_state "$label emits exactly one valid lifecycle state" "$OUT" required
  assert_contains "$label is VIOLATION" "$OUT" "STATE: VIOLATION"
  assert_contains "$label names the failed $chain runtime verification" "$OUT" "the $chain runtime verification of the created key failed unexpectedly"
  assert_contains "$label shows only the masked suffix" "$OUT" "created bootstrap key suffix ****0001"
  assert_contains \
    "$label gives explicit recovery guidance" \
    "$OUT" \
    "NEXT: run scripts/aws-demo.sh revoke-credential --key-id 0001, then scripts/aws-demo.sh issue-credential"
  assert_not_contains "$label leaks no full access key ID" "$OUT$ERR" "AKIAEXAMPLE000000001"
  assert_not_contains "$label leaks no secret" "$OUT$ERR" "0123456789abcdefghijklmnopqrstuvwxYZAB12"
  assert_eq "$label retains created credential" "created" "$(cat "$post_create_state")"
  assert_eq "$label keeps the written ID file" "AKIAEXAMPLE000000001" "$(cat "$post_create_id")"
  assert_eq "$label keeps the written secret file" "0123456789abcdefghijklmnopqrstuvwxYZAB12" "$(cat "$post_create_secret")"
  assert_not_contains "$label does not auto-rollback credential" "$(cat "$post_create_aws_log")" "delete-access-key"
}

run_post_create_issue FAKE_GENERIC_LIST_CLUSTERS_FAILURE=1
assert_post_create_runtime_violation "post-create AWS runtime operational failure" AWS

run_post_create_issue FAKE_KUBECTL_GENERIC_FAILURE=1
assert_post_create_runtime_violation "post-create Kubernetes runtime operational failure" Kubernetes

# Already-classified runtime violations (exit 2) pass through unchanged, with
# their own single STATE line and no post-create translation.
run_post_create_issue FAKE_DELIVERY_CALLER_ARN="arn:aws:sts::554422868760:assumed-role/other-role/aws-demo-runtime"
assert_eq "post-create AWS authorization violation exits 2" "2" "$RC"
assert_lifecycle_state "post-create AWS authorization violation has exactly one STATE" "$OUT" required
assert_contains "post-create AWS authorization violation keeps its own detail" "$OUT" "assumed delivery session is not the omnivise-iot-jenkins-delivery role"
assert_not_contains "post-create AWS authorization violation is not re-reported" "$OUT" "runtime verification of the created key failed unexpectedly"
assert_not_contains "post-create AWS authorization violation does not auto-rollback" "$(cat "$post_create_aws_log")" "delete-access-key"

run_post_create_issue FAKE_KUBECTL_DEPLOYMENTS=no
assert_eq "post-create Kubernetes authorization violation exits 2" "2" "$RC"
assert_lifecycle_state "post-create Kubernetes authorization violation has exactly one STATE" "$OUT" required
assert_contains "post-create Kubernetes authorization violation is VIOLATION" "$OUT" "STATE: VIOLATION"
assert_not_contains "post-create Kubernetes authorization violation is not re-reported" "$OUT" "runtime verification of the created key failed unexpectedly"
assert_not_contains "post-create Kubernetes authorization violation does not auto-rollback" "$(cat "$post_create_aws_log")" "delete-access-key"

# H5 A: bootstrap credential becomes usable after bounded IAM propagation.
run_post_create_issue FAKE_BOOTSTRAP_CALLER_MODE=propagating FAKE_PROPAGATION_FAILURES=2

assert_eq "post-create propagation eventually succeeds with normal outcome" "1" "$RC"
assert_contains \
  "post-create propagation success reports restart-required" \
  "$OUT" \
  "STATE: UP-RESTART-REQUIRED"
assert_eq \
  "post-create propagation retried bootstrap identity until usable" \
  "3" \
  "$(cat "$post_create_caller_count")"
assert_eq \
  "post-create propagation sleeps between attempts" \
  "2" \
  "$(grep -c . "$post_create_sleep_log")"
assert_contains \
  "post-create propagation continues into Kubernetes chain" \
  "$(cat "$post_create_kubectl_log")" \
  "auth can-i create deployments -n omnivise-iot"
assert_not_contains \
  "post-create propagation success never rolls back credential" \
  "$(cat "$post_create_aws_log")" \
  "delete-access-key"

# H5 B: propagation never completes within the bound.
run_post_create_issue FAKE_BOOTSTRAP_CALLER_MODE=always-invalid

assert_eq "post-create propagation exhaustion is retryable exit 1" "1" "$RC"
assert_eq \
  "post-create propagation exhaustion is bounded to 10 attempts" \
  "10" \
  "$(cat "$post_create_caller_count")"
assert_not_contains \
  "post-create propagation exhaustion claims no lifecycle state" \
  "$OUT" \
  "STATE:"
assert_contains \
  "post-create propagation exhaustion points to status" \
  "$OUT" \
  "NEXT: rerun scripts/aws-demo.sh status"
assert_eq \
  "post-create propagation exhaustion retains created credential" \
  "created" \
  "$(cat "$post_create_state")"
assert_not_contains \
  "post-create propagation exhaustion does not roll back credential" \
  "$(cat "$post_create_aws_log")" \
  "delete-access-key"
assert_eq \
  "post-create propagation exhaustion never reaches Kubernetes chain" \
  "" \
  "$(cat "$post_create_kubectl_log")"

# H5 C: generic bootstrap STS failure is not propagation and is not retried.
run_post_create_issue FAKE_BOOTSTRAP_CALLER_MODE=network

assert_post_create_runtime_violation "post-create generic STS failure" AWS
assert_eq \
  "post-create generic STS failure is attempted exactly once" \
  "1" \
  "$(cat "$post_create_caller_count")"
assert_eq \
  "post-create generic STS failure does not sleep for retry" \
  "0" \
  "$(grep -c . "$post_create_sleep_log" || true)"
assert_not_contains \
  "post-create generic STS failure does not roll back credential" \
  "$(cat "$post_create_aws_log")" \
  "delete-access-key"

# H5 guard: normal status must not treat InvalidClientTokenId as propagation.
printf '%s\n' created > "$post_create_state"
: > "$post_create_aws_log"
: > "$post_create_sleep_log"
rm -f "$post_create_caller_count"
printf '%s' "AKIAEXAMPLE000000001" > "$post_create_id"
printf '%s' "0123456789abcdefghijklmnopqrstuvwxYZAB12" > "$post_create_secret"
chmod 600 "$post_create_id" "$post_create_secret"

run_capture env \
  PATH="$post_create_bin:$PATH" \
  BASE_FAKE_AWS="$credential_bin/aws" \
  RUNTIME_FAKE_AWS="$runtime_bin/aws" \
  FAKE_AWS_LOG="$post_create_aws_log" \
  FAKE_RUNTIME_ENV_LOG="$post_create_runtime_env_log" \
  FAKE_POST_CREATE_STATE_FILE="$post_create_state" \
  FAKE_KEY_STATE="one-active" \
  FAKE_KUBECTL_LOG="$post_create_kubectl_log" \
  FAKE_KUBECTL_ENV_LOG="$post_create_kubectl_env_log" \
  FAKE_BOOTSTRAP_CALLER_MODE=always-invalid \
  FAKE_BOOTSTRAP_CALLER_COUNT_FILE="$post_create_caller_count" \
  FAKE_SLEEP_LOG="$post_create_sleep_log" \
  OMNIVISE_JENKINS_PLATFORM_DIR="$post_create_root" \
  bash "$AWS_DEMO_SH" status

assert_eq "status InvalidClientTokenId remains environment error" "3" "$RC"
assert_eq \
  "status InvalidClientTokenId is not retried" \
  "1" \
  "$(cat "$post_create_caller_count")"
assert_not_contains "status InvalidClientTokenId is never READY" "$OUT" "READY"

suite "aws-demo DOWN-DIRTY credential recovery"

down_recovery_bin="$TEST_TMP_ROOT/down-recovery-bin"
mkdir -p "$down_recovery_bin"

cat > "$down_recovery_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AROAOPERATOR"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  printf 'An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found\n' >&2
  exit 254
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  case "${FAKE_DOWN_BOOTSTRAP_STATE:-present}" in
    absent)
      printf 'An error occurred (NoSuchEntity) when calling the GetUser operation: user not found\n' >&2
      exit 254
      ;;
    denied)
      printf 'An error occurred (AccessDenied) when calling the GetUser operation: denied\n' >&2
      exit 254
      ;;
    present)
      printf '%s\n' '{
        "User":{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
        }
      }'
      exit 0
      ;;
  esac
fi

# Complete DOWN leftover scan responses (clean unless a leftover is requested).
if [ "$1" = "ec2" ] && [ "$2" = "describe-vpcs" ]; then
  case "${FAKE_VPC_LEFTOVER:-0}" in
    0) printf '%s\n' '{"Vpcs":[]}' ;;
    1) printf '%s\n' '{"Vpcs":[{"VpcId":"vpc-123"}]}' ;;
  esac
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-subnets" ]; then
  printf '%s\n' '{"Subnets":[]}'
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-internet-gateways" ]; then
  printf '%s\n' '{"InternetGateways":[]}'
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-route-tables" ]; then
  printf '%s\n' '{"RouteTables":[]}'
  exit 0
fi

if [ "$1" = "ec2" ] && [ "$2" = "describe-volumes" ]; then
  printf '%s\n' '{"Volumes":[]}'
  exit 0
fi

if [ "$1" = "elbv2" ] && [ "$2" = "describe-load-balancers" ]; then
  printf '%s\n' '{"LoadBalancers":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-policy" ]; then
  printf 'An error occurred (NoSuchEntity) when calling the GetPolicy operation: policy not found\n' >&2
  exit 254
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  printf 'An error occurred (NoSuchEntity) when calling the GetRole operation: role not found\n' >&2
  exit 254
fi

if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
  state="$(cat "${FAKE_DOWN_KEY_STATE_FILE:?}")"

  case "$state" in
    zero)
      printf '%s\n' '{"AccessKeyMetadata":[]}'
      ;;
    one)
      printf '%s\n' '{
        "AccessKeyMetadata":[{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIA1234567890ABCDEF",
          "Status":"Active"
        }]
      }'
      ;;
    two)
      printf '%s\n' '{
        "AccessKeyMetadata":[
          {
            "UserName":"omnivise-iot-jenkins-bootstrap",
            "AccessKeyId":"AKIA1234567890ABCDEF",
            "Status":"Active"
          },
          {
            "UserName":"omnivise-iot-jenkins-bootstrap",
            "AccessKeyId":"AKIA0987654321FEDCBA",
            "Status":"Active"
          }
        ]
      }'
      ;;
    remaining-second)
      printf '%s\n' '{
        "AccessKeyMetadata":[{
          "UserName":"omnivise-iot-jenkins-bootstrap",
          "AccessKeyId":"AKIA0987654321FEDCBA",
          "Status":"Active"
        }]
      }'
      ;;
  esac
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "delete-access-key" ]; then
  key_id=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--access-key-id" ]; then
      key_id="$2"
      break
    fi
    shift
  done

  case "$key_id" in
    AKIA1234567890ABCDEF)
      current="$(cat "${FAKE_DOWN_KEY_STATE_FILE:?}")"
      case "$current" in
        one)
          printf '%s\n' zero > "${FAKE_DOWN_KEY_STATE_FILE:?}"
          ;;
        two)
          printf '%s\n' remaining-second > "${FAKE_DOWN_KEY_STATE_FILE:?}"
          ;;
      esac
      exit 0
      ;;
    AKIA0987654321FEDCBA)
      printf 'unexpected deletion of second recovery key\n' >&2
      exit 99
      ;;
  esac
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$down_recovery_bin/aws"

down_recovery_root="$TEST_TMP_ROOT/down-recovery-files"
mkdir -p "$down_recovery_root"

down_recovery_id="$down_recovery_root/secrets/omnivise_iot_aws_access_key_id"
down_recovery_secret="$down_recovery_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$down_recovery_root/secrets"
down_recovery_state="$TEST_TMP_ROOT/down-recovery-state"
down_recovery_log="$TEST_TMP_ROOT/down-recovery-aws.log"

printf '%s' "STALE-LOCAL-ID" > "$down_recovery_id"
printf '%s' "STALE-LOCAL-SECRET" > "$down_recovery_secret"
chmod 600 "$down_recovery_id" "$down_recovery_secret"

run_down_recovery() {
  : > "$down_recovery_log"

  run_capture env \
    PATH="$down_recovery_bin:$PATH" \
    FAKE_AWS_LOG="$down_recovery_log" \
    FAKE_DOWN_KEY_STATE_FILE="$down_recovery_state" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$down_recovery_root" \
    "$@" \
    bash "$AWS_DEMO_SH" revoke-credential "${RECOVERY_ARGS[@]}"
}

printf '%s\n' one > "$down_recovery_state"
RECOVERY_ARGS=(--key-id AKIA1234567890ABCDEF)
run_down_recovery

assert_eq \
  "DOWN-DIRTY explicit full-key recovery revoke succeeds" \
  "0" \
  "$RC"

assert_contains \
  "DOWN-DIRTY recovery deletes selected bootstrap key" \
  "$(cat "$down_recovery_log")" \
  "iam delete-access-key --user-name omnivise-iot-jenkins-bootstrap --access-key-id AKIA1234567890ABCDEF"

assert_eq \
  "DOWN-DIRTY full-key recovery leaves no bootstrap keys" \
  "zero" \
  "$(cat "$down_recovery_state")"

printf '%s\n' one > "$down_recovery_state"
RECOVERY_ARGS=(--key-id CDEF)
run_down_recovery

assert_eq \
  "DOWN-DIRTY unique-suffix recovery revoke succeeds" \
  "0" \
  "$RC"

assert_eq \
  "DOWN-DIRTY suffix recovery resolves selected key" \
  "zero" \
  "$(cat "$down_recovery_state")"

printf '%s\n' one > "$down_recovery_state"
RECOVERY_ARGS=()
run_down_recovery

assert_eq \
  "DOWN-DIRTY revoke without explicit selector is violation" \
  "2" \
  "$RC"

assert_not_contains \
  "DOWN-DIRTY revoke without selector performs no delete" \
  "$(cat "$down_recovery_log")" \
  "delete-access-key"

printf '%s\n' two > "$down_recovery_state"
RECOVERY_ARGS=(--key-id CDEF)
run_down_recovery

assert_eq \
  "DOWN-DIRTY recovery deletes only explicitly selected key" \
  "0" \
  "$RC"

assert_eq \
  "DOWN-DIRTY recovery preserves unselected bootstrap key" \
  "remaining-second" \
  "$(cat "$down_recovery_state")"

assert_not_contains \
  "DOWN-DIRTY recovery never deletes unselected second key" \
  "$(cat "$down_recovery_log")" \
  "AKIA0987654321FEDCBA"

printf '%s\n' zero > "$down_recovery_state"
RECOVERY_ARGS=(--key-id CDEF)
run_down_recovery FAKE_DOWN_BOOTSTRAP_STATE=absent

assert_eq \
  "cluster absent and bootstrap user absent is idempotent clean state" \
  "0" \
  "$RC"

assert_contains \
  "bootstrap user absence reports DOWN-CLEAN" \
  "$OUT" \
  "DOWN-CLEAN"

assert_not_contains \
  "bootstrap user absence performs no credential mutation" \
  "$(cat "$down_recovery_log")" \
  "delete-access-key"

assert_contains \
  "bootstrap user absence DOWN-CLEAN comes from complete DOWN scan" \
  "$(cat "$down_recovery_log")" \
  "ec2 describe-vpcs --region eu-north-1"

assert_contains \
  "bootstrap user absence DOWN-CLEAN scan includes platform roles" \
  "$(cat "$down_recovery_log")" \
  "iam get-role --role-name omnivise-iot-aws-eks-cluster"

printf '%s\n' zero > "$down_recovery_state"
RECOVERY_ARGS=(--key-id CDEF)
run_down_recovery FAKE_DOWN_BOOTSTRAP_STATE=absent FAKE_VPC_LEFTOVER=1

assert_eq \
  "bootstrap user absent with VPC leftover is idempotent no-op revoke" \
  "0" \
  "$RC"

assert_contains \
  "bootstrap user absent with VPC leftover reports DOWN-DIRTY" \
  "$OUT" \
  "STATE: DOWN-DIRTY"

assert_not_contains \
  "bootstrap user absent with VPC leftover never claims DOWN-CLEAN" \
  "$OUT" \
  "STATE: DOWN-CLEAN"

assert_contains \
  "bootstrap user absent with VPC leftover runs complete DOWN scan" \
  "$(cat "$down_recovery_log")" \
  "ec2 describe-vpcs --region eu-north-1"

assert_not_contains \
  "bootstrap user absent with VPC leftover performs no delete" \
  "$(cat "$down_recovery_log")" \
  "delete-access-key"

printf '%s\n' one > "$down_recovery_state"
RECOVERY_ARGS=(--key-id CDEF)
run_down_recovery FAKE_DOWN_BOOTSTRAP_STATE=denied

assert_eq \
  "DOWN recovery IAM AccessDenied is environment failure" \
  "3" \
  "$RC"

assert_not_contains \
  "DOWN recovery IAM AccessDenied performs no delete" \
  "$(cat "$down_recovery_log")" \
  "delete-access-key"

suite "aws-demo local secret symlink hardening"

symlink_bin="$TEST_TMP_ROOT/symlink-bin"
mkdir -p "$symlink_bin"

cat > "$symlink_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

if [ "$1" = "sts" ] && [ "$2" = "get-caller-identity" ]; then
  printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/operator-session","UserId":"AROAEXAMPLE"}'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-cluster" ]; then
  printf '%s\n' '{
    "cluster":{
      "name":"omnivise-iot",
      "arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot",
      "status":"ACTIVE"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user" ]; then
  printf '%s\n' '{
    "User":{
      "UserName":"omnivise-iot-jenkins-bootstrap",
      "Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-groups-for-user" ]; then
  printf '%s\n' '{"Groups":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-user-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-user-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-bootstrap-assume-delivery"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-user-policy" ]; then
  printf '%s\n' '{
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"sts:AssumeRole",
        "Resource":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role" ]; then
  printf '%s\n' '{
    "Role":{
      "RoleName":"omnivise-iot-jenkins-delivery",
      "Arn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "AssumeRolePolicyDocument":{
        "Version":"2012-10-17",
        "Statement":[{
          "Effect":"Allow",
          "Principal":{"AWS":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"},
          "Action":"sts:AssumeRole"
        }]
      }
    }
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-attached-role-policies" ]; then
  printf '%s\n' '{"AttachedPolicies":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-role-policies" ]; then
  printf '%s\n' '{"PolicyNames":["omnivise-iot-jenkins-delivery-describe-cluster"]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "get-role-policy" ]; then
  printf '%s\n' '{
    "PolicyDocument":{
      "Version":"2012-10-17",
      "Statement":[{
        "Effect":"Allow",
        "Action":"eks:DescribeCluster",
        "Resource":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
      }]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "describe-access-entry" ]; then
  principal=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--principal-arn" ]; then
      principal="$2"
      break
    fi
    shift
  done

  if [ "$principal" = "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap" ]; then
    printf 'An error occurred (ResourceNotFoundException) when calling the DescribeAccessEntry operation: not found\n' >&2
    exit 254
  fi

  printf '%s\n' '{
    "accessEntry":{
      "principalArn":"arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery",
      "type":"STANDARD",
      "kubernetesGroups":[]
    }
  }'
  exit 0
fi

if [ "$1" = "eks" ] && [ "$2" = "list-associated-access-policies" ]; then
  printf '%s\n' '{
    "associatedAccessPolicies":[{
      "policyArn":"arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy",
      "accessScope":{"type":"namespace","namespaces":["omnivise-iot"]}
    }]
  }'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
  printf '%s\n' '{"AccessKeyMetadata":[]}'
  exit 0
fi

if [ "$1" = "iam" ] && [ "$2" = "create-access-key" ]; then
  printf 'create-access-key must not be reached for symlink secret paths\n' >&2
  exit 99
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$symlink_bin/aws"

cat > "$symlink_bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "inspect" ]; then
  if [[ "$*" == *'.State.Running'* ]]; then
    printf '%s\n' true
    exit 0
  fi

  if [[ "$*" == *'.Mounts'* ]]; then
    printf '[{"Destination":"/run/secrets/omnivise_iot_aws_access_key_id","Source":"%s"},{"Destination":"/run/secrets/omnivise_iot_aws_secret_access_key","Source":"%s"}]\n' \
      "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_access_key_id" \
      "${OMNIVISE_JENKINS_PLATFORM_DIR:?}/secrets/omnivise_iot_aws_secret_access_key"
    exit 0
  fi
fi

printf 'unexpected fake docker call: %s\n' "$*" >&2
exit 99
FAKEDOCKER
chmod +x "$symlink_bin/docker"

symlink_root="$TEST_TMP_ROOT/symlink-files"
mkdir -p "$symlink_root"

symlink_real_id="$symlink_root/real-id"
symlink_real_secret="$symlink_root/real-secret"
symlink_id="$symlink_root/secrets/omnivise_iot_aws_access_key_id"
symlink_secret="$symlink_root/secrets/omnivise_iot_aws_secret_access_key"
mkdir -p "$symlink_root/secrets"
symlink_log="$TEST_TMP_ROOT/symlink-aws.log"

printf '%s' REAL-ID > "$symlink_real_id"
printf '%s' REAL-SECRET > "$symlink_real_secret"
chmod 600 "$symlink_real_id" "$symlink_real_secret"

ln -s "$symlink_real_id" "$symlink_id"
ln -s "$symlink_real_secret" "$symlink_secret"

: > "$symlink_log"

run_capture env \
  PATH="$symlink_bin:$PATH" \
  FAKE_AWS_LOG="$symlink_log" \
  OMNIVISE_JENKINS_PLATFORM_DIR="$symlink_root" \
  bash "$AWS_DEMO_SH" issue-credential

assert_eq \
  "symlink access-key ID file is violation" \
  "2" \
  "$RC"

assert_contains \
  "symlink access-key ID rejection names symbolic link" \
  "$OUT" \
  "symbolic link"

assert_not_contains \
  "symlink secret paths block credential creation" \
  "$(cat "$symlink_log")" \
  "create-access-key"

suite "aws-demo required core tool preflight"

tool_preflight_root="$TEST_TMP_ROOT/tool-preflight"
mkdir -p "$tool_preflight_root"

tool_preflight_bin="$tool_preflight_root/bin"
mkdir -p "$tool_preflight_bin"
tool_preflight_tmpdir="$tool_preflight_root/tmp"
mkdir -p "$tool_preflight_tmpdir"

# Provide only the tools the test intentionally keeps available.
for tool in jq mktemp stat realpath flock date id rm bash; do
  resolved="$(command -v "$tool")"
  ln -s "$resolved" "$tool_preflight_bin/$tool"
done

cat > "$tool_preflight_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

if [ "$1" = "configure" ] && [ "$2" = "get" ] && [ "$3" = "cli_history" ]; then
  printf '%s\n' disabled
  exit 0
fi

printf 'unexpected fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$tool_preflight_bin/aws"

run_capture env \
  PATH="$tool_preflight_bin" \
  TMPDIR="$tool_preflight_tmpdir" \
  bash "$AWS_DEMO_SH" status

assert_eq \
  "core-tool preflight succeeds when all required core tools exist" \
  "3" \
  "$RC"

assert_not_contains \
  "all-present core-tool preflight does not report missing tool" \
  "$ERR" \
  "required tool is missing"

rm -f "$tool_preflight_bin/realpath"

run_capture env \
  PATH="$tool_preflight_bin" \
  TMPDIR="$tool_preflight_tmpdir" \
  bash "$AWS_DEMO_SH" status

assert_eq \
  "missing core tool exits 3 before lifecycle classification" \
  "3" \
  "$RC"

assert_contains \
  "missing core tool is named" \
  "$ERR" \
  "realpath"

# rm is required for runtime temp cleanup and is checked before temp creation.
ln -s "$(command -v realpath)" "$tool_preflight_bin/realpath"
rm -f "$tool_preflight_bin/rm"

run_capture env \
  PATH="$tool_preflight_bin" \
  TMPDIR="$tool_preflight_tmpdir" \
  bash "$AWS_DEMO_SH" status

assert_eq "missing rm exits 3 before lifecycle classification" "3" "$RC"
assert_contains "missing rm is named" "$ERR" "required tool is missing: rm"

# A failing cleanup must not replace the original exit status.
cat > "$tool_preflight_bin/rm" <<'FAKERM'
#!/usr/bin/env bash
printf 'rm: simulated cleanup failure\n' >&2
exit 1
FAKERM
chmod +x "$tool_preflight_bin/rm"

run_capture env \
  PATH="$tool_preflight_bin" \
  TMPDIR="$tool_preflight_tmpdir" \
  bash "$AWS_DEMO_SH" status

assert_eq "failing temp cleanup preserves original exit status" "3" "$RC"
# The simulated rm cannot delete; remove the expected leftover here.
find "$tool_preflight_tmpdir" -mindepth 1 -maxdepth 1 -type d -name 'aws-demo.*' -exec rmdir {} +
assert_not_contains "failing temp cleanup emits no lifecycle state" "$OUT" "STATE:"

assert_not_contains \
  "missing core tool emits no lifecycle state" \
  "$OUT$ERR" \
  "STATE:"

suite "aws-demo credential canary non-leak"

# Unmistakable canaries, syntactically valid for the script's validators.
declare -A H6_CANARY=(
  [bootstrap-access-key-id]="AKIACANARYBOOTSTRAP1"
  [bootstrap-secret-access-key]="CanaryBootstrapSecret0123456789ABCDEFGHI"
  [delivery-access-key-id]="ASIACANARYDELIVERY01"
  [delivery-secret-access-key]="CanaryDeliverySecret0123456789ABCDEFGHIJ"
  [delivery-session-token]="CanarySessionToken-FwoGZXIvYXdzE-h6-canary"
  [exec-credential-token]="k8s-aws-v1.H6CanaryExecCredentialToken"
)

h6_root="$TEST_TMP_ROOT/h6"
h6_bin="$TEST_TMP_ROOT/h6-bin"
mkdir -p "$h6_bin"

# Credential-aware fake: operator-side calls delegate to the credential
# fixture; bootstrap/delivery identities are recognised by the full canary
# credential tuple, so the canaries are genuinely used in memory.
cat > "$h6_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_AWS_LOG:?}"

if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  if [ "$1" = "iam" ] && [ "$2" = "list-access-keys" ]; then
    if [ "$(cat "${H6_STATE_FILE:?}")" = "created" ]; then
      printf '{"AccessKeyMetadata":[{"UserName":"omnivise-iot-jenkins-bootstrap","AccessKeyId":"%s","Status":"Active"}]}\n' \
        "$H6_BOOTSTRAP_ID"
    else
      printf '%s\n' '{"AccessKeyMetadata":[]}'
    fi
    exit 0
  fi

  if [ "$1" = "iam" ] && [ "$2" = "create-access-key" ]; then
    printf '%s\n' created > "${H6_STATE_FILE:?}"
    printf '{"AccessKey":{"UserName":"omnivise-iot-jenkins-bootstrap","AccessKeyId":"%s","Status":"Active","SecretAccessKey":"%s"}}\n' \
      "$H6_BOOTSTRAP_ID" "$H6_BOOTSTRAP_SECRET"
    exit 0
  fi

  exec "${BASE_FAKE_AWS:?}" "$@"
fi

if [ "${AWS_ACCESS_KEY_ID}" = "$H6_BOOTSTRAP_ID" ] &&
   [ "${AWS_SECRET_ACCESS_KEY:-}" = "$H6_BOOTSTRAP_SECRET" ] &&
   [ -z "${AWS_SESSION_TOKEN:-}" ]; then
  case "$1 $2" in
    "sts get-caller-identity")
      printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"}'
      exit 0
      ;;
    "eks describe-cluster")
      printf 'An error occurred (AccessDeniedException) when calling the DescribeCluster operation: denied\n' >&2
      exit 254
      ;;
    "sts assume-role")
      if [[ " $* " == *" arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery "* ]]; then
        printf '{"Credentials":{"AccessKeyId":"%s","SecretAccessKey":"%s","SessionToken":"%s","Expiration":"2099-01-01T00:00:00Z"}}\n' \
          "$H6_DELIVERY_ID" "$H6_DELIVERY_SECRET" "$H6_DELIVERY_TOKEN"
        exit 0
      fi
      printf 'An error occurred (AccessDenied) when calling the AssumeRole operation: denied\n' >&2
      exit 254
      ;;
  esac
fi

if [ "${AWS_ACCESS_KEY_ID}" = "$H6_DELIVERY_ID" ] &&
   [ "${AWS_SECRET_ACCESS_KEY:-}" = "$H6_DELIVERY_SECRET" ] &&
   [ "${AWS_SESSION_TOKEN:-}" = "$H6_DELIVERY_TOKEN" ]; then
  case "$1 $2" in
    "sts get-caller-identity")
      printf '%s\n' '{"Account":"554422868760","Arn":"arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/aws-demo-runtime"}'
      exit 0
      ;;
    "eks describe-cluster")
      printf '%s\n' '{"cluster":{"name":"omnivise-iot","arn":"arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot","status":"ACTIVE","endpoint":"https://example.eks.local","certificateAuthority":{"data":"RkFLRS1DQQ=="}}}'
      exit 0
      ;;
    "eks list-clusters")
      if [ "${H6_FAILURE:-}" = "list-clusters" ]; then
        printf 'Could not connect to the endpoint URL\n' >&2
        exit 255
      fi
      printf 'An error occurred (AccessDeniedException) when calling the ListClusters operation: denied\n' >&2
      exit 254
      ;;
    "iam list-users")
      printf 'An error occurred (AccessDenied) when calling the ListUsers operation: denied\n' >&2
      exit 254
      ;;
    "eks get-token")
      if [ "$*" = "eks get-token --region eu-north-1 --cluster-name omnivise-iot" ]; then
        printf '{"kind":"ExecCredential","apiVersion":"client.authentication.k8s.io/v1beta1","spec":{},"status":{"token":"%s"}}\n' \
          "${FAKE_EXEC_TOKEN:?}"
        exit 0
      fi
      ;;
  esac
fi

printf 'unexpected h6 fake aws call: %s\n' "$*" >&2
exit 99
FAKEAWS
chmod +x "$h6_bin/aws"

h6_reset() {
  rm -rf "$h6_root"
  mkdir -p "$h6_root/home" "$h6_root/tmp" "$h6_root/logs" "$h6_root/jenkins"
  mkdir -p "$h6_root/jenkins/secrets"
  h6_id_file="$h6_root/jenkins/secrets/omnivise_iot_aws_access_key_id"
  h6_secret_file="$h6_root/jenkins/secrets/omnivise_iot_aws_secret_access_key"
}

h6_run() {
  local command="$1"
  shift

  run_capture env \
    PATH="$h6_bin:$runtime_bin:$PATH" \
    HOME="$h6_root/home" \
    TMPDIR="$h6_root/tmp" \
    BASE_FAKE_AWS="$credential_bin/aws" \
    FAKE_AWS_LOG="$h6_root/logs/aws-argv.log" \
    FAKE_KUBECTL_LOG="$h6_root/logs/kubectl-argv.log" \
    FAKE_KUBECTL_ENV_LOG="$h6_root/logs/kubectl-env.log" \
    FAKE_JENKINS_STARTED_AT="2099-01-01T00:00:00Z" \
    H6_STATE_FILE="$h6_root/logs/key-state" \
    H6_BOOTSTRAP_ID="${H6_CANARY[bootstrap-access-key-id]}" \
    H6_BOOTSTRAP_SECRET="${H6_CANARY[bootstrap-secret-access-key]}" \
    H6_DELIVERY_ID="${H6_CANARY[delivery-access-key-id]}" \
    H6_DELIVERY_SECRET="${H6_CANARY[delivery-secret-access-key]}" \
    H6_DELIVERY_TOKEN="${H6_CANARY[delivery-session-token]}" \
    FAKE_EXEC_TOKEN="${H6_CANARY[exec-credential-token]}" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$h6_root/jenkins" \
    "$@" \
    bash "$AWS_DEMO_SH" "$command"
}

# Fails with the canary label only; never prints the value.
h6_assert_text_clean() {
  local name="$1" text="$2" label=""
  local leaked=""

  for label in "${!H6_CANARY[@]}"; do
    if [[ "$text" == *"${H6_CANARY[$label]}"* ]]; then
      leaked="$leaked $label"
    fi
  done

  if [ -z "$leaked" ]; then
    _pass "$name"
  else
    _fail "$name" "canary leaked:$leaked"
  fi
}

# Recursively scan the whole H6 root (HOME, TMPDIR, logs, local files).
# Bootstrap ID/secret may exist only in their designated files when
# allow_bootstrap=1. Delivery credentials may never persist anywhere.
h6_assert_filesystem_clean() {
  local name="$1" allow_bootstrap="$2"
  local label="" path="" offenders=""

  for label in "${!H6_CANARY[@]}"; do
    while IFS= read -r path; do
      [ -n "$path" ] || continue

      if [ "$allow_bootstrap" = "1" ]; then
        case "$label:$path" in
          "bootstrap-access-key-id:$h6_id_file"|"bootstrap-secret-access-key:$h6_secret_file")
            continue
            ;;
        esac
      fi

      offenders="$offenders [$label -> $path]"
    done < <(grep -rlF -e "${H6_CANARY[$label]}" -- "$h6_root" 2>/dev/null || true)
  done

  if [ -z "$offenders" ]; then
    _pass "$name"
  else
    _fail "$name" "unauthorized canary locations:$offenders"
  fi
}

h6_assert_run_clean() {
  local flow="$1" allow_bootstrap="$2"

  h6_assert_text_clean "$flow stdout carries no credential canary" "$OUT"
  h6_assert_text_clean "$flow stderr carries no credential canary" "$ERR"
  h6_assert_text_clean \
    "$flow AWS/kubectl argv logs carry no credential canary" \
    "$(cat "$h6_root"/logs/*.log 2>/dev/null)"
  h6_assert_filesystem_clean "$flow persists canaries only in designated files" "$allow_bootstrap"
  assert_eq "$flow leaves TMPDIR empty" "" "$(find "$h6_root/tmp" -mindepth 1 -print)"
  assert_eq "$flow leaves HOME untouched" "" "$(find "$h6_root/home" -mindepth 1 -print)"
}

# A: create / post-create flow.
h6_reset
printf '%s' OLD-ID > "$h6_id_file"
printf '%s' OLD-SECRET > "$h6_secret_file"
chmod 600 "$h6_id_file" "$h6_secret_file"
printf '%s\n' empty > "$h6_root/logs/key-state"

h6_run issue-credential FAKE_KEY_STATE=zero

assert_eq "H6 create flow completes post-create verification" "1" "$RC"
assert_contains "H6 create flow reaches restart-required" "$OUT" "STATE: UP-RESTART-REQUIRED"
assert_eq "H6 create writes bootstrap ID to designated file" "${H6_CANARY[bootstrap-access-key-id]}" "$(cat "$h6_id_file")"
if [ "$(cat "$h6_secret_file")" = "${H6_CANARY[bootstrap-secret-access-key]}" ]; then
  _pass "H6 create writes bootstrap secret to designated file"
else
  _fail "H6 create writes bootstrap secret to designated file" "designated secret file content mismatch"
fi
h6_assert_run_clean "H6 create flow" 1

# B: READY status runtime flow.
h6_reset
printf '%s' "${H6_CANARY[bootstrap-access-key-id]}" > "$h6_id_file"
printf '%s' "${H6_CANARY[bootstrap-secret-access-key]}" > "$h6_secret_file"
chmod 600 "$h6_id_file" "$h6_secret_file"
printf '%s\n' created > "$h6_root/logs/key-state"

h6_run status

assert_eq "H6 READY flow exits 0" "0" "$RC"
assert_contains "H6 READY flow reports READY" "$OUT" "STATE: READY"
assert_contains \
  "H6 READY flow ran the Kubernetes chain with delivery credentials" \
  "$(cat "$h6_root/logs/kubectl-argv.log")" \
  "auth can-i create deployments -n omnivise-iot"
assert_contains \
  "H6 READY flow exercised the kubeconfig exec plugin" \
  "$(cat "$h6_root/logs/aws-argv.log")" \
  "eks get-token --region eu-north-1 --cluster-name omnivise-iot"
h6_assert_run_clean "H6 READY flow" 1

# C1: generic AWS failure after delivery credentials are in memory.
h6_reset
printf '%s' "${H6_CANARY[bootstrap-access-key-id]}" > "$h6_id_file"
printf '%s' "${H6_CANARY[bootstrap-secret-access-key]}" > "$h6_secret_file"
chmod 600 "$h6_id_file" "$h6_secret_file"
printf '%s\n' created > "$h6_root/logs/key-state"

h6_run status H6_FAILURE=list-clusters

assert_eq "H6 AWS runtime failure exits 3" "3" "$RC"
h6_assert_run_clean "H6 AWS runtime failure" 1

# C2: Kubernetes failure after delivery credentials are in memory.
h6_reset
printf '%s' "${H6_CANARY[bootstrap-access-key-id]}" > "$h6_id_file"
printf '%s' "${H6_CANARY[bootstrap-secret-access-key]}" > "$h6_secret_file"
chmod 600 "$h6_id_file" "$h6_secret_file"
printf '%s\n' created > "$h6_root/logs/key-state"

h6_run status FAKE_KUBECTL_DEPLOYMENTS=error

assert_eq "H6 Kubernetes runtime failure exits 3" "3" "$RC"
h6_assert_run_clean "H6 Kubernetes runtime failure" 1

# Scanner self-check: a planted delivery token must be detected (no value printed).
h6_reset
printf '%s' "${H6_CANARY[delivery-session-token]}" > "$h6_root/tmp/planted"
h6_planted_offenders="$(
  grep -rlF -e "${H6_CANARY[delivery-session-token]}" -- "$h6_root" 2>/dev/null || true
)"
assert_eq "H6 scanner detects a planted session token" "$h6_root/tmp/planted" "$h6_planted_offenders"
rm -f "$h6_root/tmp/planted"

suite "aws-demo shell initialization"

assert_eq \
  "script enables inherit_errexit during initialization" \
  "1" \
  "$(sed -n '1,12p' "$AWS_DEMO_SH" | grep -cx 'shopt -s inherit_errexit')"
assert_eq \
  "script sets umask 077 during initialization" \
  "1" \
  "$(sed -n '1,12p' "$AWS_DEMO_SH" | grep -cx 'umask 077')"

umask_bin="$TEST_TMP_ROOT/umask-bin"
mkdir -p "$umask_bin"
umask_log="$TEST_TMP_ROOT/umask.log"
cat > "$umask_bin/aws" <<'FAKEAWS'
#!/usr/bin/env bash
umask >> "${FAKE_UMASK_LOG:?}"
exec "${FULL_DOWN_FAKE_AWS:?}" "$@"
FAKEAWS
chmod +x "$umask_bin/aws"

: > "$umask_log"
: > "$full_down_log"
# Positional arguments are expanded by the inner shell, not here.
# shellcheck disable=SC2016
run_capture bash -c '
  umask 022
  exec env \
    PATH="$1:$PATH" \
    FULL_DOWN_FAKE_AWS="$2" \
    FAKE_AWS_LOG="$3" \
    FAKE_UMASK_LOG="$4" \
    TMPDIR="$5" \
    bash "$6" status
' _ "$umask_bin" "$full_down_bin/aws" "$full_down_log" "$umask_log" "$temp_tmpdir" "$AWS_DEMO_SH"

assert_eq "umask-hardened DOWN status still exits 0" "0" "$RC"
assert_eq \
  "every AWS CLI child runs with umask 0077 despite an inherited 022" \
  "0077" \
  "$(sort -u "$umask_log")"

suite "aws-demo local Jenkins platform configuration"

# Canonical local-jenkins-platform layout (docker-compose.yml secrets):
#   <platform>/secrets/omnivise_iot_aws_access_key_id
#   <platform>/secrets/omnivise_iot_aws_secret_access_key
# Compose project local-jenkins-platform, service jenkins, no container_name
#   -> container local-jenkins-platform-jenkins-1
m7_root="$TEST_TMP_ROOT/m7"
m7_bin="$TEST_TMP_ROOT/m7-bin"
mkdir -p "$m7_bin"

cat > "$m7_bin/docker" <<'FAKEDOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_DOCKER_LOG:?}"
printf 'Error: No such object\n' >&2
exit 1
FAKEDOCKER
chmod +x "$m7_bin/docker"

m7_write_platform() {
  local platform="$1" key_id="$2"
  mkdir -p "$platform/secrets"
  printf '%s' "$key_id" > "$platform/secrets/omnivise_iot_aws_access_key_id"
  printf '%s' "0123456789abcdefghijklmnopqrstuvwxYZAB12" > "$platform/secrets/omnivise_iot_aws_secret_access_key"
  chmod 600 "$platform/secrets/omnivise_iot_aws_access_key_id" "$platform/secrets/omnivise_iot_aws_secret_access_key"
}

m7_run() {
  local script="$1" command="$2"
  shift 2
  : > "$m7_root/docker.log"
  : > "$m7_root/aws.log"
  run_capture env \
    -u OMNIVISE_JENKINS_PLATFORM_DIR -u OMNIVISE_JENKINS_CONTAINER \
    PATH="$m7_bin:$credential_bin:$PATH" \
    FAKE_AWS_LOG="$m7_root/aws.log" \
    FAKE_DOCKER_LOG="$m7_root/docker.log" \
    FAKE_KEY_STATE="one-active" \
    TMPDIR="$temp_tmpdir" \
    "$@" \
    bash "$script" "$command"
}

# A: default platform directory is ../local-jenkins-platform relative to the
# omnivise-iot repository root (sibling checkout), with fixed secret names.
rm -rf "$m7_root"
mkdir -p "$m7_root/workspace/omnivise-iot/scripts"
cp "$AWS_DEMO_SH" "$m7_root/workspace/omnivise-iot/scripts/aws-demo.sh"
m7_default_script="$m7_root/workspace/omnivise-iot/scripts/aws-demo.sh"
m7_write_platform "$m7_root/workspace/local-jenkins-platform" "AKIAEXAMPLE000000001"
reset_temp_tmpdir

m7_run "$m7_default_script" issue-credential
assert_eq "default platform layout: matching key is idempotent no-op" "0" "$RC"
assert_contains "default platform layout: no-op points to status" "$OUT" "NEXT: run scripts/aws-demo.sh status"

m7_write_platform "$m7_root/workspace/local-jenkins-platform" "AKIAEXAMPLE000000777"
m7_run "$m7_default_script" issue-credential
assert_eq "default platform layout: mismatched default ID file is VIOLATION" "2" "$RC"

# D: default container identity is the Compose container of the platform.
m7_write_platform "$m7_root/workspace/local-jenkins-platform" "AKIAEXAMPLE000000001"
m7_run "$m7_default_script" status
assert_eq "default container missing requires restart" "1" "$RC"
assert_contains \
  "default Jenkins container is local-jenkins-platform-jenkins-1" \
  "$(cat "$m7_root/docker.log")" \
  "local-jenkins-platform-jenkins-1"

m7_run "$m7_default_script" status OMNIVISE_JENKINS_CONTAINER=custom-jenkins
assert_contains \
  "OMNIVISE_JENKINS_CONTAINER overrides the container name" \
  "$(cat "$m7_root/docker.log")" \
  "custom-jenkins"
assert_not_contains \
  "container override replaces the default name" \
  "$(cat "$m7_root/docker.log")" \
  "local-jenkins-platform-jenkins-1"

# B: explicit OMNIVISE_JENKINS_PLATFORM_DIR; filenames stay fixed.
m7_write_platform "$m7_root/explicit-platform" "AKIAEXAMPLE000000001"
m7_run "$AWS_DEMO_SH" issue-credential OMNIVISE_JENKINS_PLATFORM_DIR="$m7_root/explicit-platform"
assert_eq "explicit platform dir: secrets derived beneath it" "0" "$RC"

mkdir -p "$m7_root/renamed-platform/secrets"
printf '%s' "AKIAEXAMPLE000000001" > "$m7_root/renamed-platform/secrets/aws_access_key_id"
chmod 600 "$m7_root/renamed-platform/secrets/aws_access_key_id"
m7_run "$AWS_DEMO_SH" issue-credential OMNIVISE_JENKINS_PLATFORM_DIR="$m7_root/renamed-platform"
assert_eq "explicit platform dir: non-canonical filenames are not accepted" "2" "$RC"
assert_contains "explicit platform dir: missing canonical ID file is reported" "$OUT" "file is missing"

# C: missing platform files fail closed and are never created.
m7_run "$AWS_DEMO_SH" issue-credential OMNIVISE_JENKINS_PLATFORM_DIR="$m7_root/absent-platform"
assert_eq "absent platform directory is VIOLATION" "2" "$RC"
assert_contains "absent platform directory points to local-jenkins-platform repair" "$OUT" "local-jenkins-platform"
if [ -e "$m7_root/absent-platform" ]; then
  _fail "absent platform directory is never created" "$m7_root/absent-platform was created"
else
  _pass "absent platform directory is never created"
fi

# E: legacy arbitrary-path variables are no longer a production bypass.
m7_write_platform "$m7_root/legacy-elsewhere" "AKIAEXAMPLE000000001"
m7_run "$AWS_DEMO_SH" issue-credential \
  OMNIVISE_JENKINS_PLATFORM_DIR="$m7_root/absent-platform" \
  AWS_DEMO_ACCESS_KEY_ID_FILE="$m7_root/legacy-elsewhere/secrets/omnivise_iot_aws_access_key_id" \
  AWS_DEMO_SECRET_ACCESS_KEY_FILE="$m7_root/legacy-elsewhere/secrets/omnivise_iot_aws_secret_access_key"
assert_eq "legacy AWS_DEMO_* secret paths are ignored" "2" "$RC"
assert_eq \
  "production script has no arbitrary secret-path or container variables" \
  "" \
  "$(grep -nE 'AWS_DEMO_(ACCESS_KEY_ID_FILE|SECRET_ACCESS_KEY_FILE|JENKINS_CONTAINER)' "$AWS_DEMO_SH" || true)"
assert_eq "M7 runs leave no temp artifacts" "" "$(temp_leftovers)"

suite "aws-demo explicit revoke recovery under drift"

m10_state="$TEST_TMP_ROOT/m10-key-state"
m10_platform="$TEST_TMP_ROOT/m10-platform"
mkdir -p "$m10_platform/secrets"

m10_run() {
  local command="$1"
  shift
  local -a env_overrides=()
  while [ "$#" -gt 0 ] && [[ "$1" == *=* ]]; do
    env_overrides+=("$1")
    shift
  done
  : > "$violation_log"
  run_capture env \
    PATH="$violation_bin:$PATH" \
    FAKE_AWS_LOG="$violation_log" \
    FAKE_VIOLATION_KEY_STATE_FILE="$m10_state" \
    HOME="$TEST_TMP_ROOT/up-violation-home" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$m10_platform" \
    "${env_overrides[@]}" \
    bash "$AWS_DEMO_SH" "$command" "$@"
}

# A/B/C/E: explicit recovery deletes exactly the selected key despite
# unrelated delivery/EKS drift or a non-ACTIVE cluster.
for m10_case in \
  "FAKE_DELIVERY_MANAGED_POLICY=1:delivery role managed-policy drift" \
  "FAKE_BAD_DELIVERY_TRUST=1:delivery trust drift" \
  "FAKE_BAD_ACCESS_SCOPE=1:EKS access policy scope drift" \
  "FAKE_DELIVERY_K8S_GROUP=1:EKS access entry drift" \
  "FAKE_BOOTSTRAP_MANAGED_POLICY=1:bootstrap permission drift" \
  "FAKE_CLUSTER_STATUS=UPDATING:non-ACTIVE cluster"
do
  m10_knob="${m10_case%%:*}"
  m10_label="${m10_case#*:}"

  printf '%s\n' one > "$m10_state"
  m10_run revoke-credential "$m10_knob" --key-id CDEF

  assert_eq "explicit revoke under $m10_label succeeds" "0" "$RC"
  assert_eq "explicit revoke under $m10_label deletes the selected key" "zero" "$(cat "$m10_state")"
  assert_eq \
    "explicit revoke under $m10_label deletes exactly one key" \
    "1" \
    "$(grep -c '^iam delete-access-key --user-name omnivise-iot-jenkins-bootstrap --access-key-id AKIA1234567890ABCDEF --output json$' "$violation_log")"
  assert_eq \
    "explicit revoke under $m10_label performs no other mutation" \
    "" \
    "$(grep -E '^iam (create|update|put|attach|detach|tag)|^eks (create|update|delete|associate|disassociate)' "$violation_log" || true)"
  assert_not_contains "explicit revoke under $m10_label claims no unproven state" "$OUT" "STATE:"
  assert_contains "explicit revoke under $m10_label points to status" "$OUT" "NEXT: rerun scripts/aws-demo.sh status"

  # Default revoke (no selector) stays strict under the same drift.
  printf '%s\n' one > "$m10_state"
  printf '%s' "AKIA1234567890ABCDEF" > "$m10_platform/secrets/omnivise_iot_aws_access_key_id"
  chmod 600 "$m10_platform/secrets/omnivise_iot_aws_access_key_id"
  m10_run revoke-credential "$m10_knob"
  assert_eq "default revoke under $m10_label stays blocked" "2" "$RC"
  assert_eq "default revoke under $m10_label deletes nothing" "one" "$(cat "$m10_state")"

  # F: issue-credential stays fail-closed under the same drift.
  printf '%s\n' zero > "$m10_state"
  m10_run issue-credential "$m10_knob"
  assert_eq "issue-credential under $m10_label is VIOLATION" "2" "$RC"
  assert_not_contains \
    "issue-credential under $m10_label never creates a key" \
    "$(cat "$violation_log")" \
    "create-access-key"
done

# D: bootstrap user identity drift blocks explicit revoke.
printf '%s\n' one > "$m10_state"
m10_run revoke-credential FAKE_BOOTSTRAP_ARN_DRIFT=1 --key-id CDEF
assert_eq "explicit revoke with bootstrap identity drift is VIOLATION" "2" "$RC"
assert_contains "bootstrap identity drift reports VIOLATION" "$OUT" "STATE: VIOLATION"
assert_eq "bootstrap identity drift deletes nothing" "one" "$(cat "$m10_state")"
assert_not_contains "bootstrap identity drift performs no delete" "$(cat "$violation_log")" "delete-access-key"

# Bootstrap user absent while the cluster exists: nothing provable to revoke.
printf '%s\n' one > "$m10_state"
m10_run revoke-credential FAKE_BOOTSTRAP_ABSENT=1 --key-id CDEF
assert_eq "explicit revoke with bootstrap user absent (cluster present) is VIOLATION" "2" "$RC"
assert_not_contains "bootstrap user absent performs no delete" "$(cat "$violation_log")" "delete-access-key"

# Selector still must resolve exactly one key on the bootstrap user.
printf '%s\n' one > "$m10_state"
m10_run revoke-credential FAKE_BAD_DELIVERY_TRUST=1 --key-id ZZZZ
assert_eq "explicit recovery with unmatched selector exits 3" "3" "$RC"
assert_eq "unmatched selector deletes nothing" "one" "$(cat "$m10_state")"

suite "aws-demo UP bootstrap user absence classification"

bua_state="$TEST_TMP_ROOT/bua-key-state"
printf '%s\n' zero > "$bua_state"

bua_run() {
  local command="$1"
  shift
  : > "$violation_log"
  run_capture env \
    PATH="$violation_bin:$PATH" \
    FAKE_AWS_LOG="$violation_log" \
    FAKE_VIOLATION_KEY_STATE_FILE="$bua_state" \
    HOME="$TEST_TMP_ROOT/up-violation-home" \
    OMNIVISE_JENKINS_PLATFORM_DIR="$TEST_TMP_ROOT/bua-platform" \
    "$@" \
    bash "$AWS_DEMO_SH" "$command"
}

bua_no_mutation() {
  local label="$1"
  assert_eq \
    "$label performs no IAM/EKS mutation" \
    "" \
    "$(grep -E '^iam (create|delete|update|put|attach|detach|tag)|^eks (create|update|delete|associate|disassociate)' "$violation_log" || true)"
}

# A: ACTIVE cluster + exact NoSuchEntity for the bootstrap user -> VIOLATION.
bua_run status FAKE_BOOTSTRAP_ABSENT=1
assert_eq "cluster present + bootstrap user NoSuchEntity is VIOLATION exit 2" "2" "$RC"
assert_contains "cluster present + bootstrap user absent reports VIOLATION" "$OUT" "STATE: VIOLATION"
assert_contains "cluster present + bootstrap user absent explains the missing user" "$OUT" "bootstrap IAM user is missing"
assert_contains "cluster present + bootstrap user absent points to Terraform recovery" "$OUT" "platform Terraform saved-plan workflow"
assert_not_contains "cluster present + bootstrap user absent is not an environment error" "$ERR" "ENVIRONMENT_ERROR"
bua_no_mutation "cluster present + bootstrap user absent"

bua_run issue-credential FAKE_BOOTSTRAP_ABSENT=1
assert_eq "issue-credential with bootstrap user absent (cluster present) is VIOLATION" "2" "$RC"
assert_not_contains "issue-credential with bootstrap user absent never creates a key" "$(cat "$violation_log")" "create-access-key"

# B: operational IAM failures stay exit 3 and never become drift.
for bua_err in access-denied throttling network; do
  bua_run status FAKE_BOOTSTRAP_GET_USER_ERROR="$bua_err"
  assert_eq "bootstrap get-user $bua_err stays exit 3" "3" "$RC"
  assert_contains "bootstrap get-user $bua_err is an environment error" "$ERR" "ENVIRONMENT_ERROR"
  assert_not_contains "bootstrap get-user $bua_err is never VIOLATION" "$OUT" "STATE: VIOLATION"
  bua_no_mutation "bootstrap get-user $bua_err"
done

# C: malformed successful get-user output stays exit 3.
for bua_bad in missing-user not-json; do
  bua_run status FAKE_BOOTSTRAP_GET_USER_MALFORMED="$bua_bad"
  assert_eq "malformed get-user response ($bua_bad) stays exit 3" "3" "$RC"
  assert_not_contains "malformed get-user response ($bua_bad) is never VIOLATION" "$OUT" "STATE: VIOLATION"
  assert_not_contains "malformed get-user response ($bua_bad) is never READY" "$OUT" "READY"
done

# Wrong but well-formed identity remains a VIOLATION (exact checks not weakened).
bua_run status FAKE_BOOTSTRAP_ARN_DRIFT=1
assert_eq "well-formed bootstrap user identity drift stays VIOLATION" "2" "$RC"

# D: cluster absent + bootstrap user absent keeps DOWN classification.
: > "$full_down_log"
run_capture env \
  PATH="$full_down_bin:$PATH" \
  FAKE_AWS_LOG="$full_down_log" \
  bash "$AWS_DEMO_SH" status
assert_eq "cluster absent + bootstrap user absent stays DOWN-CLEAN" "0" "$RC"
assert_contains "cluster absent + bootstrap user absent reports DOWN-CLEAN" "$OUT" "STATE: DOWN-CLEAN"
