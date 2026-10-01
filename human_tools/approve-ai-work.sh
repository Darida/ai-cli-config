#!/bin/bash
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

main() {
  for arg in "$@"; do
    log_error "Error: unknown argument: $arg"
    exit 2
  done

  OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$(git config --get openrouter.githubapikey || echo "")}"
  if [ -z "$OPENROUTER_API_KEY" ]; then
    echo -e "${RED}Error: OpenRouter API key not found for this project.${NC}"
    echo -e "To set it for this specific repository only, run:"
    echo -e "git config --local openrouter.githubapikey 'YOUR_KEY_HERE'"
    exit 1
  fi

  echo -e "${YELLOW}=== AI Work Approval Workflow ===${NC}\n"

  # 1. Verify no unsubmitted changes in local git and check branch state
  echo -e "${YELLOW}[1/8] Verifying no uncommitted changes and branch state...${NC}"
  if ! git diff-index --quiet HEAD --; then
    local summary
    summary=$(format_uncommitted_changes_summary)
    log_error "Error: Uncommitted changes detected (${summary}). Please commit or stash your changes first."
    git status
    exit 1
  fi
  echo -e "${GREEN}✓ No uncommitted changes${NC}"

  # Check if ai-work has diverged from main
  echo "  - Checking if ai-work has diverged from main..."
  MERGE_BASE=$(git merge-base ai-work origin/main)
  if [ "$MERGE_BASE" != "$(git rev-parse origin/main)" ] && [ "$MERGE_BASE" != "$(git rev-parse ai-work)" ]; then
    REPO_PATH="$(git rev-parse --show-toplevel)"
    echo -e "${RED}Error: ai-work and main have diverged. Commits exist that are not shared.${NC}"
    echo -e "${YELLOW}main likely has commits ai-work doesn't (e.g. pushed straight to main,${NC}"
    echo -e "${YELLOW}bypassing this workflow). To reconcile, run (full path included since${NC}"
    echo -e "${YELLOW}you may not be sitting in this repo's directory):${NC}"
    echo -e "  ${GREEN}git -C \"$REPO_PATH\" merge origin/main --no-edit || git -C \"$REPO_PATH\" merge --abort${NC}"
    echo -e "${YELLOW}That merges cleanly if there's no real conflict (--no-edit skips the${NC}"
    echo -e "${YELLOW}commit-message editor, so it won't open an interactive window), or${NC}"
    echo -e "${YELLOW}aborts back to the exact state you're in now if there is — safe either${NC}"
    echo -e "${YELLOW}way. If it merges, push it and re-run this script:${NC}"
    echo -e "  ${GREEN}git -C \"$REPO_PATH\" push origin ai-work${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓ ai-work branch state is clean${NC}"
  echo -e "  Preview: $(compare_url)\n"

  # 2. Close any existing old PRs from ai-work
  echo -e "${YELLOW}[2/8] Checking for and closing any existing PRs...${NC}"
  EXISTING_PR=$(gh pr list --head ai-work --base main --state open --json number --jq '.[0].number' 2>/dev/null || true)
  if [ -n "$EXISTING_PR" ]; then
    echo "  - Found existing PR #$EXISTING_PR, closing it..."
    gh pr close "$EXISTING_PR"
    echo -e "${GREEN}✓ Closed old PR #$EXISTING_PR${NC}"
  else
    echo -e "${GREEN}✓ No existing PRs to close${NC}"
  fi
  echo ""

  log_info "[3/8] Generating PR title and description from diff..."
  DIFF_CONTENT=$(extract_git_diff_for_approval)

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROMPT_FILE="$SCRIPT_DIR/approve-ai-work.commit_description_promt.md"
  SCHEMA_FILE="$SCRIPT_DIR/approve-ai-work.commit_description.schema.json"

  if [ ! -f "$PROMPT_FILE" ]; then
    log_error "Error: Prompt file not found at $PROMPT_FILE"
    exit 1
  fi
  if [ ! -f "$SCHEMA_FILE" ]; then
    log_error "Error: Schema file not found at $SCHEMA_FILE"
    exit 1
  fi

  PROMPT_CONTENT=$(cat "$PROMPT_FILE")
  PROMPT_CONTENT="${PROMPT_CONTENT//\{DIFF_CONTENT\}/$DIFF_CONTENT}"

  log_info "  - Calling AI API (OpenRouter via openrouterclient)..."
  PROMPT_TMPFILE="$(mktemp)"
  trap 'rm -f "$PROMPT_TMPFILE"' EXIT
  printf '%s' "$PROMPT_CONTENT" > "$PROMPT_TMPFILE"

  PR_CONTENT=$("$SCRIPT_DIR/generate-content.sh" \
    --prompt="$PROMPT_TMPFILE" \
    --schema="$SCHEMA_FILE" \
    --schema-name="pr_description_response" \
    --tag=cl_description \
    --key="$OPENROUTER_API_KEY")
  PR_TITLE=$(jq -r '.title' <<< "$PR_CONTENT")
  PR_DESCRIPTION=$(jq -r '.description' <<< "$PR_CONTENT")

  log_success "✓ PR title and description generated\n"

  # 4. Validate and request approval for generated content
  echo -e "${YELLOW}[4/8] Validating and requesting approval...${NC}"
  TITLE_LENGTH=${#PR_TITLE}
  DESCRIPTION_LENGTH=${#PR_DESCRIPTION}

  if [ "$TITLE_LENGTH" -ge 250 ]; then
    echo -e "${RED}Error: PR title is too long (${TITLE_LENGTH} chars, max 250)${NC}"
    exit 1
  fi

  if [ "$DESCRIPTION_LENGTH" -ge 10000 ]; then
    echo -e "${RED}Error: PR description is too long (${DESCRIPTION_LENGTH} chars, max 10000)${NC}"
    exit 1
  fi

  echo -e "${YELLOW}Proposed PR Title (${TITLE_LENGTH}/250 chars):${NC}"
  echo -e "  ${GREEN}${PR_TITLE}${NC}\n"

  echo -e "${YELLOW}Proposed PR Description (${DESCRIPTION_LENGTH}/10000 chars):${NC}"
  echo -e "${PR_DESCRIPTION}\n"

  read -p "Do you approve these changes? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Approval denied. Exiting.${NC}"
    exit 1
  fi

  echo -e "${GREEN}✓ Changes approved${NC}\n"

  # 5. Create pull request
  echo -e "${YELLOW}[5/8] Creating pull request from ai-work to main...${NC}"
  PR_URL=$(gh pr create --base main --head ai-work --title "$PR_TITLE" --body "$PR_DESCRIPTION" 2>&1 | grep -o 'https://github.com[^[:space:]]*' || true)
  if [ -z "$PR_URL" ]; then
    # Try to get the PR number if it already exists
    PR_NUMBER=$(gh pr view ai-work --json number --jq .number 2>/dev/null || true)
    if [ -z "$PR_NUMBER" ]; then
      echo -e "${RED}Error: Failed to create PR${NC}"
      exit 1
    fi
    PR_URL="https://github.com/$(git config --get remote.origin.url | sed 's/.*:\|\.git//g')/pull/$PR_NUMBER"
  fi
  echo -e "${GREEN}✓ PR created: $PR_URL${NC}\n"

  # 6. Approve the PR
  echo -e "${YELLOW}[6/8] Approving pull request...${NC}"
  gh pr review --approve "$PR_URL" 2>/dev/null || gh pr review --approve --repo . 2>/dev/null || echo -e "${YELLOW}Note: Could not approve (may require additional permissions)${NC}"
  echo -e "${GREEN}✓ PR approved${NC}\n"

  # 7. Merge with squash
  echo -e "${YELLOW}[7/8] Merging PR with squash...${NC}"
  gh pr merge --squash --delete-branch --subject "$PR_TITLE" --body "$PR_DESCRIPTION" "$PR_URL"
  echo -e "${GREEN}✓ PR merged with squash${NC}\n"

  # 8. Reset ai-work branch history
  echo -e "${YELLOW}[8/8] Resetting ai-work branch history...${NC}"

  # Switch to main and get latest
  echo "  - Switching to main and syncing with remote..."
  git checkout main
  git fetch origin main
  git reset --hard origin/main

  # Force ai-work to match main (resetting history)
  echo "  - Resetting ai-work to match main..."
  git branch -f ai-work main

  # Switch to ai-work
  git checkout ai-work

  # Force push to reset remote history
  echo "  - Force-pushing to reset remote history..."
  git push origin ai-work --force

  echo -e "${GREEN}✓ Branch history reset${NC}\n"

  echo -e "${GREEN}=== Workflow Complete ===${NC}"
  echo -e "${GREEN}✓ PR merged successfully${NC}"
  echo -e "${GREEN}✓ ai-work branch history reset and ready for new work${NC}"
}

compare_url() {
  local remote_url org_repo
  remote_url="$(git remote get-url origin)"
  org_repo="$(echo "$remote_url" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')"
  echo "https://github.com/$org_repo/compare/ai-work?expand=1"
}

extract_git_diff_for_approval() {
  local non_sent_image_extensions=('*.png' '*.jpg' '*.jpeg' '*.gif' '*.webp' '*.bmp' '*.ico')
  local image_pathspecs=()
  for pattern in "${non_sent_image_extensions[@]}"; do
    image_pathspecs+=(":!${pattern}")
  done

  local diff_content
  diff_content=$(git diff --diff-filter=d origin/main...HEAD -- . ':!go.sum' "${image_pathspecs[@]}")

  local deleted_files
  deleted_files=$(git diff --diff-filter=D --name-only origin/main...HEAD -- . ':!go.sum' "${image_pathspecs[@]}")
  if [ -n "$deleted_files" ]; then
    diff_content="${diff_content}"$'\n\n'"Deleted files (contents omitted, filenames only):"$'\n'"${deleted_files}"
  fi

  local changed_images
  changed_images=$(git diff --name-only origin/main...HEAD -- "${non_sent_image_extensions[@]}")
  if [ -n "$changed_images" ]; then
    diff_content="${diff_content}"$'\n\n'"Image files changed (contents omitted, filenames only):"$'\n'"${changed_images}"
  fi

  echo "$diff_content"
}

format_uncommitted_changes_summary() {
  local uncommitted_files=()
  mapfile -t uncommitted_files < <(git status --porcelain | sed -E 's/^.. //' | grep -v '^[[:space:]]*$')
  local count="${#uncommitted_files[@]}"
  local file_list
  file_list=$(printf '%s, ' "${uncommitted_files[@]}")
  file_list="${file_list%, }"
  echo "${count} file(s) modified: ${file_list}"
}

timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

log_info() {
  echo -e "${YELLOW}[$(timestamp)] $1${NC}"
}

log_success() {
  echo -e "${GREEN}[$(timestamp)] $1${NC}"
}

log_error() {
  echo -e "${RED}[$(timestamp)] $1${NC}"
}

main "$@"
