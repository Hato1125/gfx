//! OpenGL ES 3.0.

const std = @import("std");
const GL = @import("gles_api.zig");
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
// In the order of the block, which leaves no gaps before any field. The
// fields after `mode` only matter for compositing.
const FilterBlock = extern struct {
    half_texel: [2]f32 = .{ 0, 0 },
    mode: FilterMode,
    scale: f32 = 1,
    size: [2]f32 = .{ 0, 0 },
    origin: [2]f32 = .{ 0, 0 },
    clip: [4]f32 = .{ 0, 0, 0, 0 },
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    outer_clip: [4]f32 = .{ 0, 0, 0, 0 },
    outer_clip_radii: [4]f32 = .{ 0, 0, 0, 0 },
    opacity: f32 = 1,
    padding: [3]f32 = .{ 0, 0, 0 },
};
const FilterMode = enum(i32) { copy, downsample, upsample, composite };

const frame_binding = 0;
const filter_binding = 1;

/// An offscreen image.
const Target = struct {
    framebuffer: GL.Uint = 0,
    texture: GL.Uint = 0,
    width: u32 = 0,
    height: u32 = 0,
};

pub const Backend = struct {
    gl: GL.Functions,

    rect_program: GL.Uint,
    rect_vao: GL.Uint,
    rect_vbo: GL.Uint,
    frame_block: GL.Uint,

    effect_program: GL.Uint,
    /// Kept so that drawing the effect quad does not run with the
    /// rectangle's attributes enabled.
    effect_vao: GL.Uint,
    filter_block: GL.Uint,

    /// Mirror the glyph atlases, in the order of `AtlasUpdate.Kind`. The
    /// textures are zero until the first update.
    atlases: [2]Target = @splat(.{}),

    width: u32 = 0,
    height: u32 = 0,
    screen: GL.Uint = 0,

    open: usize = 0,

    targets: [types.max_depth]Target = @splat(.{}),
    levels: [blur.max_passes]Target = @splat(.{}),

    /// Needs an OpenGL ES 3.0 context to be current, and `loader` to return
    /// its functions.
    pub fn init(loader: GL.Loader) !Backend {
        const table = try GL.Functions.load(loader);
        const gl = &table;

        const rect_program = try createProgram(gl, rect_vertex, rect_fragment);
        errdefer gl.DeleteProgram(rect_program);
        try bindBlock(gl, rect_program, "SLANG_ParameterGroup_Frame_std140", frame_binding);

        const effect_program = try createProgram(gl, effect_vertex, effect_fragment);
        errdefer gl.DeleteProgram(effect_program);
        try bindBlock(gl, effect_program, "SLANG_ParameterGroup_Filter_std140", filter_binding);
        gl.UseProgram(effect_program);
        gl.Uniform1i(gl.GetUniformLocation(effect_program, "source"), 0);
        gl.UseProgram(rect_program);
        gl.Uniform1i(gl.GetUniformLocation(rect_program, "atlas"), 0);
        gl.Uniform1i(gl.GetUniformLocation(rect_program, "color_atlas"), 1);
        gl.Uniform1i(gl.GetUniformLocation(rect_program, "picture"), 2);

        var rect_vao: GL.Uint = 0;
        gl.GenVertexArrays(1, &rect_vao);
        gl.BindVertexArray(rect_vao);

        var rect_vbo: GL.Uint = 0;
        gl.GenBuffers(1, &rect_vbo);
        gl.BindBuffer(GL.ARRAY_BUFFER, rect_vbo);

        inline for (.{
            .{ "rect", 4 },
            .{ "fill", 4 },
            .{ "radii", 4 },
            .{ "border_color", 4 },
            .{ "clip", 4 },
            .{ "border_width", 1 },
            .{ "uv", 4 },
            .{ "kind", 1 },
            .{ "clip_radii", 4 },
        }, 0..) |field, location| {
            gl.VertexAttribPointer(
                location,
                field[1],
                GL.FLOAT,
                GL.FALSE,
                @sizeOf(Instance),
                @ptrFromInt(@offsetOf(Instance, field[0])),
            );
            gl.EnableVertexAttribArray(location);
            gl.VertexAttribDivisor(location, 1);
        }

        var effect_vao: GL.Uint = 0;
        gl.GenVertexArrays(1, &effect_vao);

        return .{
            .gl = table,
            .rect_program = rect_program,
            .rect_vao = rect_vao,
            .rect_vbo = rect_vbo,
            .frame_block = createBlock(gl, FrameBlock, frame_binding),
            .effect_program = effect_program,
            .effect_vao = effect_vao,
            .filter_block = createBlock(gl, FilterBlock, filter_binding),
        };
    }

    pub fn deinit(backend: *Backend) void {
        const gl = &backend.gl;
        backend.deleteTargets();
        for (&backend.atlases) |*atlas| {
            if (atlas.texture != 0) gl.DeleteTextures(1, &atlas.texture);
        }
        gl.DeleteBuffers(1, &backend.filter_block);
        gl.DeleteBuffers(1, &backend.frame_block);
        gl.DeleteVertexArrays(1, &backend.effect_vao);
        gl.DeleteBuffers(1, &backend.rect_vbo);
        gl.DeleteVertexArrays(1, &backend.rect_vao);
        gl.DeleteProgram(backend.effect_program);
        gl.DeleteProgram(backend.rect_program);
    }

    /// Clears whichever framebuffer is bound; that one counts as the screen
    /// until the next call.
    pub fn beginFrame(backend: *Backend, width: u32, height: u32, background: [4]f32) void {
        const gl = &backend.gl;
        if (width != backend.width or height != backend.height) {
            backend.deleteTargets();
            backend.width = width;
            backend.height = height;
        }
        backend.open = 0;

        var screen: GL.Int = 0;
        gl.GetIntegerv(GL.FRAMEBUFFER_BINDING, &screen);
        backend.screen = @intCast(screen);

        gl.Viewport(0, 0, @intCast(width), @intCast(height));
        gl.ClearColor(background[0], background[1], background[2], background[3]);
        gl.Clear(GL.COLOR_BUFFER_BIT);

        const block: FrameBlock = .{
            .viewport = .{ @floatFromInt(width), @floatFromInt(height) },
        };
        gl.BindBuffer(GL.UNIFORM_BUFFER, backend.frame_block);
        gl.BufferSubData(GL.UNIFORM_BUFFER, 0, @sizeOf(FrameBlock), &block);
    }

    /// Brings a texture up to date with the atlas the text system keeps in
    /// memory.
    pub fn updateAtlas(backend: *Backend, update: types.AtlasUpdate) void {
        const gl = &backend.gl;
        const atlas = &backend.atlases[@intFromEnum(update.kind)];
        const internal: GL.Int, const format: GL.Enum = switch (update.kind) {
            .mask => .{ GL.R8, GL.RED },
            .color => .{ GL.RGBA8, GL.RGBA },
        };
        const stride: usize = switch (update.kind) {
            .mask => 1,
            .color => 4,
        };

        // Rows of one byte pixels are not padded to four bytes.
        gl.PixelStorei(GL.UNPACK_ALIGNMENT, 1);
        defer gl.PixelStorei(GL.UNPACK_ALIGNMENT, 4);

        if (atlas.texture == 0) {
            gl.GenTextures(1, &atlas.texture);
            gl.BindTexture(GL.TEXTURE_2D, atlas.texture);
            gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.LINEAR);
            gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.LINEAR);
            gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, GL.CLAMP_TO_EDGE);
            gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, GL.CLAMP_TO_EDGE);
        }
        gl.BindTexture(GL.TEXTURE_2D, atlas.texture);

        // A texture cannot grow, so a new size means a new image.
        if (atlas.width != update.width or atlas.height != update.height) {
            atlas.width = update.width;
            atlas.height = update.height;
            gl.TexImage2D(
                GL.TEXTURE_2D,
                0,
                internal,
                @intCast(update.width),
                @intCast(update.height),
                0,
                format,
                GL.UNSIGNED_BYTE,
                update.pixels.ptr,
            );
            return;
        }

        gl.TexSubImage2D(
            GL.TEXTURE_2D,
            0,
            0,
            @intCast(update.first_row),
            @intCast(update.width),
            @intCast(update.end_row - update.first_row),
            format,
            GL.UNSIGNED_BYTE,
            update.pixels[update.first_row * update.width * stride ..].ptr,
        );
    }

    /// Makes a texture out of `height` rows of `width` RGBA pixels, from the
    /// top down, with the colors already multiplied by the alpha. The
    /// result is what `draw` takes; zero is never returned.
    pub fn createImage(backend: *Backend, width: u32, height: u32, pixels: []const u8) u32 {
        const gl = &backend.gl;
        var texture: GL.Uint = 0;
        gl.GenTextures(1, &texture);
        gl.BindTexture(GL.TEXTURE_2D, texture);
        gl.PixelStorei(GL.UNPACK_ALIGNMENT, 1);
        defer gl.PixelStorei(GL.UNPACK_ALIGNMENT, 4);
        gl.TexImage2D(
            GL.TEXTURE_2D,
            0,
            GL.RGBA8,
            @intCast(width),
            @intCast(height),
            0,
            GL.RGBA,
            GL.UNSIGNED_BYTE,
            pixels.ptr,
        );
        // Smaller copies, so that an image shown small does not shimmer.
        gl.GenerateMipmap(GL.TEXTURE_2D);
        gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.LINEAR_MIPMAP_LINEAR);
        gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.LINEAR);
        gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, GL.CLAMP_TO_EDGE);
        gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, GL.CLAMP_TO_EDGE);
        return texture;
    }

    pub fn destroyImage(backend: *Backend, image: u32) void {
        backend.gl.DeleteTextures(1, &image);
    }

    /// Draws into the innermost open layer, or the screen if there is none.
    /// `image` is what the instances of `kind_image` are filled with; zero
    /// if there are none.
    pub fn draw(backend: *Backend, instances: []const Instance, image: u32) void {
        const gl = &backend.gl;
        if (instances.len == 0) return;

        gl.Enable(GL.BLEND);
        gl.BlendFunc(GL.ONE, GL.ONE_MINUS_SRC_ALPHA);
        gl.UseProgram(backend.rect_program);
        gl.ActiveTexture(GL.TEXTURE2);
        gl.BindTexture(GL.TEXTURE_2D, image);
        gl.ActiveTexture(GL.TEXTURE1);
        gl.BindTexture(GL.TEXTURE_2D, backend.atlases[1].texture);
        gl.ActiveTexture(GL.TEXTURE0);
        gl.BindTexture(GL.TEXTURE_2D, backend.atlases[0].texture);
        gl.BindVertexArray(backend.rect_vao);
        gl.BindBuffer(GL.ARRAY_BUFFER, backend.rect_vbo);
        gl.BufferData(
            GL.ARRAY_BUFFER,
            @intCast(@sizeOf(Instance) * instances.len),
            instances.ptr,
            GL.STREAM_DRAW,
        );
        gl.DrawArraysInstanced(GL.TRIANGLE_STRIP, 0, 4, @intCast(instances.len));
    }

    /// Redirects drawing to a transparent offscreen image.
    pub fn beginLayer(backend: *Backend) void {
        const gl = &backend.gl;
        std.debug.assert(backend.open < types.max_depth);

        const target = &backend.targets[backend.open];
        if (target.texture == 0) target.* = createTarget(gl, backend.width, backend.height);
        backend.open += 1;

        gl.BindFramebuffer(GL.FRAMEBUFFER, target.framebuffer);
        gl.ClearColor(0, 0, 0, 0);
        gl.Clear(GL.COLOR_BUFFER_BIT);
    }

    /// Runs `effects` over the innermost layer and lays the result over
    /// what is underneath.
    pub fn endLayer(backend: *Backend, effects: []const Effect, how: types.Composite) void {
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
        backend.composite(layer, parent, how);
    }

    fn blurTarget(backend: *Backend, target: Target, sigma: f32) void {
        const gl = &backend.gl;
        const plan = blur.plan(sigma, @min(backend.width, backend.height));
        if (plan.passes == 0) return;

        gl.Disable(GL.BLEND);
        var source = target;
        for (0..plan.passes) |index| {
            const level = backend.acquireLevel(index);
            backend.blurPass(source, level, .downsample, plan.offset);
            source = level;
        }

        var index = plan.passes - 1;
        while (index > 0) : (index -= 1) {
            const level = backend.levels[index - 1];
            backend.blurPass(source, level, .upsample, plan.offset);
            source = level;
        }

        if (plan.mix < 1) {
            gl.Enable(GL.BLEND);
            gl.BlendColor(0, 0, 0, plan.mix);
            gl.BlendFunc(GL.CONSTANT_ALPHA, GL.ONE_MINUS_CONSTANT_ALPHA);
        }
        backend.blurPass(source, target, .upsample, plan.offset);
    }

    fn composite(backend: *Backend, source: Target, destination: Target, how: types.Composite) void {
        const gl = &backend.gl;
        // The shader fades the edge of the outer clip; the scissor only
        // spares it the pixels that are far outside.
        const left = @max(0, @floor(how.outer_clip[0]));
        const top = @max(0, @floor(how.outer_clip[1]));
        const right = @ceil(how.outer_clip[2]);
        const bottom = @ceil(how.outer_clip[3]);
        if (right <= left or bottom <= top) return;

        // Scissor counts y from the bottom of the framebuffer.
        const height: f32 = @floatFromInt(backend.height);
        gl.Enable(GL.SCISSOR_TEST);
        defer gl.Disable(GL.SCISSOR_TEST);
        gl.Scissor(
            @intFromFloat(left),
            @intFromFloat(@max(0, height - bottom)),
            @intFromFloat(right - left),
            @intFromFloat(bottom - top),
        );

        gl.Enable(GL.BLEND);
        gl.BlendFunc(GL.ONE, GL.ONE_MINUS_SRC_ALPHA);
        backend.filter(source, destination, .{
            .mode = .composite,
            .scale = how.scale,
            .size = .{
                @floatFromInt(backend.width),
                @floatFromInt(backend.height),
            },
            .origin = how.origin,
            .clip = how.clip,
            .clip_radii = how.clip_radii,
            .outer_clip = how.outer_clip,
            .outer_clip_radii = how.outer_clip_radii,
            .opacity = how.opacity,
        });
    }

    /// One pass of the blur. `offset` is how far apart the samples are.
    fn blurPass(backend: *Backend, source: Target, destination: Target, mode: FilterMode, offset: f32) void {
        const source_width: f32 = @floatFromInt(source.width);
        const source_height: f32 = @floatFromInt(source.height);
        backend.filter(source, destination, .{
            .mode = mode,
            .half_texel = .{
                0.5 / source_width * offset,
                0.5 / source_height * offset,
            },
        });
    }

    /// Fills `destination` with `source` run through the effect shader.
    /// Leaves `destination` bound and the viewport set to its size.
    fn filter(backend: *Backend, source: Target, destination: Target, block: FilterBlock) void {
        const gl = &backend.gl;
        gl.BindBuffer(GL.UNIFORM_BUFFER, backend.filter_block);
        gl.BufferSubData(GL.UNIFORM_BUFFER, 0, @sizeOf(FilterBlock), &block);

        gl.BindFramebuffer(GL.FRAMEBUFFER, destination.framebuffer);
        gl.Viewport(0, 0, @intCast(destination.width), @intCast(destination.height));
        gl.UseProgram(backend.effect_program);
        gl.ActiveTexture(GL.TEXTURE0);
        gl.BindTexture(GL.TEXTURE_2D, source.texture);
        gl.BindVertexArray(backend.effect_vao);
        gl.DrawArrays(GL.TRIANGLE_STRIP, 0, 4);
    }

    fn acquireLevel(backend: *Backend, index: usize) Target {
        const level = &backend.levels[index];
        if (level.texture == 0) {
            const shift: u5 = @intCast(index + 1);
            level.* = createTarget(
                &backend.gl,
                @max(1, backend.width >> shift),
                @max(1, backend.height >> shift),
            );
        }
        return level.*;
    }

    fn deleteTargets(backend: *Backend) void {
        for (&backend.targets) |*target| deleteTarget(&backend.gl, target);
        for (&backend.levels) |*level| deleteTarget(&backend.gl, level);
    }
};

fn createTarget(gl: *const GL.Functions, width: u32, height: u32) Target {
    var target: Target = .{ .width = width, .height = height };

    gl.GenTextures(1, &target.texture);
    gl.BindTexture(GL.TEXTURE_2D, target.texture);
    gl.TexImage2D(
        GL.TEXTURE_2D,
        0,
        GL.RGBA8,
        @intCast(width),
        @intCast(height),
        0,
        GL.RGBA,
        GL.UNSIGNED_BYTE,
        null,
    );
    gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, GL.LINEAR);
    gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, GL.LINEAR);
    gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, GL.CLAMP_TO_EDGE);
    gl.TexParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, GL.CLAMP_TO_EDGE);

    gl.GenFramebuffers(1, &target.framebuffer);
    gl.BindFramebuffer(GL.FRAMEBUFFER, target.framebuffer);
    gl.FramebufferTexture2D(
        GL.FRAMEBUFFER,
        GL.COLOR_ATTACHMENT0,
        GL.TEXTURE_2D,
        target.texture,
        0,
    );
    if (gl.CheckFramebufferStatus(GL.FRAMEBUFFER) != GL.FRAMEBUFFER_COMPLETE) {
        std.log.err("gles: offscreen target is incomplete", .{});
    }
    return target;
}

fn deleteTarget(gl: *const GL.Functions, target: *Target) void {
    if (target.texture == 0) return;
    gl.DeleteFramebuffers(1, &target.framebuffer);
    gl.DeleteTextures(1, &target.texture);
    target.* = .{};
}

/// Allocates a uniform buffer for one `Block` and attaches it to `binding`.
fn createBlock(gl: *const GL.Functions, comptime Block: type, binding: GL.Uint) GL.Uint {
    var buffer: GL.Uint = 0;
    gl.GenBuffers(1, &buffer);
    gl.BindBuffer(GL.UNIFORM_BUFFER, buffer);
    gl.BufferData(GL.UNIFORM_BUFFER, @sizeOf(Block), null, GL.DYNAMIC_DRAW);
    gl.BindBufferBase(GL.UNIFORM_BUFFER, binding, buffer);
    return buffer;
}

/// Points the uniform block `name` of `program` at `binding`.
fn bindBlock(
    gl: *const GL.Functions,
    program: GL.Uint,
    name: [*:0]const u8,
    binding: GL.Uint,
) !void {
    const index = gl.GetUniformBlockIndex(program, name);
    if (index == GL.INVALID_INDEX) {
        std.log.err("gles: shader has no uniform block {s}", .{name});
        return error.ShaderInterface;
    }
    gl.UniformBlockBinding(program, index, binding);
}

fn createProgram(
    gl: *const GL.Functions,
    vertex_source: [*:0]const u8,
    fragment_source: [*:0]const u8,
) !GL.Uint {
    const vertex = try compileShader(gl, GL.VERTEX_SHADER, vertex_source);
    defer gl.DeleteShader(vertex);
    const fragment = try compileShader(gl, GL.FRAGMENT_SHADER, fragment_source);
    defer gl.DeleteShader(fragment);

    const program = gl.CreateProgram();
    gl.AttachShader(program, vertex);
    gl.AttachShader(program, fragment);
    gl.LinkProgram(program);

    var linked: GL.Int = GL.FALSE;
    gl.GetProgramiv(program, GL.LINK_STATUS, &linked);
    if (linked == GL.FALSE) {
        var log: [512:0]u8 = @splat(0);
        gl.GetProgramInfoLog(program, log.len, null, &log);
        std.log.err("gles: link: {s}", .{std.mem.sliceTo(&log, 0)});
        return error.ShaderLink;
    }
    return program;
}

fn compileShader(gl: *const GL.Functions, kind: GL.Enum, source: [*:0]const u8) !GL.Uint {
    const shader = gl.CreateShader(kind);
    gl.ShaderSource(shader, 1, &source, null);
    gl.CompileShader(shader);

    var compiled: GL.Int = GL.FALSE;
    gl.GetShaderiv(shader, GL.COMPILE_STATUS, &compiled);
    if (compiled == GL.FALSE) {
        var log: [512:0]u8 = @splat(0);
        gl.GetShaderInfoLog(shader, log.len, null, &log);
        std.log.err("gles: compile: {s}", .{std.mem.sliceTo(&log, 0)});
        return error.ShaderCompile;
    }
    return shader;
}
