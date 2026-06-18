#!/usr/bin/env bash
# teardown_web_aws.sh — remove the ExpensePro web app from AWS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$SCRIPT_DIR/.deploy-web-state"

if [ ! -f "$STATE_FILE" ]; then
  echo "No .deploy-web-state file found. Run deploy_web_aws.sh first."
  exit 1
fi

# shellcheck disable=SC1090
source "$STATE_FILE"

echo "=== ExpensePro Web App — Teardown ==="
echo "Bucket     : $BUCKET_NAME"
echo "CloudFront : $CF_ID ($CF_DOMAIN)"
echo "WAF ACL    : ${WAF_ACL_ID:-none}"
echo "Region     : $REGION"
echo ""
read -rp "Delete all resources? [y/N] " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── WAF Web ACL + IP set ───────────────────────────────────────────
if [ -n "${WAF_ACL_ARN:-}" ]; then
  echo ""
  echo ">>> Detaching WAF Web ACL from CloudFront"
  # Detach by removing WebACLId from distribution config
  CF_ETAG=$(aws cloudfront get-distribution-config --id "$CF_ID" --query 'ETag' --output text)
  CF_CONFIG=$(aws cloudfront get-distribution-config --id "$CF_ID" --query 'DistributionConfig' --output json)
  DETACHED_CONFIG=$(echo "$CF_CONFIG" | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
cfg['WebACLId'] = ''
print(json.dumps(cfg))
")
  aws cloudfront update-distribution \
    --id "$CF_ID" --if-match "$CF_ETAG" \
    --distribution-config "$DETACHED_CONFIG" \
    --output text > /dev/null
  echo "    Detached."

  echo ">>> Deleting WAF Web ACL: $WAF_ACL_ID"
  ACL_LOCK=$(aws wafv2 get-web-acl \
    --id "$WAF_ACL_ID" --name "expenses-web-acl" --scope CLOUDFRONT \
    --region us-east-1 --query 'LockToken' --output text)
  aws wafv2 delete-web-acl \
    --id "$WAF_ACL_ID" --name "expenses-web-acl" --scope CLOUDFRONT \
    --lock-token "$ACL_LOCK" --region us-east-1
  echo "    Done."

  echo ">>> Deleting WAF IP set: $WAF_IP_SET_ID"
  IP_LOCK=$(aws wafv2 get-ip-set \
    --id "$WAF_IP_SET_ID" --name "expenses-web-allowed-ips" --scope CLOUDFRONT \
    --region us-east-1 --query 'LockToken' --output text)
  aws wafv2 delete-ip-set \
    --id "$WAF_IP_SET_ID" --name "expenses-web-allowed-ips" --scope CLOUDFRONT \
    --lock-token "$IP_LOCK" --region us-east-1
  echo "    Done."
fi

# ── Empty and delete S3 bucket ─────────────────────────────────────
echo ""
echo ">>> Emptying S3 bucket: $BUCKET_NAME"
aws s3 rm "s3://${BUCKET_NAME}" --recursive
echo ">>> Deleting S3 bucket: $BUCKET_NAME"
aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$REGION"
echo "    Done."

# ── Disable + delete CloudFront distribution ───────────────────────
echo ""
echo ">>> Disabling CloudFront distribution: $CF_ID"
ETAG=$(aws cloudfront get-distribution-config \
  --id "$CF_ID" \
  --query 'ETag' \
  --output text)

DIST_CONFIG=$(aws cloudfront get-distribution-config \
  --id "$CF_ID" \
  --query 'DistributionConfig' \
  --output json)

DISABLED_CONFIG=$(echo "$DIST_CONFIG" | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
cfg['Enabled'] = False
print(json.dumps(cfg))
")

NEW_ETAG=$(aws cloudfront update-distribution \
  --id "$CF_ID" \
  --if-match "$ETAG" \
  --distribution-config "$DISABLED_CONFIG" \
  --query 'ETag' \
  --output text)

echo "    Waiting for distribution to reach Deployed state (~2 min)…"
aws cloudfront wait distribution-deployed --id "$CF_ID"

echo ">>> Deleting CloudFront distribution: $CF_ID"
aws cloudfront delete-distribution --id "$CF_ID" --if-match "$NEW_ETAG"
echo "    Done."

rm -f "$STATE_FILE"

echo ""
echo "✓ All web app resources removed."
