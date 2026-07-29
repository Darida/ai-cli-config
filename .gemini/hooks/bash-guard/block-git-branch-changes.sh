#!/bin/bash
# Enforce ai-work branch isolation policy

cmd=$(jq -r '.tool_input.CommandLine // .tool_input.command // empty')

if ! echo "$cmd" | grep -iwE '(git|gh)' > /dev/null; then
  echo '{"continue": true}'
  exit 0
fi

if echo "$cmd" | grep -iE 'git\s+(checkout|switch)' > /dev/null; then
  echo '{"continue": false, "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Agent must always operate only within the dedicated ai-work branch and never attempt to access other branches no matter what reason is given."}}'
  exit 0
fi

if echo "$cmd" | grep -iE '(git\s+pr\s+approve|gh\s+pr\s+review.*--approve)' > /dev/null; then
  echo '{"continue": false, "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Agent must always operate only within the dedicated ai-work branch and never attempt to access other branches no matter what reason is given."}}'
  exit 0
fi

echo '{"continue": true}'
