# AI Project Spec Pattern

A template for **spec-driven development** with Claude Code.

## The Idea

Project specs are typically monolithic documents that are hard to maintain and hard for AI to reference precisely. This pattern breaks specifications into **atomic, modular primitives** ("elements") — each covering one discrete concern. The modular structure means updates are lightweight and precise: changing your deployment target updates `INFRA.md` alone, not a 20-page spec doc.

This atomic approach gives Claude (or any AI coding agent) clean, focused context for every decision — and makes ongoing spec evolution cheap instead of painful.

## How It Works

1. **Clone or fork this template** into a new project
2. **Run `/init`** in Claude Code — Claude interviews you and generates all spec elements
3. **Run `/save-original`** to snapshot the baseline spec
4. **Develop with guardrails** — `CLAUDE.md` instructs Claude to reference your specs before making decisions
5. **Evolve the spec** with `/update-spec` — only the affected elements are modified

## The Spec Elements

All elements live in `/spec/elements/`. Each is a standalone, atomic document covering one concern:

| File | What It Defines |
|------|----------------|
| `PURPOSE.md` | Why this project exists, who it's for |
| `FEATURES.md` | Core features, planned features, and explicit exclusions |
| `STACK.md` | Approved and excluded technologies |
| `UI.md` | Interface type, platform targets, UX preferences |
| `INFRA.md` | Deployment, hosting, CI/CD, monitoring |
| `CONSTRAINTS.md` | Budget, timeline, team size, licensing |
| `PROJECT.md` | Development lifecycle, milestones, release plan |
| `VERSIONING.md` | Version scheme, release cadence, tagging strategy |
| `CONTEXT.md` | Freeform catch-all for anything else relevant |

The `/spec/original/` directory preserves the initial spec as an immutable baseline for comparison as the project evolves.

## Slash Commands

| Command | What It Does |
|---------|-------------|
| `/init` | Interactive interview — Claude asks questions and generates all spec elements |
| `/voice-init` | Generate specs from a voice note — transcribes via AssemblyAI, then parses into elements |
| `/save-original` | Snapshot current spec elements into `/spec/original/` as the immutable baseline |
| `/update-spec` | Apply targeted updates — user describes changes, only affected elements are modified |

## Why This Pattern

- **Atomic and modular** — each spec element is independent, so updates are surgical rather than wholesale
- **Lightweight ongoing updates** — changing one decision updates one file, not a monolithic document
- **Reduces drift** — Claude checks specific elements before introducing new tech or features
- **Explicit scope** — "out of scope" sections prevent feature creep
- **Reproducible onboarding** — `/init` or `/voice-init` generates a consistent spec set for every project
- **Spec evolution tracking** — `/spec/original/` preserves the baseline so you can see how the project evolved
- **Human-readable** — specs are plain Markdown, useful with or without AI tooling

## Setup

### Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI
- (Optional) [AssemblyAI](https://www.assemblyai.com/) API key for `/voice-init`

### Getting Started

```bash
# Option 1: GitHub template
gh repo create my-project --template danielrosehill/AI-Project-Spec-Pattern

# Option 2: Clone and reinitialize
git clone https://github.com/danielrosehill/AI-Project-Spec-Pattern.git my-project
cd my-project
rm -rf .git && git init

# Set up AssemblyAI (optional, for voice-init)
cp .env.example .env
# Edit .env with your API key

# Then open in Claude Code and run:
# /init        — for interactive onboarding
# /voice-init  — to start from a voice note
```

## Customizing

- **Add spec elements**: If your project needs additional primitives (e.g., `SECURITY.md`, `DATA-MODEL.md`), add them to `/spec/elements/` and reference them in `CLAUDE.md`.
- **Modify the interview**: Edit `.claude/commands/init.md` to change the onboarding questions.
- **Modify voice parsing**: Edit `.claude/commands/voice-init.md` to adjust how transcripts are parsed.
- **Layer on existing preferences**: The `/init` command can skeleton `STACK.md` from your global Claude preferences if you have them configured.

## License

MIT
