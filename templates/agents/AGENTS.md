# AI Agent Project Configuration Template

This document establishes project rules for AI agents (Claude, other AI systems) working in this repository. Replace all TODO markers with your project-specific values. This template ensures consistent, safe agent behavior across any project.

---

## Critical Rules

### ⚠️ NO cd COMMAND - ABSOLUTE RULE

You MUST NOT use the `cd` command to change directories.

**Working directory is fixed at project root:**
```
<PROJECT_ROOT>
```

**Why:**
- Maintains consistent context across tools
- Prevents getting lost in subdirectories
- Ensures all relative paths work correctly
- Preserves session state

### ⚠️ AI AGNOSTIC & LOCAL REFERENCE RULES

- **No External References:** You MUST NOT refer to any skills, files, or folders located outside of the project directory.
- **AI Agnostic & Identity-Free:** Do not include any AI identity (e.g., Claude, Gemini, Anthropic) in any documentation, commit messages, or project files. Do not reference any AI agent-specific configuration folders, project histories, or files that reside outside of the GitHub repository.

### ⚠️ DOCUMENTATION BEFORE CODE INSPECTION - ABSOLUTE RULE

Before starting ANY code inspection, file modification, or command execution for a new task:

1. You MUST check the `docs/` folder to identify relevant design or requirement documents.
2. You MUST clearly state out loud in the chat which documents in `docs/` you consider relevant for the current task.
3. You MUST read those stated documents AFTER you have declared them, and BEFORE starting any code/implementation file inspection or other tool use.

---

## Environment Setup

### TODO: Language & Runtime

Fill in your project's primary language and runtime:

```
Language: [TODO: e.g., Go, Python, TypeScript, Rust]
Version: [TODO: e.g., 1.26.3, 3.11, 18.0.0]
```

**Installation & Testing:**

```bash
# TODO: Add command to verify runtime is installed
[your-command] --version

# TODO: Add command to run tests from workspace root
[your-test-command]
```

---

## File Operations

### Relative Paths from Project Root

Always use relative paths in Read/Edit/Write tools. Work from workspace root:

```
# TODO: Replace with actual project structure
<path-to-package-or-module>/<file-name>
<path-to-service>/<component>/<file>.go
docs/<design-document>.md
```

### CRITICAL: Folder Structure Reference

**CRITICAL RULE:** You MUST read `folder_structure.md` (or equivalent) before creating any new files. You do not have to read it if you are only modifying existing files.

---

## Git Operations

### Workflow from Project Root

All git commands use the repo in current directory:

```bash
git status
git add -A
git commit -m "message"
git push origin <branch-name>
```

**Current branch:** `ai-work`

### Pre-Push Hooks

**TODO:** Document any automatic tests/checks that run on push:

```bash
# Example:
[your-test-command] -v
```

**If checks fail:** Push is aborted. Fix the issues and retry.

### First-Time Setup

```bash
# TODO: Add hook path configuration if applicable
git config core.hooksPath <path-to-hooks-dir>
```

### Preserving Git History - CRITICAL

When moving or renaming files, **ALWAYS use `mv` and `cp` (shell commands)**, NOT delete/create. This preserves git's rename detection and file history.

❌ **WRONG** (loses history):
```bash
# Read old file
Read: old_location.go
# Write to new location (creates orphaned history)
Write: new_location.go
# Delete old file
bash: rm old_location.go
```

✅ **RIGHT** (preserves history):
```bash
# Use shell mv command to move/rename
bash: mv old_location.go new_location.go
git add -A
git commit -m "refactor: rename file"
```

**For copying files** (when you need both):
```bash
bash: cp source.go destination.go
git add destination.go
git commit -m "feat: add destination with content from source"
```

---

## Testing

### TODO: Test Command & Standards

**Test Execution:**
```bash
# TODO: Add actual test command with timeout
[your-test-command] -timeout 30s
```

**CRITICAL RULE:** Manually running tests before committing or submitting is PROHIBITED. Tests run AUTOMATICALLY on commit and push via git hooks. If tests fail, the git operation will be aborted and the failed tests will be listed.

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
- Test name must describe intent—someone should understand what's tested without reading code
- Duplication in tests is acceptable for clarity
- If test name would have "And" in condition/outcome, split into separate tests

---

## Documentation Structure

### TODO: Key Documents

Reference your project's key design and implementation documents. Example structure:

```
docs/
├── ARCHITECTURE.md              — System design & component boundaries
├── folder_structure.md          — Package layout & dependency flow
├── SETUP.md                     — Local development setup
├── FEATURE_<name>.md            — Feature-specific design
├── ERROR_HANDLING.md            — Error patterns & conventions
└── TEST_STRATEGY.md             — Testing approach & conventions
```

**Before starting ANY task:**
1. Check which docs/ files are relevant
2. List them explicitly in your response
3. Read them before inspecting code

---

## Development Phases

**TODO:** Document your project phases and current status

### Phase 1: [TODO: Phase name]
- [ ] [TODO: Milestone 1]
- [ ] [TODO: Milestone 2]
- [ ] [TODO: Milestone 3]

### Phase 2: [TODO: Phase name]
- [ ] [TODO: Feature/component 1]
- [ ] [TODO: Feature/component 2]

### Phase 3+: [TODO: Future phases]

---

## Architecture & Key Principles

### System Boundaries

**TODO:** Document your architectural layers and boundaries. Example:

```
<Layer 1> (e.g., UI, API)
    ↓ calls
<Layer 2> (e.g., Business Logic)
    ├→ <Dependency 1> (e.g., Repository)
    ├→ <Dependency 2> (e.g., Config)
    └→ <Dependency 3> (e.g., External Service)
```

### Core Principles

**TODO:** List your project's architectural principles. Examples:

- [ ] Stateless backend (no persistent background processes)
- [ ] Dependency injection via [TODO: mechanism]
- [ ] [TODO: Other principle 1]
- [ ] [TODO: Other principle 2]

### Import Rules

**TODO:** Document import constraints. Example:

```
Layer A imports from: Layer B, Config (ONLY)
Layer B imports from: Layer C, Repository (ONLY)
Layer C: No dependencies (pure logic/data)

Forbidden: Circular imports, importing from internal/* directly
```

---

## Commit & Push Workflow

### Split Work into Logical Pieces

Break tasks into small, reviewable commits:

1. Each commit should represent one logical change (feature, fix, refactor)
2. Commit locally as you complete work—don't batch multiple features into one commit
3. Push to `ai-work` in smaller increments for easier review and iteration
4. Tests run automatically on commit via pre-commit hook; fix any failures and commit again

### Commands for Each Logical Piece

```bash
# Stage all changes:
git add -A

# Commit changes:
git commit -m "feat/fix/docs: descriptive message"

# PUSH the commits to remote immediately (NEVER finish a task without pushing to GitHub):
git push origin ai-work
```

**This approach ensures:**
- Work is organized and reviewable
- History is readable
- Easy rollback if needed

---

## Example Workflow

Always work from workspace root.

```bash
# 1. Read relevant file (relative path)
Read: <relative-path-to-file>

# 2. Edit file (relative path, no cd)
Edit: <relative-path-to-file>

# 3. Verify changes with git
git status

# 4. Commit (no cd)
git add -A
git commit -m "fix: something"

# 5. Push to ai-work
git push origin ai-work
```

**Note:** Tests run automatically on commit. If a test fails, fix the issue and commit again.

---

## Debugging & Common Issues

### Issue: Tests fail on push

**Solution:**
1. Review the failed test output
2. Identify the failing test and root cause
3. Fix the code
4. Commit the fix locally
5. Push again

### Issue: "permission denied" or "file not found"

**Solution:**
1. Verify you're using relative paths from project root
2. Check that paths match `folder_structure.md`
3. Use `git status` to verify current directory context

### TODO: Add project-specific debugging tips

---

## Quick Reference

| Task | Command |
|------|---------|
| Check status | `git status` |
| Review changes | `git diff` |
| Run tests | `[your-test-command]` |
| Commit work | `git add -A && git commit -m "msg"` |
| Push to ai-work | `git push origin ai-work` |
| TODO: [other common task] | `[command]` |

---

## Last Updated

- **Template Version:** 2026-07-23
- **Last Reviewed:** [TODO: Date]
- **Status:** Active (customize for your project)

---

## Customization Checklist

Before using this template in your project:

- [ ] Replace all `[TODO: ...]` markers with project-specific values
- [ ] Update language/runtime version
- [ ] Add actual test commands
- [ ] Document your folder structure
- [ ] List key design documents in docs/
- [ ] Define architectural layers and boundaries
- [ ] Add git hook configuration if applicable
- [ ] Document your development phases
- [ ] Add project-specific debugging tips
- [ ] Share this file with all contributors (especially AI agents)
