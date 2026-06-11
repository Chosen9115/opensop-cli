# opensop-cli has moved 📦 → [Chosen9115/opensop](https://github.com/Chosen9115/opensop)

The OpenSOP CLI now lives **inside the main OpenSOP repo**, under [`cli/`](https://github.com/Chosen9115/opensop/tree/main/cli):

> **https://github.com/Chosen9115/opensop** → `cli/bin/opensop`

This repository is **archived** for reference. Its full commit history was carried into the main repo (as a subtree merge), and its tags + releases (`v0.1.0`–`v0.8.0`) remain here for provenance.

## Install (new location)

```bash
curl -fsSL https://raw.githubusercontent.com/Chosen9115/opensop/main/cli/bin/opensop -o opensop
chmod +x opensop
./opensop --version
```

## What changed

As of **v0.8.0**, the CLI is **local-first by default** — `opensop run`, `list`, `search`, etc. execute on your machine against local `.sop.json` files with no server. Use `--remote` (configured server) or `--server <url>` to talk to an OpenSOP runtime. `--local` is now a deprecated no-op.

OpenSOP is **Process as Infrastructure for agentic processes**: declarative, versioned, forkable, runnable, auditable process units that live in your repo and run locally — with a server only when you want shared orchestration or a monitoring UI.

→ Continue at **[Chosen9115/opensop](https://github.com/Chosen9115/opensop)**.
