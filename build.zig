const std = @import("std");

pub fn build(b: *std.Build) void {
    // The release version is build.zig.zon's; CHANGELOG.md has a section for it.
    const info = b.addOptions();
    info.addOption([]const u8, "version", @import("build.zig.zon").version);
    // The commit, asked at build time: Zig caches the configure run, so a
    // b.run here would keep an old HEAD. Modules @embedFile("commit.txt").
    // Setup's copy of the source has no .git (nor git); it writes commit.txt.
    const commit_txt = if (b.root.access(b.graph.io, "commit.txt", .{})) |_| b.path("commit.txt") else |_| blk: {
        const rev = b.addSystemCommand(&.{ "git", "rev-parse", "--short", "HEAD" });
        rev.has_side_effects = true;
        break :blk rev.captureStdOut(.{});
    };

    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } });
    // ReleaseFast by default: the Debug renderer cannot hold the game's frame rate.
    const optimize = b.option(std.builtin.Optimize, "optimize", "Optimization mode (default fast)") orelse .fast;

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off, // guest structs are 4-byte aligned; UBSan alignment checks fire on every one
    });
    mod.addOptions("build_info", info);
    mod.addAnonymousImport("commit.txt", .{ .root_source_file = commit_txt });
    mod.addCMacro("WIN32_LEAN_AND_MEAN", "");
    mod.addCMacro("NOMINMAX", "");
    mod.addIncludePath(b.path("xboxrecomp/include"));
    mod.addIncludePath(b.path("xboxrecomp/src"));
    inline for (.{ "kernel", "d3d", "audio", "apu", "nv2a", "usb", "input", "video", "platform" }) |d|
        mod.addIncludePath(b.path("xboxrecomp/src/" ++ d));
    mod.addCSourceFiles(.{ .root = b.path("xboxrecomp/src"), .files = &toolkit_c, .flags = &.{ "-std=gnu11", "-O2", "-fno-strict-aliasing", "-w" } });
    addGenerated(b, mod);
    // settings.ini as a form, shared with the launcher (the F10 settings page).
    mod.addImport("logic", b.createModule(.{ .root_source_file = b.path("setup/logic.zig"), .target = target, .optimize = optimize }));

    // ANGLE (GL ES 3 on D3D11/Vulkan/GL): headers, import libs, and the 4 DLLs beside the exe.
    const angle = b.dependency("angle", .{});
    const gl = b.addTranslateC(.{ .root_source_file = b.path("src/gl.h"), .target = target, .optimize = optimize });
    gl.addIncludePath(angle.path("include"));
    mod.addImport("gl", gl.createModule());
    mod.addObjectFile(angle.path("lib/libEGL.dll.lib"));
    mod.addObjectFile(angle.path("lib/libGLESv2.dll.lib"));
    inline for (.{ "libEGL.dll", "libGLESv2.dll", "d3dcompiler_47.dll", "vulkan-1.dll" }) |dll|
        b.getInstallStep().dependOn(&b.addInstallBinFile(angle.path("bin/" ++ dll), dll).step);
    // SDL3 (window, events, gamepads): the official prebuilt DLL beside the exe.
    const sdl_dir = b.dependency("sdl", .{}).path("x86_64-w64-mingw32");
    const sdl = b.addTranslateC(.{ .root_source_file = b.path("src/sdl.h"), .target = target, .optimize = optimize });
    sdl.addIncludePath(sdl_dir.path(b, "include"));
    mod.addImport("sdl", sdl.createModule());
    mod.addObjectFile(sdl_dir.path(b, "lib/libSDL3.dll.a"));
    b.getInstallStep().dependOn(&b.addInstallBinFile(sdl_dir.path(b, "bin/SDL3.dll"), "SDL3.dll").step);
    // The menus (F1 debug, F10 settings, the metrics overlay): RmlUi drawn
    // by its GL3 renderer in GL ES 3 mode on ANGLE, fed SDL3's events
    // (src/ui.cpp), in the launcher's theme and font. A library of its own, so
    // its flags stay off the lifted C.
    const ui = b.addLibrary(.{ .name = "ui", .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseSmall, .link_libc = true }) });
    ui.root_module.addIncludePath(sdl_dir.path(b, "include"));
    ui.root_module.addIncludePath(angle.path("include"));
    // RMLUI_PLATFORM_EMSCRIPTEN picks the renderer's GL ES 3 path (shaders, GLES3/gl3.h): only that file reads it.
    addRmlUi(b, ui.root_module, &.{ "RmlUi_Platform_SDL.cpp", "RmlUi_Renderer_GL3.cpp" }, "src/ui.cpp", &.{ "-DRMLUI_SDL_VERSION_MAJOR=3", "-DRMLUI_PLATFORM_EMSCRIPTEN" });
    mod.linkLibrary(ui);
    mod.link_libcpp = true;
    mod.addAnonymousImport("theme.rcss", .{ .root_source_file = b.path("setup/ui/theme.rcss") });
    mod.addAnonymousImport("ShipporiMinchoB1-Bold.ttf", .{ .root_source_file = b.path("setup/assets/ShipporiMinchoB1-Bold.ttf") });
    for ([_][]const u8{ "kernel32", "bcrypt", "d3d11", "dxgi", "dxguid", "d3dcompiler_47", "mfplat", "mfreadwrite", "mfuuid", "mf", "ole32", "winmm", "xaudio2_8", "dbghelp", "gdi32", "user32" }) |l|
        mod.linkSystemLibrary(l, .{});

    mod.addWin32ResourceFile(.{ .file = b.path("src/otogi.rc") }); // the icon
    const exe = b.addExecutable(.{ .name = "otogi", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the game").dependOn(&run.step);

    // otogi-xunchain.exe, the launcher: builds the game from the player's ISO,
    // plays it, edits settings, updates. It embeds a `git archive` of HEAD, so
    // commit before `zig build setup`. Not in the player's own build (that copy
    // has commit.txt and no .git).
    const setup_step = b.step("setup", "Build otogi-xunchain.exe (the launcher)");
    const test_step = b.step("test", "Run tests");
    if (b.root.access(b.graph.io, "commit.txt", .{})) |_| {} else |_| {
        const setup_mod = launcherModule(b, target);
        setup_mod.addImport("xiso", b.createModule(.{ .root_source_file = b.path("src/xiso.zig"), .target = target }));
        const archive = b.addSystemCommand(&.{ "git", "archive", "--format=zip", "-o" });
        const source_zip = archive.addOutputFileArg("source.zip");
        archive.addArg("HEAD");
        archive.has_side_effects = true;
        setup_mod.addAnonymousImport("source.zip", .{ .root_source_file = source_zip });
        setup_mod.addOptions("build_info", info);
        setup_mod.addAnonymousImport("commit.txt", .{ .root_source_file = commit_txt });
        const setup = b.addExecutable(.{ .name = "otogi-xunchain", .root_module = setup_mod });
        setup.subsystem = .windows;
        setup_step.dependOn(&b.addInstallArtifact(setup, .{}).step);
    }

    // setup/logic.zig: the launcher's settings.ini, release notes and versions.
    inline for (.{ "src/xiso.zig", "src/d3d.zig", "src/pad.zig", "src/pacer.zig", "setup/logic.zig" }) |f| {
        const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path(f), .target = b.graph.host, .link_libc = true }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const xiso = b.addExecutable(.{ .name = "xiso", .root_module = b.createModule(.{ .root_source_file = b.path("src/xiso.zig"), .target = b.graph.host, .optimize = .ReleaseFast }) });
    const unpack = b.addRunArtifact(xiso);
    unpack.addPassthruArgs();
    b.step("unpack", "Unpack an Xbox ISO: zig build unpack -- <iso> <out_dir>").dependOn(&unpack.step);

    const pe = b.addRunArtifact(b.addExecutable(.{ .name = "xbe_to_pe", .root_module = b.createModule(.{ .root_source_file = b.path("src/xbe_to_pe.zig"), .target = b.graph.host }) }));
    pe.addPassthruArgs();
    b.step("pe", "Wrap the XBE in a PE32 for REA/Ghidra: zig build pe -- <xbe> <out.exe>").dependOn(&pe.step);
}

/// The launcher's module: setup/main.zig, its Win32 + D3D11 host (setup/window.cpp),
/// RmlUi with its Win32 platform and DX11 renderer.
fn launcherModule(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Module {
    const mod = b.createModule(.{ .root_source_file = b.path("setup/main.zig"), .target = target, .optimize = .ReleaseSmall, .link_libc = true });
    addRmlUi(b, mod, &.{ "RmlUi_Platform_Win32.cpp", "RmlUi_Renderer_DX11.cpp" }, "setup/window.cpp", &.{});
    mod.addWin32ResourceFile(.{ .file = b.path("setup/launcher.rc") }); // the icon
    for ([_][]const u8{ "d3d11", "dxgi", "d3dcompiler_47", "dwmapi", "imm32", "xinput1_4", "comdlg32", "user32", "gdi32", "ole32", "shell32", "advapi32", "windowscodecs" }) |l| mod.linkSystemLibrary(l, .{});
    return mod;
}

/// RmlUi 6.3's core (Source/Core, walked at configure time) and FreeType for
/// its fonts, all by `zig c++`/`zig cc`, no CMake; then `backends` (RmlUi's
/// Backends/) and the `host` file that drives them, with `flags` added.
fn addRmlUi(b: *std.Build, mod: *std.Build.Module, backends: []const []const u8, host: []const u8, flags: []const []const u8) void {
    const rml = b.dependency("rmlui", .{});
    const ft = b.dependency("freetype", .{});
    mod.addCMacro("RMLUI_STATIC_LIB", "");
    mod.addCMacro("RMLUI_FONT_ENGINE_FREETYPE", "");
    mod.addCMacro("FT2_BUILD_LIBRARY", "");
    mod.addCMacro("NDEBUG", ""); // else RmlUi asserts, and its GL renderer checks glGetError after each call
    for ([_]std.Build.LazyPath{ rml.path("Include"), rml.path("Backends"), ft.path("include") }) |p| mod.addIncludePath(p);
    mod.addCSourceFiles(.{ .root = ft.path("src"), .files = &freetype_c, .flags = &.{ "-std=c99", "-Os", "-w" } });

    const cpp: []const []const u8 = &.{ "-std=c++17", "-Os", "-w", "-DRMLUI_VERSION=\"6.3\"", "-D_WIN32_WINNT=0x0A00" };
    var files: std.ArrayList([]const u8) = .empty;
    const core_path = rml.builder.root.join(b.allocator, "Source/Core") catch @panic("OOM");
    var core = core_path.root_dir.handle.openDir(b.graph.io, core_path.sub_path, .{ .iterate = true }) catch @panic("RmlUi: no Source/Core");
    defer core.close(b.graph.io);
    var walk = core.walk(b.allocator) catch @panic("OOM");
    while (walk.next(b.graph.io) catch null) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.basename, ".cpp")) files.append(b.allocator, b.dupe(e.path)) catch @panic("OOM");
    }
    mod.addCSourceFiles(.{ .root = rml.path("Source/Core"), .files = files.items, .flags = cpp });
    const own = std.mem.concat(b.allocator, []const u8, &.{ cpp, flags }) catch @panic("OOM");
    mod.addCSourceFiles(.{ .root = rml.path("Backends"), .files = backends, .flags = own });
    mod.addCSourceFile(.{ .file = b.path(host), .flags = own });
    mod.link_libcpp = true;
}

/// FreeType with its default module list (include/freetype/config/ftmodule.h).
const freetype_c = [_][]const u8{
    "base/ftsystem.c",   "base/ftinit.c",     "base/ftdebug.c",     "base/ftbase.c",
    "base/ftbbox.c",     "base/ftbdf.c",      "base/ftbitmap.c",    "base/ftcid.c",
    "base/ftfstype.c",   "base/ftgasp.c",     "base/ftglyph.c",     "base/ftgxval.c",
    "base/ftmm.c",       "base/ftotval.c",    "base/ftpatent.c",    "base/ftpfr.c",
    "base/ftstroke.c",   "base/ftsynth.c",    "base/fttype1.c",     "base/ftwinfnt.c",
    "autofit/autofit.c", "bdf/bdf.c",         "cff/cff.c",          "cid/type1cid.c",
    "gzip/ftgzip.c",     "lzw/ftlzw.c",       "pcf/pcf.c",          "pfr/pfr.c",
    "psaux/psaux.c",     "pshinter/pshinter.c", "psnames/psnames.c", "raster/raster.c",
    "sdf/sdf.c",         "sfnt/sfnt.c",       "smooth/smooth.c",    "svg/svg.c",
    "truetype/truetype.c", "type1/type1.c",   "type42/type42.c",    "winfonts/winfnt.c",
};

/// Lifted C from `tools.recomp --gen-dir src/recomp/gen` (gitignored, absent on a fresh clone).
fn addGenerated(b: *std.Build, mod: *std.Build.Module) void {
    const io = b.graph.io;
    const gen = b.root.join(b.allocator, "src/recomp/gen") catch @panic("OOM");
    var dir = gen.root_dir.handle.openDir(io, gen.sub_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var files: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".c")) files.append(b.allocator, b.dupe(e.name)) catch @panic("OOM");
    }
    mod.addIncludePath(b.path("src/recomp/gen"));
    mod.addCSourceFiles(.{ .root = b.path("src/recomp/gen"), .files = files.items, .flags = &.{ "-std=gnu11", "-O2", "-fno-strict-aliasing", "-fwrapv", "-w" } });
}

// Windows source set from xboxrecomp's CMakeLists (minus the SDL/POSIX-only files).
// input/xinput_device.c is left out too: src/input.zig (SDL3) stands in for it.
const toolkit_c = [_][]const u8{
    "platform/host_time.c",       "platform/recomp_exit_hook.c",
    "kernel/kernel_path.c",       "kernel/kernel_pool.c",
    "kernel/kernel_rtl.c",        "kernel/kernel_memory.c",
    "kernel/kernel_file.c",       "kernel/kernel_missing.c",
    "kernel/kernel_thread.c",     "kernel/kernel_sync.c",
    "kernel/kernel_hal.c",        "kernel/kernel_guest_cpu.c",
    "kernel/kernel_xbox.c",       "kernel/kernel_ob.c",
    "kernel/kernel_io.c",         "kernel/kernel_crypto.c",
    "kernel/kernel_thunks.c",     "kernel/kernel_bridge.c",
    "kernel/xbox_memory_layout.c", "kernel/guest_vmem.c",
    "kernel/icall_feedback.c",    "kernel/recomp_trace.c",
    "kernel/nv2a_pb_scan.c",      "kernel/nv2a_pb_exec.c",
    "kernel/nv2a_flip_hold.c",    "kernel/nv2a_vsh_interp.c",
    "kernel/nv2a_combiner.c",     "d3d/d3d8_device.c",
    "d3d/d3d8_gamma.c",           "d3d/d3d8_resources.c",
    "d3d/d3d8_shaders.c",         "d3d/d3d8_states.c",
    "d3d/d3d8_combiners.c",       "d3d/d3d8_vsh.c",
    "audio/dsound_device.c",      "audio/wma_decoder.c",
    "apu/apu_core.c",             "apu/apu_vp.c",
    "apu/apu_dsp.c",              "apu/apu_mmio_hook.c",
    "apu/apu_xaudio2.c",          "apu/apu_sdl2.c",
    "apu/apu_wav.c",              "nv2a/nv2a_core.c",
    "nv2a/nv2a_pgraph_d3d11.c",   "nv2a/nv2a_pb_replay.c",
    "nv2a/nv2a_mmio_hook.c",      "nv2a/nv2a_pb_test.c",
    "usb/ohci.c",                 "usb/usb_gamepad.c",
    "input/input_map.c",          "input/keyboard.c",
    "input/mkb_input.c",          "video/video_player.c",
    "video/video_pump.c",         "video/fb_present.c",
    "video/gpu_present.c",
};
