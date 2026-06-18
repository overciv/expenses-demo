# Demo Expenses API

AWS Lambda + API Gateway HTTP API protected by Okta OAuth 2.1 access tokens.

## Endpoints

| Method | Path | Required scope |
|--------|------|---------------|
| `GET`  | `/expenses` | `expenses:read` |
| `POST` | `/expenses` | `expenses:write` |

## Prerequisites

- AWS CLI v2 configured (`aws configure`)
- An Okta authorization server with `expenses:read` and `expenses:write` scopes defined

## Deploy

```bash
# Required — your Okta authorization server issuer URL
export OKTA_ISSUER="https://<org>.okta.com/oauth2/<auth-server-id>"

# Optional — audience claim in tokens (default: api://expenses)
export OKTA_AUDIENCE="api://expenses"   # replace if your auth server uses a different value

chmod +x deploy.sh teardown.sh
./deploy.sh
```

### Finding your Okta issuer and audience

1. Okta Admin Console → **Security → API → Authorization Servers**
2. Click the authorization server for this API
3. **Settings** tab:
   - **Issuer** → use as `OKTA_ISSUER`
   - **Audience** → use as `OKTA_AUDIENCE`

## Test

```bash
# Get a token from Okta (client credentials or auth code flow)
TOKEN="eyJ..."

API_URL="https://<api-id>.execute-api.<region>.amazonaws.com/demo"

# List expenses — needs expenses:read
curl -s -H "Authorization: Bearer $TOKEN" $API_URL/expenses | jq

# Create expense — needs expenses:write
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"description":"Team lunch","amount":87.50,"category":"Meals"}' \
  $API_URL/expenses | jq
```

## What gets deployed

```
IAM Role          expenses-api-lambda-role
                  ├── AWSLambdaBasicExecutionRole
                  └── expenses-dynamodb-access (inline)
                      └── dynamodb:PutItem, dynamodb:Scan on expenses-demo

DynamoDB          expenses-demo  (on-demand / pay-per-request)
                  └── Partition key: id (String)

Lambda            expenses-api  (Python 3.12)
                  └── Env: DYNAMODB_TABLE=expenses-demo

API Gateway       expenses-api  (HTTP API)
  JWT Authorizer  okta-jwt
                  ├── Issuer   : $OKTA_ISSUER
                  └── Audience : $OKTA_AUDIENCE
  Routes
  ├── GET  /expenses  → Lambda  [scope: expenses:read]
  └── POST /expenses  → Lambda  [scope: expenses:write]
  Stage             demo (auto-deploy on)
```

### Persistence

`GET /expenses` returns four built-in demo records plus any expenses created
via `POST /expenses`. Created expenses are stored in DynamoDB and survive
Lambda cold starts and redeployments.

DynamoDB is billed on-demand (pay-per-request). For a demo this stays well
within the AWS free tier (25 GB / 200 M requests per month).

## How JWT authorization works

API Gateway validates every request before it reaches Lambda:

1. Extracts the Bearer token from the `Authorization` header
2. Fetches Okta's JWKS from `$OKTA_ISSUER/v1/keys` and verifies the signature
3. Checks `iss` matches the configured issuer and `aud` contains the configured audience
4. Checks the `scp` claim contains the required scope for the route (`expenses:read` or `expenses:write`)
5. Returns **401** if the token is missing or invalid; **403** if the scope check fails

Lambda receives the validated JWT claims in `event.requestContext.authorizer.jwt.claims`.

## MCP Server (FastMCP wrapper)

`mcp_server/server.py` wraps the REST API as a proper MCP server so it can be
registered as a resource in the okta-mcp-adapter.

### Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `OKTA_ISSUER` | **Yes** | Okta authorization server issuer URL — e.g. `https://<org>.okta.com/oauth2/<auth-server-id>` |
| `EXPENSES_API_URL` | **Yes** | Base URL of the AWS API Gateway — e.g. `https://<api-id>.execute-api.<region>.amazonaws.com/demo` |
| `OKTA_AUDIENCE` | No | Audience claim expected in tokens (default: `api://expenses`) |
| `MCP_BASE_URL` | No | Public HTTPS URL of this server, used in OAuth metadata |
| `MCP_PORT` | No | Bind port (default: `8001`) |
| `MCP_HOST` | No | Bind host (default: `0.0.0.0`) |
| `MCP_TRANSPORT` | No | `streamable-http` \| `sse` \| `stdio` (default: `streamable-http`) |

### Run locally

```bash
cd mcp_server

OKTA_ISSUER="https://<org>.okta.com/oauth2/<auth-server-id>" \
EXPENSES_API_URL="https://<api-id>.execute-api.<region>.amazonaws.com/demo" \
python server.py
```

Server listens at `http://localhost:8001/mcp` (streamable-http transport).

### Deploy to AWS (App Runner)

`deploy_mcp_aws.sh` containerises the MCP server and deploys it to
**AWS App Runner** so it is reachable over a public HTTPS URL without
managing any servers.

#### Prerequisites

- Docker (to build the container image)
- AWS CLI v2 authenticated with sufficient permissions (ECR, App Runner, IAM)
- The REST API already deployed (`./deploy.sh` done first)

#### What the script creates in AWS

```
ECR repository       expenses-mcp-server
                     └── Docker image built from mcp_server/

IAM role             expenses-mcp-apprunner-ecr-role
                     └── AWSAppRunnerServicePolicyForECRAccess
                         (lets App Runner pull from the ECR repo)

App Runner service   expenses-mcp-server
                     ├── Source  : ECR image above
                     ├── Port    : 8001
                     ├── Size    : 0.25 vCPU / 0.5 GB RAM
                     └── Env vars: OKTA_ISSUER, OKTA_AUDIENCE,
                                   EXPENSES_API_URL, MCP_TRANSPORT
```

App Runner handles TLS termination and auto-scales to zero when idle —
no load balancer or VPC configuration required.

#### Run

```bash
export OKTA_ISSUER="https://<org>.okta.com/oauth2/<auth-server-id>"
export EXPENSES_API_URL="https://<api-id>.execute-api.<region>.amazonaws.com/demo"

# Optional overrides
export OKTA_AUDIENCE="api://expenses"   # default
export AWS_DEFAULT_REGION="us-east-1"  # default

chmod +x deploy_mcp_aws.sh
./deploy_mcp_aws.sh
```

The script prints the public MCP URL on completion:

```
MCP URL : https://<random>.us-east-1.awsapprunner.com/mcp
```

Deployment state is saved to `.deploy-mcp-state` for use by the teardown script.

#### Tear down App Runner deployment

```bash
./teardown_mcp_aws.sh
```

This removes the App Runner service, ECR repository, and IAM role created above.

### MCP tools exposed

| Tool | Description | Scope needed |
|------|-------------|-------------|
| `list_expenses` | List all expense records | `expenses:read` |
| `create_expense` | Create a new expense | `expenses:write` |

### Register in okta-mcp-adapter

Add as a resource via the Admin API (use the App Runner URL if deployed to AWS,
or `http://localhost:8001/mcp` for local):

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

Claude Code will then see `expenses__list_expenses` and `expenses__create_expense`
as tools on the unified MCP endpoint.

## Tear down

```bash
./teardown.sh
```
