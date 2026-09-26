# Runbook: what tonight's first EC2 run actually hit

Everything below is fixed in `user-data.sh`/`launch-instance.sh` already for a
*new* launch. This file exists so a resumed session (or a future one) doesn't
have to re-derive any of it from scratch.

## Current live instance (as of this session)

- Instance: `i-0b2b592e56886ca70`, region `eu-central-1`, public IP `63.179.117.4`
- Security group: `sg-0627cdd4c2eaf1b5f` (`agentlab-no-inbound`)
- Volume: `vol-02d396c72f7719f0f`, resized live from 30GB -> 60GB (filesystem
  already grown with `growpart`/`resize2fs`, confirmed `df -h /` shows ~58G)
- `agentlab.yaml` on the box has `chartVersion: 4.65.4` (manually bumped past
  the bug below) and `extraModels: [qwen35-2b]` (the free Ollama model)
- **`./agentlab platform-test` passed clean, every check** — the platform
  itself is confirmed healthy end to end (Dex, muster, mcp-kubernetes, RBAC,
  Kyverno, kagent, Substrate, Prometheus, Backstage's metrics path).
- **Browser access resolved** (was the open loose end) — see "RESOLVED:
  browser access to Backstage" below and `GETTING_STARTED.md` for the clean
  procedure. Required a code change (`b3e7304`, kind port mappings now
  bind `0.0.0.0`) plus `agentlab down && up` on the instance.
- Logged in successfully as `admin@lab.local` via
  `https://backstage.127.0.0.1.nip.io`, reached with: security-group rules
  for 443 and 32000 scoped to the browser machine's IP, an `/etc/hosts`
  entry pointing `*.127.0.0.1.nip.io` at the instance's public IP, and a
  local `socat` proxy for port 32000 specifically (Dex's redirect is
  hardcoded to literal `localhost`).

**Cleanup owed** (uncommitted temporary changes, not in git — revert once
the demo session is done):
- Security group `sg-0627cdd4c2eaf1b5f` has inbound rules for ports 443 and
  32000 scoped to whatever the browser machine's IP was at the time (it
  changed at least twice across this work — check current rules with
  `aws ec2 describe-security-groups --group-ids sg-0627cdd4c2eaf1b5f` before
  assuming which IP(s) are still allowed) —
  `aws ec2 revoke-security-group-ingress --group-id sg-0627cdd4c2eaf1b5f --protocol tcp --port 443 --cidr 51.102.170.48/32`
  once no longer needed (that IP may also have changed by tomorrow).
- The Mac's `/etc/hosts` has a line pointing `backstage.127.0.0.1.nip.io` /
  `muster.127.0.0.1.nip.io` / `agentgateway.127.0.0.1.nip.io` at
  `63.179.117.4` — remove it once the SSM tunnel path works again, or if the
  instance is ever re-launched (the IP will change).

## Fixed in the scripts (already committed, apply automatically on any future launch)

1. **Ubuntu 22.04's `apt` Go is 1.18; repo needs 1.26.3.** `user-data.sh`
   installs the real toolchain from `go.dev` directly instead of the apt
   package.
2. **cloud-init user-data has no `$HOME`.** `ollama` panics without it
   (`$HOME is not defined`), and so does Go's build cache. `export HOME=/root`
   up front.
3. **`set -uxo pipefail` (no `-e`) let real failures cascade silently** into
   a false "bootstrap complete" — the Go build failed, so *nothing* after it
   ran, but the script kept going anyway and printed success. Fixed to
   `set -euxo pipefail`.
4. **`kubectl` was never installed.** agentlab embeds its own k8s client and
   has no need for a `kubectl` binary itself, but a human debugging over
   Session Manager does. Installed explicitly now.
5. **`giantswarm/agent-platform` chart 4.49.0 (this build's pinned default)
   has a known bug**: signed charts (e.g. `cloudnative-pg` 0.29.1 on
   `ghcr.io`) publish two OCI layers — the chart and its PGP provenance
   file — and the `OCIRepository` has no `layerSelector`, so Flux's
   `source-controller` extracts `layers[0]`, which can be the provenance
   file, and fails trying to gunzip a plain-text signature
   (`requires gzip-compressed body: gzip: invalid header`). This cascades
   into every dependent HelmRelease (`substrate`, `agent-manager`,
   `backstage`, `kagent`, `model-manager`) reading "dependency not ready"
   forever, with no hint it's this specific chart bug.
   Fixed upstream in `agent-platform` v4.65.4
   ([PR #650](https://github.com/giantswarm/agent-platform/pull/650),
   [issue #649](https://github.com/giantswarm/agent-platform/issues/649)).
   `user-data.sh` now rewrites `chartVersion` to `4.65.4` right after
   `configure --defaults` writes the older default.
6. **30GB root volume filled up completely**, which took the whole control
   plane down with it (`etcd` is very disk-sensitive; when the disk hit
   100%, `etcd`/`kube-apiserver`/`kube-controller-manager`/`kube-scheduler`
   all restarted, and several other pods that happened to restart in that
   exact window crashed trying to reach the API and sat in
   `CrashLoopBackOff` on stale exponential backoff even after the API
   recovered — `kubectl delete pod ...` on the stuck ones forced an
   immediate healthy retry). `launch-instance.sh` now provisions 60GB.
7. **The Homebrew cask `session-manager-plugin` was stale/incompatible**
   with a current AWS CLI v2 (2.36.34) — every session type failed client-side
   with `Plugin with name <X> not found` (seen for both `Standard_Stream`
   and `Port`). Fixed by installing AWS's own bundle directly instead of the
   brew cask:
   ```bash
   curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/sessionmanager-bundle.zip" -o sessionmanager-bundle.zip
   unzip sessionmanager-bundle.zip
   mkdir -p ~/bin && cp sessionmanager-bundle/bin/session-manager-plugin ~/bin/
   chmod +x ~/bin/session-manager-plugin
   echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc   # persists to new terminals
   ```
   This has no admin/sudo requirement (drops into the user's own `~/bin`),
   which matters if the Mac has restricted admin rights.
8. **Two `aws` binaries on the Mac** (`/usr/local/bin/aws` shadowing the
   Homebrew one) — turned out to be a red herring tonight (both were CLI v2,
   `/usr/local/bin/aws` was `2.36.34`, perfectly current) but worth a sanity
   check (`which aws && aws --version`) if CLI errors look version-related.
9. **SSO-based AWS login, not an IAM user.** `aws sts get-caller-identity`
   showed an `assumed-role` ARN (`AWS_881490131520_Admin/...`), so
   `aws iam create-access-key` can never work (no IAM user object exists).
   Workaround used: `aws configure export-credentials --format env` in
   CloudShell, paste the three `export` lines into the Mac terminal, plus
   `export AWS_DEFAULT_REGION=eu-central-1` (region isn't included). These
   are temporary session-token credentials and **expire** — re-run
   `export-credentials` and re-paste whenever `aws sts get-caller-identity`
   starts failing with a credentials/token error.

## RESOLVED: browser access to Backstage

**The clean procedure is now `GETTING_STARTED.md` — follow that for a new
setup.** Summary of what the real root causes turned out to be:

1. `aws ssm start-session --document-name AWS-StartPortForwardingSession`
   never worked in this account/session (`Plugin with name Port not
   found`, even with a correctly reinstalled official plugin and working
   plain shell sessions) — never root-caused, possibly an org-level SSM
   document restriction. **Abandoned in favor of a different mechanism**,
   not fixed.
2. The *real* blocker turned out to be upstream `agentlab` binding every
   kind port mapping to `127.0.0.1` only (confirmed via `ss -tlnp` showing
   `docker-proxy` on `127.0.0.1:443`, and an instant "connection refused"
   from any external client — categorically different from a
   security-group timeout). **Fixed in this fork**: changed
   `internal/lab/templates/kind-config.yaml.tmpl` to bind `0.0.0.0`
   instead (commit `b3e7304`). Requires `agentlab down && up` to take
   effect on an already-running instance.
3. With that fixed, a security-group rule scoped to one's own IP (for
   ports 443 and 32000) plus a `/etc/hosts` entry pointing
   `*.127.0.0.1.nip.io` at the instance's public IP got Backstage's own
   page loading.
4. Sign-in still failed one layer deeper: Dex's OAuth redirect is
   hardcoded to the literal string `localhost` (not a `*.nip.io` name),
   which `/etc/hosts` can't safely override system-wide. Fixed with a
   local `socat TCP-LISTEN:32000,fork,reuseaddr TCP:<public-ip>:32000`
   proxy on the client machine, so `localhost:32000` transparently reaches
   the instance.
5. One IP-address gotcha hit along the way: the security-group rule is
   scoped to a specific `/32` and needs updating whenever the client's
   public IP changes (it changed twice across this session) — always
   re-check `curl -s https://checkip.amazonaws.com` on the actual browser
   machine (not CloudShell, which has its own separate IP) before assuming
   the network path is broken.
6. Chrome specifically can fail where Firefox succeeds, due to Chrome's
   "Secure DNS" (DoH) bypassing the `/etc/hosts` override — turn it off at
   `chrome://settings/security` if hit.

## Free-model / no-Anthropic-key path (working, confirmed)

`agentlab.yaml` has `platform.extraModels: [{name: qwen35-2b, provider:
Ollama, model: qwen3.5:2b, baseUrl: http://<kind-gateway>:11434, think:
false}]`. `factory/agents/*.yaml` already reference `modelConfig: qwen35-2b`.
No Anthropic key was used or needed across any of this — everything above
is on the free path.

## Session 3: agents created, one real gap found (pick up here)

**All three factory agents exist in Backstage and are `Ready`**:
`machine-monitor`, `maintenance-dispatcher`, `supervisor` (created via the
UI wizard, not `agent-manager_create_agent` directly — the live prompts
now differ from `factory/agents/*.yaml` on disk, see below).

**Two real bugs found and fixed in the repo** (pull to get them on any
fresh instance):
- `qwen35-2b`'s `baseUrl` used whichever IPAM config entry Docker listed
  first for the `kind` network, which was IPv6 this run
  (`fc00:f853:ccd:e793::1`) — unbracketed in a URL, breaks Go's parser,
  every agent using the model failed its "golden boot" in an infinite
  retry loop. Fixed in `user-data.sh` to filter for the IPv4 entry
  specifically (commit `54c59e0`). **On the live instance this still
  needed a manual one-off fix** (re-patch `agentlab.yaml`'s `baseUrl` with
  the correct IPv4 gateway, then `agentlab platform`) since the bug had
  already written the bad value before the fix landed.
- The factory simulator's random walk had a positive-bias asymmetric
  noise term and no upper clamp — temperatures/vibration climbed
  unboundedly (129-194°C observed after ~20 min), making every reading
  "anomalous" with nothing normal to contrast against. Fixed with proper
  mean-reversion + a hard clamp (commit `f3c1802`). Redeploy with
  `./factory/simulator/apply.sh` after `git pull` if the live instance's
  simulator predates this fix.

**The free 2B model needs unusually explicit prompts and narrow toolsets**
to work at all — three escalating rounds were needed for `machine-monitor`
before it reliably worked:
1. Named tool wrong (`promql_query` instead of `x_mcp-prometheus_execute_query`)
2. Right tool, invented invalid PromQL wildcard syntax (`factories/*:factory_machine_*`)
3. Fixed by (a) restricting its toolset from all 18 `mcp-prometheus` tools
   down to just the one it needs, and (b) rewriting the prompt as an
   explicit numbered script ("Call 1: query = <exact literal string>")
   instead of prose describing what to do. The live prompt (in Backstage,
   not yet copied back to `factory/agents/machine-monitor.yaml` — the
   file still needs updating with this session's final working
   version) is:
   ```
   You have exactly one tool: x_mcp-prometheus_execute_query. It takes one
   argument, "query". You monitor 4 factory machines: press-1, press-2,
   cnc-1, conveyor-1.

   Call the tool 3 times, once for each of these exact strings as the
   "query" argument. Copy them character for character. Never add "*",
   never add "/", never combine them, never add a machine name to them:

   Call 1: query = factory_machine_temperature_celsius
   Call 2: query = factory_machine_vibration_index
   Call 3: query = factory_machine_throughput_units_per_min
   ...
   ```
   With this it correctly makes all 3 calls and produces a real answer —
   but still takes 1-3 minutes and tens of thousands of tokens (no cost:
   local model). `maintenance-dispatcher` and `supervisor` have **not**
   been similarly hardened/tested yet — expect the same class of problem
   the first time each is actually exercised.

**Confirmed gap, not yet fixed: `supervisor` cannot delegate.** Asked
"What is the current status of the factory?" with its toolset empty (`No
tools`, as designed per `factory/agents/supervisor.yaml`), and it just
asked a clarifying question in plain text — **no tool call appeared at
all**. The assumption in `factory/README.md`/the agent prompts that an
agent can reach another named agent "over A2A / muster" was never
actually verified; it may require an explicit toolset entry (unclear
which one — needs research into whether kagent/muster expose sibling
agents as callable tools at all, and if so how to declare that in an
`AgentTemplate`/Backstage's wizard) rather than working automatically
with an empty toolset. **This is the next thing to solve** before the
3-agent chain can work end to end.

**Also delivered this session**: a 5-slide CIO-facing PPTX
(`giant-swarm-agent-platform.pptx`, sent to the user, not committed to
the repo) covering what the platform is, what was stood up, the smart
factory pilot, and next steps — built with LibreOffice visual QA
unavailable in that sandbox (confirmed broken on even a blank test file),
so it only got schema/structural validation, not a pixel-level check.

**Cleanup still owed** (temporary, not in git, same as before): security
group rules for ports 443 and 32000 scoped to whatever the browser
machine's IP was at the time, an `/etc/hosts` entry on that machine, and
a `socat` process that needs to be running for port 32000 access — none
of this persists automatically; expect to redo the browser-access steps
in `GETTING_STARTED.md` section 5 next session if the IP has changed or
the socat process was killed.
