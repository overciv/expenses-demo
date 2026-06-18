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
"""

import logging
import os
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
    """Injects Authorization, X-ID-Token, and X-Agent-ID on every outbound MCP request.

    AgentCore Gateway uses Authorization to validate the inbound JWT (then strips it).
    X-ID-Token is passed through to the XAA interceptor Lambda for token exchange.
    X-Agent-ID tells the interceptor which Secrets Manager secret to use.
    """

    def __init__(self, transport: httpx.AsyncBaseTransport, token: str, agent_id: str):
        self._transport = transport
        self._headers = {
            "Authorization": f"Bearer {token}",
            "X-ID-Token": token,
            "X-Agent-ID": agent_id,
        }

    async def handle_async_request(self, request: httpx.Request) -> httpx.Response:
        request.headers.update(self._headers)
        return await self._transport.handle_async_request(request)


@asynccontextmanager
async def _mcp_transport(mcp_url: str, token: str, agent_id: str):
    timeout = httpx.Timeout(30.0, read=300.0)
    base = httpx.AsyncHTTPTransport()
    wrapped = _AuthHeaderTransport(base, token, agent_id)
    async with httpx.AsyncClient(
        transport=wrapped, timeout=timeout, follow_redirects=True
    ) as client:
        async with streamable_http_client(mcp_url, http_client=client) as streams:
            yield streams


def _create_mcp_transport(mcp_url: str, token: str, agent_id: str):
    return _mcp_transport(mcp_url, token, agent_id)


@app.entrypoint
def strands_agent(payload, context):
    """
    AgentCore Runtime entrypoint. Receives the invocation payload from the caller.

    Expected payload:
      { "prompt": "<user message>", "id_token": "<org-issued ID token>" }
    """
    prompt = (payload.get("prompt") or "").strip()
    id_token = (payload.get("id_token") or "").strip()

    if not prompt:
        return {"error": "prompt is required"}
    if not id_token:
        return {"error": "id_token is required — send the org-issued ID token from Okta"}

    logger.info("Invoking agent: prompt_len=%d agent_id=%s", len(prompt), AGENT_ID)

    try:
        mcp_client = MCPClient(
            lambda: _create_mcp_transport(GATEWAY_MCP_URL, id_token, AGENT_ID)
        )
        with mcp_client:
            tools = mcp_client.list_tools_sync()
            tool_names = [t.tool_name for t in tools]
            logger.info("MCP tools discovered via Gateway: %s", ", ".join(tool_names))

            agent = Agent(
                model=BedrockModel(
                    model_id=MODEL_ID,
                    region_name=os.environ.get("AWS_REGION", "us-east-1"),
                ),
                tools=tools,
                system_prompt=SYSTEM_PROMPT,
            )
            response = agent(prompt)

        content = response.message.get("content", []) if response.message else []
        text = "".join(
            block["text"]
            for block in content
            if isinstance(block, dict) and "text" in block
        ).strip()
        return {"response": text or str(response)}

    except Exception as e:
        logger.exception("Agent invocation failed")
        return {"error": f"Agent error: {e}"}


if __name__ == "__main__":
    app.run()
