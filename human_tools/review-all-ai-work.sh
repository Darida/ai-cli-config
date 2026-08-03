#!/bin/bash
# Runs review-ai-work.sh for every submodule of the workspace this is
# checked out in, then for the workspace root itself.
# Submodules are discovered from .gitmodules, never hardcoded. Repos with
# no diff between ai-work and main are skipped entirely.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_SCRIPT="$SCRIPT_DIR/review-ai-work.sh"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ ! -f "$REVIEW_SCRIPT" ]; then
    echo "❌ $REVIEW_SCRIPT not found" >&2
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

SUBMODULES_TO_REVIEW=()
echo "=== ai-work -> main review links ==="
for path in "${SUBMODULE_PATHS[@]}"; do
    if has_pending_changes "$WORKSPACE_ROOT/$path"; then
        echo "  $path: $(compare_url "$WORKSPACE_ROOT/$path")"
        SUBMODULES_TO_REVIEW+=("$path")
    else
        echo "  $path: no changes, skipping"
    fi
done

WORKSPACE_HAD_CHANGES=0
if has_pending_changes "$WORKSPACE_ROOT"; then
    echo "  workspace root: $(compare_url "$WORKSPACE_ROOT")"
    WORKSPACE_HAD_CHANGES=1
else
    echo "  workspace root: no changes, skipping"
fi
echo ""

if [ "${#SUBMODULES_TO_REVIEW[@]}" -eq 0 ] && [ "$WORKSPACE_HAD_CHANGES" -eq 0 ]; then
    echo "✅ Nothing to review anywhere."
    exit 0
fi

NO_CONFIRM=false
for arg in "$@"; do
  case "$arg" in
    --noconfirm|--no-confirm|-y)
      NO_CONFIRM=true
      ;;
  esac
done

if [ "$NO_CONFIRM" = false ]; then
    read -p "Proceed with review-ai-work.sh for each repository above? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "❌ Cancelled."
        exit 1
    fi
fi

WORKSPACE_KEY="$(git -C "$WORKSPACE_ROOT" config --get openrouter.githubapikey || true)"
if [ -z "$WORKSPACE_KEY" ]; then
    echo "❌ No openrouter.githubapikey configured on the workspace root." >&2
    echo "   Set it with: git -C \"$WORKSPACE_ROOT\" config --local openrouter.githubapikey 'YOUR_KEY_HERE'" >&2
    exit 1
fi

FAILED_REPOS=()

for name in "${SUBMODULES_TO_REVIEW[@]}"; do
    echo ""
    echo "=== Reviewing $name ==="
    if ! (cd "$WORKSPACE_ROOT/$name" && OPENROUTER_API_KEY="$WORKSPACE_KEY" "$REVIEW_SCRIPT" "$@"); then
        FAILED_REPOS+=("$name")
    fi
done

if [ "$WORKSPACE_HAD_CHANGES" -ne 0 ]; then
    echo ""
    echo "=== Reviewing workspace root ==="
    if ! (cd "$WORKSPACE_ROOT" && OPENROUTER_API_KEY="$WORKSPACE_KEY" "$REVIEW_SCRIPT" "$@"); then
        FAILED_REPOS+=("workspace root")
    fi
fi

echo ""
git -C "$SCRIPT_DIR" add "$SCRIPT_DIR/history.json" 2>/dev/null || true
git -C "$SCRIPT_DIR" commit -m "chore(history): update AI review history log" 2>/dev/null || true

if [ "${#FAILED_REPOS[@]}" -gt 0 ]; then
    echo "❌ AI code review failed for: ${FAILED_REPOS[*]}" >&2
    exit 1
fi

echo "✅ review-all-ai-work done"
