"""
Strands agent for the ExpensePro chat assistant.

The agent uses the MCP server (FastMCP on App Runner) as its tool interface —
the architecturally correct approach for an AI agent. The MCP server exposes
list_expenses, create_expense, and delete_expense tools over streamable-HTTP.

Token flow:
  1. Okta Cross-App Access exchange → expenses access token
  2. MCPClient connects to the MCP server with Bearer <access_token>
  3. Strands discovers tools from MCP and invokes via standard MCP protocol
"""

import asyncio
import logging
import os

from mcp.client.streamable_http import streamablehttp_client
from strands import Agent
from strands.models import BedrockModel
from strands.tools.mcp import MCPClient

from okta_xaa import get_expenses_access_token

logger = logging.getLogger(__name__)

MCP_SERVER_URL = os.environ["MCP_SERVER_URL"]   # https://g45wqjhenu.us-east-1.awsapprunner.com/mcp

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


def invoke_agent(org_id_token: str, message: str, dbg=None) -> str:
    """Perform the full XAA exchange, connect to MCP, and invoke the Strands agent.

    Replaces the old build_agent() + agent(message) pattern with a single call
    that manages the MCP client lifecycle correctly within one Lambda invocation.
    """
    _dbg = dbg or (lambda *a, **kw: None)

    # ── Step 1: Okta Cross-App Access → expenses access token ─────────────
    try:
        access_token = get_expenses_access_token(org_id_token, dbg)
    except Exception as e:
        msg = f"Okta Cross-App Access failed: {e}"
        _dbg("Lambda", "err", msg)
        raise RuntimeError(msg) from e

    # ── Step 2: Connect Strands agent to MCP server via streamable-HTTP ───
    _dbg("Lambda", "req",
         f"Connecting Strands agent to MCP server: {MCP_SERVER_URL}")

    mcp_client = MCPClient(
        lambda: streamablehttp_client(
            MCP_SERVER_URL,
            headers={"Authorization": f"Bearer {access_token}"},
        )
    )

    with mcp_client:
        tools = mcp_client.list_tools_sync()
        tool_names = [t.tool_name for t in tools]
        _dbg("Lambda", "ok",
             f"MCP tools discovered: {', '.join(tool_names)}")

        agent = Agent(
            model=BedrockModel(
                model_id="us.anthropic.claude-3-5-haiku-20241022-v1:0",
                region_name=os.environ.get("AWS_REGION", "us-east-1"),
            ),
            tools=tools,
            system_prompt=SYSTEM_PROMPT,
        )

        response = agent(message)

        # AgentResult.__str__ appends "\n" after every streaming chunk, producing
        # garbled output when Bedrock streams many small text tokens.
        # Extract and join text blocks directly — no inter-chunk newlines.
        content = response.message.get("content", []) if response.message else []
        text = "".join(
            block["text"] for block in content
            if isinstance(block, dict) and "text" in block
        ).strip()
        return text or str(response)  # fallback to __str__ if no text blocks found
