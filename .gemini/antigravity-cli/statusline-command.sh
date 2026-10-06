#!/bin/bash
# Antigravity CLI status line (stdin schema: https://antigravity.google/docs/cli/statusline).
# The branch diff segment is queried live from the
# GitHub API rather than the local git tree, so it stays accurate even in a
# sparse checkout where most files aren't present to diff locally.

# ---------- colors ----------
c_reset=$'\033[0m'
c_dim=$'\033[2m'
c_model=$'\033[36m'
c_green=$'\033[32m'
c_yellow=$'\033[33m'
c_red=$'\033[31m'
c_sep="${c_dim}|${c_reset}"

main() {
  input=$(cat)

  if ! have jq; then
    # Minimal fallback if jq isn't available.
    printf '%s' "$(echo "$input" | grep -o '"cwd":"[^"]*"' | head -n1 | cut -d'"' -f4)"
    exit 0
  fi

  local model_display ctx_str rate_str diff_str line
  model_display=$(get_model_display)
  ctx_str=$(get_context_str)
  rate_str=$(get_quota_str)
  diff_str=$(get_branch_diff_str)

  line="${c_model}${model_display}${c_reset} ${c_sep} ${ctx_str}"
  [ -n "$rate_str" ] && line="${line} ${c_sep} ${rate_str}"
  [ -n "$diff_str" ] && line="${line} ${c_sep} main..ai-work ${diff_str}"

  printf '%s' "$line"
}

# ---------- helpers (most complex first) ----------

# +/- lines between remote main and remote ai-work, via a cached, live GitHub API call.
get_branch_diff_str() {
  local owner repo host
  read -r owner repo host <<< "$(resolve_repo_coords)"
  [ -n "$owner" ] && [ -n "$repo" ] || return
  { [ -z "$host" ] || [ "$host" = "github.com" ]; } || return

  local cache_dir="$HOME/.claude/.cache"
  mkdir -p "$cache_dir" 2>/dev/null
  # Same cache as the Claude Code status line, so both CLIs share one API call per TTL.
  local cache_file="${cache_dir}/statusline-diff-${owner}-${repo}-main-ai-work.cache"
  local ttl=120

  local diff_str
  diff_str=$(read_diff_cache "$cache_file" "$ttl") && { echo "$diff_str"; return; }

  local compare_json add del
  compare_json=$(fetch_compare_json "$owner" "$repo")
  if [ -n "$compare_json" ] && echo "$compare_json" | jq -e 'has("files") or has("status")' >/dev/null 2>&1; then
    add=$(echo "$compare_json" | jq -r '[(.files // [])[].additions] | add // 0' 2>/dev/null)
    del=$(echo "$compare_json" | jq -r '[(.files // [])[].deletions] | add // 0' 2>/dev/null)
    if [ -n "$add" ] && [ -n "$del" ]; then
      diff_str="${c_green}+${add}${c_reset}/${c_red}-${del}${c_reset}"
      printf '%s\n%s\n' "$(date +%s)" "$diff_str" > "$cache_file" 2>/dev/null
      echo "$diff_str"
      return
    fi
  fi

  # API call failed -- fall back to the last known-good value instead of showing nothing.
  [ -f "$cache_file" ] && sed -n '2p' "$cache_file"
}

# Quota used for the current model, with time until reset. The payload gives
# remaining_fraction per model id, so used% is its complement.
get_quota_str() {
  local model_id remaining pct_int color reset_in seg
  model_id=$(echo "$input" | jq -r '.model.id // empty')
  [ -n "$model_id" ] || return
  remaining=$(echo "$input" | jq -r --arg m "$model_id" '.quota[$m].remaining_fraction // empty')
  [ -n "$remaining" ] || return
  pct_int=$(awk -v r="$remaining" 'BEGIN { printf "%.0f", (1 - r) * 100 }')
  color="$c_green"
  [ "$pct_int" -ge 70 ] && color="$c_yellow"
  [ "$pct_int" -ge 90 ] && color="$c_red"
  seg="Quota ${color}${pct_int}%${c_reset}"
  reset_in=$(echo "$input" | jq -r --arg m "$model_id" '.quota[$m].reset_in_seconds // empty')
  if [ -n "$reset_in" ]; then
    seg="${seg}${c_dim} (resets $(fmt_remaining $(( $(date +%s) + ${reset_in%.*} ))))${c_reset}"
  fi
  echo "$seg"
}

# Prints "owner repo host", parsed from the local git remote's URL (the
# Antigravity payload has no repo coordinates) -- the diff itself always comes from a live API call.
resolve_repo_coords() {
  local owner repo host project_dir remote_url parsed
  project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .cwd // empty')

  if [ -n "$project_dir" ] && have git; then
    remote_url=$(git -C "$project_dir" --no-optional-locks config --get remote.origin.url 2>/dev/null)
    if [ -n "$remote_url" ]; then
      parsed=$(echo "$remote_url" | sed -E 's#^git@([^:]+):#https://\1/#' | sed -E 's#\.git$##')
      host=$(echo "$parsed" | sed -E 's#https?://([^/]+)/.*#\1#')
      owner=$(echo "$parsed" | sed -E 's#https?://[^/]+/([^/]+)/([^/]+)#\1#')
      repo=$(echo "$parsed" | sed -E 's#https?://[^/]+/([^/]+)/([^/]+)#\2#')
    fi
  fi

  echo "$owner $repo $host"
}

# Prefers `gh` since it's already authenticated; curl needs an explicit token.
fetch_compare_json() {
  local owner="$1" repo="$2" compare_json="" auth_header=()
  if have gh; then
    if have timeout; then
      compare_json=$(timeout 4 gh api "repos/${owner}/${repo}/compare/main...ai-work" 2>/dev/null)
    else
      compare_json=$(gh api "repos/${owner}/${repo}/compare/main...ai-work" 2>/dev/null)
    fi
  elif have curl; then
    if [ -n "$GITHUB_TOKEN" ]; then auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
    elif [ -n "$GH_TOKEN" ]; then auth_header=(-H "Authorization: Bearer $GH_TOKEN")
    fi
    compare_json=$(curl -fsS --max-time 4 "${auth_header[@]}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${owner}/${repo}/compare/main...ai-work" 2>/dev/null)
  fi
  echo "$compare_json"
}

# Context window usage as a percentage.
get_context_str() {
  local ctx_pct ctx_int ctx_color
  ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
  if [ -n "$ctx_pct" ] && [ "$ctx_pct" != "null" ]; then
    ctx_int=$(printf '%.0f' "$ctx_pct")
    if [ "$ctx_int" -ge 80 ]; then ctx_color="$c_red"
    elif [ "$ctx_int" -ge 50 ]; then ctx_color="$c_yellow"
    else ctx_color="$c_green"
    fi
    echo "Ctx ${ctx_color}${ctx_int}%${c_reset}"
  else
    echo "Ctx ${c_dim}n/a${c_reset}"
  fi
}

# Model shown in the Antigravity TUI.
get_model_display() {
  echo "$input" | jq -r '.model.display_name // .model.id // "unknown"'
}

# Returns 1 (no output) on a cache miss so callers can fall through to a live fetch.
read_diff_cache() {
  local cache_file="$1" ttl="$2" now_ts cached_ts
  [ -f "$cache_file" ] || return 1
  now_ts=$(date +%s)
  cached_ts=$(sed -n '1p' "$cache_file" 2>/dev/null)
  if [ -n "$cached_ts" ] && [ $(( now_ts - cached_ts )) -lt "$ttl" ]; then
    sed -n '2p' "$cache_file"
    return 0
  fi
  return 1
}

fmt_remaining() {
  local resets_at="$1" now diff h m
  now=$(date +%s)
  diff=$(( resets_at - now ))
  if [ "$diff" -le 0 ]; then echo "resetting"; return; fi
  h=$(( diff / 3600 ))
  m=$(( (diff % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then echo "${h}h${m}m"; else echo "${m}m"; fi
}

have() { command -v "$1" >/dev/null 2>&1; }

main
