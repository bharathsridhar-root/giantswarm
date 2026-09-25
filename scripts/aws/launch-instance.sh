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
VOLUME_SIZE="${VOLUME_SIZE:-60}"               # GiB. 30 filled up in practice: a chart-version
                                                # upgrade (see RUNBOOK.md) doubles many image
                                                # pulls, plus Go toolchain + build cache + Ollama's
                                                # model + platform images. 30 hit 100% full and took
                                                # the control plane down with it (etcd is disk-
                                                # sensitive); 60 leaves real headroom.
NAME_TAG="${NAME_TAG:-agentlab-demo}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Looking up the latest Ubuntu 22.04 AMI for this region..."
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id \
  --query 'Parameter.Value' --output text)
echo "  AMI: $AMI_ID"

# Docker/apt/GitHub/Ollama/the platform's images are all on the public
# internet, not reachable via any AWS PrivateLink endpoint — so whichever
# subnet we launch into needs a real route out (an Internet Gateway; a NAT
# Gateway also works). Rather than assume the "default" VPC has one, check
# every subnet in every VPC and use the first one that actually does.
echo "Searching every VPC/subnet for one with a route to the internet..."
SUBNET_ID=""
VPC_ID=""
for CANDIDATE_SUBNET in $(aws ec2 describe-subnets --query 'Subnets[].SubnetId' --output text); do
  CANDIDATE_VPC=$(aws ec2 describe-subnets --subnet-ids "$CANDIDATE_SUBNET" \
    --query 'Subnets[0].VpcId' --output text)
  ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
    --filters Name=association.subnet-id,Values="$CANDIDATE_SUBNET" \
    --query 'RouteTables[0].RouteTableId' --output text)
  if [ -z "$ROUTE_TABLE_ID" ] || [ "$ROUTE_TABLE_ID" = "None" ]; then
    # No explicit association means the subnet uses its VPC's main route table.
    ROUTE_TABLE_ID=$(aws ec2 describe-route-tables \
      --filters Name=vpc-id,Values="$CANDIDATE_VPC" Name=association.main,Values=true \
      --query 'RouteTables[0].RouteTableId' --output text)
  fi
  if [ -z "$ROUTE_TABLE_ID" ] || [ "$ROUTE_TABLE_ID" = "None" ]; then
    continue
  fi
  HAS_ROUTE=$(aws ec2 describe-route-tables --route-table-ids "$ROUTE_TABLE_ID" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0' && (starts_with(GatewayId, 'igw-') || starts_with(NatGatewayId, 'nat-'))].[GatewayId,NatGatewayId]" \
    --output text)
  if [ -n "$HAS_ROUTE" ]; then
    SUBNET_ID="$CANDIDATE_SUBNET"
    VPC_ID="$CANDIDATE_VPC"
    echo "  found: $SUBNET_ID in $VPC_ID, route table $ROUTE_TABLE_ID -> $HAS_ROUTE"
    break
  fi
done

if [ -z "$SUBNET_ID" ]; then
  echo "ERROR: no subnet in any VPC in this account/region has a route to the internet" >&2
  echo "(no Internet Gateway, no NAT Gateway on any route table). This account/region has no" >&2
  echo "path out to the internet at all, so this instance could never pull Docker images," >&2
  echo "clone from GitHub, or register with SSM — this is a network configuration limit, not" >&2
  echo "something this script can work around. Options:" >&2
  echo "  - Ask whoever manages this AWS account's networking for a subnet with internet egress" >&2
  echo "    (an Internet Gateway attached + a 0.0.0.0/0 route, or a NAT Gateway)." >&2
  echo "  - Run scripts/aws/diagnose-network.sh for the exact current state to hand them." >&2
  echo "  - Use a different AWS account/region where you can create a default VPC yourself" >&2
  echo "    (Console: VPC -> Actions -> 'Create default VPC')." >&2
  exit 1
fi
echo "  VPC: $VPC_ID"
echo "  Subnet: $SUBNET_ID"

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
