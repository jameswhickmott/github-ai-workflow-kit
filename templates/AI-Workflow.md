<!-- ai-workflow:start -->
# AI Workflow

This repo uses an AI-assisted workflow for issue triage, planning, and development. When the user gives a workflow command, execute it directly using the steps below — do not call external AI tools or APIs.

## Prerequisites

- `gh` CLI authenticated (`gh auth login`)
- Write access to this repo

---

## Commands

### `status`

Print a summary of all open issues grouped by workflow stage.

1. Infer repo: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`
2. Fetch all open issues in one call:
```bash
gh issue list --state open --limit 500 --json number,title,labels
```
3. From the result, group issues into the following stages (an issue belongs to the first matching stage):

| Stage | Condition |
|-------|-----------|
| Unlabelled — needs triage | `labels` is empty |
| `ai:triage` — triage in progress | has label `ai:triage` |
| `human:review-triage` — awaiting triage review | has label `human:review-triage` |
| `ai:plan` — planning in progress | has label `ai:plan` |
| `human:review-plan` — awaiting plan review | has label `human:review-plan` |
| `ai:develop` — development in progress | has label `ai:develop` |
| `pr:created` — PR open | has label `pr:created` |
| `ai:blocked` — blocked | has label `ai:blocked` |

4. Print a summary in this format:

```
## Workflow Status — {owner/repo}

| Stage                              | # | Issues              |
|------------------------------------|---|---------------------|
| Unlabelled (needs triage)          | 2 | #12, #15            |
| ai:triage — in progress            | 1 | #20                 |
| human:review-triage — awaiting     | 0 | —                   |
| ai:plan — in progress              | 1 | #8                  |
| human:review-plan — awaiting       | 0 | —                   |
| ai:develop — in progress           | 2 | #3, #7              |
| pr:created — PR open               | 1 | #5                  |
| ai:blocked — needs intervention    | 0 | —                   |

Total open issues: 7
```

List issue numbers as `#n` links where possible. Omit stages with 0 issues unless all stages are empty.

---

### `triage [issue number]` or `triage all`

**Single issue:**
1. Infer repo: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`
2. Fetch issue: `gh issue view {n} --json title,body`
3. Check label guard: proceed if the issue has `ai:triage` label OR has no labels at all. Skip if it has other labels but not `ai:triage` (unless the user explicitly named this issue).
4. Analyse the issue and produce a triage report in this exact format:

```
## AI Triage Report

**Type:** bug | feature | enhancement | documentation | question | security | maintenance

**Complexity:** trivial | small | medium | large | epic

**Priority:** critical | high | medium | low

**Priority Rationale:** One sentence.

### Summary
One paragraph describing what the issue is asking for.

### Acceptance Criteria
- [ ] Specific, testable criterion
- [ ] (minimum 2, maximum 8)

### Open Questions
Ambiguities or missing context needed before implementation. If none: _None identified._

### Suggested Labels
Labels to apply beyond workflow labels (e.g. `type:bug`, `priority:high`). If none: _None._

### Recommendation
**Decision:** proceed | needs-clarification | reject
**Rationale:** One paragraph.

---
*AI Triage — human review required before proceeding to planning*
```

5. Post the report as a comment with a marker:
```bash
gh issue comment {n} --body "<!-- ai:triage-report -->

{report}"
```
6. Transition labels:
```bash
gh issue edit {n} --remove-label "ai:triage" --add-label "human:review-triage"
```

**`triage all`:** Get all issues needing triage — those with `ai:triage` label plus any with no labels at all:
```bash
# Issues with ai:triage label
gh issue list --label "ai:triage" --state open --json number --jq '.[].number'

# Issues with no labels (unlabelled = needs triage)
gh issue list --state open --json number,labels --jq '[.[] | select(.labels | length == 0) | .number][]'
```
Deduplicate and process each.

---

### `re-triage [issue number]`

Use when a human has answered open questions in comments and triage needs to be revisited.

1. Infer repo: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`
2. Fetch issue with comments:
```bash
gh issue view {n} --json title,body,comments
```
3. Retrieve the previous triage report comment ID and body:
```bash
gh api repos/{repo}/issues/{n}/comments --paginate \
  --jq '[.[] | select(.body | contains("<!-- ai:triage-report -->"))] | last | {id: .id, body: .body}'
```
If no previous triage report exists, stop and tell the user to run `triage` first.

4. Analyse the issue, all comments (including human answers), and the previous triage report. Produce an updated triage report in the same format as `triage`, noting what changed from the previous assessment. For any open questions answered by humans in comments: replace the Open Questions section with `_All resolved — see human responses below:_` followed by each original question (strikethrough) and the human's answer in bold (format: `- ~~Original question?~~ → **Human answer**`). If all open questions are resolved, omit the original open questions list. If no open questions were present or none are answered, retain the original Open Questions section or use `_None identified._` as applicable.

5. Mark the old triage comment as outdated:
```bash
gh api repos/{repo}/issues/comments/{prev_comment_id} --method PATCH \
  -f body="<!-- ai:triage-report:outdated -->

> ⚠️ **Outdated** — superseded by retriage. See the updated report below."
```

6. Post the updated report as a new comment:
```bash
gh issue comment {n} --body "<!-- ai:triage-report -->

{report}"
```
7. Transition labels:
```bash
gh issue edit {n} --add-label "human:review-triage"
```

---

### `plan [issue number]` or `plan all`

**Single issue:**
1. Fetch issue: `gh issue view {n} --json title,body`
2. Retrieve the triage report: find the comment containing `<!-- ai:triage-report -->` via:
```bash
gh api repos/{repo}/issues/{n}/comments --paginate \
  --jq '[.[] | select(.body | contains("<!-- ai:triage-report -->"))] | last | .body'
```
If no triage report exists, stop and tell the user triage must be completed first.

3. Analyse the issue and triage report, then produce an implementation plan in this exact format:

```
## AI Implementation Plan

### Approach
2–4 sentences on the overall technical approach and key design decisions.

### Files to Create
| File Path | Purpose |
|-----------|---------|
| `path/to/file` | What it contains and why |

If none: _None._

### Files to Modify
| File Path | Changes Required |
|-----------|-----------------|
| `path/to/file` | Exactly what changes are needed |

### Implementation Steps
Numbered, sequential, each independently completable.
1. Step
2. Step

### Test Strategy
- **Unit tests:** what to test and how
- **Integration tests:** scenarios
- **Manual verification:** steps a reviewer can follow

### Edge Cases and Risks
- **Risk:** how to handle it. If none: _None identified._

### Dependencies
External libraries or services involved. If none: _None._

### Migration Notes
DB migrations, config changes, breaking changes. If none: _None._

### Definition of Done
- [ ] All implementation steps completed
- [ ] All new and existing tests pass
- [ ] Edge cases handled

### Estimated Complexity
trivial | small | medium | large

---
*AI Implementation Plan — human review required before development begins*
```

4. Post the plan as a comment with a marker:
```bash
gh issue comment {n} --body "<!-- ai:plan-report -->

{plan}"
```
5. Transition labels:
```bash
gh issue edit {n} --remove-label "ai:plan" --add-label "human:review-plan"
```

**`plan all`:** Run `gh issue list --label "ai:plan" --state open --json number --jq '.[].number'` then process each.

---

### `develop [issue number]` or `develop all`

**Single issue:**
1. Fetch issue: `gh issue view {n} --json title,body`
2. Retrieve the plan report: find the comment containing `<!-- ai:plan-report -->` (same API call as above). If missing, stop and tell the user planning must be completed first.
3. Get default branch: `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'`
4. Create and switch to branch:
```bash
git checkout -b ai/issue-{n}
```
5. Implement the plan — follow exactly the files listed in "Files to Create" and "Files to Modify". Match the existing code style. Do not modify files outside the plan scope. Do not touch secrets, CI/CD config, or deployment infrastructure unless the plan explicitly requires it. Implement all tests from the Test Strategy section.
6. Commit:
```bash
git add -A
git commit -m "feat: AI implementation for issue #{n}

{issue title}

Co-authored-by: AI Workflow Bot <ai-workflow@noreply.github.com>"
```
7. Push:
```bash
git push origin ai/issue-{n}
```
8. Create PR:
```bash
gh pr create \
  --title "feat: issue #{n} - {issue title}" \
  --body "Closes #{n}

## Summary
AI-generated implementation for: **{issue title}**

<details>
<summary>Approved Plan</summary>

{plan report}

</details>

---
*Human review and approval required before merging.*
<!-- ai:pr-report -->" \
  --head "ai/issue-{n}" \
  --base "{default branch}"
```
9. Transition labels and post a comment:
```bash
gh issue edit {n} --remove-label "ai:develop" --add-label "pr:created"
gh issue comment {n} --body "## AI Development Complete

PR created: {pr url}
Branch: \`ai/issue-{n}\`

Human review required before merging."
```

**`develop all`:** Run `gh issue list --label "ai:develop" --state open --json number --jq '.[].number'` then process each.

---

## Workflow state machine

```
ai:triage → human:review-triage → ai:plan → human:review-plan → ai:develop → pr:created
```

Human approval is required at every stage transition. AI must not merge PRs.

## Labels reference

| Label | Set by | Meaning |
|-------|--------|---------|
| `ai:triage` | Human | Triggers triage |
| `human:review-triage` | AI | Awaiting human review of triage |
| `ai:plan` | Human | Triggers planning |
| `human:review-plan` | AI | Awaiting human review of plan |
| `ai:develop` | Human | Triggers development |
| `pr:created` | AI | PR opened |
| `ai:blocked` | AI | Failed — human intervention needed |
<!-- ai-workflow:end -->
