<!-- ai-workflow:start -->
# AI Workflow

This repo uses an AI-assisted workflow for issue triage, planning, and development. When the user gives a workflow command, execute it directly using the steps below — do not call external AI tools or APIs.

## Prerequisites

- `gh` CLI authenticated (`gh auth login`)
- Write access to this repo

---

## Chat-Initiated Changes

**Any change requested during a chat conversation must be captured as a GitHub issue before implementation begins.** This applies to all changes regardless of size — bug fixes, features, refactors, documentation updates, or configuration changes.

When a user asks for a change during chat:
1. Run `create-issue` to capture the request as a GitHub issue and label it `ai:triage`
2. Run `triage` on the new issue immediately
3. Do not implement anything until the human approves triage and the workflow proceeds through planning and development

This ensures all changes are tracked, reviewed, and implemented consistently through the workflow.

---

## Commands

### Error Handling
When executing `gh` or `git` commands, handle common failures:
- **`gh` auth errors**: Prompt user to authenticate with `gh auth login`
- **GitHub rate limits**: Wait 1-2 minutes and retry, or check remaining limits with `gh api rate_limit`
- **Missing workflow labels**: Ensure the repo has all required labels: `ai:triage`, `human:review-triage`, `ai:plan`, `human:review-plan`, `ai:develop`, `pr:created`, `ai:blocked`, `ai:review`, `human:final-review`, `human:review-close`. Create missing labels with `gh label create`
- **Label remove errors**: If `gh issue edit --remove-label` fails (label not present), append `|| true` to ignore the error
- **Git branch conflicts**: If `git checkout -b` fails because the branch exists, use `git checkout -B` to reset it (as done in `develop` command)
- **Irrecoverable failures**: If a workflow step fails and cannot be resolved, set the `ai:blocked` label on the issue and post a comment with error details
- **Duplicate comment prevention**: For all commands (`triage`, `retriage`, `plan`, `replan`), update the existing `<!-- ai:triage-report -->` / `<!-- ai:plan-report -->` comment if present, instead of creating a new one. `retriage` updates triage reports, `replan` updates plan reports.
- **Batch limits**: For `triage all`, `plan all`, `develop all`, `review-pr all`, process a maximum of 5 items at a time unless the user explicitly requests a higher limit.

---

### `setup`

Initialize the repository for AI workflow. Run this once before using other commands.

1. Infer repo: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`
2. Verify `gh` authentication:
```bash
gh auth status
```
If auth fails, prompt user to run `gh auth login`.
3. Create all required workflow labels (skip existing):
```bash
labels=("ai:triage" "human:review-triage" "ai:plan" "human:review-plan" "ai:develop" "pr:created" "ai:blocked" "ai:review" "human:final-review" "human:review-close")
for label in "${labels[@]}"; do
  gh label create "$label" --repo {repo} 2>/dev/null || true
done
```
4. Verify clean git state:
```bash
git status --short
```
If there are uncommitted changes, warn the user and stop.
5. Verify git remote:
```bash
git remote -v
```
Ensure `origin` points to the correct GitHub repo.
6. Verify default branch:
```bash
gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'
```
7. Print success message: "✅ Workflow setup complete. All labels created, gh authenticated, git state clean."

---

### `create-issue`

Use whenever a change is requested during a chat conversation. Creates a GitHub issue capturing the request and immediately enters the triage workflow. **Do not implement any change without first creating an issue.**

1. Infer repo: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`
2. Derive a concise issue title (max 72 chars) and a body from the user's request. The body should include:
   - **What was requested** — a clear description of the change
   - **Context from chat** — any relevant details the user provided
   - **Source** — note that this issue was created from a chat request
3. Create the issue with the `ai:triage` label:
```bash
issue_url=$(gh issue create \
  --title "{title}" \
  --body "{body}

---
*Created from chat request — entering AI workflow.*" \
  --label "ai:triage" \
  --repo {repo} \
  --json url --jq '.url')
issue_number=$(gh issue list --label "ai:triage" --limit 1 --json number --jq '.[0].number')
echo "Created issue #${issue_number}: ${issue_url}"
```
4. Immediately run the `triage` command on the new issue number.
5. Inform the user:
   - Issue number and URL
   - That triage has been completed and is awaiting their review
   - That implementation will not begin until they approve the triage report and plan

---

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
| `human:review-close` — awaiting close/reject review | has label `human:review-close` |
| `ai:plan` — planning in progress | has label `ai:plan` |
| `human:review-plan` — awaiting plan review | has label `human:review-plan` |
| `ai:develop` — development in progress | has label `ai:develop` |
| `pr:created` — PR open | has label `pr:created` |
| `ai:review` — PR review in progress | has label `ai:review` |
| `human:final-review` — awaiting final PR review | has label `human:final-review` |
| `ai:blocked` — blocked | has label `ai:blocked` |

4. Print a summary in this format:

```
## Workflow Status — {owner/repo}

| Stage                              | # | Issues              |
|------------------------------------|---|---------------------|
| Unlabelled (needs triage)          | 2 | #12, #15            |
| ai:triage — in progress            | 1 | #20                 |
| human:review-triage — awaiting     | 0 | —                   |
| human:review-close — awaiting      | 0 | —                   |
| ai:plan — in progress              | 1 | #8                  |
| human:review-plan — awaiting       | 0 | —                   |
| ai:develop — in progress           | 2 | #3, #7              |
| pr:created — PR open               | 1 | #5                  |
| ai:review — in progress            | 0 | —                   |
| human:final-review — awaiting      | 0 | —                   |
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

5. Check for existing active triage report comment and post/update:
```bash
# Check for existing non-outdated triage report
existing_comment=$(gh api repos/{repo}/issues/{n}/comments --paginate \
  --jq '[.[] | select(.body | contains("<!-- ai:triage-report -->") and (contains("outdated") | not))] | last | .id')
if [ -n "$existing_comment" ]; then
  # Update existing comment
  gh api repos/{repo}/issues/comments/${existing_comment} --method PATCH \
    -f body="<!-- ai:triage-report -->

{report}"
else
  # Post new comment
  gh issue comment {n} --body "<!-- ai:triage-report -->

{report}"
fi
```

6. Transition labels based on triage recommendation:
```bash
# Extract recommendation decision from report
decision=$(echo "{report}" | grep -A1 "**Decision:**" | tail -1 | tr -d ' ')
if [ "$decision" = "reject" ]; then
  gh issue edit {n} --remove-label "ai:triage" --add-label "human:review-close"
else
  gh issue edit {n} --remove-label "ai:triage" --add-label "human:review-triage"
fi
```

**`triage all`:** Get all issues needing triage — those with `ai:triage` label plus any with no labels at all:
```bash
# Issues with ai:triage label
gh issue list --label "ai:triage" --state open --json number --jq '.[].number'

# Issues with no labels (unlabelled = needs triage)
gh issue list --state open --json number,labels --jq '[.[] | select(.labels | length == 0) | .number][]'
```
Deduplicate and process each. Process a maximum of 3 issues at a time unless the user explicitly requests more.

---

### `retriage [issue number]` (also `re-triage`)

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

4. Check for existing active plan report comment and post/update:
```bash
# Check for existing non-outdated plan report
existing_comment=$(gh api repos/{repo}/issues/{n}/comments --paginate \
  --jq '[.[] | select(.body | contains("<!-- ai:plan-report -->") and (contains("outdated") | not))] | last | .id')
if [ -n "$existing_comment" ]; then
  # Update existing comment
  gh api repos/{repo}/issues/comments/${existing_comment} --method PATCH \
    -f body="<!-- ai:plan-report -->

{plan}"
else
  # Post new comment
  gh issue comment {n} --body "<!-- ai:plan-report -->

{plan}"
fi
```

5. Transition labels:
```bash
gh issue edit {n} --remove-label "ai:plan" --add-label "human:review-plan"
```

**`plan all`:** Run `gh issue list --label "ai:plan" --state open --json number --jq '.[].number'` then process each. Process a maximum of 3 issues at a time unless the user explicitly requests more.

---

### `replan [issue number]` (also `re-plan`)

Use when a human has provided feedback on a plan and the plan needs to be updated.

1. Infer repo: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`
2. Fetch issue with comments:
```bash
gh issue view {n} --json title,body,comments
```
3. Retrieve the previous plan report comment ID and body:
```bash
gh api repos/{repo}/issues/{n}/comments --paginate \
  --jq '[.[] | select(.body | contains("<!-- ai:plan-report -->"))] | last | {id: .id, body: .body}'
```
If no previous plan report exists, stop and tell the user to run `plan` first.

4. Analyse the issue, all comments (including human feedback), and the previous plan report. Produce an updated plan report in the same format as `plan`, noting what changed from the previous assessment. Address any human feedback or open questions in the updated plan.

5. Mark the old plan comment as outdated:
```bash
gh api repos/{repo}/issues/comments/{prev_comment_id} --method PATCH \
  -f body="<!-- ai:plan-report:outdated -->

> ⚠️ **Outdated** — superseded by re-plan. See the updated report below."
```

6. Post the updated plan as a new comment:
```bash
gh issue comment {n} --body "<!-- ai:plan-report -->

{plan}"
```
7. Transition labels (ensure it is still awaiting human review):
```bash
gh issue edit {n} --add-label "human:review-plan"
```

---

### `develop [issue number]` or `develop all`

**Single issue:**
1. Fetch issue: `gh issue view {n} --json title,body`
2. Retrieve the plan report: find the comment containing `<!-- ai:plan-report -->` (same API call as above). If missing, stop and tell the user planning must be completed first.
3. Get default branch: `gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name'`
4. Sync with remote default branch:
```bash
git status --short
if [ -n "$(git status --short)" ]; then
  echo "Error: Uncommitted changes present. Clean git state required."
  exit 1
fi
git fetch origin
git checkout {default_branch}
git pull --ff-only
if [ $? -ne 0 ]; then
  echo "Error: Failed to fast-forward pull default branch. Resolve conflicts first."
  exit 1
fi
```
5. Generate branch name with slug:
```bash
slug=$(echo "{issue title}" | tr '[:upper:]' '[:lower:]' | tr -s ' ' '-' | tr -cd 'a-z0-9-' | cut -c1-20)
branch="ai/issue-{n}-${slug}"
git checkout -B "${branch}"
```
6. Implement the plan — follow exactly the files listed in "Files to Create" and "Files to Modify". Match the existing code style. Do not modify files outside the plan scope. Do not touch secrets, CI/CD config, or deployment infrastructure unless the plan explicitly requires it. Implement all tests from the Test Strategy section.
7. Run tests:
```bash
# Detect test command
test_cmd=""
if [ -f "package.json" ]; then
  test_cmd=$(node -e "try { console.log(JSON.parse(require('fs').readFileSync('package.json')).scripts.test) } catch(e) { process.exit(0) }")
elif [ -f "pytest.ini" ] || [ -f "pyproject.toml" ]; then
  test_cmd="pytest"
elif [ -f "composer.json" ]; then
  test_cmd="composer test"
fi

if [ -n "$test_cmd" ]; then
  echo "Running tests: $test_cmd"
  $test_cmd
  if [ $? -ne 0 ]; then
    gh issue edit {n} --add-label "ai:blocked"
    gh issue comment {n} --body "## Tests Failed

AI implementation for issue #{n} failed tests. Blocking issue."
    exit 1
  fi
fi
```
8. Commit:
```bash
git add -A
git commit -m "feat: AI implementation for issue #{n}

{issue title}

Co-authored-by: AI Workflow Bot <ai-workflow@noreply.github.com>"
```
9. Push:
```bash
git push origin "${branch}"
```
10. Create PR:
```bash
pr_url=$(gh pr create \
  --title "feat: issue #{n} - {issue title}" \
  --body "Closes #{n}

## Summary
AI-generated implementation for: **{issue title}**

<details>
<summary>Approved Plan</summary>

{plan report}

</details>

---
*Human review and approval required before merging. AI must not merge this PR.*
<!-- ai:pr-report -->" \
  --head "${branch}" \
  --base "{default branch}" --json url --jq '.url')
```
11. Check PR status:
```bash
pr_number=$(gh pr view --head "${branch}" --json number --jq '.number')
gh pr checks ${pr_number}
checks_status=$(gh pr checks ${pr_number} --json state --jq '[.[] | .state] | unique | .[]')
if echo "$checks_status" | grep -q "pending"; then
  gh issue comment {n} --body "## PR Checks Pending

PR #{pr_number} has pending checks. Waiting for completion."
elif echo "$checks_status" | grep -q "fail"; then
  gh issue edit {n} --add-label "ai:blocked"
  gh issue comment {n} --body "## PR Checks Failed

PR #{pr_number} has failed checks. Blocking issue."
fi
```
12. Transition labels and post a comment:
```bash
gh issue edit {n} --remove-label "ai:develop" --add-label "pr:created"
gh issue comment {n} --body "## AI Development Complete

PR created: ${pr_url}
Branch: \`${branch}\`

Human review required before merging. AI must not merge this PR."
```

**`develop all`:** Run `gh issue list --label "ai:develop" --state open --json number --jq '.[].number'` then process each. Process a maximum of 3 issues at a time unless the user explicitly requests more.

---

### `review-pr [pr number]` or `review-pr all`

**Single PR:**
1. Infer repo: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`
2. Fetch PR: `gh pr view {n} --json title,body,headRefName,baseRefName,reviews,linkedIssues`
3. Check label guard: proceed if the PR has `pr:created` or `ai:review` label. Skip if it has other labels without user explicit request.
4. Retrieve linked issue's plan report: find `<!-- ai:plan-report -->` in linked issue comments.
5. Run PR checks:
```bash
gh pr checks {n}
```
6. Review the PR code against the plan, check results, and produce a review report in this exact format:

```
## AI PR Review Report

### PR Check Status
| Check | Status |
|-------|--------|
| {check name} | pass | fail | pending |

### Code Review
2–4 sentences on how well the implementation matches the approved plan.

### Feedback
- Specific feedback points, if any.

### Recommendation
**Decision:** approve | request-changes | block
**Rationale:** One paragraph.

---
*AI PR Review — human final review required. AI must not merge PRs.*
```

7. Post the report as a comment with a marker:
```bash
gh pr comment {n} --body "<!-- ai:pr-review-report -->

{report}"
```
8. Transition labels:
```bash
gh pr edit {n} --remove-label "pr:created" --remove-label "ai:review" --add-label "human:final-review"
if [ "{recommendation_decision}" = "block" ]; then
  gh issue edit {linked_issue_number} --add-label "ai:blocked"
fi
```
9. If checks failed, add `ai:blocked` label to linked issue.

**`review-pr all`:** Run `gh pr list --label "pr:created" --state open --json number --jq '.[].number'` then process each. Process a maximum of 3 PRs at a time unless the user explicitly requests more.

---

### `work [issue number]`

Interactive single-issue guided workflow. Runs each stage in sequence within the current chat session, pausing for human approval at every stage boundary. All GitHub label updates and comments are written at each step — if the session ends, the issue is in a consistent state and can be resumed with individual commands (`plan`, `develop`, etc.).

**Stage 1 — Triage:**
1. Run the full `triage` command on the issue (posts report comment, updates labels on GitHub as normal).
2. Display the triage report in chat.
3. If the recommendation is `reject`: ask the user to type `confirm-reject` to accept (they must close the issue on GitHub manually), or provide feedback to revise.
4. Otherwise ask: _"Triage complete — type **approve** to proceed to planning, or reply with feedback to revise."_
   - `approve` → proceed to Stage 2
   - Any other text → treat as triage feedback, incorporate it and run `retriage` with the feedback folded in, then loop back to step 2

**Stage 2 — Planning:**
1. Transition labels on GitHub as a human approver would: remove `human:review-triage`, add `ai:plan`.
2. Run the full `plan` command (posts plan comment, updates labels on GitHub as normal).
3. Display the plan in chat.
4. Ask: _"Plan complete — type **approve** to proceed to development, or reply with feedback to revise."_
   - `approve` → proceed to Stage 3
   - Any other text → treat as plan feedback, incorporate it and run `replan` with the feedback folded in, then loop back to step 3

**Stage 3 — Development:**
1. Transition labels on GitHub: remove `human:review-plan`, add `ai:develop`.
2. Run the full `develop` command (creates branch, implements, commits, pushes, opens PR on GitHub as normal).
3. Run `review-pr` on the new PR.
4. Display the PR URL and AI review report in chat.
5. Inform the user: _"PR created and AI-reviewed. Merging requires your manual approval on GitHub — AI cannot merge."_

**Session rules:**
- At any point, if the user types `stop` or `pause`, halt immediately and leave GitHub in its current label state.
- Open questions from triage can be answered directly in chat — the answer is folded into `retriage` rather than requiring a GitHub comment.
- All GitHub writes happen immediately at each step, so state is always recoverable.

---

### `unblock [issue number]`

Use when a blocked issue has been resolved and work can resume.

1. Infer repo: `gh repo view --json nameWithOwner --jq '.nameWithOwner'`
2. Fetch issue: `gh issue view {n} --json title,body,labels`
3. Verify the issue has the `ai:blocked` label. If not, stop and inform the user.
4. Remove the blocked label and determine the correct next stage based on the issue's last completed step (check comments for the last AI report):
   - If triage was completed but not yet planned: `--remove-label "ai:blocked" --add-label "ai:plan"`
   - If planning was completed but not yet developed: `--remove-label "ai:blocked" --add-label "ai:develop"`
   - If PR was created but not yet reviewed: `--remove-label "ai:blocked" --add-label "ai:review"`
   - If no previous AI work: `--remove-label "ai:blocked" --add-label "ai:triage"`
5. Post a comment:
```bash
gh issue comment {n} --body "## Issue Unblocked

Blocker resolved. Issue moved to appropriate workflow stage for continued processing."
```

---

## Workflow state machine

```
ai:triage → human:review-triage → ai:plan → human:review-plan → ai:develop → pr:created → ai:review → human:final-review
```

If triage decision is `reject`, issue moves to `human:review-close` instead of `human:review-triage`.

Human approval is required at every stage transition. AI must not merge PRs.

### Human approval transitions
After reviewing AI work, humans should manually update labels to trigger the next stage:
- **Approve triage**: Remove `human:review-triage`, add `ai:plan`
- **Request triage changes**: Remove `human:review-triage`, re-add `ai:triage` (or leave for `re-triage`)
- **Approve triage (reject)**: Remove `human:review-close`, close issue (if approved to reject)
- **Request triage changes (reject)**: Remove `human:review-close`, re-add `ai:triage`
- **Approve plan**: Remove `human:review-plan`, add `ai:develop`
- **Request plan changes**: Remove `human:review-plan`, re-add `ai:plan` (or leave for `re-plan`)
- **Approve PR review**: Remove `human:final-review`, merge (human only, AI must not merge)
- **Request PR changes**: Remove `human:final-review`, re-add `ai:review`
- **Blocked**: If human intervention is needed, add `ai:blocked` label

### AI Merge Prohibition
AI must never merge pull requests. This rule is enforced in `develop` and `review-pr` commands. Merging is only permitted by human users after final review.

## Labels reference

| Label | Set by | Meaning |
|-------|--------|---------|
| `ai:triage` | Human | Triggers triage |
| `human:review-triage` | AI | Awaiting human review of triage |
| `ai:plan` | Human | Triggers planning |
| `human:review-plan` | AI | Awaiting human review of plan |
| `ai:develop` | Human | Triggers development |
| `pr:created` | AI | PR opened |
| `ai:review` | AI | PR review in progress |
| `human:final-review` | AI | Awaiting human final PR review |
| `human:review-close` | AI | Awaiting human review of rejected issue |
| `ai:blocked` | AI | Failed — human intervention needed |
<!-- ai-workflow:end -->