#!/bin/bash
# One-time setup: an IAM role that lets the EC2 instance be reached through
# AWS Systems Manager Session Manager (browser-based shell, no SSH, no
# inbound security-group rules needed) and read the two secrets it needs
# from SSM Parameter Store. Run this once, from AWS CloudShell or any shell
# with an AWS CLI configured with IAM permissions. Safe to re-run — every
# step checks current state instead of assuming success or failure.
set -euo pipefail

ROLE_NAME=agentlab-ec2-role
PROFILE_NAME=agentlab-ec2-profile

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "Role $ROLE_NAME already exists."
else
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
    }' >/dev/null
fi

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

if aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null 2>&1; then
  echo "Instance profile $PROFILE_NAME already exists."
else
  echo "Creating instance profile $PROFILE_NAME..."
  aws iam create-instance-profile --instance-profile-name "$PROFILE_NAME" >/dev/null
fi

ATTACHED_ROLE=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)
if [ "$ATTACHED_ROLE" = "$ROLE_NAME" ]; then
  echo "Role already attached to the instance profile."
else
  echo "Attaching $ROLE_NAME to $PROFILE_NAME..."
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$PROFILE_NAME" \
    --role-name "$ROLE_NAME"
fi

echo "Verifying the instance profile carries the role..."
for i in 1 2 3 4 5 6; do
  ROLES=$(aws iam get-instance-profile --instance-profile-name "$PROFILE_NAME" \
    --query 'InstanceProfile.Roles[].RoleName' --output text)
  if [ "$ROLES" = "$ROLE_NAME" ]; then
    echo "  confirmed: $ROLES"
    break
  fi
  if [ "$i" = 6 ]; then
    echo "ERROR: instance profile still shows no role after waiting. Roles: '$ROLES'" >&2
    exit 1
  fi
  echo "  not yet visible, waiting (IAM propagation)..."
  sleep 5
done

echo
echo "Done. Now store your secrets (both optional — see scripts/aws/README.md,"
echo "the EC2 demo runs free by default on a local Ollama model with neither set):"
echo
echo "  aws ssm put-parameter --name /agentlab/anthropic-api-key --type SecureString --value 'sk-ant-...' --overwrite"
echo "  aws ssm put-parameter --name /agentlab/github-token       --type SecureString --value 'github_pat_...' --overwrite"
echo
echo "Then launch the instance with scripts/aws/launch-instance.sh."
