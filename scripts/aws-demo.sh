#!/usr/bin/env bash
# The bootstrap/delivery probes deliberately mutate AWS credential variables
# only inside isolated ( ... ) subshells, so the ambient environment is never
# changed; SC2030/SC2031 report exactly that intended isolation.
# shellcheck disable=SC2030,SC2031

set -euo pipefail
shopt -s inherit_errexit
umask 077

usage() {
  cat >&2 <<'USAGE'
Usage:
  scripts/aws-demo.sh status
  scripts/aws-demo.sh issue-credential
  scripts/aws-demo.sh revoke-credential [--key-id <id-or-unique-suffix>]
USAGE
}

die_usage() {
  usage
  exit 3
}

die_environment() {
  printf 'ENVIRONMENT_ERROR: %s\n' "$1" >&2
  exit 3
}

# Print exactly one lifecycle STATE line plus optional DETAIL/NEXT lines.
# Anything outside the six lifecycle states is an internal error.
report_state() {
  local state="$1"
  local detail="${2:-}"
  local next="${3:-}"

  case "$state" in
    DOWN-CLEAN|DOWN-DIRTY|UP-NO-CREDENTIAL|UP-RESTART-REQUIRED|READY|VIOLATION)
      ;;
    *)
      die_environment "internal error: invalid lifecycle state"
      ;;
  esac

  printf 'STATE: %s\n' "$state"
  [ -z "$detail" ] || printf 'DETAIL: %s\n' "$detail"
  [ -z "$next" ] || printf 'NEXT: %s\n' "$next"
}

AWS_REGION_FIXED="eu-north-1"
AWS_ACCOUNT_ID="554422868760"
BOOTSTRAP_USER_ARN="arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
DELIVERY_ROLE_ARN="arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"

# local-jenkins-platform contract: docker-compose.yml mounts these fixed
# secret files; project local-jenkins-platform + service jenkins (no
# container_name) yields the container local-jenkins-platform-jenkins-1.
JENKINS_CONTAINER_DEFAULT="local-jenkins-platform-jenkins-1"
JENKINS_PLATFORM_DIR=""
JENKINS_CONTAINER=""
ACCESS_KEY_ID_FILE=""
SECRET_ACCESS_KEY_FILE=""

# Internal result of the post-create runtime chain: the freshly created
# bootstrap key is not yet recognised by AWS (IAM propagation). Never exits
# the script with this value.
RUNTIME_PROPAGATION_PENDING=4
POST_CREATE_RUNTIME_ATTEMPTS=10
POST_CREATE_RUNTIME_RETRY_SECONDS=3

NEXT_IDENTITY_DRIFT="restore the declared identity boundary through the platform Terraform saved-plan workflow (never by manual IAM/EKS edits), then rerun scripts/aws-demo.sh status"
NEXT_LOCAL_SECRET_FILES="repair the Jenkins AWS secret files through the local-jenkins-platform procedure (existing regular files, operator-owned, mode 0600); this tool never creates them"
NEXT_KEY_RECOVERY="identify the unexpected key with 'aws iam list-access-keys --user-name omnivise-iot-jenkins-bootstrap', run scripts/aws-demo.sh revoke-credential --key-id <suffix>, then issue-credential"

# Single AWS CLI entry point for aws_ro/aws_mutate. Responses are parsed with
# jq, so the output format is pinned here and never taken from the operator's
# AWS config or AWS_DEFAULT_OUTPUT; callers must not pass their own --output.
aws_cli() {
  local arg=""

  for arg in "$@"; do
    case "$arg" in
      --output|--output=*)
        die_environment "internal error: AWS output format is pinned by aws_cli"
        ;;
    esac
  done

  aws "$@" --output json
}

aws_ro() {
  local service="$1"
  local operation="$2"
  shift 2

  case "$service:$operation" in
    sts:get-caller-identity)
      aws_cli sts get-caller-identity --region "$AWS_REGION_FIXED" "$@"
      ;;
    sts:assume-role)
      # Non-persistent role assumption for the runtime chain only: the
      # delivery role, or the AdminAssumeRole negative probe.
      case "${1:-}:${2:-}" in
        "--role-arn:$DELIVERY_ROLE_ARN"|"--role-arn:arn:aws:iam::554422868760:role/AdminAssumeRole")
          ;;
        *)
          die_environment "disallowed STS role assumption"
          ;;
      esac
      aws_cli sts assume-role --region "$AWS_REGION_FIXED" "$@"
      ;;
    eks:list-clusters)
      aws_cli eks list-clusters --region "$AWS_REGION_FIXED" "$@"
      ;;
    iam:list-users)
      aws_cli iam list-users "$@"
      ;;
    eks:describe-cluster)
      aws_cli eks describe-cluster --region "$AWS_REGION_FIXED" "$@"
      ;;
    ec2:describe-vpcs)
      aws_cli ec2 describe-vpcs --region "$AWS_REGION_FIXED" "$@"
      ;;
    ec2:describe-subnets)
      aws_cli ec2 describe-subnets --region "$AWS_REGION_FIXED" "$@"
      ;;
    ec2:describe-internet-gateways)
      aws_cli ec2 describe-internet-gateways --region "$AWS_REGION_FIXED" "$@"
      ;;
    ec2:describe-route-tables)
      aws_cli ec2 describe-route-tables --region "$AWS_REGION_FIXED" "$@"
      ;;
    ec2:describe-volumes)
      aws_cli ec2 describe-volumes --region "$AWS_REGION_FIXED" "$@"
      ;;
    elbv2:describe-load-balancers)
      aws_cli elbv2 describe-load-balancers --region "$AWS_REGION_FIXED" "$@"
      ;;
    elbv2:describe-tags)
      aws_cli elbv2 describe-tags --region "$AWS_REGION_FIXED" "$@"
      ;;
    iam:get-user)
      aws_cli iam get-user "$@"
      ;;
    iam:list-groups-for-user)
      aws_cli iam list-groups-for-user "$@"
      ;;
    iam:list-attached-user-policies)
      aws_cli iam list-attached-user-policies "$@"
      ;;
    iam:list-user-policies)
      aws_cli iam list-user-policies "$@"
      ;;
    iam:get-user-policy)
      aws_cli iam get-user-policy "$@"
      ;;
    iam:list-access-keys)
      aws_cli iam list-access-keys "$@"
      ;;
    iam:get-role)
      aws_cli iam get-role "$@"
      ;;
    iam:get-policy)
      aws_cli iam get-policy "$@"
      ;;
    iam:list-attached-role-policies)
      aws_cli iam list-attached-role-policies "$@"
      ;;
    iam:list-role-policies)
      aws_cli iam list-role-policies "$@"
      ;;
    iam:get-role-policy)
      aws_cli iam get-role-policy "$@"
      ;;
    eks:describe-access-entry)
      aws_cli eks describe-access-entry --region "$AWS_REGION_FIXED" "$@"
      ;;
    eks:list-associated-access-policies)
      aws_cli eks list-associated-access-policies --region "$AWS_REGION_FIXED" "$@"
      ;;
    *)
      die_environment "disallowed read-only AWS call: $service $operation"
      ;;
  esac
}

check_operator_identity() {
  local response=""
  local account=""
  local arn=""

  if ! response="$(aws_ro sts get-caller-identity)"; then
    die_environment "unable to determine operator AWS identity"
  fi

  if ! command -v jq >/dev/null 2>&1; then
    die_environment "jq is required"
  fi

  if ! account="$(printf '%s' "$response" | jq -er '.Account')"; then
    die_environment "invalid sts:GetCallerIdentity response"
  fi

  if ! arn="$(printf '%s' "$response" | jq -er '.Arn')"; then
    die_environment "invalid sts:GetCallerIdentity response"
  fi

  [ "$account" = "$AWS_ACCOUNT_ID" ] ||     die_environment "operator AWS account must be $AWS_ACCOUNT_ID"

  case "$arn" in
    "$BOOTSTRAP_USER_ARN"|"$DELIVERY_ROLE_ARN"|arn:aws:sts::"$AWS_ACCOUNT_ID":assumed-role/omnivise-iot-jenkins-delivery/*)
      die_environment "operator caller must not be a Jenkins delivery identity"
      ;;
  esac

  # Only the declared operator principal: an AdminAssumeRole session with a
  # non-empty STS session name. Any other user, role, session or root fails.
  [[ "$arn" =~ ^arn:aws:sts::554422868760:assumed-role/AdminAssumeRole/[A-Za-z0-9+=,.@_-]+$ ]] ||
    die_environment "operator caller must be an AdminAssumeRole session (arn:aws:sts::$AWS_ACCOUNT_ID:assumed-role/AdminAssumeRole/<session>)"
}


aws_mutate() {
  local service="$1"
  local operation="$2"
  shift 2

  case "$service:$operation" in
    iam:create-access-key)
      [ "$#" -eq 0 ] || die_environment "invalid create-access-key mutation arguments"
      aws_cli iam create-access-key \
        --user-name omnivise-iot-jenkins-bootstrap
      ;;
    iam:delete-access-key)
      [ "$#" -eq 1 ] || die_environment "invalid delete-access-key mutation arguments"
      aws_cli iam delete-access-key \
        --user-name omnivise-iot-jenkins-bootstrap \
        --access-key-id "$1"
      ;;
    *)
      die_environment "disallowed AWS mutation: $service $operation"
      ;;
  esac
}

# A key was created but could not be safely recorded locally. Never rolls
# back. Only the last four characters of a trusted AccessKeyId are shown.
report_post_create_violation() {
  local detail="$1"
  local key_suffix="${2:-}"

  if [ -n "$key_suffix" ]; then
    report_state VIOLATION \
      "$detail; created bootstrap key suffix ****$key_suffix" \
      "run scripts/aws-demo.sh revoke-credential --key-id $key_suffix, then scripts/aws-demo.sh issue-credential"
  else
    report_state VIOLATION \
      "$detail; the created key could not be identified from the response" \
      "$NEXT_KEY_RECOVERY"
  fi
}

create_bootstrap_credential() {
  local id_file="$ACCESS_KEY_ID_FILE"
  local secret_file="$SECRET_ACCESS_KEY_FILE"
  local response=""
  local access_key_id=""
  local secret_access_key=""
  local user_name=""
  local key_status=""
  local list_response=""
  local attempt=0
  local runtime_attempt=0
  local runtime_rc=0
  local key_suffix=""

  [ -n "$id_file" ] || die_environment "AWS access key ID file path is not configured"
  [ -n "$secret_file" ] || die_environment "AWS secret access key file path is not configured"

  if ! response="$(aws_mutate iam create-access-key)"; then
    die_environment "IAM create-access-key failed"
  fi

  # The IAM key now exists. From here on every failure is a VIOLATION with
  # recovery guidance, never a rollback. Missing/invalid fields parse to "".
  user_name="$(printf '%s' "$response" | jq -r '.AccessKey.UserName | strings' 2>/dev/null)" || user_name=""
  access_key_id="$(printf '%s' "$response" | jq -r '.AccessKey.AccessKeyId | strings' 2>/dev/null)" || access_key_id=""
  key_status="$(printf '%s' "$response" | jq -r '.AccessKey.Status | strings' 2>/dev/null)" || key_status=""
  secret_access_key="$(printf '%s' "$response" | jq -r '.AccessKey.SecretAccessKey | strings' 2>/dev/null)" || secret_access_key=""
  unset response

  # Expose a masked recovery suffix only when the response reliably
  # identifies a key on the bootstrap user.
  if [ "$user_name" = "omnivise-iot-jenkins-bootstrap" ] &&
     [[ "$access_key_id" =~ ^[A-Z0-9]{20}$ ]]; then
    key_suffix="${access_key_id: -4}"
  fi

  if [ "$user_name" != "omnivise-iot-jenkins-bootstrap" ]; then
    unset access_key_id secret_access_key
    report_post_create_violation "create-access-key response does not identify the bootstrap IAM user" "$key_suffix"
    return 2
  fi

  if [[ ! "$access_key_id" =~ ^[A-Z0-9]{20}$ ]]; then
    unset access_key_id secret_access_key
    report_post_create_violation "create-access-key returned a malformed AccessKeyId" "$key_suffix"
    return 2
  fi

  if [ "$key_status" != "Active" ]; then
    unset access_key_id secret_access_key
    report_post_create_violation "create-access-key returned a non-Active key" "$key_suffix"
    return 2
  fi

  if [[ ! "$secret_access_key" =~ ^[A-Za-z0-9/+=]{40}$ ]]; then
    unset access_key_id secret_access_key
    report_post_create_violation "create-access-key returned a malformed SecretAccessKey" "$key_suffix"
    return 2
  fi

  # Preserve the existing files/inodes. Jenkins Compose secret mounts are
  # wired to these host files, so replacement/rename is deliberately avoided.
  # Secret first, then ID: a matching local ID implies the secret is current.
  if ! printf '%s' "$secret_access_key" > "$secret_file"; then
    unset access_key_id secret_access_key
    report_post_create_violation "unable to write the AWS secret access key file; the access-key ID file was not changed" "$key_suffix"
    return 2
  fi

  unset secret_access_key

  if ! printf '%s' "$access_key_id" > "$id_file"; then
    unset access_key_id
    report_post_create_violation "the secret file holds the new credential, but the access-key ID file could not be written" "$key_suffix"
    return 2
  fi


  # IAM can be eventually consistent. Bound the verification attempts and
  # require exactly the newly-created active key.
  for attempt in 1 2 3 4 5; do
    # The key exists and both files are written: a failed or malformed list
    # is a post-create VIOLATION with recovery guidance, never a generic
    # environment exit and never a rollback. The written files are kept.
    if ! list_response="$(aws_ro iam list-access-keys \
        --user-name omnivise-iot-jenkins-bootstrap)"; then
      unset access_key_id user_name key_status list_response
      report_post_create_violation "the credential files were written, but IAM list-access-keys failed while verifying the created key" "$key_suffix"
      return 2
    fi

    # Malformed list output is not propagation delay.
    if ! printf '%s' "$list_response" | jq -e '
        type == "object" and (.AccessKeyMetadata | type) == "array"
      ' >/dev/null 2>&1; then
      unset access_key_id user_name key_status list_response
      report_post_create_violation "the credential files were written, but IAM list-access-keys returned a missing or non-array AccessKeyMetadata" "$key_suffix"
      return 2
    fi

    if printf '%s' "$list_response" | jq -e \
        --arg key_id "$access_key_id" '
          .AccessKeyMetadata | length == 1
          and .[0].UserName == "omnivise-iot-jenkins-bootstrap"
          and .[0].AccessKeyId == $key_id
          and .[0].Status == "Active"
        ' >/dev/null 2>&1; then
      unset access_key_id user_name key_status list_response

      # Bounded retry only for IAM propagation of the new key. The chains run
      # in a subshell so an operational exit 3 is caught here: a classified
      # VIOLATION (2) passes through unchanged, anything else becomes a
      # post-create VIOLATION with recovery guidance. No rollback.
      for (( runtime_attempt = 1; runtime_attempt <= POST_CREATE_RUNTIME_ATTEMPTS; runtime_attempt++ )); do
        if ( verify_aws_runtime_chain post-create ); then
          runtime_rc=0
          break
        else
          runtime_rc=$?
        fi

        [ "$runtime_rc" -ne 2 ] || return 2

        if [ "$runtime_rc" -ne "$RUNTIME_PROPAGATION_PENDING" ]; then
          report_post_create_violation "the credential files were written, but the AWS runtime verification of the created key failed unexpectedly" "$key_suffix"
          return 2
        fi

        if [ "$runtime_attempt" -lt "$POST_CREATE_RUNTIME_ATTEMPTS" ]; then
          sleep "$POST_CREATE_RUNTIME_RETRY_SECONDS"
        fi
      done

      if [ "$runtime_rc" -ne 0 ]; then
        printf 'DETAIL: credential was created and written, but AWS does not accept the new bootstrap key yet (IAM propagation)\n'
        printf 'NEXT: rerun scripts/aws-demo.sh status\n'
        return 1
      fi

      if ( verify_kubernetes_runtime_chain ); then
        runtime_rc=0
      else
        runtime_rc=$?
      fi

      [ "$runtime_rc" -ne 2 ] || return 2

      if [ "$runtime_rc" -ne 0 ]; then
        report_post_create_violation "the credential files were written, but the Kubernetes runtime verification of the created key failed unexpectedly" "$key_suffix"
        return 2
      fi

      printf 'STATE: UP-RESTART-REQUIRED\n'
      printf 'NEXT: restart Jenkins so it re-reads the updated AWS secret files\n'
      return 1
    fi

    if [ "$attempt" -lt 5 ]; then
      sleep 1
    fi
  done

  unset access_key_id user_name key_status list_response

  # The runtime chain has not run, so no lifecycle state is proven yet.
  printf 'DETAIL: credential was created and written, but the IAM key list has not converged yet\n'
  printf 'NEXT: rerun scripts/aws-demo.sh status\n'
  return 1
}

aws_absence_probe() {
  local service="$1"
  local operation="$2"
  shift 2

  local err_file
  local response=""
  local rc=0
  local err=""

  if ! err_file="$(mktemp "${AWS_DEMO_TMP:?}/absence.XXXXXX")"; then
    die_environment "unable to create temporary absence probe file"
  fi

  if response="$(aws_ro "$service" "$operation" "$@" 2>"$err_file")"; then
    rm -f "$err_file"
    printf '%s' "$response"
    return 0
  else
    rc=$?
  fi

  err="$(cat "$err_file")"
  rm -f "$err_file"

  case "$service:$operation" in
    iam:get-user|iam:get-role|iam:get-policy)
      if [[ "$err" == *"(NoSuchEntity)"* ]]; then
        return 1
      fi
      ;;
  esac

  printf 'ENVIRONMENT_ERROR: %s %s failed: %s\n' "$service" "$operation" "$err" >&2
  return 3
}

classify_down_state() {
  local dirty=0
  local response=""
  local rc=0
  local alb_arn=""
  local alb_arns=""
  local tags=""
  local attributable=""
  local count=0
  local role_name=""

  if ! response="$(aws_ro ec2 describe-vpcs \
      --filters \
        "Name=tag:Project,Values=omnivise-iot" \
        "Name=tag:Environment,Values=aws" \
        "Name=tag:ManagedBy,Values=terraform")"; then
    die_environment "unable to scan OmniVise VPC leftovers"
  fi

  count="$(json_array_length "$response" Vpcs)" || exit 3
  [ "$count" -eq 0 ] || dirty=1

  if ! response="$(aws_ro ec2 describe-subnets \
      --filters \
        "Name=tag:Project,Values=omnivise-iot" \
        "Name=tag:Environment,Values=aws" \
        "Name=tag:ManagedBy,Values=terraform")"; then
    die_environment "unable to scan OmniVise subnet leftovers"
  fi

  count="$(json_array_length "$response" Subnets)" || exit 3
  [ "$count" -eq 0 ] || dirty=1

  if ! response="$(aws_ro ec2 describe-internet-gateways \
      --filters \
        "Name=tag:Project,Values=omnivise-iot" \
        "Name=tag:Environment,Values=aws" \
        "Name=tag:ManagedBy,Values=terraform")"; then
    die_environment "unable to scan OmniVise Internet Gateway leftovers"
  fi

  count="$(json_array_length "$response" InternetGateways)" || exit 3
  [ "$count" -eq 0 ] || dirty=1

  if ! response="$(aws_ro ec2 describe-route-tables \
      --filters \
        "Name=tag:Project,Values=omnivise-iot" \
        "Name=tag:Environment,Values=aws" \
        "Name=tag:ManagedBy,Values=terraform")"; then
    die_environment "unable to scan OmniVise route table leftovers"
  fi

  count="$(json_array_length "$response" RouteTables)" || exit 3
  [ "$count" -eq 0 ] || dirty=1

  if ! response="$(aws_ro ec2 describe-volumes \
      --filters "Name=tag:ebs.csi.aws.com/cluster-name,Values=omnivise-iot")"; then
    die_environment "unable to scan OmniVise EBS leftovers"
  fi

  count="$(json_array_length "$response" Volumes)" || exit 3
  [ "$count" -eq 0 ] || dirty=1

  if ! response="$(aws_ro elbv2 describe-load-balancers)"; then
    die_environment "unable to scan load balancers"
  fi

  count="$(json_array_length "$response" LoadBalancers)" || exit 3

  if [ "$count" -gt 0 ]; then
    if ! alb_arns="$(printf '%s' "$response" | jq -r '
        .LoadBalancers[]
        | .LoadBalancerArn
        | if type == "string" and length > 0 then . else error("invalid ARN") end
      ' 2>/dev/null)"; then
      die_environment "invalid load balancer ARN in describe-load-balancers response"
    fi

    while IFS= read -r alb_arn; do
      if ! tags="$(aws_ro elbv2 describe-tags \
          --resource-arns "$alb_arn")"; then
        die_environment "unable to inspect load balancer tags"
      fi

      count="$(json_array_length "$tags" TagDescriptions)" || exit 3

      # Malformed tag data must not be read as "not attributable".
      if ! attributable="$(printf '%s' "$tags" | jq -r '
          [
            .TagDescriptions[]
            | .Tags
            | if type == "array" then .[] else error("missing Tags array") end
          ]
          | any(.Key == "elbv2.k8s.aws/cluster" and .Value == "omnivise-iot")
        ' 2>/dev/null)"; then
        die_environment "invalid describe-tags response"
      fi

      [ "$attributable" != "true" ] || dirty=1
    done <<< "$alb_arns"
  fi

  if aws_absence_probe iam get-user \
      --user-name omnivise-iot-jenkins-bootstrap >/dev/null; then
    dirty=1
  else
    rc=$?
    [ "$rc" -eq 1 ] || return "$rc"
  fi

  if aws_absence_probe iam get-policy \
      --policy-arn arn:aws:iam::554422868760:policy/omnivise-iot-aws-aws-load-balancer-controller \
      >/dev/null; then
    dirty=1
  else
    rc=$?
    [ "$rc" -eq 1 ] || return "$rc"
  fi

  for role_name in \
    omnivise-iot-jenkins-delivery \
    omnivise-iot-aws-eks-cluster \
    omnivise-iot-aws-eks-node \
    omnivise-iot-aws-ebs-csi \
    omnivise-iot-aws-aws-load-balancer-controller
  do
    if aws_absence_probe iam get-role \
        --role-name "$role_name" >/dev/null; then
      dirty=1
    else
      rc=$?
      [ "$rc" -eq 1 ] || return "$rc"
    fi
  done

  if [ "$dirty" -eq 0 ]; then
    printf 'STATE: DOWN-CLEAN\n'
    printf 'NEXT: bring up the AWS platform from the documented saved-plan workflow\n'
    return 0
  fi

  printf 'STATE: DOWN-DIRTY\n'
  printf 'NEXT: inspect and remove remaining OmniVise AWS resources before bring-up\n'
  return 1
}

probe_eks_access_entry() {
  local principal_arn="$1"
  local err_file
  local response=""
  local rc=0
  local err=""

  if ! err_file="$(mktemp "${AWS_DEMO_TMP:?}/access-entry.XXXXXX")"; then
    die_environment "unable to create temporary access entry probe file"
  fi

  if response="$(aws_ro eks describe-access-entry \
      --cluster-name omnivise-iot \
      --principal-arn "$principal_arn" \
      2>"$err_file")"; then
    rm -f "$err_file"
    printf '%s' "$response"
    return 0
  else
    rc=$?
  fi

  err="$(cat "$err_file")"
  rm -f "$err_file"

  if [[ "$err" == *"(ResourceNotFoundException)"* ]]; then
    return 1
  fi

  printf 'ENVIRONMENT_ERROR: eks DescribeAccessEntry failed: %s\n' "$err" >&2
  return 3
}

require_aws_json() {
  local description="$1"
  shift

  local response=""

  if ! response="$(aws_ro "$@")"; then
    die_environment "unable to verify $description"
  fi

  printf '%s' "$response"
}

# Print the length of a required top-level array field. Malformed JSON, a
# missing key, null, or any non-array value is an operational error: it must
# never be interpreted as "no resources" or "zero keys".
json_array_length() {
  local json="$1"
  local key="$2"
  local length=""

  if ! length="$(printf '%s' "$json" | jq -er --arg key "$key" '
      if type == "object" and (.[$key] | type) == "array"
      then .[$key] | length
      else error("missing or non-array field")
      end
    ' 2>/dev/null)"; then
    die_environment "AWS response field $key is missing or not an array"
  fi

  printf '%s' "$length"
}

validate_secret_file() {
  local path="$1"
  local label="$2"
  local owner_uid=""
  local mode=""

  if [ ! -e "$path" ]; then
    report_state VIOLATION \
      "required $label file is missing" \
      "$NEXT_LOCAL_SECRET_FILES"
    return 2
  fi

  if [ -L "$path" ]; then
    report_state VIOLATION \
      "required $label path must not be a symbolic link" \
      "$NEXT_LOCAL_SECRET_FILES"
    return 2
  fi

  if [ ! -f "$path" ]; then
    report_state VIOLATION \
      "required $label path is not a regular file" \
      "$NEXT_LOCAL_SECRET_FILES"
    return 2
  fi

  if ! owner_uid="$(stat -c '%u' "$path")"; then
    die_environment "unable to inspect $label owner"
  fi

  if [ "$owner_uid" != "$(id -u)" ]; then
    report_state VIOLATION \
      "required $label file is not owned by the current operator" \
      "$NEXT_LOCAL_SECRET_FILES"
    return 2
  fi

  if ! mode="$(stat -c '%a' "$path")"; then
    die_environment "unable to inspect $label mode"
  fi

  if [ "$mode" != "600" ]; then
    report_state VIOLATION \
      "required $label file mode must be 0600" \
      "$NEXT_LOCAL_SECRET_FILES"
    return 2
  fi

  return 0
}

validate_mount_source() {
  local mounts_json="$1"
  local destination="$2"
  local expected_file="$3"
  local label="$4"
  local source=""
  local expected_real=""
  local source_real=""
  local expected_identity=""
  local source_identity=""

  if ! source="$(printf '%s' "$mounts_json" | jq -er \
      --arg destination "$destination" \
      '[.[] | select(.Destination == $destination)] | if length == 1 then .[0].Source else empty end')"; then
    printf 'STATE: VIOLATION\n'
    printf 'DETAIL: Jenkins %s mount is missing or ambiguous\n' "$label"
    return 2
  fi

  if ! expected_real="$(realpath "$expected_file")"; then
    die_environment "unable to canonicalize expected $label file"
  fi

  if ! source_real="$(realpath "$source" 2>/dev/null)"; then
    printf 'STATE: VIOLATION\n'
    printf 'DETAIL: Jenkins %s mount source does not resolve to an existing host file\n' "$label"
    return 2
  fi

  if [ "$source_real" != "$expected_real" ]; then
    printf 'STATE: VIOLATION\n'
    printf 'DETAIL: Jenkins %s mount source does not match the expected host file\n' "$label"
    return 2
  fi

  if ! expected_identity="$(stat -Lc '%d:%i' "$expected_file")"; then
    die_environment "unable to inspect expected $label file identity"
  fi

  if ! source_identity="$(stat -Lc '%d:%i' "$source")"; then
    die_environment "unable to inspect Jenkins $label mount source identity"
  fi

  if [ "$source_identity" != "$expected_identity" ]; then
    printf 'STATE: VIOLATION\n'
    printf 'DETAIL: Jenkins %s mount source filesystem identity mismatch\n' "$label"
    return 2
  fi

  return 0
}

precreate_local_gate() {
  local id_file="$ACCESS_KEY_ID_FILE"
  local secret_file="$SECRET_ACCESS_KEY_FILE"
  local container="$JENKINS_CONTAINER"
  local running=""
  local mounts_json=""

  if [ -z "$id_file" ] || [ -z "$secret_file" ]; then
    die_environment "local Jenkins AWS secret file paths are not configured"
  fi

  validate_secret_file "$id_file" "AWS access key ID" || return $?

  validate_secret_file "$secret_file" "AWS secret access key" || return $?

  if ! command -v docker >/dev/null 2>&1; then
    die_environment "docker is required"
  fi

  if running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)"; then
    :
  else
    printf 'STATE: VIOLATION\n'
    printf 'DETAIL: Jenkins container does not exist\n'
    return 2
  fi

  if [ "$running" != "true" ]; then
    printf 'STATE: VIOLATION\n'
    printf 'DETAIL: Jenkins container must be running before credential issuance\n'
    return 2
  fi

  if ! mounts_json="$(docker inspect --format '{{json .Mounts}}' "$container")"; then
    die_environment "unable to inspect Jenkins mounts"
  fi

  validate_mount_source \
    "$mounts_json" \
    "/run/secrets/omnivise_iot_aws_access_key_id" \
    "$id_file" \
    "AWS access key ID" || return $?

  validate_mount_source \
    "$mounts_json" \
    "/run/secrets/omnivise_iot_aws_secret_access_key" \
    "$secret_file" \
    "AWS secret access key" || return $?

  return 0
}

expect_aws_authorization_denial() {
  local description="$1"
  local expected_code="$2"
  shift 2

  local err_file=""
  local err=""
  local rc=0

  if ! err_file="$(mktemp "${AWS_DEMO_TMP:?}/denial.XXXXXX")"; then
    die_environment "unable to create temporary AWS denial probe file"
  fi

  if "$@" >/dev/null 2>"$err_file"; then
    rm -f "$err_file"
    # A permitted call that must be denied is an authorization-boundary
    # violation, not an operational failure. Callers run in a subshell.
    report_state VIOLATION \
      "$description unexpectedly succeeded; authorization is broader than declared" \
      "$NEXT_IDENTITY_DRIFT"
    exit 2
  else
    rc=$?
  fi

  err="$(cat "$err_file")"
  rm -f "$err_file"

  if [[ "$err" != *"(${expected_code})"* ]]; then
    die_environment "$description failed, but not with the expected authorization denial"
  fi

  return 0
}

verify_aws_runtime_chain() {
  local runtime_mode="${1:-status}"
  local id_file="$ACCESS_KEY_ID_FILE"
  local secret_file="$SECRET_ACCESS_KEY_FILE"
  local bootstrap_access_key_id=""
  local bootstrap_secret_access_key=""

  if ! IFS= read -r bootstrap_access_key_id < "$id_file" &&
     [ -z "$bootstrap_access_key_id" ]; then
    die_environment "unable to read bootstrap AWS access key ID"
  fi

  if ! IFS= read -r bootstrap_secret_access_key < "$secret_file" &&
     [ -z "$bootstrap_secret_access_key" ]; then
    die_environment "unable to read bootstrap AWS secret access key"
  fi

  (
    local caller=""
    local caller_arn=""
    local assume_response=""
    local delivery_access_key_id=""
    local delivery_secret_access_key=""
    local delivery_session_token=""
    local cluster_response=""

    unset \
      AWS_SESSION_TOKEN \
      AWS_SECURITY_TOKEN \
      AWS_PROFILE \
      AWS_DEFAULT_PROFILE \
      AWS_ROLE_ARN \
      AWS_WEB_IDENTITY_TOKEN_FILE \
      AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
      AWS_CONTAINER_CREDENTIALS_FULL_URI \
      AWS_CONTAINER_AUTHORIZATION_TOKEN \
      AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE

    export AWS_REGION="$AWS_REGION_FIXED"
    export AWS_DEFAULT_REGION="$AWS_REGION_FIXED"
    export AWS_CONFIG_FILE=/dev/null
    export AWS_SHARED_CREDENTIALS_FILE=/dev/null
    export AWS_EC2_METADATA_DISABLED=true
    export AWS_PAGER=""
    export AWS_CLI_AUTO_PROMPT=off

    export AWS_ACCESS_KEY_ID="$bootstrap_access_key_id"
    export AWS_SECRET_ACCESS_KEY="$bootstrap_secret_access_key"
    unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN

    local caller_err_file=""
    local caller_err=""

    if ! caller_err_file="$(mktemp "${AWS_DEMO_TMP:?}/caller.XXXXXX")"; then
      die_environment "unable to create temporary bootstrap identity probe file"
    fi

    if caller="$(aws_ro sts get-caller-identity 2>"$caller_err_file")"; then
      rm -f "$caller_err_file"
    else
      caller_err="$(cat "$caller_err_file")"
      rm -f "$caller_err_file"

      # Only a just-created key may be "not yet known" to AWS. Every other
      # failure, including this one during normal status, is operational.
      if [ "$runtime_mode" = "post-create" ] &&
         [[ "$caller_err" == *"(InvalidClientTokenId)"* ]]; then
        exit "$RUNTIME_PROPAGATION_PENDING"
      fi

      printf '%s\n' "$caller_err" >&2
      die_environment "unable to verify bootstrap runtime caller identity"
    fi

    if ! caller_arn="$(printf '%s' "$caller" | jq -er '.Arn | strings' 2>/dev/null)"; then
      die_environment "invalid bootstrap runtime caller identity response"
    fi

    if [ "$caller_arn" != "$BOOTSTRAP_USER_ARN" ]; then
      report_state VIOLATION \
        "local bootstrap credential does not authenticate as the bootstrap IAM user" \
        "$NEXT_KEY_RECOVERY"
      exit 2
    fi

    expect_aws_authorization_denial \
      "bootstrap direct DescribeCluster probe" \
      "AccessDeniedException" \
      aws_ro eks describe-cluster \
        --name omnivise-iot

    expect_aws_authorization_denial \
      "bootstrap AdminAssumeRole probe" \
      "AccessDenied" \
      aws_ro sts assume-role \
        --role-arn "arn:aws:iam::554422868760:role/AdminAssumeRole" \
        --role-session-name aws-demo-runtime-admin

    if ! assume_response="$(aws_ro sts assume-role \
        --role-arn "$DELIVERY_ROLE_ARN" \
        --role-session-name aws-demo-runtime)"; then
      die_environment "bootstrap could not assume Jenkins delivery role"
    fi

    if ! delivery_access_key_id="$(
      printf '%s' "$assume_response" | jq -er '.Credentials.AccessKeyId'
    )"; then
      die_environment "delivery AssumeRole response missing AccessKeyId"
    fi

    if ! delivery_secret_access_key="$(
      printf '%s' "$assume_response" | jq -er '.Credentials.SecretAccessKey'
    )"; then
      die_environment "delivery AssumeRole response missing SecretAccessKey"
    fi

    if ! delivery_session_token="$(
      printf '%s' "$assume_response" | jq -er '.Credentials.SessionToken'
    )"; then
      die_environment "delivery AssumeRole response missing SessionToken"
    fi

    export AWS_ACCESS_KEY_ID="$delivery_access_key_id"
    export AWS_SECRET_ACCESS_KEY="$delivery_secret_access_key"
    export AWS_SESSION_TOKEN="$delivery_session_token"
    unset AWS_SECURITY_TOKEN

    if ! caller="$(aws_ro sts get-caller-identity)"; then
      die_environment "unable to verify delivery runtime caller identity"
    fi

    if ! caller_arn="$(printf '%s' "$caller" | jq -er '.Arn | strings' 2>/dev/null)"; then
      die_environment "invalid delivery runtime caller identity response"
    fi

    if [[ ! "$caller_arn" =~ ^arn:aws:sts::554422868760:assumed-role/omnivise-iot-jenkins-delivery/[^/]+$ ]]; then
      report_state VIOLATION \
        "assumed delivery session is not the omnivise-iot-jenkins-delivery role" \
        "$NEXT_IDENTITY_DRIFT"
      exit 2
    fi

    if ! cluster_response="$(aws_ro eks describe-cluster \
        --name omnivise-iot)"; then
      die_environment "delivery role cannot DescribeCluster target"
    fi

    if ! printf '%s' "$cluster_response" | jq -e '
        .cluster.name == "omnivise-iot"
        and .cluster.arn == "arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
        and .cluster.status == "ACTIVE"
      ' >/dev/null 2>&1; then
      die_environment "delivery DescribeCluster returned unexpected target"
    fi

    expect_aws_authorization_denial \
      "delivery ListClusters probe" \
      "AccessDeniedException" \
      aws_ro eks list-clusters

    expect_aws_authorization_denial \
      "delivery IAM ListUsers probe" \
      "AccessDenied" \
      aws_ro iam list-users

    unset \
      caller \
      assume_response \
      cluster_response \
      delivery_access_key_id \
      delivery_secret_access_key \
      delivery_session_token \
      AWS_ACCESS_KEY_ID \
      AWS_SECRET_ACCESS_KEY \
      AWS_SESSION_TOKEN

    return 0
  )

  local rc=$?

  unset bootstrap_access_key_id bootstrap_secret_access_key

  return "$rc"
}

verify_kubernetes_runtime_chain() {
  local id_file="$ACCESS_KEY_ID_FILE"
  local secret_file="$SECRET_ACCESS_KEY_FILE"
  local bootstrap_access_key_id=""
  local bootstrap_secret_access_key=""

  if ! command -v kubectl >/dev/null 2>&1; then
    die_environment "kubectl is required"
  fi

  if ! IFS= read -r bootstrap_access_key_id < "$id_file" &&
     [ -z "$bootstrap_access_key_id" ]; then
    die_environment "unable to read bootstrap AWS access key ID"
  fi

  if ! IFS= read -r bootstrap_secret_access_key < "$secret_file" &&
     [ -z "$bootstrap_secret_access_key" ]; then
    die_environment "unable to read bootstrap AWS secret access key"
  fi

  (
    local assume_response=""
    local delivery_access_key_id=""
    local delivery_secret_access_key=""
    local delivery_session_token=""
    local cluster_response=""
    local endpoint=""
    local ca_data=""
    local kube_tmp=""
    local kubeconfig=""
    local kube_cache=""
    local probe_output=""
    local probe_rc=0

    # shellcheck disable=SC2329  # invoked via the EXIT trap below
    cleanup_kube_runtime() {
      if [ -n "$kube_tmp" ] && [ -d "$kube_tmp" ]; then
        rm -rf -- "$kube_tmp"
      fi
    }

    # Early cleanup on normal subshell exit. Signal cleanup is owned by the
    # main-shell trap, which removes the whole runtime root.
    trap cleanup_kube_runtime EXIT

    unset \
      AWS_SESSION_TOKEN \
      AWS_SECURITY_TOKEN \
      AWS_PROFILE \
      AWS_DEFAULT_PROFILE \
      AWS_ROLE_ARN \
      AWS_WEB_IDENTITY_TOKEN_FILE \
      AWS_CONTAINER_CREDENTIALS_RELATIVE_URI \
      AWS_CONTAINER_CREDENTIALS_FULL_URI \
      AWS_CONTAINER_AUTHORIZATION_TOKEN \
      AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE

    export AWS_REGION="$AWS_REGION_FIXED"
    export AWS_DEFAULT_REGION="$AWS_REGION_FIXED"
    export AWS_CONFIG_FILE=/dev/null
    export AWS_SHARED_CREDENTIALS_FILE=/dev/null
    export AWS_EC2_METADATA_DISABLED=true
    export AWS_PAGER=""
    export AWS_CLI_AUTO_PROMPT=off

    export AWS_ACCESS_KEY_ID="$bootstrap_access_key_id"
    export AWS_SECRET_ACCESS_KEY="$bootstrap_secret_access_key"
    unset AWS_SESSION_TOKEN AWS_SECURITY_TOKEN

    if ! assume_response="$(aws_ro sts assume-role \
        --role-arn "$DELIVERY_ROLE_ARN" \
        --role-session-name aws-demo-kubernetes-runtime)"; then
      die_environment "bootstrap could not assume delivery role for Kubernetes probe"
    fi

    if ! delivery_access_key_id="$(
      printf '%s' "$assume_response" | jq -er '.Credentials.AccessKeyId'
    )"; then
      die_environment "Kubernetes delivery AssumeRole response missing AccessKeyId"
    fi

    if ! delivery_secret_access_key="$(
      printf '%s' "$assume_response" | jq -er '.Credentials.SecretAccessKey'
    )"; then
      die_environment "Kubernetes delivery AssumeRole response missing SecretAccessKey"
    fi

    if ! delivery_session_token="$(
      printf '%s' "$assume_response" | jq -er '.Credentials.SessionToken'
    )"; then
      die_environment "Kubernetes delivery AssumeRole response missing SessionToken"
    fi

    export AWS_ACCESS_KEY_ID="$delivery_access_key_id"
    export AWS_SECRET_ACCESS_KEY="$delivery_secret_access_key"
    export AWS_SESSION_TOKEN="$delivery_session_token"

    if ! cluster_response="$(aws_ro eks describe-cluster \
        --name omnivise-iot)"; then
      die_environment "unable to read EKS endpoint for Kubernetes runtime probe"
    fi

    if ! endpoint="$(printf '%s' "$cluster_response" | jq -er '.cluster.endpoint')"; then
      die_environment "EKS DescribeCluster response missing endpoint"
    fi

    if ! ca_data="$(
      printf '%s' "$cluster_response" |
        jq -er '.cluster.certificateAuthority.data'
    )"; then
      die_environment "EKS DescribeCluster response missing certificate authority data"
    fi

    if ! kube_tmp="$(mktemp -d "${AWS_DEMO_TMP:?}/kube.XXXXXX")"; then
      die_environment "unable to create temporary kubeconfig directory"
    fi

    kubeconfig="$kube_tmp/config"
    # Contract: kubectl discovery/http cache stays below the temp directory.
    kube_cache="$kube_tmp/cache"

    if ! mkdir -- "$kube_cache"; then
      die_environment "unable to create temporary Kubernetes cache directory"
    fi

    umask 077
    if ! cat > "$kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: omnivise-iot
  cluster:
    server: $endpoint
    certificate-authority-data: $ca_data
contexts:
- name: omnivise-iot
  context:
    cluster: omnivise-iot
    user: aws-demo-delivery
    namespace: omnivise-iot
current-context: omnivise-iot
users:
- name: aws-demo-delivery
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: aws
      args:
      - eks
      - get-token
      - --region
      - $AWS_REGION_FIXED
      - --cluster-name
      - omnivise-iot
EOF
    then
      die_environment "unable to write temporary kubeconfig"
    fi

    export KUBECONFIG="$kubeconfig"

    if probe_output="$(kubectl --cache-dir "$kube_cache" auth can-i create deployments -n omnivise-iot)"; then
      probe_rc=0
    else
      probe_rc=$?
    fi

    if [ "$probe_rc" -eq 1 ] && [ "$probe_output" = "no" ]; then
      report_state VIOLATION \
        "delivery role cannot create deployments in omnivise-iot" \
        "$NEXT_IDENTITY_DRIFT"
      return 2
    fi

    if [ "$probe_rc" -ne 0 ] || [ "$probe_output" != "yes" ]; then
      die_environment "Kubernetes deployment authorization probe did not return an exact answer"
    fi

    probe_output=""
    if probe_output="$(kubectl --cache-dir "$kube_cache" auth can-i create namespaces 2>/dev/null)"; then
      probe_rc=0
    else
      probe_rc=$?
    fi

    if [ "$probe_rc" -ne 1 ] || [ "$probe_output" != "no" ]; then
      if [ "$probe_rc" -eq 0 ]; then
        report_state VIOLATION \
          "delivery role can create cluster namespaces" \
          "$NEXT_IDENTITY_DRIFT"
        return 2
      fi
      die_environment "namespace denial probe did not return an exact Kubernetes denial"
    fi

    probe_output=""
    if probe_output="$(kubectl --cache-dir "$kube_cache" auth can-i get secrets -n kube-system 2>/dev/null)"; then
      probe_rc=0
    else
      probe_rc=$?
    fi

    if [ "$probe_rc" -ne 1 ] || [ "$probe_output" != "no" ]; then
      if [ "$probe_rc" -eq 0 ]; then
        report_state VIOLATION \
          "delivery role can read kube-system secrets" \
          "$NEXT_IDENTITY_DRIFT"
        return 2
      fi
      die_environment "kube-system secret denial probe did not return an exact Kubernetes denial"
    fi

    probe_output=""
    if probe_output="$(kubectl --cache-dir "$kube_cache" auth can-i create clusterrolebindings 2>/dev/null)"; then
      probe_rc=0
    else
      probe_rc=$?
    fi

    if [ "$probe_rc" -ne 1 ] || [ "$probe_output" != "no" ]; then
      if [ "$probe_rc" -eq 0 ]; then
        report_state VIOLATION \
          "delivery role can create clusterrolebindings" \
          "$NEXT_IDENTITY_DRIFT"
        return 2
      fi
      die_environment "clusterrolebinding denial probe did not return an exact Kubernetes denial"
    fi

    unset \
      AWS_ACCESS_KEY_ID \
      AWS_SECRET_ACCESS_KEY \
      AWS_SESSION_TOKEN \
      delivery_access_key_id \
      delivery_secret_access_key \
      delivery_session_token \
      assume_response \
      cluster_response \
      endpoint \
      ca_data \
      probe_output

    return 0
  )

  local rc=$?

  unset bootstrap_access_key_id bootstrap_secret_access_key

  return "$rc"
}

# Print a file's mtime (Y) or ctime (Z) as epoch nanoseconds. LC_ALL=C keeps
# the decimal separator a dot. Failure or malformed output exits 3.
file_metadata_epoch_ns() {
  local field="$1"
  local path="$2"
  local raw=""

  if ! raw="$(LC_ALL=C stat -c "%.9$field" -- "$path")"; then
    die_environment "unable to determine local AWS credential file metadata timestamp"
  fi

  if [[ ! "$raw" =~ ^[0-9]+\.[0-9]{9}$ ]]; then
    die_environment "malformed local AWS credential file metadata timestamp"
  fi

  printf '%s' "$((10#${raw%.*} * 1000000000 + 10#${raw#*.}))"
}

classify_jenkins_credential_freshness() {
  local id_file="$ACCESS_KEY_ID_FILE"
  local secret_file="$SECRET_ACCESS_KEY_FILE"
  local container="$JENKINS_CONTAINER"
  local started_at=""
  local started_ns=""
  local stamp=""
  local stamp_ns=""
  local latest_ns=0

  # Use nanosecond precision for both Docker StartedAt and host file
  # metadata timestamps. Equality is deliberately not fresh.
  if ! started_at="$(docker inspect \
      --format '{{.State.StartedAt}}' \
      "$container" 2>/dev/null)"; then
    printf 'STATE: UP-RESTART-REQUIRED\n'
    printf 'DETAIL: Jenkins StartedAt could not be determined\n'
    printf 'NEXT: perform the controlled Jenkins restart procedure\n'
    return 1
  fi

  if ! started_ns="$(date -u -d "$started_at" '+%s%N' 2>/dev/null)"; then
    printf 'STATE: UP-RESTART-REQUIRED\n'
    printf 'DETAIL: Jenkins StartedAt is not a valid timestamp\n'
    printf 'NEXT: perform the controlled Jenkins restart procedure\n'
    return 1
  fi

  # max(mtime(id), ctime(id), mtime(secret), ctime(secret)) in epoch
  # nanoseconds. Every stat call is checked; no default is ever substituted.
  for stamp in "Y:$id_file" "Z:$id_file" "Y:$secret_file" "Z:$secret_file"; do
    stamp_ns="$(file_metadata_epoch_ns "${stamp%%:*}" "${stamp#*:}")" || exit 3

    if (( stamp_ns > latest_ns )); then
      latest_ns="$stamp_ns"
    fi
  done

  if (( started_ns > latest_ns )); then
    printf 'STATE: READY\n'
    printf 'NEXT: Jenkins AWS delivery credential is active and freshly loaded\n'
    return 0
  fi

  printf 'STATE: UP-RESTART-REQUIRED\n'
  printf 'DETAIL: Jenkins was not started strictly after the latest AWS credential file change\n'
  printf 'NEXT: perform the controlled Jenkins restart procedure\n'
  return 1
}

classify_one_key_local_readiness() {
  local keys_json="$1"
  local id_file="$ACCESS_KEY_ID_FILE"
  local secret_file="$SECRET_ACCESS_KEY_FILE"
  local container="$JENKINS_CONTAINER"
  local aws_key_id=""
  local local_key_id=""
  local running=""
  local mounts_json=""
  local rc=0

  if [ -z "$id_file" ] || [ -z "$secret_file" ]; then
    printf 'STATE: VIOLATION\n'
    printf 'DETAIL: local Jenkins AWS secret file paths are not configured\n'
    return 2
  fi

  validate_secret_file "$id_file" "AWS access key ID"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  validate_secret_file "$secret_file" "AWS secret access key"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  if ! aws_key_id="$(printf '%s' "$keys_json" | jq -er '
      if (.AccessKeyMetadata | length) == 1
      then .AccessKeyMetadata[0].AccessKeyId
      else empty
      end
    ')"; then
    die_environment "unable to determine sole bootstrap access-key ID"
  fi

  if ! IFS= read -r local_key_id < "$id_file" && [ -z "$local_key_id" ]; then
    die_environment "unable to read local AWS access key ID"
  fi

  if [ "$local_key_id" != "$aws_key_id" ]; then
    printf 'STATE: VIOLATION\n'
    printf 'DETAIL: local access-key ID does not match the sole bootstrap IAM key\n'
    return 2
  fi

  if ! command -v docker >/dev/null 2>&1; then
    die_environment "docker is required"
  fi

  if running="$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)"; then
    :
  else
    printf 'STATE: UP-RESTART-REQUIRED\n'
    printf 'DETAIL: Jenkins container does not exist\n'
    printf 'NEXT: perform the controlled Jenkins restart/start procedure\n'
    return 1
  fi

  if [ "$running" != "true" ]; then
    printf 'STATE: UP-RESTART-REQUIRED\n'
    printf 'DETAIL: Jenkins container is not running\n'
    printf 'NEXT: perform the controlled Jenkins restart/start procedure\n'
    return 1
  fi

  if ! mounts_json="$(docker inspect --format '{{json .Mounts}}' "$container")"; then
    die_environment "unable to inspect Jenkins mounts"
  fi

  validate_mount_source \
    "$mounts_json" \
    "/run/secrets/omnivise_iot_aws_access_key_id" \
    "$id_file" \
    "AWS access key ID"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  validate_mount_source \
    "$mounts_json" \
    "/run/secrets/omnivise_iot_aws_secret_access_key" \
    "$secret_file" \
    "AWS secret access key"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  if verify_aws_runtime_chain; then
    :
  else
    rc=$?
    return "$rc"
  fi

  if verify_kubernetes_runtime_chain; then
    :
  else
    rc=$?
    return "$rc"
  fi

  classify_jenkins_credential_freshness
  return $?
}

# issue-credential with exactly one Active AWS key: idempotent no-op only when
# the local access-key ID file is valid and matches that key. The secret file
# and Jenkins container are not needed for this decision.
issue_existing_key_noop() {
  local keys_json="$1"
  local id_file="$ACCESS_KEY_ID_FILE"
  local aws_key_id=""
  local local_key_id=""

  if [ -z "$id_file" ]; then
    report_state VIOLATION \
      "local Jenkins AWS access-key ID file path is not configured" \
      "$NEXT_LOCAL_SECRET_FILES"
    return 2
  fi

  validate_secret_file "$id_file" "AWS access key ID" || return $?

  if ! aws_key_id="$(printf '%s' "$keys_json" | jq -er '
      if (.AccessKeyMetadata | length) == 1
      then .AccessKeyMetadata[0].AccessKeyId
      else empty
      end
    ')"; then
    die_environment "unable to determine sole bootstrap access-key ID"
  fi

  if ! IFS= read -r local_key_id < "$id_file" && [ -z "$local_key_id" ]; then
    die_environment "unable to read local AWS access key ID"
  fi

  if [ "$local_key_id" != "$aws_key_id" ]; then
    report_state VIOLATION \
      "local access-key ID does not match the sole bootstrap IAM key" \
      "$NEXT_KEY_RECOVERY"
    return 2
  fi

  # Whether this is UP-RESTART-REQUIRED or READY needs the runtime chain and
  # Jenkins freshness checks, so no lifecycle state is claimed here.
  printf 'DETAIL: matching bootstrap access key already issued; no new key was created\n'
  printf 'NEXT: run scripts/aws-demo.sh status\n'
  return 0
}

resolve_revoke_key_id() {
  local keys_json="$1"
  local selector="$2"
  local match_count=0
  local resolved=""

  if [[ ! "$selector" =~ ^[A-Z0-9]{4,20}$ ]]; then
    die_usage
  fi

  if ! match_count="$(printf '%s' "$keys_json" | jq -er \
      --arg selector "$selector" '
        [
          .AccessKeyMetadata[]
          | select(
              (.AccessKeyId == $selector)
              or (.AccessKeyId | endswith($selector))
            )
        ]
        | length
      ')"; then
    die_environment "unable to resolve recovery access-key selector"
  fi

  # Contract: ambiguous or unmatched selector is exit 3. Never list candidates.
  if [ "$match_count" -ne 1 ]; then
    die_environment "recovery key selector must match exactly one bootstrap access key (matches: $match_count)"
  fi

  if ! resolved="$(printf '%s' "$keys_json" | jq -er \
      --arg selector "$selector" '
        [
          .AccessKeyMetadata[]
          | select(
              (.AccessKeyId == $selector)
              or (.AccessKeyId | endswith($selector))
            )
        ][0].AccessKeyId
      ')"; then
    die_environment "unable to resolve recovery access-key ID"
  fi

  printf '%s' "$resolved"
}

revoke_selected_bootstrap_key() {
  local key_id="$1"
  local lifecycle="${2:-up}"
  local keys_json="${3:-}"
  local response=""
  local attempt=0
  local expected_remaining=""
  local observed_remaining=""
  local remaining_count=0
  local delete_err_file=""
  local delete_error_code=""

  # Contract: after revoke, converge to the expected remaining key set.
  if ! expected_remaining="$(printf '%s' "$keys_json" | jq -ce --arg key_id "$key_id" '
      [.AccessKeyMetadata[].AccessKeyId | select(. != $key_id)] | sort
    ' 2>/dev/null)"; then
    die_environment "unable to determine expected remaining bootstrap access keys"
  fi

  if ! delete_err_file="$(mktemp "${AWS_DEMO_TMP:?}/delete.XXXXXX")"; then
    die_environment "unable to create temporary delete probe file"
  fi

  if ! aws_mutate iam delete-access-key "$key_id" 2>"$delete_err_file"; then
    # Report only the AWS error code and the masked key suffix.
    delete_error_code="$(grep -oE '\([A-Za-z]+\)' "$delete_err_file" | head -n1 | tr -d '()' || true)"
    rm -f "$delete_err_file"
    die_environment "IAM delete-access-key failed (${delete_error_code:-unknown error}) for bootstrap key ****${key_id: -4}"
  fi

  rm -f "$delete_err_file"

  for attempt in 1 2 3 4 5; do
    if ! response="$(aws_ro iam list-access-keys \
        --user-name omnivise-iot-jenkins-bootstrap)"; then
      die_environment "unable to verify revoked bootstrap access key"
    fi

    # Malformed list output is an operational error, not propagation delay.
    remaining_count="$(json_array_length "$response" AccessKeyMetadata)" || exit 3

    if ! observed_remaining="$(printf '%s' "$response" | jq -ce '
        [.AccessKeyMetadata[].AccessKeyId] | sort
      ' 2>/dev/null)"; then
      die_environment "invalid IAM access-key response after revoke"
    fi

    if [ "$observed_remaining" = "$expected_remaining" ]; then
      unset key_id response

      case "$lifecycle" in
        up)
          if [ "$remaining_count" -eq 0 ]; then
            report_state UP-NO-CREDENTIAL \
              "" \
              "Jenkins AWS delivery is intentionally disabled until a new credential is issued"
          else
            # Remaining keys are not classified here; status decides.
            printf 'DETAIL: selected bootstrap access key was revoked; %s bootstrap access key(s) remain\n' "$remaining_count"
            printf 'NEXT: rerun scripts/aws-demo.sh status\n'
          fi
          ;;
        recovery)
          # Explicit recovery does not verify the identity boundary, so no
          # lifecycle state is claimed; status decides.
          printf 'DETAIL: selected bootstrap access key was revoked; %s bootstrap access key(s) remain\n' "$remaining_count"
          printf 'NEXT: rerun scripts/aws-demo.sh status\n'
          ;;
        down)
          report_state DOWN-DIRTY \
            "selected bootstrap access key was revoked; AWS teardown leftovers still require cleanup" \
            "continue the teardown/recovery procedure until status reports DOWN-CLEAN"
          ;;
        *)
          die_environment "invalid revoke lifecycle mode"
          ;;
      esac

      return 0
    fi

    if [ "$attempt" -lt 5 ]; then
      sleep 1
    fi
  done

  unset key_id response

  case "$lifecycle" in
    up|recovery)
      printf 'DETAIL: revoke completed, but the IAM key list has not converged yet\n'
      printf 'NEXT: rerun scripts/aws-demo.sh status\n'
      ;;
    down)
      # The bootstrap user still exists, so DOWN-DIRTY is proven.
      report_state DOWN-DIRTY \
        "revoke completed, but the IAM key list has not converged yet" \
        "retry recovery after IAM propagation completes"
      ;;
    *)
      die_environment "invalid revoke lifecycle mode"
      ;;
  esac

  return 1
}

# Default revoke (no --key-id) after the full UP classification. Explicit
# --key-id recovery is handled by revoke_explicit_recovery (cluster present)
# and recover_down_bootstrap_credential (cluster absent).
revoke_from_key_state() {
  local keys_json="$1"
  local key_count=0
  local key_id=""
  local local_id_file="$ACCESS_KEY_ID_FILE"
  local local_id=""
  local key_status=""

  if ! key_count="$(printf '%s' "$keys_json" | jq -er '.AccessKeyMetadata | length')"; then
    die_environment "invalid IAM access-key response"
  fi

  case "$key_count" in
    0)
      printf 'STATE: UP-NO-CREDENTIAL\n'
      printf 'NEXT: no bootstrap access key exists; nothing was revoked\n'
      return 0
      ;;

    1)
      if ! key_id="$(printf '%s' "$keys_json" | jq -er '.AccessKeyMetadata[0].AccessKeyId')"; then
        die_environment "invalid IAM access-key metadata"
      fi

      if ! key_status="$(printf '%s' "$keys_json" | jq -er '.AccessKeyMetadata[0].Status')"; then
        die_environment "invalid IAM access-key metadata"
      fi

      # Default revoke only removes a matching Active key; anything else is
      # explicit recovery.
      if [ "$key_status" != "Active" ]; then
        report_state VIOLATION \
          "the sole bootstrap access key is not Active; default revoke only deletes a matching Active key" \
          "$NEXT_KEY_RECOVERY"
        return 2
      fi

      if [ -z "$local_id_file" ]; then
        report_state VIOLATION \
          "default revoke requires the configured local access-key ID file" \
          "$NEXT_LOCAL_SECRET_FILES"
        return 2
      fi

      validate_secret_file "$local_id_file" "AWS access key ID" || return $?

      if ! IFS= read -r local_id < "$local_id_file" && [ -z "$local_id" ]; then
        die_environment "unable to read local AWS access key ID"
      fi

      if [ "$local_id" != "$key_id" ]; then
        report_state VIOLATION \
          "local access-key ID does not match the sole bootstrap IAM key" \
          "$NEXT_KEY_RECOVERY"
        return 2
      fi

      revoke_selected_bootstrap_key "$key_id" up "$keys_json"
      return $?
      ;;

    *)
      report_state VIOLATION \
        "multiple bootstrap access keys require explicit --key-id recovery selection" \
        "identify each key with 'aws iam list-access-keys --user-name omnivise-iot-jenkins-bootstrap' and run scripts/aws-demo.sh revoke-credential --key-id <suffix> for one key at a time"
      return 2
      ;;
  esac
}

# revoke-credential --key-id while the EKS cluster exists (any status).
# Recovery-only: requires the exact bootstrap user identity, a readable key
# list and an unambiguous selector, but not a healthy delivery/EKS boundary,
# so drift can never keep an existing bootstrap key alive.
revoke_explicit_recovery() {
  local selector="$1"
  local user_response=""
  local keys_response=""
  local key_count=0
  local key_id=""
  local rc=0

  if user_response="$(aws_absence_probe \
      iam get-user \
      --user-name omnivise-iot-jenkins-bootstrap)"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      report_state VIOLATION \
        "the EKS cluster exists but the bootstrap IAM user is missing; there is no provable key to revoke" \
        "$NEXT_IDENTITY_DRIFT"
      return 2
    fi
    return "$rc"
  fi

  if ! printf '%s' "$user_response" | jq -e '
      .User.UserName == "omnivise-iot-jenkins-bootstrap"
      and .User.Arn == "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    ' >/dev/null 2>&1; then
    report_state VIOLATION \
      "bootstrap IAM user identity does not match; explicit revoke refused" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  if ! keys_response="$(aws_ro iam list-access-keys \
      --user-name omnivise-iot-jenkins-bootstrap)"; then
    die_environment "unable to list bootstrap access keys for explicit revoke"
  fi

  # Malformed key-list output is an operational error.
  key_count="$(json_array_length "$keys_response" AccessKeyMetadata)" || exit 3

  if key_id="$(resolve_revoke_key_id "$keys_response" "$selector")"; then
    :
  else
    rc=$?
    return "$rc"
  fi

  revoke_selected_bootstrap_key "$key_id" recovery "$keys_response"
}

recover_down_bootstrap_credential() {
  local selector="${1:-}"
  local user_response=""
  local keys_response=""
  local key_id=""
  local rc=0

  if user_response="$(aws_absence_probe \
      iam get-user \
      --user-name omnivise-iot-jenkins-bootstrap)"; then
    :
  else
    rc=$?

    case "$rc" in
      1)
        # No bootstrap user means no credential to revoke (idempotent no-op),
        # but the lifecycle state must still come from the complete DOWN scan.
        if classify_down_state; then
          return 0
        else
          rc=$?
        fi

        [ "$rc" -eq 1 ] || return "$rc"
        return 0
        ;;
      3)
        return 3
        ;;
      *)
        die_environment "unexpected bootstrap-user absence probe result"
        ;;
    esac
  fi

  if ! printf '%s' "$user_response" | jq -e '
      .User.UserName == "omnivise-iot-jenkins-bootstrap"
      and .User.Arn == "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    ' >/dev/null 2>&1; then
    printf 'STATE: VIOLATION\n'
    printf 'DETAIL: cluster-absent recovery found an unexpected bootstrap IAM user identity\n'
    return 2
  fi

  if [ -z "$selector" ]; then
    printf 'STATE: VIOLATION\n'
    printf 'DETAIL: cluster-absent credential recovery requires explicit --key-id selection\n'
    return 2
  fi

  if ! keys_response="$(aws_ro iam list-access-keys \
      --user-name omnivise-iot-jenkins-bootstrap)"; then
    die_environment "unable to list bootstrap access keys for DOWN-DIRTY recovery"
  fi

  if key_id="$(resolve_revoke_key_id "$keys_response" "$selector")"; then
    :
  else
    rc=$?
    return "$rc"
  fi

  revoke_selected_bootstrap_key "$key_id" down "$keys_response"
  return $?
}

classify_up_state() {
  local cluster_response="$1"
  local mode="${2:-status}"
  local response=""
  local rc=0
  local key_count=0
  local key_status=""
  local count=0

  if ! printf '%s' "$cluster_response" | jq -e '
    .cluster.name == "omnivise-iot"
    and .cluster.arn == "arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
    and .cluster.status == "ACTIVE"
  ' >/dev/null 2>&1; then
    report_state VIOLATION \
      "EKS cluster is present but does not match the required ACTIVE cluster identity" \
      "if the cluster is CREATING/UPDATING/DELETING wait and rerun status; if FAILED or mismatched, repair it through the platform Terraform workflow"
    return 2
  fi

  # Only an exact NoSuchEntity proves absence; with the cluster present that
  # is identity drift (VIOLATION). Every other failure stays operational.
  if response="$(aws_absence_probe \
      iam get-user \
      --user-name omnivise-iot-jenkins-bootstrap)"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      report_state VIOLATION \
        "the EKS cluster exists but the expected bootstrap IAM user is missing" \
        "$NEXT_IDENTITY_DRIFT"
      return 2
    fi
    return "$rc"
  fi

  if ! printf '%s' "$response" | jq -e '.User | type == "object"' >/dev/null 2>&1; then
    die_environment "invalid iam get-user response for the bootstrap user"
  fi

  if ! printf '%s' "$response" | jq -e '
    .User.UserName == "omnivise-iot-jenkins-bootstrap"
    and .User.Arn == "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    and (.User | has("PermissionsBoundary") | not)
  ' >/dev/null 2>&1; then
    report_state VIOLATION \
      "bootstrap IAM user invariant mismatch" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  response="$(require_aws_json \
    "bootstrap IAM groups" \
    iam list-groups-for-user \
    --user-name omnivise-iot-jenkins-bootstrap)"

  count="$(json_array_length "$response" Groups)" || exit 3

  if [ "$count" -ne 0 ]; then
    report_state VIOLATION \
      "bootstrap IAM user must not belong to groups" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  response="$(require_aws_json \
    "bootstrap managed policies" \
    iam list-attached-user-policies \
    --user-name omnivise-iot-jenkins-bootstrap)"

  count="$(json_array_length "$response" AttachedPolicies)" || exit 3

  if [ "$count" -ne 0 ]; then
    report_state VIOLATION \
      "bootstrap IAM user must not have managed policies" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  response="$(require_aws_json \
    "bootstrap inline policy names" \
    iam list-user-policies \
    --user-name omnivise-iot-jenkins-bootstrap)"

  if ! printf '%s' "$response" | jq -e '
    .PolicyNames == ["omnivise-iot-jenkins-bootstrap-assume-delivery"]
  ' >/dev/null 2>&1; then
    report_state VIOLATION \
      "bootstrap IAM inline policy set mismatch" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  response="$(require_aws_json \
    "bootstrap inline policy" \
    iam get-user-policy \
    --user-name omnivise-iot-jenkins-bootstrap \
    --policy-name omnivise-iot-jenkins-bootstrap-assume-delivery)"

  if ! printf '%s' "$response" | jq -e '
    .PolicyDocument.Statement | length == 1
    and (.[0] | keys == ["Action", "Effect", "Resource"])
    and .[0].Effect == "Allow"
    and .[0].Action == "sts:AssumeRole"
    and .[0].Resource == "arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
  ' >/dev/null 2>&1; then
    report_state VIOLATION \
      "bootstrap IAM inline policy mismatch" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  response="$(require_aws_json \
    "delivery IAM role" \
    iam get-role \
    --role-name omnivise-iot-jenkins-delivery)"

  if ! printf '%s' "$response" | jq -e '
    .Role.RoleName == "omnivise-iot-jenkins-delivery"
    and .Role.Arn == "arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
    and (.Role | has("PermissionsBoundary") | not)
    and (.Role.AssumeRolePolicyDocument.Statement | length == 1)
    and (.Role.AssumeRolePolicyDocument.Statement[0] | keys == ["Action", "Effect", "Principal"])
    and (.Role.AssumeRolePolicyDocument.Statement[0].Principal | keys == ["AWS"])
    and .Role.AssumeRolePolicyDocument.Statement[0].Effect == "Allow"
    and .Role.AssumeRolePolicyDocument.Statement[0].Principal.AWS
      == "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap"
    and .Role.AssumeRolePolicyDocument.Statement[0].Action == "sts:AssumeRole"
  ' >/dev/null 2>&1; then
    report_state VIOLATION \
      "delivery IAM role or trust policy mismatch" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  response="$(require_aws_json \
    "delivery managed policies" \
    iam list-attached-role-policies \
    --role-name omnivise-iot-jenkins-delivery)"

  count="$(json_array_length "$response" AttachedPolicies)" || exit 3

  if [ "$count" -ne 0 ]; then
    report_state VIOLATION \
      "delivery IAM role must not have managed policies" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  response="$(require_aws_json \
    "delivery inline policy names" \
    iam list-role-policies \
    --role-name omnivise-iot-jenkins-delivery)"

  if ! printf '%s' "$response" | jq -e '
    .PolicyNames == ["omnivise-iot-jenkins-delivery-describe-cluster"]
  ' >/dev/null 2>&1; then
    report_state VIOLATION \
      "delivery IAM inline policy set mismatch" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  response="$(require_aws_json \
    "delivery inline policy" \
    iam get-role-policy \
    --role-name omnivise-iot-jenkins-delivery \
    --policy-name omnivise-iot-jenkins-delivery-describe-cluster)"

  if ! printf '%s' "$response" | jq -e '
    .PolicyDocument.Statement | length == 1
    and (.[0] | keys == ["Action", "Effect", "Resource"])
    and .[0].Effect == "Allow"
    and .[0].Action == "eks:DescribeCluster"
    and .[0].Resource == "arn:aws:eks:eu-north-1:554422868760:cluster/omnivise-iot"
  ' >/dev/null 2>&1; then
    report_state VIOLATION \
      "delivery IAM inline policy mismatch" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  if probe_eks_access_entry \
      "arn:aws:iam::554422868760:user/omnivise-iot-jenkins-bootstrap" \
      >/dev/null; then
    report_state VIOLATION \
      "bootstrap IAM user must not have an EKS access entry" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  else
    rc=$?
    [ "$rc" -eq 1 ] || return "$rc"
  fi

  if response="$(probe_eks_access_entry \
      "arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery")"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      report_state VIOLATION \
        "delivery EKS access entry is missing" \
        "$NEXT_IDENTITY_DRIFT"
      return 2
    fi
    return "$rc"
  fi

  if ! printf '%s' "$response" | jq -e '
    .accessEntry.principalArn
      == "arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery"
    and .accessEntry.type == "STANDARD"
    and .accessEntry.kubernetesGroups == []
  ' >/dev/null 2>&1; then
    report_state VIOLATION \
      "delivery EKS access entry mismatch" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  response="$(require_aws_json \
    "delivery EKS access policies" \
    eks list-associated-access-policies \
    --cluster-name omnivise-iot \
    --principal-arn arn:aws:iam::554422868760:role/omnivise-iot-jenkins-delivery)"

  if ! printf '%s' "$response" | jq -e '
    .associatedAccessPolicies | length == 1
    and .[0].policyArn
      == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
    and .[0].accessScope.type == "namespace"
    and .[0].accessScope.namespaces == ["omnivise-iot"]
  ' >/dev/null 2>&1; then
    report_state VIOLATION \
      "delivery EKS access policy association mismatch" \
      "$NEXT_IDENTITY_DRIFT"
    return 2
  fi

  response="$(require_aws_json \
    "bootstrap access keys" \
    iam list-access-keys \
    --user-name omnivise-iot-jenkins-bootstrap)"

  key_count="$(json_array_length "$response" AccessKeyMetadata)" || exit 3

  if [ "$mode" = "revoke" ]; then
    revoke_from_key_state "$response"
    return $?
  fi

  case "$key_count" in
    0)
      if [ "$mode" = "issue" ]; then
        precreate_local_gate || return $?

        create_bootstrap_credential
        return $?
      fi

      printf 'STATE: UP-NO-CREDENTIAL\n'
      printf 'NEXT: run scripts/aws-demo.sh issue-credential\n'
      return 1
      ;;

    1)
      if ! key_status="$(printf '%s' "$response" | jq -er '.AccessKeyMetadata[0].Status')"; then
        die_environment "invalid IAM access-key metadata"
      fi

      if [ "$key_status" != "Active" ]; then
        report_state VIOLATION \
          "the sole bootstrap access key must be Active" \
          "$NEXT_KEY_RECOVERY"
        return 2
      fi

      if [ "$mode" = "issue" ]; then
        issue_existing_key_noop "$response"
        return $?
      fi

      if [ "$mode" = "status" ]; then
        acquire_existing_key_lock shared

        if classify_one_key_local_readiness "$response"; then
          return 0
        else
          rc=$?
          return "$rc"
        fi
      fi

      die_environment "unexpected one-key lifecycle mode"
      ;;

    *)
      report_state VIOLATION \
        "bootstrap IAM user must have at most one access key" \
        "$NEXT_KEY_RECOVERY"
      return 2
      ;;
  esac
}

probe_cluster_presence() {
  local err_file
  local response=""
  local rc=0
  local err=""

  if ! err_file="$(mktemp "${AWS_DEMO_TMP:?}/eks.XXXXXX")"; then
    die_environment "unable to create temporary cluster probe file"
  fi

  if response="$(aws_ro eks describe-cluster --name omnivise-iot 2>"$err_file")"; then
    rc=0
  else
    rc=$?
  fi

  err="$(cat "$err_file")"
  rm -f "$err_file"

  if [ "$rc" -eq 0 ]; then
    printf '%s' "$response"
    return 0
  fi

  if [[ "$err" == *"(ResourceNotFoundException)"* ]]; then
    return 1
  fi

  printf 'ENVIRONMENT_ERROR: eks DescribeCluster failed: %s\n' "$err" >&2
  return 3
}

AWS_DEMO_LOCK_FD=""

acquire_existing_key_lock() {
  local mode="$1"
  local id_file="$ACCESS_KEY_ID_FILE"

  # DOWN classification must not depend on local Jenkins secret files.
  # If no existing key-ID file is configured, defer local validation to
  # the later readiness / mutation gate.
  if [ -z "$id_file" ] || [ ! -e "$id_file" ]; then
    return 0
  fi

  if [ ! -f "$id_file" ]; then
    return 0
  fi

  # flock does not need write access; status must not require it.
  if [ "$mode" = "shared" ]; then
    if ! exec {AWS_DEMO_LOCK_FD}<"$id_file"; then
      die_environment "unable to open access-key ID file for lock"
    fi
  elif ! exec {AWS_DEMO_LOCK_FD}<>"$id_file"; then
    die_environment "unable to open access-key ID file for lock"
  fi

  case "$mode" in
    shared)
      if ! flock -n -s "$AWS_DEMO_LOCK_FD"; then
        die_environment "access-key ID file lock is held by another aws-demo operation"
      fi
      ;;
    exclusive)
      if ! flock -n -x "$AWS_DEMO_LOCK_FD"; then
        die_environment "access-key ID file lock is held by another aws-demo operation"
      fi
      ;;
    *)
      die_environment "invalid lock mode"
      ;;
  esac
}

require_core_tools() {
  local tool=""

  for tool in aws jq mktemp stat realpath flock date id rm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      die_environment "required tool is missing: $tool"
    fi
  done
}

# Resolve OMNIVISE_JENKINS_PLATFORM_DIR (default: ../local-jenkins-platform
# next to this repository) and OMNIVISE_JENKINS_CONTAINER. Secret filenames
# are fixed and never overridable.
resolve_jenkins_platform_config() {
  local script_path=""
  local repo_root=""

  if ! script_path="$(realpath -- "${BASH_SOURCE[0]}")"; then
    die_environment "unable to resolve aws-demo.sh location"
  fi

  if ! repo_root="$(realpath -- "${script_path%/*}/..")"; then
    die_environment "unable to resolve repository root"
  fi

  JENKINS_PLATFORM_DIR="${OMNIVISE_JENKINS_PLATFORM_DIR:-$repo_root/../local-jenkins-platform}"
  JENKINS_CONTAINER="${OMNIVISE_JENKINS_CONTAINER:-$JENKINS_CONTAINER_DEFAULT}"
  ACCESS_KEY_ID_FILE="$JENKINS_PLATFORM_DIR/secrets/omnivise_iot_aws_access_key_id"
  SECRET_ACCESS_KEY_FILE="$JENKINS_PLATFORM_DIR/secrets/omnivise_iot_aws_secret_access_key"
}

security_preflight() {
  require_core_tools

  case "$-" in
    *x*)
      die_environment "shell xtrace must be disabled"
      ;;
  esac

  local name
  while IFS= read -r name; do
    case "$name" in
      AWS_ENDPOINT_URL|AWS_ENDPOINT_URL_*)
        die_environment "AWS_ENDPOINT_URL overrides are not allowed"
        ;;
    esac
  done < <(compgen -e)

  export AWS_PAGER=""
  export AWS_CLI_AUTO_PROMPT=off

  local cli_history=""
  local rc=0

  if cli_history="$(aws configure get cli_history 2>/dev/null)"; then
    rc=0
  else
    rc=$?
  fi

  case "$rc" in
    0)
      if [ "$cli_history" = "enabled" ]; then
        die_environment "AWS CLI cli_history must not be enabled"
      fi
      ;;
    1)
      # An unset cli_history setting is acceptable.
      ;;
    *)
      die_environment "unable to determine AWS CLI cli_history setting"
      ;;
  esac
}

AWS_DEMO_TMP=""

# shellcheck disable=SC2329  # invoked via the EXIT trap in setup_runtime_tmp
cleanup_runtime_tmp() {
  # Only ever remove the directory this process created via mktemp -d.
  if [ -n "$AWS_DEMO_TMP" ] && [ -d "$AWS_DEMO_TMP" ]; then
    rm -rf -- "$AWS_DEMO_TMP"
  fi
}

# One private temp root for every temporary file of this run. Created after
# the security preflight; removed on EXIT, and INT/TERM still exit non-zero.
setup_runtime_tmp() {
  if ! AWS_DEMO_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aws-demo.XXXXXX")"; then
    AWS_DEMO_TMP=""
    die_environment "unable to create private runtime temp directory"
  fi

  # Preserve the original exit status even if cleanup itself fails.
  # shellcheck disable=SC2154  # aws_demo_exit_rc is assigned inside the trap
  trap 'aws_demo_exit_rc=$?; cleanup_runtime_tmp || true; exit "$aws_demo_exit_rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

main() {
  if [ "$#" -eq 0 ]; then
    die_usage
  fi

  local command="$1"
  shift

  case "$command" in
    status)
      [ "$#" -eq 0 ] || die_usage
      security_preflight
      resolve_jenkins_platform_config
      setup_runtime_tmp
      check_operator_identity

      cluster_response=""
      if cluster_response="$(probe_cluster_presence)"; then
        cluster_rc=0
      else
        cluster_rc=$?
      fi

      case "$cluster_rc" in
        0)
          classify_up_state "$cluster_response"
          exit $?
          ;;
        1)
          classify_down_state
          exit $?
          ;;
        3)
          exit 3
          ;;
        *)
          die_environment "unexpected cluster probe result"
          ;;
      esac
      ;;
    issue-credential)
      [ "$#" -eq 0 ] || die_usage
      security_preflight
      resolve_jenkins_platform_config
      setup_runtime_tmp
      acquire_existing_key_lock exclusive
      check_operator_identity

      cluster_response=""
      if cluster_response="$(probe_cluster_presence)"; then
        classify_up_state "$cluster_response" issue
        exit $?
      else
        cluster_rc=$?
      fi

      case "$cluster_rc" in
        1)
          printf 'STATE: VIOLATION\n'
          printf 'DETAIL: cannot issue a credential while the EKS cluster is absent\n'
          exit 2
          ;;
        3)
          exit 3
          ;;
        *)
          die_environment "unexpected cluster probe result"
          ;;
      esac
      ;;
    revoke-credential)
      revoke_selector=""

      case "$#" in
        0)
          ;;
        2)
          [ "$1" = "--key-id" ] || die_usage
          # Full AWS access-key ID or a unique suffix of at least 4 characters.
          [[ "$2" =~ ^[A-Z0-9]{4,20}$ ]] || die_usage
          revoke_selector="$2"
          ;;
        *)
          die_usage
          ;;
      esac

      security_preflight
      resolve_jenkins_platform_config
      setup_runtime_tmp
      acquire_existing_key_lock exclusive
      check_operator_identity

      cluster_response=""
      if cluster_response="$(probe_cluster_presence)"; then
        if [ -n "$revoke_selector" ]; then
          revoke_explicit_recovery "$revoke_selector"
          exit $?
        fi

        classify_up_state "$cluster_response" revoke
        exit $?
      else
        cluster_rc=$?
      fi

      case "$cluster_rc" in
        1)
          recover_down_bootstrap_credential "$revoke_selector"
          exit $?
          ;;
        3)
          exit 3
          ;;
        *)
          die_environment "unexpected cluster probe result"
          ;;
      esac
      ;;
    *)
      printf 'Unknown command: %s\n' "$command" >&2
      die_usage
      ;;
  esac
}

main "$@"
