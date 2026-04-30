#!/usr/bin/env bash
# Bootstrap all required labels in a target repository.
# Idempotent — skips labels that already exist.
#
# Usage: ./bootstrap-labels.sh <owner/repo>
# Requires: gh CLI authenticated with write access to the target repo

set -euo pipefail

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

REPO="${1:-}"
if [[ -z "$REPO" ]]; then
  echo "Usage: $0 <owner/repo>" >&2
  exit 1
fi

# Format: "name|rrggbb|description"
# Colors use GitHub's hex format (no leading #)
REQUIRED_LABELS=(
  # --- Workflow state labels ---
  "ai:triage|0075ca|AI is performing triage analysis"
  "human:review-triage|e4e669|Awaiting human review of AI triage"
  "ai:plan|0052cc|AI is generating an implementation plan"
  "human:review-plan|fbca04|Awaiting human review of AI implementation plan"
  "ai:develop|006b75|AI is implementing this issue"
  "pr:created|0e8a16|AI has created a pull request for this issue"
  "ai:blocked|d93f0b|AI workflow is blocked — human intervention required"
  "decision:close|e11d48|Issue reviewed and should be closed"
  "status:done|0e8a16|Issue completed and merged"

  # --- Priority labels ---
  "priority:low|c5def5|Low priority"
  "priority:medium|bfd4f2|Medium priority"
  "priority:high|e99695|High priority"
  "priority:urgent|b60205|Urgent — requires immediate attention"

  # --- Type labels ---
  "type:bug|d73a4a|Something is not working correctly"
  "type:feature|a2eeef|New feature or capability"
  "type:refactor|cfd3d7|Code refactoring with no behavior change"
  "type:docs|0075ca|Documentation changes"
  "type:maintenance|e4e669|Maintenance and housekeeping"
)

log "Bootstrapping labels in ${REPO}..."

existing_labels=$(gh label list --repo "$REPO" --limit 200 --json name --jq '.[].name' 2>/dev/null || echo "")

created=0
skipped=0
failed=0

for entry in "${REQUIRED_LABELS[@]}"; do
  IFS='|' read -r name color description <<< "$entry"

  if echo "$existing_labels" | grep -qx "$name"; then
    log "  SKIP    '$name' (already exists)"
    ((skipped++)) || true
  else
    if gh label create "$name" \
        --repo "$REPO" \
        --color "$color" \
        --description "$description" 2>/dev/null; then
      log "  CREATED '$name'"
      ((created++)) || true
    else
      log "  FAILED  '$name'"
      ((failed++)) || true
    fi
  fi
done

echo ""
log "Bootstrap complete: ${created} created, ${skipped} skipped, ${failed} failed"

if [[ $failed -gt 0 ]]; then
  log "Some labels failed to create. Check your gh authentication and repo write access."
  exit 1
fi
