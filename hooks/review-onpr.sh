#!/bin/bash
# PreToolUse hook: Nudge/gate before gh pr create if no branch review was done

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0

# Only trigger on gh pr create
echo "$cmd" | grep -qE 'gh\s+pr\s+create' || exit 0

CONF=".claude/review/confidence.json"
[[ ! -f "$CONF" ]] && exit 0

# Check if paused or emergency
paused=$(jq -r '.session_state.paused // false' "$CONF" 2>/dev/null)
emergency=$(jq -r '.session_state.emergency // false' "$CONF" 2>/dev/null)
[[ "$paused" == "true" || "$emergency" == "true" ]] && exit 0

# Check hook mode
mode=$(jq -r '.review_hooks.pr_mode // "nudge"' "$CONF" 2>/dev/null)
[[ "$mode" == "off" ]] && exit 0

# Check if a branch review exists in recent history
branch_reviewed=false
for f in .claude/review/history/*.json; do
  [[ ! -f "$f" ]] && break
  if jq -r '.mode // empty' "$f" 2>/dev/null | grep -qE '^(branch|full)$'; then
    branch_reviewed=true
    break
  fi
done

if [[ "$branch_reviewed" == "false" ]]; then
  if [[ "$mode" == "gate" ]]; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "REVIEW GATE: No branch review found. Run /review --branch first, or /review --skip \"reason\" to bypass."
      }
    }'
  else
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        additionalContext: "REVIEW NUDGE: Consider running /review --branch before creating this PR."
      }
    }'
  fi
fi
