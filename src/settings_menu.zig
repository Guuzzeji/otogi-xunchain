//! The settings page (F10, or Back+Start on a pad): settings.ini as a form,
//! for players. Each change is saved at once (setup/logic.zig, the launcher's
//! own, keeps the file's comments) and put in the environment, where the game
//! reads its settings; the ones logic.known marks live apply at once, the rest
//! at the next start. The game is held while it is open (debug_menu.holdFrame).
//! Also the frame rate counter (fps_counter). Drawn inside the debug menu's
//! ImGui frame, on the render thread; text scales with the window's height.
const std = @import("std");
const im = @import("imgui");
const sdl = @import("sdl");
const logic = @import("logic");
const gl_hle = @import("gl_hle.zig");
const cheats = @import("cheats.zig");
const debug_menu = @import("debug_menu.zig");
const text = debug_menu.text;

extern fn _putenv(s: [*:0]const u8) c_int;
extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn fread([*]u8, usize, usize, *anyopaque) usize;
extern "c" fn fwrite([*]const u8, usize, usize, *anyopaque) usize;
extern "c" fn fclose(*anyopaque) c_int;

pub var open = false;
var shown = false; // open last frame
var counter: ?bool = null; // fps_counter, read again when it changes

var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
var ini: []const u8 = &.{};
var entries: []logic.Entry = &.{};
var bufs: [32][128:0]u8 = undefined; // text fields, by entry
var status: []const u8 = "";
// A change, made after the rows are drawn: saving reloads `entries`.
var change_key: [64]u8 = undefined;
var change_val: [128]u8 = undefined;
var change: ?[2]usize = null;
var modes: [10][12:0]u8 = undefined; // the display's resolutions, as "1920x1080"
var modes_len: usize = 0;

/// The page or the counter wants an ImGui frame.
pub fn wanted() bool {
    if (counter == null) counter = if (std.c.getenv("RECOMP_FPS_COUNTER")) |e| e[0] == '1' else false;
    return open or counter.?;
}

fn load() void {
    _ = arena.reset(.retain_capacity);
    const a = arena.allocator();
    ini = &.{};
    entries = &.{};
    const f = fopen("settings.ini", "rb") orelse return;
    const buf = a.alloc(u8, 64 * 1024) catch return;
    ini = buf[0..fread(buf.ptr, 1, buf.len, f)];
    _ = fclose(f);
    entries = logic.entries(a, ini) catch &.{};
    const n = @min(entries.len, bufs.len);
    for (entries[0..n], bufs[0..n]) |e, *b| {
        @memset(b, 0);
        @memcpy(b[0..@min(e.value.len, b.len)], e.value[0..@min(e.value.len, b.len)]);
    }
}

fn set(key: []const u8, value: []const u8) void {
    const n = @min(key.len, change_key.len);
    const m = @min(value.len, change_val.len);
    @memcpy(change_key[0..n], key[0..n]);
    @memcpy(change_val[0..m], value[0..m]);
    change = .{ n, m };
}

/// Save a change to the file as it is now, put it in the environment and
/// apply it if it can be. Render thread.
pub fn save(key: []const u8, value: []const u8) void {
    load();
    const new = logic.withValue(std.heap.page_allocator, ini, key, value) catch return;
    defer std.heap.page_allocator.free(new);
    const f = fopen("settings.ini", "wb") orelse {
        status = "Could not write settings.ini.";
        return;
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
    if (eql(u8, key, "fps_counter")) counter = null;
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

/// Dimmed and wrapped.
fn note(s: []const u8) void {
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, im.ImGui_GetStyle().*.Colors[im.ImGuiCol_TextDisabled]);
    im.ImGui_PushTextWrapPos(0);
    im.ImGui_TextUnformattedEx(s.ptr, s.ptr + s.len);
    im.ImGui_PopTextWrapPos();
    im.ImGui_PopStyleColor();
}

/// A choice of several, on the line before while it fits.
fn chip(first: bool, label: [*:0]const u8, on: bool) bool {
    if (!first) im.ImGui_SameLine();
    if (!first and im.ImGui_GetContentRegionAvail().x < im.ImGui_CalcTextSize(label).x + im.ImGui_GetFrameHeight() * 1.5) im.ImGui_NewLine();
    return im.ImGui_RadioButton(label, on);
}

fn row(i: usize, e: logic.Entry) void {
    const k = logic.knownSetting(e.key);
    const eql = std.mem.eql;
    const Kind = @FieldType(logic.Known, "kind");
    const kind: Kind = if (k) |x| x.kind else if (eql(u8, e.value, "0") or eql(u8, e.value, "1")) .toggle else .text;
    var b: [160]u8 = undefined;
    im.ImGui_PushIDStr(e.key.ptr, e.key.ptr + e.key.len);
    defer im.ImGui_PopID();
    text("{s}", .{if (k) |x| x.label else e.key});
    if (!(if (k) |x| x.live else false)) {
        im.ImGui_SameLine();
        im.ImGui_TextDisabled("(applies after restart)");
    }
    if (e.help.len != 0) note(e.help);
    switch (kind) {
        .chips => {
            var listed = false;
            for (k.?.opts, 0..) |o, n| {
                listed = listed or eql(u8, o.v, e.value);
                if (chip(n == 0, @ptrCast(std.fmt.bufPrintSentinel(&b, "{s}", .{o.label}, 0) catch return), eql(u8, o.v, e.value))) set(e.key, o.v);
            }
            if (!listed) _ = chip(false, @ptrCast(std.fmt.bufPrintSentinel(&b, "{s}", .{e.value}, 0) catch return), true);
        },
        .resolution => {
            if (chip(true, "Desktop's", e.value.len == 0)) set(e.key, "");
            var listed = e.value.len == 0;
            for (modes[0..modes_len]) |*m| {
                const v = std.mem.sliceTo(m, 0);
                listed = listed or eql(u8, v, e.value);
                if (chip(false, m, eql(u8, v, e.value))) set(e.key, v);
            }
            if (!listed) _ = chip(false, @ptrCast(std.fmt.bufPrintSentinel(&b, "{s}", .{e.value}, 0) catch return), true);
        },
        .toggle => {
            var on = eql(u8, e.value, "1");
            if (im.ImGui_Checkbox("On", &on)) set(e.key, if (on) "1" else "0");
        },
        .stepper => {
            if (im.ImGui_Button(" - ")) set(e.key, std.fmt.bufPrint(&b, "{d}", .{logic.stepDistance(e.value, false)}) catch return);
            im.ImGui_SameLine();
            text("{s}x", .{if (e.value.len == 0) "1" else e.value});
            im.ImGui_SameLine();
            if (im.ImGui_Button(" + ")) set(e.key, std.fmt.bufPrint(&b, "{d}", .{logic.stepDistance(e.value, true)}) catch return);
        },
        .text => if (i < bufs.len) {
            im.ImGui_SetNextItemWidth(im.ImGui_GetFontSize() * 12);
            _ = im.ImGui_InputText("##v", &bufs[i], bufs[i].len, 0);
            if (im.ImGui_IsItemDeactivatedAfterEdit()) set(e.key, std.mem.sliceTo(&bufs[i], 0));
        },
    }
    im.ImGui_Spacing();
    im.ImGui_Separator();
}

/// Inside the ImGui frame (debug_menu.draw).
pub fn draw(window: *sdl.SDL_Window) void {
    const io = im.ImGui_GetIO();
    const vp = im.ImGui_GetMainViewport();
    const st = im.ImGui_GetStyle();
    // About 27 px at 1080p, 36 at 1440p, 54 at 4K.
    const fs = @max(16, vp.*.Size.y / 40);
    im.ImGui_PushFontFloat(null, fs / st.*.FontScaleMain);
    defer im.ImGui_PopFont();
    _ = wanted(); // reads fps_counter
    if (counter.?) {
        im.ImGui_SetNextWindowPosEx(.{ .x = vp.*.Pos.x + vp.*.Size.x - fs * 0.5, .y = vp.*.Pos.y + fs * 0.5 }, im.ImGuiCond_Always, .{ .x = 1, .y = 0 });
        im.ImGui_SetNextWindowBgAlpha(0.4);
        if (im.ImGui_Begin("##fps", null, im.ImGuiWindowFlags_NoDecoration | im.ImGuiWindowFlags_AlwaysAutoResize | im.ImGuiWindowFlags_NoInputs | im.ImGuiWindowFlags_NoFocusOnAppearing | im.ImGuiWindowFlags_NoSavedSettings)) text("{d:.0} fps", .{debug_menu.shown_fps});
        im.ImGui_End();
    }
    // Arrows / d-pad move, Enter / Space / A pick; mouse too.
    const nav = im.ImGuiConfigFlags_NavEnableKeyboard | im.ImGuiConfigFlags_NavEnableGamepad;
    io.*.ConfigFlags = if (open) io.*.ConfigFlags | nav else io.*.ConfigFlags & ~@as(c_int, nav);
    defer shown = open;
    if (!open) return;
    if (!shown) {
        load();
        listModes(window);
        im.ImGui_SetNextWindowFocus();
    }
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = fs, .y = fs * 0.6 });
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_FramePadding, .{ .x = fs * 0.4, .y = fs * 0.2 });
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_ItemSpacing, .{ .x = fs * 0.6, .y = fs * 0.35 });
    im.ImGui_PushStyleVar(im.ImGuiStyleVar_ScrollbarSize, fs * 0.6);
    defer im.ImGui_PopStyleVarEx(4);
    im.ImGui_SetNextWindowPosEx(.{ .x = vp.*.Pos.x + vp.*.Size.x / 2, .y = vp.*.Pos.y + vp.*.Size.y / 2 }, im.ImGuiCond_Always, .{ .x = 0.5, .y = 0.5 });
    im.ImGui_SetNextWindowSize(.{ .x = @min(vp.*.Size.x * 0.92, fs * 34), .y = vp.*.Size.y * 0.88 }, im.ImGuiCond_Always);
    const flags = im.ImGuiWindowFlags_NoCollapse | im.ImGuiWindowFlags_NoResize | im.ImGuiWindowFlags_NoMove | im.ImGuiWindowFlags_NoSavedSettings;
    if (im.ImGui_Begin("Settings###settings", &open, flags)) {
        note("Saved to settings.ini as you change them; the game waits meanwhile. Back+Start, F10, B or Esc closes.");
        if (status.len != 0) text("{s}", .{status});
        if (entries.len == 0) text("No settings.ini beside otogi.exe.", .{});
        im.ImGui_Separator();
        for (entries, 0..) |e, i| row(i, e);
        // B or Esc closes, unless it is leaving a text field.
        if (im.ImGui_IsWindowFocused(im.ImGuiFocusedFlags_RootAndChildWindows) and !im.ImGui_IsAnyItemActive() and
            (im.ImGui_IsKeyPressedEx(im.ImGuiKey_Escape, false) or im.ImGui_IsKeyPressedEx(im.ImGuiKey_GamepadFaceRight, false))) open = false;
    }
    im.ImGui_End();
    if (change) |c| {
        change = null;
        save(change_key[0..c[0]], change_val[0..c[1]]);
    }
}
