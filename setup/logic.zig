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

/// Settings the forms know (the launcher's, the game's F10 page): a label and
/// proper controls. Others get a text field (in the game, a toggle if 0 or 1).
pub const Known = struct {
    key: []const u8,
    label: []const u8,
    kind: enum { chips, toggle, stepper, text, resolution },
    opts: []const struct { v: []const u8, label: []const u8 } = &.{},
    summary: bool = false, // on the launcher's Play page Settings tile
    live: bool = false, // the game's F10 page applies it at once (src/settings_menu.zig)
};
pub const known = [_]Known{
    .{ .key = "window", .label = "Window mode", .kind = .chips, .summary = true, .live = true, .opts = &.{ .{ .v = "0", .label = "Window" }, .{ .v = "1", .label = "Borderless" }, .{ .v = "2", .label = "Fullscreen" } } },
    .{ .key = "resolution", .label = "Fullscreen resolution", .kind = .resolution, .live = true },
    .{ .key = "scale", .label = "Internal resolution", .kind = .chips, .summary = true, .opts = &.{ .{ .v = "1", .label = "1x (640x480)" }, .{ .v = "2", .label = "2x" }, .{ .v = "3", .label = "3x" }, .{ .v = "4", .label = "4x" } } },
    .{ .key = "widescreen", .label = "Widescreen (16:9)", .kind = .toggle },
    .{ .key = "framerate", .label = "Frame rate", .kind = .chips, .summary = true, .live = true, .opts = &.{ .{ .v = "0", .label = "Monitor's" }, .{ .v = "30", .label = "30 (original)" }, .{ .v = "60", .label = "60" }, .{ .v = "120", .label = "120" }, .{ .v = "144", .label = "144" } } },
    .{ .key = "vsync", .label = "V-sync", .kind = .toggle, .live = true },
    .{ .key = "gfx", .label = "Graphics backend", .kind = .chips, .opts = &.{ .{ .v = "d3d11", .label = "Direct3D 11" }, .{ .v = "vulkan", .label = "Vulkan" }, .{ .v = "gl", .label = "OpenGL" } } },
    .{ .key = "mist_depth", .label = "Ground mist stays behind the ground", .kind = .toggle },
    .{ .key = "cam_invert", .label = "Modern right-stick camera", .kind = .toggle, .live = true },
    .{ .key = "cam_invert_y", .label = "Invert camera up/down", .kind = .toggle, .live = true },
    .{ .key = "show_mouse", .label = "Always show the mouse pointer", .kind = .toggle, .live = true },
    .{ .key = "draw_distance", .label = "Draw distance", .kind = .stepper, .live = true },
    .{ .key = "fog_distance", .label = "Fog distance", .kind = .stepper, .live = true },
    .{ .key = "metrics", .label = "Metrics while playing", .kind = .chips, .live = true, .opts = &.{ .{ .v = "0", .label = "Off" }, .{ .v = "1", .label = "Frame rate" }, .{ .v = "2", .label = "Full" } } },
    .{ .key = "metrics_corner", .label = "Metrics corner", .kind = .chips, .live = true, .opts = &.{ .{ .v = "0", .label = "Top right" }, .{ .v = "1", .label = "Top left" }, .{ .v = "2", .label = "Bottom right" }, .{ .v = "3", .label = "Bottom left" } } },
    .{ .key = "debug_menu", .label = "Debug menu at start (F1)", .kind = .toggle },
    .{ .key = "log", .label = "Write otogi.log", .kind = .toggle },
};
pub const distances = [_]f32{ 0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 6, 8 };

pub fn knownSetting(key: []const u8) ?Known {
    for (known) |k| if (std.mem.eql(u8, k.key, key)) return k;
    return null;
}

/// A stepper's next value: the next of `distances` up or down from `now`
/// (empty or unreadable = 1).
pub fn stepDistance(now: []const u8, up: bool) f32 {
    const v = std.fmt.parseFloat(f32, now) catch 1;
    var i: usize = 0;
    while (i + 1 < distances.len and distances[i] < v - 0.01) i += 1;
    i = if (up) @min(i + 1, distances.len - 1) else i -| 1;
    return distances[i];
}

test stepDistance {
    try std.testing.expectEqual(1.25, stepDistance("1", true));
    try std.testing.expectEqual(0.75, stepDistance("", false));
    try std.testing.expectEqual(8, stepDistance("8", true));
    try std.testing.expectEqual(0.25, stepDistance("0.25", false));
}

/// A row's control: the table's, else a toggle for 0 or 1, a text field for anything else.
pub fn kindOf(e: Entry) @FieldType(Known, "kind") {
    if (knownSetting(e.key)) |k| return k.kind;
    return if (std.mem.eql(u8, e.value, "0") or std.mem.eql(u8, e.value, "1")) .toggle else .text;
}

/// The settings form (setup/ui/theme.rcss), one row per entry: the launcher's
/// Settings page and the game's F10 page. Only its shape: values go on by id
/// (formValues), so a change keeps the controller's focus where it is.
/// `restart` marks the rows the game applies only at its next start. Clicks
/// come back as formCommand's commands. `modes` are "1920x1080".
pub fn formRml(w: *std.Io.Writer, es: []const Entry, modes: []const [12:0]u8, restart: bool) !void {
    for (es) |e| {
        const k = knownSetting(e.key);
        const kind = kindOf(e);
        const later = restart and !(if (k) |x| x.live else false);
        try w.print("<div class=\"setting{s}\"><div class=\"what\"><div class=\"label\">{f}{s}</div><div class=\"help\">{f}</div></div><div class=\"ctl\">", .{
            if (kind == .toggle or kind == .stepper) "" else " stack",
            esc(if (k) |x| x.label else e.key),
            if (later) "<span class=\"restart\">applies after restart</span>" else "",
            esc(e.help),
        });
        const key = esc(e.key);
        switch (kind) {
            .chips => {
                try w.writeAll("<div class=\"chips\">");
                var listed = false;
                for (k.?.opts) |o| {
                    listed = listed or std.mem.eql(u8, o.v, e.value);
                    try w.print("<div class=\"chip\" id=\"opt-{f}-{s}\" onclick=\"set:{f}\" value=\"{s}\">{s}</div>", .{ key, o.v, key, o.v, o.label });
                }
                if (!listed) try w.print("<div class=\"chip\" id=\"opt-{f}-{f}\" onclick=\"set:{f}\" value=\"{f}\">{f}</div>", .{ key, esc(e.value), key, esc(e.value), esc(e.value) });
                try w.writeAll("</div>");
            },
            .toggle => try w.print("<div class=\"toggle\" id=\"opt-{f}\" onclick=\"toggle:{f}\"><div class=\"knob\"/></div>", .{ key, key }),
            .stepper => try w.print("<div class=\"row stepper\"><div class=\"btn\" onclick=\"step:{f}\" value=\"-\">&#x2212;</div><div class=\"val\" id=\"val-{f}\"></div><div class=\"btn\" onclick=\"step:{f}\" value=\"+\">+</div></div>", .{ key, key, key }),
            .text => try w.print("<input type=\"text\" class=\"text\" id=\"opt-{f}\" onchange=\"set:{f}\" placeholder=\"default\"/>", .{ key, key }),
            // The monitor's own modes; Custom shows a field for any other.
            .resolution => {
                try w.writeAll("<div class=\"chips\"><div class=\"chip\" id=\"opt-resolution-desktop\" onclick=\"set:resolution\" value=\"\">Desktop's</div>");
                for (modes) |*m| {
                    const t = std.mem.sliceTo(m, 0);
                    const x = std.mem.indexOfScalar(u8, t, 'x') orelse continue;
                    try w.print("<div class=\"chip\" id=\"opt-resolution-{s}\" onclick=\"set:resolution\" value=\"{s}\">{s} &#x00D7; {s}</div>", .{ t, t, t[0..x], t[x + 1 ..] });
                }
                try w.writeAll("<div class=\"chip\" id=\"opt-resolution-custom\" onclick=\"res-custom\">Custom</div></div><input type=\"text\" class=\"text custom\" id=\"opt-resolution\" onchange=\"res-text\" placeholder=\"Width x height, such as 1920x1080\"/>");
            },
        }
        try w.writeAll("</div></div>");
    }
}

// Both UI hosts have these (setup/window.cpp, src/ui.cpp): by element id, the
// markup inside, a class on or off, a text field's value. Unchanged costs nothing.
extern fn ui_set(id: [*:0]const u8, rml: [*:0]const u8) void;
extern fn ui_class(id: [*:0]const u8, class: [*:0]const u8, on: bool) void;
extern fn ui_value(id: [*:0]const u8, value: [*:0]const u8) void;

/// formRml's controls set to the values. `custom`: the resolution's Custom
/// field is open.
pub fn formValues(es: []const Entry, modes: []const [12:0]u8, custom: bool) void {
    const Ui = struct {
        const class = ui_class;
        const value = ui_value;
        const text = ui_set;
    };
    for (es) |e| {
        var b: [160]u8 = undefined;
        var v: [160]u8 = undefined;
        const z = std.fmt.bufPrintSentinel;
        const val = z(&v, "{s}", .{e.value}, 0) catch continue;
        switch (kindOf(e)) {
            .chips => for (knownSetting(e.key).?.opts) |o| {
                Ui.class(z(&b, "opt-{s}-{s}", .{ e.key, o.v }, 0) catch continue, "on", std.mem.eql(u8, o.v, e.value));
            },
            .toggle => Ui.class(z(&b, "opt-{s}", .{e.key}, 0) catch continue, "on", std.mem.eql(u8, e.value, "1")),
            .stepper => Ui.text(z(&b, "val-{s}", .{e.key}, 0) catch continue, z(&v, "{s}x", .{if (e.value.len == 0) "1" else e.value}, 0) catch continue),
            .text => Ui.value(z(&b, "opt-{s}", .{e.key}, 0) catch continue, val),
            .resolution => {
                const listed = e.value.len == 0 or for (modes) |*m| (if (std.mem.eql(u8, std.mem.sliceTo(m, 0), e.value)) break true) else false;
                const open = custom or !listed;
                Ui.class("opt-resolution-desktop", "on", !open and e.value.len == 0);
                for (modes) |*m| {
                    const t = std.mem.sliceTo(m, 0);
                    Ui.class(z(&b, "opt-resolution-{s}", .{t}, 0) catch continue, "on", !open and std.mem.eql(u8, t, e.value));
                }
                Ui.class("opt-resolution-custom", "on", open);
                Ui.class("opt-resolution", "hidden", !open);
                Ui.value("opt-resolution", val);
            },
        }
    }
}

/// A form click (formRml's on* commands) as the key and value to save, or null
/// for any other command. `buf` holds a stepped value.
pub fn formCommand(es: []const Entry, cmd: []const u8, val: []const u8, buf: []u8) ?[2][]const u8 {
    const now = struct {
        fn f(list: []const Entry, key: []const u8) []const u8 {
            return for (list) |e| (if (std.mem.eql(u8, e.key, key)) break e.value) else "";
        }
    }.f;
    if (std.mem.startsWith(u8, cmd, "set:")) return .{ cmd[4..], val };
    if (std.mem.eql(u8, cmd, "res-text")) return .{ "resolution", val };
    if (std.mem.startsWith(u8, cmd, "toggle:")) return .{ cmd[7..], if (std.mem.eql(u8, now(es, cmd[7..]), "1")) "0" else "1" };
    if (std.mem.startsWith(u8, cmd, "step:"))
        return .{ cmd[5..], std.fmt.bufPrint(buf, "{d}", .{stepDistance(now(es, cmd[5..]), !std.mem.eql(u8, val, "-"))}) catch return null };
    return null;
}

test formCommand {
    const es = [_]Entry{ .{ .key = "vsync", .value = "1", .help = "" }, .{ .key = "draw_distance", .value = "1", .help = "" } };
    var b: [16]u8 = undefined;
    const t = formCommand(&es, "toggle:vsync", "", &b).?;
    try std.testing.expectEqualStrings("vsync", t[0]);
    try std.testing.expectEqualStrings("0", t[1]);
    try std.testing.expectEqualStrings("1.25", formCommand(&es, "step:draw_distance", "+", &b).?[1]);
    try std.testing.expectEqualStrings("60", formCommand(&es, "set:framerate", "60", &b).?[1]);
    try std.testing.expectEqual(null, formCommand(&es, "close", "", &b));
}

test formRml {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const es = [_]Entry{ .{ .key = "framerate", .value = "60", .help = "Frames <shown>" }, .{ .key = "scale", .value = "2", .help = "" }, .{ .key = "new_one", .value = "0", .help = "" } };
    try formRml(&w, &es, &.{}, true);
    const s = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, s, "id=\"opt-framerate-60\" onclick=\"set:framerate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s, "Frames &lt;shown&gt;") != null);
    // scale and the unknown key are not live; an unknown 0/1 key is a toggle.
    try std.testing.expectEqual(2, std.mem.count(u8, s, "applies after restart"));
    try std.testing.expect(std.mem.indexOf(u8, s, "class=\"toggle\" id=\"opt-new_one\"") != null);
}

/// SHA-1 of default.xbe on the redump of the USA disc: the build is made from it.
pub const xbe_sha1 = "abf12bb66fcbd9f694c223419a2309c1a5f72293";

pub fn sha1Hex(data: []const u8) [40]u8 {
    var h: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(data, &h, .{});
    return std.fmt.bytesToHex(h, .lower);
}

pub const Xbe = enum {
    /// The redump's default.xbe.
    match,
    /// The redump's with extract-xiso's media patch, which `checkXbe` undid.
    media_patched,
    /// Otogi (USA) by its certificate, but other bytes: build with a warning.
    other_dump,
    /// Not Otogi (USA): another game, or another region's release.
    wrong_game,
};

/// What a disc's default.xbe is. extract-xiso (XISOs, repacked HDD rips) turns
/// the media check's `jge` into `jmp` (one byte); that is undone in `data` when
/// it gives back the redump's exact bytes.
pub fn checkXbe(data: []u8) Xbe {
    if (std.mem.eql(u8, &sha1Hex(data), xbe_sha1)) return .match;
    if (std.mem.indexOf(u8, data, "\xE8\xCA\xFD\xFF\xFF\x85\xC0\xEB")) |i| {
        data[i + 7] = 0x7D;
        if (std.mem.eql(u8, &sha1Hex(data), xbe_sha1)) return .media_patched;
        data[i + 7] = 0xEB;
    }
    // The certificate: title ID 0x46530002 (FS-002), game region with North America.
    if (data.len < 0x11C or !std.mem.eql(u8, data[0..4], "XBEH")) return .wrong_game;
    const cert = std.mem.readInt(u32, data[0x118..0x11C], .little) -% std.mem.readInt(u32, data[0x104..0x108], .little);
    if (cert > data.len - 0xA4) return .wrong_game;
    const title = std.mem.readInt(u32, data[cert + 8 ..][0..4], .little);
    const region = std.mem.readInt(u32, data[cert + 0xA0 ..][0..4], .little);
    return if (title == 0x46530002 and region & 1 != 0) .other_dump else .wrong_game;
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

/// Text made safe in markup: "{f}" with esc(s).
pub const Esc = struct {
    s: []const u8,
    pub fn format(e: Esc, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try escape(w, e.s);
    }
};
pub fn esc(s: []const u8) Esc {
    return .{ .s = s };
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

test checkXbe {
    // A bare header and certificate: Otogi's title ID, then the region decides.
    var x: [0x300]u8 = @splat(0);
    @memcpy(x[0..4], "XBEH");
    std.mem.writeInt(u32, x[0x104..0x108], 0x10000, .little);
    std.mem.writeInt(u32, x[0x118..0x11C], 0x10184, .little);
    std.mem.writeInt(u32, x[0x18C..0x190], 0x46530002, .little);
    std.mem.writeInt(u32, x[0x224..0x228], 1, .little);
    try std.testing.expectEqual(Xbe.other_dump, checkXbe(&x));
    std.mem.writeInt(u32, x[0x224..0x228], 2, .little); // Japan
    try std.testing.expectEqual(Xbe.wrong_game, checkXbe(&x));
    std.mem.writeInt(u32, x[0x224..0x228], 1, .little);
    std.mem.writeInt(u32, x[0x18C..0x190], 0x4D530004, .little); // another game
    try std.testing.expectEqual(Xbe.wrong_game, checkXbe(&x));
    try std.testing.expectEqual(Xbe.wrong_game, checkXbe(x[0..0x100]));

    // The real one, if this checkout has game\ extracted.
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const real = std.Io.Dir.cwd().readFileAlloc(io, "game/default.xbe", gpa, .limited(8 << 20)) catch return error.SkipZigTest;
    defer gpa.free(real);
    try std.testing.expectEqual(Xbe.match, checkXbe(real));
    const at = std.mem.indexOf(u8, real, "\xE8\xCA\xFD\xFF\xFF\x85\xC0\x7D").? + 7;
    real[at] = 0xEB; // as extract-xiso leaves it
    try std.testing.expectEqual(Xbe.media_patched, checkXbe(real));
    try std.testing.expectEqual(@as(u8, 0x7D), real[at]);
    real[at + 1] ^= 1;
    try std.testing.expectEqual(Xbe.other_dump, checkXbe(real));
}

test notesRml {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try notesRml(&out.writer, "### Fixed\r\n- **Black** worlds in `glow` stages,\r\n  see [#4](https://x/4).\r\n- Two.\r\n\r\nPlain <text>.");
    try std.testing.expectEqualStrings("<h4>Fixed</h4><p class=\"li\"><strong>Black</strong> worlds in <span class=\"code\">glow</span> stages, see #4.</p><p class=\"li\">Two.</p><p>Plain &lt;text&gt;.</p>", out.written());
}
