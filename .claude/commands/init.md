You are onboarding a new project using spec-driven development. Your job is to interview the user and generate a complete set of project specification elements in `/spec/elements/`.

Walk through each spec element one at a time. For each one, ask focused questions, then generate the file based on the user's answers. Be conversational but efficient — don't ask questions you can infer from prior answers.

## Interview Flow

Work through these in order. After each section, write the corresponding file to `/spec/elements/` before moving on.

### 1. PURPOSE.md
Ask:
- What does this project do? What problem does it solve?
- Who is it for?
- Is there an existing solution this replaces or improves on?

### 2. FEATURES.md
Ask:
- What are the core features (must-have for v1)?
- What are nice-to-have features (future scope)?
- Is there anything explicitly out of scope?

Structure the file with **Core Features**, **Planned Features**, and **Out of Scope** sections.

### 3. STACK.md
Ask:
- Do you have existing stack preferences or requirements? (languages, frameworks, databases)
- Is this building on top of an existing codebase or starting fresh?
- Are there technologies you explicitly want to avoid?
- Any strong opinions on package managers, testing frameworks, or build tools?

If the user has longstanding preferences they've already shared (e.g., in their global CLAUDE.md or context files), offer to skeleton the file from those and let them adjust.

Structure the file with **In Scope** (approved technologies) and **Out of Scope** (excluded technologies) sections, plus rationale.

### 4. UI.md
Ask:
- What type of interface? (CLI, desktop GUI, web app, mobile, API-only, library/SDK)
- Target OS/platform?
- Any UI framework preferences?
- Accessibility requirements?
- Design references or style preferences?

### 5. INFRA.md
Ask:
- Where will this be deployed? (local, VPS, cloud provider, serverless, container orchestration)
- Any CI/CD preferences?
- Database hosting?
- Domain/DNS plans?
- Monitoring or observability needs?

### 6. CONSTRAINTS.md
Ask:
- Budget constraints? (hosting costs, API costs, paid services)
- Timeline or deadline?
- Team size — solo dev or collaborative?
- Licensing requirements? (open source license, proprietary, etc.)
- Any regulatory or compliance requirements?

### 7. PROJECT.md
Ask:
- What's the development approach? (POC first, iterative, waterfall, etc.)
- What does "done" look like for the first milestone?
- Are there subsequent milestones planned?
- Is this a one-off project or ongoing maintenance?

Structure with **Current Phase**, **Milestones**, and **Long-term Plan** sections.

### 8. VERSIONING.md
Ask:
- Versioning scheme? (semver, calver, custom)
- When do you cut releases? (per feature, on schedule, ad hoc)
- Tagging strategy? (git tags, GitHub releases, both)
- Do you want a CHANGELOG?
- Any preference for pre-release labels? (alpha, beta, rc)

### 9. CONTEXT.md
Ask:
- Anything else I should know? Related projects, team conventions, domain knowledge, prior art, political considerations, personal preferences?

This is the catch-all. If the user mentioned anything during earlier questions that didn't fit neatly into another file, capture it here.

## After All Files Are Generated

Once all nine files are written:
1. Confirm the full spec with the user — list all files and a one-line summary of each.
2. Ask if they want to revise anything before starting development.
3. Remind them that they can re-run `/init` at any time to regenerate or update spec files.
