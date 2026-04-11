#!/bin/bash
# Unified sync script for Claude Code + Gemini CLI settings
# Usage: ./scripts/sync.sh pull [-q]   # Import repo configs to local machine
#        ./scripts/sync.sh push [-q]   # Export local configs to repo and git push
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_ROOT/.env"
QUIET=false

# Parse flags
ACTION="${1:-pull}"
shift 2>/dev/null || true
for arg in "$@"; do
  case "$arg" in
    -q|--quiet) QUIET=true ;;
  esac
done

log() {
  if [ "$QUIET" = false ]; then
    echo "[sync] $1"
  fi
}

err() {
  echo "[sync] ERROR: $1" >&2
}

# Load API keys from .env file
load_env() {
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
}

# Substitute ${VAR} placeholders in a JSON string with env var values
# Only substitutes known safe keys, not arbitrary expansion
substitute_env() {
  local content="$1"
  # List of env vars we substitute
  local vars=(
    LINEAR_API_KEY
    PERPLEXITY_API_KEY
    GOOGLE_OAUTH_CLIENT_ID
    GOOGLE_OAUTH_CLIENT_SECRET
  )
  for var in "${vars[@]}"; do
    local val="${!var:-}"
    if [ -n "$val" ]; then
      content=$(echo "$content" | sed "s|\${${var}}|${val}|g")
    fi
  done
  echo "$content"
}

# Sanitize known secret patterns in JSON — replace values with ${VAR} placeholders
sanitize_secrets() {
  local content="$1"
  # Linear API key
  if [ -n "${LINEAR_API_KEY:-}" ]; then
    content=$(echo "$content" | sed "s|${LINEAR_API_KEY}|\${LINEAR_API_KEY}|g")
  fi
  # Perplexity API key
  if [ -n "${PERPLEXITY_API_KEY:-}" ]; then
    content=$(echo "$content" | sed "s|${PERPLEXITY_API_KEY}|\${PERPLEXITY_API_KEY}|g")
  fi
  # Google OAuth
  if [ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" ]; then
    content=$(echo "$content" | sed "s|${GOOGLE_OAUTH_CLIENT_ID}|\${GOOGLE_OAUTH_CLIENT_ID}|g")
  fi
  if [ -n "${GOOGLE_OAUTH_CLIENT_SECRET:-}" ]; then
    content=$(echo "$content" | sed "s|${GOOGLE_OAUTH_CLIENT_SECRET}|\${GOOGLE_OAUTH_CLIENT_SECRET}|g")
  fi
  # Generic patterns: lin_api_*, pplx-*, GOCSPX-*
  content=$(echo "$content" | sed -E 's/lin_api_[a-zA-Z0-9]+/${LINEAR_API_KEY}/g')
  content=$(echo "$content" | sed -E 's/pplx-[a-zA-Z0-9]+/${PERPLEXITY_API_KEY}/g')
  content=$(echo "$content" | sed -E 's/GOCSPX-[a-zA-Z0-9_-]+/${GOOGLE_OAUTH_CLIENT_SECRET}/g')
  echo "$content"
}

# Deep merge JSON: base + overlay -> result (overlay wins for conflicts)
# Requires jq
json_merge() {
  local base="$1"
  local overlay="$2"
  if ! command -v jq &>/dev/null; then
    err "jq is required. Install: apt install jq / brew install jq"
    return 1
  fi
  jq -s '.[0] * .[1]' <(echo "$base") <(echo "$overlay")
}

#--- PULL: repo -> local machine ---
do_pull() {
  load_env

  # 1. Claude Code: settings.json
  local repo_claude_settings="$REPO_ROOT/.claude/settings.json"
  local local_claude_settings="$HOME/.claude/settings.json"
  if [ -f "$repo_claude_settings" ] && [ -f "$local_claude_settings" ]; then
    local repo_content
    repo_content=$(cat "$repo_claude_settings")
    local local_content
    local_content=$(cat "$local_claude_settings")
    local merged
    merged=$(json_merge "$local_content" "$repo_content")
    echo "$merged" | jq '.' > "$local_claude_settings"
    log "Claude settings.json merged"
  elif [ -f "$repo_claude_settings" ]; then
    mkdir -p "$HOME/.claude"
    cp "$repo_claude_settings" "$local_claude_settings"
    log "Claude settings.json copied (new)"
  fi

  # 2. Claude Code: MCP servers -> ~/.claude.json
  local repo_mcp="$REPO_ROOT/.claude/mcp-servers.json"
  local claude_json="$HOME/.claude.json"
  if [ -f "$repo_mcp" ]; then
    local mcp_content
    mcp_content=$(substitute_env "$(cat "$repo_mcp")")
    if [ -f "$claude_json" ]; then
      jq --argjson mcp "$mcp_content" '.mcpServers = (.mcpServers // {} | . * $mcp)' "$claude_json" > "${claude_json}.tmp" && mv "${claude_json}.tmp" "$claude_json"
    else
      echo "{\"mcpServers\": $mcp_content}" | jq '.' > "$claude_json"
    fi
    log "Claude MCP servers merged"
  fi

  # 3. Claude Code: CLAUDE.md symlink
  local repo_claude_md="$REPO_ROOT/CLAUDE.md"
  local local_claude_md="$HOME/.claude/CLAUDE.md"
  if [ -f "$repo_claude_md" ]; then
    if [ -L "$local_claude_md" ]; then
      # Already a symlink, update target if different
      local current_target
      current_target=$(readlink "$local_claude_md")
      if [ "$current_target" != "$repo_claude_md" ]; then
        ln -sf "$repo_claude_md" "$local_claude_md"
        log "CLAUDE.md symlink updated"
      fi
    elif [ -f "$local_claude_md" ]; then
      # Existing file — don't overwrite, just warn
      log "CLAUDE.md exists as regular file, skipping symlink (back up and remove to enable)"
    else
      mkdir -p "$HOME/.claude"
      ln -s "$repo_claude_md" "$local_claude_md"
      log "CLAUDE.md symlinked"
    fi
  fi

  # 4. Claude Code: skills symlinks
  local repo_skills="$REPO_ROOT/.claude/skills"
  local local_skills="$HOME/.claude/skills"
  if [ -d "$repo_skills" ]; then
    mkdir -p "$local_skills"
    for skill_dir in "$repo_skills"/*/; do
      local skill_name
      skill_name=$(basename "$skill_dir")
      local target="$local_skills/$skill_name"
      if [ -L "$target" ]; then
        local current
        current=$(readlink "$target")
        if [ "$current" != "$skill_dir" ]; then
          ln -sf "$skill_dir" "$target"
        fi
      elif [ ! -e "$target" ]; then
        ln -s "$skill_dir" "$target"
        log "Skill symlinked: $skill_name"
      fi
    done
  fi

  # 5. Gemini CLI: settings.json
  local repo_gemini_settings="$REPO_ROOT/.gemini/settings.json"
  local local_gemini_settings="$HOME/.gemini/settings.json"
  if [ -f "$repo_gemini_settings" ] && [ -f "$local_gemini_settings" ]; then
    local repo_gemini
    repo_gemini=$(substitute_env "$(cat "$repo_gemini_settings")")
    local local_gemini
    local_gemini=$(cat "$local_gemini_settings")
    local merged_gemini
    merged_gemini=$(json_merge "$local_gemini" "$repo_gemini")
    echo "$merged_gemini" | jq '.' > "$local_gemini_settings"
    log "Gemini settings.json merged"
  elif [ -f "$repo_gemini_settings" ]; then
    mkdir -p "$HOME/.gemini"
    substitute_env "$(cat "$repo_gemini_settings")" | jq '.' > "$local_gemini_settings"
    log "Gemini settings.json copied (new)"
  fi

  log "Pull complete"
}

#--- PUSH: local machine -> repo ---
do_push() {
  load_env

  # 1. Claude Code: settings.json
  local local_claude_settings="$HOME/.claude/settings.json"
  local repo_claude_settings="$REPO_ROOT/.claude/settings.json"
  if [ -f "$local_claude_settings" ]; then
    cp "$local_claude_settings" "$repo_claude_settings"
    log "Claude settings.json exported"
  fi

  # 2. Claude Code: MCP servers from ~/.claude.json
  local claude_json="$HOME/.claude.json"
  local repo_mcp="$REPO_ROOT/.claude/mcp-servers.json"
  if [ -f "$claude_json" ]; then
    local mcp_content
    mcp_content=$(jq -S '.mcpServers // {}' "$claude_json")
    if [ "$mcp_content" != "null" ] && [ "$mcp_content" != "{}" ]; then
      local sanitized
      sanitized=$(sanitize_secrets "$mcp_content")
      echo "$sanitized" | jq '.' > "$repo_mcp"
      log "Claude MCP servers exported (sanitized)"
    fi
  fi

  # 3. Gemini CLI: settings.json
  local local_gemini="$HOME/.gemini/settings.json"
  local repo_gemini="$REPO_ROOT/.gemini/settings.json"
  if [ -f "$local_gemini" ]; then
    local gemini_content
    gemini_content=$(cat "$local_gemini")
    local sanitized_gemini
    sanitized_gemini=$(sanitize_secrets "$gemini_content")
    echo "$sanitized_gemini" | jq '.' > "$repo_gemini"
    log "Gemini settings.json exported (sanitized)"
  fi

  # 4. Git commit and push
  cd "$REPO_ROOT"
  git add -A
  if git diff --cached --quiet; then
    log "No changes to commit"
  else
    git commit -m "sync $(hostname) $(date '+%Y-%m-%d %H:%M')"
    git push
    log "Pushed to GitHub"
  fi

  log "Push complete"
}

# --- Main ---
case "$ACTION" in
  pull)  do_pull ;;
  push)  do_push ;;
  *)
    echo "Usage: $0 {pull|push} [-q|--quiet]"
    echo "  pull  - Import repo configs to local machine"
    echo "  push  - Export local configs to repo and git push"
    exit 1
    ;;
esac
