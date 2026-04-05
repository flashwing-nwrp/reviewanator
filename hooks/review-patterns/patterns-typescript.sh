#!/bin/bash
# PostToolUse hook: Grep for common TypeScript/React anti-patterns

f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0
[[ -z "$f" || ! -f "$f" ]] && exit 0
[[ "$f" != *.ts && "$f" != *.tsx ]] && exit 0

# Skip test files
[[ "$f" == *.test.* || "$f" == *.spec.* || "$f" == *__tests__/* ]] && exit 0

issues=""

# eval() — code injection
if grep -qE '\beval\s*\(' "$f" 2>/dev/null; then
  issues="${issues}- SECURITY: eval() found. Avoid eval — use safer alternatives.\n"
fi

# dangerouslySetInnerHTML — XSS
if grep -qE 'dangerouslySetInnerHTML' "$f" 2>/dev/null; then
  issues="${issues}- SECURITY: dangerouslySetInnerHTML found. Ensure input is sanitized (DOMPurify or similar).\n"
fi

# innerHTML assignment — XSS
if grep -qE '\.innerHTML\s*=' "$f" 2>/dev/null; then
  issues="${issues}- SECURITY: Direct innerHTML assignment. Use textContent or a sanitization library.\n"
fi

# Type escape hatches
if grep -qE ':\s*any\b' "$f" 2>/dev/null; then
  issues="${issues}- TYPE-SAFETY: 'any' type found. Use a specific type or 'unknown' with type guards.\n"
fi

# ts-ignore without justification
if grep -qE '@ts-ignore' "$f" 2>/dev/null; then
  issues="${issues}- TYPE-SAFETY: @ts-ignore found. Prefer @ts-expect-error with a comment explaining why.\n"
fi

# console.log left in production code
if grep -qE 'console\.(log|debug|info)\(' "$f" 2>/dev/null; then
  issues="${issues}- CLEANUP: console.log/debug/info found. Remove before merge or use a proper logger.\n"
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
