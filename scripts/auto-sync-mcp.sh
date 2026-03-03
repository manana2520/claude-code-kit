#!/bin/bash
# Auto-sync MCP servers from ~/.claude.json to git repo
# Triggered by launchd when ~/.claude.json changes

set -e

REPO_DIR="/Users/maziak/Devel/claude-code-kit"
MCP_FILE="$REPO_DIR/.claude/mcp-servers.json"
SOURCE_FILE="$HOME/.claude.json"
LOG_FILE="$REPO_DIR/.scratch/mcp-sync.log"

mkdir -p "$(dirname "$LOG_FILE")"
exec >> "$LOG_FILE" 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Sync triggered"

if [ ! -f "$SOURCE_FILE" ]; then
    log "ERROR: Source file not found: $SOURCE_FILE"
    exit 1
fi

# Extract mcpServers from ~/.claude.json and sanitize secrets
CURRENT_MCP=$(jq -S '.mcpServers // {}' "$SOURCE_FILE" 2>/dev/null)
if [ -z "$CURRENT_MCP" ] || [ "$CURRENT_MCP" = "null" ]; then
    log "No mcpServers found in source"
    exit 0
fi

# Sanitize known secret patterns (Google OAuth, API keys, etc.)
# Replace client_id/client_secret in escaped JSON strings with env var placeholders
CURRENT_MCP=$(echo "$CURRENT_MCP" | sed -E '
    s/\\\"client_id\\\": *\\\"[0-9]+-[a-zA-Z0-9]+\.apps\.googleusercontent\.com\\\"/\\"client_id\\": \\"${GOOGLE_OAUTH_CLIENT_ID}\\"/g
    s/\\\"client_secret\\\": *\\\"GOCSPX-[a-zA-Z0-9_-]+\\\"/\\"client_secret\\": \\"${GOOGLE_OAUTH_CLIENT_SECRET}\\"/g
')

# Get existing repo version (if exists)
if [ -f "$MCP_FILE" ]; then
    REPO_MCP=$(jq -S '.' "$MCP_FILE" 2>/dev/null)
else
    REPO_MCP="{}"
fi

# Compare (normalized)
if [ "$CURRENT_MCP" = "$REPO_MCP" ]; then
    log "No changes detected"
    exit 0
fi

log "Changes detected, updating repo"

# Write new version
echo "$CURRENT_MCP" | jq '.' > "$MCP_FILE"

# Commit and push
cd "$REPO_DIR"
git add .claude/mcp-servers.json

if git diff --cached --quiet; then
    log "No git changes to commit"
    exit 0
fi

git commit -m "Auto-sync MCP servers $(date '+%Y-%m-%d %H:%M')"
git push

log "Pushed to GitHub successfully"
