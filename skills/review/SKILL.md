---
name: review
description: Automated code review with isolated subagent. Computes diff, applies language-specific checklists filtered by confidence calibration, dispatches an isolated reviewer, presents findings, and collects feedback to train the system.
user-invocable: true
---

# /review — Automated Code Review

You are the review orchestrator. Follow these steps in order. Use the tools available to you (Read, Write, Edit, Bash, Glob, Grep, Agent) to execute each step.

## Step 0: Parse Arguments

Parse the user's invocation to determine the review mode:

| Argument | Mode | Diff Command |
|----------|------|-------------|
| (none) | Working tree | `git diff HEAD` |
| `--staged` | Staged only | `git diff --cached` |
| `--commit <sha>` | Single commit | `git diff <sha>~1..<sha>` |
| `--branch` | Branch diff | `git diff $(git merge-base HEAD main)..HEAD` |
| `--pr [number]` | Pull request | `gh pr diff <number>` (or current PR if no number) |
| `--full` | Full suite | Same as mode above, but skip confidence filtering in Step 4 |
| `--calibrate` | Dashboard | Skip to Step 10 (show calibration dashboard) |
| `--budget` | Spend report | Skip to Step 11 (show spend) |
| `--skip "reason"` | Skip review | Log skip to escape_hatch_log in confidence.json, print confirmation, done |
| `--undo` | Rollback | Restore most recent fix checkpoint, done |
| `--pause` | Pause triggers | Set session_state.paused, log. See Step 12 |
| `--resume` | Resume triggers | Clear session_state.paused. See Step 12 |
| `--emergency` | Emergency mode | Disable all enforcement + hooks for session. See Step 12 |
| `--reset` | Reset confidence | Clear category scores (keep rules, config). See Step 12 |
| `--reset --rules` | Reset + rules | Clear scores AND learned rules. See Step 12 |
| `--reset --all` | Full uninstall | Remove entire review system. See Step 12 |
| `--suppress "cat"` | Suppress category | Permanently skip a category. See Step 12 |
| `--set-ceiling X=N` | Adjust ceiling | Validate and update token ceiling. See Step 12 |
| `--help` | Help | Print the command reference (see Help section below), done |
| `--help --glossary` | Glossary | Print the glossary (see Glossary section below), done |

## Step 1: Compute Diff

Run the appropriate git diff command for the mode. Capture the full diff output.

If the diff is empty, report "No changes to review" and stop.

## Step 2: Classify Changed Files and Gather Context

From the diff, extract the list of changed file paths. For each file, determine:

**Language & checklist mapping:**
- `.ts`/`.tsx` → `typescript-react`
- `.java` → `java-spring`
- `.lua` → `lua-fivem`
- `.py` → `python-fastapi`
- Unknown/other extensions → no language-specific checklist (only `_base` applies)
- All files → `_base` (always included)
- **If a file's extension has no matching checklist, it is still reviewable** — `_base` checks apply to all languages. Do not skip the file or error.

**Execution context** — infer from the file path:
- `client/` or `ui/` or `components/` or `pages/` → browser/game client (untrusted environment)
- `server/` or `api/` or `routes/` or `controllers/` → server (trusted, but handles untrusted input)
- `shared/` or `common/` or `lib/` → runs in both contexts (review for both threat models)
- `test/` or `__tests__/` or `*.test.*` or `*.spec.*` → test code (lower bar for style/cleanup, higher bar for assertion quality)
- `config/` or `*.config.*` → configuration (secrets risk, deployment impact)
- `migration/` or `sql/` → schema changes (data integrity risk)

**Skip these files** (do not include in diff sent to reviewer):
- `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `*.lock`
- `*.md` (documentation)
- `*.png`, `*.jpg`, `*.gif`, `*.svg`, `*.ico`, `*.woff`, `*.woff2`, `*.ttf`
- Files matching patterns in the user's `.gitignore`

If no reviewable files remain after filtering, report "No reviewable code changes found" and stop.

**Build a Change Context summary** (this will be sent to the reviewer):
1. **Files changed:** List each file with its language and execution context
2. **Change intent:** Read the most recent commit message (`git log -1 --format=%B` if available) and the diff to infer what the change is doing — new feature, bug fix, refactor, config change
3. **Trust boundaries:** Note any data flow between untrusted → trusted contexts (e.g., "client event sends data to server handler", "user input rendered in UI", "external API response stored in database")
4. **Risk profile:** Based on execution contexts and trust boundaries, note the primary risk areas (e.g., "server endpoint handling user input — input validation and injection are primary concerns")

Format the context as:
```
Files: [list with contexts]
Intent: [1-2 sentences]
Trust boundaries: [identified boundaries, or "none — all code runs in same trust context"]
Primary risk areas: [2-3 most relevant risk categories for this specific change]
```

## Step 3: Load Calibration State

**Error recovery:** Wrap the confidence.json read in error handling. If the file cannot be parsed:
```
Could not read confidence.json ([error type]).
Options:
  1. Attempt auto-repair (fix JSON syntax, rebuild from history/)
  2. Reset to defaults (fresh start)
  3. Show me the error (manual fix)
```

Read `.claude/review/confidence.json`. Extract:
- `config.threshold` — the confidence threshold for auto-approval
- `categories` — the per-category confidence data
- `learned_rules` — rules with `status: "active"` whose `applies_to` glob matches any changed file

**Calculate effective confidence for each category:**

For each category (skip `_aggregate` entries):

**Step A — Base confidence:**
`base = accurate / reviews` (if reviews == 0, base = 0.0)

**Step B — Recency weight + clamp:**
Read the category's `streak` data:
- If `streak.accurate >= 5`: `recency = +0.02`
- Else if `streak.inaccurate >= 3`: `recency = -0.05`
- Else: `recency = 0.0`

`adjusted = clamp(base + recency, 0.0, 1.0)` — **clamp BEFORE decay** to prevent values above 1.0 from inflating the decay interpolation.

**Step C — Decay (long-term staleness):**
Read `last_reviewed`. Calculate `days_since = today - last_reviewed`:
- If null or `days_since <= 30`: no decay. `effective = adjusted`
- If `days_since > 30`:
  - `decay_factor = min(1.0, (days_since - 30) / 30)`
  - Look up `{tag}:_aggregate` confidence
  - `effective = adjusted + (aggregate - adjusted) * decay_factor`
  - (Linear interpolation — with both inputs in [0,1], output guaranteed [0,1])
- At 60+ days: effective equals the aggregate

**Step D — Safety clamp:**
`effective_confidence = clamp(effective, 0.0, 1.0)` (safety net — should never activate if B and C are correct)

Use `effective_confidence` for all filtering in Step 4. Do NOT write it back — recency and decay are computed each time.

**Note:** Decay does NOT affect learned rules. Rules remain active even when their parent category loses auto-approve due to decay.

**Recalculate aggregates** (after any category updates in Step 9):
For each `[tag]`, find all `{tag}:*` categories (excluding `_aggregate`).
Calculate: `weighted_avg = sum(cat.reviews * cat.confidence) / sum(cat.reviews)`.
Write to `{tag}:_aggregate`: `{ "confidence": weighted_avg }`.

**Version-aware calibration:**

When loading a checklist section in Step 4, extract its `<!-- version: N -->` tag. Compare against the stored category's `section_version` in confidence.json:
- If no `section_version` stored on the category: set it to the checklist's version. No special handling (first encounter).
- If stored `section_version` < checklist's version: the section was updated since last calibration.
  - Reset: `reviews = 0`, `accurate = 0`, `confidence = 0.0`, `auto_approve = false`, `streak = { "accurate": 0, "inaccurate": 0 }`
  - Update `section_version` to the new version
  - Log: "Category [key] recalibrated — checklist section updated to v[N]"
  - Do NOT inherit from aggregate — prior accuracy data is stale for the changed section
- If stored `section_version` == checklist's version: no change, proceed normally.

**Learned rules lifecycle check (after loading rules):**

For each learned rule with `status: "active"`:
1. **Stale detection:**
   - Check if `applies_to` glob matches any file in the repo (`git ls-files` with glob)
   - If no files match AND (`last_applied` is null or more than 60 days ago): mark `status: "stale"`, add `stale_reason: "no matching files"`, set `stale_since: today`
   - If files match but `last_applied` is more than 60 days ago: mark `status: "stale"`, add `stale_reason: "not applied in 60+ days"`, set `stale_since: today`
   - If parent category is suppressed: mark `status: "stale"`, add `stale_reason: "parent category suppressed"`, set `stale_since: today`
2. **Auto-prune:** Rules with `status: "stale"` where `stale_since` is 180+ days ago: set `status: "pruned"`
3. **Max active rules:** Count rules with `status: "active"`. If >= 90:
   - Flag rules with `times_applied: 0` and created 30+ days ago as candidates
   - Note for calibration dashboard: "N learned rules approaching limit. M unused rules flagged."
4. **Reactivation:** Rules with `status: "stale"` where `applies_to` NOW matches files: set back to `status: "active"`, clear `stale_reason` and `stale_since`

## Step 3b: Check Recalibration Triggers

Check each trigger. If any fires, set `recalibration_active = true` with scope:

1. **Interval:** If `config.reviews_since_last_full >= config.recalibration_interval` → full recalibration (all categories). Reset counter to 0.
2. **Confidence drop:** If any category was `auto_approve = true` but effective confidence (after decay) dropped below `threshold - 0.02` → recalibrate that category.
3. **Streak miss:** If any category has `streak.inaccurate >= 3` → recalibrate that category + all categories sharing the same tag.
4. **New language:** If a changed file's extension maps to a checklist that has zero categories in confidence.json → recalibrate all sections of that checklist.
5. **Dependency change:** If the diff modifies `package.json`, `pom.xml`, `build.gradle`, `requirements.txt`, `pyproject.toml`, or `go.mod` AND adds/removes more than 5 dependencies → recalibrate `[dependencies]` and `[breaking-changes]` categories.
6. **New contributor:** If `git log -1 --format='%ae'` (author email) has never appeared in any `.claude/review/history/*.json` file → recalibrate all categories (first review from this author).
7. **Manual request (`--full`):** If `--full` was specified, treat as formal recalibration — include all categories AND reset `reviews_since_last_full = 0`.

If recalibration is active:
- Override auto-approve for the scoped categories (include them even if confidence is high)
- If this is the user's first recalibration (`onboarding_flags.first_recalibration_explained == false`):
  - Explain: "This review is checking all categories because [trigger]. This happens periodically to verify the system's accuracy."
  - Set `first_recalibration_explained = true`
- After the review, if interval trigger fired, reset `reviews_since_last_full = 0`

## Step 4: Select Checklist Sections

For each applicable checklist file (identified in Step 2):
1. Read the checklist file from `.claude/skills/review/checklists/`
2. Parse sections by splitting on `## [tag]` headings
3. For each section, extract the `[tag]` from the heading
4. Build the category key: `{tag}:{checklist-name}` (e.g., `security:typescript-react`)
5. Look up this category in confidence.json:
   - If `auto_approve == true` AND NOT in `--full` mode: **skip this section**
   - Otherwise: **include this section**
6. Collect all included sections into a single text block

Also always include all sections from `_base.md` that apply (apply the same confidence filtering).

If `--full` mode: include ALL sections regardless of confidence (skip the filtering).

Log which sections were auto-approved (skipped) — you'll report these to the user later.

**Onboarding: first auto-approve.** If any sections were skipped AND `onboarding_flags.first_auto_approve_explained == false`:
- Add: "Some categories were skipped because the system has learned they're reliable. Run `/review --calibrate` to see details, or `/review --full` to check everything."
- Set `first_auto_approve_explained = true`

**All-auto-approved short circuit:** If ALL applicable checklist sections are auto-approved (no sections remain after filtering) and NOT in `--full` mode, skip the reviewer subagent entirely. Report to the user: "All categories auto-approved. No semantic review needed. Run `/review --full` to force a complete review." Increment `config.reviews_since_last_full` so recalibration still triggers eventually. Do not dispatch the reviewer with an empty checklist.

## Step 5: Mechanical Pre-flight

Run compile/syntax checks on the changed files:

- **TypeScript files changed:** Run `npx tsc --noEmit` in the nearest directory with a `tsconfig.json`
- **Java files changed:** Run `mvn compile -q` in the nearest directory with a `pom.xml`
- **Lua files changed:** Run `luac -p <file>` for each changed `.lua` file
- **Python files changed:** Run `python -m py_compile <file>` for each changed `.py` file

If any pre-flight check fails, report the errors and stop:
```
Pre-flight failed: [language] compilation errors

[error output]

Fix these first, then run /review again.
The semantic review won't run on code that doesn't compile.
```

If no pre-flight tools are available (e.g., `luac` not installed), skip that check and note it.

## Step 5b: Token Budget Check

Estimate the total token cost for this review:
- Static prompt (reviewer): ~1,100 tokens
- Static prompt (verifier): ~800 tokens
- Diff content: estimate `character_count / 4` tokens
- Checklist sections: estimate `character_count / 4` tokens
- Learned rules: estimate `character_count / 4` tokens
- **Total estimated = reviewer_prompt + verifier_prompt** (both agents run)

**Check enforcement mode** from `token_ceiling.enforcement`:

### Track Mode
Log the estimate. If estimate exceeds any ceiling, warn:
```
⚠ This review (~[est] tokens) exceeds your [period] ceiling ([ceiling]).
Tracking only — proceeding with review.
```
If 80% or 100% of any ceiling is reached, surface the optimization review (see Optimization Review below) after the review completes. Proceed with review.

### Hard Mode

Check if `session_state.emergency == true` → skip enforcement, proceed.

Check if `session_state.auto_degrade` is active and not expired:
- If active and not expired: apply the degradation (filter checklists to the specified priority level only). Note in output: "Auto-degraded to [level] until [until]." Proceed without prompting.
- If active but expired (period has reset): clear `auto_degrade`, proceed normally.

If estimate exceeds `per_review` ceiling OR would push any period total over its ceiling:

1. Calculate which ceiling(s) would be breached
2. Check exception budget for each breached period:
   - Read `exception_policy.current_period` for daily/weekly/monthly
   - Check if each period has reset using **fixed calendar windows (midnight UTC)**:
     - **Daily:** if `current_period.daily.date != today (UTC)`: reset `exceptions = 0`, update `date`
     - **Weekly:** if `current_period.weekly.date_start` is before this Monday (UTC): reset `exceptions = 0`, update `date_start` to this Monday
     - **Monthly:** if `current_period.monthly.date_start` is before the 1st of this month (UTC): reset `exceptions = 0`, update `date_start` to the 1st
   - After resetting stale periods, check remaining exceptions
   - Exceptions are **nested**: each exception counts against daily, weekly, AND monthly
3. **Onboarding: first ceiling hit.** If `onboarding_flags.first_ceiling_hit_explained == false`:
   - Add: "The review system has a token budget to control costs. The ceiling limits how many tokens each review uses. Adjust with `/review --set-ceiling` or check spend with `/review --budget`."
   - Set `first_ceiling_hit_explained = true`

4. Present options:

**With exceptions remaining:**
```
⛔ Review blocked — would exceed [period] ceiling.

  [period] budget:   [ceiling]
  Spent this [period]: [spent]
  This review est:    [estimate] (would total [total])
  
  Options:
  1. Critical-only sweep (~[est] tokens — fits within ceiling)
  2. Priority review: critical + important (~[est] tokens)
  3. Mechanical pre-flight only (0 tokens)
  4. Authorize exception ([remaining] of [max] [period] exceptions remaining)
     Requires: reason for exception
  5. Raise ceiling: /review --set-ceiling [period]=[suggested]
```

**With exceptions exhausted:**
```
⛔ Review blocked — would exceed [period] ceiling.
⛔ No exceptions remaining ([used]/[max] used this [period]).

  Options:
  1. Critical-only sweep (~[est] tokens)
  2. Priority review: critical + important (~[est] tokens)
  3. Mechanical pre-flight only (0 tokens)
  4. Auto-degrade for remainder of [period] (no prompts until [reset date])
  5. Raise ceiling: /review --set-ceiling [period]=[suggested]
```

When user authorizes an exception:
- Prompt for reason
- Increment `current_period` exception counts for ALL enclosing periods (nested)
- Log to `escape_hatch_log`: `{ "type": "ceiling_exception", "period": "[period]", "reason": "...", "estimate": N, "date": "..." }`
- Check if `optimization_review_trigger` is reached → if so, surface optimization review after the review completes

When user chooses auto-degrade:
- Set `session_state.auto_degrade = { "level": "critical-only", "until": "[period reset date]", "reason": "[period] exceptions exhausted" }`
- Confirm: "Auto-degraded to [level] until [reset date]."

### Soft Mode

Same as Hard Mode, but replace exception option (4) with:
```
  4. Override this once (unlimited, logged)
```
Overrides don't count against exception budget. Every 3rd override triggers optimization review.

### --full ceiling interaction

If `--full` was requested and estimate exceeds ceiling:
- Count as implicit exception (logged as `"type": "full-override"`)
- If exception budget allows: proceed without prompting
- If exception budget exhausted: present warning:
```
--full requires a ceiling exception but exceptions are exhausted.
Options:
  1. Proceed anyway (forced exception, logged as "full-override")
  2. Run standard filtered review instead
  3. Raise ceiling
```
`--full` always has an escape path. The forced exception counts toward optimization review trigger.

### Optimization Review

Triggered after `optimization_review_trigger` exceptions in any period (or every 3rd soft-mode override, or at 80%/100% ceiling in track mode).

Read the last 10 entries from `escape_hatch_log` where `type` is `ceiling_exception` or `full-override`. Display:
```
📋 Optimization Review — [N] ceiling exceptions this [period]

Exception log:
  [date]: "[reason]"    +[overage] over [period]
  ...

Analysis:
  [identify patterns — which review types cause overages]

Recommendations:
  1. [specific suggestion based on pattern]
  2. [alternative approach]
  3. No change — current exceptions are acceptable

Choose [1-N]:
```

### Mid-Review Controls

After the reviewer subagent returns (Step 7):
1. **Timeout:** If the reviewer takes longer than 120 seconds, stop and report:
```
The reviewer took too long (>120s). This usually means the diff is very large.

Try:
  /review --staged          (review less code at once)
  /review --branch          (let the system chunk it into batches)
  /review --set-ceiling per_review=20000  (if budget allows more)
```

2. **Finding cap:** After parsing the reviewer's JSON, if `findings.length > 25`:
- Truncate to top 25 by severity (all Critical, then Important, then Minor)
- Report: "⚠ Review capped at 25 findings ([total] total). [omitted] Minor findings omitted."

---

## Step 6: Assemble Reviewer Prompt

Read the reviewer agent template from `.claude/skills/review/reviewer-agent.md`.

Replace the placeholders:
- `{CHANGE_CONTEXT}` — the Change Context summary built in Step 2 (files, intent, trust boundaries, risk profile). This gives the reviewer a mental model BEFORE it reads the diff.
- `{DIFF}` — the git diff output (only for reviewable files, with lock files and assets stripped)
- `{CHECKLIST_SECTIONS}` — the collected checklist sections from Step 4
- `{LEARNED_RULES}` — the applicable learned rules from Step 3, formatted as:
  ```
  Rule #N: "human's explanation"
  Applies to: glob/pattern/**
  Category: tag:checklist
  ```
  If no learned rules apply, replace with: "No learned rules apply to the changed files."

## Step 7: Dispatch Reviewer Subagent

Launch an isolated reviewer subagent using the Agent tool:
- Pass the assembled prompt as the agent's task
- The agent must NOT have access to this conversation's context
- Wait for the agent to return its JSON response

Parse the JSON response. If parsing fails (the agent returned prose instead of JSON), ask the agent to retry with JSON-only output.

## Step 7b: Dispatch Verifier Agent (Adversarial Verification)

After the reviewer returns findings, dispatch the verifier — a second isolated agent with an adversarial bias. The verifier assumes every finding is wrong until independently proven.

**Always runs.** The verifier is not optional. Every finding must survive adversarial scrutiny before the human sees it.

1. Read the verifier template from `.claude/skills/review/verifier-agent.md`
2. Replace placeholders:
   - `{CHANGE_CONTEXT}` — same Change Context from Step 2
   - `{DIFF}` — same diff from Step 1
   - `{REVIEWER_FINDINGS}` — the full JSON output from the reviewer (Step 7)
3. Dispatch as an isolated subagent (no access to reviewer's context or this conversation)
4. Parse the verifier's JSON response

**Process the verifier's output:**

For each verified finding:
- **Confirmed:** Keep the finding, add verification note with evidence
- **Challenged:** Keep the finding but flag as challenged with the verifier's counter-evidence. The human will decide.
- **Unsubstantiated:** Keep the finding but flag as unverified. The human will decide.
- **Upgraded:** Update the finding's severity with the verifier's evidence
- **Dismissed:** Remove the finding from what the human sees. Log it in history as dismissed-by-verifier.

For new findings from the verifier: Add them to the findings list with `source: "verifier"`.

For fix test challenges: Store for use in Step 9b (Fix Pipeline) — challenges must be addressed before fix tests are considered passing.

**Update the verdict** if the verifier changed findings:
- Recalculate based on the verified finding set (not the original)
- If all Criticals were dismissed, verdict may change from `fail` to `pass_with_fixes`

## Step 8: Present Findings

Present the VERIFIED findings to the user. Only show findings that survived the verifier (Step 7b). Dismissed findings are excluded.

**If this is the user's first review** (check `onboarding_flags.first_finding_explained` in confidence.json):
- Add a brief explanation of severity levels, verification status, and how to respond
- Set `first_finding_explained: true` in confidence.json

**Format findings as:**

```
## Review Results — [verdict] (verified by adversarial agent)

[verdict_reasoning]

Verification summary: [N] confirmed, [N] challenged, [N] unsubstantiated, [N] dismissed, [N] new from verifier

### Critical
[numbered findings with file:line, title, explanation, suggestion]
Each finding includes verification status:
  [CONFIRMED ✓ high confidence] — verifier independently traced and confirmed
  [CHALLENGED ⚠ medium confidence] — verifier found counter-evidence (details shown)
  [UNVERIFIED ?] — verifier could not confirm or deny (needs human judgment)
  [UPGRADED ↑] — verifier found higher severity than reviewer claimed
  [NEW — from verifier] — verifier found this, reviewer missed it

### Important  
[numbered findings with verification status]

### Minor
[numbered findings with verification status]

### Dismissed by Verifier (not shown to human unless requested)
[count] findings dismissed — run /review --show-dismissed to see them

### Auto-Approved (skipped)
[list of categories that were skipped due to high confidence, with confidence %]
```

If no findings survive verification: "Clean review — no issues found (reviewer raised [N] findings, all dismissed by verifier). Verdict: pass"

**After findings, prompt for feedback:**
```
For each finding, respond:
  [a]pprove    — correct finding, I'll fix it
  [r]eject     — false positive, not an issue
  [r] "reason" — false positive, here's why (I'll learn from this)
  [s]kip       — don't count this one
  [?]          — explain more about this finding

Example: a 1,2  r 3 "vendor SDK requires this"  s 4
```

## Step 9: Process Feedback

When the user responds with feedback:

For each finding:

**If approved:**
1. Look up the category key (from the finding's `category` field)
2. In confidence.json, find or create the category entry
3. Increment `reviews` by 1, increment `accurate` by 1
4. Update `streak.accurate += 1`, set `streak.inaccurate = 0`
5. Recalculate `confidence = accurate / reviews`
6. If `confidence >= (threshold + 0.02)` AND `reviews >= min_reviews_before_auto`: set `auto_approve = true`
7. Set `last_reviewed` to today's date

**If rejected:**
1. Same category lookup
2. Increment `reviews` by 1 (do NOT increment `accurate`)
3. Set `streak.accurate = 0`, increment `streak.inaccurate += 1`
4. Recalculate `confidence = accurate / reviews`
5. If `confidence < (threshold - 0.02)`: set `auto_approve = false`
6. Set `last_reviewed` to today's date, set `last_human_override` to today's date

**If rejected with reason:**
1. Same as rejected above, PLUS:
2. Ask the user to classify their reasoning:
   - **"Context-specific"** — "This pattern is safe HERE because [specific reason about this code's context]." Creates a path-scoped rule.
   - **"Project convention"** — "We always/never do X in this project because [architectural reason]." Creates a broader rule that may apply project-wide.
   - **"False premise"** — "The reviewer misunderstood the code — it's not actually doing what the finding says." This is a calibration signal: the reviewer needs better context, not a rule suppression. Log it as a calibration data point.
   
   If the user doesn't want to classify, default to "context-specific."
3. Generalize the finding's file path to a glob (e.g., `src/api/auth.ts` → `src/api/**`)
4. Present the glob to the user for confirmation: "I'll apply this rule to: `src/api/**`. Adjust? [Enter to accept, or type a different glob]"
5. Create a new learned rule in confidence.json:
   ```json
   {
     "id": "rule_NNN",
     "created": "2026-04-04",
     "category": "the-category-key",
     "human_said": "the user's reason verbatim",
     "reasoning_type": "context-specific|project-convention|false-premise",
     "applies_to": "the confirmed glob",
     "source": "feedback",
     "times_applied": 0,
     "last_applied": null,
     "status": "active"
   }
   ```

**If skipped:** Do nothing for calibration. No changes to confidence.json for this finding.

**If explain (?):** Show more detail about the finding: the checklist item text that triggered it, the reviewer's full explanation, and the relevant code context. Then re-prompt for a/r/s on this finding.

After processing all feedback:
- Update `config.reviews_since_last_full += 1`
- Update `last_updated` to today's date
- Write the updated confidence.json

Print a summary:
```
Updated N findings:
  ✓ X approved (system accuracy reinforced)
  ✗ Y rejected [Z with learned rules created]
  
Current confidence: [average across active categories]%
```

## Step 9a: Write History Log

After processing feedback (or after the reviewer+verifier return findings if no feedback yet), write a review log entry.

Create a file at `.claude/review/history/{date}-{short-hash}.json` where `{date}` is today (YYYY-MM-DD) and `{short-hash}` is the first 7 chars of the HEAD commit SHA. If multiple reviews happen on the same date+commit, append a counter: `-001`, `-002`.

```json
{
  "date": "2026-04-04",
  "commit": "abc1234",
  "mode": "staged|working|commit|branch|pr|full",
  "files_reviewed": ["path/to/file.java"],
  "languages": ["java-spring"],
  "checklist_sections_included": 8,
  "checklist_sections_skipped": 5,
  "findings": {
    "critical": 0,
    "important": 1,
    "minor": 2,
    "total": 3
  },
  "verification": {
    "confirmed": 2,
    "challenged": 1,
    "unsubstantiated": 0,
    "upgraded": 0,
    "dismissed": 0,
    "new_from_verifier": 0
  },
  "verdict": "pass_with_fixes",
  "feedback": {
    "approved": 2,
    "rejected": 1,
    "rejected_with_reason": 0,
    "skipped": 0
  },
  "estimated_tokens": 5200,
  "skipped": false,
  "skip_reason": null
}
```

For `--skip` invocations, write a minimal entry with `"skipped": true`, `"skip_reason": "user's reason"`, `"estimated_tokens": 0`.

**Update spend tracking in confidence.json:**

1. Add the review's `estimated_tokens` to `spend.lifetime_tokens`
2. Get today's date key (YYYY-MM-DD). In `spend.periods`, find or create the entry for today:
   ```json
   "2026-04-04": { "tokens": 0, "reviews": 0 }
   ```
   Increment `tokens` by `estimated_tokens` and `reviews` by 1.
3. Store `last_review_tokens` at the top level of confidence.json for quick access by the budget display.

---

## Step 9b: Fix Pipeline (when user says "fix these" or "fix 1,3,5")

If the user asks to fix findings (instead of or after providing feedback), execute the fix pipeline. This ensures fixes are safe, tested, and reversible.

### F0: Verify Baseline (BEFORE checkpoint)

Before saving any checkpoint, verify the current state is known-good:

1. Run the project's existing test suite:
   - Java: `mvn test -q`
   - TypeScript: `npm test` or `npx vitest run`
   - Python: `pytest`
2. Record the result:
   - **All tests pass:** Proceed to F1. The checkpoint will capture a verified-green state.
   - **Some tests fail:** Warn the user:
     ```
     ⚠ Existing tests are already failing (N failures).
     The checkpoint will save this state — rolling back means 
     returning to code with failing tests.
     
     Proceed anyway? [y/n]
     ```
     If user says no, stop. If yes, proceed but note the pre-existing failures
     so F4 (full suite after fixes) doesn't blame new fixes for old failures.
   - **No test suite found:** Note: "No test suite detected. Checkpoint will be created without baseline verification."

### F1: Create Checkpoint

Now that the baseline is verified, create a restore point:

```bash
git stash push -m "review-fix-checkpoint-$(date +%Y%m%d-%H%M%S)"
```

If the working tree is clean (changes already committed), create a checkpoint branch:
```bash
git checkout -b review-fix-checkpoint-$(date +%Y%m%d-%H%M%S)
git checkout -  # return to original branch
```

Record the checkpoint in confidence.json under a new `active_checkpoint` field:
```json
{
  "active_checkpoint": {
    "type": "stash|branch",
    "ref": "stash@{0} or branch-name",
    "created": "2026-04-04T14:23:00Z",
    "findings_targeted": [1, 3, 5],
    "baseline_test_result": "pass|fail|no-suite",
    "pre_existing_failures": 0
  }
}
```

### F2: Generate Fix Tests

For each finding being fixed, generate a test that:
1. **Reproduces the issue** (should FAIL on current/unfixed code)
2. **Verifies the fix** (should PASS after the fix is applied)

Detect the project's test framework:
- **Java:** JUnit — put tests in `src/test/java/` matching the source package
- **TypeScript:** Jest/Vitest — put tests next to the source file or in `__tests__/`
- **Python:** pytest — put tests in `tests/` or next to the source
- **Lua (FiveM):** No standard framework — generate as markdown verification steps in a comment block

Test naming: `testReviewFix{N}_{category}_{shortDescription}` (Java) or `review-fix-{n}-{category}.test.ts` (TypeScript)

**Run generated tests on CURRENT (unfixed) code.** Vulnerability/bug tests MUST fail (red confirmation). If a "bug" test already passes on the unfixed code, the finding may be a false positive — flag it to the user before proceeding.

### F3: Apply Fixes

For each finding, ordered by severity (Critical → Important → Minor):

1. Apply the code fix
2. Show the diff to the user: `Fix for finding #N: [title]`
3. Run that finding's specific test — verify it now PASSES (green confirmation)
4. If the test still fails: stop, report the failure, offer options:
   - Retry with a different approach
   - Skip this finding
   - Rollback all fixes so far

### F4: Run Full Test Suite

After all fixes are applied:

1. Run the project's existing test suite:
   - Java: `mvn test -q`
   - TypeScript: `npm test` or `npx vitest run`
   - Python: `pytest`
2. Run all generated fix tests together
3. Compare results:
   - If existing tests that PASSED before now FAIL → the fix introduced a regression
   - Report which tests broke and which fix likely caused it
   - Offer: rollback all, rollback specific fix, or accept with known regression

Report:
```
Fix verification:
  Fix tests:     N/N pass ✓
  Existing tests: M/M pass ✓ (no regressions)
  — OR —
  Existing tests: M-1/M pass ✗ (1 regression, likely from fix #3)
```

### F5: Post-Fix Review

Run `/review` automatically on the fixed code (same mode as the original review):

- If new findings appear that weren't in the original review → the fixes introduced new issues
- Report them alongside the fix results
- Offer: fix the new issues too, rollback, or accept with known issues
- If clean: "All fixes verified. No new issues introduced."

### F6: Accept or Rollback

Present a summary:
```
Fix Summary:
  Applied: N fixes (X Critical, Y Important, Z Minor)
  Fix tests: N/N pass
  Existing tests: M/M pass (no regressions)
  Post-fix review: clean (no new issues)

  [accept]  — keep fixes, clear checkpoint, commit fix tests
  [rollback] — restore pre-fix state (fix tests retained for reference)
  [partial]  — keep fixes for #1,3,5 — rollback #2,4
```

- **Accept:** Clear `active_checkpoint` from confidence.json. Stage and commit the fixes + generated tests.
- **Rollback:** `git stash pop` (or delete checkpoint branch). Fix tests are kept but annotated with `// Fix was rolled back — test retained for reference`.
- **Partial:** Selectively revert specific fixes while keeping others. More complex — apply in reverse order.

### /review --undo

If the user runs `/review --undo` at any time:

1. Read `active_checkpoint` from confidence.json
2. If no checkpoint: "No active fix checkpoint to undo."
3. If checkpoint exists:
   - Stash type: `git stash pop`
   - Branch type: `git checkout {branch} -- .` then delete the branch
4. Clear `active_checkpoint`
5. Report: "Rolled back to pre-fix state. Fix tests retained for reference."

## Step 10: Calibration Dashboard (--calibrate)

When invoked with `--calibrate`, read confidence.json and display:

```
Review Calibration Dashboard

Categories (N total, M auto-approved):
  [for each category, sorted by confidence descending:]
  ✅ category-key    XX% (N/M reviews)  auto-approved
  ⚠️  category-key    XX% (N/M reviews)  under threshold
  🆕 category-key    --  (no reviews)    new

Learned Rules (N active, M stale):
  [for each active rule:]
  #N  ✅ "human's explanation"    applied Nx    applies to: glob
  [for each stale rule:]
  #N  ⚠️  "human's explanation"    STALE (reason)

Recalibration: N reviews since last full (triggers at M)

Stale rules requiring cleanup:
  [for each stale rule:]
  #N  ⚠ "[explanation]" — [stale_reason] (stale since [date])
      [prune] [reactivate] [keep stale]

[if approaching max rules:]
⚠ [N]/100 active learned rules. [M] unused (0 applications in 30+ days):
  [list unused rules]
  [prune all unused] [keep]

Token Spend Trends:
  This week:  [total] tokens across [N] reviews (avg [avg]/review)
  Last week:  [total] tokens across [N] reviews
  Trend:      [↑ increasing / ↓ decreasing / → stable]
  Monthly projection: ~[projected] / [ceiling] ([pct]%)

Verifier Stats (last 30 days):
  Findings verified:  [total]
  Confirmed:          [N] ([pct]%)
  Challenged:         [N] ([pct]%) — [correct] correctly, [incorrect] incorrectly
  New findings added:  [N]

Actionable Suggestions:
  [if spend > 80% ceiling:] "Consider raising monthly ceiling or switching to chunked branch reviews."
  [if category close to auto-approve:] "Category [X] at [N]% — [M] more accurate reviews to auto-approve."
  [if stale rules:] "[N] stale rules can be pruned to reduce prompt size."
  [if recal approaching:] "Full recalibration in [N] reviews. Run /review --full to trigger now."
  [if active checkpoint:] "⚠ Unresolved fix checkpoint from [date]. Accept or rollback?"
```

## Step 11: Budget Report (--budget)

When invoked with `--budget`, read confidence.json and calculate:

1. **Today's spend:** Sum tokens from `spend.periods` entries matching today's date (UTC)
2. **This week's spend:** Sum tokens from entries with dates in the current ISO week (Monday-Sunday UTC)
3. **This month's spend:** Sum tokens from entries with dates in the current month (UTC)
4. **Last review:** Read `last_review_tokens`
5. **Projected monthly:** `(this_month_spend / days_elapsed_in_month) * days_in_month`
6. **Exception counts:** Read `token_ceiling.exception_policy.current_period` for each period

Display:

```
Token Budget

  Enforcement: [enforcement mode]
  Per review:  [ceiling] (last review used [last_review_tokens])
  Daily:       [ceiling] (today: [today_spend] / [ceiling] -- [pct]%)
  Weekly:      [ceiling] (this week: [week_spend] / [ceiling] -- [pct]%)
  Monthly:     [ceiling] (this month: [month_spend] / [ceiling] -- [pct]%)
  
  Exceptions today: [used]/[max] | this week: [used]/[max] | this month: [used]/[max]
  Projected monthly at current pace: ~[projected] ([within/over] budget)
  
  [if auto_degrade active: "Auto-degraded to [level] until [date]"]
```

## Step 12: Escape Hatches

### --pause

Set `session_state.paused = true` in confidence.json. Report:
```
Review auto-triggers paused for this session.
On-demand /review still works. Resume with /review --resume.
```
Log to `escape_hatch_log`: `{ "type": "pause", "date": "YYYY-MM-DD", "reason": "user requested" }`

When paused, pre-commit and PR hooks (Plan 3) check `session_state.paused` and skip. On-demand `/review` invocations still work. Every 5th commit while paused, remind: "Review is paused. Resume with /review --resume."

### --resume

Set `session_state.paused = false` in confidence.json. Report:
```
Review auto-triggers resumed.
```

### --emergency

Set `session_state.emergency = true` and `session_state.paused = true` in confidence.json. Report:
```
⚠ Emergency mode: all review hooks, triggers, and ceiling enforcement disabled.
On-demand /review still works but ceiling will not block.
Auto-resets next session.
```
Log to `escape_hatch_log`: `{ "type": "emergency", "date": "YYYY-MM-DD" }`

When `emergency = true`, Step 5 (Token Budget Check) skips ceiling enforcement regardless of mode. Session state should be reset to `false` at the start of each new Claude Code session.

### --reset

Prompt for confirmation:
```
Reset confidence data? This clears all category scores but keeps learned rules and config.
Type "confirm" to proceed:
```

If confirmed:
- Set all category `reviews`, `accurate`, `confidence` to 0, `auto_approve` to false
- Reset `streak` to `{ "accurate": 0, "inaccurate": 0 }`
- Keep `learned_rules`, `token_ceiling`, `config` intact
- Log to `escape_hatch_log`: `{ "type": "reset", "date": "YYYY-MM-DD", "scope": "confidence" }`
- Report: "Confidence data reset. Categories will re-learn from your next reviews."

### --reset --rules

Same as `--reset` PLUS clear the `learned_rules` array entirely.
Log scope: `"confidence+rules"`.
Report: "Confidence data and learned rules reset."

### --reset --all

Prompt for serious confirmation:
```
⚠ This removes the entire review infrastructure:
  - All confidence data
  - All learned rules  
  - All history logs
  - The review skill and checklists

Type "delete review system" to proceed:
```

If confirmed: delete `.claude/skills/review/`, `.claude/review/`, remove review hook entries from `.claude/settings.json`.
Report: "Review system removed. Run /review-setup to reinstall."

### --suppress "category"

Look up the category in confidence.json. Set `suppressed = true`. Report:
```
Category [category] permanently suppressed. 
It will be skipped in all future reviews.
Visible in /review --calibrate. Un-suppress there if needed.
```

### --set-ceiling

Parse the argument as `key=value` (e.g., `per_review=20000`). Validate:
- Key must be one of: `per_review`, `daily`, `weekly`, `monthly`, `enforcement`
- For numeric values: must be positive integer
- Validate ordering using **fixed calendar windows (midnight UTC)**: `per_review <= daily <= weekly <= monthly`
- If a value would violate ordering, prompt: "Invalid: per_review (50000) exceeds daily (30000). Adjust daily as well? [y/n]"
- For `enforcement`: must be `hard`, `soft`, or `track`

Update `token_ceiling` in confidence.json. Report: "Ceiling updated: [key] = [value]"

---

## Help Section

When invoked with `--help`, display:

```
/review — Automated Code Review

Daily use:
  /review                   Review uncommitted changes
  /review --staged          Review only what you're about to commit
  /review --commit abc123   Review a specific commit
  /review --branch          Review full branch before PR
  /review --pr [number]     Review a PR (auto or by number)

Trust management:
  /review --calibrate       See confidence scores and learned rules
  /review --suppress "cat"  Permanently skip a category
  /review --full            Force full review (recheck everything)

Budget:
  /review --budget          Current token spend and ceiling status
  /review --set-ceiling     Adjust token limits

Fixes:
  /review --undo            Rollback most recent fix checkpoint

Escape hatches:
  /review --skip "reason"   Skip this review (logged)
  /review --pause           Pause auto-triggers for this session
  /review --resume          Re-enable auto-triggers
  /review --emergency       Disable everything for this session

Setup & reset:
  /review-setup             Re-run generator (detects new languages)
  /review --reset           Reset confidence data
  /review --reset --rules   Also reset learned rules
  /review --reset --all     Remove entire review infrastructure
```

## Glossary Section

When invoked with `--help --glossary`, display:

```
Glossary:

  Auto-approve   A category the system handles reliably enough to skip human review
  Calibration    The process of the system learning from your feedback
  Category       A type of check (e.g., "security in TypeScript") tracked independently
  Ceiling        A hard limit on how many tokens the review system can spend
  Checklist      The list of things the reviewer checks for in a specific language
  Confidence     How often the system's findings match your judgment (0-100%)
  Exception      A one-time allowance to exceed the token ceiling
  Finding        A specific issue the reviewer identified in your code
  Learned rule   A project-specific pattern the system learned from your feedback
  Pre-flight     Mechanical checks (compile, lint, test) before semantic review
  Recalibration  Periodic full review to verify accuracy hasn't drifted
  Threshold      The confidence level needed for auto-approval (default: 90%)
```
