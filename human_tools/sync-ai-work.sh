#!/bin/bash
# Safely brings ai-work up to date: picks up any commits already pushed to
# origin/ai-work (e.g. from another machine), then merges in anything new
# on main. Always merges, never rebases -- ai-work is a shared branch
# (synced across machines), and rebasing would rewrite commit hashes
# anyone else has already fetched. Aborts cleanly and leaves the tree
# untouched on any real conflict.
#
# If this repo is checked out as a submodule of a larger workspace (as it
# often is), also syncs every sibling submodule in that workspace the same
# way -- fetch, fast-forward its own branch, merge in main, push -- each on
# whatever branch it's currently checked out to. A submodule with
# uncommitted changes is skipped (with a warning) rather than aborting the
# whole run, since sibling project work in progress shouldn't block this.
#
# Anchors to this script's own repo root (via -C) rather than the caller's
# cwd, since running by absolute path from the workspace root would
# otherwise point bare `git` commands at the wrong repo.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

main() {
  local script_dir repo workspace_root
  script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  repo="$(git -C "$script_dir" rev-parse --show-toplevel)"

  sync_ai_work "$repo"

  workspace_root="$(git -C "$repo" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
  [ -z "$workspace_root" ] && return 0

  echo -e "${YELLOW}=== Syncing sibling submodules in $workspace_root ===${NC}\n"
  while IFS='|' read -r path name; do
    [ -z "$path" ] && continue
    sync_generic_repo "$path" "$name"
  done < <(list_other_submodules "$workspace_root" "$repo")

  sync_generic_repo "$workspace_root" "workspace root"
}

# The specialized, stricter sync for this repo: requires a clean tree,
# insists on the ai-work branch, and merges main into it specifically.
sync_ai_work() {
  local repo="$1"

  echo -e "${YELLOW}=== Sync ai-work ($repo) ===${NC}\n"

  echo -e "${YELLOW}[1/4] Verifying no uncommitted changes...${NC}"
  if ! git -C "$repo" diff-index --quiet HEAD --; then
    echo -e "${RED}Error: Uncommitted changes detected. Commit or stash first.${NC}"
    git -C "$repo" status
    exit 1
  fi
  echo -e "${GREEN}✓ Working tree clean${NC}\n"

  echo -e "${YELLOW}[2/4] Fetching origin...${NC}"
  git -C "$repo" fetch origin
  echo -e "${GREEN}✓ Fetched${NC}\n"

  local current_branch
  current_branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"
  if [ "$current_branch" != "ai-work" ]; then
    echo "  - Currently on '$current_branch', switching to ai-work..."
    git -C "$repo" checkout ai-work
  fi

  echo -e "${YELLOW}[3/4] Syncing ai-work with origin/ai-work...${NC}"
  local behind
  behind="$(git -C "$repo" rev-list --count HEAD..origin/ai-work)"
  if [ "$behind" -gt 0 ]; then
    echo "  - $behind commit(s) behind origin/ai-work, fast-forwarding..."
    git -C "$repo" merge --ff-only origin/ai-work
  else
    echo "  - Already up to date with origin/ai-work"
  fi
  echo -e "${GREEN}✓ ai-work synced${NC}\n"

  echo -e "${YELLOW}[4/4] Merging origin/main into ai-work...${NC}"
  local behind_main
  behind_main="$(git -C "$repo" rev-list --count HEAD..origin/main)"
  if [ "$behind_main" -eq 0 ]; then
    echo -e "${GREEN}✓ Already up to date with origin/main, nothing to merge${NC}\n"
  else
    echo "  - $behind_main commit(s) behind origin/main, merging..."
    if ! git -C "$repo" merge origin/main --no-edit; then
      echo -e "${RED}Error: Merge conflict merging origin/main into ai-work. Aborting merge.${NC}" >&2
      git -C "$repo" merge --abort
      echo -e "${YELLOW}Your ai-work branch is untouched. Resolve manually with:${NC}"
      echo -e "  ${GREEN}git -C \"$repo\" merge origin/main${NC}"
      exit 1
    fi
    echo -e "${GREEN}✓ Merged${NC}\n"
  fi

  local ahead
  ahead="$(git -C "$repo" rev-list --count origin/ai-work..HEAD)"
  if [ "$ahead" -eq 0 ]; then
    echo -e "${GREEN}=== ai-work already in sync, nothing to push ===${NC}\n"
    return 0
  fi

  echo -e "${YELLOW}Pushing ai-work...${NC}"
  git -C "$repo" push origin ai-work
  echo -e "${GREEN}=== ai-work synced and pushed ===${NC}\n"
}

# Generic best-effort sync: fetch, fast-forward the repo's own branch,
# merge in main if it's not already on main, push if ahead. Skips (rather
# than fails) on uncommitted changes or a merge conflict, so one messy
# sibling submodule doesn't block syncing the rest.
sync_generic_repo() {
  local repo="$1" name="$2"

  if ! git -C "$repo" diff-index --quiet HEAD --; then
    echo -e "${YELLOW}⚠ $name: uncommitted changes, skipping${NC}"
    return 0
  fi

  git -C "$repo" fetch origin --quiet 2>/dev/null || true

  local branch
  branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD)"

  if git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
    local behind
    behind="$(git -C "$repo" rev-list --count "HEAD..origin/$branch")"
    if [ "$behind" -gt 0 ]; then
      echo "  - $name: fast-forwarding $behind commit(s) from origin/$branch..."
      git -C "$repo" merge --ff-only "origin/$branch"
    fi
  fi

  if [ "$branch" != "main" ] && git -C "$repo" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
    local behind_main
    behind_main="$(git -C "$repo" rev-list --count HEAD..origin/main)"
    if [ "$behind_main" -gt 0 ]; then
      echo "  - $name: merging $behind_main commit(s) from origin/main..."
      if ! git -C "$repo" merge origin/main --no-edit; then
        echo -e "${RED}✗ $name: merge conflict, aborting merge, skipping${NC}" >&2
        git -C "$repo" merge --abort
        return 0
      fi
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

# name|path pairs for every submodule of workspace_root, excluding the one
# this script itself lives in (already handled by sync_ai_work above).
list_other_submodules() {
  local workspace_root="$1" own_repo="$2"
  local name path resolved

  if [ -f "$workspace_root/.gitmodules" ]; then
    while IFS= read -r name; do
      [ -z "$name" ] && continue
      path="$workspace_root/$name"
      [ -e "$path/.git" ] || continue
      resolved="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
      [ "$resolved" = "$own_repo" ] && continue
      echo "$path|$name"
    done < <(git config --file "$workspace_root/.gitmodules" --get-regexp '\.path$' | awk '{print $2}')
  fi
}

main "$@"
