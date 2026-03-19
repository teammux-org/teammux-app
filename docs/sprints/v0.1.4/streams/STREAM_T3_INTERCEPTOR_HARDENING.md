# Stream T3 — TD19 + TD17 + Push-to-Main Interceptor Hardening

## Your branch
feat/v014-t3-interceptor-hardening

## Your worktree path
../teammux-stream-t3

## Read first
- CLAUDE.md — hard rules, build commands, sprint workflow
- TECH_DEBT.md — TD17 (stash/apply bypass) and TD19 (exit code) are your targets
- V014_SPRINT.md — full sprint spec, Section 4 has your detailed scope

## Your mission

**Files:** engine/src/interceptor.zig only

**Three additions to bash wrapper template:**

TD19 — exit 126: Change `exit 1` to `exit 126` in ALL enforcement blocks (add block, commit -a block). Both blocks updated.

TD17 — stash/apply interception: New block after commit block:
```bash
elif [[ "$subcmd" == "stash" ]]; then
  for arg in "$@"; do
    case "$arg" in
      pop|apply)
        if [[ ${#DENY_PATTERNS[@]} -gt 0 ]]; then
          echo "[Teammux] Cannot $arg stash with write restrictions."
          echo "[Teammux] Your write scope: $WRITE_SCOPE"
          exit 126
        fi
        ;;
    esac
  done
elif [[ "$subcmd" == "apply" ]]; then
  if [[ ${#DENY_PATTERNS[@]} -gt 0 ]]; then
    echo "[Teammux] Cannot git apply with write restrictions."
    echo "[Teammux] Your write scope: $WRITE_SCOPE"
    exit 126
  fi
fi
```

Push-to-main block: New block detecting git push targeting main:
```bash
elif [[ "$subcmd" == "push" ]]; then
  for arg in "$@"; do
    case "$arg" in
      main|master)
        echo "[Teammux] Cannot push directly to main."
        echo "[Teammux] Use /teammux-pr-ready to signal task completion."
        exit 126
        ;;
    esac
  done
fi
```
git push origin teammux/* passes through. Bare git push with no remote/branch passes through (tracking branch safety deferred).

**Tests:** exit 126 on add enforcement, exit 126 on commit -a enforcement, git stash pop blocked, git stash apply blocked, git apply blocked, git push main blocked, git push origin teammux/worker-2 passes, git stash push passes.

## Message type registry (v0.1.4 additions)

Existing types (do not reuse):
- TM_MSG_TASK=0, TM_MSG_INSTRUCTION=1, TM_MSG_CONTEXT=2, TM_MSG_STATUS_REQ=3
- TM_MSG_STATUS_RPT=4, TM_MSG_COMPLETION=5, TM_MSG_ERROR=6, TM_MSG_BROADCAST=7
- TM_MSG_QUESTION=8, TM_MSG_DISPATCH=10, TM_MSG_RESPONSE=11

New in v0.1.4:
- TM_MSG_PEER_QUESTION = 12 (T2)
- TM_MSG_DELEGATION = 13 (T2)
- TM_MSG_PR_READY = 14 (T7)
- TM_MSG_PR_STATUS = 15 (T7)

## Merge order context
Wave 1 (parallel) — you can START NOW, no dependencies.
T1-T7 merge first, then Wave 2 (T8-T12), Wave 3 (T13-T15), T16 last.

## Done when
- zig build test all pass, all new tests present
- All enforcement blocks use exit 126
- stash/apply/push-main blocked correctly
- PR raised from feat/v014-t3-interceptor-hardening

## Core rules
- Never modify src/ (Ghostty upstream)
- All tm_* calls go through EngineClient.swift only
- No force-unwraps in production code
- zig build test must pass before raising PR
- engine/include/teammux.h is the authoritative C API contract
- roles/ is local only — no external network fetching
- TECH_DEBT.md updated when new debt discovered
- Message type values: do NOT reuse or skip — check registry above
