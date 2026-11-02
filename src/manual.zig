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
/// seeds/manual.h, so the lifter leaves their bodies out and the dispatch
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

/// Game's per-frame movie step (XMV): returns 1 once the movie has ended.
/// RECOMP_NO_MOVIE=1 reports every movie as ended at once.
extern fn sub_000C81A0_gen() void;
export fn sub_000C81A0() void {
    if (std.c.getenv("RECOMP_NO_MOVIE") == null) return sub_000C81A0_gen();
    g_eax = 1;
    g_esp += 4; // ret
}

// ── XAPI input (XPP section) ────────────────────────────────────────────────
// The title talks to its pad through XAPI's USB stack, which hangs and then
// crashes on the toolkit's OHCI model. Replace the eight entry points it calls
// with the toolkit's host input: usb_gamepad_report merges the host XInput pad,
// the keyboard and RECOMP_PAD_SCRIPT into an XID report, whose bytes 2..19 are
// exactly XINPUT_GAMEPAD. All are stdcall; args start at [esp+4].
// ponytail: port 0 only, always present (the keyboard stands in for a missing
// pad); report hot-plug and ports 1-3 if co-op is wanted.

extern fn usb_gamepad_report(pad: c_int, out: [*]u8, max: c_int) c_int;

fn arg(n: u32) u32 {
    return mem32(g_esp + 4 * n).*;
}

fn ret(eax: u32, arg_bytes: u32) void {
    g_eax = eax;
    g_esp += 4 + arg_bytes;
}

fn guestBytes(va: u32, len: usize) []u8 {
    const p: [*]u8 = @ptrFromInt(@as(usize, @bitCast(g_xbox_mem_offset)) + va);
    return p[0..len];
}

/// XInitDevices(count, types)
export fn sub_0016E924() void {
    ret(0, 8);
}

/// XGetDevices(type) -> bitmask of occupied ports
export fn sub_0016E929() void {
    ret(1, 4);
}

/// XGetDeviceChanges(type, *insertions, *removals) -> any change. The game
/// opens a pad on its insertion, so port 0 arrives once, as on hardware.
var pad_arrived = false;
export fn sub_0016E94B() void {
    mem32(arg(2)).* = if (pad_arrived) 0 else 1;
    mem32(arg(3)).* = 0;
    ret(if (pad_arrived) 0 else 1, 12);
    pad_arrived = true;
}

/// XInputOpen(type, port, slot, params) -> handle (port + 1), or 0
export fn sub_0016EA1A() void {
    ret(if (arg(2) == 0) 1 else 0, 16);
}

/// XInputClose(handle)
export fn sub_0016EA70() void {
    ret(0, 4);
}

/// XInputGetCapabilities(handle, *caps): XINPUT_CAPABILITIES is 26 bytes,
/// SubType at 0, In (an XINPUT_GAMEPAD of supported bits) at 4, Out at 22.
export fn sub_0016EA7C() void {
    const caps = guestBytes(arg(2), 26);
    @memset(caps, 0xFF);
    caps[0] = 1; // XINPUT_DEVSUBTYPE_GC_GAMEPAD
    caps[1] = 0;
    caps[2] = 0;
    caps[3] = 0;
    ret(0, 8);
}

var pad_last: [18]u8 = @splat(0);
var pad_packet: u32 = 0;

/// XInputGetState(handle, *state): dwPacketNumber, then XINPUT_GAMEPAD (18 bytes).
export fn sub_0016EC54() void {
    var report: [20]u8 = undefined;
    _ = usb_gamepad_report(@intCast(arg(1) -% 1), &report, report.len);
    if (!std.mem.eql(u8, &pad_last, report[2..20])) {
        pad_last = report[2..20].*;
        pad_packet +%= 1;
    }
    const state = guestBytes(arg(2), 22);
    std.mem.writeInt(u32, state[0..4], pad_packet, .little);
    @memcpy(state[4..22], &pad_last);
    ret(0, 8);
}

/// XInputSetState(handle, *feedback): rumble, ignored; the feedback header's
/// dwStatus (already 0) reads as complete.
export fn sub_0016ECC7() void {
    ret(0, 8);
}
