//! Hand-written overrides and the runtime hooks the lifted code calls.
//! Port of xboxrecomp/templates/new-game/src/recomp_manual.c.
const std = @import("std");

const RecompFn = *const fn () callconv(.c) void;

extern var g_icall_trace: [16]u32;
extern var g_icall_trace_idx: u32;
extern var g_icall_count: u64;

extern threadlocal var g_eax: u32;
extern threadlocal var g_esp: u32;
extern var g_xbox_mem_offset: isize;

fn mem32(va: u32) *volatile u32 {
    return @ptrFromInt(@as(usize, @bitCast(g_xbox_mem_offset)) + va);
}

const D3D_DEVICE_PTR: u32 = 0x1051C8; // XDK 5455 D3D's global device pointer

/// Extra indirect-call targets. The overrides below are listed in
/// seeds/manual.json, so the lifter leaves their bodies out and the dispatch
/// table already points at these exports.
export fn recomp_lookup_manual(va: u32) ?RecompFn {
    _ = va;
    return null;
}

/// XAPI DVD media check. Its cert flag (cert+0x1D8 bit 0) asks for the disc's
/// security sector via READ DVD STRUCTURE, which a plain ISO does not carry, so
/// it fails five times and the title reboots to the dashboard. Report success
/// (STATUS_SUCCESS), as an authenticated drive would.
export fn sub_000E571D() void {
    g_eax = 0;
    g_esp += 4; // ret
}

/// D3D BlockOnTime(fence, flags): spins until the GPU semaphore (*(device+0x30))
/// reaches the fence. Nothing executes the pushbuffer, so nothing ever writes the
/// semaphore. Point it at the device's own fence counter (device+0x2C) instead:
/// every fence then reads as done, for this wait and for every other semaphore
/// reader (ring make-space). With that pointer the original body returns at once.
/// Re-applied on each call because a device reset rewrites the field.
/// ponytail: GPU "always caught up"; M3's renderer needs a real semaphore if a
/// pushbuffer executor runs behind the title (xboxrecomp d3d8ltcg-device-context.md).
export fn sub_000FA2A0() void {
    const dev = mem32(D3D_DEVICE_PTR).*;
    mem32(dev + 0x30).* = dev + 0x2C;
    g_eax = mem32(dev + 0x2C).*;
    g_esp += 12; // ret 8
}

/// RECOMP_ICALL could not resolve a target.
export fn recomp_icall_fail_log(va: u32) void {
    std.debug.print("[ICALL] Failed to resolve VA 0x{X:0>8} (total calls: {d})\n  Recent ICALL targets:\n", .{ va, g_icall_count });
    for (0..16) |i| {
        const t = g_icall_trace[(g_icall_trace_idx -% 16 +% @as(u32, @intCast(i))) & 15];
        if (t != 0) std.debug.print("    [{d:>2}] 0x{X:0>8}\n", .{ i, t });
    }
}

var not_code_seen: [16]u32 = undefined;
var not_code_hits: [16]u64 = undefined;
var not_code_count: usize = 0;

/// An indirect call to a non-code address. Logged at hit 1, 10, 100, ... per address
/// so a spin shows up as a progression instead of millions of lines.
export fn recomp_icall_not_code_log(va: u32) void {
    const i = std.mem.indexOfScalar(u32, not_code_seen[0..not_code_count], va) orelse blk: {
        if (not_code_count == not_code_seen.len) return;
        not_code_seen[not_code_count] = va;
        not_code_hits[not_code_count] = 0;
        not_code_count += 1;
        break :blk not_code_count - 1;
    };
    not_code_hits[i] += 1;
    var n = not_code_hits[i];
    while (n >= 10 and n % 10 == 0) n /= 10;
    if (n != 1) return;
    std.debug.print("[ICALL] target 0x{X:0>8} is not code -- skipped {d} time(s) (null or wild function pointer, at call #{d})\n", .{ va, not_code_hits[i], g_icall_count });
}

var unimpl_printed: u32 = 0;

/// The lifter emits this at every instruction it could not translate (a no-op).
/// RECOMP_UNIMPL_TRAP=1 aborts at the first hit.
export fn recomp_unimpl(text: [*:0]const u8, va: u32) void {
    const trap = std.c.getenv("RECOMP_UNIMPL_TRAP");
    const stop = trap != null and trap.?[0] != 0 and trap.?[0] != '0';
    if (unimpl_printed < 50 or stop) {
        unimpl_printed += 1;
        std.debug.print("[UNIMPL] untranslated instruction REACHED: `{s}` at 0x{X:0>8} (a no-op; set RECOMP_UNIMPL_TRAP=1 to stop here)\n", .{ text, va });
    }
    if (stop) std.process.abort();
}

/// Game's per-frame movie step (XMV): returns 1 once the movie has ended. XMV's
/// clock only starts once its decode and audio pipeline report ready, which
/// does not happen here yet, so it would Sleep(2) forever. Report the movie as
/// ended. ponytail: skips every movie; M4 ("XMV intro movie") replaces this.
export fn sub_000C81A0() void {
    g_eax = 1;
    g_esp += 4; // ret
}
