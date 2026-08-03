#!/bin/bash
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

main() {
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
    echo -e "${RED}Error: Uncommitted changes detected. Please commit or stash your changes first.${NC}"
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
  echo -e "${GREEN}✓ ai-work branch state is clean${NC}\n"

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

  echo -e "${YELLOW}[3/8] Generating PR title and description from diff...${NC}"
  NON_SENT_IMAGE_EXTENSIONS=('*.png' '*.jpg' '*.jpeg' '*.gif' '*.webp' '*.bmp' '*.ico')
  IMAGE_PATHSPECS=()
  for pattern in "${NON_SENT_IMAGE_EXTENSIONS[@]}"; do
    IMAGE_PATHSPECS+=(":!${pattern}")
  done
  DIFF_CONTENT=$(git diff --diff-filter=d origin/main...HEAD -- . ':!go.sum' "${IMAGE_PATHSPECS[@]}")

  # Deleted files can be large (e.g. a removed source file) and their full
  # removed content is rarely useful for a PR description — list names only.
  DELETED_FILES=$(git diff --diff-filter=D --name-only origin/main...HEAD -- . ':!go.sum' "${IMAGE_PATHSPECS[@]}")
  if [ -n "$DELETED_FILES" ]; then
    DIFF_CONTENT="${DIFF_CONTENT}"$'\n\n'"Deleted files (contents omitted, filenames only):"$'\n'"${DELETED_FILES}"
  fi

  CHANGED_IMAGES=$(git diff --name-only origin/main...HEAD -- "${NON_SENT_IMAGE_EXTENSIONS[@]}")
  if [ -n "$CHANGED_IMAGES" ]; then
    DIFF_CONTENT="${DIFF_CONTENT}"$'\n\n'"Image files changed (contents omitted, filenames only):"$'\n'"${CHANGED_IMAGES}"
  fi

  # Load prompt template and substitute diff content
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROMPT_FILE="$SCRIPT_DIR/approve-ai-work.commit_description_promt.md"
  if [ ! -f "$PROMPT_FILE" ]; then
    echo -e "${RED}Error: Prompt file not found at $PROMPT_FILE${NC}"
    exit 1
  fi

  PROMPT_CONTENT=$(cat "$PROMPT_FILE")
  PROMPT_CONTENT="${PROMPT_CONTENT//\{DIFF_CONTENT\}/$DIFF_CONTENT}"

  echo "  - Calling AI API (OpenRouter)..."
  PROMPT_TMPFILE="$(mktemp)"
  PAYLOAD_TMPFILE="$(mktemp)"
  RESPONSE_TMPFILE="$(mktemp)"
  trap 'rm -f "$PROMPT_TMPFILE" "$PAYLOAD_TMPFILE" "$RESPONSE_TMPFILE"' EXIT
  printf '%s' "$PROMPT_CONTENT" > "$PROMPT_TMPFILE"

  MODEL_NAME="openrouter/free"
  PROMPT_SIZE_BYTES=$(wc -c < "$PROMPT_TMPFILE" | tr -d ' ')
  PROMPT_SIZE_LIMIT_BYTES=$((50 * 1024))
  if [ "$PROMPT_SIZE_BYTES" -gt "$PROMPT_SIZE_LIMIT_BYTES" ]; then
    echo -e "${YELLOW}Warning: formatted prompt is $((PROMPT_SIZE_BYTES / 1024))KB, over the 50KB threshold.${NC}"
    echo -e "${YELLOW}A paid model (openrouter/auto) will be used for this PR description.${NC}"
    read -p "Send it to the OpenRouter API anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo -e "${RED}Aborted before sending request.${NC}"
      exit 1
    fi
    MODEL_NAME="openrouter/auto"
  fi

  jq -n --rawfile text "$PROMPT_TMPFILE" --arg model "$MODEL_NAME" '{model: $model, messages: [{role: "user", content: $text}]}' > "$PAYLOAD_TMPFILE"

  HTTP_CODE=$(curl -s -w "%{http_code}" -o "$RESPONSE_TMPFILE" --connect-timeout 15 --max-time 240 -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    -H "Content-Type: application/json" \
    --data-binary "@$PAYLOAD_TMPFILE" || echo "000")

  API_RESPONSE=$(cat "$RESPONSE_TMPFILE" 2>/dev/null || echo "")
  AI_OUTPUT=$(extract_pr_description_content "$RESPONSE_TMPFILE")

  if [ -z "$AI_OUTPUT" ]; then
    handle_api_failure "$HTTP_CODE" "$API_RESPONSE"
  fi

  # Parse TITLE and DESCRIPTION from output
  PR_TITLE=$(echo "$AI_OUTPUT" | sed -n 's/^TITLE: //p' | head -1)
  # Extract everything after "DESCRIPTION:" preserving newlines and formatting
  PR_DESCRIPTION=$(echo "$AI_OUTPUT" | awk '/^DESCRIPTION:/ {flag=1; sub(/^DESCRIPTION:[ ]*/, ""); if (NF) print; next} flag')

  if [ -z "$PR_TITLE" ] || [ -z "$PR_DESCRIPTION" ]; then
    echo -e "${RED}Error: Invalid AI output format. Expected TITLE: ... DESCRIPTION: ...${NC}"
    echo -e "${RED}Got:${NC}"
    echo "$AI_OUTPUT"
    exit 1
  fi

  echo -e "${GREEN}✓ PR title and description generated${NC}\n"

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

extract_pr_description_content() {
  local response_file="$1"
  jq -r '.choices[0].message.content // empty' "$response_file" 2>/dev/null || echo ""
}

handle_api_failure() {
  local http_code="$1"
  local response="$2"
  echo -e "${RED}[ERROR] Failed to generate PR title and description (HTTP Status: ${http_code})${NC}"
  local clean_error
  clean_error=$(echo "$response" | sed '/^[[:space:]]*$/d' | head -n 30)
  if [ -n "$clean_error" ]; then
    echo -e "${RED}[ERROR] Response Body:${NC}\n${clean_error}"
  fi
  exit 1
}

main "$@"
