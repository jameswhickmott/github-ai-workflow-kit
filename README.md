# Local AI Workflow (Claude Code / Codex)

Run the AI triage, plan, and develop workflow from a Claude Code or Codex terminal session — no GitHub Actions, no API keys. The AI session you're already in does the analysis and writes back to GitHub directly via `gh` CLI.

---

## Setup

### 1. Add workflow files to your repo

Run this from your project root. It creates or updates `AI-Workflow.md`, `AGENTS.md`, and `CLAUDE.md` — pulling the latest workflow directly from this repo:

```bash
curl -fsSL https://raw.githubusercontent.com/jameswhickmott/github-ai-workflow-kit/main/scripts/update-workflow.sh | bash
```

- **`AI-Workflow.md`** — the workflow instructions (created or replaced)
- **`AGENTS.md`** — workflow block inserted if markers present, appended if not, created if absent
- **`CLAUDE.md`** — `@AI-Workflow.md` import prepended if missing, created if absent

If `AGENTS.md` already contains project-specific content, add these markers around the section where you want the workflow to live and re-run the script — only that section will be replaced on future updates:

```md
<!-- ai-workflow:start -->
...workflow content...
<!-- ai-workflow:end -->
```

### 2. Bootstrap labels (first time only)

```bash
curl -fsSL https://raw.githubusercontent.com/jameswhickmott/github-ai-workflow-kit/main/scripts/bootstrap-labels.sh | bash -s owner/your-repo
```

### 3. Authenticate gh CLI

```bash
gh auth login
```

That's it. No API keys. No additional config.

---

## Keeping the workflow up to date

Re-run the same command from your project root to pull the latest workflow changes:

```bash
curl -fsSL https://raw.githubusercontent.com/jameswhickmott/github-ai-workflow-kit/main/scripts/update-workflow.sh | bash
```

To update a single file only:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jameswhickmott/github-ai-workflow-kit/main/scripts/update-workflow.sh) AGENTS.md
```

---

## Usage

Start a Claude Code or Codex session inside your target repo, then use natural language:

| Say this | What happens |
|----------|-------------|
| `status` | Fetches all issue by workflow label, and renders a summary table with counts and issue numbers
| `triage issue 42` | Fetches issue #42, posts a triage report as a GitHub comment, updates labels |
| `triage all` | Finds all issues labelled `ai:triage` and triages each |
| `plan issue 42` | Reads the triage report, posts an implementation plan, updates labels |
| `plan all` | Processes all issues labelled `ai:plan` |
| `develop issue 42` | Implements the plan, creates a branch, commits, opens a PR |
| `develop all` | Processes all issues labelled `ai:develop` |

---

## Workflow stages

Issues move through three AI stages, each requiring human approval before the next begins:

```
ai:triage → human:review-triage → ai:plan → human:review-plan → ai:develop → pr:created
```

- **triage** — requires `ai:triage` label on the issue
- **plan** — requires `ai:plan` label and a completed triage comment
- **develop** — requires `ai:develop` label and a completed plan comment

---

## Optional: repo config

Add `.github/ai-workflow.yml` to describe your project. This gets injected into prompts for better context:

```yaml
project_context: "A Node.js API serving a React dashboard."
tech_stack: "TypeScript, Node.js, PostgreSQL"
```
