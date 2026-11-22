//! The running cost of one in-between frame (gl_hle.zig's fr_pass_ms).
const std = @import("std");

/// The average after one game frame's sample, or after a game frame that
/// showed no in-between (null). One slow pass (a shader compiling) counts as
/// one period at most, and the average falls while no in-between runs: it is
/// only measured inside the loop it gates, so it would otherwise stay high
/// and hold the game at 30 shown frames for the rest of the run.
pub fn cost(avg: f64, sample: ?f64, period: f64) f64 {
    const s = sample orelse return avg * 0.9;
    return avg + (@min(s, period) - avg) * 0.1;
}

test "a spike does not switch in-betweens off for good" {
    const period = 1000.0 / 30.0;
    var avg = cost(2, 500, period);
    try std.testing.expect(avg < 6);
    avg = 30; // too slow for any in-between: none runs, none is measured
    for (0..10) |_| avg = cost(avg, null, period);
    try std.testing.expect(avg < 12);
}
