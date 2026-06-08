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

# --------------------------------------------------------------------------- #
# Cell primitive (v0.6): init + scope.
# --------------------------------------------------------------------------- #
cells_dir="$OPENSOP_LOCAL_HOME/cells"
mkdir -p "$cells_dir/parent/child" "$cells_dir/no-cell"

# init in root cell (no ancestor)
( cd "$cells_dir/parent" && "$cli" init --json >/dev/null )
[ -f "$cells_dir/parent/.opensop/manifest.yaml" ] || { echo "FAIL: init didn't create manifest.yaml"; exit 1; }
[ -d "$cells_dir/parent/.opensop/runs" ]          || { echo "FAIL: init didn't create runs/"; exit 1; }
[ -d "$cells_dir/parent/.opensop/archive" ]       || { echo "FAIL: init didn't create archive/"; exit 1; }
[ -f "$cells_dir/parent/.opensop/lineage.json" ]  || { echo "FAIL: init didn't seed lineage.json"; exit 1; }
grep -q "^name: parent$"  "$cells_dir/parent/.opensop/manifest.yaml" || { echo "FAIL: parent manifest has wrong name"; exit 1; }
grep -q "^parent: null$"  "$cells_dir/parent/.opensop/manifest.yaml" || { echo "FAIL: root cell should have parent: null"; exit 1; }
echo "PASS: init — creates .opensop/ tree as root cell"

# init in child auto-detects parent
( cd "$cells_dir/parent/child" && "$cli" init --json >/dev/null )
grep -q "^name: child$"     "$cells_dir/parent/child/.opensop/manifest.yaml" || { echo "FAIL: child manifest has wrong name"; exit 1; }
grep -q "^parent: \.\./$"   "$cells_dir/parent/child/.opensop/manifest.yaml" || { echo "FAIL: child should auto-detect parent as '../'"; exit 1; }
echo "PASS: init — auto-detects parent cell from ancestor"

# init failure: already initialized
set +e
( cd "$cells_dir/parent" && "$cli" init --json >/dev/null 2>&1 ); irc=$?
set -e
[ "$irc" -ne 0 ] || { echo "FAIL: re-init of existing cell should exit non-zero"; exit 1; }
echo "PASS: init — refuses to clobber existing .opensop/"

# scope from inside child: shows child + parent (2 entries)
scope_json="$( cd "$cells_dir/parent/child" && "$cli" scope --json )"
[ "$(jq -r '. | length'      <<<"$scope_json")" = "2" ]      || { echo "FAIL: scope from child should have 2 entries"; exit 1; }
[ "$(jq -r '.[0].name'       <<<"$scope_json")" = "child" ]  || { echo "FAIL: scope[0].name should be 'child'"; exit 1; }
[ "$(jq -r '.[0].active'     <<<"$scope_json")" = "true" ]   || { echo "FAIL: scope[0] should be active"; exit 1; }
[ "$(jq -r '.[1].name'       <<<"$scope_json")" = "parent" ] || { echo "FAIL: scope[1].name should be 'parent'"; exit 1; }
[ "$(jq -r '.[1].active'     <<<"$scope_json")" = "false" ]  || { echo "FAIL: scope[1] should be inactive (ancestor)"; exit 1; }
echo "PASS: scope — walks ancestor chain from child to parent"

# scope from inside root: shows only root (1 entry)
scope_root_json="$( cd "$cells_dir/parent" && "$cli" scope --json )"
[ "$(jq -r '. | length' <<<"$scope_root_json")" = "1" ]       || { echo "FAIL: root cell scope should have 1 entry"; exit 1; }
[ "$(jq -r '.[0].name'  <<<"$scope_root_json")" = "parent" ]  || { echo "FAIL: root scope[0].name should be 'parent'"; exit 1; }
echo "PASS: scope — root cell shows only itself"

# scope failure: outside any cell
set +e
( cd "$cells_dir/no-cell" && "$cli" scope --json >/dev/null 2>&1 ); src=$?
set -e
[ "$src" -ne 0 ] || { echo "FAIL: scope outside any cell should exit non-zero"; exit 1; }
echo "PASS: scope — errors when not inside a cell"

# explicit --name + --parent
mkdir -p "$cells_dir/explicit"
( cd "$cells_dir/explicit" && "$cli" init --name custom-name --parent /some/abs/path --json >/dev/null )
grep -q "^name: custom-name$"         "$cells_dir/explicit/.opensop/manifest.yaml" || { echo "FAIL: explicit --name not honored"; exit 1; }
grep -q "^parent: /some/abs/path$"    "$cells_dir/explicit/.opensop/manifest.yaml" || { echo "FAIL: explicit --parent not honored"; exit 1; }
echo "PASS: init — explicit --name and --parent flags honored"

echo "ALL PASS"
