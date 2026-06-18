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

import logging
import os
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

app = BedrockAgentCoreApp()

GATEWAY_MCP_URL = os.environ["GATEWAY_MCP_URL"]
MODEL_ID = os.environ.get("MODEL_ID", "us.anthropic.claude-3-5-haiku-20241022-v1:0")
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


def _xaa_chain(debug: list, step_label: str, t0: float, cached: bool = False) -> None:
    """Emit the known interceptor → Okta XAA sequence for a given MCP request step.

    cached=True when the token was served from the interceptor's in-memory cache
    (no Okta round-trips needed — warm Lambda reuse within the ~1h token TTL).
    """
    def d(source, level, msg):
        debug.append({"source": source, "level": level, "msg": msg,
                       "ms": round((time.time() - t0) * 1000)})

    d("Interceptor", "req",
      f"XAA exchange fired ({step_label}) — reading X-ID-Token from request headers")

    if cached:
        d("Interceptor", "ok",
          "Token cache hit — skipping Okta round-trips (warm Lambda, token still valid)")
        d("Interceptor", "ok",
          "Authorization: Bearer <expenses-token> injected → forwarding to MCP Server")
    else:
        d("Okta", "req",
          "Stage 2: org ID token → ID-JAG  (org AS, token-exchange grant, pkjwt client_assertion)")
        d("Okta", "ok",
          "ID-JAG obtained (act.sub: AI Agent, iss: org AS, expires_in: 300s)")
        d("Okta", "req",
          "Stage 3: ID-JAG → expenses access token  (custom AS, jwt-bearer grant, pkjwt)")
        d("Okta", "ok",
          "Expenses access token obtained (scp: expenses:read expenses:write expenses:delete)")
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

        d("Gateway", "req",
          "Opening MCP session — sending X-ID-Token + X-Agent-ID headers")
        # First call: always a full XAA exchange (cold or new user)
        _xaa_chain(debug, "tools/initialize", t0, cached=False)

        with mcp_client:
            tools = mcp_client.list_tools_sync()
            tool_names = [t.tool_name for t in tools]
            d("MCP", "ok",
              f"tools/list complete — {len(tools)} tools: {', '.join(tool_names)}")
            d("Gateway", "ok",
              f"MCP session ready — {len(tools)} tools available via Gateway → MCP Server")

            agent = Agent(
                model=BedrockModel(
                    model_id=MODEL_ID,
                    region_name=os.environ.get("AWS_REGION", "us-east-1"),
                ),
                tools=tools,
                system_prompt=SYSTEM_PROMPT,
            )

            d("Bedrock", "req",
              f"Invoking {MODEL_ID.split('/')[0] if '/' in MODEL_ID else MODEL_ID} "
              f"with {len(tools)} tools")
            response = agent(prompt)

            # Extract tool calls and results from Strands message history
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

            # Emit per-tool-call events (Gateway → Interceptor → Okta → MCP chain)
            for tc in tool_calls:
                name = tc.get("name", "?")
                tool_input = tc.get("input", {})
                tool_use_id = tc.get("toolUseId", "")
                tr = tool_results.get(tool_use_id, {})
                tr_status = tr.get("status", "success")

                d("Gateway", "req",
                  f"tools/call {name}",
                  {"input": tool_input} if tool_input else None)
                # Subsequent calls hit the interceptor's in-memory token cache
                # (warm Lambda, same user sub, token still valid)
                _xaa_chain(debug, f"tools/call/{name}", t0, cached=True)
                d("MCP", "req",
                  f"Forwarding {name} to MCP Server (App Runner → REST API → DynamoDB)")
                if tr_status == "success":
                    # Try to extract a brief result summary
                    result_content = tr.get("content") or []
                    result_text = ""
                    for rc in result_content:
                        if isinstance(rc, dict) and "text" in rc:
                            result_text = rc["text"][:120]
                            break
                    d("MCP", "ok",
                      f"{name} complete — result forwarded to Bedrock"
                      + (f" ({result_text[:80]}…)" if len(result_text) > 80 else
                         (f" ({result_text})" if result_text else "")))
                else:
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
              f"Done — {len(tool_calls)} tool call(s), {elapsed}ms total")

            return {"response": text or str(response), "debug": debug}

    except Exception as e:
        logger.exception("Agent invocation failed")
        d("Runtime", "err", f"Agent error: {e}")
        return {"error": f"Agent error: {e}", "debug": debug}


if __name__ == "__main__":
    app.run()
