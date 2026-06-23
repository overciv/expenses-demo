"""
ExpensePro AI Agent — AgentCore Runtime entrypoint.

Runs as a container on AgentCore Runtime. The agent connects to the expenses
MCP tools via AgentCore Gateway, sending two custom headers on every request:

  X-ID-Token  — the user's org-issued ID token (forwarded to the Gateway interceptor)
  X-Agent-ID  — "expenses-agent" (used by the interceptor to look up XAA credentials
                 from Secrets Manager at agentcore/xaa/expenses-agent)

The AgentCore Gateway validates the inbound org ID token via its customJWTAuthorizer,
strips the Authorization header, and fires the XAA interceptor Lambda.
The interceptor exchanges the X-ID-Token for an expenses access token and injects
Authorization: Bearer <expenses_token> before forwarding to the MCP Server.

The response payload includes a `debug` array with structured events covering
the full call chain: Runtime → Gateway → Interceptor → Okta XAA → MCP Server.
These events are rendered in the browser Dev Console.
"""

import base64
import json
import logging
import os
import threading
import time
import uuid
from contextlib import asynccontextmanager

import httpx
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from mcp.client.streamable_http import streamable_http_client
from strands import Agent
from strands.models import BedrockModel
from strands.tools.mcp import MCPClient

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def _decode_jwt_claims(raw_jwt: str) -> dict:
    """Decode JWT payload without signature verification (claims only)."""
    try:
        payload = raw_jwt.split(".")[1]
        payload += "=" * (4 - len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}


# ── Module-level tool cache ───────────────────────────────────────────────────
# Populated after the first tools/list call; reused across subsequent prompts
# on the same warm container (saves one Gateway round-trip ≈ 1.2s per prompt).
# Each new invocation rebinds tool.mcp_client to the current MCPClient session.
_tool_cache: list | None = None
_tool_cache_lock = threading.Lock()

app = BedrockAgentCoreApp()

GATEWAY_MCP_URL = os.environ["GATEWAY_MCP_URL"]
MODEL_ID = os.environ.get("MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0")
AGENT_ID = os.environ.get("AGENT_ID", "expenses-agent")

SYSTEM_PROMPT = """You are an AI expense management assistant for ExpensePro.
You help authenticated users list, create, and delete company expense records on their behalf
using the Expenses MCP server.

Guidelines:
- Use list_expenses to retrieve the current expense list when asked.
- Use create_expense to create a new expense. Always confirm description, amount, and category
  before calling the tool — ask for missing fields if not provided.
- Use delete_expense only when the user explicitly asks to delete a specific expense by ID.
- Format currency amounts as USD by default unless the user specifies otherwise.
- Keep responses concise and professional.
- You are acting on behalf of the logged-in user via Okta Cross-App Access.
"""


class _AuthHeaderTransport(httpx.AsyncBaseTransport):
    """Injects Authorization, X-ID-Token, X-Agent-ID, and X-Prompt-Nonce on every request.

    X-Prompt-Nonce is a per-invocation UUID that scopes the interceptor's
    token cache to the current user prompt.  A new prompt → new nonce →
    cache miss → fresh XAA exchange.  Tool calls within the same prompt
    share the nonce and reuse the cached token.
    """

    def __init__(self, transport: httpx.AsyncBaseTransport, token: str,
                 agent_id: str, prompt_nonce: str):
        self._transport = transport
        self._headers = {
            "Authorization": f"Bearer {token}",
            "X-ID-Token": token,
            "X-Agent-ID": agent_id,
            "X-Prompt-Nonce": prompt_nonce,
        }

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        request.headers.update(self._headers)
        return await self._transport.handle_async_request(request)


@asynccontextmanager
async def _mcp_transport(mcp_url: str, token: str, agent_id: str, prompt_nonce: str):
    timeout = httpx.Timeout(30.0, read=300.0)
    base = httpx.AsyncHTTPTransport()
    wrapped = _AuthHeaderTransport(base, token, agent_id, prompt_nonce)
    async with httpx.AsyncClient(
        transport=wrapped, timeout=timeout, follow_redirects=True
    ) as client:
        async with streamable_http_client(mcp_url, http_client=client) as streams:
            yield streams


def _create_mcp_transport(mcp_url: str, token: str, agent_id: str, prompt_nonce: str):
    return _mcp_transport(mcp_url, token, agent_id, prompt_nonce)


def _xaa_chain(debug: list, step_label: str, t0: float,
               cached: bool = False, id_token_claims: dict | None = None) -> None:
    """Emit the known interceptor → Okta XAA sequence for a given MCP request step.

    cached=True  → token was served from the interceptor's in-memory cache.
    id_token_claims → decoded claims from the user's org ID token (for JWT expand).
    """
    def d(source, level, msg, data=None):
        entry: dict = {"source": source, "level": level, "msg": msg,
                        "ms": round((time.time() - t0) * 1000)}
        if data is not None:
            entry["data"] = data
        debug.append(entry)

    d("Interceptor", "req",
      f"XAA exchange fired ({step_label}) — reading X-ID-Token from request headers")

    if cached:
        d("Interceptor", "ok",
          "Token cache hit — skipping Okta round-trips (warm Lambda, token still valid)")
        d("Interceptor", "ok",
          "Authorization: Bearer <expenses-token> injected → forwarding to MCP Server")
    else:
        # Include the actual org ID token claims so the browser can expand them
        org_token_data: dict | None = None
        if id_token_claims:
            import datetime
            exp_ts = id_token_claims.get("exp")
            org_token_data = {
                "type": "jwt_claims", "token": "Org ID Token (subject token for XAA)",
                "iss":  id_token_claims.get("iss", "?"),
                "sub":  id_token_claims.get("sub", "?"),
                "aud":  id_token_claims.get("aud", "?"),
                "cid":  id_token_claims.get("cid") or id_token_claims.get("azp") or "—",
                "exp":  datetime.datetime.utcfromtimestamp(exp_ts).isoformat() + "Z" if exp_ts else "?",
            }

        d("Okta", "req",
          "Stage 2: org ID token → ID-JAG  (org AS, token-exchange grant, pkjwt client_assertion)",
          org_token_data)

        # ID-JAG claims — derived from known XAA protocol (interceptor holds the actual token)
        id_jag_data: dict | None = None
        if id_token_claims:
            id_jag_data = {
                "type":  "jwt_claims",
                "token": "ID-JAG  ⚠ derived — interceptor holds actual token",
                "iss":   id_token_claims.get("iss"),   # org AS issuer (same as org token)
                "sub":   id_token_claims.get("sub"),   # user ID preserved from org token
                "act":   {"sub": AGENT_ID},             # actual nested claim structure
                "exp":   "(~300s from exchange)",
            }

        d("Okta", "ok",
          "ID-JAG obtained (act.sub: AI Agent, iss: org AS, expires_in: 300s)",
          id_jag_data)

        d("Okta", "req",
          "Stage 3: ID-JAG → expenses access token  (custom AS, jwt-bearer grant, pkjwt)")

        # Expenses token — derived preview; actual decoded claims emitted separately
        # by the agent after the tool call via the __xaa_debug__ pipeline
        expenses_token_data: dict | None = None
        if id_token_claims:
            expenses_token_data = {
                "type":  "jwt_claims",
                "token": "Expenses Access Token  ⚠ derived — see actual token below",
                "iss":   "(custom AS issuer — available in actual token below)",
                "sub":   id_token_claims.get("sub"),   # preserved from org token
                "act":   {"sub": AGENT_ID},             # actual nested claim structure
                "scp":   ["expenses:read", "expenses:write", "expenses:delete"],
                "aud":   "api://expenses",
            }

        d("Okta", "ok",
          "Expenses access token obtained (scp: expenses:read expenses:write expenses:delete)",
          expenses_token_data)

        d("Interceptor", "ok",
          "Authorization: Bearer <expenses-token> injected → forwarding to MCP Server")


@app.entrypoint
def strands_agent(payload, context):
    """
    AgentCore Runtime entrypoint.

    Expected payload:
      { "prompt": "<user message>", "id_token": "<org-issued ID token>" }

    Response:
      { "response": "<agent reply>", "debug": [ {source, level, msg, ms}, ... ] }
    """
    global _tool_cache   # declared once at top — covers the entire function
    prompt = (payload.get("prompt") or "").strip()
    id_token = (payload.get("id_token") or "").strip()

    t0 = time.time()
    debug: list[dict] = []

    def d(source: str, level: str, msg: str, data=None):
        entry: dict = {"source": source, "level": level, "msg": msg,
                        "ms": round((time.time() - t0) * 1000)}
        if data is not None:
            entry["data"] = data
        debug.append(entry)

    if not prompt:
        return {"error": "prompt is required", "debug": debug}
    if not id_token:
        return {"error": "id_token is required", "debug": debug}

    # One nonce per prompt — scopes the interceptor's token cache to this invocation.
    # New prompt → new nonce → interceptor cache miss → fresh XAA exchange.
    prompt_nonce = str(uuid.uuid4())

    d("Runtime", "req",
      f"Agent invoked — prompt_len={len(prompt)} agent_id={AGENT_ID} nonce={prompt_nonce[:8]}…")
    d("Runtime", "info",
      f"AgentCore Gateway: {GATEWAY_MCP_URL.split('.gateway.')[0].split('/')[-1]}…/mcp")

    try:
        mcp_client = MCPClient(
            lambda: _create_mcp_transport(GATEWAY_MCP_URL, id_token, AGENT_ID, prompt_nonce)
        )

        # Decode org ID token claims once — passed to _xaa_chain for JWT expand buttons
        id_token_claims = _decode_jwt_claims(id_token)

        d("Gateway", "req",
          "Opening MCP session — sending X-ID-Token + X-Agent-ID headers")
        # First call: always a full XAA exchange (cold or new user)
        _xaa_chain(debug, "tools/initialize", t0, cached=False,
                   id_token_claims=id_token_claims)

        with mcp_client:
            with _tool_cache_lock:
                if _tool_cache is not None:
                    # Rebind cached tools to the current MCPClient session
                    # (MCPAgentTool.mcp_client is a plain attribute — safe to update)
                    for t in _tool_cache:
                        t.mcp_client = mcp_client
                    tools = _tool_cache
                    tool_names = [t.tool_name for t in tools]
                    d("MCP", "ok",
                      f"Tool cache hit — skipping tools/list "
                      f"({len(tools)} tools: {', '.join(tool_names)}) [~1.2s saved]")
                else:
                    tools = mcp_client.list_tools_sync()
                    _tool_cache = list(tools)
                    tool_names = [t.tool_name for t in tools]
                    d("MCP", "ok",
                      f"tools/list complete — {len(tools)} tools: {', '.join(tool_names)}")

            d("Gateway", "ok",
              f"MCP session ready — {len(tools)} tools available via Gateway → MCP Server")

            # ── Real-time Strands callback ──────────────────────────────
            _lock = threading.Lock()
            _tool_start_ms: dict[str, int] = {}    # toolUseId → ms when MCP call started
            _tool_complete_ms: dict[str, int] = {}  # toolUseId → ms when result arrived

            def _on_event(**kwargs):
                now_ms = round((time.time() - t0) * 1000)

                # LLM decided to call a tool — fires BEFORE MCP execution
                if "current_tool_use" in kwargs:
                    tc = kwargs["current_tool_use"]
                    if isinstance(tc, dict):
                        name = tc.get("name", "?")
                        tid  = tc.get("toolUseId", "")
                        inp  = tc.get("input", {})
                        with _lock:
                            _tool_start_ms[tid] = now_ms
                            debug.append({"source": "Gateway", "level": "req",
                                          "msg": f"tools/call {name}",
                                          "ms": now_ms,
                                          "data": {"input": inp} if inp else None})
                        _xaa_chain(debug, f"tools/call/{name}", t0, cached=True)
                        with _lock:
                            debug.append({"source": "MCP", "level": "req",
                                          "msg": f"Forwarding {name} to MCP Server"
                                                 f" (App Runner → REST API → DynamoDB)",
                                          "ms": now_ms})

                # Tool result received — fires AFTER MCP execution, BEFORE synthesis
                if "tool_result" in kwargs:
                    tr = kwargs["tool_result"]
                    if isinstance(tr, dict):
                        tid  = tr.get("toolUseId", "")
                        status = tr.get("status", "success")
                        start = _tool_start_ms.get(tid, now_ms)
                        exec_ms = now_ms - start
                        with _lock:
                            _tool_complete_ms[tid] = now_ms
                            debug.append({"source": "MCP", "level": "ok",
                                          "msg": f"Tool result received [{exec_ms}ms] — "
                                                 f"status: {status}, forwarding to Bedrock",
                                          "ms": now_ms})
                            debug.append({"source": "Bedrock", "level": "req",
                                          "msg": f"Synthesising response from tool result…",
                                          "ms": now_ms})

                # Per-LLM-call metrics (if emitted by this Strands version)
                if "event_loop_metrics" in kwargs:
                    m = kwargs["event_loop_metrics"]
                    try:
                        lats = getattr(m, "latencies", [])
                        for i, lat in enumerate(lats):
                            lat_ms  = getattr(lat, "latency_ms", None)
                            in_tok  = getattr(lat, "input_tokens", "?")
                            out_tok = getattr(lat, "output_tokens", "?")
                            if lat_ms is not None:
                                with _lock:
                                    debug.append({"source": "Bedrock", "level": "info",
                                                  "msg": f"LLM call {i+1}/{len(lats)}: "
                                                         f"{lat_ms}ms  "
                                                         f"({in_tok} in / {out_tok} out tokens)",
                                                  "ms": now_ms})
                    except Exception as ex:
                        logger.warning("Strands metrics extraction failed: %s", ex)

            # ── Agent invocation with timing ────────────────────────────
            # callback_handler is a constructor param in Strands, not __call__
            agent = Agent(
                model=BedrockModel(
                    model_id=MODEL_ID,
                    region_name=os.environ.get("AWS_REGION", "us-east-1"),
                ),
                tools=tools,
                system_prompt=SYSTEM_PROMPT,
                callback_handler=_on_event,
            )
            d("Bedrock", "req",
              f"Invoking {MODEL_ID.split('/')[-1].split(':')[0]} with {len(tools)} tools")
            t_agent_start = time.time()
            response = agent(prompt)
            t_agent_end   = time.time()
            agent_ms = round((t_agent_end - t_agent_start) * 1000)

            # ── Extract tool results for MCP completion events ──────────
            tool_calls: list[dict] = []
            tool_results: dict[str, dict] = {}
            try:
                for msg in (agent.messages or []):
                    for block in (msg.get("content") or []):
                        if not isinstance(block, dict):
                            continue
                        if "toolUse" in block:
                            tool_calls.append(block["toolUse"])
                        elif "toolResult" in block:
                            tr = block["toolResult"]
                            tool_results[tr.get("toolUseId", "")] = tr
            except Exception as ex:
                logger.warning("Could not extract tool calls from agent history: %s", ex)

            # Extract real XAA debug claims from tool results and emit as JWT events.
            # The MCP Server embeds __xaa_debug__ (real expenses token claims) when
            # the interceptor passes them via X-Debug-Xaa header.
            for tc in tool_calls:
                name        = tc.get("name", "?")
                tool_use_id = tc.get("toolUseId", "")
                tr          = tool_results.get(tool_use_id, {})
                tr_status   = tr.get("status", "success")

                result_content = tr.get("content") or []
                for rc in result_content:
                    if not isinstance(rc, dict) or "text" not in rc:
                        continue
                    try:
                        data = json.loads(rc["text"])
                        xaa_debug = data.pop("__xaa_debug__", None)
                        if xaa_debug:
                            # Emit REAL expenses token claims (decoded by interceptor)
                            d("Okta", "tok",
                              "Expenses access token — actual decoded claims",
                              {"type": "jwt_claims",
                               "token": "Expenses Access Token (real)",
                               **{k: v for k, v in xaa_debug.items()}})
                            # Update the tool result text with debug stripped
                            rc["text"] = json.dumps(data)
                    except Exception:
                        pass

                if tr_status != "success":
                    d("MCP", "err", f"{name} returned status: {tr_status}")

            # Final response
            content = response.message.get("content", []) if response.message else []
            text = "".join(
                block["text"]
                for block in content
                if isinstance(block, dict) and "text" in block
            ).strip()

            elapsed = round((time.time() - t0) * 1000)
            d("Bedrock", "ok", f"Response synthesized ({len(text)} chars)")
            d("Runtime", "ok",
              f"Done — {len(tool_calls)} tool call(s), "
              f"agent: {agent_ms}ms, total: {elapsed}ms")

            return {"response": text or str(response), "debug": debug}

    except Exception as e:
        logger.exception("Agent invocation failed")
        d("Runtime", "err", f"Agent error: {e}")
        # Invalidate tool cache on error — tools/list will be re-fetched next time
        with _tool_cache_lock:
            _tool_cache = None
        return {"error": f"Agent error: {e}", "debug": debug}


if __name__ == "__main__":
    app.run()
