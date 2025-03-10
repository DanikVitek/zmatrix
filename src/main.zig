const std = @import("std");
const builtin = @import("builtin");

const @"ansi-term" = @import("ansi-term");
const clear = @"ansi-term".clear;
const cursor = @"ansi-term".cursor;
const format = @"ansi-term".format;
const style = @"ansi-term".style;
const terminal = @"ansi-term".terminal;

// const event = @import("event.zig");

const BufWriter = @TypeOf(std.io.bufferedWriter(std.io.getStdOut().writer()));

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();

    const alloc = arena.allocator();

    var prng = std.Random.DefaultPrng.init(0);
    const rng = prng.random();

    const raw_stdout = std.io.getStdOut();
    defer raw_stdout.close();

    var buf_stdout = std.io.bufferedWriter(raw_stdout.writer());
    defer buf_stdout.flush() catch |e| std.debug.panic("{!}", .{e});

    const raw_stdin = std.io.getStdIn();
    defer raw_stdin.close();

    const stdin = raw_stdin.reader();

    try enableRawMode(raw_stdin);
    defer disableRawMode(raw_stdin) catch |e| std.debug.panic("{!}", .{e});

    try cursor.hideCursor(buf_stdout.writer());
    defer cursor.showCursor(buf_stdout.writer()) catch |e| std.debug.panic("{!}", .{e});

    try cursor.saveCursor(buf_stdout.writer());
    defer cursor.restoreCursor(buf_stdout.writer()) catch |e| std.debug.panic("{!}", .{e});

    try terminal.saveScreen(buf_stdout.writer());
    defer terminal.restoreScreen(buf_stdout.writer()) catch |e| std.debug.panic("{!}", .{e});

    try terminal.enterAlternateScreen(buf_stdout.writer());
    defer terminal.leaveAlternateScreen(buf_stdout.writer()) catch |e| std.debug.panic("{!}", .{e});

    var rain: Rain = try .init(
        alloc,
        rng,
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .at_least = 3, .at_most = 10 },
        .{ .at_least = 1, .at_most = 3 },
        50,
        100 * std.time.ns_per_ms,
        buf_stdout,
    );
    try rain.run(stdin);
}

fn Range(comptime T: type) type {
    if (@typeInfo(T) != .int) {
        @compileError("requires integer type for Range.genInt()");
    }
    return struct {
        at_least: T,
        at_most: T,

        const Self = @This();

        pub fn genInt(self: *const Self, rng: std.Random) T {
            return rng.intRangeAtMost(T, self.at_least, self.at_most);
        }
    };
}

const Rain = struct {
    color: style.ColorRGB,
    drop_len_range: Range(u8),
    drop_speed_range: Range(u16),
    drops_amount: u16,
    frame_duration_ns: u64,
    drops: std.AutoHashMapUnmanaged(u16, std.ArrayListUnmanaged(Raindrop)),
    alloc: std.mem.Allocator,
    rng: std.Random,
    buf_writer: std.io.BufferedWriter(4096, std.fs.File.Writer),

    fn init(
        alloc: std.mem.Allocator,
        rng: std.Random,
        color: style.ColorRGB,
        drop_len_range: Range(u8),
        drop_speed_range: Range(u16),
        drops_amount: u16,
        frame_duration_ns: u64,
        buf_writer: std.io.BufferedWriter(4096, std.fs.File.Writer),
    ) !Rain {
        var rain = Rain{
            .alloc = alloc,
            .drops = .{},
            .rng = rng,
            .color = color,
            .drop_len_range = drop_len_range,
            .drop_speed_range = drop_speed_range,
            .drops_amount = drops_amount,
            .frame_duration_ns = frame_duration_ns,
            .buf_writer = buf_writer,
        };
        for (0..drops_amount) |_| {
            const drop = try rain.getNewDrop();
            const entry = try rain.drops.getOrPut(alloc, drop.x);
            if (!entry.found_existing) {
                entry.value_ptr.* = .{};
            }
            try entry.value_ptr.append(alloc, drop);
            std.sort.block(Raindrop, entry.value_ptr.items, {}, struct {
                fn lessThan(_: void, lhs: Raindrop, rhs: Raindrop) bool {
                    return lhs.compare(&rhs) == .lt;
                }
            }.lessThan);
        }
        return rain;
    }

    fn run(self: *Rain, reader: std.fs.File.Reader) !void {
        const writer = self.buf_writer.writer();

        try clear.clearScreen(writer);
        try cursor.setCursor(writer, 0, 0);

        var timer = try std.time.Timer.start();
        while (true) {
            var buffer: [1]u8 = undefined;
            const len = try reader.read(&buffer);
            if (len == 1 and (buffer[0] == 'q' or buffer[0] == '\x1b')) {
                break;
            }

            try terminal.beginSynchronizedUpdate(writer);

            var it = self.drops.iterator();
            var drops_to_add: u16 = 0;
            while (it.next()) |entry| {
                var removed: u16 = 0;
                for (0..entry.value_ptr.items.len) |i| {
                    const drop = &entry.value_ptr.items[i - removed];

                    const HeightGetter = struct {
                        file: std.fs.File,
                        inline fn height(this: @This()) !u16 {
                            return termHeight(this.file);
                        }
                    };
                    const height_getter = HeightGetter{ .file = self.buf_writer.unbuffered_writer.context };

                    try drop.draw(writer, height_getter);
                    drop.fall();
                    try drop.clearTail(writer);
                    // try self.clearTail(writer, entry.key_ptr.*, i);

                    if (try drop.isPastEnd(height_getter)) {
                        _ = entry.value_ptr.orderedRemove(i - removed);
                        removed += 1;
                    }
                }
                drops_to_add += removed;
            }
            try terminal.endSynchronizedUpdate(writer);
            try self.buf_writer.flush();

            for (0..drops_to_add) |_| {
                const drop = try self.getNewDrop();
                const entry = try self.drops.getOrPut(self.alloc, drop.x);
                if (!entry.found_existing) {
                    entry.value_ptr.* = .{};
                }
                try entry.value_ptr.append(self.alloc, drop);
                std.sort.block(Raindrop, entry.value_ptr.items, {}, struct {
                    fn lessThan(_: void, lhs: Raindrop, rhs: Raindrop) bool {
                        return lhs.compare(&rhs) == .lt;
                    }
                }.lessThan);
            }

            std.time.sleep(self.frame_duration_ns -| timer.lap());
        }
    }

    // fn clearTail(self: *const Rain, writer: anytype, x: u16, i: usize) !void {
    //     const drops_at_x = self.drops.getPtr(x).?;
    //     const drop = drops_at_x.items[i];
    //     for (0..i) |j| {
    //         const other_drop = drops_at_x.items[j];
    //         if (drop.compare(&other_drop) == .eq) continue;
    //         for (0..other_drop.len) |k| {
    //             if (other_drop.y + k - other_drop.len <= 0) {
    //                 try cursor.setCursor(writer, x, other_drop.y + k);
    //                 try writer.writeByte(' ');
    //             }
    //         }
    //     }
    // }

    fn getNewDrop(self: *const Rain) !Raindrop {
        return Raindrop{
            .len = self.drop_len_range.genInt(self.rng),
            .x = self.rng.intRangeLessThan(u16, 0, try termWidth(self.buf_writer.unbuffered_writer.context)),
            .y = 0,
            .color = self.color,
            .speed = self.drop_speed_range.genInt(self.rng),
        };
    }
};

const Raindrop = struct {
    x: u16,
    /// the head (bottom) of the raindrop. 0 means the the droplet is out of the screen from the top.
    y: u16,
    speed: u16,
    len: u8,
    color: style.ColorRGB,

    fn draw(self: *const Raindrop, writer: anytype, height_getter: anytype) !void {
        var r: f32 = 0;
        var g: f32 = 0;
        var b: f32 = 0;

        const step_r: f32 = @as(f32, @floatFromInt(self.color.r)) / @as(f32, @floatFromInt(self.len));
        const step_g: f32 = @as(f32, @floatFromInt(self.color.g)) / @as(f32, @floatFromInt(self.len));
        const step_b: f32 = @as(f32, @floatFromInt(self.color.b)) / @as(f32, @floatFromInt(self.len));

        var prev_color: ?style.ColorRGB = null;
        for (0..self.len) |_i| {
            const i: u8 = @intCast(_i);
            defer {
                r += step_r;
                g += step_g;
                b += step_b;
            }
            // std.debug.print("[{*}]  y: {d}; i: {d}; len: {d}; speed: {d}\n", .{ self, self.y, i, self.len, self.speed });

            // y_i < 1 or y_i > termHeight() -> out of screen
            if (self.y + i < self.len or self.y + i + 1 - self.len > try height_getter.height()) continue; // skip if out of screen
            const y_i = self.y + i + 1 - self.len;

            // std.debug.print("y_i: {d}\n", .{y_i});

            const color: style.ColorRGB = .{
                .r = @intFromFloat(r),
                .g = @intFromFloat(g),
                .b = @intFromFloat(b),
            };

            try cursor.setCursor(writer, self.x, y_i);
            try updateColor(writer, color, prev_color);
            try writer.print("{u}", .{self.grapheme(y_i)});

            prev_color = color;
        }
    }

    fn fall(self: *Raindrop) void {
        self.y += self.speed;
    }

    fn clearTail(self: *const Raindrop, writer: anytype) !void {
        for (0..self.len) |_i| {
            const i: u16 = @intCast(_i);
            try cursor.setCursor(writer, self.x, self.y -| (self.len + i));
            try writer.writeByte(' ');
        }
    }

    fn grapheme(self: *const Raindrop, pos: u16) u21 {
        var hasher = std.hash.Adler32.init();
        std.hash.autoHash(&hasher, .{ self, pos });

        return @intCast((hasher.final() % 93) + 33); // TODO: use unicode graphemes
    }

    fn isPastEnd(self: *const Raindrop, height_getter: anytype) !bool {
        return self.y + 2 > self.len + try height_getter.height();
    }

    fn compare(self: *const Raindrop, other: *const Raindrop) std.math.Order {
        if (self.y + other.len < other.y + self.len) return .lt;
        if (self.y + other.len > other.y + self.len) return .gt;
        return .eq;
    }
};

fn updateColor(writer: anytype, new: style.ColorRGB, old: ?style.ColorRGB) !void {
    try format.updateStyle(
        writer,
        .{ .foreground = .{ .RGB = new } },
        if (old) |o| .{ .foreground = .{ .RGB = o } } else null,
    );
}

inline fn termWidth(file: std.fs.File) !u16 {
    return switch (builtin.os.tag) {
        .windows => try @import("windows.zig").termWidth(),
        .linux => (try @import("posix.zig").termSize(file)).width,
        else => @compileError("Unsupported OS"),
    };
}

inline fn termHeight(file: std.fs.File) !u16 {
    return switch (builtin.os.tag) {
        .windows => try @import("windows.zig").termHeight(),
        .linux => (try @import("posix.zig").termSize(file)).height,
        else => @compileError("Unsupported OS"),
    };
}

inline fn enableRawMode(file: std.fs.File) !void {
    switch (builtin.os.tag) {
        .windows => try @import("windows.zig").enableRawMode(),
        .linux => try @import("posix.zig").enableRawMode(file),
        else => @compileError("Unsupported OS"),
    }
}

inline fn disableRawMode(file: std.fs.File) !void {
    switch (builtin.os.tag) {
        .windows => try @import("windows.zig").disableRawMode(),
        .linux => try @import("posix.zig").disableRawMode(file),
        else => @compileError("Unsupported OS"),
    }
}
