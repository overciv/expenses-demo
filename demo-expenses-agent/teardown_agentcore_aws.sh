#!/usr/bin/env bash
# teardown_agentcore_aws.sh — tear down the AgentCore architecture
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.deploy-agentcore-state"

if [ ! -f "$STATE_FILE" ]; then
  echo "No state file found at $STATE_FILE — nothing to tear down."
  exit 0
fi

# shellcheck disable=SC1090
source "$STATE_FILE"
REGION="${REGION:-us-east-1}"

echo "=== ExpensePro AgentCore — Tear Down ==="
echo "Region: $REGION"
echo ""

echo ">>> AgentCore Runtime"
aws bedrock-agentcore-control delete-agent-runtime \
  --agent-runtime-id "$(basename "$RUNTIME_ARN")" --region "$REGION" 2>/dev/null \
  && echo "    Deleted: $RUNTIME_ARN" || echo "    Already gone."

echo ">>> AgentCore Gateway targets + gateway"
TARGETS=$(aws bedrock-agentcore-control list-gateway-targets \
  --gateway-identifier "$GATEWAY_ID" --region "$REGION" \
  --query 'items[].targetId' --output text 2>/dev/null || echo "")
for TID in $TARGETS; do
  aws bedrock-agentcore-control delete-gateway-target \
    --gateway-identifier "$GATEWAY_ID" --target-identifier "$TID" \
    --region "$REGION" 2>/dev/null || true
done
aws bedrock-agentcore-control delete-gateway \
  --gateway-identifier "$GATEWAY_ID" --region "$REGION" 2>/dev/null \
  && echo "    Gateway deleted." || echo "    Already gone."

echo ">>> XAA Interceptor Lambda"
aws lambda delete-function --function-name expenses-xaa-interceptor --region "$REGION" 2>/dev/null \
  && echo "    Deleted." || echo "    Already gone."

echo ">>> BFF API Gateway + Lambda"
aws apigatewayv2 delete-api --api-id "$BFF_API_ID" --region "$REGION" 2>/dev/null || true
aws lambda delete-function --function-name expenses-bff-org-token --region "$REGION" 2>/dev/null \
  && echo "    Deleted." || echo "    Already gone."

echo ">>> ECR repository"
aws ecr delete-repository --repository-name expenses-chat-agent --force --region "$REGION" 2>/dev/null \
  && echo "    Deleted." || echo "    Already gone."

echo ">>> Secrets Manager"
aws secretsmanager delete-secret --secret-id "agentcore/xaa/expenses-agent" \
  --force-delete-without-recovery --region "$REGION" 2>/dev/null || true
aws secretsmanager delete-secret --secret-id "expenses/bff-client-secret" \
  --force-delete-without-recovery --region "$REGION" 2>/dev/null || true
echo "    Secrets scheduled for deletion."

echo ">>> IAM roles + policies"
for ROLE in "$RUNTIME_ROLE_NAME" "$INTERCEPTOR_ROLE_NAME" "$GATEWAY_ROLE_NAME" "$BFF_ROLE_NAME"; do
  POLICIES=$(aws iam list-role-policies --role-name "$ROLE" --query 'PolicyNames' --output text 2>/dev/null || echo "")
  for POL in $POLICIES; do
    aws iam delete-role-policy --role-name "$ROLE" --policy-name "$POL" 2>/dev/null || true
  done
  ATTACHED=$(aws iam list-attached-role-policies --role-name "$ROLE" \
    --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || echo "")
  for ARN in $ATTACHED; do
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn "$ARN" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$ROLE" 2>/dev/null && echo "    Role deleted: $ROLE" || true
done

rm -f "$STATE_FILE"
echo ""
echo "✓ Tear down complete."
