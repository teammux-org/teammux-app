const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

<<<<<<< HEAD
    // Static library: libteammux.a
    const lib = b.addLibrary(.{
        .name = "teammux",
        .root_module = root_mod,
    });
    b.installArtifact(lib);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

=======
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
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

>>>>>>> abfbb7bc5d35c3e5529ab15c7d9616a49aee0de6
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run engine tests");
    test_step.dependOn(&run_tests.step);
}
