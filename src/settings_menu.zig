//! The settings page (F10, or Back+Start on a pad): settings.ini as a form,
//! for players, with the launcher's look and controls (setup/ui/theme.rcss,
//! logic.formRml). Each change is saved at once (setup/logic.zig, the
//! launcher's own, keeps the file's comments) and put in the environment,
//! where the game reads its settings; the ones logic.known marks live apply at
//! once, the rest at the next start. The game is held while it is open
//! (debug_menu.holdFrame). Also the metrics overlay (metrics, metrics_corner).
//! RmlUi context 0 (src/ui/settings.rml), on the render thread.
const std = @import("std");
const sdl = @import("sdl");
const logic = @import("logic");
const ui = @import("ui.zig");
const gl_hle = @import("gl_hle.zig");
const cheats = @import("cheats.zig");
const debug_menu = @import("debug_menu.zig");

extern fn _putenv(s: [*:0]const u8) c_int;
extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn fread([*]u8, usize, usize, *anyopaque) usize;
extern "c" fn fwrite([*]const u8, usize, usize, *anyopaque) usize;
extern "c" fn fclose(*anyopaque) c_int;

pub var open = false;
var shown = false; // open last frame
var metrics: ?[2]u8 = null; // metrics, metrics_corner; read again when one changes

var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var ini: []const u8 = &.{};
var entries: []logic.Entry = &.{};
var status: []const u8 = "";
var custom = false; // the resolution's Custom field is open
var modes: [10][12:0]u8 = undefined; // the display's resolutions, as "1920x1080"
var modes_len: usize = 0;

/// The metrics overlay (settings.ini metrics, metrics_corner): level 0 off,
/// 1 frames per second, 2 more; corner 0 top right, 1 top left, 2 bottom
/// right, 3 bottom left.
pub fn overlay() [2]u8 {
    if (metrics == null) metrics = .{ envDigit("RECOMP_METRICS", 2), envDigit("RECOMP_METRICS_CORNER", 3) };
    return metrics.?;
}

fn envDigit(name: [*:0]const u8, max: u8) u8 {
    const e = std.c.getenv(name) orelse return 0;
    return if (e[0] >= '0' and e[0] <= '0' + max) e[0] - '0' else 0;
}

/// The page or the overlay wants drawing.
pub fn wanted() bool {
    return open or overlay()[0] != 0;
}

/// settings.ini again, and the form to match it (only its values change, so
/// the focus stays where it is).
fn load() void {
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    ini = &.{};
    entries = &.{};
    if (fopen("settings.ini", "rb")) |f| {
        const buf = a.alloc(u8, 64 * 1024) catch return;
        ini = buf[0..fread(buf.ptr, 1, buf.len, f)];
        _ = fclose(f);
        entries = logic.entries(a, ini) catch &.{};
    }
    var out: std.Io.Writer.Allocating = .init(a);
    if (entries.len == 0) out.writer.writeAll("<p class=\"muted\">No settings.ini beside otogi.exe.</p>") catch return;
    logic.formRml(&out.writer, entries, modes[0..modes_len], true) catch return;
    out.writer.writeByte(0) catch return;
    ui.ui_set("list", @ptrCast(out.written().ptr));
    logic.formValues(entries, modes[0..modes_len], custom);
    ui.set("status", "{s}", .{status});
}

/// Save a change to the file as it is now, put it in the environment and
/// apply it if it can be. Render thread.
pub fn save(key: []const u8, value: []const u8) void {
    load();
    const new = logic.withValue(std.heap.page_allocator, ini, key, value) catch return;
    defer std.heap.page_allocator.free(new);
    const f = fopen("settings.ini", "wb") orelse {
        status = "Could not write settings.ini.";
        return load();
    };
    const ok = fwrite(new.ptr, 1, new.len, f) == new.len;
    _ = fclose(f);
    status = if (ok) "" else "Could not write settings.ini.";
    std.debug.print("[SETTINGS] {s} = {s}{s}\n", .{ key, value, if (ok) "" else " (could not write settings.ini)" });
    var kv: [256]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&kv, "RECOMP_{s}={s}", .{ key, value }, 0) catch return;
    for (s[7 .. 7 + key.len]) |*c| c.* = std.ascii.toUpper(c.*);
    _ = _putenv(s); // an empty value removes it: the default
    const eql = std.mem.eql;
    if (eql(u8, key, "framerate")) gl_hle.frRate();
    if (eql(u8, key, "vsync")) gl_hle.applyVsync();
    if (eql(u8, key, "window") or eql(u8, key, "resolution")) gl_hle.applyWindow();
    if (eql(u8, key, "draw_distance") or eql(u8, key, "fog_distance")) cheats.scales_read = false;
    if (eql(u8, key, "metrics") or eql(u8, key, "metrics_corner")) metrics = null;
    // cam_invert and show_mouse are read from the environment as they are used.
    load();
}

/// The display's modes, 1280x720 and up, largest first, at most 10.
fn listModes(window: *sdl.SDL_Window) void {
    modes_len = 0;
    var n: c_int = 0;
    const list = sdl.SDL_GetFullscreenDisplayModes(sdl.SDL_GetDisplayForWindow(window), &n) orelse return;
    defer sdl.SDL_free(@ptrCast(list));
    for (list[0..@intCast(n)]) |mp| {
        const md = mp.*;
        if (md.w < 1280 or md.h < 720 or modes_len == modes.len) continue;
        var b: [12:0]u8 = @splat(0);
        _ = std.fmt.bufPrint(&b, "{d}x{d}", .{ md.w, md.h }) catch continue;
        // SDL lists each size once per refresh rate.
        if (for (modes[0..modes_len]) |*x| (if (std.mem.eql(u8, x, &b)) break true) else false) continue;
        modes[modes_len] = b;
        modes_len += 1;
    }
}

/// A click on the page (ui.take). False if it is not the page's.
pub fn command(cmd: []const u8, val: []const u8) bool {
    var b: [16]u8 = undefined;
    if (logic.formCommand(entries, cmd, val, &b)) |kv| {
        if (std.mem.eql(u8, cmd, "set:resolution")) custom = false;
        save(kv[0], kv[1]);
    } else if (std.mem.eql(u8, cmd, "res-custom")) {
        custom = true;
        load();
    } else if (std.mem.eql(u8, cmd, "close")) {
        open = false;
    } else return false;
    return true;
}

/// Keys while the page is open: Esc closes, or leaves a text field first.
pub fn keyEvent(e: *const sdl.SDL_Event) void {
    if (e.type == sdl.SDL_EVENT_KEY_DOWN and e.key.scancode == sdl.SDL_SCANCODE_ESCAPE) {
        if (ui.ui_typing(ui.page)) ui.ui_blur(ui.page) else open = false;
        return;
    }
    ui.ui_input(ui.page, e);
}

/// The pads' buttons while the page is open (input.poll): d-pad and left stick
/// move, A picks, B closes.
pub fn pad(dirs: u16, a: bool, b: bool) void {
    const bits: c_int = @as(c_int, dirs & 0xF) | (@as(c_int, @intFromBool(a)) << 4) | (@as(c_int, @intFromBool(b)) << 5);
    if (ui.ui_pad(ui.page, bits) & 32 != 0) open = false;
}

/// Each frame something is drawn (debug_menu.draw), before ui.frame.
pub fn draw(window: *sdl.SDL_Window) void {
    const m = overlay();
    ui.ui_show(ui.page, open or m[0] != 0);
    ui.ui_class("metrics", "hidden", m[0] == 0);
    inline for (0..4) |c| ui.ui_class("metrics", &[_:0]u8{ 'c', '0' + c }, m[1] == c);
    if (m[0] != 0) debug_menu.metricsText(m[0], window);
    ui.ui_class("page", "hidden", !open);
    defer shown = open;
    if (open and !shown) {
        custom = false;
        listModes(window);
        load();
        ui.ui_focus_first(ui.page);
    }
    if (!open and shown) ui.ui_blur(ui.page);
}
