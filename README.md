# opensop-cli

A small bash CLI for talking to any [OpenSOP](https://github.com/Chosen9115/opensop) runtime — list processes, run them, advance step-by-step, and watch the receipts. One file, no dependencies beyond `curl` and `jq`.

## Why

OpenSOP is an open standard for executable processes — define a YAML, get a typed REST API. This CLI is the smallest useful client for that API: a thin wrapper around the `/sop/*` endpoints, with a tiny local cache so you can pass instance IDs around without re-typing process names.

It works against any conformant OpenSOP server. The reference implementation is the [opensop Rails app](https://github.com/Chosen9115/opensop); the public demo at `https://demo.opensop.ai` runs it. You do not need to self-host anything to try the CLI.

It exists so agents (and humans) can use OpenSOP from any terminal, immediately, without writing curl invocations by hand.

## Install

### One line

```bash
curl -fsSL https://raw.githubusercontent.com/Chosen9115/opensop-cli/main/bin/opensop -o /usr/local/bin/opensop && chmod +x /usr/local/bin/opensop
```

### From source

```bash
git clone https://github.com/Chosen9115/opensop-cli.git
cp opensop-cli/bin/opensop /usr/local/bin/
chmod +x /usr/local/bin/opensop
```

### Requirements

- `bash` 4+ (any modern macOS or Linux)
- `curl`
- `jq` — `brew install jq` / `apt install jq`

### Shell completions

The CLI does not generate completion files yet, but you can install static
completion examples for the common subcommands: `list`, `schema`, `run`,
`status`, `steps`, `submit`, and `dry-run`.

For bash, save this as `~/.opensop-completion.bash`:

```bash
_opensop_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local commands="list schema run status steps submit dry-run"

  if [[ "$COMP_CWORD" -eq 1 ]]; then
    COMPREPLY=($(compgen -W "$commands" -- "$cur"))
  else
    COMPREPLY=()
  fi
}

complete -F _opensop_complete opensop
```

Then source it from `~/.bashrc`:

```bash
source ~/.opensop-completion.bash
```

For zsh, create a completion directory and add it to `fpath` before `compinit`
runs:

```zsh
mkdir -p ~/.zsh/completions
```

Add this file at `~/.zsh/completions/_opensop`:

```zsh
#compdef opensop

_opensop() {
  local -a commands
  commands=(
    'list:List registered processes'
    'schema:Show a process schema'
    'run:Start a process instance'
    'status:Show instance status'
    'steps:List instance steps'
    'submit:Submit outputs for a waiting step'
    'dry-run:Validate inputs without starting'
  )

  if (( CURRENT == 2 )); then
    _describe 'opensop command' commands
  else
    _files
  fi
}

_opensop "$@"
```

In `~/.zshrc`, make sure the completion directory is loaded:

```zsh
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit
compinit
```

## Quick start

Point the CLI at a server (the public demo is at `demo.opensop.ai`):

```bash
opensop config set url https://demo.opensop.ai
opensop config set token demo-public-token-resets-daily
```

Discover what processes are available:

```bash
$ opensop list
agent-pr-review                  developer-tooling, code-review, agent-harness, ai  An agent reviews a PR diff…
appsignal-incident-fix           appsignal, incident-management, fix       Classify an AppSignal incident…
appsignal-regression-check       appsignal, regression-check               After a fix PR merges, wait 3 days…
customer-onboarding              banking, onboarding, compliance, kyb      Onboard a new business customer…
expense-approval                 finance, expense, approval, hr            Employee submits an expense; an LLM…
lead-qualification               growth, sales, qualification              Qualify an inbound lead and score…
release-deploy                   devops, release, deployment, cicd         Release engineer fills release notes…
support-ticket-triage            support, triage, customer-service         Inbound support ticket is categorized…
```

Don't know the process name? Search by intent:

```bash
$ opensop search lead
2     lead-qualification           (growth, sales, qualification)  Qualify an inbound lead and score their fit
```

Read a process's full definition:

```bash
opensop schema lead-qualification
```

Start an instance:

```bash
opensop run lead-qualification \
  --input lead_name="Ana García" \
  --input lead_email=ana@example.com \
  --input source=website
```

You'll get an instance ID back — keep it. The CLI caches the ID → process name mapping so subsequent commands take just the ID:

```bash
opensop status <instance-id>
opensop steps <instance-id>
```

Advance a paused step (form / judgment / approval):

```bash
opensop submit <instance-id> collect-context \
  --output budget=12000 \
  --output timeline=immediate \
  --output notes="Strong fit, spoke to CEO" \
  --decided-by agent:my-bot \
  --confidence 0.92
```

Before you commit to a run, preview what would happen without executing anything:

```bash
opensop dry-run lead-qualification \
  --input lead_name="Ana García" \
  --input lead_email=ana@example.com \
  --input source=website
```

This validates your inputs against the process schema and describes each step — no instance is created. Exit code 1 if validation fails.

Cancel a running instance:

```bash
opensop cancel <instance-id> --reason "lead unresponsive"
```

List all instances:

```bash
opensop instances --state running --limit 20
```

## Worked example

A full `lead-qualification` run from start to completion — what each command returns and what to do next.

**Step 1: start the instance**

```
$ opensop run lead-qualification \
    --input lead_name="Ana García" \
    --input lead_email=ana@example.com \
    --input source=website

✓ started lead-qualification
  id:    e33baee4-84d3-4d04-b902-2f50437d8191
  state: running

waiting:
  collect-context (form): waiting_for_input

next:  opensop status e33baee4-84d3-4d04-b902-2f50437d8191
```

The instance is running and paused at the first step — a `form` step waiting for human or agent input.

**Step 2: inspect the steps**

```
$ opensop steps e33baee4-84d3-4d04-b902-2f50437d8191

collect-context    form           active    waiting_for_input
score-lead         automated      pending
notify-team        notification   pending
```

**Step 3: submit the paused step**

```
$ opensop submit e33baee4-84d3-4d04-b902-2f50437d8191 collect-context \
    --output budget=12000 \
    --output timeline=immediate \
    --output notes="Strong fit, spoke to CEO" \
    --decided-by agent:my-bot \
    --confidence 0.92

✓ submitted collect-context (completed) — instance running
next:  opensop status e33baee4-84d3-4d04-b902-2f50437d8191
```

The form step is complete. The runtime moves to `score-lead` (automated) and `notify-team` (notification) automatically.

**Step 4: poll until done**

```
$ opensop status e33baee4-84d3-4d04-b902-2f50437d8191

instance: e33baee4-84d3-4d04-b902-2f50437d8191
process:  lead-qualification
state:    completed (2026-05-08T20:28:41Z)

  ✓ collect-context              form
  ✓ score-lead                   automated
  ✓ notify-team                  notification
```

That's the run-pause-submit-poll lifecycle. The receipt is stored in the runtime's database; `opensop instances --process lead-qualification` will show all historical runs.

## Output modes

By default the CLI is **TTY-aware**: pretty-printed in a terminal, JSON when piped.

```bash
opensop list                    # pretty in terminal, JSON when piped
opensop list --json             # always JSON
opensop list --pretty           # always pretty (well, always indented JSON outside a TTY)
opensop status <id> | jq ...    # piping → JSON automatically
```

When `--json` is set, **errors also emit JSON to stderr**: server errors round-trip via `{error, message, ...}` from the engine (augmented with `_meta.http_status`); CLI-side errors (config missing, file not found, invalid input, unknown command, etc.) emit `{error, message, hint?}` from the same envelope. Agents can parse stderr the same way they parse stdout.

```bash
$ opensop --json schema validate /nonexistent.yaml 2>&1 1>/dev/null
{"error":"file_not_found","message":"file does not exist: /nonexistent.yaml"}
```

Set `NO_COLOR=1` to disable ANSI color.

## Input forms

Three ways to provide inputs to `run` (and outputs to `submit`):

```bash
# Inline JSON
opensop run X --inputs '{"lead_name": "Ana", "source": "website"}'

# JSON file
opensop run X --inputs-file ./inputs.json

# Key=Value pairs (repeatable; values that look like JSON parse as JSON)
opensop run X \
  --input lead_name="Ana García" \
  --input source=website \
  --input budget=12000 \
  --input urgent=true
```

For `submit`, swap `--inputs/--input` for `--outputs/--output`, plus optional `--decided-by` and `--confidence`.

You can also attach metadata to a `run`:

```bash
opensop run lead-qualification \
  --input lead_name=Ana \
  --metadata source_system=crm \
  --metadata external_id=lead_8821
```

## Configuration

Config lives at `~/.opensop/config` (or `$OPENSOP_HOME/config` if set). Two values:

```
OPENSOP_URL="https://your-server"
OPENSOP_TOKEN="your-x-sop-token"
```

Override per-call via env vars:

```bash
OPENSOP_URL=https://prod.opensop.ai opensop list
```

Use `--local` to target `http://localhost:3000` for a single call without changing your config:

```bash
opensop list --local                        # hit your dev server
opensop run lead-qualification --local ...  # test locally before prod
```

## Process authoring

The CLI supports the full authoring loop for `.sop.yaml` files — from lint to registration.

**Step 1: lint your file**

`schema validate` is fully client-side (no server round-trip). It checks structural requirements using `yq` (mikefarah/yq v4+) if installed, or `python3` + PyYAML as a fallback:

```bash
opensop schema validate ./my-process.sop.yaml
```

What it checks:

- Top-level `opensop` version field present
- `process` object with `name`, `version`, `description`, `inputs` (array), `steps` (array)
- Each step has `id` and `type`; `type` is one of the known values (`form`, `automated`, `judgment`, `approval`, `webhook`, `notification`, `subprocess`, `loop`, `llm`, `wait`)
- Each input has `name` and `type`
- All `from:` reference strings match `steps.X.outputs.Y` or `process.inputs.Y`

Exit 0 if valid, 1 if errors. Use `--json` to get a structured `{file, valid, errors}` object.

**Step 2: preview execution**

Run `dry-run` to validate inputs against the process schema and walk through each step's description without creating an instance:

```bash
opensop dry-run my-process --input foo=bar
```

Exit 0 if inputs are valid, 1 if validation fails.

**Step 3: register**

```bash
opensop register ./my-process.sop.yaml
```

POSTs the file to `/sop/processes/register`. On success, prints `registered <name>@<version>`. If the server returns 401/403, registration may be admin-only — check your token scope or use the dashboard at `<OPENSOP_URL>/admin`.

## Subcommand reference

| Command | Purpose |
|---|---|
| **Discovery** | |
| `opensop list [--tag <tag>]` | List all registered processes, optionally filtered by tag |
| `opensop search <keyword> [...]` | Ranked text search over process names, descriptions, and tags |
| `opensop suggest "<task description>"` | Describe a task in prose; get the top-matching process back |
| `opensop schema <name>` | Full process definition (`GET /sop/<name>/schema`) |
| **Inspection** | |
| `opensop status <id>` | Instance state (`GET /sop/<name>/<id>`) |
| `opensop steps <id>` | All steps of an instance (`GET /sop/<name>/<id>/steps`) |
| `opensop diff <id1> <id2>` | Compare two instances of the same process |
| `opensop history --process <name> [--limit N]` | Recent instances of a specific process, newest-first |
| `opensop compass` | Top processes by run-count, recency, and failure rate |
| **Execution** | |
| `opensop run <name> [opts]` | Start an instance (`POST /sop/<name>/start`) |
| `opensop dry-run <name> [opts]` | Validate inputs + preview steps, no server execution |
| `opensop submit <id> <step-id> [opts]` | Advance a paused step (`POST /sop/<name>/<id>/steps/<step-id>/submit`) |
| `opensop cancel <id> [--reason TEXT]` | Cancel an instance (`POST /sop/<name>/<id>/cancel`) |
| **Authoring** | |
| `opensop register <process.yaml>` | POST a `.sop.yaml` to `/sop/processes/register` |
| `opensop schema validate <file.yaml>` | Client-side YAML lint — no server round-trip |
| **Admin** | |
| `opensop instances [--state X] [--process Y]` | Paginated list (`GET /sop/instances`) |
| **Config** | |
| `opensop config [set <key> <value>]` | Manage config |
| `opensop help` | Full help |

## Local cache

The CLI caches `id → process name` mappings in `~/.opensop/instances.tsv` — a plain TSV of `id`, `name`, `created_at`, `url`. This is why `opensop status <id>` and `opensop steps <id>` only need the instance ID; you don't have to re-type the process name. Safe to delete at any time; the CLI rebuilds it from `/sop/instances` on the next cache miss.

## Authentication

The CLI sends `X-SOP-Token` on every request when the token is set. The OpenSOP server can run in two modes:

- **Token unset, dev/test environment** — server allows all requests (logs a warning)
- **Token set** — every non-webhook request must match; mismatch returns 401

In production the server **fails closed** (503 with `server_misconfigured`) when the token is unset, so `opensop list` against a misconfigured prod will return that error from the server, not a silent open API.

## Use with Claude Code (and other agents)

The CLI was designed so an agent can use OpenSOP without writing HTTP requests. See [`docs/CLAUDE-INTEGRATION.md`](docs/CLAUDE-INTEGRATION.md) for the recipe — a small CLAUDE.md snippet that teaches the agent when to reach for `opensop` instead of doing things ad-hoc.

The short version: when an agent recognizes that what it's about to do is a multi-step process, it `opensop schema`s a candidate process, `opensop run`s it, polls `opensop status`, and submits step outputs as it works. Receipts persist in the runtime's database — observable by humans, replayable across runs.

For discovery, agents should use `opensop search` or `opensop suggest` rather than scanning the full `list` output — they surface the right process from intent, not from name recall.

## Limitations

- **Bash 4+** assumed. Default macOS bash is 3.2 — install a newer one (`brew install bash`) or run via `/usr/local/bin/bash`.
- **`register` may be admin-only.** Some OpenSOP deployments restrict `/sop/processes/register` to admin tokens. If you get a 401/403, check your token scope or use the dashboard.
- **No webhooks.** The CLI doesn't run a server, so it can't receive webhook callbacks. The OpenSOP runtime handles those itself at `/sop/webhooks/<callback_id>`.
- **Stubbed step types** in OpenSOP v0.2 (`judgment`, `approval`, `subprocess`, `wait`) pause but don't auto-advance — you'll need to `submit` them manually. See the [server's API docs](https://github.com/Chosen9115/opensop/blob/main/docs/API.md#whats-stubbed-v02) for the current state.

## Contributing

Issues and pull requests welcome. The whole CLI is one bash file (`bin/opensop`); read it top-to-bottom in 10 minutes.

If you find a `set -u` bug (very common in bash with empty arrays), open an issue — there are corners where `${array[@]}` triggers "unbound variable" if not guarded.

## License

MIT — see [LICENSE](LICENSE).
