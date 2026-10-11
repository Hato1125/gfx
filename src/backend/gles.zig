//! OpenGL ES 3.0.

const std = @import("std");
const c = @import("c");
const types = @import("../types.zig");
const blur = @import("../blur.zig");

const Color = types.Color;
const Effect = types.Effect;
const Instance = types.Instance;

// Generated from the .slang files by `zig build shaders`.
const rect_vertex = @embedFile("../shaders/gles/rect.vert.glsl");
const rect_fragment = @embedFile("../shaders/gles/rect.frag.glsl");
const effect_vertex = @embedFile("../shaders/gles/effect.vert.glsl");
const effect_fragment = @embedFile("../shaders/gles/effect.frag.glsl");

// The layouts of the `Frame` and `Filter` blocks in the shaders. A uniform
// block is padded to a multiple of 16 bytes.
const FrameBlock = extern struct {
    viewport: [2]f32,
    padding: [2]f32 = .{ 0, 0 },
};
const FilterBlock = extern struct {
    half_texel: [2]f32,
    mode: FilterMode,
    padding: i32 = 0,
};
const FilterMode = enum(i32) { copy, downsample, upsample };

const frame_binding = 0;
const filter_binding = 1;

/// An offscreen image.
const Target = struct {
    framebuffer: c.GLuint = 0,
    texture: c.GLuint = 0,
    width: u32 = 0,
    height: u32 = 0,
};

pub const Backend = struct {
    rect_program: c.GLuint,
    rect_vao: c.GLuint,
    rect_vbo: c.GLuint,
    frame_block: c.GLuint,

    effect_program: c.GLuint,
    /// Kept so that drawing the effect quad does not run with the
    /// rectangle's attributes enabled.
    effect_vao: c.GLuint,
    filter_block: c.GLuint,

    width: u32 = 0,
    height: u32 = 0,
    screen: c.GLuint = 0,

    open: usize = 0,

    targets: [types.max_depth]Target = @splat(.{}),
    levels: [blur.max_passes]Target = @splat(.{}),

    pub fn init() !Backend {
        const rect_program = try createProgram(rect_vertex, rect_fragment);
        errdefer c.glDeleteProgram(rect_program);
        try bindBlock(rect_program, "SLANG_ParameterGroup_Frame_std140", frame_binding);

        const effect_program = try createProgram(effect_vertex, effect_fragment);
        errdefer c.glDeleteProgram(effect_program);
        try bindBlock(effect_program, "SLANG_ParameterGroup_Filter_std140", filter_binding);
        c.glUseProgram(effect_program);
        c.glUniform1i(c.glGetUniformLocation(effect_program, "source"), 0);

        var rect_vao: c.GLuint = 0;
        c.glGenVertexArrays(1, &rect_vao);
        c.glBindVertexArray(rect_vao);

        var rect_vbo: c.GLuint = 0;
        c.glGenBuffers(1, &rect_vbo);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, rect_vbo);

        inline for (.{
            .{ "rect", 4 },
            .{ "fill", 4 },
            .{ "radii", 4 },
            .{ "border_color", 4 },
            .{ "clip", 4 },
            .{ "border_width", 1 },
        }, 0..) |field, location| {
            c.glVertexAttribPointer(
                location,
                field[1],
                c.GL_FLOAT,
                c.GL_FALSE,
                @sizeOf(Instance),
                @ptrFromInt(@offsetOf(Instance, field[0])),
            );
            c.glEnableVertexAttribArray(location);
            c.glVertexAttribDivisor(location, 1);
        }

        var effect_vao: c.GLuint = 0;
        c.glGenVertexArrays(1, &effect_vao);

        return .{
            .rect_program = rect_program,
            .rect_vao = rect_vao,
            .rect_vbo = rect_vbo,
            .frame_block = createBlock(FrameBlock, frame_binding),
            .effect_program = effect_program,
            .effect_vao = effect_vao,
            .filter_block = createBlock(FilterBlock, filter_binding),
        };
    }

    pub fn deinit(backend: *Backend) void {
        backend.deleteTargets();
        c.glDeleteBuffers(1, &backend.filter_block);
        c.glDeleteBuffers(1, &backend.frame_block);
        c.glDeleteVertexArrays(1, &backend.effect_vao);
        c.glDeleteBuffers(1, &backend.rect_vbo);
        c.glDeleteVertexArrays(1, &backend.rect_vao);
        c.glDeleteProgram(backend.effect_program);
        c.glDeleteProgram(backend.rect_program);
    }

    /// Clears whichever framebuffer is bound; that one counts as the screen
    /// until the next call.
    pub fn beginFrame(backend: *Backend, width: u32, height: u32, background: Color) void {
        if (width != backend.width or height != backend.height) {
            backend.deleteTargets();
            backend.width = width;
            backend.height = height;
        }
        backend.open = 0;

        var screen: c.GLint = 0;
        c.glGetIntegerv(c.GL_FRAMEBUFFER_BINDING, &screen);
        backend.screen = @intCast(screen);

        c.glViewport(0, 0, @intCast(width), @intCast(height));
        c.glClearColor(background.r, background.g, background.b, background.a);
        c.glClear(c.GL_COLOR_BUFFER_BIT);

        const block: FrameBlock = .{
            .viewport = .{ @floatFromInt(width), @floatFromInt(height) },
        };
        c.glBindBuffer(c.GL_UNIFORM_BUFFER, backend.frame_block);
        c.glBufferSubData(c.GL_UNIFORM_BUFFER, 0, @sizeOf(FrameBlock), &block);
    }

    /// Draws into the innermost open layer, or the screen if there is none.
    pub fn draw(backend: *Backend, instances: []const Instance) void {
        if (instances.len == 0) return;

        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        c.glUseProgram(backend.rect_program);
        c.glBindVertexArray(backend.rect_vao);
        c.glBindBuffer(c.GL_ARRAY_BUFFER, backend.rect_vbo);
        c.glBufferData(
            c.GL_ARRAY_BUFFER,
            @intCast(@sizeOf(Instance) * instances.len),
            instances.ptr,
            c.GL_STREAM_DRAW,
        );
        c.glDrawArraysInstanced(c.GL_TRIANGLE_STRIP, 0, 4, @intCast(instances.len));
    }

    /// Redirects drawing to a transparent offscreen image.
    pub fn beginLayer(backend: *Backend) void {
        std.debug.assert(backend.open < types.max_depth);

        const target = &backend.targets[backend.open];
        if (target.texture == 0) target.* = createTarget(backend.width, backend.height);
        backend.open += 1;

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, target.framebuffer);
        c.glClearColor(0, 0, 0, 0);
        c.glClear(c.GL_COLOR_BUFFER_BIT);
    }

    /// Runs `effects` over the innermost layer and blends the result onto
    /// what is underneath, inside `clip` (left, top, right, bottom).
    pub fn endLayer(backend: *Backend, effects: []const Effect, clip: [4]f32) void {
        backend.open -= 1;
        const layer = backend.targets[backend.open];

        for (effects) |effect| switch (effect) {
            .blur => |b| backend.blurTarget(layer, b.sigma),
        };

        const parent: Target = .{
            .framebuffer = if (backend.open == 0)
                backend.screen
            else
                backend.targets[backend.open - 1].framebuffer,
            .width = backend.width,
            .height = backend.height,
        };
        backend.composite(layer, parent, clip);
    }

    fn blurTarget(backend: *Backend, target: Target, sigma: f32) void {
        const plan = blur.plan(sigma, @min(backend.width, backend.height));
        if (plan.passes == 0) return;

        c.glDisable(c.GL_BLEND);
        var source = target;
        for (0..plan.passes) |index| {
            const level = backend.acquireLevel(index);
            backend.filter(source, level, .downsample, plan.offset);
            source = level;
        }

        var index = plan.passes - 1;
        while (index > 0) : (index -= 1) {
            const level = backend.levels[index - 1];
            backend.filter(source, level, .upsample, plan.offset);
            source = level;
        }

        if (plan.mix < 1) {
            c.glEnable(c.GL_BLEND);
            c.glBlendColor(0, 0, 0, plan.mix);
            c.glBlendFunc(c.GL_CONSTANT_ALPHA, c.GL_ONE_MINUS_CONSTANT_ALPHA);
        }
        backend.filter(source, target, .upsample, plan.offset);
    }

    fn composite(backend: *Backend, source: Target, destination: Target, clip: [4]f32) void {
        const left = @floor(clip[0]);
        const right = @ceil(clip[2]);
        const top = @floor(clip[1]);
        const bottom = @ceil(clip[3]);

        // Scissor counts y from the bottom of the framebuffer.
        const height: f32 = @floatFromInt(backend.height);
        c.glEnable(c.GL_SCISSOR_TEST);
        defer c.glDisable(c.GL_SCISSOR_TEST);
        c.glScissor(
            @intFromFloat(left),
            @intFromFloat(height - bottom),
            @intFromFloat(@max(0, right - left)),
            @intFromFloat(@max(0, bottom - top)),
        );

        c.glEnable(c.GL_BLEND);
        c.glBlendFunc(c.GL_ONE, c.GL_ONE_MINUS_SRC_ALPHA);
        backend.filter(source, destination, .copy, 0);
    }

    /// Fills `destination` with `source` run through the effect shader.
    /// Leaves `destination` bound and the viewport set to its size.
    fn filter(
        backend: *Backend,
        source: Target,
        destination: Target,
        mode: FilterMode,
        offset: f32,
    ) void {
        const source_width: f32 = @floatFromInt(source.width);
        const source_height: f32 = @floatFromInt(source.height);
        const block: FilterBlock = .{
            .half_texel = .{
                0.5 / source_width * offset,
                0.5 / source_height * offset,
            },
            .mode = mode,
        };
        c.glBindBuffer(c.GL_UNIFORM_BUFFER, backend.filter_block);
        c.glBufferSubData(c.GL_UNIFORM_BUFFER, 0, @sizeOf(FilterBlock), &block);

        c.glBindFramebuffer(c.GL_FRAMEBUFFER, destination.framebuffer);
        c.glViewport(0, 0, @intCast(destination.width), @intCast(destination.height));
        c.glUseProgram(backend.effect_program);
        c.glActiveTexture(c.GL_TEXTURE0);
        c.glBindTexture(c.GL_TEXTURE_2D, source.texture);
        c.glBindVertexArray(backend.effect_vao);
        c.glDrawArrays(c.GL_TRIANGLE_STRIP, 0, 4);
    }

    fn acquireLevel(backend: *Backend, index: usize) Target {
        const level = &backend.levels[index];
        if (level.texture == 0) {
            const shift: u5 = @intCast(index + 1);
            level.* = createTarget(
                @max(1, backend.width >> shift),
                @max(1, backend.height >> shift),
            );
        }
        return level.*;
    }

    fn deleteTargets(backend: *Backend) void {
        for (&backend.targets) |*target| deleteTarget(target);
        for (&backend.levels) |*level| deleteTarget(level);
    }
};

fn createTarget(width: u32, height: u32) Target {
    var target: Target = .{ .width = width, .height = height };

    c.glGenTextures(1, &target.texture);
    c.glBindTexture(c.GL_TEXTURE_2D, target.texture);
    c.glTexImage2D(
        c.GL_TEXTURE_2D,
        0,
        c.GL_RGBA8,
        @intCast(width),
        @intCast(height),
        0,
        c.GL_RGBA,
        c.GL_UNSIGNED_BYTE,
        null,
    );
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);

    c.glGenFramebuffers(1, &target.framebuffer);
    c.glBindFramebuffer(c.GL_FRAMEBUFFER, target.framebuffer);
    c.glFramebufferTexture2D(
        c.GL_FRAMEBUFFER,
        c.GL_COLOR_ATTACHMENT0,
        c.GL_TEXTURE_2D,
        target.texture,
        0,
    );
    if (c.glCheckFramebufferStatus(c.GL_FRAMEBUFFER) != c.GL_FRAMEBUFFER_COMPLETE) {
        std.log.err("gles: offscreen target is incomplete", .{});
    }
    return target;
}

fn deleteTarget(target: *Target) void {
    if (target.texture == 0) return;
    c.glDeleteFramebuffers(1, &target.framebuffer);
    c.glDeleteTextures(1, &target.texture);
    target.* = .{};
}

/// Allocates a uniform buffer for one `Block` and attaches it to `binding`.
fn createBlock(comptime Block: type, binding: c.GLuint) c.GLuint {
    var buffer: c.GLuint = 0;
    c.glGenBuffers(1, &buffer);
    c.glBindBuffer(c.GL_UNIFORM_BUFFER, buffer);
    c.glBufferData(c.GL_UNIFORM_BUFFER, @sizeOf(Block), null, c.GL_DYNAMIC_DRAW);
    c.glBindBufferBase(c.GL_UNIFORM_BUFFER, binding, buffer);
    return buffer;
}

/// Points the uniform block `name` of `program` at `binding`.
fn bindBlock(program: c.GLuint, name: [*:0]const u8, binding: c.GLuint) !void {
    const index = c.glGetUniformBlockIndex(program, name);
    if (index == c.GL_INVALID_INDEX) {
        std.log.err("gles: shader has no uniform block {s}", .{name});
        return error.ShaderInterface;
    }
    c.glUniformBlockBinding(program, index, binding);
}

fn createProgram(
    vertex_source: [*:0]const u8,
    fragment_source: [*:0]const u8,
) !c.GLuint {
    const vertex = try compileShader(c.GL_VERTEX_SHADER, vertex_source);
    defer c.glDeleteShader(vertex);
    const fragment = try compileShader(c.GL_FRAGMENT_SHADER, fragment_source);
    defer c.glDeleteShader(fragment);

    const program = c.glCreateProgram();
    c.glAttachShader(program, vertex);
    c.glAttachShader(program, fragment);
    c.glLinkProgram(program);

    var linked: c.GLint = c.GL_FALSE;
    c.glGetProgramiv(program, c.GL_LINK_STATUS, &linked);
    if (linked == c.GL_FALSE) {
        var log: [512:0]u8 = @splat(0);
        c.glGetProgramInfoLog(program, log.len, null, &log);
        std.log.err("gles: link: {s}", .{std.mem.sliceTo(&log, 0)});
        return error.ShaderLink;
    }
    return program;
}

fn compileShader(kind: c.GLenum, source: [*:0]const u8) !c.GLuint {
    const shader = c.glCreateShader(kind);
    c.glShaderSource(shader, 1, &source, null);
    c.glCompileShader(shader);

    var compiled: c.GLint = c.GL_FALSE;
    c.glGetShaderiv(shader, c.GL_COMPILE_STATUS, &compiled);
    if (compiled == c.GL_FALSE) {
        var log: [512:0]u8 = @splat(0);
        c.glGetShaderInfoLog(shader, log.len, null, &log);
        std.log.err("gles: compile: {s}", .{std.mem.sliceTo(&log, 0)});
        return error.ShaderCompile;
    }
    return shader;
}
