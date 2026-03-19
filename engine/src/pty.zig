const std = @import("std");

// ─────────────────────────────────────────────────────────
// PTY stub — Ghostty owns PTY via SurfaceView
//
// Architecture decision (2026-03-15): The Zig engine does NOT own
// PTY lifecycle. Ghostty's SurfaceView spawns agent processes via
// SurfaceConfiguration. The engine provides coordination metadata
// only. Text injection to worker terminals happens via tm_message_cb
// callback to Swift, which then injects text into the appropriate
// Ghostty SurfaceView using its input API.
//
// tm_pty_send() and tm_pty_fd() were removed from the C API in the
// dead-code pruning pass. Ghostty's SurfaceView is the sole PTY owner.
// ─────────────────────────────────────────────────────────

test "pty - stub module compiles" {
    // This module is intentionally minimal.
    // PTY ownership belongs to Ghostty SurfaceView in the Swift layer.
    try std.testing.expect(true);
}
