//! Packs small images into one big one, on the CPU. A backend mirrors it
//! into a texture; nothing here knows how.

const std = @import("std");
const types = @import("types.zig");

/// Where an image ended up, in atlas pixels.
pub const Slot = struct {
    x: u32,
    y: u32,
};

pub const Atlas = struct {
    allocator: std.mem.Allocator,
    kind: types.AtlasUpdate.Kind,
    pixels: []u8,
    width: u32,
    height: u32,
    max_height: u32,

    // Shelf packing: images fill a row from left to right, and a new row
    // starts under the tallest image of the one before. Glyphs of one size
    // are close in height, so little is wasted.
    shelf_x: u32 = gap,
    shelf_y: u32 = gap,
    shelf_height: u32 = 0,

    dirty_first: u32 = std.math.maxInt(u32),
    dirty_end: u32 = 0,

    /// Kept empty around every image, so that sampling just outside one
    /// never reads its neighbour.
    const gap = 1;

    pub const Options = struct {
        kind: types.AtlasUpdate.Kind,
        width: u32,
        height: u32,
        /// The height doubles when the atlas fills up, as far as this.
        max_height: u32,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Atlas {
        const pixels = try allocator.alloc(u8, options.width * options.height * stride(options.kind));
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .kind = options.kind,
            .pixels = pixels,
            .width = options.width,
            .height = options.height,
            .max_height = options.max_height,
        };
    }

    pub fn deinit(atlas: *Atlas) void {
        atlas.allocator.free(atlas.pixels);
    }

    /// Copies `rows` rows of `width` pixels, `pitch` bytes apart, into a
    /// free spot. Null when the atlas is full and cannot grow any further.
    pub fn add(atlas: *Atlas, source: [*]const u8, width: u32, rows: u32, pitch: usize) ?Slot {
        if (width + gap * 2 > atlas.width) return null;
        if (atlas.shelf_x + width + gap > atlas.width) {
            atlas.shelf_y += atlas.shelf_height + gap;
            atlas.shelf_x = gap;
            atlas.shelf_height = 0;
        }
        while (atlas.shelf_y + rows + gap > atlas.height) {
            if (!atlas.grow()) return null;
        }

        const bytes = stride(atlas.kind);
        const slot: Slot = .{ .x = atlas.shelf_x, .y = atlas.shelf_y };
        for (0..rows) |row| {
            const from = source[row * pitch ..][0 .. width * bytes];
            const start = ((slot.y + row) * atlas.width + slot.x) * bytes;
            @memcpy(atlas.pixels[start..][0 .. width * bytes], from);
        }

        atlas.shelf_x += width + gap;
        atlas.shelf_height = @max(atlas.shelf_height, rows);
        atlas.dirty_first = @min(atlas.dirty_first, slot.y);
        atlas.dirty_end = @max(atlas.dirty_end, slot.y + rows);
        return slot;
    }

    /// Empties the atlas. Every slot handed out before is void.
    pub fn clear(atlas: *Atlas) void {
        @memset(atlas.pixels, 0);
        atlas.shelf_x = gap;
        atlas.shelf_y = gap;
        atlas.shelf_height = 0;
        atlas.dirty_first = 0;
        atlas.dirty_end = atlas.height;
    }

    /// What changed since the last call, or null if nothing did.
    pub fn takeUpdate(atlas: *Atlas) ?types.AtlasUpdate {
        if (atlas.dirty_end <= atlas.dirty_first) return null;
        defer {
            atlas.dirty_first = std.math.maxInt(u32);
            atlas.dirty_end = 0;
        }
        return .{
            .kind = atlas.kind,
            .pixels = atlas.pixels,
            .width = atlas.width,
            .height = atlas.height,
            .first_row = atlas.dirty_first,
            .end_row = atlas.dirty_end,
        };
    }

    // Only the height grows, so the slots handed out before stay where
    // they are.
    fn grow(atlas: *Atlas) bool {
        if (atlas.height >= atlas.max_height) return false;
        const height = @min(atlas.height * 2, atlas.max_height);
        const bytes = atlas.width * stride(atlas.kind);
        const pixels = atlas.allocator.realloc(atlas.pixels, height * bytes) catch return false;
        @memset(pixels[atlas.height * bytes ..], 0);
        atlas.pixels = pixels;
        atlas.height = height;
        return true;
    }
};

/// Bytes per pixel.
pub fn stride(kind: types.AtlasUpdate.Kind) u32 {
    return switch (kind) {
        .mask => 1,
        .color => 4,
    };
}
