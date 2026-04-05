#!/bin/bash
# PostToolUse hook: Grep for common Python anti-patterns

f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0
[[ -z "$f" || "$f" != *.py || ! -f "$f" ]] && exit 0

# Skip test files
[[ "$f" == *test_* || "$f" == *_test.py || "$f" == *tests/* ]] && exit 0

issues=""

# eval/exec — code injection
if grep -qE '\b(eval|exec)\s*\(' "$f" 2>/dev/null; then
  issues="${issues}- SECURITY: eval()/exec() found. Use ast.literal_eval or safer alternatives.\n"
fi

# subprocess with shell=True — command injection
if grep -qE 'subprocess\.\w+\(.*shell\s*=\s*True' "$f" 2>/dev/null; then
  issues="${issues}- SECURITY: subprocess with shell=True. Use shell=False with argument list.\n"
fi

# pickle.loads on potentially untrusted data
if grep -qE 'pickle\.(loads|load)\s*\(' "$f" 2>/dev/null; then
  issues="${issues}- SECURITY: pickle deserialization found. pickle can execute arbitrary code — verify input is trusted.\n"
fi

# os.system — command injection
if grep -qE 'os\.system\s*\(' "$f" 2>/dev/null; then
  issues="${issues}- SECURITY: os.system() found. Use subprocess.run() with shell=False.\n"
fi

# assert for runtime validation (disabled with python -O)
if grep -qE '^\s*assert\s+' "$f" 2>/dev/null; then
  issues="${issues}- REVIEW: assert used for validation. assert is disabled with python -O. Use if/raise for runtime checks.\n"
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
