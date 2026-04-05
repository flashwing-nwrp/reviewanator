---
name: review-setup
description: Bootstrap or update the automated code review system. Scans the project, interviews the developer, generates tailored review infrastructure.
user-invocable: true
---

# /review-setup — Review System Generator

You are the review system generator. Follow these phases in order to bootstrap or update the review infrastructure for this project.

## Step 0: Parse Arguments

| Argument | Mode |
|----------|------|
| (none) | Full setup (detect + interview + generate) |
| `--update` | Update mode (detect new languages, preserve calibration, add missing pieces) |

## Step 1: Detect Existing Infrastructure

Check what review infrastructure already exists:

```
exists_skill = file exists at ".claude/skills/review/SKILL.md"
exists_confidence = file exists at ".claude/review/confidence.json"
exists_custom = file exists at ".claude/skills/review/checklists/_custom.md"
exists_hooks = directory exists at ".claude/hooks/review-patterns/"
```

- If `--update` and NO existing infrastructure: report "No review system found. Running full setup instead." and proceed as full setup.
- If full setup and infrastructure EXISTS: report "Review system already installed. Running in update mode to detect changes. Use `/review --reset --all` first if you want a clean reinstall." and proceed as `--update`.

## Step 2: Automatic Detection (Phase 1)

### 2a: Language Detection

Count files by extension. Use `git ls-files` if in a git repo, otherwise `find`:

```bash
git ls-files 2>/dev/null | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20
```

Map extensions to language-checklist pairs:
| Extension(s) | Language-Checklist | Framework Detection |
|---|---|---|
| `.ts`, `.tsx` | `typescript-react` | React if `.tsx` present |
| `.java` | `java-spring` | Spring if `pom.xml` contains `spring-boot-starter` |
| `.lua` | `lua-fivem` | FiveM if `fxmanifest.lua` exists anywhere |
| `.py` | `python-fastapi` | FastAPI/Django/Flask from `requirements.txt`/`pyproject.toml` |
| `.go` | `go` (no checklist yet) | Framework from `go.mod` |
| `.rs` | `rust` (no checklist yet) | — |
| `.cs` | `csharp-dotnet` (no checklist yet) | — |

### 2b: Framework Detection

Check dependency manifests for framework details:
- `package.json` → React, Vue, Angular, Express, Next.js, Vite
- `pom.xml` / `build.gradle` → Spring Boot, Quarkus
- `requirements.txt` / `pyproject.toml` → FastAPI, Django, Flask
- `go.mod` → Gin, Echo, Fiber
- `fxmanifest.lua` → FiveM resource (check for `ox_lib`, `qbx_core`)

### 2c: Existing Tooling Detection

Check for tools already handling certain checks (so we don't duplicate):
- `.eslintrc*` / `eslint.config.*` → ESLint (note: reduce style checks)
- `.prettierrc*` → Formatting handled (skip formatting checks)
- `tsconfig.json` → TypeScript config exists
- `.stylua.toml` → Lua formatting handled
- `checkstyle.xml` → Java style handled
- `.github/workflows/` → CI exists (note what it checks)
- `.claude/hooks/` → Existing Claude Code hooks (augment, don't duplicate)

### 2d: Convention Detection (CLAUDE.md-aware)

Look for `CLAUDE.md` in the project root and `.claude/docs/` directory. If found:

1. Read the file(s)
2. Extract explicit conventions using these patterns:
   - "use X for Y" → convention about preferred approach
   - "never do Z" / "do NOT Z" → convention about forbidden pattern
   - "all X must Y" → convention about mandatory behavior
   - "prefer X over Y" → convention about preference
   - Bullet points under headings like "Conventions", "Standards", "Rules", "Development", "Style"
   - Code patterns labeled as "correct" or "wrong" or "right way" or "wrong way"
3. For each convention extracted, draft a checklist item in the thinking prompt format:
   - "Consider whether [convention is followed]"
   - Tag as `[convention]` with `priority: important`
4. Group related conventions under descriptive section headings

If no CLAUDE.md exists, note this for the interview phase — you'll ask additional convention questions.

### 2e: Build Project Profile

Assemble a summary:
```
Project Profile:
  Languages:    [list with file counts, e.g., "Java (247 files), TypeScript (38 files)"]
  Frameworks:   [detected frameworks, e.g., "Spring Boot 3.5.8"]
  Tooling:      [what's already checking things, e.g., "Maven, ESLint"]
  CLAUDE.md:    [found / not found] ([N conventions extracted] if found)
  Review infra: [what's already installed from Plans 1-2]
```

## Step 3: Gap Interview (Phase 2)

Present the project profile, then ask ONLY about what couldn't be inferred. Use AskUserQuestion for each question. Every question has a recommended default — if the user just presses Enter, use the default.

**Always show the detection summary first:**
```
I've scanned your project and found:

  Languages:  [list]
  Frameworks: [list]
  Tooling:    [list]
  Conventions: [N from CLAUDE.md / "no CLAUDE.md found"]

Here's what I'll set up based on this detection...
```

**Ask these questions (accept defaults where offered):**

**Q1: Review pain points**
"What issues do your reviewers catch most often?"
- Options: security, error handling, test gaps, performance, naming, architecture, other
- Default: (skip — the checklists cover common issues)

**Q2: Project-specific patterns**
"Any conventions not captured in your docs that the review system should know about?"
- Free-text, optional
- Default: (skip — use what was detected)
- If no CLAUDE.md was found: ask 2-3 more convention-oriented questions instead

**Q3: Review mode**
"How do you want to interact with review findings?"
- `session` — findings appear in conversation (default)
- `pr` — findings posted as PR review comments
- `both` — session for on-demand, PR for auto-triggered

**Q4: Starting trust level**
"How cautious should the system start?"
- `paranoid` (0.99) — almost never auto-approves
- `balanced` (0.90) — auto-approves after ~15 accurate reviews per category (default)
- `relaxed` (0.80) — auto-approves faster, more tolerant

**Q5: Hook behavior**
"Should git commit/PR hooks nudge (warn) or gate (block)?"
- `nudge` — remind but allow (default)
- `gate` — block until `/review` is run
- `off` — no git hooks

**Q6: Token ceiling**
"Token budget for the review system?"
- Present current defaults: 15k/review, 75k/day, 300k/week, 1M/month
- Default: keep defaults

## Step 4: Generate Infrastructure (Phase 3)

Based on detection + interview answers, generate the following. Skip files that already exist unless in `--update` mode.

### 4a: Core Review Skill (SKILL.md + agents)

If `.claude/skills/review/SKILL.md` does NOT exist:
- The core skill, reviewer-agent.md, and verifier-agent.md need to be generated. This is a large generation — use the spec at `docs/superpowers/specs/2026-04-04-automated-code-review-design.md` as the source of truth for the content.
- If the spec file doesn't exist, inform the user: "The review system spec is not available. Run Plans 1-2 first, or provide the spec file."

If it already exists: skip — the core skill is managed separately.

### 4b: Checklists

For each detected language that has a checklist template:

**Available templates** (these should exist in `.claude/skills/review/checklists/`):
- `_base.md` — universal checks (always present)
- `typescript-react.md`
- `java-spring.md`
- `lua-fivem.md`
- `python-fastapi.md`

**If checklist exists:** skip (don't overwrite)
**If checklist doesn't exist but template language was detected:** Generate it. All sections get `<!-- version: 1 -->`.
**If language detected but no template available:** Note it: "Detected [lang] but no checklist template available. You can create `.claude/skills/review/checklists/[lang].md` following the section format."

### 4c: _custom.md (Project Conventions)

If `_custom.md` does NOT exist:
- Generate from conventions detected in Step 2d + pain points/patterns from Step 3
- Each convention becomes a checklist item: `- [ ] Consider whether [convention is followed]`
- Group related items under `## [convention] Section Title` headings
- All sections get `<!-- version: 1 -->`, `<!-- priority: important -->`, `<!-- context_lines: 5 -->`

If `_custom.md` EXISTS and `--update`:
- Compare current CLAUDE.md conventions against existing _custom.md items
- Present NEW conventions found: "Found N new conventions not in your current checklist:"
- Ask: "Add these? [y/n/pick]"
- Don't touch existing items

### 4d: Pattern Hooks

For each detected language, create the pattern hook script in `.claude/hooks/review-patterns/`:

| Language | Hook Script |
|---|---|
| TypeScript | `patterns-typescript.sh` |
| Java | `patterns-java.sh` |
| Lua | `patterns-lua.sh` |
| Python | `patterns-python.sh` |

**If hook already exists:** skip (don't overwrite user customizations)
**If hook doesn't exist:** generate it with language-appropriate grep patterns

Hook template format — each hook must:
1. Parse input JSON: `f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null) || exit 0`
2. Check file extension and skip test files
3. Grep for high-signal anti-patterns (security, debug leftovers, common mistakes)
4. Output warnings via `hookSpecificOutput.additionalContext` (never block)

### 4e: Git Workflow Hooks

Generate `.claude/hooks/review-precommit.sh` and `.claude/hooks/review-onpr.sh` using the mode from Q5:
- `nudge` → hooks output `additionalContext` (warn, don't block)
- `gate` → hooks output `permissionDecision: deny` (block until review)
- `off` → don't generate these hooks

**If hooks already exist:** skip

### 4f: confidence.json

If NO confidence.json exists:
- Create with full schema (version 2)
- Set `config.threshold` from Q4 answer
- Set `review_hooks.precommit_mode` and `review_hooks.pr_mode` from Q5 answer
- Set `token_ceiling` from Q6 answer (or defaults)
- All categories empty — they populate dynamically during reviews
- Set `setup_metadata` with detection results

If confidence.json EXISTS:
- Update `setup_metadata` with current detection results
- Update `review_hooks` if the user changed their Q5 answer
- Update `token_ceiling` if the user changed their Q6 answer
- Preserve ALL calibration data (categories, learned_rules, spend, history)

### 4g: settings.json

Read `.claude/settings.json` (or create if missing). Register hooks:

**PostToolUse Write|Edit:** Add pattern hook entries for each detected language's hook script.

**PreToolUse Bash:** Add `review-precommit.sh` and `review-onpr.sh` entries.

**Merging rules:**
- If settings.json doesn't exist: create it with review hooks only
- If settings.json exists: READ the existing content, APPEND review hooks to existing arrays
- NEVER replace existing hooks — augment only
- Before adding, check if the hook command already exists to avoid duplicates

## Step 5: Post-Setup Report

After generation, print a summary and quick-start guide:

```
Review system ready! Here's what was created:

  Files:
    [list each file created/modified with one-line purpose]

  Languages covered: [list]
  Convention items:  [N from CLAUDE.md, M from interview]
  Hook mode:         [nudge/gate/off]
  Trust level:       [threshold value and label]

Quick start:

  /review              Review your current changes (most common)
  /review --branch     Review everything before creating a PR
  /review --calibrate  See what the system has learned
  /review --budget     Check your token spend
  /review --help       Full command reference

The system starts cautious and learns over time. Every finding
it shows you trains it — approve accurate findings, reject false
positives, and add a reason when something is project-specific.

First review will check everything. As you provide feedback,
categories the system handles well will be auto-approved.
```

## --update Mode Specifics

When invoked with `--update`, the detection phase runs identically but generation differs:

1. **New languages:** Compare detected languages against `setup_metadata.detected_languages`
   - Generate missing checklists (new sections start at `<!-- version: 1 -->`)
   - Generate missing pattern hooks
   - New categories start at confidence 0.0 — they must earn calibration independently
   - Report: "New language detected: [lang]. Checklist and hooks generated."

2. **Removed languages:** Languages in `setup_metadata` but no files found
   - Flag but DON'T delete: "[lang] no longer detected. Checklist and hooks retained. Remove manually if no longer needed."

3. **Convention changes:** Re-parse CLAUDE.md
   - If new conventions found not in _custom.md: present them, ask whether to add
   - Don't touch existing _custom.md items

4. **Existing checklists:** Don't modify version numbers — version bumps are manual to avoid losing calibration data unintentionally

5. **Update setup_metadata** with current detection results

6. **Report what changed** vs. what stayed the same
