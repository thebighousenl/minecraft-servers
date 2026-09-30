#!/usr/bin/env bash
# Exercises restore-world.sh against the live cluster using a throwaway server "zz-rtest"
# whose container is busybox (not Bedrock). Creates and deletes its own Deployment and PVC.
set -uo pipefail
cd "$(dirname "$0")/.."

NAMESPACE=minecraft-servers
NAME=zz-rtest
SCRIPT=scripts/restore-world.sh
overlay="servers/$NAME"
tmp="$(mktemp -d)"
failures=0

cleanup() {
  kubectl delete -k "$overlay" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$NAMESPACE" delete pod "restore-$NAME" --ignore-not-found >/dev/null 2>&1
  rm -rf "$overlay"
  chmod -R u+rwx "$tmp" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

[[ ! -e "$overlay" ]] || { echo "FAIL: $overlay already exists" >&2; exit 1; }
mkdir -p "$overlay"
cat >"$overlay/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $NAMESPACE
nameSuffix: -$NAME
labels:
  - pairs:
      app.kubernetes.io/instance: $NAME
    includeSelectors: true
resources:
  - ../../base
patches:
  - path: patch.yaml
  - patch: |-
      \$patch: delete
      apiVersion: v1
      kind: Service
      metadata:
        name: bedrock
  - patch: |-
      \$patch: delete
      apiVersion: traefik.io/v1alpha1
      kind: IngressRouteUDP
      metadata:
        name: bedrock
EOF
cat >"$overlay/patch.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bedrock
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 1
      containers:
        - name: bedrock
          image: busybox:1.37
          imagePullPolicy: IfNotPresent
          command: ["sleep", "3600"]
          env:
            - name: LEVEL_NAME
              value: World
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
EOF

check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then echo "ok:   $1"; else
    echo "FAIL: $1 (expected '$2', got '$3')" >&2; failures=$((failures + 1)); fi
}
make_world() { # make_world <dir> <marker>
  mkdir -p "$1/db"; echo nbt >"$1/level.dat"; echo "$2" >"$1/marker"
}
kc() { kubectl -n "$NAMESPACE" "$@"; }
replicas() { kc get deploy "bedrock-$NAME" -o jsonpath='{.spec.replicas}'; }
marker() {
  kc rollout status deploy "bedrock-$NAME" --timeout=120s >/dev/null 2>&1
  kc exec "deploy/bedrock-$NAME" -- cat /data/worlds/World/marker 2>/dev/null
}
leftovers() { kc exec "deploy/bedrock-$NAME" -- ls -A /data/worlds | grep -v '^World$' | tr '\n' ' '; }

make_world "$tmp/v1/World" v1
make_world "$tmp/v2/World" v2
make_world "$tmp/broken/World" broken
echo secret >"$tmp/broken/World/db/unreadable"; chmod 000 "$tmp/broken/World/db/unreadable"

echo "== initial restore before the deployment exists"
kubectl apply -k "$overlay" -l app.kubernetes.io/component=storage >/dev/null
"$SCRIPT" "$NAME" "$tmp/v1/World" >"$tmp/log1" 2>&1
check "initial restore exits 0" 0 $?
kubectl apply -k "$overlay" >/dev/null
check "deployed world is v1" v1 "$(marker)"

echo "== restore without --force onto an existing world"
"$SCRIPT" "$NAME" "$tmp/v2/World" >"$tmp/log2" 2>&1
check "refuses without --force" 1 $?
grep -q "already exists" "$tmp/log2" && echo "ok:   says already exists" ||
  { echo "FAIL: no 'already exists' message: $(cat "$tmp/log2")" >&2; failures=$((failures + 1)); }
check "deployment left at 1 replica after refusal" 1 "$(replicas)"
check "world still v1 after refusal" v1 "$(marker)"

echo "== --force with a copy that fails midway"
"$SCRIPT" --force "$NAME" "$tmp/broken/World" >"$tmp/log3" 2>&1
code=$?
[[ $code -ne 0 ]] && echo "ok:   failed copy exits non-zero" ||
  { echo "FAIL: failed copy exited 0" >&2; failures=$((failures + 1)); }
check "deployment scaled back to 1 after failed copy" 1 "$(replicas)"
check "old world kept after failed copy" v1 "$(marker)"

echo "== --force with a good world"
"$SCRIPT" --force "$NAME" "$tmp/v2/World" >"$tmp/log4" 2>&1
check "forced restore exits 0" 0 $?
check "deployment at 1 replica after forced restore" 1 "$(replicas)"
check "world replaced with v2" v2 "$(marker)"
check "no leftover temp dirs in /data/worlds" "" "$(leftovers)"

if [[ $failures -gt 0 ]]; then
  echo "$failures check(s) failed" >&2
  for f in "$tmp"/log*; do echo "--- $f" >&2; cat "$f" >&2; done
  exit 1
fi
echo "all checks passed"
