pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    /// Builds an opaque color from 0xRRGGBB.
    pub fn rgb(hex: u24) Color {
        return .{
            .r = channel(hex >> 16),
            .g = channel(hex >> 8),
            .b = channel(hex),
        };
    }

    pub fn alpha(color: Color, a: f32) Color {
        return .{ .r = color.r, .g = color.g, .b = color.b, .a = a };
    }

    fn channel(bits: u24) f32 {
        return @as(f32, @floatFromInt(bits & 0xff)) / 255.0;
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

/// `x` and `y` move everything drawn until the matching `pop`.
/// `clip` is given in the moved coordinates and only ever narrows the
/// clip of the enclosing layer.
pub const Layer = struct {
    x: f32 = 0,
    y: f32 = 0,
    clip: ?Bounds = null,
};

/// The standard deviation of the gaussian, in the same unit as coordinates.
pub const Blur = struct {
    sigma: f32,
};

/// Applied to everything drawn between `push` and the matching `pop`.
pub const Effect = union(enum) {
    blur: Blur,
};

/// `width` and `height` are in pixels. Every coordinate passed to the
/// drawing functions is multiplied by `scale` to get pixels.
pub const Frame = struct {
    width: u32,
    height: u32,
    scale: f32 = 1,
    background: Color = .black,
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
    border_width: f32,
};

pub const max_depth = 32;
pub const max_effects = 4;
