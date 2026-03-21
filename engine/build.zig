const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version = b.option([]const u8, "version", "Teammux version string") orelse "dev";

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    root_mod.addOptions("build_options", build_options);

    const lib = b.addLibrary(.{
        .name = "teammux",
        .linkage = .static,
        .root_module = root_mod,
    });

    const header_install = b.addInstallHeaderFile(
        b.path("include/teammux.h"),
        "teammux.h",
    );
    b.getInstallStep().dependOn(&header_install.step);
    b.installArtifact(lib);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addOptions("build_options", build_options);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run engine tests");
    test_step.dependOn(&run_tests.step);
}
