#!/usr/bin/env bash
# AI Triage: analyzes issue, posts structured triage report, transitions labels.
#
# Required env: REPO, ISSUE_NUMBER, GH_TOKEN, REPO_DIR, WORKFLOW_KIT_DIR
# Optional env: ANTHROPIC_API_KEY, OPENAI_API_KEY

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai-common.sh
source "${SCRIPT_DIR}/ai-common.sh"

PROMPT_FILE=""

cleanup() {
  [[ -n "$PROMPT_FILE" && -f "$PROMPT_FILE" ]] && rm -f "$PROMPT_FILE"
}
trap cleanup EXIT

main() {
  validate_env REPO ISSUE_NUMBER GH_TOKEN REPO_DIR WORKFLOW_KIT_DIR
  load_config

  log_info "Starting triage for issue #${ISSUE_NUMBER} in ${REPO}"

  # Label guard — exit cleanly if the label is no longer present (prevents duplicate runs)
  if ! has_label "$REPO" "$ISSUE_NUMBER" "ai:triage"; then
    log_info "Label 'ai:triage' not present on #${ISSUE_NUMBER} — nothing to do"
    exit 0
  fi

  # Fetch issue details
  local issue_json issue_title issue_body
  issue_json=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,body)
  issue_title=$(echo "$issue_json" | jq -r '.title')
  issue_body=$(echo "$issue_json" | jq -r '.body // "(no description provided)"')

  local project_context
  project_context=$(get_config "project_context" "")

  # Build prompt: context header + base prompt instructions
  PROMPT_FILE=$(mktemp /tmp/ai-triage-XXXXXX.md)
  {
    printf "Repository: %s\n\n" "$REPO"
    if [[ -n "$project_context" ]]; then
      printf "Project context:\n%s\n\n" "$project_context"
    fi
    printf "## Issue #%s\n\n**Title:** %s\n\n**Body:**\n%s\n\n---\n\n" \
      "$ISSUE_NUMBER" "$issue_title" "$issue_body"
    cat "${WORKFLOW_KIT_DIR}/prompts/triage.md"
  } > "$PROMPT_FILE"

  # Run AI query
  local triage_result=""
  if ! run_ai_query "$PROMPT_FILE" triage_result; then
    mark_blocked "$REPO" "$ISSUE_NUMBER" "ai:triage" \
      "AI provider failed to generate a triage report. Check workflow logs for details."
    exit 1
  fi

  if [[ -z "$triage_result" ]]; then
    mark_blocked "$REPO" "$ISSUE_NUMBER" "ai:triage" \
      "AI provider returned an empty response."
    exit 1
  fi

  # Post triage comment with HTML marker for later retrieval
  post_comment "$REPO" "$ISSUE_NUMBER" "$triage_result" "ai:triage-report"

  # Transition labels: remove ai:triage, add human:review-triage
  remove_label "$REPO" "$ISSUE_NUMBER" "ai:triage"
  add_label "$REPO" "$ISSUE_NUMBER" "human:review-triage"

  log_info "Triage complete for #${ISSUE_NUMBER} — awaiting human review"
}

main "$@"
