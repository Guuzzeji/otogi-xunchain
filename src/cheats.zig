//! Debug menu cheats. Guest globals found by reading the lifted code (all
//! static: BSS or the XBE's .data). Player-object fields mean something only
//! during a stage; in menus they are stale.
const std = @import("std");
const im = @import("imgui");
const menu = @import("debug_menu.zig");
const d3d = @import("d3d.zig");

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

var god = false;
var inf_magic = false;
var warp_index: c_int = 0;

/// Every shown frame, menu open or not.
pub fn tick() void {
    if (god and p32(HP_MAX).* > 0) {
        const max: f32 = @floatFromInt(p32(HP_MAX).*);
        pf(HP).* = max;
        pf(HP_SHOWN).* = max;
    }
    if (inf_magic and p32(MAGIC_MAX).* > 0) pf(MAGIC).* = @floatFromInt(p32(MAGIC_MAX).*);
}

pub fn tab() void {
    im.ImGui_SeparatorText("Stages");
    menu.text("story stage m{d:0>3}, exit request {d}", .{ p32(STAGE).*, @as(i32, @bitCast(p32(EXIT_REQUEST).*)) });
    var all = p32(ALL_STAGES).* != 0;
    if (im.ImGui_Checkbox("All stages in stage select", &all)) p32(ALL_STAGES).* = @intFromBool(all);
    im.ImGui_SameLine();
    if (im.ImGui_Button("Mark all cleared")) for (0..29) |i| {
        p32(STAGE_RECORDS + @as(u32, @intCast(i)) * 0x3C + 0x18).* |= 1;
    };
    var names: [29 * 8]u8 = undefined;
    var w: usize = 0;
    for (0..29) |i| w += (std.fmt.bufPrint(names[w..], "m{d:0>3}\x00", .{p32(STAGE_ORDER + @as(u32, @intCast(i)) * 4).*}) catch break).len;
    names[w] = 0;
    im.ImGui_SetNextItemWidth(120);
    _ = im.ImGui_Combo("##stage", &warp_index, &names);
    im.ImGui_SameLine();
    if (im.ImGui_Button("Warp (back to the hub on it)")) warp();
    im.ImGui_TextWrapped("%s", "Warp sets the story stage and leaves the current stage; the hub then offers the chosen one. Moving the story stage back re-locks later stages unless all stages are on.");

    im.ImGui_SeparatorText("Player");
    _ = im.ImGui_Checkbox("God mode", &god);
    im.ImGui_SameLine();
    _ = im.ImGui_Checkbox("Infinite magic", &inf_magic);
    menu.text("HP {d:.0}/{d}, magic {d:.0}/{d}", .{ pf(HP).*, p32(HP_MAX).*, pf(MAGIC).*, p32(MAGIC_MAX).* });
    menu.text("level {d}, exp {d} (in stage {d}), max life {d}", .{ p32(LEVEL).*, p32(EXP).*, p32(STAGE_EXP).*, p32(MAX_LIFE).* });
    _ = im.ImGui_InputInt("money", @ptrCast(@alignCast(p32(MONEY))));
    im.ImGui_SameLine();
    if (im.ImGui_Button("Max")) p32(MONEY).* = 99999;

    im.ImGui_SeparatorText("Inventory");
    for (tables, table_max) |t, max| {
        const n = @min(p32(t.count).*, max);
        var owned: u32 = 0;
        for (0..n) |i| owned += @intFromBool(p32(t.at + @as(u32, @intCast(i)) * 16 + 8).* != 0);
        var label: [48:0]u8 = undefined;
        if (im.ImGui_Button(std.fmt.bufPrintSentinel(&label, "Give all {s}", .{t.name}, 0) catch "give")) {
            for (0..n) |i| {
                const e = p32(t.at + @as(u32, @intCast(i)) * 16 + 8);
                e.* = @max(e.*, t.own);
            }
        }
        im.ImGui_SameLine();
        menu.text("{d}/{d} owned", .{ owned, n });
    }
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
