//! XDVDFS reader: unpack an Xbox disc image. Port of xboxrecomp/tools/xiso/xdvdfs.py.
//! Usage: xiso <image.iso> <out_dir>
const std = @import("std");
const Io = std.Io;

const sector = 2048;
const magic = "MICROSOFT*XBOX*MEDIA";
// Bare, rebuilt, redump video-first, full xbox disc, redump full-disc.
const bases = [_]u64{ 0, 0xFD90, 0x30600, 0xFD90000, 0x18300000 };

pub const Entry = struct { name: []const u8, sector: u32, size: u32, is_dir: bool };

pub const Image = struct {
    file: Io.File,
    io: Io,
    base: u64,
    root_sector: u32,
    root_size: u32,

    pub fn open(io: Io, file: Io.File) !Image {
        var desc: [0x1C]u8 = undefined;
        for (bases) |base| {
            const n = file.readPositionalAll(io, &desc, base + 32 * sector) catch continue;
            if (n == desc.len and std.mem.eql(u8, desc[0..magic.len], magic)) return .{
                .file = file,
                .io = io,
                .base = base,
                .root_sector = std.mem.readInt(u32, desc[0x14..0x18], .little),
                .root_size = std.mem.readInt(u32, desc[0x18..0x1C], .little),
            };
        }
        return error.NotXdvdfs;
    }

    /// Entries are a binary tree but also contiguous per sector; a linear walk
    /// with per-sector resync cannot silently drop a subtree on a bad link.
    pub fn readDir(img: Image, gpa: std.mem.Allocator, dir_sector: u32, size: u32) ![]Entry {
        const data = try gpa.alloc(u8, size);
        if (try img.file.readPositionalAll(img.io, data, img.base + @as(u64, dir_sector) * sector) != size)
            return error.Truncated;
        var list: std.ArrayList(Entry) = .empty;
        var chunk_at: usize = 0;
        while (chunk_at < data.len) : (chunk_at += sector) {
            const chunk = data[chunk_at..@min(chunk_at + sector, data.len)];
            var off: usize = 0;
            while (off + 0x0E <= chunk.len) {
                const e = chunk[off..];
                const l = std.mem.readInt(u16, e[0..2], .little);
                const r = std.mem.readInt(u16, e[2..4], .little);
                const nlen = e[0x0D];
                if ((l == 0xFFFF and r == 0xFFFF) or nlen == 0 or 0x0E + nlen > e.len) break;
                try list.append(gpa, .{
                    .name = e[0x0E..][0..nlen],
                    .sector = std.mem.readInt(u32, e[4..8], .little),
                    .size = std.mem.readInt(u32, e[8..12], .little),
                    .is_dir = e[0x0C] & 0x10 != 0,
                });
                off += (0x0E + @as(usize, nlen) + 3) & ~@as(usize, 3);
            }
        }
        return list.items;
    }

    pub fn unpack(img: Image, gpa: std.mem.Allocator, out: Io.Dir, dir_sector: u32, size: u32) !usize {
        var n: usize = 0;
        var buf: [1 << 20]u8 = undefined;
        for (try img.readDir(gpa, dir_sector, size)) |e| {
            if (std.mem.indexOfAny(u8, e.name, "/\\:") != null or std.mem.eql(u8, e.name, "..")) return error.BadName;
            if (e.is_dir) {
                var sub = try out.createDirPathOpen(img.io, e.name, .{});
                defer sub.close(img.io);
                n += try img.unpack(gpa, sub, e.sector, e.size);
                continue;
            }
            const f = try out.createFile(img.io, e.name, .{});
            defer f.close(img.io);
            var done: u64 = 0;
            while (done < e.size) {
                const want = @min(buf.len, e.size - done);
                const got = try img.file.readPositionalAll(img.io, buf[0..want], img.base + @as(u64, e.sector) * sector + done);
                if (got != want) return error.Truncated;
                try f.writePositionalAll(img.io, buf[0..got], done);
                done += got;
            }
            n += 1;
        }
        return n;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: xiso <image.iso> <out_dir>\n", .{});
        std.process.exit(2);
    }
    const io = init.io;
    const cwd = Io.Dir.cwd();
    const file = try cwd.openFile(io, args[1], .{});
    defer file.close(io);
    const img = try Image.open(io, file);
    var out = try cwd.createDirPathOpen(io, args[2], .{});
    defer out.close(io);
    const n = try img.unpack(arena, out, img.root_sector, img.root_size);
    std.debug.print("partition 0x{X}: extracted {d} files to {s}\n", .{ img.base, n, args[2] });
}

test "real ISO lists default.xbe at sector 1714694" {
    const io = std.testing.io;
    const file = Io.Dir.cwd().openFile(io, "Otogi-usa-xbox-dump-10-31-2026.iso", .{}) catch return error.SkipZigTest;
    defer file.close(io);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const img = try Image.open(io, file);
    try std.testing.expectEqual(@as(u64, 0x18300000), img.base);
    for (try img.readDir(arena.allocator(), img.root_sector, img.root_size)) |e| {
        if (std.mem.eql(u8, e.name, "default.xbe")) {
            try std.testing.expectEqual(@as(u32, 1714694), e.sector);
            try std.testing.expectEqual(@as(u32, 1921024), e.size);
            return;
        }
    }
    return error.DefaultXbeMissing;
}
