#!/bin/bash
# One-time bootstrap for syncing Claude Code + Gemini CLI settings
# Run once on a new machine after cloning the repo and filling in .env
#
# Usage:
#   git clone https://github.com/manana2520/claude-code-kit ~/claude-code-kit
#   cd ~/claude-code-kit
#   cp .env.example .env  # fill in API keys
#   ./scripts/setup.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_ROOT/.env"

echo "=== Claude Code + Gemini CLI Settings Sync Setup ==="
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required."
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "  Install: brew install jq"
  else
    echo "  Install: sudo apt install jq"
  fi
  exit 1
fi

if ! command -v git &>/dev/null; then
  echo "ERROR: git is required."
  exit 1
fi

# Check .env file
if [ ! -f "$ENV_FILE" ]; then
  echo "WARNING: No .env file found."
  echo "  Copy .env.example and fill in your API keys:"
  echo "  cp $REPO_ROOT/.env.example $REPO_ROOT/.env"
  echo ""
  echo "Continuing without API key substitution..."
  echo ""
fi

# 1. Apply all configs (pull)
echo "--- Applying configs ---"
"$SCRIPT_DIR/sync.sh" pull
echo ""

# 2. Install SessionStart hook into ~/.claude/settings.json
echo "--- Installing Claude Code SessionStart hook ---"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD="cd ~/claude-code-kit && git pull --rebase --autostash -q && ./scripts/sync.sh pull -q 2>/dev/null || true"

if [ -f "$CLAUDE_SETTINGS" ]; then
  # Check if hook already exists
  if jq -e '.hooks.SessionStart[]?.hooks[]? | select(.command | contains("claude-code-kit"))' "$CLAUDE_SETTINGS" &>/dev/null; then
    echo "SessionStart hook already installed, updating..."
    # Update existing hook command
    jq --arg cmd "$HOOK_CMD" '
      .hooks.SessionStart |= map(
        .hooks |= map(
          if (.command | contains("claude-code-kit")) then .command = $cmd else . end
        )
      )
    ' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp" && mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS"
  else
    echo "Adding SessionStart hook..."
    jq --arg cmd "$HOOK_CMD" '
      .hooks = (.hooks // {}) |
      .hooks.SessionStart = ((.hooks.SessionStart // []) + [{
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": $cmd,
          "timeout": 15
        }]
      }])
    ' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp" && mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS"
  fi
  echo "SessionStart hook installed"
else
  echo "WARNING: ~/.claude/settings.json not found. Install Claude Code first, then re-run setup."
fi
echo ""

# 2b. Install SessionEnd hook into ~/.claude/settings.json
echo "--- Installing Claude Code SessionEnd hook ---"
END_HOOK_CMD="cd ~/claude-code-kit && ./scripts/sync.sh push -q 2>/dev/null || true"

if [ -f "$CLAUDE_SETTINGS" ]; then
  if jq -e '.hooks.SessionEnd[]?.hooks[]? | select(.command | contains("claude-code-kit"))' "$CLAUDE_SETTINGS" &>/dev/null; then
    echo "SessionEnd hook already installed, updating..."
    jq --arg cmd "$END_HOOK_CMD" '
      .hooks.SessionEnd |= map(
        .hooks |= map(
          if (.command | contains("claude-code-kit")) then .command = $cmd else . end
        )
      )
    ' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp" && mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS"
  else
    echo "Adding SessionEnd hook..."
    jq --arg cmd "$END_HOOK_CMD" '
      .hooks = (.hooks // {}) |
      .hooks.SessionEnd = ((.hooks.SessionEnd // []) + [{
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": $cmd,
          "timeout": 30
        }]
      }])
    ' "$CLAUDE_SETTINGS" > "${CLAUDE_SETTINGS}.tmp" && mv "${CLAUDE_SETTINGS}.tmp" "$CLAUDE_SETTINGS"
  fi
  echo "SessionEnd hook installed"
fi
echo ""

# 3. Summary
echo "=== Setup Complete ==="
echo ""
echo "What was configured:"
echo "  - Claude Code settings.json: merged"
echo "  - Claude Code MCP servers: merged into ~/.claude.json"
echo "  - Claude Code CLAUDE.md: symlinked"
echo "  - Claude Code skills: symlinked"
echo "  - Gemini CLI settings.json: merged (including MCP servers)"
echo "  - SessionStart hook: installed (auto-pulls on every session start)"
echo "  - SessionEnd hook: installed (auto-pushes on every session end)"
echo ""
echo "How it works:"
echo "  - Every time you start Claude Code, it auto-pulls latest settings from git"
echo "  - Every time a session ends, it auto-pushes local settings back to git"
echo "  - Manual push if needed: ~/claude-code-kit/scripts/sync.sh push"
echo ""

# Load .env to check for missing vars
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# Warn about missing env vars
missing_vars=()
for var in LINEAR_API_KEY PERPLEXITY_API_KEY; do
  if [ -z "${!var:-}" ]; then
    missing_vars+=("$var")
  fi
done

if [ ${#missing_vars[@]} -gt 0 ]; then
  echo "WARNING: Missing API keys (MCP servers using these won't work):"
  for var in "${missing_vars[@]}"; do
    echo "  - $var"
  done
  echo "  Add them to $ENV_FILE and re-run: ./scripts/sync.sh pull"
fi
