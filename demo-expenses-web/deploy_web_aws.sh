#!/usr/bin/env bash
# deploy_web_aws.sh — deploy the ExpensePro web app to S3 + CloudFront
#
# Required env vars:
#   OKTA_ISSUER       — Okta authorization server issuer URL
#   OKTA_CLIENT_ID    — Client ID of your Okta SPA application
#   EXPENSES_API_URL  — Base URL of the deployed expenses REST API
#
# Optional:
#   OKTA_AUDIENCE     — Audience claim (default: api://expenses)
#   AWS_DEFAULT_REGION — AWS region (default: us-east-1)
#
# Run order:
#   1. (First time) Run this script — it prints the CloudFront URL
#   2. Create/update your Okta SPA app with that redirect URI
#   3. Set OKTA_CLIENT_ID and re-run — embeds the real config
set -euo pipefail

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
OKTA_AUDIENCE="${OKTA_AUDIENCE:-api://expenses}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Optional: AI agent URLs — auto-read from .deploy-agentcore-state if present
AGENTCORE_STATE="$SCRIPT_DIR/../demo-expenses-agent/.deploy-agentcore-state"
if [ -f "$AGENTCORE_STATE" ]; then
  # Use cut -f2- (not -f2) to preserve = characters inside URL values (e.g. ?qualifier=DEFAULT)
  [ -z "${CHAT_API_URL:-}" ]  && CHAT_API_URL=$(grep  ^RUNTIME_INVOCATION_URL= "$AGENTCORE_STATE" | cut -d= -f2- || true)
  [ -z "${ORG_TOKEN_URL:-}" ] && ORG_TOKEN_URL=$(grep ^ORG_TOKEN_URL=          "$AGENTCORE_STATE" | cut -d= -f2- || true)
fi
CHAT_API_URL="${CHAT_API_URL:-__CHAT_API_URL__}"
ORG_TOKEN_URL="${ORG_TOKEN_URL:-__ORG_TOKEN_URL__}"

# Optional: Okta org base URL — strip custom AS path from OKTA_ISSUER if not set
if [ -z "${OKTA_ORG_URL:-}" ] && [ -n "${OKTA_ISSUER:-}" ]; then
  OKTA_ORG_URL=$(python3 -c "from urllib.parse import urlparse; u=urlparse('${OKTA_ISSUER}'); print(f'{u.scheme}://{u.netloc}')")
fi
OKTA_ORG_URL="${OKTA_ORG_URL:-__OKTA_ORG_URL__}"
DEPLOY_STATE_API="$SCRIPT_DIR/../demo-expenses-api/.deploy-state"

# ─────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────
if [ -z "${OKTA_ISSUER:-}" ]; then
  echo "ERROR: OKTA_ISSUER is required."
  echo "  export OKTA_ISSUER=https://<org>.okta.com/oauth2/<auth-server-id>"
  exit 1
fi

if [ -z "${OKTA_CLIENT_ID:-}" ]; then
  echo "WARNING: OKTA_CLIENT_ID is not set — deploying with placeholder config."
  echo "  The app will not function until you re-run with a valid OKTA_CLIENT_ID."
  echo "  (See end-of-script instructions for how to create the Okta SPA app.)"
  OKTA_CLIENT_ID="__REPLACE_WITH_OKTA_CLIENT_ID__"
fi

if [ -z "${EXPENSES_API_URL:-}" ]; then
  if [ -f "$DEPLOY_STATE_API" ]; then
    API_ID=$(grep ^API_ID= "$DEPLOY_STATE_API" | cut -d= -f2)
    API_REGION=$(grep ^REGION= "$DEPLOY_STATE_API" | cut -d= -f2)
    EXPENSES_API_URL="https://${API_ID}.execute-api.${API_REGION}.amazonaws.com/demo"
    echo "  EXPENSES_API_URL auto-detected from .deploy-state: $EXPENSES_API_URL"
  else
    echo "ERROR: EXPENSES_API_URL is required (or run deploy.sh first to create .deploy-state)."
    exit 1
  fi
fi

echo "=== ExpensePro Web App — Deploy ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="expenses-web-demo-${ACCOUNT_ID}"
echo "Region       : $REGION"
echo "Account      : $ACCOUNT_ID"
echo "S3 Bucket    : $BUCKET_NAME"
echo "Okta issuer  : $OKTA_ISSUER"
echo "Expenses API : $EXPENSES_API_URL"
echo ""

# ─────────────────────────────────────────────
# 1. Update API Gateway CORS (idempotent)
# ─────────────────────────────────────────────
if [ -f "$DEPLOY_STATE_API" ]; then
  API_ID=$(grep ^API_ID= "$DEPLOY_STATE_API" | cut -d= -f2)
  API_REGION=$(grep ^REGION= "$DEPLOY_STATE_API" | cut -d= -f2)
  echo ">>> [1/6] Updating API Gateway CORS: $API_ID"
  aws apigatewayv2 update-api \
    --api-id "$API_ID" \
    --cors-configuration 'AllowOrigins=["*"],AllowMethods=["GET","POST","DELETE","OPTIONS"],AllowHeaders=["Authorization","Content-Type"],MaxAge=300' \
    --region "$API_REGION" \
    --output json > /dev/null
  echo "    CORS enabled (AllowOrigins=*, AllowMethods=GET,POST,DELETE,OPTIONS)"
else
  echo ">>> [1/6] Skipping CORS update — .deploy-state not found (run demo-expenses-api/deploy.sh first)"
fi

# ─────────────────────────────────────────────
# 2. Create S3 bucket (private — access via CloudFront OAC only)
# ─────────────────────────────────────────────
echo ""
echo ">>> [2/6] S3 bucket: $BUCKET_NAME (private)"

if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$REGION" > /dev/null 2>&1; then
  echo "    Bucket already exists."
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$REGION" \
      --output text > /dev/null
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION" \
      --output text > /dev/null
  fi
  echo "    Bucket created."
fi

# ─────────────────────────────────────────────
# 3. CloudFront OAC + distribution
# ─────────────────────────────────────────────
echo ""
echo ">>> [3/6] CloudFront distribution (OAC)"

S3_ORIGIN_DOMAIN="${BUCKET_NAME}.s3.${REGION}.amazonaws.com"

EXISTING_CF_ID=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?Origins.Items[?DomainName=='${S3_ORIGIN_DOMAIN}']].Id" \
  --output text 2>/dev/null || true)
# AWS CLI outputs "None" (string) when a JMESPath query returns null
[ "$EXISTING_CF_ID" = "None" ] && EXISTING_CF_ID=""

if [ -n "$EXISTING_CF_ID" ]; then
  CF_ID="$EXISTING_CF_ID"
  echo "    Distribution already exists: $CF_ID"
  CF_DOMAIN=$(aws cloudfront get-distribution \
    --id "$CF_ID" \
    --query 'Distribution.DomainName' \
    --output text)
else
  # Create Origin Access Control (replaces legacy OAI; no public bucket policy needed)
  OAC_NAME="expenses-web-oac-${ACCOUNT_ID}"
  EXISTING_OAC_ID=$(aws cloudfront list-origin-access-controls \
    --query "OriginAccessControlList.Items[?Name=='${OAC_NAME}'].Id" \
    --output text 2>/dev/null || true)
  [ "$EXISTING_OAC_ID" = "None" ] && EXISTING_OAC_ID=""

  if [ -n "$EXISTING_OAC_ID" ]; then
    OAC_ID="$EXISTING_OAC_ID"
    echo "    OAC already exists: $OAC_ID"
  else
    OAC_ID=$(aws cloudfront create-origin-access-control \
      --origin-access-control-config \
        "{\"Name\":\"${OAC_NAME}\",\"Description\":\"OAC for ExpensePro web app\",\"SigningProtocol\":\"sigv4\",\"SigningBehavior\":\"always\",\"OriginAccessControlOriginType\":\"s3\"}" \
      --query 'OriginAccessControl.Id' \
      --output text)
    echo "    OAC created: $OAC_ID"
  fi

  CF_CONFIG=$(python3 -c "
import json, uuid
print(json.dumps({
  'CallerReference': str(uuid.uuid4()),
  'Comment': 'ExpensePro web demo',
  'DefaultRootObject': 'index.html',
  'DefaultCacheBehavior': {
    'TargetOriginId': 'S3-OAC',
    'ViewerProtocolPolicy': 'redirect-to-https',
    'AllowedMethods': {
      'Quantity': 2, 'Items': ['GET', 'HEAD'],
      'CachedMethods': {'Quantity': 2, 'Items': ['GET', 'HEAD']},
    },
    'ForwardedValues': {'QueryString': False, 'Cookies': {'Forward': 'none'}},
    'MinTTL': 0, 'DefaultTTL': 86400, 'MaxTTL': 31536000,
    'Compress': True,
  },
  'Origins': {
    'Quantity': 1,
    'Items': [{
      'Id': 'S3-OAC',
      'DomainName': '${S3_ORIGIN_DOMAIN}',
      'S3OriginConfig': {'OriginAccessIdentity': ''},
      'OriginAccessControlId': '${OAC_ID}',
    }]
  },
  'CustomErrorResponses': {
    'Quantity': 2,
    'Items': [
      {'ErrorCode': 403, 'ResponseCode': '200', 'ResponsePagePath': '/index.html', 'ErrorCachingMinTTL': 0},
      {'ErrorCode': 404, 'ResponseCode': '200', 'ResponsePagePath': '/index.html', 'ErrorCachingMinTTL': 0},
    ]
  },
  'Enabled': True,
  'PriceClass': 'PriceClass_100',
  'HttpVersion': 'http2',
  'IsIPV6Enabled': True,
}))
")
  CF_RESULT=$(aws cloudfront create-distribution \
    --distribution-config "$CF_CONFIG" \
    --query '[Distribution.Id, Distribution.DomainName]' \
    --output text)
  CF_ID=$(echo "$CF_RESULT" | awk '{print $1}')
  CF_DOMAIN=$(echo "$CF_RESULT" | awk '{print $2}')
  echo "    Created distribution: $CF_ID"
fi

echo "    CloudFront domain: $CF_DOMAIN"
REDIRECT_URI="https://${CF_DOMAIN}/"

# Bucket policy: allow only this CloudFront distribution via OAC (not a public policy)
BUCKET_POLICY=$(python3 -c "
import json
print(json.dumps({
  'Version': '2012-10-17',
  'Statement': [{
    'Sid': 'AllowCloudFrontOAC',
    'Effect': 'Allow',
    'Principal': {'Service': 'cloudfront.amazonaws.com'},
    'Action': 's3:GetObject',
    'Resource': 'arn:aws:s3:::${BUCKET_NAME}/*',
    'Condition': {'StringEquals': {'aws:SourceArn': 'arn:aws:cloudfront::${ACCOUNT_ID}:distribution/${CF_ID}'}}
  }]
}))
")
aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy "$BUCKET_POLICY"
echo "    Bucket policy applied (CloudFront OAC only — bucket stays private)."

# ─────────────────────────────────────────────
# 4. Generate config.js and upload assets
# ─────────────────────────────────────────────
echo ""
echo ">>> [4/6] Generating config.js"
CONFIG_JS="$SCRIPT_DIR/config.js"
OKTA_WEBAPP_CLIENT_ID="${OKTA_WEBAPP_CLIENT_ID:-__OKTA_WEBAPP_CLIENT_ID__}"

sed \
  -e "s|__OKTA_ISSUER__|${OKTA_ISSUER}|g" \
  -e "s|__OKTA_CLIENT_ID__|${OKTA_CLIENT_ID}|g" \
  -e "s|__REDIRECT_URI__|${REDIRECT_URI}|g" \
  -e "s|__EXPENSES_API_URL__|${EXPENSES_API_URL}|g" \
  -e "s|__OKTA_ORG_URL__|${OKTA_ORG_URL}|g" \
  -e "s|__CHAT_API_URL__|${CHAT_API_URL}|g" \
  -e "s|__ORG_TOKEN_URL__|${ORG_TOKEN_URL}|g" \
  -e "s|__OKTA_WEBAPP_CLIENT_ID__|${OKTA_WEBAPP_CLIENT_ID}|g" \
  "$SCRIPT_DIR/config.js.template" > "$CONFIG_JS"
echo "    config.js written."

# ─────────────────────────────────────────────
# 5. Upload to S3
# ─────────────────────────────────────────────
echo ""
echo ">>> [5/6] Uploading to S3"
aws s3 cp "$SCRIPT_DIR/index.html" "s3://${BUCKET_NAME}/index.html" \
  --content-type "text/html" \
  --cache-control "no-cache, no-store, must-revalidate"
aws s3 cp "$CONFIG_JS" "s3://${BUCKET_NAME}/config.js" \
  --content-type "application/javascript" \
  --cache-control "no-cache, no-store, must-revalidate"
echo "    Uploaded index.html and config.js."

# Remove generated config (has secrets, don't leave it on disk by accident)
rm -f "$CONFIG_JS"

# ─────────────────────────────────────────────
# 6. Invalidate CloudFront cache
# ─────────────────────────────────────────────
echo ""
echo ">>> [6/6] Invalidating CloudFront cache"
INVALIDATION_ID=$(aws cloudfront create-invalidation \
  --distribution-id "$CF_ID" \
  --paths "/*" \
  --query 'Invalidation.Id' \
  --output text)
echo "    Invalidation: $INVALIDATION_ID (propagates in ~1–2 min)"

# ─────────────────────────────────────────────
# Save state
# ─────────────────────────────────────────────
cat > "$SCRIPT_DIR/.deploy-web-state" <<EOF
CF_ID=$CF_ID
CF_DOMAIN=$CF_DOMAIN
BUCKET_NAME=$BUCKET_NAME
REGION=$REGION
ACCOUNT_ID=$ACCOUNT_ID
EOF

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo " ✓  ExpensePro Web App deployed!"
echo "════════════════════════════════════════════"
echo ""
echo "  App URL    : https://${CF_DOMAIN}/"
echo "  S3 Bucket  : $BUCKET_NAME"
echo "  Okta issuer: $OKTA_ISSUER"
echo "  API URL    : $EXPENSES_API_URL"
echo ""

if [ "$OKTA_CLIENT_ID" = "__REPLACE_WITH_OKTA_CLIENT_ID__" ]; then
  echo "  ⚠️  IMPORTANT: OKTA_CLIENT_ID was not provided."
  echo "  The app is live but Okta login will not work until configured."
  echo ""
fi

echo "  ── Okta SPA Application Setup ────────────────────────────────"
echo ""
echo "  If you haven't already, create an Okta SPA application:"
echo ""
echo "    1. Okta Admin Console → Applications → Create App Integration"
echo "    2. Sign-in method: OIDC - OpenID Connect"
echo "    3. Application type: Single-Page Application"
echo "    4. App name: ExpensePro Web"
echo "    5. Grant types: ✓ Authorization Code  (PKCE enabled by default)"
echo "    6. Sign-in redirect URI:   https://${CF_DOMAIN}/"
echo "    7. Sign-out redirect URI:  https://${CF_DOMAIN}/"
echo "    8. Assignments: Assign yourself and any other demo users"
echo "    9. Note the Client ID"
echo ""
echo "  Then grant the API scopes:"
echo "    - Okta Admin → Security → API → ${OKTA_ISSUER##*/}"
echo "      (or your custom auth server)"
echo "    - Scopes tab → verify 'expenses:read' and 'expenses:write' exist"
echo "    - Your app must have these scopes in its allowed scopes list"
echo ""
echo "  Then re-run with the Client ID:"
echo "    export OKTA_ISSUER=\"$OKTA_ISSUER\""
echo "    export OKTA_CLIENT_ID=\"<your-client-id>\""
echo "    export EXPENSES_API_URL=\"$EXPENSES_API_URL\""
echo "    ./deploy_web_aws.sh"
echo ""
echo "  ── Tear down ─────────────────────────────────────────────────"
echo "    ./teardown_web_aws.sh"
echo ""
