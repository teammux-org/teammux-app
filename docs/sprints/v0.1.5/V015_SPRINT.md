# Teammux v0.1.5 — Sprint Master Spec

**Theme:** Polish & Stability
**Status:** In Progress
**Baseline:** audit-address-v014 tag, engine tests passing

## Objective

No new features. Fix all known v0.1.5 tech debt items,
resolve the diff tab backend (disabled since audit-address),
resolve the updateRepo thread safety TODO left by AA1, and
produce OSS-ready documentation. Ship a clean, stable,
well-documented codebase as the foundation for v0.2.

## TD Items Resolved This Sprint

| ID   | Module                   | Issue                                                         |
|------|--------------------------|---------------------------------------------------------------|
| TD22 | SessionState.swift       | Session restore does not re-establish ownership registry      |
| TD23 | ContextView.swift        | CLAUDE.md rendered as plain text, not true markdown           |
| TD26 | TeamMessage/CoordTypes   | PRState and PRStatus divergent colors                         |
| TD27 | ContextView.swift        | Hot-reload repeat within 3s not detected by onChange          |
| TD28 | ContextView.swift        | Diff highlight positional comparison, not LCS/Myers           |
| TD31 | EngineClient.swift       | approveMerge/rejectMerge treat CLEANUP_INCOMPLETE as failure  |
| TD32 | merge.zig                | runGitLogged does not capture stderr for diagnostics          |
| TD36 | main.zig                 | tm_interceptor_path worker 0 OOM returns null without setError|
| TD37 | main.zig                 | sessionStop TL interceptor cleanup failure not surfaced       |

## Additional Scope

- updateRepo thread safety: resolve TODO(AA2) in github.zig
- Diff tab backend: implement getDiff via GitHub PR files API,
  re-enable Diff tab (disabled since audit-address sprint I17)
- OSS docs: README overhaul, CONTRIBUTING.md, getting started guide
- Integration tests for new diff flow, session restore ownership,
  hot-reload dedup

---

## Stream Registry

| Stream | Branch | Owns | Layer | Wave | Complexity |
|--------|--------|------|-------|------|------------|
| S1 | fix/v015-s1-updaterepo-threadsafety | updateRepo mutex (TODO AA2) | Engine | 1 | small |
| S2 | fix/v015-s2-merge-diagnostics | TD31, TD32 | Engine | 1 | small |
| S3 | fix/v015-s3-interceptor-errors | TD36, TD37 | Engine | 1 | small |
| S4 | fix/v015-s4-session-restore-ownership | TD22 | Engine + Swift | 2 | medium |
| S5 | fix/v015-s5-github-diff | Diff tab backend | Engine + Swift | 2 | medium |
| S6 | fix/v015-s6-ux-polish | TD23, TD26, TD27, TD28 | Swift | 2 | medium |
| S7 | fix/v015-s7-oss-docs | README, CONTRIBUTING, guide | Docs | 2 | medium |
| S8 | fix/v015-s8-integration | Tests, TD resolved, tag | Engine + Docs | 3 | medium |

## Wave Structure

Wave 1 — S1, S2, S3 (pure engine, all parallel, no deps)
Wave 2 — S4, S5, S6, S7 (all parallel, no deps on each other)
          S4 and S5 have no Wave 1 dependency
          S6 has thin dependency on S1 (TD27 engine change)
          S7 has no code dependencies at all
Wave 3 — S8 (waits for all 7 streams merged)

## Merge Order

S1 → S2 → S3 → S4 → S5 → S6 → S7 → S8

Rationale: engine streams first (least conflict risk with Swift),
S7 (docs only) merges before S8 (integration) to ensure docs
are committed before the final ship commit.

## Key Files Per Stream

- S1: engine/src/github.zig, engine/src/main.zig
- S2: engine/src/merge.zig, macos/Sources/Teammux/Engine/EngineClient.swift
- S3: engine/src/main.zig
- S4: engine/src/main.zig, macos/Sources/Teammux/Engine/EngineClient.swift,
      macos/Sources/Teammux/Setup/SessionState.swift
- S5: engine/src/github.zig, engine/include/teammux.h,
      macos/Sources/Teammux/Engine/EngineClient.swift,
      macos/Sources/Teammux/RightPane/DiffView.swift,
      macos/Sources/Teammux/RightPane/RightPaneView.swift
- S6: engine/src/hotreload.zig,
      macos/Sources/Teammux/RightPane/ContextView.swift,
      macos/Sources/Teammux/Models/CoordinationTypes.swift,
      macos/Sources/Teammux/Models/TeamMessage.swift,
      macos/Sources/Teammux/RightPane/GitView.swift
- S7: README.md, CONTRIBUTING.md, docs/getting-started.md,
      docs/architecture.md
- S8: engine/src/main.zig (integration tests), docs/TECH_DEBT.md,
      CLAUDE.md, V015_SPRINT.md

---

## Stream Specifications

---

### S1 — updateRepo Thread Safety

**Branch:** fix/v015-s1-updaterepo-threadsafety
**Owns:** Resolve TODO(AA2) comment in github.zig

**Background:**
AA1 (audit-address sprint) made GitHubClient own its repo string
and added updateRepo() for atomic reload. A TODO(AA2) comment was
left noting that pollEvents() reads self.repo on a background thread
while updateRepo() can free/replace it concurrently from the main
thread — a data race. AA2 added mutex patterns to ownership and
last_error but did not cover github.zig.

**Fix:**
1. Add a Mutex field to GitHubClient: repo_mutex
2. pollEvents(): acquire repo_mutex before reading self.repo,
   release after the gh command is launched (not for the full poll
   duration — just long enough to copy the repo string locally)
3. updateRepo(): acquire repo_mutex before freeing and replacing
   self.repo, release after
4. Initialize repo_mutex in GitHubClient.init()
5. Deinit repo_mutex in GitHubClient.deinit()

**Files:** engine/src/github.zig

**Commit sequence:**
Commit 1: github.zig — repo_mutex field, init/deinit
Commit 2: github.zig — pollEvents acquires mutex for repo read,
           updateRepo acquires mutex for repo swap
After each: cd engine && zig build && zig build test

**Definition of done:**
- repo_mutex protects all self.repo reads and writes
- No TODO(AA2) comment remaining
- Engine tests pass

---

### S2 — Merge Diagnostics

**Branch:** fix/v015-s2-merge-diagnostics
**Owns:** TD31, TD32

**TD31 — approveMerge/rejectMerge treat CLEANUP_INCOMPLETE as failure**
File: macos/Sources/Teammux/Engine/EngineClient.swift (lines ~895, ~922)

Problem: Both functions use `guard result == TM_OK` which treats
TM_ERR_CLEANUP_INCOMPLETE (15) as total failure. The merge/reject
itself succeeded — only worktree/branch cleanup failed. Swift
returns false to the UI, showing an error when the operation
actually worked.

Fix:
- Change the guard to accept both TM_OK (0) and
  TM_ERR_CLEANUP_INCOMPLETE (15) as success
- On code 15: return true AND log a warning visible to the user:
  "Merge succeeded but worktree cleanup was incomplete.
   Manual cleanup may be needed."
- Consider surfacing this as a non-fatal banner in GitView

**TD32 — runGitLogged does not capture git stderr**
File: engine/src/merge.zig

Problem: runGitLogged uses runGitCapture which sets
stderr_behavior = .Ignore. Cleanup failure logs show operation
name and exit code but not git's actual error message
(e.g. "fatal: '/path' is not a working tree").

Fix:
- Add a runGitLoggedWithStderr variant that captures stderr
- Use it in the cleanup paths in approve and reject flows
- Include the stderr output in the warning log message

**Files:** engine/src/merge.zig,
           macos/Sources/Teammux/Engine/EngineClient.swift

**Commit sequence:**
Commit 1: merge.zig — runGitLoggedWithStderr, use in cleanup paths
Commit 2: EngineClient.swift — TD31 partial success handling

After Commit 1: cd engine && zig build && zig build test
After Commit 2: ./build.sh

**Definition of done:**
- approveMerge/rejectMerge return true on CLEANUP_INCOMPLETE
- User sees informational warning, not an error, on code 15
- Cleanup failure logs include git stderr output
- Tests pass

---

### S3 — Interceptor Error Surfacing

**Branch:** fix/v015-s3-interceptor-errors
**Owns:** TD36, TD37

**TD36 — tm_interceptor_path worker 0 OOM returns null without setError**
File: engine/src/main.zig

Problem: tm_interceptor_path for worker_id == 0 calls
std.heap.c_allocator.dupeZ. On OOM, it returns null without
calling setError. Swift interprets null as "no interceptor
installed" masking the root cause.

Fix:
- After the dupeZ call for worker 0 path, check for null/error
- On OOM: call setError("tm_interceptor_path: OOM allocating
  Team Lead wrapper path") before returning null

**TD37 — sessionStop Team Lead interceptor cleanup failure not surfaced**
File: engine/src/main.zig

Problem: sessionStop calls interceptor.remove for the Team Lead
wrapper. On failure, the error is logged via std.log.warn but not
stored via setError. The orphaned .git-wrapper directory in project
root can interfere with manual git usage after the app exits.

Fix:
- On interceptor.remove failure in sessionStop: call setError
  with a descriptive message noting the orphaned path
- This allows Swift to surface a notification if desired

**Files:** engine/src/main.zig

**Commit sequence:**
Commit 1: main.zig — TD36 setError on OOM for worker 0 path
Commit 2: main.zig — TD37 setError on sessionStop cleanup failure

After each: cd engine && zig build && zig build test

**Definition of done:**
- OOM on Team Lead interceptor path sets lastError
- sessionStop cleanup failure sets lastError
- Engine tests pass

---

### S4 — Session Restore Ownership Registry

**Branch:** fix/v015-s4-session-restore-ownership
**Owns:** TD22

**Background (from TECH_DEBT.md note):**
SessionState.swift restores worker roster and spawns workers into
existing worktrees. FileOwnershipRegistry is rebuilt at spawn time
from the role definition — but deny patterns from runtime ownership
changes (direct tm_ownership_register calls) are lost. Full registry
snapshot was deferred to v0.2. v0.1.5 fix: re-register ownership
rules from the worker's saved role definition on restore.

**Phase 1 brainstorm required before implementing.**
Read these files first and present analysis:
- engine/src/main.zig (tm_worker_spawn, tm_ownership_register)
- engine/src/ownership.zig
- macos/Sources/Teammux/Setup/SessionState.swift (restoreSession)
- macos/Sources/Teammux/Engine/EngineClient.swift (sessionStart,
  spawnWorker, workerRoles)

Brainstorm questions to answer:
1. When spawnWorker is called during restore, does it already
   call tm_ownership_register with the role's deny patterns?
   Or does the normal spawn path skip this?
2. What is the correct source for ownership rules during restore:
   the saved role definition from the snapshot, or the live role
   file from disk?
3. Is the fix entirely Swift-side (call tm_ownership_register
   after spawnWorker in the restore path) or does it need an
   engine-side change?

**Likely fix (to be confirmed in brainstorm):**
After restoring each worker in restoreSession(), call
tm_ownership_register with the role's write_patterns and
deny_patterns from the loaded RoleDefinition. The role is
available via workerRoles[workerId] after spawn.

**Files:** macos/Sources/Teammux/Engine/EngineClient.swift,
           macos/Sources/Teammux/Setup/SessionState.swift,
           engine/src/main.zig (if engine change needed)

**Commit sequence:**
Commit 1: brainstorm approved fix

After commit: ./build.sh

**Definition of done:**
- Restored workers have ownership rules registered
- Registry deny patterns enforced after session restore
- No regression in normal spawn path
- ./build.sh passes

---

### S5 — GitHub Diff Backend

**Branch:** fix/v015-s5-github-diff
**Owns:** Diff tab backend, re-enable Diff tab (I17 from audit-address)

**Background:**
The Diff tab was disabled in the audit-address sprint because
getDiff() always returned error.NotImplemented. The approach for
v0.1.5 is to use the GitHub PR files API — the same data GitHub
shows in its UI — rather than local git diff. Teammux already has
an authenticated gh CLI, so the API call is straightforward.

**Phase 1 brainstorm required before implementing.**
Read these files first and present analysis:
- engine/src/github.zig (existing GitHubClient, runGhCommand)
- engine/src/main.zig (tm_github_get_diff export)
- engine/include/teammux.h (tm_diff_t, tm_diff_file_t structs)
- macos/Sources/Teammux/RightPane/DiffView.swift
- macos/Sources/Teammux/RightPane/RightPaneView.swift

Brainstorm questions:
1. The current tm_diff_t / tm_diff_file_t structs in the header —
   do they match what the GitHub PR files API returns, or do they
   need reshaping?
2. The GitHub PR files API endpoint:
   GET /repos/{owner}/{repo}/pulls/{pr_number}/files
   Returns an array of file objects with filename, status, additions,
   deletions, patch (unified diff string). Does the current DiffView
   UI handle this structure or need updating?
3. How does DiffView get the PR number for the current worker?
   It needs to look up engine.workerPRs[worker.id].prUrl and extract
   the PR number from the URL.
4. The gh CLI call would be:
   gh api /repos/{owner}/{repo}/pulls/{pr_number}/files
   Is runGhCommand sufficient or do we need runGhCommandCapture?

**Likely fix (to be confirmed in brainstorm):**
1. engine/src/github.zig: implement getDiff() using gh api call
   to the PR files endpoint, parse JSON response, populate
   tm_diff_file_t array
2. engine/src/main.zig: remove unreachable in tm_github_get_diff,
   wire through to getDiff()
3. macos/Sources/Teammux/RightPane/DiffView.swift: update to use
   real diff data, display per-file patch with syntax styling
4. macos/Sources/Teammux/RightPane/RightPaneView.swift: re-enable
   .diff case (remove .disabled() modifier added in audit-address)

**Files:** engine/src/github.zig, engine/src/main.zig,
           engine/include/teammux.h,
           macos/Sources/Teammux/Engine/EngineClient.swift,
           macos/Sources/Teammux/RightPane/DiffView.swift,
           macos/Sources/Teammux/RightPane/RightPaneView.swift

**Commit sequence:**
Commit 1: engine — getDiff() via GitHub PR files API
Commit 2: engine — wire tm_github_get_diff, remove unreachable
Commit 3: Swift — DiffView updated, Diff tab re-enabled

After Commit 1+2: cd engine && zig build && zig build test
After Commit 3: ./build.sh

**Definition of done:**
- Diff tab visible and functional in right pane
- Shows per-file diffs from GitHub PR for selected worker
- getDiff() uses GitHub API, not local git diff
- unreachable removed from tm_github_get_diff
- Engine tests pass, ./build.sh passes

---

### S6 — UX Polish Bundle

**Branch:** fix/v015-s6-ux-polish
**Owns:** TD23, TD26, TD27, TD28

Note: TD27 has a thin engine component (hotreload.zig). Read
the TD27 note in TECH_DEBT.md carefully before implementing.

**TD23 — CLAUDE.md rendered as plain text, not markdown**
File: macos/Sources/Teammux/RightPane/ContextView.swift

Current state: ContextView renders CLAUDE.md with basic ## bold
detection. TD23 calls for a proper SwiftUI-compatible markdown
renderer without adding a dependency.

Fix: Use AttributedString with Markdown support (available in
SwiftUI since iOS 15/macOS 12). Replace the per-line ForEach
rendering with AttributedString(markdown:) for the full content.
Preserve the per-line diff highlight overlay — apply yellow
background to changed line ranges using AttributedString ranges
rather than per-line views.

**TD26 — PRState and PRStatus divergent colors**
Files: macos/Sources/Teammux/Models/TeamMessage.swift,
       macos/Sources/Teammux/Models/CoordinationTypes.swift,
       macos/Sources/Teammux/RightPane/GitView.swift

Current state: PRState (TeamMessage.swift) maps to tm_pr_state_t.
PRStatus (CoordinationTypes.swift) is the bus message workflow type.
PRState.closed is red, PRStatus.closed is grey. Divergent for the
same concept.

Fix:
1. Unify on PRStatus (the newer type from T11/v0.1.4)
2. Update PRStatus.color: open=green, merged=purple, closed=grey
   (matching the more considered design from T11)
3. Remove PRState or alias it to PRStatus
4. Update all PRState references in GitView and TeamMessage
5. Ensure tm_pr_state_t enum in teammux.h maps correctly

**TD27 — Hot-reload repeat within 3s not detected by onChange**
Files: engine/src/hotreload.zig,
       macos/Sources/Teammux/RightPane/ContextView.swift

Current state: ContextView observes hotReloadedWorkers (a Set).
Set.insert on an already-present element is a no-op — the Set
doesn't mutate, so onChange doesn't fire for repeat saves within
the 3s window.

Fix (engine side):
- In hotreload.zig fireCallback: expose a reload counter or
  timestamp per worker alongside the existing callback mechanism
- Add a new C API field or augment the existing callback to pass
  a monotonic reload sequence number

Fix (Swift side):
- Replace hotReloadedWorkers: Set<UInt32> with a dict:
  [UInt32: Int] mapping worker ID to reload counter
- Incrementing the counter on every reload fires onChange even
  for rapid repeated saves
- ContextView observes the counter value, not just presence

**TD28 — Diff highlight positional comparison, not LCS**
File: macos/Sources/Teammux/RightPane/ContextView.swift

Current state: applyDiffHighlight compares old and new content
lines by positional index. An insertion near the top marks all
subsequent shifted lines as changed.

Fix: Implement a simple LCS (longest common subsequence) based
line diff. Swift stdlib does not include LCS but a clean O(nm)
implementation is ~30 lines. Only highlight lines not present
in LCS output (truly added/removed/changed lines). This eliminates
false positives on insertions and deletions.

**Files:** engine/src/hotreload.zig,
           macos/Sources/Teammux/RightPane/ContextView.swift,
           macos/Sources/Teammux/Models/CoordinationTypes.swift,
           macos/Sources/Teammux/Models/TeamMessage.swift,
           macos/Sources/Teammux/RightPane/GitView.swift

**Commit sequence:**
Commit 1: engine/hotreload.zig — reload counter per worker (TD27)
Commit 2: ContextView.swift — AttributedString markdown (TD23),
           replace Set with reload counter dict (TD27),
           LCS diff highlight (TD28)
Commit 3: TeamMessage.swift + CoordinationTypes.swift + GitView.swift
           — PRState/PRStatus unification (TD26)

After Commit 1: cd engine && zig build && zig build test
After Commits 2+3: ./build.sh

**Definition of done:**
- CLAUDE.md renders with full markdown (headers, bold, italic,
  code blocks) using AttributedString
- PRState and PRStatus unified with consistent colors
- Rapid saves within 3s window all trigger diff highlight refresh
- LCS diff highlights only truly changed lines
- Engine tests pass, ./build.sh passes

---

### S7 — OSS Documentation

**Branch:** fix/v015-s7-oss-docs
**Owns:** README.md, CONTRIBUTING.md, docs/getting-started.md,
          docs/architecture.md

This stream is fully independent. No code changes. Docs only.
Can run in parallel from day one with zero dependencies.

**README.md — Full overhaul**
The current README.md is minimal. Rewrite it as the OSS project
homepage. Include:
- What Teammux is (one paragraph, sharp)
- Why it's different (Team Lead structural constraints, not convention)
- Screenshot or architecture diagram placeholder
- Requirements (macOS 15, Apple Silicon, Xcode, Zig 0.15.x)
- Quick start (clone, build, run)
- How it works (brief: worktrees, ownership registry, interceptor)
- Link to getting-started guide
- Link to CONTRIBUTING.md
- License

**CONTRIBUTING.md — New file at repo root**
Write a clear contributor guide covering:
- Development setup (exact steps to get a build running)
- Repository structure (point to docs/ for sprint history,
  docs/codex-audits/ for audit history)
- Sprint and stream workflow (how PRs are structured)
- CLAUDE.md and AGENTS.md — what they are and how they work
- Code conventions (Zig ownership rules, Swift tm_* confinement,
  no src/ modifications)
- How to report bugs
- How to propose features

**docs/getting-started.md — New file**
Step-by-step guide for first-time users:
- Install prerequisites
- Clone and build
- Create a .teammux/config.toml for a project
- Define your first role TOML file
- Launch Teammux on a project
- Spawn your first worker
- Read the Team Lead interface
- Complete a task and review the PR

**docs/architecture.md — New file**
Technical architecture overview:
- System diagram (ASCII or Mermaid): Engine ↔ C API ↔ Swift UI
- Worktree isolation model (one worker = one worktree = one branch)
- Ownership registry and interceptor (how write enforcement works)
- Team Lead structural constraints (what the engine enforces)
- Message bus (how events flow from agent PTY to Swift UI)
- Session persistence model
- Key design decisions and their rationale

**Commit sequence:**
Commit 1: README.md overhaul
Commit 2: CONTRIBUTING.md (new)
Commit 3: docs/getting-started.md (new)
Commit 4: docs/architecture.md (new)

No build verification needed — docs only.

**Definition of done:**
- README.md is OSS-ready, informative, and accurate
- CONTRIBUTING.md covers the full development workflow
- Getting started guide works end to end
- Architecture doc accurately describes the current system
- No broken links, no references to old Rust/TOML stack

---

### S8 — Integration Tests + v0.1.5 Ship

**Branch:** fix/v015-s8-integration
**Owns:** Integration tests, TECH_DEBT.md updates, tag v0.1.5
**Depends on:** All 7 streams merged to main

**Integration scenarios to test:**

1. updateRepo thread safety — start GitHub polling, trigger
   config reload with new github_repo, verify no race/crash,
   polling continues with new repo value

2. Merge cleanup incomplete — approve a worker merge that
   succeeds but cleanup fails, verify Swift shows partial
   success warning not error, verify log contains stderr output

3. Session restore ownership — save session with a worker,
   restore it, verify the worker's deny patterns are enforced
   in the ownership registry after restore

4. Diff tab end to end — spawn a worker with an open PR,
   open the Diff tab, verify per-file diffs load from GitHub,
   verify the tab is no longer disabled

5. Markdown rendering — create a CLAUDE.md with headers,
   bold text, and a code block, verify ContextView renders
   them correctly

6. Hot-reload repeat — save a role file twice within 3 seconds,
   verify both saves trigger the diff highlight in ContextView

7. LCS diff highlight — edit a CLAUDE.md file with an insertion
   at the top, verify only the inserted line is highlighted
   (not all subsequent shifted lines)

8. PRStatus unification — verify PR cards in GitView and
   LiveFeedView use consistent colors for open/merged/closed

**Documentation updates:**

TECH_DEBT.md:
- TD22, TD23, TD26, TD27, TD28 → RESOLVED (S4, S6)
- TD31, TD32 → RESOLVED (S2)
- TD36, TD37 → RESOLVED (S3)
- updateRepo TODO → RESOLVED (S1)
- Add any new debt discovered during this sprint as TD38+

CLAUDE.md:
- v0.1.5 → shipped
- Update test baseline count

V015_SPRINT.md:
- All 8 streams → complete

**Tag and release:**

git tag -a v0.1.5 \
  -m "v0.1.5 — Polish & Stability: TD22/23/26/27/28/31/32/36/37 resolved, diff tab backend, updateRepo thread safety, OSS docs"

git push origin v0.1.5

**Definition of done:**
- All 8 integration scenarios pass
- All resolved TD items marked in TECH_DEBT.md
- CLAUDE.md updated with shipped status and test count
- v0.1.5 tag on remote
- GitHub release created

---

## Message Type Registry (no additions this sprint)

Current values (do not collide):
- 0: task, 1: instruction, 2: context, 3: statusReq (removed AA6),
  4: statusRpt (removed AA6), 5: completion, 6: error,
  7: broadcast, 8: question, 9: (reserved), 10: dispatch,
  11: response, 12: peerQuestion, 13: delegation,
  14: prReady, 15: prStatus

## PR Review Standards

All PRs follow the same review standard as v0.1.4:
- Branch based on current main (Check 1)
- Only correct files modified (Check 2)
- No force-unwraps in production Swift (Check 3)
- No tm_* calls outside EngineClient.swift (Check 4)
- Engine builds cleanly (Check N-2)
- All engine tests pass (Check N-1)
- ./build.sh passes for Swift streams (Check N)
- Conflict check with main (Check N+1)
- No src/ modifications (any check)

## References

- docs/TECH_DEBT.md — full debt registry
- docs/codex-audits/audit-001-post-v014/ACTION-PLAN.md — audit findings
- docs/sprints/audit-address-v014/AUDIT_ADDRESS_SPRINT.md — prior sprint
- engine/include/teammux.h — C API source of truth
