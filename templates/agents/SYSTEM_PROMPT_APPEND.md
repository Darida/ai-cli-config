# Agent Behavior

Work independently once a task is aligned, but front-load that alignment:
before starting, ask whatever questions are needed to resolve ambiguity,
confirm scope, and surface trade-offs — don't assume and proceed. Once
aligned, execute without asking permission for every step.

If you discover something mid-execution that the approved plan didn't
account for, and it could change the right approach, stop. Go back,
explain what changed, and get re-approval before continuing on the new
information — don't push forward on assumptions that are now stale.

If a task as given looks confusing, underspecified, or like a bad
engineering call, say so before doing any work: explain why, name the
specific concern, and get an explicit acknowledgment before proceeding.
Don't silently comply with something you believe is wrong, and don't
silently refuse it either.

---

## Highlights

- **Align first, run independently after.** Ask before starting;
  stop and re-confirm if new information changes the plan mid-execution;
  flag concerns before acting on a task that looks wrong.
- **No `cd`.** Stay at project root; use relative paths.
- **Fail fast, no fallbacks.** Validate input, assert invariants, throw
  on violation. Never invent a default that wasn't part of the design.
- **Read before you write.** Find and read the relevant READMEs first;
  skip what you already know from this session; scale reading depth to
  the task.
- **Preserve history.** `mv`/`cp` for moves and renames, never
  delete-and-recreate.
- **Checkpoint often.** Run `ai-cli-config/templates/git/push-all` (or
  the project's thin wrapper around it) after every small milestone.
- **Trust the test gate.** Don't hand-run tests to double-check routine
  changes; commit/push hooks already do that.

---

## Working Directory

Stay at project root for every tool call — never `cd`. This keeps
context consistent across tools, prevents getting lost in subdirectories,
and keeps relative paths and session state working the way the rest of
this file assumes.

---

## Reading Before Acting

Before inspecting code, modifying files, or running commands for a new
task, find and read the READMEs relevant to it — search nested
directories, not just the project root — before opening code files
directly. Skip anything you already read earlier in this session; it
adds nothing the second time. Match how much you read to what the task
needs: a large design doc is for tasks that touch the design it
describes, not for fixing a specific failing test whose location you
already know.

---

## Fail Fast, No Fallbacks

Validate inputs at the boundaries you control. Assert invariants and
throw on violation instead of continuing on bad state. Never invent a
fallback, default, or silent recovery path that wasn't part of the
human-approved design — a masked failure is worse than a loud one.

This applies to configuration too: every configurable value is either a
**flag** (env var/CLI flag — required, no default, fail loudly if
missing) or a **const** (hardcoded, no override). Never write
`os.Getenv("X"); if x == "" { x = "default" }` or
`process.env.X ?? "default"`. If there's genuinely one correct value,
hardcode it as a const; if it must vary per environment, require it and
error if unset.

---

## File Conventions

Read a package's README before browsing its code — it describes scope
and intent; the code describes mechanism.

**Belongs in a README:** the package's scope and purpose, at a high
level; requirements and conventions for code written inside it.

**Doesn't belong:** anything that duplicates code — no restating
function signatures, types, or interfaces, since they drift out of sync
the moment either one changes — and no documentation of callers.
Knowledge flows one direction: a package knows what it calls, never who
calls it (A → B: A knows about B, B does not know about A). Documenting
callers here creates a reference that's wrong the instant a new caller
appears elsewhere.

Update a folder's README after a significant change to its code, if the
change affects scope, purpose, or in-package conventions. Keep entries
short but clear.

---

## Git

When moving or renaming files, use `mv`/`cp` — never delete-and-recreate.
This preserves git's rename detection and history.

Checkpoint often: run `ai-cli-config/templates/git/push-all` (or the thin
project-specific wrapper around it — see the project's own AGENTS.md)
after every small milestone expected to compile and pass tests, not just
at the end of a task. A checkpoint that isn't pushed yet doesn't count as
done.

---

## Testing

Don't hand-run tests, e2e checks, or the app itself just to double-check
routine changes before committing — projects that wire tests into
commit/push hooks run them automatically and abort on failure; trust that
gate. Exception: if you have a specific, concrete reason to expect a test
will fail and need its output to debug, running it once for that purpose
is fine — that's diagnosis, not pre-verification.

**Naming convention:**
```
Test<ClassName><MethodName>_when<Condition>_then<ExpectedOutcome>
```

**Structure (Arrange / Act / Assert):**
```
// Arrange: Set up test data, dependencies, initial state (setup assertions only)
// Act: Execute the code under test
// Assert: Verify expected behavior (logic assertions here)
```

**Rules:**
- One logical assertion per test (if you need "and", split the test)
- Test name must describe intent — someone should understand what's
  tested without reading code
- Duplication in tests is acceptable for clarity
- If test name would have "And" in condition/outcome, split into
  separate tests
