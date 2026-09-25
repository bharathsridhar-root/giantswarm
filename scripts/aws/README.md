# Running agentlab on EC2 with no SSH access

**Picking this up after a break? Read `RUNBOOK.md` first** — it has the
exact state of the last live instance, what's still unresolved, and every
gotcha already hit and fixed (stale Go/kubectl, a chart bug, a full disk, a
stale `session-manager-plugin`, SSO vs IAM-user credentials) so you don't
re-discover any of it.

For accounts where SSH (port 22 inbound) is blocked by policy. Everything
here uses **AWS Systems Manager Session Manager** instead: the instance
opens no inbound ports at all (outbound HTTPS only, to the SSM service),
and you get a shell either from the EC2 console's browser-based "Connect"
button or the AWS CLI — no key pair, no security-group hole. The whole
lab install is also unattended and **entirely free by default**:
`user-data.sh` runs at first boot, installs [Ollama](https://ollama.com)
and pulls a small free model (`qwen3.5:2b`, ~2.7 GB, CPU-only, proven
tool-calling-capable in `docs/models.md`), wires it as a kagent
`ModelConfig` named `qwen35-2b`, then runs `configure --defaults` + `up`.
No Anthropic API key, no credit card, nothing but EC2's own hourly cost.
There is nothing to type once the instance is launched other than to watch
the log.

If you'd rather use real Claude models (better answers, still costs
per-call on top of EC2), that's still supported — see "Using Claude
instead of the free model" below. It's opt-in, not required.

## One-time setup (run in AWS CloudShell, or any shell with AWS CLI + IAM permissions)

```bash
cd scripts/aws
chmod +x *.sh
./setup-ssm-role.sh
```

This creates an IAM role (`agentlab-ec2-role`) with `AmazonSSMManagedInstanceCore`
(what makes Session Manager work) plus read access to a `/agentlab/*` SSM
parameter path, and an instance profile the launch script attaches. **No
SSM parameters are required for the free path** — skip straight to Launch.

## Launch

```bash
./launch-instance.sh
```

Boots an `m5.2xlarge` (8 vCPU/32 GiB) Ubuntu 22.04 box, no SSH key, no open
inbound ports, with `user-data.sh` attached. The extra headroom over
agentlab's bare 4-CPU/6GiB floor is for Ollama running alongside the
platform — set `INSTANCE_TYPE=m5.xlarge` before running the script if
you're using a real Anthropic key instead and skipping the local model
(see below). It prints the instance ID and the command to watch progress.

**EC2 cost**: `m5.2xlarge` is about $0.38/hr on-demand (`m5.xlarge` about
$0.19/hr) — this is the only real charge on the free path. Stop or
terminate the instance when you're not using it (see Tearing down).

## Watching the bootstrap

Either the EC2 console (**Instances → your instance → Connect → Session
Manager tab → Connect**, works from any browser, nothing to install), or
from a shell with the AWS CLI + the [Session Manager
plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html):

```bash
aws ssm start-session --target <instance-id>
# inside the session:
sudo tail -f /var/log/agentlab-setup.log
```

Bootstrap takes several minutes (Docker + Go install, image pulls, the kind
cluster, the full platform). It ends with `agentlab platform-test` printing
pass/fail, still in that same log.

## Reaching the portal from your Mac

The instance publishes the platform's ports (443, Dex on 32000) on
`localhost` inside the instance only — nothing is exposed externally. Get
them to your Mac with SSM port forwarding, which (unlike SSH) rides over
the same outbound-only SSM channel and isn't blocked by whatever policy
blocks SSH:

**One-time, on your Mac**: install the AWS CLI and the [Session Manager
plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
(`brew install --cask session-manager-plugin` after `brew install awscli`),
and make sure `aws configure` / your SSO login has access to this account.

```bash
aws ssm start-session \
  --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["443"],"localPortNumber":["443"]}'
```

Run a second one in another terminal tab for Dex if you need it directly:

```bash
aws ssm start-session \
  --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["32000"],"localPortNumber":["32000"]}'
```

Leave those running, then open `https://backstage.127.0.0.1.nip.io` in
your Mac browser — `nip.io` resolves to `127.0.0.1`, which is exactly what
the tunnel is listening on. Sign in as `admin@lab.local` / `dev@lab.local` /
`viewer@lab.local`, password `password`.

If your Mac can't install the CLI/plugin either, use the EC2 console's
Session Manager shell (no local install needed) to run
`curl -sk https://backstage.127.0.0.1.nip.io` from *inside* the instance to
confirm the platform itself is healthy, and drive the demo entirely through
that in-browser shell with `KUBECONFIG=/opt/agentlab/state/kubeconfig
kubectl ...` / the `agentlab *-test` commands rather than the visual portal.

## Trusting the lab CA (optional, kills the browser warning)

```bash
aws ssm start-session --target <instance-id>
sudo cat /opt/agentlab/certs/ca.crt   # copy this out, e.g. paste into a local file
```
Import it into macOS Keychain (double-click the saved file, or Keychain
Access → File → Import) and trust it for SSL — or just click through the
one browser warning for a demo.

## Claude Code / MCP from your Mac against this lab

With the 443 tunnel running:
```bash
export NODE_EXTRA_CA_CERTS=/path/to/ca.crt   # or skip and use http://localhost:8090/mcp if you exposed it
claude mcp add --transport http muster https://muster.127.0.0.1.nip.io/mcp
```

## Using the free model

Once the platform's up, create agents (Backstage's create-agent wizard, or
the `factory/` starter agents) with model **`qwen35-2b`** — that's the
`ModelConfig` `user-data.sh` wired from the Ollama running on the instance
itself. `factory/agents/*.yaml` already point at it. It's a 2B-parameter
model: fine for simple tool calls and short answers, not GPT-4-class
reasoning — see `docs/models.md` "Agent proofs without an Anthropic key"
for what it's good at and its known misses.

To check it's actually running: from a Session Manager shell,
`curl http://localhost:11434/api/tags` should list `qwen3.5:2b`.

## Using Claude instead of the free model (optional, has a real cost)

Store a key **before** launching (the instance only reads it once, at
boot):
```bash
aws ssm put-parameter --name /agentlab/anthropic-api-key --type SecureString --value 'sk-ant-...' --overwrite
aws ssm put-parameter --name /agentlab/github-token       --type SecureString --value 'github_pat_...' --overwrite   # optional, lifts a GitHub rate limit
```
`user-data.sh` picks it up automatically and wires the chart's default
Anthropic `ModelConfig` alongside the free one — use `modelConfig: default`
in an agent instead of `qwen35-2b` to use it. Set a spending limit on the
key in the Anthropic Console first; each agent turn is a billed API call.

If you launched before setting the key, add it after the fact from a
Session Manager shell:
```bash
sudo -i
cd /opt/agentlab
export ANTHROPIC_API_KEY=$(aws ssm get-parameter --name /agentlab/anthropic-api-key --with-decryption --query Parameter.Value --output text)
./agentlab platform   # idempotent — only fills the gap
```

## Tearing down

```bash
./teardown.sh <instance-id>   # or just: ./teardown.sh (uses the last launch's id)
```
Terminates the instance. The IAM role/instance profile and security group
are left so the next `launch-instance.sh` is a single command.
