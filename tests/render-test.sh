#!/usr/bin/env bash
# Renders every server overlay and checks names, references and wiring.
# Needs kubectl with access to the cluster (for CRD discovery and server-side dry-run).
set -euo pipefail
cd "$(dirname "$0")/.."

NAMESPACE=minecraft-servers
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }

check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

shopt -s nullglob
servers=(servers/*/)
[[ ${#servers[@]} -gt 0 ]] || { echo "FAIL: no servers/* overlays found" >&2; exit 1; }

for dir in "${servers[@]}"; do
  name="$(basename "$dir")"
  echo "== $name"

  json="$(kubectl kustomize "$dir" | kubectl create --dry-run=client -o json -f - | jq -s "{items: .}")"
  item() { jq -c --arg k "$1" '[.items[] | select(.kind == $k)] | first // empty' <<<"$json"; }

  deploy="$(item Deployment)"; svc="$(item Service)"; pvc="$(item PersistentVolumeClaim)"; iru="$(item IngressRouteUDP)"

  check "$name deployment name" "bedrock-$name" "$(jq -r '.metadata.name' <<<"$deploy")"
  check "$name service name" "bedrock-$name" "$(jq -r '.metadata.name' <<<"$svc")"
  check "$name pvc name" "bedrock-data-$name" "$(jq -r '.metadata.name' <<<"$pvc")"
  check "$name ingressrouteudp name" "bedrock-$name" "$(jq -r '.metadata.name' <<<"$iru")"

  check "$name all in namespace" "$NAMESPACE" \
    "$(jq -r '[.items[].metadata.namespace] | unique | join(",")' <<<"$json")"

  check "$name claimName" "bedrock-data-$name" \
    "$(jq -r '.spec.template.spec.volumes[] | select(.name == "data") | .persistentVolumeClaim.claimName' <<<"$deploy")"
  check "$name selector instance" "$name" \
    "$(jq -r '.spec.selector.matchLabels["app.kubernetes.io/instance"]' <<<"$deploy")"
  check "$name service selector instance" "$name" \
    "$(jq -r '.spec.selector["app.kubernetes.io/instance"]' <<<"$svc")"
  check "$name strategy" "Recreate" "$(jq -r '.spec.strategy.type' <<<"$deploy")"

  env_of() { jq -r --arg n "$1" '.spec.template.spec.containers[0].env[] | select(.name == $n) | .value' <<<"$deploy"; }
  check "$name EULA" "TRUE" "$(env_of EULA)"
  check "$name VERSION" "LATEST" "$(env_of VERSION)"
  check "$name TRANSPORT" "raknet" "$(env_of TRANSPORT)"
  [[ -n "$(env_of LEVEL_NAME)" ]] && pass "$name LEVEL_NAME set" || fail "$name LEVEL_NAME not set"

  check "$name entrypoint" "mc-$name" "$(jq -r '.spec.entryPoints | join(",")' <<<"$iru")"
  check "$name route service" "bedrock-$name:19132" \
    "$(jq -r '.spec.routes[0].services[0] | "\(.name):\(.port)"' <<<"$iru")"

  check "$name storage selector" "persistentvolumeclaim/bedrock-data-$name" \
    "$(kubectl apply -k "$dir" -l app.kubernetes.io/component=storage --dry-run=client -o name)"

  if kubectl kustomize "$dir" | kubectl apply --dry-run=server -f - >/dev/null; then
    pass "$name server-side dry-run"
  else
    fail "$name server-side dry-run"
  fi

  if [[ -f cluster/traefik-helmchartconfig.yaml ]] && grep -Eq "^ +mc-$name:\$" cluster/traefik-helmchartconfig.yaml; then
    pass "$name has traefik port entry"
  else
    fail "$name has no 'mc-$name:' port in cluster/traefik-helmchartconfig.yaml"
  fi
done

if [[ -f cluster/traefik-helmchartconfig.yaml ]]; then
  if kubectl apply --dry-run=server -f cluster/traefik-helmchartconfig.yaml >/dev/null; then
    pass "traefik helmchartconfig server-side dry-run"
  else
    fail "traefik helmchartconfig server-side dry-run"
  fi
fi

if [[ $failures -gt 0 ]]; then echo "$failures check(s) failed" >&2; exit 1; fi
echo "all checks passed"
