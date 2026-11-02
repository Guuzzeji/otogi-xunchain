//! otogi-setup.exe: builds the game from the player's own disc image.
//! Checks the ISO, extracts game\, fetches pinned Zig and Python (+ Capstone),
//! lifts the XBE to C, builds, and leaves a playable folder:
//!   <out>\otogi.exe, the ANGLE DLLs, settings.ini, game\
//! Work files go to <out>\build; each finished step leaves a stamp in
//! <out>\build\.stamps, so a rerun picks up where it stopped. Once a step runs,
//! every later step runs too.
const std = @import("std");
const Io = std.Io;
const w32 = std.os.windows;
const im = @import("imgui");
const xiso = @import("xiso");

extern fn win_init(title: [*:0]const u16, w: c_int, h: c_int) bool;
extern fn win_begin() bool;
extern fn win_end() void;
extern fn win_pick_iso(buf: [*]u8, len: c_int) bool;
extern fn win_pick_folder(buf: [*]u8, len: c_int) bool;
extern fn win_open(path: [*:0]const u8) void;
extern fn win_gpu_name() [*:0]const u8;
extern fn win_texture_dds(data: [*]const u8, len: c_int, w: *c_int, h: *c_int) ?*anyopaque;
extern fn win_font_memory(data: *const anyopaque, len: c_int) ?*im.ImFont;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn SetEnvironmentVariableA(name: [*:0]const u8, value: [*:0]const u8) callconv(.winapi) c_int;
extern "kernel32" fn GetDiskFreeSpaceExA(dir: [*:0]const u8, avail: *u64, total: ?*u64, free: ?*u64) callconv(.winapi) c_int;
extern "kernel32" fn GetFileAttributesA(path: [*:0]const u8) callconv(.winapi) u32;

/// Release-time `git archive` of the repo (build.zig), and its commit.
const source_zip = @embedFile("source.zip");
const build_info = @import("build_info");
/// "v0.6.0 (abc1234)": the version in build.zig.zon and the commit built.
const version = "v" ++ build_info.version ++ " (" ++ build_info.commit ++ ")";

const xbe_sha1 = "abf12bb66fcbd9f694c223419a2309c1a5f72293";
/// <exe dir>\otogi-setup-iso.txt: the path of the last disc image that checked out.
var remembered_buf: [1100]u8 = undefined;
var remembered: []const u8 = "otogi-setup-iso.txt";
/// game\ (2.2 GB) plus the build folder and Zig's cache, measured: ~3.5 GB.
const need_gb = 5;

const Download = struct { url: []const u8, sha256: []const u8, name: []const u8 };
const zig_dl: Download = .{
    .url = "https://ziglang.org/download/0.17.0/zig-x86_64-windows-0.17.0.zip",
    .sha256 = "b5663f69581dcf391293fbf16c06cb80d81d806545ce618b4d0bab7f0eb8c428",
    .name = "zig-x86_64-windows-0.17.0.zip",
};
const python_dl: Download = .{
    .url = "https://www.python.org/ftp/python/3.14.7/python-3.14.7-embed-amd64.zip",
    .sha256 = "d297e5ff019966817ad8502465176139f2d3d840fa4ed84b13bed399a6ab1f15",
    .name = "python-3.14.7-embed-amd64.zip",
};
const capstone_dl: Download = .{
    .url = "https://files.pythonhosted.org/packages/50/e6/6f06fdb6a9ed32b2f7cd9c036b92d5324112c3ef7080f2c71efc367d40dd/capstone-5.0.9-py3-none-win_amd64.whl",
    .sha256 = "732cedbbb56d42e723f14d7af6387f1454194a820b4b96b56d1e53f865ef85d0",
    .name = "capstone-5.0.9-py3-none-win_amd64.whl",
};

const steps = [_][:0]const u8{ "Check the disc image", "Extract the game files", "Unpack the source code", "Download Zig", "Download Python and Capstone", "Translate the game code to C", "Compile the game", "Finish" };

// ── Shared between the UI and the worker ───────────────────────────────────
var iso_buf: [1024:0]u8 = @splat(0);
var out_buf: [1024:0]u8 = @splat(0);
var running = std.atomic.Value(bool).init(false);
var step_at = std.atomic.Value(u32).init(0);
var result: enum { none, ok, failed } = .none;
var fail_msg: [256:0]u8 = @splat(0);
var ram_gb: u64 = 0;
var started_ms: u64 = 0;
var finished_ms: u64 = 0;
var step_ms: u64 = 0; // when the current step started

/// Seconds each step takes on a first run, measured 2026-11-01 on a 12-core i5-12600K with a
/// fast connection (setup.log stamps each step; 8 min 15 s in all; extract is 5 s from a
/// warm cache, so 20 here). Steps already done count 0.
/// ponytail: fixed guesses; scale by the measured speed if they prove far off.
const step_secs = [_]f32{ 1, 20, 1, 20, 2, 230, 240, 1 };
var step_left: [steps.len]f32 = step_secs;

/// Cancel: the worker stops at the next step; tools die with the job.
var cancel = std.atomic.Value(bool).init(false);
var cancel_armed_at: f64 = -10;
var job: ?w32.HANDLE = null;
extern "kernel32" fn CreateJobObjectA(sa: ?*anyopaque, name: ?[*:0]const u8) callconv(.winapi) ?w32.HANDLE;
extern "kernel32" fn SetInformationJobObject(job: w32.HANDLE, class: c_int, info: *const anyopaque, len: u32) callconv(.winapi) c_int;
extern "kernel32" fn AssignProcessToJobObject(job: w32.HANDLE, process: w32.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn TerminateJobObject(job: w32.HANDLE, code: u32) callconv(.winapi) c_int;

/// Tools and everything they start live in one job. KILL_ON_JOB_CLOSE: when
/// setup exits (or is closed mid-build) they all die with it.
fn makeJob() void {
    job = CreateJobObjectA(null, null);
    var info: [144]u8 = @splat(0); // JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    std.mem.writeInt(u32, info[16..20], 0x2000, .little); // BasicLimitInformation.LimitFlags = KILL_ON_JOB_CLOSE
    if (job) |j| _ = SetInformationJobObject(j, 9, &info, info.len); // JobObjectExtendedLimitInformation
}

/// Seconds left: the rest of the current step (never below a tenth of it,
/// so an overrun reads as "almost") plus every later step.
fn secsLeft() f32 {
    const at = step_at.load(.acquire);
    if (at >= steps.len) return 0;
    const in_step = @as(f32, @floatFromInt(GetTickCount64() -| step_ms)) / 1000;
    var left = @max(step_left[at] - in_step, step_left[at] * 0.1);
    for (step_left[at + 1 ..]) |v| left += v;
    return left;
}

/// "about 6 min", "about 40 s".
fn approx(buf: []u8, secs: f32) [:0]const u8 {
    const s_: u32 = @intFromFloat(@max(secs, 0));
    if (s_ >= 90) return std.fmt.bufPrintSentinel(buf, "about {d} min", .{(s_ + 30) / 60}, 0) catch "";
    return std.fmt.bufPrintSentinel(buf, "about {d} s", .{@max(5, (s_ + 4) / 5 * 5)}, 0) catch "";
}

/// Before a run: steps whose stamps exist cost nothing.
fn estimateFromStamps(io: Io) f32 {
    var total: f32 = 0;
    const names = [_][]const u8{ "", "extract", "source", "zig", "python", "lift", "build", "" };
    var redo = false;
    for (step_secs, names) |secs, name| {
        var p: [1200]u8 = undefined;
        const stamp = std.fmt.bufPrint(&p, "{s}\\build\\.stamps\\{s}", .{ std.mem.sliceTo(&out_buf, 0), name }) catch continue;
        const have = name.len != 0 and !redo and if (Io.Dir.cwd().access(io, stamp, .{})) |_| true else |_| false;
        if (name.len != 0 and !have) redo = true;
        if (!have) total += secs * slowFactor(name);
    }
    return total;
}

fn slowFactor(name: []const u8) f32 {
    return if (std.mem.eql(u8, name, "build") and ram_gb != 0 and ram_gb < 16) 2.5 else 1;
}

// ── Look: the title screen's indigo, crimson, gold, washi cream and the
// blue spirit lights; seigaiha waves on the bands ───────────────────────────
fn rgb(hex: u24) im.ImVec4 {
    return .{ .x = @as(f32, @floatFromInt(hex >> 16)) / 255, .y = @as(f32, @floatFromInt((hex >> 8) & 0xFF)) / 255, .z = @as(f32, @floatFromInt(hex & 0xFF)) / 255, .w = 1 };
}
fn col32(hex: u24) u32 { // ImU32 is ABGR
    return colA(hex, 1);
}
fn colA(hex: u24, a: f32) u32 {
    const alpha: u32 = @intFromFloat(std.math.clamp(a, 0, 1) * 255);
    return alpha << 24 | @as(u32, hex & 0xFF) << 16 | @as(u32, hex & 0xFF00) | @as(u32, hex >> 16);
}
const indigo = 0x140808; // the cover's red-black
const panel = 0x1E1E3C;
const crimson = 0x9E2B25;
const band = 0x5A1713;
const gold = 0xD4A84B;
const gold_dim = 0x7A6230;
const cream = 0xEFE6D2;
const muted = 0xBDB19A;
const spirit = 0x8FD0FF;
const good = 0x8DBF6B;
const bad = 0xE0604F;

// ── Art. Bundled: an OFL font (Shippori Mincho B1 Bold, subset); see
// setup/assets/README.md. Once a disc
// image checks out, the game's own menu art is read from it: nothing of the
// game ships in this exe.
const Art = struct {
    tex: ?*anyopaque = null,
    w: f32 = 0,
    h: f32 = 0,
    fn ref(a: Art) im.ImTextureRef {
        return .{ ._TexData = null, ._TexID = @intFromPtr(a.tex) };
    }
};
var disc: struct { title: Art = .{}, raikoh: Art = .{}, waves: Art = .{}, brush: Art = .{} } = .{};
var disc_loaded = false;

/// The game's menu textures (plain DDS) from the disc's menu\ folder.
fn loadDiscArt(io: Io, gpa: std.mem.Allocator, img: xiso.Image) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const root = img.readDir(a, img.root_sector, img.root_size) catch return;
    const menu = for (root) |e| {
        if (e.is_dir and std.ascii.eqlIgnoreCase(e.name, "menu")) break e;
    } else return;
    const files = img.readDir(a, menu.sector, menu.size) catch return;
    inline for (.{ .{ "title", "title.dds" }, .{ "raikoh", "fe_end00.dds" }, .{ "waves", "fe_bg03A.dds" }, .{ "brush", "fe_lo000.dds" } }) |f| {
        for (files) |e| if (std.ascii.eqlIgnoreCase(e.name, f[1])) {
            const data = a.alloc(u8, e.size) catch break;
            const n = img.file.readPositionalAll(io, data, img.base + @as(u64, e.sector) * 2048) catch break;
            var w: c_int = 0;
            var h: c_int = 0;
            @field(disc, f[0]) = .{ .tex = win_texture_dds(data.ptr, @intCast(n), &w, &h), .w = @floatFromInt(w), .h = @floatFromInt(h) };
        };
    }
    disc_loaded = disc.title.tex != null;
}

/// Part of a texture (uv rect) into a screen rect.
fn image(dl: *im.ImDrawList, art: Art, a: im.ImVec2, b: im.ImVec2, uv0: im.ImVec2, uv1: im.ImVec2, tint: u32) void {
    if (art.tex == null) return;
    im.ImDrawList_AddImageEx(dl, art.ref(), a, b, uv0, uv1, tint);
}

/// A texture repeated over a rect, tiles of `tile` pixels wide.
fn tiled(dl: *im.ImDrawList, art: Art, a: im.ImVec2, b: im.ImVec2, tile: f32, tint: u32) void {
    if (art.tex == null) return;
    const th = tile * art.h / art.w;
    im.ImDrawList_PushClipRect(dl, a, b, true);
    defer im.ImDrawList_PopClipRect(dl);
    var y = a.y;
    while (y < b.y) : (y += th) {
        var x = a.x;
        while (x < b.x) : (x += tile) im.ImDrawList_AddImageEx(dl, art.ref(), .{ .x = x, .y = y }, .{ .x = x + tile, .y = y + th }, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }, tint);
    }
}

var font_title: ?*im.ImFont = null;
var font_head: ?*im.ImFont = null;
var font_jp: ?*im.ImFont = null;
var font_mono: ?*im.ImFont = null;
var dpi: f32 = 1;

fn px(v: f32) f32 {
    return v * dpi;
}

/// Called by window.cpp before it scales the style for the monitor's DPI.
export fn setup_style() void {
    const s = im.ImGui_GetStyle();
    im.ImGui_StyleColorsDark(s);
    const c = &s.*.Colors;
    c[im.ImGuiCol_Text] = rgb(cream);
    c[im.ImGuiCol_TextDisabled] = rgb(muted);
    c[im.ImGuiCol_WindowBg] = rgb(indigo);
    c[im.ImGuiCol_ChildBg] = .{ .x = 0.118, .y = 0.118, .z = 0.235, .w = 0.82 };
    c[im.ImGuiCol_Border] = rgb(gold_dim);
    c[im.ImGuiCol_FrameBg] = rgb(0x1E0D0B);
    c[im.ImGuiCol_FrameBgHovered] = rgb(0x2A1310);
    c[im.ImGuiCol_FrameBgActive] = rgb(0x351814);
    c[im.ImGuiCol_Button] = rgb(crimson);
    c[im.ImGuiCol_ButtonHovered] = rgb(0xB8362E);
    c[im.ImGuiCol_ButtonActive] = rgb(0x7E211C);
    c[im.ImGuiCol_PlotHistogram] = rgb(crimson);
    c[im.ImGuiCol_ScrollbarBg] = .{ .x = 0, .y = 0, .z = 0, .w = 0 };
    c[im.ImGuiCol_ScrollbarGrab] = rgb(0x5A3A30);
    c[im.ImGuiCol_TextSelectedBg] = rgb(0x6B2A25);
    s.*.WindowPadding = .{ .x = 18, .y = 14 };
    s.*.FramePadding = .{ .x = 10, .y = 7 };
    s.*.ItemSpacing = .{ .x = 10, .y = 8 };
    s.*.FrameRounding = 3;
    s.*.ChildRounding = 4;
    s.*.GrabRounding = 3;
    s.*.WindowBorderSize = 0;
    s.*.ChildBorderSize = 1;
    s.*.FrameBorderSize = 1;
    c[im.ImGuiCol_Border] = rgb(gold_dim);
    s.*.FontSizeBase = 17;
    s.*.DisabledAlpha = 0.7;
    const fonts = im.ImGui_GetIO().*.Fonts;
    // Stock Windows fonts; ImGui's own if one is missing.
    _ = addFont(fonts, "C:\\Windows\\Fonts\\segoeui.ttf");
    const mincho = @embedFile("assets/ShipporiMinchoB1-Bold.ttf");
    font_head = win_font_memory(mincho, mincho.len);
    font_title = font_head;
    font_jp = font_head; // the subset carries 御伽
    font_mono = addFont(fonts, "C:\\Windows\\Fonts\\consola.ttf");
}

fn addFont(fonts: *im.ImFontAtlas, path: [*:0]const u8) ?*im.ImFont {
    if (GetFileAttributesA(path) == 0xFFFFFFFF) return null;
    return im.ImFontAtlas_AddFontFromFileTTF(fonts, path, 17, null, null);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    ram_gb = (std.process.totalSystemMemory() catch 0) >> 30;
    var exe_dir: [1024]u8 = undefined;
    const n = std.process.executableDirPath(io, &exe_dir) catch 0;
    _ = std.fmt.bufPrintSentinel(&out_buf, "{s}\\Otogi", .{exe_dir[0..n]}, 0) catch {};
    remembered = std.fmt.bufPrint(&remembered_buf, "{s}\\otogi-setup-iso.txt", .{exe_dir[0..n]}) catch remembered;
    if (!win_init(std.unicode.utf8ToUtf16LeStringLiteral("Otogi: Myth of Demons - Setup v" ++ build_info.version), 1240, 960)) return error.NoWindow;
    dpi = im.ImGui_GetStyle().*.FontScaleDpi;
    makeJob();

    var u: Ui = .{ .io = io, .gpa = gpa };
    // otogi-setup.exe <iso> <output folder>: start building at once.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3) {
        _ = try std.fmt.bufPrintSentinel(&iso_buf, "{s}", .{args[1]}, 0);
        _ = try std.fmt.bufPrintSentinel(&out_buf, "{s}", .{args[2]}, 0);
        u.checkIso();
        u.start();
    } else {
        u.findIso(exe_dir[0..n]);
    }
    while (win_begin()) {
        if (u.thread != null and !running.load(.acquire)) {
            u.thread.?.join();
            u.thread = null;
        }
        u.tailLog();
        u.draw();
        win_end();
    }
}

const Ui = struct {
    io: Io,
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    log: std.ArrayList(u8) = .empty,
    log_off: u64 = 0,
    iso_state: enum { none, ok, wrong, unreadable } = .none,
    copied_at: f64 = -10,

    /// At startup: the last disc image that checked out, else the first .iso
    /// beside the exe. Picking it again would only repeat what we know.
    fn findIso(u: *Ui, exe_dir: []const u8) void {
        var buf: [1024]u8 = undefined;
        if (Io.Dir.cwd().readFile(u.io, remembered, &buf)) |last| {
            _ = std.fmt.bufPrintSentinel(&iso_buf, "{s}", .{last}, 0) catch {};
            u.checkIso();
            if (u.iso_state == .ok) return;
        } else |_| {}
        @memset(&iso_buf, 0);
        u.iso_state = .none;
        var dir = Io.Dir.cwd().openDir(u.io, exe_dir, .{ .iterate = true }) catch return;
        defer dir.close(u.io);
        var it = dir.iterate();
        while (it.next(u.io) catch null) |e| {
            if (e.kind != .file or !std.ascii.endsWithIgnoreCase(e.name, ".iso")) continue;
            _ = std.fmt.bufPrintSentinel(&iso_buf, "{s}\\{s}", .{ exe_dir, e.name }, 0) catch continue;
            u.checkIso();
            if (u.iso_state == .ok) return;
        }
        @memset(&iso_buf, 0);
        u.iso_state = .none;
    }

    fn checkIso(u: *Ui) void {
        const path = std.mem.sliceTo(&iso_buf, 0);
        if (path.len == 0) {
            u.iso_state = .none;
            return;
        }
        const hex = xbeSha1(u.io, u.gpa, path) catch {
            u.iso_state = .unreadable;
            return;
        };
        u.iso_state = if (std.mem.eql(u8, &hex, xbe_sha1)) .ok else .wrong;
        if (u.iso_state == .ok) Io.Dir.cwd().writeFile(u.io, .{ .sub_path = remembered, .data = path }) catch {};
        if (u.iso_state == .ok and !disc_loaded) {
            const f = Io.Dir.cwd().openFile(u.io, path, .{}) catch return;
            defer f.close(u.io);
            loadDiscArt(u.io, u.gpa, xiso.Image.open(u.io, f) catch return);
        }
    }

    fn start(u: *Ui) void {
        cancel.store(false, .release);
        step_left = step_secs;
        step_left[6] *= slowFactor("build");
        u.log.clearRetainingCapacity();
        u.log_off = 0;
        result = .none;
        started_ms = GetTickCount64();
        running.store(true, .release);
        u.thread = std.Thread.spawn(.{}, worker, .{ u.io, u.gpa }) catch blk: {
            running.store(false, .release);
            break :blk null;
        };
    }

    fn draw(u: *Ui) void {
        const vp = im.ImGui_GetMainViewport();
        im.ImGui_SetNextWindowPos(vp.*.WorkPos, 0);
        im.ImGui_SetNextWindowSize(vp.*.WorkSize, 0);
        im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = px(24), .y = 0 });
        _ = im.ImGui_Begin("setup", null, im.ImGuiWindowFlags_NoDecoration | im.ImGuiWindowFlags_NoMove | im.ImGuiWindowFlags_NoBringToFrontOnFocus | im.ImGuiWindowFlags_NoScrollWithMouse);
        im.ImGui_PopStyleVar();
        defer im.ImGui_End();
        backdrop();
        header();

        // Two columns: the steps on the left, the log on the right.
        const footer = px(34);
        const avail = im.ImGui_GetContentRegionAvail();
        const left_w = @max(px(470), avail.x * 0.44);
        const col_h = avail.y - footer;
        im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, .{ .x = 0, .y = 0, .z = 0, .w = 0 }); // the spirit lights show through
        const left = im.ImGui_BeginChild("left", .{ .x = left_w, .y = col_h }, 0, im.ImGuiWindowFlags_NoScrollbar);
        im.ImGui_PopStyleColor();
        if (left) u.leftColumn();
        im.ImGui_EndChild();
        im.ImGui_SameLine();
        im.ImGui_Dummy(.{ .x = px(6), .y = 0 });
        im.ImGui_SameLine();
        u.logPanel(col_h);
    }

    fn leftColumn(u: *Ui) void {
        const busy = running.load(.acquire);
        im.ImGui_BeginDisabled(busy);
        if (cardBegin("disc", "Your disc image", 0)) {
            im.ImGui_TextDisabled("%s", "An ISO of your own Otogi: Myth of Demons (USA) disc.");
            im.ImGui_SetNextItemWidth(-(btn_w() + im.ImGui_GetStyle().*.ItemSpacing.x));
            if (im.ImGui_InputText("##iso", &iso_buf, iso_buf.len, 0)) u.checkIso();
            im.ImGui_SameLine();
            if (button("Browse...##iso") and win_pick_iso(&iso_buf, iso_buf.len)) u.checkIso();
            switch (u.iso_state) {
                .none => im.ImGui_TextDisabled("%s", "Pick the .iso file."),
                .ok => colored(good, "Otogi (USA): verified"),
                .wrong => colored(bad, "Not the Otogi (USA) disc this build supports (default.xbe does not match)."),
                .unreadable => colored(bad, "Cannot read an Xbox game from this file."),
            }
        }
        cardEnd();

        if (cardBegin("out", "Install folder", 0)) {
            im.ImGui_TextDisabled("%s", "The game goes here. Nothing is installed anywhere else.");
            im.ImGui_SetNextItemWidth(-(btn_w() + im.ImGui_GetStyle().*.ItemSpacing.x));
            _ = im.ImGui_InputText("##out", &out_buf, out_buf.len, 0);
            im.ImGui_SameLine();
            if (button("Browse...##out")) {
                var pick: [1024:0]u8 = @splat(0);
                if (win_pick_folder(&pick, pick.len)) _ = std.fmt.bufPrintSentinel(&out_buf, "{s}\\Otogi", .{std.mem.sliceTo(&pick, 0)}, 0) catch {};
            }
            var line: [160:0]u8 = undefined;
            if (freeGb()) |f| {
                const s = std.fmt.bufPrintSentinel(&line, "{d} GB free on this drive, {d} GB needed", .{ f, need_gb }, 0) catch "";
                colored(if (f < need_gb) bad else muted, s);
            }
            if (ram_gb != 0 and ram_gb < 16) colored(gold, std.fmt.bufPrintSentinel(&line, "{d} GB of RAM: the compile runs one job at a time and takes longer.", .{ram_gb}, 0) catch "");
        }
        cardEnd();
        im.ImGui_EndDisabled();

        // The main button: the game's red brush stroke (fe_lo000) under the
        // label; ash grey while it cannot run. Cream text either way.
        const now = im.ImGui_GetTime();
        const armed = busy and now - cancel_armed_at < 3;
        const can = busy or u.iso_state == .ok;
        im.ImGui_Dummy(.{ .x = 0, .y = px(4) });
        const label: [*:0]const u8 = if (busy and cancel.load(.acquire)) "Stopping..." else if (armed) "Click again to stop the build" else if (busy) "Stop the build" else if (u.iso_state != .ok) "Pick your disc image first" else if (result == .failed) "Try again" else "Build the game";
        const size: im.ImVec2 = .{ .x = im.ImGui_GetContentRegionAvail().x, .y = px(50) };
        const p0 = im.ImGui_GetCursorScreenPos();
        const clicked = im.ImGui_InvisibleButton("build", size, 0);
        const hot = can and im.ImGui_IsItemHovered(0);
        const dl = im.ImGui_GetWindowDrawList();
        const p1: im.ImVec2 = .{ .x = p0.x + size.x, .y = p0.y + size.y };
        if (disc.brush.tex != null) {
            const tint: u32 = if (!can) col32(0x5A4A48) else if (hot) col32(0xFFFFFF) else col32(0xD8D0D0);
            // The stroke fills u 0..0.84, v 0.1..0.9 of fe_lo000.
            image(dl, disc.brush, .{ .x = p0.x - px(6), .y = p0.y - px(6) }, .{ .x = p1.x + px(6), .y = p1.y + px(6) }, .{ .x = 0, .y = 0.1 }, .{ .x = 0.84, .y = 0.9 }, tint);
        } else {
            im.ImDrawList_AddRectFilledEx(dl, p0, p1, col32(if (!can) 0x3A2E2E else if (hot) 0xB8362E else crimson), px(4), 0);
        }
        im.ImGui_PushFontFloat(font_head, 26);
        const ts = im.ImGui_CalcTextSize(label);
        const tp: im.ImVec2 = .{ .x = p0.x + (size.x - ts.x) / 2, .y = p0.y + (size.y - ts.y) / 2 };
        im.ImDrawList_AddText(dl, .{ .x = tp.x + px(2), .y = tp.y + px(2) }, colA(0x000000, 0.6), label);
        im.ImDrawList_AddText(dl, tp, col32(if (can) cream else 0xCFC6B4), label);
        im.ImGui_PopFont();
        if (clicked and busy) {
            if (armed) stopBuild() else cancel_armed_at = now;
        } else if (clicked and can) u.start();
        // How long it takes, before and during the run.
        var eta: [64]u8 = undefined;
        var line: [128:0]u8 = undefined;
        const msg: [:0]const u8 = if (busy)
            std.fmt.bufPrintSentinel(&line, "{s} left", .{approx(&eta, secsLeft())}, 0) catch ""
        else if (u.iso_state == .ok and result != .ok)
            std.fmt.bufPrintSentinel(&line, "Takes {s}, most of it translating and compiling.", .{approx(&eta, estimateFromStamps(u.io))}, 0) catch ""
        else
            "";
        if (msg.len != 0) {
            const mw = im.ImGui_CalcTextSize(msg.ptr).x;
            im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + (size.x - mw) / 2);
            colored(muted, msg);
        }
        im.ImGui_Dummy(.{ .x = 0, .y = px(2) });

        if (cardBegin("steps", "Progress", 0)) progress(busy);
        cardEnd();
    }

    fn logPanel(u: *Ui, h: f32) void {
        if (cardBegin("logcard", "Log", h)) {
            if (button("Copy log")) {
                u.copyLog();
                u.copied_at = im.ImGui_GetTime();
            }
            im.ImGui_SameLine();
            if (button("Open log file")) openOut("setup.log");
            im.ImGui_SameLine();
            if (im.ImGui_GetTime() - u.copied_at < 2) colored(good, "Copied. Paste it into your report.") else im.ImGui_TextDisabled("%s", "Send this with any problem report.");
            var v: [160:0]u8 = undefined;
            const vs: [:0]const u8 = std.fmt.bufPrintSentinel(&v, "setup {s}  |  {s}", .{ version, std.mem.span(win_gpu_name()) }, 0) catch "";
            im.ImGui_TextDisabled("%s", vs.ptr);
            im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, rgb(0x080303));
            im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = px(10), .y = px(8) });
            if (im.ImGui_BeginChild("log", .{ .x = 0, .y = 0 }, im.ImGuiChildFlags_Borders | im.ImGuiChildFlags_AlwaysUseWindowPadding, im.ImGuiWindowFlags_HorizontalScrollbar)) {
                im.ImGui_PushFontFloat(font_mono, 14);
                if (u.log.items.len == 0) im.ImGui_TextDisabled("%s", "Nothing yet. The log fills in once you build.");
                u.log.append(u.gpa, 0) catch {};
                im.ImGui_TextUnformatted(@ptrCast(u.log.items.ptr));
                _ = u.log.pop();
                im.ImGui_PopFont();
                if (im.ImGui_GetScrollY() >= im.ImGui_GetScrollMaxY()) im.ImGui_SetScrollHereY(1);
            }
            im.ImGui_EndChild();
            im.ImGui_PopStyleVar();
            im.ImGui_PopStyleColor();
        }
        cardEnd();
    }

    /// The whole setup.log to the clipboard (the view keeps only its tail).
    fn copyLog(u: *Ui) void {
        var p: [1100]u8 = undefined;
        const name = std.fmt.bufPrint(&p, "{s}\\setup.log", .{std.mem.sliceTo(&out_buf, 0)}) catch return;
        const text = Io.Dir.cwd().readFileAllocOptions(u.io, name, u.gpa, .limited(64 << 20), .of(u8), 0) catch return;
        defer u.gpa.free(text);
        im.ImGui_SetClipboardText(text.ptr);
    }

    /// Show the tail of <out>\setup.log (ours and the tools' output).
    fn tailLog(u: *Ui) void {
        var path: [1100]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "{s}\\setup.log", .{std.mem.sliceTo(&out_buf, 0)}) catch return;
        const f = Io.Dir.cwd().openFile(u.io, p, .{}) catch return;
        defer f.close(u.io);
        var buf: [64 * 1024]u8 = undefined;
        const got = f.readPositionalAll(u.io, &buf, u.log_off) catch return;
        u.log_off += got;
        u.log.appendSlice(u.gpa, buf[0..got]) catch return;
        const keep = 128 * 1024; // ponytail: tail only; the file has everything
        if (u.log.items.len > keep) {
            const cut = std.mem.indexOfScalarPos(u8, u.log.items, u.log.items.len - keep, '\n') orelse u.log.items.len - keep;
            u.log.replaceRangeAssumeCapacity(0, cut + 1, &.{});
        }
    }
};

/// Every small button has the same size, and light text on crimson.
fn btn_w() f32 {
    return px(132);
}
fn button(label: [*:0]const u8) bool {
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_Text, rgb(cream));
    defer im.ImGui_PopStyleColor();
    return im.ImGui_ButtonEx(label, .{ .x = btn_w(), .y = 0 });
}

// ── Panels: dark lacquer over the backdrop, a gold edge, light text. ──────
const panel_bg = 0x120707;

/// A panel titled `title`; height 0 fits its contents.
fn cardBegin(id: [*:0]const u8, comptime title: [:0]const u8, height: f32) bool {
    const w = im.ImGui_GetContentRegionAvail().x;
    im.ImGui_PushStyleColorImVec4(im.ImGuiCol_ChildBg, .{ .x = 0, .y = 0, .z = 0, .w = 0 });
    im.ImGui_PushStyleVarImVec2(im.ImGuiStyleVar_WindowPadding, .{ .x = px(20), .y = px(16) });
    const flags = im.ImGuiChildFlags_AlwaysUseWindowPadding | (if (height == 0) im.ImGuiChildFlags_AutoResizeY else 0);
    const open = im.ImGui_BeginChild(id, .{ .x = w, .y = height }, flags, im.ImGuiWindowFlags_NoScrollbar);
    im.ImGui_PopStyleVar();
    im.ImGui_PopStyleColor();
    if (open) {
        im.ImGui_PushFontFloat(font_head, 21);
        colored(gold, title);
        im.ImGui_PopFont();
    }
    return open;
}

/// Ends the panel and draws it behind its contents: the parent's draw list
/// renders before the child window.
fn cardEnd() void {
    im.ImGui_EndChild();
    const a = im.ImGui_GetItemRectMin();
    const b = im.ImGui_GetItemRectMax();
    const dl = im.ImGui_GetWindowDrawList();
    im.ImDrawList_AddRectFilledEx(dl, a, b, colA(panel_bg, 0.88), px(4), 0);
    im.ImDrawList_AddRectEx(dl, a, b, col32(gold_dim), px(4), px(1), 0);
    im.ImDrawList_AddLineEx(dl, .{ .x = a.x + px(12), .y = a.y }, .{ .x = b.x - px(12), .y = a.y }, colA(gold, 0.8), px(2), 0);
    im.ImGui_Dummy(.{ .x = 0, .y = px(6) });
}

fn stepLine(i: usize, busy: bool, at: u32) void {
    const dl = im.ImGui_GetWindowDrawList();
    const h = im.ImGui_GetTextLineHeight();
    const p = im.ImGui_GetCursorScreenPos();
    const ctr: im.ImVec2 = .{ .x = p.x + h * 0.5, .y = p.y + h * 0.5 };
    const r = h * 0.26;
    const started = busy or result != .none;
    const state: enum { done, now, failed, todo } = if (!started) .todo else if (result == .ok or i < at) .done else if (i == at) (if (result == .failed) .failed else .now) else .todo;
    switch (state) {
        .done => im.ImDrawList_AddCircleFilled(dl, ctr, r, col32(cream), 0),
        .now => {
            const pulse: f32 = @floatCast(0.5 + 0.5 * @sin(im.ImGui_GetTime() * 5));
            im.ImDrawList_AddCircleFilled(dl, ctr, r * (1.5 + pulse), colA(bad, 0.25 * (1 - pulse)), 0);
            im.ImDrawList_AddCircleEx(dl, ctr, r, col32(bad), 0, 2.5, 0);
        },
        .failed => im.ImDrawList_AddCircleFilled(dl, ctr, r, col32(bad), 0),
        .todo => im.ImDrawList_AddCircleEx(dl, ctr, r, col32(muted), 0, 1.5, 0),
    }
    im.ImGui_SetCursorPosX(im.ImGui_GetCursorPosX() + h * 1.4);
    const on_brush = state == .now and disc.brush.tex != null;
    if (on_brush) {
        const tp = im.ImGui_GetCursorScreenPos();
        const ts = im.ImGui_CalcTextSize(steps[i].ptr);
        image(dl, disc.brush, .{ .x = tp.x - px(10), .y = tp.y - px(5) }, .{ .x = tp.x + ts.x + px(14), .y = tp.y + ts.y + px(5) }, .{ .x = 0, .y = 0.1 }, .{ .x = 0.84, .y = 0.9 }, col32(0xFFFFFF));
    }
    im.ImGui_PushStyleColor(im.ImGuiCol_Text, col32(if (on_brush) cream else switch (state) {
        .done => cream,
        .now, .failed => bad,
        .todo => muted,
    }));
    im.ImGui_TextUnformatted(steps[i].ptr);
    im.ImGui_PopStyleColor();
}

/// Progress bar, elapsed time and the step checklist; Play once done.
fn progress(busy: bool) void {
    const at = step_at.load(.acquire);
    if (busy or result != .none) {
        const end = if (busy) GetTickCount64() else finished_ms;
        const secs = (end -| started_ms) / 1000;
        var label: [96:0]u8 = undefined;
        var eta: [32]u8 = undefined;
        const ov = std.fmt.bufPrintSentinel(&label, "{s}   {d}:{d:0>2}{s}{s}", .{ switch (result) {
            .ok => "Done",
            .failed => "Stopped",
            .none => steps[@min(at, steps.len - 1)],
        }, secs / 60, secs % 60, if (busy) "  /  " else "", if (busy) approx(&eta, secsLeft()) else "" }, 0) catch "";
        // Filled by time, not by step count: the compile is most of it.
        var total: f32 = 0;
        for (step_left) |v| total += v;
        const frac: f32 = if (result == .ok) 1 else if (total == 0) 0 else std.math.clamp(1 - secsLeft() / total, 0, 1);
        im.ImGui_ProgressBar(frac, .{ .x = -std.math.floatMin(f32), .y = px(24) }, ov.ptr);
    }

    // Two columns of steps. Ink dot = done, pulsing crimson ring = running,
    // red dot = failed.
    const half = im.ImGui_GetContentRegionAvail().x / 2;
    const x0 = im.ImGui_GetCursorPosX();
    for (0..steps.len / 2) |row| {
        stepLine(row, busy, at);
        im.ImGui_SameLine();
        im.ImGui_SetCursorPosX(x0 + half);
        stepLine(row + steps.len / 2, busy, at);
    }
    if (result == .ok) {
        im.ImGui_Dummy(.{ .x = 0, .y = px(2) });
        colored(good, "Otogi is ready.");
        if (button("Play")) openOut("otogi.exe");
        im.ImGui_SameLine();
        if (button("Open folder")) openOut("");
        colored(muted, "settings.ini in that folder sets resolution, widescreen and frame rate. In game, F1 opens the debug menu.");
    }
    if (result == .failed) {
        im.ImGui_Dummy(.{ .x = 0, .y = px(2) });
        colored(bad, std.mem.sliceTo(&fail_msg, 0));
        colored(muted, "Try again keeps the finished steps. If it keeps failing, click Copy log and send it with your report.");
    }
}

/// Seigaiha: rows of overlapping wave scales, each row half a radius lower.
fn seigaiha(dl: *im.ImDrawList, a: im.ImVec2, b: im.ImVec2, r: f32, fill: u32, line: u32) void {
    im.ImDrawList_PushClipRect(dl, a, b, true);
    defer im.ImDrawList_PopClipRect(dl);
    var row: u32 = 0;
    var y = a.y - r;
    while (y < b.y + r) : ({
        y += r / 2;
        row += 1;
    }) {
        var x = a.x - (if (row % 2 == 1) r else 0);
        while (x < b.x + r) : (x += 2 * r) {
            const c: im.ImVec2 = .{ .x = x, .y = y };
            im.ImDrawList_AddCircleFilled(dl, c, r, fill, 28);
            for ([_]f32{ 0.9, 0.68, 0.46, 0.24 }) |k| im.ImDrawList_AddCircleEx(dl, c, r * k, line, 28, px(1.2), 0);
        }
    }
}

/// Spirit lights drifting up the window, as on the title screen, and a
/// seigaiha strip along the bottom.
fn backdrop() void {
    const dl = im.ImGui_GetWindowDrawList();
    const wp = im.ImGui_GetWindowPos();
    const ws = im.ImGui_GetWindowSize();
    const t: f32 = @floatCast(im.ImGui_GetTime());
    if (disc.waves.tex != null) {
        tiled(dl, disc.waves, wp, .{ .x = wp.x + ws.x, .y = wp.y + ws.y }, px(300), col32(0xFFFFFF));
        im.ImDrawList_AddRectFilled(dl, wp, .{ .x = wp.x + ws.x, .y = wp.y + ws.y }, colA(0x0C0404, 0.74));
    }
    var i: u32 = 0;
    while (i < 48) : (i += 1) {
        const hsh = std.hash.int(i *% 2654435761);
        const fx = @as(f32, @floatFromInt(hsh & 0xFFFF)) / 65536;
        const fy = @as(f32, @floatFromInt((hsh >> 16) & 0xFFFF)) / 65536;
        const speed = px(8 + @as(f32, @floatFromInt(hsh % 23)));
        const fi: f32 = @floatFromInt(i);
        const y = wp.y + ws.y - @mod(fy * ws.y + t * speed, ws.y);
        const x = wp.x + fx * ws.x + @sin(t * 0.6 + fi) * px(10);
        const a = 0.25 + 0.2 * @sin(t * 1.7 + fi * 1.3);
        const r = px(1.2 + @as(f32, @floatFromInt(hsh % 3)) * 0.7);
        im.ImDrawList_AddCircleFilled(dl, .{ .x = x, .y = y }, r * 5, colA(spirit, a * 0.08), 16);
        im.ImDrawList_AddCircleFilled(dl, .{ .x = x, .y = y }, r, colA(spirit, a), 8);
    }
    const foot = px(26);
    const top = wp.y + ws.y - foot;
    seigaiha(dl, .{ .x = wp.x, .y = top }, .{ .x = wp.x + ws.x, .y = wp.y + ws.y }, px(16), col32(0x120606), colA(gold, 0.16));
    im.ImDrawList_AddLineEx(dl, .{ .x = wp.x, .y = top }, .{ .x = wp.x + ws.x, .y = top }, col32(gold_dim), px(1.5), 0);
}

/// With the disc: its title logo on the title-screen brocade, fading to black
/// where Raikoh (the ending art) stands.
fn discHeader() void {
    const dl = im.ImGui_GetWindowDrawList();
    const wp = im.ImGui_GetWindowPos();
    const w = im.ImGui_GetWindowSize().x;
    const h = px(148);
    const bottom = wp.y + h;
    const margin = px(24);
    im.ImDrawList_AddRectFilled(dl, wp, .{ .x = wp.x + w, .y = bottom }, col32(0x000000));
    // title.dds (1024x512): logo in u 0.065..0.55 (its glyphs start at u 0.1),
    // plain brocade in u 0.55..1; v 0.05..0.8 skips the black fades and the copyright.
    const v0: f32 = 0.05;
    const v1: f32 = 0.8;
    const k = h / ((v1 - v0) * disc.title.h); // texels to pixels
    const logo_w = (0.55 - 0.065) * disc.title.w * k;
    const logo_x = wp.x + margin - (0.1 - 0.065) * disc.title.w * k;
    const seg_w = 0.45 * disc.title.w * k;
    // Brocade behind everything, then the logo (on its own brocade) over it.
    var x = wp.x - seg_w + @mod(logo_x + logo_w - wp.x, seg_w);
    while (x < wp.x + w * 0.75) : (x += seg_w) image(dl, disc.title, .{ .x = x, .y = wp.y }, .{ .x = x + seg_w, .y = bottom }, .{ .x = 0.55, .y = v0 }, .{ .x = 1, .y = v1 }, col32(0xFFFFFF));
    image(dl, disc.title, .{ .x = logo_x, .y = wp.y }, .{ .x = logo_x + logo_w, .y = bottom }, .{ .x = 0.065, .y = v0 }, .{ .x = 0.55, .y = v1 }, col32(0xFFFFFF));
    // Fade to black on the right, where Raikoh stands.
    im.ImDrawList_AddRectFilledMultiColor(dl, .{ .x = wp.x + w * 0.45, .y = wp.y }, .{ .x = wp.x + w * 0.72, .y = bottom }, colA(0, 0), colA(0, 1), colA(0, 1), colA(0, 0));
    im.ImDrawList_AddRectFilled(dl, .{ .x = wp.x + w * 0.72, .y = wp.y }, .{ .x = wp.x + w, .y = bottom }, col32(0x000000));
    // fe_end00: Raikoh and his sword, u 0.03..0.62, v 0.1..0.95, on black; inside the right margin.
    const rh = h - px(8);
    const rw = rh * (0.59 * disc.raikoh.w) / (0.85 * disc.raikoh.h);
    image(dl, disc.raikoh, .{ .x = wp.x + w - margin - rw, .y = wp.y + px(4) }, .{ .x = wp.x + w - margin, .y = wp.y + px(4) + rh }, .{ .x = 0.03, .y = 0.1 }, .{ .x = 0.62, .y = 0.95 }, col32(0xFFFFFF));
    // Subtitle right of the logo's glyphs (they end near u 0.52), on the logo's lower line.
    im.ImGui_PushFontFloat(font_head, 24);
    const sub = "Myth of Demons  \xe2\x80\x94  PC setup";
    const ts = im.ImGui_CalcTextSize(sub);
    const sp: im.ImVec2 = .{ .x = logo_x + (0.52 - 0.065) * disc.title.w * k + px(18), .y = wp.y + h * 0.66 - ts.y };
    im.ImDrawList_AddText(dl, .{ .x = sp.x + px(2), .y = sp.y + px(2) }, col32(0x000000), sub);
    im.ImDrawList_AddText(dl, sp, col32(cream), sub);
    im.ImGui_PopFont();
    im.ImDrawList_AddLineEx(dl, .{ .x = wp.x, .y = bottom }, .{ .x = wp.x + w, .y = bottom }, col32(gold), px(2), 0);
    im.ImDrawList_AddLineEx(dl, .{ .x = wp.x, .y = bottom + px(5) }, .{ .x = wp.x + w, .y = bottom + px(5) }, col32(gold_dim), px(1), 0);
    im.ImGui_SetCursorScreenPos(.{ .x = wp.x + margin, .y = bottom + px(20) });
}

/// Crimson band of seigaiha waves, a double gold rule, the title.
fn header() void {
    if (disc_loaded) return discHeader();
    const dl = im.ImGui_GetWindowDrawList();
    const wp = im.ImGui_GetWindowPos();
    const w = im.ImGui_GetWindowSize().x;
    const bottom = wp.y + px(86);
    seigaiha(dl, wp, .{ .x = wp.x + w, .y = bottom }, px(22), col32(band), colA(gold, 0.22));
    // Darker on the left, so the title reads over the waves.
    im.ImDrawList_AddRectFilledMultiColor(dl, wp, .{ .x = wp.x + w * 0.55, .y = bottom }, colA(0x2A0A08, 0.85), colA(0x2A0A08, 0), colA(0x2A0A08, 0), colA(0x2A0A08, 0.85));
    im.ImDrawList_AddLineEx(dl, .{ .x = wp.x, .y = bottom }, .{ .x = wp.x + w, .y = bottom }, col32(gold), px(2), 0);
    im.ImDrawList_AddLineEx(dl, .{ .x = wp.x, .y = bottom + px(5) }, .{ .x = wp.x + w, .y = bottom + px(5) }, col32(gold_dim), px(1), 0);

    im.ImGui_SetCursorScreenPos(.{ .x = wp.x + px(24), .y = wp.y + px(14) });
    im.ImGui_PushFontFloat(font_jp, 44);
    colored(gold, "御伽");
    im.ImGui_PopFont();
    im.ImGui_SameLine();
    im.ImGui_PushFontFloat(font_title, 40);
    colored(gold, "OTOGI");
    im.ImGui_PopFont();
    im.ImGui_SameLine();
    im.ImGui_SetCursorPosY(im.ImGui_GetCursorPosY() + px(15));
    im.ImGui_PushFontFloat(font_head, 22);
    colored(cream, "Myth of Demons  \xe2\x80\x94  PC setup");
    im.ImGui_PopFont();
    im.ImGui_SetCursorScreenPos(.{ .x = wp.x + px(24), .y = bottom + px(16) });
}

fn colored(c: u24, text: [:0]const u8) void {
    im.ImGui_PushStyleColor(im.ImGuiCol_Text, col32(c));
    im.ImGui_TextWrapped("%s", text.ptr);
    im.ImGui_PopStyleColor();
}

fn openOut(comptime name: []const u8) void {
    var p: [1100:0]u8 = undefined;
    win_open(std.fmt.bufPrintSentinel(&p, "{s}\\" ++ name, .{std.mem.sliceTo(&out_buf, 0)}, 0) catch return);
}

/// Free space on the install folder's drive, in GB.
fn freeGb() ?u64 {
    const out = std.mem.sliceTo(&out_buf, 0);
    if (out.len < 3 or out[1] != ':') return null;
    const root: [3:0]u8 = .{ out[0], ':', '\\' };
    var avail: u64 = 0;
    if (GetDiskFreeSpaceExA(&root, &avail, null, null) == 0) return null;
    return avail >> 30;
}

/// SHA-1 of default.xbe on the disc image, lower-case hex.
fn xbeSha1(io: Io, gpa: std.mem.Allocator, iso_path: []const u8) ![40]u8 {
    const iso = try Io.Dir.cwd().openFile(io, iso_path, .{});
    defer iso.close(io);
    const img = try xiso.Image.open(io, iso);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (try img.readDir(arena.allocator(), img.root_sector, img.root_size)) |e| {
        if (!std.mem.eql(u8, e.name, "default.xbe")) continue;
        const data = try arena.allocator().alloc(u8, e.size);
        if (try img.file.readPositionalAll(io, data, img.base + @as(u64, e.sector) * 2048) != e.size) return error.Truncated;
        var h: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(data, &h, .{});
        return std.fmt.bytesToHex(h, .lower);
    }
    return error.NoXbe;
}

// ── Worker ─────────────────────────────────────────────────────────────────

const Ctx = struct {
    io: Io,
    gpa: std.mem.Allocator,
    out: []const u8, // output folder, absolute
    work: []const u8, // <out>\build
    log: Io.File,
    redo: bool = false, // a step ran, so every later step runs too

    fn say(c: *Ctx, comptime f: []const u8, args: anytype) void {
        var buf: [2048]u8 = undefined;
        c.log.writeStreamingAll(c.io, std.fmt.bufPrint(&buf, f ++ "\n", args) catch return) catch {};
    }

    fn path(c: *Ctx, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(c.gpa, f, args) catch @panic("OOM");
    }

    fn done(c: *Ctx, name: []const u8) bool {
        if (c.redo) return false;
        Io.Dir.cwd().access(c.io, c.path("{s}\\.stamps\\{s}", .{ c.work, name }), .{}) catch return false;
        c.say("[{s}] already done", .{name});
        step_left[step_at.load(.acquire)] = 0;
        return true;
    }

    fn stamp(c: *Ctx, name: []const u8) void {
        Io.Dir.cwd().writeFile(c.io, .{ .sub_path = c.path("{s}\\.stamps\\{s}", .{ c.work, name }), .data = "" }) catch {};
        c.redo = true;
    }

    fn drain(c: *Ctx, f: Io.File) void {
        var buf: [16 * 1024]u8 = undefined;
        while (true) {
            const n = f.readStreaming(c.io, &.{&buf}) catch break;
            if (n == 0) break;
            c.log.writeStreamingAll(c.io, buf[0..n]) catch {};
        }
    }

    /// Run a tool with its output in the log; error unless it exits 0.
    fn run(c: *Ctx, cwd: []const u8, argv: []const []const u8) !void {
        c.say("> {s} (in {s})", .{ std.mem.join(c.gpa, " ", argv) catch "", cwd });
        // Both streams copied to the log here. Given the log file itself (.file),
        // Zig reopens it by name: the tool then writes from offset 0 over the log.
        if (cancel.load(.acquire)) return error.Cancelled;
        var child = try std.process.spawn(c.io, .{ .argv = argv, .cwd = .{ .path = cwd }, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe, .create_no_window = true });
        if (job) |j| _ = AssignProcessToJobObject(j, child.id.?);
        const err_thread = try std.Thread.spawn(.{}, Ctx.drain, .{ c, child.stderr.? });
        c.drain(child.stdout.?);
        err_thread.join();
        const term = try child.wait(c.io);
        if (cancel.load(.acquire)) return error.Cancelled;
        if (!term.success()) {
            c.say("{s} failed: {f}", .{ std.fs.path.basename(argv[0]), term });
            return error.ToolFailed;
        }
    }
};

fn worker(io: Io, gpa: std.mem.Allocator) void {
    defer running.store(false, .release);
    step_at.store(0, .release);
    const out = std.mem.sliceTo(&out_buf, 0);
    Io.Dir.cwd().createDirPath(io, out) catch {};
    const log = Io.Dir.cwd().createFile(io, std.fmt.allocPrint(gpa, "{s}\\setup.log", .{out}) catch return, .{}) catch |e| return fail("cannot write to the output folder: {t}", .{e});
    defer log.close(io);
    var c: Ctx = .{ .io = io, .gpa = gpa, .out = out, .work = std.fmt.allocPrint(gpa, "{s}\\build", .{out}) catch return, .log = log };
    Io.Dir.cwd().createDirPath(io, c.path("{s}\\.stamps", .{c.work})) catch {};
    defer finished_ms = GetTickCount64();
    systemInfo(&c);
    pipeline(&c) catch |e| {
        if (e == error.Cancelled) {
            c.say("Stopped by the user.", .{});
            return fail("{s}", .{"Stopped. Build again to pick up from the last finished step."});
        }
        c.say("FAILED: {t}", .{e});
        if (result != .failed) fail("{s}: {t}", .{ steps[step_at.load(.acquire)], e });
        return;
    };
    c.say("Done: {s}\\otogi.exe", .{out});
    result = .ok;
}


/// Kill whatever tool runs now (and its children); the worker stops at the
/// next step boundary. In-process steps (extract, downloads) finish first.
fn stopBuild() void {
    cancel.store(true, .release);
    if (job) |j| _ = TerminateJobObject(j, 1);
}

fn fail(comptime f: []const u8, args: anytype) void {
    _ = std.fmt.bufPrintSentinel(&fail_msg, f, args, 0) catch {};
    result = .failed;
}

fn next(c: *Ctx, i: u32) !void {
    if (cancel.load(.acquire)) return error.Cancelled;
    step_ms = GetTickCount64();
    step_at.store(i, .release);
    c.say("== {s} (at {d:.1} s)", .{ steps[i], @as(f64, @floatFromInt(GetTickCount64() - started_ms)) / 1000 });
}

/// The top of every setup.log: what a bug report needs to know.
fn systemInfo(c: *Ctx) void {
    var v: OsVersion = .{};
    _ = RtlGetVersion(&v);
    var cpu: [128]u8 = @splat(0);
    var cpu_len: u32 = cpu.len;
    _ = RegGetValueA(0x80000002, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", "ProcessorNameString", 0x2, null, &cpu, &cpu_len); // HKLM, RRF_RT_REG_SZ
    const iso = std.mem.sliceTo(&iso_buf, 0);
    const iso_size = if (Io.Dir.cwd().statFile(c.io, iso, .{})) |st| st.size else |_| 0;
    c.say("Otogi setup {s}", .{version});
    c.say("Windows {d}.{d} build {d}; CPU {s}; {d} GB RAM; GPU {s}", .{ v.major, v.minor, v.build, std.mem.sliceTo(&cpu, 0), ram_gb, std.mem.span(win_gpu_name()) });
    c.say("disc image {s} ({d} bytes)", .{ iso, iso_size });
    c.say("install folder {s} ({?d} GB free)", .{ c.out, freeGb() });
}

const OsVersion = extern struct { size: u32 = @sizeOf(OsVersion), major: u32 = 0, minor: u32 = 0, build: u32 = 0, platform: u32 = 0, csd: [128]u16 = @splat(0) };
extern "ntdll" fn RtlGetVersion(v: *OsVersion) callconv(.winapi) i32;
extern "advapi32" fn RegGetValueA(key: usize, sub: [*:0]const u8, value: [*:0]const u8, flags: u32, kind: ?*u32, data: *anyopaque, len: *u32) callconv(.winapi) i32;

fn pipeline(c: *Ctx) !void {
    const io = c.io;
    const cwd = Io.Dir.cwd();

    try next(c, 0);
    const iso_path = std.mem.sliceTo(&iso_buf, 0);
    const hex = xbeSha1(io, c.gpa, iso_path) catch |e| {
        fail("{s}", .{"Cannot read an Xbox game from the disc image."});
        return e;
    };
    c.say("default.xbe SHA-1 {s}", .{&hex});
    if (!std.mem.eql(u8, &hex, xbe_sha1)) {
        fail("{s}", .{"This is not the Otogi (USA) disc this build supports (default.xbe does not match)."});
        return error.WrongDisc;
    }
    const iso = try cwd.openFile(io, iso_path, .{});
    defer iso.close(io);
    const img = try xiso.Image.open(io, iso);

    try next(c, 1);
    if (!c.done("extract")) {
        var game = try cwd.createDirPathOpen(io, c.path("{s}\\game", .{c.out}), .{});
        defer game.close(io);
        c.say("extracted {d} files", .{try img.unpack(c.gpa, game, img.root_sector, img.root_size)});
        c.stamp("extract");
    }

    try next(c, 2);
    if (!c.done("source")) {
        try unzipBytes(c, source_zip, c.work);
        c.stamp("source");
    }

    try next(c, 3);
    const zig = c.path("{s}\\tools\\zig-x86_64-windows-0.17.0\\zig.exe", .{c.work});
    if (!c.done("zig")) {
        try unzipFile(c, try fetch(c, zig_dl), c.path("{s}\\tools", .{c.work}));
        c.stamp("zig");
    }

    try next(c, 4);
    const py_dir = c.path("{s}\\tools\\python", .{c.work});
    const python = c.path("{s}\\python.exe", .{py_dir});
    if (!c.done("python")) {
        try unzipFile(c, try fetch(c, python_dl), py_dir);
        try unzipFile(c, try fetch(c, capstone_dl), c.path("{s}\\Lib\\site-packages", .{py_dir}));
        // Embeddable Python reads its whole sys.path from this file.
        try cwd.writeFile(io, .{ .sub_path = c.path("{s}\\python314._pth", .{py_dir}), .data = c.path("python314.zip\n.\nLib\\site-packages\n{s}\\xboxrecomp\n", .{c.work}) });
        c.stamp("python");
    }

    try next(c, 5);
    if (!c.done("lift")) {
        const tk = c.path("{s}\\xboxrecomp", .{c.work});
        const xbe = c.path("{s}\\game\\default.xbe", .{c.out});
        try c.run(tk, &.{ python, "-u", "-m", "tools.xbe_parser", xbe, "--json", c.path("{s}\\game\\otogi_analysis.json", .{c.out}) });
        try c.run(tk, &.{ python, "-u", "-m", "tools.disasm", xbe });
        try c.run(tk, &.{ python, "-u", "-m", "tools.func_id", xbe });
        try c.run(tk, &.{ python, "-u", "-m", "tools.abi_analysis", xbe });
        try c.run(tk, &.{ python, "-u", "-m", "tools.recomp", xbe, "--all", "--split", "250", "--gen-dir", "../src/recomp/gen", "--exclude-manual", "../seeds/manual.h" });
        c.stamp("lift");
    }

    try next(c, 6);
    if (!c.done("build")) {
        // Sneak King's lift needed ~16 GB to compile in parallel.
        const jobs: []const u8 = if (ram_gb != 0 and ram_gb < 16) "-j1" else "-j4";
        // Zig's cache (packages too) stays in the build folder; zig build has
        // no flag for it, the child inherits this.
        _ = SetEnvironmentVariableA("ZIG_GLOBAL_CACHE_DIR", (std.fmt.allocPrintSentinel(c.gpa, "{s}\\zig-cache", .{c.work}, 0) catch unreachable).ptr);
        try c.run(c.work, &.{ zig, "build", jobs, "--prefix", c.out, "--prefix-exe-dir", "." });
        c.stamp("build");
    }

    try next(c, 7);
    // settings.ini is the player's once it exists.
    cwd.access(io, c.path("{s}\\settings.ini", .{c.out}), .{}) catch
        try Io.Dir.copyFile(cwd, c.path("{s}\\settings.ini", .{c.work}), cwd, c.path("{s}\\settings.ini", .{c.out}), io, .{});
}

/// Download into <work>\downloads (kept between runs) and check its SHA-256.
fn fetch(c: *Ctx, d: Download) ![]const u8 {
    const io = c.io;
    const dir = c.path("{s}\\downloads", .{c.work});
    try Io.Dir.cwd().createDirPath(io, dir);
    const dest = c.path("{s}\\{s}", .{ dir, d.name });
    if (sha256File(c, dest)) |h| if (std.mem.eql(u8, &h, d.sha256)) return dest;
    c.say("downloading {s}", .{d.url});
    {
        const f = try Io.Dir.cwd().createFile(io, dest, .{});
        defer f.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var w = f.writer(io, &buf);
        var client: std.http.Client = .{ .allocator = c.gpa, .io = io };
        defer client.deinit();
        const res = try client.fetch(.{ .location = .{ .url = d.url }, .response_writer = &w.interface });
        try w.interface.flush();
        if (res.status != .ok) {
            c.say("HTTP {d}", .{@intFromEnum(res.status)});
            return error.DownloadFailed;
        }
    }
    const h = sha256File(c, dest) orelse return error.DownloadFailed;
    if (!std.mem.eql(u8, &h, d.sha256)) {
        c.say("{s}: SHA-256 {s}, expected {s}", .{ d.name, &h, d.sha256 });
        return error.HashMismatch;
    }
    return dest;
}

fn sha256File(c: *Ctx, p: []const u8) ?[64]u8 {
    const f = Io.Dir.cwd().openFile(c.io, p, .{}) catch return null;
    defer f.close(c.io);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [256 * 1024]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = f.readPositionalAll(c.io, &buf, off) catch return null;
        if (n == 0) break;
        h.update(buf[0..n]);
        off += n;
    }
    return std.fmt.bytesToHex(h.finalResult(), .lower);
}

fn unzipFile(c: *Ctx, zip: []const u8, dest: []const u8) !void {
    c.say("unpacking {s}", .{std.fs.path.basename(zip)});
    var d = try Io.Dir.cwd().createDirPathOpen(c.io, dest, .{});
    defer d.close(c.io);
    const f = try Io.Dir.cwd().openFile(c.io, zip, .{});
    defer f.close(c.io);
    var buf: [64 * 1024]u8 = undefined;
    var r = f.reader(c.io, &buf);
    try std.zip.extract(d, &r, .{ .allow_backslashes = true });
}

fn unzipBytes(c: *Ctx, bytes: []const u8, dest: []const u8) !void {
    const tmp = c.path("{s}\\source.zip", .{c.work});
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = tmp, .data = bytes });
    try unzipFile(c, tmp, dest);
}
