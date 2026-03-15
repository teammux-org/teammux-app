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
// tm_pty_send() and tm_pty_fd() are retained as C exports for ABI
// stability but return TM_ERR_UNKNOWN. They are deprecated in favor
// of the callback-based message delivery through bus.zig.
// ─────────────────────────────────────────────────────────

test "pty - stub module compiles" {
    // This module is intentionally minimal.
    // PTY ownership belongs to Ghostty SurfaceView in the Swift layer.
    try std.testing.expect(true);
}
