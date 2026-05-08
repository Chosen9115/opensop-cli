# opensop-cli

A small bash CLI for talking to any [OpenSOP](https://github.com/Chosen9115/opensop) runtime — list processes, run them, advance step-by-step, and watch the receipts. One file, no dependencies beyond `curl` and `jq`.

## Why

OpenSOP is an open standard for executable processes — define a YAML, get a typed REST API. This CLI is the smallest useful client for that API: a thin wrapper around the `/sop/*` endpoints, with a tiny local cache so you can pass instance IDs around without re-typing process names.

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

## Quick start

Point the CLI at a server (the public demo is at `demo.opensop.ai`):

```bash
opensop config set url https://demo.opensop.ai
opensop config set token demo-public-token-resets-daily
```

Discover what processes are available:

```bash
opensop list
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
  --decided-by agent:my-bot \
  --confidence 0.92
```

Cancel a running instance:

```bash
opensop cancel <instance-id> --reason "lead unresponsive"
```

List all instances:

```bash
opensop instances --state running --limit 20
```

## Output modes

By default the CLI is **TTY-aware**: pretty-printed in a terminal, JSON when piped.

```bash
opensop list                    # pretty in terminal, JSON when piped
opensop list --json             # always JSON
opensop list --pretty           # always pretty (well, always indented JSON outside a TTY)
opensop status <id> | jq ...    # piping → JSON automatically
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

The local cache lives at `~/.opensop/instances.tsv` — TSV of `id`, `name`, `created_at`, `url`. Safe to delete; the CLI rebuilds it from `/sop/instances` on the next miss.

## Authentication

The CLI sends `X-SOP-Token` on every request when the token is set. The OpenSOP server can run in two modes:

- **Token unset, dev/test environment** — server allows all requests (logs a warning)
- **Token set** — every non-webhook request must match; mismatch returns 401

In production the server **fails closed** (503 with `server_misconfigured`) when the token is unset, so `opensop list` against a misconfigured prod will return that error from the server, not a silent open API.

## Use with Claude Code (and other agents)

The CLI was designed so an agent can use OpenSOP without writing HTTP requests. See [`docs/CLAUDE-INTEGRATION.md`](docs/CLAUDE-INTEGRATION.md) for the recipe — a small CLAUDE.md snippet that teaches the agent when to reach for `opensop` instead of doing things ad-hoc.

The short version: when an agent recognizes that what it's about to do is a multi-step process, it `opensop schema`s a candidate process, `opensop run`s it, polls `opensop status`, and submits step outputs as it works. Receipts persist in the runtime's database — observable by humans, replayable across runs.

## Subcommand reference

| Command | Purpose |
|---|---|
| `opensop list` | List all registered processes (`GET /sop/`) |
| `opensop schema <name>` | Full process definition (`GET /sop/<name>/schema`) |
| `opensop run <name> [opts]` | Start an instance (`POST /sop/<name>/start`) |
| `opensop status <id>` | Instance state (`GET /sop/<name>/<id>`) |
| `opensop steps <id>` | All steps of an instance (`GET /sop/<name>/<id>/steps`) |
| `opensop submit <id> <step-id> [opts]` | Advance a paused step (`POST /sop/<name>/<id>/steps/<step-id>/submit`) |
| `opensop cancel <id> [--reason TEXT]` | Cancel an instance (`POST /sop/<name>/<id>/cancel`) |
| `opensop instances [--state X] [--process Y]` | Paginated list (`GET /sop/instances`) |
| `opensop config [set <key> <value>]` | Manage config |
| `opensop help` | Full help |

## Limitations

- **Bash 4+** assumed. Default macOS bash is 3.2 — install a newer one (`brew install bash`) or run via `/usr/local/bin/bash`.
- **No `register` subcommand.** Process registration in v0.2 of the OpenSOP server is admin-only; register via the dashboard or the Rails admin API.
- **No webhooks.** The CLI doesn't run a server, so it can't receive webhook callbacks. The OpenSOP runtime handles those itself at `/sop/webhooks/<callback_id>`.
- **Stubbed step types** in OpenSOP v0.2 (`judgment`, `approval`, `subprocess`, `wait`) pause but don't auto-advance — you'll need to `submit` them manually. See the [server's API docs](https://github.com/Chosen9115/opensop/blob/main/docs/API.md#whats-stubbed-v02) for the current state.

## Contributing

Issues and pull requests welcome. The whole CLI is one bash file (`bin/opensop`); read it top-to-bottom in 10 minutes.

If you find a `set -u` bug (very common in bash with empty arrays), open an issue — there are corners where `${array[@]}` triggers "unbound variable" if not guarded.

## License

MIT — see [LICENSE](LICENSE).
