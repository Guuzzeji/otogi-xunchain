//! In-game debug menu (F1): render health, pause and frame step, a memory
//! poke and cheats. Dear ImGui drawn over the window after each blit, on the
//! render thread (the only GL thread). Closed, it costs nothing.
const std = @import("std");
const im = @import("imgui");
const gl_hle = @import("gl_hle.zig");
const d3d = @import("d3d.zig");
const cheats = @import("cheats.zig");
const build_info = @import("build_info");
const commit = std.mem.trim(u8, @embedFile("commit.txt"), " \r\n");

const sdl = @import("sdl");
extern fn cImGui_ImplSDL3_InitForOther(window: *sdl.SDL_Window) bool;
extern fn cImGui_ImplSDL3_NewFrame() void;
extern fn cImGui_ImplSDL3_ProcessEvent(event: *const sdl.SDL_Event) bool;
extern fn cImGui_ImplOpenGL3_InitEx(glsl_version: ?[*:0]const u8) bool;
extern fn cImGui_ImplOpenGL3_NewFrame() void;
extern fn cImGui_ImplOpenGL3_RenderDrawData(data: *im.ImDrawData) void;
const manual = @import("manual.zig");

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn GetCurrentThread() callconv(.winapi) *anyopaque;
extern "kernel32" fn GetProcessTimes(*anyopaque, *u64, *u64, kernel: *u64, user: *u64) callconv(.winapi) i32;
extern "kernel32" fn GetThreadTimes(*anyopaque, *u64, *u64, kernel: *u64, user: *u64) callconv(.winapi) i32;
const MemCounters = extern struct { cb: u32 = @sizeOf(MemCounters), faults: u32 = 0, peak_working_set: usize = 0, working_set: usize = 0, quota: [4]usize = @splat(0), pagefile: usize = 0, peak_pagefile: usize = 0, private: usize = 0 };
extern "kernel32" fn K32GetProcessMemoryInfo(*anyopaque, *MemCounters, u32) callconv(.winapi) i32;
extern fn xbox_ContiguousInUseBytes() u32;
extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(*anyopaque) c_int;

/// RECOMP_DEBUG_MENU=1 opens it at boot.
pub var open = false;
var open_checked = false;
var inited = false;
var paused = false;
var step = false;

/// Window events: F1 toggles the menu; while it is open ImGui sees them all.
/// True for a key press the game must not also get: one typed into the menu.
pub fn event(e: *const sdl.SDL_Event) bool {
    const press = e.type == sdl.SDL_EVENT_KEY_DOWN;
    if (press and e.key.scancode == sdl.SDL_SCANCODE_F1) {
        if (!e.key.repeat) open = !open;
        return true;
    }
    if (!inited or !open) return false;
    _ = cImGui_ImplSDL3_ProcessEvent(e);
    return press and im.ImGui_GetIO().*.WantCaptureKeyboard;
}

/// Swap holds the current frame while paused; a step lets one through.
pub fn holdFrame() bool {
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
    var c: u64 = 0;
    var e: u64 = 0;
    var k: [2]u64 = .{ 0, 0 };
    var u: [2]u64 = .{ 0, 0 };
    _ = GetProcessTimes(GetCurrentProcess(), &c, &e, &k[0], &u[0]);
    _ = GetThreadTimes(gl_hle.game_thread orelse GetCurrentThread(), &c, &e, &k[1], &u[1]);
    return .{ k[0] + u[0], k[1] + u[1] };
}
var cpu0: [2]u64 = .{ 0, 0 };
var cpu_pct: [2]f32 = .{ 0, 0 }; // process, game thread; 100 = one core
var mem: MemCounters = .{};
pub var cull_last: [manual.cull.len]manual.CullSite = @splat(.{});

/// Rates over the last second, and the guest's work time per frame.
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

fn sampleRates() void {
    if (gl_hle.frame != seen_frame) {
        seen_frame = gl_hle.frame;
        work_hist[hist_at] = gl_hle.last.work_ms;
        draw_hist[hist_at] = gl_hle.last.draw_ms;
        hist_at = (hist_at + 1) % work_hist.len;
        if (gl_hle.last.work_ms > 1000.0 / 30.0) late += 1;
        cull_last = manual.cull;
        for (&manual.cull) |*c| c.* = .{ .from = c.from };
    }
    const now = nowMs();
    if (now - rate_t0 < 1000) return;
    const cpu = cpuTimes();
    if (rate_t0 != 0) {
        const dt: f32 = @floatCast((now - rate_t0) / 1000);
        for (&cpu_pct, cpu, cpu0) |*p, a, b| p.* = @as(f32, @floatFromInt(a - b)) / 1e5 / dt;
        _ = K32GetProcessMemoryInfo(GetCurrentProcess(), &mem, @sizeOf(MemCounters));
        game_fps = @as(f32, @floatFromInt(gl_hle.frame -% rate_f0)) / dt;
        shown_fps = @as(f32, @floatFromInt(gl_hle.shown -% rate_s0)) / dt;
    }
    rate_t0, rate_f0, rate_s0 = .{ now, gl_hle.frame, gl_hle.shown };
    cpu0 = cpu;
}

pub fn text(comptime f: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    im.ImGui_TextUnformatted(std.fmt.bufPrintSentinel(&buf, f, args, 0) catch return);
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
    if (!open) return;
    if (!inited) {
        _ = im.ImGui_CreateContext(null);
        const io = im.ImGui_GetIO();
        io.*.IniFilename = "debug_menu.ini"; // window layout, beside otogi.exe
        im.ImGui_StyleColorsDark(null);
        const style = im.ImGui_GetStyle();
        im.ImGuiStyle_ScaleAllSizes(style, 1.5);
        style.*.FontScaleMain = 1.5;
        _ = cImGui_ImplSDL3_InitForOther(window);
        _ = cImGui_ImplOpenGL3_InitEx("#version 300 es");
        inited = true;
    }
    cImGui_ImplOpenGL3_NewFrame();
    cImGui_ImplSDL3_NewFrame();
    im.ImGui_NewFrame();
    im.ImGui_SetNextWindowPos(.{ .x = 20, .y = 20 }, im.ImGuiCond_FirstUseEver);
    im.ImGui_SetNextWindowSize(.{ .x = 760, .y = 640 }, im.ImGuiCond_FirstUseEver);
    if (im.ImGui_Begin("Debug (F1)", &open, 0)) {
        if (im.ImGui_BeginTabBar("tabs", 0)) {
            if (im.ImGui_BeginTabItem("Render", null, 0)) {
                renderTab();
                im.ImGui_EndTabItem();
            }
            if (im.ImGui_BeginTabItem("Cheats", null, 0)) {
                cheats.tab();
                im.ImGui_EndTabItem();
            }
            if (im.ImGui_BeginTabItem("Memory", null, 0)) {
                memoryTab();
                im.ImGui_EndTabItem();
            }
            im.ImGui_EndTabBar();
        }
    }
    im.ImGui_End();
    im.ImGui_Render();
    cImGui_ImplOpenGL3_RenderDrawData(im.ImGui_GetDrawData());
}

fn renderTab() void {
    text("Otogi XUnchain v{s} ({s})", .{ build_info.version, commit });
    text("{s}", .{gl_hle.renderer_name});
    text("scale {s}, widescreen {s}, framerate {s}, vsync {s}", .{ env("RECOMP_SCALE"), env("RECOMP_WIDESCREEN"), env("RECOMP_FRAMERATE"), env("RECOMP_VSYNC") });
    im.ImGui_SeparatorText("Frame rate");
    text("game {d:.1} fps (target 30), shown {d:.1} fps, frame {d}", .{ game_fps, shown_fps, gl_hle.frame });
    // Guest ms is the game's code plus draw(), which records; the second graph is draw() alone.
    for ([_]struct { [:0]const u8, *const [120]f32 }{ .{ "guest ms", &work_hist }, .{ "of it in draw", &draw_hist } }) |g| {
        var max: f32 = 0;
        var sum: f32 = 0;
        for (g[1]) |v| {
            max = @max(max, v);
            sum += v;
        }
        var overlay: [64]u8 = undefined;
        const ov = std.fmt.bufPrintSentinel(&overlay, "avg {d:.1} ms, max {d:.1} ms", .{ sum / work_hist.len, max }, 0) catch "";
        im.ImGui_PlotLinesEx(g[0], g[1], work_hist.len, @intCast(hist_at), ov, 0, 50, .{ .x = 0, .y = 80 }, @sizeOf(f32));
    }
    text("frames over 33.3 ms of guest work: {d}", .{late});
    im.ImGui_SameLine();
    if (im.ImGui_Button("reset")) late = 0;
    im.ImGui_SeparatorText("CPU and RAM");
    text("CPU, 100 = one core: all {d:.0}%, game thread {d:.0}%, others {d:.0}%", .{ cpu_pct[0], cpu_pct[1], cpu_pct[0] - cpu_pct[1] });
    text("RAM: {d} MB in use ({d} MB private, peak {d} MB)", .{ mem.working_set >> 20, mem.private >> 20, mem.peak_working_set >> 20 });
    text("guest contiguous memory: {d:.1} of 64 MB", .{@as(f32, @floatFromInt(xbox_ContiguousInUseBytes())) / (1 << 20)});
    // The sampler (main.zig) logs where each thread spent the next 3 s.
    if (im.ImGui_Button("Profile 3 s to otogi.log")) if (fopen("logs\\sample", "wb")) |f| {
        _ = fclose(f);
    };
    im.ImGui_SeparatorText("Last game frame");
    const l = gl_hle.last;
    text("draws {d} ({d} from the mesh cache, {d} new, {d} merged into another)", .{ l.draws, l.mesh_hits, l.mesh_new, l.merged });
    text("clears {d}, CopyRects {d}, texture uploads {d}", .{ l.clears, l.copies, l.uploads });
    text("game code {d:.1} ms, recording draws {d:.1} ms, waiting on read-backs {d:.1} ms", .{ l.work_ms - l.draw_ms - l.sync_ms, l.draw_ms, l.sync_ms });
    text("render thread {d:.1} ms over all passes; objects queued to draw {d} + {d}", .{ l.render_ms, l.queued[0], l.queued[1] });
    if (im.ImGui_TreeNode("Frustum tests by call site")) {
        for (cull_last) |s| if (s.tested != 0) text("{X:0>6}: {d} tested, {d} visible", .{ s.from, s.tested, s.visible });
        im.ImGui_TreePop();
    }
    const c = gl_hle.cacheSizes();
    im.ImGui_SeparatorText("Host caches");
    text("textures {d}, GL programs {d}, render targets {d}, meshes {d}", .{ c.textures, c.programs, c.targets, c.meshes });
    text("vertex programs {d}, pixel shaders {d}, recorded pushbuffers {d}", .{ c.vertex_programs, c.pixel_shaders, c.pushbuffers });
    im.ImGui_SeparatorText("Game");
    _ = im.ImGui_Checkbox("Pause", &paused);
    im.ImGui_SameLine();
    if (im.ImGui_Button("Step frame")) step = true;
}

var mem_addr: u32 = 0x1051C8;
var mem_val: u32 = 0;

/// Guest RAM is 64 MB at VA 0; anything past it is not mapped here.
pub fn valid(va: u32, n: u32) bool {
    return va >= 0x10000 and @as(u64, va) + n <= 0x0400_0000;
}

fn memoryTab() void {
    _ = im.ImGui_InputScalarEx("address", im.ImGuiDataType_U32, &mem_addr, null, null, "%08X", im.ImGuiInputTextFlags_CharsHexadecimal);
    if (!valid(mem_addr & ~@as(u32, 3), 64)) return text("not in guest RAM", .{});
    const a = mem_addr & ~@as(u32, 3);
    var row: u32 = 0;
    while (row < 4) : (row += 1) {
        const r = a + row * 16;
        text("{X:0>8}: {X:0>8} {X:0>8} {X:0>8} {X:0>8}", .{ r, d3d.mem32(r), d3d.mem32(r + 4), d3d.mem32(r + 8), d3d.mem32(r + 12) });
    }
    text("u32 {d}  i32 {d}  f32 {d:.4}", .{ d3d.mem32(a), @as(i32, @bitCast(d3d.mem32(a))), d3d.memf(a) });
    _ = im.ImGui_InputScalarEx("value", im.ImGuiDataType_U32, &mem_val, null, null, "%08X", im.ImGuiInputTextFlags_CharsHexadecimal);
    im.ImGui_SameLine();
    if (im.ImGui_Button("write u32")) @as(*align(1) u32, @ptrCast(d3d.ptr(a))).* = mem_val;
}
