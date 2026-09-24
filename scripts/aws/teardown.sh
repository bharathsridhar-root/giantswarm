#!/bin/bash
# Terminates the agentlab demo instance launched by launch-instance.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_ID="${1:-$(cat "$SCRIPT_DIR/.last-instance-id" 2>/dev/null || true)}"

if [ -z "$INSTANCE_ID" ]; then
  echo "Usage: $0 <instance-id>  (or run from a shell where launch-instance.sh left .last-instance-id)"
  exit 1
fi

echo "Terminating $INSTANCE_ID..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"
echo "Done. The security group agentlab-no-inbound and the IAM role/profile are left in place for next time."
