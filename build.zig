const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const additional_system_headers = b.option(std.Build.LazyPath, "additional_system_headers", "Extra system headers path, e.g. emscripten sysroot") orelse null;

    const lib = b.addLibrary(.{
        .name = "wren",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });

    lib.root_module.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{
            "vm/wren_compiler.c",
            "vm/wren_core.c",
            "vm/wren_debug.c",
            "vm/wren_primitive.c",
            "vm/wren_utils.c",
            "vm/wren_value.c",
            "vm/wren_vm.c",
            "optional/wren_opt_meta.c",
            "optional/wren_opt_random.c",
        },
        .flags = &.{"-std=c99"},
    });

    lib.root_module.addIncludePath(b.path("src/include"));
    lib.root_module.addIncludePath(b.path("src/vm"));
    lib.root_module.addIncludePath(b.path("src/optional"));
    lib.root_module.link_libc = true;

    b.installArtifact(lib);

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/include/wren.h"),
        .target = target,
        .optimize = optimize,
    });

    if (additional_system_headers) |headers| {
        translate_c.addSystemIncludePath(headers);
    }

    const mod = b.addModule("wren", .{
        .root_source_file = b.path("src/wren.zig"),
        .imports = &.{
            .{ .name = "c", .module = translate_c.createModule() },
        },
    });
    mod.linkLibrary(lib);
}
