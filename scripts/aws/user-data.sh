#!/bin/bash
# EC2 user-data: unattended bootstrap for the agentlab demo, running fully
# free — no Anthropic key, no paid API of any kind. Agents run on a small
# local Ollama model (qwen3.5:2b, free, CPU-only) instead of Claude.
# Runs once at first boot as root (cloud-init). Everything is logged to
# /var/log/agentlab-setup.log for tailing over Session Manager or the
# EC2 serial console — there is no SSH access to this instance by design.
set -uxo pipefail
exec > >(tee -a /var/log/agentlab-setup.log) 2>&1
echo "=== agentlab bootstrap starting $(date -u) ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io golang-go git awscli jq python3-yaml
systemctl enable --now docker

# Region from IMDSv2 (the instance role has no local AWS config file).
IMDS_TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
export AWS_DEFAULT_REGION
AWS_DEFAULT_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

# Optional: only used if you *do* want Claude-quality agents and stored a
# key in SSM. Nothing below requires it — the lab and the factory demo work
# entirely on the free local model without it.
ANTHROPIC_API_KEY=$(aws ssm get-parameter --name /agentlab/anthropic-api-key \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)
GITHUB_TOKEN=$(aws ssm get-parameter --name /agentlab/github-token \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)
export ANTHROPIC_API_KEY GITHUB_TOKEN
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  echo "Anthropic key found in SSM — the chart's default Anthropic ModelConfig will also be wired (real cost per call)."
else
  echo "No Anthropic key in SSM — proceeding free-only, agents use the local Ollama model below."
fi

echo "=== Installing Ollama (free, local, CPU inference) ==="
curl -fsSL https://ollama.com/install.sh | sh

# Ollama must listen on more than loopback: pods reach the host through the
# kind docker network's gateway, not localhost (docs/models.md "Local
# backends on the lab host"). Also raise the context window — the default
# 4096 tokens is too small once agent tool schemas are added to a prompt
# (docs/models.md "Context length (Ollama)").
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_CONTEXT_LENGTH=32768"
EOF
systemctl daemon-reload
systemctl enable --now ollama
sleep 5

echo "Pulling qwen3.5:2b (~2.7 GB, free, tool-calling-capable, proven in docs/models.md)..."
ollama pull qwen3.5:2b

REPO_DIR=/opt/agentlab
REPO_URL="https://github.com/bharathsridhar-root/giantswarm.git"
REPO_BRANCH="claude/gracious-brahmagupta-5t9eh1"

if [ -d "$REPO_DIR/.git" ]; then
  echo "Repo already present, pulling latest..."
  git -C "$REPO_DIR" fetch origin "$REPO_BRANCH"
  git -C "$REPO_DIR" checkout "$REPO_BRANCH"
  git -C "$REPO_DIR" reset --hard "origin/$REPO_BRANCH"
else
  git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
fi
cd "$REPO_DIR"

echo "Building agentlab..."
go build -o agentlab .

echo "Running agentlab configure --defaults (auto-detects the Ollama we just started)..."
./agentlab configure --defaults

echo "Wiring the free local model as an extraModel (platform.extraModels: qwen35-2b)..."
KIND_GATEWAY=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.21.0.1")
python3 - "$KIND_GATEWAY" <<'PYEOF'
import sys, yaml

gateway = sys.argv[1]
path = "agentlab.yaml"
with open(path) as f:
    cfg = yaml.safe_load(f) or {}

cfg.setdefault("platform", {})
extra = cfg["platform"].setdefault("extraModels", [])
if not any(m.get("name") == "qwen35-2b" for m in extra):
    extra.append({
        "name": "qwen35-2b",
        "provider": "Ollama",
        "model": "qwen3.5:2b",
        "baseUrl": f"http://{gateway}:11434",
        "think": False,
    })

with open(path, "w") as f:
    yaml.safe_dump(cfg, f, sort_keys=False)
PYEOF

echo "Running agentlab up (pulls several GiB of platform images, several minutes)..."
./agentlab up --trust=false --open=false

echo "=== agentlab up finished $(date -u) — running platform-test ==="
./agentlab platform-test || echo "platform-test reported issues — check the log above"

chown -R ubuntu:ubuntu "$REPO_DIR"
echo "=== bootstrap complete $(date -u) ==="
echo "Portal:  https://backstage.127.0.0.1.nip.io  (tunnel port 443 from your Mac, see scripts/aws/README.md)"
echo "Users:   admin@lab.local / dev@lab.local / viewer@lab.local, password: password"
echo "Free model ModelConfig: qwen35-2b (Ollama, qwen3.5:2b) — select it when creating an agent."
