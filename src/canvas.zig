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

const Instance = types.Instance;

const State = struct {
    x: f32,
    y: f32,
    clip: [4]f32,
    layer: usize,
};

const LayerRecord = struct {
    effects: [types.max_effects]Effect = undefined,
    effect_count: usize = 0,
    /// The clip that was active outside the layer.
    clip: [4]f32,
};

/// `at` is the number of instances recorded before the boundary.
const Command = struct {
    kind: enum {
        layer_begin,
        layer_end,
    },
    layer: usize,
    at: usize,
};

const max_instances = 16384;
const max_layers = 1024;

pub const Canvas = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    texts: text_system.System,
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
    pub fn init(allocator: std.mem.Allocator) !Canvas {
        const instances = try allocator.alloc(Instance, max_instances);
        errdefer allocator.free(instances);

        const layers = try allocator.alloc(LayerRecord, max_layers);
        errdefer allocator.free(layers);

        const commands = try allocator.alloc(Command, max_layers * 2);
        errdefer allocator.free(commands);

        var texts: text_system.System = try .init(allocator);
        errdefer texts.deinit();

        return .{
            .allocator = allocator,
            .backend = try Backend.init(),
            .texts = texts,
            .instances = instances,
            .layers = layers,
            .commands = commands,
        };
    }

    pub fn deinit(canvas: *Canvas) void {
        canvas.backend.deinit();
        canvas.texts.deinit();
        canvas.allocator.free(canvas.commands);
        canvas.allocator.free(canvas.layers);
        canvas.allocator.free(canvas.instances);
    }

    pub fn begin(canvas: *Canvas, frame: Frame) void {
        canvas.scale = frame.scale;
        canvas.instance_count = 0;
        canvas.layer_count = 0;
        canvas.command_count = 0;
        canvas.depth = 0;
        canvas.states[0] = .{
            .x = 0,
            .y = 0,
            .clip = .{
                0,
                0,
                @floatFromInt(frame.width),
                @floatFromInt(frame.height),
            },
            .layer = 0,
        };
        canvas.backend.beginFrame(frame.width, frame.height, frame.background);
    }

    pub fn end(canvas: *Canvas) void {
        std.debug.assert(canvas.depth == 0);

        if (canvas.texts.masks.takeUpdate()) |update| canvas.backend.updateAtlas(update);
        if (canvas.texts.colors.takeUpdate()) |update| canvas.backend.updateAtlas(update);

        // Only layers with an effect interrupt the run of instances.
        var drawn: usize = 0;
        for (canvas.commands[0..canvas.command_count]) |command| {
            const layer = canvas.layers[command.layer];
            if (layer.effect_count == 0) continue;

            canvas.backend.draw(canvas.instances[drawn..command.at]);
            drawn = command.at;
            switch (command.kind) {
                .layer_begin => canvas.backend.beginLayer(),
                .layer_end => canvas.backend.endLayer(
                    layer.effects[0..layer.effect_count],
                    layer.clip,
                ),
            }
        }
        canvas.backend.draw(canvas.instances[drawn..canvas.instance_count]);
        canvas.texts.endFrame();
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
                .clip = state.clip,
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
            .clip = state.clip,
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
        const s = canvas.scale;
        var state: State = .{
            .x = parent.x + layer.x * s,
            .y = parent.y + layer.y * s,
            .clip = parent.clip,
            .layer = canvas.layer_count,
        };
        if (layer.clip) |clip| {
            const left = state.x + clip.x * s;
            const top = state.y + clip.y * s;
            state.clip = .{
                @max(parent.clip[0], left),
                @max(parent.clip[1], top),
                @min(parent.clip[2], left + clip.width * s),
                @min(parent.clip[3], top + clip.height * s),
            };
        }

        canvas.layers[canvas.layer_count] = .{ .clip = parent.clip };
        canvas.layer_count += 1;
        canvas.record(.layer_begin, state.layer);

        canvas.depth += 1;
        canvas.states[canvas.depth] = state;
    }

    pub fn pop(canvas: *Canvas) void {
        std.debug.assert(canvas.depth > 0);
        canvas.record(.layer_end, canvas.states[canvas.depth].layer);
        canvas.depth -= 1;
    }

    /// Adds an effect to the layer opened by the innermost `push`.
    /// Effects run in the order they were added, when the layer is popped.
    pub fn effect(canvas: *Canvas, e: Effect) void {
        std.debug.assert(canvas.depth > 0);

        const layer = &canvas.layers[canvas.states[canvas.depth].layer];
        std.debug.assert(layer.effect_count < types.max_effects);
        layer.effects[layer.effect_count] = switch (e) {
            .blur => |blur| .{ .blur = .{ .sigma = blur.sigma * canvas.scale } },
        };
        layer.effect_count += 1;
    }

    fn record(canvas: *Canvas, kind: @FieldType(Command, "kind"), layer: usize) void {
        canvas.commands[canvas.command_count] = .{
            .kind = kind,
            .layer = layer,
            .at = canvas.instance_count,
        };
        canvas.command_count += 1;
    }
};

fn vector(color: Color) [4]f32 {
    return .{ color.r, color.g, color.b, color.a };
}
