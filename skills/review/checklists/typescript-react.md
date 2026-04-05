# TypeScript + React

Evaluate in the context of where this code runs (browser, SSR, NUI) and what data it handles. A component rendering static content has different risks than one rendering user-generated content.

## [security] XSS & Injection Prevention
<!-- context_lines: 5 -->
<!-- priority: critical -->
<!-- version: 1 -->

- [ ] For any code that renders HTML from variables: trace the data source. Does it originate from user input, an external API, or a trusted internal source? User-originated HTML rendered without sanitization is Critical. Server-rendered trusted content may be acceptable — but the trust assumption should be explicit.
- [ ] For `href` and `src` attributes built from variables: could an attacker control the value? `javascript:` protocol injection requires the attacker to control the URL string. If the value comes from a controlled enum or server-validated URL, the risk is lower — but document the assumption.
- [ ] For `eval()`, `new Function()`, or `innerHTML`: what is the concrete use case? These are almost never necessary in application code but may be legitimate in tooling, templates, or sandboxed contexts. If it exists, the code should make clear why no safer alternative works.

## [effects] React Effect Cleanup
<!-- context_lines: function -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For each `useEffect`: what side effect does it create? (subscription, timer, event listener, fetch call) Does the cleanup function undo that specific side effect? A missing cleanup causes memory leaks and stale callbacks — but the severity depends on whether the component unmounts frequently (route changes = important) or rarely (root layout = minor).
- [ ] For effects that fetch data: what happens if the component unmounts before the fetch completes? Without an AbortController or mounted-check, the response handler may update state on an unmounted component. This is a React warning today and a crash risk in concurrent mode.
- [ ] For effect dependency arrays: are they complete? A missing dependency causes the effect to use stale values. An unnecessary dependency causes excessive re-runs. Consider which is worse for this specific effect.

## [error-handling] Async Error Boundaries
<!-- context_lines: function -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For each API call or async operation: what does the user see when it fails? Trace the failure path through the component tree. If the answer is "blank screen" or "spinner forever," that needs an error state. If there's already an error boundary above this component, it may be covered.
- [ ] For lazy-loaded routes and components (`React.lazy`, dynamic `import()`): is there an error boundary that catches chunk load failures? A failed chunk load crashes the entire app without a boundary.
- [ ] Consider whether network errors and application errors need different handling. "Server is unreachable" (retry later) is a different user experience than "you don't have permission" (don't retry).

## [state] State Management
<!-- context_lines: function -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For shared state: is it managed through the project's designated pattern (Context, Zustand, Redux), or is data being threaded through many layers of props? Prop drilling through 3+ levels often signals state that should be lifted. But consider: is this state truly shared, or is prop passing actually the simpler solution here?
- [ ] For state updates that depend on the current value: does the update use the functional form (`setState(prev => ...)`)?  With the direct form (`setState(newValue)`), concurrent updates can overwrite each other. This matters most for counters, toggles, and anything updated from multiple sources.
- [ ] Is any state being stored that could be computed from other state? Derived state creates synchronization bugs — when the source changes, the derived value must be updated in the same render or it's stale.

## [types] Type Safety
<!-- context_lines: 5 -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For `any` types: is the loss of type safety intentional and documented, or a shortcut? In third-party library boundaries or dynamic data, `any` may be necessary — but it should be narrowed as quickly as possible. In application logic, `any` masks bugs that TypeScript would otherwise catch.
- [ ] For type assertions (`as Type`): could this mask a runtime error? An assertion tells the compiler "trust me" — if the runtime value doesn't match, the crash happens far from the assertion, making debugging difficult. Prefer type guards (`if ('field' in obj)`) that validate at runtime.
- [ ] For API response types: do they reflect the actual API contract, or are they hand-written guesses? A mismatch between the type and the real response causes bugs that TypeScript can't catch because it trusts the type declaration.

## [performance] Render Performance
<!-- context_lines: function -->
<!-- priority: minor -->
<!-- version: 1 -->

- [ ] Consider whether performance optimization is needed here at all. `React.memo`, `useCallback`, and `useMemo` add complexity. They're valuable for components that re-render frequently with expensive operations — but premature optimization on a component rendered once is just noise.
- [ ] For lists: are `key` props stable and unique? Array indices as keys cause subtle bugs when items are reordered, inserted, or deleted. For static lists that never change, indices are fine.

## [naming] Naming Conventions
<!-- context_lines: 2 -->
<!-- priority: minor -->
<!-- version: 1 -->

- [ ] Do names communicate intent to the next developer? Components in PascalCase, hooks prefixed with `use`, event handlers with `handle`/`on` — these conventions exist so developers can identify what something IS from its name. Flag deviations only when they would genuinely confuse someone reading the code for the first time.
