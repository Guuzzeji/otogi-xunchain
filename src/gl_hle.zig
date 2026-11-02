//! The game's Xbox D3D8 (XDK 5455) mapped onto GL ES 3 through ANGLE, which
//! runs it on D3D11 (default), Vulkan or desktop GL (RECOMP_GFX). Port of
//! Sneak King's gl_hle.c; the guest side is src/d3d.zig.
//!
//! D3D entry points are wrapped (seeds/manual.h). Setters run the lifted body
//! and mirror what the renderer needs; draws, Clear and the present are done
//! here. The lifted D3D still writes a pushbuffer, which nothing executes.
//! The title also writes its own quads into the pushbuffer between
//! BeginPush/EndPush; EndPush decodes those.
//!
//! GL ES has no fixed function, so GLSL is generated per state combination:
//! the vertex half from the FVF (or the title's own vertex program,
//! translated from NV2A microcode), the fragment half from the texture
//! stages, fog and alpha test. Programs are cached on that key.
//!
//! Orientation: the render target keeps the guest's row order, row 0 at the
//! top. GL's window space is the guest's screen space: clip y is negated after
//! projection, a D3D clockwise triangle is GL counter-clockwise, and only the
//! blit to the window flips.
const std = @import("std");
const gl = @import("gl");
const d3d = @import("d3d.zig");
const debug_menu = @import("debug_menu.zig");

const arg = d3d.arg;
const mem32 = d3d.mem32;

extern threadlocal var g_ecx: u32;
extern threadlocal var g_edx: u32;
extern threadlocal var g_eax: u32;

// ── Window ──────────────────────────────────────────────────────────────────
// Our own Win32 window on the guest thread, pumped at each Swap. Its keys and
// mouse drive only the debug menu (F1); the game reads the controller.

const HWND = *opaque {};
const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: *const fn (HWND, u32, usize, isize) callconv(.winapi) isize,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?*anyopaque = null,
    hIcon: ?*anyopaque = null,
    hCursor: ?*anyopaque = null,
    hbrBackground: ?*anyopaque = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: ?*anyopaque = null,
};
const MSG = extern struct { hwnd: ?HWND, message: u32, wParam: usize, lParam: isize, time: u32, pt: [2]i32, private: u32 };
const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };
extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(u32, [*:0]const u16, [*:0]const u16, u32, i32, i32, i32, i32, ?HWND, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, u32, usize, isize) callconv(.winapi) isize;
extern "user32" fn PeekMessageW(*MSG, ?HWND, u32, u32, u32) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) isize;
extern "user32" fn AdjustWindowRect(*RECT, u32, i32) callconv(.winapi) i32;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) i32;
extern "kernel32" fn ExitProcess(u32) callconv(.winapi) noreturn;

const WS_OVERLAPPEDWINDOW: u32 = 0x00CF0000;
const WS_VISIBLE: u32 = 0x10000000;
const WM_CLOSE: u32 = 0x0010;

fn wndProc(wnd: HWND, msg: u32, wp: usize, lp: isize) callconv(.winapi) isize {
    if (msg == WM_CLOSE) ExitProcess(0); // closing the window ends the game
    if (debug_menu.wndProc(wnd, msg, wp, lp)) return 1;
    return DefWindowProcW(wnd, msg, wp, lp);
}

fn pumpMessages() void {
    var m: MSG = undefined;
    while (PeekMessageW(&m, null, 0, 0, 1) != 0) { // PM_REMOVE
        _ = TranslateMessage(&m);
        _ = DispatchMessageW(&m);
    }
}

fn clientSize() [2]i32 {
    var r: RECT = .{};
    _ = GetClientRect(hwnd.?, &r);
    return .{ r.right, r.bottom };
}

// ── EGL and the host back buffer ───────────────────────────────────────────

/// Render scale: the back buffer is 640x480 times this. RECOMP_SCALE (1-4).
var scale: u32 = 2;

/// Widescreen (hor+) widens the back buffer to 16:9 by this factor;
/// RECOMP_WIDESCREEN=0 keeps 4:3. 3D stretches across it (manual.zig widens
/// the projection's aspect to match) and pre-transformed 2D stays 4:3 in the middle.
pub fn wide() f32 {
    const S = struct {
        var v: f32 = 0;
    };
    if (S.v == 0) S.v = if (std.c.getenv("RECOMP_WIDESCREEN")) |e| (if (e[0] == '0') 1 else 4.0 / 3.0) else 4.0 / 3.0;
    return S.v;
}

/// Frame of the last widened projection (manual.zig). 3D stretches across the
/// wide back buffer only while the title projects through one (in a stage);
/// the title and menu screens' own 3D stays 4:3 in the middle.
pub var wide_frame: u32 = 0xFFFF_0000;

fn wideNow() bool {
    return frame -% wide_frame <= 2;
}

/// Back buffer width in guest pixels.
fn bbw() u32 {
    return @intFromFloat(@round(640 * wide()));
}

/// A guest x span on the back buffer to host pixels: full width stretches
/// across, anything else keeps its 4:3 place in the middle.
fn bbSpan(x1: u32, x2: u32) [2]u32 {
    if (x1 == 0 and x2 >= 640) return .{ 0, bbw() };
    const off = (bbw() - 640) / 2;
    return .{ x1 + off, x2 + off };
}

/// The current draw stretches across the wide back buffer (setViewport).
var draw_stretch = false;
/// Data of recent full-width back buffer copies (CopyRects), and of offscreen
/// targets drawn from one (the pause blur downsamples a copy): each holds the
/// whole wide back buffer.
var bb_copies: [8]u32 = @splat(0);
var bb_copy_next: usize = 0;

fn isCopy(tex: u32) bool {
    return tex != 0 and std.mem.indexOfScalar(u32, &bb_copies, d3d.resData(tex)) != null;
}

fn addCopy(data: u32) void {
    if (std.mem.indexOfScalar(u32, &bb_copies, data) != null) return;
    bb_copies[bb_copy_next] = data;
    bb_copy_next = (bb_copy_next + 1) % bb_copies.len;
}

pub var hwnd: ?HWND = null;
var dpy: gl.EGLDisplay = null;
var surf: gl.EGLSurface = null;
var state: enum { none, ready, failed } = .none;
var s3tc = false;
var vao: gl.GLuint = 0;
var vbo: gl.GLuint = 0;
var ibo: gl.GLuint = 0;
var fbo: gl.GLuint = 0;
var fbo_color: gl.GLuint = 0;
var fbo_depth: gl.GLuint = 0;
var samplers: [4]gl.GLuint = @splat(0);

// HWNDs need not be aligned; translate-c types EGLNativeWindowType as a struct pointer.
extern fn eglCreateWindowSurface(gl.EGLDisplay, gl.EGLConfig, ?HWND, ?*const gl.EGLint) gl.EGLSurface;

fn hasExt(name: []const u8) bool {
    var n: gl.GLint = 0;
    gl.glGetIntegerv(gl.GL_NUM_EXTENSIONS, &n);
    for (0..@intCast(n)) |i| {
        if (std.mem.eql(u8, std.mem.span(gl.glGetStringi(gl.GL_EXTENSIONS, @intCast(i))), name)) return true;
    }
    return false;
}

/// Window, context and back buffer on first use. RECOMP_GFX=d3d11 (default), vulkan or gl.
fn ready() bool {
    if (state != .none) return state == .ready;
    state = .failed;
    if (std.c.getenv("RECOMP_SCALE")) |s| scale = std.math.clamp(std.fmt.parseInt(u32, std.mem.span(s), 10) catch 2, 1, 4);
    const class = std.unicode.utf8ToUtf16LeStringLiteral("OtogiRecomp");
    _ = RegisterClassExW(&.{ .lpfnWndProc = wndProc, .lpszClassName = class });
    var r: RECT = .{ .right = @intCast(bbw() * scale), .bottom = @intCast(480 * scale) };
    _ = AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, 0);
    hwnd = CreateWindowExW(0, class, std.unicode.utf8ToUtf16LeStringLiteral("Otogi: Myth of Demons"), WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, r.right - r.left, r.bottom - r.top, null, null, null, null) orelse return false;

    var platform: gl.EGLAttrib = gl.EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE;
    if (std.c.getenv("RECOMP_GFX")) |g| {
        const s = std.mem.span(g);
        if (std.ascii.eqlIgnoreCase(s, "vulkan")) platform = gl.EGL_PLATFORM_ANGLE_TYPE_VULKAN_ANGLE;
        if (std.ascii.eqlIgnoreCase(s, "gl")) platform = gl.EGL_PLATFORM_ANGLE_TYPE_OPENGL_ANGLE;
    }
    const dpy_attrs = [_]gl.EGLAttrib{ gl.EGL_PLATFORM_ANGLE_TYPE_ANGLE, platform, gl.EGL_NONE };
    dpy = gl.eglGetPlatformDisplay(gl.EGL_PLATFORM_ANGLE_ANGLE, null, &dpy_attrs);
    const cfg_attrs = [_]gl.EGLint{ gl.EGL_RED_SIZE, 8, gl.EGL_GREEN_SIZE, 8, gl.EGL_BLUE_SIZE, 8, gl.EGL_RENDERABLE_TYPE, gl.EGL_OPENGL_ES3_BIT, gl.EGL_NONE };
    const ctx_attrs = [_]gl.EGLint{ gl.EGL_CONTEXT_MAJOR_VERSION, 3, gl.EGL_CONTEXT_MINOR_VERSION, 0, gl.EGL_NONE };
    var cfg: gl.EGLConfig = null;
    var n: gl.EGLint = 0;
    if (dpy == gl.EGL_NO_DISPLAY or gl.eglInitialize(dpy, null, null) == 0 or
        gl.eglChooseConfig(dpy, &cfg_attrs, &cfg, 1, &n) == 0 or n == 0)
    {
        std.debug.print("[GL] EGL display failed: 0x{X}\n", .{gl.eglGetError()});
        return false;
    }
    surf = eglCreateWindowSurface(dpy, cfg, hwnd, null);
    const ctx = gl.eglCreateContext(dpy, cfg, gl.EGL_NO_CONTEXT, &ctx_attrs);
    if (surf == gl.EGL_NO_SURFACE or ctx == gl.EGL_NO_CONTEXT or gl.eglMakeCurrent(dpy, surf, surf, ctx) == 0) {
        std.debug.print("[GL] EGL context failed: 0x{X}\n", .{gl.eglGetError()});
        return false;
    }
    // The game paces itself by its vblank; RECOMP_VSYNC (default on, 0 = off)
    // also waits for the monitor's, so frames do not tear.
    const vsync = if (std.c.getenv("RECOMP_VSYNC")) |e| e[0] != '0' else true;
    _ = gl.eglSwapInterval(dpy, @intFromBool(vsync));
    // The NV2A does not clip on depth, it clamps (as xemu does): Otogi's sky
    // dome lies past the far plane.
    if (hasExt("GL_EXT_depth_clamp")) gl.glEnable(gl.GL_DEPTH_CLAMP_EXT) else std.debug.print("[GL] no GL_EXT_depth_clamp: geometry past the far plane is clipped\n", .{});
    s3tc = hasExt("GL_EXT_texture_compression_s3tc") or
        (hasExt("GL_EXT_texture_compression_dxt1") and hasExt("GL_ANGLE_texture_compression_dxt5"));

    gl.glGenVertexArrays(1, &vao);
    gl.glBindVertexArray(vao);
    gl.glGenBuffers(1, &vbo);
    gl.glGenBuffers(1, &ibo);
    gl.glGenSamplers(4, &samplers);
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
    gl.glPixelStorei(gl.GL_PACK_ALIGNMENT, 1);
    // ponytail: one back buffer for every render target; the title sets the
    // render target once (to its back buffer) through the menus.
    gl.glGenFramebuffers(1, &fbo);
    gl.glGenTextures(1, &fbo_color);
    gl.glGenRenderbuffers(1, &fbo_depth);
    gl.glBindTexture(gl.GL_TEXTURE_2D, fbo_color);
    gl.glTexStorage2D(gl.GL_TEXTURE_2D, 1, gl.GL_RGBA8, @intCast(bbw() * scale), @intCast(480 * scale));
    gl.glBindRenderbuffer(gl.GL_RENDERBUFFER, fbo_depth);
    gl.glRenderbufferStorage(gl.GL_RENDERBUFFER, gl.GL_DEPTH24_STENCIL8, @intCast(bbw() * scale), @intCast(480 * scale));
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, fbo);
    gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, fbo_color, 0);
    gl.glFramebufferRenderbuffer(gl.GL_FRAMEBUFFER, gl.GL_DEPTH_STENCIL_ATTACHMENT, gl.GL_RENDERBUFFER, fbo_depth);
    target_fbo = fbo;
    renderer_name = gl.glGetString(gl.GL_RENDERER);
    std.debug.print("[GL] {s}, {s}; rendering at {d}x{s}\n", .{ gl.glGetString(gl.GL_RENDERER), gl.glGetString(gl.GL_VERSION), scale, if (s3tc) "" else " (no S3TC)" });
    frInit();
    state = .ready;
    return true;
}

// ── Textures: everything but DXT becomes RGBA8 on the CPU ──────────────────

pub var renderer_name: [*:0]const u8 = "";

/// Per game frame counts for the debug menu: `stats` fills during a frame,
/// `last` is the frame before.
pub const Stats = struct { draws: u32 = 0, clears: u32 = 0, copies: u32 = 0, uploads: u32 = 0, work_ms: f32 = 0 };
pub var stats: Stats = .{};
pub var last: Stats = .{};

pub fn cacheSizes() struct { textures: usize, programs: usize, vertex_programs: usize, pixel_shaders: usize, targets: usize, pushbuffers: usize } {
    return .{ .textures = textures.items.len, .programs = progs.items.len, .vertex_programs = programs.items.len, .pixel_shaders = pixel_shaders.items.len, .targets = rts.items.len, .pushbuffers = pb_recs.items.len };
}

var conv: std.ArrayList(u8) = .empty;
const alloc = std.heap.page_allocator;

fn convBuf(n: usize) []u8 {
    conv.resize(alloc, n) catch @panic("OOM");
    return conv.items;
}

fn dxtGl(f: d3d.Fmt) gl.GLenum {
    return switch (f.kind) {
        .dxt1 => gl.GL_COMPRESSED_RGBA_S3TC_DXT1_EXT,
        .dxt3 => gl.GL_COMPRESSED_RGBA_S3TC_DXT3_EXT,
        else => gl.GL_COMPRESSED_RGBA_S3TC_DXT5_EXT,
    };
}

/// One level of a guest texture to `target` (2D or a cube face).
fn uploadLevel(f: d3d.Fmt, target: gl.GLenum, lv: i32, src0: [*]const u8, w: u32, h: u32, pitch0: u32, pal: ?[*]align(1) const u32) void {
    if (d3d.isDxt(f)) {
        if (s3tc) gl.glCompressedTexImage2D(target, lv, dxtGl(f), @intCast(w), @intCast(h), 0, @intCast(d3d.levelBytes(f, w, h)), src0);
        return; // ponytail: no S3TC means no DXT textures; decode on the CPU if a back end lacks it
    }
    const bpp: u32 = f.bits / 8;
    var src = src0;
    var pitch = pitch0;
    var tmp: []u8 = &.{};
    defer alloc.free(tmp);
    if (f.swizzled) {
        tmp = alloc.alloc(u8, w * h * bpp) catch return;
        d3d.unswizzle(tmp, src, w, h, bpp);
        src = tmp.ptr;
        pitch = w * bpp;
    }
    const d = convBuf(w * h * 4);
    const yuv = f.kind == .yuy2 or f.kind == .uyvy;
    for (0..h) |y| for (0..w) |x| {
        const o = d[(y * w + x) * 4 ..][0..4];
        if (yuv) d3d.yuvRgba(f.kind, src + y * pitch, x, o) else d3d.texelRgba(f, src + y * pitch + x * bpp, pal, o);
    };
    gl.glTexImage2D(target, lv, gl.GL_RGBA8, @intCast(w), @intCast(h), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, d.ptr);
}

const HostTex = struct { data: u32, format: u32, size: u32, palette: u32, hash: u32, checked: u32, tex: gl.GLuint };
var textures: std.ArrayList(HostTex) = .empty;

fn texCreate(f: d3d.Fmt, data: u32, format: u32, w: u32, h: u32, pitch: u32, pal: ?[*]align(1) const u32, cube: bool) gl.GLuint {
    var levels: u32 = if (f.swizzled or d3d.isDxt(f)) (format >> 16) & 0xF else 1;
    if (levels == 0) levels = 1;
    if (d3d.isDxt(f) and !s3tc) return 0;
    const bind: gl.GLenum = if (cube) gl.GL_TEXTURE_CUBE_MAP else gl.GL_TEXTURE_2D;
    var src = d3d.ptr(data);
    var t: gl.GLuint = 0;
    stats.uploads += 1;
    gl.glGenTextures(1, &t);
    gl.glBindTexture(bind, t);
    for (0..if (cube) 6 else 1) |face| {
        var lw = w;
        var lh = h;
        var face_bytes: u32 = 0;
        const target: gl.GLenum = if (cube) @as(gl.GLenum, gl.GL_TEXTURE_CUBE_MAP_POSITIVE_X) + @as(gl.GLenum, @intCast(face)) else gl.GL_TEXTURE_2D;
        for (0..levels) |lv| {
            uploadLevel(f, target, @intCast(lv), src, lw, lh, if (pitch != 0) pitch else lw * f.bits / 8, pal);
            const b = d3d.levelBytes(f, lw, lh);
            face_bytes += b;
            src += b;
            lw = @max(lw / 2, 1);
            lh = @max(lh / 2, 1);
        }
        if (cube) src += ((face_bytes + 127) & ~@as(u32, 127)) - face_bytes; // faces start on 128 bytes
    }
    gl.glTexParameteri(bind, gl.GL_TEXTURE_MAX_LEVEL, @intCast(levels - 1));
    return t;
}

/// The host texture for a guest texture. lin is set (texel size) for linear
/// textures, whose coordinates the title gives in texels.
fn texGet(res: u32, tlin: *[2]f32, cube: *bool) gl.GLuint {
    const data = d3d.resData(res);
    const format = mem32(res + 0xC);
    const size = mem32(res + 0x10);
    const dims = d3d.surfDims(res);
    const xfmt = (format >> 8) & 0xFF;
    tlin.* = .{ 0, 0 };
    cube.* = (format >> 2) & 1 != 0;
    if (data == d3d.resData(backBuffer())) return 0; // ponytail: sampling the back buffer is not done
    for (rts.items) |r| if (r.data == data) {
        if (size != 0) tlin.* = .{ @floatFromInt(dims.w), @floatFromInt(dims.h) }; // linear: texel coordinates
        return r.tex;
    };
    const f = d3d.fmtFind(xfmt) orelse {
        const said = struct {
            var mask: u64 = 0;
        };
        if (said.mask & (@as(u64, 1) << @intCast(xfmt & 63)) == 0) std.debug.print("[GL] texture format 0x{X:0>2} not handled\n", .{xfmt});
        said.mask |= @as(u64, 1) << @intCast(xfmt & 63);
        return 0;
    };
    // ponytail: palettes (P8) read as white; mirror SetPalette when a title uses them
    if (!f.swizzled and !d3d.isDxt(f)) tlin.* = .{ @floatFromInt(dims.w), @floatFromInt(dims.h) };
    var t: ?*HostTex = null;
    for (textures.items) |*e| {
        if (e.data == data and e.format == format and e.size == size) {
            t = e;
            break;
        }
    }
    if (t) |e| if (e.checked == frame) return e.tex;
    const bytes = if (dims.pitch != 0) dims.pitch * dims.h else d3d.levelBytes(f, dims.w, dims.h);
    const hash = d3d.hashBytes(d3d.ptr(data), bytes);
    if (t) |e| if (e.hash == hash) {
        e.checked = frame;
        return e.tex;
    };
    const e = t orelse textures.addOne(alloc) catch return 0;
    if (t != null) gl.glDeleteTextures(1, &e.tex);
    e.* = .{ .data = data, .format = format, .size = size, .palette = 0, .hash = hash, .checked = frame, .tex = 0 };
    e.tex = texCreate(f, data, format, dims.w, dims.h, dims.pitch, null, cube.*);
    return e.tex;
}

// ── Mirrored state ──────────────────────────────────────────────────────────

var stage_tex: [4]u32 = @splat(0);
var vshader: u32 = 0; // FVF, or a program handle (odd)
var pshader: u32 = 0;
var stream_vb: [16]u32 = @splat(0);
var stream_stride: [16]u32 = @splat(0);
/// Host copies standing in for the streams while a recorded frame replays
/// (pointing where vertex 0 would be).
var stream_host: [16]?[*]const u8 = @splat(null);
var base_vertex: u32 = 0;
var xf: [10][16]f32 = @splat(identity); // view, proj, tex0-3, world0-3
var vp: struct { x: u32 = 0, y: u32 = 0, w: u32 = 640, h: u32 = 480 } = .{};
var lin: [4][2]f32 = @splat(.{ 0, 0 });

const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

/// The back buffer surface: the render target the device sets first (at
/// CreateDevice). Swap rotates its Data; the surface object stays.
var back_buffer: u32 = 0;
fn backBuffer() u32 {
    return back_buffer;
}

fn matMul(a: [16]f32, b: [16]f32) [16]f32 { // row vectors: a * b
    var o: [16]f32 = undefined;
    for (0..4) |r| for (0..4) |c| {
        o[r * 4 + c] = a[r * 4] * b[c] + a[r * 4 + 1] * b[4 + c] + a[r * 4 + 2] * b[8 + c] + a[r * 4 + 3] * b[12 + c];
    };
    return o;
}

fn argbVec(c: u32) [4]f32 {
    return .{ @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255, @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255, @as(f32, @floatFromInt(c & 0xFF)) / 255, @as(f32, @floatFromInt(c >> 24)) / 255 };
}

// ── Vertex programs ─────────────────────────────────────────────────────────

const HostVs = struct {
    handle: u32,
    decl: [96]u32,
    mc: [136 * 4]u32,
    nmc: usize,
    inputs: u16 = 0,
    uses_vp: bool = false,
    hash: u32 = 0, // of the microcode: names a program across runs
    glsl: ?[]u8 = null,
};
var programs: std.ArrayList(HostVs) = .empty;
var vsc: [192][4]f32 = @splat(.{ 0, 0, 0, 0 });

fn vsFind(handle: u32) ?*HostVs {
    for (programs.items) |*h| if (h.handle == handle) return h;
    return null;
}

// ── Shader generation ───────────────────────────────────────────────────────

/// Everything a generated program depends on. Zeroed then filled, so it compares as bytes.
const Key = extern struct {
    vs: u32 = 0, // index+1 into programs, or 0: fixed function
    ps: u32 = 0, // index+1 into pixel_shaders, or 0: texture stages
    rhw: u8 = 0,
    diffuse: u8 = 0,
    specular: u8 = 0,
    ntc: u8 = 0,
    tc_set: [4]u8 = @splat(0),
    tc_count: [4]u8 = @splat(0),
    tc_proj: [4]u8 = @splat(0),
    tc_size: [8]u8 = @splat(0),
    colorop: [4]u8 = @splat(0),
    colorarg: [4][3]u8 = @splat(@splat(0)),
    alphaop: [4]u8 = @splat(0),
    alphaarg: [4][3]u8 = @splat(@splat(0)),
    result_temp: [4]u8 = @splat(0),
    tex: [4]u8 = @splat(0), // 0 none, 1 2D, 2 cube
    spec_add: u8 = 0,
    fog: u8 = 0,
    fog_table: u8 = 0,
    alpha_test: u8 = 0,
    alpha_func: u8 = 0,
    flat: u8 = 0,
};

const Prog = struct {
    key: Key,
    prog: gl.GLuint,
    u_wv: gl.GLint = -1,
    u_proj: gl.GLint = -1,
    u_texm: gl.GLint = -1,
    u_rhw: gl.GLint = -1,
    u_fog: gl.GLint = -1,
    u_fogcolor: gl.GLint = -1,
    u_tf: gl.GLint = -1,
    u_aref: gl.GLint = -1,
    u_tscale: gl.GLint = -1,
    u_c: gl.GLint = -1,
    u_psc: gl.GLint = -1,
    u_psf: gl.GLint = -1,
    u_bump: gl.GLint = -1,
};
var progs: std.ArrayList(Prog) = .empty;

// Xbox D3DTOP values (the order differs from PC D3D after BLENDTEXTUREALPHA).
const XOP = struct {
    const DISABLE = 1;
    const SELECTARG1 = 2;
    const SELECTARG2 = 3;
    const MODULATE = 4;
    const MODULATE2X = 5;
    const MODULATE4X = 6;
    const ADD = 7;
    const ADDSIGNED = 8;
    const ADDSIGNED2X = 9;
    const SUBTRACT = 10;
    const ADDSMOOTH = 11;
    const BLENDDIFFUSEALPHA = 12;
    const BLENDCURRENTALPHA = 13;
    const BLENDTEXTUREALPHA = 14;
    const BLENDFACTORALPHA = 15;
    const BLENDTEXTUREALPHAPM = 16;
    const PREMODULATE = 17;
    const MODULATEALPHA_ADDCOLOR = 18;
    const MODULATECOLOR_ADDALPHA = 19;
    const MODULATEINVALPHA_ADDCOLOR = 20;
    const MODULATEINVCOLOR_ADDALPHA = 21;
    const DOTPRODUCT3 = 22;
    const MULTIPLYADD = 23;
    const LERP = 24;
};

/// GLSL for a texture-stage argument (D3DTA: source in the low bits,
/// COMPLEMENT 0x10, ALPHAREPLICATE 0x20).
fn ffArg(w: *std.Io.Writer, a: u32, st: usize) !void {
    const src = [_][]const u8{ "dif", "cur", "tx", "tf", "spe", "tmp" };
    var buf: [16]u8 = undefined;
    const base = if (a & 7 == 2) try std.fmt.bufPrint(&buf, "tx{d}", .{st}) else if (a & 7 < 6) src[a & 7] else "cur";
    if (a & 0x20 != 0) {
        if (a & 0x10 != 0) try w.print("vec4(1.0 - {s}.a)", .{base}) else try w.print("vec4({s}.a)", .{base});
    } else {
        if (a & 0x10 != 0) try w.print("(1.0 - {s})", .{base}) else try w.writeAll(base);
    }
}

fn ffOp(w: *std.Io.Writer, op: u32, st: usize) !void {
    switch (op) {
        XOP.SELECTARG1 => try w.writeAll("a1"),
        XOP.SELECTARG2 => try w.writeAll("a2"),
        XOP.MODULATE => try w.writeAll("a1 * a2"),
        XOP.MODULATE2X => try w.writeAll("a1 * a2 * 2.0"),
        XOP.MODULATE4X => try w.writeAll("a1 * a2 * 4.0"),
        XOP.ADD => try w.writeAll("a1 + a2"),
        XOP.ADDSIGNED => try w.writeAll("a1 + a2 - 0.5"),
        XOP.ADDSIGNED2X => try w.writeAll("(a1 + a2 - 0.5) * 2.0"),
        XOP.SUBTRACT => try w.writeAll("a1 - a2"),
        XOP.ADDSMOOTH => try w.writeAll("a1 + a2 - a1 * a2"),
        XOP.BLENDDIFFUSEALPHA => try w.writeAll("mix(a2, a1, dif.a)"),
        XOP.BLENDCURRENTALPHA => try w.writeAll("mix(a2, a1, cur.a)"),
        XOP.BLENDTEXTUREALPHA => try w.print("mix(a2, a1, tx{d}.a)", .{st}),
        XOP.BLENDFACTORALPHA => try w.writeAll("mix(a2, a1, tf.a)"),
        XOP.BLENDTEXTUREALPHAPM => try w.print("a1 + a2 * (1.0 - tx{d}.a)", .{st}),
        XOP.MODULATEALPHA_ADDCOLOR => try w.writeAll("a1 + a1.a * a2"),
        XOP.MODULATECOLOR_ADDALPHA => try w.writeAll("a1 * a2 + a1.a"),
        XOP.MODULATEINVALPHA_ADDCOLOR => try w.writeAll("(1.0 - a1.a) * a2 + a1"),
        XOP.MODULATEINVCOLOR_ADDALPHA => try w.writeAll("(1.0 - a1) * a2 + a1.a"),
        XOP.DOTPRODUCT3 => try w.writeAll("vec4(clamp(dot((a1.rgb - 0.5) * 2.0, (a2.rgb - 0.5) * 2.0), 0.0, 1.0))"),
        XOP.MULTIPLYADD => try w.writeAll("a0 + a1 * a2"),
        XOP.LERP => try w.writeAll("mix(a2, a1, a0)"),
        else => { // ponytail: PREMODULATE and the bump ops pass the first argument
            sayOnce("texture stage op (bump or premodulate) not done");
            try w.writeAll("a1");
        },
    }
}

fn sayOnce(comptime msg: []const u8) void {
    const s = struct {
        var said = false;
    };
    if (!s.said) std.debug.print("[GL] " ++ msg ++ "\n", .{});
    s.said = true;
}

const common = "#version 300 es\nprecision highp float;\nprecision highp int;\n";

fn genVs(k: *const Key, w: *std.Io.Writer) !void {
    const fl = if (k.flat != 0) "flat " else "";
    try w.writeAll(common);
    try w.writeAll("uniform vec4 u_fog;\n");
    try w.print("{s}out vec4 v_d0;\n{s}out vec4 v_d1;\nout vec4 v_t0, v_t1, v_t2, v_t3;\nout float v_fog, v_eyez;\n", .{ fl, fl });
    if (k.vs != 0) {
        const h = &programs.items[k.vs - 1];
        try w.writeAll("uniform vec4 u_c[192];\n");
        for (0..16) |i| if (h.inputs & (@as(u16, 1) << @intCast(i)) != 0) try w.print("in vec4 v{d};\n", .{i});
        // oFog.x is a distance for table fog and the factor itself with FOGTABLEMODE
        // NONE (Otogi writes 1 - z/far). A NaN factor reads as no fog, as on the NV2A.
        try w.writeAll(
            \\float nv_fog(float f) { float d = abs(f); return u_fog.x == 3.0 ? (u_fog.z - d) / (u_fog.z - u_fog.y)
            \\  : u_fog.x == 1.0 ? exp(-d * u_fog.w) : u_fog.x == 2.0 ? exp(-(d * u_fog.w) * (d * u_fog.w)) : f; }
            \\float rcc(float x) { float f = 1.0 / x; float m = clamp(abs(f), 5.42101e-20, 1.884467e19); return f < 0.0 ? -m : m; }
            \\vec4 nv_log(float x) { float a = abs(x); float e = floor(log2(a)); return a == 0.0 ? vec4(-1e38, 1.0, -1e38, 1.0) : vec4(e, a / exp2(e), log2(a), 1.0); }
            \\vec4 nv_lit(vec4 c) { float p = clamp(c.w, -127.9961, 127.9961); return vec4(1.0, max(c.x, 0.0), c.x > 0.0 ? pow(max(c.y, 0.0), p) : 0.0, 1.0); }
            \\#define c u_c
            \\void main() {
            \\  vec4 R0 = vec4(0.0), R1 = R0, R2 = R0, R3 = R0, R4 = R0, R5 = R0, R6 = R0, R7 = R0, R8 = R0, R9 = R0, R10 = R0, R11 = R0, R12 = R0;
            \\  vec4 oD0 = vec4(0.0, 0.0, 0.0, 1.0), oD1 = oD0, oFog = vec4(0.0);
            \\  vec4 oT0 = vec4(0.0, 0.0, 0.0, 1.0), oT1 = oT0, oT2 = oT0, oT3 = oT0;
            \\  int a0 = 0;
            \\
        );
        try w.writeAll(h.glsl.?);
        try w.print("  vec4 p = {s};\n", .{if (h.uses_vp) "vec4(R12.xyz * R12.w, R12.w)" else "R12"});
        try w.writeAll(
            \\  gl_Position = vec4(p.x, -p.y, 2.0 * p.z - p.w, p.w);
            \\  v_d0 = clamp(oD0, 0.0, 1.0); v_d1 = clamp(oD1, 0.0, 1.0); v_fog = nv_fog(oFog.x); v_fog = isnan(v_fog) ? 1.0 : clamp(v_fog, 0.0, 1.0); v_eyez = 0.0;
            \\  v_t0 = oT0; v_t1 = oT1; v_t2 = oT2; v_t3 = oT3;
            \\}
            \\
        );
        return;
    }
    try w.writeAll("uniform mat4 u_wv, u_proj, u_texm[4];\nuniform vec4 u_rhw;\nin vec4 a_pos;\n");
    if (k.diffuse != 0) try w.writeAll("in vec4 a_diffuse;\n");
    if (k.specular != 0) try w.writeAll("in vec4 a_specular;\n");
    for (0..k.ntc) |i| try w.print("in vec4 a_tc{d};\n", .{i});
    try w.writeAll("void main() {\n");
    try w.print("  vec4 dif_in = {s}, spe_in = {s};\n", .{ if (k.diffuse != 0) "a_diffuse.zyxw" else "vec4(1.0)", if (k.specular != 0) "a_specular.zyxw" else "vec4(0.0)" });
    if (k.rhw != 0) {
        // Pre-transformed: guest pixels (centres on integers) to clip space.
        try w.writeAll(
            \\  float w = a_pos.w != 0.0 ? 1.0 / a_pos.w : 1.0;
            \\  vec2 ndc = (a_pos.xy + 0.5 - u_rhw.xy) / u_rhw.zw * 2.0 - 1.0;
            \\  gl_Position = vec4(ndc * w, (2.0 * a_pos.z - 1.0) * w, w);
            \\  v_eyez = w;
            \\
        );
    } else {
        // ponytail: fixed-function lighting is not done (SetLight is not identified in this XDK build).
        try w.writeAll(
            \\  vec4 eye = u_wv * vec4(a_pos.xyz, 1.0);
            \\  vec4 p = u_proj * eye;
            \\  gl_Position = vec4(p.x, -p.y, 2.0 * p.z - p.w, p.w);
            \\  v_eyez = abs(eye.z);
            \\
        );
    }
    try w.writeAll("  v_d0 = dif_in; v_d1 = spe_in;\n");
    for (0..4) |i| {
        var buf: [64]u8 = undefined;
        const in: []const u8 = if (k.tc_set[i] < k.ntc) blk: {
            // D3D pads a 2D coordinate as (u, v, 1, 0) for its texture matrix.
            const n = k.tc_size[k.tc_set[i]];
            const t = k.tc_set[i];
            break :blk try switch (n) {
                1 => std.fmt.bufPrint(&buf, "vec4(a_tc{d}.x, 1.0, 0.0, 0.0)", .{t}),
                2 => std.fmt.bufPrint(&buf, "vec4(a_tc{d}.xy, 1.0, 0.0)", .{t}),
                3 => std.fmt.bufPrint(&buf, "vec4(a_tc{d}.xyz, 1.0)", .{t}),
                else => std.fmt.bufPrint(&buf, "a_tc{d}", .{t}),
            };
        } else "vec4(0.0, 0.0, 0.0, 1.0)";
        if (k.tc_count[i] != 0)
            try w.print("  v_t{d} = u_texm[{d}] * {s};\n", .{ i, i, in })
        else
            try w.print("  v_t{d} = {s};\n", .{ i, in });
    }
    try w.writeAll(if (k.fog != 0 and k.fog_table == 0) "  v_fog = spe_in.a;\n}\n" else "  v_fog = 1.0;\n}\n");
}

fn genFs(k: *const Key, w: *std.Io.Writer) !void {
    const fl = if (k.flat != 0) "flat " else "";
    try w.writeAll(common);
    try w.print("{s}in vec4 v_d0;\n{s}in vec4 v_d1;\nin vec4 v_t0, v_t1, v_t2, v_t3;\nin float v_fog, v_eyez;\n", .{ fl, fl });
    try w.writeAll("uniform vec4 u_tf, u_fog, u_fogcolor, u_tscale[4];\nuniform float u_aref;\n");
    for (0..4) |st| if (k.tex[st] != 0) try w.print("uniform {s} u_tex{d};\n", .{ if (k.tex[st] == 2) "samplerCube" else "sampler2D", st });
    if (k.ps != 0) {
        try w.writeAll("uniform vec4 u_psc[16], u_psf[2], u_bump[4];\nout vec4 o_color;\n" ++
            "vec2 sgn8(vec2 x) { vec2 b = floor(x * 255.0 + 0.5); return max(mix(b, b - 256.0, step(128.0, b)) / 127.0, -1.0); }\n" ++
            "void main() {\n  vec4 cur;\n");
        try genCombiners(k, &pixel_shaders.items[k.ps - 1].def, w);
        return genAlphaTest(k, w);
    }
    try w.writeAll("out vec4 o_color;\nvoid main() {\n  vec4 dif = v_d0, spe = v_d1, tf = u_tf, cur = dif, tmp = vec4(0.0), a0, a1, a2;\n");
    for (0..4) |st| {
        if (k.tex[st] == 2) {
            try w.print("  vec4 tx{d} = texture(u_tex{d}, v_t{d}.xyz);\n", .{ st, st, st });
        } else if (k.tex[st] != 0 and k.tc_proj[st] != 0) {
            const q: u8 = switch (k.tc_count[st]) {
                3 => 'z',
                2 => 'y',
                else => 'w',
            };
            try w.print("  vec4 tx{d} = texture(u_tex{d}, v_t{d}.xy / v_t{d}.{c} * u_tscale[{d}].xy + u_tscale[{d}].zw);\n", .{ st, st, st, st, q, st, st });
        } else if (k.tex[st] != 0) {
            try w.print("  vec4 tx{d} = texture(u_tex{d}, v_t{d}.xy * u_tscale[{d}].xy + u_tscale[{d}].zw);\n", .{ st, st, st, st, st });
        } else {
            try w.print("  vec4 tx{d} = vec4(1.0);\n", .{st});
        }
    }
    for (0..4) |st| {
        if (k.colorop[st] == XOP.DISABLE or k.colorop[st] == 0) break;
        for (0..3) |a| {
            try w.print("  a{d} = ", .{a});
            try ffArg(w, k.colorarg[st][a], st);
            try w.writeAll(";\n");
        }
        try w.print("  vec3 c{d} = clamp((", .{st});
        try ffOp(w, k.colorop[st], st);
        try w.writeAll(").rgb, 0.0, 1.0);\n");
        if (k.alphaop[st] == XOP.DISABLE or k.alphaop[st] == 0) {
            try w.print("  float x{d} = cur.a;\n", .{st});
        } else {
            for (0..3) |a| {
                try w.print("  a{d} = ", .{a});
                try ffArg(w, k.alphaarg[st][a], st);
                try w.writeAll(";\n");
            }
            try w.print("  float x{d} = clamp((", .{st});
            try ffOp(w, k.alphaop[st], st);
            try w.writeAll(").a, 0.0, 1.0);\n");
        }
        try w.print("  {s} = vec4(c{d}, x{d});\n", .{ if (k.result_temp[st] != 0) "tmp" else "cur", st, st });
    }
    if (k.spec_add != 0) try w.writeAll("  cur.rgb = clamp(cur.rgb + spe.rgb, 0.0, 1.0);\n");
    if (k.fog != 0) {
        try w.writeAll(if (k.fog_table != 0)
            \\  float f = u_fog.x == 3.0 ? (u_fog.z - v_eyez) / (u_fog.z - u_fog.y)
            \\          : u_fog.x == 1.0 ? exp(-v_eyez * u_fog.w) : exp(-(v_eyez * u_fog.w) * (v_eyez * u_fog.w));
            \\
        else
            "  float f = v_fog;\n");
        try w.writeAll("  cur.rgb = mix(u_fogcolor.rgb, cur.rgb, clamp(f, 0.0, 1.0));\n");
    }
    return genAlphaTest(k, w);
}

fn genAlphaTest(k: *const Key, w: *std.Io.Writer) !void {
    if (k.alpha_test != 0) {
        // GL_NEVER 0x200 .. GL_ALWAYS 0x207, as the Xbox stores them.
        const cmp = [8][]const u8{ "false", "<", "==", "<=", ">", "!=", ">=", "true" };
        const f = k.alpha_func & 7;
        if (f == 0) try w.writeAll("  discard;\n") else if (f != 7) try w.print("  if (!(floor(cur.a * 255.0 + 0.5) {s} u_aref)) discard;\n", .{cmp[f]});
    }
    try w.writeAll("  o_color = cur;\n}\n");
}

// ── Pixel shaders: NV2A register combiners to GLSL ─────────────────────────
// The D3DPIXELSHADERDEF words are the NV2A's own combiner words. Semantics
// from the toolkit's CPU model (src/kernel/nv2a_combiner.c, after xemu's
// psh.c). Registers: 0 zero, 1 c0, 2 c1, 3 fog, 4 v0, 5 v1, 8-11 t0-t3,
// 12 r0, 13 r1, 14 v1+r0 sum and 15 E*F (final combiner only).

const PsDef = struct {
    const alpha_inputs = 0;
    const final_abcd = 8;
    const final_efg = 9;
    const constant0 = 10;
    const constant1 = 18;
    const alpha_outputs = 26;
    const rgb_inputs = 34;
    const final_c0 = 43;
    const final_c1 = 44;
    const rgb_outputs = 45;
    const combiner_count = 53;
    const texture_modes = 54;
    const words = 60; // sizeof(D3DPIXELSHADERDEF) / 4
};
const HostPs = struct { handle: u32, def: [PsDef.words]u32 };
var pixel_shaders: std.ArrayList(HostPs) = .empty;

fn psFind(handle: u32) ?usize {
    for (pixel_shaders.items, 0..) |p, i| if (p.handle == handle) return i;
    return null;
}

/// An input byte: reg | alpha << 4 | mapping << 5, as RGB (vec3) or alpha (float).
fn psIn(w: *std.Io.Writer, byte: u32, alpha_portion: bool) !void {
    const reg = byte & 0xF;
    const sel = if (alpha_portion) (if (byte & 0x10 != 0) ".a" else ".b") else (if (byte & 0x10 != 0) ".aaa" else ".rgb");
    var buf: [32]u8 = undefined;
    const x = try std.fmt.bufPrint(&buf, "R[{d}]{s}", .{ reg, sel });
    switch ((byte >> 5) & 7) {
        0 => try w.print("max({s}, 0.0)", .{x}), // unsigned identity
        1 => try w.print("(1.0 - clamp({s}, 0.0, 1.0))", .{x}), // unsigned invert
        2 => try w.print("(2.0 * max({s}, 0.0) - 1.0)", .{x}), // expand normal
        3 => try w.print("(-2.0 * max({s}, 0.0) + 1.0)", .{x}), // expand negate
        4 => try w.print("(max({s}, 0.0) - 0.5)", .{x}), // half-bias normal
        5 => try w.print("(-max({s}, 0.0) + 0.5)", .{x}), // half-bias negate
        6 => try w.writeAll(x), // signed identity
        else => try w.print("(-{s})", .{x}), // signed negate
    }
}

fn psOut(op: u32) []const u8 { // OCW scale/bias, applied to `x`
    return switch (op) {
        0x08 => "(x - 0.5)",
        0x10 => "(x * 2.0)",
        0x18 => "((x - 0.5) * 2.0)",
        0x20 => "(x * 4.0)",
        0x30 => "(x * 0.5)",
        else => "x",
    };
}

fn genCombiners(k: *const Key, def: *const [PsDef.words]u32, w: *std.Io.Writer) !void {
    const modes = def[PsDef.texture_modes];
    try w.writeAll("  vec4 R[16];\n  for (int i = 0; i < 16; i++) R[i] = vec4(0.0);\n");
    try w.writeAll("  R[3] = vec4(u_fogcolor.rgb, v_fog); R[4] = v_d0; R[5] = v_d1;\n");
    for (0..4) |st| {
        const mode = (modes >> @intCast(5 * st)) & 0x1F;
        const reg = 8 + st;
        if (mode == 0) continue; // NONE: zero
        if (mode == 4) { // PASSTHRU: the coordinates as a colour
            try w.print("  R[{d}] = clamp(v_t{d}, 0.0, 1.0);\n", .{ reg, st });
        } else if (mode == 6 and st > 0 and k.tex[st] == 1) {
            // BUMPENVMAP: the previous stage's texel is a signed (du, dv), V8U8 with
            // U in byte 0 (G here), turned by this stage's BUMPENVMAT and added to
            // its coordinates, in texels for a linear texture.
            try w.print("  {{ vec2 d = sgn8(R[{d}].gb); vec4 m = u_bump[{d}];\n" ++
                "    R[{d}] = texture(u_tex{d}, (v_t{d}.xy / (v_t{d}.w != 0.0 ? v_t{d}.w : 1.0) + vec2(m.x * d.x + m.z * d.y, m.y * d.x + m.w * d.y)) * u_tscale[{d}].xy + u_tscale[{d}].zw); }}\n", .{ reg - 1, st, reg, st, st, st, st, st, st });
        } else if (k.tex[st] == 2) {
            try w.print("  R[{d}] = texture(u_tex{d}, v_t{d}.xyz);\n", .{ reg, st, st });
        } else if (k.tex[st] == 1) {
            // ponytail: 3D, clip-plane, bump and dot-product modes sample as 2D
            if (mode != 1) {
                const said = struct {
                    var mask: u32 = 0;
                };
                if (said.mask & (@as(u32, 1) << @intCast(mode)) == 0) std.debug.print("[GL] pixel shader texture mode 0x{X} (stage {d}) sampled as 2D\n", .{ mode, st });
                said.mask |= @as(u32, 1) << @intCast(mode);
            }
            try w.print("  R[{d}] = texture(u_tex{d}, v_t{d}.xy / (v_t{d}.w != 0.0 ? v_t{d}.w : 1.0) * u_tscale[{d}].xy + u_tscale[{d}].zw);\n", .{ reg, st, st, st, st, st, st });
        } else {
            try w.print("  R[{d}] = vec4(1.0);\n", .{reg});
        }
    }
    // r0.a starts as texture 0's alpha, or 1 with stage 0 off.
    try w.writeAll(if (modes & 0x1F != 0) "  R[12].a = R[8].a;\n" else "  R[12].a = 1.0;\n");

    const control = def[PsDef.combiner_count];
    const flags = control >> 8;
    for (0..@min(control & 0xFF, 8)) |s| {
        const icw = def[PsDef.rgb_inputs + s];
        const ocw = def[PsDef.rgb_outputs + s];
        const aicw = def[PsDef.alpha_inputs + s];
        const aocw = def[PsDef.alpha_outputs + s];
        const fl = ocw >> 12;
        const afl = aocw >> 12;
        try w.print("  {{ R[1] = u_psc[{d}]; R[2] = u_psc[{d}];\n", .{ if (flags & 0x010 != 0) s else 0, 8 + (if (flags & 0x100 != 0) s else 0) });
        try w.writeAll(if (flags & 1 != 0) "    bool mux = R[12].a >= 0.5;\n" else "    bool mux = (int(R[12].a * 255.0) & 1) != 0;\n");
        // Both portions read before either writes.
        inline for (.{ "A", "B", "C", "D" }, .{ 24, 16, 8, 0 }) |n, sh| {
            try w.writeAll("    vec3 " ++ n ++ " = ");
            try psIn(w, (icw >> sh) & 0xFF, false);
            try w.writeAll("; float a" ++ n ++ " = ");
            try psIn(w, (aicw >> sh) & 0xFF, true);
            try w.writeAll(";\n");
        }
        try w.print("    vec3 pab = {s}; vec3 pcd = {s};\n", .{ if (fl & 2 != 0) "vec3(dot(A, B))" else "A * B", if (fl & 1 != 0) "vec3(dot(C, D))" else "C * D" });
        try w.print("    vec3 psum = {s}; float qab = aA * aB, qcd = aC * aD, qsum = {s};\n", .{ if (fl & 4 != 0) "mux ? pcd : pab" else "pab + pcd", if (afl & 4 != 0) "mux ? qcd : qab" else "qab + qcd" });
        try w.print("    vec3 x; vec3 ab, cd, ms; float aab, acd, ams;\n" ++
            "    x = pab; ab = clamp({0s}, -1.0, 1.0); x = pcd; cd = clamp({0s}, -1.0, 1.0); x = psum; ms = clamp({0s}, -1.0, 1.0);\n", .{psOut(fl & 0x38)});
        const ao = psOut(afl & 0x38);
        try w.print("    {{ float x = qab; aab = clamp({0s}, -1.0, 1.0); }} {{ float x = qcd; acd = clamp({0s}, -1.0, 1.0); }} {{ float x = qsum; ams = clamp({0s}, -1.0, 1.0); }}\n", .{ao});
        // RGB destinations; blue-to-alpha also writes the destination's alpha.
        if ((ocw >> 4) & 0xF != 0) try w.print("    R[{d}].rgb = ab;\n", .{(ocw >> 4) & 0xF});
        if ((ocw >> 4) & 0xF != 0 and fl & 0x80 != 0) try w.print("    R[{d}].a = ab.b;\n", .{(ocw >> 4) & 0xF});
        if (ocw & 0xF != 0) try w.print("    R[{d}].rgb = cd;\n", .{ocw & 0xF});
        if (ocw & 0xF != 0 and fl & 0x40 != 0) try w.print("    R[{d}].a = cd.b;\n", .{ocw & 0xF});
        if ((ocw >> 8) & 0xF != 0) try w.print("    R[{d}].rgb = ms;\n", .{(ocw >> 8) & 0xF});
        if ((aocw >> 4) & 0xF != 0) try w.print("    R[{d}].a = aab;\n", .{(aocw >> 4) & 0xF});
        if (aocw & 0xF != 0) try w.print("    R[{d}].a = acd;\n", .{aocw & 0xF});
        if ((aocw >> 8) & 0xF != 0) try w.print("    R[{d}].a = ams;\n", .{(aocw >> 8) & 0xF});
        try w.writeAll("    R[0] = vec4(0.0);\n  }\n");
    }

    const f0 = def[PsDef.final_abcd];
    const f1 = def[PsDef.final_efg];
    if (f0 != 0 or f1 != 0) {
        const ff = f1 & 0xFF;
        try w.writeAll("  R[1] = u_psf[0]; R[2] = u_psf[1];\n");
        // V1R0 sum: optional complements (0x40 v1, 0x20 r0), clamp (0x80).
        try w.print("  R[14] = vec4({s}{s} + {s}{s}{s}, 0.0);\n", .{
            if (ff & 0x80 != 0) "clamp(" else "",
            if (ff & 0x40 != 0) "(1.0 - R[5].rgb)" else "R[5].rgb",
            if (ff & 0x20 != 0) "(1.0 - R[12].rgb)" else "R[12].rgb",
            if (ff & 0x80 != 0) ", 0.0, 1.0)" else "",
            "",
        });
        try w.writeAll("  { vec3 E = ");
        try psIn(w, (f1 >> 24) & 0xFF, false);
        try w.writeAll("; vec3 F = ");
        try psIn(w, (f1 >> 16) & 0xFF, false);
        try w.writeAll("; R[15] = vec4(E * F, 0.0); }\n  { vec3 A = ");
        try psIn(w, (f0 >> 24) & 0xFF, false);
        try w.writeAll("; vec3 B = ");
        try psIn(w, (f0 >> 16) & 0xFF, false);
        try w.writeAll("; vec3 C = ");
        try psIn(w, (f0 >> 8) & 0xFF, false);
        try w.writeAll("; vec3 D = ");
        try psIn(w, f0 & 0xFF, false);
        try w.writeAll(";\n    cur.rgb = D + C * (1.0 - A) + B * A; cur.a = ");
        try psIn(w, (f1 >> 8) & 0xFF, true);
        try w.writeAll("; }\n");
    } else {
        // No final combiner: D3D supplies one, which fogs r0 when FOGENABLE is set.
        try w.writeAll(if (k.fog != 0) "  cur = vec4(mix(R[3].rgb, R[12].rgb, R[3].a), R[12].a);\n" else "  cur = R[12];\n");
    }
    try w.writeAll("  cur = clamp(cur, 0.0, 1.0);\n");
}

fn compile(kind: gl.GLenum, src: []const u8) gl.GLuint {
    const sh = gl.glCreateShader(kind);
    const p: [*c]const u8 = src.ptr;
    const len: gl.GLint = @intCast(src.len);
    gl.glShaderSource(sh, 1, &p, &len);
    gl.glCompileShader(sh);
    var ok: gl.GLint = 0;
    gl.glGetShaderiv(sh, gl.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [2048]u8 = undefined;
        var n: gl.GLsizei = 0;
        gl.glGetShaderInfoLog(sh, log.len, &n, &log);
        std.debug.print("[GL] shader does not compile:\n{s}\n--- source ---\n{s}\n", .{ log[0..@intCast(n)], src });
        gl.glDeleteShader(sh);
        return 0;
    }
    return sh;
}

var src_buf: [256 * 1024]u8 = undefined;

fn progGet(k: *const Key) ?*Prog {
    for (progs.items) |*p| if (std.mem.eql(u8, std.mem.asBytes(&p.key), std.mem.asBytes(k))) return if (p.prog != 0) p else null;
    const p = progs.addOne(alloc) catch return null;
    p.* = .{ .key = k.*, .prog = 0 };
    var w: std.Io.Writer = .fixed(&src_buf);
    genVs(k, &w) catch return null;
    if (std.c.getenv("RECOMP_GL_DUMP") != null and k.vs != 0) std.debug.print("[GL] program {d}, vertex shader {X}:\n{s}\n", .{ progs.items.len, programs.items[k.vs - 1].handle, w.buffered() });
    const vs = compile(gl.GL_VERTEX_SHADER, w.buffered());
    w = .fixed(&src_buf);
    genFs(k, &w) catch return null;
    if (std.c.getenv("RECOMP_GL_DUMP") != null and k.ps != 0) std.debug.print("[GL] program {d}, pixel shader {X}:\n{s}\n", .{ progs.items.len, pixel_shaders.items[k.ps - 1].handle, w.buffered() });
    const fs = compile(gl.GL_FRAGMENT_SHADER, w.buffered());
    if (vs == 0 or fs == 0) return null;
    const prog = gl.glCreateProgram();
    gl.glAttachShader(prog, vs);
    gl.glAttachShader(prog, fs);
    var name: [16]u8 = undefined;
    if (k.vs != 0) {
        for (0..16) |i| gl.glBindAttribLocation(prog, @intCast(i), (std.fmt.bufPrintSentinel(&name, "v{d}", .{i}, 0) catch unreachable).ptr);
    } else {
        for ([_][*:0]const u8{ "a_pos", "a_normal", "a_diffuse", "a_specular", "a_psize", "a_tc0", "a_tc1", "a_tc2", "a_tc3" }, 0..) |a, i| gl.glBindAttribLocation(prog, @intCast(i), a);
    }
    gl.glLinkProgram(prog);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(fs);
    var ok: gl.GLint = 0;
    gl.glGetProgramiv(prog, gl.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [2048]u8 = undefined;
        var n: gl.GLsizei = 0;
        gl.glGetProgramInfoLog(prog, log.len, &n, &log);
        std.debug.print("[GL] program does not link: {s}\n", .{log[0..@intCast(n)]});
        return null;
    }
    p.prog = prog;
    inline for (.{ "u_wv", "u_proj", "u_texm", "u_rhw", "u_fog", "u_fogcolor", "u_tf", "u_aref", "u_tscale", "u_c", "u_psc", "u_psf", "u_bump" }) |u|
        @field(p, u) = gl.glGetUniformLocation(prog, u);
    gl.glUseProgram(prog);
    for (0..4) |i| gl.glUniform1i(gl.glGetUniformLocation(prog, (std.fmt.bufPrintSentinel(&name, "u_tex{d}", .{i}, 0) catch unreachable).ptr), @intCast(i));
    return p;
}

// ── Per-draw state ──────────────────────────────────────────────────────────

fn setCap(cap: gl.GLenum, on: bool) void {
    if (on) gl.glEnable(cap) else gl.glDisable(cap);
}

fn glFunc(v: u32) gl.GLenum {
    return if (v >= 0x200 and v <= 0x207) v else gl.GL_ALWAYS;
}

/// Otogi turns the depth test off for part of its ground mist (sprites of the
/// particle program A8A1DBCD), so those patches draw over the ground in front
/// of them. Keep it on; RECOMP_MIST_DEPTH=0 gives the original.
fn mistDepth() bool {
    const S = struct {
        var on: ?bool = null;
    };
    if (S.on == null) S.on = if (std.c.getenv("RECOMP_MIST_DEPTH")) |e| e[0] != '0' else true;
    if (!S.on.? or vshader & 1 == 0) return false;
    const h = vsFind(vshader) orelse return false;
    return h.hash == 0xA8A1DBCD;
}

fn applyRenderState() void {
    const rs = d3d.rs;
    const cull = rs(.cullmode);
    const cw = rs(.colorwriteenable);
    setCap(gl.GL_DEPTH_TEST, rs(.zenable) != 0 or mistDepth());
    gl.glDepthFunc(glFunc(rs(.zfunc)));
    gl.glDepthMask(@intFromBool(rs(.zwriteenable) != 0));
    setCap(gl.GL_BLEND, rs(.alphablendenable) != 0);
    gl.glBlendFunc(rs(.srcblend), rs(.destblend));
    gl.glBlendEquation(if (rs(.blendop) != 0) rs(.blendop) else gl.GL_FUNC_ADD);
    const bc = argbVec(rs(.blendcolor));
    gl.glBlendColor(bc[0], bc[1], bc[2], bc[3]);
    gl.glColorMask(@intCast((cw >> 16) & 1), @intCast((cw >> 8) & 1), @intCast(cw & 1), @intCast((cw >> 24) & 1));
    setCap(gl.GL_STENCIL_TEST, rs(.stencilenable) != 0);
    gl.glStencilFunc(glFunc(rs(.stencilfunc)), @intCast(rs(.stencilref)), rs(.stencilmask));
    gl.glStencilMask(rs(.stencilwritemask));
    gl.glStencilOp(if (rs(.stencilfail) != 0) rs(.stencilfail) else gl.GL_ZERO, if (rs(.stencilzfail) != 0) rs(.stencilzfail) else gl.GL_ZERO, if (rs(.stencilpass) != 0) rs(.stencilpass) else gl.GL_ZERO);
    // A D3D clockwise triangle is counter-clockwise in GL's (unflipped) window space.
    setCap(gl.GL_CULL_FACE, cull == 0x900 or cull == 0x901);
    gl.glCullFace(gl.GL_BACK);
    gl.glFrontFace(if (cull == 0x900) gl.GL_CW else gl.GL_CCW);
    const solid = rs(.solidoffsetenable) != 0;
    const slope: f32 = if (solid) @bitCast(rs(.polygonoffsetzslopescale)) else 0;
    // ZBIAS (0..16, larger is nearer) on top. ponytail: 256 steps per unit is Sneak King's guess.
    const units: f32 = (if (solid) @as(f32, @bitCast(rs(.polygonoffsetzoffset))) else 0) - @as(f32, @floatFromInt(rs(.zbias))) * 256;
    setCap(gl.GL_POLYGON_OFFSET_FILL, slope != 0 or units != 0);
    gl.glPolygonOffset(slope, units);
}

fn glWrap(v: u32) gl.GLint {
    return switch (v) {
        1 => gl.GL_REPEAT,
        2 => gl.GL_MIRRORED_REPEAT,
        else => gl.GL_CLAMP_TO_EDGE,
    };
}

fn applyStages(k: *Key) void {
    const tss = d3d.tss;
    for (0..4) |st| {
        const s: u32 = @intCast(st);
        var cube = false;
        const t = if (stage_tex[st] != 0) texGet(stage_tex[st], &lin[st], &cube) else blk: {
            lin[st] = .{ 0, 0 };
            break :blk 0;
        };
        k.tex[st] = if (t == 0) 0 else if (cube) 2 else 1;
        gl.glActiveTexture(@as(gl.GLenum, gl.GL_TEXTURE0) + s);
        gl.glBindTexture(if (cube) gl.GL_TEXTURE_CUBE_MAP else gl.GL_TEXTURE_2D, t);
        const smp = samplers[st];
        gl.glBindSampler(s, smp);
        gl.glSamplerParameteri(smp, gl.GL_TEXTURE_WRAP_S, glWrap(tss(s, .addressu)));
        gl.glSamplerParameteri(smp, gl.GL_TEXTURE_WRAP_T, glWrap(tss(s, .addressv)));
        gl.glSamplerParameteri(smp, gl.GL_TEXTURE_WRAP_R, glWrap(tss(s, .addressw)));
        const mag = tss(s, .magfilter);
        const min = tss(s, .minfilter);
        const mip = tss(s, .mipfilter);
        gl.glSamplerParameteri(smp, gl.GL_TEXTURE_MAG_FILTER, if (mag == 1) gl.GL_NEAREST else gl.GL_LINEAR);
        gl.glSamplerParameteri(smp, gl.GL_TEXTURE_MIN_FILTER, switch (mip) {
            0 => if (min == 1) gl.GL_NEAREST else gl.GL_LINEAR,
            1 => if (min == 1) gl.GL_NEAREST_MIPMAP_NEAREST else gl.GL_LINEAR_MIPMAP_NEAREST,
            else => if (min == 1) gl.GL_NEAREST_MIPMAP_LINEAR else gl.GL_LINEAR_MIPMAP_LINEAR,
        });
        gl.glSamplerParameterf(smp, gl.GL_TEXTURE_MIN_LOD, @floatFromInt(tss(s, .maxmiplevel)));
        k.colorop[st] = @truncate(tss(s, .colorop));
        k.alphaop[st] = @truncate(tss(s, .alphaop));
        k.colorarg[st] = .{ @truncate(tss(s, .colorarg0)), @truncate(tss(s, .colorarg1)), @truncate(tss(s, .colorarg2)) };
        k.alphaarg[st] = .{ @truncate(tss(s, .alphaarg0)), @truncate(tss(s, .alphaarg1)), @truncate(tss(s, .alphaarg2)) };
        k.result_temp[st] = @intFromBool(tss(s, .resultarg) == 5);
    }
    gl.glActiveTexture(gl.GL_TEXTURE0);
}

fn keyVertex(k: *Key) void {
    if (k.vs != 0) return;
    const fvf = vshader;
    k.rhw = @intFromBool(fvf & 0x00E == 0x004);
    k.diffuse = @intFromBool(fvf & 0x040 != 0);
    k.specular = @intFromBool(fvf & 0x080 != 0);
    k.ntc = @intCast(@min((fvf >> 8) & 0xF, 4));
    for (0..k.ntc) |i| {
        k.tc_size[i] = switch ((fvf >> @intCast(16 + 2 * i)) & 3) {
            0 => 2,
            1 => 3,
            2 => 4,
            else => 1,
        };
    }
    for (0..4) |i| {
        const s: u32 = @intCast(i);
        k.tc_set[i] = @intCast(d3d.tss(s, .texcoordindex) & 7);
        const ttf = d3d.tss(s, .texturetransformflags);
        k.tc_count[i] = @intCast(ttf & 7);
        k.tc_proj[i] = @intFromBool(ttf & 0x100 != 0);
    }
}

/// Texture coordinate scale (linear textures address in texels) and offset.
/// A back buffer copy holds the whole wide back buffer; a draw kept in the 4:3
/// middle (the title logo's refraction) samples it at its 4:3 screen position.
fn uploadTscale(p: *const Prog) void {
    if (p.u_tscale < 0) return;
    var v: [4][4]f32 = undefined;
    for (0..4) |i| {
        v[i] = .{ if (lin[i][0] != 0) 1 / lin[i][0] else 1, if (lin[i][1] != 0) 1 / lin[i][1] else 1, 0, 0 };
        if (target_fbo == fbo and !draw_stretch and isCopy(stage_tex[i])) {
            const bw: f32 = @floatFromInt(bbw());
            v[i][0] *= 640 / bw;
            v[i][2] = @as(f32, @floatFromInt((bbw() - 640) / 2)) / bw;
        }
    }
    gl.glUniform4fv(p.u_tscale, 4, @ptrCast(&v));
}

fn uploadUniforms(p: *const Prog) void {
    const rs = d3d.rs;
    if (p.u_wv >= 0) gl.glUniformMatrix4fv(p.u_wv, 1, gl.GL_FALSE, &matMul(xf[6], xf[0])); // world0 * view
    if (p.u_proj >= 0) {
        // A quad exactly on the far plane with ZFUNC LESS against depth cleared to
        // 1.0 survives the NV2A's integer depth; scale z a hair under 1 for float depth.
        var pr = xf[1];
        const kz: f32 = 1.0 - 1.0 / 4194304.0;
        for ([_]usize{ 2, 6, 10, 14 }) |i| pr[i] *= kz;
        gl.glUniformMatrix4fv(p.u_proj, 1, gl.GL_FALSE, &pr);
    }
    if (p.u_texm >= 0) gl.glUniformMatrix4fv(p.u_texm, 4, gl.GL_FALSE, @ptrCast(&xf[2]));
    if (p.u_rhw >= 0) gl.glUniform4f(p.u_rhw, @floatFromInt(vp.x), @floatFromInt(vp.y), @floatFromInt(@max(vp.w, 1)), @floatFromInt(@max(vp.h, 1)));
    if (p.u_fog >= 0) gl.glUniform4f(p.u_fog, @floatFromInt(rs(.fogtablemode)), @bitCast(rs(.fogstart)), @bitCast(rs(.fogend)), @bitCast(rs(.fogdensity)));
    if (p.u_fogcolor >= 0) gl.glUniform4fv(p.u_fogcolor, 1, &argbVec(rs(.fogcolor)));
    if (p.u_tf >= 0) gl.glUniform4fv(p.u_tf, 1, &argbVec(rs(.texturefactor)));
    if (p.u_aref >= 0) gl.glUniform1f(p.u_aref, @floatFromInt(rs(.alpharef) & 0xFF));
    uploadTscale(p);
    if (p.u_c >= 0) {
        // c[58]/c[59] identity: the translated program undoes D3D's divide.
        vsc[58] = .{ 1, 1, 1, 1 };
        vsc[59] = .{ 0, 0, 0, 0 };
        gl.glUniform4fv(p.u_c, 192, @ptrCast(&vsc));
    }
    if (p.key.ps != 0) {
        const def = &pixel_shaders.items[p.key.ps - 1].def;
        var c: [16][4]f32 = undefined;
        for (0..8) |i| {
            c[i] = argbVec(def[PsDef.constant0 + i]);
            c[8 + i] = argbVec(def[PsDef.constant1 + i]);
        }
        if (p.u_psc >= 0) gl.glUniform4fv(p.u_psc, 16, @ptrCast(&c));
        const f = [2][4]f32{ argbVec(def[PsDef.final_c0]), argbVec(def[PsDef.final_c1]) };
        if (p.u_psf >= 0) gl.glUniform4fv(p.u_psf, 2, @ptrCast(&f));
        if (p.u_bump >= 0) {
            var m: [4][4]f32 = undefined;
            for (0..4) |i| {
                const s: u32 = @intCast(i);
                m[i] = .{ @bitCast(d3d.tss(s, .bumpenvmat00)), @bitCast(d3d.tss(s, .bumpenvmat01)), @bitCast(d3d.tss(s, .bumpenvmat10)), @bitCast(d3d.tss(s, .bumpenvmat11)) };
            }
            gl.glUniform4fv(p.u_bump, 4, @ptrCast(&m));
        }
    }
}

// ── Draws ───────────────────────────────────────────────────────────────────

fn fvfStride(fvf: u32) u32 {
    var n: u32 = switch (fvf & 0x00E) {
        0x002 => 12,
        0x004, 0x006 => 16,
        0x008 => 20,
        0x00A => 24,
        0x00C => 28,
        else => 0,
    };
    if (fvf & 0x010 != 0) n += 12;
    if (fvf & 0x020 != 0) n += 4;
    if (fvf & 0x040 != 0) n += 4;
    if (fvf & 0x080 != 0) n += 4;
    for (0..(fvf >> 8) & 0xF) |i| n += switch ((fvf >> @intCast(16 + 2 * i)) & 3) {
        0 => 8,
        1 => 12,
        2 => 16,
        else => 4,
    };
    return n;
}

fn attrib(i: u32, n: i32, kind: gl.GLenum, norm: bool, stride: u32, off: u32) void {
    gl.glEnableVertexAttribArray(i);
    gl.glVertexAttribPointer(i, n, kind, @intFromBool(norm), @intCast(stride), @ptrFromInt(off));
}

/// Attribute pointers for an FVF vertex in the bound array buffer.
fn fvfAttribs(fvf: u32, stride: u32) void {
    for (0..13) |i| gl.glDisableVertexAttribArray(@intCast(i));
    const pos = fvf & 0x00E;
    attrib(0, if (pos == 0x004) 4 else 3, gl.GL_FLOAT, false, stride, 0);
    var off: u32 = if (pos == 0x004) 16 else 12;
    if (pos >= 0x006 and pos <= 0x00C) {
        sayOnce("FVF blend weights skipped"); // ponytail: world0 only
        off += 4 * ((pos - 0x004) / 2);
    }
    if (fvf & 0x010 != 0) {
        attrib(1, 3, gl.GL_FLOAT, false, stride, off);
        off += 12;
    }
    if (fvf & 0x020 != 0) off += 4;
    if (fvf & 0x040 != 0) {
        attrib(2, 4, gl.GL_UNSIGNED_BYTE, true, stride, off);
        off += 4;
    }
    if (fvf & 0x080 != 0) {
        attrib(3, 4, gl.GL_UNSIGNED_BYTE, true, stride, off);
        off += 4;
    }
    for (0..@min((fvf >> 8) & 0xF, 4)) |i| {
        const n: u32 = switch ((fvf >> @intCast(16 + 2 * i)) & 3) {
            0 => 2,
            1 => 3,
            2 => 4,
            else => 1,
        };
        attrib(@intCast(5 + i), @intCast(n), gl.GL_FLOAT, false, stride, off);
        off += n * 4;
    }
}

var vs_buf: std.ArrayList(u8) = .empty;

/// Vertices base+[lo, hi] for a program, as float4 slots. Stream 0 is `up`
/// when the draw supplies it. Returns the stride; regs gets the registers filled.
fn vsVertices(h: *HostVs, base: u32, lo: u32, hi: u32, up: ?[*]const u8, up_stride: u32, regs: *u16) u32 {
    var in: [16]d3d.VsInput = undefined;
    const n = d3d.vsInputs(&h.decl, &in);
    regs.* = h.inputs;
    for (in[0..n]) |e| regs.* |= @as(u16, 1) << @intCast(e.reg);
    if (regs.* == 0) regs.* = 1;
    var slot: [16]u32 = undefined;
    var ns: u32 = 0;
    for (0..16) |r| if (regs.* & (@as(u16, 1) << @intCast(r)) != 0) {
        slot[r] = ns;
        ns += 1;
    };
    const stride = 16 * ns;
    vs_buf.resize(alloc, (hi - lo + 1) * stride) catch @panic("OOM");
    const out: [*][4]f32 = @ptrCast(@alignCast(vs_buf.items.ptr));
    for (lo..hi + 1) |v| {
        const o = out + (v - lo) * ns;
        for (0..ns) |s| o[s] = .{ 0, 0, 0, 1 };
        for (in[0..n]) |e| {
            const src: [*]const u8, const sstride = if (e.stream == 0 and up != null) .{ up.?, up_stride } else if (stream_host[e.stream]) |hp| .{ hp, stream_stride[e.stream] } else if (stream_vb[e.stream] != 0) .{ d3d.ptr(d3d.resData(stream_vb[e.stream])), stream_stride[e.stream] } else continue;
            d3d.vsdtRead(e.type, src + (base + v) * sstride + e.offset, &o[slot[e.reg]]);
        }
    }
    return stride;
}

/// GL viewport for the guest viewport. On the wide back buffer it stretches
/// across, or keeps its 4:3 place in the middle.
fn setViewport(stretch: bool) void {
    draw_stretch = stretch;
    var x: f32 = @floatFromInt(vp.x);
    var w: f32 = @floatFromInt(vp.w);
    if (target_fbo == fbo) {
        if (stretch) {
            x *= wide();
            w *= wide();
        } else x = @floatFromInt(bbSpan(vp.x, vp.x + 1)[0]);
    }
    const s: f32 = @floatFromInt(scale);
    gl.glViewport(@intFromFloat(@round(x * s)), @intCast(vp.y * scale), @intFromFloat(@round(w * s)), @intCast(vp.h * scale));
}

/// x range of pre-transformed vertices.
fn xSpan(verts: [*]const u8, stride: u32, n: u32) [2]f32 {
    var r: [2]f32 = .{ 1e9, -1e9 };
    for (0..n) |i| {
        const x = std.mem.bytesToValue(f32, verts[i * stride ..][0..4]);
        r = .{ @min(r[0], x), @max(r[1], x) };
    }
    return r;
}

var ext_buf: std.ArrayList(u8) = .empty;
var ext_tail: std.ArrayList(u8) = .empty;

/// A pre-transformed draw at a screen edge (backgrounds, banners, tiles,
/// fades, letterbox bars) reaches the wide back buffer's edge. A banner tile
/// (a quad 16-256 pixels wide, a power of two) repeats outward, so a band of
/// clamped tiles carries its pattern on. Otherwise the edge vertices move out
/// with their texture coordinates extrapolated: a tiled pattern carries on, a
/// picture's clamped border repeats, and a picture inside a full-screen layer
/// (the title logo) keeps its shape. Returns the edited vertices, or null
/// when the draw is not such a quad.
fn extend2d(verts: [*]const u8, stride: u32, n: u32, xprim: u32) ?[]const u8 {
    const group: u32 = if (xprim == 8) 4 else if (n <= 6) n else return null;
    var tc: u32 = 16; // XYZRHW, then point size, diffuse, specular
    for ([_]u32{ 0x020, 0x040, 0x080 }) |b| tc += if (vshader & b != 0) 4 else 0;
    const ntc = @min((stride -| tc) / 4, 16);
    ext_buf.clearRetainingCapacity();
    ext_tail.clearRetainingCapacity();
    ext_buf.appendSlice(alloc, verts[0 .. n * stride]) catch return null;
    const v = ext_buf.items;
    const off: f32 = @floatFromInt((bbw() - 640) / 2);
    const f = struct {
        fn at(b: []u8, i: usize) *align(1) f32 {
            return @ptrCast(b[i..][0..4]);
        }
    }.at;
    var g: u32 = 0;
    while (g + group <= n) : (g += group) {
        var lo: f32 = 1e9;
        var hi: f32 = -1e9;
        for (g..g + group) |i| {
            lo = @min(lo, f(v, i * stride).*);
            hi = @max(hi, f(v, i * stride).*);
        }
        if (lo > 0.5 and hi < 639) continue;
        const w = hi - lo;
        const tile = xprim == 8 and w >= 15.5 and w <= 256.5 and @abs(w - std.math.exp2(@round(std.math.log2(w)))) < 0.5;
        if (tile) {
            const dir: f32 = if (lo <= 0.5) -1 else 1;
            var k: f32 = 1;
            while ((k - 1) * w < off) : (k += 1) {
                const at = ext_tail.items.len;
                ext_tail.appendSlice(alloc, v[g * stride .. (g + group) * stride]) catch return null;
                for (0..group) |i| f(ext_tail.items, at + i * stride).* += dir * k * w;
            }
            continue;
        }
        // Gradient along x: two vertices on one row.
        var a: ?u32 = null;
        var b: u32 = 0;
        for (g..g + group) |i| for (i + 1..g + group) |j| {
            const dx = f(v, j * stride).* - f(v, i * stride).*;
            if (a == null and @abs(dx) > 1 and @abs(f(v, j * stride + 4).* - f(v, i * stride + 4).*) < 0.5) {
                a = @intCast(i);
                b = @intCast(j);
            }
        };
        const ai = a orelse return null;
        const dx = f(v, b * stride).* - f(v, ai * stride).*;
        var grad: [16]f32 = undefined;
        for (0..ntc) |c| grad[c] = (f(v, b * stride + tc + 4 * c).* - f(v, ai * stride + tc + 4 * c).*) / dx;
        for (g..g + group) |i| {
            const x = f(v, i * stride);
            const d: f32 = if (x.* <= 0.5) -off else if (x.* >= 639) off else continue;
            x.* += d;
            for (0..ntc) |c| f(v, i * stride + tc + 4 * c).* += d * grad[c];
        }
    }
    ext_buf.appendSlice(alloc, ext_tail.items) catch return null;
    return ext_buf.items;
}

fn prepareDraw() ?*Prog {
    if (!ready()) return null;
    var k: Key = .{};
    if (vshader & 1 != 0) {
        const h = vsFind(vshader) orelse return null;
        if (h.glsl == null) {
            var w: std.Io.Writer = .fixed(&src_buf);
            d3d.vshBody(h.mc[0..h.nmc * 4], &w, &h.inputs, &h.uses_vp) catch return null;
            h.glsl = alloc.dupe(u8, w.buffered()) catch return null;
        }
        k.vs = @intCast(h - programs.items.ptr + 1);
    }
    if (pshader != 0) {
        const i = psFind(pshader) orelse return null;
        k.ps = @intCast(i + 1);
    }
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, target_fbo);
    keyVertex(&k);
    // On the wide back buffer, 3D stretches across and pre-transformed 2D keeps its 4:3 place.
    setViewport(k.rhw == 0 and wideNow());
    applyRenderState();
    applyStages(&k);
    const rs = d3d.rs;
    k.spec_add = @intFromBool(rs(.specularenable) != 0);
    k.fog = @intFromBool(rs(.fogenable) != 0);
    k.fog_table = @intFromBool(k.fog != 0 and rs(.fogtablemode) != 0 and k.vs == 0);
    k.alpha_test = @intFromBool(rs(.alphatestenable) != 0);
    k.alpha_func = if (k.alpha_test != 0) @truncate(rs(.alphafunc) -% 0x200) else 0;
    k.flat = @intFromBool(rs(.shademode) == 0x1D00);
    const p = progGet(&k) orelse {
        if (drawlog_frame == frame + 1) std.debug.print("[DRAW] no program: vs={X} ps={X}\n", .{ vshader, pshader });
        return null;
    };
    if (drawlog_frame == frame + 1) {
        const t0 = stage_tex[0];
        std.debug.print("[DRAW] rt={d} vs={X} ps={X} tex0={X} fmt0={X} c0={d}:{X},{X} a0={d}:{X},{X} c1={d} blend={d} {X}/{X} atest={d} {X}\n", .{
            target_fbo, vshader, pshader, t0, if (t0 != 0) (mem32(t0 + 0xC) >> 8) & 0xFF else 0,
            k.colorop[0], k.colorarg[0][1], k.colorarg[0][2], k.alphaop[0], k.alphaarg[0][1], k.alphaarg[0][2], k.colorop[1],
            rs(.alphablendenable), rs(.srcblend), rs(.destblend), rs(.alphatestenable), rs(.alpharef),
        });
        std.debug.print("       vp={d},{d} {d}x{d} rhw={d} wide={d} fog={d} table={d} {d}..{d} dens={d} col={X} zen={d} zw={d} cull={X}", .{ vp.x, vp.y, vp.w, vp.h, k.rhw, frame -% wide_frame, rs(.fogenable), rs(.fogtablemode), @as(f32, @bitCast(rs(.fogstart))), @as(f32, @bitCast(rs(.fogend))), @as(f32, @bitCast(rs(.fogdensity))), rs(.fogcolor), rs(.zenable), rs(.zwriteenable), rs(.cullmode) });
        if (k.ps != 0) {
            const def = &pixel_shaders.items[k.ps - 1].def;
            std.debug.print(" modes={X} n={X} fin={X:0>8} {X:0>8}", .{ def[PsDef.texture_modes], def[PsDef.combiner_count], def[PsDef.final_abcd], def[PsDef.final_efg] });
        }
        std.debug.print("\n", .{});
    }
    gl.glUseProgram(p.prog);
    uploadUniforms(p);
    return p;
}

var idx_buf: std.ArrayList(u16) = .empty;

/// One draw. Vertices come from `up` (inline) or the bound streams starting at
/// vertex `base`; idx == null draws [0, n). Xbox primitive types are NV2A's.
fn draw(xprim: u32, n: u32, idx: ?[*]align(1) const u16, up: ?[*]const u8, up_stride: u32, base: u32) void {
    if (n == 0) return;
    if (rec_cur) |ri| {
        if (up != null) return sayOnce("DrawVerticesUP inside a recorded pushbuffer skipped");
        return recordDraw(ri, xprim, n, idx, base);
    }
    if (fr_on and !fr_replaying) frameDraw(xprim, n, idx, up, up_stride, base);
    if (!fr_replaying) stats.draws += 1;
    const p = prepareDraw() orelse return;
    if (target_fbo != fbo) for (stage_tex) |t| if (isCopy(t)) addCopy(d3d.resData(render_target));
    var lo: u32 = 0;
    var hi: u32 = n - 1;
    var nv = n; // vertices drawn: extend2d may add banner tiles
    if (idx) |ix| {
        lo = 0xFFFF;
        hi = 0;
        for (0..n) |i| {
            lo = @min(lo, ix[i]);
            hi = @max(hi, ix[i]);
        }
    }
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
    if (p.key.vs != 0) {
        var regs: u16 = 0;
        const stride = vsVertices(&programs.items[p.key.vs - 1], base, lo, hi, up, up_stride, &regs);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(vs_buf.items.len), vs_buf.items.ptr, gl.GL_STREAM_DRAW);
        var slot: u32 = 0;
        for (0..16) |r| {
            if (regs & (@as(u16, 1) << @intCast(r)) != 0) {
                attrib(@intCast(r), 4, gl.GL_FLOAT, false, stride, 16 * slot);
                slot += 1;
            } else {
                gl.glDisableVertexAttribArray(@intCast(r));
                gl.glVertexAttrib4f(@intCast(r), 0, 0, 0, 1);
            }
        }
    } else {
        var stride = if (up != null) up_stride else stream_stride[0];
        if (stride == 0) stride = fvfStride(vshader);
        const verts = if (up) |u| u else if (stream_host[0]) |h| h + base * stride else if (stream_vb[0] != 0) d3d.ptr(d3d.resData(stream_vb[0])) + base * stride else return;
        if (stride == 0) return;
        var src = verts + lo * stride;
        var bytes = (hi - lo + 1) * stride;
        const xs = if (p.key.rhw != 0) xSpan(src, stride, hi - lo + 1) else [2]f32{ 1, 1 };
        if (drawlog_frame == frame + 1 and p.key.rhw != 0) std.debug.print("       x={d:.1}..{d:.1} n={d} prim={d} idx={}\n", .{ xs[0], xs[1], n, xprim, idx != null });
        // 2D at a screen edge reaches the wide buffer's edge (backgrounds, banners, tiled
        // pictures, fades, letterbox bars); one spanning the width that extend2d cannot
        // edit, or that draws a back buffer copy back (it holds the whole buffer), stretches.
        if (p.key.rhw != 0 and target_fbo == fbo and wide() > 1 and (xs[0] <= 0.5 or xs[1] >= 639)) {
            const copy = for (stage_tex) |t| {
                if (isCopy(t)) break true;
            } else false;
            const ext = if (!copy and idx == null and vp.x == 0 and vp.w == 640) extend2d(src, stride, n, xprim) else null;
            if (drawlog_frame == frame + 1) std.debug.print("       edge: copy={} ext={}\n", .{ copy, ext != null });
            if (ext) |e| {
                src = e.ptr;
                bytes = @intCast(e.len);
                nv = bytes / stride;
                gl.glViewport(0, @intCast(vp.y * scale), @intCast(bbw() * scale), @intCast(vp.h * scale));
                gl.glUniform4f(p.u_rhw, -@as(f32, @floatFromInt((bbw() - 640) / 2)), @floatFromInt(vp.y), @floatFromInt(bbw()), @floatFromInt(@max(vp.h, 1)));
            } else if (xs[0] <= 0.5 and xs[1] >= 639) {
                setViewport(true);
                uploadTscale(p);
            }
        }
        // One glBufferData per draw: a mapped ring is slower on ANGLE's D3D11 (Sneak King P10).
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(bytes), src, gl.GL_STREAM_DRAW);
        fvfAttribs(vshader, stride);
    }
    // Indices are rebased onto lo. Quads have no GL primitive: split them.
    idx_buf.clearRetainingCapacity();
    var mode: gl.GLenum = gl.GL_TRIANGLES;
    if (xprim == 8) {
        var q: u32 = 0;
        while (q + 4 <= nv) : (q += 4) {
            var v: [4]u16 = undefined;
            for (0..4) |i| v[i] = @intCast((if (idx) |ix| ix[q + i] else q + @as(u32, @intCast(i))) - lo);
            idx_buf.appendSlice(alloc, &.{ v[0], v[1], v[2], v[0], v[2], v[3] }) catch return;
        }
    } else {
        mode = switch (xprim) {
            1 => gl.GL_POINTS,
            2 => gl.GL_LINES,
            3 => gl.GL_LINE_LOOP,
            4 => gl.GL_LINE_STRIP,
            5 => gl.GL_TRIANGLES,
            6, 9 => gl.GL_TRIANGLE_STRIP, // quad strip: same order
            7, 10 => gl.GL_TRIANGLE_FAN, // polygon: convex
            else => return,
        };
        if (idx) |ix| for (0..n) |i| idx_buf.append(alloc, @intCast(ix[i] - lo)) catch return;
    }
    if (xprim == 8 or idx != null) {
        if (idx_buf.items.len == 0) return;
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, ibo);
        gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, @intCast(idx_buf.items.len * 2), idx_buf.items.ptr, gl.GL_STREAM_DRAW);
        gl.glDrawElements(mode, @intCast(idx_buf.items.len), gl.GL_UNSIGNED_SHORT, null);
    } else {
        gl.glDrawArrays(mode, 0, @intCast(n));
    }
}

// ── Frame interpolation (RECOMP_FRAMERATE) ──────────────────────────────────
// The game steps its logic once per 30 Hz frame. To show more frames without
// speeding it up, each frame's draws and clears are recorded (state, vertex
// and index copies, constants), and while Swap waits out the 30 Hz slot the
// frame is drawn again at in-between times with vertex shader constants and
// transforms blended from the matching draw of the frame before. The real
// frame shows at the end of its slot: one game frame of extra latency.
// ponytail: only constants blend (camera, objects, bones); vertex data the CPU
// writes each frame (particles, 2D) shows at the newer frame's positions.

var fr_on = false;
var fr_steps: u32 = 1; // shown frames per game frame
var fr_replaying = false;

const Tgt = struct { fbo: gl.GLuint, size: [2]u32, rt: u32 };
fn tgtNow() Tgt {
    return .{ .fbo = target_fbo, .size = target_size, .rt = render_target };
}

const FDraw = struct {
    prim: u32,
    n: u32,
    base: u32,
    lo: u32,
    idx: ?u32 = null, // offsets into Frame.bytes
    up: ?u32 = null,
    up_stride: u32,
    streams: [16]?u32 = @splat(null),
    stride: [16]u32,
    vb: [16]u32,
    tex: [4]u32,
    vs: u32,
    ps: u32,
    state: [d3d.STATE_WORDS]u32,
    vsc: u32, // index into Frame.consts
    xf: u32, // index into Frame.xfs
    vp: @TypeOf(vp),
    tgt: Tgt,
    key: u64,
};
const FOp = union(enum) { draw: FDraw, clear: struct { c: Clear, tgt: Tgt } };
const Frame = struct {
    ops: std.ArrayList(FOp) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    consts: std.ArrayList([192][4]f32) = .empty,
    xfs: std.ArrayList([10][16]f32) = .empty,
    match: std.ArrayList(?u32) = .empty, // per op, the previous frame's matching draw

    fn reset(f: *Frame) void {
        f.ops.clearRetainingCapacity();
        f.bytes.clearRetainingCapacity();
        f.consts.clearRetainingCapacity();
        f.xfs.clearRetainingCapacity();
        f.match.clearRetainingCapacity();
    }
    fn store(f: *Frame, b: []const u8) u32 {
        const o: u32 = @intCast(f.bytes.items.len);
        f.bytes.appendSlice(alloc, b) catch @panic("OOM");
        return o;
    }
};
var frames: [2]Frame = .{ .{}, .{} };
var fcur: usize = 0;
var vsc_dirty = true;
var xf_dirty = true;
var hold_fbo: gl.GLuint = 0;
var hold_tex: gl.GLuint = 0;
pub var shown: u32 = 0; // frames shown, game and in-between

extern "gdi32" fn GetDeviceCaps(hdc: ?*anyopaque, index: c_int) callconv(.winapi) c_int;
extern "user32" fn GetDC(wnd: ?HWND) callconv(.winapi) ?*anyopaque;

/// RECOMP_FRAMERATE=<hz> shows that many frames a second (rounded down to a
/// multiple of 30); unset or 0 follows the monitor's refresh rate; 30 is off.
fn frInit() void {
    var hz: u32 = 0;
    if (std.c.getenv("RECOMP_FRAMERATE")) |e| hz = std.fmt.parseInt(u32, std.mem.span(e), 10) catch 0;
    if (hz == 0) hz = @intCast(@max(GetDeviceCaps(GetDC(null), 116), 30)); // VREFRESH
    fr_steps = @max(hz / 30, 1); // not past the refresh rate: 144 Hz shows 120
    fr_on = fr_steps > 1;
    if (!fr_on) return;
    gl.glGenTextures(1, &hold_tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, hold_tex);
    gl.glTexStorage2D(gl.GL_TEXTURE_2D, 1, gl.GL_RGBA8, @intCast(bbw() * scale), @intCast(480 * scale));
    gl.glGenFramebuffers(1, &hold_fbo);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, hold_fbo);
    gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, hold_tex, 0);
    std.debug.print("[GL] frame interpolation: {d} frames a second\n", .{30 * fr_steps});
}

fn frameDraw(xprim: u32, n: u32, idx: ?[*]align(1) const u16, up: ?[*]const u8, up_stride: u32, base: u32) void {
    const f = &frames[fcur];
    var lo: u32 = 0;
    var hi: u32 = n - 1;
    if (idx) |ix| {
        lo = 0xFFFF;
        hi = 0;
        for (0..n) |i| {
            lo = @min(lo, ix[i]);
            hi = @max(hi, ix[i]);
        }
    }
    if (vsc_dirty) f.consts.append(alloc, vsc) catch @panic("OOM");
    if (xf_dirty) f.xfs.append(alloc, xf) catch @panic("OOM");
    vsc_dirty = false;
    xf_dirty = false;
    var d: FDraw = .{
        .prim = xprim,
        .n = n,
        .base = base,
        .lo = lo,
        .up_stride = up_stride,
        .stride = stream_stride,
        .vb = stream_vb,
        .tex = stage_tex,
        .vs = vshader,
        .ps = pshader,
        .state = undefined,
        .vsc = @intCast(f.consts.items.len - 1),
        .xf = @intCast(f.xfs.items.len - 1),
        .vp = vp,
        .tgt = tgtNow(),
        .key = 0,
    };
    if (d3d.state_snap) |s| d.state = s.* else d3d.stateBlock(&d.state);
    if (idx) |ix| d.idx = f.store(@as([*]const u8, @ptrCast(ix))[0 .. 2 * n]);
    if (up) |u| d.up = f.store(u[0 .. (hi + 1) * up_stride]);
    // The streams the draw reads: a program's declared ones, or stream 0 for an FVF.
    var used: u16 = 1;
    if (vshader & 1 != 0) if (vsFind(vshader)) |h| {
        var in: [16]d3d.VsInput = undefined;
        used = 0;
        for (in[0..d3d.vsInputs(&h.decl, &in)]) |e| used |= @as(u16, 1) << @intCast(e.stream);
    };
    if (up != null) used &= ~@as(u16, 1);
    for (0..16) |s| if (used & (@as(u16, 1) << @intCast(s)) != 0 and stream_vb[s] != 0) {
        var st = stream_stride[s];
        if (s == 0 and st == 0) st = fvfStride(vshader);
        if (st == 0) continue;
        d.stride[s] = st;
        d.streams[s] = f.store(d3d.ptr(d3d.resData(stream_vb[s]))[(base + lo) * st .. (base + hi + 1) * st]);
    };
    var hsh = std.hash.Wyhash.init(0);
    hsh.update(std.mem.asBytes(&[_]u32{ vshader, pshader, stage_tex[0], stage_tex[1], stream_vb[0], base, lo, n, xprim, render_target }));
    d.key = hsh.final();
    f.ops.append(alloc, .{ .draw = d }) catch @panic("OOM");
}

/// For each draw of `cur`, the draw of `prev` with the same key, when the key
/// is unique in both frames. Repeated look-alike draws (mist sprites,
/// particles) cannot be told apart, and blending them between the wrong pairs
/// made the mist vanish from in-between frames: they show unblended.
fn frameMatch(prev: *const Frame, cur: *Frame) void {
    const Seen = struct { prev: u32 = 0, n_prev: u32 = 0, n_cur: u32 = 0 };
    var seen: std.AutoHashMapUnmanaged(u64, Seen) = .empty;
    defer seen.deinit(alloc);
    for (prev.ops.items, 0..) |op, i| if (op == .draw) {
        const g = seen.getOrPutValue(alloc, op.draw.key, .{}) catch @panic("OOM");
        g.value_ptr.prev = @intCast(i);
        g.value_ptr.n_prev += 1;
    };
    for (cur.ops.items) |op| if (op == .draw) {
        const g = seen.getOrPutValue(alloc, op.draw.key, .{}) catch @panic("OOM");
        g.value_ptr.n_cur += 1;
    };
    cur.match.clearRetainingCapacity();
    for (cur.ops.items) |op| {
        const s = if (op == .draw) seen.get(op.draw.key).? else Seen{};
        cur.match.append(alloc, if (s.n_prev == 1 and s.n_cur == 1) s.prev else null) catch @panic("OOM");
    }
}

fn lerpInto(out: []f32, a: []const f32, b: []const f32, t: f32) void {
    for (out, a, b) |*o, x, y| o.* = x + (y - x) * t;
}

/// Draw `cur` again at `t` (0..1) of the way from `prev`.
fn frameReplay(prev: *const Frame, cur: *const Frame, t: f32) void {
    const saved = .{ stage_tex, vshader, pshader, stream_vb, stream_stride, vsc, xf, vp, target_fbo, target_size, render_target };
    fr_replaying = true;
    const bytes = cur.bytes.items.ptr;
    for (cur.ops.items, cur.match.items) |*op, m| switch (op.*) {
        .clear => |*c| {
            target_fbo, target_size, render_target = .{ c.tgt.fbo, c.tgt.size, c.tgt.rt };
            clearGl(&c.c);
        },
        .draw => |*d| {
            target_fbo, target_size, render_target = .{ d.tgt.fbo, d.tgt.size, d.tgt.rt };
            vsc = cur.consts.items[d.vsc];
            xf = cur.xfs.items[d.xf];
            if (m) |pi| {
                const p = &prev.ops.items[pi].draw;
                lerpInto(@as(*[192 * 4]f32, @ptrCast(&vsc)), @as(*const [192 * 4]f32, @ptrCast(&prev.consts.items[p.vsc])), @as(*const [192 * 4]f32, @ptrCast(&cur.consts.items[d.vsc])), t);
                lerpInto(@as(*[160]f32, @ptrCast(&xf)), @as(*const [160]f32, @ptrCast(&prev.xfs.items[p.xf])), @as(*const [160]f32, @ptrCast(&cur.xfs.items[d.xf])), t);
            }
            stage_tex = d.tex;
            vshader = d.vs;
            pshader = d.ps;
            stream_vb = d.vb;
            stream_stride = d.stride;
            vp = d.vp;
            for (&stream_host, d.streams, d.stride) |*h, o, st| h.* = if (o) |off| @ptrFromInt(@intFromPtr(bytes + off) -% (d.base + d.lo) * st) else null;
            d3d.state_snap = &d.state;
            draw(d.prim, d.n, if (d.idx) |o| @ptrCast(bytes + o) else null, if (d.up) |o| bytes + o else null, d.up_stride, d.base);
        },
    };
    d3d.state_snap = null;
    stream_host = @splat(null);
    fr_replaying = false;
    stage_tex, vshader, pshader, stream_vb, stream_stride, vsc, xf, vp, target_fbo, target_size, render_target = saved;
}


fn blitFbo(src: gl.GLuint, dst: gl.GLuint) void {
    const w: i32 = @intCast(bbw() * scale);
    const h: i32 = @intCast(480 * scale);
    gl.glBindFramebuffer(gl.GL_READ_FRAMEBUFFER, src);
    gl.glBindFramebuffer(gl.GL_DRAW_FRAMEBUFFER, dst);
    gl.glDisable(gl.GL_SCISSOR_TEST);
    gl.glColorMask(1, 1, 1, 1);
    gl.glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, gl.GL_COLOR_BUFFER_BIT, gl.GL_NEAREST);
}

fn waitUntil(t: f64) void {
    var now = nowMs();
    while (now < t) : (now = nowMs()) Sleep(if (t - now >= 2) @intFromFloat(t - now - 1) else 0);
}

/// Swap with interpolation: in-between frames inside the 30 Hz slot, then
/// the game's frame at its end.
fn swapInterp() void {
    const cur = &frames[fcur];
    const prev = &frames[1 - fcur];
    if (last_present != 0 and prev.ops.items.len != 0) {
        blitFbo(fbo, hold_fbo);
        frameMatch(prev, cur);
        const step = present_period / @as(f64, @floatFromInt(fr_steps));
        for (1..fr_steps) |k| {
            const t = last_present + step * @as(f64, @floatFromInt(k));
            if (nowMs() >= t + step) continue; // too late for this one
            frameReplay(prev, cur, @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(fr_steps)));
            waitUntil(t);
            showFbo(fbo);
        }
        blitFbo(hold_fbo, fbo);
    }
    const due = last_present + present_period;
    if (last_present != 0) waitUntil(due);
    const now = nowMs();
    last_present = if (now - due < present_period) due else now;
    present();
    fcur = 1 - fcur;
    frames[fcur].reset();
    vsc_dirty = true;
    xf_dirty = true;
}

// ── Present ─────────────────────────────────────────────────────────────────

pub var frame: u32 = 0;

/// Frame whose draws are logged: RECOMP_GL_DRAWLOG=<frame>, or the frame after
/// logs\drawlog appears (deleted at once; also takes a RECOMP_SHOT-style shot).
var drawlog_frame: u32 = 0;
extern "kernel32" fn DeleteFileA([*:0]const u8) callconv(.winapi) i32;

fn present() void {
    frame += 1;
    if (frame == 1) if (std.c.getenv("RECOMP_GL_DRAWLOG")) |e| {
        drawlog_frame = std.fmt.parseInt(u32, std.mem.span(e), 10) catch 0;
    };
    if (DeleteFileA("logs\\drawlog") != 0) drawlog_frame = frame + 1;
    // RECOMP_FPS=1: game frames and shown frames per second, every 5 s.
    if (frame % 64 == 0 and std.c.getenv("RECOMP_FPS") != null) {
        const s = struct {
            var t0: f64 = 0;
            var f0: u32 = 0;
            var s0: u32 = 0;
        };
        const now = nowMs();
        if (now - s.t0 >= 5000) {
            if (s.t0 != 0) std.debug.print("[GL] {d:.1} fps, {d:.1} shown\n", .{ @as(f64, @floatFromInt(frame - s.f0)) * 1000 / (now - s.t0), @as(f64, @floatFromInt(shown - s.s0)) * 1000 / (now - s.t0) });
            s.t0 = now;
            s.f0 = frame;
            s.s0 = shown;
        }
    }
    blitWindow(fbo);
    if (frame == drawlog_frame) writeShot() catch {} else maybeShot();
    swapWindow();
    last = stats;
    stats = .{};
    // Debug menu pause: show this frame until resumed or stepped.
    while (debug_menu.holdFrame()) {
        showFbo(fbo);
        Sleep(10);
    }
}

/// An in-between frame (frame interpolation).
fn showFbo(src: gl.GLuint) void {
    blitWindow(src);
    swapWindow();
}

fn swapWindow() void {
    _ = gl.eglSwapBuffers(dpy, surf);
    shown += 1;
    pumpMessages();
}

/// The back buffer `src` to the window, letterboxed to its aspect and flipped:
/// the back buffer keeps the guest's row order.
fn blitWindow(src: gl.GLuint) void {
    const sz = clientSize();
    gl.glBindFramebuffer(gl.GL_READ_FRAMEBUFFER, src);
    gl.glBindFramebuffer(gl.GL_DRAW_FRAMEBUFFER, 0);
    gl.glDisable(gl.GL_SCISSOR_TEST);
    gl.glColorMask(1, 1, 1, 1);
    gl.glClearColor(0, 0, 0, 1);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    const bw: i32 = @intCast(bbw());
    const w: i32 = @min(sz[0], @divTrunc(sz[1] * bw, 480));
    const h: i32 = @divTrunc(w * 480, bw);
    const x = @divTrunc(sz[0] - w, 2);
    const y = @divTrunc(sz[1] - h, 2);
    gl.glBlitFramebuffer(0, 0, bw * @as(i32, @intCast(scale)), @intCast(480 * scale), x, y + h, x + w, y, gl.GL_COLOR_BUFFER_BIT, gl.GL_LINEAR);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    debug_menu.draw(hwnd.?);
}

/// RECOMP_SHOT=120,600: write the window at those frames to logs\frame_N.bmp.
fn maybeShot() void {
    const spec = std.mem.span(std.c.getenv("RECOMP_SHOT") orelse return);
    var it = std.mem.tokenizeScalar(u8, spec, ',');
    while (it.next()) |t| {
        if ((std.fmt.parseInt(u32, t, 10) catch continue) == frame) return writeShot() catch {};
    }
}

fn writeShot() !void {
    const sz = clientSize();
    const w: u32 = @intCast(sz[0]);
    const h: u32 = @intCast(sz[1]);
    const px = try alloc.alloc(u8, w * h * 4);
    defer alloc.free(px);
    gl.glReadPixels(0, 0, @intCast(w), @intCast(h), gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, px.ptr);
    var i: usize = 0;
    while (i < px.len) : (i += 4) std.mem.swap(u8, &px[i], &px[i + 2]); // RGBA -> BGRA; GL rows are bottom-up, as BMP's
    var hdr: [54]u8 = @splat(0);
    hdr[0] = 'B';
    hdr[1] = 'M';
    std.mem.writeInt(u32, hdr[2..6], 54 + @as(u32, @intCast(px.len)), .little);
    std.mem.writeInt(u32, hdr[10..14], 54, .little);
    std.mem.writeInt(u32, hdr[14..18], 40, .little);
    std.mem.writeInt(u32, hdr[18..22], w, .little);
    std.mem.writeInt(u32, hdr[22..26], h, .little);
    std.mem.writeInt(u16, hdr[26..28], 1, .little);
    std.mem.writeInt(u16, hdr[28..30], 32, .little);
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintSentinel(&name_buf, "logs\\frame_{d}.bmp", .{frame}, 0);
    const f = std.c.fopen(name, "wb") orelse return error.Open;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(&hdr, 1, hdr.len, f);
    _ = std.c.fwrite(px.ptr, 1, px.len, f);
    std.debug.print("[GL] frame {d} -> {s}\n", .{ frame, name });
}

// ── The title's own pushbuffer quads ────────────────────────────────────────
// Between BeginPush and EndPush the title writes NV2A methods itself:
// SET_BEGIN_END (0x17FC) and INLINE_ARRAY (0x1818), vertices in the FVF it
// set just before. Only those two methods appear in its push blocks.

var push_start: u32 = 0;
var push_prim: u32 = 0;
var push_verts: std.ArrayList(u8) = .empty;

fn decodePush(start: u32, end: u32) void {
    var p = start;
    while (p + 4 <= end) {
        const h = mem32(p);
        const count = (h >> 18) & 0x7FF;
        const method = h & 0x1FFC;
        p += 4;
        if (h & 0xE0030003 != 0 and h & 0x40000000 == 0) return; // a jump or call: not ours
        const data = d3d.ptr(p);
        switch (method) {
            0x17FC => {
                const prim = mem32(p);
                if (prim == 0 and push_prim != 0) {
                    const stride = fvfStride(vshader);
                    if (stride != 0) draw(push_prim, @intCast(push_verts.items.len / stride), null, push_verts.items.ptr, stride, 0);
                    push_verts.clearRetainingCapacity();
                }
                push_prim = prim;
            },
            0x1818 => push_verts.appendSlice(alloc, data[0 .. count * 4]) catch return,
            else => sayOnce("push block method other than SET_BEGIN_END/INLINE_ARRAY skipped"),
        }
        p += count * 4;
    }
}

// ── Wrapped D3D entry points ────────────────────────────────────────────────
// stdcall unless noted; arguments are read before the lifted body pops them.

extern fn sub_000F4D00_gen() void;
extern fn sub_000F4EB0_gen() void;
extern fn sub_000F8330_gen() void;
extern fn sub_000F78D0_gen() void;
extern fn sub_000F8590_gen() void;
extern fn sub_000F7130_gen() void;
extern fn sub_000F8740_gen() void;
extern fn sub_000F7530_gen() void;
extern fn sub_000F95E0_gen() void;
extern fn sub_000F6EC0_gen() void;
extern fn sub_000F7020_gen() void;
extern fn sub_000F7080_gen() void;
extern fn sub_000FA090_gen() void;
extern fn sub_000FA0B0_gen() void;
extern fn sub_000F7CF0_gen() void;
extern fn sub_000F7FC0_gen() void;
extern fn sub_000F9570_gen() void;
extern fn sub_000FA990_gen() void;
extern fn sub_000FAA00_gen() void;
extern fn sub_000FA6F0_gen() void;

extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

fn nowMs() f64 {
    var f: i64 = 0;
    var t: i64 = 0;
    _ = QueryPerformanceFrequency(&f);
    _ = QueryPerformanceCounter(&t);
    return @as(f64, @floatFromInt(t)) * 1000 / @as(f64, @floatFromInt(f));
}

var last_present: f64 = 0;

/// D3DDevice_Swap(Flags). On the Xbox a flip waits for vblank; nothing here
/// does, so presents are held to the title's rate or it runs at 1000 fps.
/// Otogi's CreateDevice (0x159D0) asks for FullScreen_PresentationInterval
/// 0x80000002: every second vblank of 60 Hz, at once when late. Its game
/// logic steps once per frame, so 30 Hz is its speed.
const present_period = 1000.0 / 30.0;
var last_swap_end: f64 = 0;
export fn sub_000F4D00() void {
    if (last_swap_end != 0) stats.work_ms = @floatCast(nowMs() - last_swap_end);
    defer last_swap_end = nowMs();
    sub_000F4D00_gen();
    if (!ready()) return;
    if (fr_on) return swapInterp();
    var now = nowMs();
    const due = last_present + present_period;
    while (last_present != 0 and now < due) : (now = nowMs()) Sleep(if (due - now >= 2) @intFromFloat(due - now - 1) else 0);
    // On the vblank grid while on time, so sleep overshoot does not add up.
    last_present = if (now - due < present_period) due else now;
    present();
}

/// D3DDevice_Clear(Count, pRects, Flags, Color, Z, Stencil).
/// Xbox flags: ZBUFFER 0x1, STENCIL 0x2, TARGET 0xF0 (one bit per channel).
export fn sub_000F4EB0() void {
    var c: Clear = .{ .flags = arg(2), .color = arg(3), .z = arg(4), .stencil = arg(5) };
    const rects = arg(1);
    if (rects != 0) {
        c.count = @min(arg(0), 16);
        for (0..c.count) |i| for (0..4) |j| {
            c.rects[i][j] = @bitCast(mem32(rects + 16 * @as(u32, @intCast(i)) + 4 * @as(u32, @intCast(j))));
        };
    }
    if (drawlog_frame == frame + 1) std.debug.print("[DRAW] clear flags={X} color={X} rects={d} rt={d}\n", .{ c.flags, c.color, c.count, target_fbo });
    sub_000F4EB0_gen();
    if (!ready()) return;
    if (fr_on and !fr_replaying) frames[fcur].ops.append(alloc, .{ .clear = .{ .c = c, .tgt = tgtNow() } }) catch {};
    stats.clears += 1;
    clearGl(&c);
}

const Clear = struct { count: u32 = 0, rects: [16][4]i32 = undefined, flags: u32, color: u32, z: u32, stencil: u32 };

fn clearGl(c: *const Clear) void {
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, target_fbo);
    var mask: gl.GLbitfield = 0;
    if (c.flags & 0xF0 != 0) mask |= gl.GL_COLOR_BUFFER_BIT;
    if (c.flags & 1 != 0) mask |= gl.GL_DEPTH_BUFFER_BIT;
    if (c.flags & 2 != 0) mask |= gl.GL_STENCIL_BUFFER_BIT;
    if (mask == 0) return;
    const col = argbVec(c.color);
    gl.glColorMask(1, 1, 1, 1);
    gl.glDepthMask(1);
    gl.glStencilMask(0xFF);
    gl.glClearColor(col[0], col[1], col[2], col[3]);
    gl.glClearDepthf(@bitCast(c.z));
    gl.glClearStencil(@intCast(c.stencil & 0xFF));
    if (c.count != 0) {
        gl.glEnable(gl.GL_SCISSOR_TEST);
        for (c.rects[0..c.count]) |r| {
            var x1 = r[0];
            var x2 = r[2];
            if (target_fbo == fbo and x1 >= 0 and x2 > x1) {
                const sp = bbSpan(@intCast(x1), @intCast(x2));
                x1 = @intCast(sp[0]);
                x2 = @intCast(sp[1]);
            }
            const s: i32 = @intCast(scale);
            gl.glScissor(x1 * s, r[1] * s, (x2 - x1) * s, (r[3] - r[1]) * s);
            gl.glClear(mask);
        }
        gl.glDisable(gl.GL_SCISSOR_TEST);
    } else {
        gl.glDisable(gl.GL_SCISSOR_TEST);
        gl.glClear(mask);
    }
}

var render_target: u32 = 0;
var target_fbo: gl.GLuint = 0; // the back buffer's fbo, or an offscreen target's
var target_size: [2]u32 = .{ 640, 480 };

/// An offscreen render target, kept on the GPU. A texture whose Data is the
/// target's samples the host texture (texGet), so nothing is read back.
const Rt = struct { data: u32, w: u32, h: u32, tex: gl.GLuint, fbo: gl.GLuint, depth: gl.GLuint };
var rts: std.ArrayList(Rt) = .empty;

fn rtGet(s: u32) ?*Rt {
    const data = d3d.resData(s);
    const dims = d3d.surfDims(s);
    for (rts.items) |*r| if (r.data == data and r.w == dims.w and r.h == dims.h) return r;
    const r = rts.addOne(alloc) catch return null;
    r.* = .{ .data = data, .w = dims.w, .h = dims.h, .tex = 0, .fbo = 0, .depth = 0 };
    gl.glGenTextures(1, &r.tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, r.tex);
    gl.glTexStorage2D(gl.GL_TEXTURE_2D, 1, gl.GL_RGBA8, @intCast(r.w * scale), @intCast(r.h * scale));
    gl.glGenRenderbuffers(1, &r.depth);
    gl.glBindRenderbuffer(gl.GL_RENDERBUFFER, r.depth);
    gl.glRenderbufferStorage(gl.GL_RENDERBUFFER, gl.GL_DEPTH24_STENCIL8, @intCast(r.w * scale), @intCast(r.h * scale));
    gl.glGenFramebuffers(1, &r.fbo);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, r.fbo);
    gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, r.tex, 0);
    std.debug.print("[GL] render target {d}x{d} format 0x{X:0>2} at 0x{X:0>8}\n", .{ r.w, r.h, (mem32(s + 0xC) >> 8) & 0xFF, data });
    return r;
}

/// D3DDevice_SetRenderTarget(pRenderTarget, pNewZStencil). D3D resets the
/// viewport to the whole new target. An offscreen target gets its own depth
/// buffer while the title passes one, and none while it passes NULL (the
/// movie does), so depth tests then pass as they do without a Z surface.
/// ponytail: the title's Z surface itself is not shared between targets.
export fn sub_000F7CF0() void {
    const s = arg(0);
    const z = arg(1);
    sub_000F7CF0_gen();
    if (back_buffer == 0) back_buffer = s;
    if (s == 0 or !ready()) return;
    render_target = s;
    target_fbo = fbo;
    target_size = .{ 640, 480 };
    if (s != back_buffer) if (rtGet(s)) |r| {
        target_fbo = r.fbo;
        target_size = .{ r.w, r.h };
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, r.fbo);
        gl.glFramebufferRenderbuffer(gl.GL_FRAMEBUFFER, gl.GL_DEPTH_STENCIL_ATTACHMENT, gl.GL_RENDERBUFFER, if (z != 0) r.depth else 0);
    };
    vp = .{ .w = target_size[0], .h = target_size[1] };
}

/// D3DDevice_DrawVerticesUP(PrimitiveType, VertexCount, pVertexStreamZeroData, VertexStreamZeroStride): replaced.
export fn sub_000F8F80() void {
    if (arg(2) != 0) draw(arg(0), arg(1), null, d3d.ptr(arg(2)), arg(3), 0);
    d3d.stdcallRet(4, 0);
}

/// D3DDevice_CopyRects(pSrc, pSrcRects, cRects, pDst, pDstPoints). The title
/// draws text to the back buffer and copies it into a texture. The back buffer
/// is only on the GPU, so read the rectangles back into the guest surface;
/// the texture cache then sees new bytes.
export fn sub_000F7FC0() void {
    const src = arg(0);
    const rects = arg(1);
    const n = arg(2);
    const dst = arg(3);
    const points = arg(4);
    stats.copies += 1;
    sub_000F7FC0_gen();
    if (drawlog_frame == frame + 1) std.debug.print("[DRAW] copyrects src={X} dst={X} n={d} rect0={d},{d}-{d},{d} rt={d}\n", .{ src, dst, n, if (rects != 0) mem32(rects) else 0, if (rects != 0) mem32(rects + 4) else 0, if (rects != 0) mem32(rects + 8) else 0, if (rects != 0) mem32(rects + 12) else 0, target_fbo });
    if (src == 0 or src != render_target or dst == 0 or !ready()) return;
    const fmt = (mem32(dst + 0xC) >> 8) & 0xFF;
    const f = d3d.fmtFind(fmt) orelse return sayOnce("CopyRects into an unknown format skipped");
    if (f.bits != 32 or d3d.isDxt(f)) return sayOnce("CopyRects into a non-32-bit surface skipped");
    const dd = d3d.surfDims(dst);
    const masks = d3d.swizzleMasks(dd.w, dd.h);
    const out = d3d.ptr(d3d.resData(dst));
    gl.glBindFramebuffer(gl.GL_READ_FRAMEBUFFER, target_fbo);
    for (0..@max(n, 1)) |i| {
        const ri: u32 = @intCast(i);
        var x1: u32 = 0;
        var y1: u32 = 0;
        var x2: u32 = 640;
        var y2: u32 = 480;
        if (rects != 0) {
            x1 = mem32(rects + 16 * ri);
            y1 = mem32(rects + 16 * ri + 4);
            x2 = mem32(rects + 16 * ri + 8);
            y2 = mem32(rects + 16 * ri + 12);
        }
        const dx = if (points != 0) mem32(points + 8 * ri) else x1;
        const dy = if (points != 0) mem32(points + 8 * ri + 4) else y1;
        if (x2 <= x1 or y2 <= y1 or x2 > 640 or y2 > 480) continue;
        const w = x2 - x1;
        const h = y2 - y1;
        // A full-width copy of the wide back buffer squeezes all of it into the 640 columns
        // (post effects draw it back across the whole screen; uploadTscale remaps draws kept
        // in the 4:3 middle); a narrower one keeps its 4:3 place.
        const sp = if (target_fbo == fbo) bbSpan(x1, x2) else [2]u32{ x1, x2 };
        if (target_fbo == fbo and sp[1] - sp[0] > w) {
            addCopy(d3d.resData(dst));
        }
        const hw = (sp[1] - sp[0]) * scale;
        // ponytail: nearest sample of the scaled back buffer, not a filtered downscale
        const px = convBuf(hw * h * scale * 4);
        gl.glReadPixels(@intCast(sp[0] * scale), @intCast(y1 * scale), @intCast(hw), @intCast(h * scale), gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, px.ptr);
        for (0..h) |y| for (0..w) |x| {
            const tx: u32 = dx + @as(u32, @intCast(x));
            const ty: u32 = dy + @as(u32, @intCast(y));
            if (tx >= dd.w or ty >= dd.h) continue;
            const s = px[((y * scale) * hw + x * hw / w) * 4 ..][0..4];
            const at: u32 = if (f.swizzled) d3d.swizzleIndex(tx, ty, masks) * 4 else ty * (if (dd.pitch != 0) dd.pitch else dd.w * 4) + tx * 4;
            const o = out[at..][0..4];
            o.* = if (f.kind == .abgr8) .{ s[0], s[1], s[2], s[3] } else .{ s[2], s[1], s[0], s[3] }; // to ARGB in memory (B, G, R, A)
        };
    }
}

/// D3DDevice_SetViewport(pViewport): X, Y, Width, Height, MinZ, MaxZ
export fn sub_000F8330() void {
    const p = arg(0);
    // D3D clamps to the render target; the title passes 0x7FFFFFFF for "all of it".
    if (p != 0) {
        const x = @min(mem32(p), target_size[0]);
        const y = @min(mem32(p + 4), target_size[1]);
        vp = .{ .x = x, .y = y, .w = @min(mem32(p + 8), target_size[0] - x), .h = @min(mem32(p + 12), target_size[1] - y) };
    }
    sub_000F8330_gen();
}

/// D3DDevice_SetTransform(State, pMatrix)
export fn sub_000F78D0() void {
    const st = arg(0);
    const p = arg(1);
    if (st < 10 and p != 0) @memcpy(std.mem.asBytes(&xf[st]), d3d.ptr(p)[0..64]);
    xf_dirty = true;
    sub_000F78D0_gen();
}

/// D3DDevice_SetTexture(Stage, pTexture)
export fn sub_000F8590() void {
    if (arg(0) < 4) stage_tex[arg(0)] = arg(1);
    sub_000F8590_gen();
}

/// D3DDevice_SetStreamSource(Stream, pVB, Stride)
export fn sub_000F7130() void {
    if (arg(0) < 16) {
        stream_vb[arg(0)] = arg(1);
        stream_stride[arg(0)] = arg(2);
    }
    sub_000F7130_gen();
}

/// D3DDevice_SetIndices(pIB, BaseVertexIndex)
export fn sub_000F8740() void {
    base_vertex = arg(1);
    sub_000F8740_gen();
}

/// D3DDevice_SetVertexShader(Handle)
export fn sub_000F7530() void {
    vshader = arg(0);
    sub_000F7530_gen();
}

/// D3DDevice_CreatePixelShader(pPSDef, pHandle): keep the definition by handle.
export fn sub_000F9570() void {
    const def = arg(0);
    const ph = arg(1);
    sub_000F9570_gen();
    if (def == 0 or ph == 0 or mem32(ph) == 0) return;
    const i = psFind(mem32(ph)) orelse blk: {
        pixel_shaders.append(alloc, .{ .handle = mem32(ph), .def = undefined }) catch return;
        break :blk pixel_shaders.items.len - 1;
    };
    // ponytail: a recreated handle keeps any program cached on the old definition
    for (0..PsDef.words) |j| pixel_shaders.items[i].def[j] = mem32(def + 4 * @as(u32, @intCast(j)));
}

/// D3DDevice_SetPixelShader(Handle)
export fn sub_000F95E0() void {
    pshader = arg(0);
    sub_000F95E0_gen();
}

/// D3DDevice_DrawVertices(PrimitiveType, StartVertex, VertexCount): replaced.
export fn sub_000F90F0() void {
    draw(arg(0), arg(2), null, null, 0, arg(1));
    d3d.stdcallRet(3, 0);
}

/// D3DDevice_DrawIndexedVertices(PrimitiveType, VertexCount, pIndexData): replaced.
export fn sub_000F9190() void {
    if (arg(2) != 0) draw(arg(0), arg(1), @ptrCast(d3d.ptr(arg(2))), null, 0, base_vertex);
    d3d.stdcallRet(3, 0);
}

/// D3DDevice_CreateVertexShader(pDeclaration, pFunction, pHandle, Usage)
export fn sub_000F6EC0() void {
    const decl = arg(0);
    const func = arg(1);
    const ph = arg(2);
    sub_000F6EC0_gen();
    if (ph == 0 or mem32(ph) == 0 or func == 0) return;
    const h = vsFind(mem32(ph)) orelse programs.addOne(alloc) catch return;
    // ponytail: a recreated handle keeps any program cached on the old microcode
    h.* = .{ .handle = mem32(ph), .decl = @splat(0xFFFFFFFF), .mc = @splat(0), .nmc = @min(mem32(func) >> 16, 136) };
    for (0..95) |i| {
        h.decl[i] = if (decl != 0) mem32(decl + 4 * @as(u32, @intCast(i))) else 0xFFFFFFFF;
        if (h.decl[i] == 0xFFFFFFFF) break;
    }
    for (0..h.nmc * 4) |i| h.mc[i] = mem32(func + 4 + 4 * @as(u32, @intCast(i)));
    h.hash = d3d.hashBytes(@ptrCast(&h.mc), @intCast(h.nmc * 16));
}

/// SetVertexShaderConstant1/4 (fastcall: ecx = register 0..191, edx = data).
fn vscCopy(reg: i32, n: u32, p: u32) void {
    vsc_dirty = true;
    for (0..n) |k| {
        const r = reg + @as(i32, @intCast(k));
        if (r >= 0 and r < 192) @memcpy(std.mem.asBytes(&vsc[@intCast(r)]), d3d.ptr(p + 16 * @as(u32, @intCast(k)))[0..16]);
    }
}
fn vscMirror(n: u32, gen: *const fn () callconv(.c) void) void {
    const reg: i32 = @bitCast(g_ecx);
    const p = g_edx;
    if (p != 0) vscCopy(reg, n, p);
    gen();
    // Recording: the constants were just written to the pushbuffer, ending at
    // the device's put pointer (device+0). Fixups rewrite them there.
    const ri = rec_cur orelse return;
    if (p == 0) return;
    const va = d3d.mem32(d3d.mem32(d3d.DEVICE_PTR)) -% 16 * n;
    if (!std.mem.eql(u8, d3d.ptr(va)[0 .. 16 * n], d3d.ptr(p)[0 .. 16 * n])) return sayOnce("recorded vertex shader constants not found in the pushbuffer");
    pb_recs.items[ri].ops.append(alloc, .{ .vsc = .{ .reg = reg, .n = n, .va = va } }) catch {};
}
export fn sub_000F7020() void {
    vscMirror(1, sub_000F7020_gen);
}
export fn sub_000F7080() void {
    vscMirror(4, sub_000F7080_gen);
}

// ── Recorded pushbuffers ────────────────────────────────────────────────────
// The title records each map mesh once (BeginPushBuffer, setters, draws,
// EndPushBuffer) and plays it every frame with RunPushBuffer, a fixup
// rewriting its per-object constants. Draws are replaced here, so the guest
// pushbuffer holds no draws; record the calls on the host instead and replay
// them. A replayed draw sees the state as recorded where the recording
// changed it (against the state at BeginPushBuffer), the live state elsewhere.

const PbDraw = struct { prim: u32, n: u32, idx: ?[*]align(1) const u16, base: u32, tex: [4]u32, vs: u32, ps: u32, vb: [4]u32, stride: [4]u32, state: [d3d.STATE_WORDS]u32 };
const PbOp = union(enum) { vsc: struct { reg: i32, n: u32, va: u32 }, draw: PbDraw };
const PbRec = struct { pb: u32, base: [d3d.STATE_WORDS]u32, ops: std.ArrayList(PbOp) };
var pb_recs: std.ArrayList(PbRec) = .empty;
var rec_cur: ?usize = null;

fn pbFind(pb: u32) ?usize {
    for (pb_recs.items, 0..) |r, i| if (r.pb == pb) return i;
    return null;
}

fn recordDraw(ri: usize, xprim: u32, n: u32, idx: ?[*]align(1) const u16, base: u32) void {
    const op = pb_recs.items[ri].ops.addOne(alloc) catch return;
    op.* = .{ .draw = .{ .prim = xprim, .n = n, .idx = idx, .base = base, .tex = stage_tex, .vs = vshader, .ps = pshader, .vb = stream_vb[0..4].*, .stride = stream_stride[0..4].*, .state = undefined } };
    d3d.stateBlock(&op.draw.state);
}

fn replay(r: *const PbRec) void {
    const saved = .{ stage_tex, vshader, pshader, stream_vb, stream_stride };
    var live: [d3d.STATE_WORDS]u32 = undefined;
    var eff: [d3d.STATE_WORDS]u32 = undefined;
    d3d.stateBlock(&live);
    if (drawlog_frame == frame + 1) std.debug.print("[DRAW] replay pushbuffer {X}, {d} ops\n", .{ r.pb, r.ops.items.len });
    for (r.ops.items) |*op| switch (op.*) {
        .vsc => |c| vscCopy(c.reg, c.n, c.va),
        .draw => |*d| {
            for (&eff, live, d.state, r.base) |*e, l, s, b| e.* = if (s != b) s else l;
            d3d.state_snap = &eff;
            stage_tex = d.tex;
            vshader = d.vs;
            pshader = d.ps;
            stream_vb[0..4].* = d.vb;
            stream_stride[0..4].* = d.stride;
            draw(d.prim, d.n, d.idx, null, 0, d.base);
        },
    };
    d3d.state_snap = null;
    stage_tex, vshader, pshader, stream_vb, stream_stride = saved;
}

/// D3DDevice_BeginPushBuffer(pPushBuffer)
export fn sub_000FA990() void {
    const pb = arg(0);
    sub_000FA990_gen();
    const i = pbFind(pb) orelse blk: {
        pb_recs.append(alloc, .{ .pb = pb, .base = undefined, .ops = .empty }) catch return;
        break :blk pb_recs.items.len - 1;
    };
    pb_recs.items[i].ops.clearRetainingCapacity();
    d3d.stateBlock(&pb_recs.items[i].base);
    rec_cur = i;
}

/// D3DDevice_EndPushBuffer()
export fn sub_000FAA00() void {
    sub_000FAA00_gen();
    rec_cur = null;
}

/// D3DDevice_RunPushBuffer(pPushBuffer, pFixup): the lifted body applies the
/// fixup to the pushbuffer, then the recording replays.
/// ponytail: a pushbuffer the title did not record here (loaded from disc)
/// draws nothing; decode its NV2A methods if a title uses those.
export fn sub_000FA6F0() void {
    const pb = arg(0);
    sub_000FA6F0_gen();
    if (!ready()) return;
    if (pbFind(pb)) |i| replay(&pb_recs.items[i]) else sayOnce("RunPushBuffer of a pushbuffer not recorded here skipped");
}

/// D3DDevice_BeginPush(Count) -> pointer the title writes methods to
export fn sub_000FA090() void {
    sub_000FA090_gen();
    push_start = g_eax;
}

/// D3DDevice_EndPush(pPush)
export fn sub_000FA0B0() void {
    const end = arg(0);
    if (push_start != 0 and end > push_start and end - push_start < 0x100000) decodePush(push_start, end);
    push_start = 0;
    sub_000FA0B0_gen();
}
