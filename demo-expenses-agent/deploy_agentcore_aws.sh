#!/usr/bin/env bash
# deploy_agentcore_aws.sh — deploy the ExpensePro AI agent on AgentCore Runtime
#
# Architecture:
#   Browser → AgentCore Runtime (Strands agent, container)
#           → AgentCore Gateway (MCP proxy)
#           → Lambda Interceptor (Okta XAA token exchange)
#           → MCP Server (App Runner)
#           → REST API (Lambda + DynamoDB)
#
#   Browser → BFF Lambda (/org-token only: PKCE code → org ID token)
#
# Required env vars:
#   OKTA_ORG_URL              — Okta org base URL (e.g. https://zelemon.oktapreview.com)
#   OKTA_WEBAPP_CLIENT_ID     — Okta Web App (confidential) client ID (audience of org ID token)
#   OKTA_WEBAPP_CLIENT_SECRET — Okta Web App client secret (for BFF code exchange)
#   OKTA_AGENT_CLIENT_ID      — Okta AI Agent client ID (for pkjwt XAA)
#   OKTA_ISSUER               — Custom AS issuer URL (auto-read from .deploy-state if unset)
#   OKTA_PRIVATE_KEY_PEM      — RSA private key PEM for the AI Agent (stored in Secrets Manager)
#
# Optional:
#   OKTA_PRIVATE_KEY_ID       — key ID in the Okta JWK set (default: expenses-agent-key-1)
#   MCP_SERVER_URL            — App Runner MCP URL (auto-read from .deploy-mcp-state if unset)
#   MODEL_ID                  — Bedrock model ID (default: us.anthropic.claude-3-5-haiku-20241022-v1:0)
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_STATE_API="$SCRIPT_DIR/../demo-expenses-api/.deploy-state"
DEPLOY_STATE_MCP="$SCRIPT_DIR/../demo-expenses-api/.deploy-mcp-state"
STATE_FILE="$SCRIPT_DIR/.deploy-agentcore-state"

# ─────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────
for VAR in OKTA_ORG_URL OKTA_WEBAPP_CLIENT_ID OKTA_WEBAPP_CLIENT_SECRET OKTA_AGENT_CLIENT_ID OKTA_PRIVATE_KEY_PEM; do
  if [ -z "${!VAR:-}" ]; then
    echo "ERROR: $VAR is required."
    exit 1
  fi
done

# Auto-read OKTA_ISSUER from API deploy state
if [ -z "${OKTA_ISSUER:-}" ] && [ -f "$DEPLOY_STATE_API" ]; then
  API_ID=$(grep ^API_ID= "$DEPLOY_STATE_API" | cut -d= -f2)
  API_REGION=$(grep ^REGION= "$DEPLOY_STATE_API" | cut -d= -f2)
  OKTA_ISSUER=$(aws apigatewayv2 get-authorizers --api-id "$API_ID" --region "$API_REGION" \
    --query 'Items[0].JwtConfiguration.Issuer' --output text)
  echo "  Auto-detected OKTA_ISSUER: $OKTA_ISSUER"
fi
[ -z "${OKTA_ISSUER:-}" ] && { echo "ERROR: OKTA_ISSUER required."; exit 1; }

# Auto-read MCP_SERVER_URL from MCP deploy state
if [ -z "${MCP_SERVER_URL:-}" ] && [ -f "$DEPLOY_STATE_MCP" ]; then
  SERVICE_URL=$(grep ^SERVICE_URL= "$DEPLOY_STATE_MCP" | cut -d= -f2)
  MCP_SERVER_URL="https://${SERVICE_URL}/mcp"
  echo "  Auto-detected MCP_SERVER_URL: $MCP_SERVER_URL"
fi
[ -z "${MCP_SERVER_URL:-}" ] && { echo "ERROR: MCP_SERVER_URL required."; exit 1; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OKTA_PRIVATE_KEY_ID="${OKTA_PRIVATE_KEY_ID:-expenses-agent-key-1}"
MODEL_ID="${MODEL_ID:-us.anthropic.claude-3-5-haiku-20241022-v1:0}"
AGENT_ID="expenses-agent"

INTERCEPTOR_FUNCTION_NAME="expenses-xaa-interceptor"
INTERCEPTOR_ROLE_NAME="expenses-xaa-interceptor-role"
XAA_SECRET_NAME="agentcore/xaa/${AGENT_ID}"

GATEWAY_NAME="expenses-mcp-gateway"
GATEWAY_ROLE_NAME="expenses-gateway-role"
GATEWAY_TARGET_NAME="expenses-mcp-server"

RUNTIME_NAME="expenses_chat_agent"
RUNTIME_ROLE_NAME="expenses-agentcore-runtime-role"
ECR_REPO="expenses-chat-agent"
# Versioned tag forces AgentCore Runtime to pull the new image on every deploy
# (using :latest risks the Runtime reusing a warm cached container)
IMAGE_TAG="v$(date +%Y%m%d%H%M%S)"

BFF_FUNCTION_NAME="expenses-bff-org-token"
BFF_ROLE_NAME="expenses-bff-role"
BFF_API_NAME="expenses-bff-api"

echo "=== ExpensePro AI Agent — AgentCore Deploy ==="
echo "Region        : $REGION"
echo "Account       : $ACCOUNT_ID"
echo "Okta org URL  : $OKTA_ORG_URL"
echo "Okta issuer   : $OKTA_ISSUER"
echo "MCP Server    : $MCP_SERVER_URL"
echo "Model         : $MODEL_ID"
echo ""

# ─────────────────────────────────────────────
# 1. Secrets Manager — XAA credentials
# ─────────────────────────────────────────────
echo ">>> [1/8] Secrets Manager: $XAA_SECRET_NAME"
XAA_SECRET_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
  'okta_org_url':         '${OKTA_ORG_URL}',
  'okta_issuer':          '${OKTA_ISSUER}',
  'okta_agent_client_id': '${OKTA_AGENT_CLIENT_ID}',
  'okta_private_key_pem': '''${OKTA_PRIVATE_KEY_PEM}''',
  'okta_private_key_id':  '${OKTA_PRIVATE_KEY_ID}',
  'scope':                'expenses:read expenses:write expenses:delete',
}))
")

if aws secretsmanager describe-secret --secret-id "$XAA_SECRET_NAME" --region "$REGION" &>/dev/null; then
  aws secretsmanager put-secret-value \
    --secret-id "$XAA_SECRET_NAME" --secret-string "$XAA_SECRET_PAYLOAD" \
    --region "$REGION" --output text > /dev/null
  echo "    Secret updated."
else
  aws secretsmanager create-secret \
    --name "$XAA_SECRET_NAME" \
    --description "Okta XAA credentials for ExpensePro AI Agent" \
    --secret-string "$XAA_SECRET_PAYLOAD" \
    --region "$REGION" --output text > /dev/null
  echo "    Secret created."
fi
XAA_SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "$XAA_SECRET_NAME" --region "$REGION" --query 'ARN' --output text)
echo "    ARN: $XAA_SECRET_ARN"

# Also store Web App client secret for BFF Lambda
BFF_SECRET_NAME="expenses/bff-client-secret"
BFF_SECRET_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'client_id':     '${OKTA_WEBAPP_CLIENT_ID}',
  'client_secret': '${OKTA_WEBAPP_CLIENT_SECRET}',
}))
")
if aws secretsmanager describe-secret --secret-id "$BFF_SECRET_NAME" --region "$REGION" &>/dev/null; then
  aws secretsmanager put-secret-value \
    --secret-id "$BFF_SECRET_NAME" --secret-string "$BFF_SECRET_PAYLOAD" \
    --region "$REGION" --output text > /dev/null
else
  aws secretsmanager create-secret \
    --name "$BFF_SECRET_NAME" --secret-string "$BFF_SECRET_PAYLOAD" \
    --region "$REGION" --output text > /dev/null
fi
BFF_SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "$BFF_SECRET_NAME" --region "$REGION" --query 'ARN' --output text)

# ─────────────────────────────────────────────
# 2. XAA Interceptor Lambda
# ─────────────────────────────────────────────
echo ""
echo ">>> [2/8] XAA Interceptor Lambda: $INTERCEPTOR_FUNCTION_NAME"
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if aws iam get-role --role-name "$INTERCEPTOR_ROLE_NAME" &>/dev/null; then
  INTERCEPTOR_ROLE_ARN=$(aws iam get-role --role-name "$INTERCEPTOR_ROLE_NAME" --query 'Role.Arn' --output text)
else
  INTERCEPTOR_ROLE_ARN=$(aws iam create-role \
    --role-name "$INTERCEPTOR_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy --role-name "$INTERCEPTOR_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "    Waiting 15s for IAM propagation..."
  sleep 15
fi
echo "    Role ARN: $INTERCEPTOR_ROLE_ARN"

INTERCEPTOR_INLINE=$(python3 -c "
import json
print(json.dumps({
  'Version': '2012-10-17',
  'Statement': [{
    'Effect': 'Allow',
    'Action': ['secretsmanager:GetSecretValue'],
    'Resource': 'arn:aws:secretsmanager:${REGION}:${ACCOUNT_ID}:secret:agentcore/xaa/*'
  }]
}))
")
aws iam put-role-policy --role-name "$INTERCEPTOR_ROLE_NAME" \
  --policy-name "interceptor-secrets" --policy-document "$INTERCEPTOR_INLINE"

# Package the interceptor
INTERCEPTOR_BUILD_DIR="$(mktemp -d)"
pip3 install -q \
  -r "$SCRIPT_DIR/interceptor/requirements.txt" \
  -t "$INTERCEPTOR_BUILD_DIR" \
  --platform manylinux2014_x86_64 --implementation cp \
  --python-version 3.12 --only-binary=:all: --upgrade
cp "$SCRIPT_DIR/interceptor/lambda_function.py" "$INTERCEPTOR_BUILD_DIR/"
INTERCEPTOR_ZIP="$(mktemp).zip"
(cd "$INTERCEPTOR_BUILD_DIR" && zip -q -r "$INTERCEPTOR_ZIP" .)
rm -rf "$INTERCEPTOR_BUILD_DIR"
echo "    Package: $(du -sh "$INTERCEPTOR_ZIP" | cut -f1)"

INTERCEPTOR_ENV="Variables={XAA_SECRET_PREFIX=agentcore/xaa,AWS_REGION_OVERRIDE=$REGION}"

if aws lambda get-function --function-name "$INTERCEPTOR_FUNCTION_NAME" --region "$REGION" &>/dev/null; then
  aws lambda update-function-code \
    --function-name "$INTERCEPTOR_FUNCTION_NAME" --zip-file "fileb://$INTERCEPTOR_ZIP" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-updated --function-name "$INTERCEPTOR_FUNCTION_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$INTERCEPTOR_FUNCTION_NAME" \
    --environment "$INTERCEPTOR_ENV" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-updated --function-name "$INTERCEPTOR_FUNCTION_NAME" --region "$REGION"
else
  aws lambda create-function \
    --function-name "$INTERCEPTOR_FUNCTION_NAME" \
    --runtime python3.12 --role "$INTERCEPTOR_ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://$INTERCEPTOR_ZIP" \
    --timeout 60 --memory-size 256 \
    --description "ExpensePro XAA interceptor — Okta Cross-App Access token exchange" \
    --environment "$INTERCEPTOR_ENV" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-active --function-name "$INTERCEPTOR_FUNCTION_NAME" --region "$REGION"
fi
rm -f "$INTERCEPTOR_ZIP"
INTERCEPTOR_LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$INTERCEPTOR_FUNCTION_NAME" --region "$REGION" \
  --query 'Configuration.FunctionArn' --output text)
echo "    Lambda ARN: $INTERCEPTOR_LAMBDA_ARN"

# ─────────────────────────────────────────────
# 3. AgentCore Gateway IAM role
# ─────────────────────────────────────────────
echo ""
echo ">>> [3/8] AgentCore Gateway: $GATEWAY_NAME"
GATEWAY_TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"bedrock-agentcore.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if aws iam get-role --role-name "$GATEWAY_ROLE_NAME" &>/dev/null; then
  GATEWAY_ROLE_ARN=$(aws iam get-role --role-name "$GATEWAY_ROLE_NAME" --query 'Role.Arn' --output text)
else
  GATEWAY_ROLE_ARN=$(aws iam create-role \
    --role-name "$GATEWAY_ROLE_NAME" \
    --assume-role-policy-document "$GATEWAY_TRUST" \
    --query 'Role.Arn' --output text)
  sleep 10
fi

GATEWAY_INLINE=$(python3 -c "
import json
print(json.dumps({
  'Version': '2012-10-17',
  'Statement': [
    {
      'Effect': 'Allow',
      'Action': ['lambda:InvokeFunction'],
      'Resource': '${INTERCEPTOR_LAMBDA_ARN}'
    }
  ]
}))
")
aws iam put-role-policy --role-name "$GATEWAY_ROLE_NAME" \
  --policy-name "gateway-invoke-interceptor" --policy-document "$GATEWAY_INLINE"

# Grant Gateway service principal permission to invoke the interceptor Lambda
aws lambda add-permission \
  --function-name "$INTERCEPTOR_FUNCTION_NAME" \
  --statement-id "allow-agentcore-gateway" \
  --action lambda:InvokeFunction \
  --principal bedrock-agentcore.amazonaws.com \
  --region "$REGION" 2>/dev/null || true

# Create or update Gateway
GATEWAY_AUTH_CONFIG=$(python3 -c "
import json
print(json.dumps({
  'customJWTAuthorizer': {
    'discoveryUrl': '${OKTA_ORG_URL}/.well-known/openid-configuration',
    'allowedAudience': ['${OKTA_WEBAPP_CLIENT_ID}']
  }
}))
")
INTERCEPTOR_CONFIG=$(python3 -c "
import json
print(json.dumps([{
  'interceptor': {'lambda': {'arn': '${INTERCEPTOR_LAMBDA_ARN}'}},
  'interceptionPoints': ['REQUEST'],
  'inputConfiguration': {'passRequestHeaders': True}
}]))
")

EXISTING_GATEWAY_ID=$(aws bedrock-agentcore-control list-gateways --region "$REGION" \
  --query "items[?name=='$GATEWAY_NAME'].gatewayId" --output text 2>/dev/null || echo "")
[ "$EXISTING_GATEWAY_ID" = "None" ] && EXISTING_GATEWAY_ID=""

if [ -z "$EXISTING_GATEWAY_ID" ]; then
  GATEWAY_RESPONSE=$(aws bedrock-agentcore-control create-gateway \
    --name "$GATEWAY_NAME" \
    --protocol-type MCP \
    --authorizer-type CUSTOM_JWT \
    --authorizer-configuration "$GATEWAY_AUTH_CONFIG" \
    --role-arn "$GATEWAY_ROLE_ARN" \
    --region "$REGION" --output json)
  GATEWAY_ID=$(echo "$GATEWAY_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['gatewayId'])")
  echo "    Gateway created: $GATEWAY_ID"
else
  GATEWAY_ID="$EXISTING_GATEWAY_ID"
  echo "    Gateway exists: $GATEWAY_ID — updating"
fi

# Add MCP target pointing to App Runner MCP Server
EXISTING_TARGET_JSON=$(aws bedrock-agentcore-control list-gateway-targets \
  --gateway-identifier "$GATEWAY_ID" --region "$REGION" \
  --output json 2>/dev/null || echo '{"items":[]}')
EXISTING_TARGET=$(echo "$EXISTING_TARGET_JSON" | python3 -c "
import json,sys
items = json.load(sys.stdin).get('items', [])
match = next((i for i in items if i['name'] == '${GATEWAY_TARGET_NAME}'), None)
print(match['targetId'] if match else '')
")
EXISTING_TARGET_STATUS=$(echo "$EXISTING_TARGET_JSON" | python3 -c "
import json,sys
items = json.load(sys.stdin).get('items', [])
match = next((i for i in items if i['name'] == '${GATEWAY_TARGET_NAME}'), None)
print(match.get('status', '') if match else '')
")

MCP_TARGET_CONFIG=$(python3 -c "
import json
print(json.dumps({
  'mcp': {
    'mcpServer': {
      'endpoint': '${MCP_SERVER_URL}'
    }
  }
}))
")

if [ -z "$EXISTING_TARGET" ]; then
  aws bedrock-agentcore-control create-gateway-target \
    --gateway-identifier "$GATEWAY_ID" \
    --name "$GATEWAY_TARGET_NAME" \
    --target-configuration "$MCP_TARGET_CONFIG" \
    --region "$REGION" --output text > /dev/null
  echo "    MCP target created → $MCP_SERVER_URL"
elif [ "$EXISTING_TARGET_STATUS" = "READY" ]; then
  echo "    MCP target already READY (${EXISTING_TARGET}) — skipping recreation"
else
  # FAILED or other — delete, wait for propagation, then recreate
  echo "    MCP target status: ${EXISTING_TARGET_STATUS} — deleting and recreating..."
  aws bedrock-agentcore-control delete-gateway-target \
    --gateway-identifier "$GATEWAY_ID" \
    --target-id "$EXISTING_TARGET" \
    --region "$REGION" --output text > /dev/null 2>&1 || true
  echo "    Waiting 15s for name to clear..."
  sleep 15
  aws bedrock-agentcore-control create-gateway-target \
    --gateway-identifier "$GATEWAY_ID" \
    --name "$GATEWAY_TARGET_NAME" \
    --target-configuration "$MCP_TARGET_CONFIG" \
    --region "$REGION" --output text > /dev/null
  echo "    MCP target recreated → $MCP_SERVER_URL"
fi

# Attach interceptor to gateway
aws bedrock-agentcore-control update-gateway \
  --gateway-identifier "$GATEWAY_ID" \
  --name "$GATEWAY_NAME" \
  --protocol-type MCP \
  --authorizer-type CUSTOM_JWT \
  --authorizer-configuration "$GATEWAY_AUTH_CONFIG" \
  --role-arn "$GATEWAY_ROLE_ARN" \
  --interceptor-configurations "$INTERCEPTOR_CONFIG" \
  --region "$REGION" --output text > /dev/null
echo "    XAA interceptor attached."

GATEWAY_MCP_URL=$(aws bedrock-agentcore-control get-gateway \
  --gateway-identifier "$GATEWAY_ID" --region "$REGION" \
  --query 'gatewayUrl' --output text)
echo "    Gateway MCP URL: $GATEWAY_MCP_URL"

# ─────────────────────────────────────────────
# 4. ECR — AgentCore Runtime image
# ─────────────────────────────────────────────
echo ""
echo ">>> [4/8] ECR + Docker: $ECR_REPO"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}"

if ! aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" &>/dev/null; then
  aws ecr create-repository --repository-name "$ECR_REPO" --region "$REGION" --output text > /dev/null
  echo "    ECR repo created."
fi

aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

docker build --platform linux/arm64 -t "${ECR_REPO}:${IMAGE_TAG}" "$SCRIPT_DIR" -q
docker tag "${ECR_REPO}:${IMAGE_TAG}" "${ECR_URI}:${IMAGE_TAG}"
docker push "${ECR_URI}:${IMAGE_TAG}" --quiet
echo "    Image pushed: ${ECR_URI}:${IMAGE_TAG}"

# ─────────────────────────────────────────────
# 5. AgentCore Runtime IAM role
# ─────────────────────────────────────────────
echo ""
echo ">>> [5/8] AgentCore Runtime IAM role: $RUNTIME_ROLE_NAME"
RUNTIME_TRUST=$(python3 -c "
import json
print(json.dumps({
  'Version': '2012-10-17',
  'Statement': [
    {
      'Effect': 'Allow',
      'Principal': {'Service': 'bedrock-agentcore.amazonaws.com'},
      'Action': 'sts:AssumeRole'
    }
  ]
}))
")

if aws iam get-role --role-name "$RUNTIME_ROLE_NAME" &>/dev/null; then
  RUNTIME_ROLE_ARN=$(aws iam get-role --role-name "$RUNTIME_ROLE_NAME" --query 'Role.Arn' --output text)
else
  RUNTIME_ROLE_ARN=$(aws iam create-role \
    --role-name "$RUNTIME_ROLE_NAME" \
    --assume-role-policy-document "$RUNTIME_TRUST" \
    --query 'Role.Arn' --output text)
  sleep 10
fi

RUNTIME_INLINE=$(python3 -c "
import json
print(json.dumps({
  'Version': '2012-10-17',
  'Statement': [
    {
      'Effect': 'Allow',
      'Action': ['ecr:GetDownloadUrlForLayer', 'ecr:BatchGetImage', 'ecr:BatchCheckLayerAvailability'],
      'Resource': 'arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO}'
    },
    {
      'Effect': 'Allow',
      'Action': ['ecr:GetAuthorizationToken'],
      'Resource': '*'
    },
    {
      'Effect': 'Allow',
      'Action': ['bedrock:InvokeModel', 'bedrock:InvokeModelWithResponseStream'],
      'Resource': [
        'arn:aws:bedrock:*::foundation-model/anthropic.*',
        'arn:aws:bedrock:*:*:inference-profile/us.anthropic.*'
      ]
    },
    {
      'Effect': 'Allow',
      'Action': ['bedrock-agentcore:GetWorkloadAccessToken', 'bedrock-agentcore:GetWorkloadAccessTokenForJWT'],
      'Resource': '*'
    },
    {
      'Effect': 'Allow',
      'Action': ['logs:CreateLogGroup', 'logs:CreateLogStream', 'logs:PutLogEvents'],
      'Resource': 'arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:/aws/bedrock-agentcore/*'
    }
  ]
}))
")
aws iam put-role-policy --role-name "$RUNTIME_ROLE_NAME" \
  --policy-name "agentcore-runtime-permissions" --policy-document "$RUNTIME_INLINE"
echo "    Role ARN: $RUNTIME_ROLE_ARN"

# ─────────────────────────────────────────────
# 6. AgentCore Runtime
# ─────────────────────────────────────────────
echo ""
echo ">>> [6/8] AgentCore Runtime: $RUNTIME_NAME"
AUTHORIZER_CONFIG=$(python3 -c "
import json
print(json.dumps({
  'customJWTAuthorizer': {
    'discoveryUrl': '${OKTA_ORG_URL}/.well-known/openid-configuration',
    'allowedAudience': ['${OKTA_WEBAPP_CLIENT_ID}']
  }
}))
")
RUNTIME_ENV_VARS=$(python3 -c "
import json
print(json.dumps({
  'GATEWAY_MCP_URL': '${GATEWAY_MCP_URL}',
  'MODEL_ID':        '${MODEL_ID}',
  'AGENT_ID':        'expenses-agent',
}))
")

EXISTING_RUNTIME_ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region "$REGION" \
  --query "agentRuntimes[?agentRuntimeName=='$RUNTIME_NAME'].agentRuntimeArn" --output text 2>/dev/null || echo "")
[ "$EXISTING_RUNTIME_ARN" = "None" ] && EXISTING_RUNTIME_ARN=""

if [ -z "$EXISTING_RUNTIME_ARN" ]; then
  RUNTIME_RESPONSE=$(aws bedrock-agentcore-control create-agent-runtime \
    --agent-runtime-name "$RUNTIME_NAME" \
    --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_URI}:${IMAGE_TAG}\"}}" \
    --authorizer-configuration "$AUTHORIZER_CONFIG" \
    --network-configuration '{"networkMode":"PUBLIC"}' \
    --environment-variables "$RUNTIME_ENV_VARS" \
    --role-arn "$RUNTIME_ROLE_ARN" \
    --region "$REGION" --output json)
  RUNTIME_ARN=$(echo "$RUNTIME_RESPONSE" | python3 -c "import json,sys; print(json.load(sys.stdin)['agentRuntimeArn'])")
  echo "    Runtime created: $RUNTIME_ARN"
else
  RUNTIME_ARN="$EXISTING_RUNTIME_ARN"
  aws bedrock-agentcore-control update-agent-runtime \
    --agent-runtime-id "$(basename "$RUNTIME_ARN")" \
    --agent-runtime-artifact "{\"containerConfiguration\":{\"containerUri\":\"${ECR_URI}:${IMAGE_TAG}\"}}" \
    --authorizer-configuration "$AUTHORIZER_CONFIG" \
    --environment-variables "$RUNTIME_ENV_VARS" \
    --role-arn "$RUNTIME_ROLE_ARN" \
    --region "$REGION" --output text > /dev/null
  echo "    Runtime updated: $RUNTIME_ARN"
fi

# Derive the invocation endpoint URL
RUNTIME_ARN_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$RUNTIME_ARN', safe=''))")
RUNTIME_INVOCATION_URL="https://bedrock-agentcore.${REGION}.amazonaws.com/runtimes/${RUNTIME_ARN_ENCODED}/invocations?qualifier=DEFAULT"
echo "    Invocation URL: $RUNTIME_INVOCATION_URL"

# ─────────────────────────────────────────────
# 7. BFF Lambda (/org-token)
# ─────────────────────────────────────────────
echo ""
echo ">>> [7/8] BFF Lambda: $BFF_FUNCTION_NAME"
if aws iam get-role --role-name "$BFF_ROLE_NAME" &>/dev/null; then
  BFF_ROLE_ARN=$(aws iam get-role --role-name "$BFF_ROLE_NAME" --query 'Role.Arn' --output text)
else
  BFF_ROLE_ARN=$(aws iam create-role \
    --role-name "$BFF_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy --role-name "$BFF_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  sleep 15
fi

BFF_INLINE=$(python3 -c "
import json
print(json.dumps({
  'Version': '2012-10-17',
  'Statement': [{
    'Effect': 'Allow',
    'Action': ['secretsmanager:GetSecretValue'],
    'Resource': '${BFF_SECRET_ARN}'
  }]
}))
")
aws iam put-role-policy --role-name "$BFF_ROLE_NAME" \
  --policy-name "bff-secrets" --policy-document "$BFF_INLINE"

BFF_BUILD_DIR="$(mktemp -d)"
pip3 install -q requests -t "$BFF_BUILD_DIR" \
  --platform manylinux2014_x86_64 --implementation cp \
  --python-version 3.12 --only-binary=:all:
cp "$SCRIPT_DIR/handler.py" "$SCRIPT_DIR/org_token.py" "$BFF_BUILD_DIR/"
BFF_ZIP="$(mktemp).zip"
(cd "$BFF_BUILD_DIR" && zip -q -r "$BFF_ZIP" .)
rm -rf "$BFF_BUILD_DIR"

BFF_ENV="Variables={OKTA_ORG_URL=${OKTA_ORG_URL},OKTA_WEBAPP_CLIENT_ID=${OKTA_WEBAPP_CLIENT_ID},OKTA_WEBAPP_CLIENT_SECRET=${OKTA_WEBAPP_CLIENT_SECRET}}"

if aws lambda get-function --function-name "$BFF_FUNCTION_NAME" --region "$REGION" &>/dev/null; then
  aws lambda update-function-code \
    --function-name "$BFF_FUNCTION_NAME" --zip-file "fileb://$BFF_ZIP" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-updated --function-name "$BFF_FUNCTION_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$BFF_FUNCTION_NAME" --environment "$BFF_ENV" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-updated --function-name "$BFF_FUNCTION_NAME" --region "$REGION"
else
  aws lambda create-function \
    --function-name "$BFF_FUNCTION_NAME" \
    --runtime python3.12 --role "$BFF_ROLE_ARN" \
    --handler handler.lambda_handler \
    --zip-file "fileb://$BFF_ZIP" \
    --timeout 30 --memory-size 128 \
    --description "ExpensePro BFF — PKCE code → org ID token exchange" \
    --environment "$BFF_ENV" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-active --function-name "$BFF_FUNCTION_NAME" --region "$REGION"
fi
rm -f "$BFF_ZIP"
BFF_LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$BFF_FUNCTION_NAME" --region "$REGION" \
  --query 'Configuration.FunctionArn' --output text)

# ─────────────────────────────────────────────
# 8. API Gateway for BFF
# ─────────────────────────────────────────────
echo ""
echo ">>> [8/8] API Gateway (BFF): $BFF_API_NAME"
EXISTING_BFF_API_ID=$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='$BFF_API_NAME'].ApiId" --output text)
[ "$EXISTING_BFF_API_ID" = "None" ] && EXISTING_BFF_API_ID=""

if [ -z "$EXISTING_BFF_API_ID" ]; then
  BFF_API_ID=$(aws apigatewayv2 create-api \
    --name "$BFF_API_NAME" --protocol-type HTTP \
    --description "ExpensePro BFF — org-token endpoint" \
    --cors-configuration 'AllowOrigins=["*"],AllowMethods=["POST","OPTIONS"],AllowHeaders=["Content-Type"],MaxAge=300' \
    --region "$REGION" --query 'ApiId' --output text)
else
  BFF_API_ID="$EXISTING_BFF_API_ID"
  echo "    Reusing existing API: $BFF_API_ID"
fi

# Integration
EXISTING_INT=$(aws apigatewayv2 get-integrations --api-id "$BFF_API_ID" --region "$REGION" \
  --query "Items[?IntegrationUri=='$BFF_LAMBDA_ARN'].IntegrationId" --output text)
[ "$EXISTING_INT" = "None" ] && EXISTING_INT=""
if [ -z "$EXISTING_INT" ]; then
  BFF_INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$BFF_API_ID" --integration-type AWS_PROXY \
    --integration-uri "$BFF_LAMBDA_ARN" --payload-format-version "2.0" \
    --region "$REGION" --query 'IntegrationId' --output text)
else
  BFF_INTEGRATION_ID="$EXISTING_INT"
fi

EXISTING_ROUTE=$(aws apigatewayv2 get-routes --api-id "$BFF_API_ID" --region "$REGION" \
  --query "Items[?RouteKey=='POST /org-token'].RouteId" --output text)
[ "$EXISTING_ROUTE" = "None" ] && EXISTING_ROUTE=""
[ -z "$EXISTING_ROUTE" ] && aws apigatewayv2 create-route --api-id "$BFF_API_ID" \
  --route-key "POST /org-token" --target "integrations/$BFF_INTEGRATION_ID" \
  --region "$REGION" --output text > /dev/null

aws lambda add-permission \
  --function-name "$BFF_FUNCTION_NAME" \
  --statement-id "allow-apigw-bff-${BFF_API_ID}" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$BFF_API_ID/*" \
  --region "$REGION" 2>/dev/null || true

EXISTING_STAGE=$(aws apigatewayv2 get-stages --api-id "$BFF_API_ID" --region "$REGION" \
  --query "Items[?StageName=='live'].StageName" --output text)
[ "$EXISTING_STAGE" = "None" ] && EXISTING_STAGE=""
if [ -z "$EXISTING_STAGE" ]; then
  aws apigatewayv2 create-stage --api-id "$BFF_API_ID" --stage-name "live" --auto-deploy \
    --region "$REGION" --output text > /dev/null
else
  aws apigatewayv2 create-deployment --api-id "$BFF_API_ID" --stage-name "live" \
    --region "$REGION" --output text > /dev/null
fi

ORG_TOKEN_URL="https://${BFF_API_ID}.execute-api.${REGION}.amazonaws.com/live/org-token"
echo "    BFF org-token URL: $ORG_TOKEN_URL"

# ─────────────────────────────────────────────
# Save state
# ─────────────────────────────────────────────
cat > "$STATE_FILE" <<EOF
RUNTIME_ARN=${RUNTIME_ARN}
RUNTIME_INVOCATION_URL=${RUNTIME_INVOCATION_URL}
GATEWAY_ID=${GATEWAY_ID}
GATEWAY_MCP_URL=${GATEWAY_MCP_URL}
INTERCEPTOR_LAMBDA_ARN=${INTERCEPTOR_LAMBDA_ARN}
BFF_API_ID=${BFF_API_ID}
ORG_TOKEN_URL=${ORG_TOKEN_URL}
ECR_URI=${ECR_URI}
XAA_SECRET_ARN=${XAA_SECRET_ARN}
RUNTIME_ROLE_NAME=${RUNTIME_ROLE_NAME}
INTERCEPTOR_ROLE_NAME=${INTERCEPTOR_ROLE_NAME}
GATEWAY_ROLE_NAME=${GATEWAY_ROLE_NAME}
BFF_ROLE_NAME=${BFF_ROLE_NAME}
REGION=${REGION}
ACCOUNT_ID=${ACCOUNT_ID}
EOF

echo ""
echo "════════════════════════════════════════════════════════════════"
echo " ✓  ExpensePro AgentCore deployment complete!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  AgentCore Runtime URL : $RUNTIME_INVOCATION_URL"
echo "  BFF org-token URL     : $ORG_TOKEN_URL"
echo "  Gateway MCP URL       : $GATEWAY_MCP_URL"
echo ""
echo "  ── Web app config ──────────────────────────────────────────"
echo "  Update demo-expenses-web/config.js.template and re-deploy:"
echo "    export OKTA_CLIENT_ID=\"<spa-client-id>\""
echo "    export CHAT_API_URL=\"$RUNTIME_INVOCATION_URL\""
echo "    export ORG_TOKEN_URL=\"$ORG_TOKEN_URL\""
echo "    ./demo-expenses-web/deploy_web_aws.sh"
echo ""
echo "  ── Tear down ────────────────────────────────────────────────"
echo "    ./teardown_agentcore_aws.sh"
echo ""
