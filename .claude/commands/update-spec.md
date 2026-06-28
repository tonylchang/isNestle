You are updating the project specification based on new information from the user.

The user will describe changes — new decisions, revised scope, updated constraints, shifted timelines, etc. Your job is to incorporate these updates into the appropriate spec element files in `/spec/elements/`. Do NOT modify files in `/spec/original/`.

## Process

1. **Read all current spec elements** from `/spec/elements/` to understand the current state.
2. **Listen to the user's updates.** They may provide updates as:
   - Free-form text ("we decided to drop Redis and use SQLite instead")
   - A voice note (use AssemblyAI MCP to transcribe, then parse)
   - Bullet points or structured changes
   - A reference to a conversation or decision ("we're going serverless now")
3. **Map each update to the correct spec element(s).** A single user statement may affect multiple files (e.g., "we're switching to Vercel" affects both `STACK.md` and `INFRA.md`).
4. **Update only the affected files.** Do not rewrite files that haven't changed.
5. **Preserve context.** When updating, don't delete prior content that's still valid — amend, replace, or add sections as appropriate. If something was in scope and is now out of scope, move it to the "Out of Scope" section rather than deleting it.

## Rules

- **Only update `/spec/elements/`.** Never touch `/spec/original/`.
- **Track what changed.** After all updates, present a summary:
  - Which files were modified
  - What changed in each (brief diff summary)
- **Flag conflicts.** If an update contradicts an existing spec element (e.g., adding a feature that's listed as out of scope), flag it and ask the user to confirm.
- **Don't infer beyond what's stated.** If the user says "switch to PostgreSQL", update the database sections — don't also assume they want to change hosting unless they said so.
- **Ask for clarification** if an update is ambiguous or could be interpreted multiple ways.

## After Updates

Summarize all changes made and ask:
- "Does this capture everything, or are there more changes?"
- If the spec has diverged significantly from the original, suggest the user review `/spec/original/` to see how far the project has evolved.
