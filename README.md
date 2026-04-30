# github-ai-workflow-kit

A reusable AI-assisted GitHub development workflow system. Target repositories call the workflows in this repo to get AI triage, planning, and development — orchestrated through GitHub labels with mandatory human approval gates at every stage.

**AI triages. AI plans. AI codes. Humans review and merge. Always.**

---

## How it works

Issues progress through a label-driven state machine. Labels are the source of truth — no workflow state is stored anywhere else.

```
Issue opened
     │
     ▼ (issue form auto-applies, or human adds manually)
 ┌─────────┐
 │ai:triage│  ← AI analyzes issue, posts structured triage report
 └────┬────┘
      │ AI removes ai:triage, adds human:review-triage
      ▼
 ┌──────────────────┐
 │human:review-triage│  ← Human reads triage. Approves, blocks, or closes.
 └────────┬─────────┘
          │ Human removes human:review-triage, adds ai:plan
          ▼
 ┌────────┐
 │ ai:plan│  ← AI analyzes repo, produces detailed implementation plan
 └────┬───┘
      │ AI removes ai:plan, adds human:review-plan
      ▼
 ┌─────────────────┐
 │human:review-plan│  ← Human reads plan. Approves or blocks.
 └────────┬────────┘
          │ Human removes human:review-plan, adds ai:develop
          ▼
 ┌──────────┐
 │ai:develop│  ← AI creates branch, implements plan, opens PR
 └─────┬────┘
       │ AI removes ai:develop, adds pr:created
       ▼
 ┌──────────┐
 │pr:created│  ← Human reviews PR and merges (AI must not self-merge)
 └──────────┘
```

If anything goes wrong at any AI stage, `ai:blocked` is applied and a comment explains why. Human removes the block and re-adds the appropriate `ai:*` label to retry.

---

## Onboarding a target repository

### Step 1 — Bootstrap labels

Run once per target repo. Idempotent — safe to re-run.

```bash
# Authenticate gh CLI first: gh auth login
./scripts/bootstrap-labels.sh owner/your-repo
```

This creates all 17 required labels (workflow state, priority, type).

### Step 2 — Add the config file

Copy [templates/ai-workflow.yml](templates/ai-workflow.yml) to `.github/ai-workflow.yml` in the target repo and fill it in:

```yaml
ai_provider: claude            # claude | openai | codex | aider
max_issues_per_run: 3
project_context: "A Node.js API serving a React dashboard."
tech_stack: "TypeScript, Node.js, PostgreSQL, Jest"
test_command: npm test
lint_command: npm run lint
```

### Step 3 — Add the issue form

Copy [templates/issue-form.yml](templates/issue-form.yml) to `.github/ISSUE_TEMPLATE/ai-task.yml`.

Submitting this form automatically applies `ai:triage`, which triggers the triage workflow.

### Step 4 — Add the wrapper workflows

Copy all three wrapper files and replace `YOUR_ORG` with your GitHub organisation name:

```bash
# From the target repo root:
cp path/to/workflow-kit/templates/wrapper-triage.yml  .github/workflows/ai-triage.yml
cp path/to/workflow-kit/templates/wrapper-plan.yml    .github/workflows/ai-plan.yml
cp path/to/workflow-kit/templates/wrapper-develop.yml .github/workflows/ai-develop.yml

# Replace the placeholder in all three files:
sed -i 's/YOUR_ORG/your-actual-org/g' .github/workflows/ai-*.yml
```

### Step 5 — Add secrets

Add these secrets to the target repo under **Settings → Secrets and variables → Actions**:

| Secret | Required | Purpose |
|--------|----------|---------|
| `GH_PAT` | Always | Push branches, create PRs, call private workflow-kit |
| `ANTHROPIC_API_KEY` | If `ai_provider: claude` | Claude API |
| `OPENAI_API_KEY` | If `ai_provider: openai \| codex \| aider` | OpenAI API |

The `GH_PAT` must belong to a user (or machine account) with **write access** to the target repo. Required scopes: `repo` for private repos, `public_repo` for public repos.

---

## Configuration reference

All fields in `.github/ai-workflow.yml` are optional. Defaults apply when omitted.

| Key | Default | Description |
|-----|---------|-------------|
| `ai_provider` | `claude` | AI provider: `claude`, `openai`, `codex`, `aider` |
| `openai_model` | `gpt-4o` | OpenAI model (ignored for claude) |
| `max_issues_per_run` | `3` | Max issues processed per queue run |
| `project_context` | _(empty)_ | Project description injected into all prompts |
| `tech_stack` | _(empty)_ | Tech stack injected into planning and develop prompts |
| `test_command` | _(empty)_ | Run after AI development (non-fatal if fails) |
| `build_command` | _(empty)_ | Run after AI development (non-fatal if fails) |
| `lint_command` | _(empty)_ | Run after AI development (non-fatal if fails) |

---

## AI provider setup

### Claude (default)

Requires `ANTHROPIC_API_KEY`. The [Claude Code CLI](https://docs.anthropic.com/claude-code) is installed at runtime.

```yaml
ai_provider: claude
```

### OpenAI

Uses the OpenAI chat completions API via `curl` (no extra tooling needed) for triage and planning. Uses `aider` for code generation during development.

```yaml
ai_provider: openai
openai_model: gpt-4o   # or gpt-4-turbo, o1, etc.
```

Requires `OPENAI_API_KEY`.

### Aider

Uses `aider` for all stages (falls back to OpenAI API for text-only queries).

```yaml
ai_provider: aider
openai_model: gpt-4o
```

Requires `OPENAI_API_KEY`.

### Codex

Uses the [OpenAI Codex CLI](https://github.com/openai/codex) for development.

```yaml
ai_provider: codex
```

Requires `OPENAI_API_KEY`.

---

## Triggering stages manually

Every stage can be triggered by a comment on the issue in addition to the label mechanism:

| Comment | Effect |
|---------|--------|
| `/ai triage` | Re-runs triage (useful if issue was updated) |
| `/ai plan` | Re-runs planning |
| `/ai develop` | Re-runs development |

The develop workflow can also be triggered manually via **Actions → AI Develop → Run workflow** with an optional issue number. Leave the issue number blank to run in queue mode.

---

## Queue processing

The develop workflow supports processing multiple issues in a single run without manual intervention.

When triggered by schedule or manual dispatch (no issue number), it:

1. Fetches all open issues labelled `ai:develop`
2. Processes them sequentially (one at a time, never concurrent)
3. Skips any issue that already has an open PR or branch (`ai/issue-N`)
4. On per-issue failure: applies `ai:blocked`, comments the reason, moves to next issue
5. Stops only on infrastructure-level failure

Configure the maximum batch size in `.github/ai-workflow.yml`:

```yaml
max_issues_per_run: 5
```

The scheduled cron in `wrapper-develop.yml` defaults to every 4 hours. Adjust or remove it as needed.

---

## Branch and PR conventions

| Convention | Value |
|------------|-------|
| Branch name | `ai/issue-{number}` |
| PR title | `feat: issue #{number} - {title}` |
| PR body | Always includes `Closes #{number}` |

The `Closes #N` keyword automatically links the PR to the issue and closes it on merge.

---

## Security

### Human approval is mandatory

AI progresses through the state machine only when a human manually changes labels:

- `human:review-triage` → `ai:plan` requires a human
- `human:review-plan` → `ai:develop` requires a human

There is no automated path from triage to implementation.

### AI must not merge

AI opens PRs. It does not approve them, does not merge them, and does not have the ability to trigger merges. Only humans merge.

Consider enabling [branch protection rules](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches) requiring at least one human review before merging.

### Minimal permissions

Each workflow stage requests only the permissions it needs:

| Stage | Permissions |
|-------|-------------|
| Triage / Plan | `contents: read`, `issues: write` |
| Develop | `contents: write`, `issues: write`, `pull-requests: write` |

### Prompt injection

Issue body content is inserted into AI prompts. A crafted issue could attempt to override AI instructions. The prompts in `prompts/` are structured so that user-supplied content appears after the system instructions, which reduces (but does not eliminate) injection risk.

Mitigations:
- Human review gates catch suspicious AI output before it reaches code
- The AI has no ability to merge or deploy — even a fully successful injection can only produce a PR for a human to reject

### No secrets in this repository

This repo contains no credentials. All secrets (`GH_PAT`, API keys) live in the target repositories and are never stored here.

---

## Repository structure

```
github-ai-workflow-kit/
│
├── .github/workflows/
│   ├── reusable-ai-triage.yml   # Called by target repos via workflow_call
│   ├── reusable-ai-plan.yml
│   └── reusable-ai-develop.yml
│
├── scripts/
│   ├── ai-common.sh             # Shared utilities (source in every script)
│   ├── ai-triage.sh             # Triage logic
│   ├── ai-plan.sh               # Planning logic
│   ├── ai-develop.sh            # Development + queue logic
│   └── bootstrap-labels.sh      # One-time label setup
│
├── prompts/
│   ├── triage.md                # Triage instructions for the AI
│   ├── planning.md              # Planning instructions for the AI
│   └── develop.md               # Development instructions for the AI
│
└── templates/                   # Copy these into each target repository
    ├── ai-workflow.yml           → .github/ai-workflow.yml
    ├── issue-form.yml            → .github/ISSUE_TEMPLATE/ai-task.yml
    ├── wrapper-triage.yml        → .github/workflows/ai-triage.yml
    ├── wrapper-plan.yml          → .github/workflows/ai-plan.yml
    └── wrapper-develop.yml       → .github/workflows/ai-develop.yml
```

---

## How the multi-repo checkout works

When a target repo triggers a reusable workflow, the runner checks out:

1. The **target repo** at `target_repo/` — the codebase being worked on
2. This **workflow kit** at `_workflow_kit/` — where scripts and prompts live

Scripts run from `_workflow_kit/scripts/` and operate on `target_repo/`. The environment bridge between workflow and scripts is a set of exported variables:

| Env var | Value |
|---------|-------|
| `REPO` | `owner/repo` of the target repo |
| `ISSUE_NUMBER` | Issue being processed |
| `REPO_DIR` | Absolute path to `target_repo/` |
| `WORKFLOW_KIT_DIR` | Absolute path to `_workflow_kit/` |
| `GH_TOKEN` | GitHub token for `gh` CLI calls |

This means every script is also **locally testable** by exporting these variables and running the script directly.

---

## Local testing

```bash
export REPO="your-org/your-repo"
export ISSUE_NUMBER="42"
export GH_TOKEN="$(gh auth token)"
export ANTHROPIC_API_KEY="sk-ant-..."
export REPO_DIR="/tmp/test-repo"
export WORKFLOW_KIT_DIR="$(pwd)"

git clone "https://github.com/$REPO" "$REPO_DIR"

# Test individual stages:
./scripts/ai-triage.sh
./scripts/ai-plan.sh
./scripts/ai-develop.sh --issue 42
```

---

## Labels reference

### Workflow state labels

| Label | Applied by | Meaning |
|-------|------------|---------|
| `ai:triage` | Issue form / human | Triggers AI triage |
| `human:review-triage` | AI (triage script) | Awaiting human review of triage |
| `ai:plan` | Human | Triggers AI planning |
| `human:review-plan` | AI (plan script) | Awaiting human review of plan |
| `ai:develop` | Human | Triggers AI development |
| `pr:created` | AI (develop script) | PR has been opened |
| `ai:blocked` | AI (any script) | Workflow blocked — human intervention needed |
| `decision:close` | Human | Issue should be closed |
| `status:done` | Human | Issue complete and merged |

### Optional labels

`priority:low`, `priority:medium`, `priority:high`, `priority:urgent`

`type:bug`, `type:feature`, `type:refactor`, `type:docs`, `type:maintenance`

---

## Extending the system

The modular structure makes additions straightforward:

- **New AI stage** (e.g. AI code review): add `scripts/ai-review.sh` + `prompts/review.md` + `reusable-ai-review.yml` following the same pattern
- **New AI provider**: add a case to `run_ai_query` and `run_ai_develop` in `scripts/ai-common.sh`
- **Notifications**: add a `post_slack_notification` function to `ai-common.sh` and call it from relevant scripts
- **Scheduled triage**: add a cron trigger to `wrapper-triage.yml` that runs queue-mode triage on new unlabelled issues
