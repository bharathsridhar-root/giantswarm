# Smart factory agent demo

Three agents on top of the agentlab platform, wired through muster like any
other agent-platform agent. They are **not** raw Kubernetes manifests you
`kubectl apply` — in this platform an agent is created by `agent-manager`
(the same path Backstage's "create agent" wizard uses), which renders the
`HelmRelease`/`AgentTemplate`/`RemoteMCPServer` objects for you and pins
skill commits. The files in `agents/` are the **values** you hand to that
call, in the shape `x_agent-manager_create_agent` (or Backstage's wizard)
expects: `name`, `description`, `systemPrompt`, `toolset`, `modelConfig`.

## The three agents

- **supervisor** (`agents/supervisor.yaml`) — the entry point. Talks to a
  person or another system, delegates to the other two agents, and reports
  overall factory status. No direct tool access beyond querying agent
  status.
- **machine-monitor** (`agents/machine-monitor.yaml`) — watches simulated
  machine telemetry (via `mcp-prometheus`, already in the lab) and flags
  anomalies (temperature, vibration, throughput drift).
- **maintenance-dispatcher** (`agents/maintenance-dispatcher.yaml`) —
  receives anomaly reports and turns them into a structured work order
  (priority, summary, recommended action). The lab's `mcp-kubernetes` is
  deliberately **read-only** (`docs/platform.md`: "runs non-destructive and
  registers no writers"), so this first pass only returns the work order in
  the chat — it doesn't persist anywhere yet. See "Persisting work orders"
  below for the follow-up.

Toolsets are declared narrowly per agent (`docs/platform.md` "toolsets") so
each one only sees what it needs — the same RBAC-through-muster model the
rest of the platform uses.

## Creating them

Once `agentlab up` has the platform running and you're signed in (see the
repo root README / `docs/getting-started.md`), the fastest path is
Backstage's create-agent wizard at `https://backstage.127.0.0.1.nip.io`
(or `:8443` under rootless Podman) — paste each YAML's fields in.

To script it instead (e.g. from Claude Code once `claude mcp add` is done),
call the muster tool directly:

```bash
# from Claude Code, with the muster MCP server added (see repo root README)
# ask it to call x_agent-manager_create_agent with the contents of
# factory/agents/supervisor.yaml, then machine-monitor.yaml, then
# maintenance-dispatcher.yaml
```

Or with `curl` against muster directly (bearer token from `agentlab login`):

```bash
export TOKEN=$(agentlab login dev@lab.local --print-token)
curl -sk https://muster.127.0.0.1.nip.io/mcp \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"tool":"x_agent-manager_create_agent","input":'"$(cat factory/agents/supervisor.yaml | yq -o=json)"'}'
```

Verify readiness the same way the platform's own proofs do:

```bash
KUBECONFIG=state/kubeconfig kubectl -n kagent get agenttemplates
KUBECONFIG=state/kubeconfig kubectl -n kagent get helmreleases
```

Then chat with `supervisor` from Backstage or over A2A, and watch it call
out to the other two through muster with your own token, scoped to each
agent's declared toolset.

## Simulating machine telemetry

The lab ships a minimal Prometheus but no factory data source. Easiest
option: run a tiny synthetic exporter as a Deployment in-cluster that emits
`factory_machine_temperature_celsius{machine="press-1"}` style gauges with
random walk + occasional spikes, scraped by the lab's Prometheus. A ~40-line
Python `prometheus_client` script in a `python:slim` pod is enough — ask
Claude Code to scaffold one (`factory/simulator/`) once you've confirmed the
agents are wired up; it's deliberately left out here so the first pass stays
small enough to debug in Codespaces.

## Persisting work orders

`mcp-kubernetes` in this lab is read-only by design, so maintenance-dispatcher
can't write a ConfigMap/Event directly. Two options once the read-only first
pass works end to end:

1. Stand up a tiny mock "CMMS" MCP server (a small HTTP+stdio MCP tool that
   just appends to an in-memory/SQLite list) and register it with muster as
   a component, then give maintenance-dispatcher a scoped toolset against
   it — this mirrors how a real work-order system would be integrated and
   keeps the platform's read-only Kubernetes boundary intact.
2. If you just want writes to land in-cluster for the demo, use
   `vm-manager`'s or Backstage's own write paths rather than
   `mcp-kubernetes`, or ask whoever owns the lab's mcp-kubernetes config to
   register a scoped writer for a `factory` namespace only — out of scope
   for this starter, flagged here so it isn't a surprise.
