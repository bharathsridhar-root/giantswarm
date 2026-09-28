# Getting agentlab running on EC2, from scratch

The clean, validated end-to-end procedure — everything that was fought
through to get here is in `RUNBOOK.md`; this doc is just "do this, in this
order" for a fresh setup or a fresh instance.

**Who this is for**: an AWS account where you cannot SSH into instances
directly, and (as discovered the hard way) where AWS Systems Manager's
port-forwarding session type doesn't work even with a correctly configured
client — so this doc's browser-access method is a local TCP proxy
(`socat`) over a security-group rule scoped to your own IP, not SSM
tunneling. If SSM port-forwarding *does* work in your account, skip
straight to "Alternative: SSM port-forwarding" near the end — it's simpler
when it works.

## Prerequisites

- AWS CloudShell access (or any shell with the AWS CLI + IAM permissions
  for EC2/IAM)
- A Mac/Linux terminal with `curl`, and [Homebrew](https://brew.sh) if on
  macOS
- This repo's branch checked out somewhere you can push from (only needed
  if you're changing the scripts themselves, not for a normal run)

## 1. One-time IAM setup (CloudShell)

```bash
git clone --branch claude/gracious-brahmagupta-5t9eh1 https://github.com/bharathsridhar-root/giantswarm.git
cd giantswarm/scripts/aws
chmod +x *.sh
./setup-ssm-role.sh
```

Creates the IAM role/instance profile the instance uses for Session
Manager access. Safe to re-run.

## 2. Launch the instance (CloudShell)

```bash
./launch-instance.sh
```

- No SSH key, no inbound ports open by default — everything reachable only
  via Session Manager until you deliberately open ports in step 5.
- Prints the instance ID. **Save it** — every command below needs it.
- Defaults: `m5.2xlarge` (8 vCPU/32 GiB), 60 GiB disk, free Ollama model
  (`qwen35-2b`), no Anthropic key required. See `README.md` if you want an
  Anthropic-key path instead.
- Scans every VPC/subnet for one with real internet egress and picks it
  automatically — if it errors saying none qualify, your account genuinely
  has no internet-routable subnet; see `RUNBOOK.md`'s network section.

## 3. Watch the bootstrap (10-25 minutes)

Either the EC2 console (**Instances → your instance → Connect → Session
Manager tab → Connect**) or from a shell with the AWS CLI:

```bash
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/agentlab-setup.log
```

Wait for:
```
=== bootstrap complete ===
Portal:  https://backstage.127.0.0.1.nip.io
```

If it fails partway, `RUNBOOK.md` documents every failure mode already hit
and fixed (stale apt Go, missing `$HOME`, a chart bug, a full disk, and
more) — check there before re-deriving a fix.

## 4. Verify the platform is actually healthy

Still in the Session Manager shell:
```bash
sudo -i
cd /opt/agentlab
export KUBECONFIG=/opt/agentlab/state/kubeconfig
./agentlab platform-test
```
Every line should end `PASS`. If not, fix that before moving on to browser
access — a browser problem is much harder to diagnose on top of a platform
that isn't actually healthy.

## 5. Get Backstage into your actual browser

This is the part that needed real debugging (see `RUNBOOK.md` "Unresolved:
browser access" — now resolved). The lab's port mappings are bound to
`0.0.0.0` (this fork's change from upstream's `127.0.0.1`-only default —
see the git history on `internal/lab/templates/kind-config.yaml.tmpl`), so
reachability is gated purely by the EC2 security group, which we open only
to your specific IP.

**5a. Find your current public IP** (run on the machine with the browser,
not CloudShell — they can differ):
```bash
curl -s https://checkip.amazonaws.com
```

**5b. Open the two ports you need, scoped to that IP** (CloudShell — this
needs your own IAM permissions, not the instance's role):
```bash
aws ec2 authorize-security-group-ingress --group-id <security-group-id> --protocol tcp --port 443 --cidr <your-ip>/32
aws ec2 authorize-security-group-ingress --group-id <security-group-id> --protocol tcp --port 32000 --cidr <your-ip>/32
```
(port 443 is Backstage/muster/the gateway; port 32000 is Dex, needed for
the OAuth sign-in redirect specifically)

**5c. Get the instance's public IP** (CloudShell):
```bash
aws ec2 describe-instances --instance-ids <instance-id> --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
```

**5d. Point the lab's hostname at that IP** (on your browser machine —
this is safe and standard; it only affects DNS resolution for these exact
names, nothing else):
```bash
sudo sh -c 'echo "<public-ip>  backstage.127.0.0.1.nip.io muster.127.0.0.1.nip.io agentgateway.127.0.0.1.nip.io observability.127.0.0.1.nip.io" >> /etc/hosts'
```
(on macOS, `/etc/hosts` needs `sudo` to edit; use `sudo nano /etc/hosts` if
you'd rather edit by hand)

**5e. Proxy port 32000 locally** (Dex's redirect is hardcoded to the
literal string `localhost`, which is *your* machine, not the EC2 instance
— `/etc/hosts` can't safely override `localhost` itself without breaking
every other local tool that uses it, so a local proxy is the fix):
```bash
brew install socat   # one-time
socat TCP-LISTEN:32000,bind=127.0.0.1,fork,reuseaddr TCP:<public-ip>:32000
```
**The `bind=127.0.0.1` matters**: without it, `socat` listens on every
network interface, not just loopback — anyone else on the same network as
your machine (shared WiFi, hotel network) could then tunnel through your
box to reach the EC2 instance's Dex port, bypassing the security-group IP
restriction entirely (the outbound leg still comes from your machine's own
trusted IP). Binding to loopback closes that off.

Run this in its own terminal tab and **leave it running** for the whole
session; stop it (Ctrl+C) when you're done.

**5f. Verify before touching the browser**:
```bash
curl -v -k --max-time 10 https://backstage.127.0.0.1.nip.io 2>&1 | tail -10
curl -v -k --max-time 10 https://localhost:32000/dex/.well-known/openid-configuration 2>&1 | tail -10
```
Both should return real content (an HTML page / a JSON OIDC discovery
document), not a timeout or refusal.

**5g. Open the browser**:
```
https://backstage.127.0.0.1.nip.io
```
Click through the certificate warning (self-signed lab CA), click **Sign
In**, then in the popup sign in as `admin@lab.local` / password `password`.

**If Chrome fails but Firefox (or Firefox Incognito) works**: Chrome's
"Secure DNS" (DNS-over-HTTPS) can bypass your `/etc/hosts` override.
`chrome://settings/security` → turn off "Use secure DNS", or clear
`chrome://net-internals/#dns`'s host cache, then retry.

## 6. Your IP will change — redo step 5a/5b when it does

Corporate networks/VPNs commonly rotate egress IPs. If step 5f's `curl`
tests suddenly start timing out (not refusing — timing out specifically),
recheck `curl -s https://checkip.amazonaws.com` and re-run the
`authorize-security-group-ingress` commands with the new IP (the old rule
can be left in place or revoked with the equivalent `revoke-` command).

## Resuming after a stop (do this every time you come back)

Stopping the instance (see "Tearing down" below — `stop-instances`, not
`terminate-instances`) keeps everything intact and free of charge, but a
**new public IP** is assigned on every start, so the browser-access setup
(security group rule, `/etc/hosts`, `socat`) needs redoing from scratch
each time. The platform itself needs nothing redone — same disk, same
cluster, same agents.

```bash
# 1. Start it (CloudShell)
aws ec2 start-instances --instance-ids <instance-id>
# wait ~30-60s, then get the new public IP:
aws ec2 describe-instances --instance-ids <instance-id> \
  --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' --output text

# 2. Confirm the platform survived the reboot cleanly (Session Manager)
aws ssm start-session --target <instance-id>
sudo -i
cd /opt/agentlab
export KUBECONFIG=/opt/agentlab/state/kubeconfig
./agentlab platform-test
```

A pod or two restarting once right after boot (racing Dex coming back up)
is normal and self-heals within a minute or two — check
`kubectl get pods -A | grep -v Running | grep -v Completed`; if restart
counts aren't climbing and everything is `Running`, it's fine even if
`platform-test` flags a historical restart count.

Then redo browser access exactly as in step 5, with the **new** IP:
```bash
# get your current IP (on the browser machine, not CloudShell):
curl -s https://checkip.amazonaws.com

# CloudShell — open the security group for it:
aws ec2 authorize-security-group-ingress --group-id <sg-id> --protocol tcp --port 443 --cidr <your-ip>/32
aws ec2 authorize-security-group-ingress --group-id <sg-id> --protocol tcp --port 32000 --cidr <your-ip>/32

# on the browser machine — update /etc/hosts with the NEW instance IP,
# then start the tunnel with the NEW instance IP:
socat TCP-LISTEN:32000,bind=127.0.0.1,fork,reuseaddr TCP:<new-instance-ip>:32000

# verify before touching the browser:
curl -v -k --max-time 10 https://backstage.127.0.0.1.nip.io 2>&1 | tail -10
```

### If the `curl` verify times out (not "connection refused")

Work through these in order — a **timeout** (not an instant refusal)
almost always means the security group, not the instance:

1. **Wrong/stale IP** — the most common cause. Re-run
   `checkip.amazonaws.com` on the *browser* machine specifically (not
   CloudShell — they have different IPs), confirm the security-group rule
   actually has that exact IP:
   ```bash
   aws ec2 describe-security-groups --group-ids <sg-id> \
     --query 'SecurityGroupRules[?FromPort==`443` || FromPort==`32000`]'
   ```
2. **Confirm the instance side is actually fine** (Session Manager):
   ```bash
   ss -tlnp | grep -E ':443|:32000'   # should show docker-proxy on 0.0.0.0
   docker ps                          # agentlab-control-plane should be Up
   ```
3. **Test from a completely different network path** to isolate client vs.
   AWS-side: from CloudShell (unrestricted egress),
   `curl -v -k --max-time 10 https://<instance-ip>:443` — a TLS error
   (`unexpected eof`) here is actually **success** (it reached the server;
   it just failed because a bare IP has no matching SNI) — what matters is
   whether it *connects* instead of timing out.
4. **If CloudShell connects fine but your machine still times out**:
   confirmed — **a corporate network can silently block this specific
   outbound connection** even though nothing about the AWS setup is wrong.
   This actually happened during development on a Deloitte-managed
   laptop/network: identical setup, correct security group, correct
   listener — timed out on the corporate network, connected instantly over
   a **phone hotspot**. If you hit this, tethering to a hotspot is the
   fastest fix; getting it working on the corporate network would need
   your IT team to allowlist outbound HTTPS to the instance's IP, which is
   awkward since that IP changes on every stop/start.
   Isolate it with a raw TCP test (no TLS, so it can't be a cert/SNI
   issue): `nc -zv -G 5 <instance-ip> 443` — a bare timeout here, with
   nothing else explaining it, points straight at network-level blocking.

## 7. Create the smart factory agents

Once logged in, use Backstage's create-agent wizard (or script it through
muster) using the specs in `factory/agents/*.yaml` — see `factory/README.md`.
They're pre-wired to the free `qwen35-2b` Ollama model, no Anthropic key
needed.

## 8. Tearing down / cleaning up

```bash
# CloudShell — revoke the security-group rules once done:
aws ec2 revoke-security-group-ingress --group-id <security-group-id> --protocol tcp --port 443 --cidr <your-ip>/32
aws ec2 revoke-security-group-ingress --group-id <security-group-id> --protocol tcp --port 32000 --cidr <your-ip>/32

# terminate the instance entirely:
cd scripts/aws && ./teardown.sh <instance-id>
```
Also stop the `socat` process (Ctrl+C in its terminal) and remove the
`/etc/hosts` line you added.

## Alternative: SSM port-forwarding (if it works in your account)

This is architecturally simpler than the socat/security-group dance above
— no security-group changes, no `/etc/hosts` editing, no local proxy
process. It didn't work in the account this was developed against (every
session type beyond a plain shell failed client-side with `Plugin with
name <X> not found`, even with a fresh official `session-manager-plugin`
install — see `RUNBOOK.md`), which may be an account-specific IAM/SCP
restriction on that SSM document. Worth trying first in a new account:

```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["443"],"localPortNumber":["443"]}'
```
Then just `https://backstage.127.0.0.1.nip.io` directly (no `/etc/hosts`
edit needed — `nip.io` already resolves that to `127.0.0.1`, which is
exactly what the tunnel listens on). Repeat for port 32000 in a second
terminal tab if Dex sign-in needs it directly.
