# Agent Behavior

Passed via `--append-system-prompt-file` — this is not copied into a
project and filled in. It's fixed, generic behavior shared by every
project that uses this config. Anything project-specific (tech stack,
architecture, deploy process, human commander) belongs in that project's
own top-level AGENTS.md, and anything package-specific belongs in that
package's own README — never here.

---

## Critical Rules

### ⚠️ NO cd COMMAND - ABSOLUTE RULE

You MUST NOT use the `cd` command to change directories. Working
directory stays fixed at project root for every tool call.

**Why:**
- Maintains consistent context across tools
- Prevents getting lost in subdirectories
- Ensures all relative paths work correctly
- Preserves session state

### ⚠️ README-FIRST, SCOPE-AWARE READING - ABSOLUTE RULE

Before inspecting code, modifying files, or running commands for a new
task:

1. Find READMEs in directories relevant to the task — search nested
   directories, not just the project root — and read the relevant ones
   before opening code files directly.
2. Skip anything you already read earlier in this session. Re-reading a
   README or doc already in context adds nothing.
3. Match how much you read to what the task needs. A large design doc is
   for tasks that touch the design it describes — don't read it end to
   end to fix a specific failing test whose location you already know.

### ⚠️ NO FALLBACKS FOR ENV VARS OR FLAGS - ABSOLUTE RULE

Every configurable value is either a **flag** (env var/CLI flag —
required, no default, fail loudly if missing) or a **const** (hardcoded
in code, no override). Never write a flag with a fallback default — no
`os.Getenv("X"); if x == "" { x = "default" }`, no
`process.env.X ?? "default"`, no `System.getenv("X") ?: "default"`.

If there's genuinely one correct value, hardcode it as a const with no
env override. If it must vary per environment, require it and error if
unset. Silently falling back masks misconfiguration instead of surfacing
it.

---

## File Operations

### README-First Navigation

Read a package's README (if one exists) before browsing its code.
READMEs describe scope and intent; code describes mechanism.

**What belongs in a README:**
- The package's scope and purpose, at a high level
- Requirements/conventions for code written inside it

**What does NOT belong in a README:**
- Anything that duplicates code — no restating function signatures,
  types, or interfaces. They drift out of sync the moment either one
  changes.
- Who calls into this package. Knowledge flows one direction: a package
  knows what it calls, never who calls it (A → B: A knows about B, B does
  not know about A). Documenting callers here creates a reference that's
  wrong the instant a new caller shows up elsewhere.

**Keep them current:** after a significant change to a folder's code,
update its README if the change affects scope, purpose, or in-package
conventions. Keep entries short but clear.

### CRITICAL: Folder Structure Reference

**CRITICAL RULE:** You MUST read `folder_structure.md` (or equivalent)
before creating any new files. Not required if you're only modifying
existing files.

---

## Git Operations

### Preserving Git History

When moving or renaming files, use `mv`/`cp` (shell commands) — never
delete-and-recreate. This preserves git's rename detection and history.

### Commit & Push Often

Run the project's checkpoint/push script after every small milestone
expected to compile and pass tests, not just at the end of a task — a
checkpoint that isn't pushed yet doesn't count as done. See the project's
own AGENTS.md for the exact command.

---

## Testing

**CRITICAL RULE:** Don't manually run tests, e2e checks, or the app
itself just to double-check routine changes before committing — projects
that wire tests into commit/push hooks run them automatically and abort
the operation on failure; trust that gate. Exception: if you have a
specific, concrete reason to expect a test will fail and need its output
to debug, running it manually once for that purpose is fine — that's
diagnosis, not pre-verification.

### Test Standards

**Naming Convention:**
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
