const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const stringzilla = b.addStaticLibrary(.{
        .name = "StringZilla",
        .target = target,
        .optimize = optimize,
    });
    stringzilla.addIncludePath(b.path("third-party/StringZilla/include/"));
    stringzilla.defineCMacro("SZ_DYNAMIC_DISPATCH", "0");
    stringzilla.defineCMacro("SZ_USE_X86_AVX512", "1");
    stringzilla.defineCMacro("SZ_USE_X86_AVX2", "0");
    stringzilla.defineCMacro("SZ_AVOID_LIBC", "1");
    stringzilla.addCSourceFile(.{
        .file = b.path("third-party/StringZilla/c/lib.c"),
    });
    stringzilla.addCSourceFile(.{
        .file = b.path("c/intr.c"),
    });
    stringzilla.linkLibC();

    const clib = b.addStaticLibrary(.{
        .name = "cex",
        .target = target,
        .optimize = optimize,
    });
    clib.addIncludePath(b.path("c"));
    clib.addCSourceFile(.{ .file = b.path("c/sysops.c") });
    clib.linkLibC();

    // Let's add the main executable we want to build.
    const exe = b.addExecutable(.{
        .name = "rabbit-search",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const yazap = b.dependency("yazap", .{});
    exe.root_module.addImport("yazap", yazap.module("yazap"));

    exe.linkLibC();
    exe.linkLibrary(stringzilla);
    exe.addIncludePath(b.path("c"));
    exe.linkLibrary(clib);

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}
