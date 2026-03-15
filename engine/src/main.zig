const std = @import("std");

// Module imports — stubs until individually implemented
pub const config = @import("config.zig");
pub const worktree = @import("worktree.zig");
pub const pty_mod = @import("pty.zig");
pub const bus = @import("bus.zig");
pub const github = @import("github.zig");
pub const commands = @import("commands.zig");

// C export: engine version
export fn tm_version() [*:0]const u8 {
    return "0.1.0";
}

test "version returns 0.1.0" {
    const v = tm_version();
    const slice = std.mem.span(v);
    try std.testing.expectEqualStrings("0.1.0", slice);
}
