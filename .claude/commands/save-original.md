Save the current state of the project specification as the original, unedited baseline.

## What to Do

1. Copy every file from `/spec/elements/` into `/spec/original/`, preserving filenames.
2. If files already exist in `/spec/original/`, ask the user before overwriting — the original is meant to be a snapshot of the initial spec before any development-driven changes.
3. Add a `_SNAPSHOT.md` file to `/spec/original/` with metadata:

```markdown
# Spec Snapshot

- **Date**: YYYY-MM-DD
- **Method**: [how the spec was generated — /init interview, /voice-init, manual]
- **Files preserved**: [list of files]
```

## Purpose

The `/spec/original/` directory preserves the initial spec as a reference point. During development, the elements in `/spec/elements/` may evolve — the originals let you see what changed and why.
