const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const c = translate_c.createModule();

    // FreeType, HarfBuzz and libunibreak come from the system for now.
    const translate_text = b.addTranslateC(.{
        .root_source_file = b.path("src/text.h"),
        .target = target,
        .optimize = optimize,
    });
    const flags = b.run(&.{
        "pkg-config", "--cflags-only-I", "freetype2", "harfbuzz", "libunibreak",
    });
    var include_flags = std.mem.tokenizeAny(u8, flags, " \n");
    while (include_flags.next()) |flag| {
        translate_text.addSystemIncludePath(.{ .cwd_relative = flag["-I".len..] });
    }

    const gfx = b.addModule("gfx", .{
        .root_source_file = b.path("src/canvas.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "c", .module = c },
            .{ .name = "ft", .module = translate_text.createModule() },
        },
    });
    gfx.linkSystemLibrary("freetype2", .{});
    gfx.linkSystemLibrary("harfbuzz", .{});
    gfx.linkSystemLibrary("libunibreak", .{});

    // The GLSL in src/shaders/gles is generated and checked in, so an
    // ordinary build needs neither slangc nor spirv-cross.
    const shaders = b.step("shaders", "Regenerate the GLSL from the Slang sources");
    for ([_][]const u8{ "rect", "effect" }) |name| {
        for ([_]ShaderStage{
            .{ .name = "vertex", .extension = "vert", .varyings = "out" },
            .{ .name = "fragment", .extension = "frag", .varyings = "in" },
        }) |stage| {
            const compile = b.addSystemCommand(&.{"slangc"});
            // Passed as a file so that the step runs again when it changes.
            compile.addFileArg(b.path(b.fmt("src/shaders/{s}.slang", .{name})));
            compile.addArgs(&.{
                "-target", "spirv",
                "-entry",  b.fmt("{s}Main", .{stage.name}),
                "-stage",  stage.name,
                "-o",
            });
            const spirv = compile.addOutputFileArg(b.fmt("{s}.{s}.spv", .{ name, stage.extension }));

            const convert = b.addSystemCommand(&.{ "spirv-cross", "--version", "300", "--es" });
            // GLSL ES 3.00 links the two stages by variable name, and Slang
            // names the two ends differently.
            for (0..16) |location| {
                convert.addArgs(&.{
                    "--rename-interface-variable", stage.varyings,
                    b.fmt("{d}", .{location}),     b.fmt("v{d}", .{location}),
                });
            }
            convert.addFileArg(spirv);
            convert.addArgs(&.{
                "--output",
                b.pathFromRoot(b.fmt("src/shaders/gles/{s}.{s}.glsl", .{ name, stage.extension })),
            });
            convert.has_side_effects = true;
            shaders.dependOn(&convert.step);
        }
    }
}

const ShaderStage = struct {
    name: []const u8,
    extension: []const u8,
    varyings: []const u8,
};
