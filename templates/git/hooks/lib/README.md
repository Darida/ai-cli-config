# lib/

Generic git hook scripts, shared across whatever projects use this
template. Every script takes everything it needs as `--flag=value`
arguments and asserts its own preconditions — no repo names, no `pwd` or
caller assumptions baked in anywhere. A project's own `git/hooks/<repo>/`
delegators (see that project's `git/hooks/README.md`) call into these
with their specific paths filled in.

Three of these auto-commit when they change something — same reasoning in
each case: don't fail a commit/push over noise the script itself just
produced and can safely commit on its own. None of them ever commit
anything outside what they specifically touched (never `add -A`), and
none of them block — `require-clean` is the only script with blocking
power, meant to run last, after the others have had their chance to clean
up.

- `check-branch --repo=`
- `go-test --repo=` — skips if not a Go module
- `npm-test --repo=` — skips if no `package.json`; otherwise runs `npm
  test`
- `go-generate --repo= --generated-dir=` — skips if not a Go module;
  regenerates and auto-commits if that changed the generated dir. Run
  this *before* `go-test`, not after — otherwise tests can run against
  stale generated code whenever pre-commit's own regen step was bypassed.
- `cassette-check --repo=` — auto-commits cassette-path changes
  specifically, logs (never blocks) if other changes remain
- `proto-sync --dest= --source=` — copies then auto-commits if that
  changed the destination
- `git-show-remote-tree --repo= --remote= --branch= --path= --output=`
- `proto-verify --original= --destination=` — plain directory diff, no
  git; compare against a ref by materializing it first with
  `git-show-remote-tree`
- `require-clean --repo=` — the actual gate: fails if anything is left
  uncommitted

## Gotchas found by testing these for real (not by reasoning about them)

- **`GIT_DIR` leaks into nested `git -C` calls.** git sets `GIT_DIR` (and
  related env vars) when invoking a hook, pointing at the invoking repo's
  own git dir. That silently overrides `-C` on any nested `git -C
  "$OTHER_REPO" ...` call — without `unset GIT_DIR GIT_WORK_TREE
  GIT_INDEX_FILE GIT_PREFIX` first, those calls operate on the wrong repo
  and fail silently (empty output, easy to misread as some other bug).
  `proto-sync` and `git-show-remote-tree` both do this unset since both
  can target a repo other than the one that invoked the hook. No need to
  restore it afterward — env var changes are local to a process and never
  propagate back to the parent once the script exits, so the calling
  delegator's own environment is untouched either way.
- **A subshell's `cd` doesn't follow you out.** `proto-verify` originally
  ran `find` in a subshell that `cd`'d into the source dir to get clean
  relative paths, then used those same relative paths directly outside
  that subshell — where cwd was whatever the caller's cwd was. Always
  re-join the base dir with the relative path before using it outside the
  subshell that produced it.
- **An auto-commit without `--no-verify` recurses into itself.**
  `go-generate` and `proto-sync` are called from `pre-commit`; their own
  internal `git commit` is a real `git commit` invocation, so it
  re-triggers `pre-commit` — which calls the same script again. If
  codegen/sync genuinely still differs from `HEAD` (the normal case this
  auto-commit exists for, not an edge case), the outer commit is still
  blocked on its own nested `pre-commit` finishing, so `HEAD` never
  moves, so every recursive level sees the same unresolved diff against
  the same stale `HEAD` — forever, until something kills the process.
  This isn't hypothetical: it happened on the very first real use of
  `go-generate`'s auto-commit path in this workspace, 600+ levels deep
  before being caught. All three auto-committing scripts now use `git
  commit --no-verify` for exactly this reason — any new auto-commit added
  here needs it too if it could ever run from inside `pre-commit`.
- **Scoping the `add`, without also scoping the `commit`, doesn't scope
  the commit.** `git commit` with no pathspec commits the *entire index*,
  not just what the script itself just staged. A caller further up the
  chain (`push-all` does `git add -A` before its own `git commit`) can
  leave unrelated files already staged when one of these scripts runs —
  and without a trailing `-- <pathspec>` on the `commit` matching the
  `add`, all of that gets swept into the auto-commit and mislabeled under
  its generic message (e.g. everything landing in a commit titled "chore:
  regenerate gen"). All three scripts now pass the same pathspec to both
  `add` and `commit`. Any new auto-commit added here must do the same, or
  the "never commits outside what it specifically touched" claim above is
  false in practice even though the `add` line alone looks correct.

Verify any new cross-repo `git -C` call or subshell-scoped `cd` the same
way: by actually running the hook, not just reading it.
