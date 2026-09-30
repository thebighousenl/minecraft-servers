#!/usr/bin/env bash
# Dry-runs scripts/deploy.sh against the cluster as the OneDev ServiceAccount, so it proves both
# the deploy script and the CI's RBAC permissions without changing anything.
set -euo pipefail
cd "$(dirname "$0")/.."

if KUBECTL_ARGS="--as=system:serviceaccount:onedev:onedev" scripts/deploy.sh --dry-run; then
  echo "all checks passed"
else
  echo "FAIL: deploy dry-run as onedev:onedev" >&2
  exit 1
fi
