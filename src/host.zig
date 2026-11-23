//! The few OS calls the host makes that std has no io-free form of: Win32 on
//! Windows, libc on Linux. Callable from any thread, C callbacks included.
const std = @import("std");
const builtin = @import("builtin");
pub const windows = builtin.os.tag == .windows;

/// A lock and one condition on it.
pub const Lock = struct {
    m: if (windows) ?*anyopaque else std.c.pthread_mutex_t = if (windows) null else .{},
    c: if (windows) ?*anyopaque else std.c.pthread_cond_t = if (windows) null else .{},

    pub fn lock(l: *Lock) void {
        if (windows) AcquireSRWLockExclusive(&l.m) else _ = std.c.pthread_mutex_lock(&l.m);
    }
    pub fn unlock(l: *Lock) void {
        if (windows) ReleaseSRWLockExclusive(&l.m) else _ = std.c.pthread_mutex_unlock(&l.m);
    }
    /// Holding the lock: sleep until wakeAll, or `ms` pass (0xFFFFFFFF: no limit).
    pub fn wait(l: *Lock, ms: u32) void {
        if (windows) {
            _ = SleepConditionVariableSRW(&l.c, &l.m, ms, 0);
        } else if (ms == 0xFFFFFFFF) {
            _ = std.c.pthread_cond_wait(&l.c, &l.m);
        } else {
            var t: std.c.timespec = undefined;
            _ = clock_gettime(CLOCK_REALTIME, &t);
            const ns = @as(i64, t.nsec) + @as(i64, ms % 1000) * std.time.ns_per_ms;
            t.sec += @intCast(ms / 1000 + @as(u32, @intCast(@divTrunc(ns, std.time.ns_per_s))));
            t.nsec = @intCast(@mod(ns, std.time.ns_per_s));
            _ = std.c.pthread_cond_timedwait(&l.c, &l.m, &t);
        }
    }
    pub fn wakeAll(l: *Lock) void {
        if (windows) WakeAllConditionVariable(&l.c) else _ = std.c.pthread_cond_broadcast(&l.c);
    }
};

/// Milliseconds on a steady clock.
pub fn nowMs() f64 {
    if (windows) {
        var f: i64 = 0;
        var t: i64 = 0;
        _ = QueryPerformanceFrequency(&f);
        _ = QueryPerformanceCounter(&t);
        return @as(f64, @floatFromInt(t)) * 1000 / @as(f64, @floatFromInt(f));
    }
    var t: std.c.timespec = undefined;
    _ = clock_gettime(CLOCK_MONOTONIC, &t);
    return @as(f64, @floatFromInt(t.sec)) * 1000 + @as(f64, @floatFromInt(t.nsec)) / 1e6;
}

pub fn sleepMs(ms: u32) void {
    if (windows) return Sleep(ms);
    const t: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    _ = nanosleep(&t, null);
}

pub fn mkdir(path: [*:0]const u8) void {
    _ = if (windows) _mkdir(path) else std.c.mkdir(path, 0o755);
}

/// name=value in this process's environment (C getenv sees it).
pub fn setEnv(name: [*:0]const u8, value: [*:0]const u8) void {
    _ = if (windows) _putenv_s(name, value) else setenv(name, value, 1);
}

/// The calling thread, for threadCpu.
pub const Thread = if (windows) ?*anyopaque else c_int;
pub fn currentThread() Thread {
    if (windows) return OpenThread(0x0800, 0, GetCurrentThreadId()); // THREAD_QUERY_LIMITED_INFORMATION
    var clk: c_int = 0;
    _ = pthread_getcpuclockid(std.c.pthread_self(), &clk);
    return clk;
}

/// CPU time (kernel + user) in 100 ns units: the whole process, and one thread.
pub fn processCpu() u64 {
    if (windows) {
        var c: u64 = 0;
        var e: u64 = 0;
        var k: u64 = 0;
        var u: u64 = 0;
        _ = GetProcessTimes(GetCurrentProcess(), &c, &e, &k, &u);
        return k + u;
    }
    return clockTicks(CLOCK_PROCESS_CPUTIME_ID);
}
pub fn threadCpu(t: Thread) u64 {
    if (windows) {
        var c: u64 = 0;
        var e: u64 = 0;
        var k: u64 = 0;
        var u: u64 = 0;
        _ = GetThreadTimes(t orelse GetCurrentThread(), &c, &e, &k, &u);
        return k + u;
    }
    return clockTicks(t);
}
fn clockTicks(clk: c_int) u64 {
    var t: std.c.timespec = undefined;
    if (clock_gettime(clk, &t) != 0) return 0;
    return @as(u64, @intCast(t.sec)) * 10_000_000 + @as(u64, @intCast(t.nsec)) / 100;
}

/// RAM in use, the part no other process shares, and the peak, in bytes.
pub const Mem = struct { in_use: usize = 0, private: usize = 0, peak: usize = 0 };
pub fn memory() Mem {
    if (windows) {
        var m: MemCounters = .{};
        _ = K32GetProcessMemoryInfo(GetCurrentProcess(), &m, @sizeOf(MemCounters));
        return .{ .in_use = m.working_set, .private = m.private, .peak = m.peak_working_set };
    }
    // /proc/self/statm: size resident shared ... in pages; ru_maxrss in KB.
    var buf: [128]u8 = undefined;
    const fd = std.c.open("/proc/self/statm", .{});
    if (fd < 0) return .{};
    const n = std.c.read(fd, &buf, buf.len);
    _ = std.c.close(fd);
    var it = std.mem.tokenizeScalar(u8, buf[0..@intCast(@max(n, 0))], ' ');
    _ = it.next();
    const res = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
    const shared = std.fmt.parseInt(usize, it.next() orelse "0", 10) catch 0;
    var ru: [144]u8 align(8) = @splat(0); // struct rusage; ru_maxrss is at 32
    _ = getrusage(0, &ru);
    return .{ .in_use = res * 4096, .private = (res -| shared) * 4096, .peak = std.mem.readInt(usize, ru[32..40], .little) * 1024 };
}

// Win32
extern "kernel32" fn AcquireSRWLockExclusive(*?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(*?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn SleepConditionVariableSRW(*?*anyopaque, *?*anyopaque, ms: u32, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn WakeAllConditionVariable(*?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn OpenThread(access: u32, inherit: i32, id: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "kernel32" fn GetCurrentThread() callconv(.winapi) *anyopaque;
extern "kernel32" fn GetProcessTimes(*anyopaque, *u64, *u64, kernel: *u64, user: *u64) callconv(.winapi) i32;
extern "kernel32" fn GetThreadTimes(*anyopaque, *u64, *u64, kernel: *u64, user: *u64) callconv(.winapi) i32;
const MemCounters = extern struct { cb: u32 = @sizeOf(MemCounters), faults: u32 = 0, peak_working_set: usize = 0, working_set: usize = 0, quota: [4]usize = @splat(0), pagefile: usize = 0, peak_pagefile: usize = 0, private: usize = 0 };
extern "kernel32" fn K32GetProcessMemoryInfo(*anyopaque, *MemCounters, u32) callconv(.winapi) i32;
extern "c" fn _mkdir([*:0]const u8) c_int;
extern "c" fn _putenv_s([*:0]const u8, [*:0]const u8) c_int;

// libc (Linux)
const CLOCK_REALTIME = 0;
const CLOCK_MONOTONIC = 1;
const CLOCK_PROCESS_CPUTIME_ID = 2;
extern "c" fn clock_gettime(clk: c_int, t: *std.c.timespec) c_int;
extern "c" fn nanosleep(req: *const std.c.timespec, rem: ?*std.c.timespec) c_int;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn pthread_getcpuclockid(std.c.pthread_t, *c_int) c_int;
extern "c" fn getrusage(who: c_int, usage: *anyopaque) c_int;
