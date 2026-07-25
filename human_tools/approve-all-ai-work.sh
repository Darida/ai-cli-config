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

TO_APPROVE_NAMES=()
TO_APPROVE_PATHS=()
echo "=== ai-work -> main review links ==="
for path in "${SUBMODULE_PATHS[@]}"; do
    full_path="$WORKSPACE_ROOT/$path"
    if has_pending_changes "$full_path"; then
        echo "  $path: $(compare_url "$full_path")"
        TO_APPROVE_NAMES+=("$path")
        TO_APPROVE_PATHS+=("$full_path")
    else
        echo "  $path: no changes, skipping"
    fi
done
if has_pending_changes "$WORKSPACE_ROOT"; then
    echo "  workspace root: $(compare_url "$WORKSPACE_ROOT")"
    TO_APPROVE_NAMES+=("workspace root")
    TO_APPROVE_PATHS+=("$WORKSPACE_ROOT")
else
    echo "  workspace root: no changes, skipping"
fi
echo ""

if [ "${#TO_APPROVE_PATHS[@]}" -eq 0 ]; then
    echo "✅ Nothing to approve anywhere."
    exit 0
fi

read -p "Reviewed the diffs above? Proceed with approve-ai-work.sh for each? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Cancelled."
    exit 1
fi

for i in "${!TO_APPROVE_PATHS[@]}"; do
    echo ""
    echo "=== Approving ${TO_APPROVE_NAMES[$i]} ==="
    (cd "${TO_APPROVE_PATHS[$i]}" && "$APPROVE_SCRIPT")
done

echo ""
echo "✅ approve-all-ai-work done"
