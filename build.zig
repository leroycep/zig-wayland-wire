const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libxkbcommon = b.dependency("libxkbcommon", .{
        .target = target,
        .optimize = optimize,
    });

    const xkbcommon_module = b.createModule(.{
        .root_source_file = .{ .path = "deps/zig-xkbcommon/src/xkbcommon.zig" },
    });
    xkbcommon_module.linkLibrary(libxkbcommon.artifact("xkbcommon"));

    const module = b.addModule("wayland", .{
        .root_source_file = .{ .path = "src/main.zig" },
        .imports = &.{
            .{ .name = "xkbcommon", .module = xkbcommon_module },
        },
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

    const client_connect_raw_exe = b.addExecutable(.{
        .name = "00_client_connect",
        .root_source_file = .{ .path = "examples/00_client_connect.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(client_connect_raw_exe);

    const client_connect_exe = b.addExecutable(.{
        .name = "01_client_connect",
        .root_source_file = .{ .path = "examples/01_client_connect.zig" },
        .target = target,
        .optimize = optimize,
    });
    client_connect_exe.root_module.addImport("wayland", module);
    b.installArtifact(client_connect_exe);

    // Text Editor example
    const text_editor_exe = b.addExecutable(.{
        .name = "10_text_editor",
        .root_source_file = .{ .path = "examples/10_text_editor.zig" },
        .target = target,
        .optimize = optimize,
    });
    text_editor_exe.root_module.addImport("wayland", module);
    text_editor_exe.linkLibC();
    text_editor_exe.addIncludePath(.{ .path = "deps/font8x8/" });
    b.installArtifact(text_editor_exe);
}
