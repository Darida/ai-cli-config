#!/bin/bash
set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Read OpenRouter API Key
OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$(git config --get openrouter.githubapikey || echo "")}"
if [ -z "$OPENROUTER_API_KEY" ]; then
  echo -e "${RED}Error: OpenRouter API key not found for this project.${NC}"
  echo -e "To set it for this specific repository only, run:"
  echo -e "git config --local openrouter.githubapikey 'YOUR_KEY_HERE'"
  exit 1
fi

echo -e "${YELLOW}=== AI Work Code Review ===${NC}\n"

# Determine base ref for diff
BASE_REF="${1:-}"
if [ -z "$BASE_REF" ]; then
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    BASE_REF="origin/main"
  elif git rev-parse --verify main >/dev/null 2>&1; then
    BASE_REF="main"
  else
    BASE_REF="HEAD~1"
  fi
fi

echo -e "${YELLOW}[1/3] Verifying clean working tree and extracting git diff against ${BASE_REF}...${NC}"

# Abort if uncommitted changes exist
if ! git diff-index --quiet HEAD --; then
  echo -e "${RED}Error: Uncommitted changes detected. Please commit or stash your changes first.${NC}"
  git status
  exit 1
fi
echo -e "${GREEN}✓ Working tree is clean${NC}"

# Define image exclusions (same as approval workflow)
IMAGE_EXCLUDES=('*.png' '*.jpg' '*.jpeg' '*.gif' '*.webp' '*.bmp' '*.ico')
IMAGE_PATHSPECS=()
for pattern in "${IMAGE_EXCLUDES[@]}"; do
  IMAGE_PATHSPECS+=(":!${pattern}")
done

# Extract diff comparing BASE_REF...HEAD
DIFF_CONTENT=""
if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  DIFF_CONTENT=$(git diff --diff-filter=d "$BASE_REF"...HEAD -- . ':!go.sum' "${IMAGE_PATHSPECS[@]}" 2>/dev/null || git diff --diff-filter=d "$BASE_REF" -- . ':!go.sum' "${IMAGE_PATHSPECS[@]}" || echo "")
fi

DELETED_FILES=$(git diff --diff-filter=D --name-only "$BASE_REF" -- . ':!go.sum' "${IMAGE_PATHSPECS[@]}" 2>/dev/null || echo "")
if [ -n "$DELETED_FILES" ]; then
  DIFF_CONTENT="${DIFF_CONTENT}"$'\n\n'"Deleted files (contents omitted, filenames only):"$'\n'"${DELETED_FILES}"
fi

CHANGED_IMAGES=$(git diff --name-only "$BASE_REF" -- "${IMAGE_EXCLUDES[@]}" 2>/dev/null || echo "")
if [ -n "$CHANGED_IMAGES" ]; then
  DIFF_CONTENT="${DIFF_CONTENT}"$'\n\n'"Image files changed (contents omitted, filenames only):"$'\n'"${CHANGED_IMAGES}"
fi

if [ -z "$DIFF_CONTENT" ]; then
  echo -e "${GREEN}✓ No diff found against ${BASE_REF}. Nothing to review.${NC}"
  exit 0
fi

echo -e "${GREEN}✓ Diff extracted successfully${NC}\n"

# Locate prompt template
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/review.promt.md"
if [ ! -f "$PROMPT_FILE" ]; then
  PROMPT_FILE="$SCRIPT_DIR/review.prompt.md"
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo -e "${RED}Error: Prompt file not found at $PROMPT_FILE${NC}"
  exit 1
fi

echo -e "${YELLOW}[2/3] Preparing prompt and sending to AI (OpenRouter)...${NC}"
PROMPT_TMPFILE="$(mktemp)"
PAYLOAD_TMPFILE="$(mktemp)"
DIFF_TMPFILE="$(mktemp)"
trap 'rm -f "$PROMPT_TMPFILE" "$PAYLOAD_TMPFILE" "$DIFF_TMPFILE"' EXIT

printf '%s' "$DIFF_CONTENT" > "$DIFF_TMPFILE"

node -e '
const fs = require("fs");
const template = fs.readFileSync(process.argv[1], "utf8");
const diff = fs.readFileSync(process.argv[2], "utf8");
const prompt = template.replace("{DIFF_CONTENT}", diff);
fs.writeFileSync(process.argv[3], prompt, "utf8");
' "$PROMPT_FILE" "$DIFF_TMPFILE" "$PROMPT_TMPFILE"

PROMPT_SIZE_BYTES=$(wc -c < "$PROMPT_TMPFILE")
PROMPT_SIZE_LIMIT_BYTES=$((50 * 1024))
if [ "$PROMPT_SIZE_BYTES" -gt "$PROMPT_SIZE_LIMIT_BYTES" ]; then
  echo -e "${YELLOW}Warning: formatted prompt is $((PROMPT_SIZE_BYTES / 1024))KB, over the 50KB threshold.${NC}"
  read -p "Send it to the OpenRouter API anyway? (y/n) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Aborted before sending request.${NC}"
    exit 1
  fi
fi

jq -n --rawfile text "$PROMPT_TMPFILE" '{model: "openrouter/auto", messages: [{role: "user", content: $text}]}' > "$PAYLOAD_TMPFILE"

API_RESPONSE=$(curl -s -X POST "https://openrouter.ai/api/v1/chat/completions" \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
  -H "Content-Type: application/json" \
  --data-binary "@$PAYLOAD_TMPFILE")

AI_OUTPUT=$(echo "$API_RESPONSE" | jq -r '.choices[0].message.content // empty')

if [ -z "$AI_OUTPUT" ]; then
  echo -e "${RED}Error: Failed to generate AI review output.${NC}"
  echo -e "${YELLOW}Raw API Response (Debug Info):${NC}"
  echo "$API_RESPONSE"
  exit 1
fi

echo -e "${GREEN}✓ AI review complete${NC}\n"

echo -e "${YELLOW}[3/3] AI Code Review Notes for Manual Reviewer:${NC}"
echo -e "${BLUE}======================================================${NC}"
echo "$AI_OUTPUT"
echo -e "${BLUE}======================================================${NC}"
