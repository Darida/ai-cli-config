#!/bin/bash
# If the submitted prompt contains a question, nudge the agent to answer
# from existing context using read-only tools instead of taking action.

prompt=$(jq -r '.prompt // empty')

if [[ "$prompt" == *"?"* ]]; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: "This prompt contains a question. Answer it directly, prioritizing existing context. Do not take actions — read-only tools only, and keep tool usage to a minimum."
    }
  }'
else
  echo '{"continue": true}'
fi
