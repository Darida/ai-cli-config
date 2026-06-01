#!/bin/bash
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== AI Work Approval Workflow ===${NC}\n"

# 1. Verify no unsubmitted changes in local git
echo -e "${YELLOW}[1/6] Verifying no uncommitted changes...${NC}"
if ! git diff-index --quiet HEAD --; then
  echo -e "${RED}Error: Uncommitted changes detected. Please commit or stash your changes first.${NC}"
  git status
  exit 1
fi
echo -e "${GREEN}✓ No uncommitted changes${NC}\n"

# 2. Generate PR description using gemini CLI
echo -e "${YELLOW}[2/6] Generating PR description from diff...${NC}"
PR_DESCRIPTION=$(git diff main...HEAD -- . ':!go.sum' | gemini "SYSTEM: You are an isolated text processor. Tools, search, and external access are strictly disabled for this request. Rely ONLY on the text piped below. Write a professional GitHub PR summary in clean markdown bullet points based on this diff:\n\n\$(cat -)")
if [ -z "$PR_DESCRIPTION" ]; then
  echo -e "${RED}Error: Failed to generate PR description with gemini${NC}"
  exit 1
fi
echo -e "${GREEN}✓ PR description generated${NC}\n"

# 3. Create pull request
echo -e "${YELLOW}[3/6] Creating pull request from ai-work to main...${NC}"
PR_URL=$(gh pr create --base main --head ai-work --title "AI Work" --body "$PR_DESCRIPTION" --fill 2>&1 | grep -o 'https://github.com[^[:space:]]*' || true)
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

# 4. Approve the PR
echo -e "${YELLOW}[4/6] Approving pull request...${NC}"
gh pr review --approve "$PR_URL" 2>/dev/null || gh pr review --approve --repo . 2>/dev/null || echo -e "${YELLOW}Note: Could not approve (may require additional permissions)${NC}"
echo -e "${GREEN}✓ PR approved${NC}\n"

# 5. Merge with squash
echo -e "${YELLOW}[5/6] Merging PR with squash...${NC}"
gh pr merge --squash --delete-branch --auto "$PR_URL" 2>/dev/null || gh pr merge --squash --delete-branch "$PR_URL" 2>/dev/null
echo -e "${GREEN}✓ PR merged with squash${NC}\n"

# 6. Reset ai-work branch history
echo -e "${YELLOW}[6/6] Resetting ai-work branch history...${NC}"

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
