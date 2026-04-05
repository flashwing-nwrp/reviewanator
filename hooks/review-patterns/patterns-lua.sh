#!/bin/bash
# PostToolUse hook: Grep for common Lua/FiveM anti-patterns
# Complements lua-footgun-check.sh — different checks, no overlap

f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0
[[ -z "$f" || "$f" != *.lua || ! -f "$f" ]] && exit 0

issues=""

# Client-side 'source' usage (meaningless on client, server-only variable)
if echo "$f" | grep -qiE '(client|cl_)'; then
  if grep -E '\bsource\b' "$f" 2>/dev/null | grep -vE '^\s*--' | grep -q .; then
    issues="${issues}- FIVEM: 'source' variable used in client-side file. source is only meaningful on server side.\n"
  fi
fi

# while true do without Wait (infinite freeze)
if grep -qE 'while\s+true\s+do' "$f" 2>/dev/null; then
  while_blocks=$(grep -A 5 -E 'while\s+true\s+do' "$f" 2>/dev/null)
  if ! echo "$while_blocks" | grep -qE '(Wait|Citizen\.Wait)' 2>/dev/null; then
    issues="${issues}- PERFORMANCE: while true do without Wait() will freeze the game. Add Wait(N) inside the loop.\n"
  fi
fi

# RegisterCommand without ACE restriction (file-global check — may miss per-occurrence gaps)
if grep -qE 'RegisterCommand\s*\(' "$f" 2>/dev/null; then
  if ! grep -qE '(IsPlayerAceAllowed|IsAceAllowed|group\.)' "$f" 2>/dev/null; then
    issues="${issues}- SECURITY: RegisterCommand without ACE permission check. Add IsPlayerAceAllowed or restrict via ACE.\n"
  fi
fi

# TriggerClientEvent with -1 source (broadcast)
if grep -qE 'TriggerClientEvent\s*\([^,]*,\s*-1' "$f" 2>/dev/null; then
  issues="${issues}- REVIEW: TriggerClientEvent broadcast to all players (-1). Verify this should go to everyone.\n"
fi

if [[ -n "$issues" ]]; then
  issues_json=$(printf '%s' "$issues" | jq -Rs .)
  jq -n --arg f "$f" --argjson issues "$issues_json" '{
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: ("REVIEW PATTERN WARNINGS in " + $f + ":\n" + $issues)
    }
  }'
fi
