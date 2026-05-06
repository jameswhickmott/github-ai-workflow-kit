

# AI Workflow (Agent Contract)

This file is the **minimal, token-efficient contract** the AI must follow. The detailed human runbook (full bash snippets, troubleshooting, examples) is in `docs/ai-workflow-runbook.md`.

## Non‑negotiable invariants

- **No chat-initiated changes without an issue**: if a user asks for any repo change, first create a GitHub issue and label it `ai:triage`.
- **Human approval gates**: do not proceed across stage boundaries without human approval.
- **AI must never merge PRs**.
- **Stay within scope**: during development, change only what’s in the approved plan.
- **On failure**: if a step can’t be recovered quickly, label the issue `ai:blocked` and comment with what failed + the next action.

## Workflow state machine (labels)

```
ai:triage → human:review-triage → ai:plan → human:review-plan → ai:develop → pr:created → ai:review → human:final-review
```

If triage recommendation is **reject**, transition to `human:review-close` instead of `human:review-triage`.

## Required labels

`ai:triage`, `human:review-triage`, `ai:plan`, `human:review-plan`, `ai:develop`, `pr:created`, `ai:review`, `human:final-review`, `human:review-close`, `ai:blocked`

## Required comment markers (update in-place when possible)

- `<!-- ai:triage-report -->`
- `<!-- ai:plan-report -->`
- `<!-- ai:pr-report -->`
- `<!-- ai:pr-review-report -->`
- Outdated marker: `<!-- ai:*:outdated -->` (superseded reports must be marked outdated)

## Batch safety

- For any `* all` operation, process **max 5 items** unless the user explicitly requests more.

## Commands (behavioral spec)

### `setup`

- Ensure `gh` is authenticated and required labels exist.
- Refuse to proceed if git working tree is not clean.

### `create-issue` (mandatory for chat requests)

- Search for likely duplicates; if likely duplicate, ask the human whether to cancel.
- Create issue labeled `ai:triage`, then immediately run `triage` for it.

### `status`

- Summarize open issues grouped by the first matching workflow stage label.

### `triage {issue}` / `retriage {issue}`

- Produce an **AI Triage Report** (format below) and post it using `<!-- ai:triage-report -->`.
- Transition labels:
  - If any prerequisite issue **blocks this issue** → label `ai:blocked` and comment blockers.
  - Else if recommendation is `reject` → label `human:review-close`.
  - Else → label `human:review-triage`.
- `retriage` must supersede the previous report (mark old report outdated, then post updated report).

### `plan {issue}` / `replan {issue}`

- Preconditions:
  - Issue must not be `ai:blocked`.
  - A triage report must exist.
- Produce an **AI Implementation Plan** (format below) and post it using `<!-- ai:plan-report -->`.
- Transition to `human:review-plan`.
- `replan` must supersede the previous plan (mark old plan outdated, then post updated plan).

### `develop {issue}`

- Preconditions:
  - Issue must not be `ai:blocked`.
  - An approved plan exists (issue in/after `human:review-plan` stage and explicitly approved by human).
  - Git working tree must be clean; repo must be up to date with default branch.
- Create branch `ai/issue-{n}-{slug}`.
- Implement strictly per the approved plan (files + tests).
- Run tests (best-effort based on repo conventions).
- Commit, push, open PR that **closes the issue**, and label issue `pr:created`.
- Include the approved plan in the PR body (or link to the plan comment).

### `review-pr {pr}`

- Verify checks status.
- Review changes against approved plan.
- Post **AI PR Review Report** (format below) using `<!-- ai:pr-review-report -->`.
- Transition PR to `human:final-review`.
- If checks failed or review decision is `block`, label linked issue `ai:blocked`.

### `work {issue}` (guided)

- Run triage → pause for explicit human **approve** → plan → pause for **approve** → develop → review-pr.
- If the user says `stop`/`pause`, halt immediately without trying to “clean up” state.

### `unblock {issue}`

- Only valid if issue has `ai:blocked`.
- Remove `ai:blocked` and move it to the next stage inferred from the latest AI report present (triage/plan/pr-review), then comment that it’s unblocked.

## Report formats (must match)

### AI Triage Report

```
## AI Triage Report

**Type:** bug | feature | enhancement | documentation | question | security | maintenance
**Complexity:** trivial | small | medium | large | epic
**Priority:** critical | high | medium | low
**Priority Rationale:** One sentence.

### Summary
One paragraph.

### Acceptance Criteria
- [ ] 2–8 specific, testable items.

### Open Questions
If none: _None identified._

### Related Issues
If none: _None identified._

### Recommendation
**Decision:** proceed | needs-clarification | reject
**Rationale:** One paragraph.

---
*AI Triage — human review required before proceeding to planning*
```

### AI Implementation Plan

```
## AI Implementation Plan

### Approach
2–4 sentences.

### Files to Create
If none: _None._

### Files to Modify
If none: _None._

### Implementation Steps
Numbered, sequential.

### Test Strategy
- **Unit tests:** …
- **Integration tests:** …
- **Manual verification:** …

### Edge Cases and Risks
If none: _None identified._

### Dependencies
If none: _None._

### Migration Notes
If none: _None._

### Definition of Done
- [ ] …

### Estimated Complexity
trivial | small | medium | large

---
*AI Implementation Plan — human review required before development begins*
```

### AI PR Review Report

```
## AI PR Review Report

### PR Check Status
Summarize pass/fail/pending.

### Code Review
2–4 sentences (plan adherence).

### Feedback
- If any.

### Recommendation
**Decision:** approve | request-changes | block
**Rationale:** One paragraph.

---
*AI PR Review — human final review required. AI must not merge PRs.*
```

