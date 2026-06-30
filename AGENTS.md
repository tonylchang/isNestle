# AGENTS.md — Spec-Driven Development

This project uses **spec-driven development**. Before writing any code, read and internalize the project specification files in `/spec/elements/`. These foundational documents define what to build, how to build it, and what constraints apply.

## Spec Elements

All spec elements live in `/spec/elements/`. Read every file before beginning work. If a file is empty or contains only skeleton headings, ask the user to populate it or run `/init` to generate specs interactively.

| File | Purpose |
|------|---------|
| `PURPOSE.md` | Why this project exists — the core problem it solves |
| `FEATURES.md` | Planned features, prioritized and scoped |
| `STACK.md` | Technology choices — what's in scope and what's explicitly out |
| `UI.md` | Target interface type (CLI/GUI/web/API), OS targets, UX preferences |
| `INFRA.md` | Deployment targets, hosting, CI/CD, infrastructure plans |
| `CONSTRAINTS.md` | Budget, time, team size, licensing, and other hard limits |
| `PROJECT.md` | Development lifecycle — POC, milestones, release plan |
| `VERSIONING.md` | Version numbering scheme, release cadence, tagging strategy |
| `CONTEXT.md` | Freeform context — anything else that informs development |

The `/spec/original/` directory preserves the initial spec as a baseline. Never modify files there.

## Slash Commands

| Command | Purpose |
|---------|---------|
| `/init` | Interactive interview to generate all spec elements from scratch |
| `/voice-init` | Generate spec elements from a voice note (requires AssemblyAI) |
| `/save-original` | Snapshot current spec elements to `/spec/original/` |
| `/update-spec` | Apply targeted updates to specific spec elements |

## How to Use This

1. **Starting a new project**: Run `/init` or `/voice-init` to generate all spec elements.
2. **Preserve the baseline**: Run `/save-original` to snapshot the initial spec.
3. **During development**: Reference spec elements to stay aligned with stated goals and constraints.
4. **Evolving the spec**: Run `/update-spec` to make targeted updates — only affected elements are modified.
5. **Scope questions**: Check `FEATURES.md` and `CONSTRAINTS.md` before adding anything new.
6. **Tech decisions**: Check `STACK.md` before introducing a dependency.
7. **Deployment questions**: Check `INFRA.md` and `PROJECT.md` for staging/release plans.

## Rules

- Do not add features not listed in `FEATURES.md` without asking the user.
- Respect stack boundaries in `STACK.md` — if a technology is listed as out-of-scope, do not use it.
- Respect constraints in `CONSTRAINTS.md` — especially budget and licensing limits.
- Follow the versioning scheme in `VERSIONING.md` for all releases and tags.
- When the spec is ambiguous, ask — don't assume.
- Never modify files in `/spec/original/` — they are the immutable baseline.
