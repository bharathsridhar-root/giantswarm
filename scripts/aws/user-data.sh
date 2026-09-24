#!/bin/bash
# EC2 user-data: unattended bootstrap for the agentlab demo.
# Runs once at first boot as root (cloud-init). Everything is logged to
# /var/log/agentlab-setup.log for tailing over Session Manager or the
# EC2 serial console — there is no SSH access to this instance by design.
set -uxo pipefail
exec > >(tee -a /var/log/agentlab-setup.log) 2>&1
echo "=== agentlab bootstrap starting $(date -u) ==="

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io golang-go git awscli jq
systemctl enable --now docker

# Region from IMDSv2 (the instance role has no local AWS config file).
IMDS_TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
export AWS_DEFAULT_REGION
AWS_DEFAULT_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/region)

echo "Fetching secrets from SSM Parameter Store in $AWS_DEFAULT_REGION..."
ANTHROPIC_API_KEY=$(aws ssm get-parameter --name /agentlab/anthropic-api-key \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)
GITHUB_TOKEN=$(aws ssm get-parameter --name /agentlab/github-token \
  --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "WARNING: /agentlab/anthropic-api-key not set in SSM — the lab installs" \
       "without a working model key. Put the parameter and re-run" \
       "'./agentlab platform' (see scripts/aws/README.md) once it's set."
fi
export ANTHROPIC_API_KEY GITHUB_TOKEN

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

echo "Running agentlab configure --defaults..."
./agentlab configure --defaults

echo "Running agentlab up (this pulls several GiB of images, several minutes)..."
./agentlab up --trust=false --open=false

echo "=== agentlab up finished $(date -u) — running platform-test ==="
./agentlab platform-test || echo "platform-test reported issues — check the log above"

chown -R ubuntu:ubuntu "$REPO_DIR"
echo "=== bootstrap complete $(date -u) ==="
echo "Portal:  https://backstage.127.0.0.1.nip.io  (tunnel port 443 from your Mac, see scripts/aws/README.md)"
echo "Users:   admin@lab.local / dev@lab.local / viewer@lab.local, password: password"
