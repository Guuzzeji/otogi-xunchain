//! M0 spike: map the XBE's memory layout and exit.
const std = @import("std");

comptime {
    _ = @import("manual.zig");
}

extern fn xbox_MemoryLayoutInit(xbe_data: [*]const u8, xbe_size: usize) c_int;

pub fn main(init: std.process.Init) !void {
    const xbe = try std.Io.Dir.cwd().readFileAlloc(init.io, "game/default.xbe", init.arena.allocator(), .unlimited);
    if (xbox_MemoryLayoutInit(xbe.ptr, xbe.len) == 0) return error.MemoryLayoutInit;
    std.debug.print("xbox_MemoryLayoutInit ok\n", .{});
}

// Referenced by xboxrecomp's nv2a_pb_replay.c (another game's frontend hooks); unused by Otogi.
export var g_suppress_present: c_int = 0;
export var g_fe_cursor: c_int = 0;
export fn fe_menu_get_pb_state() c_int {
    return 0;
}
