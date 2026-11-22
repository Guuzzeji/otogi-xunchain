//! otogi-xunchain.exe, the launcher. Builds the game from the player's own disc
//! image, plays it, edits settings.ini, lists the saves, and updates itself from
//! GitHub releases (then rebuilds).
//! The build checks the ISO, extracts game\, fetches pinned Zig, the build's
//! packages (ANGLE, Dear ImGui) and Python (+ Capstone), all before the long
//! steps, lifts the XBE to C, builds, and leaves a playable folder:
//!   <out>\otogi.exe, the ANGLE DLLs, settings.ini, game\, otogi-xunchain.exe
//! Work files go to <out>\build; each finished step leaves a stamp in
//! <out>\build\.stamps, so a rerun picks up where it stopped. Once a step runs,
//! every later step runs too.
//! The window is RmlUi (setup/window.cpp): setup/ui/launcher.rml and theme.rcss,
//! filled in by id from here.
const std = @import("std");
const Io = std.Io;
const w32 = std.os.windows;
const xiso = @import("xiso");
const logic = @import("logic.zig");

extern fn ui_init(title: [*:0]const u16, w: c_int, h: c_int) bool;
extern fn ui_font(path: [*:0]const u8, fallback: bool) bool;
extern fn ui_load(path: [*:0]const u8) bool;
extern fn ui_frame() bool;
extern fn ui_set(id: [*:0]const u8, rml: [*:0]const u8) void;
extern fn ui_attr(id: [*:0]const u8, name: [*:0]const u8, value: ?[*:0]const u8) void;
extern fn ui_class(id: [*:0]const u8, class: [*:0]const u8, on: bool) void;
extern fn ui_value(id: [*:0]const u8, value: [*:0]const u8) void;
extern fn ui_clipboard(text: [*:0]const u8) void;
extern fn win_pick_iso(buf: [*]u8, len: c_int) bool;
extern fn win_pick_folder(buf: [*]u8, len: c_int) bool;
extern fn win_open(path: [*:0]const u8) void;
extern fn win_gpu_name() [*:0]const u8;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn SetEnvironmentVariableA(name: [*:0]const u8, value: [*:0]const u8) callconv(.winapi) c_int;
extern "kernel32" fn GetDiskFreeSpaceExA(dir: [*:0]const u8, avail: *u64, total: ?*u64, free: ?*u64) callconv(.winapi) c_int;

/// Release-time `git archive` of the repo (build.zig), and its commit.
const source_zip = @embedFile("source.zip");
const build_info = @import("build_info");
const commit = std.mem.trim(u8, @embedFile("commit.txt"), " \r\n");
/// "v0.6.0 (abc1234)": the version in build.zig.zon and the commit built.
const version = "v" ++ build_info.version ++ " (" ++ commit ++ ")";

/// Where releases are listed; OTOGI_RELEASES_URL overrides it (to test updates).
const releases_url = "https://api.github.com/repos/Guuzzeji/otogi-xunchain/releases";
/// The launcher's asset name in each release.
const asset_name = "otogi-xunchain.exe";
/// Bug reports go to issues; questions to discussions (setup/ui/launcher.rml).
const issues_url = "https://github.com/Guuzzeji/otogi-xunchain/issues";

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

const steps = [_][:0]const u8{ "Check the disc image", "Extract the game files", "Unpack the source code", "Download Zig and libraries", "Download Python and Capstone", "Translate the game code to C", "Compile the game", "Finish" };

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
const step_secs = [_]f32{ 1, 20, 1, 30, 2, 230, 240, 1 };
var step_left: [steps.len]f32 = step_secs;

/// Cancel: the worker stops at the next step; tools die with the job.
var cancel = std.atomic.Value(bool).init(false);
var cancel_armed_at: u64 = 0;
var job: ?w32.HANDLE = null;
extern "kernel32" fn CreateJobObjectA(sa: ?*anyopaque, name: ?[*:0]const u8) callconv(.winapi) ?w32.HANDLE;
extern "kernel32" fn SetInformationJobObject(job: w32.HANDLE, class: c_int, info: *const anyopaque, len: u32) callconv(.winapi) c_int;
extern "kernel32" fn AssignProcessToJobObject(job: w32.HANDLE, process: w32.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn TerminateJobObject(job: w32.HANDLE, code: u32) callconv(.winapi) c_int;

/// Tools and everything they start live in one job. KILL_ON_JOB_CLOSE: when
/// the launcher exits (or is closed mid-build) they all die with it.
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
fn approx(buf: []u8, secs: f32) []const u8 {
    const s_: u32 = @intFromFloat(@max(secs, 0));
    if (s_ >= 90) return std.fmt.bufPrint(buf, "about {d} min", .{(s_ + 30) / 60}) catch "";
    return std.fmt.bufPrint(buf, "about {d} s", .{@max(5, (s_ + 4) / 5 * 5)}) catch "";
}

const stamp_names = [_][]const u8{ "", "extract", "source", "zig", "python", "lift", "build", "" };

/// Before a run: steps whose stamps exist cost nothing.
fn estimateFromStamps(io: Io) f32 {
    var total: f32 = 0;
    var redo = false;
    for (step_secs, stamp_names) |secs, name| {
        const have = name.len != 0 and !redo and hasStamp(io, name);
        if (name.len != 0 and !have) redo = true;
        if (!have) total += secs * slowFactor(name);
    }
    return total;
}

fn hasStamp(io: Io, name: []const u8) bool {
    var p: [1200]u8 = undefined;
    const stamp = std.fmt.bufPrint(&p, "{s}\\build\\.stamps\\{s}", .{ std.mem.sliceTo(&out_buf, 0), name }) catch return false;
    return if (Io.Dir.cwd().access(io, stamp, .{})) |_| true else |_| false;
}

fn slowFactor(name: []const u8) f32 {
    return if (std.mem.eql(u8, name, "build") and ram_gb != 0 and ram_gb < 16) 2.5 else 1;
}

// ── The page's files, all inside the exe (window.cpp asks through ui_file) ──
// setup/assets/art: the game's own menu textures, ripped from the disc so the
// launcher looks like the game before any disc is picked; an OFL font
// (Shippori Mincho B1 Bold, subset) for headings.
const embedded = .{
    .{ "launcher.rml", @embedFile("ui/launcher.rml") },
    .{ "theme.rcss", @embedFile("ui/theme.rcss") },
    .{ "art/title.jpg", @embedFile("assets/art/title.jpg") },
    .{ "art/raikoh.jpg", @embedFile("assets/art/raikoh.jpg") },
    .{ "art/brush.png", @embedFile("assets/art/brush.png") },
    .{ "ShipporiMinchoB1-Bold.ttf", @embedFile("assets/ShipporiMinchoB1-Bold.ttf") },
};

export fn ui_file(path: [*:0]const u8, len: *usize) ?[*]const u8 {
    const p = std.mem.span(path);
    inline for (embedded) |e| if (std.mem.eql(u8, p, e[0])) {
        len.* = e[1].len;
        return e[1].ptr;
    };
    return null;
}

/// Commands from on* attributes (onclick="page" value="saves"). Queued: they
/// arrive mid-frame, while RmlUi walks the very elements a handler may replace.
const Cmd = struct { cmd: [64]u8 = undefined, cmd_len: usize = 0, val: [1100]u8 = undefined, val_len: usize = 0 };
var cmds: [16]Cmd = undefined;
var cmds_len: usize = 0;

export fn ui_event(cmd: [*:0]const u8, value: [*:0]const u8) void {
    if (cmds_len == cmds.len) return;
    const c = &cmds[cmds_len];
    const a = std.mem.span(cmd);
    const b = std.mem.span(value);
    c.cmd_len = @min(a.len, c.cmd.len);
    c.val_len = @min(b.len, c.val.len);
    @memcpy(c.cmd[0..c.cmd_len], a[0..c.cmd_len]);
    @memcpy(c.val[0..c.val_len], b[0..c.val_len]);
    cmds_len += 1;
}

/// Text made safe in markup: "{f}" with esc(s).
const Esc = struct {
    s: []const u8,
    pub fn format(e: Esc, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try logic.escape(w, e.s);
    }
};
fn esc(s: []const u8) Esc {
    return .{ .s = s };
}

/// Inner markup of element `id`, formatted. window.cpp skips it if unchanged.
fn set(id: [*:0]const u8, comptime f: []const u8, args: anytype) void {
    var buf: [16 * 1024]u8 = undefined;
    ui_set(id, std.fmt.bufPrintSentinel(&buf, f, args, 0) catch return);
}

fn attr(id: [*:0]const u8, name: [*:0]const u8, comptime f: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    ui_attr(id, name, std.fmt.bufPrintSentinel(&buf, f, args, 0) catch return);
}

fn z(buf: []u8, comptime f: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, f, args, 0) catch "";
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    ram_gb = (std.process.totalSystemMemory() catch 0) >> 30;
    var exe_dir: [1024]u8 = undefined;
    const n = std.process.executableDirPath(io, &exe_dir) catch 0;
    // In the install folder (beside otogi.exe or game\), that is the folder;
    // anywhere else, a new Otogi folder beside the launcher.
    const here = for ([_][]const u8{ "otogi.exe", "game\\default.xbe", "build\\.stamps" }) |f| {
        var p: [1100]u8 = undefined;
        if (Io.Dir.cwd().access(io, std.fmt.bufPrint(&p, "{s}\\{s}", .{ exe_dir[0..n], f }) catch continue, .{})) |_| break true else |_| {}
    } else false;
    _ = std.fmt.bufPrintSentinel(&out_buf, "{s}{s}", .{ exe_dir[0..n], if (here) "" else "\\Otogi" }, 0) catch {};
    remembered = std.fmt.bufPrint(&remembered_buf, "{s}\\otogi-setup-iso.txt", .{exe_dir[0..n]}) catch remembered;
    deleteOldSelf(io);

    if (!ui_init(std.unicode.utf8ToUtf16LeStringLiteral("Otogi XUnchain"), 1280, 860)) return error.NoWindow;
    const windir = std.mem.span(std.c.getenv("WINDIR") orelse "C:\\Windows");
    for ([_][]const u8{ "segoeui.ttf", "segoeuib.ttf", "consola.ttf", "segmdl2.ttf", "seguiemj.ttf" }) |f| {
        var p: [300]u8 = undefined;
        _ = ui_font(z(&p, "{s}\\Fonts\\{s}", .{ windir, f }), std.mem.eql(u8, f, "seguiemj.ttf")); // emoji in release notes
    }
    _ = ui_font("ShipporiMinchoB1-Bold.ttf", true); // also the fallback for 御伽
    if (!ui_load("launcher.rml")) return error.NoPage;
    makeJob();

    var u: Ui = .{ .io = io, .gpa = gpa };
    // otogi-xunchain.exe <iso> <output folder>: start building at once.
    // otogi-xunchain.exe --rebuild <output folder>: after an update, rebuild.
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "--rebuild")) {
        _ = try std.fmt.bufPrintSentinel(&out_buf, "{s}", .{args[2]}, 0);
        u.findIso(exe_dir[0..n]);
        for (stamp_names) |s| if (s.len != 0 and !std.mem.eql(u8, s, "extract")) {
            var p: [1200]u8 = undefined;
            Io.Dir.cwd().deleteFile(io, std.fmt.bufPrint(&p, "{s}\\build\\.stamps\\{s}", .{ args[2], s }) catch continue) catch {};
        };
        u.page = .install;
        u.start();
    } else if (args.len == 3) {
        _ = try std.fmt.bufPrintSentinel(&iso_buf, "{s}", .{args[1]}, 0);
        _ = try std.fmt.bufPrintSentinel(&out_buf, "{s}", .{args[2]}, 0);
        u.checkIso();
        u.page = .install;
        u.start();
    } else {
        u.findIso(exe_dir[0..n]);
    }
    u.refresh();
    if (!u.built and !running.load(.acquire)) u.page = .install;
    news.thread = std.Thread.spawn(.{}, fetchNews, .{ io, gpa }) catch null;

    while (ui_frame()) {
        if (u.thread != null and !running.load(.acquire)) {
            u.thread.?.join();
            u.thread = null;
            u.refresh();
            if (result == .ok) u.page = .play;
        }
        for (cmds[0..cmds_len]) |*c| u.handle(c.cmd[0..c.cmd_len], c.val[0..c.val_len]);
        cmds_len = 0;
        if (news.update.load(.acquire) == .ready) return u.relaunch();
        u.tailLog();
        u.draw();
    }
}

const Page = enum { play, install, settings, saves, news, help };

const Ui = struct {
    io: Io,
    gpa: std.mem.Allocator,
    thread: ?std.Thread = null,
    page: Page = .play,
    log: std.ArrayList(u8) = .empty,
    log_off: u64 = 0,
    iso_state: enum { none, ok, wrong, unreadable } = .none,
    copied_at: u64 = 0,
    help_log: enum { game, build } = .game,
    toast: [:0]const u8 = "",
    toast_at: u64 = 0,
    /// Refreshed every second: the game is built, its disc is extracted.
    built: bool = false,
    extracted: bool = false,
    free_gb: ?u64 = null,
    refreshed_at: u64 = 0,
    shown_page: ?Page = null,
    news_shown: bool = false,
    /// settings.ini as last read, and what the page shows of it.
    ini: []u8 = &.{},
    ini_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    saves_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),

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

    fn say(u: *Ui, msg: [:0]const u8) void {
        u.toast = msg;
        u.toast_at = GetTickCount64();
    }

    /// What the disk says: built, extracted, free space, settings.
    fn refresh(u: *Ui) void {
        u.refreshed_at = GetTickCount64();
        u.built = hasFile(u.io, "otogi.exe");
        u.extracted = hasStamp(u.io, "extract");
        u.free_gb = freeGb();
        u.loadSettings();
        u.loadSaves();
        if (u.page == .help) u.loadHelpLog();
    }

    fn handle(u: *Ui, cmd: []const u8, val: []const u8) void {
        const busy = running.load(.acquire);
        const eql = std.mem.eql;
        if (eql(u8, cmd, "page")) {
            u.page = std.meta.stringToEnum(Page, val) orelse return;
            if (u.page == .settings or u.page == .saves or u.page == .help) u.refresh();
        } else if (eql(u8, cmd, "page-step")) {
            const i: i32 = @intFromEnum(u.page);
            const d: i32 = if (eql(u8, val, "-1")) -1 else 1;
            u.page = @enumFromInt(@mod(i + d, @as(i32, std.meta.tags(Page).len)));
        } else if (eql(u8, cmd, "back")) {
            u.page = .play;
        } else if (eql(u8, cmd, "play-main")) {
            if (u.built and !busy) openOut("otogi.exe") else u.page = .install;
        } else if (eql(u8, cmd, "iso") and !busy) {
            _ = std.fmt.bufPrintSentinel(&iso_buf, "{s}", .{val}, 0) catch return;
            u.checkIso();
        } else if (eql(u8, cmd, "pick-iso") and !busy) {
            if (win_pick_iso(&iso_buf, iso_buf.len)) u.checkIso();
        } else if (eql(u8, cmd, "out") and !busy) {
            _ = std.fmt.bufPrintSentinel(&out_buf, "{s}", .{val}, 0) catch return;
            u.refresh();
        } else if (eql(u8, cmd, "pick-out") and !busy) {
            var pick: [1024:0]u8 = @splat(0);
            if (win_pick_folder(&pick, pick.len)) _ = std.fmt.bufPrintSentinel(&out_buf, "{s}\\Otogi", .{std.mem.sliceTo(&pick, 0)}, 0) catch {};
            u.refresh();
        } else if (eql(u8, cmd, "build")) {
            const now = GetTickCount64();
            if (busy) {
                if (now - cancel_armed_at < 3000) stopBuild() else cancel_armed_at = now;
            } else if (u.iso_state == .ok or u.extracted) u.start();
        } else if (eql(u8, cmd, "copy-log")) {
            _ = u.copyLog("setup.log");
            u.copied_at = GetTickCount64();
        } else if (eql(u8, cmd, "log-pick")) {
            u.help_log = if (eql(u8, val, "build")) .build else .game;
            u.loadHelpLog();
        } else if (eql(u8, cmd, "log-copy")) {
            u.say(if (u.copyLog(u.helpLogName())) "Log copied." else "There is no log to copy yet.");
        } else if (eql(u8, cmd, "log-open")) {
            var p: [1100:0]u8 = undefined;
            win_open(z(&p, "{s}\\{s}", .{ std.mem.sliceTo(&out_buf, 0), u.helpLogName() }));
        } else if (eql(u8, cmd, "report")) {
            // From a failed build: its log; from Help: the log on show.
            u.report(if (eql(u8, val, "build")) "setup.log" else u.helpLogName());
        } else if (eql(u8, cmd, "url") and std.mem.startsWith(u8, val, "https://github.com/")) {
            var p: [300:0]u8 = undefined;
            win_open(z(&p, "{s}", .{val}));
        } else if (eql(u8, cmd, "open-log")) {
            openOut("setup.log");
        } else if (eql(u8, cmd, "open-out")) {
            openOut("");
        } else if (eql(u8, cmd, "open-settings")) {
            openOut("settings.ini");
        } else if (std.mem.startsWith(u8, cmd, "set:")) {
            u.setSetting(cmd[4..], val);
        } else if (std.mem.startsWith(u8, cmd, "toggle:")) {
            const on = for (u.entries()) |e| (if (eql(u8, e.key, cmd[7..])) break eql(u8, e.value, "1")) else false;
            u.setSetting(cmd[7..], if (on) "0" else "1");
        } else if (std.mem.startsWith(u8, cmd, "step:")) {
            const now = for (u.entries()) |e| (if (eql(u8, e.key, cmd[5..])) break std.fmt.parseFloat(f32, e.value) catch 1) else 1;
            var i: usize = 0;
            while (i + 1 < distances.len and distances[i] < now - 0.01) i += 1;
            i = if (eql(u8, val, "-")) i -| 1 else @min(i + 1, distances.len - 1);
            var b: [16]u8 = undefined;
            u.setSetting(cmd[5..], std.fmt.bufPrint(&b, "{d}", .{distances[i]}) catch return);
        } else if (eql(u8, cmd, "open-saves")) {
            var p: [600:0]u8 = undefined;
            win_open(z(&p, "{s}", .{saveDir(&p)}));
        } else if (eql(u8, cmd, "backup-saves")) {
            u.backupSaves();
        } else if (eql(u8, cmd, "update")) {
            if (busy) return u.say("Wait for the build to finish first.");
            if (news.update.load(.acquire) == .downloading) return; // only this thread starts one
            if (news.update_thread) |t| t.join(); // the last try, finished
            update_err[0] = 0;
            news.update.store(.downloading, .release);
            news.update_thread = std.Thread.spawn(.{}, downloadUpdate, .{ u.io, u.gpa }) catch null;
        }
    }

    // ── Drawing: every frame sets what each element shows; unchanged costs nothing.
    fn draw(u: *Ui) void {
        const now = GetTickCount64();
        if (now - u.refreshed_at > 1000) u.refresh();
        const busy = running.load(.acquire);
        var b: [2048]u8 = undefined;

        if (u.shown_page != u.page) {
            u.shown_page = u.page;
            inline for (comptime std.meta.fieldNames(Page)) |f| {
                ui_class("nav-" ++ f, "on", u.page == @field(Page, f));
                ui_class("page-" ++ f, "shown", u.page == @field(Page, f));
            }
        }
        set("title-ver", "{s}", .{"v" ++ build_info.version});
        set("foot-ver", "{s}", .{version});
        set("foot-gpu", "{f}", .{esc(std.mem.span(win_gpu_name()))});
        ui_class("toast", "shown", now - u.toast_at < 2500 and u.toast.len != 0);
        if (u.toast.len != 0) set("toast", "{s}", .{u.toast});

        // Play
        ui_class("play-btn", "busy", busy);
        set("play-btn", "{s}", .{if (busy) "BUILDING" else if (u.built) "PLAY" else "INSTALL"});
        var eta: [32]u8 = undefined;
        if (busy)
            set("play-status", "Building: <strong>{s}</strong>, {s} left", .{ steps[@min(step_at.load(.acquire), steps.len - 1)], approx(&eta, secsLeft()) })
        else if (u.built)
            set("play-status", "<strong>Ready</strong> &#x2014; {s}", .{"v" ++ build_info.version})
        else
            set("play-status", "Not installed yet. <strong>Install</strong> builds it from your disc.", .{});

        u.drawInstall(busy, &b);
        u.drawNews();
    }

    fn drawInstall(u: *Ui, busy: bool, b: []u8) void {
        const now = GetTickCount64();
        ui_value("iso", &iso_buf);
        ui_value("out", &out_buf);
        ui_attr("iso", "disabled", if (busy) "" else null);
        ui_attr("out", "disabled", if (busy) "" else null);
        set("iso-status", "{s}", .{switch (u.iso_state) {
            .none => if (u.extracted) "<span class=\"good\">Already extracted: the disc is not needed again.</span>" else "<span class=\"muted\">Pick the .iso file.</span>",
            .ok => "<span class=\"good\">Otogi (USA): verified</span>",
            .wrong => "<span class=\"bad\">Not the Otogi (USA) disc this build supports (default.xbe does not match).</span>",
            .unreadable => "<span class=\"bad\">Cannot read an Xbox game from this file.</span>",
        }});
        if (u.free_gb) |f|
            set("out-status", "<span class=\"{s}\">{d} GB free on this drive, {d} GB needed.</span>{s}", .{ if (f < need_gb) "bad" else "muted", f, need_gb, if (ram_gb != 0 and ram_gb < 16) " <span class=\"gold\">Under 16 GB of RAM: the compile runs one job at a time and takes longer.</span>" else "" })
        else
            set("out-status", "", .{});

        const armed = busy and now - cancel_armed_at < 3000;
        const can = busy or u.iso_state == .ok or u.extracted;
        ui_class("build", "busy", busy);
        ui_class("build", "off", !can);
        set("build", "{s}", .{if (busy and cancel.load(.acquire)) "STOPPING..." else if (armed) "CLICK AGAIN TO STOP" else if (busy) "STOP THE BUILD" else if (!can) "PICK YOUR DISC IMAGE FIRST" else if (result == .failed) "TRY AGAIN" else if (u.built) "BUILD AGAIN" else "BUILD THE GAME"});
        var eta: [32]u8 = undefined;
        if (busy)
            set("eta", "{s} left", .{approx(&eta, secsLeft())})
        else if (can and result != .ok)
            set("eta", "Takes {s}, most of it translating and compiling.", .{approx(&eta, estimateFromStamps(u.io))})
        else
            set("eta", "", .{});

        // Progress: filled by time, not by step count: the compile is most of it.
        const at = step_at.load(.acquire);
        const started = busy or result != .none;
        var total: f32 = 0;
        for (step_left) |v| total += v;
        const frac: f32 = if (result == .ok) 1 else if (!started or total == 0) 0 else std.math.clamp(1 - secsLeft() / total, 0, 1);
        attr("progress", "value", "{d:.3}", .{frac});
        const end = if (busy) now else finished_ms;
        const secs = (end -| started_ms) / 1000;
        if (started)
            set("progress-label", "{s} &#x2014; {d}:{d:0>2}", .{ switch (result) {
                .ok => "Done",
                .failed => "Stopped",
                .none => steps[@min(at, steps.len - 1)],
            }, secs / 60, secs % 60 })
        else
            set("progress-label", "<span class=\"muted\">Not started.</span>", .{});
        var w: std.Io.Writer = .fixed(b);
        for (steps, 0..) |s, i| {
            const state = if (!started) "" else if (result == .ok or i < at) "done" else if (i == at) (if (result == .failed) "failed" else "now") else "";
            w.print("<div class=\"step {s}\"><div class=\"dot\"/><span class=\"label\">{s}</span></div>", .{ state, s }) catch break;
        }
        w.writeByte(0) catch {};
        ui_set("steps", @ptrCast(w.buffered().ptr));
        if (result == .ok)
            set("build-result", "<div class=\"gap\"/><p class=\"good\">Otogi is ready.</p><div class=\"gap\"/><div class=\"btn primary\" onclick=\"play-main\">Play</div><div class=\"btn\" onclick=\"open-out\">Open folder</div><div class=\"btn\" onclick=\"page\" value=\"settings\">Settings</div>", .{})
        else if (result == .failed)
            set("build-result", "<div class=\"gap\"/><p class=\"bad\">{f}</p><p class=\"muted small\">Try again keeps the finished steps. If it keeps failing, report it: the log goes with it.</p><div class=\"btn\" onclick=\"report\" value=\"build\">Report this on GitHub</div>", .{esc(std.mem.sliceTo(&fail_msg, 0))})
        else
            set("build-result", "", .{});

        set("copied", "{s}", .{if (now - u.copied_at < 2000 and u.copied_at != 0) "<span class=\"good\">Copied. Paste it into your report.</span>" else "Send this with any problem report."});
        set("sysline", "launcher {s} &#x2014; {f}", .{ version, esc(std.mem.span(win_gpu_name())) });
    }

    fn drawLog(u: *Ui) void {
        showLog(u.gpa, "log", u.log.items, "Nothing yet. The log fills in once you build.");
    }

    /// A whole log (setup.log, otogi.log) to the clipboard: the views keep only
    /// its tail. False if there is none.
    fn copyLog(u: *Ui, name: []const u8) bool {
        var p: [1100]u8 = undefined;
        const path = std.fmt.bufPrint(&p, "{s}\\{s}", .{ std.mem.sliceTo(&out_buf, 0), name }) catch return false;
        const text = Io.Dir.cwd().readFileAllocOptions(u.io, path, u.gpa, .limited(64 << 20), .of(u8), 0) catch return false;
        defer u.gpa.free(text);
        ui_clipboard(text.ptr);
        return true;
    }

    // ── Help & logs ─────────────────────────────────────────────────────────
    fn helpLogName(u: *Ui) []const u8 {
        return if (u.help_log == .game) "otogi.log" else "setup.log";
    }

    /// The picked log's tail, followed live: refresh() calls this each second.
    fn loadHelpLog(u: *Ui) void {
        ui_class("log-game", "on", u.help_log == .game);
        ui_class("log-build", "on", u.help_log == .build);
        var p: [1100]u8 = undefined;
        const path = std.fmt.bufPrint(&p, "{s}\\{s}", .{ std.mem.sliceTo(&out_buf, 0), u.helpLogName() }) catch return;
        set("help-log-path", "{f}", .{esc(path)});
        const f = Io.Dir.cwd().openFile(u.io, path, .{}) catch {
            set("help-log-info", "", .{});
            return showLog(u.gpa, "help-log", "", if (u.help_log == .game) "No game log yet. otogi.log is written each time the game runs (unless log = 0 in Settings)." else "No build log yet. setup.log is written when you build the game.");
        };
        defer f.close(u.io);
        const st = f.stat(u.io) catch return;
        const keep = 96 * 1024; // ponytail: the tail only; Copy and Open file have it all
        const buf = u.gpa.alloc(u8, @min(st.size, keep)) catch return;
        defer u.gpa.free(buf);
        const got = f.readPositionalAll(u.io, buf, st.size - buf.len) catch return;
        var d: [16]u8 = undefined;
        set("help-log-info", "{d} KB, last written {s} (UTC)", .{ (st.size + 1023) / 1024, dateTime(&d, st.mtime.nanoseconds) });
        showLog(u.gpa, "help-log", buf[0..got], "The log is empty.");
    }

    /// A new GitHub issue with the version and this PC filled in, and the log
    /// on the clipboard to paste into it (a URL cannot carry a file).
    fn report(u: *Ui, log: []const u8) void {
        const copied = u.copyLog(log);
        var m: [400]u8 = undefined;
        var body_buf: [2048]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            \\**What happened?**
            \\
            \\
            \\**What were you doing?** (stage, menu, settings you changed)
            \\
            \\
            \\**Version:** {s}
            \\**PC:** {s}
            \\
            \\**Log** ({s}):
            \\{s}
            \\
        , .{ version, machine(&m), log, if (copied) "the launcher copied it: paste it here, or drag the file in from the game folder" else "drag it in from the game folder" }) catch return;
        var url: [6144:0]u8 = undefined;
        var w: std.Io.Writer = .fixed(&url);
        w.writeAll(issues_url ++ "/new?labels=bug&body=") catch return;
        logic.urlEncode(&w, body) catch return;
        w.writeByte(0) catch return;
        win_open(@ptrCast(w.buffered().ptr));
        u.say(if (copied) "Log copied. Paste it into the issue that just opened." else "Opened a new issue on GitHub.");
    }

    /// Show the tail of <out>\setup.log (ours and the tools' output).
    fn tailLog(u: *Ui) void {
        var path: [1100]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "{s}\\setup.log", .{std.mem.sliceTo(&out_buf, 0)}) catch return;
        const f = Io.Dir.cwd().openFile(u.io, p, .{}) catch return u.drawLog();
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
        if (got != 0 or u.log.items.len == 0) u.drawLog();
    }

    // ── Settings: settings.ini as a form, saved on every change ─────────────
    fn entries(u: *Ui) []logic.Entry {
        return logic.entries(u.ini_arena.allocator(), u.ini) catch &.{};
    }

    fn loadSettings(u: *Ui) void {
        _ = u.ini_arena.reset(.retain_capacity);
        const a = u.ini_arena.allocator();
        var p: [1100]u8 = undefined;
        const path = std.fmt.bufPrint(&p, "{s}\\settings.ini", .{std.mem.sliceTo(&out_buf, 0)}) catch return;
        set("settings-path", "{f}", .{esc(path)});
        u.ini = Io.Dir.cwd().readFileAlloc(u.io, path, a, .limited(64 * 1024)) catch {
            u.ini = &.{};
            set("settings-list", "<div class=\"gap\"/><p class=\"muted\">settings.ini comes with the game. Install it first.</p>", .{});
            set("tile-settings-title", "Not installed", .{});
            set("tile-settings-text", "Settings appear once the game is built.", .{});
            return;
        };
        const es = u.entries();
        // The form's shape (keys and choices) is set once; values go on by id,
        // so a click keeps the controller's focus where it is.
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        for (es) |e| {
            const k = knownSetting(e.key);
            const kind = if (k) |x| x.kind else .text;
            w.print("<div class=\"setting{s}\"><div class=\"what\"><div class=\"label\">{f}</div><div class=\"help\">{f}</div></div><div class=\"ctl\">", .{ if (kind == .chips or kind == .text) " stack" else "", esc(if (k) |x| x.label else e.key), esc(e.help) }) catch return;
            switch (kind) {
                .chips => {
                    w.writeAll("<div class=\"chips\">") catch return;
                    var listed = false;
                    for (k.?.opts) |o| {
                        listed = listed or std.mem.eql(u8, o.v, e.value);
                        w.print("<div class=\"chip\" id=\"opt-{s}-{s}\" onclick=\"set:{s}\" value=\"{s}\">{s}</div>", .{ e.key, o.v, e.key, o.v, o.label }) catch return;
                    }
                    if (!listed) w.print("<div class=\"chip\" id=\"opt-{f}-{f}\" onclick=\"set:{f}\" value=\"{f}\">{f}</div>", .{ esc(e.key), esc(e.value), esc(e.key), esc(e.value), esc(e.value) }) catch return;
                    w.writeAll("</div>") catch return;
                },
                .toggle => w.print("<div class=\"toggle\" id=\"opt-{s}\" onclick=\"toggle:{s}\"><div class=\"knob\"/></div>", .{ e.key, e.key }) catch return,
                .stepper => w.print("<div class=\"row stepper\"><div class=\"btn\" onclick=\"step:{s}\" value=\"-\">&#x2212;</div><div class=\"val\" id=\"val-{s}\"></div><div class=\"btn\" onclick=\"step:{s}\" value=\"+\">+</div></div>", .{ e.key, e.key, e.key }) catch return,
                .text => w.print("<input type=\"text\" class=\"text\" id=\"opt-{f}\" onchange=\"set:{f}\" placeholder=\"default\"/>", .{ esc(e.key), esc(e.key) }) catch return,
            }
            w.writeAll("</div></div>") catch return;
        }
        w.writeByte(0) catch return;
        ui_set("settings-list", @ptrCast(out.written().ptr));

        var v: [600]u8 = undefined;
        var sum: std.Io.Writer = .fixed(&v);
        for (es) |e| {
            var b: [200]u8 = undefined;
            const k = knownSetting(e.key) orelse {
                ui_value(z(&b, "opt-{s}", .{e.key}), z(b[100..], "{s}", .{e.value}));
                continue;
            };
            switch (k.kind) {
                .chips => for (k.opts) |o| ui_class(z(&b, "opt-{s}-{s}", .{ e.key, o.v }), "on", std.mem.eql(u8, o.v, e.value)),
                .toggle => ui_class(z(&b, "opt-{s}", .{e.key}), "on", std.mem.eql(u8, e.value, "1")),
                .stepper => set(z(&b, "val-{s}", .{e.key}), "{s}x", .{if (e.value.len == 0) "1" else e.value}),
                .text => ui_value(z(&b, "opt-{s}", .{e.key}), z(b[100..], "{s}", .{e.value})),
            }
            if (k.summary) for (k.opts) |o| if (std.mem.eql(u8, o.v, e.value)) sum.print("{s}{s}", .{ if (sum.end == 0) "" else " &#x00B7; ", o.label }) catch {};
        }
        set("tile-settings-title", "Display", .{});
        set("tile-settings-text", "{s}", .{sum.buffered()});
    }

    fn setSetting(u: *Ui, key: []const u8, value: []const u8) void {
        if (u.ini.len == 0) return u.say("Install the game first: settings.ini comes with it.");
        const new = logic.withValue(u.gpa, u.ini, key, value) catch return;
        defer u.gpa.free(new);
        var p: [1100]u8 = undefined;
        const path = std.fmt.bufPrint(&p, "{s}\\settings.ini", .{std.mem.sliceTo(&out_buf, 0)}) catch return;
        Io.Dir.cwd().writeFile(u.io, .{ .sub_path = path, .data = new }) catch return u.say("Could not write settings.ini.");
        u.loadSettings();
        u.say("Saved. Takes effect the next time the game starts.");
    }

    // ── Saves: the game's memory unit, %LOCALAPPDATA%\Otogi (src/main.zig) ──
    fn loadSaves(u: *Ui) void {
        _ = u.saves_arena.reset(.retain_capacity);
        const a = u.saves_arena.allocator();
        var p: [600:0]u8 = undefined;
        const root = saveDir(&p);
        set("saves-path", "{f}", .{esc(root)});
        const Save = struct { name: []const u8, game: bool, mtime: i96, size: u64 };
        var saves: std.ArrayList(Save) = .empty;
        const udata = std.fmt.allocPrint(a, "{s}\\UDATA\\" ++ title_id, .{root}) catch return;
        if (Io.Dir.cwd().openDir(u.io, udata, .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close(u.io);
            var it = dir.iterate();
            while (it.next(u.io) catch null) |e| {
                if (e.kind != .directory) continue;
                var s: Save = .{ .name = e.name, .game = false, .mtime = 0, .size = 0 };
                s.name = a.dupe(u8, e.name) catch continue;
                var sub = dir.openDir(u.io, e.name, .{ .iterate = true }) catch continue;
                defer sub.close(u.io);
                var fi = sub.iterate();
                while (fi.next(u.io) catch null) |f| {
                    const st = sub.statFile(u.io, f.name, .{}) catch continue;
                    s.size += st.size;
                    s.mtime = @max(s.mtime, st.mtime.nanoseconds);
                    if (std.mem.eql(u8, f.name, "game.xsv")) s.game = true;
                    if (std.mem.eql(u8, f.name, "SaveMeta.xbx")) s.name = saveName(u.io, a, sub) orelse s.name;
                }
                saves.append(a, s) catch {};
            }
        } else |_| {}
        std.mem.sort(Save, saves.items, {}, struct {
            fn lt(_: void, x: Save, y: Save) bool {
                return x.mtime > y.mtime;
            }
        }.lt);
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        var games: usize = 0;
        for (saves.items) |s| {
            if (s.game) games += 1;
            var d: [16]u8 = undefined;
            w.print("<div class=\"save\"><span class=\"icon\">{s}</span><span class=\"name\">{f}</span><span class=\"meta\">{s}</span><span class=\"meta\">{s}</span><span class=\"meta\">{d} KB</span></div>", .{ if (s.game) "&#xE7FC;" else "&#xE707;", esc(s.name), if (s.game) "Game save" else "Stage data", date(&d, s.mtime), (s.size + 1023) / 1024 }) catch return;
        }
        if (saves.items.len == 0) w.writeAll("<p class=\"muted\">No saves yet. They appear here once you save in the game.</p>") catch return;
        w.writeByte(0) catch return;
        ui_set("saves-list", @ptrCast(out.written().ptr));
        if (games == 0) {
            set("tile-saves-title", "No saves yet", .{});
            set("tile-saves-text", "Saved games appear here.", .{});
        } else {
            var d: [16]u8 = undefined;
            const last = for (saves.items) |s| (if (s.game) break s) else unreachable;
            set("tile-saves-title", "{d} saved game{s}", .{ games, if (games == 1) "" else "s" });
            set("tile-saves-text", "Last: {f}, {s}", .{ esc(last.name), date(&d, last.mtime) });
        }
    }

    /// The memory unit's saves (UDATA) copied to "Otogi saves <date>" in a picked folder.
    fn backupSaves(u: *Ui) void {
        var pick: [1024:0]u8 = @splat(0);
        if (!win_pick_folder(&pick, pick.len)) return;
        var p: [600:0]u8 = undefined;
        var src: [700]u8 = undefined;
        var dst: [1200]u8 = undefined;
        var d: [16]u8 = undefined;
        const from = std.fmt.bufPrint(&src, "{s}\\UDATA", .{saveDir(&p)}) catch return;
        const now: i96 = @intCast(std.Io.Clock.real.now(u.io).nanoseconds);
        const to = std.fmt.bufPrint(&dst, "{s}\\Otogi saves {s}\\UDATA", .{ std.mem.sliceTo(&pick, 0), date(&d, now) }) catch return;
        copyTree(u.io, u.gpa, from, to) catch return u.say("Back up failed: could not copy the saves.");
        win_open(z(&p, "{s}", .{std.fs.path.dirname(to).?}));
        u.say("Saves backed up.");
    }

    // ── What's new and updates ──────────────────────────────────────────────
    fn drawNews(u: *Ui) void {
        const update = news.update.load(.acquire);
        switch (update) {
            .downloading => set("update-btn", "UPDATING", .{}),
            .failed => {
                set("update-btn", "TRY AGAIN", .{});
                set("banner-text", "<span class=\"bad\">{f}</span>", .{esc(if (update_err[0] != 0) std.mem.sliceTo(&update_err, 0) else "The download is not a launcher exe. Try again later.")});
            },
            else => set("update-btn", "UPDATE", .{}),
        }
        const state = news.state.load(.acquire);
        if (state == .fetching or u.news_shown) return;
        u.news_shown = true;
        if (state == .failed) {
            set("tile-news-title", "v{s}", .{build_info.version});
            set("tile-news-text", "Could not reach GitHub for updates.", .{});
            set("play-notes", "<h3>What's in v{s}</h3><p class=\"muted\">The release notes show here when GitHub can be reached.</p>", .{build_info.version});
            set("releases", "<div class=\"card\"><p class=\"muted\">Could not reach GitHub ({s}). The release notes and updates show here when it can.</p></div>", .{std.mem.sliceTo(&news.err, 0)});
            return;
        }
        var out: std.Io.Writer.Allocating = .init(u.gpa);
        defer out.deinit();
        const w = &out.writer;
        var shown: usize = 0;
        for (news.releases) |r| {
            if (r.draft or r.prerelease) continue;
            if (shown == 15) break;
            shown += 1;
            const tag = std.mem.trimStart(u8, r.tag_name, "v");
            const is_new = logic.newer(tag, build_info.version);
            const is_now = std.mem.eql(u8, tag, build_info.version);
            if (is_now) {
                var notes: std.Io.Writer.Allocating = .init(u.gpa);
                defer notes.deinit();
                notes.writer.print("<h3>What's in v{s}</h3><div class=\"when\">{f}</div>", .{ build_info.version, esc(if (r.published_at) |d| d[0..@min(10, d.len)] else "") }) catch {};
                logic.notesRml(&notes.writer, r.body orelse "") catch {};
                notes.writer.writeByte(0) catch {};
                ui_set("play-notes", @ptrCast(notes.written().ptr));
            }
            w.print("<div class=\"card release\"><h3>v{f}{s}</h3><div class=\"when\">{f}</div>", .{ esc(tag), if (is_now) "<span class=\"tag now\">INSTALLED</span>" else if (is_new) "<span class=\"tag new\">NEW</span>" else "", esc(if (r.published_at) |d| d[0..@min(10, d.len)] else "") }) catch return;
            logic.notesRml(w, r.body orelse "") catch return;
            w.writeAll("</div>") catch return;
        }
        if (shown == 0) w.writeAll("<div class=\"card\"><p class=\"muted\">No releases yet.</p></div>") catch return;
        w.writeByte(0) catch return;
        ui_set("releases", @ptrCast(out.written().ptr));

        if (news.latest) |l| {
            const tag = std.mem.trimStart(u8, l.tag_name, "v");
            ui_class("banner", "shown", true);
            ui_class("news-badge", "shown", true);
            set("banner-title", "v{f} is out", .{esc(tag)});
            set("banner-text", "You have v{s}. Update downloads the new launcher, then rebuilds the game from your disc (translate and compile again, about 8 minutes). Your saves and settings stay.", .{build_info.version});
            set("tile-news-title", "v{f} is out", .{esc(tag)});
            set("tile-news-text", "Update from here: no need to download anything yourself.", .{});
        } else {
            set("tile-news-title", "v{s}", .{build_info.version});
            set("tile-news-text", "You have the latest version.", .{});
        }
    }

    /// After a downloaded update: run the new launcher to rebuild, and quit.
    fn relaunch(u: *Ui) !void {
        var p: [1100]u8 = undefined;
        const n = try std.process.executablePath(u.io, &p);
        _ = try std.process.spawn(u.io, .{ .argv = &.{ p[0..n], "--rebuild", std.mem.sliceTo(&out_buf, 0) }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    }
};

/// Settings the form knows: a label and proper controls. Others get a text field.
const Known = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { chips, toggle, stepper, text },
    opts: []const struct { v: []const u8, label: []const u8 } = &.{},
    summary: bool = false, // on the Play page's Settings tile
};
const known = [_]Known{
    .{ .key = "window", .label = "Window mode", .kind = .chips, .summary = true, .opts = &.{ .{ .v = "0", .label = "Window" }, .{ .v = "1", .label = "Borderless" }, .{ .v = "2", .label = "Fullscreen" } } },
    .{ .key = "resolution", .label = "Fullscreen resolution", .kind = .text },
    .{ .key = "scale", .label = "Internal resolution", .kind = .chips, .summary = true, .opts = &.{ .{ .v = "1", .label = "1x (640x480)" }, .{ .v = "2", .label = "2x" }, .{ .v = "3", .label = "3x" }, .{ .v = "4", .label = "4x" } } },
    .{ .key = "widescreen", .label = "Widescreen (16:9)", .kind = .toggle },
    .{ .key = "framerate", .label = "Frame rate", .kind = .chips, .summary = true, .opts = &.{ .{ .v = "0", .label = "Monitor's" }, .{ .v = "30", .label = "30 (original)" }, .{ .v = "60", .label = "60" }, .{ .v = "120", .label = "120" }, .{ .v = "144", .label = "144" } } },
    .{ .key = "vsync", .label = "V-sync", .kind = .toggle },
    .{ .key = "gfx", .label = "Graphics backend", .kind = .chips, .opts = &.{ .{ .v = "d3d11", .label = "Direct3D 11" }, .{ .v = "vulkan", .label = "Vulkan" }, .{ .v = "gl", .label = "OpenGL" } } },
    .{ .key = "mist_depth", .label = "Ground mist stays behind the ground", .kind = .toggle },
    .{ .key = "cam_invert", .label = "Modern right-stick camera", .kind = .toggle },
    .{ .key = "draw_distance", .label = "Draw distance", .kind = .stepper },
    .{ .key = "fog_distance", .label = "Fog distance", .kind = .stepper },
    .{ .key = "debug_menu", .label = "Debug menu at start (F1)", .kind = .toggle },
    .{ .key = "log", .label = "Write otogi.log", .kind = .toggle },
};
const distances = [_]f32{ 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8 };

fn knownSetting(key: []const u8) ?Known {
    for (known) |k| if (std.mem.eql(u8, k.key, key)) return k;
    return null;
}

const title_id = "46530002";

/// %LOCALAPPDATA%\Otogi, where otogi.exe keeps its memory unit (src/main.zig).
fn saveDir(buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}\\Otogi", .{std.mem.span(std.c.getenv("LOCALAPPDATA") orelse ".")}) catch ".";
}

/// SaveMeta.xbx is UTF-16 "Name=OTOGI01 LV02 00:02\r\n...".
fn saveName(io: Io, a: std.mem.Allocator, dir: Io.Dir) ?[]const u8 {
    var raw: [512]u8 align(2) = undefined;
    const got = dir.readFile(io, "SaveMeta.xbx", &raw) catch return null;
    const text = std.unicode.utf16LeToUtf8Alloc(a, std.mem.bytesAsSlice(u16, @as([]align(2) const u8, @alignCast(got[0 .. got.len & ~@as(usize, 1)])))) catch return null;
    const at = std.mem.indexOf(u8, text, "Name=") orelse return null;
    const name = text[at + 5 ..];
    return std.mem.trim(u8, name[0 .. std.mem.indexOfAny(u8, name, "\r\n") orelse name.len], " ");
}

/// The last 400 lines of `text`, escaped, into element `id` (a log view).
fn showLog(gpa: std.mem.Allocator, id: [*:0]const u8, log_text: []const u8, empty: [*:0]const u8) void {
    if (log_text.len == 0) return ui_set(id, empty);
    var lines: usize = 0;
    var i = log_text.len;
    while (i > 0 and lines < 400) : (i -= 1) if (log_text[i - 1] == '\n') {
        lines += 1;
    };
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    logic.escape(&out.writer, log_text[i..]) catch return;
    out.writer.writeByte(0) catch return;
    ui_set(id, @ptrCast(out.written().ptr));
}

/// "2026-11-14 18:03" (UTC) from file-time nanoseconds.
fn dateTime(buf: []u8, ns: i96) []const u8 {
    var d: [16]u8 = undefined;
    const secs: u64 = @intCast(@max(0, @divFloor(ns, std.time.ns_per_s)));
    return std.fmt.bufPrint(buf, "{s} {d:0>2}:{d:0>2}", .{ date(&d, ns), secs / 3600 % 24, secs / 60 % 60 }) catch "";
}

/// "2026-11-14" (UTC) from file-time nanoseconds.
fn date(buf: []u8, ns: i96) []const u8 {
    const secs: u64 = @intCast(@max(0, @divFloor(ns, std.time.ns_per_s)));
    const day = (std.time.epoch.EpochSeconds{ .secs = secs }).getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1 }) catch "";
}

fn copyTree(io: Io, gpa: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    var src = try Io.Dir.cwd().openDir(io, from, .{ .iterate = true });
    defer src.close(io);
    var dst = try Io.Dir.cwd().createDirPathOpen(io, to, .{});
    defer dst.close(io);
    var walk = try src.walk(gpa);
    defer walk.deinit();
    while (try walk.next(io)) |e| switch (e.kind) {
        .directory => try dst.createDirPath(io, e.path),
        .file => try Io.Dir.copyFile(src, e.path, dst, e.path, io, .{}),
        else => {},
    };
}

fn hasFile(io: Io, name: []const u8) bool {
    var p: [1100]u8 = undefined;
    const path = std.fmt.bufPrint(&p, "{s}\\{s}", .{ std.mem.sliceTo(&out_buf, 0), name }) catch return false;
    return if (Io.Dir.cwd().access(io, path, .{})) |_| true else |_| false;
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

// ── GitHub releases (a thread at startup) and the update download ──────────
const Release = struct {
    tag_name: []const u8,
    body: ?[]const u8 = null,
    published_at: ?[]const u8 = null,
    draft: bool = false,
    prerelease: bool = false,
    assets: []const struct { name: []const u8, browser_download_url: []const u8 } = &.{},
};
var news: struct {
    state: std.atomic.Value(enum(u8) { fetching, ok, failed }) = .init(.fetching),
    releases: []const Release = &.{},
    /// The newest release past this version that carries the launcher.
    latest: ?Release = null,
    err: [64]u8 = @splat(0),
    thread: ?std.Thread = null,
    update: std.atomic.Value(enum(u8) { none, downloading, ready, failed }) = .init(.none),
    update_thread: ?std.Thread = null,
} = .{};

fn fetchNews(io: Io, gpa: std.mem.Allocator) void {
    var arena: std.heap.ArenaAllocator = .init(gpa); // kept: news.releases point into it
    const a = arena.allocator();
    const url = std.mem.span(std.c.getenv("OTOGI_RELEASES_URL") orelse releases_url);
    var body: std.Io.Writer.Allocating = .init(a);
    const ok = if (httpGet(io, a, url, &body.writer)) |status| status == .ok else |_| false;
    if (!ok) {
        _ = std.fmt.bufPrint(&news.err, "no answer from api.github.com", .{}) catch {};
        return news.state.store(.failed, .release);
    }
    news.releases = std.json.parseFromSliceLeaky([]const Release, a, body.written(), .{ .ignore_unknown_fields = true }) catch {
        _ = std.fmt.bufPrint(&news.err, "unexpected reply", .{}) catch {};
        return news.state.store(.failed, .release);
    };
    for (news.releases) |r| {
        if (r.draft or r.prerelease or !logic.newer(r.tag_name, build_info.version)) continue;
        if (news.latest) |l| if (!logic.newer(r.tag_name, l.tag_name)) continue;
        for (r.assets) |x| if (std.mem.eql(u8, x.name, asset_name)) {
            news.latest = r;
        };
    }
    news.state.store(.ok, .release);
}

/// The new launcher to <exe>.new, then swapped in: the running exe can be
/// renamed (to .old, deleted at the next start), not overwritten.
var update_err: [160:0]u8 = @splat(0);

fn downloadUpdate(io: Io, gpa: std.mem.Allocator) void {
    const ok = swapIn(io, gpa) catch |e| blk: {
        _ = std.fmt.bufPrintSentinel(&update_err, "Update failed ({t}). Check your connection and try again.", .{e}, 0) catch {};
        break :blk false;
    };
    news.update.store(if (ok) .ready else .failed, .release);
}

fn swapIn(io: Io, gpa: std.mem.Allocator) !bool {
    const l = news.latest orelse return false;
    const url = for (l.assets) |x| (if (std.mem.eql(u8, x.name, asset_name)) break x.browser_download_url) else return false;
    var p: [1100]u8 = undefined;
    const exe = p[0..try std.process.executablePath(io, &p)];
    const new = try std.fmt.allocPrint(gpa, "{s}.new", .{exe});
    defer gpa.free(new);
    const old = try std.fmt.allocPrint(gpa, "{s}.old", .{exe});
    defer gpa.free(old);
    {
        const f = try Io.Dir.cwd().createFile(io, new, .{});
        defer f.close(io);
        var buf: [64 * 1024]u8 = undefined;
        var w = f.writer(io, &buf);
        if (try httpGet(io, gpa, url, &w.interface) != .ok) return false;
        try w.interface.flush();
    }
    defer Io.Dir.cwd().deleteFile(io, new) catch {}; // gone once swapped in
    {
        const f = try Io.Dir.cwd().openFile(io, new, .{});
        defer f.close(io);
        var head: [2]u8 = undefined;
        if (try f.readPositionalAll(io, &head, 0) != 2 or !std.mem.eql(u8, &head, "MZ")) return false; // not an exe
    }
    Io.Dir.cwd().deleteFile(io, old) catch {};
    try move(gpa, exe, old);
    move(gpa, new, exe) catch |e| {
        move(gpa, old, exe) catch {};
        return e;
    };
    return true;
}

extern "kernel32" fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) callconv(.winapi) i32;

/// A rename that works on the running exe: Zig's Dir.rename opens the file in a
/// way Windows refuses for a loaded image (FileBusy); MoveFileEx does not.
fn move(gpa: std.mem.Allocator, from: []const u8, to: []const u8) !void {
    const a = try std.unicode.utf8ToUtf16LeAllocZ(gpa, from);
    defer gpa.free(a);
    const b = try std.unicode.utf8ToUtf16LeAllocZ(gpa, to);
    defer gpa.free(b);
    if (MoveFileExW(a, b, 1) == 0) return error.RenameFailed; // MOVEFILE_REPLACE_EXISTING
}

fn deleteOldSelf(io: Io) void {
    var p: [1100]u8 = undefined;
    const n = std.process.executablePath(io, &p) catch return;
    var q: [1110]u8 = undefined;
    Io.Dir.cwd().deleteFile(io, std.fmt.bufPrint(&q, "{s}.old", .{p[0..n]}) catch return) catch {};
}

fn httpGet(io: Io, gpa: std.mem.Allocator, url: []const u8, w: *std.Io.Writer) !std.http.Status {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const res = try client.fetch(.{ .location = .{ .url = url }, .response_writer = w });
    return res.status;
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
        const at = step_at.load(.acquire);
        if (result == .failed) return;
        if (at == 3 or at == 4) fail("Could not download the build tools ({t}). Check your internet connection and try again.", .{e}) else fail("{s}: {t}", .{ steps[at], e });
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
    const iso = std.mem.sliceTo(&iso_buf, 0);
    const iso_size = if (Io.Dir.cwd().statFile(c.io, iso, .{})) |st| st.size else |_| 0;
    var m: [400]u8 = undefined;
    c.say("Otogi XUnchain launcher {s}", .{version});
    c.say("{s}", .{machine(&m)});
    if (iso.len == 0) c.say("disc image: none picked", .{}) else c.say("disc image {s} ({d} bytes)", .{ iso, iso_size });
    c.say("install folder {s} ({?d} GB free)", .{ c.out, freeGb() });
}

/// "Windows 10.0 build 26200; CPU ...; 31 GB RAM; GPU ...": for setup.log and bug reports.
fn machine(buf: []u8) []const u8 {
    var v: OsVersion = .{};
    _ = RtlGetVersion(&v);
    var cpu: [128]u8 = @splat(0);
    var cpu_len: u32 = cpu.len;
    _ = RegGetValueA(0x80000002, "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0", "ProcessorNameString", 0x2, null, &cpu, &cpu_len); // HKLM, RRF_RT_REG_SZ
    return std.fmt.bufPrint(buf, "Windows {d}.{d} build {d}; CPU {s}; {d} GB RAM; GPU {s}", .{ v.major, v.minor, v.build, std.mem.trim(u8, std.mem.sliceTo(&cpu, 0), " "), ram_gb, std.mem.span(win_gpu_name()) }) catch "";
}

const OsVersion = extern struct { size: u32 = @sizeOf(OsVersion), major: u32 = 0, minor: u32 = 0, build: u32 = 0, platform: u32 = 0, csd: [128]u16 = @splat(0) };
extern "ntdll" fn RtlGetVersion(v: *OsVersion) callconv(.winapi) i32;
extern "advapi32" fn RegGetValueA(key: usize, sub: [*:0]const u8, value: [*:0]const u8, flags: u32, kind: ?*u32, data: *anyopaque, len: *u32) callconv(.winapi) i32;

fn pipeline(c: *Ctx) !void {
    const io = c.io;
    const cwd = Io.Dir.cwd();

    // Once game\ is extracted the disc is not needed again (an update rebuilds
    // without it).
    try next(c, 0);
    const iso_path = std.mem.sliceTo(&iso_buf, 0);
    const extracted = if (cwd.access(io, c.path("{s}\\.stamps\\extract", .{c.work}), .{})) |_| true else |_| false;
    if (extracted) {
        c.say("game files already extracted; the disc is not needed", .{});
    } else {
        const hex = xbeSha1(io, c.gpa, iso_path) catch |e| {
            fail("{s}", .{"Cannot read an Xbox game from the disc image."});
            return e;
        };
        c.say("default.xbe SHA-1 {s}", .{&hex});
        if (!std.mem.eql(u8, &hex, xbe_sha1)) {
            fail("{s}", .{"This is not the Otogi (USA) disc this build supports (default.xbe does not match)."});
            return error.WrongDisc;
        }
    }

    try next(c, 1);
    if (!c.done("extract")) {
        const iso = try cwd.openFile(io, iso_path, .{});
        defer iso.close(io);
        const img = try xiso.Image.open(io, iso);
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
    // The source has no .git: build.zig takes the commit from here instead.
    try cwd.writeFile(c.io, .{ .sub_path = c.path("{s}\\commit.txt", .{c.work}), .data = commit });

    // Zig's cache (packages too) stays in the build folder; zig build has
    // no flag for it, the child inherits this.
    _ = SetEnvironmentVariableA("ZIG_GLOBAL_CACHE_DIR", (std.fmt.allocPrintSentinel(c.gpa, "{s}\\zig-cache", .{c.work}, 0) catch unreachable).ptr);

    try next(c, 3);
    const zig = c.path("{s}\\tools\\zig-x86_64-windows-0.17.0\\zig.exe", .{c.work});
    if (!c.done("zig")) {
        try unzipFile(c, try fetch(c, zig_dl), c.path("{s}\\tools", .{c.work}));
        // build.zig.zon's packages (ANGLE, Dear ImGui) now, not minutes later
        // in the compile: a network failure should cost seconds.
        var attempt: u32 = 1;
        while (true) : (attempt += 1) {
            if (c.run(c.work, &.{ zig, "build", "--fetch" })) break else |e| {
                if (e == error.Cancelled or attempt == tries) return e;
                c.say("retrying ({d} of {d})", .{ attempt + 1, tries });
            }
        }
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
        try c.run(c.work, &.{ zig, "build", jobs, "--prefix", c.out, "--prefix-exe-dir", "." });
        c.stamp("build");
    }

    try next(c, 7);
    try writeSettings(c);
    installSelf(c);
}

/// The launcher into the install folder, so it travels with the game and the
/// next update lands there.
fn installSelf(c: *Ctx) void {
    var p: [1100]u8 = undefined;
    const self = p[0 .. std.process.executablePath(c.io, &p) catch return];
    const dest = c.path("{s}\\" ++ asset_name, .{c.out});
    if (std.ascii.eqlIgnoreCase(self, dest)) return;
    Io.Dir.copyFileAbsolute(self, dest, c.io, .{}) catch |e| return c.say("could not copy the launcher to {s}: {t}", .{ dest, e });
    c.say("launcher copied to {s}", .{dest});
}

extern "kernel32" fn GetLocalTime(t: *[8]u16) callconv(.winapi) void;

/// <out>\settings.ini, beside otogi.exe: a header with the version and this
/// version's changelog notes, then the template (the repo's settings.ini, one
/// comment per setting). Values the player already set are kept, and settings
/// the template does not know are carried over at the end.
fn writeSettings(c: *Ctx) !void {
    const io = c.io;
    const cwd = Io.Dir.cwd();
    const dest = c.path("{s}\\settings.ini", .{c.out});
    const tmpl = try cwd.readFileAlloc(io, c.path("{s}\\settings.ini", .{c.work}), c.gpa, .limited(64 * 1024));
    const old_text = cwd.readFileAlloc(io, dest, c.gpa, .limited(64 * 1024)) catch "";
    var old: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, old_text, "\r\n");
    while (lines.next()) |line| if (logic.setting(line)) |kv| if (kv[1].len != 0) try old.put(c.gpa, kv[0], kv[1]);

    var out: std.Io.Writer.Allocating = .init(c.gpa);
    const w = &out.writer;
    var t: [8]u16 = undefined; // SYSTEMTIME: year, month, weekday, day, ...
    GetLocalTime(&t);
    try w.print("; Otogi XUnchain {s}: Otogi: Myth of Demons, PC recompilation\n", .{version});
    try w.print("; Written by otogi-xunchain on {d}-{d:0>2}-{d:0>2}. Rebuilding keeps your values.\n", .{ t[0], t[1], t[3] });
    // This version's section of CHANGELOG.md (in the unpacked source).
    const log = cwd.readFileAlloc(io, c.path("{s}\\CHANGELOG.md", .{c.work}), c.gpa, .limited(1 << 20)) catch "";
    const head = "## [" ++ build_info.version ++ "]";
    if (std.mem.indexOf(u8, log, head)) |at| {
        const body = log[at..];
        const end = std.mem.indexOfPos(u8, body, head.len, "\n## [") orelse body.len;
        // "## [0.6.0] - 2026-11-01" -> "What's in v0.6.0 (2026-11-01):"
        const heading = std.mem.trimEnd(u8, body[0 .. std.mem.indexOfScalar(u8, body, '\n') orelse body.len], "\r ");
        const date_ = if (std.mem.indexOf(u8, heading, "] - ")) |d| heading[d + 4 ..] else "";
        try w.print(";\n; What's in v{s}{s}{s}{s}:\n", .{ build_info.version, if (date_.len != 0) " (" else "", date_, if (date_.len != 0) ")" else "" });
        var it = std.mem.splitScalar(u8, body[0..end], '\n');
        _ = it.next(); // the heading
        while (it.next()) |raw| {
            const l = std.mem.trimEnd(u8, raw, "\r ");
            if (l.len != 0) try w.print(";   {s}\n", .{l});
        }
    }
    try w.writeAll(";\n");

    var known_keys: std.StringHashMapUnmanaged(void) = .empty;
    var tl = std.mem.splitScalar(u8, std.mem.trimEnd(u8, tmpl, "\r\n"), '\n');
    while (tl.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (logic.setting(line)) |kv| {
            try known_keys.put(c.gpa, kv[0], {});
            if (old.get(kv[0])) |v| {
                try w.print("{s} = {s}\n", .{ kv[0], v });
                continue;
            }
        }
        try w.print("{s}\n", .{line});
    }
    var first = true;
    for (old.keys(), old.values()) |k, v| {
        if (known_keys.contains(k)) continue;
        if (first) try w.writeAll("\n; Kept from your earlier settings.ini.\n");
        first = false;
        try w.print("{s} = {s}\n", .{ k, v });
    }
    try cwd.writeFile(io, .{ .sub_path = dest, .data = out.written() });
    c.say("wrote {s} ({d} of your values kept)", .{ dest, old.count() });
}

/// Download into <work>\downloads (kept between runs) and check its SHA-256.
fn fetch(c: *Ctx, d: Download) ![]const u8 {
    const io = c.io;
    const dir = c.path("{s}\\downloads", .{c.work});
    try Io.Dir.cwd().createDirPath(io, dir);
    const dest = c.path("{s}\\{s}", .{ dir, d.name });
    if (sha256File(c, dest)) |h| if (std.mem.eql(u8, &h, d.sha256)) return dest;
    c.say("downloading {s}", .{d.url});
    var attempt: u32 = 1;
    while (true) : (attempt += 1) {
        if (download(c, d.url, dest)) break else |e| {
            if (attempt == tries or cancel.load(.acquire)) return e;
            c.say("download failed: {t}; retrying ({d} of {d})", .{ e, attempt + 1, tries });
        }
    }
    const h = sha256File(c, dest) orelse return error.DownloadFailed;
    if (!std.mem.eql(u8, &h, d.sha256)) {
        c.say("{s}: SHA-256 {s}, expected {s}", .{ d.name, &h, d.sha256 });
        return error.HashMismatch;
    }
    return dest;
}

/// A download that fails is tried this many times in all.
const tries = 3;

fn download(c: *Ctx, url: []const u8, dest: []const u8) !void {
    const f = try Io.Dir.cwd().createFile(c.io, dest, .{});
    defer f.close(c.io);
    var buf: [64 * 1024]u8 = undefined;
    var w = f.writer(c.io, &buf);
    const status = try httpGet(c.io, c.gpa, url, &w.interface);
    try w.interface.flush();
    if (status != .ok) {
        c.say("HTTP {d}", .{@intFromEnum(status)});
        return error.DownloadFailed;
    }
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
    // std.zip will not overwrite, and a step stopped part-way leaves files
    // behind: delete the zip's own files first (nothing else in dest).
    {
        var it = try std.zip.Iterator.init(&r);
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (try it.next()) |e| {
            const name = try e.getFilename(&r, &name_buf, .{ .allow_backslashes = true });
            if (name.len != 0 and name[name.len - 1] != '/') d.deleteFile(c.io, name) catch {};
        }
    }
    try std.zip.extract(d, &r, .{ .allow_backslashes = true });
}

fn unzipBytes(c: *Ctx, bytes: []const u8, dest: []const u8) !void {
    const tmp = c.path("{s}\\source.zip", .{c.work});
    try Io.Dir.cwd().writeFile(c.io, .{ .sub_path = tmp, .data = bytes });
    try unzipFile(c, tmp, dest);
}
