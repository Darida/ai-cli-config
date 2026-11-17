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
rm -rf "${HOME:?}/.cache"/* && echo "ok" || echo "failed"

section "npm cache (~/.npm/*)"
if [ -d "${HOME:?}/.npm" ]; then
  rm -rf "${HOME:?}/.npm"/* && echo "ok" || echo "failed"
else
  echo "not present"
fi

section "go build cache"
if command -v go >/dev/null 2>&1; then
  go clean -cache && echo "ok" || echo "failed"
else
  echo "skipped (go not on PATH)"
fi

section "go module cache (forces re-download of every dependency on next build)"
if command -v go >/dev/null 2>&1; then
  go clean -modcache && echo "ok" || echo "failed"
else
  echo "skipped (go not on PATH)"
fi

echo
echo "Done."
