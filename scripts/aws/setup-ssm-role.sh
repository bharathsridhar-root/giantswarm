#!/bin/bash
# One-time setup: an IAM role that lets the EC2 instance be reached through
# AWS Systems Manager Session Manager (browser-based shell, no SSH, no
# inbound security-group rules needed) and read the two secrets it needs
# from SSM Parameter Store. Run this once, from AWS CloudShell or any shell
# with an AWS CLI configured with IAM permissions.
set -euo pipefail

ROLE_NAME=agentlab-ec2-role
PROFILE_NAME=agentlab-ec2-profile

echo "Creating IAM role $ROLE_NAME..."
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }' 2>/dev/null || echo "  (role already exists, continuing)"

echo "Attaching AmazonSSMManagedInstanceCore (Session Manager access)..."
aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

echo "Attaching an inline policy scoped to /agentlab/* SSM parameters..."
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name agentlab-read-parameters \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["ssm:GetParameter", "ssm:GetParameters"],
      "Resource": "arn:aws:ssm:*:*:parameter/agentlab/*"
    }]
  }'

echo "Creating instance profile $PROFILE_NAME..."
aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" 2>/dev/null \
  || echo "  (instance profile already exists, continuing)"
aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME" 2>/dev/null || true

echo "Waiting for the instance profile to propagate..."
sleep 10

echo "Done. Now store your secrets (only ANTHROPIC_API_KEY is required):"
echo
echo "  aws ssm put-parameter --name /agentlab/anthropic-api-key --type SecureString --value 'sk-ant-...' --overwrite"
echo "  aws ssm put-parameter --name /agentlab/github-token       --type SecureString --value 'github_pat_...' --overwrite   # optional"
echo
echo "Then launch the instance with scripts/aws/launch-instance.sh."
