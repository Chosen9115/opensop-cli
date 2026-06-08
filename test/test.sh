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

# --------------------------------------------------------------------------- #
# Lineage primitives (v0.6): annotate + lineage.
# --------------------------------------------------------------------------- #
ln_dir="$OPENSOP_LOCAL_HOME/lineage"
mkdir -p "$ln_dir/c1"
( cd "$ln_dir/c1" && "$cli" init --json >/dev/null )

# annotate creates a lineage entry for a previously-unknown skill
ann_evt="$( cd "$ln_dir/c1" && "$cli" annotate skill-a promote '{"to":"m2"}' --json )"
[ "$(jq -r '.type' <<<"$ann_evt")" = "promote" ]      || { echo "FAIL: annotate output event.type wrong"; exit 1; }
[ "$(jq -r '.data.to' <<<"$ann_evt")" = "m2" ]        || { echo "FAIL: annotate output event.data.to wrong"; exit 1; }
[ -n "$(jq -r '.at' <<<"$ann_evt")" ]                  || { echo "FAIL: annotate output missing .at timestamp"; exit 1; }
on_disk="$(cat "$ln_dir/c1/.opensop/lineage.json")"
[ "$(jq -r '."skill-a".logical_name' <<<"$on_disk")" = "skill-a" ]    || { echo "FAIL: skill-a not stored in lineage.json"; exit 1; }
[ "$(jq -r '."skill-a".history | length' <<<"$on_disk")" = "1" ]      || { echo "FAIL: skill-a should have 1 history event"; exit 1; }
echo "PASS: annotate — creates lineage entry + appends first event"

# annotate appends to an existing entry (history grows; both events preserved)
( cd "$ln_dir/c1" && "$cli" annotate skill-a promote '{"to":"m3"}' --json >/dev/null )
( cd "$ln_dir/c1" && "$cli" annotate skill-a bless   '{"by":"human"}' --json >/dev/null )
on_disk="$(cat "$ln_dir/c1/.opensop/lineage.json")"
[ "$(jq -r '."skill-a".history | length' <<<"$on_disk")" = "3" ]        || { echo "FAIL: skill-a should have 3 history events"; exit 1; }
[ "$(jq -r '."skill-a".history[2].type' <<<"$on_disk")" = "bless" ]     || { echo "FAIL: last event type wrong"; exit 1; }
[ "$(jq -r '."skill-a".history[0].data.to' <<<"$on_disk")" = "m2" ]     || { echo "FAIL: first event data lost"; exit 1; }
echo "PASS: annotate — appends to existing entry, preserves order + prior events"

# lineage retrieves the entry (json mode round-trips faithfully)
lin_json="$( cd "$ln_dir/c1" && "$cli" lineage skill-a --json )"
[ "$(jq -r '.logical_name'        <<<"$lin_json")" = "skill-a" ] || { echo "FAIL: lineage logical_name wrong"; exit 1; }
[ "$(jq -r '.history | length'    <<<"$lin_json")" = "3" ]       || { echo "FAIL: lineage history count wrong"; exit 1; }
[ "$(jq -r '.status'              <<<"$lin_json")" = "" ]        || { echo "FAIL: lineage status should be empty by default"; exit 1; }
[ "$(jq -r '.forked_from'         <<<"$lin_json")" = "null" ]    || { echo "FAIL: lineage forked_from should be null"; exit 1; }
echo "PASS: lineage — returns full entry with correct shape"

# lineage on never-annotated skill returns default empty entry (not an error)
lin_empty="$( cd "$ln_dir/c1" && "$cli" lineage never-touched --json )"
[ "$(jq -r '.logical_name'     <<<"$lin_empty")" = "never-touched" ] || { echo "FAIL: lineage on unknown skill should still set logical_name"; exit 1; }
[ "$(jq -r '.history | length' <<<"$lin_empty")" = "0" ]             || { echo "FAIL: lineage on unknown skill should have empty history"; exit 1; }
echo "PASS: lineage — returns empty default for never-annotated skill"

# negative: invalid JSON data
set +e
( cd "$ln_dir/c1" && "$cli" annotate skill-a promote 'this-is-not-json' --json >/dev/null 2>&1 ); arc=$?
set -e
[ "$arc" -ne 0 ] || { echo "FAIL: annotate with invalid JSON should exit non-zero"; exit 1; }
echo "PASS: annotate — rejects invalid JSON data"

# negative: missing args (annotate needs skill + type + data)
set +e
( cd "$ln_dir/c1" && "$cli" annotate skill-a --json >/dev/null 2>&1 ); brc=$?
set -e
[ "$brc" -ne 0 ] || { echo "FAIL: annotate with missing args should exit non-zero"; exit 1; }
echo "PASS: annotate — rejects missing args"

# negative: annotate outside any cell
set +e
( cd "$OPENSOP_LOCAL_HOME" && "$cli" annotate x y '{}' --json >/dev/null 2>&1 ); crc=$?
set -e
[ "$crc" -ne 0 ] || { echo "FAIL: annotate outside any cell should exit non-zero"; exit 1; }
echo "PASS: annotate — errors when not inside a cell"

# negative: lineage outside any cell
set +e
( cd "$OPENSOP_LOCAL_HOME" && "$cli" lineage anything --json >/dev/null 2>&1 ); drc=$?
set -e
[ "$drc" -ne 0 ] || { echo "FAIL: lineage outside any cell should exit non-zero"; exit 1; }
echo "PASS: lineage — errors when not inside a cell"

# corruption guard: bad JSON in lineage.json triggers invalid_json error
echo "not { valid : json" > "$ln_dir/c1/.opensop/lineage.json"
set +e
( cd "$ln_dir/c1" && "$cli" lineage skill-a --json >/dev/null 2>&1 ); erc=$?
set -e
[ "$erc" -ne 0 ] || { echo "FAIL: lineage on corrupt lineage.json should exit non-zero"; exit 1; }
echo "PASS: lineage — refuses to read a corrupt lineage.json"

# --------------------------------------------------------------------------- #
# --pretty flag overrides auto-mode regardless of TTY (regression for the
# subshell-capture bug that made cmd_init/scope/annotate/lineage always
# emit JSON because _resolve_output_mode was called via $() which made
# is_tty see a pipe instead of the terminal).
# --------------------------------------------------------------------------- #
mkdir -p "$cells_dir/pretty-out"
pretty_init="$( cd "$cells_dir/pretty-out" && "$cli" --pretty init )"
# Must NOT start with '{' (which would mean JSON output)
[[ "${pretty_init:0:1}" != "{" ]]                                   || { echo "FAIL: init --pretty produced JSON"; exit 1; }
[[ "$pretty_init" == *"initialized cell"* ]]                        || { echo "FAIL: init --pretty missing 'initialized cell'"; exit 1; }
echo "PASS: init --pretty produces prose (not JSON) even from non-TTY caller"

pretty_scope="$( cd "$cells_dir/pretty-out" && "$cli" --pretty scope )"
[[ "${pretty_scope:0:1}" != "[" ]]                                  || { echo "FAIL: scope --pretty produced JSON array"; exit 1; }
[[ "$pretty_scope" == *"active cell"* ]]                            || { echo "FAIL: scope --pretty missing 'active cell'"; exit 1; }
echo "PASS: scope --pretty produces prose (not JSON) even from non-TTY caller"

pretty_ann="$( cd "$cells_dir/pretty-out" && "$cli" --pretty annotate s promote '{"x":1}' )"
[[ "${pretty_ann:0:1}" != "{" ]]                                    || { echo "FAIL: annotate --pretty produced JSON event"; exit 1; }
[[ "$pretty_ann" == *"annotated"* ]]                                || { echo "FAIL: annotate --pretty missing 'annotated'"; exit 1; }
echo "PASS: annotate --pretty produces prose (not JSON) even from non-TTY caller"

pretty_lin="$( cd "$cells_dir/pretty-out" && "$cli" --pretty lineage s )"
[[ "${pretty_lin:0:1}" != "{" ]]                                    || { echo "FAIL: lineage --pretty produced JSON entry"; exit 1; }
[[ "$pretty_lin" == *"lineage:"* ]]                                 || { echo "FAIL: lineage --pretty missing 'lineage:' header"; exit 1; }
echo "PASS: lineage --pretty produces prose (not JSON) even from non-TTY caller"

# --------------------------------------------------------------------------- #
# Per-cell OPENSOP_LOCAL_HOME default (v0.6 PR 3): when cwd is inside a cell
# and the user did NOT explicitly set OPENSOP_LOCAL_HOME, local-mode receipts
# land in the cell's .opensop/runs/ — not in the global ~/.opensop-local.
# Explicit env override still wins.
# --------------------------------------------------------------------------- #
runs_cell="$OPENSOP_LOCAL_HOME/runs-cell"
mkdir -p "$runs_cell"
( cd "$runs_cell" && env -u OPENSOP_LOCAL_HOME "$cli" init --json >/dev/null )

# (1) Inside cell, no explicit OPENSOP_LOCAL_HOME → receipt lands in cell
m1=$( cd "$runs_cell" && env -u OPENSOP_LOCAL_HOME "$cli" run "$here/examples/greet.sop.json" --local --input name=cellrun --json )
rid1=$(jq -r '.run_id' <<<"$m1")
[ "$(jq -r '.status' <<<"$m1")" = "completed" ]      || { echo "FAIL: cell-aware run didn't complete"; exit 1; }
[ -d "$runs_cell/.opensop/runs/$rid1" ]              || { echo "FAIL: receipt not in cell's .opensop/runs/"; exit 1; }
[ ! -d "$OPENSOP_LOCAL_HOME/runs/$rid1" ]            || { echo "FAIL: receipt leaked to test's OPENSOP_LOCAL_HOME"; exit 1; }
echo "PASS: runs — inside cell, default OPENSOP_LOCAL_HOME → receipt in cell's .opensop/runs/"

# (2) Inside cell, explicit OPENSOP_LOCAL_HOME → that path wins over cell
override_home="$(mktemp -d)"
m2=$( cd "$runs_cell" && OPENSOP_LOCAL_HOME="$override_home" "$cli" run "$here/examples/greet.sop.json" --local --input name=override --json )
rid2=$(jq -r '.run_id' <<<"$m2")
[ -d "$override_home/runs/$rid2" ]                    || { echo "FAIL: explicit override not honored"; exit 1; }
[ ! -d "$runs_cell/.opensop/runs/$rid2" ]             || { echo "FAIL: receipt leaked to cell despite explicit override"; exit 1; }
rm -rf "$override_home"
echo "PASS: runs — explicit OPENSOP_LOCAL_HOME wins over cell-aware default"

# (3) `opensop runs` inside the cell sees the cell's receipts (not the global)
runs_list=$( cd "$runs_cell" && env -u OPENSOP_LOCAL_HOME "$cli" runs )
[[ "$runs_list" == *"$rid1"* ]]                       || { echo "FAIL: 'opensop runs' inside cell didn't show cell's run"; exit 1; }
[[ "$runs_list" != *"$rid2"* ]]                       || { echo "FAIL: 'opensop runs' inside cell shouldn't see override's run"; exit 1; }
echo "PASS: runs — 'opensop runs' inside cell reads the cell's receipts only"

# (4) Corrupt cell: .opensop/ directory without manifest.yaml is NOT a cell
fake_cell="$OPENSOP_LOCAL_HOME/fake-cell"
mkdir -p "$fake_cell/.opensop"
set +e
( cd "$fake_cell" && env -u OPENSOP_LOCAL_HOME "$cli" scope --json >/dev/null 2>&1 ); fcrc=$?
set -e
[ "$fcrc" -ne 0 ] || { echo "FAIL: cwd with .opensop/ but no manifest.yaml should NOT be recognized as a cell"; exit 1; }
echo "PASS: cells — .opensop/ without manifest.yaml is correctly ignored (not a cell)"

# (5) Nested cells: run from inner cell lands receipts in inner, not in outer
mkdir -p "$OPENSOP_LOCAL_HOME/nested/outer/inner"
( cd "$OPENSOP_LOCAL_HOME/nested/outer"       && env -u OPENSOP_LOCAL_HOME "$cli" init --json >/dev/null )
( cd "$OPENSOP_LOCAL_HOME/nested/outer/inner" && env -u OPENSOP_LOCAL_HOME "$cli" init --json >/dev/null )

m_inner=$( cd "$OPENSOP_LOCAL_HOME/nested/outer/inner" && env -u OPENSOP_LOCAL_HOME "$cli" run "$here/examples/greet.sop.json" --local --input name=nested-inner --json )
rid_inner=$(jq -r '.run_id' <<<"$m_inner")
[ -d "$OPENSOP_LOCAL_HOME/nested/outer/inner/.opensop/runs/$rid_inner" ] || { echo "FAIL: nested inner-cell run receipt not in inner"; exit 1; }
[ ! -d "$OPENSOP_LOCAL_HOME/nested/outer/.opensop/runs/$rid_inner" ]     || { echo "FAIL: nested inner-cell run receipt leaked to outer"; exit 1; }
echo "PASS: runs — nested cells route receipts to the innermost cell, not ancestors"

# --------------------------------------------------------------------------- #
# Name resolution across the cell chain (v0.6 PR 4):
#   * `opensop list` walks active cell + ancestors, tagging each with [cell-name]
#   * `opensop run <name>` resolves bare name → processes/<name>.sop.json
#     nearest-wins; explicit paths still work for backwards compat
# --------------------------------------------------------------------------- #
nr_org="$OPENSOP_LOCAL_HOME/nr-org"
nr_team="$nr_org/team"
mkdir -p "$nr_team"
( cd "$nr_org"  && env -u OPENSOP_LOCAL_HOME "$cli" init --json >/dev/null )
( cd "$nr_team" && env -u OPENSOP_LOCAL_HOME "$cli" init --json >/dev/null )

# Inline skill at the org level — uses a `shell` step so it has no file deps
mkdir -p "$nr_org/processes"
cat > "$nr_org/processes/say-hi.sop.json" <<'JSON'
{ "name": "say-hi", "inputs": {},
  "steps": [ { "id": "hi", "type": "shell", "run": "echo hi" } ] }
JSON

# (1) list from inside team walks up — should find org's say-hi tagged [nr-org]
list_out=$( cd "$nr_team" && env -u OPENSOP_LOCAL_HOME "$cli" list --local )
[[ "$list_out" == *"[nr-org]"*"say-hi"* ]] || { echo "FAIL: list inside team didn't surface org's say-hi tagged [nr-org]"; echo "  got: $list_out"; exit 1; }
echo "PASS: list — inside cell, walks active + ancestor processes/ tagged with [cell-name]"

# (2) list with explicit dir arg uses the original find-based behavior (no [cell] tags)
explicit_dir_list=$( "$cli" list --local "$nr_org" )
[[ "$explicit_dir_list" == *"say-hi"* ]]   || { echo "FAIL: explicit-dir list didn't find say-hi"; exit 1; }
[[ "$explicit_dir_list" != *"[nr-org]"* ]] || { echo "FAIL: explicit-dir list shouldn't add [cell-name] tag (backwards compat)"; exit 1; }
echo "PASS: list — explicit dir arg uses original find behavior (no cell tag)"

# (3) run by NAME from team resolves to org's say-hi (parent cell)
m_nr=$( cd "$nr_team" && env -u OPENSOP_LOCAL_HOME "$cli" run say-hi --local --json )
[ "$(jq -r '.status'       <<<"$m_nr")" = "completed" ]              || { echo "FAIL: name-resolved run didn't complete"; exit 1; }
[ "$(jq -r '.process_file' <<<"$m_nr")" = "$nr_org/processes/say-hi.sop.json" ] || { echo "FAIL: name resolved to wrong file"; exit 1; }
echo "PASS: run — bare name resolves to ancestor cell's processes/<name>.sop.json"

# (4) nearest-wins: a same-name skill in team's processes/ shadows org's
mkdir -p "$nr_team/processes"
cat > "$nr_team/processes/say-hi.sop.json" <<'JSON'
{ "name": "say-hi", "inputs": {},
  "steps": [ { "id": "hi-team", "type": "shell", "run": "echo hi-from-team" } ] }
JSON
m_near=$( cd "$nr_team" && env -u OPENSOP_LOCAL_HOME "$cli" run say-hi --local --json )
[ "$(jq -r '.process_file' <<<"$m_near")" = "$nr_team/processes/say-hi.sop.json" ] || { echo "FAIL: nearest-wins didn't pick team's say-hi"; exit 1; }
echo "PASS: run — nearest-wins resolution (team's say-hi shadows org's)"

# (5) explicit path still works (backwards compat)
m_path=$( cd "$nr_team" && env -u OPENSOP_LOCAL_HOME "$cli" run "$nr_org/processes/say-hi.sop.json" --local --json )
[ "$(jq -r '.process_file' <<<"$m_path")" = "$nr_org/processes/say-hi.sop.json" ] || { echo "FAIL: explicit path not honored"; exit 1; }
echo "PASS: run — explicit path still works (backwards compat for paths containing / or .sop.json)"

# (6) run by non-existent name errors helpfully
set +e
( cd "$nr_team" && env -u OPENSOP_LOCAL_HOME "$cli" run no-such-skill --local --json >/dev/null 2>&1 ); nrrc=$?
set -e
[ "$nrrc" -ne 0 ] || { echo "FAIL: run with non-existent name should exit non-zero"; exit 1; }
echo "PASS: run — non-existent name errors cleanly"

# (7) run by name when NOT in any cell — also errors (nothing to resolve against)
set +e
( cd "$OPENSOP_LOCAL_HOME" && env -u OPENSOP_LOCAL_HOME "$cli" run say-hi --local --json >/dev/null 2>&1 ); ncrc=$?
set -e
[ "$ncrc" -ne 0 ] || { echo "FAIL: run by name outside any cell should exit non-zero"; exit 1; }
echo "PASS: run — bare name outside any cell errors (no cell chain to search)"

# --------------------------------------------------------------------------- #
# Fork mechanic (v0.6 PR 5): materialize an ancestor's skill in the active
# cell + record a lineage entry with forked_from snapshot of parent state.
# --------------------------------------------------------------------------- #
fk_org="$OPENSOP_LOCAL_HOME/fk-org"
fk_team="$fk_org/team"
mkdir -p "$fk_team"
( cd "$fk_org"  && env -u OPENSOP_LOCAL_HOME "$cli" init --json >/dev/null )
( cd "$fk_team" && env -u OPENSOP_LOCAL_HOME "$cli" init --json >/dev/null )

mkdir -p "$fk_org/processes"
cat > "$fk_org/processes/greet-skill.sop.json" <<'JSON'
{ "name": "greet-skill", "inputs": {}, "steps": [{"id":"x","type":"shell","run":"echo greet"}] }
JSON

# Seed parent's lineage with a non-trivial policy state to test snapshotting
fk_lineage="$fk_org/.opensop/lineage.json"
jq --arg name "greet-skill" \
   '.[$name] = {logical_name:$name, forked_from:null, history:[{at:"2026-01-01T00:00:00Z",type:"promote",data:{to:"m3"}}], status:"mineralized", metadata:{m:"3.247"}}' \
   "$fk_lineage" > "$fk_lineage.tmp" && mv "$fk_lineage.tmp" "$fk_lineage"

# (1) Fork from team auto-detects org as the source (walk-up)
fork_out=$( cd "$fk_team" && env -u OPENSOP_LOCAL_HOME "$cli" fork greet-skill --json )
[ "$(jq -r '.ok'             <<<"$fork_out")" = "true" ]                       || { echo "FAIL: fork ok!=true"; exit 1; }
[ "$(jq -r '.source_cell'    <<<"$fork_out")" = "$fk_org" ]                    || { echo "FAIL: fork source_cell wrong"; exit 1; }
[ "$(jq -r '.dest_file'      <<<"$fork_out")" = "$fk_team/processes/greet-skill.sop.json" ] || { echo "FAIL: fork dest_file wrong"; exit 1; }
[ -f "$fk_team/processes/greet-skill.sop.json" ]                               || { echo "FAIL: file not copied to child cell"; exit 1; }
echo "PASS: fork — copies file from ancestor's processes/ into active cell"

# (2) Child's lineage entry has forked_from with the parent's policy snapshot
child_lineage="$fk_team/.opensop/lineage.json"
[ "$(jq -r '."greet-skill".forked_from.cell' "$child_lineage")"                = "$fk_org" ]    || { echo "FAIL: forked_from.cell wrong"; exit 1; }
[ -n "$(jq -r '."greet-skill".forked_from.forked_at' "$child_lineage")" ]                       || { echo "FAIL: forked_at missing"; exit 1; }
[ "$(jq -r '."greet-skill".forked_from.snapshot.status' "$child_lineage")"      = "mineralized" ] || { echo "FAIL: snapshot.status wrong"; exit 1; }
[ "$(jq -r '."greet-skill".forked_from.snapshot.metadata.m' "$child_lineage")"  = "3.247" ]       || { echo "FAIL: snapshot.metadata.m wrong"; exit 1; }
echo "PASS: fork — child's forked_from captures parent's status + metadata as snapshot"

# (3) Child's live status + metadata are empty (substrate is policy-neutral; let policy set them)
[ "$(jq -r '."greet-skill".status'           "$child_lineage")" = "" ]  || { echo "FAIL: child's live status should be empty after fork"; exit 1; }
[ "$(jq -c '."greet-skill".metadata'         "$child_lineage")" = "{}" ] || { echo "FAIL: child's live metadata should be empty after fork"; exit 1; }
[ "$(jq -r '."greet-skill".history | length' "$child_lineage")" = "0" ]  || { echo "FAIL: child's history should start empty"; exit 1; }
echo "PASS: fork — child's live status/metadata/history start empty (policy populates)"

# (4) Parent's lineage is NOT modified by the fork
[ "$(jq -r '."greet-skill".status'     "$fk_lineage")" = "mineralized" ] || { echo "FAIL: parent's status was modified by fork"; exit 1; }
[ "$(jq -r '."greet-skill".metadata.m' "$fk_lineage")" = "3.247" ]       || { echo "FAIL: parent's metadata was modified by fork"; exit 1; }
echo "PASS: fork — parent's lineage is untouched"

# (5) Refuses to overwrite an existing skill in the active cell
set +e
( cd "$fk_team" && env -u OPENSOP_LOCAL_HOME "$cli" fork greet-skill --json >/dev/null 2>&1 ); fk_rc1=$?
set -e
[ "$fk_rc1" -ne 0 ] || { echo "FAIL: re-fork into a cell that already has the skill should exit non-zero"; exit 1; }
echo "PASS: fork — refuses to overwrite an existing skill in active cell"

# (6) Errors on non-existent skill
set +e
( cd "$fk_team" && env -u OPENSOP_LOCAL_HOME "$cli" fork no-such-skill --json >/dev/null 2>&1 ); fk_rc2=$?
set -e
[ "$fk_rc2" -ne 0 ] || { echo "FAIL: fork of non-existent skill should exit non-zero"; exit 1; }
echo "PASS: fork — errors when skill not found in any ancestor"

# (7) Outside any cell — errors (need a cell to fork into)
set +e
( cd "$OPENSOP_LOCAL_HOME" && env -u OPENSOP_LOCAL_HOME "$cli" fork greet-skill --json >/dev/null 2>&1 ); fk_rc3=$?
set -e
[ "$fk_rc3" -ne 0 ] || { echo "FAIL: fork outside any cell should exit non-zero"; exit 1; }
echo "PASS: fork — errors when not inside a cell"

# (8) --from <path> override resolves explicitly
mkdir -p "$OPENSOP_LOCAL_HOME/fk-isolated"
( cd "$OPENSOP_LOCAL_HOME/fk-isolated" && env -u OPENSOP_LOCAL_HOME "$cli" init --json >/dev/null )
mkdir -p "$OPENSOP_LOCAL_HOME/fk-isolated/processes"
cat > "$OPENSOP_LOCAL_HOME/fk-isolated/processes/explicit-src.sop.json" <<'JSON'
{ "name": "explicit-src", "inputs": {}, "steps": [{"id":"x","type":"shell","run":"echo ok"}] }
JSON
fk_explicit=$( cd "$fk_team" && env -u OPENSOP_LOCAL_HOME "$cli" fork explicit-src --from "$OPENSOP_LOCAL_HOME/fk-isolated" --json )
[ "$(jq -r '.source_cell' <<<"$fk_explicit")" = "$OPENSOP_LOCAL_HOME/fk-isolated" ] || { echo "FAIL: --from override not honored"; exit 1; }
[ -f "$fk_team/processes/explicit-src.sop.json" ]                                   || { echo "FAIL: --from fork didn't copy file"; exit 1; }
echo "PASS: fork — --from <cell> override copies from a non-ancestor cell"

# (9) Integration: after fork, name-resolution (PR #9) finds child's copy first
m_resolved=$( cd "$fk_team" && env -u OPENSOP_LOCAL_HOME "$cli" run greet-skill --local --json )
[ "$(jq -r '.process_file' <<<"$m_resolved")" = "$fk_team/processes/greet-skill.sop.json" ] || { echo "FAIL: name resolution didn't pick child's forked copy"; exit 1; }
echo "PASS: fork + run — forked skill is nearest-wins for name resolution"

# --------------------------------------------------------------------------- #
# Executor field (v0.6 PR 6): optional `executor: internal|external` on steps.
# Field is validated up-front (parse_error on invalid value), defaults per type
# when absent, and is recorded in each step's audit entry.
# --------------------------------------------------------------------------- #
ex_dir="$OPENSOP_LOCAL_HOME/exec"
mkdir -p "$ex_dir"

# (1) default (no executor) — shell step records executor:external
cat > "$ex_dir/def.sop.json" <<'JSON'
{ "name": "def", "inputs": {},
  "steps": [ { "id": "s1", "type": "shell", "run": "echo ok" } ] }
JSON
m_def=$("$cli" run "$ex_dir/def.sop.json" --local --json)
rid_def=$(jq -r .run_id <<<"$m_def")
[ "$(jq -r '.executor' "$OPENSOP_LOCAL_HOME/runs/$rid_def/audit.jsonl")" = "external" ] || { echo "FAIL: shell-step default executor should be 'external'"; exit 1; }
echo "PASS: executor — shell step defaults to external in receipts"

# (2) noop step records executor:internal by default
cat > "$ex_dir/noop.sop.json" <<'JSON'
{ "name": "noop-test", "inputs": {},
  "steps": [ { "id": "s1", "type": "noop" } ] }
JSON
m_noop=$("$cli" run "$ex_dir/noop.sop.json" --local --json)
rid_noop=$(jq -r .run_id <<<"$m_noop")
[ "$(jq -r '.executor' "$OPENSOP_LOCAL_HOME/runs/$rid_noop/audit.jsonl")" = "internal" ] || { echo "FAIL: noop step default executor should be 'internal'"; exit 1; }
echo "PASS: executor — noop step defaults to internal in receipts"

# (3) explicit executor: internal honored even on shell step (purely metadata)
cat > "$ex_dir/exp-int.sop.json" <<'JSON'
{ "name": "exp-int", "inputs": {},
  "steps": [ { "id": "s1", "type": "shell", "executor": "internal", "run": "echo ok" } ] }
JSON
m_ei=$("$cli" run "$ex_dir/exp-int.sop.json" --local --json)
rid_ei=$(jq -r .run_id <<<"$m_ei")
[ "$(jq -r '.executor' "$OPENSOP_LOCAL_HOME/runs/$rid_ei/audit.jsonl")" = "internal" ] || { echo "FAIL: explicit executor:internal not recorded"; exit 1; }
echo "PASS: executor — explicit 'internal' is honored and recorded"

# (4) explicit executor: external honored
cat > "$ex_dir/exp-ext.sop.json" <<'JSON'
{ "name": "exp-ext", "inputs": {},
  "steps": [ { "id": "s1", "type": "shell", "executor": "external", "run": "echo ok" } ] }
JSON
m_ee=$("$cli" run "$ex_dir/exp-ext.sop.json" --local --json)
rid_ee=$(jq -r .run_id <<<"$m_ee")
[ "$(jq -r '.executor' "$OPENSOP_LOCAL_HOME/runs/$rid_ee/audit.jsonl")" = "external" ] || { echo "FAIL: explicit executor:external not recorded"; exit 1; }
echo "PASS: executor — explicit 'external' is honored and recorded"

# (5) invalid executor → parse_error, fails BEFORE any step runs
cat > "$ex_dir/bad.sop.json" <<'JSON'
{ "name": "bad", "inputs": {},
  "steps": [ { "id": "s1", "type": "shell", "executor": "wat", "run": "echo never" } ] }
JSON
set +e
"$cli" run "$ex_dir/bad.sop.json" --local --json >/dev/null 2>&1; bad_rc=$?
set -e
[ "$bad_rc" -ne 0 ] || { echo "FAIL: invalid executor should exit non-zero"; exit 1; }
echo "PASS: executor — invalid value errors with parse_error before any step runs"

# (6) invalid value on a later step — caught up-front, NO run dir created
cat > "$ex_dir/bad-later.sop.json" <<'JSON'
{ "name": "bad-later", "inputs": {},
  "steps": [
    { "id": "first", "type": "shell", "run": "echo first-ran" },
    { "id": "second", "type": "shell", "executor": "wrong", "run": "echo never" }
  ] }
JSON
runs_before=$(ls "$OPENSOP_LOCAL_HOME/runs" 2>/dev/null | wc -l | tr -d ' ')
set +e
"$cli" run "$ex_dir/bad-later.sop.json" --local --json >/dev/null 2>&1; bl_rc=$?
set -e
runs_after=$(ls "$OPENSOP_LOCAL_HOME/runs" 2>/dev/null | wc -l | tr -d ' ')
[ "$bl_rc" -ne 0 ]                 || { echo "FAIL: bad-later should exit non-zero"; exit 1; }
[ "$runs_before" = "$runs_after" ] || { echo "FAIL: bad-later created a run dir despite up-front validation"; exit 1; }
echo "PASS: executor — pre-validates ALL steps before creating a run dir (no partial runs)"

# --------------------------------------------------------------------------- #
# `opensop list --conflicts` (post-v0.6 polish): when inside a cell, mark
# the first occurrence of each filename as active and subsequent ones as
# shadowed by the nearest cell that has it (PATH-style resolution preview).
# --------------------------------------------------------------------------- #
cf_org="$OPENSOP_LOCAL_HOME/cf-org"
cf_team="$cf_org/team"
mkdir -p "$cf_team"
( cd "$cf_org"  && env -u OPENSOP_LOCAL_HOME "$cli" init --json >/dev/null )
( cd "$cf_team" && env -u OPENSOP_LOCAL_HOME "$cli" init --json >/dev/null )

# Same basename in both cells → team's wins, org's is shadowed
mkdir -p "$cf_org/processes" "$cf_team/processes"
echo '{"name":"shared-org","steps":[{"id":"x","type":"shell","run":"echo o"}]}'  > "$cf_org/processes/shared.sop.json"
echo '{"name":"shared-team","steps":[{"id":"x","type":"shell","run":"echo t"}]}' > "$cf_team/processes/shared.sop.json"
# Only-org skill (no conflict)
echo '{"name":"org-unique","steps":[{"id":"x","type":"shell","run":"echo u"}]}' > "$cf_org/processes/org-unique.sop.json"

# Default list — no shadowing markers (backwards compat with PR #9 output)
plain=$( cd "$cf_team" && env -u OPENSOP_LOCAL_HOME "$cli" list --local )
[[ "$plain" != *"shadowed"* && "$plain" != *"active"* ]]  || { echo "FAIL: default list shouldn't include shadowing markers"; exit 1; }
[[ "$plain" == *"[team]"*"shared.sop.json"* ]]            || { echo "FAIL: default list missing team's shared"; exit 1; }
[[ "$plain" == *"[cf-org]"*"shared.sop.json"* ]]          || { echo "FAIL: default list missing org's shared"; exit 1; }
echo "PASS: list — default mode (no --conflicts) preserves backwards-compatible output"

# --conflicts mode
conf=$( cd "$cf_team" && env -u OPENSOP_LOCAL_HOME "$cli" list --local --conflicts )
[[ "$conf" == *"[team]"*"shared.sop.json"*"← active"* ]]              || { echo "FAIL: --conflicts didn't mark team's shared as active"; exit 1; }
[[ "$conf" == *"[cf-org]"*"shared.sop.json"*"← shadowed by [team]"* ]] || { echo "FAIL: --conflicts didn't mark org's shared as shadowed by team"; exit 1; }
[[ "$conf" == *"[cf-org]"*"org-unique.sop.json"*"← active"* ]]         || { echo "FAIL: --conflicts didn't mark org-unique as active"; exit 1; }
echo "PASS: list --conflicts — marks shadowed entries with the nearest cell that owns them"

# Explicit dir arg with --conflicts: dir wins (cell-aware mode is skipped), --conflicts is benign
dir_out=$( "$cli" list --local "$cf_org" --conflicts 2>&1 )
[[ "$dir_out" == *"shared.sop.json"* ]] || { echo "FAIL: list with explicit dir + --conflicts dropped output"; exit 1; }
[[ "$dir_out" != *"shadowed"* ]]        || { echo "FAIL: explicit-dir list should not produce shadowing markers"; exit 1; }
echo "PASS: list — --conflicts with explicit dir arg is benign (no cell chain to compare)"

echo "ALL PASS"
