const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "teammux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const header_install = b.addInstallHeaderFile(
        b.path("include/teammux.h"),
        "teammux.h",
    );
    b.getInstallStep().dependOn(&header_install.step);
    b.installArtifact(lib);
}
