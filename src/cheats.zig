//! Debug menu cheats. Guest globals found by reading the lifted code (all
//! static: BSS or the XBE's .data). Player-object fields mean something only
//! during a stage; in menus they are stale.
const std = @import("std");
const ui = @import("ui.zig");
const logic = @import("logic");
const menu = @import("debug_menu.zig");
const d3d = @import("d3d.zig");
const gl_hle = @import("gl_hle.zig");

fn p32(va: u32) *align(1) u32 {
    return @ptrCast(d3d.ptr(va));
}
fn pf(va: u32) *align(1) f32 {
    return @ptrCast(d3d.ptr(va));
}

// Progress (sub_000CA890, sub_000BCBC0, main loop sub_00043310).
const STAGE = 0x13DAC08; // story stage id; the hub opens on it. Save "Map".
const ALL_STAGES = 0x13DAC04; // non-zero: stage select lists every stage
const STAGE_ORDER = 0x1B98A0; // i32[29]: 0..24, 185, 25, 26, 27
const STAGE_RECORDS = 0x1D2C88; // 29 x 0x3C; +0x18 flags, bit 0 = cleared
const EXIT_REQUEST = 0x1D80EC; // -1 none, 1 = back to the hub (sub_000111E0)
const EXIT_FADE = 0x1D80F0; // f32 timer, f32 length
// Status (sub_000B01F0 returns 0x13DA270).
const LEVEL = 0x13DA270;
const EXP = 0x13DA288; // written back from the player at stage end
const MONEY = 0x13DA28C; // capped at 99999 (sub_000B0390)
const MAX_LIFE = 0x13DA294;
// Player object 0x13C91D0 (sub_00081090 life, sub_00081100 magic).
const HP = 0x13D8BA8; // f32; HP_SHOWN lags toward it
const HP_SHOWN = 0x13D8BAC;
const HP_MAX = 0x13D8BB0; // i32
const MAGIC = 0x13D8BB4; // f32
const MAGIC_MAX = 0x13D8BB8; // i32
const STAGE_EXP = 0x13D8B88; // the player's copy of EXP during a stage
// Inventories (sub_000B0FE0): 16-byte entries, +8 owned (items: quantity).
const Table = struct { name: [:0]const u8, at: u32, count: u32, own: u32 };
const tables = [_]Table{
    .{ .name = "weapons", .at = 0x13DA4C8, .count = 0x13DAAD0, .own = 1 },
    .{ .name = "magic", .at = 0x13DA170, .count = 0x13DA8C8, .own = 1 },
    .{ .name = "accessories", .at = 0x13DA2C0, .count = 0x13DA4C0, .own = 1 },
    .{ .name = "items (x9)", .at = 0x13DA8D0, .count = 0x13DA8CC, .own = 9 }, // gifts stop adding at 15
};
const table_max = [_]u32{ 64, 16, 32, 32 };

// Stage render settings (stage render sub_000428A0, loader sub_00026570).
const FAR = 0x1E6830; // f32: the projection's far plane and the frustum test's far distance
const MAP_HEADER = 0x2F5790; // -> the loaded map's header; +0x14 f32 = its far distance

var god = false;
var inf_magic = false;
/// Draw and fog distance, times the stage's own (settings.ini draw_distance,
/// fog_distance). 1 leaves the game untouched.
var far_scale: f32 = 1;
pub var scales_read = false; // false reads the settings again (the settings page)

fn envScale(name: [*:0]const u8) f32 {
    const v = std.fmt.parseFloat(f32, std.mem.span(std.c.getenv(name) orelse return 1)) catch return 1;
    return if (v >= 0.1 and v <= 16) v else 1;
}
var warp_index: usize = 0;

extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn fread([*]u8, usize, usize, *anyopaque) usize;
extern "c" fn fclose(*anyopaque) c_int;
extern "c" fn remove([*:0]const u8) c_int;

/// logs\cheat, for scripted testing: read and deleted when it appears, one
/// command per line: warp <stage id>, stage <id> (the story stage only), god,
/// ungod, magic, kill, all, clear, give, status, far <x>, fog <x> (draw and fog
/// distance), cull (last frame's frustum tests), set <key> <value> (settings.ini
/// as the settings page sets it). Results go to the log.
fn liveCommands() void {
    const f = fopen("logs/cheat", "rb") orelse return;
    var buf: [512]u8 = undefined;
    const n = fread(&buf, 1, buf.len, f);
    _ = fclose(f);
    _ = remove("logs/cheat");
    var lines = std.mem.tokenizeAny(u8, buf[0..n], "\r\n");
    while (lines.next()) |line| {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const cmd = it.next() orelse continue;
        if (std.mem.eql(u8, cmd, "warp")) {
            const id = std.fmt.parseInt(u32, it.next() orelse "", 10) catch continue;
            warp_index = for (0..29) |i| {
                if (p32(STAGE_ORDER + @as(u32, @intCast(i)) * 4).* == id) break i;
            } else continue;
            warp();
        } else if (std.mem.eql(u8, cmd, "stage")) {
            p32(STAGE).* = std.fmt.parseInt(u32, it.next() orelse "", 10) catch continue;
        } else if (std.mem.eql(u8, cmd, "set")) {
            @import("settings_menu.zig").save(it.next() orelse continue, it.rest());
        } else if (std.mem.eql(u8, cmd, "far")) {
            far_scale = std.fmt.parseFloat(f32, it.next() orelse "") catch continue;
        } else if (std.mem.eql(u8, cmd, "fog")) {
            gl_hle.fog_scale = std.fmt.parseFloat(f32, it.next() orelse "") catch continue;
        } else if (std.mem.eql(u8, cmd, "cull")) {
            for (menu.cull_last) |s| if (s.tested != 0) std.debug.print("[CHEAT] frustum test from {X:0>6}: {d} tested, {d} visible\n", .{ s.from, s.tested, s.visible });
        } else if (std.mem.eql(u8, cmd, "god")) god = true
        else if (std.mem.eql(u8, cmd, "ungod")) god = false
        else if (std.mem.eql(u8, cmd, "magic")) inf_magic = true
        else if (std.mem.eql(u8, cmd, "kill")) {
            god = false;
            pf(HP).* = 0;
        } else if (std.mem.eql(u8, cmd, "all")) p32(ALL_STAGES).* = 1
        else if (std.mem.eql(u8, cmd, "clear")) {
            for (0..29) |i| p32(STAGE_RECORDS + @as(u32, @intCast(i)) * 0x3C + 0x18).* |= 1;
        } else if (std.mem.eql(u8, cmd, "give")) {
            for (tables, table_max) |t, max| for (0..@min(p32(t.count).*, max)) |i| {
                const e = p32(t.at + @as(u32, @intCast(i)) * 16 + 8);
                e.* = @max(e.*, t.own);
            };
        }
        std.debug.print("[CHEAT] {s}: stage m{d:0>3}, exit {d}, HP {d:.0}/{d}, god {}\n", .{ line, p32(STAGE).*, @as(i32, @bitCast(p32(EXIT_REQUEST).*)), pf(HP).*, p32(HP_MAX).*, god });
    }
}

/// Every shown frame, menu open or not.
pub fn tick() void {
    liveCommands();
    if (god and p32(HP_MAX).* > 0) {
        const max: f32 = @floatFromInt(p32(HP_MAX).*);
        pf(HP).* = max;
        pf(HP_SHOWN).* = max;
    }
    if (inf_magic and p32(MAGIC_MAX).* > 0) pf(MAGIC).* = @floatFromInt(p32(MAGIC_MAX).*);
    if (!scales_read) {
        scales_read = true;
        far_scale = envScale("RECOMP_DRAW_DISTANCE");
        gl_hle.fog_scale = envScale("RECOMP_FOG_DISTANCE");
    }
    // The loader sets FAR once per stage from the map header (500000 without
    // one); the stage render reads it every frame.
    const header = p32(MAP_HEADER).*;
    if ((far_scale != 1 or far_touched) and menu.valid(header, 0x18)) {
        const far = pf(header + 0x14).*;
        pf(FAR).* = far_scale * (if (far > 0) far else 500000);
        far_touched = far_scale != 1; // one more write puts the stage's own back
    }
}
var far_touched = false;

/// The Cheats tab's fixed parts (src/ui/debug.rml): a chip per stage, a row per inventory.
pub fn shape() void {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (0..29) |i| w.print("<div class=\"chip\" id=\"warp-{d}\" onclick=\"warp-pick\" value=\"{d}\">m{d:0>3}</div>", .{ i, i, p32(STAGE_ORDER + @as(u32, @intCast(i)) * 4).* }) catch return;
    ui.set("warp-list", "{s}", .{w.buffered()});
    w = .fixed(&buf);
    for (tables, 0..) |t, i| w.print("<div class=\"row\"><div class=\"btn\" onclick=\"give\" value=\"{d}\">Give all {s}</div><span id=\"inv-{d}\"></span></div>", .{ i, t.name, i }) catch return;
    ui.set("c-inv", "{s}", .{w.buffered()});
}

/// The Cheats tab, every frame it is shown.
pub fn tab() void {
    ui.set("c-stage", "story stage m{d:0>3}, exit request {d}", .{ p32(STAGE).*, @as(i32, @bitCast(p32(EXIT_REQUEST).*)) });
    ui.ui_class("all-stages", "on", p32(ALL_STAGES).* != 0);
    for (0..29) |i| {
        var id: [16]u8 = undefined;
        ui.ui_class(std.fmt.bufPrintSentinel(&id, "warp-{d}", .{i}, 0) catch continue, "on", i == warp_index);
    }
    ui.ui_class("god", "on", god);
    ui.ui_class("inf-magic", "on", inf_magic);
    ui.set("c-player", "HP {d:.0}/{d}, magic {d:.0}/{d}<br/>level {d}, exp {d} (in stage {d}), max life {d}", .{ pf(HP).*, p32(HP_MAX).*, pf(MAGIC).*, p32(MAGIC_MAX).*, p32(LEVEL).*, p32(EXP).*, p32(STAGE_EXP).*, p32(MAX_LIFE).* });
    ui.value("money", "{d}", .{@as(i32, @bitCast(p32(MONEY).*))});
    ui.set("far-val", "{d}x", .{far_scale});
    ui.set("fog-val", "{d}x", .{gl_hle.fog_scale});
    ui.set("c-far", "far plane {d:.0}", .{pf(FAR).*});
    for (tables, table_max, 0..) |t, max, i| {
        const n = @min(p32(t.count).*, max);
        var owned: u32 = 0;
        for (0..n) |j| owned += @intFromBool(p32(t.at + @as(u32, @intCast(j)) * 16 + 8).* != 0);
        var id: [16]u8 = undefined;
        ui.set(std.fmt.bufPrintSentinel(&id, "inv-{d}", .{i}, 0) catch continue, "{d}/{d} owned", .{ owned, n });
    }
}

/// A click in the Cheats tab (ui.take). False if it is not one.
pub fn command(cmd: []const u8, val: []const u8) bool {
    const eql = std.mem.eql;
    if (eql(u8, cmd, "all-stages")) {
        p32(ALL_STAGES).* = @intFromBool(p32(ALL_STAGES).* == 0);
    } else if (eql(u8, cmd, "clear-all")) {
        for (0..29) |i| p32(STAGE_RECORDS + @as(u32, @intCast(i)) * 0x3C + 0x18).* |= 1;
    } else if (eql(u8, cmd, "warp-pick")) {
        warp_index = @min(std.fmt.parseInt(usize, val, 10) catch warp_index, 28);
    } else if (eql(u8, cmd, "warp")) {
        warp();
    } else if (eql(u8, cmd, "god")) {
        god = !god;
    } else if (eql(u8, cmd, "magic")) {
        inf_magic = !inf_magic;
    } else if (eql(u8, cmd, "money")) {
        p32(MONEY).* = @bitCast(std.fmt.parseInt(i32, std.mem.trim(u8, val, " "), 10) catch return true);
    } else if (eql(u8, cmd, "money-max")) {
        p32(MONEY).* = 99999;
    } else if (eql(u8, cmd, "far") or eql(u8, cmd, "fog")) {
        const s = if (eql(u8, cmd, "far")) &far_scale else &gl_hle.fog_scale;
        var b: [16]u8 = undefined;
        s.* = logic.stepDistance(std.fmt.bufPrint(&b, "{d}", .{s.*}) catch "1", eql(u8, val, "+"));
    } else if (eql(u8, cmd, "give")) {
        const i = std.fmt.parseInt(usize, val, 10) catch return true;
        if (i >= tables.len) return true;
        const t = tables[i];
        for (0..@min(p32(t.count).*, table_max[i])) |j| {
            const e = p32(t.at + @as(u32, @intCast(j)) * 16 + 8);
            e.* = @max(e.*, t.own);
        }
    } else return false;
    return true;
}

/// Story stage = the pick, then ask the main loop to leave for the hub
/// (sub_000111E0 takes a request only while none is pending).
fn warp() void {
    p32(STAGE).* = p32(STAGE_ORDER + @as(u32, @intCast(warp_index)) * 4).*;
    if (p32(EXIT_REQUEST).* == 0xFFFFFFFF) {
        p32(EXIT_REQUEST).* = 1;
        pf(EXIT_FADE).* = 0;
        pf(EXIT_FADE + 4).* = 0;
    }
}
