# Using opensop-cli with Claude Code (and other agents)

The point of this CLI isn't speed or convenience for humans — it's that an AI agent can drive OpenSOP without writing HTTP requests by hand. This doc describes the patterns that turn ad-hoc agent behavior into reusable, observable processes.

## The core idea: prose runbook → typed contract

When you ask an agent "do X for me," the agent's working memory is prose — a series of decisions that disappear when the conversation ends. If you ask it to do X again next week, it derives the same plan from scratch, often slightly differently, and you have no audit trail.

OpenSOP turns those prose runbooks into structured, executable processes:

- A `.sop.yaml` file describes inputs, outputs, and steps as a typed contract
- Running it produces an **instance** with persistent state — every step's inputs, outputs, retries, durations queryable as plain SQL
- Re-running the process is byte-for-byte the same plan; only the inputs vary

The CLI is how an agent reaches that runtime. Three integration patterns, in order of complexity:

## Pattern 1 — Agent invokes existing processes

The simplest pattern. The agent doesn't author processes; it just runs ones that already exist.

**Add to your `CLAUDE.md` (or skill file):**

```markdown
## OpenSOP processes

When you have a multi-step task that someone has likely already turned into a
process, check first: `opensop list` shows what's available. `opensop schema <name>`
shows what a process expects.

If a process fits the task at hand, prefer running it over re-deriving the steps:

  opensop run <name> --input key=value --input key2=value2

Then `opensop status <instance-id>` until it reaches `completed`. If a step is
`waiting` (form / judgment / approval), advance it with `opensop submit <id> <step-id>`.

This gives the work persistence and a receipt — better than ad-hoc execution.
```

The agent now has a habit of *checking* before doing.

## Pattern 2 — Agent recognizes mineralization candidates

The agent notices when a multi-step task it's about to do is general enough to be reused, and proposes capturing it as a `.sop.yaml`.

**Add to your `CLAUDE.md`:**

```markdown
## When to suggest a new process

If you're about to do something that has all of these properties, pause and
suggest capturing it as an OpenSOP process before you start:

- 3+ distinct steps (not just "edit a file and run a test")
- Will likely be repeated (weekly cron, every PR, every customer onboarding)
- Has clear inputs and outputs
- A future agent or human would benefit from auditing what was done

Tell me: "this looks like an OpenSOP process — want me to write a .sop.yaml
first?" and wait for confirmation. If yes, draft the YAML, then register it
on the server (via the admin UI or POST /sop/processes/register) and run it
via `opensop run`.

If no, just do the task ad-hoc.
```

The agent now has a habit of *spotting* when a one-off should become a process. It doesn't assume — it asks.

## Pattern 3 — Agent uses OpenSOP as its persistent state

This is the deep integration. The agent treats OpenSOP as its own working memory: every cron tick, every long-running task, every back-and-forth handoff goes through the runtime.

This works best when:

- The agent runs as a cron job (gbrain, Hermes, etc.)
- Outputs of one tick need to be inputs to the next
- Multiple agents need to coordinate (one agent triages, another deploys, a third audits)

Pattern: each cron tick starts (or resumes) an OpenSOP instance. The instance's `metadata` tracks which agent owns it. Step outputs are the agent's "memory" between ticks. When the process completes, the audit trail shows exactly what happened.

Concrete example: a daily morning-briefing process.

```yaml
opensop: "0.1"
process:
  name: morning-briefing
  version: "1.0"
  description: Daily synthesis of overnight events into a single brief
  inputs:
    - { name: date, type: string, required: true }
  outputs:
    - { name: brief_md, type: string, from: steps.synthesize.outputs.brief_md }
  steps:
    - id: collect-events
      type: automated
      script: ./scripts/fetch-overnight-events.sh
      outputs: [{ name: events, type: object }]
    - id: synthesize
      type: llm
      model: claude-opus-4-7
      prompt: "Synthesize these into a 200-word brief: ..."
      expected_output_schema:
        brief_md: string
    - id: post-to-slack
      type: notification
      channel: slack
      to: "#daily-briefings"
      body: "{{ steps.synthesize.outputs.brief_md }}"
```

The agent's cron job is now one line:

```bash
opensop run morning-briefing --input date=$(date -u +%Y-%m-%d)
```

Every run has a queryable history. If something failed, the agent can `opensop status <id>` and see exactly which step broke.

## Recipe: bootstrapping the integration on a new project

1. Install the CLI: `curl -fsSL https://raw.githubusercontent.com/Chosen9115/opensop-cli/main/bin/opensop -o /usr/local/bin/opensop && chmod +x /usr/local/bin/opensop`
2. Point it at a server: `opensop config set url https://demo.opensop.ai && opensop config set token demo-public-token-resets-daily` (or your own deploy)
3. Add **one** of the patterns above to your `CLAUDE.md`
4. Run a low-stakes task through OpenSOP first (e.g., `lead-qualification` from the demo) so the agent confirms the integration works
5. Identify your first real candidate for mineralization — a 3+ step task you do at least weekly
6. Author the `.sop.yaml`, register it on your server, run it via the CLI from then on

## Why bash and not a Go binary?

This CLI is intentionally a bash script:

- An agent can `cat /usr/local/bin/opensop` and read all 600 lines in seconds
- No build step means PRs land in minutes, not days
- HTTP wrapping is what bash + `curl` + `jq` are *for*
- If it grows past the point where bash is the right choice, porting to Go is a weekend, not a rewrite

Stay close to `curl` until friction tells you it's time to graduate.

## See also

- [OpenSOP repo](https://github.com/Chosen9115/opensop) — the reference implementation (Rails)
- [OpenSOP API docs](https://github.com/Chosen9115/opensop/blob/main/docs/API.md) — every endpoint the CLI talks to
- [Process authoring guide](https://github.com/Chosen9115/opensop/blob/main/docs/process-authoring.md) — how to write a `.sop.yaml`
