#!/bin/bash
# Reclaims disk space on this VM: package caches, rotated/active logs,
# and developer tool caches. Everything here is regenerable or rotated
# data — never project source or git history.
set -uo pipefail

section() { echo; echo "== $1 =="; }

HAVE_SUDO=0
if sudo -n true 2>/dev/null; then
  HAVE_SUDO=1
fi

section "apt package cache"
if [ "$HAVE_SUDO" = 1 ]; then
  sudo apt clean && echo "ok" || echo "failed"
else
  echo "skipped (no passwordless sudo)"
fi

section "apt autoremove"
if [ "$HAVE_SUDO" = 1 ]; then
  sudo apt autoremove -y && echo "ok" || echo "failed"
else
  echo "skipped (no passwordless sudo)"
fi

section "systemd journal (keep last 3 days)"
if [ "$HAVE_SUDO" = 1 ]; then
  sudo journalctl --vacuum-time=3d && echo "ok" || echo "failed"
else
  echo "skipped (no passwordless sudo)"
fi

section "syslog rotation (daily + compress, so syslog stops refilling the disk)"
RSYSLOG_ROTATE=/etc/logrotate.d/rsyslog
if [ ! -f "$RSYSLOG_ROTATE" ]; then
  echo "not present"
elif [ "$HAVE_SUDO" != 1 ]; then
  echo "skipped (no passwordless sudo)"
elif grep -qE '^\s*daily\s*$' "$RSYSLOG_ROTATE" && grep -qE '^\s*compress\s*$' "$RSYSLOG_ROTATE"; then
  echo "already daily + compress"
else
  sudo sed -i -E 's/^(\s*)(weekly|monthly)\s*$/\1daily/' "$RSYSLOG_ROTATE"
  if grep -qE '^\s*daily\s*$' "$RSYSLOG_ROTATE" && grep -qE '^\s*compress\s*$' "$RSYSLOG_ROTATE"; then
    echo "set to daily + compress"
  else
    echo "failed (unexpected format, edit $RSYSLOG_ROTATE by hand)"
  fi
fi

section "rotated syslog backup (/var/log/syslog.1)"
if [ ! -f /var/log/syslog.1 ]; then
  echo "not present"
elif [ "$HAVE_SUDO" = 1 ]; then
  sudo rm -f /var/log/syslog.1 && echo "removed" || echo "failed"
else
  echo "skipped (no passwordless sudo)"
fi

section "active syslog (truncate in place, not delete, so logging keeps working)"
if [ ! -f /var/log/syslog ]; then
  echo "not present"
elif [ "$HAVE_SUDO" = 1 ]; then
  sudo truncate -s 0 /var/log/syslog && echo "truncated" || echo "failed"
else
  echo "skipped (no passwordless sudo)"
fi

section "user cache directory (~/.cache/*)"
# Includes the Go build cache (~/.cache/go-build) on purpose: one slow Go build
# afterwards (~5 min) is an accepted price for a fully clean cache.
rm -rf "${HOME:?}/.cache"/* && echo "ok" || echo "failed"

section "npm cache (~/.npm/*)"
if [ -d "${HOME:?}/.npm" ]; then
  rm -rf "${HOME:?}/.npm"/* && echo "ok" || echo "failed"
else
  echo "not present"
fi

section "Claude Code session temp (/tmp/claude-$(id -u), entries untouched 3+ days)"
CLAUDE_TMP="/tmp/claude-$(id -u)"
if [ -d "$CLAUDE_TMP" ]; then
  # Age-based so live sessions' scratch and task output survive.
  find "$CLAUDE_TMP" -mindepth 1 -type f -mtime +3 -delete \
    && find "$CLAUDE_TMP" -mindepth 1 -type d -empty -mtime +3 -delete \
    && echo "ok" || echo "failed"
else
  echo "not present"
fi

section "old Claude Code versions (~/.local/share/claude/versions, keeps the active one)"
CLAUDE_VERSIONS="${HOME:?}/.local/share/claude/versions"
if [ ! -d "$CLAUDE_VERSIONS" ]; then
  echo "not present"
elif ! command -v claude >/dev/null 2>&1; then
  echo "skipped (claude not on PATH, can't tell which version is active)"
else
  ACTIVE_CLAUDE="$(readlink -f "$(command -v claude)")"
  if [ "$(dirname "$ACTIVE_CLAUDE")" != "$CLAUDE_VERSIONS" ]; then
    echo "failed (active claude $ACTIVE_CLAUDE is not under $CLAUDE_VERSIONS)"
  else
    find "$CLAUDE_VERSIONS" -mindepth 1 -maxdepth 1 ! -path "$ACTIVE_CLAUDE" -exec rm -rf {} + \
      && echo "ok (kept $(basename "$ACTIVE_CLAUDE"))" || echo "failed"
  fi
fi

section "go module cache (forces re-download of every dependency on next build)"
# Kept despite the small gain (~150 MB): the one-time re-download is accepted.
if command -v go >/dev/null 2>&1; then
  go clean -modcache && echo "ok" || echo "failed"
else
  echo "skipped (go not on PATH)"
fi

echo
echo "Done."
