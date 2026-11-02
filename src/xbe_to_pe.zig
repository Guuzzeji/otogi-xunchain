//! Wrap the XBE's flat image in a minimal PE32, so PE-only tools (REA's
//! Ghidra provider) load it at the XBE's own addresses. Port of Sneak King's
//! tools/xbe_to_pe.py. The output is game-derived: keep it in analysis/.
//!   zig build pe -- game/default.xbe analysis/rea/default_flat.exe
const std = @import("std");

const XOR_ENTRY_RETAIL: u32 = 0xA8FC57AB;
const ALIGN: u32 = 0x1000;

fn rd(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 3) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const xbe = try cwd.readFileAlloc(init.io, args[1], gpa, .unlimited);

    const base = rd(xbe, 0x104);
    const entry = rd(xbe, 0x128) ^ XOR_ENTRY_RETAIL;
    const nsect = rd(xbe, 0x11C);
    const sects = rd(xbe, 0x120) - base;
    var end: u32 = 0;
    for (0..nsect) |i| {
        const s = sects + 56 * i;
        end = @max(end, rd(xbe, s + 4) + rd(xbe, s + 8));
    }
    const img = try gpa.alloc(u8, (end - base + ALIGN - 1) / ALIGN * ALIGN);
    @memset(img, 0);
    for (0..nsect) |i| {
        const s = sects + 56 * i;
        const va = rd(xbe, s + 4) - base;
        const raw = rd(xbe, s + 12);
        const size = rd(xbe, s + 16);
        @memcpy(img[va..][0..size], xbe[raw..][0..size]);
    }
    const body = img[ALIGN..];
    const n: u32 = @intCast(body.len);

    var hdr: [ALIGN]u8 = @splat(0);
    var w: std.Io.Writer = .fixed(&hdr);
    try w.writeAll("MZ");
    w.end = 0x3C;
    try w.writeInt(u32, 0x40, .little);
    try w.writeAll("PE\x00\x00");
    // COFF: i386, 1 section, optional header 0xE0, EXECUTABLE|32BIT
    inline for (.{ u16, u16, u32, u32, u32, u16, u16 }, .{ 0x14C, 1, 0, 0, 0, 0xE0, 0x0102 }) |T, v| try w.writeInt(T, v, .little);
    // PE32 optional header, then 16 empty data directories
    inline for (
        .{ u16, u8, u8, u32, u32, u32, u32, u32, u32, u32, u32, u32, u16, u16, u16, u16, u16, u16, u32, u32, u32, u32, u16, u16, u32, u32, u32, u32, u32, u32 },
        .{ 0x10B, 0, 0, n, 0, 0, entry - base, ALIGN, ALIGN, base, ALIGN, ALIGN, 4, 0, 0, 0, 4, 0, 0, @as(u32, @intCast(img.len)), ALIGN, 0, 2, 0, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16 },
    ) |T, v| try w.writeInt(T, v, .little);
    w.end += 128;
    // One RWX section spanning VA base+0x1000 .. end
    try w.writeAll(".xbe\x00\x00\x00\x00");
    inline for (.{ n, ALIGN, n, ALIGN, 0, 0 }) |v| try w.writeInt(u32, v, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u32, 0xE0000060, .little);

    const out = try cwd.createFile(init.io, args[2], .{});
    defer out.close(init.io);
    try out.writePositionalAll(init.io, &hdr, 0);
    try out.writePositionalAll(init.io, body, ALIGN);
    std.debug.print("{s}: base 0x{X}, entry 0x{X}, 0x{X} bytes\n", .{ args[2], base, entry, img.len });
}
