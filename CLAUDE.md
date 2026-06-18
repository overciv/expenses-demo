# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A demo Expenses system with three components:

1. **REST API** — AWS Lambda (Python 3.12) behind API Gateway HTTP API, protected by Okta JWT authorization. Stores expenses in DynamoDB.
2. **MCP Server** — FastMCP 3.x wrapper around the REST API, deployed as a Docker container on AWS App Runner. Exposes two MCP tools (`list_expenses`, `create_expense`) to AI clients via streamable-HTTP transport.
3. **Web App** — Single-page app (vanilla HTML/JS + Tailwind CDN + Okta Auth JS) hosted on S3 + CloudFront. Lets end-users log in via Okta PKCE and manage expenses in a browser.

Both API layers enforce the same Okta JWT. Each expense carries a `source` field (`"web"`, `"ai-agent"`, `"demo"`, `"api"`) written at creation time and displayed as a badge in the web UI.

## Deployment

All infrastructure is managed by shell scripts — there is no Terraform or CDK.

```bash
# Deploy REST API (Lambda + API Gateway + DynamoDB)
export OKTA_ISSUER="https://<org>.okta.com/oauth2/<auth-server-id>"
export OKTA_AUDIENCE="api://expenses"   # optional, default shown
./demo-expenses-api/deploy.sh

# Deploy MCP Server (ECR + App Runner)  — requires REST API already deployed
export EXPENSES_API_URL="https://<api-id>.execute-api.<region>.amazonaws.com/demo"
./demo-expenses-api/deploy_mcp_aws.sh

# Tear down REST API
./demo-expenses-api/teardown.sh

# Tear down MCP Server (App Runner, ECR, IAM role)
./demo-expenses-api/teardown_mcp_aws.sh
```

```bash
# Deploy Web App (S3 + CloudFront) — requires REST API already deployed
export OKTA_ISSUER="https://<org>.okta.com/oauth2/<auth-server-id>"
export OKTA_CLIENT_ID="<spa-client-id>"    # Okta SPA application
# EXPENSES_API_URL is auto-read from demo-expenses-api/.deploy-state if not set
./demo-expenses-web/deploy_web_aws.sh

# Tear down Web App
./demo-expenses-web/teardown_web_aws.sh
```

Deploy scripts are idempotent: re-running updates existing resources rather than failing.

State files: `.deploy-state` (REST API), `.deploy-mcp-state` (MCP server), `.deploy-web-state` (web app).

### Okta SPA application setup (for the web app)

1. Okta Admin → Applications → **Create App Integration** → OIDC, Single-Page Application
2. Grant types: Authorization Code (PKCE enabled by default)
3. Sign-in redirect URI: `https://<cloudfront-domain>/`
4. Sign-out redirect URI: `https://<cloudfront-domain>/`
5. Assign users; note the Client ID → set as `OKTA_CLIENT_ID`
6. Ensure `expenses:read` and `expenses:write` scopes exist on the custom auth server

Run `deploy_web_aws.sh` once without `OKTA_CLIENT_ID` to get the CloudFront URL, then configure Okta and re-run.

## Run MCP server locally

```bash
cd demo-expenses-api/mcp_server
pip install -r requirements.txt   # or activate .venv

OKTA_ISSUER="https://<org>.okta.com/oauth2/<auth-server-id>" \
EXPENSES_API_URL="https://<api-id>.execute-api.<region>.amazonaws.com/demo" \
python server.py
# Listens at http://localhost:8001/mcp
```

## Architecture details

### Request flow

```
MCP client  →  MCP Server (FastMCP / App Runner)
                 1. OktaTokenVerifier validates JWT against Okta JWKS
                 2. Forwards Bearer token in Authorization header
             →  API Gateway (JWT Authorizer: okta-jwt)
                 3. Validates JWT again, enforces route scope
             →  Lambda (handler.py)
                 4. Reads JWT claims from event.requestContext.authorizer.jwt.claims
```

### Key design decisions

- **Decimal handling**: DynamoDB requires `decimal.Decimal` for numeric fields. `handler.py` stores amounts as `Decimal(str(float))` to avoid floating-point precision issues, and uses `_DecimalEncoder` for JSON serialization back to `float`.
- **Demo records**: Four static expenses (hardcoded, `source: "demo"`) are merged with DynamoDB records at read time. They are never written to DynamoDB.
- **Source field**: Written at creation time by the caller (`"web"` from the SPA, `"ai-agent"` hardcoded in `mcp_server/server.py`, `"demo"` on static records). Stored in DynamoDB and displayed as a badge in the web UI.
- **CORS**: Enabled at the API Gateway level (`update-api --cors-configuration`) and duplicated in Lambda response headers as belt-and-suspenders. OPTIONS preflight is handled by API Gateway natively, bypassing the JWT authorizer.
- **Scope passthrough**: The MCP server does not re-check scopes — it relies on API Gateway (403). The `_check()` helper in `server.py` surfaces actionable error messages when this happens.
- **MCP_BASE_URL two-phase deploy**: App Runner only assigns a hostname after first create, so `deploy_mcp_aws.sh` does a second `update-service` to patch `MCP_BASE_URL`. Required for RFC 9728 protected-resource metadata.
- **Web app config**: `config.js` is generated at deploy time from `config.js.template` with env var substitution and uploaded to S3. It is never committed (contains Okta client ID). Loaded before the app script via a `<script src="./config.js">` tag.

### File map

```
demo-expenses-api/
  lambda/handler.py          # Lambda function — all business logic
  mcp_server/server.py       # FastMCP server with OktaTokenVerifier
  deploy.sh                  # Deploys REST API + configures CORS
  teardown.sh
  deploy_mcp_aws.sh          # Builds image, deploys to App Runner
  teardown_mcp_aws.sh

demo-expenses-web/
  index.html                 # Single-file SPA (Okta Auth JS + Tailwind CDN)
  config.js.template         # Template — deploy script generates config.js from this
  deploy_web_aws.sh          # Creates S3 bucket + CloudFront, uploads app
  teardown_web_aws.sh
```

## Register MCP server in okta-mcp-adapter

```bash
TOKEN=$(curl -s -X POST http://localhost:8000/api/admin/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' | jq -r .access_token)

curl -s -X POST http://localhost:8000/api/admin/resources \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "expenses",
    "url": "https://<random>.us-east-1.awsapprunner.com/mcp",
    "auth_method": "bearer-passthrough",
    "paths": ["/expenses"]
  }' | jq
```

Tools appear as `expenses__list_expenses` and `expenses__create_expense`.
