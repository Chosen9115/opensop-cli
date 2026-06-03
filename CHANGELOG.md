# Changelog

All notable changes to opensop-cli are documented here.

This project follows [Semantic Versioning](https://semver.org/) and the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

---

## [Unreleased]

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

[0.4.1]: https://github.com/Chosen9115/opensop-cli/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/Chosen9115/opensop-cli/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/Chosen9115/opensop-cli/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/Chosen9115/opensop-cli/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Chosen9115/opensop-cli/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Chosen9115/opensop-cli/releases/tag/v0.1.0
