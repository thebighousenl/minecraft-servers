#!/usr/bin/env bash
# Applies the Traefik entrypoints and every server overlay. Run by CI on push to main
# (.onedev-buildspec.yml); also works locally.
#
# Usage: scripts/deploy.sh [--dry-run]
#   --dry-run  server-side dry-run only; changes nothing
# Extra kubectl flags can be passed in KUBECTL_ARGS (e.g. --as=... for permission checks).
#
# Never deletes anything: removing a server folder does not remove the server or its world.
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE=minecraft-servers
dry_run=false
case "${1:-}" in
  --dry-run) dry_run=true ;;
  "") ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

read -r -a extra <<<"${KUBECTL_ARGS:-}"
k() { kubectl ${extra[@]+"${extra[@]}"} "$@"; }

shopt -s nullglob
servers=(servers/*/)

echo "== Dry run"
k apply --dry-run=server -f cluster/traefik-helmchartconfig.yaml
for dir in "${servers[@]}"; do
  k apply --dry-run=server -k "$dir"
done
$dry_run && exit 0

echo "== Apply"
k apply -f cluster/traefik-helmchartconfig.yaml
for dir in "${servers[@]}"; do
  k apply -k "$dir"
done

echo "== Wait for rollouts"
for dir in "${servers[@]}"; do
  k -n "$NAMESPACE" rollout status "deploy/bedrock-$(basename "$dir")" --timeout=300s
done
