# Python + FastAPI

Evaluate in the context of async vs sync execution, whether the endpoint handles user input, and the application's concurrency model.

## [security] Injection & Input Validation
<!-- context_lines: 10 -->
<!-- priority: critical -->
<!-- version: 1 -->

- [ ] For any database query: trace the data from the endpoint parameter to the query. Are f-strings or `.format()` used to build SQL? These create injection points when the input is user-controlled. Parameterized queries (SQLAlchemy bind params, `cursor.execute(sql, params)`) are the fix. Severity depends on whether the endpoint is authenticated and what data the query accesses.
- [ ] For file upload handling: what validation exists? Consider: size limits (prevent DoS), content type verification (the extension doesn't guarantee the content), and filename sanitization (can an attacker craft a filename like `../../etc/passwd` to write outside the upload directory?).
- [ ] For subprocess calls: is `shell=True` used? With shell mode, the command string is interpreted by the shell — user input in the string enables command injection. Argument lists (`subprocess.run(["cmd", arg1, arg2])`) avoid shell interpretation. Consider whether shelling out is necessary at all.
- [ ] For CORS: are allowed origins explicit? `allow_origins=["*"]` means any website can make authenticated requests on behalf of logged-in users. This is sometimes acceptable for public APIs with no authentication, but should be intentional.

## [async] Async Correctness
<!-- context_lines: function -->
<!-- priority: critical -->
<!-- version: 1 -->

- [ ] For `async def` endpoints: is any blocking I/O called without `run_in_executor`? Blocking calls (synchronous file reads, `requests.get()`, CPU-heavy computation) in an async handler block the entire event loop — all other requests stall until the blocking call completes. This is the #1 FastAPI performance killer. Check for synchronous database drivers, `open()` without `aiofiles`, and `time.sleep()`.
- [ ] For database session management: trace the session lifecycle. Is it acquired and released properly? With async drivers (`asyncpg`), use `async with`. With sync drivers through dependency injection, ensure the session is closed even on error paths. A leaked session eventually exhausts the connection pool.
- [ ] For concurrent operations: are independent async calls running concurrently (`asyncio.gather()`) or sequentially (one `await` after another)? Sequential awaits are correct when operations depend on each other; for independent operations (fetch user + fetch permissions), they waste time.
- [ ] For background work: is it using `BackgroundTasks` (request-scoped, runs after response) or a proper task queue (Celery, ARQ)? Fire-and-forget coroutines (`asyncio.create_task()` without tracking) lose errors silently and are hard to monitor.

## [error-handling] Exception Handling
<!-- context_lines: function -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For exception handling: is the error response appropriate for the consumer? Consider: `HTTPException(status_code=404)` for "not found" is clear. `HTTPException(status_code=500)` for every error is not — it tells the client nothing about whether to retry, fix their input, or escalate. 502/503 for upstream failures guides the client to retry.
- [ ] For bare `except:` or `except Exception:`: what errors are being caught? Catching everything silently hides bugs. If broad exception handling is necessary (e.g., at an API boundary), log the error with context and return a sanitized response. The on-call engineer needs the real error; the user needs a safe message.
- [ ] For error response consistency: do all endpoints return errors in the same shape? Clients that parse `{"detail": ...}` break when one endpoint returns `{"error": ...}`. A `@app.exception_handler` or middleware ensures consistency.

## [types] Type Annotations & Pydantic
<!-- context_lines: 5 -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For endpoint parameters: are they typed with Pydantic models or raw access (`request.query_params["key"]`)? Pydantic models provide automatic validation, documentation, and error messages. Raw access skips all of this and requires manual validation.
- [ ] For response types: is `response_model` specified on the endpoint? Without it, whatever the function returns is serialized directly — including internal fields, SQLAlchemy model internals, or fields that should be excluded. The response model acts as a serialization boundary.
- [ ] For Optional fields in Pydantic models: do they have explicit `None` defaults? Without a default, the field is required — clients must send `"field": null` explicitly, which is usually not the intent.

## [testing] Testing Patterns
<!-- context_lines: function -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For API tests: are they using `TestClient` or `AsyncClient` (from httpx)? These test the full HTTP layer including middleware, validation, and serialization. Raw function calls skip the framework entirely and miss integration issues.
- [ ] For database tests: what happens to the data after the test? Tests that modify a shared database and don't clean up create order-dependent test suites that break when run in parallel. Transaction rollback or isolated databases prevent contamination.
- [ ] For external service dependencies: are they mocked at the HTTP layer (`respx`, `responses`) or at the Python interface? Interface mocks hide serialization bugs, header issues, and status code handling. HTTP-level mocks catch real integration problems.

## [dependencies] Dependency Management
<!-- context_lines: 5 -->
<!-- priority: minor -->
<!-- version: 1 -->

- [ ] For dependency versions: are they pinned or locked? Unpinned dependencies change on every install — a minor version bump in a transitive dependency can introduce breaking changes. Consider whether the project uses `poetry.lock`, `uv.lock`, or pinned `requirements.txt`.
- [ ] For the FastAPI + Pydantic version boundary: Pydantic v1 and v2 have incompatible APIs. If the project is on one version, new code must use the same version's patterns. Mixing v1 and v2 patterns causes subtle runtime errors.
