# Teammux v0.1.1 — Stream A2: GitHub Debt

## Your branch
feat/v011-stream-a2-github-debt

## Your worktree
../teammux-stream-a2

## Read first
Read V011_SPRINT.md Section 3 (stream-A2) and TECH_DEBT.md
(TD2 and TD3) before doing anything else.
Read engine/src/github.zig — your primary file.
Pay attention to line 166 (TD2 TODO) and line 199 (TD3 TODO).

## Your mission
Resolve TD2 and TD3 from TECH_DEBT.md.

### TD2 — Webhook retry
After first gh webhook forward attempt fails:
log the failure with reason, wait exactly 5s, retry once.
If second attempt also fails: log and trigger TD3 fallback.
If gh binary not in PATH: skip retry, go straight to TD3.

### TD3 — Polling fallback
After TD2 retry exhausted (or gh not found):
spawn a background thread that runs every 60s:
  gh api repos/{repo}/events
Parse JSON response for push and pull_request events
on worker branches (branches matching teammux/* pattern).
Fire tm_github_event_cb for each relevant event found.
On tm_github_webhooks_stop: signal thread to exit, join it
cleanly before returning. No dangling threads.

## Merge order
You MAY merge in parallel with stream-A1.
No dependency between A1 and A2 — they touch different files.

## Done when
- cd engine && zig build test — all tests pass, new tests added
  for retry sequence and polling thread lifecycle
- Polling thread starts after webhook failure
- Polling thread stops cleanly on webhooks_stop
- No panics, no dangling threads, no resource leaks
- PR raised, all checks pass

## Core rules
- Never modify src/
- Your changes are confined to engine/src/github.zig only
- No Swift changes in this stream
