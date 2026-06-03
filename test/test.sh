#!/usr/bin/env bash
# Golden test for the --local backend: run the greet example through the CLI,
# then inspect it via `opensop show`. Asserts context threading, receipts, and
# no step-output leak. Requires bash + jq (no server, no curl).
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cli="$here/bin/opensop"
export OPENSOP_LOCAL_HOME="$(mktemp -d)"
trap 'rm -rf "$OPENSOP_LOCAL_HOME"' EXIT

manifest="$("$cli" run "$here/examples/greet.sop.json" --local --input name=opensop --json)"
run_id="$(jq -r '.run_id' <<<"$manifest")"
status="$(jq -r '.status' <<<"$manifest")"
echo "run $run_id -> $status"
[ "$status" = "completed" ] || { echo "FAIL: run not completed"; exit 1; }

# inspect via the CLI's own `show` (exercises the local inspection path too)
show="$("$cli" show "$run_id" --json)"
render="$(jq -r '.steps[] | select(.step=="render") | .output.stdout' <<<"$show")"
echo "render -> $render"
echo "$render" | grep -q "hello, opensop" || { echo "FAIL: expected greeting not rendered"; exit 1; }

jq -e '.steps[] | select(.step=="build"  and .status=="completed")' <<<"$show" >/dev/null || { echo "FAIL: build receipt missing/failed"; exit 1; }
jq -e '.steps[] | select(.step=="render" and .status=="completed")' <<<"$show" >/dev/null || { echo "FAIL: render receipt missing/failed"; exit 1; }
# render must NOT have leaked the build step's output (regression guard)
jq -e '.steps[] | select(.step=="render") | .output | has("greeting")' <<<"$show" >/dev/null 2>&1 && { echo "FAIL: render leaked build output"; exit 1; }

echo "PASS: opensop run --local + show — 2 steps, context threaded, receipts written, no leak"
