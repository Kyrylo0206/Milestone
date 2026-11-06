#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage: OWNER=<handle> scripts/recreate-timed.sh --yes

Runs scripts/teardown.sh --yes, then scripts/deploy-stack.sh, then scripts/verify-network.sh, and writes UTC
timestamps and durations to docs/evidence/recreate/<timestamp>.log. Exit code is non-zero if any step fails.
--yes is required because this deletes the network stack (and kvs-app first, if it exists).

Env vars: OWNER (required), STACK_NETWORK (default kvs-network), TEMPLATE (default infra/network.yaml),
PARAMS (default infra/params/network-sandbox.json), AWS_REGION, EVIDENCE_DIR.
After the run, add a short note by hand to the README about what broke on the first attempt.
USAGE
}
YES=0
for a in "$@"; do
  case "$a" in -h|--help) usage; exit 0 ;; --yes) YES=1 ;; *) usage >&2; die "unknown argument: $a" ;; esac
done
[ "$YES" -eq 1 ] || { usage >&2; die "refusing to delete without --yes"; }
require_owner
require_session

STACK_NETWORK="${STACK_NETWORK:-kvs-network}"
TEMPLATE="${TEMPLATE:-$REPO_ROOT/infra/network.yaml}"
PARAMS="${PARAMS:-$REPO_ROOT/infra/params/network-sandbox.json}"
LOG="$(evidence_path recreate "recreate.log")"
mkdir -p "$(dirname "$LOG")"

stamp() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
: >"$LOG"
T0="$(date +%s)"
stamp "TEARDOWN_START"
STACK_NETWORK="$STACK_NETWORK" "$LIB_DIR/teardown.sh" --yes 2>&1 | tee -a "$LOG"
T1="$(date +%s)"; stamp "TEARDOWN_END seconds=$((T1 - T0))"
stamp "CREATE_START"
"$LIB_DIR/deploy-stack.sh" "$STACK_NETWORK" "$TEMPLATE" "$PARAMS" 2>&1 | tee -a "$LOG"
T2="$(date +%s)"; stamp "CREATE_END seconds=$((T2 - T1))"
stamp "VERIFY_START"
RC=0
"$LIB_DIR/verify-network.sh" "$STACK_NETWORK" 2>&1 | tee -a "$LOG" || RC=$?
T3="$(date +%s)"; stamp "VERIFY_END seconds=$((T3 - T2)) exit=$RC"
stamp "TOTAL seconds=$((T3 - T0))"
exit "$RC"
