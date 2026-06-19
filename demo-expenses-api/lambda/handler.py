import decimal
import json
import os
import uuid
from datetime import datetime, timezone

import boto3

TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "expenses-demo")
_dynamodb = boto3.resource("dynamodb")
_table = _dynamodb.Table(TABLE_NAME)

DEMO_EXPENSES = [
    {
        "id": "exp-001",
        "description": "Cloud infrastructure - AWS",
        "amount": 1250.00,
        "currency": "USD",
        "category": "Infrastructure",
        "submitted_by": "alice@acme.com",
        "date": "2026-04-01",
        "status": "approved",
        "source": "demo",
    },
    {
        "id": "exp-002",
        "description": "SaaS tools subscription (Figma, Notion, Slack)",
        "amount": 349.00,
        "currency": "USD",
        "category": "Software",
        "submitted_by": "bob@acme.com",
        "date": "2026-04-10",
        "status": "pending",
        "source": "demo",
    },
    {
        "id": "exp-003",
        "description": "Team offsite - travel and accommodation",
        "amount": 4200.00,
        "currency": "USD",
        "category": "Travel",
        "submitted_by": "carol@acme.com",
        "date": "2026-04-15",
        "status": "approved",
        "source": "demo",
    },
    {
        "id": "exp-004",
        "description": "Security conference tickets",
        "amount": 1800.00,
        "currency": "USD",
        "category": "Training",
        "submitted_by": "dave@acme.com",
        "date": "2026-04-22",
        "status": "pending",
        "source": "demo",
    },
]


def lambda_handler(event, context):
    # EventBridge scheduled warm-up ping — return immediately to keep the
    # Lambda execution environment alive without touching DynamoDB.
    if event.get("source") == "aws.events":
        return {"statusCode": 200, "body": "warm"}

    route_key = event.get("routeKey", "")
    # CORS preflight — API Gateway native CORS handles OPTIONS, but this covers
    # edge cases where the request reaches Lambda anyway.
    if event.get("requestContext", {}).get("http", {}).get("method") == "OPTIONS":
        return _response(200, {})
    if route_key == "GET /expenses":
        return list_expenses(event)
    elif route_key == "POST /expenses":
        return create_expense(event)
    elif route_key == "DELETE /expenses/{expenseId}":
        return delete_expense(event)
    else:
        return _response(404, {"error": "Not found", "routeKey": route_key})


def list_expenses(event):
    claims = _jwt_claims(event)

    # Scan all user-created expenses from DynamoDB
    result = _table.scan()
    created = result.get("Items", [])
    while "LastEvaluatedKey" in result:
        result = _table.scan(ExclusiveStartKey=result["LastEvaluatedKey"])
        created.extend(result.get("Items", []))

    all_expenses = DEMO_EXPENSES + created
    return _response(
        200,
        {
            "expenses": all_expenses,
            "count": len(all_expenses),
            "requested_by": claims.get("sub", "unknown"),
            "scopes_granted": claims.get("scp", claims.get("scope", "")),
        },
    )


def create_expense(event):
    claims = _jwt_claims(event)

    body = {}
    if event.get("body"):
        try:
            body = json.loads(event["body"])
        except (json.JSONDecodeError, ValueError):
            return _response(400, {"error": "Invalid JSON body"})

    missing = [f for f in ("description", "amount", "category") if f not in body]
    if missing:
        return _response(400, {"error": f"Missing required fields: {', '.join(missing)}"})

    try:
        amount = float(body["amount"])
    except (TypeError, ValueError):
        return _response(400, {"error": "amount must be a number"})

    expense = {
        "id": f"exp-{str(uuid.uuid4())[:8]}",
        "description": str(body["description"]),
        # DynamoDB requires Decimal for numeric types — str(float) avoids fp precision issues
        "amount": decimal.Decimal(str(amount)),
        "currency": body.get("currency", "USD"),
        "category": str(body["category"]),
        "submitted_by": claims.get("sub", "unknown"),
        "date": body.get("date", datetime.now(timezone.utc).strftime("%Y-%m-%d")),
        "status": "pending",
        "source": str(body.get("source", "api")),
        "creator_client_id": str(claims.get("cid", claims.get("client_id", ""))),
    }

    _table.put_item(Item=expense)

    # Return amount as float for the JSON response
    return _response(201, {**expense, "amount": float(expense["amount"])})


def delete_expense(event):
    claims    = _jwt_claims(event)
    expense_id = (event.get("pathParameters") or {}).get("expenseId", "").strip()

    if not expense_id:
        return _response(400, {"error": "expenseId path parameter is required"})

    demo_ids = {e["id"] for e in DEMO_EXPENSES}
    if expense_id in demo_ids:
        return _response(403, {"error": f"Demo expense '{expense_id}' cannot be deleted"})

    result = _table.delete_item(
        Key={"id": expense_id},
        ReturnValues="ALL_OLD",
    )

    if "Attributes" not in result:
        return _response(404, {"error": f"Expense '{expense_id}' not found"})

    return _response(200, {
        "message": f"Expense '{expense_id}' deleted successfully",
        "deleted_by": claims.get("sub", "unknown"),
        "deleted_id": expense_id,
    })


def _jwt_claims(event) -> dict:
    return (
        event.get("requestContext", {})
        .get("authorizer", {})
        .get("jwt", {})
        .get("claims", {})
    )


class _DecimalEncoder(json.JSONEncoder):
    """Convert DynamoDB Decimal values to float for JSON serialization."""
    def default(self, obj):
        if isinstance(obj, decimal.Decimal):
            return float(obj)
        return super().default(obj)


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Authorization,Content-Type",
            "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
        },
        "body": json.dumps(body, cls=_DecimalEncoder),
    }
