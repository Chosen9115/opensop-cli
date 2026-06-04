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

# --------------------------------------------------------------------------- #
# Failure path (regression guard for the set -e abort bug): a failing step must
# NOT abort the CLI silently. It must write a "failed" receipt, finalize the
# manifest as "failed", and exit non-zero. Without the `|| rc=$?` guard, `set -e`
# aborts at the step substitution and none of this happens.
# --------------------------------------------------------------------------- #
fail_proc="$OPENSOP_LOCAL_HOME/fail.sop.json"
cat > "$fail_proc" <<'JSON'
{ "name": "failtest", "inputs": {},
  "steps": [
    { "id": "boom",  "type": "shell", "run": "echo boom-stderr >&2; echo oops; exit 3" },
    { "id": "after", "type": "shell", "run": "echo should-not-run" }
  ] }
JSON
set +e
fm="$("$cli" run "$fail_proc" --local --json)"; frc=$?
set -e
[ "$frc" -ne 0 ] || { echo "FAIL: failing run should exit non-zero, got $frc"; exit 1; }
[ "$(jq -r '.status' <<<"$fm")" = "failed" ] || { echo "FAIL: manifest not 'failed'"; exit 1; }
frun="$(jq -r '.run_id' <<<"$fm")"
fshow="$("$cli" show "$frun" --json)"
jq -e '.steps[] | select(.step=="boom" and .status=="failed" and .exit_code==3)' <<<"$fshow" >/dev/null || { echo "FAIL: boom receipt missing/not failed"; exit 1; }
jq -e '.steps[] | select(.step=="after")' <<<"$fshow" >/dev/null && { echo "FAIL: 'after' ran despite prior failure (no continue_on_error)"; exit 1; }
jq -e '.steps[] | select(.step=="boom") | .stderr | test("boom-stderr")' <<<"$fshow" >/dev/null || { echo "FAIL: boom stderr not captured in receipt"; exit 1; }
echo "PASS: failing step — non-zero exit, 'failed' receipt + manifest, stderr captured, halted"

# --------------------------------------------------------------------------- #
# continue_on_error: a failed step with continue_on_error:true must NOT halt the
# run — the later step runs and the run completes.
# --------------------------------------------------------------------------- #
coe_proc="$OPENSOP_LOCAL_HOME/coe.sop.json"
cat > "$coe_proc" <<'JSON'
{ "name": "coetest", "inputs": {},
  "steps": [
    { "id": "boom",  "type": "shell", "continue_on_error": true, "run": "echo oops; exit 3" },
    { "id": "after", "type": "shell", "run": "echo reached" }
  ] }
JSON
cm="$("$cli" run "$coe_proc" --local --json)"
[ "$(jq -r '.status' <<<"$cm")" = "completed" ] || { echo "FAIL: continue_on_error run should complete"; exit 1; }
crun="$(jq -r '.run_id' <<<"$cm")"
cshow="$("$cli" show "$crun" --json)"
jq -e '.steps[] | select(.step=="boom"  and .status=="failed")'    <<<"$cshow" >/dev/null || { echo "FAIL: boom should be recorded failed"; exit 1; }
jq -e '.steps[] | select(.step=="after" and .status=="completed")' <<<"$cshow" >/dev/null || { echo "FAIL: 'after' should have run under continue_on_error"; exit 1; }
echo "PASS: continue_on_error — failed step recorded, later step still runs, run completes"

# --------------------------------------------------------------------------- #
# Empty/invalid process guards.
# --------------------------------------------------------------------------- #
empty_proc="$OPENSOP_LOCAL_HOME/empty.sop.json"
echo '{ "name": "empty", "steps": [] }' > "$empty_proc"
set +e; "$cli" run "$empty_proc" --local --json >/dev/null 2>&1; erc=$?; set -e
[ "$erc" -ne 0 ] || { echo "FAIL: empty-steps process should be rejected"; exit 1; }
echo "PASS: empty-steps process rejected"

echo "ALL PASS"
