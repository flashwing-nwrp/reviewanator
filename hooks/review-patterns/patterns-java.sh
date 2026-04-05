#!/bin/bash
# PostToolUse hook: Grep for common Java/Spring anti-patterns
# Fast, zero-token, non-blocking

f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0
[[ -z "$f" || "$f" != *.java || ! -f "$f" ]] && exit 0

# Skip test files — relaxed rules for tests
[[ "$f" == *Test.java || "$f" == *Tests.java || "$f" == *test/* || "$f" == *tests/* ]] && exit 0

issues=""

# SQL string concatenation (potential injection) — checks both directions
if grep -iE '(select|insert|update|delete)\b.*"\s*\+|"\s*\+\s*\w+.*(query|sql|select|insert|update|delete)' "$f" 2>/dev/null | grep -vE '^\s*//' | grep -q .; then
  issues="${issues}- SECURITY: Possible SQL string concatenation. Use parameterized queries or PreparedStatement.\n"
fi

# System.out in production code
if grep -qE 'System\.(out|err)\.(print|println)' "$f" 2>/dev/null; then
  issues="${issues}- CLEANUP: System.out/err.print found. Use SLF4J logger instead.\n"
fi

# printStackTrace (information leak)
if grep -qE '\.printStackTrace\(\)' "$f" 2>/dev/null; then
  issues="${issues}- CLEANUP: .printStackTrace() found. Use logger.error(\"msg\", ex) instead.\n"
fi

# Unmanaged Thread creation in Spring
if grep -qE 'new\s+Thread\(' "$f" 2>/dev/null; then
  issues="${issues}- THREADING: Raw Thread creation in Spring. Use @Async, ExecutorService, or TaskExecutor.\n"
fi

# @SuppressWarnings hiding real issues
if grep -qE '@SuppressWarnings' "$f" 2>/dev/null; then
  issues="${issues}- REVIEW: @SuppressWarnings found. Verify the suppression is justified.\n"
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
