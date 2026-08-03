#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$(git config --get openrouter.githubapikey || echo "")}"
if [ -z "$OPENROUTER_API_KEY" ]; then
  echo -e "${RED}Error: OpenRouter API key not found for this project.${NC}"
  echo -e "To set it for this specific repository only, run:"
  echo -e "git config --local openrouter.githubapikey 'YOUR_KEY_HERE'"
  exit 1
fi

echo -e "${YELLOW}=== AI Work Code Review ===${NC}\n"

NO_CONFIRM=false
BASE_REF=""

for arg in "$@"; do
  case "$arg" in
    --noconfirm|--no-confirm|-y)
      NO_CONFIRM=true
      ;;
    *)
      if [ -z "$BASE_REF" ]; then
        BASE_REF="$arg"
      fi
      ;;
  esac
done

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

if ! git diff-index --quiet HEAD --; then
  echo -e "${RED}Error: Uncommitted changes detected. Please commit or stash your changes first.${NC}"
  git status
  exit 1
fi
echo -e "${GREEN}✓ Working tree is clean${NC}"

IMAGE_EXCLUDES=('*.png' '*.jpg' '*.jpeg' '*.gif' '*.webp' '*.bmp' '*.ico')
IMAGE_PATHSPECS=()
for pattern in "${IMAGE_EXCLUDES[@]}"; do
  IMAGE_PATHSPECS+=(":!${pattern}")
done

MD_EXCLUDES=('*.md')
MD_PATHSPECS=()
for pattern in "${MD_EXCLUDES[@]}"; do
  MD_PATHSPECS+=(":!${pattern}")
done

DIFF_CONTENT=""
if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  DIFF_CONTENT=$(git diff --diff-filter=d "$BASE_REF"...HEAD -- . ':!go.sum' "${IMAGE_PATHSPECS[@]}" "${MD_PATHSPECS[@]}" 2>/dev/null || git diff --diff-filter=d "$BASE_REF" -- . ':!go.sum' "${IMAGE_PATHSPECS[@]}" "${MD_PATHSPECS[@]}" || echo "")
fi

DELETED_FILES=$(git diff --diff-filter=D --name-only "$BASE_REF" -- . ':!go.sum' "${IMAGE_PATHSPECS[@]}" "${MD_PATHSPECS[@]}" 2>/dev/null || echo "")
if [ -n "$DELETED_FILES" ]; then
  DIFF_CONTENT="${DIFF_CONTENT}"$'\n\n'"Deleted files (contents omitted, filenames only):"$'\n'"${DELETED_FILES}"
fi

CHANGED_IMAGES=$(git diff --name-only "$BASE_REF" -- "${IMAGE_EXCLUDES[@]}" 2>/dev/null || echo "")
if [ -n "$CHANGED_IMAGES" ]; then
  DIFF_CONTENT="${DIFF_CONTENT}"$'\n\n'"Image files changed (contents omitted, filenames only):"$'\n'"${CHANGED_IMAGES}"
fi

CHANGED_MD=$(git diff --name-only "$BASE_REF" -- "${MD_EXCLUDES[@]}" 2>/dev/null || echo "")
if [ -n "$CHANGED_MD" ]; then
  DIFF_CONTENT="${DIFF_CONTENT}"$'\n\n'"Markdown files changed (contents omitted, filenames only):"$'\n'"${CHANGED_MD}"
fi

if [ -z "$DIFF_CONTENT" ]; then
  echo -e "${GREEN}✓ No diff found against ${BASE_REF}. Nothing to review.${NC}"
  exit 0
fi

echo -e "${GREEN}✓ Diff extracted successfully${NC}\n"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/review.prompt.md"

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

MODEL_NAME="openrouter/free"
PROMPT_SIZE_BYTES=$(wc -c < "$PROMPT_TMPFILE" | tr -d ' ')
PROMPT_SIZE_LIMIT_BYTES=$((50 * 1024))
PROMPT_SIZE_KB=$((PROMPT_SIZE_BYTES / 1024))

if [ "$PROMPT_SIZE_BYTES" -gt "$PROMPT_SIZE_LIMIT_BYTES" ]; then
  echo -e "${YELLOW}Notice: Formatted prompt size is ${PROMPT_SIZE_KB}KB (exceeds $((PROMPT_SIZE_LIMIT_BYTES / 1024))KB limit).${NC}"
  if [ "$NO_CONFIRM" = true ]; then
    echo -e "${YELLOW}⏭️  Skipping AI code review for this repository (--noconfirm active and prompt size ${PROMPT_SIZE_KB}KB > 50KB).${NC}"
    echo -e "${YELLOW}    To review this repository, run interactively without --noconfirm to approve using openrouter/auto.${NC}"
    exit 0
  else
    echo -e "${YELLOW}A paid model (openrouter/auto) will be used for this review.${NC}"
    read -p "Send it to the OpenRouter API anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo -e "${RED}Aborted before sending request.${NC}"
      exit 1
    fi
    MODEL_NAME="openrouter/auto"
  fi
fi

jq -n --rawfile text "$PROMPT_TMPFILE" --arg model "$MODEL_NAME" '{model: $model, messages: [{role: "user", content: $text}]}' > "$PAYLOAD_TMPFILE"

MAX_RETRIES=3
ATTEMPT=1
STATUS=""
AI_OUTPUT=""
LAST_HTTP_CODE=""
LAST_API_RESPONSE=""

while [ "$ATTEMPT" -le "$MAX_RETRIES" ]; do
  if [ "$ATTEMPT" -gt 1 ]; then
    echo -e "${YELLOW}[Attempt $ATTEMPT/$MAX_RETRIES] Retrying API call to OpenRouter (${MODEL_NAME})...${NC}"
  else
    echo -e "${YELLOW}Sending request to OpenRouter API (model: ${MODEL_NAME}, payload size: ${PROMPT_SIZE_KB}KB)...${NC}"
  fi

  HTTP_RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" --connect-timeout 15 --max-time 120 -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    -H "Content-Type: application/json" \
    --data-binary "@$PAYLOAD_TMPFILE" || echo -e "\nHTTP_STATUS:000")

  LAST_HTTP_CODE=$(echo "$HTTP_RESPONSE" | grep -o 'HTTP_STATUS:[0-9]*' | cut -d: -f2 || echo "000")
  LAST_API_RESPONSE=$(echo "$HTTP_RESPONSE" | sed '/HTTP_STATUS:[0-9]*/d')

  if [ "$LAST_HTTP_CODE" != "200" ]; then
    echo -e "${RED}[ERROR] OpenRouter API call failed with HTTP status: ${LAST_HTTP_CODE}${NC}"
    if [ -n "$LAST_API_RESPONSE" ]; then
      echo -e "${RED}[ERROR] Response Body:${NC}\n${LAST_API_RESPONSE}"
    else
      echo -e "${RED}[ERROR] Request timed out or network connection failed.${NC}"
    fi
  fi

  RAW_OUTPUT=$(echo "$LAST_API_RESPONSE" | jq -r '.choices[0].message.content // empty' 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "")

  if [ -n "$RAW_OUTPUT" ]; then
    FIRST_LINE=$(echo "$RAW_OUTPUT" | head -n 1 | tr -d '\r' | xargs)
    if [ "$FIRST_LINE" = "LGTM" ]; then
      STATUS="LGTM"
      AI_OUTPUT="$RAW_OUTPUT"
      break
    elif [ "$FIRST_LINE" = "ACTION_REQUIRED" ]; then
      STATUS="ACTION_REQUIRED"
      AI_OUTPUT="$RAW_OUTPUT"
      break
    fi
    echo -e "${YELLOW}[WARN] Response format mismatch (attempt $ATTEMPT/$MAX_RETRIES). Expected 'LGTM' or 'ACTION_REQUIRED', got: '${FIRST_LINE}'${NC}"
  else
    if [ "$LAST_HTTP_CODE" = "200" ]; then
      echo -e "${YELLOW}[WARN] API returned HTTP 200 but payload contained no choice content.${NC}"
      echo -e "${YELLOW}[DEBUG] Raw Response: ${LAST_API_RESPONSE}${NC}"
    fi
  fi

  ATTEMPT=$((ATTEMPT + 1))
  sleep 1
done

if [ -z "$STATUS" ]; then
  STATUS="UNKNOWN"
  if [ -n "${RAW_OUTPUT:-}" ]; then
    AI_OUTPUT="$RAW_OUTPUT"
  elif [ -n "${LAST_API_RESPONSE:-}" ]; then
    AI_OUTPUT="Error: Failed to obtain valid AI review response after $MAX_RETRIES attempts.\nHTTP Status: ${LAST_HTTP_CODE}\nRaw API Response:\n${LAST_API_RESPONSE}"
  else
    AI_OUTPUT="Error: Failed to obtain valid AI review response after $MAX_RETRIES attempts (HTTP Status: ${LAST_HTTP_CODE}, no response body received)."
  fi
fi

echo -e "${GREEN}✓ AI review complete (Result: ${STATUS})${NC}\n"

echo -e "${YELLOW}[3/3] AI Code Review Notes for Manual Reviewer:${NC}"
echo -e "${BLUE}======================================================${NC}"
echo -e "$AI_OUTPUT"
echo -e "${BLUE}======================================================${NC}"

if [ "$STATUS" = "ACTION_REQUIRED" ] || [ "$STATUS" = "UNKNOWN" ]; then
  echo -e "${RED}❌ Review failed with status: ${STATUS}${NC}"
  exit 1
fi
