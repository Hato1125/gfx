/// Each part runs from 0 to 255. The alpha is not multiplied into the
/// colors.
pub const Color = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 255,

    pub const black: Color = .{};
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255 };
    pub const transparent: Color = .{ .a = 0 };

    /// Builds an opaque color from 0xRRGGBB.
    pub fn rgb(hex: u24) Color {
        return .{
            .r = @truncate(hex >> 16),
            .g = @truncate(hex >> 8),
            .b = @truncate(hex),
        };
    }

    /// The same color at `opacity`, from 0 to 1.
    pub fn alpha(color: Color, opacity: f32) Color {
        const limited = @min(@max(opacity, 0), 1);
        return .{
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = @intFromFloat(@round(limited * 255)),
        };
    }

    /// The color between `a` and `b` as it is seen. Each color counts by its
    /// alpha, so one that is transparent only lets the other fade and does
    /// not tint it on the way. A color does not go past `b` either: where a
    /// curve overshoots, the color waits at `b`.
    pub fn lerp(a: Color, b: Color, t: f32) Color {
        const progress = @min(@max(t, 0), 1);
        const weight_a = @as(f32, @floatFromInt(a.a)) * (1 - progress);
        const weight_b = @as(f32, @floatFromInt(b.a)) * progress;
        const total = weight_a + weight_b;
        if (total == 0) return .{ .r = b.r, .g = b.g, .b = b.b, .a = 0 };
        return .{
            .r = weighted(a.r, b.r, weight_a, weight_b),
            .g = weighted(a.g, b.g, weight_a, weight_b),
            .b = weighted(a.b, b.b, weight_a, weight_b),
            .a = @intFromFloat(@round(total)),
        };
    }

    fn weighted(a: u8, b: u8, weight_a: f32, weight_b: f32) u8 {
        const sum = @as(f32, @floatFromInt(a)) * weight_a + @as(f32, @floatFromInt(b)) * weight_b;
        return @intFromFloat(@round(sum / (weight_a + weight_b)));
    }
};

pub const Corners = struct {
    top_left: f32 = 0,
    top_right: f32 = 0,
    bottom_right: f32 = 0,
    bottom_left: f32 = 0,

    pub fn all(radius: f32) Corners {
        return .{
            .top_left = radius,
            .top_right = radius,
            .bottom_right = radius,
            .bottom_left = radius,
        };
    }
};

pub const Border = struct {
    width: f32 = 0,
    color: Color = .black,
};

pub const Bounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
};

pub const Rect = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    color: Color = .white,
    corners: Corners = .{},
    border: Border = .{},
};

/// `x` and `y` are the center.
pub const Circle = struct {
    x: f32,
    y: f32,
    radius: f32,
    color: Color = .white,
    border: Border = .{},
};

/// An image made with `Canvas.createImage`.
pub const Image = enum(u32) { _ };

/// `pixels` holds `height` rows of `width` pixels from the top down, four
/// bytes each: red, green, blue and alpha. The colors are not multiplied
/// by the alpha.
pub const ImageData = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

/// What to do when the image and the box it is drawn in differ in shape.
pub const Fit = enum {
    /// Stretch the image over the box.
    fill,
    /// Show all of the image, as large as fits, centered in the box.
    contain,
    /// Cover all of the box, cutting off what sticks out of it.
    cover,
};

/// `corners` and `border` belong to what is drawn, which under `contain`
/// can be smaller than the box.
pub const Picture = struct {
    image: Image,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    fit: Fit = .fill,
    corners: Corners = .{},
    border: Border = .{},
    opacity: f32 = 1,
};

pub const Extent = struct {
    width: f32,
    height: f32,
};

pub const Point = struct {
    x: f32,
    y: f32,
};

/// `x` and `y` move everything drawn until the matching `pop`. The other
/// fields are given in the moved coordinates.
///
/// An opacity under one, a scale other than one and any effect make the
/// layer be drawn on its own first and laid over the rest afterwards. In
/// that case the effects come first, then the clip, the opacity and the
/// scale.
pub const Layer = struct {
    x: f32 = 0,
    y: f32 = 0,
    /// Only ever narrows the clip of the enclosing layer.
    clip: ?Bounds = null,
    /// Rounds the corners of `clip`. Where a clip inside this one cuts a
    /// rounded corner off, the corner it leaves is square.
    corners: Corners = .{},
    /// Applies to the layer as a whole, so shapes that overlap inside it
    /// do not show through each other.
    opacity: f32 = 1,
    /// The layer is shown this many times its size. `origin` stays where
    /// it is.
    scale: f32 = 1,
    origin: Point = .{ .x = 0, .y = 0 },
};

/// How a backend lays a finished layer over what is under it. Everything
/// is in pixels; clips are left, top, right, bottom followed by the radii
/// of the top left, top right, bottom right and bottom left corners.
pub const Composite = struct {
    /// The layer's own clip, before the scale.
    clip: [4]f32,
    clip_radii: [4]f32,
    /// The clip the layer was pushed inside, after the scale.
    outer_clip: [4]f32,
    outer_clip_radii: [4]f32,
    opacity: f32,
    scale: f32,
    origin: [2]f32,
};

/// The standard deviation of the gaussian, in the same unit as coordinates.
pub const Blur = struct {
    sigma: f32,
};

/// A fragment shader made with `Canvas.createShader`.
pub const Shader = enum(u16) { _ };

/// What a shader is made from. The source is GLSL ES 3.0 that defines
///
///     vec4 effect(vec4 source, vec2 uv)
///
/// which gets the color of the layer at `uv`, with the colors multiplied by
/// the alpha and `uv` running from 0 to 1 from the bottom left, and returns
/// the color to show there in the same form. Everything before it is added
/// by the canvas:
///
///     uniform sampler2D source;  // The whole layer, for sampling around.
///     uniform Custom {
///         vec4 params[4];        // Whatever the effect passes.
///         vec2 size;             // The frame in pixels.
///         float time;            // `Frame.time`.
///     };
///
/// The line numbers of a compile error count from the first line of the
/// source.
pub const ShaderSource = struct {
    glsl_es: []const u8,
};

/// The most vec4 values that an effect passes to a shader.
pub const max_shader_params = 4;

/// Runs `shader` over the layer.
pub const ShaderEffect = struct {
    shader: Shader,
    /// The first `max_shader_params` are used; the rest of `params` in the
    /// shader are zero.
    params: []const [4]f32 = &.{},
};

/// Applied to everything drawn between `push` and the matching `pop`.
pub const Effect = union(enum) {
    blur: Blur,
    shader: ShaderEffect,
};

/// An effect as the canvas records it for a backend, in pixels and with the
/// shader looked up.
pub const Pass = union(enum) {
    blur: Blur,
    shader: struct {
        shader: Shader,
        params: [max_shader_params][4]f32,
    },
};

/// A font loaded with `Canvas.loadFont`.
pub const Font = enum(u16) { _ };

pub const FontOptions = struct {
    /// Which face to take from a file that holds several.
    index: u32 = 0,
};

/// A value for one axis of a variable font, such as `"FILL"` or `"wdth"`.
pub const Variation = struct {
    tag: *const [4]u8,
    value: f32,
};

pub const TextAlign = enum { start, center, end };

/// `fonts` are tried in order for every character, so a later one only
/// supplies what the earlier ones lack. `size` is the height of the em box.
pub const TextStyle = struct {
    fonts: []const Font,
    size: f32 = 16,
    /// 400 is regular and 700 is bold. The same as a variation of `"wght"`.
    weight: f32 = 400,
    /// Only variable fonts follow these and `weight`, each as far as its
    /// axes go; any other font is drawn the one way it comes. An axis for
    /// the optical size follows `size` unless it is named here.
    variations: []const Variation = &.{},
    /// The distance from one baseline to the next. Null takes it from the
    /// first font.
    line_height: ?f32 = null,
    /// Added after every character.
    tracking: f32 = 0,
    /// Lines are broken to fit. Null only breaks at line feeds.
    width: ?f32 = null,
    /// Within `width`, or within the longest line when that is null.
    alignment: TextAlign = .start,
};

/// `x` and `y` are the top left of the layout.
pub const Text = struct {
    x: f32,
    y: f32,
    layout: *TextLayout,
    color: Color = .white,
};

pub const TextLayout = @import("text.zig").Layout;

/// Where the caret stands before a character: the top of the line and how
/// tall the line is.
pub const Caret = struct {
    x: f32,
    y: f32,
    height: f32,
};

/// `width` and `height` are in pixels. Every coordinate passed to the
/// drawing functions is multiplied by `scale` to get pixels.
pub const Frame = struct {
    width: u32,
    height: u32,
    scale: f32 = 1,
    background: Color = .black,
    /// In seconds, for the shaders of effects. Only differences matter.
    time: f32 = 0,
};

/// What the canvas hands to a backend for every rectangle, already in
/// pixels. The field order and sizes are the vertex layout the rectangle
/// shader reads, so both have to change together.
pub const Instance = extern struct {
    rect: [4]f32,
    fill: [4]f32,
    radii: [4]f32,
    border_color: [4]f32,
    /// Left, top, right, bottom.
    clip: [4]f32,
    border_width: f32 = 0,
    /// Where a glyph sits in its atlas: left, top, right, bottom, in pixels
    /// of the atlas.
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    /// One of the `kind_` values. A float because that is what the vertex
    /// layout carries.
    kind: f32 = kind_shape,

    /// The corners of `clip`, in the order of `radii`.
    clip_radii: [4]f32 = .{ 0, 0, 0, 0 },

    pub const kind_shape: f32 = 0;
    /// The mask atlas says how much of each pixel the fill covers.
    pub const kind_glyph: f32 = 1;
    /// The color atlas holds the colors; the fill only gives the opacity.
    pub const kind_color_glyph: f32 = 2;
    /// A shape filled with the image that is bound when it is drawn; `uv`
    /// runs from 0 to 1 over the image and the fill gives the opacity.
    pub const kind_image: f32 = 3;
};

/// A change to a glyph atlas for the backend to mirror in its texture.
/// `pixels` is the whole atlas, row after row. Only the rows from
/// `first_row` up to `end_row` differ from the last update, unless the
/// size changed, in which case everything does.
pub const AtlasUpdate = struct {
    kind: Kind,
    pixels: []const u8,
    width: u32,
    height: u32,
    first_row: u32,
    end_row: u32,

    pub const Kind = enum {
        /// One byte per pixel: coverage.
        mask,
        /// Four bytes per pixel: red, green, blue and alpha, with the
        /// colors already multiplied by the alpha.
        color,
    };
};

pub const max_depth = 32;
pub const max_effects = 4;
