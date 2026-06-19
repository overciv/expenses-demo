#!/usr/bin/env bash
# deploy.sh — build and deploy the demo Expenses API to AWS
# Usage:  OKTA_ISSUER=<issuer> OKTA_AUDIENCE=<audience> ./deploy.sh
set -euo pipefail

# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
FUNCTION_NAME="expenses-api"
ROLE_NAME="expenses-api-lambda-role"
API_NAME="expenses-api"
STAGE_NAME="demo"
TABLE_NAME="expenses-demo"

OKTA_ISSUER="${OKTA_ISSUER:-}"
OKTA_AUDIENCE="${OKTA_AUDIENCE:-api://expenses}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMBDA_DIR="$SCRIPT_DIR/lambda"
BUILD_DIR="$SCRIPT_DIR/.build"

# ─────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────
if [ -z "$OKTA_ISSUER" ]; then
  echo "ERROR: OKTA_ISSUER is required."
  echo "  export OKTA_ISSUER=https://<org>.okta.com/oauth2/<auth-server-id>"
  exit 1
fi

echo "=== Expenses API — Deploy ==="
echo "Region    : $REGION"
echo "Issuer    : $OKTA_ISSUER"
echo "Audience  : $OKTA_AUDIENCE"
echo "DynamoDB  : $TABLE_NAME"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account: $ACCOUNT_ID"
echo ""

# ─────────────────────────────────────────────
# 1. IAM Role + DynamoDB policy
# ─────────────────────────────────────────────
echo ">>> [1/8] Creating IAM role: $ROLE_NAME"

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "lambda.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "    Role already exists — skipping creation."
  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)
else
  ROLE_ARN=$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query 'Role.Arn' \
    --output text)
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  echo "    Waiting 15 s for IAM role propagation..."
  sleep 15
fi

echo "    Role ARN: $ROLE_ARN"

# Inline policy: allow Lambda to read/write the expenses DynamoDB table
DYNAMODB_POLICY=$(python3 -c "
import json
print(json.dumps({
  'Version': '2012-10-17',
  'Statement': [{
    'Effect': 'Allow',
    'Action': ['dynamodb:PutItem', 'dynamodb:Scan', 'dynamodb:DeleteItem'],
    'Resource': 'arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}'
  }]
}))
")
aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "expenses-dynamodb-access" \
  --policy-document "$DYNAMODB_POLICY"
echo "    DynamoDB inline policy attached."

# ─────────────────────────────────────────────
# 2. DynamoDB table
# ─────────────────────────────────────────────
echo ""
echo ">>> [2/8] DynamoDB table: $TABLE_NAME"

if aws dynamodb describe-table --table-name "$TABLE_NAME" --region "$REGION" &>/dev/null; then
  echo "    Table already exists — skipping."
else
  aws dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" \
    --query 'TableDescription.TableArn' \
    --output text
  echo "    Waiting for table to become ACTIVE..."
  aws dynamodb wait table-exists --table-name "$TABLE_NAME" --region "$REGION"
  echo "    Table ready."
fi

# ─────────────────────────────────────────────
# 3. Package Lambda
# ─────────────────────────────────────────────
echo ""
echo ">>> [3/8] Packaging Lambda function"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
cp "$LAMBDA_DIR/handler.py" "$BUILD_DIR/"
(cd "$BUILD_DIR" && zip -q function.zip handler.py)
echo "    Package: $BUILD_DIR/function.zip"

# ─────────────────────────────────────────────
# 4. Lambda Function
# ─────────────────────────────────────────────
echo ""
echo ">>> [4/8] Deploying Lambda function: $FUNCTION_NAME"

if aws lambda get-function --function-name "$FUNCTION_NAME" --region "$REGION" &>/dev/null; then
  echo "    Function exists — updating code."
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$BUILD_DIR/function.zip" \
    --region "$REGION" \
    --query 'FunctionArn' \
    --output text
  # Wait for update to complete before updating config
  aws lambda wait function-updated \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION"
else
  LAMBDA_ARN=$(aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --role "$ROLE_ARN" \
    --handler handler.lambda_handler \
    --zip-file "fileb://$BUILD_DIR/function.zip" \
    --timeout 10 \
    --description "Demo Expenses API protected by Okta OAuth 2.1" \
    --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME}" \
    --region "$REGION" \
    --query 'FunctionArn' \
    --output text)
  echo "    Lambda ARN: $LAMBDA_ARN"
  aws lambda wait function-active \
    --function-name "$FUNCTION_NAME" \
    --region "$REGION"
fi

# Always ensure the env var is set (idempotent for updates)
aws lambda update-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --environment "Variables={DYNAMODB_TABLE=$TABLE_NAME}" \
  --region "$REGION" \
  --query 'FunctionArn' \
  --output text > /dev/null
echo "    Environment: DYNAMODB_TABLE=$TABLE_NAME"

LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION" \
  --query 'Configuration.FunctionArn' \
  --output text)

# ─────────────────────────────────────────────
# 5. HTTP API Gateway
# ─────────────────────────────────────────────
echo ""
echo ">>> [5/8] Creating HTTP API: $API_NAME"

EXISTING_API_ID=$(aws apigatewayv2 get-apis \
  --region "$REGION" \
  --query "Items[?Name=='$API_NAME'].ApiId" \
  --output text)

if [ -n "$EXISTING_API_ID" ]; then
  API_ID="$EXISTING_API_ID"
  echo "    API already exists — reusing $API_ID"
else
  API_ID=$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --description "Demo Expenses API protected by Okta JWT" \
    --region "$REGION" \
    --query 'ApiId' \
    --output text)
  echo "    Created API: $API_ID"
fi

# Enable CORS so browser-based clients (the web portal) can call the API.
# HTTP API native CORS handles OPTIONS preflight before the JWT authorizer runs.
aws apigatewayv2 update-api \
  --api-id "$API_ID" \
  --cors-configuration 'AllowOrigins=["*"],AllowMethods=["GET","POST","DELETE","OPTIONS"],AllowHeaders=["Authorization","Content-Type"],MaxAge=300' \
  --region "$REGION" \
  --output json > /dev/null
echo "    CORS configured (AllowOrigins=*, AllowMethods=GET,POST,DELETE,OPTIONS)"

# ─────────────────────────────────────────────
# 6. JWT Authorizer
# ─────────────────────────────────────────────
echo ""
echo ">>> [6/8] Creating JWT authorizer (Okta)"

EXISTING_AUTH_ID=$(aws apigatewayv2 get-authorizers \
  --api-id "$API_ID" \
  --region "$REGION" \
  --query "Items[?Name=='okta-jwt'].AuthorizerId" \
  --output text)

if [ -n "$EXISTING_AUTH_ID" ]; then
  echo "    Updating existing authorizer: $EXISTING_AUTH_ID"
  AUTHORIZER_ID=$(aws apigatewayv2 update-authorizer \
    --api-id "$API_ID" \
    --authorizer-id "$EXISTING_AUTH_ID" \
    --identity-source '$request.header.Authorization' \
    --jwt-configuration "Issuer=$OKTA_ISSUER,Audience=$OKTA_AUDIENCE" \
    --region "$REGION" \
    --query 'AuthorizerId' \
    --output text)
else
  AUTHORIZER_ID=$(aws apigatewayv2 create-authorizer \
    --api-id "$API_ID" \
    --authorizer-type JWT \
    --name okta-jwt \
    --identity-source '$request.header.Authorization' \
    --jwt-configuration "Issuer=$OKTA_ISSUER,Audience=$OKTA_AUDIENCE" \
    --region "$REGION" \
    --query 'AuthorizerId' \
    --output text)
fi
echo "    Authorizer ID: $AUTHORIZER_ID"

# ─────────────────────────────────────────────
# 7. Lambda Integration + Routes
# ─────────────────────────────────────────────
echo ""
echo ">>> [7/8] Creating integration and routes"

EXISTING_INTEGRATION_ID=$(aws apigatewayv2 get-integrations \
  --api-id "$API_ID" \
  --region "$REGION" \
  --query "Items[?IntegrationUri=='$LAMBDA_ARN'].IntegrationId" \
  --output text)

if [ -n "$EXISTING_INTEGRATION_ID" ]; then
  INTEGRATION_ID="$EXISTING_INTEGRATION_ID"
  echo "    Reusing integration: $INTEGRATION_ID"
else
  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$LAMBDA_ARN" \
    --payload-format-version "2.0" \
    --region "$REGION" \
    --query 'IntegrationId' \
    --output text)
  echo "    Integration ID: $INTEGRATION_ID"
fi

aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "allow-apigw-${API_ID}" \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:$REGION:$ACCOUNT_ID:$API_ID/*" \
  --region "$REGION" \
  2>/dev/null || echo "    Lambda permission already exists — skipping."

create_or_update_route() {
  local ROUTE_KEY="$1"
  local SCOPE="$2"

  EXISTING_ROUTE_ID=$(aws apigatewayv2 get-routes \
    --api-id "$API_ID" \
    --region "$REGION" \
    --query "Items[?RouteKey=='$ROUTE_KEY'].RouteId" \
    --output text)

  if [ -n "$EXISTING_ROUTE_ID" ]; then
    aws apigatewayv2 update-route \
      --api-id "$API_ID" \
      --route-id "$EXISTING_ROUTE_ID" \
      --authorization-type JWT \
      --authorizer-id "$AUTHORIZER_ID" \
      --authorization-scopes "$SCOPE" \
      --target "integrations/$INTEGRATION_ID" \
      --region "$REGION" \
      --query 'RouteId' \
      --output text
    echo "    Updated route  : $ROUTE_KEY  [scope: $SCOPE]"
  else
    aws apigatewayv2 create-route \
      --api-id "$API_ID" \
      --route-key "$ROUTE_KEY" \
      --authorization-type JWT \
      --authorizer-id "$AUTHORIZER_ID" \
      --authorization-scopes "$SCOPE" \
      --target "integrations/$INTEGRATION_ID" \
      --region "$REGION" \
      --query 'RouteId' \
      --output text
    echo "    Created route  : $ROUTE_KEY  [scope: $SCOPE]"
  fi
}

create_or_update_route "GET /expenses"                "expenses:read"
create_or_update_route "POST /expenses"               "expenses:write"
create_or_update_route "DELETE /expenses/{expenseId}" "expenses:delete"

# ─────────────────────────────────────────────
# 8. Stage (auto-deploy)
# ─────────────────────────────────────────────
echo ""
echo ">>> [8/8] Deploying stage: $STAGE_NAME"

EXISTING_STAGE=$(aws apigatewayv2 get-stages \
  --api-id "$API_ID" \
  --region "$REGION" \
  --query "Items[?StageName=='$STAGE_NAME'].StageName" \
  --output text)

if [ -n "$EXISTING_STAGE" ]; then
  echo "    Stage already exists — triggering a new deployment."
  aws apigatewayv2 create-deployment \
    --api-id "$API_ID" \
    --stage-name "$STAGE_NAME" \
    --region "$REGION" \
    --query 'DeploymentId' \
    --output text
else
  aws apigatewayv2 create-stage \
    --api-id "$API_ID" \
    --stage-name "$STAGE_NAME" \
    --auto-deploy \
    --region "$REGION" \
    --query 'StageName' \
    --output text
fi

# ─────────────────────────────────────────────
# Warm-up — EventBridge rule pings Lambda every 5 minutes to prevent cold starts
# ─────────────────────────────────────────────
WARMUP_RULE="expenses-api-warmup"
echo ">>> Warm-up: EventBridge rule ($WARMUP_RULE, rate 5 min)"
aws events put-rule \
  --name "$WARMUP_RULE" \
  --schedule-expression "rate(5 minutes)" \
  --description "Keep expenses-api Lambda warm to avoid cold-start latency" \
  --state ENABLED \
  --region "$REGION" --output text > /dev/null
WARMUP_RULE_ARN="arn:aws:events:${REGION}:${ACCOUNT_ID}:rule/${WARMUP_RULE}"
aws events put-targets \
  --rule "$WARMUP_RULE" \
  --targets "[{\"Id\":\"expenses-api-warm\",\"Arn\":\"${LAMBDA_ARN}\"}]" \
  --region "$REGION" --output text > /dev/null
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id "allow-eventbridge-warmup" \
  --action lambda:InvokeFunction \
  --principal events.amazonaws.com \
  --source-arn "$WARMUP_RULE_ARN" \
  --region "$REGION" 2>/dev/null || true
echo "    Warm-up rule active — Lambda will be pinged every 5 minutes."

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE_NAME}"

echo ""
echo "════════════════════════════════════════════"
echo " ✓  Expenses API deployed successfully!"
echo "════════════════════════════════════════════"
echo ""
echo "  API URL   : $API_URL"
echo "  Audience  : $OKTA_AUDIENCE"
echo "  Issuer    : $OKTA_ISSUER"
echo "  DynamoDB  : $TABLE_NAME"
echo ""
echo "  Endpoints:"
echo "    GET  $API_URL/expenses   (requires scope: expenses:read)"
echo "    POST $API_URL/expenses   (requires scope: expenses:write)"
echo ""
echo "  Test (replace TOKEN with a valid Okta access token):"
echo "    curl -H 'Authorization: Bearer \$TOKEN' $API_URL/expenses"
echo ""
echo "  To tear down:  ./teardown.sh"
echo ""

# Save state for teardown
cat > "$SCRIPT_DIR/.deploy-state" <<EOF
API_ID=$API_ID
REGION=$REGION
FUNCTION_NAME=$FUNCTION_NAME
ROLE_NAME=$ROLE_NAME
TABLE_NAME=$TABLE_NAME
ACCOUNT_ID=$ACCOUNT_ID
EOF
