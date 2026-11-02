//! Host pad to Otogi pad (XInputGetState in manual.zig).
const std = @import("std");

/// A modern pad on Otogi's controls (XINPUT_GAMEPAD: buttons, 8 analog
/// buttons A B X Y Black White LT RT, then LX LY RX RY).
/// - LB/RB press LT/RT too. The host maps them to Black/White, which Otogi
///   does not use; its lock-on and dash are the triggers (Controller Config).
/// - The right stick turns the view the modern way: Otogi orbits the camera
///   (right turns the view left, up looks down) and has no option for it.
///   RECOMP_CAM_INVERT=0 keeps the original.
/// - The game ignores the inner 40% of each axis (0x44060: (|v| - 0.4) / 0.6),
///   a Duke-sized dead zone that makes the camera slow to respond on a modern
///   stick. Past a 15% host dead zone the right stick starts at the game's 40%.
pub fn hostPad(g: *[18]u8) void {
    g[8] = @max(g[8], g[6]);
    g[9] = @max(g[9], g[7]);
    const invert = if (std.c.getenv("RECOMP_CAM_INVERT")) |e| e[0] != '0' else true;
    for ([_]usize{ 14, 16 }) |o| {
        const raw: f32 = @floatFromInt(std.mem.readInt(i16, g[o..][0..2], .little));
        var v = raw / 32767;
        const m = @abs(v);
        v = if (m < 0.15) 0 else std.math.sign(v) * @min(0.4 + 0.6 * (m - 0.15) / 0.85, 1);
        if (invert) v = -v;
        std.mem.writeInt(i16, g[o..][0..2], @intFromFloat(v * 32767), .little);
    }
}

test hostPad {
    var g: [18]u8 = @splat(0);
    g[6] = 255; // Black (LB)
    std.mem.writeInt(i16, g[14..16], 32767, .little); // RX full right
    std.mem.writeInt(i16, g[16..18], 1000, .little); // RY inside the host dead zone
    hostPad(&g);
    try std.testing.expectEqual(255, g[8]); // LT
    try std.testing.expectEqual(-32767, std.mem.readInt(i16, g[14..16], .little));
    try std.testing.expectEqual(0, std.mem.readInt(i16, g[16..18], .little));
    std.mem.writeInt(i16, g[14..16], -32768, .little);
    std.mem.writeInt(i16, g[16..18], 0x2000, .little); // 25%: just past the game's dead zone after mapping
    hostPad(&g);
    try std.testing.expectEqual(32767, std.mem.readInt(i16, g[14..16], .little));
    try std.testing.expect(std.mem.readInt(i16, g[16..18], .little) < -13107); // past the game's 40%
}

