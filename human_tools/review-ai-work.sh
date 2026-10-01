#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RULES_URL="https://github.com/Darida/ai-cli-config/blob/main/human_tools/review.prompt.md"

main() {
  BASE_REF=""
  for arg in "$@"; do
    case "$arg" in
      -*) log_error "Error: unknown option: $arg"; exit 2 ;;
      *)
        if [ -n "$BASE_REF" ]; then
          log_error "Error: unexpected extra argument: $arg"
          exit 2
        fi
        BASE_REF="$arg"
        ;;
    esac
  done
  OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-$(git config --get openrouter.githubapikey || echo "")}"
  if [ -z "$OPENROUTER_API_KEY" ]; then
    log_error "Error: OpenRouter API key not found for this project."
    echo -e "To set it for this specific repository only, run:"
    echo -e "git config --local openrouter.githubapikey 'YOUR_KEY_HERE'"
    exit 1
  fi

  log_info "=== AI Work Code Review ==="

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

  log_info "[2/3] Preparing prompt and sending to AI (OpenRouter via openrouterclient)..."
  PROMPT_TMPFILE="$(mktemp)"
  DIFF_TMPFILE="$(mktemp)"
  trap 'rm -f "$PROMPT_TMPFILE" "$DIFF_TMPFILE"' EXIT

  printf '%s' "$DIFF_CONTENT" > "$DIFF_TMPFILE"

  node -e '
  const fs = require("fs");
  const template = fs.readFileSync(process.argv[1], "utf8");
  const diff = fs.readFileSync(process.argv[2], "utf8");
  const prompt = template.replace("{DIFF_CONTENT}", diff);
  fs.writeFileSync(process.argv[3], prompt, "utf8");
  ' "$PROMPT_FILE" "$DIFF_TMPFILE" "$PROMPT_TMPFILE"

  SCHEMA_FILE="$SCRIPT_DIR/review.schema.json"
  if [ ! -f "$SCHEMA_FILE" ]; then
    log_error "Error: Schema file not found at $SCHEMA_FILE"
    exit 1
  fi

  REVIEW_CONTENT=$("$SCRIPT_DIR/generate-content.sh" \
    --prompt="$PROMPT_TMPFILE" \
    --schema="$SCHEMA_FILE" \
    --schema-name="code_review_response" \
    --tag=cl_review \
    --key="$OPENROUTER_API_KEY" \
    --exclude-models="$SCRIPT_DIR/review.excluded-models.txt")
  STATUS=$(jq -r '.status' <<< "$REVIEW_CONTENT")

  log_info "[3/3] AI Code Review Notes for Manual Reviewer:"
  echo -e "  Rules: ${RULES_URL}"
  echo -e "${BLUE}======================================================${NC}"
  echo "$STATUS"
  jq -r '.notes[] | "- **" + .rule + "** (`" + .file + "`): " + .text' <<< "$REVIEW_CONTENT"
  echo -e "${BLUE}======================================================${NC}"

  log_success "✓ AI review complete (Overall Result: ${STATUS})"

  if [ "$STATUS" = "ACTION_REQUIRED" ]; then
    log_error "❌ Review failed with status: ${STATUS}"
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

  # Generated code is sometimes committed to the repo; it doesn't need review, so send filenames only.
  local generated_dirs='**/gen/**'
  local generated_pathspec=":(exclude,glob)${generated_dirs}"

  local diff_content=""
  diff_content=$(git --no-pager diff --diff-filter=d origin/main...HEAD -- . ':!go.sum' "${image_pathspecs[@]}" "${md_pathspecs[@]}" "$generated_pathspec" 2>/dev/null || echo "")

  if [ -n "$diff_content" ]; then
    diff_content=$(printf "%s" "$diff_content" | node -e '
    const raw = require("fs").readFileSync(0, "utf8");
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
    ')
  fi

  local deleted_files
  deleted_files=$(git --no-pager diff --diff-filter=D --name-only origin/main...HEAD -- . ':!go.sum' "${image_pathspecs[@]}" "${md_pathspecs[@]}" "$generated_pathspec" 2>/dev/null || echo "")
  if [ -n "$deleted_files" ]; then
    diff_content="${diff_content}"$'\n\n'"Deleted files (contents omitted, filenames only):"$'\n'"${deleted_files}"
  fi

  local changed_images
  changed_images=$(git --no-pager diff --name-only origin/main...HEAD -- "${image_excludes[@]}" 2>/dev/null || echo "")
  if [ -n "$changed_images" ]; then
    diff_content="${diff_content}"$'\n\n'"Image files changed (contents omitted, filenames only):"$'\n'"${changed_images}"
  fi

  local changed_md
  changed_md=$(git --no-pager diff --name-only origin/main...HEAD -- "${md_excludes[@]}" 2>/dev/null || echo "")
  if [ -n "$changed_md" ]; then
    diff_content="${diff_content}"$'\n\n'"Markdown files changed (contents omitted, filenames only):"$'\n'"${changed_md}"
  fi

  local changed_generated
  changed_generated=$(git --no-pager diff --name-only origin/main...HEAD -- ":(glob)${generated_dirs}" 2>/dev/null || echo "")
  if [ -n "$changed_generated" ]; then
    diff_content="${diff_content}"$'\n\n'"Generated files changed (contents omitted, filenames only):"$'\n'"${changed_generated}"
  fi

  echo "$diff_content"
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
