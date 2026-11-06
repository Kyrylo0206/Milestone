#!/usr/bin/env bash
# Shared helpers: source, do not run. Bash 3.2 compatible (macOS default).

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=""
EVIDENCE_DIR="${EVIDENCE_DIR:-$REPO_ROOT/docs/evidence}"
PYTHON="${PYTHON:-python3}"

if [ -t 2 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_OFF=""
fi

ts()   { date -u +%Y%m%dT%H%M%SZ; }
info() { printf '%s\n' "$*" >&2; }
ok()   { printf '%sOK%s    %s\n' "$C_GREEN" "$C_OFF" "$*" >&2; }
warn() { printf '%sWARN%s  %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH. $2"; }

require_session() {
  need_cmd aws "Install the AWS CLI v2."
  if ! SESSION_JSON="$(aws sts get-caller-identity --output json 2>&1)"; then
    printf '%s\n' "$SESSION_JSON" >&2
    die "No valid AWS session. In Learner Lab: Start Lab, AWS Details, copy the CLI credentials to ~/.aws/credentials (they last about 4 hours). Region used: $AWS_REGION."
  fi
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
  info "Session ok. Account $ACCOUNT_ID, region $AWS_REGION, caller $CALLER_ARN"
}

# evidence_path <topic> <name>  ->  prints docs/evidence/<topic>/<UTC timestamp>-<name>
RUN_TS="${RUN_TS:-$(ts)}"
evidence_path() {
  mkdir -p "$EVIDENCE_DIR/$1"
  printf '%s/%s/%s-%s' "$EVIDENCE_DIR" "$1" "$RUN_TS" "$2"
}

# run_or_record <outfile> <command...>
# Never aborts the caller, because a denied call is evidence too.
run_or_record() {
  local out="$1"; shift
  local errf rc=0
  errf="$(mktemp)"
  "$@" >"$out" 2>"$errf" || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$errf" "$out.error.txt"
    info "ok      $(basename "$out")"
  else
    { printf 'COMMAND: %s\nEXIT: %s\nERROR:\n' "$*" "$rc"; cat "$errf"; } >"$out.error.txt"
    rm -f "$errf" "$out"
    warn "failed  $(basename "$out").error.txt"
  fi
  return 0
}

require_owner() {
  [ -n "${OWNER:-}" ] || die "Set OWNER to your student handle, for example: OWNER=kyrylo $0 ..."
}
stack_tags() {
  printf '%s\n' "Key=Project,Value=kvs-capstone" "Key=Milestone,Value=${MILESTONE:-m1}" \
    "Key=Environment,Value=${ENVIRONMENT:-sandbox}" "Key=Owner,Value=$OWNER" \
    "Key=ManagedBy,Value=cloudformation"
}

# stack_status <stack> -> prints status or NONE
stack_status() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || printf 'NONE'
}

stack_output() { # <stack> <key>
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}
