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
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    var buf_stdout = std.io.bufferedWriter(std.io.getStdOut().writer());

    var prng = std.rand.DefaultPrng.init(0);
    const rng = prng.random();

    try cursor.hideCursor(buf_stdout.writer());
    // try terminal.enterAlternateScreen(buf_stdout.writer());

    var rain = try Rain.init(
        alloc,
        rng,
        .{ .r = 0, .g = 255, .b = 0 },
        .{ .at_least = 3, .at_most = 10 },
        .{ .at_least = 1, .at_most = 3 },
        100,
        50 * std.time.ns_per_ms,
    );
    try rain.draw(&buf_stdout);

    // try terminal.leaveAlternateScreen(buf_stdout.writer());
    try cursor.showCursor(buf_stdout.writer());
    try buf_stdout.flush();
}

fn Range(comptime T: type) type {
    return struct {
        at_least: T,
        at_most: T,

        const Self = @This();

        pub fn genInt(self: *const Self, rng: std.Random) T {
            if (@typeInfo(T) != .Int) {
                @compileError("requires integer type for Range.genInt()");
            }
            return rng.intRangeAtMost(T, self.at_least, self.at_most);
        }
    };
}

const Rain = struct {
    color: style.ColorRGB,
    drop_len_range: Range(u8),
    drop_speed_range: Range(u16),
    drops_amount: u16,
    drops: std.ArrayList(Raindrop),
    rng: std.Random,
    frame_delay_ns: u64,

    fn init(
        alloc: std.mem.Allocator,
        rng: std.Random,
        color: style.ColorRGB,
        drop_len_range: Range(u8),
        drop_speed_range: Range(u16),
        drops_amount: u16,
        frame_delay_ns: u64,
    ) !Rain {
        var rain = Rain{
            .drops = try std.ArrayList(Raindrop).initCapacity(alloc, drops_amount),
            .rng = rng,
            .color = color,
            .drop_len_range = drop_len_range,
            .drop_speed_range = drop_speed_range,
            .drops_amount = drops_amount,
            .frame_delay_ns = frame_delay_ns,
        };
        for (0..drops_amount) |_| {
            rain.drops.appendAssumeCapacity(try rain.getNewDrop());
        }
        return rain;
    }

    fn draw(self: *Rain, buf_writer: *BufWriter) !void {
        const writer = buf_writer.writer();

        try clear.clearScreen(writer);
        try cursor.setCursor(writer, 0, 0);

        while (true) {
            try terminal.beginSynchronizedUpdate(writer);
            for (0..self.drops.items.len) |i| {
                const drop = &self.drops.items[i];

                try drop.draw(writer);
                drop.fall();
                try drop.clearTail(writer);

                if (try drop.isPastEnd()) {
                    drop.* = try self.getNewDrop();
                }
            }
            try terminal.endSynchronizedUpdate(writer);
            try buf_writer.flush();
            std.time.sleep(self.frame_delay_ns);
        }
    }

    fn getNewDrop(self: *const Rain) !Raindrop {
        return Raindrop{
            .len = self.drop_len_range.genInt(self.rng),
            .x = self.rng.intRangeLessThan(u16, 0, try termWidth()),
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

    fn draw(self: *const Raindrop, writer: anytype) !void {
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
            if (self.y + i < self.len or self.y + i + 1 - self.len > try termHeight()) continue; // skip if out of screen
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

    fn isPastEnd(self: *const Raindrop) !bool {
        return self.y + 2 > self.len + try termHeight();
    }
};

fn updateColor(writer: anytype, new: style.ColorRGB, old: ?style.ColorRGB) !void {
    try format.updateStyle(
        writer,
        .{ .foreground = .{ .RGB = new } },
        if (old) |o| .{ .foreground = .{ .RGB = o } } else null,
    );
}

inline fn termWidth() !u16 {
    return switch (builtin.os.tag) {
        .windows => @import("windows.zig").termWidth(),
        else => @compileError("Unsupported OS"),
    };
}

inline fn termHeight() !u16 {
    return switch (builtin.os.tag) {
        .windows => @import("windows.zig").termHeight(),
        else => @compileError("Unsupported OS"),
    };
}

inline fn enableRawMode() !void {
    switch (builtin.os.tag) {
        .windows => @import("windows.zig").enableRawMode(),
        else => @compileError("Unsupported OS"),
    }
}

inline fn disableRawMode() !void {
    switch (builtin.os.tag) {
        .windows => @import("windows.zig").disableRawMode(),
        else => @compileError("Unsupported OS"),
    }
}
