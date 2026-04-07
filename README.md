# Reviewanator

Automated code review for Claude Code. An isolated reviewer + adversarial verifier, language-specific checklists, confidence calibration that learns from your feedback, and token budget controls.

## What It Does

1. **`/review`** — Reviews your code changes with an isolated subagent that knows nothing about your conversation. A second adversarial verifier independently challenges every finding before you see it.

2. **`/review-setup`** — Scans your project, detects languages/frameworks, interviews you about conventions, and generates tailored review infrastructure.

The system starts cautious and learns over time. Approve accurate findings, reject false positives with a reason, and the system calibrates — eventually auto-approving categories it handles reliably.

## Install

**Step 1:** Register the marketplace (once per machine):

```
/plugin marketplace add flashwing-nwrp/reviewanator
```

**Step 2:** Install the plugin:

```
/plugin install reviewanator@flashwing-nwrp
```

**Step 3:** Bootstrap your project (generates checklists, hooks, and calibration config):

```
/review-setup
```

> `/review-setup` scans your project, detects languages/frameworks, extracts conventions
> from your `CLAUDE.md`, and generates tailored review infrastructure. Re-run with
> `--update` when your project adds new languages or your conventions change.

## Quick Start

```bash
/review                    # Review uncommitted changes
/review --staged           # Review only staged changes
/review --branch           # Review full branch before PR
/review --commit abc123    # Review a specific commit
/review --full             # Force full review (skip calibration)
/review --calibrate        # See what the system has learned
/review --budget           # Check token spend
/review --help             # Full command reference
```

## How It Works

### Two-Agent Pipeline

Every review goes through two isolated agents that never share context:

```
Your code → Reviewer (untrusted) → Verifier (adversarial, mandatory) → You
```

- **Reviewer** reads the diff + language checklists, finds issues. Its output is a hypothesis, not a conclusion.
- **Verifier** assumes every finding is wrong, independently traces the code to confirm or challenge each one. It also independently audits the diff for issues the reviewer missed.
- The verifier **always runs** — even when the reviewer finds nothing, even when all categories are auto-approved. No configuration, confidence score, or budget constraint can bypass it.
- You only see verified findings with evidence

### Confidence Calibration

Each checklist category (e.g., "security in TypeScript") is tracked independently:

- **Approve** a finding → confidence goes up
- **Reject** a finding → confidence goes down
- **Reject with reason** → creates a learned rule the system won't re-flag

When confidence reaches the threshold (~90% accuracy over 15+ reviews), that category is **auto-approved** — the reviewer skips it, saving tokens. The verifier still runs a full independent audit of the diff regardless. Recalibration triggers periodically to verify accuracy hasn't drifted.

### Language Checklists

Thinking-oriented checklists — "Consider whether..." not "No X without Y":

| Checklist | Sections |
|-----------|----------|
| `_base.md` | Secrets, dependencies, migration, breaking changes, testing, error handling, cleanup |
| `typescript-react.md` | XSS/injection, React effects, async errors, state, types, performance, naming |
| `java-spring.md` | Injection/auth, transactions, exceptions, Spring deps, integration testing, Optionals |
| `lua-fivem.md` | Client/server boundary, thread safety, net events, database, FLRP patterns, tick optimization |
| `python-fastapi.md` | Injection/input, async correctness, exceptions, Pydantic types, testing, dependencies |

### Pattern Hooks

Zero-token grep-based hooks that run on every file edit (PostToolUse). Catch common anti-patterns instantly — no AI needed:

- **Java:** SQL concatenation, System.out, printStackTrace, raw Thread, @SuppressWarnings
- **TypeScript:** eval, dangerouslySetInnerHTML, innerHTML, `: any`, @ts-ignore, console.log
- **Lua:** client-side `source`, while-true without Wait, RegisterCommand without ACE, broadcast events
- **Python:** eval/exec, subprocess shell=True, pickle, os.system, assert for validation

### Git Workflow Hooks

- **Pre-commit nudge/gate** — reminds (or blocks) if you haven't run `/review` today
- **PR nudge/gate** — reminds (or blocks) if no branch review before `gh pr create`
- Mode configurable: `nudge` (warn), `gate` (block), `off`

### Token Budget

Hard/soft/track enforcement with per-review, daily, weekly, monthly ceilings. Exception budgets, auto-degrade mode, and optimization reviews when you hit limits repeatedly.

### Convention Pipeline

`/review-setup` parses your `CLAUDE.md` for project conventions and converts them into checklist items in `_custom.md`. The reviewer enforces your conventions alongside the standard checklists.

## What `/review-setup` Generates

| File | Purpose |
|------|---------|
| `.claude/skills/review/checklists/_custom.md` | Project conventions from CLAUDE.md |
| `.claude/hooks/review-patterns/patterns-*.sh` | Per-edit grep hooks for detected languages |
| `.claude/hooks/review-precommit.sh` | Pre-commit nudge/gate |
| `.claude/hooks/review-onpr.sh` | PR nudge/gate |
| `.claude/review/confidence.json` | Calibration state (categories, rules, spend, ceiling) |
| `.claude/review/history/*.json` | Per-review result logs |
| Updates to `.claude/settings.json` | Hook registrations |

Re-run `/review-setup --update` when your project adds new languages or your CLAUDE.md conventions change.

## Fix Pipeline

When the reviewer finds issues, say "fix these" and the system:

1. Creates a git checkpoint (rollback-safe)
2. Generates red/green tests for each finding
3. Applies fixes one at a time, verifying each
4. Runs the full test suite (catches regressions)
5. Runs a post-fix review (catches new issues from fixes)
6. Lets you accept, rollback, or partial-accept

## Escape Hatches

Every enforcement point has a bypass. Bypasses are logged, never silent.

| Situation | Command |
|-----------|---------|
| Skip this review | `/review --skip "reason"` |
| Iterating fast | `/review --pause` / `--resume` |
| Production is down | `/review --emergency` |
| Category always wrong | `/review --suppress "category"` |
| Reset everything | `/review --reset` / `--reset --rules` / `--reset --all` |

## License

MIT
