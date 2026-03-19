# Stream AA5 — Performance Hot Path

## Context

Read these files before doing anything else (in parallel):
- CLAUDE.md
- docs/TECH_DEBT.md
- docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md
  (read findings I14 and I16 in full)
- engine/src/bus.zig
- engine/src/main.zig (busSendBridge, message routing)
- macos/Sources/Teammux/Engine/EngineClient.swift
  (handleCompletionMessage, triggerAutonomousDispatch,
   refreshDispatchHistory)

Then run: cd engine && zig build test
Confirm 356 tests pass before writing any code.

## Your Task

Two performance fixes on the message delivery critical path.

## Fix I14 — Bus send spawns git rev-parse on every message
**File:** engine/src/bus.zig:120
**Problem:** MessageBus.send() runs git rev-parse HEAD
synchronously on every bus message of every type.
**Fix:**
1. Add to MessageBus struct:
   commit_cache: ?[]const u8 = null
   (owned, freed in deinit)
2. On send: if commit_cache is non-null, use it directly
3. On send with type == .completion or .prReady:
   invalidate cache (free + set null), then fetch fresh
4. On cache miss: run git rev-parse HEAD, store result
5. For message types where commit context is irrelevant
   (.delegation, .question, .broadcast, .dispatch,
   .response): skip git call entirely, log null for
   the commit field
6. Free commit_cache in MessageBus.deinit

## Fix I16 — Completion handling fans out @Published updates
**File:** macos/Sources/Teammux/Engine/EngineClient.swift:1459
**Problem:** One completion triggers: messages append,
workerCompletions update, dispatchTask, refreshDispatchHistory
(full bridge round-trip), autonomousDispatches update —
four separate SwiftUI invalidations.
**Fix:**
1. In triggerAutonomousDispatch: remove the
   refreshDispatchHistory() call after dispatchTask
2. Instead, construct the DispatchEvent locally from
   the dispatch parameters and append it directly to
   dispatchHistory without a bridge round-trip:
   let event = DispatchEvent(
     targetWorkerId: workerId,
     instruction: instruction,
     timestamp: Date(),
     delivered: success,
     kind: .task
   )
   dispatchHistory.append(event)
3. Wrap the entire completion handling block so
   messages, workerCompletions, dispatchHistory, and
   autonomousDispatches are all updated before the
   next SwiftUI render cycle

## Commit Sequence

Commit 1: bus.zig — commit cache with per-type
           invalidation strategy
Commit 2: EngineClient.swift — batch completion-side
           @Published updates, remove refreshDispatchHistory
           from autonomous dispatch path

After Commit 1:
  cd engine && zig build && zig build test
After Commit 2:
  ./build.sh

## Definition of Done

- git rev-parse not called on delegation, question,
  broadcast, dispatch, response message types
- Commit cache invalidated on completion and prReady
- Completion handling produces one SwiftUI update cycle
- refreshDispatchHistory not called from autonomous dispatch
- DispatchEvent appended locally instead of bridge reload
- 356 engine tests passing
- ./build.sh passing

Raise PR from fix/aa5-performance-hotpath against main.
Do NOT merge. Report back with PR link.
