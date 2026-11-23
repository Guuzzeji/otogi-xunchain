//! The launcher's own art (setup/assets/art) as premultiplied RGBA for RmlUi on
//! Linux, where there is no WIC: 8-bit RGB or RGBA PNGs, not interlaced (what
//! the art is). The system's SDL3 may be older than SDL_LoadPNG (3.4).
const std = @import("std");

pub const Image = struct { w: u32, h: u32, px: []u8 };

pub fn decode(gpa: std.mem.Allocator, png: []const u8) !Image {
    if (png.len < 8 or !std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) return error.NotPng;
    var w: u32 = 0;
    var h: u32 = 0;
    var bpp: usize = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var at: usize = 8;
    while (at + 12 <= png.len) {
        const len = std.mem.readInt(u32, png[at..][0..4], .big);
        if (at + 12 + len > png.len) return error.Truncated;
        const data = png[at + 8 ..][0..len];
        const kind = png[at + 4 ..][0..4];
        at += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
            bpp = switch (data[9]) { // color type
                2 => 3,
                6 => 4,
                else => return error.Unsupported,
            };
            if (data[8] != 8 or data[12] != 0) return error.Unsupported; // bit depth, interlace
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (bpp == 0) return error.NotPng;

    // Rows of 1 filter byte + w * bpp, zlib-compressed.
    const stride = w * bpp;
    const raw = try gpa.alloc(u8, (stride + 1) * h);
    defer gpa.free(raw);
    var in: std.Io.Reader = .fixed(idat.items);
    var win: [std.compress.flate.max_window_len]u8 = undefined;
    var z: std.compress.flate.Decompress = .init(&in, .zlib, &win);
    try z.reader.readSliceAll(raw);

    const px = try gpa.alloc(u8, w * h * 4);
    errdefer gpa.free(px);
    const line = try gpa.alloc(u8, stride * 2); // this row and the one above, unfiltered
    defer gpa.free(line);
    @memset(line, 0);
    for (0..h) |y| {
        const cur = line[(y & 1) * stride ..][0..stride];
        const up = line[(~y & 1) * stride ..][0..stride];
        const row = raw[y * (stride + 1) ..][0 .. stride + 1];
        for (cur, row[1..], 0..) |*c, f, i| {
            const a: u8 = if (i >= bpp) cur[i - bpp] else 0;
            const b = up[i];
            const ab: u8 = if (i >= bpp) up[i - bpp] else 0;
            c.* = f +% switch (row[0]) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => paeth(a, b, ab),
                else => return error.BadFilter,
            };
        }
        for (0..w) |x| {
            const s = cur[x * bpp ..];
            const alpha: u16 = if (bpp == 4) s[3] else 255;
            const d = px[(y * w + x) * 4 ..][0..4];
            for (0..3) |k| d[k] = @intCast((@as(u16, s[k]) * alpha + 127) / 255); // RmlUi wants premultiplied alpha
            d[3] = @intCast(alpha);
        }
    }
    return .{ .w = w, .h = h, .px = px };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    return if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
}

fn pixel(img: Image, x: u32, y: u32) [4]u8 {
    return img.px[(y * img.w + x) * 4 ..][0..4].*;
}

// Expected pixels as Windows (System.Drawing) decodes them, premultiplied.
test "the art decodes as Windows does" {
    const gpa = std.testing.allocator;
    const raikoh = try decode(gpa, @embedFile("assets/art/raikoh.png"));
    defer gpa.free(raikoh.px);
    try std.testing.expectEqual(@as(u32, 1024), raikoh.w);
    const title = try decode(gpa, @embedFile("assets/art/title.png"));
    defer gpa.free(title.px);
    try std.testing.expectEqual([4]u8{ 138, 83, 86, 255 }, pixel(title, 512, 256)); // RGB
    const brush = try decode(gpa, @embedFile("assets/art/brush.png"));
    defer gpa.free(brush.px);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, pixel(brush, 0, 0)); // RGBA
    try std.testing.expectEqual([4]u8{ 119, 0, 0, 119 }, pixel(brush, 128, 32));
}
