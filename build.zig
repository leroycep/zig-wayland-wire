const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("wayland", .{
        .source_file = .{ .path = "src/main.zig" },
    });

    const lib = b.addStaticLibrary(.{
        .name = "zig-wayland-wire",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const main_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_main_tests = b.addRunArtifact(main_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    const client_connect_exe = b.addExecutable(.{
        .name = "client_connect",
        .root_source_file = .{ .path = "examples/01_client_connect.zig" },
        .target = target,
        .optimize = optimize,
    });
    client_connect_exe.addModule("wayland", module);
    b.installArtifact(client_connect_exe);
}
