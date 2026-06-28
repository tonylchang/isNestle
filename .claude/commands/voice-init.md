You are onboarding a new project from a voice note using spec-driven development.

The user has recorded a voice note describing their project idea. Your job is to:

1. **Transcribe the voice note** using the AssemblyAI MCP server
2. **Save the raw transcript** unedited to `/spec/original/` as `voice-transcript.md` with a timestamp header
3. **Parse the transcript** into the 9 spec element files

## Step 1: Get the Audio

Ask the user for the path to their audio file (MP3, WAV, M4A, etc.) or a URL. Then use the AssemblyAI MCP to transcribe it.

## Step 2: Save the Original

Write the unedited transcript to `/spec/original/voice-transcript.md` in this format:

```markdown
# Original Voice Note Transcript

- **Date**: YYYY-MM-DD
- **Source**: [filename or URL]

---

[full unedited transcript here]
```

## Step 3: Extract Spec Elements

Read through the transcript and extract information relevant to each of the 9 spec elements. For each file in `/spec/elements/`, replace the skeleton content with whatever the user mentioned.

Work through them in this order:
1. `PURPOSE.md` — Look for problem statements, motivation, "I want to build..."
2. `FEATURES.md` — Look for feature descriptions, "it should...", "it needs to..."
3. `STACK.md` — Look for technology mentions, framework preferences, "I want to use..."
4. `UI.md` — Look for interface descriptions, "it'll be a web app", "CLI tool", platform mentions
5. `INFRA.md` — Look for deployment mentions, hosting preferences, "deploy to..."
6. `CONSTRAINTS.md` — Look for budget mentions, timeline, "I need this by...", licensing preferences
7. `PROJECT.md` — Look for phasing, "start with a POC", milestone descriptions
8. `VERSIONING.md` — Look for version/release preferences (often not mentioned in voice — use sensible defaults and flag for review)
9. `CONTEXT.md` — Capture anything relevant that doesn't fit the other files

## Important

- **Do not fabricate details.** If the voice note doesn't mention something (e.g., versioning), leave the skeleton headings in place and note "Not specified in voice note — needs input."
- **Do not edit the original.** The transcript in `/spec/original/` must be verbatim.
- **Flag ambiguity.** If the transcript is unclear on a point, add a `<!-- REVIEW: [question] -->` comment in the relevant spec file.

## After Extraction

Present a summary showing:
- Which spec elements were populated from the voice note
- Which still need user input
- Any ambiguities flagged for review

Ask the user if they want to fill in the gaps interactively (similar to `/init`) or leave them for later.
