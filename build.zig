const std = @import("std");

pub fn build(b: *std.Build) void {
    // The release version is build.zig.zon's; CHANGELOG.md has a section for it.
    const info = b.addOptions();
    info.addOption([]const u8, "version", @import("build.zig.zon").version);
    // The commit, asked at build time: Zig caches the configure run, so a
    // b.run here would keep an old HEAD. Modules @embedFile("commit.txt").
    const rev = b.addSystemCommand(&.{ "git", "rev-parse", "--short", "HEAD" });
    rev.has_side_effects = true;
    const commit_txt = rev.captureStdOut(.{});

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

    // ANGLE (GL ES 3 on D3D11/Vulkan/GL): headers, import libs, and the 4 DLLs beside the exe.
    const angle = b.dependency("angle", .{});
    const gl = b.addTranslateC(.{ .root_source_file = b.path("src/gl.h"), .target = target, .optimize = optimize });
    gl.addIncludePath(angle.path("include"));
    mod.addImport("gl", gl.createModule());
    mod.addObjectFile(angle.path("lib/libEGL.dll.lib"));
    mod.addObjectFile(angle.path("lib/libGLESv2.dll.lib"));
    inline for (.{ "libEGL.dll", "libGLESv2.dll", "d3dcompiler_47.dll", "vulkan-1.dll" }) |dll|
        b.getInstallStep().dependOn(&b.addInstallBinFile(angle.path("bin/" ++ dll), dll).step);
    addImgui(b, mod, target, optimize, &.{ "win32", "opengl3" });
    for ([_][]const u8{ "kernel32", "bcrypt", "d3d11", "dxgi", "dxguid", "d3dcompiler_47", "mfplat", "mfreadwrite", "mfuuid", "mf", "ole32", "winmm", "xaudio2_8", "xinput1_4", "dbghelp", "gdi32", "user32" }) |l|
        mod.linkSystemLibrary(l, .{});

    const exe = b.addExecutable(.{ .name = "otogi", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the game").dependOn(&run.step);

    // otogi-setup.exe: builds the game from the player's ISO. It embeds a
    // `git archive` of HEAD, so commit before `zig build setup`.
    const setup_mod = b.createModule(.{ .root_source_file = b.path("setup/main.zig"), .target = target, .optimize = .ReleaseSmall, .link_libc = true });
    addImgui(b, setup_mod, target, .ReleaseSmall, &.{ "win32", "dx11" });
    setup_mod.addCSourceFile(.{ .file = b.path("setup/window.cpp"), .flags = &.{ "-std=c++17", "-O2", "-fno-exceptions", "-fno-rtti", "-w" } });
    setup_mod.addImport("xiso", b.createModule(.{ .root_source_file = b.path("src/xiso.zig"), .target = target }));
    const archive = b.addSystemCommand(&.{ "git", "archive", "--format=zip", "-o" });
    const source_zip = archive.addOutputFileArg("source.zip");
    archive.addArg("HEAD");
    archive.has_side_effects = true;
    setup_mod.addAnonymousImport("source.zip", .{ .root_source_file = source_zip });
    setup_mod.addOptions("build_info", info);
    setup_mod.addAnonymousImport("commit.txt", .{ .root_source_file = commit_txt });
    for ([_][]const u8{ "d3d11", "dxgi", "d3dcompiler_47", "comdlg32", "user32", "gdi32", "ole32", "shell32", "advapi32" }) |l| setup_mod.linkSystemLibrary(l, .{});
    const setup = b.addExecutable(.{ .name = "otogi-setup", .root_module = setup_mod });
    setup.subsystem = .windows;
    b.step("setup", "Build otogi-setup.exe").dependOn(&b.addInstallArtifact(setup, .{}).step);

    const test_step = b.step("test", "Run tests");
    inline for (.{ "src/xiso.zig", "src/d3d.zig", "src/pad.zig" }) |f| {
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

/// Dear ImGui (C++) plus its C API from dear_bindings, as module "imgui".
/// Backends are called through hand-declared externs (see debug_menu.zig).
fn addImgui(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, comptime backends: []const []const u8) void {
    const imgui = b.dependency("imgui", .{});
    const bind = b.dependency("dear_bindings", .{});
    const flags: []const []const u8 = &.{ "-std=c++17", "-O2", "-fno-exceptions", "-fno-rtti", "-w", "-DIMGUI_IMPL_OPENGL_ES3", "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS" };
    for ([_]std.Build.LazyPath{ imgui.path(""), imgui.path("backends"), bind.path(""), bind.path("backends"), b.dependency("angle", .{}).path("include") }) |p| mod.addIncludePath(p);
    mod.addCSourceFiles(.{ .root = imgui.path(""), .files = &.{ "imgui.cpp", "imgui_draw.cpp", "imgui_tables.cpp", "imgui_widgets.cpp", "imgui_demo.cpp" }, .flags = flags });
    mod.addCSourceFile(.{ .file = bind.path("dcimgui.cpp"), .flags = flags });
    inline for (backends) |be| {
        mod.addCSourceFile(.{ .file = imgui.path("backends/imgui_impl_" ++ be ++ ".cpp"), .flags = flags });
        mod.addCSourceFile(.{ .file = bind.path("backends/dcimgui_impl_" ++ be ++ ".cpp"), .flags = flags });
    }
    mod.link_libcpp = true;
    mod.linkSystemLibrary("dwmapi", .{});
    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/imgui.h"), .target = target, .optimize = optimize });
    tc.addIncludePath(bind.path(""));
    tc.addIncludePath(imgui.path(""));
    mod.addImport("imgui", tc.createModule());
}

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
    mod.addCSourceFiles(.{ .root = b.path("src/recomp/gen"), .files = files.items, .flags = &.{ "-std=gnu11", "-O1", "-fno-strict-aliasing", "-fwrapv", "-w" } });
}

// Windows source set from xboxrecomp's CMakeLists (minus the SDL/POSIX-only files).
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
    "input/input_map.c",          "input/xinput_device.c",
    "input/keyboard.c",           "input/mkb_input.c",
    "video/video_player.c",       "video/video_pump.c",
    "video/fb_present.c",         "video/gpu_present.c",
};
