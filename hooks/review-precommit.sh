#!/bin/bash
# PreToolUse hook: Nudge/gate before git commit if no review was done
# Checks session_state.paused and recent review history

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# Only trigger on git commit commands
echo "$cmd" | grep -qE 'git\s+commit' || exit 0
# Don't trigger on --amend
echo "$cmd" | grep -qE '\-\-amend' && exit 0

CONF=".claude/review/confidence.json"
[[ ! -f "$CONF" ]] && exit 0

# Check if paused — if so, allow silently
paused=$(jq -r '.session_state.paused // false' "$CONF" 2>/dev/null)
if [[ "$paused" == "true" ]]; then
  exit 0
fi

# Check if emergency mode
emergency=$(jq -r '.session_state.emergency // false' "$CONF" 2>/dev/null)
[[ "$emergency" == "true" ]] && exit 0

# Check hook mode
mode=$(jq -r '.review_hooks.precommit_mode // "nudge"' "$CONF" 2>/dev/null)
[[ "$mode" == "off" ]] && exit 0

# Check if a review was done today
today=$(date -u +%Y-%m-%d)
recent_review=false
if [[ -d ".claude/review/history" ]] && ls .claude/review/history/${today}-* 1>/dev/null 2>&1; then
  recent_review=true
fi

if [[ "$recent_review" == "false" ]]; then
  if [[ "$mode" == "gate" ]]; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "REVIEW GATE: No /review found today. Run /review first, or /review --skip \"reason\" to bypass."
      }
    }'
  else
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: "REVIEW NUDGE: No /review found today. Consider running /review before committing. Skip with /review --skip \"reason\"."
      }
    }'
  fi
fi
