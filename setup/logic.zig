//! The launcher's logic that needs no window: settings.ini as a form, GitHub
//! release notes as RmlUi markup, version order. `zig build test` runs the tests.
const std = @import("std");

/// `key = value` with comments (; or #) stripped, as otogi.exe reads it.
pub fn setting(line: []const u8) ?[2][]const u8 {
    const body = line[0 .. std.mem.indexOfAny(u8, line, "#;") orelse line.len];
    const eq = std.mem.indexOfScalar(u8, body, '=') orelse return null;
    const k = std.mem.trim(u8, body[0..eq], " \t");
    const v = std.mem.trim(u8, body[eq + 1 ..], " \t");
    if (k.len == 0) return null;
    return .{ k, v };
}

/// One setting of settings.ini and the comment block just above it.
pub const Entry = struct { key: []const u8, value: []const u8, help: []const u8 };

/// Every `key = value` line (empty values too: "keep the default") with its
/// help: the `;` lines right above it, joined with spaces. Slices into `text`
/// except help, which is allocated.
pub fn entries(gpa: std.mem.Allocator, text: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    var help: std.ArrayList(u8) = .empty;
    defer help.deinit(gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            help.clearRetainingCapacity();
        } else if (line[0] == ';' or line[0] == '#') {
            const c = std.mem.trim(u8, line[1..], " \t");
            if (help.items.len != 0 and c.len != 0) try help.append(gpa, ' ');
            try help.appendSlice(gpa, c);
        } else if (setting(line)) |kv| {
            try out.append(gpa, .{ .key = kv[0], .value = kv[1], .help = try gpa.dupe(u8, help.items) });
            help.clearRetainingCapacity();
        }
    }
    return out.toOwnedSlice(gpa);
}

/// `text` with `key`'s line set to `key = value` (the rest untouched); a key it
/// lacks goes at the end.
pub fn withValue(gpa: std.mem.Allocator, text: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    const w = &out.writer;
    var found = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |raw| {
        if (!first) try w.writeByte('\n');
        first = false;
        const cr = std.mem.endsWith(u8, raw, "\r");
        if (setting(raw)) |kv| if (!found and std.mem.eql(u8, kv[0], key)) {
            found = true;
            try w.print("{s} = {s}{s}", .{ key, value, if (cr) "\r" else "" });
            continue;
        };
        try w.writeAll(raw);
    }
    if (!found) {
        if (text.len != 0 and text[text.len - 1] != '\n') try w.writeByte('\n');
        try w.print("{s} = {s}\n", .{ key, value });
    }
    return out.toOwnedSlice();
}

/// "0.10.0" > "0.9.2"; a leading "v" is ignored.
pub fn newer(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, std.mem.trimStart(u8, a, "v"), '.');
    var ib = std.mem.splitScalar(u8, std.mem.trimStart(u8, b, "v"), '.');
    for (0..3) |_| {
        const x = std.fmt.parseInt(u32, ia.next() orelse "0", 10) catch 0;
        const y = std.fmt.parseInt(u32, ib.next() orelse "0", 10) catch 0;
        if (x != y) return x > y;
    }
    return false;
}

/// `s` percent-encoded for a URL's query (everything but A-Z a-z 0-9 - _ . ~).
pub fn urlEncode(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try w.writeByte(c),
        else => try w.print("%{X:0>2}", .{c}),
    };
}

/// Text made safe inside RmlUi markup.
pub fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

/// A release body (CHANGELOG.md's section: `### Added`, `- item`, `**bold**`,
/// `code`, [links](url)) as RmlUi markup. CHANGELOG.md wraps its lines: a
/// plain line goes on with the item or paragraph above it.
pub fn notesRml(w: *std.Io.Writer, md: []const u8) !void {
    var open = false; // a <p> is open
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const head = std.mem.startsWith(u8, line, "#");
        const item = std.mem.startsWith(u8, line, "- ") or std.mem.startsWith(u8, line, "* ");
        if (open and (line.len == 0 or head or item)) {
            try w.writeAll("</p>");
            open = false;
        }
        if (line.len == 0) continue;
        if (head) {
            try w.writeAll("<h4>");
            try inline_(w, std.mem.trimStart(u8, line, "# "));
            try w.writeAll("</h4>");
        } else if (item) {
            try w.writeAll("<p class=\"li\">");
            try inline_(w, line[2..]);
            open = true;
        } else {
            try w.writeAll(if (open) " " else "<p>");
            try inline_(w, line);
            open = true;
        }
    }
    if (open) try w.writeAll("</p>");
}

fn inline_(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "**")) if (std.mem.indexOfPos(u8, s, i + 2, "**")) |end| {
            try w.writeAll("<strong>");
            try escape(w, s[i + 2 .. end]);
            try w.writeAll("</strong>");
            i = end + 2;
            continue;
        };
        if (s[i] == '`') if (std.mem.indexOfScalarPos(u8, s, i + 1, '`')) |end| {
            try w.writeAll("<span class=\"code\">");
            try escape(w, s[i + 1 .. end]);
            try w.writeAll("</span>");
            i = end + 1;
            continue;
        };
        if (s[i] == '[') if (std.mem.indexOfPos(u8, s, i, "](")) |mid| if (std.mem.indexOfScalarPos(u8, s, mid, ')')) |end| {
            try escape(w, s[i + 1 .. mid]); // the link's text; the launcher opens no links
            i = end + 1;
            continue;
        };
        try escape(w, s[i .. i + 1]);
        i += 1;
    }
}

test entries {
    const gpa = std.testing.allocator;
    const text =
        "; Otogi settings.\r\n\r\n; 0 = a window,\r\n; 1 = borderless\r\nwindow = 1\r\n\r\n; Empty = desktop.\r\nresolution =\r\nscale = 2 ; inline\r\n";
    const es = try entries(gpa, text);
    defer {
        for (es) |e| gpa.free(e.help);
        gpa.free(es);
    }
    try std.testing.expectEqual(3, es.len);
    try std.testing.expectEqualStrings("window", es[0].key);
    try std.testing.expectEqualStrings("1", es[0].value);
    try std.testing.expectEqualStrings("0 = a window, 1 = borderless", es[0].help);
    try std.testing.expectEqualStrings("", es[1].value);
    try std.testing.expectEqualStrings("Empty = desktop.", es[1].help);
    try std.testing.expectEqualStrings("2", es[2].value);
    try std.testing.expectEqualStrings("", es[2].help);
}

test withValue {
    const gpa = std.testing.allocator;
    const a = try withValue(gpa, "; keep me\r\nwindow = 1\r\nscale = 2\r\n", "scale", "4");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("; keep me\r\nwindow = 1\r\nscale = 4\r\n", a);
    const b = try withValue(gpa, "window = 1", "vsync", "0");
    defer gpa.free(b);
    try std.testing.expectEqualStrings("window = 1\nvsync = 0\n", b);
}

test newer {
    try std.testing.expect(newer("v0.10.0", "0.9.2"));
    try std.testing.expect(newer("1.0.0", "0.99.99"));
    try std.testing.expect(!newer("0.8.0", "v0.8.0"));
    try std.testing.expect(!newer("0.7.9", "0.8.0"));
}

test urlEncode {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try urlEncode(&w, "a b&c=d\n**v0.8**~");
    try std.testing.expectEqualStrings("a%20b%26c%3Dd%0A%2A%2Av0.8%2A%2A~", w.buffered());
}

test notesRml {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try notesRml(&out.writer, "### Fixed\r\n- **Black** worlds in `glow` stages,\r\n  see [#4](https://x/4).\r\n- Two.\r\n\r\nPlain <text>.");
    try std.testing.expectEqualStrings("<h4>Fixed</h4><p class=\"li\"><strong>Black</strong> worlds in <span class=\"code\">glow</span> stages, see #4.</p><p class=\"li\">Two.</p><p>Plain &lt;text&gt;.</p>", out.written());
}
