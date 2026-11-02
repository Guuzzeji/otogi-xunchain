//! Boot: map the XBE, bring up the kernel replacement, run the lifted entry point.
//! Port of xboxrecomp/templates/new-game/src/main.c.
const std = @import("std");
const w = std.os.windows;

comptime {
    _ = @import("manual.zig");
    _ = @import("gl_hle.zig");
}

const XBE_ENTRY: u32 = 0x000E43B7;

// Runtime (xboxrecomp/src/kernel). The guest registers are __thread in the C side:
// they must be declared threadlocal here or g_esp lands in the TLS template.
extern threadlocal var g_eax: u32;
extern threadlocal var g_ecx: u32;
extern threadlocal var g_edx: u32;
extern threadlocal var g_esp: u32;
extern threadlocal var g_ebx: u32;
extern threadlocal var g_esi: u32;
extern threadlocal var g_edi: u32;
extern var g_xbox_mem_offset: isize;
extern var g_xbox_code_lo: u32;
extern var g_xbox_code_hi: u32;
extern var g_xbox_stack_base: u32;
extern var g_xbox_stack_size: u32;
extern var g_icall_trace: [16]u32;
extern var g_icall_trace_idx: u32;
extern var g_apu_state: ?*anyopaque;

extern fn xbox_MemoryLayoutInit(xbe_data: [*]const u8, xbe_size: usize) c_int;
extern fn xbox_MemoryLayoutShutdown() void;
extern fn xbox_GetMemoryBase() [*]u8;
extern fn xbox_VehMmioFault(ep: *w.EXCEPTION_POINTERS) c_int;
extern fn xbox_WatchdogStart() void;
extern fn xbox_kernel_init() void;
extern fn xbox_kernel_shutdown() void;
extern fn xbox_kernel_bridge_init() void;
extern fn xbox_path_init(game_dir: [*:0]const u8, save_dir: ?[*:0]const u8) void;
extern fn mcpx_apu_init_standalone(ram: [*]u8) ?*anyopaque;
extern fn recomp_dispatch_init() c_int;
extern fn xbe_entry_point() void;

// Win32 / CRT bits std does not declare.
extern "kernel32" fn AddVectoredExceptionHandler(first: u32, handler: w.VECTORED_EXCEPTION_HANDLER) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateDirectoryA(path: [*:0]const u8, sa: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn CreateFileA(name: [*:0]const u8, access: u32, share: u32, sa: ?*anyopaque, disp: u32, flags: u32, tmpl: ?w.HANDLE) callconv(.winapi) w.HANDLE;
extern "kernel32" fn SetStdHandle(which: u32, h: w.HANDLE) callconv(.winapi) c_int;
extern "winmm" fn timeBeginPeriod(ms: u32) callconv(.winapi) u32;
extern "dbghelp" fn SymSetOptions(opts: u32) callconv(.winapi) u32;
extern "dbghelp" fn SymInitialize(process: w.HANDLE, search: ?[*:0]const u8, invade: c_int) callconv(.winapi) c_int;
extern "dbghelp" fn SymFromAddr(process: w.HANDLE, addr: u64, disp: *u64, sym: *SymbolInfo) callconv(.winapi) c_int;
extern fn _open_osfhandle(h: isize, flags: c_int) c_int;
extern fn _dup2(from: c_int, to: c_int) c_int;
extern fn __acrt_iob_func(i: c_uint) *anyopaque;
extern fn setvbuf(f: *anyopaque, buf: ?[*]u8, mode: c_int, size: usize) c_int;
extern fn _putenv(s: [*:0]const u8) c_int;

const SymbolInfo = extern struct {
    SizeOfStruct: u32 = 88, // sizeof(SYMBOL_INFO) on x64; Name is written past it
    TypeIndex: u32 = 0,
    Reserved: [2]u64 = .{ 0, 0 },
    Index: u32 = 0,
    Size: u32 = 0,
    ModBase: u64 = 0,
    Flags: u32 = 0,
    Value: u64 = 0,
    Address: u64 = 0,
    Register: u32 = 0,
    Scope: u32 = 0,
    Tag: u32 = 0,
    NameLen: u32 = 0,
    MaxNameLen: u32 = 255,
    Name: [256]u8 = undefined,
};

const print = std.debug.print;

/// Send stdout, stderr (CRT and Win32) to logs\otogi.log, unbuffered so a crash loses nothing.
fn openLog() void {
    _ = CreateDirectoryA("logs", null);
    const h = CreateFileA("logs\\otogi.log", 0x40000000, 1, null, 2, 0, null); // GENERIC_WRITE, FILE_SHARE_READ, CREATE_ALWAYS
    if (h == w.INVALID_HANDLE_VALUE) return;
    _ = SetStdHandle(@bitCast(@as(i32, -11)), h);
    _ = SetStdHandle(@bitCast(@as(i32, -12)), h);
    const fd = _open_osfhandle(@bitCast(@intFromPtr(h)), 0x8000); // _O_BINARY
    _ = _dup2(fd, 1);
    _ = _dup2(fd, 2);
    for ([_]c_uint{ 1, 2 }) |i| _ = setvbuf(__acrt_iob_func(i), null, 4, 0); // _IONBF
}

/// Name the lifted function a fault is in (sub_XXXXXXXX via the PDB) and scan the
/// guest stack for return addresses. A scan, not a walk: FPO frames have no ebp chain.
fn printGuestContext(rip: u64) void {
    var sym: SymbolInfo = .{};
    var disp: u64 = 0;
    if (SymFromAddr(w.GetCurrentProcess(), rip, &disp, &sym) != 0)
        print("  in {s}+0x{X}\n", .{ sym.Name[0..sym.NameLen], disp });
    if (g_xbox_mem_offset == 0 or g_esp == 0) return;
    const sp: [*]const u32 = @ptrFromInt(@as(usize, @bitCast(g_xbox_mem_offset)) + g_esp);
    print("  guest stack (return addresses, innermost first):\n", .{});
    var shown: u32 = 0;
    for (0..256) |i| {
        if (sp[i] > g_xbox_code_lo and sp[i] < g_xbox_code_hi) {
            print("    [esp+{d:<4}] 0x{X:0>8}\n", .{ i * 4, sp[i] });
            shown += 1;
            if (shown == 24) break;
        }
    }
    if (shown != 0) return;
    // Nothing in range: the frame is gone. Show what the stack cannot overwrite.
    print("    (no return addresses in range)\n  recent ICALL targets:", .{});
    for (0..16) |k| print(" {X:0>8}", .{g_icall_trace[(g_icall_trace_idx +% @as(u32, @intCast(k))) & 15]});
    print("\n", .{});
    for (0..20) |i| print("    raw[esp+{d:<4}] 0x{X:0>8}\n", .{ i * 4, sp[i] });
}

fn vehHandler(ep: *w.EXCEPTION_POINTERS) callconv(.winapi) c_long {
    const rec = ep.ExceptionRecord;
    if (rec.ExceptionCode != w.EXCEPTION_ACCESS_VIOLATION) return 0; // EXCEPTION_CONTINUE_SEARCH
    // Trapped hardware registers (APU, USB OHCI) are decoded and stepped over.
    if (xbox_VehMmioFault(ep) != 0) return -1; // EXCEPTION_CONTINUE_EXECUTION
    const fault = rec.ExceptionInformation[1];
    const ctx = ep.ContextRecord;
    print("[CRASH] Access violation at RIP=0x{X}, fault addr=0x{X} ({s})\n", .{ ctx.Rip, fault, if (rec.ExceptionInformation[0] != 0) "write" else "read" });
    print("  Xbox regs: eax=0x{X:0>8} ecx=0x{X:0>8} edx=0x{X:0>8} esp=0x{X:0>8}\n", .{ g_eax, g_ecx, g_edx, g_esp });
    print("  Xbox regs: ebx=0x{X:0>8} esi=0x{X:0>8} edi=0x{X:0>8}\n", .{ g_ebx, g_esi, g_edi });
    print("  Xbox VA of fault: 0x{X:0>8}\n", .{@as(u32, @truncate(fault -% @as(usize, @bitCast(g_xbox_mem_offset))))});
    printGuestContext(ctx.Rip);
    return 0;
}

pub fn main(init: std.process.Init) !void {
    openLog();
    _ = timeBeginPeriod(1);
    // Toolkit switches Otogi needs. The environment still wins.
    //  RECOMP_ASYNC_IO: async-opened files must return STATUS_PENDING; the
    //    stream loader only reads the byte count on that path (else disc error).
    //  RECOMP_VBLANK: vblank interrupts, so D3D and the game get frame ticks.
    //  RECOMP_AC97_READY: the emulated APU. Without DirectSound the game never
    //    starts its sound-stream worker, and the main menu waits on it forever.
    inline for (.{ "RECOMP_ASYNC_IO", "RECOMP_VBLANK", "RECOMP_AC97_READY" }) |v| {
        if (std.c.getenv(v) == null) _ = _putenv(v ++ "=1");
    }
    print("=== Otogi: Myth of Demons - static recompilation ===\n", .{});

    // Symbols up front: SymInitialize allocates, which is unsafe inside the handler.
    _ = SymSetOptions(0x4 | 0x2); // SYMOPT_DEFERRED_LOADS | SYMOPT_UNDNAME
    _ = SymInitialize(w.GetCurrentProcess(), null, 1);
    _ = AddVectoredExceptionHandler(1, vehHandler);

    const xbe = try std.Io.Dir.cwd().readFileAlloc(init.io, "game/default.xbe", init.arena.allocator(), .unlimited);
    if (xbox_MemoryLayoutInit(xbe.ptr, xbe.len) == 0) return error.MemoryLayoutInit;
    print("XBE mapped: {d} bytes, offset 0x{X}\n", .{ xbe.len, g_xbox_mem_offset });

    // The APU model and the AC97 register trap are useless apart; both follow this variable.
    if (std.c.getenv("RECOMP_AC97_READY") != null) {
        g_apu_state = mcpx_apu_init_standalone(xbox_GetMemoryBase());
        print("[BOOT] emulated APU {s}\n", .{if (g_apu_state != null) "up" else "FAILED to initialise"});
    }

    xbox_kernel_init();
    xbox_path_init("game", null); // D:\ -> game\, saves under SaveData\
    xbox_kernel_bridge_init();
    g_esp = g_xbox_stack_base + g_xbox_stack_size - 16; // XBOX_STACK_TOP

    if (recomp_dispatch_init() == 0) print("[BOOT] flat dispatch unavailable; indirect calls use the binary search\n", .{});
    xbox_WatchdogStart(); // inert unless RECOMP_WATCHDOG_SECS is set

    print("Starting game at 0x{X:0>8}, esp 0x{X:0>8}\n", .{ XBE_ENTRY, g_esp });
    xbe_entry_point();

    print("Game returned.\n", .{});
    xbox_kernel_shutdown();
    xbox_MemoryLayoutShutdown();
}

// Referenced by xboxrecomp's nv2a_pb_replay.c (another game's frontend hooks); unused by Otogi.
export var g_suppress_present: c_int = 0;
export var g_fe_cursor: c_int = 0;
export fn fe_menu_get_pb_state() c_int {
    return 0;
}
