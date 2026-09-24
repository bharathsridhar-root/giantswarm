# Running agentlab on EC2 with no SSH access

For accounts where SSH (port 22 inbound) is blocked by policy. Everything
here uses **AWS Systems Manager Session Manager** instead: the instance
opens no inbound ports at all (outbound HTTPS only, to the SSM service),
and you get a shell either from the EC2 console's browser-based "Connect"
button or the AWS CLI — no key pair, no security-group hole. The whole
lab install is also unattended: `user-data.sh` runs at first boot and does
`configure --defaults` + `up` for you, so there is nothing to type once the
instance is launched other than to watch the log.

## One-time setup (run in AWS CloudShell, or any shell with AWS CLI + IAM permissions)

```bash
cd scripts/aws
chmod +x *.sh
./setup-ssm-role.sh
```

This creates an IAM role (`agentlab-ec2-role`) with `AmazonSSMManagedInstanceCore`
(what makes Session Manager work) plus read access to a `/agentlab/*` SSM
parameter path, and an instance profile the launch script attaches.

Then store your Anthropic key (required) and GitHub token (optional, lifts
a rate limit) as SecureString parameters — the instance decrypts them at
boot, they're never in plaintext user-data or the EC2 console:

```bash
aws ssm put-parameter --name /agentlab/anthropic-api-key --type SecureString --value 'sk-ant-...' --overwrite
aws ssm put-parameter --name /agentlab/github-token       --type SecureString --value 'github_pat_...' --overwrite   # optional
```

## Launch

```bash
./launch-instance.sh
```

Boots an `m5.xlarge` (4 vCPU/16 GiB — agentlab's floor) Ubuntu 22.04 box,
no SSH key, no open inbound ports, with `user-data.sh` attached. It prints
the instance ID and the command to watch progress.

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

## Re-running with a key added after boot

If you launched before setting `/agentlab/anthropic-api-key`, set it, then
from a Session Manager shell:
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
