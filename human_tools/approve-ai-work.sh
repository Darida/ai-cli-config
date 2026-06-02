#!/bin/bash
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== AI Work Approval Workflow ===${NC}\n"

# 1. Verify no unsubmitted changes in local git
echo -e "${YELLOW}[1/8] Verifying no uncommitted changes...${NC}"
if ! git diff-index --quiet HEAD --; then
  echo -e "${RED}Error: Uncommitted changes detected. Please commit or stash your changes first.${NC}"
  git status
  exit 1
fi
echo -e "${GREEN}✓ No uncommitted changes${NC}\n"

# 2. Close any existing old PRs from ai-work
echo -e "${YELLOW}[2/8] Checking for and closing any existing PRs...${NC}"
EXISTING_PR=$(gh pr list --head ai-work --base main --state open --json number --jq '.[0].number' 2>/dev/null || true)
if [ -n "$EXISTING_PR" ]; then
  echo "  - Found existing PR #$EXISTING_PR, closing it..."
  gh pr close "$EXISTING_PR" --delete-branch
  echo -e "${GREEN}✓ Closed old PR #$EXISTING_PR${NC}"
else
  echo -e "${GREEN}✓ No existing PRs to close${NC}"
fi
echo ""

# 3. Generate PR title and description using gemini CLI
echo -e "${YELLOW}[3/8] Generating PR title and description from diff...${NC}"
DIFF_CONTENT=$(git diff main...HEAD -- . ':!go.sum')

# Load prompt template and substitute diff content
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/approve-ai-work.commit_description_promt.md"
if [ ! -f "$PROMPT_FILE" ]; then
  echo -e "${RED}Error: Prompt file not found at $PROMPT_FILE${NC}"
  exit 1
fi

PROMPT_CONTENT=$(cat "$PROMPT_FILE")
PROMPT_CONTENT="${PROMPT_CONTENT//\{DIFF_CONTENT\}/$DIFF_CONTENT}"

GEMINI_OUTPUT=$(echo "$PROMPT_CONTENT" | gemini)

if [ -z "$GEMINI_OUTPUT" ]; then
  echo -e "${RED}Error: Failed to generate PR title and description with gemini${NC}"
  exit 1
fi

# Parse TITLE and DESCRIPTION from output
PR_TITLE=$(echo "$GEMINI_OUTPUT" | sed -n 's/^TITLE: //p' | head -1)
# Extract everything after "DESCRIPTION:" preserving newlines and formatting
PR_DESCRIPTION=$(echo "$GEMINI_OUTPUT" | awk '/^DESCRIPTION:/ {flag=1; sub(/^DESCRIPTION:[ ]*/, ""); if (NF) print; next} flag')

if [ -z "$PR_TITLE" ] || [ -z "$PR_DESCRIPTION" ]; then
  echo -e "${RED}Error: Invalid gemini output format. Expected TITLE: ... DESCRIPTION: ...${NC}"
  echo -e "${RED}Got:${NC}"
  echo "$GEMINI_OUTPUT"
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
echo "  - Switching to main and pulling latest..."
git checkout main
git pull origin main

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
