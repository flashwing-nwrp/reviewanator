# Universal Checks

These checks apply to all languages. Each item is a thinking prompt — evaluate in the context of what the code does and where it runs, not as a mechanical pattern match.

## [secrets] Secret Exposure
<!-- context_lines: 0 -->
<!-- priority: critical -->
<!-- version: 1 -->

- [ ] Identify any string literals that look like credentials (API keys, tokens, passwords, connection strings, private keys). For each: is this a real secret, a placeholder/example value, or a test fixture? Real secrets in committed code are Critical — they cannot be rotated after push without assuming compromise.
- [ ] Check whether new config files (.env, credentials.json, *.pem) are being tracked. If so: intentional (template with placeholders) or accidental?
- [ ] For any secret reference: trace where the value comes from at runtime. Environment variable? Vault? Config file outside the repo? If the sourcing isn't obvious from the code, flag it — the next developer shouldn't have to guess.

## [dependencies] Dependency Changes
<!-- context_lines: 5 -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For each new dependency: does an existing dependency already cover this functionality? Unnecessary dependencies increase attack surface and bundle size. Consider whether the functionality is simple enough to implement without a dependency.
- [ ] Are dependency versions pinned? Floating ranges (^, ~, >=) can silently introduce breaking changes or vulnerabilities on the next install. Consider the project's risk tolerance.
- [ ] For new or upgraded dependencies: are there known CVEs for this version? What does the dependency do with the data it receives — does it make network calls, access the filesystem, execute code?
- [ ] Are dev dependencies separated from production? A test framework in the production bundle is waste; a production library in devDependencies causes runtime failures.

## [migration] Schema & Data Migration
<!-- context_lines: file -->
<!-- priority: critical -->
<!-- version: 1 -->

- [ ] If the diff changes data structures (database schema, API contracts, config formats): is there a migration path for existing data? What happens to rows/records that were created under the old schema?
- [ ] For destructive changes (dropping columns, renaming tables): is the old data preserved or migrated? Can the change be rolled back if deployment fails partway through?
- [ ] For new required (non-nullable) columns: what value do existing rows get? A missing default causes the migration to fail on tables with existing data.
- [ ] For index changes on large tables: will the index build lock the table during deployment? Consider the table size and whether the migration needs to run during a maintenance window.

## [breaking-changes] API & Interface Contract
<!-- context_lines: function -->
<!-- priority: critical -->
<!-- version: 1 -->

- [ ] If public function signatures, API endpoints, export shapes, or config formats changed: who are the consumers? Will they break? Is there a versioning or deprecation strategy?
- [ ] If something was removed (endpoint, export, function): are there consumers still using it? A deprecation period, compatibility shim, or migration guide prevents surprise breakage.
- [ ] For response shape changes: are they purely additive (new fields) or do they modify/remove existing fields? Additive changes are generally safe; removals break consumers that depend on the old shape.

## [testing] Test Coverage
<!-- context_lines: 0 -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For new branching logic (if/else, switch, try/catch, conditional returns): are the branches tested? Focus on branches where the wrong path has consequences — a UI label change needs less test coverage than a payment calculation.
- [ ] Consider the edge cases for this specific code: What happens with null/undefined inputs? Empty collections? Boundary values? The highest-value tests are the ones that catch bugs real usage will trigger.
- [ ] Do the tests verify behavior ("rejects expired tokens") or implementation ("calls validateToken with the right args")? Implementation-coupled tests break on refactors and provide false confidence.
- [ ] Are there any tests that pass regardless of what the implementation does? (e.g., asserting against the input instead of the output, or always-true conditions)

## [error-handling] Error Handling
<!-- context_lines: function -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For each external call (network, database, filesystem, third-party API): what happens when it fails? Trace the failure path — does the error propagate meaningfully, get silently swallowed, or crash the process? The right answer depends on context: a background sync can retry silently; a user-facing request must respond with an error.
- [ ] Are errors informative enough to diagnose without exposing internals? "Failed to load user profile" is actionable for the user; a raw stack trace or SQL error is a security risk.
- [ ] For async operations: is there a .catch() or try/catch on every await? An unhandled rejection can crash a Node process or leave a Lua thread dead.
- [ ] Does resource cleanup (connections, file handles, locks) happen in all code paths, including the error path? If cleanup only happens in the happy path, failures cause resource leaks.

## [cleanup] Code Hygiene
<!-- context_lines: 2 -->
<!-- priority: minor -->
<!-- version: 1 -->

- [ ] Are there debug artifacts (console.log, print, debugger statements) in code that will run in production? In test code or development tooling, these are fine. In production paths, they're noise at best and information leaks at worst.
- [ ] Is there commented-out code? If it was removed intentionally, delete it — git history preserves it. If it's temporarily disabled, a comment explaining why and when to re-enable is more useful than dead code.
- [ ] Are there new TODO/FIXME/HACK comments? These are fine if they reference a tracking issue. Without a reference, they become permanent tech debt that nobody owns.
