#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

main() {
  OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$(git config --get openrouter.githubapikey || echo "")}"
  if [ -z "$OPENROUTER_API_KEY" ]; then
    log_error "Error: OpenRouter API key not found for this project."
    echo -e "To set it for this specific repository only, run:"
    echo -e "git config --local openrouter.githubapikey 'YOUR_KEY_HERE'"
    exit 1
  fi

  log_info "=== AI Work Code Review ==="

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

  log_info "[1/3] Verifying clean working tree and extracting git diff against ${BASE_REF}..."

  if ! git diff-index --quiet HEAD --; then
    log_error "Error: Uncommitted changes detected. Please commit or stash your changes first."
    git status
    exit 1
  fi
  log_success "✓ Working tree is clean"

  DIFF_CONTENT=$(extract_git_diff "$BASE_REF")

  if [ -z "$DIFF_CONTENT" ]; then
    log_success "✓ No diff found against ${BASE_REF}. Nothing to review."
    exit 0
  fi

  log_success "✓ Diff extracted successfully"

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROMPT_FILE="$SCRIPT_DIR/review.prompt.md"

  if [ ! -f "$PROMPT_FILE" ]; then
    log_error "Error: Prompt file not found at $PROMPT_FILE"
    exit 1
  fi

  log_info "[2/3] Preparing prompt and sending to AI (OpenRouter)..."
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
    log_info "Notice: Formatted prompt size is ${PROMPT_SIZE_KB}KB (exceeds $((PROMPT_SIZE_LIMIT_BYTES / 1024))KB limit)."
    if [ "$NO_CONFIRM" = true ]; then
      log_info "⏭️  Skipping AI code review for this repository (--noconfirm active and prompt size ${PROMPT_SIZE_KB}KB > 50KB)."
      log_info "    To review this repository, run interactively without --noconfirm to approve using openrouter/auto."
      exit 0
    else
      log_info "A paid model (openrouter/auto) will be used for this review."
      read -p "Send it to the OpenRouter API anyway? (y/n) " -n 1 -r
      echo
      if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Aborted before sending request."
        exit 1
      fi
      MODEL_NAME="openrouter/auto"
    fi
  fi

  HISTORY_FILE="$SCRIPT_DIR/history.json"
  EXCLUDED_MODELS=$(get_excluded_models "$HISTORY_FILE")
  if [ -n "$EXCLUDED_MODELS" ]; then
    log_info "Excluding models with high failure rates: ${EXCLUDED_MODELS}"
  fi

  jq -n \
    --rawfile text "$PROMPT_TMPFILE" \
    --arg model "$MODEL_NAME" \
    --arg excluded "$EXCLUDED_MODELS" \
    '{
      model: $model,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "code_review_response",
          strict: true,
          schema: {
            type: "object",
            properties: {
              status: {
                type: "string",
                enum: ["LGTM", "ACTION_REQUIRED"]
              },
              notes: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    rule: { type: "string" },
                    text: { type: "string" }
                  },
                  required: ["rule", "text"],
                  additionalProperties: false
                }
              }
            },
            required: ["status", "notes"],
            additionalProperties: false
          }
        }
      },
      plugins: (if ($excluded | length > 0) then [{ id: "auto-router", allowed_models: (["*"] + ($excluded | split(" ") | map("!" + .))) }] else [] end),
      messages: [{ role: "user", content: $text }]
    }' > "$PAYLOAD_TMPFILE"

  MAX_RETRIES=3
  ATTEMPT=1
  STATUS=""
  AI_OUTPUT=""
  FAILED_ATTEMPT_FILES=()

  while [ "$ATTEMPT" -le "$MAX_RETRIES" ]; do
    RESPONSE_TMPFILE=$(mktemp "/tmp/review_attempt_${ATTEMPT}_XXXXXX.json")

    if [ "$ATTEMPT" -gt 1 ]; then
      log_info "[Attempt $ATTEMPT/$MAX_RETRIES] Retrying API call to OpenRouter (${MODEL_NAME})..."
    else
      log_info "Sending request to OpenRouter API (model: ${MODEL_NAME}, payload size: ${PROMPT_SIZE_KB}KB)..."
    fi

    HTTP_CODE=$(curl -s -w "%{http_code}" -o "$RESPONSE_TMPFILE" --connect-timeout 15 --max-time 240 -X POST "https://openrouter.ai/api/v1/chat/completions" \
      -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
      -H "Content-Type: application/json" \
      --data-binary "@$PAYLOAD_TMPFILE" || echo "000")

    HTTP_CODE=$(echo "$HTTP_CODE" | tr -d '\r\n[:space:]' | tail -c 3)
    [ -z "$HTTP_CODE" ] && HTTP_CODE="000"

    ACTUAL_MODEL=$(jq -r '.model // empty' "$RESPONSE_TMPFILE" 2>/dev/null || echo "$MODEL_NAME")

    RAW_CONTENT=$(jq -r '.choices[0].message.content // .choices[0].message.reasoning // empty' "$RESPONSE_TMPFILE" 2>/dev/null || echo "")
    PARSED_STATUS=$(echo "$RAW_CONTENT" | jq -r '.status // empty' 2>/dev/null || echo "")

    if [ "$HTTP_CODE" = "200" ]; then
      if [ "$PARSED_STATUS" = "LGTM" ]; then
        STATUS="LGTM"
        AI_OUTPUT="LGTM"
        record_history_entry "$HISTORY_FILE" "$ACTUAL_MODEL" "success" 0
        rm -f "$RESPONSE_TMPFILE"
        break
      elif [ "$PARSED_STATUS" = "ACTION_REQUIRED" ]; then
        STATUS="ACTION_REQUIRED"
        NOTES_COUNT=$(echo "$RAW_CONTENT" | jq -r '.notes | length' 2>/dev/null || echo 0)
        FORMATTED_NOTES=$(echo "$RAW_CONTENT" | jq -r '.notes[]? | "- **" + (.rule // "Finding") + "**: " + (.text // .)' 2>/dev/null || echo "")
        AI_OUTPUT="ACTION_REQUIRED"$'\n'"${FORMATTED_NOTES}"
        record_history_entry "$HISTORY_FILE" "$ACTUAL_MODEL" "success" "$NOTES_COUNT"
        rm -f "$RESPONSE_TMPFILE"
        break
      else
        TRIMMED_CONTENT=$(echo "$RAW_CONTENT" | sed '/^[[:space:]]*$/d' | head -n 1 | tr -d '\r' | xargs)
        if [ "$TRIMMED_CONTENT" = "LGTM" ]; then
          STATUS="LGTM"
          AI_OUTPUT="LGTM"
          record_history_entry "$HISTORY_FILE" "$ACTUAL_MODEL" "success" 0
          rm -f "$RESPONSE_TMPFILE"
          break
        fi
      fi
    fi

    # Attempt failed — preserve tmp file for debugging and record failure
    record_history_entry "$HISTORY_FILE" "$ACTUAL_MODEL" "fail" 0
    FAILED_ATTEMPT_FILES+=("$RESPONSE_TMPFILE")
    log_error "[ERROR] Attempt $ATTEMPT/$MAX_RETRIES failed (HTTP Status: ${HTTP_CODE}, Model: ${ACTUAL_MODEL}). Debug file: file://${RESPONSE_TMPFILE}"

    ATTEMPT=$((ATTEMPT + 1))
    sleep 1
  done

  if [ -z "$STATUS" ]; then
    STATUS="UNKNOWN"
    AI_OUTPUT="Error: Failed to obtain valid AI review response after $MAX_RETRIES attempts.\nPreserved attempt debug files:\n"
    for f in "${FAILED_ATTEMPT_FILES[@]}"; do
      AI_OUTPUT="${AI_OUTPUT}  - file://${f}\n"
    done
  fi

  log_success "✓ AI review complete (Result: ${STATUS})\n"

  log_info "[3/3] AI Code Review Notes for Manual Reviewer:"
  echo -e "${BLUE}======================================================${NC}"
  echo -e "$AI_OUTPUT"
  echo -e "${BLUE}======================================================${NC}"

  if [ "$STATUS" = "ACTION_REQUIRED" ] || [ "$STATUS" = "UNKNOWN" ]; then
    log_error "❌ Review failed with status: ${STATUS}"
    exit 1
  fi
}

extract_git_diff() {
  local base_ref="$1"
  local image_excludes=('*.png' '*.jpg' '*.jpeg' '*.gif' '*.webp' '*.bmp' '*.ico')
  local image_pathspecs=()
  for pattern in "${image_excludes[@]}"; do
    image_pathspecs+=(":!${pattern}")
  done

  local md_excludes=('*.md')
  local md_pathspecs=()
  for pattern in "${md_excludes[@]}"; do
    md_pathspecs+=(":!${pattern}")
  done

  local diff_content=""
  if git rev-parse --verify "$base_ref" >/dev/null 2>&1; then
    diff_content=$(git diff --diff-filter=d "$base_ref"...HEAD -- . ':!go.sum' "${image_pathspecs[@]}" "${md_pathspecs[@]}" 2>/dev/null || git diff --diff-filter=d "$base_ref" -- . ':!go.sum' "${image_pathspecs[@]}" "${md_pathspecs[@]}" || echo "")
  fi

  local deleted_files
  deleted_files=$(git diff --diff-filter=D --name-only "$base_ref" -- . ':!go.sum' "${image_pathspecs[@]}" "${md_pathspecs[@]}" 2>/dev/null || echo "")
  if [ -n "$deleted_files" ]; then
    diff_content="${diff_content}"$'\n\n'"Deleted files (contents omitted, filenames only):"$'\n'"${deleted_files}"
  fi

  local changed_images
  changed_images=$(git diff --name-only "$base_ref" -- "${image_excludes[@]}" 2>/dev/null || echo "")
  if [ -n "$changed_images" ]; then
    diff_content="${diff_content}"$'\n\n'"Image files changed (contents omitted, filenames only):"$'\n'"${changed_images}"
  fi

  local changed_md
  changed_md=$(git diff --name-only "$base_ref" -- "${md_excludes[@]}" 2>/dev/null || echo "")
  if [ -n "$changed_md" ]; then
    diff_content="${diff_content}"$'\n\n'"Markdown files changed (contents omitted, filenames only):"$'\n'"${changed_md}"
  fi

  echo "$diff_content"
}

get_excluded_models() {
  local history_file="$1"
  node -e '
  const fs = require("fs");
  const historyFile = process.argv[1];
  let history = [];
  try {
    if (fs.existsSync(historyFile)) {
      history = JSON.parse(fs.readFileSync(historyFile, "utf8"));
    }
  } catch (e) {
    history = [];
  }

  const now = new Date();
  const todayStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())).getTime();
  const weekStart = now.getTime() - 7 * 24 * 60 * 60 * 1000;
  const monthStart = now.getTime() - 30 * 24 * 60 * 60 * 1000;

  const failures = {};

  for (const item of history) {
    if (item.status !== "fail" || !item.model) continue;
    const time = new Date(item.timestamp).getTime();
    if (isNaN(time)) continue;

    if (!failures[item.model]) {
      failures[item.model] = { today: 0, week: 0, month: 0 };
    }

    if (time >= todayStart) failures[item.model].today++;
    if (time >= weekStart) failures[item.model].week++;
    if (time >= monthStart) failures[item.model].month++;
  }

  const excluded = [];
  for (const [model, count] of Object.entries(failures)) {
    if (count.today > 3 || count.week > 6 || count.month > 12) {
      excluded.push(model);
    }
  }

  console.log(excluded.join(" "));
  ' "$history_file" 2>/dev/null || echo ""
}

record_history_entry() {
  local history_file="$1"
  local model_name="$2"
  local status_val="$3"
  local notes_cnt="$4"

  node -e '
  const fs = require("fs");
  const historyFile = process.argv[1];
  const entry = {
    timestamp: new Date().toISOString(),
    model: process.argv[2],
    status: process.argv[3],
    notes_count: parseInt(process.argv[4], 10) || 0
  };

  let history = [];
  try {
    if (fs.existsSync(historyFile)) {
      history = JSON.parse(fs.readFileSync(historyFile, "utf8"));
    }
  } catch (e) {
    history = [];
  }

  history.push(entry);
  fs.writeFileSync(historyFile, JSON.stringify(history, null, 2), "utf8");
  ' "$history_file" "$model_name" "$status_val" "$notes_cnt" 2>/dev/null || true
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

timestamp() {
  date "+%Y-%m-%d %H:%M:%S"
}

main "$@"
