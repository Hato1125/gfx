const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // FreeType, HarfBuzz and libunibreak are built from source, so that
    // nothing has to be installed to build this.
    // They are optimized whatever the rest is built as: unoptimized, laying
    // text out and drawing glyphs takes about twice as long.
    const library_optimize: std.builtin.OptimizeMode =
        if (optimize == .Debug) .ReleaseFast else optimize;
    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = library_optimize,
        // The bitmaps of color emoji are stored as PNG.
        .@"enable-libpng" = true,
    });
    const harfbuzz = b.dependency("harfbuzz", .{
        .target = target,
        .optimize = library_optimize,
    });
    const unibreak_source = b.dependency("libunibreak", .{}).path("src");
    const unibreak = b.addLibrary(.{
        .name = "unibreak",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = library_optimize,
            .link_libc = true,
        }),
    });
    unibreak.root_module.addCSourceFiles(.{
        .root = unibreak_source,
        .files = &.{
            "unibreakbase.c",
            "unibreakdef.c",
            "linebreak.c",
            "linebreakdata.c",
            "linebreakdef.c",
            "eastasianwidthdef.c",
            "emojidef.c",
            "graphemebreak.c",
            "wordbreak.c",
        },
    });

    const translate_text = b.addTranslateC(.{
        .root_source_file = b.path("src/text.h"),
        .target = target,
        .optimize = optimize,
    });
    // The packages wrap the original sources, which hold the headers.
    translate_text.addIncludePath(freetype.builder.dependency("freetype", .{}).path("include"));
    translate_text.addIncludePath(harfbuzz.builder.dependency("harfbuzz", .{}).path("src"));
    translate_text.addIncludePath(unibreak_source);

    const gfx = b.addModule("gfx", .{
        .root_source_file = b.path("src/canvas.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ft", .module = translate_text.createModule() },
        },
    });
    gfx.linkLibrary(harfbuzz.artifact("harfbuzz"));
    gfx.linkLibrary(freetype.artifact("freetype"));
    gfx.linkLibrary(unibreak);

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
            compile.addFileInput(b.path("src/shaders/sdf.slang"));
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
