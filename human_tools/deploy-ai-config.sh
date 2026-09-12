#!/bin/bash
# Deploys .claude/ and .gemini/ from this checkout (the local working tree,
# not whatever is committed/pushed) to $HOME/.claude and $HOME/.gemini,
# overwriting the originals there.
#
# For every file under the source trees, diffs it against the current file
# at the destination (if any) and prints the diff before touching anything.
# For .claude/hooks, .gemini/hooks and .gemini/policies specifically, the
# destination is fully mirrored: any file under those paths that has no
# counterpart in source is deleted. Everything else under .claude/ and
# .gemini/ is add/update only -- unrelated files already at the destination
# (caches, sessions, credentials, etc.) are left alone.
#
# Usage: ./deploy-ai-config.sh [--dry-run]
#   --dry-run   print the diffs and the add/update/delete plan, change nothing
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TOP_DIRS=(".claude" ".gemini")
MIRROR_SUBDIRS=(".claude/hooks" ".gemini/hooks" ".gemini/policies")

copy_src=()
copy_dst=()
copy_status=()
delete_path=()

# Diffs every file under $REPO_ROOT/<top> against $HOME/<top> for each top
# dir in TOP_DIRS, printing a diff for anything that would change and
# queuing it into copy_src/copy_dst/copy_status.
plan_copies() {
  local top src dst rel srcfile dstfile
  for top in "${TOP_DIRS[@]}"; do
    src="$REPO_ROOT/$top"
    dst="$HOME/$top"
    [ -d "$src" ] || { echo -e "${RED}Error: source $src not found${NC}" >&2; exit 1; }

    while IFS= read -r -d '' rel; do
      rel="${rel#./}"
      srcfile="$src/$rel"
      dstfile="$dst/$rel"
      if [ -f "$dstfile" ]; then
        if ! cmp -s "$srcfile" "$dstfile"; then
          echo -e "${YELLOW}--- $top/$rel ---${NC}"
          diff -u --label "current: ~/$top/$rel" --label "new: $top/$rel" "$dstfile" "$srcfile" || true
          copy_src+=("$srcfile"); copy_dst+=("$dstfile"); copy_status+=("changed  $top/$rel")
        fi
      else
        copy_src+=("$srcfile"); copy_dst+=("$dstfile"); copy_status+=("new      $top/$rel")
      fi
    done < <(cd "$src" && find . -type f -print0)
  done
}

# For each dir in MIRROR_SUBDIRS, finds files under $HOME/<dir> that have no
# counterpart under $REPO_ROOT/<dir> and queues them into delete_path.
plan_deletes() {
  local m src dst rel
  for m in "${MIRROR_SUBDIRS[@]}"; do
    src="$REPO_ROOT/$m"
    dst="$HOME/$m"
    [ -d "$src" ] || { echo -e "${RED}Error: source $src not found${NC}" >&2; exit 1; }
    [ -d "$dst" ] || continue

    while IFS= read -r -d '' rel; do
      rel="${rel#./}"
      [ -f "$src/$rel" ] || delete_path+=("$dst/$rel")
    done < <(cd "$dst" && find . -type f -print0)
  done
}

apply() {
  local i
  for i in "${!copy_src[@]}"; do
    mkdir -p "$(dirname "${copy_dst[$i]}")"
    cp "${copy_src[$i]}" "${copy_dst[$i]}"
  done
  for p in "${delete_path[@]}"; do
    rm -f "$p"
  done
}

main() {
  local dry_run=false arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run|-n) dry_run=true ;;
    esac
  done

  echo -e "${YELLOW}Diffing $REPO_ROOT against $HOME ...${NC}\n"
  plan_copies
  plan_deletes

  echo ""
  echo "Summary: ${#copy_status[@]} to add/update, ${#delete_path[@]} to delete"
  local s
  for s in "${copy_status[@]}"; do echo "  + $s"; done
  for p in "${delete_path[@]}"; do echo "  - ${p/#$HOME/~}"; done

  if [ ${#copy_status[@]} -eq 0 ] && [ ${#delete_path[@]} -eq 0 ]; then
    echo -e "${GREEN}Nothing to do -- $HOME already matches source.${NC}"
    exit 0
  fi

  if [ "$dry_run" = true ]; then
    echo -e "${YELLOW}Dry run -- nothing was changed.${NC}"
    exit 0
  fi

  read -p "Apply these changes? (y/n) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 1; }

  apply
  echo -e "${GREEN}✓ Deployed to $HOME${NC}"
}

main "$@"
