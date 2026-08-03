#!/bin/bash
# Claude Code status line.
#
# Shows:
#   1. The actual model in use (resolved via the transcript so auto-routing
#      shows the real underlying model, not just the "auto" alias).
#   2. Context window usage as a percentage.
#   3. 5-hour / 7-day rate-limit usage; once either crosses 70% it also shows
#      the time remaining until that window resets.
#   4. +/- line diff between the remote 'main' and remote 'ai-work' branches,
#      queried live from the GitHub API (never the local git tree).

input=$(cat)

have() { command -v "$1" >/dev/null 2>&1; }

if ! have jq; then
  # Minimal fallback if jq isn't available.
  printf '%s' "$(echo "$input" | grep -o '"cwd":"[^"]*"' | head -n1 | cut -d'"' -f4)"
  exit 0
fi

# ---------- colors ----------
c_reset=$'\033[0m'
c_dim=$'\033[2m'
c_model=$'\033[36m'
c_green=$'\033[32m'
c_yellow=$'\033[33m'
c_red=$'\033[31m'
c_sep="${c_dim}|${c_reset}"

# Turn a raw model id like "claude-opus-4-5-20250929" into "Opus 4.5"
format_model_id() {
  local s="$1"
  s="${s%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}"   # strip trailing -YYYYMMDD
  s="${s#claude-}"                                      # strip leading "claude-"
  local IFS='-'
  local parts=()
  read -ra parts <<< "$s"
  local out="" prev_num=false p cap
  for p in "${parts[@]}"; do
    if [[ "$p" =~ ^[0-9]+$ ]]; then
      if $prev_num; then out="${out}.${p}"; else out="${out} ${p}"; fi
      prev_num=true
    else
      cap="$(tr '[:lower:]' '[:upper:]' <<< "${p:0:1}")${p:1}"
      out="${out} ${cap}"
      prev_num=false
    fi
  done
  out="${out# }"
  if [ -n "$out" ]; then echo "$out"; else echo "$1"; fi
}

# ---------- 1. actual model in use (resolves auto-routing via the transcript) ----------
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
model_raw=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  model_raw=$(tail -n 400 "$transcript_path" 2>/dev/null | jq -rs '
    [.[] | select(.type=="assistant") | .message.model? // empty] | last // empty
  ' 2>/dev/null)
fi

if [ -n "$model_raw" ] && [ "$model_raw" != "null" ]; then
  model_display=$(format_model_id "$model_raw")
else
  model_display=$(echo "$input" | jq -r '.model.display_name // .model.id // "unknown"')
fi

# ---------- 2. context window usage ----------
ctx_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$ctx_pct" ] && [ "$ctx_pct" != "null" ]; then
  ctx_int=$(printf '%.0f' "$ctx_pct")
  if [ "$ctx_int" -ge 80 ]; then ctx_color="$c_red"
  elif [ "$ctx_int" -ge 50 ]; then ctx_color="$c_yellow"
  else ctx_color="$c_green"
  fi
  ctx_str="Ctx ${ctx_color}${ctx_int}%${c_reset}"
else
  ctx_str="Ctx ${c_dim}n/a${c_reset}"
fi

# ---------- 3. 5h / 7d rate limits ----------
fmt_remaining() {
  local resets_at="$1" now diff h m
  now=$(date +%s)
  diff=$(( resets_at - now ))
  if [ "$diff" -le 0 ]; then echo "resetting"; return; fi
  h=$(( diff / 3600 ))
  m=$(( (diff % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then echo "${h}h${m}m"; else echo "${m}m"; fi
}

rate_str=""
for window in five_hour seven_day; do
  label="5h"; [ "$window" = "seven_day" ] && label="7d"
  pct=$(echo "$input" | jq -r ".rate_limits.${window}.used_percentage // empty")
  [ -z "$pct" ] || [ "$pct" = "null" ] && continue
  pct_int=$(printf '%.0f' "$pct")
  color="$c_green"
  [ "$pct_int" -ge 70 ] && color="$c_yellow"
  [ "$pct_int" -ge 90 ] && color="$c_red"
  seg="${label} ${color}${pct_int}%${c_reset}"
  if [ "$pct_int" -ge 70 ]; then
    resets_at=$(echo "$input" | jq -r ".rate_limits.${window}.resets_at // empty")
    if [ -n "$resets_at" ] && [ "$resets_at" != "null" ]; then
      remaining=$(fmt_remaining "$resets_at")
      seg="${seg}${c_dim} (resets ${remaining})${c_reset}"
    fi
  fi
  if [ -n "$rate_str" ]; then rate_str="${rate_str} ${seg}"; else rate_str="${seg}"; fi
done

# ---------- 4. +/- lines between remote main and remote ai-work (live GitHub state) ----------
owner=$(echo "$input" | jq -r '.workspace.repo.owner // empty')
repo=$(echo "$input" | jq -r '.workspace.repo.name // empty')
host=$(echo "$input" | jq -r '.workspace.repo.host // empty')
project_dir=$(echo "$input" | jq -r '.workspace.project_dir // .cwd // empty')

# Fallback: if Claude Code didn't supply workspace.repo, derive owner/name from
# the local git remote URL. This only reads the remote's *name*, never its
# state -- the actual diff still comes from a live GitHub API call below.
if { [ -z "$owner" ] || [ -z "$repo" ]; } && [ -n "$project_dir" ] && have git; then
  remote_url=$(git -C "$project_dir" --no-optional-locks config --get remote.origin.url 2>/dev/null)
  if [ -n "$remote_url" ]; then
    parsed=$(echo "$remote_url" | sed -E 's#^git@([^:]+):#https://\1/#' | sed -E 's#\.git$##')
    host=$(echo "$parsed" | sed -E 's#https?://([^/]+)/.*#\1#')
    owner=$(echo "$parsed" | sed -E 's#https?://[^/]+/([^/]+)/([^/]+)#\1#')
    repo=$(echo "$parsed" | sed -E 's#https?://[^/]+/([^/]+)/([^/]+)#\2#')
  fi
fi

diff_str=""
if [ -n "$owner" ] && [ -n "$repo" ] && { [ -z "$host" ] || [ "$host" = "github.com" ]; }; then
  cache_dir="$HOME/.claude/.cache"
  mkdir -p "$cache_dir" 2>/dev/null
  cache_file="${cache_dir}/statusline-diff-${owner}-${repo}-main-ai-work.cache"
  ttl=120
  now_ts=$(date +%s)
  use_cache=false
  if [ -f "$cache_file" ]; then
    cached_ts=$(sed -n '1p' "$cache_file" 2>/dev/null)
    if [ -n "$cached_ts" ] && [ $(( now_ts - cached_ts )) -lt "$ttl" ]; then
      use_cache=true
    fi
  fi

  if $use_cache; then
    diff_str=$(sed -n '2p' "$cache_file")
  else
    compare_json=""
    if have gh; then
      if have timeout; then
        compare_json=$(timeout 4 gh api "repos/${owner}/${repo}/compare/main...ai-work" 2>/dev/null)
      else
        compare_json=$(gh api "repos/${owner}/${repo}/compare/main...ai-work" 2>/dev/null)
      fi
    elif have curl; then
      auth_header=()
      if [ -n "$GITHUB_TOKEN" ]; then auth_header=(-H "Authorization: Bearer $GITHUB_TOKEN")
      elif [ -n "$GH_TOKEN" ]; then auth_header=(-H "Authorization: Bearer $GH_TOKEN")
      fi
      compare_json=$(curl -fsS --max-time 4 "${auth_header[@]}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${owner}/${repo}/compare/main...ai-work" 2>/dev/null)
    fi

    if [ -n "$compare_json" ] && echo "$compare_json" | jq -e 'has("files") or has("status")' >/dev/null 2>&1; then
      add=$(echo "$compare_json" | jq -r '[(.files // [])[].additions] | add // 0' 2>/dev/null)
      del=$(echo "$compare_json" | jq -r '[(.files // [])[].deletions] | add // 0' 2>/dev/null)
      if [ -n "$add" ] && [ -n "$del" ]; then
        diff_str="${c_green}+${add}${c_reset}/${c_red}-${del}${c_reset}"
        printf '%s\n%s\n' "$now_ts" "$diff_str" > "$cache_file" 2>/dev/null
      fi
    fi

    # API call failed (branch missing, offline, rate-limited, etc.) -- reuse
    # the last known-good value if we have one rather than showing nothing.
    if [ -z "$diff_str" ] && [ -f "$cache_file" ]; then
      diff_str=$(sed -n '2p' "$cache_file")
    fi
  fi
fi

# ---------- assemble ----------
line="${c_model}${model_display}${c_reset} ${c_sep} ${ctx_str}"
[ -n "$rate_str" ] && line="${line} ${c_sep} ${rate_str}"
[ -n "$diff_str" ] && line="${line} ${c_sep} main..ai-work ${diff_str}"

printf '%s' "$line"
