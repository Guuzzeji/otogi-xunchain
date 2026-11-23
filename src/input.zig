//! Host input through SDL3, in place of the toolkit's XInput backend
//! (input/xinput_device.c): the same five entry points, which
//! usb_gamepad_report calls for the guest pad.
//! SDL reads Xbox, PlayStation and Switch pads itself, and all of them play
//! the one guest pad (pad.merge). The render thread owns SDL: it takes the
//! events and polls the pads (gl_hle.pumpEvents), the game thread reads the
//! last state.
const std = @import("std");
const sdl = @import("sdl");
const pad = @import("pad.zig");
const settings_menu = @import("settings_menu.zig");

const SRWLOCK = extern struct { p: ?*anyopaque = null };
extern "kernel32" fn AcquireSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;

extern fn xbox_InputKeySet(vk: c_int, down: c_int) void;
extern fn xbox_InputKeysClear() void;
extern fn xbox_InputKeyboardPoll(out: *State) c_int;
extern fn mkb_merge(port: u32, state: *State) c_int;

/// XBOX_INPUT_STATE
const State = extern struct { packet: u32 = 0, pad: pad.Pad = .{} };

var mtx: SRWLOCK = .{};
var now: pad.Pad = .{}; // every host pad, merged
var connected = false;
var motors: [2]u16 = .{ 0, 0 }; // what the game last asked for
var motors_sent: [2]u16 = .{ 0, 0 };
var pads: [8]?*sdl.SDL_Gamepad = @splat(null);
var combo_held = false; // Back+Start pressed and not yet both let go

fn name(g: ?*sdl.SDL_Gamepad) [*:0]const u8 {
    const n: ?[*:0]const u8 = sdl.SDL_GetGamepadName(g);
    return n orelse "?";
}

/// Gamepad arrivals and keys (render thread).
pub fn event(e: *const sdl.SDL_Event) void {
    switch (e.type) {
        sdl.SDL_EVENT_GAMEPAD_ADDED => {
            const slot = std.mem.indexOfScalar(?*sdl.SDL_Gamepad, &pads, null) orelse return;
            const g = sdl.SDL_OpenGamepad(e.gdevice.which) orelse return;
            pads[slot] = g;
            motors_sent = .{ 0, 0 };
            std.debug.print("[INPUT] pad connected: {s}\n", .{name(g)});
        },
        sdl.SDL_EVENT_GAMEPAD_REMOVED => for (&pads) |*p| {
            if (p.* == null or sdl.SDL_GetGamepadID(p.*) != e.gdevice.which) continue;
            std.debug.print("[INPUT] pad disconnected: {s}\n", .{name(p.*)});
            sdl.SDL_CloseGamepad(p.*);
            p.* = null;
        },
        sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => if (keyVk(e.key.scancode)) |vk| xbox_InputKeySet(vk, @intFromBool(e.key.down)),
        // Its key-up events go elsewhere: nothing stays held.
        sdl.SDL_EVENT_WINDOW_FOCUS_LOST => xbox_InputKeysClear(),
        else => {},
    }
}

/// The Windows key code the toolkit's key map (input/keyboard.c) names.
fn keyVk(sc: sdl.SDL_Scancode) ?c_int {
    const s: c_int = @intCast(sc);
    if (s >= sdl.SDL_SCANCODE_A and s <= sdl.SDL_SCANCODE_Z) return 'A' + (s - sdl.SDL_SCANCODE_A);
    if (s >= sdl.SDL_SCANCODE_1 and s <= sdl.SDL_SCANCODE_9) return '1' + (s - sdl.SDL_SCANCODE_1);
    return switch (s) {
        sdl.SDL_SCANCODE_UP => 0x26,
        sdl.SDL_SCANCODE_DOWN => 0x28,
        sdl.SDL_SCANCODE_LEFT => 0x25,
        sdl.SDL_SCANCODE_RIGHT => 0x27,
        sdl.SDL_SCANCODE_RETURN => 0x0D,
        sdl.SDL_SCANCODE_BACKSPACE => 0x08,
        sdl.SDL_SCANCODE_LSHIFT, sdl.SDL_SCANCODE_RSHIFT => 0x10,
        sdl.SDL_SCANCODE_LCTRL, sdl.SDL_SCANCODE_RCTRL => 0x11,
        sdl.SDL_SCANCODE_KP_8 => 0x68,
        sdl.SDL_SCANCODE_KP_2 => 0x62,
        sdl.SDL_SCANCODE_KP_4 => 0x64,
        sdl.SDL_SCANCODE_KP_6 => 0x66,
        else => null,
    };
}

fn read(g: *sdl.SDL_Gamepad) pad.Pad {
    var p: pad.Pad = .{};
    // XINPUT_GAMEPAD's low byte: D-pad up down left right, Start, Back, stick clicks.
    inline for (.{ sdl.SDL_GAMEPAD_BUTTON_DPAD_UP, sdl.SDL_GAMEPAD_BUTTON_DPAD_DOWN, sdl.SDL_GAMEPAD_BUTTON_DPAD_LEFT, sdl.SDL_GAMEPAD_BUTTON_DPAD_RIGHT, sdl.SDL_GAMEPAD_BUTTON_START, sdl.SDL_GAMEPAD_BUTTON_BACK, sdl.SDL_GAMEPAD_BUTTON_LEFT_STICK, sdl.SDL_GAMEPAD_BUTTON_RIGHT_STICK }, 0..) |b, bit| {
        if (sdl.SDL_GetGamepadButton(g, b)) p.buttons |= 1 << bit;
    }
    // By place, not by label: the bottom face button is A on every pad. The
    // shoulders are Black and White, as the XInput backend had them.
    inline for (.{ sdl.SDL_GAMEPAD_BUTTON_SOUTH, sdl.SDL_GAMEPAD_BUTTON_EAST, sdl.SDL_GAMEPAD_BUTTON_WEST, sdl.SDL_GAMEPAD_BUTTON_NORTH, sdl.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, sdl.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER }, 0..) |b, i| {
        if (sdl.SDL_GetGamepadButton(g, b)) p.analog[i] = 255;
    }
    p.analog[6] = @intCast(@max(sdl.SDL_GetGamepadAxis(g, sdl.SDL_GAMEPAD_AXIS_LEFT_TRIGGER), 0) >> 7); // 0..32767
    p.analog[7] = @intCast(@max(sdl.SDL_GetGamepadAxis(g, sdl.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER), 0) >> 7);
    inline for (.{ sdl.SDL_GAMEPAD_AXIS_LEFTX, sdl.SDL_GAMEPAD_AXIS_LEFTY, sdl.SDL_GAMEPAD_AXIS_RIGHTX, sdl.SDL_GAMEPAD_AXIS_RIGHTY }, 0..) |a, i| {
        const v = sdl.SDL_GetGamepadAxis(g, a);
        p.axes[i] = if (i & 1 == 0) v else -@max(v, -32767); // SDL's Y grows downward
    }
    return p;
}

/// Read the pads and send them the rumble (render thread, after the events).
pub fn poll(menu_open: bool) void {
    var m: pad.Pad = .{};
    var any = false;
    for (pads) |p| {
        pad.merge(&m, read(p orelse continue));
        any = true;
    }
    // Back+Start opens and closes the settings page. The game sees neither
    // button from then until both are let go, and no pad while the page is open.
    const combo = m.buttons & 0x30 == 0x30;
    if (combo and !combo_held) settings_menu.open = !settings_menu.open;
    if (combo) combo_held = true;
    if (m.buttons & 0x30 == 0) combo_held = false;
    if (combo_held) m.buttons &= ~@as(u16, 0x30);
    if (settings_menu.open) m = .{};
    // With a pad in hand the pointer over the game is in the way: hide it.
    // settings.ini show_mouse = 1 keeps it; the menus set their own.
    const show = if (std.c.getenv("RECOMP_SHOW_MOUSE")) |e| e[0] != '0' else false;
    const hide = any and !show;
    if (!menu_open and !settings_menu.open and sdl.SDL_CursorVisible() == hide) {
        _ = if (hide) sdl.SDL_HideCursor() else sdl.SDL_ShowCursor();
        std.debug.print("[INPUT] mouse pointer {s}\n", .{if (hide) "hidden: a pad is connected" else "shown"});
    }
    AcquireSRWLockExclusive(&mtx);
    now = m;
    connected = any;
    const want = motors;
    ReleaseSRWLockExclusive(&mtx);
    if (std.mem.eql(u16, &want, &motors_sent)) return;
    motors_sent = want;
    // ponytail: SDL's rumble ends by itself, XInput's holds: a minute is
    // longer than Otogi shakes for; resend on a timer if a title holds one.
    for (pads) |p| _ = sdl.SDL_RumbleGamepad(p orelse continue, want[0], want[1], 60_000);
}

export fn xbox_InputInit() void {}

/// Port 0 is every host pad plus the keyboard; the others are empty.
export fn xbox_InputGetState(port: u32, state: ?*State) u32 {
    const s = state orelse return 1167; // ERROR_DEVICE_NOT_CONNECTED
    if (port != 0) return 1167;
    AcquireSRWLockExclusive(&mtx);
    s.* = .{ .pad = now };
    ReleaseSRWLockExclusive(&mtx);
    var kb: State = .{};
    if (xbox_InputKeyboardPoll(&kb) != 0) pad.merge(&s.pad, kb.pad);
    _ = mkb_merge(0, s);
    return 0;
}

export fn xbox_InputSetState(port: u32, vib: ?*const [2]u16) u32 {
    if (port != 0 or vib == null) return 1167;
    AcquireSRWLockExclusive(&mtx);
    motors = vib.?.*;
    ReleaseSRWLockExclusive(&mtx);
    return 0;
}

export fn xbox_InputIsConnected(port: u32) c_int {
    return @intFromBool(port == 0 and connected);
}

/// XBOX_INPUT_CAPABILITIES: Type, SubType, Flags, then a pad and motors.
export fn xbox_InputGetCapabilities(port: u32, flags: u32, caps: ?*[26]u8) u32 {
    _ = flags;
    if (port != 0 or caps == null) return 1167;
    caps.?.* = @splat(0);
    caps.?[0] = 1; // XINPUT_DEVTYPE_GAMEPAD
    caps.?[1] = 1; // XINPUT_DEVSUBTYPE_GAMEPAD
    return 0;
}
