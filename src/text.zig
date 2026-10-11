//! Turns strings into glyphs placed in an atlas. FreeType draws the glyphs,
//! HarfBuzz decides which ones a string needs and where they go, and
//! libunibreak says where a line may end. All three are slow, so every
//! result is kept and reused. Nothing here knows about the graphics API.
//!
//! Text runs left to right only.

const std = @import("std");
const ft = @import("ft");
const types = @import("types.zig");
const Atlas = @import("atlas.zig").Atlas;

const Font = types.Font;
const Instance = types.Instance;

// Hinting only snaps glyphs to the pixel grid vertically. Stems stay where
// the font put them, which keeps the spacing of a line independent of size.
const load_flags: c_int = ft.FT_LOAD_DEFAULT | (ft.FT_RENDER_MODE_LIGHT << 16);

/// How many frames a layout made by `System.cached` survives without being
/// asked for again, and how often the unused ones are looked for.
const cache_lifetime = 256;

/// A glyph ready to become an instance. Positions are in pixels, relative
/// to the top left of the layout, on whole pixels.
pub const Glyph = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    /// The top left of its image in the atlas.
    atlas_x: f32,
    atlas_y: f32,
    kind: f32,
    font: Font,
    variant: Variant,
    id: u32,
};

/// A position the caret can take, in pixels from the left of the layout.
const Stop = struct {
    byte: u32,
    x: f32,
};

const Line = struct {
    top: f32,
    /// Indexes into `Layout.stops`; a line always has at least one.
    first_stop: u32,
    end_stop: u32,
};

/// A string broken into lines, with every glyph placed.
pub const Layout = struct {
    /// The size of the box the text fills, in the unit of the coordinates.
    width: f32,
    height: f32,
    /// The scale of the canvas when the layout was made. A layout made at
    /// another scale than the one it is drawn at comes out at the wrong
    /// size.
    scale: f32,

    glyphs: []Glyph,
    lines: []Line,
    stops: []Stop,
    /// In pixels.
    line_height: f32,
    /// The font size in 26.6 pixels, to draw the glyphs again with.
    size: i32,
    generation: u32,
    last_used: u32 = 0,

    pub fn lineCount(layout: *const Layout) usize {
        return layout.lines.len;
    }

    /// The byte of the string that the caret lands before when the point
    /// `x`, `y` is picked. The point is relative to the top left of the
    /// layout. The length of the string means after the last character.
    pub fn indexAt(layout: *const Layout, x: f32, y: f32) usize {
        const row = @floor(y * layout.scale / layout.line_height);
        const last: f32 = @floatFromInt(layout.lines.len - 1);
        const line = layout.lines[@intFromFloat(std.math.clamp(row, 0, last))];

        const target = x * layout.scale;
        var best = layout.stops[line.first_stop];
        for (layout.stops[line.first_stop..line.end_stop]) |stop| {
            if (@abs(stop.x - target) < @abs(best.x - target)) best = stop;
        }
        return best.byte;
    }

    /// Where the caret stands when it is before the byte `index`.
    pub fn caret(layout: *const Layout, index: usize) types.Caret {
        // A line break offers the same byte twice, at the end of one line
        // and at the start of the next. The later one wins.
        var found_line = layout.lines[0];
        var found = layout.stops[0];
        for (layout.lines) |line| {
            for (layout.stops[line.first_stop..line.end_stop]) |stop| {
                if (stop.byte > index) continue;
                found = stop;
                found_line = line;
            }
        }
        return .{
            .x = found.x / layout.scale,
            .y = found_line.top / layout.scale,
            .height = layout.line_height / layout.scale,
        };
    }
};

/// One setting of the axes of a variable font. Zero is the setting every
/// font starts with.
const Variant = u16;

/// The most fonts one style can name.
const max_fonts = 8;
const max_axes = 8;

/// A `TextStyle` converted to pixels.
const Request = struct {
    fonts: []const Font,
    /// The variant to draw each of `fonts` in.
    variants: [max_fonts]Variant = @splat(0),
    size: i32,
    line_height: ?f32,
    tracking: f32,
    width: ?f32,
    alignment: types.TextAlign,
    scale: f32,

    fn from(style: types.TextStyle, scale: f32) Request {
        return .{
            .fonts = style.fonts[0..@min(style.fonts.len, max_fonts)],
            .size = @intFromFloat(@round(style.size * scale * 64)),
            .line_height = if (style.line_height) |height| @round(height * scale) else null,
            .tracking = style.tracking * scale,
            .width = if (style.width) |width| width * scale else null,
            .alignment = style.alignment,
            .scale = scale,
        };
    }
};

const Face = struct {
    face: ft.FT_Face,
    shaper: *ft.hb_font_t,
    /// A font of bitmaps, which only come in the sizes it was made in.
    fixed: bool,
    color: bool,
    /// Empty for a font that is not variable.
    axes: [max_axes]Axis = undefined,
    axis_count: usize = 0,
    /// The size and the variant the face is currently set to.
    size: i32 = 0,
    variant: Variant = 0,
    /// What everything the face reports has to be multiplied by. Not one
    /// when a bitmap of another size stands in for the size asked for.
    unit: f32 = 1,
};

const Axis = struct {
    tag: u32,
    minimum: f32,
    default: f32,
    maximum: f32,
};

/// The values of the axes of one font, in the order the font lists them.
const Coordinates = struct {
    font: Font,
    values: [max_axes]ft.FT_Fixed,
};

/// A glyph as HarfBuzz placed it, before lines are broken.
const Shaped = struct {
    font: Font,
    variant: Variant,
    id: u32,
    /// The byte in the string that the glyph belongs to.
    cluster: u32,
    advance: f32,
    x_offset: f32,
    y_offset: f32,
    /// Where the pen stood, measured from the start of the string as if it
    /// were one line.
    pen: f32 = 0,
};

/// An image in an atlas and where it sits relative to the pen.
const Raster = struct {
    left: f32,
    top: f32,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    kind: f32,
};

const RasterKey = struct {
    font: Font,
    variant: Variant,
    glyph: u32,
    size: i32,
};

const LineDraft = struct {
    /// Indexes into the shaped glyphs.
    first: usize,
    end: usize,
    /// The pen at the start of the line and at the end of its ink.
    origin: f32,
    ink: f32,
};

pub const System = struct {
    allocator: std.mem.Allocator,
    library: ft.FT_Library,
    buffer: *ft.hb_buffer_t,
    faces: std.ArrayList(Face) = .empty,
    /// Every setting of the axes that was ever asked for. The index is the
    /// `Variant`; the first entry stands for the defaults of any font.
    coordinates: std.ArrayList(Coordinates) = .empty,
    variants: std.AutoHashMapUnmanaged(u64, Variant) = .empty,

    masks: Atlas,
    colors: Atlas,
    rasters: std.AutoHashMapUnmanaged(RasterKey, ?Raster) = .empty,
    /// Counts how often the atlases were emptied. A layout made before the
    /// last time holds positions that mean nothing any more.
    generation: u32 = 0,
    atlas_full: bool = false,

    cache: std.AutoHashMapUnmanaged(u64, *Layout) = .empty,
    frame: u32 = 0,

    // Reused from one layout to the next.
    shaped: std.ArrayList(Shaped) = .empty,
    breaks: std.ArrayList(u8) = .empty,
    drafts: std.ArrayList(LineDraft) = .empty,
    glyphs: std.ArrayList(Glyph) = .empty,
    lines: std.ArrayList(Line) = .empty,
    stops: std.ArrayList(Stop) = .empty,
    scaled: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) !System {
        var library: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&library) != 0) return error.FreeType;
        errdefer _ = ft.FT_Done_FreeType(library);

        const buffer = ft.hb_buffer_create() orelse return error.HarfBuzz;
        errdefer ft.hb_buffer_destroy(buffer);
        ft.init_linebreak();

        var masks: Atlas = try .init(allocator, .{
            .kind = .mask,
            .width = 1024,
            .height = 256,
            .max_height = 4096,
        });
        errdefer masks.deinit();
        const colors: Atlas = try .init(allocator, .{
            .kind = .color,
            .width = 1024,
            .height = 128,
            .max_height = 4096,
        });

        return .{
            .allocator = allocator,
            .library = library,
            .buffer = buffer,
            .masks = masks,
            .colors = colors,
        };
    }

    pub fn deinit(system: *System) void {
        const allocator = system.allocator;
        var cached_layouts = system.cache.valueIterator();
        while (cached_layouts.next()) |layout| system.destroy(layout.*);
        system.cache.deinit(allocator);

        system.rasters.deinit(allocator);
        system.coordinates.deinit(allocator);
        system.variants.deinit(allocator);
        system.shaped.deinit(allocator);
        system.breaks.deinit(allocator);
        system.drafts.deinit(allocator);
        system.glyphs.deinit(allocator);
        system.lines.deinit(allocator);
        system.stops.deinit(allocator);
        system.scaled.deinit(allocator);
        system.masks.deinit();
        system.colors.deinit();

        for (system.faces.items) |face| {
            ft.hb_font_destroy(face.shaper);
            _ = ft.FT_Done_Face(face.face);
        }
        system.faces.deinit(allocator);
        ft.hb_buffer_destroy(system.buffer);
        _ = ft.FT_Done_FreeType(system.library);
    }

    pub fn loadFont(system: *System, path: [:0]const u8, options: types.FontOptions) !Font {
        var face: ft.FT_Face = null;
        if (ft.FT_New_Face(system.library, path.ptr, @intCast(options.index), &face) != 0) {
            return error.FontLoad;
        }
        errdefer _ = ft.FT_Done_Face(face);

        const flags = face.*.face_flags;
        const shaper = ft.hb_ft_font_create_referenced(face) orelse return error.HarfBuzz;
        errdefer ft.hb_font_destroy(shaper);
        const color = flags & ft.FT_FACE_FLAG_COLOR != 0;
        const color_flags: c_int = @intCast(load_flags | ft.FT_LOAD_COLOR);
        ft.hb_ft_font_set_load_flags(shaper, if (color) color_flags else load_flags);

        var loaded: Face = .{
            .face = face,
            .shaper = shaper,
            .fixed = flags & ft.FT_FACE_FLAG_SCALABLE == 0 and
                flags & ft.FT_FACE_FLAG_FIXED_SIZES != 0,
            .color = color,
        };
        if (flags & ft.FT_FACE_FLAG_MULTIPLE_MASTERS != 0) system.readAxes(&loaded);

        if (system.coordinates.items.len == 0) {
            try system.coordinates.append(system.allocator, .{ .font = @enumFromInt(0), .values = @splat(0) });
        }
        try system.faces.append(system.allocator, loaded);
        return @enumFromInt(system.faces.items.len - 1);
    }

    fn readAxes(system: *System, face: *Face) void {
        var master: [*c]ft.FT_MM_Var = null;
        if (ft.FT_Get_MM_Var(face.face, &master) != 0) return;
        defer _ = ft.FT_Done_MM_Var(system.library, master);

        face.axis_count = @min(master.*.num_axis, max_axes);
        for (face.axes[0..face.axis_count], 0..) |*axis, index| {
            const source = master.*.axis[index];
            axis.* = .{
                .tag = @intCast(source.tag),
                .minimum = fixed16(source.minimum),
                .default = fixed16(source.def),
                .maximum = fixed16(source.maximum),
            };
        }
    }

    /// The variant of `font` that `style` asks for at `size`, which is the
    /// font size in the unit of the coordinates.
    fn variantFor(system: *System, font: Font, style: types.TextStyle) Variant {
        const face = &system.faces.items[@intFromEnum(font)];
        if (face.axis_count == 0) return 0;

        var record: Coordinates = .{ .font = font, .values = @splat(0) };
        var changed = false;
        for (face.axes[0..face.axis_count], 0..) |axis, index| {
            var value = axis.default;
            if (axis.tag == tag("wght")) value = style.weight;
            if (axis.tag == tag("opsz")) value = style.size;
            for (style.variations) |variation| {
                if (axis.tag == tag(variation.tag)) value = variation.value;
            }
            value = std.math.clamp(value, axis.minimum, axis.maximum);

            // Every distinct value means drawing every glyph again, so a
            // value that is being animated moves in steps.
            const range = axis.maximum - axis.minimum;
            const step: f32 = if (range >= 50) 5 else if (range >= 10) 1 else range / 16;
            if (step > 0) value = axis.minimum + @round((value - axis.minimum) / step) * step;

            if (value != axis.default) changed = true;
            record.values[index] = @intFromFloat(@round(value * 65536));
        }
        if (!changed) return 0;

        const key = std.hash.Wyhash.hash(0, std.mem.asBytes(&record));
        if (system.variants.get(key)) |found| return found;
        const variant: Variant = @intCast(system.coordinates.items.len);
        system.coordinates.append(system.allocator, record) catch return 0;
        system.variants.put(system.allocator, key, variant) catch {};
        return variant;
    }

    /// Call once per frame, after everything has been drawn.
    pub fn endFrame(system: *System) void {
        system.frame +%= 1;

        // Emptying an atlas in the middle of a frame would pull the images
        // out from under the glyphs already drawn, so it waits until here.
        if (system.atlas_full) {
            system.atlas_full = false;
            system.masks.clear();
            system.colors.clear();
            system.rasters.clearRetainingCapacity();
            system.generation +%= 1;
        }

        if (system.frame % cache_lifetime != 0) return;
        var entries = system.cache.iterator();
        while (entries.next()) |entry| {
            if (system.frame -% entry.value_ptr.*.last_used < cache_lifetime) continue;
            system.destroy(entry.value_ptr.*);
            system.cache.removeByPtr(entry.key_ptr);
        }
    }

    /// A layout that the system keeps for as long as it is asked for every
    /// now and then. Do not hold on to it across frames.
    pub fn cached(system: *System, string: []const u8, style: types.TextStyle, scale: f32) ?*Layout {
        if (style.fonts.len == 0) return null;
        const request: Request = .from(style, scale);

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(string);
        hasher.update(std.mem.sliceAsBytes(request.fonts));
        hasher.update(std.mem.asBytes(&request.size));
        hasher.update(std.mem.asBytes(&style.weight));
        for (style.variations) |variation| {
            hasher.update(variation.tag);
            hasher.update(std.mem.asBytes(&variation.value));
        }
        hasher.update(std.mem.asBytes(&request.tracking));
        // No real line height or width is negative.
        const line_height: f32 = request.line_height orelse -1;
        const width: f32 = request.width orelse -1;
        hasher.update(std.mem.asBytes(&line_height));
        hasher.update(std.mem.asBytes(&width));
        hasher.update(std.mem.asBytes(&request.alignment));
        const key = hasher.final();

        if (system.cache.get(key)) |found| {
            found.last_used = system.frame;
            return found;
        }

        const layout = system.build(string, style, request) catch return null;
        layout.last_used = system.frame;
        system.cache.put(system.allocator, key, layout) catch {
            system.destroy(layout);
            return null;
        };
        return layout;
    }

    /// A layout that belongs to the caller, to be given to `destroy`.
    pub fn create(system: *System, string: []const u8, style: types.TextStyle, scale: f32) !*Layout {
        if (style.fonts.len == 0) return error.NoFont;
        return system.build(string, style, .from(style, scale));
    }

    pub fn destroy(system: *System, layout: *Layout) void {
        system.allocator.free(layout.glyphs);
        system.allocator.free(layout.lines);
        system.allocator.free(layout.stops);
        system.allocator.destroy(layout);
    }

    /// Makes sure the glyphs of `layout` are in the atlases. Call before
    /// reading where they are.
    pub fn prepare(system: *System, layout: *Layout) void {
        if (layout.generation == system.generation) return;
        layout.generation = system.generation;
        for (layout.glyphs) |*glyph| {
            const image = system.raster(glyph.font, glyph.variant, glyph.id, layout.size) orelse {
                // Left where it was; it reads an empty part of the atlas
                // for the frame it takes to make room.
                glyph.atlas_x = 0;
                glyph.atlas_y = 0;
                glyph.width = 0;
                glyph.height = 0;
                continue;
            };
            glyph.atlas_x = @floatFromInt(image.x);
            glyph.atlas_y = @floatFromInt(image.y);
            glyph.width = @floatFromInt(image.width);
            glyph.height = @floatFromInt(image.height);
        }
    }

    fn build(system: *System, string: []const u8, style: types.TextStyle, unresolved: Request) !*Layout {
        const allocator = system.allocator;
        var request = unresolved;
        for (request.fonts, 0..) |font, index| {
            request.variants[index] = system.variantFor(font, style);
        }
        try system.shape(string, request);
        try system.breakLines(string, request);

        const primary = system.sized(request.fonts[0], request.variants[0], request.size);
        const metrics = primary.face.*.size.*.metrics;
        const natural = @round(fixed(metrics.height) * primary.unit);
        const ascent = @round(fixed(metrics.ascender) * primary.unit);
        const line_height = request.line_height orelse natural;
        // A line taller or shorter than the font asks for is centered on
        // where the font would have put it.
        const lead = @round((line_height - natural) / 2);

        var longest: f32 = 0;
        for (system.drafts.items) |draft| longest = @max(longest, draft.ink - draft.origin);
        const box = request.width orelse longest;

        system.glyphs.clearRetainingCapacity();
        system.lines.clearRetainingCapacity();
        system.stops.clearRetainingCapacity();
        const shaped = system.shaped.items;
        const end_pen = if (shaped.len == 0) 0 else shaped[shaped.len - 1].pen + shaped[shaped.len - 1].advance;

        for (system.drafts.items, 0..) |draft, row| {
            const spare = box - (draft.ink - draft.origin);
            const indent = @round(switch (request.alignment) {
                .start => 0,
                .center => spare / 2,
                .end => spare,
            });
            const top = @as(f32, @floatFromInt(row)) * line_height;
            const baseline = top + lead + ascent;
            const first_stop: u32 = @intCast(system.stops.items.len);

            var previous: ?u32 = null;
            for (shaped[draft.first..draft.end]) |glyph| {
                if (previous != glyph.cluster) {
                    try system.stops.append(allocator, .{
                        .byte = glyph.cluster,
                        .x = indent + glyph.pen - draft.origin,
                    });
                    previous = glyph.cluster;
                }

                // Fonts draw a placeholder for control characters.
                if (string[glyph.cluster] < ' ') continue;
                const image = system.raster(glyph.font, glyph.variant, glyph.id, request.size) orelse continue;
                try system.glyphs.append(allocator, .{
                    .x = indent + @round(glyph.pen - draft.origin + glyph.x_offset) + image.left,
                    .y = baseline - @round(glyph.y_offset) - image.top,
                    .width = @floatFromInt(image.width),
                    .height = @floatFromInt(image.height),
                    .atlas_x = @floatFromInt(image.x),
                    .atlas_y = @floatFromInt(image.y),
                    .kind = image.kind,
                    .font = glyph.font,
                    .variant = glyph.variant,
                    .id = glyph.id,
                });
            }

            // The end of the line, which is also where the caret goes on a
            // line without any characters.
            const line_end = if (draft.end < shaped.len) shaped[draft.end].pen else end_pen;
            try system.stops.append(allocator, .{
                .byte = if (draft.end < shaped.len) shaped[draft.end].cluster else @intCast(string.len),
                .x = indent + line_end - draft.origin,
            });
            try system.lines.append(allocator, .{
                .top = top,
                .first_stop = first_stop,
                .end_stop = @intCast(system.stops.items.len),
            });
        }

        const layout = try allocator.create(Layout);
        errdefer allocator.destroy(layout);
        const glyphs = try allocator.dupe(Glyph, system.glyphs.items);
        errdefer allocator.free(glyphs);
        const lines = try allocator.dupe(Line, system.lines.items);
        errdefer allocator.free(lines);
        const stops = try allocator.dupe(Stop, system.stops.items);

        const line_count: f32 = @floatFromInt(lines.len);
        layout.* = .{
            .width = @ceil(longest) / request.scale,
            .height = line_count * line_height / request.scale,
            .scale = request.scale,
            .glyphs = glyphs,
            .lines = lines,
            .stops = stops,
            .line_height = line_height,
            .size = request.size,
            .generation = system.generation,
        };
        return layout;
    }

    /// Fills `shaped` with the glyphs of the whole string, as one line.
    fn shape(system: *System, string: []const u8, request: Request) !void {
        system.shaped.clearRetainingCapacity();
        const unicode = ft.hb_unicode_funcs_get_default();

        // HarfBuzz shapes one font and one script at a time, so the string
        // is cut wherever either changes.
        var start: usize = 0;
        while (start < string.len) {
            const first = decode(string[start..]);
            const chosen = system.fontFor(string, start, request.fonts);
            var script = ft.hb_unicode_script(unicode, first.codepoint);
            var end = start + first.length;
            while (end < string.len) {
                const next = decode(string[end..]);
                // A joiner or a modifier belongs to the character before it
                // whichever font holds it.
                if (!continues(next.codepoint)) {
                    if (system.fontFor(string, end, request.fonts) != chosen) break;
                    const next_script = ft.hb_unicode_script(unicode, next.codepoint);
                    if (specific(next_script)) {
                        if (specific(script) and next_script != script) break;
                        script = next_script;
                    }
                }
                end += next.length;
            }
            try system.shapeRun(
                string,
                start,
                end,
                request.fonts[chosen],
                request.variants[chosen],
                script,
                request.size,
            );
            start = end;
        }

        var pen: f32 = 0;
        var index: usize = 0;
        const shaped = system.shaped.items;
        while (index < shaped.len) {
            // Glyphs of one cluster are one character to the reader, and
            // the tracking goes after all of them.
            const cluster = shaped[index].cluster;
            while (index < shaped.len and shaped[index].cluster == cluster) : (index += 1) {
                if (isLineFeed(string[cluster])) shaped[index].advance = 0;
                shaped[index].pen = pen;
                pen += shaped[index].advance;
            }
            shaped[index - 1].advance += request.tracking;
            pen += request.tracking;
        }
    }

    fn shapeRun(
        system: *System,
        string: []const u8,
        start: usize,
        end: usize,
        font: Font,
        variant: Variant,
        script: ft.hb_script_t,
        size: i32,
    ) !void {
        const face = system.sized(font, variant, size);
        const buffer = system.buffer;
        ft.hb_buffer_reset(buffer);
        // The whole string is passed so that the shaper sees what surrounds
        // the run.
        ft.hb_buffer_add_utf8(
            buffer,
            string.ptr,
            @intCast(string.len),
            @intCast(start),
            @intCast(end - start),
        );
        ft.hb_buffer_set_direction(buffer, ft.HB_DIRECTION_LTR);
        if (specific(script)) ft.hb_buffer_set_script(buffer, script);
        ft.hb_buffer_guess_segment_properties(buffer);
        ft.hb_shape(face.shaper, buffer, null, 0);

        var count: c_uint = 0;
        const infos = ft.hb_buffer_get_glyph_infos(buffer, &count);
        const positions = ft.hb_buffer_get_glyph_positions(buffer, &count);
        try system.shaped.ensureUnusedCapacity(system.allocator, count);
        for (0..count) |index| {
            const position = positions[index];
            system.shaped.appendAssumeCapacity(.{
                .font = font,
                .variant = variant,
                .id = infos[index].codepoint,
                .cluster = infos[index].cluster,
                .advance = fixed(position.x_advance) * face.unit,
                .x_offset = fixed(position.x_offset) * face.unit,
                .y_offset = fixed(position.y_offset) * face.unit,
            });
        }
    }

    /// Fills `drafts` with the lines the shaped glyphs fall into.
    fn breakLines(system: *System, string: []const u8, request: Request) !void {
        const allocator = system.allocator;
        system.drafts.clearRetainingCapacity();
        try system.breaks.resize(allocator, string.len);
        if (string.len > 0) {
            ft.set_linebreaks_utf8(string.ptr, string.len, null, system.breaks.items.ptr);
        }
        const breaks = system.breaks.items;
        const shaped = system.shaped.items;

        // The last place the line could end, in case the next word does
        // not fit.
        const Chance = struct { index: usize, pen: f32, ink: f32 };
        var chance: ?Chance = null;
        var first: usize = 0;
        var origin: f32 = 0;
        var ink: f32 = 0;

        var index: usize = 0;
        while (index < shaped.len) {
            const cluster = shaped[index].cluster;
            var end = index + 1;
            while (end < shaped.len and shaped[end].cluster == cluster) end += 1;
            const next_byte = if (end < shaped.len) shaped[end].cluster else string.len;
            const after = shaped[end - 1].pen + shaped[end - 1].advance;
            const blank = isBlank(string[cluster..]);

            // Blanks may hang past the edge; they are not seen there.
            if (request.width) |limit| {
                if (!blank and after - origin > limit and index > first) {
                    const cut: Chance = chance orelse .{ .index = index, .pen = shaped[index].pen, .ink = ink };
                    try system.drafts.append(allocator, .{
                        .first = first,
                        .end = cut.index,
                        .origin = origin,
                        .ink = @min(cut.ink, cut.pen),
                    });
                    first = cut.index;
                    origin = cut.pen;
                    ink = @max(ink, origin);
                    chance = null;
                    // Looked at again: what moved to the new line may be
                    // too long for it as well.
                    continue;
                }
            }

            if (!blank) ink = after - request.tracking;
            const verdict = breaks[next_byte - 1];
            if (verdict == ft.LINEBREAK_MUSTBREAK and next_byte < string.len) {
                try system.drafts.append(allocator, .{ .first = first, .end = end, .origin = origin, .ink = ink });
                first = end;
                origin = after;
                ink = after;
                chance = null;
            } else if (verdict == ft.LINEBREAK_ALLOWBREAK) {
                chance = .{ .index = end, .pen = after, .ink = ink };
            }
            index = end;
        }

        const end_pen = if (shaped.len == 0) 0 else shaped[shaped.len - 1].pen + shaped[shaped.len - 1].advance;
        try system.drafts.append(allocator, .{
            .first = first,
            .end = shaped.len,
            .origin = origin,
            .ink = @max(ink, origin),
        });
        // A line feed at the very end opens a line for the caret to go to.
        if (string.len > 0 and string[string.len - 1] == '\n') {
            try system.drafts.append(allocator, .{
                .first = shaped.len,
                .end = shaped.len,
                .origin = end_pen,
                .ink = end_pen,
            });
        }
    }

    /// The image of a glyph, drawn on first use. Null for a glyph without
    /// ink, such as a space, and for one there is no room for.
    fn raster(system: *System, font: Font, variant: Variant, glyph: u32, size: i32) ?Raster {
        const key: RasterKey = .{ .font = font, .variant = variant, .glyph = glyph, .size = size };
        if (system.rasters.get(key)) |found| return found;

        const drawn = system.draw(font, variant, glyph, size) catch |failure| switch (failure) {
            // Not remembered, so that it is tried again once there is room.
            error.AtlasFull => {
                system.atlas_full = true;
                return null;
            },
            error.OutOfMemory => return null,
        };
        system.rasters.put(system.allocator, key, drawn) catch {};
        return drawn;
    }

    fn draw(system: *System, font: Font, variant: Variant, glyph: u32, size: i32) !?Raster {
        const face = system.sized(font, variant, size);
        var flags = load_flags | ft.FT_LOAD_RENDER;
        if (face.color) flags |= ft.FT_LOAD_COLOR;
        if (ft.FT_Load_Glyph(face.face, glyph, @intCast(flags)) != 0) return null;

        const slot = face.face.*.glyph;
        const bitmap = slot.*.bitmap;
        if (bitmap.width == 0 or bitmap.rows == 0) return null;
        const left: f32 = @floatFromInt(slot.*.bitmap_left);
        const top: f32 = @floatFromInt(slot.*.bitmap_top);

        if (bitmap.pixel_mode == ft.FT_PIXEL_MODE_GRAY) {
            const spot = system.masks.add(
                bitmap.buffer,
                bitmap.width,
                bitmap.rows,
                @intCast(bitmap.pitch),
            ) orelse return error.AtlasFull;
            return .{
                .left = left,
                .top = top,
                .width = bitmap.width,
                .height = bitmap.rows,
                .x = spot.x,
                .y = spot.y,
                .kind = Instance.kind_glyph,
            };
        }
        if (bitmap.pixel_mode != ft.FT_PIXEL_MODE_BGRA) return null;

        // A bitmap comes in the size the font was made in, which is rarely
        // the size asked for.
        const width: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(bitmap.width)) * face.unit))));
        const height: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(bitmap.rows)) * face.unit))));
        try system.scaled.resize(system.allocator, width * height * 4);
        resample(bitmap.buffer, bitmap.width, bitmap.rows, @intCast(bitmap.pitch), system.scaled.items, width, height);

        const spot = system.colors.add(system.scaled.items.ptr, width, height, width * 4) orelse
            return error.AtlasFull;
        return .{
            .left = @round(left * face.unit),
            .top = @round(top * face.unit),
            .width = width,
            .height = height,
            .x = spot.x,
            .y = spot.y,
            .kind = Instance.kind_color_glyph,
        };
    }

    /// The index of the first of `fonts` that can draw the character at
    /// `at`, or of the first one if none can, so that something is drawn in
    /// its place.
    fn fontFor(system: *System, string: []const u8, at: usize, fonts: []const Font) usize {
        const here = decode(string[at..]);
        const after = at + here.length;

        // A character followed by the emoji selector is meant in color,
        // even when a font before the emoji one has it in outline.
        const emoji_selector = 0xFE0F;
        if (after < string.len and decode(string[after..]).codepoint == emoji_selector) {
            for (fonts, 0..) |font, index| {
                const face = system.faces.items[@intFromEnum(font)];
                if (face.color and ft.FT_Get_Char_Index(face.face, here.codepoint) != 0) return index;
            }
        }

        for (fonts, 0..) |font, index| {
            const face = system.faces.items[@intFromEnum(font)].face;
            if (ft.FT_Get_Char_Index(face, here.codepoint) != 0) return index;
        }
        return 0;
    }

    /// The face of `font`, set to `variant` and `size`. A face holds one of
    /// each at a time.
    fn sized(system: *System, font: Font, variant: Variant, size: i32) *Face {
        const face = &system.faces.items[@intFromEnum(font)];
        if (face.size == size and face.variant == variant) return face;

        if (face.variant != variant) {
            face.variant = variant;
            // Variant zero is the defaults, whichever font it is asked of.
            var values = system.coordinates.items[variant].values;
            if (variant == 0) {
                for (face.axes[0..face.axis_count], 0..) |axis, index| {
                    values[index] = @intFromFloat(@round(axis.default * 65536));
                }
            }
            _ = ft.FT_Set_Var_Design_Coordinates(face.face, @intCast(face.axis_count), &values);
        }
        face.size = size;

        if (face.fixed) {
            // The smallest bitmap that is at least as large as asked for
            // scales down the best; failing that, the largest there is.
            const sizes = face.face.*.available_sizes;
            const count: usize = @intCast(face.face.*.num_fixed_sizes);
            var best: usize = 0;
            for (0..count) |index| {
                const candidate = sizes[index].y_ppem;
                const current = sizes[best].y_ppem;
                const better = if (current < size) candidate > current else candidate >= size and candidate < current;
                if (better) best = index;
            }
            _ = ft.FT_Select_Size(face.face, @intCast(best));
            face.unit = @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(sizes[best].y_ppem));
        } else {
            _ = ft.FT_Set_Char_Size(face.face, 0, size, 72, 72);
            face.unit = 1;
        }
        ft.hb_ft_font_changed(face.shaper);
        return face;
    }
};

/// 16.16 fixed point, which is how FreeType gives the values of an axis.
fn fixed16(value: i64) f32 {
    return @as(f32, @floatFromInt(value)) / 65536.0;
}

/// The four letters of an axis as the number fonts store them as.
fn tag(letters: *const [4]u8) u32 {
    return std.mem.readInt(u32, letters, .big);
}

/// 26.6 fixed point to pixels.
fn fixed(value: i64) f32 {
    return @as(f32, @floatFromInt(value)) / 64.0;
}

/// Shrinks or stretches a BGRA image into an RGBA one by averaging the
/// source pixels that each destination pixel covers.
fn resample(
    source: [*]const u8,
    source_width: u32,
    source_height: u32,
    pitch: usize,
    destination: []u8,
    width: u32,
    height: u32,
) void {
    for (0..height) |y| {
        const top = y * source_height / height;
        const bottom = @max(top + 1, (y + 1) * source_height / height);
        for (0..width) |x| {
            const left = x * source_width / width;
            const right = @max(left + 1, (x + 1) * source_width / width);

            var sum: [4]u32 = .{ 0, 0, 0, 0 };
            for (top..bottom) |row| {
                for (left..right) |column| {
                    const pixel = source[row * pitch + column * 4 ..][0..4];
                    sum[0] += pixel[2];
                    sum[1] += pixel[1];
                    sum[2] += pixel[0];
                    sum[3] += pixel[3];
                }
            }
            const count: u32 = @intCast((bottom - top) * (right - left));
            const out = destination[(y * width + x) * 4 ..][0..4];
            for (out, sum) |*channel, total| channel.* = @intCast((total + count / 2) / count);
        }
    }
}

const Decoded = struct {
    codepoint: u21,
    length: usize,
};

/// The first character of `bytes`, which must not be empty. A byte that is
/// not valid UTF-8 counts as one unknown character.
fn decode(bytes: []const u8) Decoded {
    const replacement: Decoded = .{ .codepoint = 0xFFFD, .length = 1 };
    const length = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return replacement;
    if (length > bytes.len) return replacement;
    const codepoint = std.unicode.utf8Decode(bytes[0..length]) catch return replacement;
    return .{ .codepoint = codepoint, .length = length };
}

/// Whether `codepoint` only makes sense attached to the character before
/// it: combining marks, joiners, variation selectors and skin tones.
fn continues(codepoint: u21) bool {
    return switch (codepoint) {
        0x0300...0x036F,
        0x200C,
        0x200D,
        0x20E3,
        0x3099,
        0x309A,
        0xFE00...0xFE0F,
        0x1F3FB...0x1F3FF,
        0xE0020...0xE007F,
        0xE0100...0xE01EF,
        => true,
        else => false,
    };
}

/// Whether `script` names a writing system, rather than saying that the
/// character goes with whatever surrounds it.
fn specific(script: ft.hb_script_t) bool {
    return script != ft.HB_SCRIPT_COMMON and
        script != ft.HB_SCRIPT_INHERITED and
        script != ft.HB_SCRIPT_UNKNOWN;
}

fn isLineFeed(byte: u8) bool {
    return byte == '\n' or byte == '\r';
}

/// Whether `bytes` starts with something that leaves no mark.
fn isBlank(bytes: []const u8) bool {
    return switch (bytes[0]) {
        ' ', '\t', '\n', '\r' => true,
        else => std.mem.startsWith(u8, bytes, "\u{3000}"),
    };
}
