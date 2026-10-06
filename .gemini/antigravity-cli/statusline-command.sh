#!/bin/bash
# Antigravity CLI status line (stdin schema: https://antigravity.google/docs/cli/statusline).
# Antigravity kills a slow status command, and on a loaded VM every fork costs
# ~0.5s, so this sticks to one jq call plus bash builtins, and never waits on
# the network: the main..ai-work diff is served from cache and refreshed in the
# background. The diff comes from the GitHub API rather than the local git
# tree, so it stays accurate even in a sparse checkout.

# ---------- colors ----------
c_reset=$'\033[0m'
c_dim=$'\033[2m'
c_model=$'\033[36m'
c_green=$'\033[32m'
c_yellow=$'\033[33m'
c_red=$'\033[31m'
c_sep="${c_dim}|${c_reset}"

# Same cache as the Claude Code status line, so both CLIs share one API call per TTL.
cache_dir="$HOME/.claude/.cache"
diff_ttl=120

main() {
  local model_display ctx_pct used_5h reset_5h used_7d reset_7d project_dir
  # \x1f, not tab: read collapses runs of whitespace IFS, which would drop empty fields.
  IFS=$'\x1f' read -r model_display ctx_pct used_5h reset_5h used_7d reset_7d project_dir < <(jq -r '
    # Quota is bucketed by model family, not keyed by model id: gemini-* for
    # Gemini models, 3p-* for third-party ones.
    (if ((.model.id // "") | test("gemini"; "i")) then "gemini" else "3p" end) as $fam
    | def used: if . == null then "" else ((1 - .) * 100 | round) end;
      def secs: if . == null then "" else floor end;
    [ (.model.display_name // .model.id // "unknown"),
      (.context_window.used_percentage | if . == null then "" else round end),
      (.quota["\($fam)-5h"].remaining_fraction | used),
      (.quota["\($fam)-5h"].reset_in_seconds | secs),
      (.quota["\($fam)-weekly"].remaining_fraction | used),
      (.quota["\($fam)-weekly"].reset_in_seconds | secs),
      (.workspace.project_dir // .cwd // "") ]
    | map(tostring) | join("\u001f")')

  printf -v now '%(%s)T' -1

  local line ctx_str quota_str diff_str
  ctx_str=$(format_ctx "$ctx_pct")
  quota_str=$(format_quota 5h "$used_5h" "$reset_5h")
  quota_str="${quota_str:+$quota_str }$(format_quota 7d "$used_7d" "$reset_7d")"
  quota_str="${quota_str% }"
  diff_str=$(get_branch_diff_str "$project_dir")

  line="${c_model}${model_display}${c_reset} ${c_sep} ${ctx_str}"
  [ -n "$quota_str" ] && line="${line} ${c_sep} ${quota_str}"
  [ -n "$diff_str" ] && line="${line} ${c_sep} main..ai-work ${diff_str}"

  printf '%s' "$line"
}

# ---------- helpers (most complex first) ----------

# Prints the cached +/- diff and, if the cache is stale, kicks off a detached refresh.
get_branch_diff_str() {
  local project_dir="$1" coords owner repo cache_file cached_ts cached_val
  coords=$(resolve_repo_coords "$project_dir") || return
  read -r owner repo <<< "$coords"
  cache_file="${cache_dir}/statusline-diff-${owner}-${repo}-main-ai-work.cache"

  if [ -f "$cache_file" ]; then
    { read -r cached_ts; read -r cached_val; } < "$cache_file"
  fi
  if [ -z "$cached_ts" ] || (( now - cached_ts >= diff_ttl )); then
    refresh_diff_cache_async "$owner" "$repo" "$cache_file"
  fi
  printf '%s' "$cached_val"
}

# Detached so Antigravity doesn't wait on (or kill) the API call; the lock dir
# stops every redraw from spawning another fetch while one is in flight.
refresh_diff_cache_async() {
  local owner="$1" repo="$2" cache_file="$3" lock="${3}.lock"
  mkdir -p "$cache_dir" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return
  (
    trap 'rmdir "$lock"' EXIT
    local json add_del
    json=$(timeout 10 gh api "repos/${owner}/${repo}/compare/main...ai-work" 2>/dev/null) || exit
    add_del=$(jq -r '[([(.files // [])[].additions] | add // 0), ([(.files // [])[].deletions] | add // 0)] | @tsv' <<< "$json") || exit
    local add del
    IFS=$'\t' read -r add del <<< "$add_del"
    printf '%s\n%s\n' "$(date +%s)" "${c_green}+${add}${c_reset}/${c_red}-${del}${c_reset}" > "$cache_file"
  ) </dev/null >/dev/null 2>&1 &
  disown
}

# Prints "owner repo" for a github.com origin remote; returns 1 otherwise.
resolve_repo_coords() {
  local project_dir="$1" remote_url
  [ -n "$project_dir" ] || return 1
  remote_url=$(git -C "$project_dir" --no-optional-locks config --get remote.origin.url 2>/dev/null) || return 1
  [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/]+)$ ]] || return 1
  printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
}

# One quota window's used %, with time until reset.
format_quota() {
  local label="$1" used="$2" reset_in="$3" color seg
  [ -n "$used" ] || return
  color="$c_green"
  (( used >= 70 )) && color="$c_yellow"
  (( used >= 90 )) && color="$c_red"
  seg="${label} ${color}${used}%${c_reset}"
  [ -n "$reset_in" ] && seg="${seg}${c_dim} (resets $(fmt_duration "$reset_in"))${c_reset}"
  printf '%s' "$seg"
}

format_ctx() {
  local pct="$1" color
  if [ -z "$pct" ]; then printf 'Ctx %sn/a%s' "$c_dim" "$c_reset"; return; fi
  color="$c_green"
  (( pct >= 50 )) && color="$c_yellow"
  (( pct >= 80 )) && color="$c_red"
  printf 'Ctx %s%s%%%s' "$color" "$pct" "$c_reset"
}

fmt_duration() {
  local secs="$1" h m
  if (( secs <= 0 )); then printf 'resetting'; return; fi
  h=$(( secs / 3600 ))
  m=$(( (secs % 3600) / 60 ))
  if (( h > 0 )); then printf '%sh%sm' "$h" "$m"; else printf '%sm' "$m"; fi
}

main
