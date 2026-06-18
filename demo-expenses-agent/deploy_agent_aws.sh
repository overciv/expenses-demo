#!/usr/bin/env bash
# deploy_agent_aws.sh — deploy the ExpensePro AI chat agent to AWS Lambda + API Gateway
#
# Required env vars:
#   OKTA_ORG_URL              — Okta org base URL (e.g. https://zelemon.oktapreview.com)
#   OKTA_WEBAPP_CLIENT_ID     — Okta Web App (confidential client) client ID
#   OKTA_WEBAPP_CLIENT_SECRET — Okta Web App client secret
#   OKTA_ISSUER               — Custom AS issuer (auto-read from demo-expenses-api/.deploy-state)
#   EXPENSES_API_URL          — Expenses REST API URL (auto-read from demo-expenses-api/.deploy-state)
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_STATE_API="$SCRIPT_DIR/../demo-expenses-api/.deploy-state"

# ─────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────
for VAR in OKTA_ORG_URL OKTA_WEBAPP_CLIENT_ID OKTA_WEBAPP_CLIENT_SECRET OKTA_AGENT_CLIENT_ID OKTA_PRIVATE_KEY_PEM; do
  if [ -z "${!VAR:-}" ]; then
    echo "ERROR: $VAR is required."
    exit 1
  fi
done

if [ -z "${OKTA_ISSUER:-}" ] || [ -z "${EXPENSES_API_URL:-}" ]; then
  if [ -f "$DEPLOY_STATE_API" ]; then
    API_ID=$(grep ^API_ID= "$DEPLOY_STATE_API" | cut -d= -f2)
    API_REGION=$(grep ^REGION= "$DEPLOY_STATE_API" | cut -d= -f2)
    OKTA_ISSUER="${OKTA_ISSUER:-$(aws apigatewayv2 get-authorizers --api-id "$API_ID" --region "$API_REGION" --query 'Items[0].JwtConfiguration.Issuer' --output text)}"
    EXPENSES_API_URL="${EXPENSES_API_URL:-https://${API_ID}.execute-api.${API_REGION}.amazonaws.com/demo}"
    echo "  Auto-detected OKTA_ISSUER  : $OKTA_ISSUER"
    echo "  Auto-detected EXPENSES_API_URL: $EXPENSES_API_URL"
  else
    echo "ERROR: OKTA_ISSUER and EXPENSES_API_URL are required (or run demo-expenses-api/deploy.sh first)."
    exit 1
  fi
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
FUNCTION_NAME="expenses-chat-handler"
ROLE_NAME="expenses-chat-lambda-role"
API_NAME="expenses-chat-api"
SECRET_NAME="expenses/agent-client-secret"

echo "=== ExpensePro AI Agent — Deploy ==="
echo "Region          : $REGION"
echo "Account         : $ACCOUNT_ID"
echo "Okta org URL    : $OKTA_ORG_URL"
echo "Okta issuer     : $OKTA_ISSUER"
echo "Expenses API    : $EXPENSES_API_URL"
echo "WebApp client ID: $OKTA_WEBAPP_CLIENT_ID"
echo ""

# ─────────────────────────────────────────────
# 1. Store client secret in Secrets Manager
# ─────────────────────────────────────────────
echo ">>> [1/6] Secrets Manager: $SECRET_NAME"
OKTA_PRIVATE_KEY_ID="${OKTA_PRIVATE_KEY_ID:-expenses-agent-key-1}"
SECRET_PAYLOAD=$(python3 -c "
import json
print(json.dumps({
  'client_id':      '${OKTA_WEBAPP_CLIENT_ID}',
  'private_key_pem': '''${OKTA_PRIVATE_KEY_PEM}''',
  'key_id':          '${OKTA_PRIVATE_KEY_ID}',
}))
")

if aws secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" &>/dev/null; then
  aws secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "$SECRET_PAYLOAD" \
    --region "$REGION" --output text > /dev/null
  echo "    Secret updated."
else
  aws secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Okta Web App credentials for ExpensePro AI agent" \
    --secret-string "$SECRET_PAYLOAD" \
    --region "$REGION" --output text > /dev/null
  echo "    Secret created."
fi

SECRET_ARN=$(aws secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" \
  --region "$REGION" \
  --query 'ARN' --output text)
echo "    ARN: $SECRET_ARN"

# ─────────────────────────────────────────────
# 2. IAM Role
# ─────────────────────────────────────────────
echo ""
echo ">>> [2/6] IAM role: $ROLE_NAME"
TRUST_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
  echo "    Role already exists — skipping creation."
else
  ROLE_ARN=$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "    Waiting 15s for IAM propagation..."
  sleep 15
fi
echo "    Role ARN: $ROLE_ARN"

# Inline policy: Secrets Manager + Bedrock InvokeModel
INLINE_POLICY=$(python3 -c "
import json
print(json.dumps({
  'Version': '2012-10-17',
  'Statement': [
    {
      'Effect': 'Allow',
      'Action': ['secretsmanager:GetSecretValue'],
      'Resource': '${SECRET_ARN}'
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
      'Action': [
        'aws-marketplace:ViewSubscriptions',
        'aws-marketplace:Subscribe',
        'aws-marketplace:Unsubscribe'
      ],
      'Resource': '*'
    }
  ]
}))
")
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "expenses-chat-permissions" \
  --policy-document "$INLINE_POLICY"
echo "    Inline policy attached (Secrets Manager + Bedrock)."

# ─────────────────────────────────────────────
# 3. Package Lambda (with dependency cache)
# ─────────────────────────────────────────────
echo ""
echo ">>> [3/6] Packaging Lambda"

BUILD_DIR="$SCRIPT_DIR/.build"
DEPS_DIR="$SCRIPT_DIR/.build-deps"
DEPS_HASH_FILE="$SCRIPT_DIR/.build-deps-hash"
CURRENT_HASH=$(shasum -a 256 "$SCRIPT_DIR/requirements.txt" | cut -d' ' -f1)
CACHED_HASH=$(cat "$DEPS_HASH_FILE" 2>/dev/null || echo "")

if [ "$CURRENT_HASH" != "$CACHED_HASH" ]; then
  echo "    requirements.txt changed — installing linux/amd64 wheels (this takes ~1 min)..."
  rm -rf "$DEPS_DIR" && mkdir -p "$DEPS_DIR"
  pip3 install \
    -r "$SCRIPT_DIR/requirements.txt" \
    -t "$DEPS_DIR" \
    --platform manylinux2014_x86_64 \
    --implementation cp \
    --python-version 3.12 \
    --only-binary=:all: \
    --upgrade \
    -q
  echo "$CURRENT_HASH" > "$DEPS_HASH_FILE"
  echo "    Dependencies cached in .build-deps/."
else
  echo "    requirements.txt unchanged — using cached dependencies (skipping pip install)."
fi

# Assemble: cached deps + source files → zip
rm -rf "$BUILD_DIR" && cp -r "$DEPS_DIR" "$BUILD_DIR"
cp "$SCRIPT_DIR/handler.py" "$SCRIPT_DIR/agent.py" "$SCRIPT_DIR/okta_xaa.py" "$SCRIPT_DIR/org_token.py" "$BUILD_DIR/"
(cd "$BUILD_DIR" && zip -q -r "$SCRIPT_DIR/.build.zip" .)
echo "    Package: $SCRIPT_DIR/.build.zip ($(du -sh "$SCRIPT_DIR/.build.zip" | cut -f1))"

# ─────────────────────────────────────────────
# 4. Lambda function
# ─────────────────────────────────────────────
echo ""
echo ">>> [4/6] Lambda function: $FUNCTION_NAME"

MCP_SERVER_URL="${MCP_SERVER_URL:-https://g45wqjhenu.us-east-1.awsapprunner.com/mcp}"
ENV_VARS="Variables={OKTA_ORG_URL=${OKTA_ORG_URL},OKTA_ISSUER=${OKTA_ISSUER},OKTA_WEBAPP_CLIENT_ID=${OKTA_WEBAPP_CLIENT_ID},OKTA_WEBAPP_CLIENT_SECRET=${OKTA_WEBAPP_CLIENT_SECRET},OKTA_AGENT_CLIENT_ID=${OKTA_AGENT_CLIENT_ID},OKTA_PRIVATE_KEY_PEM=${OKTA_PRIVATE_KEY_PEM},OKTA_PRIVATE_KEY_ID=${OKTA_PRIVATE_KEY_ID:-expenses-agent-key-1},EXPENSES_API_URL=${EXPENSES_API_URL},MCP_SERVER_URL=${MCP_SERVER_URL}}"

if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" &>/dev/null; then
  echo "    Function exists — updating code."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$SCRIPT_DIR/.build.zip" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --environment "$ENV_VARS" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region "$REGION"
else
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler handler.lambda_handler \
    --zip-file "fileb://$SCRIPT_DIR/.build.zip" \
    --timeout 120 \
    --memory-size 512 \
    --description "ExpensePro AI chat — Strands agent with Okta Cross-App Access" \
    --environment "$ENV_VARS" \
    --region "$REGION" --output text > /dev/null
  aws lambda wait function-active --function-name "$FUNCTION_NAME" --region "$REGION"
fi
echo "    Lambda deployed."

LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" --region "$REGION" \
  --query 'Configuration.FunctionArn' --output text)

# ─────────────────────────────────────────────
# 5. API Gateway HTTP API
# ─────────────────────────────────────────────
echo ""
echo ">>> [5/6] API Gateway: $API_NAME"

EXISTING_API_ID=$(aws apigatewayv2 get-apis \
  --region "$REGION" \
  --query "Items[?Name=='$API_NAME'].ApiId" \
  --output text)
[ "$EXISTING_API_ID" = "None" ] && EXISTING_API_ID=""

if [ -n "$EXISTING_API_ID" ]; then
  CHAT_API_ID="$EXISTING_API_ID"
  echo "    API already exists — reusing $CHAT_API_ID"
else
  CHAT_API_ID=$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --description "ExpensePro AI chat endpoint" \
    --cors-configuration 'AllowOrigins=["*"],AllowMethods=["POST","OPTIONS"],AllowHeaders=["Content-Type"],MaxAge=300' \
    --region "$REGION" \
    --query 'ApiId' --output text)
  echo "    Created API: $CHAT_API_ID"
fi

# Lambda integration
EXISTING_INTEGRATION=$(aws apigatewayv2 get-integrations \
  --api-id "$CHAT_API_ID" --region "$REGION" \
  --query "Items[?IntegrationUri=='$LAMBDA_ARN'].IntegrationId" \
  --output text)
[ "$EXISTING_INTEGRATION" = "None" ] && EXISTING_INTEGRATION=""

if [ -n "$EXISTING_INTEGRATION" ]; then
  INTEGRATION_ID="$EXISTING_INTEGRATION"
  echo "    Reusing integration: $INTEGRATION_ID"
else
  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$CHAT_API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$LAMBDA_ARN" \
    --payload-format-version "2.0" \
    --region "$REGION" \
    --query 'IntegrationId' --output text)
  echo "    Integration created: $INTEGRATION_ID"
fi

# POST /chat route
EXISTING_ROUTE=$(aws apigatewayv2 get-routes \
  --api-id "$CHAT_API_ID" --region "$REGION" \
  --query "Items[?RouteKey=='POST /chat'].RouteId" \
  --output text)
[ "$EXISTING_ROUTE" = "None" ] && EXISTING_ROUTE=""
if [ -z "$EXISTING_ROUTE" ]; then
  aws apigatewayv2 create-route --api-id "$CHAT_API_ID" \
    --route-key "POST /chat" --target "integrations/$INTEGRATION_ID" \
    --region "$REGION" --output text > /dev/null
  echo "    Route created: POST /chat"
else
  echo "    Route already exists: POST /chat"
fi

# POST /org-token route (code → org ID token via client_secret)
EXISTING_ORG_ROUTE=$(aws apigatewayv2 get-routes \
  --api-id "$CHAT_API_ID" --region "$REGION" \
  --query "Items[?RouteKey=='POST /org-token'].RouteId" \
  --output text)
[ "$EXISTING_ORG_ROUTE" = "None" ] && EXISTING_ORG_ROUTE=""
if [ -z "$EXISTING_ORG_ROUTE" ]; then
  aws apigatewayv2 create-route --api-id "$CHAT_API_ID" \
    --route-key "POST /org-token" --target "integrations/$INTEGRATION_ID" \
    --region "$REGION" --output text > /dev/null
  echo "    Route created: POST /org-token"
else
  echo "    Route already exists: POST /org-token"
fi

# Lambda permission for API Gateway
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "allow-apigw-chat-${CHAT_API_ID}" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$CHAT_API_ID/*" \
  --region "$REGION" 2>/dev/null || echo "    Lambda permission already exists."

# Stage
EXISTING_STAGE=$(aws apigatewayv2 get-stages \
  --api-id "$CHAT_API_ID" --region "$REGION" \
  --query "Items[?StageName=='live'].StageName" --output text)
[ "$EXISTING_STAGE" = "None" ] && EXISTING_STAGE=""

if [ -z "$EXISTING_STAGE" ]; then
  aws apigatewayv2 create-stage \
    --api-id "$CHAT_API_ID" --stage-name "live" --auto-deploy \
    --region "$REGION" --output text > /dev/null
else
  aws apigatewayv2 create-deployment \
    --api-id "$CHAT_API_ID" --stage-name "live" \
    --region "$REGION" --output text > /dev/null
fi

CHAT_API_URL="https://${CHAT_API_ID}.execute-api.${REGION}.amazonaws.com/live/chat"
echo "    Chat API URL: $CHAT_API_URL"

# ─────────────────────────────────────────────
# 6. Save state
# ─────────────────────────────────────────────
echo ""
echo ">>> [6/6] Saving state"
cat > "$SCRIPT_DIR/.deploy-agent-state" <<EOF
CHAT_API_ID=$CHAT_API_ID
CHAT_API_URL=$CHAT_API_URL
FUNCTION_NAME=$FUNCTION_NAME
ROLE_NAME=$ROLE_NAME
SECRET_ARN=$SECRET_ARN
REGION=$REGION
ACCOUNT_ID=$ACCOUNT_ID
EOF

rm -rf "$BUILD_DIR" "$SCRIPT_DIR/.build.zip"

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo " ✓  ExpensePro AI Agent deployed!"
echo "════════════════════════════════════════════"
echo ""
echo "  Chat API URL : $CHAT_API_URL"
echo "  Lambda       : $FUNCTION_NAME"
echo "  Model        : Claude 3 Sonnet (Bedrock)"
echo "  Token flow   : Okta Cross-App Access (org ID token → ID-JAG → expenses token)"
echo ""
echo "  ── Next step: update the web app config ────────────────────────"
echo ""
echo "  Run deploy_web_aws.sh with these additional vars:"
echo "    export OKTA_ORG_URL=\"$OKTA_ORG_URL\""
echo "    export OKTA_CLIENT_ID=\"<spa-client-id>\""
echo "    export CHAT_API_URL=\"$CHAT_API_URL\""
echo "    export OKTA_ISSUER=\"$OKTA_ISSUER\""
echo "    ./demo-expenses-web/deploy_web_aws.sh"
echo ""
echo "  ── Okta Web App prerequisites ───────────────────────────────────"
echo ""
echo "  Ensure your Okta Web App ($OKTA_WEBAPP_CLIENT_ID) is configured:"
echo "    1. Grant types: ✓ Client Credentials (for token exchange)"
echo "    2. Client authentication: client_secret_post (default)"
echo "    3. Assign the Web App to the custom AS resource connection:"
echo "       Admin Console → Security → API → AI Agents (Cross-App Access)"
echo "       → Resource Connection → target: $OKTA_ISSUER"
echo ""
echo "  ── Tear down ─────────────────────────────────────────────────────"
echo "    ./teardown_agent_aws.sh"
echo ""
