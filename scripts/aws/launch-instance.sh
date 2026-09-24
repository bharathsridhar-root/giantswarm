#!/bin/bash
# Launches the agentlab demo EC2 instance: no SSH key, no open inbound
# ports — reachable only through SSM Session Manager. Run from CloudShell
# (or any shell with the AWS CLI configured) after scripts/aws/setup-ssm-role.sh
# and after storing the SSM parameters it printed.
set -euo pipefail

INSTANCE_TYPE="${INSTANCE_TYPE:-m5.2xlarge}"  # 8 vCPU / 32 GiB — agentlab's 4-CPU/6GiB floor
                                               # plus headroom for Ollama running the free model
                                               # alongside it (see user-data.sh). m5.xlarge (4/16)
                                               # works if you skip the free model and bring your
                                               # own Anthropic key instead.
VOLUME_SIZE="${VOLUME_SIZE:-30}"              # GiB; default 8GiB root disk is too small
NAME_TAG="${NAME_TAG:-agentlab-demo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Looking up the latest Ubuntu 22.04 AMI for this region..."
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
  --query 'Parameter.Value' --output text)
echo "  AMI: $AMI_ID"

echo "Creating a security group with no inbound rules (SSM needs only outbound 443)..."
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
SG_ID=$(aws ec2 create-security-group \
  --group-name agentlab-no-inbound \
  --description "agentlab demo — outbound only, reached via SSM" \
  --vpc-id "$VPC_ID" --query 'GroupId' --output text 2>/dev/null || \
  aws ec2 describe-security-groups --filters Name=group-name,Values=agentlab-no-inbound \
    Name=vpc-id,Values="$VPC_ID" --query 'SecurityGroups[0].GroupId' --output text)
echo "  Security group: $SG_ID (no ingress rules added — nothing is open to the internet)"

echo "Launching $INSTANCE_TYPE..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --iam-instance-profile Name=agentlab-ec2-profile \
  --security-group-ids "$SG_ID" \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\"}}]" \
  --user-data "file://$SCRIPT_DIR/user-data.sh" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME_TAG}]" \
  --metadata-options "HttpTokens=required" \
  --query 'Instances[0].InstanceId' --output text)

echo
echo "Instance launched: $INSTANCE_ID"
echo "No SSH key was used and no inbound ports are open — this instance is reachable only via SSM."
echo
echo "Watch the bootstrap (takes several minutes — Docker install, image pulls, kind cluster, the platform):"
echo "  aws ssm start-session --target $INSTANCE_ID"
echo "  # then inside the session:"
echo "  sudo tail -f /var/log/agentlab-setup.log"
echo
echo "Or use the EC2 console: Instances -> $INSTANCE_ID -> Connect -> Session Manager tab -> Connect"
echo "(this works from the AWS browser console with zero local setup)"
echo
echo "Once it's done, forward the portal to your Mac — see scripts/aws/README.md 'Reaching the portal'."
echo "$INSTANCE_ID" > "$SCRIPT_DIR/.last-instance-id"
