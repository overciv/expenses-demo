"""
Lambda handler for the ExpensePro AI chat endpoint.

Responsibilities (thin handler):
  1. Handle CORS preflight
  2. Parse and validate the incoming request
  3. Basic validation of the org-issued ID token (issuer + expiry, no sig verify)
  4. Build the Strands agent and invoke it with the user message
  5. Return the agent's response
"""

import json
import logging
import os
import time

import jwt  # PyJWT — decode-only, no signature verification

from agent import invoke_agent
from org_token import exchange_code_for_org_id_token

logger = logging.getLogger()
logger.setLevel(logging.INFO)

OKTA_ORG_URL = os.environ["OKTA_ORG_URL"]

CORS_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
}


def lambda_handler(event, context):
    # CORS preflight
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    route  = event.get("requestContext", {}).get("http", {}).get("path", "")
    if method == "OPTIONS":
        return {"statusCode": 200, "headers": CORS_HEADERS, "body": ""}

    # Org token exchange endpoint — no debug log needed for this lightweight call
    if route.endswith("/org-token") and method == "POST":
        return _handle_org_token(event)

    # Per-request debug log — returned to browser for the live console
    debug: list[dict] = []

    def dbg(source: str, level: str, msg: str, data=None):
        logger.info("[%s] %s", source, msg)
        entry = {"source": source, "level": level, "msg": msg}
        if data is not None:
            entry["data"] = data
        debug.append(entry)

    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, ValueError):
        return _resp(400, {"error": "Invalid JSON body"})

    message      = (body.get("message") or "").strip()
    org_id_token = (body.get("orgIdToken") or "").strip()

    if not message:
        return _resp(400, {"error": "message is required"})
    if not org_id_token:
        return _resp(400, {"error": "orgIdToken is required"})

    # Validate the org ID token (iss + exp only — Okta verifies the signature during exchange)
    try:
        claims = jwt.decode(org_id_token, options={"verify_signature": False})
        iss = claims.get("iss", "")
        exp = int(claims.get("exp", 0))
        safe_claims = {k: claims[k] for k in ("iss", "sub", "aud", "exp", "iat") if k in claims}
        dbg("Lambda", "tok", f"Org ID token received — iss: {iss}, sub: {claims.get('sub','?')}", safe_claims)
        if not iss.startswith(OKTA_ORG_URL):
            dbg("Lambda", "err", f"Issuer mismatch: got {iss}, expected prefix {OKTA_ORG_URL}")
            return _resp(401, {"error": f"ID token issuer mismatch: {iss}", "debug": debug})
        if exp < int(time.time()):
            dbg("Lambda", "err", "ID token has expired")
            return _resp(401, {"error": "ID token has expired", "debug": debug})
        dbg("Lambda", "ok", "Org ID token validated ✓")
    except Exception as exc:
        return _resp(400, {"error": f"Invalid ID token: {exc}", "debug": debug})

    try:
        dbg("Lambda", "req", f"Invoking agent via MCP → \"{message[:80]}{'...' if len(message)>80 else ''}\"")
        resp_text = invoke_agent(org_id_token, message, dbg)
        dbg("Lambda", "ok", f"Agent response received ({len(resp_text)} chars)")
        return _resp(200, {"response": resp_text, "debug": debug})
    except PermissionError as exc:
        dbg("Lambda", "err", str(exc))
        return _resp(403, {"error": str(exc), "debug": debug})
    except Exception as exc:
        logger.exception("Agent invocation failed")
        dbg("Lambda", "err", f"Agent error: {exc}")
        return _resp(500, {"error": f"Agent error: {exc}", "debug": debug})


def _handle_org_token(event: dict) -> dict:
    try:
        body = json.loads(event.get("body") or "{}")
    except (json.JSONDecodeError, ValueError):
        return _resp(400, {"error": "Invalid JSON body"})

    code          = (body.get("code") or "").strip()
    code_verifier = (body.get("code_verifier") or "").strip()
    redirect_uri  = (body.get("redirect_uri") or "").strip()

    if not all([code, code_verifier, redirect_uri]):
        return _resp(400, {"error": "code, code_verifier and redirect_uri are required"})

    try:
        id_token = exchange_code_for_org_id_token(code, code_verifier, redirect_uri)
        return _resp(200, {"id_token": id_token})
    except Exception as exc:
        logger.exception("Org token exchange failed")
        return _resp(500, {"error": str(exc)})


def _resp(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": CORS_HEADERS,
        "body": json.dumps(body),
    }
