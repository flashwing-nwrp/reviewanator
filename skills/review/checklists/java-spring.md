# Java + Spring Boot

Evaluate in the context of the application layer (controller, service, repository) and whether the code handles external input.

## [security] Injection & Auth
<!-- context_lines: 10 -->
<!-- priority: critical -->
<!-- version: 1 -->

- [ ] For any database query: trace the data from source to query. Is user input flowing into a SQL string through concatenation or string formatting? Parameterized queries (`?` binds, JPA named params) prevent injection. The severity depends on whether the input is user-controlled and whether the endpoint is authenticated.
- [ ] For any process execution (`Runtime.exec`, `ProcessBuilder`): what constructs the command string? If any part comes from user input, command injection is possible. Consider whether the operation could use a library instead of shelling out.
- [ ] For REST endpoints: is authentication enforced? An unauthenticated endpoint is intentional (`@PermitAll`) or a security hole. Check whether authorization is also verified — authentication proves identity, authorization proves permission. URL-pattern-based security is fragile; prefer method-level annotations.
- [ ] For CORS configuration: is the allowed origin list explicit, or is it `*`? In production, `@CrossOrigin("*")` allows any website to make authenticated requests on behalf of the user.

## [transactions] Transaction Boundaries
<!-- context_lines: function -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For `@Transactional` methods: what operations are inside the transaction boundary? If the method calls an external service (HTTP, message queue), a network timeout holds the DB transaction open — under load this exhausts the connection pool. External calls should happen outside the transaction.
- [ ] For read-only operations: `@Transactional(readOnly = true)` isn't just annotation hygiene — it enables Hibernate flush-mode optimization and can route to read replicas. Consider whether the operation modifies data.
- [ ] For methods with multiple writes: if the method fails partway through, does the transaction boundary ensure atomicity? Or could partial writes persist because the boundary is in the wrong place?

## [error-handling] Exception Strategy
<!-- context_lines: function -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For catch blocks: what is being caught and what happens to the exception? A bare `catch(Exception e)` that logs and continues may swallow a critical error. Consider whether the caught exception is recoverable in this context.
- [ ] For error responses returned to clients: do they expose internal details? Stack traces, SQL errors, internal file paths, and class names are useful for attackers and confusing for users. Error responses should be informative without being revealing.
- [ ] For resources (streams, connections, locks): are they closed in all code paths? `try-with-resources` handles this automatically — if the code uses manual close(), verify the finally block covers the error path.

## [dependencies] Spring-Specific Dependencies
<!-- context_lines: 5 -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For new or changed dependencies: are versions managed by the Spring Boot BOM, or overridden individually? Individual overrides can create version conflicts that manifest as obscure runtime errors. If an override is necessary, document why.
- [ ] For beans with complex dependency graphs: are there circular references? Spring can resolve some via proxies, but they create initialization-order bugs. If a circular dependency is unavoidable, `@Lazy` on one side breaks the cycle — but document the reason so the next developer doesn't "fix" it.

## [testing] Integration Testing
<!-- context_lines: function -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For repository/service tests: do they hit a real database (H2, testcontainers) or mock the repository interface? Mocked repository tests pass when the query is wrong — they only verify the Java code, not the SQL. The tradeoff is speed vs. coverage; for complex queries, a real database is worth the cost.
- [ ] For tests involving external services: are they mocked at the HTTP layer (WireMock) or at the Java interface? Interface mocks hide HTTP-level issues (serialization, headers, status codes). HTTP mocks are heavier but catch real integration problems.
- [ ] For async operations in tests: are they verified with explicit assertions and timeouts, or with `Thread.sleep()`? Sleep-based tests are flaky (too short = intermittent failure, too long = slow suite).

## [optionals] Optional Handling
<!-- context_lines: 5 -->
<!-- priority: minor -->
<!-- version: 1 -->

- [ ] For `.get()` on Optional: what happens if the Optional is empty? `.get()` throws NoSuchElementException with no context. `.orElseThrow(() -> new BusinessException("User not found: " + id))` provides a meaningful error. Consider which failure message the on-call engineer needs at 3 AM.
- [ ] For Optional used as method parameters or fields: this is a code smell (Sonar, IntelliJ both flag it). Optional is designed for return types — "this might not exist." As a parameter, it makes the API awkward and the null-check problem worse, not better.
- [ ] For Optional unwrapping: is the code using if/else with manual `.isPresent()`/`.get()` where chaining (`.map()`, `.flatMap()`, `.filter()`) would express the same logic more concisely? Chaining makes the "empty" case impossible to forget; if/else blocks require the developer to handle both branches correctly. But consider readability — a deeply nested chain can be harder to follow than a clear if/else.
