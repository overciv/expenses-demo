#!/usr/bin/env bash
# teardown_agent_aws.sh — remove all AI agent AWS resources
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.deploy-agent-state"

if [ ! -f "$STATE_FILE" ]; then
  echo "No .deploy-agent-state found. Run deploy_agent_aws.sh first."
  exit 1
fi

# shellcheck disable=SC1090
source "$STATE_FILE"

echo "=== ExpensePro AI Agent — Teardown ==="
echo "API Gateway : $CHAT_API_ID"
echo "Lambda      : $FUNCTION_NAME"
echo "IAM Role    : $ROLE_NAME"
echo "Secret      : $SECRET_ARN"
echo ""
read -rp "Delete all resources? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo ""
echo ">>> Deleting API Gateway: $CHAT_API_ID"
aws apigatewayv2 delete-api --api-id "$CHAT_API_ID" --region "$REGION" && echo "    Done."

echo ""
echo ">>> Deleting Lambda: $FUNCTION_NAME"
aws lambda delete-function --function-name "$FUNCTION_NAME" --region "$REGION" && echo "    Done."

echo ""
echo ">>> Deleting IAM role: $ROLE_NAME"
aws iam detach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam delete-role-policy --role-name "$ROLE_NAME" \
  --policy-name "expenses-chat-permissions" 2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" && echo "    Done."

echo ""
echo ">>> Deleting secret: $SECRET_ARN"
aws secretsmanager delete-secret \
  --secret-id "$SECRET_ARN" \
  --force-delete-without-recovery \
  --region "$REGION" --output text > /dev/null && echo "    Done."

rm -f "$STATE_FILE"
echo ""
echo "✓ All AI agent resources removed."
