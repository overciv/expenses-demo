#!/usr/bin/env bash
# teardown.sh — remove all AWS resources created by deploy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.deploy-state"

if [ ! -f "$STATE_FILE" ]; then
  echo "No .deploy-state file found. Run deploy.sh first."
  exit 1
fi

# shellcheck disable=SC1090
source "$STATE_FILE"

echo "=== Expenses API — Teardown ==="
echo "API ID    : $API_ID"
echo "Region    : $REGION"
echo "Function  : $FUNCTION_NAME"
echo "Role      : $ROLE_NAME"
echo "DynamoDB  : ${TABLE_NAME:-expenses-demo}"
echo ""
read -rp "Delete all resources? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo ""
echo ">>> Deleting API Gateway: $API_ID"
aws apigatewayv2 delete-api --api-id "$API_ID" --region "$REGION" && echo "    Done."

echo ""
echo ">>> Deleting Lambda function: $FUNCTION_NAME"
aws lambda delete-function --function-name "$FUNCTION_NAME" --region "$REGION" && echo "    Done."

echo ""
echo ">>> Detaching policies and deleting IAM role: $ROLE_NAME"
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
  2>/dev/null || true
aws iam delete-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "expenses-dynamodb-access" \
  2>/dev/null || true
aws iam delete-role --role-name "$ROLE_NAME" && echo "    Done."

echo ""
_TABLE="${TABLE_NAME:-expenses-demo}"
echo ">>> Deleting DynamoDB table: $_TABLE"
aws dynamodb delete-table --table-name "$_TABLE" --region "$REGION" \
  --query 'TableDescription.TableStatus' --output text
aws dynamodb wait table-not-exists --table-name "$_TABLE" --region "$REGION"
echo "    Done."

echo ""
echo ">>> Deleting EventBridge warm-up rule"
aws events remove-targets --rule expenses-api-warmup --ids expenses-api-warm \
  --region "$REGION" 2>/dev/null || true
aws events delete-rule --name expenses-api-warmup --region "$REGION" 2>/dev/null || true
echo "    Done."

rm -f "$STATE_FILE"
rm -rf "$SCRIPT_DIR/.build"

echo ""
echo "✓ All resources removed."
