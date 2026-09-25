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
- **Open loose end**: viewing Backstage in an actual Mac browser never
  worked tonight. See "Unresolved: browser access" below — pick this up
  first tomorrow.

**Cleanup owed** (uncommitted temporary changes, not in git — do these
tomorrow regardless of how browser access gets fixed):
- Security group `sg-0627cdd4c2eaf1b5f` has an inbound rule opening 443 to
  `51.102.170.48/32` (the Mac's public IP at the time) —
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

## Unresolved: browser access to Backstage

Basic `aws ssm start-session --target <id>` (plain shell) works reliably
after fix #7 above. **`--document-name AWS-StartPortForwardingSession`
still fails** with `Plugin with name Port not found` even with the
AWS-official plugin bundle installed and confirmed working for plain
sessions. Not yet root-caused — candidates for tomorrow, in likely order:

1. **A Deloitte-side IAM/SCP restriction scoped to the port-forwarding SSM
   document specifically** (allow-listing `AWS-StartSSHSession`/plain shell
   but not `AWS-StartPortForwardingSession` is a common enterprise SSM
   hardening pattern) — check the actual IAM policy attached to
   `AWS_881490131520_Admin` for an `ssm:StartSession` condition on
   `Resource: arn:aws:ssm:*:*:document/AWS-StartPortForwardingSession` or
   similar, or ask Deloitte IT directly whether SSM port forwarding is
   blocked by policy for this account.
2. Try `AWS-StartSSHSession` + real OpenSSH `-L` forwarding instead (a
   `ProxyCommand` tunneling actual SSH through SSM, no inbound port 22
   needed) — it may hit the same underlying restriction as #1 since it's
   plausibly the same stream-plugin family, but it's a different document
   name and worth ruling out.
3. The security-group + `/etc/hosts` workaround (open 443 to the Mac's own
   IP, point `backstage.127.0.0.1.nip.io` at the instance's public IP so the
   Host header/SNI still match) was set up tonight but the browser still
   failed to connect. **Prime suspect: macOS DNS/browser caching** — an
   `/etc/hosts` edit doesn't always take effect immediately.
   Try, in order, before assuming the security group itself is the problem:
   ```bash
   sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder
   ```
   then a **hard-refresh** or a brand-new browser (private window), then
   confirm resolution actually changed: `ping backstage.127.0.0.1.nip.io`
   should show `63.179.117.4` (or whatever the current public IP is), not
   `127.0.0.1`. If it still shows `127.0.0.1`, the `/etc/hosts` edit itself
   didn't save/apply — re-check `cat /etc/hosts`.
   Also double check the security group rule is actually on the right group
   (confirm `i-0b2b592e56886ca70`'s current security groups match
   `sg-0627cdd4c2eaf1b5f` exactly) and that the instance's public IP hasn't
   changed since (EC2 instances lose their public IP if stopped/started,
   though a running instance's shouldn't change).

## Free-model / no-Anthropic-key path (working, confirmed)

`agentlab.yaml` has `platform.extraModels: [{name: qwen35-2b, provider:
Ollama, model: qwen3.5:2b, baseUrl: http://<kind-gateway>:11434, think:
false}]`. `factory/agents/*.yaml` already reference `modelConfig: qwen35-2b`.
No Anthropic key was used or needed tonight — everything above is on the
free path.
