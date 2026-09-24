#!/bin/bash
# Prints every VPC, Internet Gateway, NAT Gateway and subnet's default-route
# target in this account/region. Run this when launch-instance.sh reports no
# subnet has internet access, and hand the output to whoever manages this
# account's networking — it's the exact evidence needed to fix it (attach/
# route an IGW, or point to an existing NAT Gateway).
set -uo pipefail

echo "=== VPCs ==="
aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,IsDefault,CidrBlock]' --output table

echo "=== Internet Gateways attached to any VPC ==="
aws ec2 describe-internet-gateways \
  --query 'InternetGateways[].[InternetGatewayId,Attachments[0].VpcId,Attachments[0].State]' \
  --output table

echo "=== NAT Gateways ==="
aws ec2 describe-nat-gateways --query 'NatGateways[].[NatGatewayId,VpcId,SubnetId,State]' --output table

echo "=== Subnets with their route table's default-route target ==="
for SUBNET in $(aws ec2 describe-subnets --query 'Subnets[].SubnetId' --output text); do
  VPC=$(aws ec2 describe-subnets --subnet-ids "$SUBNET" --query 'Subnets[0].VpcId' --output text)
  RT=$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values="$SUBNET" \
    --query 'RouteTables[0].RouteTableId' --output text)
  if [ -z "$RT" ] || [ "$RT" = "None" ]; then
    RT=$(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" Name=association.main,Values=true \
      --query 'RouteTables[0].RouteTableId' --output text)
  fi
  TARGET=$(aws ec2 describe-route-tables --route-table-ids "$RT" \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].[GatewayId,NatGatewayId]" --output text)
  echo "$SUBNET  vpc=$VPC  routetable=$RT  default-route-target=${TARGET:-none}"
done
