#!/usr/bin/env bash
# teardown_mcp_aws.sh — remove App Runner service, ECR repo, and IAM role
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.deploy-mcp-state"

if [ ! -f "$STATE_FILE" ]; then
  echo "No .deploy-mcp-state found. Run deploy_mcp_aws.sh first."
  exit 1
fi

# shellcheck disable=SC1090
source "$STATE_FILE"

echo "=== Expenses MCP Server — Teardown ==="
echo "Service  : $SERVICE_ARN"
echo "ECR      : $ECR_URI"
echo "IAM Role : $ECR_ACCESS_ROLE_NAME"
echo "Region   : $REGION"
echo ""
read -rp "Delete all resources? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo ""
echo ">>> Deleting App Runner service..."
aws apprunner delete-service --service-arn "$SERVICE_ARN" --region "$REGION" \
  --query 'Service.Status' --output text

echo ""
echo ">>> Deleting ECR images and repository: $ECR_REPO"
# Delete all images first
IMAGE_IDS=$(aws ecr list-images \
  --repository-name "$ECR_REPO" \
  --region "$REGION" \
  --query 'imageIds[*]' --output json)
if [ "$IMAGE_IDS" != "[]" ] && [ -n "$IMAGE_IDS" ]; then
  aws ecr batch-delete-image \
    --repository-name "$ECR_REPO" \
    --image-ids "$IMAGE_IDS" \
    --region "$REGION" \
    --output text > /dev/null
fi
aws ecr delete-repository --repository-name "$ECR_REPO" --region "$REGION" && echo "    Done."

echo ""
echo ">>> Detaching policies and deleting IAM role: $ECR_ACCESS_ROLE_NAME"
aws iam detach-role-policy \
  --role-name "$ECR_ACCESS_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess \
  2>/dev/null || true
aws iam delete-role --role-name "$ECR_ACCESS_ROLE_NAME" && echo "    Done."

rm -f "$STATE_FILE"
echo ""
echo "✓ All MCP server resources removed."
