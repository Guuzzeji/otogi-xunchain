//! The menus' RmlUi host (src/ui.cpp) from Zig: start-up, the files it reads,
//! the commands its on* attributes send, and markup by element id. Context 0
//! is the settings page and metrics overlay, 1 the F1 debug menu.
const std = @import("std");
const sdl = @import("sdl");

pub const page = 0;
pub const debug = 1;

extern fn ui_init(window: *sdl.SDL_Window) bool;
extern fn ui_font(path: [*:0]const u8, fallback: bool) bool;
extern fn ui_font_as(path: [*:0]const u8, family: [*:0]const u8, bold: bool) bool;
extern "c" fn popen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn pclose(*anyopaque) c_int;
extern "c" fn fread([*]u8, usize, usize, *anyopaque) usize;
extern fn ui_load(i: c_int, path: [*:0]const u8) bool;
pub extern fn ui_show(i: c_int, on: bool) void;
pub extern fn ui_input(i: c_int, e: *const sdl.SDL_Event) void;
pub extern fn ui_typing(i: c_int) bool;
pub extern fn ui_blur(i: c_int) void;
pub extern fn ui_pad(i: c_int, bits: c_int) c_int;
pub extern fn ui_focus_first(i: c_int) void;
pub extern fn ui_bars(id: [*:0]const u8, v: [*]const f32, n: c_int, at: c_int, max: f32) void;
extern fn ui_frame(w: c_int, h: c_int, ratio0: f32, ratio1: f32, corner: c_int, box_w: f32, box_h: f32) void;
pub extern fn ui_set(id: [*:0]const u8, rml: [*:0]const u8) void;
pub extern fn ui_class(id: [*:0]const u8, class: [*:0]const u8, on: bool) void;
pub extern fn ui_value(id: [*:0]const u8, value: [*:0]const u8) void;

// The launcher's theme and heading font (build.zig), and the two documents.
const embedded = .{
    .{ "theme.rcss", @embedFile("theme.rcss") },
    .{ "ShipporiMinchoB1-Bold.ttf", @embedFile("ShipporiMinchoB1-Bold.ttf") },
    .{ "settings.rml", @embedFile("ui/settings.rml") },
    .{ "debug.rml", @embedFile("ui/debug.rml") },
};

export fn ui_file(path: [*:0]const u8, len: *usize) ?[*]const u8 {
    const p = std.mem.span(path);
    inline for (embedded) |e| if (std.mem.eql(u8, p, e[0])) {
        len.* = e[1].len;
        return e[1].ptr;
    };
    return null;
}

var state: enum { off, on, failed } = .off;

/// RmlUi, its fonts and documents, the first time a menu is wanted (render
/// thread, GL context current). False if it could not start.
pub fn start(window: *sdl.SDL_Window) bool {
    if (state == .off) {
        state = .failed;
        if (!ui_init(window)) {
            std.debug.print("[UI] RmlUi did not start: no menus\n", .{});
            return false;
        }
        if (@import("builtin").os.tag == .windows) {
            // Segoe UI and Consolas from Windows, as the launcher has them.
            const windir = std.mem.span(std.c.getenv("WINDIR") orelse "C:\\Windows");
            for ([_][]const u8{ "segoeui.ttf", "segoeuib.ttf", "consola.ttf" }) |f| {
                var p: [300]u8 = undefined;
                _ = ui_font(std.fmt.bufPrintSentinel(&p, "{s}\\Fonts\\{s}", .{ windir, f }, 0) catch continue, false);
            }
        } else for ([_]struct { [*:0]const u8, [*:0]const u8, bool }{
            // Linux: the system's sans and mono (fontconfig) under the theme's names.
            .{ "sans-serif", "Segoe UI", false },
            .{ "sans-serif:bold", "Segoe UI", true },
            .{ "monospace", "Consolas", false },
        }) |q| {
            var p: [512]u8 = undefined;
            _ = ui_font_as(fcMatch(q[0], &p) orelse continue, q[1], q[2]);
        }
        _ = ui_font("ShipporiMinchoB1-Bold.ttf", true); // headings, and the fallback for 御伽
        if (!ui_load(page, "settings.rml") or !ui_load(debug, "debug.rml")) {
            std.debug.print("[UI] menu documents did not load\n", .{});
            return false;
        }
        state = .on;
    }
    return state == .on;
}

/// The font file fontconfig picks for `pattern`, or null without fc-match.
fn fcMatch(pattern: [*:0]const u8, buf: *[512]u8) ?[*:0]const u8 {
    var cmd: [128]u8 = undefined;
    const f = popen(std.fmt.bufPrintSentinel(&cmd, "fc-match -f '%{{file}}' '{s}'", .{pattern}, 0) catch return null, "r") orelse return null;
    const n = fread(buf, 1, buf.len - 1, f);
    _ = pclose(f);
    if (n == 0) return null;
    buf[n] = 0;
    return buf[0..n :0];
}

/// Lay out and draw what is shown, over the window (frame buffer 0).
/// `overlay`: only the metrics overlay is shown, at this level and corner
/// (settings_menu.overlay); ui.cpp then draws just that corner.
pub fn frame(window: *sdl.SDL_Window, overlay: ?[2]u8) void {
    var w: c_int = 1;
    var h: c_int = 1;
    _ = sdl.SDL_GetWindowSizeInPixels(window, &w, &h);
    const hf: f32 = @floatFromInt(h);
    // The corner's size in dp, as settings.rml's #metrics needs it.
    const box: [2]f32 = if (overlay) |o| (if (o[0] == 1) .{ 130, 40 } else .{ 380, 80 }) else .{ 0, 0 };
    // Settings page: 15 dp text is 27 px at 1080p, 36 at 1440p, 54 at 4K.
    // Debug menu: about its old ImGui size, growing past 1080p.
    ui_frame(w, h, hf / 600, @max(1, hf / 1080) * 1.25, if (overlay) |o| o[1] else -1, box[0], box[1]);
}

/// Inner markup of element `id`, formatted. ui.cpp skips it if unchanged.
pub fn set(id: [*:0]const u8, comptime f: []const u8, args: anytype) void {
    var buf: [8 * 1024]u8 = undefined;
    ui_set(id, std.fmt.bufPrintSentinel(&buf, f, args, 0) catch return);
}

pub fn value(id: [*:0]const u8, comptime f: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    ui_value(id, std.fmt.bufPrintSentinel(&buf, f, args, 0) catch return);
}

/// Commands from on* attributes (onclick="close"), queued: they arrive while
/// RmlUi walks the very elements a handler may replace.
pub const Cmd = struct { cmd: [64]u8 = undefined, cmd_len: usize = 0, val: [256]u8 = undefined, val_len: usize = 0 };
var cmds: [16]Cmd = undefined;
var cmds_len: usize = 0;

export fn ui_event(cmd: [*:0]const u8, val: [*:0]const u8) void {
    if (cmds_len == cmds.len) return;
    const c = &cmds[cmds_len];
    const a = std.mem.span(cmd);
    const b = std.mem.span(val);
    c.cmd_len = @min(a.len, c.cmd.len);
    c.val_len = @min(b.len, c.val.len);
    @memcpy(c.cmd[0..c.cmd_len], a[0..c.cmd_len]);
    @memcpy(c.val[0..c.val_len], b[0..c.val_len]);
    cmds_len += 1;
}

/// The queued commands, oldest first; the queue is empty after.
pub fn take(out: *[16]Cmd) []Cmd {
    const n = cmds_len;
    @memcpy(out[0..n], cmds[0..n]);
    cmds_len = 0;
    return out[0..n];
}
