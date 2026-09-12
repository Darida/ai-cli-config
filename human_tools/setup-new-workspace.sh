#!/bin/bash
# Initialize AI agent configuration for a new workspace repo
# Run from your project root directory
# This script:
# 1. Creates an empty AGENTS.md (fill in project-specific rules by hand)
# 2. Creates CLAUDE.md as a symbolic link to AGENTS.md
# 3. Copies the pre-push hook from ai-cli-config's own git/hooks/pre-push
# 4. Commits all files to git

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRE_PUSH_HOOK="$SCRIPT_DIR/../git/hooks/pre-push"

# Verify we're in a git repository
if [ ! -d .git ]; then
    echo "❌ Error: Not in a git repository root"
    exit 1
fi

# Check current branch and other branches
CURRENT_BRANCH=$(git branch --show-current)
OTHER_BRANCHES=$(git branch --list | grep -v "^\*" | grep -v "^  main$" | tr -d ' ')

# Show what will happen
echo "📋 Pre-flight check:"
echo "  - Current branch: $CURRENT_BRANCH"
if [ -n "$OTHER_BRANCHES" ]; then
    echo "  - Branches to delete: $(echo "$OTHER_BRANCHES" | tr '\n' ' ')"
fi
echo "  - Will switch to main and proceed with setup"
echo ""

# Single confirmation before proceeding
read -p "Proceed? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "❌ Operation cancelled"
    exit 1
fi

# Switch to main if needed
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "🔄 Switching to main..."
    git checkout main >/dev/null 2>&1
fi

# Delete other branches if any exist
if [ -n "$OTHER_BRANCHES" ]; then
    echo "🗑️  Deleting other branches..."
    echo "$OTHER_BRANCHES" | while read branch; do
        git branch -D "$branch" 2>/dev/null || true
    done
fi

# Verify the pre-push hook source exists
if [ ! -f "$PRE_PUSH_HOOK" ]; then
    echo "❌ Error: Hook not found at $PRE_PUSH_HOOK"
    exit 1
fi

echo "📋 Initializing AI agent configuration..."

# 1. Create empty AGENTS.md
echo "📄 Creating empty AGENTS.md..."
touch AGENTS.md
echo "✓ AGENTS.md created"

# 2. Create CLAUDE.md as symbolic link to AGENTS.md
echo "🔗 Creating CLAUDE.md symlink..."
ln -sf AGENTS.md CLAUDE.md
echo "✓ CLAUDE.md symlink created"

# 3. Copy pre-push hook
echo "🪝 Copying pre-push hook..."
mkdir -p git/hooks
cp "$PRE_PUSH_HOOK" git/hooks/pre-push
chmod +x git/hooks/pre-push
echo "✓ Pre-push hook copied"

# 4. Configure git to use hooks directory
echo "⚙️  Configuring git..."
git config core.hooksPath git/hooks
echo "✓ Git configured"

# 5. Commit all files
echo "📝 Committing files..."
git add AGENTS.md CLAUDE.md git/hooks/pre-push
git commit -m "docs: add AI agent configuration

- Add empty AGENTS.md for project-specific rules and guidelines
- Add CLAUDE.md symlink to AGENTS.md
- Add pre-push hook for automated testing

Fill in AGENTS.md with project-specific details." || echo "  (no changes to commit)"

# 6. Push to remote
echo "🚀 Pushing to remote..."
echo "  - Temporarily disabling pre-push hook..."
git config core.hooksPath ""
git push origin $(git rev-parse --abbrev-ref HEAD)
echo "  - Re-enabling pre-push hook..."
git config core.hooksPath git/hooks

# 7. Execute start-ai-work.sh to finalize ai-work branch setup
bash "$(dirname "$0")/start-ai-work.sh"

# 8. Validate files exist in remote repository
echo ""
echo "✅ Validating files in remote repository..."
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if git ls-remote --heads origin "$CURRENT_BRANCH" | grep -q "$CURRENT_BRANCH"; then
    if git show origin/$CURRENT_BRANCH:AGENTS.md >/dev/null 2>&1 && \
       git show origin/$CURRENT_BRANCH:CLAUDE.md >/dev/null 2>&1 && \
       git show origin/$CURRENT_BRANCH:git/hooks/pre-push >/dev/null 2>&1; then
        echo "✓ All files verified in remote repository"
    else
        echo "❌ ERROR: Some files missing from remote repository"
        exit 1
    fi
else
    echo "❌ ERROR: Branch '$CURRENT_BRANCH' not found in remote"
    exit 1
fi

echo ""
echo "✅ AI agent configuration initialized!"
echo ""
echo "📝 Next steps:"
echo "  1. Fill in AGENTS.md with project-specific rules and guidelines"
echo "  2. Adapt git/hooks/pre-push test command if needed"
echo "  3. Changes have been committed and pushed"
echo ""
