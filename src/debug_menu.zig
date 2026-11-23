//! In-game debug menu (F1): render health, pause and frame step, a memory
//! poke and cheats. RmlUi (context 1, src/ui/debug.rml; src/ui.cpp) drawn over
//! the window after each blit, on the render thread (the only GL thread), with
//! the settings page and metrics overlay (src/settings_menu.zig). Closed,
//! they cost nothing.
const std = @import("std");
const ui = @import("ui.zig");
const gl_hle = @import("gl_hle.zig");
const d3d = @import("d3d.zig");
const cheats = @import("cheats.zig");
const logic = @import("logic");
const build_info = @import("build_info");
const commit = std.mem.trim(u8, @embedFile("commit.txt"), " \r\n");

const sdl = @import("sdl");
const manual = @import("manual.zig");
const settings_menu = @import("settings_menu.zig");

const host = @import("host.zig");
extern fn xbox_ContiguousInUseBytes() u32;
extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(*anyopaque) c_int;

/// RECOMP_DEBUG_MENU=1 opens it at boot.
pub var open = false;
var open_checked = false;
var paused = false;
var step = false;
var visible = false; // a menu or the counter was drawn last frame
var started = false; // RmlUi is up

/// Window events: F1 toggles the menu, F10 the settings page. The settings
/// page takes every event while it is open; the debug menu takes the mouse,
/// and keys only while one of its text fields has the focus (else they play
/// the game). True for a key press the game must not also get.
pub fn event(e: *const sdl.SDL_Event) bool {
    const press = e.type == sdl.SDL_EVENT_KEY_DOWN;
    if (press and (e.key.scancode == sdl.SDL_SCANCODE_F1 or e.key.scancode == sdl.SDL_SCANCODE_F10)) {
        if (!e.key.repeat) {
            if (e.key.scancode == sdl.SDL_SCANCODE_F1) open = !open else settings_menu.open = !settings_menu.open;
        }
        return true;
    }
    if (!started) return false;
    if (settings_menu.open) {
        settings_menu.keyEvent(e);
        return press;
    }
    if (!open) return false;
    const typing = ui.ui_typing(ui.debug);
    switch (e.type) {
        sdl.SDL_EVENT_MOUSE_MOTION, sdl.SDL_EVENT_MOUSE_BUTTON_DOWN, sdl.SDL_EVENT_MOUSE_BUTTON_UP, sdl.SDL_EVENT_MOUSE_WHEEL, sdl.SDL_EVENT_TEXT_INPUT, sdl.SDL_EVENT_WINDOW_MOUSE_LEAVE => ui.ui_input(ui.debug, e),
        sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_EVENT_KEY_UP => if (typing) ui.ui_input(ui.debug, e),
        else => {},
    }
    return press and typing;
}

/// Swap holds the current frame while paused or the settings page is open;
/// a step lets one through.
pub fn holdFrame() bool {
    if (settings_menu.open) return true;
    if (step) {
        step = false;
        return false;
    }
    return paused;
}

const nowMs = gl_hle.nowMs;

/// CPU time (kernel + user, 100 ns units) of the process and of the game's
/// thread, which runs the lifted code and records every draw.
fn cpuTimes() [2]u64 {
    return .{ host.processCpu(), if (gl_hle.game_thread) |t| host.threadCpu(t) else 0 };
}
var cpu0: [2]u64 = .{ 0, 0 };
var cpu_pct: [2]f32 = .{ 0, 0 }; // process, game thread; 100 = one core
var mem: host.Mem = .{};
pub var cull_last: [manual.cull.len]manual.CullSite = @splat(.{});

/// Rates over the last half second, and the guest's work time per frame.
var work_hist: [120]f32 = @splat(0);
var draw_hist: [120]f32 = @splat(0);
var hist_at: usize = 0;
var seen_frame: u32 = 0;
var rate_t0: f64 = 0;
var rate_f0: u32 = 0;
var rate_s0: u32 = 0;
var game_fps: f32 = 0;
var shown_fps: f32 = 0;
var late: u32 = 0;
// For the metrics overlay: per half second, the longest time between shown
// frames, and the guest's work and draws per game frame.
var shown_at: f64 = 0;
var gap: f64 = 0;
var worst_ms: f32 = 0;
var work_sum: f32 = 0;
var draws_sum: u64 = 0;
var steps: u32 = 0;
var work_avg: f32 = 0;
var draws_avg: u64 = 0;

/// Every shown frame (draw), menus open or not.
fn sampleRates() void {
    if (gl_hle.frame != seen_frame) {
        seen_frame = gl_hle.frame;
        work_hist[hist_at] = gl_hle.last.work_ms;
        draw_hist[hist_at] = gl_hle.last.draw_ms;
        hist_at = (hist_at + 1) % work_hist.len;
        if (gl_hle.last.work_ms > 1000.0 / 30.0) late += 1;
        cull_last = manual.cull;
        for (&manual.cull) |*c| c.* = .{ .from = c.from };
        work_sum += gl_hle.last.work_ms;
        draws_sum += gl_hle.last.draws;
        steps += 1;
    }
    const now = nowMs();
    if (shown_at != 0) gap = @max(gap, now - shown_at);
    shown_at = now;
    if (now - rate_t0 < 500) return;
    const cpu = cpuTimes();
    if (rate_t0 != 0) {
        const dt: f32 = @floatCast((now - rate_t0) / 1000);
        for (&cpu_pct, cpu, cpu0) |*p, a, b| p.* = @as(f32, @floatFromInt(a - b)) / 1e5 / dt;
        mem = host.memory();
        game_fps = @as(f32, @floatFromInt(gl_hle.frame -% rate_f0)) / dt;
        shown_fps = @as(f32, @floatFromInt(gl_hle.shown -% rate_s0)) / dt;
        worst_ms = @floatCast(gap);
        if (steps != 0) {
            work_avg = work_sum / @as(f32, @floatFromInt(steps));
            draws_avg = draws_sum / steps;
        }
    }
    rate_t0, rate_f0, rate_s0 = .{ now, gl_hle.frame, gl_hle.shown };
    cpu0 = cpu;
    gap, work_sum, draws_sum, steps = .{ 0, 0, 0, 0 };
}

/// The metrics overlay's text (settings_menu.draw), level 1 or 2. It changes
/// twice a second, so the markup is set no more often than that.
pub fn metricsText(level: u8, window: *sdl.SDL_Window) void {
    const ms = if (shown_fps > 0) 1000 / shown_fps else 0;
    if (level == 1) return ui.set("metrics", "{d:.0} fps", .{shown_fps});
    var w: c_int = 0;
    var h: c_int = 0;
    _ = sdl.SDL_GetWindowSizeInPixels(window, &w, &h);
    const gfx = std.mem.span(std.c.getenv("RECOMP_GFX") orelse "d3d11");
    const backend = if (std.ascii.eqlIgnoreCase(gfx, "vulkan")) "Vulkan" else if (std.ascii.eqlIgnoreCase(gfx, "gl")) "OpenGL" else "Direct3D 11";
    ui.set("metrics", "{d:.0} fps &#x00B7; {d:.1} ms, worst {d:.1}<br/><span class=\"more\">game {d:.0} steps/s &#x00B7; {d:.1} ms each &#x00B7; {d} draws<br/>{s} &#x00B7; {d}&#x00D7;{d} &#x00B7; internal {f}x</span>", .{
        shown_fps, ms, worst_ms, game_fps, work_avg, draws_avg, backend, w, h, logic.esc(std.mem.span(std.c.getenv("RECOMP_SCALE") orelse "2")),
    });
}

fn env(name: [*:0]const u8) []const u8 {
    return std.mem.span(std.c.getenv(name) orelse "default");
}

pub fn draw(window: *sdl.SDL_Window) void {
    sampleRates();
    cheats.tick();
    if (!open_checked) {
        open_checked = true;
        if (std.c.getenv("RECOMP_DEBUG_MENU")) |e| open = e[0] == '1';
    }
    // One more pass after the last menu closes, to hide it.
    const want = open or settings_menu.wanted();
    if (!want and !visible) return;
    if (!ui.start(window)) return;
    started = true;
    visible = want;
    var buf: [16]ui.Cmd = undefined;
    for (ui.take(&buf)) |*c| {
        const cmd = c.cmd[0..c.cmd_len];
        const val = c.val[0..c.val_len];
        if (!settings_menu.command(cmd, val) and !command(cmd, val)) _ = cheats.command(cmd, val);
    }
    // The menus show the mouse pointer; input.zig hides it again after them.
    if ((open or settings_menu.open) and !sdl.SDL_CursorVisible()) _ = sdl.SDL_ShowCursor();
    ui.ui_show(ui.debug, open);
    if (open) debugWindow();
    settings_menu.draw(window);
    ui.frame(window, if (!open and !settings_menu.open) settings_menu.overlay() else null);
}

const Tab = enum { render, cheats, memory };
var tab: Tab = .render;
var tab_shown: ?Tab = null;
var cull_open = false;
var bars_at: usize = std.math.maxInt(usize);

/// A click in the menu (ui.take). False if it is not one of the menu's own.
fn command(cmd: []const u8, val: []const u8) bool {
    const eql = std.mem.eql;
    if (eql(u8, cmd, "debug-close")) {
        open = false;
    } else if (eql(u8, cmd, "tab")) {
        tab = std.meta.stringToEnum(Tab, val) orelse tab;
    } else if (eql(u8, cmd, "late-reset")) {
        late = 0;
    } else if (eql(u8, cmd, "profile")) {
        // The sampler (main.zig) logs where each thread spent the next 3 s.
        if (fopen("logs/sample", "wb")) |f| _ = fclose(f);
    } else if (eql(u8, cmd, "cull")) {
        cull_open = !cull_open;
    } else if (eql(u8, cmd, "pause")) {
        paused = !paused;
    } else if (eql(u8, cmd, "step")) {
        step = true;
    } else if (eql(u8, cmd, "metrics")) {
        settings_menu.save("metrics", val); // as the settings page sets it: saved, and shown at once

    } else if (eql(u8, cmd, "mem-addr")) {
        mem_addr = std.fmt.parseInt(u32, std.mem.trim(u8, val, " "), 16) catch mem_addr;
    } else if (eql(u8, cmd, "mem-val")) {
        mem_val = std.fmt.parseInt(u32, std.mem.trim(u8, val, " "), 16) catch mem_val;
    } else if (eql(u8, cmd, "mem-write")) {
        const a = mem_addr & ~@as(u32, 3);
        if (valid(a, 4)) @as(*align(1) u32, @ptrCast(d3d.ptr(a))).* = mem_val;
    } else return false;
    return true;
}

fn debugWindow() void {
    if (tab_shown != tab) {
        tab_shown = tab;
        inline for (comptime std.meta.fieldNames(Tab)) |f| {
            ui.ui_class("tab-" ++ f, "on", tab == @field(Tab, f));
            ui.ui_class("page-" ++ f, "shown", tab == @field(Tab, f));
        }
        if (tab == .cheats) cheats.shape();
        if (tab == .memory) {
            ui.value("mem-addr", "{X:0>8}", .{mem_addr});
            ui.value("mem-val", "{X:0>8}", .{mem_val});
        }
    }
    switch (tab) {
        .render => renderTab(),
        .cheats => cheats.tab(),
        .memory => memoryTab(),
    }
}

fn renderTab() void {
    ui.set("r-head", "Otogi XUnchain v{s} ({s})<br/>{f}<br/>scale {s}, widescreen {s}, framerate {s}, vsync {s}", .{ build_info.version, commit, logic.esc(std.mem.span(gl_hle.renderer_name)), env("RECOMP_SCALE"), env("RECOMP_WIDESCREEN"), env("RECOMP_FRAMERATE"), env("RECOMP_VSYNC") });
    ui.set("r-fps", "game {d:.1} fps (target 30), shown {d:.1} fps, frame {d}", .{ game_fps, shown_fps, gl_hle.frame });
    // Guest ms is the game's code plus draw(), which records; the second graph is draw() alone.
    for ([_]struct { [*:0]const u8, [*:0]const u8, []const u8, *const [120]f32 }{ .{ "g-work", "g-work-txt", "guest ms", &work_hist }, .{ "g-draw", "g-draw-txt", "of it in draw", &draw_hist } }) |g| {
        var max: f32 = 0;
        var sum: f32 = 0;
        for (g[3]) |v| {
            max = @max(max, v);
            sum += v;
        }
        if (bars_at != hist_at) ui.ui_bars(g[0], g[3], g[3].len, @intCast(hist_at), 50);
        ui.set(g[1], "{s}: avg {d:.1} ms, max {d:.1} ms (graph 0 to 50 ms)", .{ g[2], sum / g[3].len, max });
    }
    bars_at = hist_at;
    ui.set("r-late", "frames over 33.3 ms of guest work: {d}", .{late});
    ui.set("r-cpu", "CPU, 100 = one core: all {d:.0}%, game thread {d:.0}%, others {d:.0}%<br/>RAM: {d} MB in use ({d} MB private, peak {d} MB)<br/>guest contiguous memory: {d:.1} of 64 MB", .{ cpu_pct[0], cpu_pct[1], cpu_pct[0] - cpu_pct[1], mem.in_use >> 20, mem.private >> 20, mem.peak >> 20, @as(f32, @floatFromInt(xbox_ContiguousInUseBytes())) / (1 << 20) });
    const l = gl_hle.last;
    ui.set("r-frame", "draws {d} ({d} from the mesh cache, {d} new, {d} merged into another)<br/>clears {d}, CopyRects {d}, texture uploads {d}<br/>game code {d:.1} ms, recording draws {d:.1} ms, waiting on read-backs {d:.1} ms<br/>render thread {d:.1} ms over all passes; objects queued to draw {d} + {d}", .{ l.draws, l.mesh_hits, l.mesh_new, l.merged, l.clears, l.copies, l.uploads, l.work_ms - l.draw_ms - l.sync_ms, l.draw_ms, l.sync_ms, l.render_ms, l.queued[0], l.queued[1] });
    ui.ui_class("cull-btn", "on", cull_open);
    var cull: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&cull);
    if (cull_open) for (cull_last) |s| if (s.tested != 0) w.print("{X:0>6}: {d} tested, {d} visible<br/>", .{ s.from, s.tested, s.visible }) catch break;
    ui.set("r-cull", "{s}", .{w.buffered()});
    const c = gl_hle.cacheSizes();
    ui.set("r-caches", "textures {d}, GL programs {d}, render targets {d}, meshes {d}<br/>vertex programs {d}, pixel shaders {d}, recorded pushbuffers {d}", .{ c.textures, c.programs, c.targets, c.meshes, c.vertex_programs, c.pixel_shaders, c.pushbuffers });
    ui.ui_class("pause", "on", paused);
    inline for (0..3) |i| ui.ui_class("dm-metrics-" ++ [_]u8{'0' + i}, "on", settings_menu.overlay()[0] == i);
}

var mem_addr: u32 = 0x1051C8;
var mem_val: u32 = 0;

/// Guest RAM is 64 MB at VA 0; anything past it is not mapped here.
pub fn valid(va: u32, n: u32) bool {
    return va >= 0x10000 and @as(u64, va) + n <= 0x0400_0000;
}

fn memoryTab() void {
    const a = mem_addr & ~@as(u32, 3);
    if (!valid(a, 64)) return ui.set("mem-dump", "not in guest RAM", .{});
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var row: u32 = 0;
    while (row < 4) : (row += 1) {
        const r = a + row * 16;
        w.print("{X:0>8}: {X:0>8} {X:0>8} {X:0>8} {X:0>8}<br/>", .{ r, d3d.mem32(r), d3d.mem32(r + 4), d3d.mem32(r + 8), d3d.mem32(r + 12) }) catch return;
    }
    w.print("u32 {d}  i32 {d}  f32 {d:.4}", .{ d3d.mem32(a), @as(i32, @bitCast(d3d.mem32(a))), d3d.memf(a) }) catch return;
    ui.set("mem-dump", "{s}", .{w.buffered()});
}
