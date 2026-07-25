#!/bin/bash
# Runs approve-ai-work.sh for every submodule of the workspace this is
# checked out in, then for the workspace root itself — in that order,
# since the root's own ai-work diff includes submodule pointer updates
# that only make sense once each submodule has actually been merged.
# Submodules are discovered from .gitmodules, never hardcoded, so this
# doesn't need updating when a submodule is added or removed. Repos with
# no diff between ai-work and main are skipped entirely (no link shown,
# nothing run for them) — nothing to approve there.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPROVE_SCRIPT="$SCRIPT_DIR/approve-ai-work.sh"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ ! -f "$APPROVE_SCRIPT" ]; then
    echo "❌ $APPROVE_SCRIPT not found" >&2
    exit 1
fi

compare_url() {
    local repo_path="$1"
    local remote_url org_repo
    remote_url="$(git -C "$repo_path" remote get-url origin)"
    org_repo="$(echo "$remote_url" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')"
    echo "https://github.com/$org_repo/compare/ai-work?expand=1"
}

has_pending_changes() {
    local repo_path="$1"
    git -C "$repo_path" fetch origin main ai-work --quiet 2>/dev/null || true
    ! git -C "$repo_path" diff --quiet origin/main...origin/ai-work -- 2>/dev/null
}

mapfile -t SUBMODULE_PATHS < <(git config --file "$WORKSPACE_ROOT/.gitmodules" --get-regexp '\.path$' | awk '{print $2}')

SUBMODULES_TO_APPROVE=()
echo "=== ai-work -> main review links ==="
for path in "${SUBMODULE_PATHS[@]}"; do
    if has_pending_changes "$WORKSPACE_ROOT/$path"; then
        echo "  $path: $(compare_url "$WORKSPACE_ROOT/$path")"
        SUBMODULES_TO_APPROVE+=("$path")
    else
        echo "  $path: no changes, skipping"
    fi
done

# Just informational here — approving any submodule below always updates
# the workspace root's submodule pointers, so the root ends up needing
# approval either because of this check or because the loop ran at all
# (see the final approval step).
WORKSPACE_HAD_CHANGES=0
if has_pending_changes "$WORKSPACE_ROOT"; then
    echo "  workspace root: $(compare_url "$WORKSPACE_ROOT")"
    WORKSPACE_HAD_CHANGES=1
else
    echo "  workspace root: no changes, skipping"
fi
echo ""

if [ "${#SUBMODULES_TO_APPROVE[@]}" -eq 0 ] && [ "$WORKSPACE_HAD_CHANGES" -eq 0 ]; then
    echo "✅ Nothing to approve anywhere."
    exit 0
fi

read -p "Reviewed the diffs above? Proceed with approve-ai-work.sh for each? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Cancelled."
    exit 1
fi

# One key, from the workspace root's own local git config, used for
# every repo — no per-repo config, no fallback chain. Read once here and
# passed in explicitly rather than letting approve-ai-work.sh re-derive it
# itself from cwd.
WORKSPACE_KEY="$(git -C "$WORKSPACE_ROOT" config --get gemini.apikey || true)"
if [ -z "$WORKSPACE_KEY" ]; then
    echo "❌ No gemini.apikey configured on the workspace root." >&2
    echo "   Set it with: git -C \"$WORKSPACE_ROOT\" config --local gemini.apikey 'YOUR_KEY_HERE'" >&2
    exit 1
fi

for name in "${SUBMODULES_TO_APPROVE[@]}"; do
    echo ""
    echo "=== Approving $name ==="
    (cd "$WORKSPACE_ROOT/$name" && GEMINI_API_KEY="$WORKSPACE_KEY" "$APPROVE_SCRIPT")

    # Approving a submodule always squash-merges it and resets its
    # ai-work branch to a brand-new commit — a fresh SHA that can never
    # match what the workspace root had recorded, so the pointer bump
    # below is guaranteed, not conditional. (approve-ai-work.sh's own
    # `set -e`, and ours, means we'd never even reach this line on
    # cancellation or failure — only on to a real, completed approval.)
    git -C "$WORKSPACE_ROOT" add "$name"
    git -C "$WORKSPACE_ROOT" commit -m "chore: sync $name submodule pointer after approval"
    git -C "$WORKSPACE_ROOT" push origin ai-work
done

if [ "$WORKSPACE_HAD_CHANGES" -eq 1 ] || [ "${#SUBMODULES_TO_APPROVE[@]}" -gt 0 ]; then
    echo ""
    echo "=== Approving workspace root ==="
    (cd "$WORKSPACE_ROOT" && GEMINI_API_KEY="$WORKSPACE_KEY" "$APPROVE_SCRIPT")
fi

echo ""
echo "✅ approve-all-ai-work done"
