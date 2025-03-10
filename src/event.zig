const std = @import("std");
const builtin = @import("builtin");

pub fn poll(timeout_ns: u64) !bool {
    return poll_internal(timeout_ns, EventFilter.filter());
}

fn poll_internal(timeout_ns: ?u64, filter: Filter) !bool {
    var reader, const leftover_timeout_ns = if (timeout_ns) |timeout| b: {
        const poll_timeout = try PollTimeout.init(timeout);
        if (tryLockInternalEventReaderFor(timeout)) |reader| {
            break :b .{ reader, poll_timeout.leftover() };
        } else {
            return false;
        }
    } else {
        .{ lockInternalEventReader(), null };
    };
    defer mutex.unlock();
    reader.poll(leftover_timeout_ns, filter);
}

var internal_event_reader: ?InternalEventReader = null;
const mutex = std.Thread.Mutex{};

fn lockInternalEventReader() !*const InternalEventReader {
    mutex.lock();
    errdefer mutex.unlock();
    if (internal_event_reader) |*reader| {
        return reader;
    } else {
        internal_event_reader = InternalEventReader{};
        return &internal_event_reader;
    }
}

const InternalEventReader = struct {
    events: Events,
    source: ?EventSource,
    skipped_events: std.ArrayList(InternalEvent),

    const Events = std.fifo.LinearFifo(InternalEvent, .Dynamic);

    pub fn init(alloc: std.mem.Allocator) !InternalEventReader {
        var reader = InternalEventReader{
            .events = Events.init(alloc),
            .source = null,
            .skipped_events = try std.ArrayList(InternalEvent).initCapacity(alloc, 32),
        };

        try reader.events.ensureUnusedCapacity(32);

        return reader;
    }

    fn poll(self: *InternalEventReader, timeout_ns: ?u64, filter: Filter) !bool {
        for (0..self.events.count) |i| {
            
        }
    }
};

const EventSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        tryReadFn: *const fn (self: *anyopaque, timeout: ?u64) anyerror!?InternalEvent,
    };

    pub fn tryRead(self: EventSource, timeout: ?u64) anyerror!?InternalEvent {
        return self.vtable.tryReadFn(self.ptr, timeout);
    }
};

const WindowsEventSource = struct {
    pub fn tryRead(self: *const WindowsEventSource, timeout: ?u64) anyerror!?InternalEvent {
        _ = self;
        @panic("unimplemented");
    }
};

fn tryLockInternalEventReaderFor(timeout: PollTimeout) ?InternalEventReader {
    if (internal_event_reader) |reader| {
        return reader;
    } else {
        return null;
    }
}

const PollTimeout = struct {
    timeout_ns: ?u64,
    start: std.time.Instant,

    pub fn init(timeout_ns: ?u64) !PollTimeout {
        return .{ .timeout_ns = timeout_ns, .start = std.time.Instant.now() };
    }

    pub fn leftover(self: PollTimeout) ?u64 {
        return if (self.timeout_ns) |timeout_ns| b: {
            const elapsed = (try std.time.Instant.now()).since(self.start);
            break :b if (elapsed >= timeout_ns)
                0
            else
                (timeout_ns - elapsed);
        } else null;
    }
};

const Filter = struct {
    ptr: *const anyopaque,
    evalFn: *const fn (self: *const anyopaque, event: *const InternalEvent) bool,

    pub fn eval(self: Filter, event: *const InternalEvent) bool {
        return self.evalFn(self.ptr, event);
    }
};

const EventFilter = struct {
    pub fn filter(self: *const EventFilter) Filter {
        return .{
            .ptr = self,
            .evalFn = EventFilter.eval,
        };
    }

    pub fn eval(self: *const EventFilter, event: *const InternalEvent) bool {
        _ = self;
        if (builtin.os.tag == .windows) {
            return true;
        } else {
            return std.meta.activeTag(event.*) == .event;
        }
    }
};

const InternalEvent = union(enum) {
    event: Event,
    cursor_position: struct { u16, u16 },
    keyboard_enhancement_flags: KeyboardEnhancementFlags,
    primary_device_attributes,
};

const KeyboardEnhancementFlags = packed struct {
    disambiguate_escape_codes: bool = false,
    report_event_types: bool = false,
    report_alternate_keys: bool = false,
    report_all_keys_as_escape_codes: bool = false,
    // report_associated_text: bool = false,
};

pub fn read() !Event {
    @panic("unimplemented");
}

pub const Event = union(enum) {
    focus_gained,
    focus_lost,
    key: Key,
    mouse: Mouse,
    resize: struct { width: u32, height: u32 },

    pub const Key = struct {
        code: Code,
        modifiers: KeyModifiers,
        kind: Kind,
        state: State,

        pub const Code = union(enum) {
            /// Backspace key.
            backspace,
            /// Enter key.
            enter,
            /// Left arrow key.
            left,
            /// Right arrow key.
            right,
            /// Up arrow key.
            up,
            /// Down arrow key.
            down,
            /// Home key.
            home,
            /// End key.
            end,
            /// Page up key.
            page_up,
            /// Page down key.
            page_down,
            /// Tab key.
            tab,
            /// Shift + Tab key.
            back_tab,
            /// Delete key.
            delete,
            /// Insert key.
            insert,
            /// F key.
            ///
            /// `KeyCode{ .f = 1 }` represents F1 key, etc.
            f: std.math.IntFittingRange(1, 24),
            /// A character.
            ///
            /// `KeyCode{ .char = 'c' }` represents `c` character, etc.
            char: u21,
            /// Null.
            null,
            /// Escape key.
            esc,
            /// Caps Lock key.
            ///
            /// **Note:** this key can only be read if
            /// [`KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES`] has been enabled with
            /// [`PushKeyboardEnhancementFlags`].
            caps_lock,
            /// Scroll Lock key.
            ///
            /// **Note:** this key can only be read if
            /// [`KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES`] has been enabled with
            /// [`PushKeyboardEnhancementFlags`].
            scroll_lock,
            /// Num Lock key.
            ///
            /// **Note:** this key can only be read if
            /// [`KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES`] has been enabled with
            /// [`PushKeyboardEnhancementFlags`].
            num_lock,
            /// Print Screen key.
            ///
            /// **Note:** this key can only be read if
            /// [`KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES`] has been enabled with
            /// [`PushKeyboardEnhancementFlags`].
            print_screen,
            /// Pause key.
            ///
            /// **Note:** this key can only be read if
            /// [`KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES`] has been enabled with
            /// [`PushKeyboardEnhancementFlags`].
            pause,
            /// Menu key.
            ///
            /// **Note:** this key can only be read if
            /// [`KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES`] has been enabled with
            /// [`PushKeyboardEnhancementFlags`].
            menu,
            /// The "Begin" key (often mapped to the 5 key when Num Lock is turned on).
            ///
            /// **Note:** this key can only be read if
            /// [`KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES`] has been enabled with
            /// [`PushKeyboardEnhancementFlags`].
            keypad_begin,
            /// A media key.
            ///
            /// **Note:** these keys can only be read if
            /// [`KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES`] has been enabled with
            /// [`PushKeyboardEnhancementFlags`].
            media: Media,
            /// A modifier key.
            ///
            /// **Note:** these keys can only be read if **both**
            /// [`KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES`] and
            /// [`KeyboardEnhancementFlags::REPORT_ALL_KEYS_AS_ESCAPE_CODES`] have been enabled with
            /// [`PushKeyboardEnhancementFlags`].
            modifier: Modifier,

            pub const Media = enum {
                /// Play media key.
                play,
                /// Pause media key.
                pause,
                /// Play/Pause media key.
                play_pause,
                /// Reverse media key.
                reverse,
                /// Stop media key.
                stop,
                /// Fast-forward media key.
                fast_forward,
                /// Rewind media key.
                rewind,
                /// Next-track media key.
                track_next,
                /// Previous-track media key.
                track_previous,
                /// Record media key.
                record,
                /// Lower-volume media key.
                lower_volume,
                /// Raise-volume media key.
                raise_volume,
                /// Mute media key.
                mute_volume,
            };

            pub const Modifier = enum {
                /// Left Shift key.
                left_shift,
                /// Left Control key.
                left_control,
                /// Left Alt key.
                left_alt,
                /// Left Super key.
                left_super,
                /// Left Hyper key.
                left_hyper,
                /// Left Meta key.
                left_meta,
                /// Right Shift key.
                right_shift,
                /// Right Control key.
                right_control,
                /// Right Alt key.
                right_alt,
                /// Right Super key.
                right_super,
                /// Right Hyper key.
                right_hyper,
                /// Right Meta key.
                right_meta,
                /// Iso Level3 Shift key.
                iso_level3_shift,
                /// Iso Level5 Shift key.
                iso_level5_shift,
            };
        };

        pub const Kind = enum {
            press,
            repeat,
            release,
        };

        pub const State = packed struct {
            keypad: bool = false,
            _: u2 = 0,
            caps_num_lock: bool = false,
        };
    };

    pub const Mouse = struct {
        kind: Kind,
        column: u16,
        row: u16,
        modifiers: KeyModifiers,

        pub const Kind = union(enum) {
            /// Pressed mouse button. Contains the button that was pressed.
            down: Button,
            /// Released mouse button. Contains the button that was released.
            up: Button,
            /// Moved the mouse cursor while pressing the contained mouse button.
            drag: Button,
            /// Moved the mouse cursor while not pressing a mouse button.
            Moved,
            /// Scrolled mouse wheel downwards (towards the user).
            ScrollDown,
            /// Scrolled mouse wheel upwards (away from the user).
            ScrollUp,
            /// Scrolled mouse wheel left (mostly on a laptop touchpad).
            ScrollLeft,
            /// Scrolled mouse wheel right (mostly on a laptop touchpad).
            ScrollRight,
        };

        pub const Button = enum {
            left,
            right,
            middle,
            // button4,
            // button5,
            // button6,
            // button7,
            // button8,
        };
    };

    pub const KeyModifiers = packed struct {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        super: bool = false,
        hyper: bool = false,
        meta: bool = false,
    };
};
