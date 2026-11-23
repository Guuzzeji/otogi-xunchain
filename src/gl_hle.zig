//! The game's Xbox D3D8 (XDK 5455) mapped onto GL ES 3 through ANGLE, which
//! runs it on D3D11 (default), Vulkan or desktop GL (RECOMP_GFX). Port of
//! Sneak King's gl_hle.c; the guest side is src/d3d.zig.
//!
//! D3D entry points are wrapped (seeds/manual.h). Setters run the lifted body
//! and mirror what the renderer needs; draws, Clear and the present are done
//! here. The lifted D3D still writes a pushbuffer, which nothing executes.
//!
//! Two threads. The game's runs the wrappers: they mirror state and record each
//! frame's draws and clears, with copies of everything a draw reads from guest
//! memory (Frame). The render thread owns the window and the GL context and
//! draws the recorded frames (see Render thread). The game thread calls no GL.
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
const pacer = @import("pacer.zig");
const sdl = @import("sdl");
const input = @import("input.zig");

const arg = d3d.arg;
const mem32 = d3d.mem32;

extern threadlocal var g_ecx: u32;
extern threadlocal var g_edx: u32;
extern threadlocal var g_eax: u32;

// ── Window ──────────────────────────────────────────────────────────────────
// An SDL3 window on the render thread, pumped at each shown frame. SDL is the
// window, its events and the pads (input.zig) only: ANGLE draws into the
// window's HWND, and SDL's own GL and swap calls are not used.

extern "kernel32" fn ExitProcess(u32) callconv(.winapi) noreturn;
extern fn SDL_SetMainReady() void; // SDL_main.h, which also renames main

/// RECOMP_WINDOW: 0 = a window, 1 = borderless (a window covering the
/// monitor), 2 = fullscreen (on top of everything, minimized when switched
/// away from, at RECOMP_RESOLUTION such as 1920x1080 when set). Alt+Enter
/// switches between a window and fullscreen (borderless when started windowed).
var window_mode: u8 = 0;
var full = false;
var window: ?*sdl.SDL_Window = null;

fn setFull(on: bool) void {
    full = on;
    var mode: sdl.SDL_DisplayMode = undefined;
    // No mode is borderless.
    _ = sdl.SDL_SetWindowFullscreenMode(window, if (on and window_mode == 2 and fullMode(&mode)) &mode else null);
    _ = sdl.SDL_SetWindowFullscreen(window, on);
}

/// The fullscreen mode: RECOMP_RESOLUTION=WxH, or the desktop's.
fn fullMode(mode: *sdl.SDL_DisplayMode) bool {
    const display = sdl.SDL_GetDisplayForWindow(window);
    const desk = sdl.SDL_GetDesktopDisplayMode(display) orelse return false;
    var w = desk.*.w;
    var h = desk.*.h;
    if (std.c.getenv("RECOMP_RESOLUTION")) |s| {
        var it = std.mem.tokenizeAny(u8, std.mem.span(s), "x* ");
        const rw = std.fmt.parseInt(c_int, it.next() orelse "", 10) catch 0;
        const rh = std.fmt.parseInt(c_int, it.next() orelse "", 10) catch 0;
        if (rw > 0 and rh > 0) {
            w = rw;
            h = rh;
        }
    }
    if (sdl.SDL_GetClosestFullscreenDisplayMode(display, w, h, 0, false, mode)) return true;
    std.debug.print("[GL] resolution {d}x{d} failed ({s}); borderless instead\n", .{ w, h, sdl.SDL_GetError() });
    return false;
}

/// Window, key and pad events, then the pads' state for the game (input.zig).
fn pumpEvents() void {
    var e: sdl.SDL_Event = undefined;
    while (sdl.SDL_PollEvent(&e)) {
        switch (e.type) {
            sdl.SDL_EVENT_QUIT => ExitProcess(0), // closing the window ends the game
            sdl.SDL_EVENT_KEY_DOWN => if (!e.key.repeat and e.key.scancode == sdl.SDL_SCANCODE_RETURN and e.key.mod & sdl.SDL_KMOD_ALT != 0) {
                if (window_mode == 0) window_mode = 1;
                setFull(!full);
                continue;
            },
            // Another monitor, or another mode on this one.
            sdl.SDL_EVENT_WINDOW_DISPLAY_CHANGED, sdl.SDL_EVENT_DISPLAY_CURRENT_MODE_CHANGED => frRate(),
            else => {},
        }
        if (!debug_menu.event(&e)) input.event(&e);
    }
    input.poll(debug_menu.open);
}

fn clientSize() [2]i32 {
    var sz: [2]c_int = .{ 1, 1 };
    _ = sdl.SDL_GetWindowSizeInPixels(window, &sz[0], &sz[1]);
    return sz;
}

// ── EGL and the host back buffer ───────────────────────────────────────────

/// Render scale: the back buffer is 640x480 times this. RECOMP_SCALE (1-4).
var scale: u32 = 2;

/// Widescreen (hor+) widens the back buffer to 16:9 by this factor;
/// RECOMP_WIDESCREEN=0 keeps 4:3. 3D stretches across it (manual.zig widens
/// the projection's aspect to match) and pre-transformed 2D stays 4:3 in the middle.
/// Fog start and end times this (cheats.zig; settings.ini fog_distance).
pub var fog_scale: f32 = 1;

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
    return gframe -% wide_frame <= 2;
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
/// targets drawn from one (the pause blur downsamples a copy) or with widened 3D,
/// and of copies of those: each holds the whole wide view.
var bb_copies: [8]u32 = @splat(0);
var bb_copy_next: usize = 0;
/// Frame of the last full-width back buffer copy (CopyRects).
var last_wide_copy: u32 = 0xFFFF_0000;
/// Textures made just after one (maybe screen stills, see texGet); a full-screen
/// draw of one stretches like a copy. Others made then (fonts) are left alone.
var stills: [8]u32 = @splat(0);
var still_next: usize = 0;

fn isCopy(tex: u32) bool {
    return tex != 0 and std.mem.indexOfScalar(u32, &bb_copies, d3d.resData(tex)) != null;
}

/// The offscreen target the movie (XMV) last drew a YUY2/UYVY frame into, and
/// when. The movie is 4:3: drawn to the screen it keeps its place in the middle
/// with black at the sides, as extending it only smears its edge columns (issue #9).
var movie_rt: u32 = 0;
var movie_frame: u32 = 0xFFFF_0000;

fn isYuv(xfmt: u32) bool {
    return xfmt == 0x24 or xfmt == 0x25;
}

fn isMovie(data: u32, xfmt: u32) bool {
    return isYuv(xfmt) or (data == movie_rt and gframe -% movie_frame <= 30);
}

fn addCopy(data: u32) void {
    if (std.mem.indexOfScalar(u32, &bb_copies, data) != null) return;
    bb_copies[bb_copy_next] = data;
    bb_copy_next = (bb_copy_next + 1) % bb_copies.len;
}

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
extern fn eglCreateWindowSurface(gl.EGLDisplay, gl.EGLConfig, ?*anyopaque, ?*const gl.EGLint) gl.EGLSurface;
extern fn eglSetBlobCacheFuncsANDROID(gl.EGLDisplay, *const fn (?*const anyopaque, isize, ?*const anyopaque, isize) callconv(.c) void, *const fn (?*const anyopaque, isize, ?*anyopaque, isize) callconv(.c) isize) void;

fn hasExt(name: []const u8) bool {
    var n: gl.GLint = 0;
    gl.glGetIntegerv(gl.GL_NUM_EXTENSIONS, &n);
    for (0..@intCast(n)) |i| {
        if (std.mem.eql(u8, std.mem.span(gl.glGetStringi(gl.GL_EXTENSIONS, @intCast(i))), name)) return true;
    }
    return false;
}

/// The render thread, started on first use; false when it could not get a context.
fn ready() bool {
    if (state == .none) {
        const t = std.Thread.spawn(.{}, renderThread, .{}) catch return false;
        t.detach();
        game_tid = GetCurrentThreadId();
        game_thread = OpenThread(0x0800, 0, game_tid); // THREAD_QUERY_LIMITED_INFORMATION
        lock();
        while (state == .none) wait(0xFFFFFFFF);
        unlock();
    }
    return state == .ready;
}

/// The game's thread, for the debug menu's CPU readout.
pub var game_thread: ?*anyopaque = null;
var game_tid: u32 = 0;
extern "kernel32" fn OpenThread(access: u32, inherit: i32, id: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;

// ── Shader cache on disk ────────────────────────────────────────────────────
// ANGLE hands over every compiled program as a blob (EGL_ANDROID_blob_cache)
// and asks for it back by key in later runs, so a shader is compiled once per
// machine, not once per run. One file per blob in shader_cache\, beside
// otogi.exe. The key covers the driver and backend: after an update the old
// files are just never asked for.
// The callbacks run on whichever thread ANGLE compiles on.

extern "c" fn fopen([*:0]const u8, [*:0]const u8) ?*anyopaque;
extern "c" fn fclose(*anyopaque) c_int;
extern "c" fn fread(*anyopaque, usize, usize, *anyopaque) usize;
extern "c" fn fwrite(*const anyopaque, usize, usize, *anyopaque) usize;
extern "c" fn rename([*:0]const u8, [*:0]const u8) c_int;
extern "c" fn remove([*:0]const u8) c_int;
extern "c" fn _mkdir([*:0]const u8) c_int;

var blob_hits: std.atomic.Value(u32) = .init(0);
var blob_stores: std.atomic.Value(u32) = .init(0);


fn blobPath(buf: *[96]u8, key: ?*const anyopaque, n: isize, ext: []const u8) ?[*:0]const u8 {
    if (key == null or n <= 0 or n > 32) return null;
    const k: [*]const u8 = @ptrCast(key.?);
    return (std.fmt.bufPrintSentinel(buf, "shader_cache\\{x}{s}", .{ k[0..@intCast(n)], ext }, 0) catch return null).ptr;
}

fn blobSet(key: ?*const anyopaque, key_n: isize, value: ?*const anyopaque, n: isize) callconv(.c) void {
    var a: [96]u8 = undefined;
    var b: [96]u8 = undefined;
    var ext: [24]u8 = undefined;
    const path = blobPath(&a, key, key_n, ".bin") orelse return;
    if (value == null or n <= 0) return;
    // Written whole under another name first: a crash mid-write leaves no
    // half blob under the real one.
    const tmp = blobPath(&b, key, key_n, std.fmt.bufPrint(&ext, ".{d}.tmp", .{GetCurrentThreadId()}) catch return) orelse return;
    const f = fopen(tmp, "wb") orelse return sayShader("cannot write into shader_cache (read-only folder or full disk?); programs are compiled again next run");
    const ok = fwrite(value.?, 1, @intCast(n), f) == n;
    _ = fclose(f);
    _ = remove(path);
    if (!ok or rename(tmp, path) != 0) {
        _ = remove(tmp);
        sayShader("cannot write into shader_cache (read-only folder or full disk?); programs are compiled again next run");
    } else _ = blob_stores.fetchAdd(1, .monotonic);
}

/// The blob's size, or 0 when there is none; filled in only when it fits.
fn blobGet(key: ?*const anyopaque, key_n: isize, value: ?*anyopaque, n: isize) callconv(.c) isize {
    var a: [96]u8 = undefined;
    const f = fopen(blobPath(&a, key, key_n, ".bin") orelse return 0, "rb") orelse return 0;
    defer _ = fclose(f);
    var size: usize = 0;
    var chunk: [4096]u8 = undefined;
    const room: usize = if (value != null and n > 0) @intCast(n) else 0;
    const out: [*]u8 = if (value) |v| @ptrCast(v) else &chunk;
    while (true) {
        const got = fread(&chunk, 1, chunk.len, f);
        if (got == 0) break;
        if (size + got <= room) @memcpy(out[size..][0..got], chunk[0..got]);
        size += got;
    }
    if (size != 0 and size <= room) _ = blob_hits.fetchAdd(1, .monotonic);
    return @intCast(size);
}

/// RECOMP_SHADER_CACHE=0 turns it off.
fn sayShader(comptime msg: []const u8) void {
    const s = struct {
        var said = false; // once each: a write that fails does so for every blob
    };
    if (!s.said) std.debug.print("[SHADER] " ++ msg ++ "\n", .{});
    s.said = true;
}

fn blobInit() void {
    if (std.c.getenv("RECOMP_SHADER_CACHE")) |e| if (e[0] == '0') return sayShader("disk cache off (RECOMP_SHADER_CACHE=0): every program is compiled again each run");
    const exts: ?[*:0]const u8 = gl.eglQueryString(dpy, gl.EGL_EXTENSIONS);
    if (exts == null or std.mem.indexOf(u8, std.mem.span(exts.?), "EGL_ANDROID_blob_cache") == null)
        return sayShader("no disk cache: this graphics backend has no EGL_ANDROID_blob_cache; every program is compiled again each run");
    _ = _mkdir("shader_cache");
    eglSetBlobCacheFuncsANDROID(dpy, blobSet, blobGet);
    sayShader("disk cache on, in shader_cache beside the game");
}

/// Window, context and back buffer. RECOMP_GFX=d3d11 (default), vulkan or gl.
fn glInit() bool {
    if (std.c.getenv("RECOMP_SCALE")) |s| scale = std.math.clamp(std.fmt.parseInt(u32, std.mem.span(s), 10) catch 2, 1, 4);
    // ponytail: SDL lives on this thread, not the process's first. Fine on
    // Windows; macOS wants its windows on the main thread, so a port moves
    // the game to a thread of its own instead.
    SDL_SetMainReady();
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_GAMEPAD)) {
        std.debug.print("[GL] SDL_Init failed: {s}\n", .{sdl.SDL_GetError()});
        return false;
    }
    window = sdl.SDL_CreateWindow("Otogi: Myth of Demons", @intCast(bbw() * scale), @intCast(480 * scale), sdl.SDL_WINDOW_RESIZABLE) orelse return false;
    const hwnd = sdl.SDL_GetPointerProperty(sdl.SDL_GetWindowProperties(window), sdl.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null);
    if (std.c.getenv("RECOMP_WINDOW")) |m| window_mode = std.math.clamp(m[0] -| '0', 0, 2);
    if (window_mode != 0) setFull(true);

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
    blobInit();
    shader_record = std.c.getenv("RECOMP_SHADER_RECORD") != null;
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
    warm();
    return true;
}

// ── Textures: everything but DXT becomes RGBA8 on the CPU ──────────────────

pub var renderer_name: [*:0]const u8 = "";

/// Per game frame counts for the debug menu: `stats` fills on the game thread
/// during a frame and travels with it; `last` is the frame last presented.
/// work_ms: one Swap's return to the next one's entry (game code and draw()).
/// draw_ms: the part of it inside draw(), recording. queued: the game's two draw
/// queues (objects that passed its frustum test, 0x1E69A8/AC) as of Swap.
/// uploads, mesh_hits, mesh_new and merged are the render thread's (rstats).
pub const Stats = struct { draws: u32 = 0, clears: u32 = 0, copies: u32 = 0, uploads: u32 = 0, work_ms: f32 = 0, draw_ms: f32 = 0, mesh_hits: u32 = 0, mesh_new: u32 = 0, merged: u32 = 0, render_ms: f32 = 0, sync_ms: f32 = 0, queued: [2]u32 = .{ 0, 0 } };
var stats: Stats = .{};
var rstats: Stats = .{};
pub var last: Stats = .{};

pub fn cacheSizes() struct { textures: usize, programs: usize, vertex_programs: usize, pixel_shaders: usize, targets: usize, pushbuffers: usize, meshes: usize } {
    return .{ .textures = textures.items.len, .programs = progs.items.len, .vertex_programs = programs.items.len, .pixel_shaders = pixel_shaders.items.len, .targets = rt_keys.items.len, .pushbuffers = pb_recs.items.len, .meshes = meshes.count() };
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

/// A guest texture the game thread has seen: `hash` is of the bytes the render
/// thread was last sent, `checked` the game frame they were hashed in.
const HostTex = struct { hash: u32, checked: u32 };
var textures: std.ArrayList(HostTex) = .empty;
var tex_index: std.AutoHashMapUnmanaged([3]u32, u32) = .empty; // data, format, size -> index into textures
/// The render thread's texture for each of `textures`, and the ones replaced
/// while the frame being shown may still draw them.
var tex_gl: std.ArrayList(gl.GLuint) = .empty;
var tex_dead: std.ArrayList(gl.GLuint) = .empty;

/// What a draw samples on one stage, resolved when the draw is recorded.
const TexRef = struct {
    id: u32 = 0, // 0 none, or 1 + index into textures (rt: into the render targets)
    rt: bool = false,
    cube: bool = false,
    copy: bool = false, // holds the whole wide view (isCopy)
    still: bool = false, // maybe a screen still (stills)
    movie: bool = false, // a video frame (isMovie): stays 4:3
    fmt: u8 = 0,
    lin: [2]f32 = .{ 0, 0 }, // texel size of a linear texture, whose coordinates the title gives in texels
    gl: gl.GLuint = 0, // the render thread's, once it has the frame (frameResolve)
};

/// Work for the render thread before it draws the frame that carries it: a
/// texture's bytes, copied when their hash changed, or a new render target.
const Upload = union(enum) {
    tex: struct { id: u32, f: d3d.Fmt, format: u32, w: u32, h: u32, pitch: u32, cube: bool, bytes: []u8 },
    rt: struct { w: u32, h: u32 },
};

fn texLevels(f: d3d.Fmt, format: u32) u32 {
    const levels: u32 = if (f.swizzled or d3d.isDxt(f)) (format >> 16) & 0xF else 1;
    return @max(levels, 1);
}

/// Bytes texCreate reads.
fn texBytes(f: d3d.Fmt, format: u32, w: u32, h: u32, pitch: u32, cube: bool) u32 {
    var face: u32 = 0;
    var lw = w;
    var lh = h;
    for (0..texLevels(f, format)) |_| {
        face += d3d.levelBytes(f, lw, lh);
        lw = @max(lw / 2, 1);
        lh = @max(lh / 2, 1);
    }
    return @max(if (cube) 5 * ((face + 127) & ~@as(u32, 127)) + face else face, pitch * h);
}

fn texCreate(f: d3d.Fmt, data: [*]const u8, format: u32, w: u32, h: u32, pitch: u32, pal: ?[*]align(1) const u32, cube: bool) gl.GLuint {
    const levels = texLevels(f, format);
    if (d3d.isDxt(f) and !s3tc) return 0;
    const bind: gl.GLenum = if (cube) gl.GL_TEXTURE_CUBE_MAP else gl.GL_TEXTURE_2D;
    var src = data;
    var t: gl.GLuint = 0;
    rstats.uploads += 1;
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

/// What a draw samples from a guest texture (game thread). Its bytes are
/// hashed once a game frame and copied for the render thread when they changed.
fn texRef(res: u32) TexRef {
    if (res == 0) return .{};
    const data = d3d.resData(res);
    const format = mem32(res + 0xC);
    const size = mem32(res + 0x10);
    const dims = d3d.surfDims(res);
    const xfmt = (format >> 8) & 0xFF;
    var r: TexRef = .{ .cube = (format >> 2) & 1 != 0, .fmt = @truncate(xfmt), .copy = isCopy(res), .movie = isMovie(data, xfmt) };
    if (data == d3d.resData(backBuffer())) return .{}; // ponytail: sampling the back buffer is not done
    for (rt_keys.items, 1..) |k, i| if (k.data == data and !k.locked) {
        if (size != 0) r.lin = .{ @floatFromInt(dims.w), @floatFromInt(dims.h) }; // linear: texel coordinates
        r.id = @intCast(i);
        r.rt = true;
        return r;
    };
    const f = d3d.fmtFind(xfmt) orelse {
        const said = struct {
            var mask: u64 = 0;
        };
        if (said.mask & (@as(u64, 1) << @intCast(xfmt & 63)) == 0) std.debug.print("[GL] texture format 0x{X:0>2} not handled\n", .{xfmt});
        said.mask |= @as(u64, 1) << @intCast(xfmt & 63);
        return .{};
    };
    if (d3d.isDxt(f) and !s3tc) return .{};
    // ponytail: palettes (P8) read as white; mirror SetPalette when a title uses them.
    // Otogi has none: its 3219 DDS textures on the disc are DXT1/3/5 and A8R8G8B8.
    if (f.kind == .p8) sayOnce("paletted (P8) texture drawn white");
    if (!f.swizzled and !d3d.isDxt(f)) r.lin = .{ @floatFromInt(dims.w), @floatFromInt(dims.h) };
    const slot = tex_index.getOrPut(alloc, .{ data, format, size }) catch return .{};
    if (!slot.found_existing) {
        slot.value_ptr.* = @intCast(textures.items.len);
        textures.append(alloc, .{ .hash = 0, .checked = gframe -% 1 }) catch @panic("OOM");
    }
    const e = &textures.items[slot.value_ptr.*];
    r.id = slot.value_ptr.* + 1;
    changed: {
        if (e.checked == gframe) break :changed;
        e.checked = gframe;
        const bytes = if (dims.pitch != 0) dims.pitch * dims.h else d3d.levelBytes(f, dims.w, dims.h);
        const hash = d3d.hashBytes(d3d.ptr(data), bytes);
        if (slot.found_existing and e.hash == hash) break :changed;
        e.hash = hash;
        // The game-over and pause menus keep a still of the screen: the title reads a
        // full-width copy back and compresses it into a screen-sized texture itself.
        // It holds the whole wide buffer like any copy, so drawn full screen it stretches.
        if (dims.w >= 640 and dims.h >= 480 and gframe -% last_wide_copy <= 60) {
            stills[still_next] = data;
            still_next = (still_next + 1) % stills.len;
        }
        const all = alloc.dupe(u8, d3d.ptr(data)[0..texBytes(f, format, dims.w, dims.h, dims.pitch, r.cube)]) catch @panic("OOM");
        build.uploads.append(alloc, .{ .tex = .{ .id = r.id, .f = f, .format = format, .w = dims.w, .h = dims.h, .pitch = dims.pitch, .cube = r.cube, .bytes = all } }) catch @panic("OOM");
    }
    r.still = std.mem.indexOfScalar(u32, &stills, data) != null;
    return r;
}

/// The render thread's side of a frame's uploads, run before it draws any of it.
fn runUploads(f: *Frame) void {
    for (f.uploads.items) |u| switch (u) {
        .tex => |t| {
            if (tex_gl.items.len < t.id) tex_gl.appendNTimes(alloc, 0, t.id - tex_gl.items.len) catch @panic("OOM");
            const name = &tex_gl.items[t.id - 1];
            if (name.* != 0) tex_dead.append(alloc, name.*) catch @panic("OOM");
            name.* = texCreate(t.f, t.bytes.ptr, t.format, t.w, t.h, t.pitch, null, t.cube);
            alloc.free(t.bytes);
        },
        .rt => |t| rtCreate(t.w, t.h),
    };
    f.uploads.clearRetainingCapacity();
}

/// GL names for the textures of `f`'s draws up to `to`, after runUploads.
fn frameResolve(f: *Frame, to: usize) void {
    for (f.ops.items[f.resolved..to]) |*op| switch (op.*) {
        .draw => |*d| for (&d.tex) |*r| {
            if (r.id != 0) r.gl = if (r.rt) rts.items[r.id - 1].tex else tex_gl.items[r.id - 1];
        },
        .clear, .copy => {},
    };
    f.resolved = to;
}

// ── Mirrored state ──────────────────────────────────────────────────────────

// The game thread mirrors the device here. The threadlocal ones the render
// thread has too: each draw it replays sets them to what the draw recorded.
var stage_tex: [4]u32 = @splat(0);
threadlocal var vshader: u32 = 0; // FVF, or a program handle (odd)
var pshader: u32 = 0;
var stream_vb: [16]u32 = @splat(0);
threadlocal var stream_stride: [16]u32 = @splat(0);
/// Copies of the streams of the recorded draw (pointing where vertex 0 would be).
var stream_host: [16]?[*]const u8 = @splat(null);
var base_vertex: u32 = 0;
threadlocal var xf: [10][16]f32 = @splat(identity); // view, proj, tex0-3, world0-3
const Viewport = struct { x: u32 = 0, y: u32 = 0, w: u32 = 640, h: u32 = 480 };
threadlocal var vp: Viewport = .{};
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

/// A vertex program, by content: handles that carry the same declaration and
/// microcode share one, and it stays for the run (a Key names it by index).
const HostVs = struct {
    decl: [96]u32,
    mc: [136 * 4]u32,
    nmc: usize,
    inputs: u16 = 0,
    uses_vp: bool = false,
    hash: u32 = 0, // of the microcode: names a program across runs
    func: u32 = 0, // where the game keeps it, for the shader list (see Rec)
    decl_va: u32 = 0,
    glsl: ?[]u8 = null,
};
// ponytail: fixed tables, so the render thread reads entries while the game
// thread adds more. Otogi makes a few dozen of each; grow them under the lock
// if a title fills one.
var programs_buf: [1024]HostVs = undefined;
var programs: std.ArrayList(HostVs) = .initBuffer(&programs_buf);
var vs_handles: std.AutoHashMapUnmanaged(u32, u32) = .empty; // handle -> index + 1
threadlocal var vsc: [192][4]f32 = @splat(.{ 0, 0, 0, 0 });

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
    u_flow: gl.GLint = -1,
    // The uniform values last set, in uploadUniforms' order: ANGLE uploads a
    // program's whole constant buffer at the next draw after any glUniform call.
    shadow: ?*[1024]f32 = null,
    fresh: bool = true, // shadow is not what the program holds
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
            \\
        );
        // The waterfall's layer mesh runs v 0 (top edge) down; genFs fades it in from there.
        if (k.fog == 2) try w.writeAll(if (h.inputs & 8 != 0) "  v_eyez = v3.y;\n" else "  v_eyez = 1.0;\n");
        try w.writeAll("}\n");
        return;
    }
    try w.writeAll("uniform mat4 u_wv, u_proj, u_texm[4];\nuniform vec4 u_rhw;\nin vec4 a_pos;\n");
    if (k.diffuse != 0) try w.writeAll("in vec4 a_diffuse;\n");
    if (k.specular != 0) try w.writeAll("in vec4 a_specular;\n");
    for (0..k.ntc) |i| try w.print("in vec4 a_tc{d};\n", .{i});
    try w.writeAll("void main() {\n");
    try w.print("  vec4 dif_in = {s}, spe_in = {s};\n", .{ if (k.diffuse != 0) "a_diffuse.zyxw" else "vec4(1.0)", if (k.specular != 0) "a_specular.zyxw" else "vec4(0.0)" });
    if (k.rhw != 0) {
        // Pre-transformed: guest pixels (centres on integers) to clip space. The
        // half-pixel shift is half a guest pixel at 1x; scaled up it is half a host
        // pixel, or a quad from x/y 0 (letterbox bars, menu frames) misses the
        // first row and column and shows a line of the scene at the screen edge.
        try w.print(
            \\  float w = a_pos.w != 0.0 ? 1.0 / a_pos.w : 1.0;
            \\  vec2 ndc = (a_pos.xy + {d} - u_rhw.xy) / u_rhw.zw * 2.0 - 1.0;
            \\  gl_Position = vec4(ndc * w, (2.0 * a_pos.z - 1.0) * w, w);
            \\  v_eyez = w;
            \\
        , .{0.5 / @as(f32, @floatFromInt(scale))});
    } else {
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
    try w.writeAll("uniform vec4 u_tf, u_fog, u_fogcolor, u_tscale[4];\nuniform vec2 u_flow;\nuniform float u_aref;\n");
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
        // ponytail: Tower of Water's waterfall (fog 2, see prepareDraw) is our own shader, tuned by
        // eye against Xbox footage, not the game's maths (additive layers fogged to a light colour
        // stack to flat white). v_eyez is the strip's v, 0 at its top edge, 1 at the bottom. Two
        // layers of the ripple texture flow down (u_flow), stretched as falling water speeds up
        // (a power of the drop); whole-number u scales keep the wrap round the tower seamless, and
        // whole-number flow scales the wrap of u_flow. Pure white: solid at the top but for the
        // texture's dark grain, thinning to fine soft streaks and mist lower down. The fade-in at
        // the top edge is short, so a strip meets the solid white above it without a band.
        try w.writeAll(if (k.fog == 2)
            "  vec3 L = vec3(0.299, 0.587, 0.114);\n" ++
            "  float fall = pow(max(v_eyez, 0.0), 0.7);\n" ++
            "  vec2 uv1 = vec2(v_t0.x * 2.0, (fall - u_flow.x) * 3.0);\n" ++
            "  vec2 uv2 = vec2(v_t0.x * 3.0 + 0.31, fall * 2.6 - u_flow.y * 3.0 + 0.47);\n" ++
            "  float lum = 0.5 * (dot(texture(u_tex0, uv1).rgb, L) + dot(texture(u_tex0, uv2).rgb, L));\n" ++
            "  float edge = smoothstep(0.0, 0.05, v_eyez) * (1.0 - smoothstep(0.5, 1.0, v_eyez));\n" ++
            "  float st = smoothstep(0.05, 0.7, v_eyez);\n" ++
            "  float a = smoothstep(mix(-0.3, 0.15, st), mix(0.45, 0.95, st), lum) * edge;\n" ++
            "  cur = vec4(a);\n"
        else
            "  cur.rgb = mix(u_fogcolor.rgb, cur.rgb, clamp(f, 0.0, 1.0));\n");
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
const HostPs = struct { def: [PsDef.words]u32, va: u32 = 0 };
var pixel_shaders_buf: [1024]HostPs = undefined;
var pixel_shaders: std.ArrayList(HostPs) = .initBuffer(&pixel_shaders_buf);
var ps_handles: std.AutoHashMapUnmanaged(u32, u32) = .empty; // handle -> index + 1

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
/// RECOMP_SHADER_RECORD: add every program the shader list lacks to it (see Rec).
var shader_record = false;

fn progGet(k: *const Key) ?*Prog {
    // Most draws use the program of the draw before.
    const S = struct {
        var last: usize = 0;
    };
    for (0..progs.items.len + 1) |n| {
        const i = if (n == 0) S.last else n - 1;
        if (i >= progs.items.len) continue;
        const p = &progs.items[i];
        if (!std.mem.eql(u8, std.mem.asBytes(&p.key), std.mem.asBytes(k))) continue;
        S.last = i;
        return if (p.prog != 0) p else null;
    }
    const p = progs.addOne(alloc) catch return null;
    p.* = .{ .key = k.*, .prog = 0, .shadow = alloc.create([1024]f32) catch null };
    if (shader_record and !warming) recAppend(k);
    // One [SHADER] line for every program built, for bug reports: when, how
    // long, and whether the disk cache had it.
    const t0 = nowMs();
    const hits = blob_hits.load(.monotonic);
    const id = .{ progs.items.len, if (k.vs != 0) programs.items[k.vs - 1].hash else 0, if (k.ps != 0) psHash(&pixel_shaders.items[k.ps - 1]) else 0 };
    progBuild(p, k) catch {
        std.debug.print("[SHADER] program {d} (vs {X:0>8} ps {X:0>8}) failed to build; what it draws is missing\n", id);
        return null;
    };
    std.debug.print("[SHADER] program {d} (vs {X:0>8} ps {X:0>8}) {s}: {d:.1} ms, {s}\n", id ++ .{
        if (warming) "at start-up" else "while playing, not on the list",
        nowMs() - t0,
        if (blob_hits.load(.monotonic) != hits) "from the disk cache" else "compiled",
    });
    return p;
}

fn progBuild(p: *Prog, k: *const Key) !void {
    var w: std.Io.Writer = .fixed(&src_buf);
    try genVs(k, &w);
    if (std.c.getenv("RECOMP_GL_DUMP") != null and k.vs != 0) std.debug.print("[GL] program {d}, vertex shader {X}:\n{s}\n", .{ progs.items.len, programs.items[k.vs - 1].hash, w.buffered() });
    const vs = compile(gl.GL_VERTEX_SHADER, w.buffered());
    w = .fixed(&src_buf);
    try genFs(k, &w);
    if (std.c.getenv("RECOMP_GL_DUMP") != null and k.ps != 0) std.debug.print("[GL] program {d}, pixel shader {d}:\n{s}\n", .{ progs.items.len, k.ps, w.buffered() });
    const fs = compile(gl.GL_FRAGMENT_SHADER, w.buffered());
    if (vs == 0 or fs == 0) return error.Compile;
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
        return error.Link;
    }
    p.prog = prog;
    inline for (.{ "u_wv", "u_proj", "u_texm", "u_rhw", "u_fog", "u_fogcolor", "u_tf", "u_aref", "u_tscale", "u_c", "u_psc", "u_psf", "u_bump", "u_flow" }) |u|
        @field(p, u) = gl.glGetUniformLocation(prog, u);
    gl.glUseProgram(prog);
    for (0..4) |i| gl.glUniform1i(gl.glGetUniformLocation(prog, (std.fmt.bufPrintSentinel(&name, "u_tex{d}", .{i}, 0) catch unreachable).ptr), @intCast(i));
}

// ── The shader list: every program, built at start-up ──────────────────────

/// One program of src/shaders.bin: its Key, with the run's shader indexes
/// swapped for where the game keeps each shader and a hash of it. Otogi makes
/// all its shaders at start-up from fixed places in its image (0x1C01C0 to
/// 0x1D48A0), so the list holds addresses and render states, no game data.
/// The hash skips a program on a disc whose image differs.
const Rec = extern struct {
    key: Key, // vs and ps: 1 when it has one
    vs_func: u32 = 0,
    vs_decl: u32 = 0,
    vs_hash: u32 = 0,
    ps_def: u32 = 0,
    ps_hash: u32 = 0,
};
comptime {
    // Key changed: the list no longer matches. Empty src/shaders.bin and record it again.
    std.debug.assert(@sizeOf(Rec) == 100);
}
const list_path = "src/shaders.bin";
var warming = false;

/// The list is ours, but a bad address must not fault: guest RAM is 64 MB, all readable.
fn inGuest(va: u32) bool {
    return va >= 0x10000 and va < 0x04000000 - 0x1000;
}

fn psHash(p: *const HostPs) u32 {
    return d3d.hashBytes(@ptrCast(&p.def), PsDef.words * 4);
}

/// RECOMP_SHADER_RECORD, run from the repo: a program the list lacks is added to it.
fn recAppend(k: *const Key) void {
    var r: Rec = .{ .key = k.* };
    if (k.vs != 0) {
        const v = &programs.items[k.vs - 1];
        r.key.vs = 1;
        r.vs_func = v.func;
        r.vs_decl = v.decl_va;
        r.vs_hash = v.hash;
    }
    if (k.ps != 0) {
        const p = &pixel_shaders.items[k.ps - 1];
        r.key.ps = 1;
        r.ps_def = p.va;
        r.ps_hash = psHash(p);
    }
    const f = fopen(list_path, "ab") orelse return sayOnce("cannot write " ++ list_path);
    _ = fwrite(&r, 1, @sizeOf(Rec), f);
    _ = fclose(f);
}

/// The record's Key in this run, registering its shaders as the game would;
/// null when the game's image does not hold them.
fn recKey(r: *const Rec) ?Key {
    var k = r.key;
    if (k.vs != 0) {
        if (!inGuest(r.vs_func) or (r.vs_decl != 0 and !inGuest(r.vs_decl))) return recSkip("vertex program", r.vs_func, 0, r.vs_hash);
        k.vs = vsAdd(r.vs_decl, r.vs_func);
        if (k.vs == 0) return null;
        const h = programs.items[k.vs - 1].hash;
        if (h != r.vs_hash) return recSkip("vertex program", r.vs_func, h, r.vs_hash);
        vsGlsl(&programs.items[k.vs - 1]) catch return null;
    }
    if (k.ps != 0) {
        if (!inGuest(r.ps_def)) return recSkip("pixel shader", r.ps_def, 0, r.ps_hash);
        k.ps = psAdd(r.ps_def);
        if (k.ps == 0) return null;
        const h = psHash(&pixel_shaders.items[k.ps - 1]);
        if (h != r.ps_hash) return recSkip("pixel shader", r.ps_def, h, r.ps_hash);
    }
    return k;
}

fn recSkip(what: []const u8, va: u32, have: u32, want: u32) ?Key {
    std.debug.print("[SHADER] list entry skipped: the {s} at 0x{X:0>8} is {X:0>8}, the list has {X:0>8} (another version of the game?)\n", .{ what, va, have, want });
    return null;
}

/// Build every listed program before the game starts, behind a progress bar,
/// so none is compiled mid-game. With the disk cache full this takes a moment;
/// with it empty (first run, new driver) it is the wait. A program the list
/// lacks is still built when first drawn.
fn warm() void {
    var list: []const u8 = @embedFile("shaders.bin");
    if (shader_record) {
        if (fopen(list_path, "rb")) |f| {
            const buf = alloc.alloc(u8, 1 << 20) catch return;
            list = buf[0..fread(buf.ptr, 1, buf.len, f)];
            _ = fclose(f);
        }
    }
    const n = list.len / @sizeOf(Rec);
    if (n == 0) return;
    const t0 = nowMs();
    var shown_at = t0;
    var built: usize = 0;
    warming = true;
    for (0..n) |i| {
        var r: Rec = undefined;
        @memcpy(std.mem.asBytes(&r), list[i * @sizeOf(Rec) ..][0..@sizeOf(Rec)]);
        if (recKey(&r)) |k| {
            if (progGet(&k) != null) built += 1;
        }
        // The bar, when there is a wait to show: a swap waits for the monitor.
        if (nowMs() - shown_at < 50) continue;
        shown_at = nowMs();
        const sz = clientSize();
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
        gl.glClearColor(0, 0, 0, 1);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        gl.glEnable(gl.GL_SCISSOR_TEST);
        const w = @divTrunc(sz[0], 2);
        gl.glScissor(@divTrunc(sz[0], 4), @divTrunc(sz[1], 2) - 4, @intCast(@divTrunc(w * @as(i32, @intCast(i + 1)), @as(i32, @intCast(n)))), 8);
        gl.glClearColor(0.8, 0.8, 0.8, 1);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        gl.glDisable(gl.GL_SCISSOR_TEST);
        _ = gl.eglSwapBuffers(dpy, surf);
        pumpEvents();
    }
    warming = false;
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, fbo);
    std.debug.print("[SHADER] start-up: {d} of {d} listed programs ready in {d:.0} ms; disk cache gave {d} blobs and took {d} new ones\n", .{ built, n, nowMs() - t0, blob_hits.load(.monotonic), blob_stores.load(.monotonic) });
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
    return S.on.? and fr_d.vsi != 0 and programs.items[fr_d.vsi - 1].hash == 0xA8A1DBCD;
}

fn applyRenderState() void {
    const rs = d3d.rs;
    setCap(gl.GL_DEPTH_TEST, rs(.zenable) != 0 or mistDepth());
    const cull = rs(.cullmode);
    const cw = rs(.colorwriteenable);
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
    const S = struct {
        var set: [4][7]u32 = @splat(@splat(0xFFFFFFFF));
    };
    for (0..4) |st| {
        const s: u32 = @intCast(st);
        // A stage with no texture is not sampled (genFs): its unit and sampler stay as they are.
        const r = &fr_d.tex[st];
        const t = r.gl;
        const cube = r.cube;
        lin[st] = if (t != 0) r.lin else .{ 0, 0 };
        k.tex[st] = if (t == 0) 0 else if (cube) 2 else 1;
        if (t != 0) {
            gl.glActiveTexture(@as(gl.GLenum, gl.GL_TEXTURE0) + s);
            gl.glBindTexture(if (cube) gl.GL_TEXTURE_CUBE_MAP else gl.GL_TEXTURE_2D, t);
            const smp = samplers[st];
            gl.glBindSampler(s, smp);
            const mag = tss(s, .magfilter);
            const min = tss(s, .minfilter);
            const mip = tss(s, .mipfilter);
            // Only this writes the samplers, so values equal to the last ones set are skipped:
            // most draws change none, and a changed sampler costs again at the draw.
            const sv = [7]u32{ tss(s, .addressu), tss(s, .addressv), tss(s, .addressw), mag, min, mip, tss(s, .maxmiplevel) };
            if (!std.mem.eql(u32, &sv, &S.set[st])) {
                S.set[st] = sv;
                gl.glSamplerParameteri(smp, gl.GL_TEXTURE_WRAP_S, glWrap(sv[0]));
                gl.glSamplerParameteri(smp, gl.GL_TEXTURE_WRAP_T, glWrap(sv[1]));
                gl.glSamplerParameteri(smp, gl.GL_TEXTURE_WRAP_R, glWrap(sv[2]));
                gl.glSamplerParameteri(smp, gl.GL_TEXTURE_MAG_FILTER, if (mag == 1) gl.GL_NEAREST else gl.GL_LINEAR);
                gl.glSamplerParameteri(smp, gl.GL_TEXTURE_MIN_FILTER, switch (mip) {
                    0 => if (min == 1) gl.GL_NEAREST else gl.GL_LINEAR,
                    1 => if (min == 1) gl.GL_NEAREST_MIPMAP_NEAREST else gl.GL_LINEAR_MIPMAP_NEAREST,
                    else => if (min == 1) gl.GL_NEAREST_MIPMAP_LINEAR else gl.GL_LINEAR_MIPMAP_LINEAR,
                });
                gl.glSamplerParameterf(smp, gl.GL_TEXTURE_MIN_LOD, @floatFromInt(sv[6]));
            }
        }
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
fn uploadTscale(p: *Prog, shadowed: bool) void {
    if (p.u_tscale < 0) return;
    var v: [4][4]f32 = undefined;
    for (0..4) |i| {
        v[i] = .{ if (lin[i][0] != 0) 1 / lin[i][0] else 1, if (lin[i][1] != 0) 1 / lin[i][1] else 1, 0, 0 };
        if (target_fbo == fbo and !draw_stretch and fr_d.tex[i].copy) {
            const bw: f32 = @floatFromInt(bbw());
            v[i][0] *= 640 / bw;
            v[i][2] = @as(f32, @floatFromInt((bbw() - 640) / 2)) / bw;
        }
    }
    if (!shadowed or uniNew(p, @as(*const [16]f32, @ptrCast(&v)))) gl.glUniform4fv(p.u_tscale, 4, @ptrCast(&v));
    if (!shadowed) p.fresh = true;
}

/// True if `v`, the next uniform in uploadUniforms' order, differs from what
/// the program holds; the shadow then takes it.
fn uniNew(p: *Prog, v: []const f32) bool {
    const s = p.shadow orelse return true;
    const old = s[uni_at..][0..v.len];
    uni_at += v.len;
    if (!p.fresh and std.mem.eql(u8, std.mem.sliceAsBytes(old), std.mem.sliceAsBytes(v))) return false;
    @memcpy(old, v);
    return true;
}
var uni_at: usize = 0;

fn uploadUniforms(p: *Prog) void {
    const rs = d3d.rs;
    uni_at = 0;
    defer p.fresh = false;
    if (p.u_wv >= 0) {
        const m = matMul(xf[6], xf[0]); // world0 * view
        if (uniNew(p, &m)) gl.glUniformMatrix4fv(p.u_wv, 1, gl.GL_FALSE, &m);
    }
    if (p.u_proj >= 0) {
        // A quad exactly on the far plane with ZFUNC LESS against depth cleared to
        // 1.0 survives the NV2A's integer depth; scale z a hair under 1 for float depth.
        var pr = xf[1];
        const kz: f32 = 1.0 - 1.0 / 4194304.0;
        for ([_]usize{ 2, 6, 10, 14 }) |i| pr[i] *= kz;
        if (uniNew(p, &pr)) gl.glUniformMatrix4fv(p.u_proj, 1, gl.GL_FALSE, &pr);
    }
    if (p.u_texm >= 0 and uniNew(p, @as(*const [64]f32, @ptrCast(&xf[2])))) gl.glUniformMatrix4fv(p.u_texm, 4, gl.GL_FALSE, @ptrCast(&xf[2]));
    if (p.u_rhw >= 0) {
        const v = [4]f32{ @floatFromInt(vp.x), @floatFromInt(vp.y), @floatFromInt(@max(vp.w, 1)), @floatFromInt(@max(vp.h, 1)) };
        if (uniNew(p, &v)) gl.glUniform4fv(p.u_rhw, 1, &v);
    }
    if (p.u_fog >= 0) {
        const v = [4]f32{ @floatFromInt(rs(.fogtablemode)), @bitCast(rs(.fogstart)), @bitCast(rs(.fogend)), @bitCast(rs(.fogdensity)) };
        if (uniNew(p, &v)) gl.glUniform4fv(p.u_fog, 1, &v);
    }
    if (p.u_fogcolor >= 0) {
        const v = argbVec(rs(.fogcolor));
        if (uniNew(p, &v)) gl.glUniform4fv(p.u_fogcolor, 1, &v);
    }
    if (p.u_flow >= 0) {
        // The waterfall's flow (genFs): game frames at 30 a second, 0.35 texture lengths a second,
        // wrapped here in f64 so the phase never jumps (the game's own scroll wraps at 1). fr_t
        // is the part of a game frame an in-between frame is at, so it flows on those too.
        const t = (@as(f64, @floatFromInt(frame)) + fr_t) / 30.0 * 0.35;
        const v = [2]f32{ @floatCast(@mod(t, 1.0)), @floatCast(@mod(t * 0.73, 1.0)) };
        if (uniNew(p, &v)) gl.glUniform2fv(p.u_flow, 1, &v);
    }
    if (p.u_tf >= 0) {
        const v = argbVec(rs(.texturefactor));
        if (uniNew(p, &v)) gl.glUniform4fv(p.u_tf, 1, &v);
    }
    if (p.u_aref >= 0) {
        const v = [1]f32{@floatFromInt(rs(.alpharef) & 0xFF)};
        if (uniNew(p, &v)) gl.glUniform1f(p.u_aref, v[0]);
    }
    uploadTscale(p, true);
    if (p.u_c >= 0) {
        // c[58]/c[59] identity: the translated program undoes D3D's divide.
        vsc[58] = .{ 1, 1, 1, 1 };
        vsc[59] = .{ 0, 0, 0, 0 };
        // Fog distance hack: c158.x is -1/(end - start), so dividing it moves both.
        const c158 = vsc[158][0];
        if (fog_scale != 1 and std.math.isFinite(c158)) vsc[158][0] = c158 / fog_scale;
        defer vsc[158][0] = c158;
        if (uniNew(p, @as(*const [192 * 4]f32, @ptrCast(&vsc)))) gl.glUniform4fv(p.u_c, 192, @ptrCast(&vsc));
    }
    if (p.key.ps != 0) {
        const def = &pixel_shaders.items[p.key.ps - 1].def;
        var c: [16][4]f32 = undefined;
        for (0..8) |i| {
            c[i] = argbVec(def[PsDef.constant0 + i]);
            c[8 + i] = argbVec(def[PsDef.constant1 + i]);
        }
        if (p.u_psc >= 0 and uniNew(p, @as(*const [64]f32, @ptrCast(&c)))) gl.glUniform4fv(p.u_psc, 16, @ptrCast(&c));
        const f = [2][4]f32{ argbVec(def[PsDef.final_c0]), argbVec(def[PsDef.final_c1]) };
        if (p.u_psf >= 0 and uniNew(p, @as(*const [8]f32, @ptrCast(&f)))) gl.glUniform4fv(p.u_psf, 2, @ptrCast(&f));
        if (p.u_bump >= 0) {
            var m: [4][4]f32 = undefined;
            for (0..4) |i| {
                const s: u32 = @intCast(i);
                m[i] = .{ @bitCast(d3d.tss(s, .bumpenvmat00)), @bitCast(d3d.tss(s, .bumpenvmat01)), @bitCast(d3d.tss(s, .bumpenvmat10)), @bitCast(d3d.tss(s, .bumpenvmat11)) };
            }
            if (uniNew(p, @as(*const [16]f32, @ptrCast(&m)))) gl.glUniform4fv(p.u_bump, 4, @ptrCast(&m));
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
            const src: [*]const u8, const sstride = streamSrc(e.stream, up, up_stride) orelse continue;
            d3d.vsdtRead(e.type, src + (base + v) * sstride + e.offset, &o[slot[e.reg]]);
        }
    }
    return stride;
}

/// Where a stream's vertex 0 is, and its stride.
fn streamSrc(stream: u32, up: ?[*]const u8, up_stride: u32) ?struct { [*]const u8, u32 } {
    return if (stream == 0 and up != null) .{ up.?, up_stride } else if (stream_host[stream]) |hp| .{ hp, stream_stride[stream] } else null;
}

// ── Mesh cache ──────────────────────────────────────────────────────────────
// Most draws repeat a mesh the title has not touched since the frame before
// (models are skinned and placed by their vertex programs). Converting and
// uploading it each time, and ANGLE then streaming it into its own buffers, was
// most of a draw's cost. A program draw is named by a hash of everything its
// buffers depend on, the source vertices and indices included; drawn a second
// time with the same hash, it gets buffers of its own and draws from them from
// then on. Vertices the title rewrites every frame never repeat and keep the
// streamed path.
// ponytail: fixed-function (FVF) draws are not cached; they are the 2D layer,
// few and edited per draw (extend2d). Cache them if a title draws its world so.

const Mesh = struct {
    vao: gl.GLuint = 0,
    bufs: [2]gl.GLuint = .{ 0, 0 },
    mode: gl.GLenum = gl.GL_TRIANGLES,
    count: gl.GLsizei = 0,
    indexed: bool = false,
    used: u32,
    // Indexed triangles keep their vertices and a triangle list, for merging (below).
    verts: []u8 = &.{},
    tris: []u16 = &.{},
    stride: u32 = 0,
    regs: u16 = 0,
};
var meshes: std.AutoHashMapUnmanaged(u64, Mesh) = .empty;

// ── Merged draws ────────────────────────────────────────────────────────────
// A model part reaches us as several small indexed strips, one draw each, with
// nothing changed in between but the winding the cull mode expects (Otogi's
// m001 building: 3,700 draws a frame, half of them 24 vertices or fewer). A
// draw of a cached mesh waits; draws after it in the same state join it, and
// the lot is drawn as one triangle list, cached under its members' keys like
// any mesh once seen twice. Everything else that touches GL flushes first.
// ponytail: a merged mesh is a second copy of its members' vertices, in RAM and
// on the GPU; share one vertex buffer if that ever shows.

const Sig = struct { state: [d3d.STATE_WORDS]u32, tex: [4]gl.GLuint, vs: u32, ps: u32, vsc: [192][4]f32, xf: [10][16]f32, vp: Viewport };
var batch: struct { n: u32 = 0, verts: usize = 0, cull: u32 = 0, sig: Sig = undefined, h: *HostVs = undefined, keys: [64]u64 = undefined, flip: [64]bool = undefined } = .{};

fn texNames(d: *const FDraw) [4]gl.GLuint {
    return .{ d.tex[0].gl, d.tex[1].gl, d.tex[2].gl, d.tex[3].gl };
}

/// Everything a draw's GL state comes from but the target (setTarget flushes),
/// with CW and CCW culling as one (cull gets which): the merged list winds its
/// triangles one way.
fn sigNow(s: *Sig, cull: *u32) void {
    s.* = .{ .state = d3d.state_snap.?.*, .tex = texNames(fr_d), .vs = fr_d.vsi, .ps = fr_d.psi, .vsc = vsc, .xf = xf, .vp = vp };
    const c = &s.state[128 + @intFromEnum(d3d.Rs.cullmode)];
    cull.* = c.*;
    if (c.* == 0x901) c.* = 0x900;
}

fn idxSpan(ix: [*]align(1) const u16, n: u32) [2]u32 {
    var lo: u32 = 0xFFFF;
    var hi: u32 = 0;
    for (0..n) |i| {
        lo = @min(lo, ix[i]);
        hi = @max(hi, ix[i]);
    }
    return .{ lo, hi };
}

/// This draw joins the waiting one: same state, and a mesh the cache holds.
/// Its record says part of that already (fr_d, fr_same).
fn batchAdd(xprim: u32, n: u32, ix: [*]align(1) const u16, base: u32) bool {
    const b = &batch;
    const d = fr_d;
    if (b.n == b.keys.len) return false;
    const eq = struct {
        fn eq(x: anytype, y: anytype) bool {
            return std.mem.eql(u8, std.mem.sliceAsBytes(x), std.mem.sliceAsBytes(y));
        }
    }.eq;
    if (!fr_same and !(eq(&vsc, &b.sig.vsc) and eq(&xf, &b.sig.xf))) return false;
    const st = d3d.state_snap.?;
    const ci = 128 + @intFromEnum(d3d.Rs.cullmode);
    const cull = st[ci];
    // A draw that joined the draw before it the first time it was drawn is in its state still.
    if (!(d.seen and d.joined)) {
        const s = &b.sig;
        if ((if (cull == 0x901) 0x900 else cull) != s.state[ci] or !eq(st[0..ci], s.state[0..ci]) or !eq(st[ci + 1 ..], s.state[ci + 1 ..])) return false;
        if (!eq(&texNames(d), &s.tex) or d.vsi != s.vs or d.psi != s.ps or !std.meta.eql(vp, s.vp)) return false;
    }
    const key = if (d.mesh != 0) d.mesh else blk: {
        const lo, const hi = idxSpan(ix, n);
        break :blk meshKey(b.h, xprim, n, ix, base, lo, hi, null, 0);
    };
    const m = meshes.getPtr(key) orelse return false;
    if (m.tris.len == 0 or b.verts + m.verts.len / m.stride > 0xFFFF) return false;
    m.used = fid;
    if (fr_final) {
        rstats.mesh_hits += 1;
        rstats.merged += 1;
    }
    if (!d.seen) {
        d.mesh = key;
        d.joined = true;
    }
    b.keys[b.n] = key;
    b.flip[b.n] = cull != b.cull;
    b.verts += m.verts.len / m.stride;
    b.n += 1;
    return true;
}

/// Draw what waits. GL state is still as the first draw's prepareDraw left it.
fn flushBatch() void {
    const b = &batch;
    const keys = b.keys[0..b.n];
    if (keys.len == 0) return;
    b.n = 0;
    var merged: ?*Mesh = null;
    if (keys.len > 1) {
        var hs = std.hash.Wyhash.init(keys.len);
        hs.update(std.mem.sliceAsBytes(keys));
        hs.update(std.mem.sliceAsBytes(b.flip[0..keys.len]));
        const got = meshes.getOrPut(alloc, hs.final()) catch return;
        if (!got.found_existing) {
            got.value_ptr.* = .{ .used = fid };
        } else if (got.value_ptr.vao != 0 or got.value_ptr.used != fid) { // as in drawGl()
            merged = got.value_ptr;
        }
    }
    const mm = merged orelse {
        // Alone, or a group seen for the first time: each from its own buffers.
        for (keys, b.flip[0..keys.len]) |k, flip| {
            const m = meshes.getPtr(k) orelse continue;
            gl.glBindVertexArray(m.vao);
            if (flip) gl.glFrontFace(if (b.cull == 0x900) gl.GL_CCW else gl.GL_CW);
            gl.glDrawElements(m.mode, m.count, gl.GL_UNSIGNED_SHORT, null);
            if (flip) gl.glFrontFace(if (b.cull == 0x900) gl.GL_CW else gl.GL_CCW);
        }
        return;
    };
    mm.used = fid;
    if (mm.vao == 0) {
        vs_buf.clearRetainingCapacity();
        idx_buf.clearRetainingCapacity();
        var first: ?*const Mesh = null;
        for (keys, b.flip[0..keys.len]) |k, flip| {
            const m = meshes.getPtr(k) orelse continue;
            if (first == null) first = m;
            const off: u16 = @intCast(vs_buf.items.len / m.stride);
            vs_buf.appendSlice(alloc, m.verts) catch @panic("OOM");
            var i: usize = 0;
            while (i + 3 <= m.tris.len) : (i += 3) {
                const t = m.tris[i..][0..3];
                idx_buf.appendSlice(alloc, &.{ off + t[@intFromBool(flip)], off + t[@intFromBool(!flip)], off + t[2] }) catch @panic("OOM");
            }
        }
        const f = first orelse return;
        gl.glGenVertexArrays(1, &mm.vao);
        gl.glGenBuffers(2, &mm.bufs);
        gl.glBindVertexArray(mm.vao);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, mm.bufs[0]);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(vs_buf.items.len), vs_buf.items.ptr, gl.GL_STATIC_DRAW);
        vsAttribs(f.regs, f.stride);
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, mm.bufs[1]);
        gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, @intCast(idx_buf.items.len * 2), idx_buf.items.ptr, gl.GL_STATIC_DRAW);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
        mm.count = @intCast(idx_buf.items.len);
        mm.indexed = true;
    }
    gl.glBindVertexArray(mm.vao);
    gl.glDrawElements(gl.GL_TRIANGLES, mm.count, gl.GL_UNSIGNED_SHORT, null);
}

/// A program's vertices as vsVertices lays them out: float4 per register used.
fn vsAttribs(regs: u16, stride: u32) void {
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
}

fn meshKey(h: *const HostVs, xprim: u32, n: u32, idx: ?[*]align(1) const u16, base: u32, lo: u32, hi: u32, up: ?[*]const u8, up_stride: u32) u64 {
    var in: [16]d3d.VsInput = undefined;
    const ni = d3d.vsInputs(&h.decl, &in);
    var hs = std.hash.Wyhash.init(h.inputs);
    hs.update(std.mem.asBytes(&[_]u32{ xprim, n, lo, hi, @intFromBool(idx != null) }));
    hs.update(std.mem.sliceAsBytes(in[0..ni]));
    var seen: u16 = 0;
    for (in[0..ni]) |e| {
        if (seen & (@as(u16, 1) << @intCast(e.stream)) != 0) continue;
        seen |= @as(u16, 1) << @intCast(e.stream);
        const src, const stride = streamSrc(e.stream, up, up_stride) orelse continue;
        hs.update(std.mem.asBytes(&stride));
        hs.update(src[(base + lo) * stride .. (base + hi + 1) * stride]);
    }
    if (idx) |ix| hs.update(@as([*]const u8, @ptrCast(ix))[0 .. n * 2]);
    return hs.final();
}

/// Meshes not drawn for 256 frames go, every 256 frames.
fn meshSweep() void {
    flushBatch();
    var it = meshes.iterator();
    while (it.next()) |e| if (fid -% e.value_ptr.used > 256) {
        if (e.value_ptr.vao != 0) {
            gl.glDeleteVertexArrays(1, &e.value_ptr.vao);
            gl.glDeleteBuffers(2, &e.value_ptr.bufs);
        }
        alloc.free(e.value_ptr.verts);
        alloc.free(e.value_ptr.tris);
        meshes.removeByPtr(e.key_ptr);
    };
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

/// Translate a vertex program's microcode once; genVs needs the result.
fn vsGlsl(h: *HostVs) !void {
    if (h.glsl != null) return;
    var w: std.Io.Writer = .fixed(&src_buf);
    try d3d.vshBody(h.mc[0 .. h.nmc * 4], &w, &h.inputs, &h.uses_vp);
    h.glsl = try alloc.dupe(u8, w.buffered());
}

fn prepareDraw() ?*Prog {
    const d = fr_d;
    var k: Key = .{};
    if (d.vsi != 0) {
        const h = &programs.items[d.vsi - 1];
        vsGlsl(h) catch return null;
        k.vs = d.vsi;
    } else if (d.vs & 1 != 0) return null;
    if (d.ps != 0 and d.psi == 0) return null;
    k.ps = d.psi;
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, target_fbo);
    keyVertex(&k);
    // On the wide back buffer, 3D stretches across and pre-transformed 2D keeps its 4:3 place.
    setViewport(k.rhw == 0 and d.wide);
    applyRenderState();
    applyStages(&k);
    const rs = d3d.rs;
    k.spec_add = @intFromBool(rs(.specularenable) != 0);
    k.fog = @intFromBool(rs(.fogenable) != 0);
    // Fog 2: Tower of Water's waterfall, the stage's only fogged layer added on top (m007 is
    // story stage 7). Its strips wind both ways, so culling dropped half of them (the shards);
    // drawn from both sides as alpha-blended sheets (premultiplied, see genFs).
    if (k.fog != 0 and rs(.alphablendenable) != 0 and rs(.destblend) == gl.GL_ONE and d.stage7) {
        k.fog = 2;
        gl.glDisable(gl.GL_CULL_FACE);
        gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);
    }
    k.fog_table = @intFromBool(k.fog != 0 and rs(.fogtablemode) != 0 and k.vs == 0);
    k.alpha_test = @intFromBool(rs(.alphatestenable) != 0);
    k.alpha_func = if (k.alpha_test != 0) @truncate(rs(.alphafunc) -% 0x200) else 0;
    k.flat = @intFromBool(rs(.shademode) == 0x1D00);
    // ponytail: fixed-function lighting is not done; Otogi lights in its vertex programs and
    // draws FVF geometry pre-transformed (unlit), so this has not been seen.
    if (k.vs == 0 and k.rhw == 0 and rs(.lighting) != 0) sayOnce("fixed-function lighting requested; drawn unlit");
    const p = progGet(&k) orelse {
        if (logging) std.debug.print("[DRAW] no program: vs={X} ps={X}\n", .{ d.vs, d.ps });
        return null;
    };
    if (logging) {
        std.debug.print("[DRAW] rt={d} vs={X} ps={X} tex0={d} fmt0={X} c0={d}:{X},{X} a0={d}:{X},{X} c1={d} blend={d} {X}/{X} atest={d} {X}\n", .{
            target_fbo,            d.vs,             d.ps,             d.tex[0].id,          d.tex[0].fmt,
            k.colorop[0],          k.colorarg[0][1], k.colorarg[0][2], k.alphaop[0],         k.alphaarg[0][1],
            k.alphaarg[0][2],      k.colorop[1],     rs(.alphablendenable), rs(.srcblend),   rs(.destblend),
            rs(.alphatestenable), rs(.alpharef),
        });
        std.debug.print("       vp={d},{d} {d}x{d} rhw={d} wide={} fog={d} table={d} {d}..{d} dens={d} col={X} zen={d} zw={d} cull={X}", .{ vp.x, vp.y, vp.w, vp.h, k.rhw, d.wide, rs(.fogenable), rs(.fogtablemode), @as(f32, @bitCast(rs(.fogstart))), @as(f32, @bitCast(rs(.fogend))), @as(f32, @bitCast(rs(.fogdensity))), rs(.fogcolor), rs(.zenable), rs(.zwriteenable), rs(.cullmode) });
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
extern threadlocal var g_esp: u32;

/// One draw, on the game thread: recorded into the frame being built. Vertices
/// come from `up` (inline) or the bound streams starting at vertex `base`;
/// idx == null draws [0, n). Xbox primitive types are NV2A's.
fn draw(xprim: u32, n: u32, idx: ?[*]align(1) const u16, up: ?[*]const u8, up_stride: u32, base: u32) void {
    if (n == 0) return;
    const t0 = nowMs();
    defer stats.draw_ms += @floatCast(nowMs() - t0);
    if (rec_cur) |ri| {
        if (up != null) return sayOnce("DrawVerticesUP inside a recorded pushbuffer skipped");
        return recordDraw(ri, xprim, n, idx, base);
    }
    if (!ready()) return;
    frameDraw(xprim, n, idx, up, up_stride, base);
    stats.draws += 1;
}

/// A recorded draw (fr_d), on the render thread; the mirrored state is the draw's.
fn drawGl(xprim: u32, n: u32, idx: ?[*]align(1) const u16, up: ?[*]const u8, up_stride: u32, base: u32) void {
    const d = fr_d;
    // Indexed triangles of a program can merge; the draw log wants each draw.
    const can = idx != null and up == null and (xprim == 5 or xprim == 6) and d.vsi != 0 and !logging;
    if (can and batch.n != 0 and batchAdd(xprim, n, idx.?, base)) return;
    flushBatch();
    const p = prepareDraw() orelse return;
    // Who drew what: the guest's return address (stale inside a pushbuffer replay).
    if (logging) std.debug.print("       n={d} prim={d} idx={} vb={X} base={d} from={X}\n", .{ n, xprim, idx != null, d.vb0, base, d.from });
    var lo: u32 = 0;
    var hi: u32 = n - 1;
    var nv = n; // vertices drawn: extend2d may add banner tiles
    if (idx) |ix| lo, hi = idxSpan(ix, n);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
    var mesh: ?*Mesh = null; // this draw's buffers are kept in it (mesh cache)
    var regs: u16 = 0;
    var stride: u32 = 0;
    if (p.key.vs != 0) {
        const h = &programs.items[p.key.vs - 1];
        const key = if (d.mesh != 0) d.mesh else meshKey(h, xprim, n, idx, base, lo, hi, up, up_stride);
        d.mesh = key;
        const got = meshes.getOrPut(alloc, key) catch return;
        if (!got.found_existing) {
            got.value_ptr.* = .{ .used = fid };
            rstats.mesh_new += 1;
        } else if (got.value_ptr.vao != 0 or got.value_ptr.used != fid) { // another pass over this frame is not a second time
            const m = got.value_ptr;
            m.used = fid;
            mesh = m;
            if (m.vao != 0) {
                if (fr_final) rstats.mesh_hits += 1;
                // Flat shading takes its colour from a vertex the merged list may not keep last.
                if (can and m.tris.len != 0 and p.key.flat == 0) {
                    sigNow(&batch.sig, &batch.cull);
                    batch.h = h;
                    batch.keys[0] = key;
                    batch.flip[0] = false;
                    batch.verts = m.verts.len / m.stride;
                    batch.n = 1;
                    return;
                }
                gl.glBindVertexArray(m.vao);
                if (m.count == 0) return;
                if (m.indexed) gl.glDrawElements(m.mode, m.count, gl.GL_UNSIGNED_SHORT, null) else gl.glDrawArrays(m.mode, 0, m.count);
                return;
            }
            gl.glGenVertexArrays(1, &m.vao);
            gl.glGenBuffers(2, &m.bufs);
            gl.glBindVertexArray(m.vao);
            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, m.bufs[0]);
        }
        if (mesh == null) gl.glBindVertexArray(vao);
        stride = vsVertices(h, base, lo, hi, up, up_stride, &regs);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(vs_buf.items.len), vs_buf.items.ptr, if (mesh != null) gl.GL_STATIC_DRAW else gl.GL_STREAM_DRAW);
        vsAttribs(regs, stride);
    } else {
        gl.glBindVertexArray(vao);
        stride = if (up != null) up_stride else stream_stride[0];
        if (stride == 0) stride = fvfStride(vshader);
        const verts = if (up) |u| u else if (stream_host[0]) |h| h + base * stride else return;
        if (stride == 0) return;
        var src = verts + lo * stride;
        var bytes = (hi - lo + 1) * stride;
        const xs = if (p.key.rhw != 0) xSpan(src, stride, hi - lo + 1) else [2]f32{ 1, 1 };
        if (logging and p.key.rhw != 0) std.debug.print("       x={d:.1}..{d:.1} n={d} prim={d} idx={}\n", .{ xs[0], xs[1], n, xprim, idx != null });
        // 2D at a screen edge reaches the wide buffer's edge (backgrounds, banners, tiled
        // pictures, fades, letterbox bars); one spanning the width that extend2d cannot
        // edit, or that draws a back buffer copy back (it holds the whole buffer), stretches.
        // A movie frame stays 4:3 (isMovie).
        if (p.key.rhw != 0 and target_fbo == fbo and wide() > 1 and (xs[0] <= 0.5 or xs[1] >= 639) and !d.tex[0].movie) {
            const copy = for (d.tex) |t| {
                if (t.copy or (xs[0] <= 0.5 and xs[1] >= 639 and t.still)) break true;
            } else false;
            const ext = if (!copy and idx == null and vp.x == 0 and vp.w == 640) extend2d(src, stride, n, xprim) else null;
            if (logging) std.debug.print("       edge: copy={} ext={}\n", .{ copy, ext != null });
            if (ext) |e| {
                src = e.ptr;
                bytes = @intCast(e.len);
                nv = bytes / stride;
                gl.glViewport(0, @intCast(vp.y * scale), @intCast(bbw() * scale), @intCast(vp.h * scale));
                gl.glUniform4f(p.u_rhw, -@as(f32, @floatFromInt((bbw() - 640) / 2)), @floatFromInt(vp.y), @floatFromInt(bbw()), @floatFromInt(@max(vp.h, 1)));
                p.fresh = true;
            } else if (xs[0] <= 0.5 and xs[1] >= 639) {
                setViewport(true);
                uploadTscale(p, false);
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
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, if (mesh) |m| m.bufs[1] else ibo);
        gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, @intCast(idx_buf.items.len * 2), idx_buf.items.ptr, if (mesh != null) gl.GL_STATIC_DRAW else gl.GL_STREAM_DRAW);
        gl.glDrawElements(mode, @intCast(idx_buf.items.len), gl.GL_UNSIGNED_SHORT, null);
        if (mesh) |m| {
            m.* = .{ .vao = m.vao, .bufs = m.bufs, .mode = mode, .count = @intCast(idx_buf.items.len), .indexed = true, .used = fid };
            if (can) {
                // As a triangle list, each triangle's last vertex still last. Degenerate ones go.
                const ix = idx_buf.items;
                const strip = xprim == 6;
                var tris: std.ArrayList(u16) = .empty;
                var i: usize = 0;
                while (i + 3 <= ix.len) : (i += if (strip) 1 else 3) {
                    const odd = @intFromBool(strip and i & 1 != 0);
                    const t = [3]u16{ ix[i + odd], ix[i + 1 - odd], ix[i + 2] };
                    if (t[0] != t[1] and t[1] != t[2] and t[0] != t[2]) tris.appendSlice(alloc, &t) catch @panic("OOM");
                }
                m.tris = tris.toOwnedSlice(alloc) catch @panic("OOM");
                m.verts = alloc.dupe(u8, vs_buf.items) catch @panic("OOM");
                m.stride = stride;
                m.regs = regs;
            }
        }
    } else {
        gl.glDrawArrays(mode, 0, @intCast(n));
        if (mesh) |m| m.* = .{ .vao = m.vao, .bufs = m.bufs, .mode = mode, .count = @intCast(n), .used = fid };
    }
}

// ── Frames and the render thread ────────────────────────────────────────────
// The game thread does no GL. Each draw and clear is recorded into a frame
// (state, vertex and index copies, constants, texture bytes that changed) and
// Swap hands the frame to the render thread, which draws it while the game
// builds the next one. The game steps its logic once per 30 Hz frame; to show
// more (RECOMP_FRAMERATE) the render thread draws the frame at in-between
// times too, with vertex shader constants and transforms blended from the
// matching draw of the frame before, and the frame itself at the end of its
// slot: one game frame of extra latency, and one more for the hand-over.
// A CopyRects over a whole surface is recorded too. One that has to put
// pixels in the guest's memory waits while the render thread draws the part of
// the game's frame recorded so far (serveSync), as does locking a surface an
// earlier copy left on the GPU.
// ponytail: only constants blend (camera, objects, bones); vertex data the CPU
// writes each frame (particles, 2D) shows at the newer frame's positions.

var fr_step: f64 = present_period; // ms between shown frames
var fr_pass_ms: f64 = 0; // what drawing one in-between costs, averaged
var fr_slow = false; // an in-between costs too much to fit one
var fr_said: u32 = 0;
var fr_d: *FDraw = undefined; // the draw being replayed
var fr_same = false; // and its constants and transforms are the draw's before it
var fr_final = false; // this pass draws the game's frame for showing: not an in-between, not a read-back
var logging = false; // and its draws go to the draw log
var fid: u32 = 0; // id of the frame being drawn
/// Game frames handed over (game thread).
pub var gframe: u32 = 0;

/// Where a draw goes: the back buffer (0), or 1 + index of an offscreen target.
const Tgt = struct { rt: u32 = 0, z: bool = true };

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
    vb0: u32, // for the draw log
    from: u32, // the guest's return address, for the draw log
    tex: [4]TexRef = @splat(.{}),
    vs: u32, // FVF or handle
    vsi: u32 = 0, // 1 + index into programs, 0 for an FVF
    ps: u32,
    psi: u32 = 0, // 1 + index into pixel_shaders, 0 for none
    state: [d3d.STATE_WORDS]u32,
    vsc: u32, // index into Frame.consts
    xf: u32, // index into Frame.xfs
    vp: Viewport,
    tgt: Tgt,
    wide: bool, // 3D stretches across the wide back buffer (wideNow)
    stage7: bool,
    key: u64,
    mesh: u64 = 0, // its mesh cache key, once drawGl() has worked it out
    joined: bool = false, // merged into the draw before it
    seen: bool = false, // drawn once already
};
/// `copy`: CopyRects of host pixels `s` (x1, y1, x2, y2) of target `src` over all of target `dst`.
const FOp = union(enum) { draw: FDraw, clear: struct { c: Clear, tgt: Tgt }, copy: struct { src: u32, s: [4]i32, dst: u32, d: [2]i32 } };
const Frame = struct {
    ops: std.ArrayList(FOp) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    consts: std.ArrayList([192][4]f32) = .empty,
    xfs: std.ArrayList([10][16]f32) = .empty,
    match: std.ArrayList(?u32) = .empty, // per op, the previous frame's matching draw
    uploads: std.ArrayList(Upload) = .empty, // emptied by runUploads
    resolved: usize = 0, // ops frameResolve has done
    stats: Stats = .{},
    eye: [3]f32 = .{ 0, 0, 0 },
    id: u32 = 0,

    fn reset(f: *Frame) void {
        f.ops.clearRetainingCapacity();
        f.bytes.clearRetainingCapacity();
        f.consts.clearRetainingCapacity();
        f.xfs.clearRetainingCapacity();
        f.match.clearRetainingCapacity();
        f.resolved = 0;
    }
    fn store(f: *Frame, b: []const u8) u32 {
        const o: u32 = @intCast(f.bytes.items.len);
        f.bytes.appendSlice(alloc, b) catch @panic("OOM");
        return o;
    }
};
/// One being built by the game thread, two with the render thread: the one it
/// draws and the one before, to blend from.
var frames: [3]Frame = .{ .{}, .{}, .{} };
var build: *Frame = &frames[0];
var fr_prev: *Frame = &frames[1];
var fr_cur: *Frame = &frames[2];
var vsc_dirty = true;
var xf_dirty = true;
/// The back buffer as the game's last two frames left it: [hold_at] is where
/// the frame being drawn starts from, the other where it ends.
var hold: [2]struct { fbo: gl.GLuint = 0, tex: gl.GLuint = 0 } = .{ .{}, .{} };
var hold_at: usize = 0;
var final_done = true; // fr_cur has been drawn into the other hold
pub var shown: u32 = 0; // frames shown, game and in-between

// Between the threads, under the lock: a finished frame for the render thread
// and the spare one it gives back; a read-back request (CopyRects).
var pending: ?*Frame = null;
var returned: *Frame = undefined;
var sync_req: ?struct { rt: u32, x: u32, y: u32, w: u32, h: u32, n: usize } = null;
var sync_px: std.ArrayList(u8) = .empty;
var sync_have: usize = 0; // ops of `build` the back buffer already holds on top of fr_cur

const SRWLOCK = extern struct { p: ?*anyopaque = null };
const CONDITION_VARIABLE = extern struct { p: ?*anyopaque = null };
extern "kernel32" fn AcquireSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(*SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn SleepConditionVariableSRW(*CONDITION_VARIABLE, *SRWLOCK, ms: u32, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn WakeAllConditionVariable(*CONDITION_VARIABLE) callconv(.winapi) void;
var mtx: SRWLOCK = .{};
var cond: CONDITION_VARIABLE = .{};
fn lock() void {
    AcquireSRWLockExclusive(&mtx);
}
fn unlock() void {
    ReleaseSRWLockExclusive(&mtx);
}
/// Holding the lock: sleep until the other thread wakes this one, or `ms` pass.
fn wait(ms: u32) void {
    _ = SleepConditionVariableSRW(&cond, &mtx, ms, 0);
}
fn wake() void {
    WakeAllConditionVariable(&cond);
}

/// RECOMP_FRAMERATE=<hz> shows that many frames a second; unset or 0 follows
/// the refresh rate of the monitor the window is on (59.94 and such
/// included), again whenever that changes; 30 is off.
fn frRate() void {
    var hz: f64 = 0;
    if (std.c.getenv("RECOMP_FRAMERATE")) |e| hz = std.fmt.parseFloat(f64, std.mem.span(e)) catch 0;
    if (hz == 0) {
        const m = sdl.SDL_GetCurrentDisplayMode(sdl.SDL_GetDisplayForWindow(window));
        hz = if (m != null and m.*.refresh_rate > 1) m.*.refresh_rate else 60;
    }
    const step = if (hz > 30) 1000.0 / hz else present_period;
    if (step != fr_step) std.debug.print("[GL] showing {d:.2} frames a second\n", .{1000.0 / step});
    fr_step = step;
}

fn frInit() void {
    frRate();
    for (&hold) |*h| {
        gl.glGenTextures(1, &h.tex);
        gl.glBindTexture(gl.GL_TEXTURE_2D, h.tex);
        gl.glTexStorage2D(gl.GL_TEXTURE_2D, 1, gl.GL_RGBA8, @intCast(bbw() * scale), @intCast(480 * scale));
        gl.glGenFramebuffers(1, &h.fbo);
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, h.fbo);
        gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, h.tex, 0);
    }
}

/// Record a draw into the frame being built (game thread).
fn frameDraw(xprim: u32, n: u32, idx: ?[*]align(1) const u16, up: ?[*]const u8, up_stride: u32, base: u32) void {
    const f = build;
    const vsi = if (vshader & 1 != 0) vs_handles.get(vshader) orelse return else 0;
    const psi = if (pshader != 0) ps_handles.get(pshader) orelse return else 0;
    var lo: u32 = 0;
    var hi: u32 = n - 1;
    if (idx) |ix| lo, hi = idxSpan(ix, n);
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
        .vb0 = stream_vb[0],
        .from = mem32(g_esp),
        .vs = vshader,
        .vsi = vsi,
        .ps = pshader,
        .psi = psi,
        .state = undefined,
        .vsc = @intCast(f.consts.items.len - 1),
        .xf = @intCast(f.xfs.items.len - 1),
        .vp = vp,
        .tgt = .{ .rt = target_rt, .z = target_z },
        .wide = wideNow(),
        .stage7 = mem32(0x13DAC08) == 7,
        .key = 0,
    };
    for (&d.tex, stage_tex) |*r, t| r.* = texRef(t);
    if (target_rt != 0 and isYuv(d.tex[0].fmt)) {
        movie_rt = d3d.resData(render_target);
        movie_frame = gframe;
    }
    // An offscreen target holds the whole wide view like a back buffer copy when
    // it is drawn from one, or when widened 3D is drawn into it (m027's after-images).
    const rhw = vshader & 1 == 0 and vshader & 0xE == 4;
    if (target_rt != 0 and (!rhw and d.wide or for (d.tex) |r| {
        if (r.copy) break true;
    } else false)) addCopy(d3d.resData(render_target));
    if (d3d.state_snap) |s| d.state = s.* else d3d.stateBlock(&d.state);
    if (idx) |ix| d.idx = f.store(@as([*]const u8, @ptrCast(ix))[0 .. 2 * n]);
    if (up) |u| d.up = f.store(u[0 .. (hi + 1) * up_stride]);
    // The streams the draw reads: a program's declared ones, or stream 0 for an FVF.
    var used: u16 = 1;
    if (vsi != 0) {
        var in: [16]d3d.VsInput = undefined;
        used = 0;
        for (in[0..d3d.vsInputs(&programs.items[vsi - 1].decl, &in)]) |e| used |= @as(u16, 1) << @intCast(e.stream);
    }
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

const RowSet = std.StaticBitSet(232);
const no_row = 255;
const no_op: u32 = 0xFFFFFFFF;
/// Row `r` of a draw's 192 constants and 40 transform rows.
fn frameRow(f: *const Frame, d: *const FDraw, r: usize) [4]u32 {
    return @bitCast(if (r < 192) f.consts.items[d.vsc][r] else @as(*const [40][4]f32, @ptrCast(&f.xfs.items[d.xf]))[r - 192]);
}
/// A draw's rows `rows` as one number.
fn frameId(f: *const Frame, d: *const FDraw, rows: *const RowSet) u64 {
    var h = std.hash.Wyhash.init(d.key);
    var it = rows.iterator(.{});
    while (it.next()) |r| h.update(std.mem.asBytes(&frameRow(f, d, r)));
    return h.final();
}
/// How far apart two draws are in the rows `rows`, squared.
fn frameDist(a: *const Frame, da: *const FDraw, b: *const Frame, db: *const FDraw, rows: [4]u8) f32 {
    var sum: f32 = 0;
    for (rows) |r| if (r != no_row) {
        const d = @as(@Vector(4, f32), @as([4]f32, @bitCast(frameRow(a, da, r)))) - @as(@Vector(4, f32), @as([4]f32, @bitCast(frameRow(b, db, r))));
        sum += @reduce(.Add, d * d);
    };
    return sum;
}

/// Whether two draws of a frame have the same constants.
fn frameTwin(f: *const Frame, a: *const FDraw, b: *const FDraw) bool {
    return (a.vsc == b.vsc or std.mem.eql(u8, std.mem.asBytes(&f.consts.items[a.vsc]), std.mem.asBytes(&f.consts.items[b.vsc]))) and
        (a.xf == b.xf or std.mem.eql(u8, std.mem.asBytes(&f.xfs.items[a.xf]), std.mem.asBytes(&f.xfs.items[b.xf])));
}
/// Of the previous draws from `head` back that are not paired yet, the one
/// nearest `d` in `rows`, and how near it and the next are. One with the same
/// constants as the nearest is not the next: either will do.
fn frameNearest(prev: *const Frame, head: u32, cur: *const Frame, d: *const FDraw, rows: [4]u8) struct { at: u32, best: f32, next: f32 } {
    var at: u32 = no_op;
    var best = std.math.inf(f32);
    var next = best;
    var i = head;
    while (i != no_op) : (i = fr_link[0].items[i]) {
        if (fr_near.items[i] < 0) continue;
        const p = &prev.ops.items[i].draw;
        const dist = frameDist(prev, p, cur, d, rows);
        fr_near.items[i] = @min(fr_near.items[i], dist);
        if (dist < best) {
            next = best;
            best = dist;
            at = i;
        } else if (dist == best and at != no_op) {
            if (!frameTwin(prev, p, &prev.ops.items[at].draw)) next = best;
        } else if (dist < next) next = dist;
    }
    return .{ .at = at, .best = best, .next = next };
}
/// How badly `rows` tell the previous draw of each of `sample` from the next,
/// 0 to 1 a draw.
fn frameCost(prev: *const Frame, head: u32, cur: *const Frame, sample: []const u32, rows: [4]u8) f32 {
    var cost: f32 = 0;
    for (sample) |i| {
        const r = frameNearest(prev, head, cur, &cur.ops.items[i].draw, rows);
        cost += if (r.next > 0 and r.best < r.next) r.best / r.next else 1;
    }
    return cost;
}

var fr_link: [2]std.ArrayList(u32) = .{ .empty, .empty }; // per op of the previous and current frame, the one before it with the same key
var fr_near: std.ArrayList(f32) = .empty; // per op of the previous frame, how near the nearest current draw is; negative once paired by its rows
var fr_id: std.ArrayList(u64) = .empty; // per op of the current frame, its frameId
/// Per repeated key, the rows that name an instance and the frame they were
/// found in, and the rows that place one.
var fr_rows: std.AutoHashMapUnmanaged(u64, struct { rows: RowSet = .empty, at: u32 = 0, near: ?[4]u8 = null }) = .empty;

/// For each draw of `cur`, the draw of `prev` it continues. A key unique in
/// both frames names it. A mesh drawn several times (trees, enemies of one
/// kind, mist sprites) repeats its key. Things that stand still keep some
/// constant rows from frame to frame that differ from one to the next (m000's
/// bamboo: its light in object space, rows 91-93 and 120-122) while the rows
/// the camera is in change for all: those rows name the instance, whatever the
/// camera does and however many are culled. The ones not named so (they move)
/// each take the previous draw nearest in the up to 4 rows that change least
/// from frame to frame for how much they differ within the key (the mist's
/// world matrix, rows 120-122: a camera turn changes the others more than the
/// sprites are apart), when that one is 4 times nearer than the next and no
/// other current draw is nearer to it. Draws with the same constants (the two
/// passes of a shadow volume) get the same answer, or the passes come apart.
/// ponytail: keys repeated more than 512 times stay unblended (the search is n
/// squared); so does what moves further in a frame than a quarter of the way
/// to its neighbour.
fn frameMatch(prev: *const Frame, cur: *Frame) void {
    const none = no_op;
    const Seen = struct {
        prev: u32 = none,
        cur: u32 = none,
        n_prev: u32 = 0,
        n_cur: u32 = 0,
        rows: ?RowSet = null,
        near: ?[4]u8 = null,
        named: u32 = 0, // current draws paired by their rows
        fn group(s: @This()) bool {
            return s.n_prev != 0 and s.n_cur != 0 and s.n_prev + s.n_cur > 2;
        }
        fn byRows(s: @This()) bool {
            return s.named * 2 >= s.n_cur;
        }
    };
    var seen: std.AutoHashMapUnmanaged(u64, Seen) = .empty;
    defer seen.deinit(alloc);
    for ([_]*const Frame{ prev, cur }, &fr_link, 0..) |f, *link, side| {
        link.resize(alloc, f.ops.items.len) catch @panic("OOM");
        for (f.ops.items, link.items, 0..) |op, *l, i| if (op == .draw) {
            const g = seen.getOrPutValue(alloc, op.draw.key, .{}) catch @panic("OOM");
            const head, const n = if (side == 0) .{ &g.value_ptr.prev, &g.value_ptr.n_prev } else .{ &g.value_ptr.cur, &g.value_ptr.n_cur };
            l.* = head.*;
            head.* = @intCast(i);
            n.* += 1;
        };
    }
    var groups = seen.iterator();
    while (groups.next()) |e| if (e.value_ptr.group() and @max(e.value_ptr.n_prev, e.value_ptr.n_cur) <= 512) {
        if (fr_rows.get(e.key_ptr.*)) |k| {
            if (k.rows.count() != 0) e.value_ptr.rows = k.rows;
            e.value_ptr.near = k.near;
        }
    };

    // By the rows that name an instance.
    var ids: std.AutoHashMapUnmanaged(u64, struct { prev: u32, n_prev: u32 = 1, n_cur: u32 = 0 }) = .empty;
    defer ids.deinit(alloc);
    for (prev.ops.items, 0..) |*op, i| if (op.* == .draw) if (seen.getPtr(op.draw.key).?.rows) |*rows| {
        const g = ids.getOrPut(alloc, frameId(prev, &op.draw, rows)) catch @panic("OOM");
        if (g.found_existing) g.value_ptr.n_prev += 1 else g.value_ptr.* = .{ .prev = @intCast(i) };
    };
    fr_id.resize(alloc, cur.ops.items.len) catch @panic("OOM");
    for (cur.ops.items, fr_id.items) |*op, *id| if (op.* == .draw) if (seen.getPtr(op.draw.key).?.rows) |*rows| {
        id.* = frameId(cur, &op.draw, rows);
        if (ids.getPtr(id.*)) |g| g.n_cur += 1;
    };
    cur.match.clearRetainingCapacity();
    for (cur.ops.items, fr_id.items) |*op, id| {
        var m: ?u32 = null;
        if (op.* == .draw) {
            const s = seen.getPtr(op.draw.key).?;
            if (s.n_prev == 1 and s.n_cur == 1) {
                m = s.prev;
            } else if (s.rows != null) if (ids.get(id)) |g| if (g.n_prev == 1 and g.n_cur == 1) {
                m = g.prev;
                s.named += 1;
            };
        }
        cur.match.append(alloc, m) catch @panic("OOM");
    }

    // The rest by the nearest rows, among the previous draws not paired yet.
    fr_near.resize(alloc, prev.ops.items.len) catch @panic("OOM");
    @memset(fr_near.items, std.math.inf(f32));
    for (cur.ops.items, cur.match.items) |*op, *m| if (m.*) |pi| {
        const s = seen.get(op.draw.key).?;
        if (!s.group()) continue;
        if (s.byRows()) fr_near.items[pi] = -1 else m.* = null;
    };
    for (cur.ops.items, cur.match.items) |*op, *m| if (op.* == .draw and m.* == null) {
        const s = seen.get(op.draw.key).?;
        const r = frameNearest(prev, s.prev, cur, &op.draw, s.near orelse continue);
        if (r.best * 16 < r.next) m.* = r.at;
    };
    for (cur.ops.items, cur.match.items) |*op, *m| if (m.*) |pi| {
        const near = seen.get(op.draw.key).?.near orelse continue;
        if (fr_near.items[pi] >= 0 and fr_near.items[pi] < frameDist(prev, &prev.ops.items[pi].draw, cur, &op.draw, near)) m.* = null;
    };

    // Look for the rows again where some were not named.
    // ponytail: the naming rows every 16 frames at most and not for keys
    // repeated more than 256 times, the placing rows every 4 frames from 16
    // of the draws; the table is dropped when it fills.
    if (fr_rows.count() > 4096) fr_rows.clearRetainingCapacity();
    groups = seen.iterator();
    while (groups.next()) |e| {
        const s = e.value_ptr;
        const n = @max(s.n_prev, s.n_cur);
        if (!s.group() or s.named == s.n_cur or n > 512) continue;
        const k = (fr_rows.getOrPutValue(alloc, e.key_ptr.*, .{}) catch @panic("OOM")).value_ptr;
        // Naming: the rows that differ within the key, each found unchanged in
        // the previous frame by 3 in 4.
        if (!s.byRows() and n <= 256 and frame -% k.at >= 16) {
            k.at = frame;
            k.rows = .empty;
            for (0..232) |r| {
                const first = frameRow(cur, &cur.ops.items[s.cur].draw, r);
                var differs = false;
                var found: u32 = 0;
                var i = s.cur;
                while (i != none) : (i = fr_link[1].items[i]) {
                    const row = frameRow(cur, &cur.ops.items[i].draw, r);
                    differs = differs or !std.mem.eql(u32, &row, &first);
                    var j = s.prev;
                    while (j != none) : (j = fr_link[0].items[j]) if (std.mem.eql(u32, &frameRow(prev, &prev.ops.items[j].draw, r), &row)) {
                        found += 1;
                        break;
                    };
                }
                if (differs and found * 4 >= @min(s.n_prev, s.n_cur) * 3) k.rows.set(r);
            }
        }
        // Placing: of the rows that differ, add the one that best sets the
        // nearest previous draw apart from the next, while one does so by a
        // quarter.
        if (k.near != null and (frame +% @as(u32, @truncate(e.key_ptr.*))) % 4 != 0) continue;
        var sample: [16]u32 = undefined;
        var cnt: usize = 0;
        var i = s.cur;
        while (i != none and cnt < sample.len) : (i = fr_link[1].items[i]) {
            if (cur.match.items[i]) |pi| if (fr_near.items[pi] < 0) continue;
            sample[cnt] = i;
            cnt += 1;
        }
        if (cnt == 0) continue;
        var differ: RowSet = .empty;
        for (0..232) |r| for (sample[1..cnt]) |j| if (!std.mem.eql(u32, &frameRow(cur, &cur.ops.items[j].draw, r), &frameRow(cur, &cur.ops.items[sample[0]].draw, r))) {
            differ.set(r);
            break;
        };
        var near: [4]u8 = @splat(no_row);
        var least = frameCost(prev, s.prev, cur, sample[0..cnt], near);
        for (&near) |*slot| {
            var pick: u8 = no_row;
            var low = least * 0.75;
            var it = differ.iterator(.{});
            while (it.next()) |r| {
                slot.* = @intCast(r);
                const c = frameCost(prev, s.prev, cur, sample[0..cnt], near);
                if (c < low) {
                    low = c;
                    pick = @intCast(r);
                }
            }
            slot.* = pick;
            if (pick == no_row) break;
            least = low;
            differ.unset(pick);
        }
        k.near = near;
    }
}

fn lerpInto(out: []f32, a: []const f32, b: []const f32, t: f32) void {
    for (out, a, b) |*o, x, y| o.* = x + (y - x) * t;
}

var tgt_now: Tgt = .{};
/// Draw into `t` from here on.
fn setTarget(t: Tgt) void {
    if (t.rt == tgt_now.rt and (t.rt == 0 or t.z == tgt_now.z)) return;
    flushBatch();
    tgt_now = t;
    target_fbo = fbo;
    if (t.rt == 0) return;
    const r = &rts.items[t.rt - 1];
    target_fbo = r.fbo;
    if (r.z == t.z) return;
    r.z = t.z;
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, r.fbo);
    gl.glFramebufferRenderbuffer(gl.GL_FRAMEBUFFER, gl.GL_DEPTH_STENCIL_ATTACHMENT, gl.GL_RENDERBUFFER, if (t.z) r.depth else 0);
}

/// Draw ops [from, to) of `cur`: as recorded, or with `prev` at `t` (0..1) of
/// the way from it (frameMatch has paired them).
fn frameReplay(prev: ?*const Frame, cur: *Frame, from: usize, to: usize, t: f32) void {
    const t0 = nowMs();
    fid = cur.id;
    fr_t = t;
    logging = fr_final and drawlog_frame == frame + 1;
    const bytes = cur.bytes.items.ptr;
    var from0: [4]u32 = @splat(no_op);
    for (cur.ops.items[from..to], from..) |*op, i| switch (op.*) {
        .clear => |*c| {
            setTarget(c.tgt);
            if (logging) std.debug.print("[DRAW] clear flags={X} color={X} rects={d} rt={d}\n", .{ c.c.flags, c.c.color, c.c.count, target_fbo });
            clearGl(&c.c);
        },
        .copy => |c| {
            flushBatch();
            gl.glBindFramebuffer(gl.GL_READ_FRAMEBUFFER, if (c.src == 0) fbo else rts.items[c.src - 1].fbo);
            gl.glBindFramebuffer(gl.GL_DRAW_FRAMEBUFFER, rts.items[c.dst - 1].fbo);
            gl.glDisable(gl.GL_SCISSOR_TEST);
            gl.glColorMask(1, 1, 1, 1);
            gl.glBlitFramebuffer(c.s[0], c.s[1], c.s[2], c.s[3], 0, 0, c.d[0], c.d[1], gl.GL_COLOR_BUFFER_BIT, gl.GL_LINEAR);
        },
        .draw => |*d| {
            setTarget(d.tgt);
            const pf = prev orelse cur;
            const p: ?*const FDraw = if (prev != null) (if (cur.match.items[i]) |pi| &pf.ops.items[pi].draw else null) else null;
            // Blended from the same four sets as the last draw's: they are loaded.
            const sets = [4]u32{ d.vsc, d.xf, if (p) |x| x.vsc else no_op, if (p) |x| x.xf else no_op };
            fr_same = std.mem.eql(u32, &sets, &from0);
            from0 = sets;
            if (!fr_same) {
                vsc = cur.consts.items[d.vsc];
                xf = cur.xfs.items[d.xf];
                if (p) |q| {
                    lerpInto(@as(*[192 * 4]f32, @ptrCast(&vsc)), @as(*const [192 * 4]f32, @ptrCast(&pf.consts.items[q.vsc])), @as(*const [192 * 4]f32, @ptrCast(&cur.consts.items[d.vsc])), t);
                    lerpInto(@as(*[160]f32, @ptrCast(&xf)), @as(*const [160]f32, @ptrCast(&pf.xfs.items[q.xf])), @as(*const [160]f32, @ptrCast(&cur.xfs.items[d.xf])), t);
                    // A sprite sheet's cell (the particle program's c159) is a step, not a slide.
                    if (d.vsi != 0 and programs.items[d.vsi - 1].hash == 0xA8A1DBCD) vsc[159] = cur.consts.items[d.vsc][159];
                }
            }
            fr_d = d;
            vshader = d.vs;
            stream_stride = d.stride;
            vp = d.vp;
            for (&stream_host, d.streams, d.stride) |*h, o, st| h.* = if (o) |off| @ptrFromInt(@intFromPtr(bytes + off) -% (d.base + d.lo) * st) else null;
            d3d.state_snap = &d.state;
            drawGl(d.prim, d.n, if (d.idx) |o| @ptrCast(bytes + o) else null, if (d.up) |o| bytes + o else null, d.up_stride, d.base);
            d.seen = true;
        },
    };
    flushBatch();
    d3d.state_snap = null;
    logging = false;
    rstats.render_ms += @floatCast(nowMs() - t0);
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

/// The game's frame itself, from the back buffer the frame before left to the
/// one this leaves.
fn finalPass() void {
    blitFbo(hold[hold_at].fbo, fbo);
    fr_final = true;
    frameReplay(null, fr_cur, 0, fr_cur.ops.items.len, 1);
    fr_final = false;
    blitFbo(fbo, hold[1 - hold_at].fbo);
    final_done = true;
    sync_have = 0;
}

/// A read-back the game thread waits on (syncRead): draw what it has recorded
/// of its frame so far on top of the frame before, and read the pixels.
fn serveSync() void {
    lock();
    const req = sync_req;
    const f = build;
    unlock();
    const q = req orelse return;
    if (!final_done) finalPass();
    runUploads(f);
    frameResolve(f, q.n);
    if (sync_have == 0) blitFbo(hold[1 - hold_at].fbo, fbo);
    frameReplay(null, f, sync_have, q.n, 1);
    sync_have = q.n;
    gl.glBindFramebuffer(gl.GL_READ_FRAMEBUFFER, if (q.rt == 0) fbo else rts.items[q.rt - 1].fbo);
    sync_px.resize(alloc, q.w * q.h * 4) catch @panic("OOM");
    gl.glReadPixels(@intCast(q.x), @intCast(q.y), @intCast(q.w), @intCast(q.h), gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, sync_px.items.ptr);
    lock();
    sync_req = null;
    wake();
    unlock();
}

/// Pixels of a render target (0: the back buffer) as the game's frame has drawn
/// it so far, bottom row first as GL reads them (game thread).
fn syncRead(rt: u32, x: u32, y: u32, w: u32, h: u32) []const u8 {
    const t0 = nowMs();
    defer stats.sync_ms += @floatCast(nowMs() - t0);
    lock();
    sync_req = .{ .rt = rt, .x = x, .y = y, .w = w, .h = h, .n = build.ops.items.len };
    wake();
    while (sync_req != null) wait(0xFFFFFFFF);
    unlock();
    return sync_px.items;
}

/// Sleep until `t`, serving read-backs as they come.
fn waitServing(t: f64) void {
    while (true) {
        serveSync();
        const now = nowMs();
        if (now >= t) return;
        // A sleep of 1 ms can take 2 at the 1 ms timer resolution: stop 2 ms short, spin the rest.
        if (t - now < 3) continue;
        lock();
        if (sync_req == null) wait(@intFromFloat(t - now - 2));
        unlock();
    }
}

// ── Present ─────────────────────────────────────────────────────────────────

/// Game frames shown (render thread).
pub var frame: u32 = 0;
var fr_t: f32 = 1; // how far into the game frame the replay being drawn is

/// Frame whose draws are logged: RECOMP_GL_DRAWLOG=<frame>, or the frame after
/// logs\drawlog appears (deleted at once; also takes a RECOMP_SHOT-style shot).
var drawlog_frame: u32 = 0;
extern "kernel32" fn DeleteFileA([*:0]const u8) callconv(.winapi) i32;

/// The render thread: takes each frame the game thread finishes, shows it at
/// in-between times inside its 30 Hz slot and as recorded at the slot's end.
fn renderThread() void {
    const ok = glInit();
    lock();
    state = if (ok) .ready else .failed;
    wake();
    unlock();
    if (!ok) return;
    while (true) {
        lock();
        while (pending == null) {
            const idle = sync_req == null;
            if (idle) wait(10);
            unlock();
            if (idle) pumpEvents() else serveSync();
            lock();
        }
        returned = fr_prev;
        fr_prev = fr_cur;
        fr_cur = pending.?;
        pending = null;
        wake();
        unlock();
        const cur = fr_cur;
        hold_at = 1 - hold_at;
        final_done = false;
        sync_have = 0;
        // Textures replaced since the last frame: nothing draws them now.
        if (tex_dead.items.len != 0) gl.glDeleteTextures(@intCast(tex_dead.items.len), tex_dead.items.ptr);
        tex_dead.clearRetainingCapacity();
        runUploads(cur);
        frameResolve(cur, cur.ops.items.len);
        const due = last_present + present_period;
        if (last_present != 0 and fr_step < present_period and fr_prev.ops.items.len != 0) {
            frameMatch(fr_prev, cur);
            // Evenly spaced beats many: when one in-between takes longer to draw
            // than one refresh, they show every second (third...) one.
            const slot = fr_step * @max(1, @ceil(fr_pass_ms / fr_step));
            // Each is blended for the time it really shows at, not for a place on
            // a grid: one shown late with an earlier picture moves the world unevenly.
            var shown_at = last_present;
            var next = @max(shown_at + slot, nowMs() + fr_pass_ms);
            while (next < due - slot * 0.5) : (next = @max(shown_at + slot, nowMs() + fr_pass_ms)) {
                serveSync();
                const t0 = nowMs();
                blitFbo(hold[hold_at].fbo, fbo);
                frameReplay(fr_prev, cur, 0, cur.ops.items.len, @floatCast((next - last_present) / present_period));
                sync_have = 0;
                blitWindow(fbo);
                fr_pass_ms = pacer.cost(fr_pass_ms, nowMs() - t0, present_period);
                waitServing(next);
                swapWindow();
                shown_at = nowMs(); // with vsync the swap returns at the vblank
            }
            if (shown_at == last_present) fr_pass_ms = pacer.cost(fr_pass_ms, null, present_period);
            // For reports of a game stuck at 30 shown frames (issue #15).
            const slow = slot * 1.5 >= present_period;
            if (slow != fr_slow and fr_said < 20) {
                fr_said += 1;
                std.debug.print("[GL] in-between frames {s}: one costs {d:.1} ms\n", .{ if (slow) "off" else "on", fr_pass_ms });
            }
            fr_slow = slow;
        }
        if (!final_done) finalPass();
        frame += 1;
        if (frame == 1) if (std.c.getenv("RECOMP_GL_DRAWLOG")) |e| {
            drawlog_frame = std.fmt.parseInt(u32, std.mem.span(e), 10) catch 0;
        };
        if (DeleteFileA("logs\\drawlog") != 0) drawlog_frame = frame + 1;
        blitWindow(hold[1 - hold_at].fbo);
        if (frame == drawlog_frame) writeShot() catch {} else maybeShot();
        if (last_present != 0) waitServing(due);
        swapWindow();
        const now = nowMs();
        // On the vblank grid while on time, so sleep overshoot does not add up.
        last_present = if (now - due < present_period) due else now;
        frameStats(cur);
        if (frame % 256 == 0) meshSweep();
        // Debug menu pause: show this frame until resumed or stepped.
        while (debug_menu.holdFrame()) {
            serveSync();
            showFbo(hold[1 - hold_at].fbo);
            Sleep(10);
        }
    }
}

/// `last` for the debug menu, and RECOMP_FPS=1: game frames and shown frames
/// per second, guest work per frame (and the part inside draw()), draws per
/// frame, the game's queued objects and the camera's position, every 5 s.
fn frameStats(f: *const Frame) void {
    var s = f.stats;
    s.uploads, s.mesh_hits, s.mesh_new, s.merged, s.render_ms = .{ rstats.uploads, rstats.mesh_hits, rstats.mesh_new, rstats.merged, rstats.render_ms };
    rstats = .{};
    last = s;
    const fps = struct {
        var on: ?bool = null;
        var t0: f64 = 0;
        var f0: u32 = 0;
        var s0: u32 = 0;
        var work: f64 = 0;
        var work_max: f32 = 0;
        var draws: u64 = 0;
        var draw_ms: f64 = 0;
        var render: f64 = 0;
        var sync: f64 = 0;
    };
    if (fps.on == null) fps.on = std.c.getenv("RECOMP_FPS") != null;
    if (!fps.on.?) return;
    fps.work += s.work_ms;
    fps.work_max = @max(fps.work_max, s.work_ms);
    fps.draws += s.draws;
    fps.draw_ms += s.draw_ms;
    fps.render += s.render_ms;
    fps.sync += s.sync_ms;
    const now = nowMs();
    if (frame % 64 != 0 or now - fps.t0 < 5000) return;
    const n: f64 = @floatFromInt(frame - fps.f0);
    if (fps.t0 != 0) std.debug.print("[GL] {d:.1} fps, {d:.1} shown, guest {d:.1} ms avg {d:.1} max ({d:.1} in draw), {d} draws ({d} merged), queued {d}+{d}, eye {d:.0} {d:.0} {d:.0}, render {d:.1} ms, read-back {d:.1} ms, longest gap {d:.1} ms\n", .{ n * 1000 / (now - fps.t0), @as(f64, @floatFromInt(shown - fps.s0)) * 1000 / (now - fps.t0), fps.work / n, fps.work_max, fps.draw_ms / n, fps.draws / @as(u64, @intFromFloat(n)), s.merged, s.queued[0], s.queued[1], f.eye[0], f.eye[1], f.eye[2], fps.render / n, fps.sync / n, swap_gap });
    swap_gap = 0;
    fps.t0 = now;
    fps.f0 = frame;
    fps.s0 = shown;
    fps.work = 0;
    fps.work_max = 0;
    fps.draws = 0;
    fps.draw_ms = 0;
    fps.render = 0;
    fps.sync = 0;
}

/// A frame again (paused).
fn showFbo(src: gl.GLuint) void {
    blitWindow(src);
    swapWindow();
}

var swap_at: f64 = 0;
var swap_gap: f64 = 0; // longest time between shown frames, for RECOMP_FPS

fn swapWindow() void {
    _ = gl.eglSwapBuffers(dpy, surf);
    shown += 1;
    const now = nowMs();
    if (swap_at != 0) swap_gap = @max(swap_gap, now - swap_at);
    swap_at = now;
    pumpEvents();
}

/// The back buffer `src` to the window, letterboxed to its aspect and flipped:
/// the back buffer keeps the guest's row order.
fn blitWindow(src: gl.GLuint) void {
    flushBatch();
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
    debug_menu.draw(window.?);
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
extern fn sub_000FE580_gen() void;
extern fn sub_000F9570_gen() void;
extern fn sub_000FA990_gen() void;
extern fn sub_000FAA00_gen() void;
extern fn sub_000FA6F0_gen() void;

extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

pub fn nowMs() f64 {
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
    stats.queued = .{ mem32(0x1E69A8), mem32(0x1E69AC) };
    defer last_swap_end = nowMs();
    sub_000F4D00_gen();
    if (!ready()) return;
    build.stats = stats;
    stats = .{};
    build.eye = .{ d3d.memf(0x1386AB4), d3d.memf(0x1386AB8), d3d.memf(0x1386ABC) };
    gframe += 1;
    // The frame goes to the render thread once it has shown the one before
    // (that wait is the 30 Hz pacing); the one before that comes back to fill.
    lock();
    pending = build;
    wake();
    while (pending != null) wait(0xFFFFFFFF);
    build = returned;
    unlock();
    build.reset();
    build.id = gframe;
    vsc_dirty = true;
    xf_dirty = true;
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
    sub_000F4EB0_gen();
    if (!ready()) return;
    build.ops.append(alloc, .{ .clear = .{ .c = c, .tgt = .{ .rt = target_rt, .z = target_z } } }) catch @panic("OOM");
    stats.clears += 1;
}

const Clear = struct { count: u32 = 0, rects: [16][4]i32 = undefined, flags: u32, color: u32, z: u32, stencil: u32 };

fn clearGl(c: *const Clear) void {
    flushBatch();
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, target_fbo);
    var mask: gl.GLbitfield = 0;
    if (c.flags & 0xF0 != 0) mask |= gl.GL_COLOR_BUFFER_BIT;
    if (c.flags & 1 != 0) mask |= gl.GL_DEPTH_BUFFER_BIT;
    if (c.flags & 2 != 0) mask |= gl.GL_STENCIL_BUFFER_BIT;
    if (mask == 0) return;
    const col = argbVec(c.color);
    // D3DCLEAR_TARGET_R/G/B/A (0x10/20/40/80) each clear one channel: the glow
    // effect (m014, m019) clears only alpha and keeps the scene under it.
    const ch = struct {
        fn on(f: u32, bit: u32) gl.GLboolean {
            return @intFromBool(f & bit != 0);
        }
    };
    gl.glColorMask(ch.on(c.flags, 0x10), ch.on(c.flags, 0x20), ch.on(c.flags, 0x40), ch.on(c.flags, 0x80));
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

// The game thread's target: the surface, 1 + its index in rt_keys (0: the back
// buffer), its size and whether it has a Z surface.
var render_target: u32 = 0;
var target_rt: u32 = 0;
var target_size: [2]u32 = .{ 640, 480 };
var target_z = true;
var target_fbo: gl.GLuint = 0; // the render thread's: the back buffer's fbo, or an offscreen target's

/// An offscreen render target, kept on the GPU. A texture whose Data is the
/// target's samples the host texture (texRef), so nothing is read back. The
/// game thread knows it by rt_keys, the render thread makes it (rts, same index).
const Rt = struct { tex: gl.GLuint = 0, fbo: gl.GLuint = 0, depth: gl.GLuint = 0, z: bool = false };
var rts: std.ArrayList(Rt) = .empty;
var rt_keys: std.ArrayList(RtKey) = .empty;
/// A whole-surface CopyRects makes its destination one too: the copy stays on
/// the GPU and the guest's bytes fall behind (`stale`) until the game locks the
/// surface (toGuest). From then the bytes are what draws (`locked`), until the
/// next copy.
const RtKey = struct { data: u32, w: u32, h: u32, stale: bool = false, locked: bool = false, f: ?d3d.Fmt = null, pitch: u32 = 0 };

/// 1 + the index of surface `s` as a render target, new ones made on the way (game thread).
fn rtIndex(s: u32) u32 {
    const data = d3d.resData(s);
    const dims = d3d.surfDims(s);
    for (rt_keys.items, 1..) |k, i| if (k.data == data and k.w == dims.w and k.h == dims.h) return @intCast(i);
    rt_keys.append(alloc, .{ .data = data, .w = dims.w, .h = dims.h }) catch @panic("OOM");
    build.uploads.append(alloc, .{ .rt = .{ .w = dims.w, .h = dims.h } }) catch @panic("OOM");
    std.debug.print("[GL] render target {d}x{d} format 0x{X:0>2} at 0x{X:0>8}\n", .{ dims.w, dims.h, (mem32(s + 0xC) >> 8) & 0xFF, data });
    return @intCast(rt_keys.items.len);
}

fn rtCreate(w: u32, h: u32) void {
    const r = rts.addOne(alloc) catch @panic("OOM");
    r.* = .{};
    gl.glGenTextures(1, &r.tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, r.tex);
    gl.glTexStorage2D(gl.GL_TEXTURE_2D, 1, gl.GL_RGBA8, @intCast(w * scale), @intCast(h * scale));
    gl.glGenRenderbuffers(1, &r.depth);
    gl.glBindRenderbuffer(gl.GL_RENDERBUFFER, r.depth);
    gl.glRenderbufferStorage(gl.GL_RENDERBUFFER, gl.GL_DEPTH24_STENCIL8, @intCast(w * scale), @intCast(h * scale));
    gl.glGenFramebuffers(1, &r.fbo);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, r.fbo);
    gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, r.tex, 0);
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
    target_rt = 0;
    target_size = .{ 640, 480 };
    target_z = z != 0;
    if (s != back_buffer) {
        const dims = d3d.surfDims(s);
        target_rt = rtIndex(s);
        rt_keys.items[target_rt - 1].locked = false;
        target_size = .{ dims.w, dims.h };
    }
    vp = .{ .w = target_size[0], .h = target_size[1] };
}

/// D3DDevice_DrawVerticesUP(PrimitiveType, VertexCount, pVertexStreamZeroData, VertexStreamZeroStride): replaced.
export fn sub_000F8F80() void {
    if (arg(2) != 0) draw(arg(0), arg(1), null, d3d.ptr(arg(2)), arg(3), 0);
    d3d.stdcallRet(4, 0);
}

/// D3DDevice_CopyRects(pSrc, pSrcRects, cRects, pDst, pDstPoints). The source
/// is only on the GPU. A copy over a whole surface (the post effects copy the
/// back buffer every frame) is recorded for the render thread and the surface
/// drawn from like a render target. A copy into part of one (text drawn to the
/// back buffer, then copied into a texture) is read back into the guest surface
/// (syncRead: the render thread first draws the frame so far); the texture
/// cache then sees new bytes.
export fn sub_000F7FC0() void {
    const src = arg(0);
    const rects = arg(1);
    const n = arg(2);
    const dst = arg(3);
    const points = arg(4);
    stats.copies += 1;
    sub_000F7FC0_gen();
    // ponytail: the draw log's frame is the render thread's; this one is a frame or two ahead of it.
    if (drawlog_frame == gframe + 1) std.debug.print("[DRAW] copyrects src={X} dst={X} n={d} rect0={d},{d}-{d},{d} rt={d}\n", .{ src, dst, n, if (rects != 0) mem32(rects) else 0, if (rects != 0) mem32(rects + 4) else 0, if (rects != 0) mem32(rects + 8) else 0, if (rects != 0) mem32(rects + 12) else 0, target_rt });
    if (src == 0 or dst == 0 or !ready()) return;
    // The source need not be the current target: m027's after-image pass copies its
    // offscreen target after switching back to the back buffer.
    const sd = d3d.resData(src);
    const src_rt: u32 = if (src == render_target) target_rt else if (back_buffer != 0 and sd == d3d.resData(back_buffer)) 0 else for (rt_keys.items, 1..) |k, i| {
        if (k.data == sd) break @intCast(i);
    } else return sayOnce("CopyRects from a surface never rendered to skipped");
    const dd = d3d.surfDims(dst);
    const data = d3d.resData(dst);
    const f = d3d.fmtFind((mem32(dst + 0xC) >> 8) & 0xFF);
    const rgba = f != null and f.?.bits == 32 and !d3d.isDxt(f.?);
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
        const sp = if (src_rt == 0) bbSpan(x1, x2) else [2]u32{ x1, x2 };
        if (src_rt == 0 and sp[1] - sp[0] > w) {
            addCopy(data);
            last_wide_copy = gframe;
        } else if (src_rt != 0 and isCopy(src)) addCopy(data);
        // Over the whole surface (the post effects, every frame): the render thread copies.
        if (dx == 0 and dy == 0 and w == dd.w and h == dd.h) {
            const di = rtIndex(dst);
            const k = &rt_keys.items[di - 1];
            k.stale = true;
            k.locked = false;
            k.f = if (rgba) f else null;
            k.pitch = dd.pitch;
            build.ops.append(alloc, .{ .copy = .{ .src = src_rt, .s = .{ @intCast(sp[0] * scale), @intCast(y1 * scale), @intCast(sp[1] * scale), @intCast(y2 * scale) }, .dst = di, .d = .{ @intCast(w * scale), @intCast(h * scale) } } }) catch @panic("OOM");
            continue;
        }
        // Into part of one (text drawn to the back buffer): read back into the guest's bytes.
        if (!rgba) {
            sayOnce("CopyRects into part of a non-32-bit surface skipped");
            continue;
        }
        toGuest(data, true);
        const hw = (sp[1] - sp[0]) * scale;
        putPixels(syncRead(src_rt, sp[0] * scale, y1 * scale, hw, h * scale), hw, w, h, f.?, data, dd.w, dd.h, dd.pitch, dx, dy);
    }
}

/// Host pixels (`hw` a row, `scale` rows a guest row) into the w x h rectangle
/// at dx, dy of a 32-bit guest surface.
/// ponytail: nearest sample of the scaled pixels, not a filtered downscale
fn putPixels(px: []const u8, hw: u32, w: u32, h: u32, f: d3d.Fmt, data: u32, dw: u32, dh: u32, pitch: u32, dx: u32, dy: u32) void {
    const masks = d3d.swizzleMasks(dw, dh);
    const out = d3d.ptr(data);
    for (0..h) |y| for (0..w) |x| {
        const tx: u32 = dx + @as(u32, @intCast(x));
        const ty: u32 = dy + @as(u32, @intCast(y));
        if (tx >= dw or ty >= dh) continue;
        const s = px[((y * scale) * hw + x * hw / w) * 4 ..][0..4];
        const at: u32 = if (f.swizzled) d3d.swizzleIndex(tx, ty, masks) * 4 else ty * (if (pitch != 0) pitch else dw * 4) + tx * 4;
        const o = out[at..][0..4];
        o.* = if (f.kind == .abgr8) .{ s[0], s[1], s[2], s[3] } else .{ s[2], s[1], s[0], s[3] }; // to ARGB in memory (B, G, R, A)
    };
}

/// The game is about to read or write a surface's bytes: if it is a CopyRects
/// destination kept on the GPU, read it back first, and draw from the bytes
/// from here on (game thread; `all`: also when they are not behind).
fn toGuest(data: u32, all: bool) void {
    for (rt_keys.items, 1..) |*k, i| if (k.data == data and (k.stale or all and k.f != null)) {
        const f = k.f orelse return sayOnce("locked a non-32-bit CopyRects destination; its bytes are not the copy");
        if (k.stale) putPixels(syncRead(@intCast(i), 0, 0, k.w * scale, k.h * scale), k.w * scale, k.w, k.h, f, data, k.w, k.h, k.pitch, 0, 0);
        k.stale = false;
        k.locked = true;
    };
}

/// Lock2DSurface(pPixelContainer, FaceType, Level, pLockedRect, pRect, Flags),
/// under D3DTexture_LockRect and D3DSurface_LockRect: see toGuest.
export fn sub_000FE580() void {
    const res = arg(0);
    if (res != 0 and state == .ready and GetCurrentThreadId() == game_tid) toGuest(d3d.resData(res), false);
    sub_000FE580_gen();
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

/// D3DDevice_CreatePixelShader(pPSDef, pHandle): keep the definition, and
/// which one the handle means now. A freed shader's memory is reused
/// (RECOMP_HEAP_RECLAIM), so a handle comes back with another definition;
/// draws already recorded keep the one they were made with.
export fn sub_000F9570() void {
    const def = arg(0);
    const ph = arg(1);
    sub_000F9570_gen();
    if (def == 0 or ph == 0 or mem32(ph) == 0) return;
    const i = psAdd(def);
    if (i != 0) ps_handles.put(alloc, mem32(ph), i) catch @panic("OOM");
}

/// The pixel shader at `def`, by content: index + 1, or 0 when the table is full.
fn psAdd(def: u32) u32 {
    var d: [PsDef.words]u32 = undefined;
    for (&d, 0..) |*w, j| w.* = mem32(def + 4 * @as(u32, @intCast(j)));
    for (pixel_shaders.items, 0..) |*p, i| {
        if (std.mem.eql(u32, &p.def, &d)) return @intCast(i + 1);
    }
    if (pixel_shaders.items.len == pixel_shaders.capacity) {
        sayOnce("pixel shader table full; shader not drawn");
        return 0;
    }
    pixel_shaders.appendAssumeCapacity(.{ .def = d, .va = def });
    return @intCast(pixel_shaders.items.len);
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
    const i = vsAdd(decl, func);
    if (i != 0) vs_handles.put(alloc, mem32(ph), i) catch @panic("OOM");
}

/// The vertex program at `func` with the declaration at `decl`, by content:
/// index + 1, or 0 when the table is full.
fn vsAdd(decl: u32, func: u32) u32 {
    var h: HostVs = .{ .decl = @splat(0xFFFFFFFF), .mc = @splat(0), .nmc = @min(mem32(func) >> 16, 136), .func = func, .decl_va = decl };
    for (0..95) |i| {
        h.decl[i] = if (decl != 0) mem32(decl + 4 * @as(u32, @intCast(i))) else 0xFFFFFFFF;
        if (h.decl[i] == 0xFFFFFFFF) break;
    }
    for (0..h.nmc * 4) |i| h.mc[i] = mem32(func + 4 + 4 * @as(u32, @intCast(i)));
    h.hash = d3d.hashBytes(@ptrCast(&h.mc), @intCast(h.nmc * 16));
    // By content, as pixel shaders are (see CreatePixelShader).
    for (programs.items, 0..) |*p, i| {
        if (p.hash == h.hash and std.mem.eql(u32, &p.decl, &h.decl) and std.mem.eql(u32, &p.mc, &h.mc)) return @intCast(i + 1);
    }
    if (programs.items.len == programs.capacity) {
        sayOnce("vertex program table full; program not drawn");
        return 0;
    }
    programs.appendAssumeCapacity(h);
    return @intCast(programs.items.len);
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

/// Indices go into the pushbuffer on the console, so the title may free its
/// copy once recorded (and memory is reused): keep our own.
fn recordDraw(ri: usize, xprim: u32, n: u32, idx: ?[*]align(1) const u16, base: u32) void {
    const own: ?[*]align(1) const u16 = if (idx) |ix| blk: {
        const c = alloc.alloc(u16, n) catch return;
        for (c, 0..) |*v, i| v.* = ix[i];
        break :blk c.ptr;
    } else null;
    const op = pb_recs.items[ri].ops.addOne(alloc) catch return;
    op.* = .{ .draw = .{ .prim = xprim, .n = n, .idx = own, .base = base, .tex = stage_tex, .vs = vshader, .ps = pshader, .vb = stream_vb[0..4].*, .stride = stream_stride[0..4].*, .state = undefined } };
    d3d.stateBlock(&op.draw.state);
}

fn replay(r: *const PbRec) void {
    const saved = .{ stage_tex, vshader, pshader, stream_vb, stream_stride };
    var live: [d3d.STATE_WORDS]u32 = undefined;
    var eff: [d3d.STATE_WORDS]u32 = undefined;
    d3d.stateBlock(&live);
    if (drawlog_frame == gframe + 1) std.debug.print("[DRAW] replay pushbuffer {X}, {d} ops\n", .{ r.pb, r.ops.items.len });
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
    for (pb_recs.items[i].ops.items) |op| if (op == .draw) if (op.draw.idx) |ix| alloc.free(@as([*]u16, @ptrCast(@alignCast(@constCast(ix))))[0..op.draw.n]);
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
