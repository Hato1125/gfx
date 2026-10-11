//! Dual Kawase blur: every pass down halves the image while averaging
//! neighbours, every pass up doubles it again. Most of the work happens on
//! images far smaller than the frame.

pub const max_passes = 8;

pub const Plan = struct {
    passes: usize,
    offset: f32,
    /// Below the weakest blur one pass can produce, the blurred image is
    /// mixed with the sharp one by this amount instead.
    mix: f32,
};

// Dual Kawase has no closed form for its strength. These come from running
// the same filter on small squares in a simulation and measuring the result:
// after n passes with offset o, sigma² = base[n - 1] + gain[n - 1] · o².
// The last two entries are extrapolated; each pass quadruples both.
const base = [max_passes]f32{ 0.98, 5.5, 23.2, 93.2, 375.0, 1504.0, 6016.0, 24064.0 };
const gain = [max_passes]f32{ 1.47, 7.17, 30.1, 121.9, 488.8, 1956.0, 7824.0, 31296.0 };
// Below this offset the result depends on where the content sits relative
// to the shrunken pixel grid, which shows up as shimmer when things move.
const min_offset = 1.2;
const max_offset = 4.0;

/// `sigma` is in pixels. `shortest_side` limits how often the image can be
/// halved.
pub fn plan(sigma: f32, shortest_side: u32) Plan {
    var limit: usize = 0;
    while (limit < max_passes and
        (shortest_side >> @as(u5, @intCast(limit + 1))) >= 2) : (limit += 1)
    {}
    if (limit == 0 or sigma < 0.05) return .{ .passes = 0, .offset = 0, .mix = 0 };

    // Use as many passes as the strength allows without dropping the
    // offset under its minimum.
    const variance = sigma * sigma;
    const least = min_offset * min_offset;
    var passes: usize = 1;
    while (passes < limit and
        variance >= base[passes] + gain[passes] * least) passes += 1;

    const weakest = base[passes - 1];
    if (variance < weakest) {
        return .{ .passes = passes, .offset = 0, .mix = variance / weakest };
    }
    return .{
        .passes = passes,
        .offset = @min(@sqrt((variance - weakest) / gain[passes - 1]), max_offset),
        .mix = 1,
    };
}
