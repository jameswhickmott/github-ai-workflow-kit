#!/usr/bin/env bash
# Foundation utilities shared by all ai-*.sh scripts.
# Source this file at the top of every script: source "${SCRIPT_DIR}/ai-common.sh"

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log()       { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
log_info()  { log "INFO  $*"; }
log_warn()  { log "WARN  $*"; }
log_error() { log "ERROR $*" >&2; }

# ---------------------------------------------------------------------------
# Config — parses .github/ai-workflow.yml in REPO_DIR
# ---------------------------------------------------------------------------

declare -gA AI_CONFIG=()

load_config() {
  local config_file="${REPO_DIR:-}/.github/ai-workflow.yml"
  if [[ ! -f "$config_file" ]]; then
    log_warn "No config found at $config_file — using defaults"
    return 0
  fi

  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*(.*) ]]; then
      local key="${BASH_REMATCH[1]}"
      local value="${BASH_REMATCH[2]}"
      value="${value%%  #*}"     # strip inline comments (double-space prefix)
      value="${value%\"}"        # strip trailing double-quote
      value="${value#\"}"        # strip leading double-quote
      value="${value%\'}"        # strip trailing single-quote
      value="${value#\'}"        # strip leading single-quote
      value="${value%"${value##*[![:space:]]}"}"  # trim trailing whitespace
      AI_CONFIG["$key"]="$value"
    fi
  done < "$config_file"

  log_info "Loaded config from $config_file"
}

get_config() {
  local key="$1"
  local default="${2:-}"
  echo "${AI_CONFIG[$key]:-$default}"
}

# ---------------------------------------------------------------------------
# Environment validation
# ---------------------------------------------------------------------------

validate_env() {
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Required environment variables not set: ${missing[*]}"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Label management
# ---------------------------------------------------------------------------

add_label() {
  local repo="$1" issue="$2" label="$3"
  log_info "Adding label '$label' to #${issue}"
  gh issue edit "$issue" --repo "$repo" --add-label "$label"
}

remove_label() {
  local repo="$1" issue="$2" label="$3"
  log_info "Removing label '$label' from #${issue}"
  gh issue edit "$issue" --repo "$repo" --remove-label "$label" 2>/dev/null || true
}

has_label() {
  local repo="$1" issue="$2" label="$3"
  gh issue view "$issue" --repo "$repo" --json labels \
    --jq '.labels[].name' 2>/dev/null | grep -qx "$label"
}

# ---------------------------------------------------------------------------
# Comments
# ---------------------------------------------------------------------------

post_comment() {
  local repo="$1" issue="$2" body="$3" marker="${4:-}"
  local full_body
  if [[ -n "$marker" ]]; then
    full_body="<!-- ${marker} -->

${body}"
  else
    full_body="$body"
  fi
  log_info "Posting comment on #${issue}"
  gh issue comment "$issue" --repo "$repo" --body "$full_body"
}

# Find the most recent comment containing the given HTML marker.
# Outputs the comment body to stdout. Returns 1 if not found.
get_comment_with_marker() {
  local repo="$1" issue="$2" marker="$3"
  local result
  result=$(gh api "repos/${repo}/issues/${issue}/comments" \
    --paginate \
    --jq "[.[] | select(.body | contains(\"<!-- ${marker} -->\"))] | last | .body // empty" \
    2>/dev/null)
  if [[ -z "$result" ]]; then
    return 1
  fi
  echo "$result"
}

# ---------------------------------------------------------------------------
# Branch and PR checks
# ---------------------------------------------------------------------------

branch_exists_remote() {
  local repo="$1" branch="$2"
  gh api "repos/${repo}/git/refs/heads/${branch}" --silent 2>/dev/null
  return $?
}

pr_exists_for_issue() {
  local repo="$1" issue="$2"
  local count
  count=$(gh pr list --repo "$repo" --state open \
    --search "\"Closes #${issue}\"" \
    --json number --jq 'length' 2>/dev/null || echo "0")
  [[ "$count" -gt 0 ]]
}

# ---------------------------------------------------------------------------
# Failure handling
# ---------------------------------------------------------------------------

mark_blocked() {
  local repo="$1" issue="$2" current_label="$3" reason="$4"
  log_warn "Marking #${issue} as blocked: $reason"
  remove_label "$repo" "$issue" "$current_label" || true
  add_label "$repo" "$issue" "ai:blocked"
  post_comment "$repo" "$issue" \
"## AI Workflow Blocked

**Stage:** \`${current_label}\`

**Reason:** ${reason}

To retry after resolving:
1. Remove the \`ai:blocked\` label
2. Re-add the \`${current_label}\` label

*Human review required — AI must not self-clear this block.*"
}

# ---------------------------------------------------------------------------
# Repository helpers
# ---------------------------------------------------------------------------

get_default_branch() {
  local repo="${1:-$REPO}"
  gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name'
}

# ---------------------------------------------------------------------------
# AI provider abstraction
# ---------------------------------------------------------------------------

# Run an AI text query and capture the output into a named variable.
# Usage: run_ai_query <prompt_file> <output_var_name>
run_ai_query() {
  local prompt_file="$1"
  local output_var="$2"
  local provider
  provider=$(get_config "ai_provider" "claude")

  local result=""
  local exit_code=0

  case "$provider" in
    claude)
      result=$(ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
        claude --print --no-markdown -p "$(cat "$prompt_file")" 2>&1) || exit_code=$?
      ;;
    openai|codex|aider)
      local model
      model=$(get_config "openai_model" "gpt-4o")
      local payload
      payload=$(jq -n \
        --arg model "$model" \
        --rawfile content "$prompt_file" \
        '{"model":$model,"messages":[{"role":"user","content":$content}]}')
      result=$(curl -sf https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer ${OPENAI_API_KEY:-}" \
        -H "Content-Type: application/json" \
        -d "$payload" | jq -r '.choices[0].message.content') || exit_code=$?
      ;;
    *)
      log_error "Unknown AI provider: $provider"
      return 1
      ;;
  esac

  if [[ $exit_code -ne 0 ]]; then
    log_error "AI provider '$provider' returned exit code $exit_code"
    return $exit_code
  fi

  printf -v "$output_var" '%s' "$result"
}

# Run an AI agent that modifies files in a working directory.
# Usage: run_ai_develop <prompt_file> <working_dir>
run_ai_develop() {
  local prompt_file="$1"
  local working_dir="$2"
  local provider
  provider=$(get_config "ai_provider" "claude")

  pushd "$working_dir" > /dev/null
  local exit_code=0

  case "$provider" in
    claude)
      ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
        claude --dangerously-skip-permissions -p "$(cat "$prompt_file")" || exit_code=$?
      ;;
    aider|openai)
      OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
        aider --yes-always --no-git \
              --model "$(get_config "openai_model" "gpt-4o")" \
              --message "$(cat "$prompt_file")" || exit_code=$?
      ;;
    codex)
      OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
        codex --full-auto "$(cat "$prompt_file")" || exit_code=$?
      ;;
    *)
      log_error "Unknown AI provider for develop: $provider"
      popd > /dev/null
      return 1
      ;;
  esac

  popd > /dev/null
  return $exit_code
}
