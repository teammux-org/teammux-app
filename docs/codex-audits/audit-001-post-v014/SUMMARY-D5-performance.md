# Audit Summary — Domain 5: Performance

## Severity Counts
- CRITICAL: 0
- IMPORTANT: 3
- SUGGESTION: 3
- TOTAL: 6

## Top 3 Issues
1. [IMPORTANT/HIGH] Message bus send path spawns `git` for every message — every bus delivery blocks on `git rev-parse HEAD` before logging and callback delivery — engine/src/bus.zig:120
2. [IMPORTANT/MEDIUM] Completion/question history append is O(n) and stays on the delivery path — each append rewrites the full JSONL file and will get slower as TD24’s unbounded log grows — engine/src/history.zig:114
3. [IMPORTANT/MEDIUM] Completion handling fans out into multiple `@Published` invalidations and a full dispatch-history reload — one completion can mutate `messages`, `workerCompletions`, `dispatchHistory`, and `autonomousDispatches` in sequence — macos/Sources/Teammux/Engine/EngineClient.swift:1459

## Recommended Sprint Allocation
- Audit-address sprint: Message bus send path spawns `git` for every message; Completion handling fans out into multiple `@Published` invalidations and a full dispatch-history reload
- v0.1.5: Live feed message storage is unbounded while the UI renders the full array; JSON key scanning allocates short search strings on the heap in common paths; Role hot-reload always regenerates the interceptor wrapper, even for metadata-only edits
- v0.2 / defer: Completion/question history append is O(n) and stays on the delivery path

## Systemic Patterns
The same data is repeatedly transformed at each boundary: command JSON is scanned with tiny heap allocations, bus messages are reformatted into JSONL, copied again into C strings, bridged into Swift strings, reparsed with `JSONSerialization`, and then fanned out into several observed collections. The watcher infrastructure itself is event-driven and reasonably lean; the heavier costs come from synchronous persistence, subprocess-based metadata capture, and UI state updates that rebuild broader collections than the immediate event requires.
