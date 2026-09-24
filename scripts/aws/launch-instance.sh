#!/bin/bash
# Launches the agentlab demo EC2 instance: no SSH key, no open inbound
# ports — reachable only through SSM Session Manager. Run from CloudShell
# (or any shell with the AWS CLI configured) after scripts/aws/setup-ssm-role.sh.
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

echo "Finding a VPC to launch into..."
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true \
  --query 'Vpcs[0].VpcId' --output text)
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "  no default VPC in this account/region — falling back to the first available VPC..."
  VPC_ID=$(aws ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)
fi
if [ -z "$VPC_ID" ] || [ "$VPC_ID" = "None" ]; then
  echo "ERROR: no VPC found in this account/region at all. Create one (the AWS console's" >&2
  echo "'Create default VPC' button under VPC settings is the fastest way) and re-run." >&2
  exit 1
fi
echo "  VPC: $VPC_ID"

echo "Finding a subnet in $VPC_ID..."
SUBNET_ID=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" \
  --query 'Subnets[0].SubnetId' --output text)
if [ -z "$SUBNET_ID" ] || [ "$SUBNET_ID" = "None" ]; then
  echo "ERROR: VPC $VPC_ID has no subnets. Pick a different VPC or create a subnet, then re-run." >&2
  exit 1
fi
echo "  Subnet: $SUBNET_ID"

echo "Checking $SUBNET_ID has a route to the internet (needed for apt/Docker/GitHub pulls and for SSM to register)..."
ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
  --filters Name=association.subnet-id,Values="$SUBNET_ID" \
  --query 'RouteTables[0].RouteTableId' --output text)
if [ -z "$ROUTE_TABLE_ID" ] || [ "$ROUTE_TABLE_ID" = "None" ]; then
  # No explicit association means the subnet uses the VPC's main route table.
  ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --filters Name=vpc-id,Values="$VPC_ID" Name=association.main,Values=true \
    --query 'RouteTables[0].RouteTableId' --output text)
fi
HAS_IGW_ROUTE=$(aws ec2 describe-route-tables --route-table-ids "$ROUTE_TABLE_ID" \
  --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && starts_with(GatewayId, 'igw-')].GatewayId" \
  --output text)
if [ -z "$HAS_IGW_ROUTE" ]; then
  echo "ERROR: subnet $SUBNET_ID has no route to an internet gateway (route table $ROUTE_TABLE_ID)." >&2
  echo "This instance would have no internet access, so it can never register with SSM and the" >&2
  echo "bootstrap would stall on its first 'apt-get update'. Pick a VPC/subnet that has a route to" >&2
  echo "an Internet Gateway (any default-VPC subnet normally does), or add one, then re-run." >&2
  exit 1
fi
echo "  route to $HAS_IGW_ROUTE confirmed"

echo "Finding or creating the agentlab-no-inbound security group..."
SG_ID=$(aws ec2 describe-security-groups \
  --filters Name=group-name,Values=agentlab-no-inbound Name=vpc-id,Values="$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text)
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  SG_ID=$(aws ec2 create-security-group \
    --group-name agentlab-no-inbound \
    --description "agentlab demo - outbound only, reached via SSM" \
    --vpc-id "$VPC_ID" --query 'GroupId' --output text)
fi
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
  echo "ERROR: could not find or create the security group. See the AWS CLI output above." >&2
  exit 1
fi
echo "  Security group: $SG_ID (no ingress rules — nothing is open to the internet)"

echo "Launching $INSTANCE_TYPE..."
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE_TYPE" \
  --iam-instance-profile Name=agentlab-ec2-profile \
  --security-group-ids "$SG_ID" \
  --subnet-id "$SUBNET_ID" \
  --associate-public-ip-address \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_SIZE,\"VolumeType\":\"gp3\"}}]" \
  --user-data "file://$SCRIPT_DIR/user-data.sh" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME_TAG}]" \
  --metadata-options "HttpTokens=required" \
  --query 'Instances[0].InstanceId' --output text)

if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
  echo "ERROR: run-instances did not return an instance id. See the AWS CLI output above." >&2
  exit 1
fi

echo
echo "Instance launched: $INSTANCE_ID"
echo "It has a public IP (needed to reach the internet for apt/Docker/GitHub and to register with"
echo "SSM), but the security group still has zero inbound rules — nothing can connect to it from"
echo "the internet on any port. No SSH key was used either; it's reachable only via SSM."
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
