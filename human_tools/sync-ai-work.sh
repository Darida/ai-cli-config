#!/bin/bash
# Safely syncs the repo you're standing in, plus every submodule beneath it
# (recursively) -- e.g. run from a workspace root, it syncs the workspace
# and all its project submodules in one shot.
#
# Always merges, never rebases -- these are shared branches synced across
# machines, and rebasing would rewrite commit hashes anyone else has
# already fetched.
#
# The repo you're standing in must have a clean tree, or the whole run
# aborts before touching anything. Submodules found underneath are
# best-effort: one with uncommitted changes, or a merge conflict, is
# skipped (with a warning) rather than blocking the rest of the tree.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

main() {
  local cwd_repo
  cwd_repo="$(git rev-parse --show-toplevel)"
  sync_repo "$cwd_repo" "$(basename "$cwd_repo")" "true"
}

# Recursively syncs $repo, then every submodule beneath it. $is_root
# controls whether uncommitted changes / a merge conflict abort the whole
# script (true, only for the repo main() was invoked from) or just skip
# this one repo and move on (false, for everything discovered underneath).
sync_repo() {
  local repo="$1" name="$2" is_root="$3"

  echo -e "${YELLOW}=== $name ($repo) ===${NC}"

  if ! git -C "$repo" diff-index --quiet HEAD --; then
    if [ "$is_root" = "true" ]; then
      echo -e "${RED}Error: Uncommitted changes detected. Commit or stash first.${NC}"
      git -C "$repo" status
      exit 1
    fi
    echo -e "${YELLOW}⚠ $name: uncommitted changes, skipping${NC}\n"
    return 0
  fi

  git -C "$repo" fetch origin --quiet 2>/dev/null || true

  if git -C "$repo" rev-parse --verify --quiet refs/remotes/origin/ai-work >/dev/null; then
    sync_branch "$repo" "$name" "$is_root" "ai-work" "main"
  else
    local current_branch
    current_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
    sync_branch "$repo" "$name" "$is_root" "$current_branch" "main"
  fi

  echo ""

  local sub_path sub_name
  while IFS='|' read -r sub_path sub_name; do
    [ -z "$sub_path" ] && continue
    sync_repo "$sub_path" "$sub_name" "false"
  done < <(list_submodules "$repo")
}

# Fast-forwards $repo to origin/$branch (switching to it first if needed),
# merges origin/$main_branch into it, and pushes if anything moved.
sync_branch() {
  local repo="$1" name="$2" is_root="$3" branch="$4" main_branch="$5"

  local current_branch
  current_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
  if [ "$current_branch" != "$branch" ]; then
    echo "  - $name: switching to $branch..."
    git -C "$repo" checkout "$branch"
  fi

  if git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
    local behind
    behind="$(git -C "$repo" rev-list --count "HEAD..origin/$branch")"
    if [ "$behind" -gt 0 ]; then
      if git -C "$repo" merge --ff-only --quiet "origin/$branch" 2>/dev/null; then
        echo "  - $name: fast-forwarded $behind commit(s) from origin/$branch"
      else
        echo "  - $name: origin/$branch has diverged, merging $behind commit(s)..."
        merge_or_skip "$repo" "$name" "$is_root" "origin/$branch" || return 0
      fi
    fi
  fi

  if [ "$branch" != "$main_branch" ] && git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$main_branch" >/dev/null; then
    local behind_main
    behind_main="$(git -C "$repo" rev-list --count "HEAD..origin/$main_branch")"
    if [ "$behind_main" -gt 0 ]; then
      echo "  - $name: merging $behind_main commit(s) from origin/$main_branch..."
      merge_or_skip "$repo" "$name" "$is_root" "origin/$main_branch" || return 0
    fi
  fi

  if git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
    local ahead
    ahead="$(git -C "$repo" rev-list --count "origin/$branch..HEAD")"
    if [ "$ahead" -gt 0 ]; then
      echo "  - $name: pushing $branch..."
      git -C "$repo" push origin "$branch"
    fi
  fi

  echo -e "${GREEN}✓ $name synced${NC}"
}

# On conflict, aborts the merge (tree left untouched) and either exits the
# whole script (root repo) or returns 1 so the caller skips the rest of this
# repo.
merge_or_skip() {
  local repo="$1" name="$2" is_root="$3" ref="$4"

  if git -C "$repo" merge "$ref" --no-edit; then
    return 0
  fi

  git -C "$repo" merge --abort
  if [ "$is_root" = "true" ]; then
    echo -e "${RED}Error: Merge conflict merging $ref. Aborting merge, tree untouched.${NC}" >&2
    echo -e "${YELLOW}Resolve manually with:${NC} git -C \"$repo\" merge $ref"
    exit 1
  fi
  echo -e "${RED}✗ $name: merge conflict merging $ref, skipping${NC}" >&2
  return 1
}

# name|path pairs for every direct submodule of $repo.
list_submodules() {
  local repo="$1"
  local name path

  if [ -f "$repo/.gitmodules" ]; then
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      path="$repo/$name"
      [ -e "$path/.git" ] || continue
      echo "$path|$name"
    done < <(git config --file "$repo/.gitmodules" --get-regexp '\.path$' | awk '{print $2}')
  fi
}

main "$@"
