#!/usr/bin/env bash
# AI Plan: retrieves triage report, produces implementation plan, transitions labels.
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

  log_info "Starting planning for issue #${ISSUE_NUMBER} in ${REPO}"

  # Label guard
  if ! has_label "$REPO" "$ISSUE_NUMBER" "ai:plan"; then
    log_info "Label 'ai:plan' not present on #${ISSUE_NUMBER} — nothing to do"
    exit 0
  fi

  # Fetch issue details
  local issue_json issue_title issue_body
  issue_json=$(gh issue view "$ISSUE_NUMBER" --repo "$REPO" --json title,body)
  issue_title=$(echo "$issue_json" | jq -r '.title')
  issue_body=$(echo "$issue_json" | jq -r '.body // "(no description provided)"')

  # Retrieve triage report — planning requires a completed triage
  local triage_report=""
  if ! triage_report=$(get_comment_with_marker "$REPO" "$ISSUE_NUMBER" "ai:triage-report"); then
    mark_blocked "$REPO" "$ISSUE_NUMBER" "ai:plan" \
      "No triage report found on this issue. Ensure the triage stage completed successfully before planning (look for a comment containing \`<!-- ai:triage-report -->\`)."
    exit 1
  fi

  local project_context tech_stack
  project_context=$(get_config "project_context" "")
  tech_stack=$(get_config "tech_stack" "")

  # Build prompt: context + issue + triage + planning instructions
  PROMPT_FILE=$(mktemp /tmp/ai-plan-XXXXXX.md)
  {
    printf "Repository: %s\n\n" "$REPO"
    [[ -n "$tech_stack" ]] && printf "Tech stack: %s\n\n" "$tech_stack"
    [[ -n "$project_context" ]] && printf "Project context:\n%s\n\n" "$project_context"
    printf "## Issue #%s\n\n**Title:** %s\n\n**Body:**\n%s\n\n---\n\n" \
      "$ISSUE_NUMBER" "$issue_title" "$issue_body"
    printf "## Triage Report\n\n%s\n\n---\n\n" "$triage_report"
    cat "${WORKFLOW_KIT_DIR}/prompts/planning.md"
  } > "$PROMPT_FILE"

  # Run AI query
  local plan_result=""
  if ! run_ai_query "$PROMPT_FILE" plan_result; then
    mark_blocked "$REPO" "$ISSUE_NUMBER" "ai:plan" \
      "AI provider failed to generate an implementation plan. Check workflow logs for details."
    exit 1
  fi

  if [[ -z "$plan_result" ]]; then
    mark_blocked "$REPO" "$ISSUE_NUMBER" "ai:plan" \
      "AI provider returned an empty plan."
    exit 1
  fi

  # Post plan comment with HTML marker for later retrieval by ai-develop.sh
  post_comment "$REPO" "$ISSUE_NUMBER" "$plan_result" "ai:plan-report"

  # Transition labels: remove ai:plan, add human:review-plan
  remove_label "$REPO" "$ISSUE_NUMBER" "ai:plan"
  add_label "$REPO" "$ISSUE_NUMBER" "human:review-plan"

  log_info "Planning complete for #${ISSUE_NUMBER} — awaiting human review"
}

main "$@"
