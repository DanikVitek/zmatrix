const std = @import("std");
const win = std.os.windows;

pub fn termWidth() !u16 {
    const srWindow = (try (try ScreenBuffer.current()).info()).srWindow;
    return @intCast(srWindow.Right - srWindow.Left + 1);
}

pub fn termHeight() !u16 {
    const srWindow = (try (try ScreenBuffer.current()).info()).srWindow;
    return @intCast(srWindow.Bottom - srWindow.Top + 1);
}

const ScreenBuffer = struct {
    handle: Handle,

    fn current() !ScreenBuffer {
        return .{ .handle = try Handle.init(.current_output_handle) };
    }

    fn info(self: ScreenBuffer) !win.CONSOLE_SCREEN_BUFFER_INFO {
        var csbi = std.mem.zeroes(win.CONSOLE_SCREEN_BUFFER_INFO);
        try result(win.kernel32.GetConsoleScreenBufferInfo(self.handle.inner, &csbi));
        return csbi;
    }
};

pub fn enableRawMode() !void {
    const console_mode = ConsoleMode{ .handle = try Handle.currentInHandle() };

    const dw_mode = try console_mode.mode();

    const new_mode = dw_mode & ~NOT_RAW_MODE_MASK;

    try console_mode.setMode(new_mode);
}

pub fn disableRawMode() !void {
    const console_mode = ConsoleMode{ .handle = try Handle.currentInHandle() };

    const dw_mode = try console_mode.mode();

    const new_mode = dw_mode | NOT_RAW_MODE_MASK;

    try console_mode.setMode(new_mode);
}

const Handle = struct {
    inner: win.HANDLE,

    pub inline fn init(comptime handle_type: HandleType) !Handle {
        return switch (handle_type) {
            .output_handle => try outputHandle(),
            .input_handle => try inputHandle(),
            .current_output_handle => try currentOutHandle(),
            .current_input_handle => try currentInHandle(),
        };
    }

    pub fn currentOutHandle() !Handle {
        return .{ .inner = try handleResult(win.kernel32.CreateFileW(
            comptime encodeUtf16Z("CONOUT$"),
            win.GENERIC_READ | win.GENERIC_WRITE,
            win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
            null,
            win.OPEN_EXISTING,
            0,
            null,
        )) };
    }

    pub fn currentInHandle() !Handle {
        return .{ .inner = try handleResult(win.kernel32.CreateFileW(
            comptime encodeUtf16Z("CONIN$"),
            win.GENERIC_READ | win.GENERIC_WRITE,
            win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
            null,
            win.OPEN_EXISTING,
            0,
            null,
        )) };
    }

    pub fn outputHandle() !Handle {
        const STD_OUTPUT_HANDLE: win.DWORD = 0xFFFF_FFF5;
        return .{ .inner = try handleResult(win.kernel32.GetStdHandle(STD_OUTPUT_HANDLE)) };
    }

    pub fn inputHandle() !Handle {
        const STD_INPUT_HANDLE: win.DWORD = 0xFFFF_FFF6;
        return .{ .inner = try handleResult(win.kernel32.GetStdHandle(STD_INPUT_HANDLE)) };
    }

    fn stdHandle(which_std: win.DWORD) !Handle {
        return .{ .inner = try handleResult(win.kernel32.GetStdHandle(which_std)) };
    }
};

const HandleType = enum {
    /// The process' standard output handle.
    output_handle,
    /// The process' standard input handle.
    input_handle,
    /// The process' active console screen buffer, `CONOUT$`.
    current_output_handle,
    /// The process' console input buffer, `CONIN$`.
    current_input_handle,
};

const ConsoleMode = struct {
    handle: Handle,

    fn mode(self: ConsoleMode) !u32 {
        var console_mode: win.DWORD = 0;
        if (win.kernel32.GetConsoleMode(self.handle.inner, &console_mode) != 0) {
            return @errorFromInt(@intFromEnum(win.kernel32.GetLastError()));
        }
        return console_mode;
    }

    fn setMode(self: ConsoleMode, dw_mode: u32) !void {
        return result(SetConsoleMode(self.handle.inner, dw_mode));
    }
};

pub extern "kernel32" fn SetConsoleMode(in_hConsoleHandle: win.HANDLE, in_dwMode: win.DWORD) callconv(win.WINAPI) win.BOOL;

const NOT_RAW_MODE_MASK: u32 = b: {
    const ENABLE_PROCESSED_INPUT = 0x0001;
    const ENABLE_LINE_INPUT = 0x0002;
    const ENABLE_ECHO_INPUT = 0x0004;
    break :b ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT;
};

inline fn handleResult(return_value: win.HANDLE) Win32Error!win.HANDLE {
    return if (return_value != win.INVALID_HANDLE_VALUE)
        return_value
    else
        @as(Win32Error, @errorCast(@errorFromInt(@intFromEnum(win.kernel32.GetLastError()))));
}

inline fn result(return_value: win.BOOL) Win32Error!void {
    if (return_value == 0) {
        return @as(Win32Error, @errorCast(@errorFromInt(@intFromEnum(win.kernel32.GetLastError()))));
    }
}

const Win32Error = b: {
    var error_set: []const std.builtin.Type.Error = &.{};
    @setEvalBranchQuota(@typeInfo(win.Win32Error).Enum.fields.len);
    for (@typeInfo(win.Win32Error).Enum.fields) |field| {
        error_set = error_set ++ .{.{ .name = field.name }};
    }
    break :b @Type(.{ .ErrorSet = error_set });
};

fn encodeUtf16Z(comptime utf8: []const u8) [*:0]const u16 {
    comptime {
        var utf8_iter = std.unicode.Utf8View.initComptime(utf8).iterator();

        var utf16: []const u16 = &.{};
        var extra: u16 = 0;

        while (true) {
            if (extra != 0) {
                const tmp = extra;
                extra = 0;
                utf16 = utf16 ++ .{tmp};
                continue;
            }

            var buf: [2]u16 = .{0} ** 2;
            if (utf8_iter.nextCodepoint()) |ch| {
                const n = if ((ch & 0xFFFF) == ch) b: {
                    buf[0] = @intCast(ch);
                    break :b 1;
                } else b: {
                    const code = ch - 0x1_0000;
                    buf[0] = 0xD800 | @as(u16, @intCast(code >> 10));
                    buf[1] = 0xDC00 | (@as(u16, @intCast(code)) & 0x3FF);
                    break :b 2;
                };
                if (n == 2) {
                    extra = buf[1];
                }
                utf16 = utf16 ++ .{buf[0]};
            } else break;
        }

        utf16 = utf16 ++ .{0};
        return utf16[0 .. utf16.len - 1 :0];
    }
}
