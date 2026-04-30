#!/usr/bin/env bash
# Pull the latest AI workflow from github-ai-workflow-kit and update the
# current project's AI-Workflow.md, AGENTS.md, and CLAUDE.md.
#
# Auto mode (no args) — run from your project root:
#   • AI-Workflow.md  — created or replaced in full
#   • AGENTS.md       — fenced section updated if markers exist; block appended
#                       if no markers; created from scratch if file absent
#   • CLAUDE.md       — @AI-Workflow.md prepended if missing; created if absent
#
# Single-file mode — update one specific file:
#   ./update-workflow.sh path/to/AGENTS.md
#   ./update-workflow.sh path/to/AI-Workflow.md
#
#   Fenced mode  — file contains <!-- ai-workflow:start/end --> markers;
#                  only that section is replaced, rest of the file untouched.
#   Replace mode — no markers; entire file is replaced.
#
# Requirements: curl, python3

set -euo pipefail

RAW_URL="https://raw.githubusercontent.com/jameswhickmott/github-ai-workflow-kit/main/templates/AI-Workflow.md"
START_MARKER="<!-- ai-workflow:start -->"
END_MARKER="<!-- ai-workflow:end -->"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
err() { echo "Error: $*" >&2; exit 1; }

TMPFILE=$(mktemp)
TMPSWAP=$(mktemp)
trap 'rm -f "$TMPFILE" "$TMPSWAP"' EXIT

# --- Fetch ---
log "Fetching latest AI-Workflow.md..."
curl -fsSL -H "Cache-Control: no-cache" "$RAW_URL" -o "$TMPFILE" || err "failed to fetch $RAW_URL"
log "Fetched $(wc -l < "$TMPFILE" | tr -d ' ') lines."

# --- Replace the fenced section inside a file ---
replace_fenced() {
  local target="$1"
  python3 - "$target" "$START_MARKER" "$END_MARKER" "$TMPFILE" <<'PYEOF'
import sys

target_path, start_marker, end_marker, source_path = sys.argv[1:]

with open(target_path) as f:
    content = f.read()
with open(source_path) as f:
    new_block = f.read().strip()

start_idx = content.find(start_marker)
end_idx   = content.find(end_marker) + len(end_marker)
result    = content[:start_idx] + new_block + content[end_idx:]

with open(target_path, "w") as f:
    f.write(result)
PYEOF
}

# --- Handle AI-Workflow.md ---
update_ai_workflow() {
  cp "$TMPFILE" "AI-Workflow.md"
  log "AI-Workflow.md — written."
}

# --- Handle AGENTS.md ---
update_agents() {
  if [[ -f "AGENTS.md" ]]; then
    if grep -qF "$START_MARKER" "AGENTS.md" && grep -qF "$END_MARKER" "AGENTS.md"; then
      replace_fenced "AGENTS.md"
      log "AGENTS.md — fenced section updated."
    else
      printf "\n" >> "AGENTS.md"
      cat "$TMPFILE" >> "AGENTS.md"
      log "AGENTS.md — workflow block appended (move it to your preferred location if needed)."
    fi
  else
    cp "$TMPFILE" "AGENTS.md"
    log "AGENTS.md — created."
  fi
}

# --- Handle CLAUDE.md ---
update_claude() {
  if [[ -f "CLAUDE.md" ]]; then
    if grep -qF "@AI-Workflow.md" "CLAUDE.md"; then
      log "CLAUDE.md — @AI-Workflow.md already present, skipping."
    else
      printf "@AI-Workflow.md\n\n" | cat - "CLAUDE.md" > "$TMPSWAP"
      mv "$TMPSWAP" "CLAUDE.md"
      log "CLAUDE.md — prepended @AI-Workflow.md."
    fi
  else
    printf "@AI-Workflow.md\n" > "CLAUDE.md"
    log "CLAUDE.md — created."
  fi
}

# --- Main ---
if [[ $# -eq 0 ]]; then
  log "Auto mode — updating AI-Workflow.md, AGENTS.md, and CLAUDE.md in $(pwd)..."
  update_ai_workflow
  update_agents
  update_claude
else
  TARGET="$1"
  [[ -f "$TARGET" ]] || err "target file '$TARGET' not found."

  if grep -qF "$START_MARKER" "$TARGET" && grep -qF "$END_MARKER" "$TARGET"; then
    log "Markers found — updating fenced section in '$TARGET'..."
    replace_fenced "$TARGET"
    log "Done."
  else
    log "No markers — replacing entire file '$TARGET'..."
    cp "$TMPFILE" "$TARGET"
    log "Done."
  fi
fi
