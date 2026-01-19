const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string") orelse "dev";
    const output = b.option([]const u8, "output", "Custom output path (e.g., dist/quizzig-Linux-x86_64)");

    const pcre2_dep = b.dependency("pcre2", .{
        .target = target,
        .optimize = optimize,
    });
    const pcre2_lib = pcre2_dep.artifact("pcre2-8");

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    // Main executable
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    exe_mod.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "quizzig",
        .root_module = exe_mod,
    });
    exe.linkLibrary(pcre2_lib);

    const opt = b.dependency("opt", .{});
    exe.root_module.addImport("opt", opt.module("opt"));

    if (output) |out_path| {
        const install = b.addInstallFileWithDir(exe.getEmittedBin(), .prefix, out_path);
        b.getInstallStep().dependOn(&install.step);
    } else {
        b.installArtifact(exe);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run quizzig");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    unit_tests.linkLibrary(pcre2_lib);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
