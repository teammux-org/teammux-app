# S15 — Integration Tests + v0.1.6 Ship

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Write 10 cross-module integration tests validating S1-S14 features, update docs, tag v0.1.6.

**Architecture:** All 10 tests go in engine/src/main.zig (inline, before final `test { _ = ... }` line). Tests exercise the C API layer to validate cross-module integration. Doc updates in TECH_DEBT.md, CLAUDE.md, V016_SPRINT.md.

**Tech Stack:** Zig 0.15.2, C API (tm_* exports), git CLI for test repos

---

## Task 1: Integration Test — Roster Safety (S1)

**Files:**
- Modify: `engine/src/main.zig` (before final `test { _ = ... }` line)

**Test:** Spawn 3 workers via C API in a real git repo, dismiss one, verify roster count drops to 2, get roster snapshot again to confirm no use-after-free crash (copyWorkerFields pattern validated).

---

## Task 2: Integration Test — Crash Recovery (S2)

**Files:**
- Modify: `engine/src/main.zig`

**Test:** Create git repo, resolve worktree root, manually create orphan directory (numeric name like "99/"), create engine + session start, verify directory removed by recoverOrphans.

---

## Task 3: Integration Test — History Rotation (S3)

**Files:**
- Modify: `engine/src/main.zig`

**Test:** Create HistoryLogger with 64-byte max, append entries until rotation triggers, verify .jsonl.1 archive exists and fresh .jsonl restarts.

---

## Task 4: Integration Test — Bus Reliability / Unknown Command (S4/I6)

**Files:**
- Modify: `engine/src/main.zig`

**Test:** Create CommandWatcher, write unknown command JSON to commands dir, scan, verify .teammux-error file written with error details.

---

## Task 5: Integration Test — Dispatch Delivery Failure (S4/I7)

**Files:**
- Modify: `engine/src/main.zig`

**Test:** Create engine with bus, subscribe always-fail callback, call tm_dispatch_task, verify returns TM_ERR_DELIVERY_FAILED (16).

---

## Task 6: Integration Test — PTY Death (S5/I8)

**Files:**
- Modify: `engine/src/main.zig`

**Test:** Create engine with bus, add worker + ownership, call tm_worker_pty_died, verify TM_MSG_PTY_DIED on bus, worker status .err, ownership released.

---

## Task 7: Integration Test — Diff Pagination (S7)

**Files:**
- Modify: `engine/src/main.zig`

**Test:** Generate JSON array of 150 file entries, call parseDiffResponse, verify all 150 files returned (not truncated at 100).

---

## Task 8: Integration Test — Worker Health Stall (S11)

**Files:**
- Modify: `engine/src/main.zig`

**Test:** Create engine, add worker with old last_activity_ts (400s ago, past 300s default threshold), call checkWorkerHealth(300), verify health_status = .stalled.

---

## Task 9: Integration Test — Agent Memory (S13)

**Files:**
- Modify: `engine/src/main.zig`

**Test:** Create engine with git repo, spawn worker (gets worktree), call tm_memory_append, call tm_memory_read, verify content contains summary and header.

---

## Task 10: Integration Test — MergeCoordinator Conflict Resolution (S10)

**Files:**
- Modify: `engine/src/main.zig`

**Test:** Create git repo, spawn worker, make conflicting changes on both branches, call mc.approve, verify .conflict status, verify conflicts list has file, resolve with .ours, finalize, verify .success.

---

## Task 11: Documentation Updates

**Files:**
- Modify: `docs/TECH_DEBT.md` — TD21/24/29/30/33/34/35 → RESOLVED, TD42/43/44 → RESOLVED
- Modify: `CLAUDE.md` — v0.1.6 shipped, test count updated
- Modify: `docs/sprints/v0.1.6/V016_SPRINT.md` — all streams complete

---

## Task 12: Tag and Release

**Commands:**
- `git tag -a v0.1.6 -m "..."`
- `git push origin v0.1.6`
- `gh release create v0.1.6 ...`
