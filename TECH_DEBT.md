# Teammux — Known Technical Debt

## Stream 2 — Zig Engine (v0.1.1 targets)

| ID  | Module     | Issue                              | Stream    | Breaking | Status | Notes                                                        |
|-----|------------|------------------------------------|-----------|----------|--------|--------------------------------------------------------------|
| TD1 | bus.zig    | Message retry not implemented      | stream-A1 | YES      | OPEN   | tm_message_cb is void — retry needs API change               |
| TD2 | github.zig | Webhook retry after 5s not done    | stream-A2 | NO       | OPEN   | Single try + log. Intent documented at line 166.             |
| TD3 | github.zig | 60s polling fallback not done      | stream-A2 | NO       | OPEN   | Webhook failure degrades silently. TODO at line 199.         |
| TD4 | bus.zig    | git_commit always null in messages | stream-A1 | NO       | OPEN   | Field exists in log format, rev-parse HEAD call missing.     |

## Stream 3 — MergeCoordinator + Team Lead Review

| ID  | Module          | Issue                            | Stream    | Breaking | Status |
|-----|-----------------|----------------------------------|-----------|----------|--------|
| TD5 | merge.zig       | MergeCoordinator not implemented | stream-B1 | YES      | OPEN   |
| TD6 | EngineClient    | tm_merge_* bridge missing        | stream-B2 | NO       | OPEN   |
| TD7 | GitView.swift   | Team Lead review UI not built    | stream-C1 | NO       | OPEN   |

## Notes
- TD1 breaking change: tm_message_cb gains a return value. stream-A1 updates engine/include/teammux.h, bus.zig, and EngineClient.swift atomically. No partial states.
- TD5 adds new functions to teammux.h. stream-B1 owns the header changes. stream-B2 consumes them.
- Merge order: A1 → A2 → B1 → B2 → C1
