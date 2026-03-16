# Teammux — Known Technical Debt

## Stream 2 — Zig Engine (v0.1.1 targets)

| ID  | Module     | Issue                              | Stream    | Breaking | Status | Notes                                                        |
|-----|------------|------------------------------------|-----------|----------|--------|--------------------------------------------------------------|
| TD1 | bus.zig    | Message retry not implemented      | stream-A1 | YES      | RESOLVED | tm_message_cb returns tm_result_t, retry 3x with backoff    |
| TD2 | github.zig | Webhook retry after 5s not done    | stream-A2 | NO       | RESOLVED | Retry once after 5s, then polling fallback.                  |
| TD3 | github.zig | 60s polling fallback not done      | stream-A2 | NO       | RESOLVED | Background thread polls gh api every 60s on teammux/* branches. |
| TD4 | bus.zig    | git_commit always null in messages | stream-A1 | NO       | RESOLVED | git -C rev-parse HEAD captured before each message log       |

## Stream 3 — MergeCoordinator + Team Lead Review

| ID  | Module          | Issue                            | Stream    | Breaking | Status |
|-----|-----------------|----------------------------------|-----------|----------|--------|
| TD5 | merge.zig       | MergeCoordinator not implemented | stream-B1 | YES      | RESOLVED |
| TD6 | EngineClient    | tm_merge_* bridge missing        | stream-B2 | NO       | OPEN   |
| TD7 | GitView.swift   | Team Lead review UI not built    | stream-C1 | NO       | OPEN   |
| TD8 | ConflictInfo    | conflictType as String not enum  | stream-C1 or v0.2 | NO | OPEN |

## Notes
- TD1 breaking change: tm_message_cb gains a return value. stream-A1 updates engine/include/teammux.h, bus.zig, and EngineClient.swift atomically. No partial states.
- TD5 adds new functions to teammux.h. stream-B1 owns the header changes. stream-B2 consumes them.
- TD8: ConflictInfo.conflictType is a raw String. Consider an enum once engine's conflict type vocabulary is stable. Deferred from stream-B2 review.
- Merge order: A1 → A2 → B1 → B2 → C1
