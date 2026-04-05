# Lua + FiveM

The critical context for FiveM code: client scripts run on untrusted player machines. Anything the client sends can be fabricated. Server scripts are trusted but must validate everything from clients. Evaluate every piece of code through this trust boundary lens.

## [security] Client/Server Boundary
<!-- context_lines: 10 -->
<!-- priority: critical -->
<!-- version: 1 -->

- [ ] First, determine: is this file client-side or server-side? (Check the file path and the fxmanifest.lua to see which side loads it.) This determines the entire threat model.
- [ ] For entity creation (vehicles, peds, objects): is it happening on the server? Client-side `CreateVehicle()` or `CreatePed()` can be exploited to spawn anything — a cheater can call these with any model. Server-side spawning via `qbx.spawnVehicle` or `CreateVehicleServerSetter` means the server controls what gets created.
- [ ] For server event handlers (`RegisterNetEvent` on server): trace what the handler does with the data it receives. The `source` parameter is the only thing you can trust — it's set by the engine. Everything else in the event payload is client-controlled and can be fabricated. Does the handler validate amounts, item names, player IDs, or coordinates, or does it trust them blindly?
- [ ] For `TriggerServerEvent` calls on client: what data is being sent? If the client sends a price, amount, item name, or target player ID, the server must independently verify these values. The client should send minimal data (e.g., "I want to buy item X") and the server should look up the price, check inventory, and validate proximity.

## [threads] Thread Safety
<!-- context_lines: function -->
<!-- priority: critical -->
<!-- version: 1 -->

- [ ] For each `CreateThread` with a persistent loop: What happens if an error occurs inside the loop body? In FiveM, an unhandled error permanently kills the thread — no error message, no recovery, the functionality just silently stops working. If the thread is critical (state sync, periodic checks, main loop), wrap the body in `pcall` and decide what recovery looks like. If the thread is one-shot setup, pcall may be unnecessary.
- [ ] For `Wait()` values: what timing does this code actually need? `Wait(0)` runs every frame (~16ms at 60fps) and is only appropriate for render-critical work (drawing, per-frame checks). For polling (is player near X? has state changed?), `Wait(500)` or `Wait(1000)` is almost always sufficient. Excessive `Wait(0)` loops cause frame drops with 48 players.
- [ ] For `goto` statements: verify they don't jump past `local` declarations. This is a Lua 5.4-specific trap — the file silently fails to parse with no error message. The entire script just doesn't load.

## [events] Net Event Protection
<!-- context_lines: function -->
<!-- priority: critical -->
<!-- version: 1 -->

- [ ] For server-side event handlers: does the handler verify `source > 0`? A source of 0 means the event was triggered server-side (or by the console), not by a player. Handlers that grant items, money, or permissions must verify the source is a real connected player.
- [ ] For event parameters: think like a cheater. If this event accepts an item name, could a cheater send a rare/expensive item? If it accepts an amount, could they send 999999? If it accepts a target player ID, could they target another player? Each parameter needs validation appropriate to its risk.
- [ ] For frequently-called events (item use, shop purchase, vehicle spawn): is there rate limiting? Without it, a cheater can call the event hundreds of times per second. Even legitimate use can cause server strain if a rapid-fire exploit is found.

## [database] Database Patterns
<!-- context_lines: 5 -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For SQL queries: trace the data from source to query string. Is any variable being concatenated into the SQL? In `MySQL.query('SELECT * FROM players WHERE name = "' .. name .. '"')`, the `name` variable is an injection point. The fix is parameterized queries: `MySQL.query('SELECT * FROM players WHERE name = ?', {name})`. Severity depends on whether the input is player-controlled.
- [ ] For query frequency: where in the code lifecycle does this query run? In a one-time callback (player join, menu open) — fine. In a `CreateThread` loop or per-frame check — potentially devastating at 48 players. MariaDB connection pooling has limits; batch writes and cache reads for hot paths.
- [ ] For write operations: is the code using `MySQL.insert`/`MySQL.update` (which handle escaping) or raw `MySQL.query` with hand-built INSERT/UPDATE strings (which don't)?

## [notifications] FLRP-Specific Patterns
<!-- context_lines: 2 -->
<!-- priority: important -->
<!-- version: 1 -->

- [ ] For notification calls: FLRP uses `exports['lation_ui']:notify()`, not ox_lib's `lib.notify()`. The wrong export silently fails — the player never sees the notification. This is a common mistake when adapting code from other QBCore servers.
- [ ] For Ollama/AI integration: does the code acquire the GPU lock before making the API call? All consumers share a single 3090 Ti — concurrent calls without the lock cause VRAM swapping and all AI responses fail. Also verify `think: false` is set (prevents reasoning mode, which eats the entire context window) and the model is `qwen3.5:27b` (mixed models cause VRAM thrashing).
- [ ] For `qbx.spawnVehicle`: the return is TWO values (`local netId, veh = ...`). Capturing only one silently discards the vehicle entity reference. This is a FiveM-specific gotcha — most functions return one value.

## [performance] Tick Optimization
<!-- context_lines: function -->
<!-- priority: minor -->
<!-- version: 1 -->

- [ ] For per-frame loops (`Wait(0)` in CreateThread): consider whether the check actually needs to run every frame. Distance checks, state polling, and zone detection often work fine at `Wait(500)`. `lib.zones` provides efficient zone detection without any polling. The performance impact scales with player count — acceptable at 5 players, catastrophic at 48.
- [ ] For entity pool iteration (`GetGamePool`): is the pool being scanned every frame, or cached and refreshed periodically? A full pool scan every frame on a busy server is expensive. Consider whether the code could use event-driven approaches (state bags, entity creation events) instead.
- [ ] For distance comparisons in frequently-called code: is the code using `GetDistanceBetweenCoords` (which computes a square root) when a squared-distance comparison (`#(a - b) < threshold`) would work? The square root is unnecessary when you only need to compare against a threshold. In one-shot callbacks or infrequent checks, the readability difference may not matter — this is primarily a concern in per-frame loops and hot paths with many entities.
