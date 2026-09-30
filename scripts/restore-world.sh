#!/usr/bin/env bash
# Restores a Bedrock world directory (e.g. from a LinuxGSM backup) into a server's PVC.
#
# Usage: scripts/restore-world.sh [--force] [--dry-run] <server> <path-to-world-dir>
#
# The world directory name must equal the server's LEVEL_NAME. For a new server, apply only
# its PVC first, run this script, then apply the full overlay:
#   kubectl apply -k servers/<server> -l app.kubernetes.io/component=storage
#   scripts/restore-world.sh <server> <path-to-world-dir>
#   kubectl apply -k servers/<server>
# If the Deployment already exists, it is scaled to 0 during the copy and back to 1 after.
set -euo pipefail

NAMESPACE=minecraft-servers
HELPER_IMAGE=busybox:1.37
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  echo "Usage: $0 [--force] [--dry-run] <server> <path-to-world-dir>" >&2
  exit 2
}

force=false
dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) force=true; shift ;;
    --dry-run) dry_run=true; shift ;;
    -h | --help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *) break ;;
  esac
done
[[ $# -eq 2 ]] || usage

server="$1"
world_dir="${2%/}"
overlay="$REPO_ROOT/servers/$server"

[[ -d "$overlay" ]] || { echo "No overlay at servers/$server" >&2; exit 1; }
[[ -f "$world_dir/level.dat" && -d "$world_dir/db" ]] || {
  echo "Not a Bedrock world (missing level.dat or db/): $world_dir" >&2
  exit 1
}
[[ -s "$world_dir/level.dat" ]] || {
  echo "level.dat is empty in $world_dir. If level.dat_old is intact, restore from a copy of the" >&2
  echo "world where level.dat_old is copied over level.dat." >&2
  exit 1
}

world_name="$(basename "$world_dir")"
level_name="$(kubectl kustomize "$overlay" |
  awk '/- name: LEVEL_NAME$/ { getline; sub(/^ *value: */, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit }')"

if [[ "$world_name" != "$level_name" ]]; then
  echo "World directory name '$world_name' does not match LEVEL_NAME '$level_name' in servers/$server." >&2
  echo "Copy the world to a directory named '$level_name', or change LEVEL_NAME." >&2
  exit 1
fi

deploy="bedrock-$server"
pvc="bedrock-data-$server"
helper="restore-$server"
target="/data/worlds/$world_name"

if $dry_run; then
  echo "Dry run: would copy '$world_dir' into PVC $NAMESPACE/$pvc at $target (force=$force)."
  exit 0
fi

kc() { kubectl -n "$NAMESPACE" "$@"; }

kc get pvc "$pvc" >/dev/null 2>&1 || {
  echo "PVC $pvc not found. Create it first:" >&2
  echo "  kubectl apply -k servers/$server -l app.kubernetes.io/component=storage" >&2
  exit 1
}

scaled_down=false
cleanup() {
  kc delete pod "$helper" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if $scaled_down; then
    echo "Scaling $deploy back to 1"
    kc scale deploy "$deploy" --replicas=1 >/dev/null || true
  fi
}
trap cleanup EXIT

# The helper can mount the RWO volume next to a running server: local-path is single-node.
kc delete pod "$helper" --ignore-not-found --wait=true >/dev/null
echo "Starting helper pod $helper"
kc run "$helper" --image="$HELPER_IMAGE" --restart=Never --overrides="$(cat <<JSON
{
  "spec": {
    "containers": [{
      "name": "$helper",
      "image": "$HELPER_IMAGE",
      "command": ["sleep", "3600"],
      "volumeMounts": [{"name": "data", "mountPath": "/data"}]
    }],
    "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "$pvc"}}]
  }
}
JSON
)"
kc wait --for=condition=Ready "pod/$helper" --timeout=180s

if kc exec "$helper" -- test -e "$target"; then
  if ! $force; then
    echo "A world already exists at $target. Rerun with --force to replace it." >&2
    exit 1
  fi
  echo "Will replace existing world at $target (--force)"
fi

if kc get deploy "$deploy" >/dev/null 2>&1; then
  echo "Scaling $deploy to 0"
  scaled_down=true
  kc scale deploy "$deploy" --replicas=0
  kc wait --for=delete pod -l "app.kubernetes.io/instance=$server,app.kubernetes.io/name=bedrock" --timeout=180s
fi

# Copy into a staging directory first, so a failed copy never touches the existing world.
staging="/data/worlds/.restore-tmp"
echo "Copying '$world_dir' to $staging"
kc exec "$helper" -- sh -c "rm -rf '$staging' /data/worlds/.restore-old && mkdir -p '$staging'"
COPYFILE_DISABLE=1 tar --no-mac-metadata -C "$(dirname "$world_dir")" -cf - "$world_name" |
  kc exec -i "$helper" -- tar -xf - -C "$staging"
kc exec "$helper" -- test -s "$staging/$world_name/level.dat"

echo "Moving world into place at $target"
kc exec "$helper" -- sh -c '
  set -e
  if [ -e "$1" ]; then mv "$1" /data/worlds/.restore-old; fi
  mv "$2" "$1"
  rm -rf /data/worlds/.restore-old "$3"
  chown -R "$(stat -c %u:%g /data)" /data/worlds
' sh "$target" "$staging/$world_name" "$staging"
echo "Restored. Contents:"
kc exec "$helper" -- ls -la "$target"

if ! $scaled_down; then
  echo "Done. Now deploy the server: kubectl apply -k servers/$server"
fi
