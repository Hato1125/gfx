//! Records what to draw and replays it through a backend at the end of the
//! frame. Nothing in this file talks to the graphics API.

const std = @import("std");
const types = @import("types.zig");
const text_system = @import("text.zig");
const Backend = @import("backend/gles.zig").Backend;

pub const Color = types.Color;
pub const Corners = types.Corners;
pub const Border = types.Border;
pub const Bounds = types.Bounds;
pub const Rect = types.Rect;
pub const Circle = types.Circle;
pub const Layer = types.Layer;
pub const Point = types.Point;
pub const Extent = types.Extent;
pub const Image = types.Image;
pub const ImageData = types.ImageData;
pub const Picture = types.Picture;
pub const Fit = types.Fit;
pub const Blur = types.Blur;
pub const Effect = types.Effect;
pub const Frame = types.Frame;
pub const Font = types.Font;
pub const FontOptions = types.FontOptions;
pub const Text = types.Text;
pub const TextStyle = types.TextStyle;
pub const TextAlign = types.TextAlign;
pub const Variation = types.Variation;
pub const TextLayout = types.TextLayout;
pub const Caret = types.Caret;

/// Lays text out without a canvas, for measuring before there is anything
/// to draw on. A canvas given the same one draws what it laid out.
pub const TextSystem = text_system.System;

/// Returns the function of the current context with the given name, like
/// `SDL_GL_GetProcAddress` and `eglGetProcAddress`.
pub const Loader = @import("backend/gles_api.zig").Loader;

pub const Options = struct {
    loader: Loader,
    /// Has to outlive the canvas. Null makes the canvas keep its own.
    texts: ?*TextSystem = null,
};

const Instance = types.Instance;

const Clip = struct {
    /// Left, top, right, bottom in pixels.
    bounds: [4]f32,
    /// Top left, top right, bottom right, bottom left.
    radii: [4]f32 = .{ 0, 0, 0, 0 },

    /// What is inside both. Each corner of the result is rounded like the
    /// corner it shares with `a` or `b`, and square if it is only where
    /// two edges happen to cross.
    fn intersect(a: Clip, b: Clip) Clip {
        const bounds: [4]f32 = .{
            @max(a.bounds[0], b.bounds[0]),
            @max(a.bounds[1], b.bounds[1]),
            @min(a.bounds[2], b.bounds[2]),
            @min(a.bounds[3], b.bounds[3]),
        };
        // The horizontal and the vertical edge that meet at each corner.
        const edges = [4][2]usize{
            .{ 0, 1 },
            .{ 2, 1 },
            .{ 2, 3 },
            .{ 0, 3 },
        };
        var radii: [4]f32 = undefined;
        for (&radii, edges, 0..) |*radius, edge, corner| {
            radius.* = 0;
            for ([_]Clip{ a, b }) |source| {
                const shared = source.bounds[edge[0]] == bounds[edge[0]] and
                    source.bounds[edge[1]] == bounds[edge[1]];
                if (shared) radius.* = @max(radius.*, source.radii[corner]);
            }
        }
        return .{ .bounds = bounds, .radii = radii };
    }
};

const State = struct {
    x: f32,
    y: f32,
    clip: Clip,
    layer: usize,
};

const LayerRecord = struct {
    effects: [types.max_effects]Effect = undefined,
    effect_count: usize = 0,
    /// Drawn on its own and laid over the rest afterwards.
    separate: bool,
    /// The layer's own clip, not narrowed by the ones around it.
    clip: Clip,
    /// The clip that was active outside the layer.
    outer_clip: Clip,
    opacity: f32,
    scale: f32,
    origin: [2]f32,
};

/// `at` is the number of instances recorded before the command. `index`
/// names a layer, or for `image` what the backend calls the image that
/// the instances from here on are filled with.
const Command = struct {
    kind: enum {
        layer_begin,
        layer_end,
        image,
    },
    index: usize,
    at: usize,
};

const ImageRecord = struct {
    /// What the backend calls it. Zero marks a slot that is free.
    backend: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

const max_instances = 16384;
const max_layers = 1024;
/// How often one frame can go from drawing one image to drawing another.
const max_image_changes = 2048;

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    texts: *TextSystem,
    /// Whether `texts` was made by `init` and goes away with the canvas.
    owns_texts: bool,
    images: std.ArrayList(ImageRecord) = .empty,
    /// What the backend calls the image that the instances recorded from
    /// now on are filled with. Zero for none.
    bound_image: u32 = 0,
    image_changes: usize = 0,
    scale: f32 = 1,

    instances: []Instance,
    instance_count: usize = 0,
    layers: []LayerRecord,
    layer_count: usize = 0,
    commands: []Command,
    command_count: usize = 0,
    states: [types.max_depth]State = undefined,
    depth: usize = 0,

    /// Needs a current OpenGL ES 3.0 context.
    pub fn init(allocator: std.mem.Allocator, options: Options) !Canvas {
        const instances = try allocator.alloc(Instance, max_instances);
        errdefer allocator.free(instances);

        const layers = try allocator.alloc(LayerRecord, max_layers);
        errdefer allocator.free(layers);

        const commands = try allocator.alloc(Command, max_layers * 2 + max_image_changes);
        errdefer allocator.free(commands);

        const texts = options.texts orelse try allocator.create(TextSystem);
        errdefer if (options.texts == null) allocator.destroy(texts);
        if (options.texts == null) texts.* = try .init(allocator);
        errdefer if (options.texts == null) texts.deinit();
        // The backend starts without textures, whatever was drawn into the
        // atlases before.
        texts.masks.invalidate();
        texts.colors.invalidate();

        return .{
            .allocator = allocator,
            .backend = try Backend.init(options.loader),
            .texts = texts,
            .owns_texts = options.texts == null,
            .instances = instances,
            .layers = layers,
            .commands = commands,
        };
    }

    pub fn deinit(canvas: *Canvas) void {
        for (canvas.images.items) |slot| {
            if (slot.backend != 0) canvas.backend.destroyImage(slot.backend);
        }
        canvas.images.deinit(canvas.allocator);
        canvas.backend.deinit();
        if (canvas.owns_texts) {
            canvas.texts.deinit();
            canvas.allocator.destroy(canvas.texts);
        }
        canvas.allocator.free(canvas.commands);
        canvas.allocator.free(canvas.layers);
        canvas.allocator.free(canvas.instances);
    }

    pub fn begin(canvas: *Canvas, frame: Frame) void {
        canvas.scale = frame.scale;
        canvas.instance_count = 0;
        canvas.bound_image = 0;
        canvas.image_changes = 0;
        canvas.layer_count = 0;
        canvas.command_count = 0;
        canvas.depth = 0;
        canvas.states[0] = .{
            .x = 0,
            .y = 0,
            .clip = .{ .bounds = .{
                0,
                0,
                @floatFromInt(frame.width),
                @floatFromInt(frame.height),
            } },
            .layer = 0,
        };
        canvas.backend.beginFrame(frame.width, frame.height, vector(frame.background));
    }

    pub fn end(canvas: *Canvas) void {
        std.debug.assert(canvas.depth == 0);

        if (canvas.texts.masks.takeUpdate()) |update| canvas.backend.updateAtlas(update);
        if (canvas.texts.colors.takeUpdate()) |update| canvas.backend.updateAtlas(update);

        // A run of instances ends where the image changes and where a
        // layer that is drawn on its own begins or ends.
        var drawn: usize = 0;
        var bound: u32 = 0;
        for (canvas.commands[0..canvas.command_count]) |command| {
            if (command.kind == .image) {
                canvas.backend.draw(canvas.instances[drawn..command.at], bound);
                drawn = command.at;
                bound = @intCast(command.index);
                continue;
            }
            const layer = canvas.layers[command.index];
            if (!layer.separate) continue;

            canvas.backend.draw(canvas.instances[drawn..command.at], bound);
            drawn = command.at;
            switch (command.kind) {
                .image => unreachable,
                .layer_begin => canvas.backend.beginLayer(),
                .layer_end => canvas.backend.endLayer(layer.effects[0..layer.effect_count], .{
                    .clip = layer.clip.bounds,
                    .clip_radii = layer.clip.radii,
                    .outer_clip = layer.outer_clip.bounds,
                    .outer_clip_radii = layer.outer_clip.radii,
                    .opacity = layer.opacity,
                    .scale = layer.scale,
                    .origin = layer.origin,
                }),
            }
        }
        canvas.backend.draw(canvas.instances[drawn..canvas.instance_count], bound);
        canvas.texts.endFrame();
    }

    /// Copies `data`, which can be let go of when this returns.
    pub fn createImage(canvas: *Canvas, data: ImageData) !Image {
        std.debug.assert(data.pixels.len == @as(usize, data.width) * data.height * 4);
        const allocator = canvas.allocator;

        // Everything is blended with the colors already multiplied by the
        // alpha, so the image is brought into that form once, here.
        const pixels = try allocator.alloc(u8, data.pixels.len);
        defer allocator.free(pixels);
        var offset: usize = 0;
        while (offset < pixels.len) : (offset += 4) {
            const alpha: u32 = data.pixels[offset + 3];
            for (0..3) |channel| {
                const value: u32 = data.pixels[offset + channel];
                pixels[offset + channel] = @intCast((value * alpha + 127) / 255);
            }
            pixels[offset + 3] = @intCast(alpha);
        }

        const created: ImageRecord = .{
            .backend = canvas.backend.createImage(data.width, data.height, pixels),
            .width = data.width,
            .height = data.height,
        };
        for (canvas.images.items, 0..) |*slot, index| {
            if (slot.backend != 0) continue;
            slot.* = created;
            return @enumFromInt(index);
        }
        try canvas.images.append(allocator, created);
        return @enumFromInt(canvas.images.items.len - 1);
    }

    /// Not while a frame that draws the image is still open.
    pub fn destroyImage(canvas: *Canvas, handle: Image) void {
        const slot = &canvas.images.items[@intFromEnum(handle)];
        canvas.backend.destroyImage(slot.backend);
        slot.* = .{};
    }

    /// In the pixels of the image.
    pub fn imageSize(canvas: *Canvas, handle: Image) Extent {
        const slot = canvas.images.items[@intFromEnum(handle)];
        return .{ .width = @floatFromInt(slot.width), .height = @floatFromInt(slot.height) };
    }

    pub fn image(canvas: *Canvas, p: Picture) void {
        if (canvas.instance_count == max_instances) {
            std.log.err("canvas: more than {d} shapes in one frame", .{max_instances});
            return;
        }
        const slot = canvas.images.items[@intFromEnum(p.image)];
        if (slot.backend == 0 or p.width <= 0 or p.height <= 0) return;

        // The part of the image to show, and the part of the box to show
        // it in. Each fit narrows at most one of the two.
        var box: Bounds = .{ .x = p.x, .y = p.y, .width = p.width, .height = p.height };
        var uv: [4]f32 = .{ 0, 0, 1, 1 };
        const image_ratio = @as(f32, @floatFromInt(slot.width)) / @as(f32, @floatFromInt(slot.height));
        const box_ratio = p.width / p.height;
        switch (p.fit) {
            .fill => {},
            .contain => if (image_ratio > box_ratio) {
                box.height = p.width / image_ratio;
                box.y += (p.height - box.height) / 2;
            } else {
                box.width = p.height * image_ratio;
                box.x += (p.width - box.width) / 2;
            },
            .cover => if (image_ratio > box_ratio) {
                const shown = box_ratio / image_ratio;
                uv[0] = (1 - shown) / 2;
                uv[2] = 1 - uv[0];
            } else {
                const shown = image_ratio / box_ratio;
                uv[1] = (1 - shown) / 2;
                uv[3] = 1 - uv[1];
            },
        }

        if (canvas.bound_image != slot.backend) {
            if (canvas.image_changes == max_image_changes) {
                std.log.err("canvas: more than {d} changes of image in one frame", .{max_image_changes});
                return;
            }
            canvas.image_changes += 1;
            canvas.bound_image = slot.backend;
            canvas.record(.image, slot.backend);
        }

        const state = canvas.states[canvas.depth];
        const s = canvas.scale;
        const width = box.width * s;
        const height = box.height * s;
        const limit = @min(width, height) / 2;
        canvas.instances[canvas.instance_count] = .{
            .rect = .{ state.x + box.x * s, state.y + box.y * s, width, height },
            .fill = .{ 1, 1, 1, p.opacity },
            .radii = .{
                @min(p.corners.top_left * s, limit),
                @min(p.corners.top_right * s, limit),
                @min(p.corners.bottom_right * s, limit),
                @min(p.corners.bottom_left * s, limit),
            },
            .border_color = vector(p.border.color),
            .clip = state.clip.bounds,
            .clip_radii = state.clip.radii,
            .border_width = p.border.width * s,
            .uv = uv,
            .kind = Instance.kind_image,
        };
        canvas.instance_count += 1;
    }

    pub fn loadFont(canvas: *Canvas, path: [:0]const u8, options: FontOptions) !Font {
        return canvas.texts.loadFont(path, options);
    }

    /// Lays `string` out for the scale of the last `begin`. The canvas
    /// keeps the layout for as long as it is asked for every few frames,
    /// so call this again each frame rather than holding on to the result.
    /// Null if the style names no font or there is no memory left.
    pub fn textLayout(canvas: *Canvas, string: []const u8, style: TextStyle) ?*TextLayout {
        return canvas.texts.cached(string, style, canvas.scale);
    }

    /// Like `textLayout`, but the layout belongs to the caller, who gives
    /// it to `destroyTextLayout` when done. Worth it for text that stays
    /// the same over many frames: nothing is looked up to draw it.
    pub fn createTextLayout(canvas: *Canvas, string: []const u8, style: TextStyle) !*TextLayout {
        return canvas.texts.create(string, style, canvas.scale);
    }

    pub fn destroyTextLayout(canvas: *Canvas, layout: *TextLayout) void {
        canvas.texts.destroy(layout);
    }

    pub fn text(canvas: *Canvas, t: Text) void {
        const layout = t.layout;
        canvas.texts.prepare(layout);
        if (canvas.instance_count + layout.glyphs.len > max_instances) {
            std.log.err("canvas: more than {d} shapes in one frame", .{max_instances});
            return;
        }

        // Glyphs are drawn for whole pixels, so the layout starts on one.
        const state = canvas.states[canvas.depth];
        const left = @round(state.x + t.x * canvas.scale);
        const top = @round(state.y + t.y * canvas.scale);
        const fill = vector(t.color);

        for (layout.glyphs) |glyph| {
            canvas.instances[canvas.instance_count] = .{
                .rect = .{ left + glyph.x, top + glyph.y, glyph.width, glyph.height },
                .fill = fill,
                .radii = .{ 0, 0, 0, 0 },
                .border_color = .{ 0, 0, 0, 0 },
                .clip = state.clip.bounds,
                .clip_radii = state.clip.radii,
                .uv = .{
                    glyph.atlas_x,
                    glyph.atlas_y,
                    glyph.atlas_x + glyph.width,
                    glyph.atlas_y + glyph.height,
                },
                .kind = glyph.kind,
            };
            canvas.instance_count += 1;
        }
    }

    pub fn rect(canvas: *Canvas, r: Rect) void {
        if (canvas.instance_count == max_instances) {
            std.log.err("canvas: more than {d} shapes in one frame", .{max_instances});
            return;
        }

        const state = canvas.states[canvas.depth];
        const s = canvas.scale;
        const width = r.width * s;
        const height = r.height * s;
        const limit = @min(width, height) / 2;

        canvas.instances[canvas.instance_count] = .{
            .rect = .{ state.x + r.x * s, state.y + r.y * s, width, height },
            .fill = vector(r.color),
            .radii = .{
                @min(r.corners.top_left * s, limit),
                @min(r.corners.top_right * s, limit),
                @min(r.corners.bottom_right * s, limit),
                @min(r.corners.bottom_left * s, limit),
            },
            .border_color = vector(r.border.color),
            .clip = state.clip.bounds,
            .clip_radii = state.clip.radii,
            .border_width = r.border.width * s,
        };
        canvas.instance_count += 1;
    }

    pub fn circle(canvas: *Canvas, circ: Circle) void {
        canvas.rect(.{
            .x = circ.x - circ.radius,
            .y = circ.y - circ.radius,
            .width = circ.radius * 2,
            .height = circ.radius * 2,
            .color = circ.color,
            .corners = .all(circ.radius),
            .border = circ.border,
        });
    }

    pub fn push(canvas: *Canvas, layer: Layer) void {
        std.debug.assert(canvas.depth + 1 < types.max_depth);
        std.debug.assert(canvas.layer_count < max_layers);

        const parent = canvas.states[canvas.depth];
        const frame = canvas.states[0].clip;
        const s = canvas.scale;
        const x = parent.x + layer.x * s;
        const y = parent.y + layer.y * s;

        var own = frame;
        if (layer.clip) |clip| {
            const left = x + clip.x * s;
            const top = y + clip.y * s;
            const limit = @min(clip.width, clip.height) * s / 2;
            own = .{
                .bounds = .{
                    left,
                    top,
                    left + clip.width * s,
                    top + clip.height * s,
                },
                .radii = .{
                    @min(layer.corners.top_left * s, limit),
                    @min(layer.corners.top_right * s, limit),
                    @min(layer.corners.bottom_right * s, limit),
                    @min(layer.corners.bottom_left * s, limit),
                },
            };
        }

        const record_index = canvas.layer_count;
        canvas.layers[record_index] = .{
            .separate = layer.opacity < 1 or layer.scale != 1,
            .clip = own,
            .outer_clip = parent.clip,
            .opacity = layer.opacity,
            .scale = layer.scale,
            .origin = .{ x + layer.origin.x * s, y + layer.origin.y * s },
        };
        canvas.layer_count += 1;
        canvas.record(.layer_begin, record_index);

        canvas.depth += 1;
        canvas.states[canvas.depth] = .{
            .x = x,
            .y = y,
            // A separate layer is clipped when it is laid over the rest,
            // so nothing inside it has to be.
            .clip = if (canvas.layers[record_index].separate) frame else parent.clip.intersect(own),
            .layer = record_index,
        };
    }

    pub fn pop(canvas: *Canvas) void {
        std.debug.assert(canvas.depth > 0);
        canvas.record(.layer_end, canvas.states[canvas.depth].layer);
        canvas.depth -= 1;
    }

    /// Adds an effect to the layer opened by the innermost `push`. Call it
    /// before drawing into the layer. Effects run in the order they were
    /// added, when the layer is popped.
    pub fn effect(canvas: *Canvas, e: Effect) void {
        std.debug.assert(canvas.depth > 0);

        const state = &canvas.states[canvas.depth];
        const layer = &canvas.layers[state.layer];
        std.debug.assert(layer.effect_count < types.max_effects);
        layer.effects[layer.effect_count] = switch (e) {
            .blur => |blur| .{ .blur = .{ .sigma = blur.sigma * canvas.scale } },
        };
        layer.effect_count += 1;

        layer.separate = true;
        state.clip = canvas.states[0].clip;
    }

    fn record(canvas: *Canvas, kind: @FieldType(Command, "kind"), index: usize) void {
        canvas.commands[canvas.command_count] = .{
            .kind = kind,
            .index = index,
            .at = canvas.instance_count,
        };
        canvas.command_count += 1;
    }
};

/// The parts of a color as the shader takes them, from 0 to 1.
fn vector(color: Color) [4]f32 {
    return .{
        @as(f32, @floatFromInt(color.r)) / 255.0,
        @as(f32, @floatFromInt(color.g)) / 255.0,
        @as(f32, @floatFromInt(color.b)) / 255.0,
        @as(f32, @floatFromInt(color.a)) / 255.0,
    };
}
