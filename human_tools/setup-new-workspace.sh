#!/bin/bash
# Initialize AI agent configuration from templates
# Run from your project root directory
# This script:
# 1. Copies AGENTS.md template from ~/templates/agents/AGENTS.md
# 2. Creates CLAUDE.md as a symbolic link to AGENTS.md
# 3. Copies pre-push hook from ~/templates/git/hooks/pre-push
# 4. Commits all files to git

set -e

TEMPLATES_DIR=~/templates

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

# Verify template files exist
if [ ! -f "$TEMPLATES_DIR/agents/AGENTS.md" ]; then
    echo "❌ Error: Template not found at $TEMPLATES_DIR/agents/AGENTS.md"
    exit 1
fi

if [ ! -f "$TEMPLATES_DIR/git/hooks/pre-push" ]; then
    echo "❌ Error: Hook template not found at $TEMPLATES_DIR/git/hooks/pre-push"
    exit 1
fi

echo "📋 Initializing AI agent configuration..."

# 1. Copy AGENTS.md template
echo "📄 Copying AGENTS.md template..."
cp "$TEMPLATES_DIR/agents/AGENTS.md" AGENTS.md
echo "✓ AGENTS.md copied"

# 2. Create CLAUDE.md as symbolic link to AGENTS.md
echo "🔗 Creating CLAUDE.md symlink..."
ln -sf AGENTS.md CLAUDE.md
echo "✓ CLAUDE.md symlink created"

# 3. Copy pre-push hook
echo "🪝 Copying pre-push hook..."
mkdir -p git/hooks
cp "$TEMPLATES_DIR/git/hooks/pre-push" git/hooks/pre-push
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

- Add AGENTS.md with AI agent rules and guidelines
- Add CLAUDE.md symlink to AGENTS.md
- Add pre-push hook for automated testing

Customize AGENTS.md with project-specific details."

# 6. Push to remote
echo "🚀 Pushing to remote..."
echo "  - Temporarily disabling pre-push hook..."
git config core.hooksPath ""
git push origin $(git rev-parse --abbrev-ref HEAD)
echo "  - Re-enabling pre-push hook..."
git config core.hooksPath git/hooks

# 7. Execute start-ai-work.sh to finalize ai-work branch setup
bash "$(dirname "$0")/start-ai-work.sh"

echo ""
echo "✅ AI agent configuration initialized!"
echo ""
echo "📝 Next steps:"
echo "  1. Edit AGENTS.md to customize for your project"
echo "  2. Replace all TODO markers with project-specific values"
echo "  3. Adapt git/hooks/pre-push test command if needed"
echo "  4. Changes have been committed and pushed"
echo ""
