# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Branches

| Branch | Architecture |
|---|---|
| `main` | **AgentCore** — Strands agent on AgentCore Runtime, Okta XAA via Gateway Lambda interceptor |
| `v1-lambda-strands` | **Legacy** — Strands agent on AWS Lambda, XAA inline in the Chat Lambda |

## What this project is

A demo Expenses system with four components:

1. **REST API** — AWS Lambda (Python 3.12) behind API Gateway HTTP API, protected by Okta JWT authorization. Stores expenses in DynamoDB.
2. **MCP Server** — FastMCP 3.x wrapper around the REST API, deployed as a Docker container on AWS App Runner. Exposes three MCP tools (`list_expenses`, `create_expense`, `delete_expense`) via streamable-HTTP.
3. **Web App** — Single-page app (vanilla HTML/JS + Tailwind CDN + Okta Auth JS) hosted on S3 + CloudFront. Lets end-users log in via Okta PKCE and manage expenses in a browser.
4. **AI Agent** — Strands agent on **AgentCore Runtime** (container). Connects to MCP tools via **AgentCore Gateway**. A Lambda interceptor in the Gateway performs the Okta Cross-App Access (XAA) token exchange so the agent code contains no auth logic.

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

```bash
# Deploy AI Agent (AgentCore Runtime + Gateway + Lambda interceptor + BFF)
# Requires REST API + MCP Server already deployed.
export OKTA_ORG_URL="https://<org>.oktapreview.com"
export OKTA_WEBAPP_CLIENT_ID="<web-app-client-id>"
export OKTA_WEBAPP_CLIENT_SECRET="<web-app-client-secret>"
export OKTA_AGENT_CLIENT_ID="<ai-agent-client-id>"
export OKTA_PRIVATE_KEY_PEM="$(cat path/to/agent-private-key.pem)"
./demo-expenses-agent/deploy_agentcore_aws.sh

# Tear down AI Agent
./demo-expenses-agent/teardown_agentcore_aws.sh
```

Deploy scripts are idempotent: re-running updates existing resources rather than failing.

State files: `.deploy-state` (REST API), `.deploy-mcp-state` (MCP server), `.deploy-web-state` (web app), `.deploy-agentcore-state` (AgentCore agent).

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

### Request flow — AI agent

```
Browser (SPA)
  │  1. PKCE auth code → POST /org-token (BFF Lambda) → org ID token
  │  2. POST AgentCore Runtime  { prompt, id_token }
  │     Authorization: Bearer <org-id-token>
  ▼
AgentCore Runtime  (Strands agent container)
  │  Validates org ID token via customJWTAuthorizer (Okta OIDC discovery)
  │  Agent calls tools via AgentCore Gateway MCPClient
  │  Sends:  Authorization: Bearer <org-id-token>  (Gateway validates & strips)
  │          X-ID-Token: <org-id-token>             (forwarded to interceptor)
  │          X-Agent-ID: expenses-agent             (secret lookup key)
  ▼
AgentCore Gateway  (MCP proxy)
  │  passRequestHeaders: true → fires Lambda interceptor on every tool call
  ▼
Lambda Interceptor  (expenses-xaa-interceptor)
  │  1. Reads X-ID-Token from request headers
  │  2. Loads agent credentials from Secrets Manager: agentcore/xaa/expenses-agent
  │  3. Okta XAA Stage 2: org ID token → ID-JAG  (org AS)
  │  4. Okta XAA Stage 3: ID-JAG → expenses access token  (custom AS)
  │  5. Returns transformedGatewayRequest: Authorization: Bearer <expenses-token>
  ▼
MCP Server (App Runner)  →  REST API (Lambda + DynamoDB)
```

### Request flow — web app

```
Browser → API Gateway (JWT Authorizer) → Lambda (handler.py) → DynamoDB
```

### Key design decisions

- **XAA interceptor, not inline**: Okta Cross-App Access exchange runs in the Gateway Lambda interceptor — agent code contains zero auth logic. Interceptor reads `X-ID-Token`, loads pkjwt credentials from Secrets Manager, runs XAA, injects `Authorization: Bearer <expenses-token>`.
- **Authorization header stripped by Gateway**: AgentCore Gateway validates the inbound `Authorization: Bearer` JWT then strips it before forwarding. The agent sends `X-ID-Token` as a separate custom header so the interceptor can read the original user token.
- **Secrets Manager per-agent credentials**: The interceptor loads `agentcore/xaa/<agent-id>` from Secrets Manager (cached per warm Lambda). Stored fields: `okta_org_url`, `okta_issuer`, `okta_agent_client_id`, `okta_private_key_pem`, `okta_private_key_id`, `scope`. No private keys in env vars.
- **BFF Lambda**: Browser cannot hold the Web App private key. `handler.py` serves `/org-token` only — exchanges PKCE auth code for org ID token via `client_secret_post`. The org ID token is then passed directly to AgentCore Runtime.
- **Scope fallback ladder**: Interceptor tries `[read, write, delete]` first, falls back to `[read, write]`, then `[read]` on `invalid_scope` errors.
- **Decimal handling**: DynamoDB requires `decimal.Decimal` for numeric fields. `handler.py` stores amounts as `Decimal(str(float))` and uses `_DecimalEncoder` for JSON serialization back to `float`.
- **Demo records**: Four static expenses (hardcoded, `source: "demo"`) are merged with DynamoDB records at read time. Never written to DynamoDB.
- **Source field**: Written at creation time by the caller (`"web"`, `"ai-agent"`, `"demo"`, `"api"`). Stored in DynamoDB and displayed as a badge in the web UI.
- **CORS**: Enabled at API Gateway level and duplicated in Lambda response headers. OPTIONS handled by API Gateway natively.
- **Web app config**: `config.js` generated at deploy time from `config.js.template`. Never committed (contains Okta client ID).

### File map

```
demo-expenses-api/
  lambda/handler.py               # Lambda function — all business logic
  mcp_server/server.py            # FastMCP server with OktaTokenVerifier
  deploy.sh                       # Deploys REST API + configures CORS
  teardown.sh
  deploy_mcp_aws.sh               # Builds image, deploys to App Runner
  teardown_mcp_aws.sh

demo-expenses-agent/
  agent.py                        # AgentCore Runtime entrypoint (BedrockAgentCoreApp)
  handler.py                      # BFF Lambda — /org-token only
  org_token.py                    # PKCE code → org ID token (client_secret_post)
  okta_xaa.py                     # XAA exchange logic (reference; used by interceptor)
  Dockerfile                      # AgentCore Runtime container
  requirements.txt                # Runtime container deps
  interceptor/
    lambda_function.py            # Gateway XAA interceptor Lambda
    requirements.txt              # okta-client-python, aiohttp
  deploy_agentcore_aws.sh         # Deploys Runtime + Gateway + Interceptor + BFF
  teardown_agentcore_aws.sh

demo-expenses-web/
  index.html                      # Single-file SPA (Okta Auth JS + Tailwind CDN)
  config.js.template              # Template — deploy script generates config.js from this
  deploy_web_aws.sh               # Creates S3 bucket + CloudFront, uploads app
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
