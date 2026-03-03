#!/bin/bash
# Sync MCP servers from claude-code-kit repo to ~/.claude.json
# Run this after updating .claude/mcp-servers.json

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MCP_FILE="$REPO_ROOT/.claude/mcp-servers.json"
CLAUDE_JSON="$HOME/.claude.json"

if [ ! -f "$MCP_FILE" ]; then
    echo "Error: MCP servers file not found at $MCP_FILE"
    exit 1
fi

if [ ! -f "$CLAUDE_JSON" ]; then
    echo "Error: Claude config not found at $CLAUDE_JSON"
    exit 1
fi

# Backup current config
cp "$CLAUDE_JSON" "$CLAUDE_JSON.backup"

# Update mcpServers in ~/.claude.json using jq
if command -v jq &> /dev/null; then
    jq --slurpfile mcp "$MCP_FILE" '.mcpServers = $mcp[0]' "$CLAUDE_JSON" > "$CLAUDE_JSON.tmp" && mv "$CLAUDE_JSON.tmp" "$CLAUDE_JSON"
    echo "MCP servers synced successfully from $MCP_FILE"
    echo "Backup saved to $CLAUDE_JSON.backup"
else
    echo "Error: jq is required. Install with: brew install jq"
    exit 1
fi
