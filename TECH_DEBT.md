# Teammux — Known Technical Debt

## Stream 2 — Zig Engine (v0.2 targets)

| ID  | Module     | Issue                              | Notes                                                        |
|-----|------------|------------------------------------|--------------------------------------------------------------|
| TD1 | bus.zig    | Message retry not implemented      | tm_message_cb is void — retry needs API change in v0.2       |
| TD2 | github.zig | Webhook retry after 5s not done    | Single try + log. Intent documented at line 166.             |
| TD3 | github.zig | 60s polling fallback not done      | Webhook failure degrades silently. TODO at line 199.         |
| TD4 | bus.zig    | git_commit always null in messages | Field exists in log format, rev-parse HEAD call missing.     |

## Notes
- All TD items are non-blocking for v0.1
- TD1 requires tm_message_cb signature change — coordinate with Swift layer
- TD2, TD3 can be added to github.zig independently
- TD4 is a one-line fix: git rev-parse HEAD subprocess call in bus.zig
