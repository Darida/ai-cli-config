#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}=== AI Workspace Setup ===${NC}\n"

DIRTY=$(git status --porcelain)
CURRENT_BRANCH=$(git branch --show-current)

# 1. Handle uncommitted changes on main (or other non-ai branches)
if [ -n "$DIRTY" ] && [ "$CURRENT_BRANCH" != "ai-work" ]; then
    echo -e "${YELLOW}Warning: You have uncommitted changes on local branch '${CURRENT_BRANCH}'.${NC}"
    read -p "Do you want to WIPE these changes to proceed? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Operation cancelled. Please commit or stash your changes first.${NC}"
        exit 1
    fi
    echo "  - Wiping uncommitted changes on ${CURRENT_BRANCH}..."
    git reset --hard HEAD >/dev/null 2>&1
    git clean -fd >/dev/null 2>&1
fi

# 2. Check if ai-work branch exists
LOCAL_EXISTS=$(git branch --list ai-work)
REMOTE_EXISTS=$(git ls-remote --heads origin ai-work)

if [ -n "$LOCAL_EXISTS" ] || [ -n "$REMOTE_EXISTS" ]; then
    echo -e "${YELLOW}Warning: The 'ai-work' branch already exists.${NC}"
    read -p "Confirm wiping all AI data, deleting the branch, and starting clean? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${RED}Operation cancelled.${NC}"
        exit 1
    fi
    
    # If we are currently on ai-work with dirty files, wipe them before checkout
    if [ "$CURRENT_BRANCH" == "ai-work" ]; then
        echo "  - Wiping uncommitted AI garbage..."
        git reset --hard HEAD >/dev/null 2>&1 || true
        git clean -fd >/dev/null 2>&1 || true
    fi
    
    echo "  - Switching to main..."
    git checkout main >/dev/null 2>&1
    
    if [ -n "$LOCAL_EXISTS" ]; then
        echo "  - Deleting local ai-work branch..."
        git branch -D ai-work
    fi
else
    # Doesn't exist, safely switch to main
    git checkout main >/dev/null 2>&1
fi

# 3. Sync and create fresh branch
echo -e "${YELLOW}[2/3] Syncing main with remote...${NC}"
git fetch origin
git reset --hard origin/main

echo -e "${YELLOW}[3/3] Creating fresh ai-work branch...${NC}"
git checkout -b ai-work main
git push -u origin ai-work --force

echo -e "${GREEN}=== Setup Complete ===${NC}"
echo -e "${GREEN}✓ You are now on a completely clean 'ai-work' branch.${NC}"
