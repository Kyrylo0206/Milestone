#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/lint.sh [--no-online]

Runs, in order:
  1. cfn-lint on infra/*.yaml
  2. JSON parse of infra/params/*.json
  3. python3 -I scripts/test_cidr.py and the pytest tests in tests/ (if pytest is installed)
  4. aws cloudformation validate-template for each template (only with a valid session)

Env vars: CFN_LINT (path to cfn-lint), PYTHON, AWS_REGION (default us-east-1), EVIDENCE_DIR.
Output is saved to docs/evidence/lint/. Exit code is non-zero if any offline check fails.
USAGE
}

ONLINE=1
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --no-online) ONLINE=0 ;;
    *) usage >&2; die "unknown argument: $a" ;;
  esac
done

LOG="$(evidence_path lint lint.log)"
exec > >(tee "$LOG") 2>&1
cd "$REPO_ROOT"
FAIL=0

CFN_LINT="${CFN_LINT:-$(command -v cfn-lint || true)}"
if [ -z "$CFN_LINT" ]; then
  die "cfn-lint not found. Install it: pip3 install --user cfn-lint (or use a venv) and set CFN_LINT if it is not on PATH."
fi

echo "== cfn-lint =="
if "$CFN_LINT" infra/*.yaml; then echo "cfn-lint clean"; else echo "cfn-lint FAILED"; FAIL=1; fi

echo "== JSON parameter files =="
for f in infra/params/*.json; do
  if "$PYTHON" -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$f"; then echo "parses: $f"; else echo "BAD JSON: $f"; FAIL=1; fi
done

echo "== CIDR plan test =="
"$PYTHON" -I scripts/test_cidr.py || FAIL=1

echo "== pytest =="
if "$PYTHON" -c 'import pytest, yaml' 2>/dev/null; then
  (cd tests && "$PYTHON" -m pytest -q) || FAIL=1
else
  echo "pytest or pyyaml missing, skipped. pip3 install -r requirements-dev.txt"
fi

if [ "$ONLINE" -eq 1 ]; then
  echo "== validate-template (needs a session) =="
  if aws sts get-caller-identity >/dev/null 2>&1; then
    for t in infra/*.yaml; do
      if aws cloudformation validate-template --template-body "file://$t" --query 'Description' --output text; then
        echo "validate-template ok: $t"
      else
        echo "validate-template denied or failed (recorded, not fatal): $t"
      fi
    done
  else
    echo "No AWS session, skipped."
  fi
fi

[ "$FAIL" -eq 0 ] && echo "LINT RESULT: PASS" || { echo "LINT RESULT: FAIL"; exit 1; }
