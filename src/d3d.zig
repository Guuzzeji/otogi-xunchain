//! The guest side of the D3D8 HLE (src/gl_hle.zig): guest memory access,
//! XDK 5455 state addresses and enums, vertex declarations, texture formats
//! and the NV2A vertex program translator. Port of Sneak King's
//! d3d_hle_shared.h; the decoding is the toolkit's nv2a_vsh_interp.c.
const std = @import("std");

extern threadlocal var g_esp: u32;
extern threadlocal var g_eax: u32;
extern var g_xbox_mem_offset: isize;

// XbSymbolDatabase (analysis/xbsymbol/xbsymbol.txt).
pub const RENDER_STATE: u32 = 0x00104F30; // D3D_g_RenderState
pub const TEXTURE_STATE: u32 = 0x00104D30; // D3D_g_DeferredTextureState[4][32]
pub const DEVICE_PTR: u32 = 0x001051C8; // D3D_g_pDevice

pub fn ptr(va: u32) [*]u8 {
    return @ptrFromInt(@as(usize, @bitCast(g_xbox_mem_offset)) + va);
}
pub fn mem32(va: u32) u32 {
    return std.mem.readInt(u32, ptr(va)[0..4], .little);
}
pub fn memf(va: u32) f32 {
    return @bitCast(mem32(va));
}
/// Stack argument n of a stdcall entry point (before its body runs).
pub fn arg(n: u32) u32 {
    return mem32(g_esp + 4 + 4 * n);
}
/// Pop the return address and n stack args, as `ret 4*n` would.
pub fn stdcallRet(n: u32, eax: u32) void {
    g_eax = eax;
    g_esp += 4 + 4 * n;
}

/// A resource's Data. D3D stores the GPU (physical) address for anything in
/// contiguous memory, which is mapped at 0x80000000 + phys.
pub fn resData(res: u32) u32 {
    const d = mem32(res + 4);
    return if (d < 0x80000000) d | 0x80000000 else d;
}

/// The deferred texture state and the render state are one block of guest
/// memory (TEXTURE_STATE + 0x200 == RENDER_STATE). While a recorded pushbuffer
/// replays, reads come from its snapshot of the block instead.
pub const STATE_WORDS = 128 + 160;
pub var state_snap: ?*const [STATE_WORDS]u32 = null;
comptime {
    std.debug.assert(RENDER_STATE == TEXTURE_STATE + 0x200);
    for (std.enums.values(Rs)) |v| std.debug.assert(@intFromEnum(v) < STATE_WORDS - 128);
}

pub fn stateBlock(out: *[STATE_WORDS]u32) void {
    for (out, 0..) |*v, i| v.* = mem32(TEXTURE_STATE + 4 * @as(u32, @intCast(i)));
}
fn stateWord(n: u32) u32 {
    return if (state_snap) |s| s[n] else mem32(TEXTURE_STATE + 4 * n);
}
pub fn rs(i: Rs) u32 {
    return stateWord(128 + @intFromEnum(i));
}
pub fn tss(stage: u32, i: Tss) u32 {
    return stateWord(32 * stage + @intFromEnum(i));
}

/// D3DRENDERSTATETYPE: the index into D3D_g_RenderState. XDK 5455 matches
/// 5849 (block starts 92 and 136; ALPHAFUNC 58, BLENDOP 74 checked against
/// the title's inlined setters).
pub const Rs = enum(u32) {
    zfunc = 57,
    alphafunc,
    alphablendenable,
    alphatestenable,
    alpharef,
    srcblend,
    destblend,
    zwriteenable,
    ditherenable,
    shademode,
    colorwriteenable,
    stencilzfail,
    stencilpass,
    stencilfunc,
    stencilref,
    stencilmask,
    stencilwritemask,
    blendop,
    blendcolor,
    swathwidth,
    polygonoffsetzslopescale,
    polygonoffsetzoffset,
    pointoffsetenable,
    wireframeoffsetenable,
    solidoffsetenable,
    fogenable = 92,
    fogtablemode,
    fogstart,
    fogend,
    fogdensity,
    rangefogenable,
    wrap0,
    wrap1,
    wrap2,
    wrap3,
    lighting,
    specularenable,
    localviewer,
    colorvertex,
    backspecularmaterialsource,
    backdiffusematerialsource,
    backambientmaterialsource,
    backemissivematerialsource,
    specularmaterialsource,
    diffusematerialsource,
    ambientmaterialsource,
    emissivematerialsource,
    backambient,
    ambient,
    pointsize,
    pointsize_min,
    pointspriteenable,
    pointscaleenable,
    pointscale_a,
    pointscale_b,
    pointscale_c,
    pointsize_max,
    pstexturemodes = 136,
    vertexblend,
    fogcolor,
    fillmode,
    backfillmode,
    twosidedlighting,
    normalizenormals,
    zenable,
    stencilenable,
    stencilfail,
    frontface,
    cullmode,
    texturefactor,
    zbias,
};

/// D3DTEXTURESTAGESTATETYPE: the index into a stage's 32 dwords.
pub const Tss = enum(u32) {
    addressu,
    addressv,
    addressw,
    magfilter,
    minfilter,
    mipfilter,
    mipmaplodbias,
    maxmiplevel,
    maxanisotropy,
    colorkeyop,
    colorsign,
    alphakill,
    colorop,
    colorarg0,
    colorarg1,
    colorarg2,
    alphaop,
    alphaarg0,
    alphaarg1,
    alphaarg2,
    resultarg,
    texturetransformflags,
    bumpenvmat00,
    bumpenvmat01,
    bumpenvmat11,
    bumpenvmat10,
    bumpenvlscale,
    bumpenvloffset,
    texcoordindex,
    bordercolor,
};

/// Width, height and pitch (0 for swizzled/compressed) of a surface/texture.
pub fn surfDims(res: u32) struct { w: u32, h: u32, pitch: u32 } {
    const f = mem32(res + 0xC);
    const sz = mem32(res + 0x10);
    if (sz != 0) return .{ .w = (sz & 0xFFF) + 1, .h = ((sz >> 12) & 0xFFF) + 1, .pitch = (((sz >> 24) & 0xFF) + 1) * 64 };
    return .{ .w = @as(u32, 1) << @intCast((f >> 20) & 0xF), .h = @as(u32, 1) << @intCast((f >> 24) & 0xF), .pitch = 0 };
}

// ── Texture formats ─────────────────────────────────────────────────────────

pub const Kind = enum { l8, al8, a1rgb5, x1rgb5, argb4, rgb565, argb8, xrgb8, p8, dxt1, dxt3, dxt5, a8, a8l8, abgr8, g8b8, yuy2, uyvy };
pub const Fmt = struct { bits: u8, swizzled: bool, kind: Kind };

pub fn fmtFind(xf: u32) ?Fmt {
    return switch (xf) {
        0x00 => .{ .bits = 8, .swizzled = true, .kind = .l8 },
        0x01 => .{ .bits = 8, .swizzled = true, .kind = .al8 },
        0x02 => .{ .bits = 16, .swizzled = true, .kind = .a1rgb5 },
        0x03 => .{ .bits = 16, .swizzled = true, .kind = .x1rgb5 },
        0x04 => .{ .bits = 16, .swizzled = true, .kind = .argb4 },
        0x05 => .{ .bits = 16, .swizzled = true, .kind = .rgb565 },
        0x06 => .{ .bits = 32, .swizzled = true, .kind = .argb8 },
        0x07 => .{ .bits = 32, .swizzled = true, .kind = .xrgb8 },
        0x0B => .{ .bits = 8, .swizzled = true, .kind = .p8 },
        0x0C => .{ .bits = 4, .swizzled = false, .kind = .dxt1 },
        0x0E => .{ .bits = 8, .swizzled = false, .kind = .dxt3 },
        0x0F => .{ .bits = 8, .swizzled = false, .kind = .dxt5 },
        0x10 => .{ .bits = 16, .swizzled = false, .kind = .a1rgb5 },
        0x11 => .{ .bits = 16, .swizzled = false, .kind = .rgb565 },
        0x12 => .{ .bits = 32, .swizzled = false, .kind = .argb8 },
        0x13 => .{ .bits = 8, .swizzled = false, .kind = .l8 },
        0x19 => .{ .bits = 8, .swizzled = true, .kind = .a8 },
        0x1A => .{ .bits = 16, .swizzled = true, .kind = .a8l8 },
        0x1B => .{ .bits = 8, .swizzled = false, .kind = .al8 },
        0x1C => .{ .bits = 16, .swizzled = false, .kind = .x1rgb5 },
        0x1D => .{ .bits = 16, .swizzled = false, .kind = .argb4 },
        0x1E => .{ .bits = 32, .swizzled = false, .kind = .xrgb8 },
        0x1F => .{ .bits = 8, .swizzled = false, .kind = .a8 },
        0x20 => .{ .bits = 16, .swizzled = false, .kind = .a8l8 },
        0x24 => .{ .bits = 16, .swizzled = false, .kind = .yuy2 },
        0x25 => .{ .bits = 16, .swizzled = false, .kind = .uyvy },
        0x28 => .{ .bits = 16, .swizzled = true, .kind = .g8b8 },
        0x3A => .{ .bits = 32, .swizzled = true, .kind = .abgr8 },
        0x3F => .{ .bits = 32, .swizzled = false, .kind = .abgr8 },
        else => null,
    };
}

pub fn isDxt(f: Fmt) bool {
    return f.kind == .dxt1 or f.kind == .dxt3 or f.kind == .dxt5;
}

pub fn levelBytes(f: Fmt, w: u32, h: u32) u32 {
    if (isDxt(f)) return ((w + 3) / 4) * ((h + 3) / 4) * (@as(u32, f.bits) * 2);
    return w * h * f.bits / 8;
}

fn c5(v: u32) u8 {
    return @intCast((v << 3 | v >> 2) & 0xFF);
}
fn c4(v: u32) u8 {
    return @intCast((v << 4 | v) & 0xFF);
}

/// One texel of a guest format as RGBA bytes.
pub fn texelRgba(f: Fmt, s: [*]const u8, pal: ?[*]align(1) const u32, o: *[4]u8) void {
    const p16: u32 = if (f.bits == 16) std.mem.readInt(u16, s[0..2], .little) else 0;
    o.* = switch (f.kind) {
        .l8 => .{ s[0], s[0], s[0], 255 },
        .al8 => .{ s[0], s[0], s[0], s[0] },
        .a8 => .{ 255, 255, 255, s[0] }, // NV2A reads RGB as 1 (as xemu); PC D3D would give 0
        .a8l8 => .{ s[0], s[0], s[0], s[1] },
        .a1rgb5, .x1rgb5 => .{ c5((p16 >> 10) & 31), c5((p16 >> 5) & 31), c5(p16 & 31), if (f.kind == .x1rgb5 or p16 & 0x8000 != 0) 255 else 0 },
        .argb4 => .{ c4((p16 >> 8) & 15), c4((p16 >> 4) & 15), c4(p16 & 15), c4(p16 >> 12) },
        .rgb565 => .{ c5((p16 >> 11) & 31), @intCast(((p16 >> 5) & 63) << 2 | ((p16 >> 5) & 63) >> 4), c5(p16 & 31), 255 },
        .argb8 => .{ s[2], s[1], s[0], s[3] },
        .xrgb8 => .{ s[2], s[1], s[0], 255 },
        .abgr8 => .{ s[0], s[1], s[2], s[3] },
        .g8b8 => .{ 0, s[0], s[1], 255 }, // as xemu: R 0, G byte 0, B byte 1
        .p8 => blk: {
            const c = if (pal) |pp| pp[s[0]] else 0xFFFFFFFF;
            break :blk .{ @truncate(c >> 16), @truncate(c >> 8), @truncate(c), @truncate(c >> 24) };
        },
        else => .{ 255, 255, 255, 255 },
    };
}

/// Texel x of a YUY2 (Y0 U Y1 V) or UYVY (U Y0 V Y1) row as RGBA: BT.601
/// limited range, as xemu converts them.
pub fn yuvRgba(kind: Kind, row: [*]const u8, x: usize, o: *[4]u8) void {
    const p = row + (x & ~@as(usize, 1)) * 2;
    const odd = x & 1;
    const uy = kind == .uyvy;
    const c: i32 = @as(i32, if (uy) p[1 + 2 * odd] else p[2 * odd]) - 16;
    const d: i32 = @as(i32, if (uy) p[0] else p[1]) - 128;
    const e: i32 = @as(i32, if (uy) p[2] else p[3]) - 128;
    const cl = struct {
        fn f(v: i32) u8 {
            return @intCast(std.math.clamp((v + 128) >> 8, 0, 255));
        }
    }.f;
    o.* = .{ cl(298 * c + 409 * e), cl(298 * c - 100 * d - 208 * e), cl(298 * c + 516 * d), 255 };
}

test yuvRgba {
    var o: [4]u8 = undefined;
    yuvRgba(.yuy2, &[_]u8{ 235, 128, 16, 128 }, 0, &o); // white
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, o);
    yuvRgba(.uyvy, &[_]u8{ 128, 235, 128, 16 }, 1, &o); // black
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, o);
}

/// Which address bits belong to x and to y in a swizzled w x h surface.
pub fn swizzleMasks(w: u32, h: u32) [2]u32 {
    var mx: u32 = 0;
    var my: u32 = 0;
    var bit: u32 = 1;
    var mb: u32 = 1;
    while (bit < w or bit < h) : (bit <<= 1) {
        if (bit < w) {
            mx |= mb;
            mb <<= 1;
        }
        if (bit < h) {
            my |= mb;
            mb <<= 1;
        }
    }
    return .{ mx, my };
}

/// The swizzled texel index of (x, y): x and y deposited into their masks.
pub fn swizzleIndex(x: u32, y: u32, masks: [2]u32) u32 {
    var r: u32 = 0;
    inline for (.{ x, y }, masks) |v, m0| {
        var m = m0;
        var bit: u32 = 1;
        while (m != 0) : (bit <<= 1) {
            const low = m & (~m +% 1);
            if (v & bit != 0) r |= low;
            m &= m - 1;
        }
    }
    return r;
}

/// Swizzled (Morton order) to linear rows. Port of the toolkit's
/// xbox_unswizzle_rect (d3d8_swizzle.h), which is static inline in C.
pub fn unswizzle(dst: []u8, src: [*]const u8, w: u32, h: u32, bpp: u32) void {
    const mx, const my = swizzleMasks(w, h);
    var oy: u32 = 0;
    for (0..h) |y| {
        var ox: u32 = 0;
        for (0..w) |x| {
            const s = (oy + ox) * bpp;
            @memcpy(dst[(y * w + x) * bpp ..][0..bpp], src[s..][0..bpp]);
            ox = (ox -% mx) & mx;
        }
        oy = (oy -% my) & my;
    }
}

/// FNV over the first 256 bytes, every 61st dword and the last 256.
/// ponytail: a title rewriting a few texels between samples keeps the old
/// upload; hashing every bound texture in full each frame costs more than the frame.
pub fn hashBytes(p: [*]const u8, n: u32) u32 {
    var h: u32 = 2166136261;
    var i: u32 = 0;
    while (i + 4 <= n and i < 256) : (i += 4) h = (h ^ std.mem.readInt(u32, p[i..][0..4], .little)) *% 16777619;
    while (i + 4 <= n) : (i += 61 * 4) h = (h ^ std.mem.readInt(u32, p[i..][0..4], .little)) *% 16777619;
    i = if (n > 256) n - 256 else 0;
    while (i + 4 <= n) : (i += 4) h = (h ^ std.mem.readInt(u32, p[i..][0..4], .little)) *% 16777619;
    return h ^ n;
}

// ── Vertex declarations ─────────────────────────────────────────────────────

pub const VsInput = struct { reg: u32, stream: u32, offset: u32, type: u32 };

fn vsdtSize(t: u32) u32 {
    return switch (t) {
        0x12, 0x40, 0x25, 0x21, 0x16, 0x44 => 4,
        0x22, 0x45, 0x41 => 8,
        0x32, 0x72 => 12,
        0x42 => 16,
        0x15, 0x11, 0x24 => 2,
        0x35, 0x31 => 6,
        0x14 => 1,
        0x34 => 3,
        else => 0,
    };
}

/// The registers a vertex declaration feeds and where each comes from.
pub fn vsInputs(decl: []const u32, in: *[16]VsInput) usize {
    var n: usize = 0;
    var stream: u32 = 0;
    var off: [16]u32 = @splat(0);
    var i: usize = 0;
    while (i < decl.len and decl[i] != 0xFFFFFFFF) : (i += 1) {
        const tok = decl[i];
        switch (tok >> 29) {
            1 => stream = tok & 0xF,
            2 => if (tok & 0x10000000 == 0) {
                const t = (tok >> 16) & 0xFF;
                if (n < 16 and t != 0x02) {
                    in[n] = .{ .reg = tok & 0x1F, .stream = stream, .offset = off[stream], .type = t };
                    n += 1;
                }
                off[stream] += vsdtSize(t);
            } else {
                off[stream] += if (tok & 0x08000000 != 0) (tok >> 16) & 0xFF else ((tok >> 16) & 0xF) * 4;
            },
            4 => i += ((tok >> 25) & 0xF) * 4, // CONSTMEM: data follows
            else => {},
        }
    }
    return n;
}

pub fn vsdtRead(t: u32, p: [*]const u8, o: *[4]f32) void {
    o.* = .{ 0, 0, 0, 1 };
    const n = t >> 4;
    switch (t) {
        0x12, 0x22, 0x32, 0x42 => for (0..n) |k| {
            o[k] = @bitCast(std.mem.readInt(u32, p[4 * k ..][0..4], .little));
        },
        0x72 => { // FLOAT2H: x, y, w
            o[0] = @bitCast(std.mem.readInt(u32, p[0..4], .little));
            o[1] = @bitCast(std.mem.readInt(u32, p[4..8], .little));
            o[3] = @bitCast(std.mem.readInt(u32, p[8..12], .little));
        },
        0x40 => { // D3DCOLOR: ARGB -> RGBA
            o.* = .{ @as(f32, @floatFromInt(p[2])) / 255, @as(f32, @floatFromInt(p[1])) / 255, @as(f32, @floatFromInt(p[0])) / 255, @as(f32, @floatFromInt(p[3])) / 255 };
        },
        0x15, 0x25, 0x35, 0x45 => for (0..n) |k| {
            o[k] = @floatFromInt(std.mem.readInt(i16, p[2 * k ..][0..2], .little));
        },
        0x11, 0x21, 0x31, 0x41 => for (0..n) |k| {
            o[k] = @as(f32, @floatFromInt(std.mem.readInt(i16, p[2 * k ..][0..2], .little))) / 32767;
        },
        0x14, 0x24, 0x34, 0x44 => for (0..n) |k| {
            o[k] = @as(f32, @floatFromInt(p[k])) / 255;
        },
        0x16 => { // NORMPACKED3: 11:11:10 signed
            const v = std.mem.readInt(u32, p[0..4], .little);
            o[0] = @as(f32, @floatFromInt(@as(i32, @bitCast(v << 21)) >> 21)) / 1023;
            o[1] = @as(f32, @floatFromInt(@as(i32, @bitCast(v << 10)) >> 21)) / 1023;
            o[2] = @as(f32, @floatFromInt(@as(i32, @bitCast(v)) >> 22)) / 511;
        },
        else => {},
    }
}

// ── NV2A vertex microcode to GLSL ES 3.00 ───────────────────────────────────

fn vfield(ins: []const u32, dw: usize, lo: u5, width: u5) u32 {
    return (ins[dw] >> lo) & ((@as(u32, 1) << width) - 1);
}

fn emitSrc(w: *std.Io.Writer, ins: []const u32, which: u2, inputs: *u16, uses_vp: *bool) !void {
    const sw = "xyzw";
    const ci = vfield(ins, 1, 13, 8);
    const rel = vfield(ins, 3, 1, 1);
    var neg: u32 = undefined;
    var swz: u32 = undefined;
    var mux: u32 = undefined;
    var reg: u32 = undefined;
    switch (which) {
        0 => {
            neg = vfield(ins, 1, 8, 1);
            swz = vfield(ins, 1, 0, 8);
            mux = vfield(ins, 2, 26, 2);
            reg = vfield(ins, 2, 28, 4);
        },
        1 => {
            neg = vfield(ins, 2, 25, 1);
            swz = vfield(ins, 2, 17, 8);
            mux = vfield(ins, 2, 11, 2);
            reg = vfield(ins, 2, 13, 4);
        },
        else => {
            neg = vfield(ins, 2, 10, 1);
            swz = vfield(ins, 2, 2, 8);
            mux = vfield(ins, 3, 28, 2);
            reg = (vfield(ins, 2, 0, 2) << 2) | vfield(ins, 3, 30, 2);
        },
    }
    if (neg != 0) try w.writeAll("-");
    if (mux == 1) {
        try w.print("R{d}", .{if (reg <= 12) reg else 0});
    } else if (mux == 2) {
        const in = vfield(ins, 1, 9, 4);
        inputs.* |= @as(u16, 1) << @intCast(in);
        try w.print("v{d}", .{in});
    } else if (rel != 0) {
        try w.print("c[a0 + {d}]", .{ci});
    } else {
        if (ci == 58 or ci == 59) uses_vp.* = true;
        try w.print("c[{d}]", .{ci});
    }
    try w.print(".{c}{c}{c}{c}", .{ sw[(swz >> 6) & 3], sw[(swz >> 4) & 3], sw[(swz >> 2) & 3], sw[swz & 3] });
}

fn emitMask(w: *std.Io.Writer, m: u32) !void {
    try w.writeAll(".");
    if (m & 8 != 0) try w.writeAll("x");
    if (m & 4 != 0) try w.writeAll("y");
    if (m & 2 != 0) try w.writeAll("z");
    if (m & 1 != 0) try w.writeAll("w");
}

/// The instructions of a vertex program as GLSL statements over R0-R12, a0
/// and the o* outputs, which the caller declares. Sets inputs to the v
/// registers read and uses_vp when the program applies D3D's viewport (c[58], c[59]).
pub fn vshBody(mc: []const u32, w: *std.Io.Writer, inputs: *u16, uses_vp: *bool) !void {
    const mac_glsl = [14]?[]const u8{ null, "A", "A * B", "A + C", "A * B + C", "vec4(dot(A.xyz, B.xyz))", "vec4(dot(A.xyz, B.xyz) + B.w)", "vec4(dot(A, B))", "vec4(1.0, A.y * B.y, A.z, B.w)", "min(A, B)", "max(A, B)", "vec4(lessThan(A, B))", "vec4(greaterThanEqual(A, B))", null };
    const ilu_glsl = [8]?[]const u8{ null, "C", "vec4(1.0 / C.x)", "vec4(rcc(C.x))", "vec4(inversesqrt(abs(C.x)))", "vec4(exp2(floor(C.x)), C.x - floor(C.x), exp2(C.x), 1.0)", "nv_log(C.x)", "nv_lit(C)" };
    const oname = [13]?[]const u8{ "R12", null, null, "oD0", "oD1", "oFog", null, null, null, "oT0", "oT1", "oT2", "oT3" };
    inputs.* = 0;
    uses_vp.* = false;
    var i: usize = 0;
    while (i + 4 <= mc.len) : (i += 4) {
        const ins = mc[i..][0..4];
        const mac = vfield(ins, 1, 21, 4);
        const ilu = vfield(ins, 1, 25, 3);
        const mac_mask = vfield(ins, 3, 24, 4);
        const ilu_mask = vfield(ins, 3, 16, 4);
        const tdst = vfield(ins, 3, 20, 4);
        const omask = vfield(ins, 3, 12, 4);
        const oaddr = vfield(ins, 3, 3, 8);
        const out_ilu = vfield(ins, 3, 2, 1);
        const out_reg = vfield(ins, 3, 11, 1);

        try w.writeAll("  { vec4 A = ");
        try emitSrc(w, ins, 0, inputs, uses_vp);
        try w.writeAll("; vec4 B = ");
        try emitSrc(w, ins, 1, inputs, uses_vp);
        try w.writeAll("; vec4 C = ");
        try emitSrc(w, ins, 2, inputs, uses_vp);
        try w.print(";\n    vec4 M = {s}; vec4 I = {s};\n", .{
            if (mac != 0 and mac < 13) mac_glsl[mac] orelse "vec4(0.0)" else "vec4(0.0)",
            if (ilu != 0) ilu_glsl[ilu] orelse "vec4(0.0)" else "vec4(0.0)",
        });
        if (mac == 13) try w.writeAll("    a0 = int(floor(A.x + 0.001));\n");
        if (mac != 0 and mac != 13 and mac_mask != 0 and tdst <= 12) {
            try w.print("    R{d}", .{tdst});
            try emitMask(w, mac_mask);
            try w.writeAll(" = M");
            try emitMask(w, mac_mask);
            try w.writeAll(";\n");
        }
        if (ilu != 0 and ilu_mask != 0) {
            const it: u32 = if (mac != 0) 1 else tdst; // beside a MAC op the ILU can only write R1
            if (it <= 12) {
                try w.print("    R{d}", .{it});
                try emitMask(w, ilu_mask);
                try w.writeAll(" = I");
                try emitMask(w, ilu_mask);
                try w.writeAll(";\n");
            }
        }
        if (omask != 0 and out_reg != 0 and oaddr < 13) if (oname[oaddr]) |on| {
            try w.print("    {s}", .{on});
            try emitMask(w, omask);
            try w.print(" = {s}", .{if (out_ilu != 0) "I" else "M"});
            try emitMask(w, omask);
            try w.writeAll(";\n");
        };
        try w.writeAll("  }\n");
        if (vfield(ins, 3, 0, 1) != 0) break;
    }
}
