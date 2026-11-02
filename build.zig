const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu } });
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off, // guest structs are 4-byte aligned; UBSan alignment checks fire on every one
    });
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
    for ([_][]const u8{ "kernel32", "bcrypt", "d3d11", "dxgi", "dxguid", "d3dcompiler_47", "mfplat", "mfreadwrite", "mfuuid", "mf", "ole32", "winmm", "xaudio2_8", "xinput1_4", "dbghelp", "gdi32", "user32" }) |l|
        mod.linkSystemLibrary(l, .{});

    const exe = b.addExecutable(.{ .name = "otogi", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the game").dependOn(&run.step);

    const t = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/xiso.zig"), .target = b.graph.host }) });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(t).step);

    const xiso = b.addExecutable(.{ .name = "xiso", .root_module = b.createModule(.{ .root_source_file = b.path("src/xiso.zig"), .target = b.graph.host, .optimize = .ReleaseFast }) });
    const unpack = b.addRunArtifact(xiso);
    unpack.addPassthruArgs();
    b.step("unpack", "Unpack an Xbox ISO: zig build unpack -- <iso> <out_dir>").dependOn(&unpack.step);

    const pe = b.addRunArtifact(b.addExecutable(.{ .name = "xbe_to_pe", .root_module = b.createModule(.{ .root_source_file = b.path("src/xbe_to_pe.zig"), .target = b.graph.host }) }));
    pe.addPassthruArgs();
    b.step("pe", "Wrap the XBE in a PE32 for REA/Ghidra: zig build pe -- <xbe> <out.exe>").dependOn(&pe.step);
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
