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
- **Checkpoint often, without asking.** Run
  `ai-cli-config/templates/git/push-all` (or the project's thin wrapper
  around it) after every small milestone — never ask permission first.
- **Trust the test gate.** Don't hand-run tests to double-check routine
  changes; commit/push hooks already do that.
- **Trust READMEs.** A README (plus an interface/type declaration, for
  code) is sufficient on its own — don't re-verify it against source,
  a script's contents, or live state (e.g. `gcloud` queries) unless you
  already have concrete evidence in front of you that it's wrong. If
  you do end up needing to read further (impl for code, a script before
  running it) because the README truly didn't cover it, update the
  README with the missing piece once you've read it.
- **Comments explain why, not what.** Non-trivial only, best-effort
  short (2 lines max outside genuine complexity); prefer a well-named
  helper/variable over a comment, and skip narrating history unless it's
  non-obvious or the code would look wrong without it.

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

## Trusting Documentation

Once you've read the relevant README (and, for code, the interface/type
declaration), treat that as the answer — don't spend a tool call
confirming it against the underlying source, a script's body, or live
state (`gcloud`/`kubectl`/API queries, etc.) just to be sure. A service
account table in a README is the account list; a repository list in a
README is the repository list. Re-deriving what documentation already
gives you wastes a call and the user's time for no benefit.

The one exception is when something already in your context contradicts
the README — a build error, a test failure, a diff, a prior message in
this conversation — that gives concrete reason to think it's stale.
Only then go verify against the real thing.

If a task genuinely requires reading past the README (an impl file
because the interface didn't say enough, a script's actual body before
running it because the README didn't cover a detail you needed), that's
fine — but once you've read it, fold whatever was missing back into the
README so the next read doesn't need to repeat the trip.

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

**A reference table or list (a service-account table, a repo list, a
role matrix) stays pure current-state.** "Grant X because Y broke last
week" is a story about how the state came to be, not the state itself
— it doesn't belong in the row/entry, because a table nobody can scan
in one pass stops being a reference. If a mistake is genuinely
repeatable — not a one-off — write a short, generalized note (what to
do, why, without the incident narrative) in a place someone would
actually see it before repeating the mistake: a comment on the exact
line/script most likely to trigger it, or a dedicated pitfalls/gotchas
note near that code. The table still gets the current fact (the role
that's now granted); the reasoning, if worth keeping at all, goes
beside the code it protects, not inside the row.

---

## Comments

A comment states **why**, never **what** — the code already says what;
restating it in prose is a second copy of the same fact, and the two
drift the moment either one changes without the other. Write one only
when there's something genuinely non-obvious to explain: a hidden
constraint, a workaround for a specific bug, a decision that isn't the
first thing a reader would guess. If nothing like that is true, skip the
comment entirely.

Keep it best-effort short — one line where one line covers it. Anything
past two lines is for cases too genuinely complex to compress further;
that should be the rare exception, not the default.

Prefer making the code explain itself over commenting it: a helper
function or a local variable with a name that states its purpose often
replaces a comment outright, and — unlike a comment — stays correct
automatically as the surrounding code changes.

Don't narrate history: a previous iteration, a solution that got
replaced, or why one approach lost to another, in most cases doesn't
belong in the file — that's what the commit message and PR description
are for. The exception is when the reason itself is non-obvious, or the
current code would look wrong or contradict common sense to a reader who
doesn't know it; a short note earns its place there.

---

## Git

Commit and push at every small milestone expected to compile and pass
tests, not just at the end of a task — don't ask "should I commit?" or
"want me to push?" first; asking is itself the mistake this exists to
prevent. Run `ai-cli-config/templates/git/push-all` (or the project's
thin wrapper around it — see the project's own README) each time. A
checkpoint that isn't pushed yet doesn't count as done.

When moving or renaming files, use `mv`/`cp` — never delete-and-recreate.
This preserves git's rename detection and history.

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
