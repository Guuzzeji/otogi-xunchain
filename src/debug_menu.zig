//! In-game debug menu (F1): render health, pause and frame step, a memory
//! poke and cheats. Dear ImGui drawn over the window after each blit, on the
//! guest thread (the only GL thread). Closed, it costs nothing.
const std = @import("std");
const im = @import("imgui");
const gl_hle = @import("gl_hle.zig");
const d3d = @import("d3d.zig");
const cheats = @import("cheats.zig");
const build_info = @import("build_info");
const commit = std.mem.trim(u8, @embedFile("commit.txt"), " \r\n");

extern fn cImGui_ImplWin32_InitForOpenGL(hwnd: *anyopaque) bool;
extern fn cImGui_ImplWin32_NewFrame() void;
extern fn cImGui_ImplWin32_WndProcHandler(hwnd: *anyopaque, msg: u32, wp: usize, lp: isize) isize;
extern fn cImGui_ImplOpenGL3_InitEx(glsl_version: ?[*:0]const u8) bool;
extern fn cImGui_ImplOpenGL3_NewFrame() void;
extern fn cImGui_ImplOpenGL3_RenderDrawData(data: *im.ImDrawData) void;
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;

const VK_F1 = 0x70;
const WM_KEYDOWN = 0x0100;

/// RECOMP_DEBUG_MENU=1 opens it at boot.
var open = false;
var open_checked = false;
var inited = false;
var paused = false;
var step = false;

/// Window messages: F1 toggles the menu; while it is open ImGui gets the rest.
pub fn wndProc(wnd: anytype, msg: u32, wp: usize, lp: isize) bool {
    if (msg == WM_KEYDOWN and wp == VK_F1 and (lp & (1 << 30)) == 0) { // not auto-repeat
        open = !open;
        return true;
    }
    return inited and open and cImGui_ImplWin32_WndProcHandler(@ptrCast(wnd), msg, wp, lp) != 0;
}

/// Swap holds the current frame while paused; a step lets one through.
pub fn holdFrame() bool {
    if (step) {
        step = false;
        return false;
    }
    return paused;
}

fn nowMs() f64 {
    var f: i64 = 0;
    var t: i64 = 0;
    _ = QueryPerformanceFrequency(&f);
    _ = QueryPerformanceCounter(&t);
    return @as(f64, @floatFromInt(t)) * 1000 / @as(f64, @floatFromInt(f));
}

/// Rates over the last second, and the guest's work time per frame.
var work_hist: [120]f32 = @splat(0);
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
        hist_at = (hist_at + 1) % work_hist.len;
        if (gl_hle.last.work_ms > 1000.0 / 30.0) late += 1;
    }
    const now = nowMs();
    if (now - rate_t0 < 1000) return;
    if (rate_t0 != 0) {
        const dt: f32 = @floatCast((now - rate_t0) / 1000);
        game_fps = @as(f32, @floatFromInt(gl_hle.frame -% rate_f0)) / dt;
        shown_fps = @as(f32, @floatFromInt(gl_hle.shown -% rate_s0)) / dt;
    }
    rate_t0, rate_f0, rate_s0 = .{ now, gl_hle.frame, gl_hle.shown };
}

pub fn text(comptime f: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    im.ImGui_TextUnformatted(std.fmt.bufPrintSentinel(&buf, f, args, 0) catch return);
}

fn env(name: [*:0]const u8) []const u8 {
    return std.mem.span(std.c.getenv(name) orelse "default");
}

pub fn draw(hwnd: anytype) void {
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
        io.*.IniFilename = "logs\\imgui.ini";
        im.ImGui_StyleColorsDark(null);
        const style = im.ImGui_GetStyle();
        im.ImGuiStyle_ScaleAllSizes(style, 1.5);
        style.*.FontScaleMain = 1.5;
        _ = cImGui_ImplWin32_InitForOpenGL(@ptrCast(hwnd));
        _ = cImGui_ImplOpenGL3_InitEx("#version 300 es");
        inited = true;
    }
    cImGui_ImplOpenGL3_NewFrame();
    cImGui_ImplWin32_NewFrame();
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
    text("Otogi recomp v{s} ({s})", .{ build_info.version, commit });
    text("{s}", .{gl_hle.renderer_name});
    text("scale {s}, widescreen {s}, framerate {s}, vsync {s}", .{ env("RECOMP_SCALE"), env("RECOMP_WIDESCREEN"), env("RECOMP_FRAMERATE"), env("RECOMP_VSYNC") });
    im.ImGui_SeparatorText("Frame rate");
    text("game {d:.1} fps (target 30), shown {d:.1} fps, frame {d}", .{ game_fps, shown_fps, gl_hle.frame });
    var max: f32 = 0;
    var sum: f32 = 0;
    for (work_hist) |v| {
        max = @max(max, v);
        sum += v;
    }
    var overlay: [64]u8 = undefined;
    const ov = std.fmt.bufPrintSentinel(&overlay, "avg {d:.1} ms, max {d:.1} ms", .{ sum / work_hist.len, max }, 0) catch "";
    im.ImGui_PlotLinesEx("guest ms", &work_hist, work_hist.len, @intCast(hist_at), ov, 0, 50, .{ .x = 0, .y = 80 }, @sizeOf(f32));
    text("frames over 33.3 ms of guest work: {d}", .{late});
    im.ImGui_SameLine();
    if (im.ImGui_Button("reset")) late = 0;
    im.ImGui_SeparatorText("Last game frame");
    const l = gl_hle.last;
    text("draws {d}, clears {d}, CopyRects {d}, texture uploads {d}", .{ l.draws, l.clears, l.copies, l.uploads });
    const c = gl_hle.cacheSizes();
    im.ImGui_SeparatorText("Host caches");
    text("textures {d}, GL programs {d}, render targets {d}", .{ c.textures, c.programs, c.targets });
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
