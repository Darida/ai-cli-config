#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RULES_URL="https://github.com/Darida/ai-cli-config/blob/main/human_tools/review.prompt.md"

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
  NOFLUSH=false
  BASE_REF=""

  for arg in "$@"; do
    case "$arg" in
      --noconfirm|--no-confirm|-y)
        NO_CONFIRM=true
        ;;
      --noflush)
        NOFLUSH=true
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

  log_info "[1/3] Verifying clean working tree and extracting git diff against origin/main..."

  if ! git diff-index --quiet HEAD --; then
    local summary
    summary=$(format_uncommitted_changes_summary)
    log_error "Error: Uncommitted changes detected (${summary}). Please commit or stash your changes first."
    git status
    exit 1
  fi
  log_success "✓ Working tree is clean"

  PREVIEW_URL="$(compare_url "$BASE_REF" 2>/dev/null || true)"
  if [ -n "$PREVIEW_URL" ]; then
    echo -e "  Preview: ${PREVIEW_URL}\n"
  fi

  DIFF_CONTENT=$(extract_git_diff)

  if [ -z "$DIFF_CONTENT" ]; then
    log_success "✓ No diff found against origin/main. Nothing to review."
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
  trap 'rm -f "$PROMPT_TMPFILE" "$PAYLOAD_TMPFILE" "$DIFF_TMPFILE"; [ "$NOFLUSH" = true ] || flush_and_commit_history "$SCRIPT_DIR/history.json"' EXIT

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

  SCHEMA_FILE="$SCRIPT_DIR/review.schema.json"
  if [ ! -f "$SCHEMA_FILE" ]; then
    log_error "Error: Schema file not found at $SCHEMA_FILE"
    exit 1
  fi

  HISTORY_FILE="$SCRIPT_DIR/history.json"
  GET_EXCLUDED_OUTPUT=$(get_excluded_models "$HISTORY_FILE")
  EXCLUDED_MODELS=$(sed -n '1p' <<< "$GET_EXCLUDED_OUTPUT")
  MODELS_BELOW_CAP=$(sed -n '2p' <<< "$GET_EXCLUDED_OUTPUT")
  if [ -n "$MODELS_BELOW_CAP" ]; then
    log_info "Models with recent failures below the exclusion cap: ${MODELS_BELOW_CAP}"
  fi
  if [ -n "$EXCLUDED_MODELS" ]; then
    log_info "Excluding models with high failure rates: ${EXCLUDED_MODELS}"
  fi

  build_openrouter_payload "$PROMPT_TMPFILE" "$SCHEMA_FILE" "$MODEL_NAME" "$EXCLUDED_MODELS" > "$PAYLOAD_TMPFILE"

  # Hedged-parallel attempts: never abort a request. Attempt 1 fires immediately;
  # attempt N+1 fires as soon as attempt N is either known-failed or has been
  # pending STAGGER_SECONDS with no response — whichever comes first. Once any
  # attempt succeeds, no further attempt is launched, but ones already in flight
  # are left to finish (never killed) so their latency/outcome can still be
  # logged. All printing/history-writing happens only in the single main loop
  # (never inside a backgrounded attempt), so concurrent outputs never interleave.
  MAX_ATTEMPTS=3
  STAGGER_SECONDS=60
  RUN_TAG="$$"
  declare -A LAUNCHED=() PROCESSED=() LAUNCH_TS=()
  ANY_SUCCESS=false
  OVERALL_STATUS=""
  FAILED_ATTEMPT_FILES=()

  log_info "Sending request to OpenRouter API (model: ${MODEL_NAME}, payload size: ${PROMPT_SIZE_KB}KB)..."
  run_attempt 1 &
  LAUNCHED[1]=1
  LAUNCH_TS[1]=$(date +%s)

  log_info "[3/3] AI Code Review Notes for Manual Reviewer (printed as each attempt completes):"
  echo -e "  Rules: ${RULES_URL}"

  while true; do
    NOW=$(date +%s)

    maybe_launch_next_attempt 1 2 "$NOW"
    maybe_launch_next_attempt 2 3 "$NOW"
    poll_completed_attempts

    all_launched_attempts_processed && break

    sleep 1
  done

  if [ "$ANY_SUCCESS" = false ]; then
    log_error "❌ Failed to obtain any valid AI review response after ${MAX_ATTEMPTS} attempts."
    for f in "${FAILED_ATTEMPT_FILES[@]}"; do
      log_error "  - file://${f}"
    done
    exit 1
  fi

  log_success "✓ AI review complete (Overall Result: ${OVERALL_STATUS})"

  if [ "$OVERALL_STATUS" = "ACTION_REQUIRED" ]; then
    log_error "❌ Review failed with status: ${OVERALL_STATUS}"
    exit 1
  fi
}

compare_url() {
  local base_ref="$1"
  local remote_url org_repo base_branch current_branch
  remote_url="$(git remote get-url origin 2>/dev/null)" || return 1
  current_branch="$(git branch --show-current 2>/dev/null)"
  [ -z "$current_branch" ] && return 1
  base_branch="${base_ref#origin/}"
  case "$base_branch" in
    *~*|*^*) return 1 ;;  # not a real branch name (e.g. HEAD~1), no meaningful compare link
  esac
  org_repo="$(echo "$remote_url" | sed -E 's#^git@github\.com:##; s#^https://github\.com/##; s#\.git$##')"
  echo "https://github.com/$org_repo/compare/${base_branch}...${current_branch}?expand=1"
}

extract_git_diff() {
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
  diff_content=$(git diff --diff-filter=d origin/main...HEAD -- . ':!go.sum' "${image_pathspecs[@]}" "${md_pathspecs[@]}" 2>/dev/null || echo "")

  if [ -n "$diff_content" ]; then
    diff_content=$(node -e '
    const raw = process.argv[1];
    const lines = raw.split("\n");
    const out = [];
    let count = 0;

    const flush = () => {
      if (count > 0) {
        out.push(`<deleted ${count} ${count === 1 ? "line" : "lines"}>`);
        count = 0;
      }
    };

    for (const line of lines) {
      if (line.startsWith("-") && !line.startsWith("--- ")) {
        count++;
      } else {
        flush();
        out.push(line);
      }
    }
    flush();
    console.log(out.join("\n"));
    ' "$diff_content")
  fi

  local deleted_files
  deleted_files=$(git diff --diff-filter=D --name-only origin/main...HEAD -- . ':!go.sum' "${image_pathspecs[@]}" "${md_pathspecs[@]}" 2>/dev/null || echo "")
  if [ -n "$deleted_files" ]; then
    diff_content="${diff_content}"$'\n\n'"Deleted files (contents omitted, filenames only):"$'\n'"${deleted_files}"
  fi

  local changed_images
  changed_images=$(git diff --name-only origin/main...HEAD -- "${image_excludes[@]}" 2>/dev/null || echo "")
  if [ -n "$changed_images" ]; then
    diff_content="${diff_content}"$'\n\n'"Image files changed (contents omitted, filenames only):"$'\n'"${changed_images}"
  fi

  local changed_md
  changed_md=$(git diff --name-only origin/main...HEAD -- "${md_excludes[@]}" 2>/dev/null || echo "")
  if [ -n "$changed_md" ]; then
    diff_content="${diff_content}"$'\n\n'"Markdown files changed (contents omitted, filenames only):"$'\n'"${changed_md}"
  fi

  echo "$diff_content"
}

build_openrouter_payload() {
  local prompt_file="$1"
  local schema_file="$2"
  local model_name="$3"
  local excluded_models="$4"

  # https://openrouter.ai/docs/client-sdks/python/components/preferredmaxlatency
  jq -n \
    --rawfile text "$prompt_file" \
    --rawfile schema "$schema_file" \
    --arg model "$model_name" \
    --arg excluded "$excluded_models" \
    '{
      model: $model,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "code_review_response",
          strict: true,
          schema: ($schema | fromjson)
        }
      },
      provider: { require_parameters: true, preferred_max_latency: 30 },
      reasoning: { exclude: true, effort: "low" },
      plugins: (if ($excluded | length > 0) then [{ id: "auto-router", allowed_models: (["*"] + ($excluded | split(" ") | map("!" + .))) }] else [] end),
      messages: [{ role: "user", content: $text }]
    }'
}

# Decides whether to launch `next_attempt` given how `prev_attempt` is doing.
# Fires immediately if prev already finished (and failed — if it had succeeded,
# ANY_SUCCESS would already be true and the first check below short-circuits),
# or once prev has been pending STAGGER_SECONDS with no response. Reads/writes
# LAUNCHED/LAUNCH_TS/ANY_SUCCESS, which are locals of main() further up the
# call stack — safe here since this is always called synchronously (never
# backgrounded) from within main()'s own loop, so no subshell copy is involved.
maybe_launch_next_attempt() {
  local prev_attempt="$1"
  local next_attempt="$2"
  local now="$3"

  [ "$ANY_SUCCESS" = false ] || return 0
  [ -n "${LAUNCHED[$prev_attempt]:-}" ] || return 0
  [ -z "${LAUNCHED[$next_attempt]:-}" ] || return 0

  if [ -n "${PROCESSED[$prev_attempt]:-}" ] || [ $((now - LAUNCH_TS[$prev_attempt])) -ge "$STAGGER_SECONDS" ]; then
    log_info "[Attempt ${next_attempt}/${MAX_ATTEMPTS}] Issuing a concurrent request to OpenRouter (${MODEL_NAME})..."
    run_attempt "$next_attempt" &
    LAUNCHED[$next_attempt]=1
    LAUNCH_TS[$next_attempt]=$now
  fi
}

# Picks up any attempt whose result file has appeared since the last poll,
# processes it (prints/logs), and marks it done. Same call-stack note as above.
poll_completed_attempts() {
  local n result_file
  for n in 1 2 3; do
    if [ -n "${LAUNCHED[$n]:-}" ] && [ -z "${PROCESSED[$n]:-}" ]; then
      result_file="/tmp/review_result_${RUN_TAG}_${n}.json"
      if [ -f "$result_file" ]; then
        process_attempt_result "$result_file" "$n"
        PROCESSED[$n]=1
        rm -f "$result_file"
      fi
    fi
  done
}

all_launched_attempts_processed() {
  local n
  for n in "${!LAUNCHED[@]}"; do
    [ -n "${PROCESSED[$n]:-}" ] || return 1
  done
  return 0
}

# Issues the OpenRouter request for one attempt, writing the raw response body
# to response_tmpfile. Echoes the HTTP status code ("000" if curl never got one).
send_review_request() {
  local response_tmpfile="$1"
  local http_code

  http_code=$(curl -s -w "%{http_code}" -o "$response_tmpfile" --connect-timeout 15 -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    -H "Content-Type: application/json" \
    --data-binary "@$PAYLOAD_TMPFILE" || echo "000")
  http_code=$(echo "$http_code" | tr -d '\r\n[:space:]' | tail -c 3)
  [ -z "$http_code" ] && http_code="000"
  echo "$http_code"
}

extract_response_model() {
  local response_tmpfile="$1"
  local model
  model=$(jq -r '.model // empty' "$response_tmpfile" 2>/dev/null || echo "")
  [ -z "$model" ] && model="unknown"
  echo "$model"
}

# Sets status_val/ai_output/notes_count in the caller's scope (run_attempt) —
# same caller-local-mutation idiom as maybe_launch_next_attempt above, chosen
# because ai_output can be multi-line, which rules out a simple one-line-per-
# field stdout protocol like get_excluded_models uses.
parse_review_verdict() {
  local http_code="$1"
  local response_tmpfile="$2"
  local raw_content parsed_status trimmed_content

  status_val=""
  ai_output=""
  notes_count=0

  [ "$http_code" = "200" ] || return 0

  raw_content=$(jq -r '.choices[0].message.content // .choices[0].message.reasoning // empty' "$response_tmpfile" 2>/dev/null || echo "")
  parsed_status=$(echo "$raw_content" | jq -r '.status // empty' 2>/dev/null || echo "")

  if [ "$parsed_status" = "LGTM" ]; then
    status_val="LGTM"
    ai_output="LGTM"
  elif [ "$parsed_status" = "ACTION_REQUIRED" ]; then
    status_val="ACTION_REQUIRED"
    notes_count=$(echo "$raw_content" | jq -r '.notes | length' 2>/dev/null || echo 0)
    ai_output="ACTION_REQUIRED"$'\n'"$(echo "$raw_content" | jq -r '.notes[]? | "- **" + (.rule // "Finding") + "** (`" + (.file // "unknown") + "`): " + (.text // .)' 2>/dev/null || echo "")"
  else
    trimmed_content=$(echo "$raw_content" | sed '/^[[:space:]]*$/d' | head -n 1 | tr -d '\r' | xargs)
    if [ "$trimmed_content" = "LGTM" ]; then
      status_val="LGTM"
      ai_output="LGTM"
    fi
  fi
}

run_attempt() {
  local attempt_num="$1"
  local result_file="/tmp/review_result_${RUN_TAG}_${attempt_num}.json"
  # Safety net: this runs backgrounded under `set -e` — if anything here fails
  # unexpectedly before the normal result write, guarantee a result file still
  # appears, or the main loop's poll would wait for it forever.
  trap 'write_fallback_result "$result_file" "$attempt_num"' EXIT

  local response_tmpfile start_ts end_ts latency http_code model
  local status_val ai_output notes_count failure_reason="" response_ref=""

  response_tmpfile=$(mktemp "/tmp/review_attempt_${attempt_num}_XXXXXX.json")
  start_ts=$(date +%s)
  http_code=$(send_review_request "$response_tmpfile")
  end_ts=$(date +%s)
  latency=$((end_ts - start_ts))
  model=$(extract_response_model "$response_tmpfile")

  parse_review_verdict "$http_code" "$response_tmpfile"

  if [ -z "$status_val" ]; then
    failure_reason=$(classify_response_failure "$response_tmpfile")
    response_ref="$response_tmpfile"
  else
    rm -f "$response_tmpfile"
  fi

  jq -n \
    --argjson attempt "$attempt_num" \
    --arg model "$model" \
    --arg http_code "$http_code" \
    --arg status "$status_val" \
    --arg output "$ai_output" \
    --argjson notes_count "$notes_count" \
    --argjson latency "$latency" \
    --arg failure_reason "$failure_reason" \
    --arg response_file "$response_ref" \
    '{attempt: $attempt, model: $model, http_code: $http_code, status: $status, output: $output, notes_count: $notes_count, latency: $latency, failure_reason: $failure_reason, response_file: $response_file}' \
    > "${result_file}.partial"
  mv "${result_file}.partial" "$result_file"
}

write_fallback_result() {
  local result_file="$1"
  local attempt_num="$2"
  [ -f "$result_file" ] && return 0
  jq -n --argjson attempt "$attempt_num" \
    '{attempt: $attempt, model: "unknown", http_code: "000", status: "", output: "", notes_count: 0, latency: 0, failure_reason: "unexpected script error", response_file: ""}' \
    > "${result_file}.partial" 2>/dev/null && mv "${result_file}.partial" "$result_file" 2>/dev/null || true
}

process_attempt_result() {
  local result_file="$1"
  local attempt_num="$2"
  local model status_val output notes_count latency http_code failure_reason response_file

  model=$(jq -r '.model' "$result_file")
  status_val=$(jq -r '.status' "$result_file")
  output=$(jq -r '.output' "$result_file")
  notes_count=$(jq -r '.notes_count' "$result_file")
  latency=$(jq -r '.latency' "$result_file")
  http_code=$(jq -r '.http_code' "$result_file")
  failure_reason=$(jq -r '.failure_reason' "$result_file")
  response_file=$(jq -r '.response_file' "$result_file")

  if [ -n "$status_val" ]; then
    record_history_entry "$HISTORY_FILE" "$model" "success" "$notes_count" "$latency"
    ANY_SUCCESS=true
    if [ "$status_val" = "ACTION_REQUIRED" ]; then
      OVERALL_STATUS="ACTION_REQUIRED"
    elif [ "$OVERALL_STATUS" != "ACTION_REQUIRED" ]; then
      OVERALL_STATUS="LGTM"
    fi

    log_success "✓ Attempt ${attempt_num} succeeded (model: ${model}, latency: ${latency}s, result: ${status_val})"
    echo -e "${BLUE}======================================================${NC}"
    echo -e "$output"
    echo -e "${BLUE}======================================================${NC}"
  else
    record_history_entry "$HISTORY_FILE" "$model" "fail" 0 "$latency"
    FAILED_ATTEMPT_FILES+=("$response_file")
    log_error "[ERROR] Attempt ${attempt_num}/${MAX_ATTEMPTS} failed (HTTP Status: ${http_code}, Model: ${model}, Reason: ${failure_reason}, Latency: ${latency}s). Debug file: file://${response_file}"
  fi
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
    const isFailure = item.status === "fail" || (typeof item.latency === "number" && item.latency >= 60);
    if (!isFailure || !item.model) continue;
    const time = new Date(item.timestamp).getTime();
    if (isNaN(time)) continue;

    if (!failures[item.model]) {
      failures[item.model] = { today: 0, week: 0, month: 0, lifetime: 0 };
    }

    if (time >= todayStart) failures[item.model].today++;
    if (time >= weekStart) failures[item.model].week++;
    if (time >= monthStart) failures[item.model].month++;
    failures[item.model].lifetime++;
  }

  const excluded = [];
  const belowCap = [];
  for (const [model, count] of Object.entries(failures)) {
    if (count.today > 3 || count.week > 6 || count.month > 12 || count.lifetime > 24) {
      excluded.push(model);
    } else {
      belowCap.push(`${model} (today=${count.today} week=${count.week} month=${count.month} lifetime=${count.lifetime})`);
    }
  }

  console.log(excluded.join(" "));
  console.log(belowCap.join(", "));
  ' "$history_file" 2>/dev/null || printf "\n\n"
}

classify_response_failure() {
  local response_file="$1"
  if [ ! -f "$response_file" ]; then
    echo "unknown"
    return
  fi
  local content_val
  content_val=$(jq -r '.choices[0].message.content' "$response_file" 2>/dev/null || echo "")
  if [ "$content_val" = "null" ]; then
    echo "empty response"
  else
    echo "unknown"
  fi
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

record_history_entry() {
  local history_file="$1"
  local model_name="$2"
  local status_val="$3"
  local notes_cnt="$4"
  local latency_val="$5"
  local pending_file="/tmp/review_history_pending.json"

  node -e '
  const fs = require("fs");
  const pendingFile = process.argv[1];
  const entry = {
    timestamp: new Date().toISOString(),
    model: process.argv[2],
    status: process.argv[3],
    notes_count: parseInt(process.argv[4], 10) || 0,
    latency: parseInt(process.argv[5], 10) || 0
  };

  let history = [];
  try {
    if (fs.existsSync(pendingFile)) {
      history = JSON.parse(fs.readFileSync(pendingFile, "utf8"));
    }
  } catch (e) {
    history = [];
  }

  history.push(entry);
  fs.writeFileSync(pendingFile, JSON.stringify(history, null, 2), "utf8");
  ' "$pending_file" "$model_name" "$status_val" "$notes_cnt" "$latency_val" 2>/dev/null || true
}

flush_and_commit_history() {
  local history_file="$1"
  local pending_file="/tmp/review_history_pending.json"
  local script_dir
  script_dir="$(cd "$(dirname "$history_file")" && pwd)"

  [ ! -f "$pending_file" ] && return 0

  node -e '
  const fs = require("fs");
  const historyFile = process.argv[1];
  const pendingFile = process.argv[2];
  let history = [];
  try {
    if (fs.existsSync(historyFile)) {
      history = JSON.parse(fs.readFileSync(historyFile, "utf8"));
    }
  } catch (e) {}

  try {
    if (fs.existsSync(pendingFile)) {
      const pending = JSON.parse(fs.readFileSync(pendingFile, "utf8"));
      if (Array.isArray(pending) && pending.length > 0) {
        history = history.concat(pending);
        fs.writeFileSync(historyFile, JSON.stringify(history, null, 2), "utf8");
      }
      fs.unlinkSync(pendingFile);
    }
  } catch (e) {}
  ' "$history_file" "$pending_file" 2>/dev/null || true

  if git -C "$script_dir" status --porcelain "$history_file" 2>/dev/null | grep -q .; then
    git -C "$script_dir" add "$history_file" 2>/dev/null || true
    if git -C "$script_dir" commit -m "chore(history): update AI review history log" 2>/dev/null; then
      git -C "$script_dir" push origin ai-work 2>/dev/null || true
    fi
  fi
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
