#!/usr/bin/env bash
# AI Develop: creates branch, implements approved plan, opens PR.
# Supports single-issue mode (--issue N) and queue mode (--queue).
#
# Required env: REPO, GH_TOKEN, REPO_DIR, WORKFLOW_KIT_DIR
# Optional env: ISSUE_NUMBER (overridden by --issue flag), ANTHROPIC_API_KEY, OPENAI_API_KEY

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ai-common.sh
source "${SCRIPT_DIR}/ai-common.sh"

PROMPT_FILE=""

cleanup() {
  [[ -n "$PROMPT_FILE" && -f "$PROMPT_FILE" ]] && rm -f "$PROMPT_FILE"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Process a single issue end-to-end.
# Returns 0 on success or handled failure (caller continues queue).
# Returns 1 only on unrecoverable infrastructure failure.
# ---------------------------------------------------------------------------
process_issue() {
  local issue_num="$1"
  local branch="ai/issue-${issue_num}"
  local default_branch
  default_branch=$(get_default_branch "$REPO")

  log_info "Processing issue #${issue_num} (branch: $branch)"

  # Label guard — prevent duplicate work if label was removed between queue fetch and now
  if ! has_label "$REPO" "$issue_num" "ai:develop"; then
    log_info "#${issue_num} no longer has 'ai:develop' label — skipping"
    return 0
  fi

  # Duplicate prevention: skip if branch or PR already exists
  if branch_exists_remote "$REPO" "$branch" 2>/dev/null; then
    log_warn "Branch '$branch' already exists — skipping #${issue_num} to prevent duplicate"
    return 0
  fi
  if pr_exists_for_issue "$REPO" "$issue_num" 2>/dev/null; then
    log_warn "Open PR already exists for #${issue_num} — skipping"
    return 0
  fi

  # Fetch issue details
  local issue_json issue_title issue_body
  issue_json=$(gh issue view "$issue_num" --repo "$REPO" --json title,body)
  issue_title=$(echo "$issue_json" | jq -r '.title')
  issue_body=$(echo "$issue_json" | jq -r '.body // "(no description provided)"')

  # Retrieve the approved plan — required before any code changes
  local plan_report=""
  if ! plan_report=$(get_comment_with_marker "$REPO" "$issue_num" "ai:plan-report"); then
    mark_blocked "$REPO" "$issue_num" "ai:develop" \
      "No approved plan found. Ensure the planning stage completed successfully (look for a comment containing \`<!-- ai:plan-report -->\`)."
    return 0
  fi

  local tech_stack project_context test_command build_command lint_command
  tech_stack=$(get_config "tech_stack" "")
  project_context=$(get_config "project_context" "")
  test_command=$(get_config "test_command" "")
  build_command=$(get_config "build_command" "")
  lint_command=$(get_config "lint_command" "")

  # Configure git identity in the target repo
  git -C "$REPO_DIR" config user.email "ai-workflow-bot@github-actions.noreply"
  git -C "$REPO_DIR" config user.name "AI Workflow Bot"

  # Ensure we start from a clean default branch
  git -C "$REPO_DIR" checkout "$default_branch" 2>/dev/null || true
  git -C "$REPO_DIR" pull --ff-only origin "$default_branch" 2>/dev/null || \
    log_warn "Could not fast-forward pull — proceeding from current HEAD"

  # Create feature branch
  git -C "$REPO_DIR" checkout -b "$branch"
  log_info "Created branch '$branch'"

  # Build the development prompt
  PROMPT_FILE=$(mktemp /tmp/ai-develop-XXXXXX.md)
  {
    printf "Repository: %s\n" "$REPO"
    printf "Branch: %s\n\n" "$branch"
    [[ -n "$tech_stack" ]]       && printf "Tech stack: %s\n\n" "$tech_stack"
    [[ -n "$project_context" ]]  && printf "Project context:\n%s\n\n" "$project_context"
    [[ -n "$test_command" ]]     && printf "Test command: %s\n" "$test_command"
    [[ -n "$build_command" ]]    && printf "Build command: %s\n" "$build_command"
    [[ -n "$lint_command" ]]     && printf "Lint command: %s\n" "$lint_command"
    printf "\n## Issue #%s\n\n**Title:** %s\n\n**Body:**\n%s\n\n---\n\n" \
      "$issue_num" "$issue_title" "$issue_body"
    printf "## Approved Implementation Plan\n\n%s\n\n---\n\n" "$plan_report"
    cat "${WORKFLOW_KIT_DIR}/prompts/develop.md"
  } > "$PROMPT_FILE"

  # Run AI development agent
  local develop_exit=0
  run_ai_develop "$PROMPT_FILE" "$REPO_DIR" || develop_exit=$?

  if [[ $develop_exit -ne 0 ]]; then
    log_error "AI develop failed for #${issue_num} (exit $develop_exit)"
    git -C "$REPO_DIR" checkout "$default_branch" 2>/dev/null || true
    git -C "$REPO_DIR" branch -D "$branch" 2>/dev/null || true
    mark_blocked "$REPO" "$issue_num" "ai:develop" \
      "AI provider failed during code implementation (exit code ${develop_exit}). Check the workflow run logs for details."
    rm -f "$PROMPT_FILE"; PROMPT_FILE=""
    return 0
  fi

  # Verify the AI actually made changes
  local has_staged has_untracked
  has_staged=$(git -C "$REPO_DIR" diff --name-only HEAD 2>/dev/null || true)
  has_untracked=$(git -C "$REPO_DIR" ls-files --others --exclude-standard 2>/dev/null || true)

  if [[ -z "$has_staged" && -z "$has_untracked" ]]; then
    log_warn "AI made no file changes for #${issue_num}"
    git -C "$REPO_DIR" checkout "$default_branch" 2>/dev/null || true
    git -C "$REPO_DIR" branch -D "$branch" 2>/dev/null || true
    mark_blocked "$REPO" "$issue_num" "ai:develop" \
      "AI provider ran successfully but made no file changes. The implementation plan may need more specificity."
    rm -f "$PROMPT_FILE"; PROMPT_FILE=""
    return 0
  fi

  # Run optional quality checks (non-fatal — results noted in PR body)
  local lint_status="not run" test_status="not run"

  if [[ -n "$lint_command" ]]; then
    log_info "Running lint: $lint_command"
    if (cd "$REPO_DIR" && eval "$lint_command"); then
      lint_status="passed"
    else
      lint_status="failed"
      log_warn "Lint failed — continuing (will be noted in PR)"
    fi
  fi

  if [[ -n "$test_command" ]]; then
    log_info "Running tests: $test_command"
    if (cd "$REPO_DIR" && eval "$test_command"); then
      test_status="passed"
    else
      test_status="failed"
      log_warn "Tests failed — continuing (will be noted in PR)"
    fi
  fi

  # Commit all changes
  git -C "$REPO_DIR" add -A
  git -C "$REPO_DIR" commit -m "feat: AI implementation for issue #${issue_num}

$(echo "$issue_title" | head -c 72)

Co-authored-by: AI Workflow Bot <ai-workflow@noreply.github.com>"

  # Push branch
  git -C "$REPO_DIR" push origin "$branch"
  log_info "Pushed branch '$branch'"

  # Build PR body
  local pr_body
  pr_body="Closes #${issue_num}

## Summary

AI-generated implementation for: **${issue_title}**

| Check | Status |
|-------|--------|
| Lint | ${lint_status} |
| Tests | ${test_status} |

## Review Notes

- Verify the implementation matches the approved plan on issue #${issue_num}
- Check that all acceptance criteria from the triage report are met
- Run tests locally before merging

<details>
<summary>Approved Plan (expand)</summary>

${plan_report}

</details>

---
*This PR was opened by the AI development workflow. Human review and approval is required before merging. AI must not self-approve or merge.*
<!-- ai:pr-report -->"

  # Create PR
  local pr_url=""
  pr_url=$(gh pr create \
    --repo "$REPO" \
    --title "feat: issue #${issue_num} - ${issue_title}" \
    --body "$pr_body" \
    --head "$branch" \
    --base "$default_branch")

  log_info "Created PR: $pr_url"

  # Transition labels
  remove_label "$REPO" "$issue_num" "ai:develop"
  add_label "$REPO" "$issue_num" "pr:created"

  # Notify on the issue
  post_comment "$REPO" "$issue_num" \
"## AI Development Complete

A pull request has been created for this issue:

**${pr_url}**

Branch: \`${branch}\`

Human review and approval required before merging.

| Check | Status |
|-------|--------|
| Lint | ${lint_status} |
| Tests | ${test_status} |

*AI must not self-approve or merge this PR.*"

  # Clean up for next iteration
  rm -f "$PROMPT_FILE"; PROMPT_FILE=""
  git -C "$REPO_DIR" checkout "$default_branch" 2>/dev/null || true

  log_info "Development complete for #${issue_num}"
}

# ---------------------------------------------------------------------------
main() {
  validate_env REPO GH_TOKEN REPO_DIR WORKFLOW_KIT_DIR
  load_config

  local mode="single"
  local single_issue="${ISSUE_NUMBER:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --issue)
        mode="single"
        single_issue="$2"
        shift 2
        ;;
      --queue)
        mode="queue"
        shift
        ;;
      *)
        log_error "Unknown argument: $1"
        exit 1
        ;;
    esac
  done

  local issues=()

  if [[ "$mode" == "single" ]]; then
    if [[ -z "$single_issue" ]]; then
      log_error "Single mode requires --issue N or ISSUE_NUMBER env var"
      exit 1
    fi
    issues=("$single_issue")
  else
    local max
    max=$(get_config "max_issues_per_run" "3")
    log_info "Queue mode: fetching up to $max open issues with 'ai:develop' label"
    mapfile -t issues < <(
      gh issue list \
        --repo "$REPO" \
        --label "ai:develop" \
        --state open \
        --limit "$max" \
        --json number \
        --jq '.[].number' \
      2>/dev/null || true
    )
  fi

  if [[ ${#issues[@]} -eq 0 ]]; then
    log_info "No issues to process"
    exit 0
  fi

  log_info "Processing ${#issues[@]} issue(s): ${issues[*]}"

  local overall_exit=0
  for issue_num in "${issues[@]}"; do
    process_issue "$issue_num" || {
      log_error "Unrecoverable error processing #${issue_num} — stopping queue"
      overall_exit=1
      break
    }
  done

  log_info "Queue complete"
  exit $overall_exit
}

main "$@"
