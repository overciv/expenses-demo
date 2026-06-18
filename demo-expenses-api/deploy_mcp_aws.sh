#!/usr/bin/env bash
# deploy_mcp_aws.sh — build & deploy the Expenses MCP Server to AWS App Runner
# Usage: ./deploy_mcp_aws.sh
set -euo pipefail

# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
SERVICE_NAME="expenses-mcp-server"
ECR_REPO="expenses-mcp-server"
ECR_ACCESS_ROLE_NAME="expenses-mcp-apprunner-ecr-role"

OKTA_ISSUER="${OKTA_ISSUER:-}"
OKTA_AUDIENCE="${OKTA_AUDIENCE:-api://expenses}"
EXPENSES_API_URL="${EXPENSES_API_URL:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MCP_DIR="$SCRIPT_DIR/mcp_server"

# ─────────────────────────────────────────────
# Preflight
# ─────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker is required to build the container image."
  exit 1
fi

if [ -z "$OKTA_ISSUER" ]; then
  echo "ERROR: OKTA_ISSUER is required."
  echo "  export OKTA_ISSUER=https://<org>.okta.com/oauth2/<auth-server-id>"
  exit 1
fi

if [ -z "$EXPENSES_API_URL" ]; then
  echo "ERROR: EXPENSES_API_URL is required."
  echo "  export EXPENSES_API_URL=https://<api-id>.execute-api.<region>.amazonaws.com/demo"
  exit 1
fi

echo "=== Expenses MCP Server — Deploy to App Runner ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
ECR_URI="${ECR_REGISTRY}/${ECR_REPO}"

echo "Region       : $REGION"
echo "Account      : $ACCOUNT_ID"
echo "Registry     : $ECR_REGISTRY"
echo "Okta issuer  : $OKTA_ISSUER"
echo "Audience     : $OKTA_AUDIENCE"
echo "Expenses API : $EXPENSES_API_URL"
echo ""

# ─────────────────────────────────────────────
# 1. ECR repository
# ─────────────────────────────────────────────
echo ">>> [1/5] ECR repository: $ECR_REPO"
if aws ecr describe-repositories --repository-names "$ECR_REPO" --region "$REGION" &>/dev/null; then
  echo "    Already exists."
else
  aws ecr create-repository \
    --repository-name "$ECR_REPO" \
    --region "$REGION" \
    --image-scanning-configuration scanOnPush=true \
    --query 'repository.repositoryUri' --output text
  echo "    Created."
fi

# ─────────────────────────────────────────────
# 2. Build & push Docker image
# ─────────────────────────────────────────────
echo ""
echo ">>> [2/5] Build & push Docker image"
echo "    Logging in to ECR..."
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

echo "    Building for linux/amd64 (App Runner is x86_64)..."
docker build --platform linux/amd64 -t "${ECR_REPO}:latest" "$MCP_DIR"
docker tag "${ECR_REPO}:latest" "${ECR_URI}:latest"

echo "    Pushing..."
docker push "${ECR_URI}:latest"
echo "    Done: ${ECR_URI}:latest"

# ─────────────────────────────────────────────
# 3. IAM role — App Runner ECR access
# ─────────────────────────────────────────────
echo ""
echo ">>> [3/5] IAM role for App Runner ECR access"

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "build.apprunner.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}'

if aws iam get-role --role-name "$ECR_ACCESS_ROLE_NAME" &>/dev/null; then
  echo "    Role already exists."
  ECR_ROLE_ARN=$(aws iam get-role \
    --role-name "$ECR_ACCESS_ROLE_NAME" \
    --query 'Role.Arn' --output text)
else
  ECR_ROLE_ARN=$(aws iam create-role \
    --role-name "$ECR_ACCESS_ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query 'Role.Arn' --output text)
  aws iam attach-role-policy \
    --role-name "$ECR_ACCESS_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess
  echo "    Waiting 10s for IAM propagation..."
  sleep 10
fi
echo "    Role ARN: $ECR_ROLE_ARN"

# ─────────────────────────────────────────────
# 4. App Runner service
# ─────────────────────────────────────────────
echo ""
echo ">>> [4/5] App Runner service: $SERVICE_NAME"

# Build source config JSON. MCP_BASE_URL is left blank on first create — App
# Runner only assigns the public hostname after the service exists, so we set
# it via a follow-up update once SERVICE_URL is known.
build_source_config() {
  local mcp_base_url="$1"
  python3 -c "
import json
cfg = {
  'ImageRepository': {
    'ImageIdentifier': '${ECR_URI}:latest',
    'ImageConfiguration': {
      'Port': '8001',
      'RuntimeEnvironmentVariables': {
        'EXPENSES_API_URL': '${EXPENSES_API_URL}',
        'OKTA_ISSUER':      '${OKTA_ISSUER}',
        'OKTA_AUDIENCE':    '${OKTA_AUDIENCE}',
        'MCP_TRANSPORT':    'streamable-http',
        'MCP_PORT':         '8001',
        'MCP_BASE_URL':     '${mcp_base_url}',
      }
    },
    'ImageRepositoryType': 'ECR'
  },
  'AutoDeploymentsEnabled': False,
  'AuthenticationConfiguration': {
    'AccessRoleArn': '${ECR_ROLE_ARN}'
  }
}
print(json.dumps(cfg))
"
}

HEALTH_CHECK='{"Protocol":"TCP","Interval":10,"Timeout":5,"HealthyThreshold":1,"UnhealthyThreshold":5}'
INSTANCE_CONFIG='{"Cpu":"0.25 vCPU","Memory":"0.5 GB"}'

# Check if service already exists
EXISTING_ARN=$(aws apprunner list-services \
  --region "$REGION" \
  --query "ServiceSummaryList[?ServiceName=='$SERVICE_NAME'].ServiceArn" \
  --output text)

if [ -n "$EXISTING_ARN" ]; then
  # Existing service: SERVICE_URL is already known, so embed MCP_BASE_URL on
  # the first (and only) update — avoids a second deployment cycle.
  EXISTING_URL=$(aws apprunner describe-service \
    --service-arn "$EXISTING_ARN" \
    --region "$REGION" \
    --query 'Service.ServiceUrl' \
    --output text)
  echo "    Service exists — updating config then forcing deployment. URL: $EXISTING_URL"
  SOURCE_CONFIG=$(build_source_config "https://${EXISTING_URL}")
  aws apprunner update-service \
    --service-arn "$EXISTING_ARN" \
    --source-configuration "$SOURCE_CONFIG" \
    --region "$REGION" \
    --output text > /dev/null
  # update-service doesn't always trigger a new deployment when the image tag
  # hasn't changed (AutoDeploymentsEnabled: false) — force one explicitly.
  aws apprunner start-deployment \
    --service-arn "$EXISTING_ARN" \
    --region "$REGION" \
    --output text > /dev/null
  SERVICE_ARN="$EXISTING_ARN"
else
  SOURCE_CONFIG=$(build_source_config "")
  SERVICE_ARN=$(aws apprunner create-service \
    --service-name "$SERVICE_NAME" \
    --source-configuration "$SOURCE_CONFIG" \
    --instance-configuration "$INSTANCE_CONFIG" \
    --health-check-configuration "$HEALTH_CHECK" \
    --region "$REGION" \
    --query 'Service.ServiceArn' --output text)
  echo "    Created ARN: $SERVICE_ARN"
fi

# ─────────────────────────────────────────────
# 5. Wait for RUNNING
# ─────────────────────────────────────────────
echo ""
echo ">>> [5/5] Waiting for service to reach RUNNING (~2-3 min)..."
SERVICE_URL=""
for i in $(seq 1 30); do
  INFO=$(aws apprunner describe-service \
    --service-arn "$SERVICE_ARN" \
    --region "$REGION" \
    --query '[Service.Status, Service.ServiceUrl]' \
    --output text)
  STATUS=$(echo "$INFO" | awk '{print $1}')
  SERVICE_URL=$(echo "$INFO" | awk '{print $2}')
  printf "    [%2d/30] %s\n" "$i" "$STATUS"
  if [ "$STATUS" = "RUNNING" ]; then break; fi
  if [[ "$STATUS" == *FAILED* ]]; then
    echo "ERROR: Service deployment failed. Check App Runner console."
    exit 1
  fi
  sleep 10
done

if [ "$STATUS" != "RUNNING" ]; then
  echo "ERROR: Timed out waiting for RUNNING state."
  exit 1
fi

MCP_URL="https://${SERVICE_URL}/mcp"

# ─────────────────────────────────────────────
# 5b. Patch MCP_BASE_URL for newly created services
# ─────────────────────────────────────────────
# Only needed when we just created the service: SOURCE_CONFIG was built with
# an empty MCP_BASE_URL because App Runner hadn't assigned the hostname yet.
# Now that SERVICE_URL is known, push it back so the protected-resource
# metadata advertises the real public URL instead of localhost.
if [ -z "$EXISTING_ARN" ]; then
  echo ""
  echo ">>> [5b/5] Setting MCP_BASE_URL=https://${SERVICE_URL} (triggers a second deploy)"
  PATCHED_CONFIG=$(build_source_config "https://${SERVICE_URL}")
  aws apprunner update-service \
    --service-arn "$SERVICE_ARN" \
    --source-configuration "$PATCHED_CONFIG" \
    --region "$REGION" \
    --output text > /dev/null

  for i in $(seq 1 30); do
    STATUS=$(aws apprunner describe-service \
      --service-arn "$SERVICE_ARN" \
      --region "$REGION" \
      --query 'Service.Status' --output text)
    printf "    [%2d/30] %s\n" "$i" "$STATUS"
    if [ "$STATUS" = "RUNNING" ]; then break; fi
    if [[ "$STATUS" == *FAILED* ]]; then
      echo "ERROR: MCP_BASE_URL patch failed. Check App Runner console."
      exit 1
    fi
    sleep 10
  done
fi

# ─────────────────────────────────────────────
# Save state for teardown
# ─────────────────────────────────────────────
cat > "$SCRIPT_DIR/.deploy-mcp-state" <<EOF
SERVICE_ARN=$SERVICE_ARN
SERVICE_URL=$SERVICE_URL
ECR_URI=$ECR_URI
ECR_REPO=$ECR_REPO
ECR_ACCESS_ROLE_NAME=$ECR_ACCESS_ROLE_NAME
REGION=$REGION
ACCOUNT_ID=$ACCOUNT_ID
EOF

echo ""
echo "════════════════════════════════════════════"
echo " ✓  Expenses MCP Server deployed!"
echo "════════════════════════════════════════════"
echo ""
echo "  MCP URL    : $MCP_URL"
echo "  Metadata   : https://${SERVICE_URL}/.well-known/oauth-protected-resource"
echo "             : https://${SERVICE_URL}/.well-known/oauth-protected-resource/mcp"
echo "  Auth       : Okta JWT (issuer: $OKTA_ISSUER, aud: $OKTA_AUDIENCE)"
echo ""
echo "  Clients must send:  Authorization: Bearer <okta-access-token>"
echo "  The token is forwarded to the expenses REST API — same token,"
echo "  scope enforcement happens at both layers."
echo ""
echo "  Register as a resource in okta-mcp-adapter (Admin API):"
echo "    POST http://localhost:8000/api/admin/resources"
echo "    {"
echo "      \"name\": \"expenses\","
echo "      \"url\": \"$MCP_URL\","
echo "      \"auth_method\": \"bearer-passthrough\","
echo "      \"paths\": [\"/expenses\"]"
echo "    }"
echo ""
echo "  To tear down:  ./teardown_mcp_aws.sh"
echo ""
