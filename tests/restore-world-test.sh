#!/usr/bin/env bash
# Tests restore-world.sh validation paths. Uses --dry-run; never touches the cluster.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRIPT=scripts/restore-world.sh
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0

expect() { # expect <description> <expected-exit> <expected-output-substring> -- <cmd...>
  local desc="$1" want_code="$2" want_out="$3"; shift 4
  local out code
  out="$("$@" 2>&1)"; code=$?
  if [[ $code -ne $want_code ]]; then
    echo "FAIL: $desc (exit $code, want $want_code): $out" >&2; failures=$((failures + 1))
  elif [[ "$out" != *"$want_out"* ]]; then
    echo "FAIL: $desc (output lacks '$want_out'): $out" >&2; failures=$((failures + 1))
  else
    echo "ok:   $desc"
  fi
}

make_world() { mkdir -p "$1/db"; touch "$1/level.dat"; }

make_world "$tmp/Daan"
make_world "$tmp/Wrong"
make_world "$tmp/with space/Daan"
mkdir -p "$tmp/NotAWorld"

expect "no args is usage error" 2 "Usage:" -- "$SCRIPT"
expect "unknown option" 2 "Unknown option" -- "$SCRIPT" --bogus daan "$tmp/Daan"
expect "unknown server" 1 "No overlay at servers/nope" -- "$SCRIPT" --dry-run nope "$tmp/Daan"
expect "not a world" 1 "Not a Bedrock world" -- "$SCRIPT" --dry-run daan "$tmp/NotAWorld"
expect "missing dir" 1 "Not a Bedrock world" -- "$SCRIPT" --dry-run daan "$tmp/missing"
expect "level name mismatch" 1 "does not match LEVEL_NAME 'Daan'" -- "$SCRIPT" --dry-run daan "$tmp/Wrong"
expect "valid dry run" 0 "would copy" -- "$SCRIPT" --dry-run daan "$tmp/Daan"
expect "valid dry run targets world dir" 0 "/data/worlds/Daan" -- "$SCRIPT" --dry-run daan "$tmp/Daan"
expect "trailing slash" 0 "/data/worlds/Daan" -- "$SCRIPT" --dry-run daan "$tmp/Daan/"
expect "path with space" 0 "/data/worlds/Daan" -- "$SCRIPT" --dry-run daan "$tmp/with space/Daan"

if [[ $failures -gt 0 ]]; then echo "$failures test(s) failed" >&2; exit 1; fi
echo "all tests passed"
