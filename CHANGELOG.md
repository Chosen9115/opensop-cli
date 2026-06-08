# Changelog

All notable changes to opensop-cli are documented here.

This project follows [Semantic Versioning](https://semver.org/) and the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

---

## [Unreleased]

## [0.6.0] — 2026-06-08

The cell substrate. Six PRs (#6, #7, #8, #9, #10, #11) added a fractal
addressing primitive, a substrate-level event log per skill, name resolution
across the cell chain, fork with lineage, per-cell receipts, and the
executor field. Backwards-compatible — every pre-v0.6 usage continues to
work; v0.6 features only activate inside a cell.

### Added

- **Cell primitive — `opensop init` and `opensop scope`.** A "cell" is a
  directory marked by `.opensop/manifest.yaml`. `init` creates one in cwd
  (auto-detecting the parent cell when an ancestor `.opensop/` exists);
  `scope` walks up from cwd and prints the active cell + ancestor chain.
  Pure-additive — no existing command behavior changes. Foundation for the
  rest of v0.6.
- **Lineage primitives — `opensop annotate` and `opensop lineage`.**
  Substrate-level event log per skill stored in `.opensop/lineage.json` in
  each cell. `annotate <skill> <event-type> <json>` appends a policy event
  to the skill's history (creates the lineage entry if it doesn't exist).
  `lineage <skill>` prints the entry (status, metadata, history) in the
  active cell, returning an empty default if no events have been recorded.
  Policy-neutral: the substrate stores `status` (open string), `metadata`
  (open object), and `history[].type` (open string); it doesn't interpret
  any of them. This is what evolution policies (e.g. mineralization) sit on
  top of to record promotions, demotions, locks, etc.
- **Fork mechanic — `opensop fork <name> [--from <cell>]`.** Materializes
  a copy of an ancestor cell's skill into the active cell and records a lineage
  entry with `forked_from = { cell, forked_at, snapshot }`. The `snapshot` is
  the parent's `status` and `metadata` captured opaquely — the substrate stores;
  evolution policies decide what to do with it (typical: inherit + mark
  unverified until first run in the child cell). Auto-detects the source via
  walk-up; pass `--from` to override. Refuses to overwrite an existing skill
  in the active cell.
- **Step executor field — `executor: internal|external`.** Steps in a
  `.sop.json` may declare where their work happens: `external` means the work
  is done by a process outside the OpenSOP runtime (script, webhook); the
  runtime orchestrates and receives the receipt. `internal` means the runtime
  handles the step directly. Field is optional; per-type defaults apply when
  absent (`automated`/`shell`/`webhook` → external, `noop`/`form`/`approval`/
  `notification`/`wait`/`judgment` → internal). Invalid values fail with
  `parse_error` at process load time — before any step runs and before a run
  directory is even created. The effective executor (explicit or defaulted)
  is recorded in each step's `audit.jsonl` entry. Formalizes the
  B-mode-vs-A-mode distinction and matches existing production patterns
  (deterministic external scripts producing typed receipts).

### Changed

- **Name resolution across the cell chain.** Two changes to the local
  engine when a cell is active:
  - `opensop run <name> --local` accepts a **bare logical name** (in addition
    to a file path). The name resolves to `processes/<name>.sop.json` in the
    active cell, then in each ancestor cell — nearest wins. Explicit file
    paths still work for backwards compatibility (paths are detected when the
    argument ends in `.sop.json` or contains `/`).
  - `opensop list --local` (no dir arg) now walks the active cell + ancestors
    when invoked from inside a cell, tagging each entry with `[cell-name]`.
    Passing an explicit `dir` keeps the original `find`-based behavior with
    no cell awareness.
- **`OPENSOP_LOCAL_HOME` default is now cell-aware.** When cwd is inside
  an OpenSOP cell AND the user has not explicitly set `OPENSOP_LOCAL_HOME`,
  local-mode receipts (`opensop run --local`, `opensop runs`, `opensop show`)
  now default to `<cell-root>/.opensop/` instead of the global
  `~/.opensop-local`. Receipts land alongside the processes that produced
  them, and each cell has its own receipt history. Outside any cell, the
  default is still `~/.opensop-local`. Explicit `OPENSOP_LOCAL_HOME=…` always
  wins. Backwards-compatible because it only kicks in when a `.opensop/`
  marker exists in cwd's path (no pre-v0.6 user has one).

---

## [0.5.0] — 2026-06-04

### Added

- **Local execution backend (`--local`) — no server.** The CLI now has two
  backends: by default it talks to a running OpenSOP server; with `--local` the
  *same commands* run on-machine against internal files — no Rails, no daemon,
  no network, no `curl` (just `bash` + `jq`). `opensop run <process>.sop.json
  --local` runs `automated`/`shell`/`noop` steps in order, threads a JSON
  context between them (stdin + `$OSL_CONTEXT`, stdout merged under the step id),
  and writes an append-only on-disk receipt per step
  (`$OPENSOP_LOCAL_HOME/runs/<id>/`, default `~/.opensop-local`). This is an
  extension of OpenSOP, not a separate tool.
- **`runs`** — list local runs. **`show <run_id>`** — a local run's manifest +
  per-step receipts (the local analogue of `instances` / `status`).
- **`list --local [dir]`** — discover internal `.sop.json` processes.
- A worked example (`examples/greet.sop.json` + `examples/steps/build.sh`) and a
  golden test (`test/test.sh`).

### Changed

- **BREAKING: `--local` now means *local execution*** (run against internal
  files). It previously aliased `OPENSOP_URL` to `http://localhost:3000`. For a
  local dev **server**, use `opensop config set url http://localhost:3000` or
  `OPENSOP_URL=http://localhost:3000` instead.

### Fixed

- **Failing steps are handled instead of aborting.** Under `set -e`, a non-zero
  step previously aborted the whole CLI before the failure receipt, manifest
  finalization, and `continue_on_error` could run. Step execution is now guarded
  so failures are recorded (`failed` receipt + manifest `status:"failed"`) and
  `continue_on_error` works.
- **`runs` / `show` no longer require `curl`** — they are always-local commands.
- **Interrupted runs no longer stick at `running`.** A killed/crashed run is
  finalized as `interrupted` via an EXIT trap.
- **Step `stderr` is captured** into the receipt (surfaced by `show`); empty
  stderr logs are no longer left behind.
- **Empty/malformed `steps` are rejected** up front instead of "completing"
  trivially. `run_id` hardened against same-second/recycled-PID collisions.
- Trust boundary documented (local steps run as shell — only run process files
  you trust), and failure-path regression tests added to `test/test.sh`.

---

## [0.4.1] — 2026-05-08

### Fixed

- **Cache priming on `history` and `instances`** — both subcommands now
  populate the local `id → process.name` map from every response row.
  Agents who use the discovery layer to find an instance and immediately
  inspect it no longer hit the cache-miss path.
- **Paginated cache-miss fallback in `lookup_name`** — the fallback now
  walks up to 1000 instances (5 pages of 200) before giving up, instead
  of stopping at the first 200. Defensive fix; rarely hit once cache
  priming is in.
- **Multi-word `search` and `suggest`** — queries are now tokenized on
  whitespace and scored per-token, with hyphenated process names also
  tokenized on `-`/`_`. `search "morning briefing"` now correctly
  matches `darwin-morning-briefing`. Single-word queries unchanged.

### Changed

- **Search/suggest corpus widened** — `inputs_summary` and
  `outputs_summary` (already in the `/sop/` discovery response, just
  unused) are now indexed alongside name + description + tags.
  Expected ~30% recall lift on "what produces X?" / "I want Y"
  intent queries. Reported by the Darwin agent.

---

## [0.4.0] — 2026-05-08

### Added

- **Structured CLI-side errors in `--json` mode.** When `--json` is set, every
  `die()`/`err()` call now emits `{"error": "<code>", "message": "<message>",
  "hint": "<hint>"}` to stderr instead of prose. Prose-mode default (TTY) is
  unchanged — fully backward-compatible.
- `_resolve_output_mode()` helper that respects `OUTPUT_MODE` before `main()`
  has finished stripping flags (e.g. very early dependency checks).
- Error codes for all CLI-side failure paths: `config_missing`,
  `missing_dependency`, `network_error`, `instance_not_found`, `usage_error`,
  `file_not_found`, `invalid_json`, `unknown_command`, `unknown_flag`,
  `parse_error`, `cli_error`.
- `hint` field on relevant codes (e.g. `config_missing` hints
  `opensop config set url <URL>`; `missing_dependency` for jq hints
  `brew install jq`).

### Changed

- **HTTP error path in `api_call`:** in `--json` mode, server error envelopes
  now pass through verbatim with a `_meta.http_status` field appended. The
  previous behavior (prose + raw JSON dump) is replaced by a single clean JSON
  object on stderr.
- `register` HTTP error path brought in line with the same `api_call` pattern.
- All `die "..."` call sites updated with explicit codes and hints where
  applicable.
- `file not found` wording normalised to `"file does not exist: <path>"` across
  `register` and `schema validate`.

---

## [0.3.1] — 2026-05-08

### Fixed

- `compass --json` shape now matches docs: top-level keys are
  `{by_runs, by_recency, by_failure_rate}` with consistent field names per
  slice (`{name, total}` / `{name, last_run_at}` /
  `{name, total, failures, rate}`).

---

## [0.3.0] — 2026-05-08

### Added

- `diff <id1> <id2>` — compare two instances of the same process field-by-field.
- `compass` — top processes by run-count, recency, and failure rate.
- `history --process <name> [--limit N]` — recent instances of a specific
  process, newest-first.
- `dry-run <name> [opts]` — client-side preview: validates inputs against the
  process schema and describes each step without creating an instance.
- `register <process.yaml>` — POST a `.sop.yaml` to `/sop/processes/register`.
- `schema validate <file.yaml>` — fully client-side YAML lint using `yq` (v4+)
  with `python3` + PyYAML as a fallback.
- `--local` global flag — overrides `OPENSOP_URL` to `http://localhost:3000`
  for a single call without changing config.

---

## [0.2.0] — 2026-05-08

### Added

- `search <keyword> [...]` — ranked text search over process names,
  descriptions, and tags.
- `suggest "<task description>"` — inverse retrieval: describe a task, get the
  top-matching process back with a confidence score.
- `list --tag <tag>` — client-side filter by tag.
- README worked example (full `lead-qualification` run from start to
  completion).
- Sample `opensop list` output in README.
- Lifted the cache-line note into its own README section.

---

## [0.1.0] — 2026-05-07

### Added

- Initial release.
- 9 subcommands: `list`, `schema`, `run`, `status`, `steps`, `submit`,
  `cancel`, `instances`, `config`.
- Instance-ID local cache (`~/.opensop/instances.tsv`) — maps instance IDs to
  process names so subsequent commands need only the ID.
- TTY-aware output: pretty-printed in a terminal, compact JSON when piped.
- `--json` / `--pretty` global flags.
- `X-SOP-Token` auth header support.
- `NO_COLOR` support.

[0.6.0]: https://github.com/Chosen9115/opensop-cli/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Chosen9115/opensop-cli/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/Chosen9115/opensop-cli/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Chosen9115/opensop-cli/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/Chosen9115/opensop-cli/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Chosen9115/opensop-cli/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Chosen9115/opensop-cli/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Chosen9115/opensop-cli/releases/tag/v0.1.0
