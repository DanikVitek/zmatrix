const std = @import("std");

pub fn termSize(file: std.fs.File) !TermSize {
    var buf: std.posix.winsize = undefined;
    return switch (std.posix.errno(
        std.posix.system.ioctl(
            file.handle,
            std.posix.T.IOCGWINSZ,
            @intFromPtr(&buf),
        ),
    )) {
        .SUCCESS => TermSize{
            .width = buf.col,
            .height = buf.row,
        },
        else => error.IoctlError,
    };
}

pub const TermSize = struct {
    width: u16,
    height: u16,
};

var orig_termios: ?std.posix.termios = null;

pub fn enableRawMode(file: std.fs.File) !void {
    if (orig_termios != null) {
        return;
    }

    const termios = try std.posix.tcgetattr(file.handle);

    var new_termios = termios;

    //   ECHO: Stop the terminal from displaying pressed keys.
    // ICANON: Disable canonical ("cooked") input mode. Allows us to read inputs
    //         byte-wise instead of line-wise.
    //   ISIG: Disable signals for Ctrl-C (SIGINT) and Ctrl-Z (SIGTSTP), so we
    //         can handle them as "normal" escape sequences.
    // IEXTEN: Disable input preprocessing. This allows us to handle Ctrl-V,
    //         which would otherwise be intercepted by some terminals.
    new_termios.lflag.ECHO = false;
    new_termios.lflag.ICANON = false;
    new_termios.lflag.ISIG = false;
    new_termios.lflag.IEXTEN = false;

    //   IXON: Disable software control flow. This allows us to handle Ctrl-S
    //         and Ctrl-Q.
    //  ICRNL: Disable converting carriage returns to newlines. Allows us to
    //         handle Ctrl-J and Ctrl-M.
    // BRKINT: Disable converting sending SIGINT on break conditions. Likely has
    //         no effect on anything remotely modern.
    //  INPCK: Disable parity checking. Likely has no effect on anything
    //         remotely modern.
    // ISTRIP: Disable stripping the 8th bit of characters. Likely has no effect
    //         on anything remotely modern.
    new_termios.iflag.IXON = false;
    new_termios.iflag.ICRNL = false;
    new_termios.iflag.BRKINT = false;
    new_termios.iflag.INPCK = false;
    new_termios.iflag.ISTRIP = false;

    // Disable output processing. Common output processing includes prefixing
    // newline with a carriage return.
    new_termios.oflag.OPOST = false;

    // Set the character size to 8 bits per byte. Likely has no effect on
    // anything remotely modern.
    new_termios.cflag.CSIZE = .CS8;

    // These are used to control the read syscall when getting input from the terminal interface
    // VTIME: Timeout in deciseconds for non-canonical read. 0 means no timeout.
    //  VMIN: Minimum number of bytes to read for non-canonical read. 1 means read at least 1 byte.
    new_termios.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    new_termios.cc[@intFromEnum(std.posix.V.MIN)] = 0;

    try std.posix.tcsetattr(
        file.handle,
        .FLUSH,
        new_termios,
    );

    orig_termios = termios;
}

pub fn disableRawMode(file: std.fs.File) !void {
    if (orig_termios) |termios| {
        try std.posix.tcsetattr(
            file.handle,
            .FLUSH,
            termios,
        );
        orig_termios = null;
    }
}
