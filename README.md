# Local AI Workflow (Claude Code / Codex)

Run the AI triage, plan, and develop workflow from a Claude Code or Codex terminal session — no GitHub Actions, no API keys. The AI session you're already in does the analysis and writes back to GitHub directly via `gh` CLI.

---

## Setup

### 1. Clone this kit (once)

```bash
git clone https://github.com/your-org/github-ai-workflow-kit ~/GitHub/github-ai-workflow-kit
```

### 2. Add workflow instructions to your target repo

If `CLAUDE.md` / `AGENTS.md` don't exist yet, copy them:

```bash
cp ~/GitHub/github-ai-workflow-kit/templates/CLAUDE.md  your-repo/CLAUDE.md
cp ~/GitHub/github-ai-workflow-kit/templates/AGENTS.md  your-repo/AGENTS.md
```

If they already exist, append instead:

```bash
cat ~/GitHub/github-ai-workflow-kit/templates/CLAUDE.md >> your-repo/CLAUDE.md
cat ~/GitHub/github-ai-workflow-kit/templates/AGENTS.md >> your-repo/AGENTS.md
```

### 3. Bootstrap labels (first time only)

```bash
~/GitHub/github-ai-workflow-kit/scripts/bootstrap-labels.sh owner/your-repo
```

### 4. Authenticate gh CLI

```bash
gh auth login
```

That's it. No API keys. No additional config.

---

## Usage

Start a Claude Code or Codex session inside your target repo, then use natural language:

| Say this | What happens |
|----------|-------------|
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
