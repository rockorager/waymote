//! Privileged browser-input injection through Wayland virtual input protocols.

const RemoteInput = @This();

const std = @import("std");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const zwp = wayland.client.zwp;

const xkb = @cImport({
    @cInclude("stdlib.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const record_size = 16;
const protocol_version = 2;
const pointer_extent = 65_535;

const CommandType = enum(u8) {
    pointer_motion = 1,
    pointer_button = 2,
    pointer_scroll = 3,
    keyboard_key = 4,
    release_all = 5,
    pointer_relative = 8,
};

pub const KeyState = enum(u8) {
    released = 0,
    pressed = 1,
    repeated = 2,
};

pub const Command = union(CommandType) {
    pointer_motion: struct { x: u32, y: u32, sequence: u32 },
    pointer_button: struct { button: u32, pressed: bool },
    pointer_scroll: struct { dx: f32, dy: f32 },
    keyboard_key: struct { key: u32, keysym: u32, state: KeyState },
    release_all,
    pointer_relative: struct { dx: f32, dy: f32, sequence: u32 },
};

allocator: std.mem.Allocator,
io: std.Io,
seat: ?*wl.Seat = null,
keyboard_manager: ?*zwp.VirtualKeyboardManagerV1 = null,
pointer_manager: ?*zwlr.VirtualPointerManagerV1 = null,
keyboard: ?*zwp.VirtualKeyboardV1 = null,
pointer: ?*zwlr.VirtualPointerV1 = null,
input_method_manager: ?*zwp.InputMethodManagerV2 = null,
input_method: ?*zwp.InputMethodV2 = null,
input_method_active: bool = false,
input_method_pending_active: ?bool = null,
input_method_done: u32 = 0,
keymap_file: ?std.Io.File = null,
xkb_context: ?*xkb.struct_xkb_context = null,
xkb_keymap: ?*xkb.struct_xkb_keymap = null,
xkb_state: ?*xkb.struct_xkb_state = null,
pressed_keys: [256]bool = @splat(false),
held_keysyms: [256]u32 = @splat(0),
resolved_keysyms: [256]u32 = @splat(0),
pressed_buttons: [5]bool = @splat(false),

layout: [:0]const u8 = "us",

pub fn init(allocator: std.mem.Allocator, io: std.Io, layout: [:0]const u8) RemoteInput {
    return .{ .allocator = allocator, .io = io, .layout = layout };
}

pub fn bindGlobal(
    self: *RemoteInput,
    registry: *wl.Registry,
    name: u32,
    interface: []const u8,
    version: u32,
) !void {
    if (std.mem.eql(u8, interface, std.mem.span(wl.Seat.interface.name))) {
        if (self.seat == null) {
            self.seat = try registry.bind(name, wl.Seat, @min(version, wl.Seat.generated_version));
        }
    } else if (std.mem.eql(
        u8,
        interface,
        std.mem.span(zwp.VirtualKeyboardManagerV1.interface.name),
    )) {
        if (self.keyboard_manager == null) {
            self.keyboard_manager = try registry.bind(name, zwp.VirtualKeyboardManagerV1, 1);
        }
    } else if (std.mem.eql(
        u8,
        interface,
        std.mem.span(zwlr.VirtualPointerManagerV1.interface.name),
    )) {
        if (self.pointer_manager == null) {
            self.pointer_manager = try registry.bind(
                name,
                zwlr.VirtualPointerManagerV1,
                @min(version, zwlr.VirtualPointerManagerV1.generated_version),
            );
        }
    } else if (std.mem.eql(u8, interface, std.mem.span(zwp.InputMethodManagerV2.interface.name))) {
        if (self.input_method_manager == null) {
            self.input_method_manager = try registry.bind(name, zwp.InputMethodManagerV2, 1);
        }
    }
}

pub fn start(self: *RemoteInput, output: *wl.Output) !void {
    const seat = self.seat orelse return error.MissingInputSeat;
    const pointer_manager = self.pointer_manager orelse return error.MissingVirtualPointer;
    const keyboard_manager = self.keyboard_manager orelse return error.MissingVirtualKeyboard;

    self.pointer = if (pointer_manager.getVersion() >=
        zwlr.VirtualPointerManagerV1.create_virtual_pointer_with_output_since_version)
        try pointer_manager.createVirtualPointerWithOutput(seat, output)
    else
        try pointer_manager.createVirtualPointer(seat);
    self.keyboard = try keyboard_manager.createVirtualKeyboard(seat);
    try self.installKeymap();
    if (self.input_method_manager) |manager| {
        self.input_method = try manager.getInputMethod(seat);
        self.input_method.?.setListener(*RemoteInput, inputMethodListener, self);
    }
}

pub fn deinit(self: *RemoteInput) void {
    self.releaseAll();
    if (self.pointer) |pointer| pointer.destroy();
    if (self.input_method) |method| method.destroy();
    if (self.input_method_manager) |manager| manager.destroy();
    if (self.keyboard) |keyboard| keyboard.destroy();
    if (self.keymap_file) |file| file.close(self.io);
    if (self.xkb_state) |state| xkb.xkb_state_unref(state);
    if (self.xkb_keymap) |keymap| xkb.xkb_keymap_unref(keymap);
    if (self.xkb_context) |context| xkb.xkb_context_unref(context);
    if (self.pointer_manager) |manager| manager.destroy();
    if (self.keyboard_manager) |manager| manager.destroy();
    if (self.seat) |seat| {
        if (seat.getVersion() >= wl.Seat.release_since_version) {
            seat.release();
        } else {
            seat.destroy();
        }
    }
    self.* = undefined;
}

pub fn apply(self: *RemoteInput, command: Command) void {
    const time = monotonicMilliseconds();
    switch (command) {
        .pointer_motion => |motion| {
            const pointer = self.pointer orelse return;
            pointer.motionAbsolute(time, motion.x, motion.y, pointer_extent, pointer_extent);
            pointer.frame();
        },
        .pointer_relative => |motion| {
            const pointer = self.pointer orelse return;
            pointer.motion(time, wl.Fixed.fromDouble(motion.dx), wl.Fixed.fromDouble(motion.dy));
            pointer.frame();
        },
        .pointer_button => |button| self.applyButton(time, button.button, button.pressed),
        .pointer_scroll => |scroll| {
            const pointer = self.pointer orelse return;
            pointer.axisSource(.continuous);
            if (scroll.dx != 0) {
                pointer.axis(time, .horizontal_scroll, wl.Fixed.fromDouble(scroll.dx));
            }
            if (scroll.dy != 0) {
                pointer.axis(time, .vertical_scroll, wl.Fixed.fromDouble(scroll.dy));
            }
            pointer.frame();
        },
        .keyboard_key => |key| self.applyKey(time, key.key, key.keysym, key.state),
        .release_all => self.releaseAll(),
    }
}

pub fn decodeRecord(record: *const [record_size]u8) !Command {
    if (record[0] != protocol_version or record[3] != 0) {
        return error.InvalidInputRecord;
    }
    const command_type = std.enums.fromInt(CommandType, record[1]) orelse
        return error.InvalidInputRecord;
    const key_state = std.enums.fromInt(KeyState, record[2]) orelse
        return error.InvalidInputRecord;
    const a = std.mem.readInt(u32, record[4..8], .little);
    const b = std.mem.readInt(u32, record[8..12], .little);
    const c = std.mem.readInt(u32, record[12..16], .little);
    return switch (command_type) {
        .pointer_motion => if (a <= pointer_extent and b <= pointer_extent and
            key_state == .released and c != 0)
            .{ .pointer_motion = .{ .x = a, .y = b, .sequence = c } }
        else
            error.InvalidInputRecord,
        .pointer_relative => blk: {
            const dx: f32 = @bitCast(a);
            const dy: f32 = @bitCast(b);
            if (!std.math.isFinite(dx) or !std.math.isFinite(dy) or @abs(dx) > 4096 or
                @abs(dy) > 4096 or key_state != .released or c == 0) break :blk error.InvalidInputRecord;
            break :blk .{ .pointer_relative = .{ .dx = dx, .dy = dy, .sequence = c } };
        },
        .pointer_button => if (buttonIndex(a) != null and b == 0 and c != 0 and
            key_state != .repeated)
            .{ .pointer_button = .{ .button = a, .pressed = key_state == .pressed } }
        else
            error.InvalidInputRecord,
        .pointer_scroll => blk: {
            const dx: f32 = @bitCast(a);
            const dy: f32 = @bitCast(b);
            if (!std.math.isFinite(dx) or !std.math.isFinite(dy) or
                @abs(dx) > 4096 or @abs(dy) > 4096 or key_state != .released or c == 0)
            {
                break :blk error.InvalidInputRecord;
            }
            break :blk .{ .pointer_scroll = .{ .dx = dx, .dy = dy } };
        },
        .keyboard_key => if (a > 0 and a < 256 and validResolvedKeysym(b) and c != 0)
            .{ .keyboard_key = .{ .key = a, .keysym = b, .state = key_state } }
        else
            error.InvalidInputRecord,
        .release_all => if (a == 0 and b == 0 and c == 0 and key_state == .released)
            .release_all
        else
            error.InvalidInputRecord,
    };
}

fn installKeymap(self: *RemoteInput) !void {
    if (self.xkb_context == null) {
        self.xkb_context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
    }
    const base_keymap = xkb.xkb_keymap_new_from_names(
        self.xkb_context.?,
        &xkb.struct_xkb_rule_names{
            .rules = null,
            .model = null,
            .layout = self.layout.ptr,
            .variant = null,
            .options = null,
        },
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.XkbKeymapFailed;
    defer xkb.xkb_keymap_unref(base_keymap);
    const source = try keymapSource(self.allocator, base_keymap, &self.resolved_keysyms);
    defer self.allocator.free(source);
    const keymap = xkb.xkb_keymap_new_from_string(
        self.xkb_context.?,
        source.ptr,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.XkbKeymapFailed;
    errdefer xkb.xkb_keymap_unref(keymap);
    const state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;
    errdefer xkb.xkb_state_unref(state);
    if (self.xkb_state) |old_state| {
        restoreXKBState(state, old_state, &self.pressed_keys);
    }
    const text_pointer = xkb.xkb_keymap_get_as_string(
        keymap,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
    ) orelse return error.SerializeKeymapFailed;
    defer xkb.free(text_pointer);
    const text = std.mem.span(text_pointer);
    const size = std.math.add(usize, text.len, 1) catch return error.KeymapTooLarge;
    if (size > std.math.maxInt(u32)) return error.KeymapTooLarge;

    const fd = try std.posix.memfd_create("waymote-keymap", std.os.linux.MFD.CLOEXEC);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    errdefer file.close(self.io);
    try file.setLength(self.io, size);
    try file.writeStreamingAll(self.io, text_pointer[0..size]);
    const old_file = self.keymap_file;
    self.keymap_file = file;
    self.keyboard.?.keymap(.xkb_v1, fd, @intCast(size));
    if (old_file) |old| old.close(self.io);
    if (self.xkb_state) |old_state| xkb.xkb_state_unref(old_state);
    if (self.xkb_keymap) |old_keymap| xkb.xkb_keymap_unref(old_keymap);
    self.xkb_keymap = keymap;
    self.xkb_state = state;
    // Clients create a fresh XKB state on keymap replacement. Force a
    // modifier transition so compositors that suppress unchanged masks
    // still restore held Ctrl/Alt/etc. before the next physical shortcut.
    self.sendNeutralModifiers();
    self.sendModifiers();
}

fn restoreXKBState(
    state: *xkb.struct_xkb_state,
    old_state: *xkb.struct_xkb_state,
    pressed_keys: *const [256]bool,
) void {
    for (pressed_keys, 0..) |pressed, key| {
        if (pressed) {
            _ = xkb.xkb_state_update_key(state, @intCast(key + 8), xkb.XKB_KEY_DOWN);
        }
    }
    _ = xkb.xkb_state_update_mask(
        state,
        xkb.xkb_state_serialize_mods(state, xkb.XKB_STATE_MODS_DEPRESSED),
        xkb.xkb_state_serialize_mods(old_state, xkb.XKB_STATE_MODS_LATCHED),
        xkb.xkb_state_serialize_mods(old_state, xkb.XKB_STATE_MODS_LOCKED),
        0,
        0,
        xkb.xkb_state_serialize_layout(old_state, xkb.XKB_STATE_LAYOUT_LOCKED),
    );
}

fn keymapSource(
    allocator: std.mem.Allocator,
    base_keymap: *xkb.struct_xkb_keymap,
    resolved_keysyms: *const [256]u32,
) ![:0]u8 {
    const text_pointer = xkb.xkb_keymap_get_as_string(
        base_keymap,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
    ) orelse return error.SerializeKeymapFailed;
    defer xkb.free(text_pointer);
    const text = std.mem.span(text_pointer);
    // Amend xkbcommon's serialized symbols section, preserving all rules,
    // model and option resolution in the base map. Its section terminators
    // are unindented; individual key definitions are indented.
    const symbols = std.mem.indexOf(u8, text, "\nxkb_symbols ") orelse
        return error.InvalidKeymapSource;
    const end = std.mem.indexOfPos(u8, text, symbols, "\n};") orelse
        return error.InvalidKeymapSource;
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(allocator);
    try source.appendSlice(allocator, text[0..end]);
    try source.append(allocator, '\n');
    for (resolved_keysyms, 0..) |keysym, key| {
        if (keysym == 0) continue;
        const name_pointer = xkb.xkb_keymap_key_get_name(base_keymap, @intCast(key + 8)) orelse
            return error.XkbKeyNameMissing;
        try source.print(
            allocator,
            "override key <{s}> {{ repeat=no, type=\"ONE_LEVEL\", symbols[Group1]= [ 0x{x:0>8} ] }};\n",
            .{ std.mem.span(name_pointer), keysym },
        );
    }
    try source.appendSlice(allocator, text[end..]);
    return source.toOwnedSliceSentinel(allocator, 0);
}

pub fn sendText(self: *RemoteInput, preedit: bool, text: []const u8) void {
    if (!self.input_method_active) return;
    const method = self.input_method orelse return;
    if (text.len > 4000) return;
    var terminated: [4001]u8 = undefined;
    @memcpy(terminated[0..text.len], text);
    terminated[text.len] = 0;
    const value: [*:0]const u8 = @ptrCast(&terminated);
    if (preedit) {
        method.setPreeditString(value, @intCast(text.len), @intCast(text.len));
    } else {
        method.setPreeditString("", 0, 0);
        method.commitString(value);
    }
    method.commit(self.input_method_done);
}

fn inputMethodListener(_: *zwp.InputMethodV2, event: zwp.InputMethodV2.Event, self: *RemoteInput) void {
    switch (event) {
        .activate => self.input_method_pending_active = true,
        .deactivate => self.input_method_pending_active = false,
        .done => {
            if (self.input_method_pending_active) |active| {
                self.input_method_active = active;
                self.input_method_pending_active = null;
            }
            self.input_method_done +%= 1;
        },
        .unavailable => {
            self.input_method_active = false;
            self.input_method_pending_active = null;
            if (self.input_method) |method| method.destroy();
            self.input_method = null;
        },
        else => {},
    }
}

pub fn validLayout(layout: []const u8) bool {
    if (layout.len == 0 or layout.len > 32) return false;
    for (layout) |character| if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-') return false;
    return true;
}

fn applyButton(self: *RemoteInput, time: u32, button: u32, pressed: bool) void {
    const index = buttonIndex(button) orelse return;
    if (self.pressed_buttons[index] == pressed) return;
    self.pressed_buttons[index] = pressed;
    const pointer = self.pointer orelse return;
    pointer.button(time, button, if (pressed) .pressed else .released);
    pointer.frame();
}

fn applyKey(self: *RemoteInput, time: u32, key: u32, keysym: u32, state: KeyState) void {
    if (key == 0 or key >= self.pressed_keys.len) return;
    const keyboard = self.keyboard orelse return;
    const pressed = state == .pressed;
    if (state == .repeated) {
        if (!self.pressed_keys[key]) return;
    } else if (self.pressed_keys[key] == pressed) {
        return;
    }
    // Keep the initial physical/resolved route, but allow a resolved repeat
    // to change character (e.g. releasing Shift while holding a digit).
    // Older clients send zero on repeats; retain their last resolved symbol.
    if (pressed or (state == .repeated and self.held_keysyms[key] != 0 and keysym != 0)) {
        if (self.resolved_keysyms[key] != keysym) {
            const old_keysym = self.resolved_keysyms[key];
            self.resolved_keysyms[key] = keysym;
            self.installKeymap() catch {
                self.resolved_keysyms[key] = old_keysym;
                return;
            };
        }
        self.held_keysyms[key] = keysym;
    }
    if (state == .repeated) {
        // Preserve browser-owned cadence for clients predating wl_keyboard's
        // repeated pseudo-state without changing our tracked held-key state.
        if (self.held_keysyms[key] != 0) self.sendNeutralModifiers();
        keyboard.key(time, key, @intFromEnum(KeyState.released));
        keyboard.key(time, key, @intFromEnum(KeyState.pressed));
        if (self.held_keysyms[key] != 0) self.sendModifiers();
        return;
    }
    if (self.held_keysyms[key] != 0) self.sendNeutralModifiers();
    self.pressed_keys[key] = pressed;
    keyboard.key(time, key, @intFromEnum(state));
    _ = xkb.xkb_state_update_key(
        self.xkb_state.?,
        key + 8,
        if (pressed) xkb.XKB_KEY_DOWN else xkb.XKB_KEY_UP,
    );
    self.sendModifiers();
    if (!pressed) self.held_keysyms[key] = 0;
}

fn sendNeutralModifiers(self: *RemoteInput) void {
    self.keyboard.?.modifiers(0, 0, 0, 0);
}

fn sendModifiers(self: *RemoteInput) void {
    const state = self.xkb_state orelse return;
    self.keyboard.?.modifiers(
        xkb.xkb_state_serialize_mods(state, xkb.XKB_STATE_MODS_DEPRESSED),
        xkb.xkb_state_serialize_mods(state, xkb.XKB_STATE_MODS_LATCHED),
        xkb.xkb_state_serialize_mods(state, xkb.XKB_STATE_MODS_LOCKED),
        xkb.xkb_state_serialize_layout(state, xkb.XKB_STATE_LAYOUT_EFFECTIVE),
    );
}

pub fn releaseAll(self: *RemoteInput) void {
    const time = monotonicMilliseconds();
    for (&self.pressed_buttons, 0..) |*pressed, index| {
        if (!pressed.*) continue;
        pressed.* = false;
        if (self.pointer) |pointer| {
            pointer.button(time, buttonAt(index), .released);
        }
    }
    if (self.pointer) |pointer| pointer.frame();

    var released_key = false;
    for (&self.pressed_keys, 0..) |*pressed, key| {
        if (!pressed.*) continue;
        pressed.* = false;
        self.held_keysyms[key] = 0;
        released_key = true;
        if (self.keyboard) |keyboard| {
            keyboard.key(time, @intCast(key), @intFromEnum(wl.Keyboard.KeyState.released));
        }
        if (self.xkb_state) |state| {
            _ = xkb.xkb_state_update_key(state, @intCast(key + 8), xkb.XKB_KEY_UP);
        }
    }
    if (released_key) self.sendModifiers();
    if (std.mem.allEqual(u32, &self.resolved_keysyms, 0)) return;
    const old_keysyms = self.resolved_keysyms;
    self.resolved_keysyms = @splat(0);
    self.installKeymap() catch {
        self.resolved_keysyms = old_keysyms;
    };
}

fn validResolvedKeysym(keysym: u32) bool {
    if (keysym == 0 or (keysym >= 0x20 and keysym <= 0x7e) or
        (keysym >= 0xa0 and keysym <= 0xff)) return true;
    if (keysym < 0x01000100 or keysym > 0x0110ffff) return false;
    const code_point = keysym & 0x00ffffff;
    return code_point < 0xd800 or code_point > 0xdfff;
}

fn buttonIndex(button: u32) ?usize {
    return switch (button) {
        0x110 => 0,
        0x111 => 1,
        0x112 => 2,
        0x113 => 3,
        0x114 => 4,
        else => null,
    };
}

fn buttonAt(index: usize) u32 {
    return switch (index) {
        0 => 0x110,
        1 => 0x111,
        2 => 0x112,
        3 => 0x113,
        4 => 0x114,
        else => unreachable,
    };
}

fn monotonicMilliseconds() u32 {
    var timestamp: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &timestamp);
    const seconds: u64 = @intCast(timestamp.sec);
    const nanoseconds: u64 = @intCast(timestamp.nsec);
    return @truncate(seconds * 1000 + nanoseconds / std.time.ns_per_ms);
}

test "remote input records decode bounded commands" {
    var record: [record_size]u8 = @splat(0);
    record[0] = protocol_version;
    record[1] = @intFromEnum(CommandType.pointer_motion);
    std.mem.writeInt(u32, record[4..8], 32_768, .little);
    std.mem.writeInt(u32, record[8..12], pointer_extent, .little);
    std.mem.writeInt(u32, record[12..16], 42, .little);
    try std.testing.expectEqual(
        Command{ .pointer_motion = .{ .x = 32_768, .y = pointer_extent, .sequence = 42 } },
        try decodeRecord(&record),
    );

    record[1] = @intFromEnum(CommandType.keyboard_key);
    record[2] = 1;
    std.mem.writeInt(u32, record[4..8], 30, .little);
    std.mem.writeInt(u32, record[8..12], 0, .little);
    try std.testing.expectEqual(
        Command{ .keyboard_key = .{ .key = 30, .keysym = 0, .state = .pressed } },
        try decodeRecord(&record),
    );

    record[2] = 2;
    try std.testing.expectEqual(
        Command{ .keyboard_key = .{ .key = 30, .keysym = 0, .state = .repeated } },
        try decodeRecord(&record),
    );

    std.mem.writeInt(u32, record[8..12], 0x010020ac, .little);
    try std.testing.expectEqual(
        Command{ .keyboard_key = .{ .key = 30, .keysym = 0x010020ac, .state = .repeated } },
        try decodeRecord(&record),
    );

    record[1] = @intFromEnum(CommandType.pointer_button);
    record[2] = 1;
    std.mem.writeInt(u32, record[4..8], 0x111, .little);
    std.mem.writeInt(u32, record[8..12], 0, .little);
    try std.testing.expectEqual(
        Command{ .pointer_button = .{ .button = 0x111, .pressed = true } },
        try decodeRecord(&record),
    );
}

test "resolved keysym overlays compile and replace the physical symbol" {
    const context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbContextFailed;
    defer xkb.xkb_context_unref(context);
    const base_keymap = xkb.xkb_keymap_new_from_names(
        context,
        &xkb.struct_xkb_rule_names{
            .rules = null,
            .model = null,
            .layout = "us",
            .variant = null,
            .options = null,
        },
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.XkbKeymapFailed;
    defer xkb.xkb_keymap_unref(base_keymap);
    var resolved_keysyms: [256]u32 = @splat(0);
    resolved_keysyms[16] = 0x27;
    resolved_keysyms[30] = 0xfc;
    const source = try keymapSource(
        std.testing.allocator,
        base_keymap,
        &resolved_keysyms,
    );
    defer std.testing.allocator.free(source);
    const keymap = xkb.xkb_keymap_new_from_string(
        context,
        source.ptr,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.XkbKeymapFailed;
    defer xkb.xkb_keymap_unref(keymap);
    const state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;
    defer xkb.xkb_state_unref(state);

    try std.testing.expectEqual(@as(u32, 0x27), xkb.xkb_state_key_get_one_sym(state, 16 + 8));
    try std.testing.expectEqual(@as(u32, 0xfc), xkb.xkb_state_key_get_one_sym(state, 30 + 8));
}

test "resolved keymap transitions preserve configured base options" {
    const context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbContextFailed;
    defer xkb.xkb_context_unref(context);
    const base_keymap = xkb.xkb_keymap_new_from_names(
        context,
        &xkb.struct_xkb_rule_names{
            .rules = null,
            .model = null,
            .layout = "us",
            .variant = null,
            .options = "ctrl:nocaps",
        },
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.XkbKeymapFailed;
    defer xkb.xkb_keymap_unref(base_keymap);
    var resolved_keysyms: [256]u32 = @splat(0);
    // Start physical, resolve Shift+2, release Shift, change layout, then
    // return to physical input. Caps-as-Ctrl must survive every replacement.
    for ([_]u32{ 0, 0x40, 0x32, 0x01000106, 0 }) |keysym| {
        resolved_keysyms[3] = keysym;
        const source = try keymapSource(std.testing.allocator, base_keymap, &resolved_keysyms);
        defer std.testing.allocator.free(source);
        const keymap = xkb.xkb_keymap_new_from_string(
            context,
            source.ptr,
            xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
            xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.XkbKeymapFailed;
        defer xkb.xkb_keymap_unref(keymap);
        const state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;
        defer xkb.xkb_state_unref(state);
        try std.testing.expectEqual(@as(u32, xkb.XKB_KEY_Control_L), xkb.xkb_state_key_get_one_sym(state, 58 + 8));
        try std.testing.expectEqual(if (keysym == 0) @as(u32, 0x32) else keysym, xkb.xkb_state_key_get_one_sym(state, 3 + 8));
        try std.testing.expectEqual(@as(c_int, if (keysym == 0) 1 else 0), xkb.xkb_keymap_key_repeats(keymap, 3 + 8));
        _ = xkb.xkb_state_update_key(state, 58 + 8, xkb.XKB_KEY_DOWN);
        try std.testing.expect(xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_CTRL, xkb.XKB_STATE_MODS_DEPRESSED) > 0);
        _ = xkb.xkb_state_update_key(state, 58 + 8, xkb.XKB_KEY_UP);
        try std.testing.expectEqual(@as(u32, 0), xkb.xkb_state_serialize_mods(state, xkb.XKB_STATE_MODS_DEPRESSED));
    }
}

test "resolved keysyms accept printable Unicode scalar values" {
    try std.testing.expect(validResolvedKeysym(0));
    try std.testing.expect(validResolvedKeysym(0x20));
    try std.testing.expect(validResolvedKeysym(0xfc));
    try std.testing.expect(validResolvedKeysym(0x0101f986));
    try std.testing.expect(!validResolvedKeysym(0x1f));
    try std.testing.expect(!validResolvedKeysym(0x0100d800));
    try std.testing.expect(!validResolvedKeysym(0x01110000));
}

test "keymap replacement retains and releases held modifiers" {
    const context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbContextFailed;
    defer xkb.xkb_context_unref(context);
    const keymap = xkb.xkb_keymap_new_from_names(
        context,
        &xkb.struct_xkb_rule_names{
            .rules = null,
            .model = null,
            .layout = "us",
            .variant = null,
            .options = null,
        },
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return error.XkbKeymapFailed;
    defer xkb.xkb_keymap_unref(keymap);
    const old_state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;
    defer xkb.xkb_state_unref(old_state);
    const replacement_state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;
    defer xkb.xkb_state_unref(replacement_state);
    const shift_key = 42;
    _ = xkb.xkb_state_update_key(old_state, shift_key + 8, xkb.XKB_KEY_DOWN);
    var pressed_keys: [256]bool = @splat(false);
    pressed_keys[shift_key] = true;

    restoreXKBState(replacement_state, old_state, &pressed_keys);
    try std.testing.expect(xkb.xkb_state_serialize_mods(
        replacement_state,
        xkb.XKB_STATE_MODS_DEPRESSED,
    ) != 0);
    _ = xkb.xkb_state_update_key(replacement_state, shift_key + 8, xkb.XKB_KEY_UP);
    try std.testing.expectEqual(@as(u32, 0), xkb.xkb_state_serialize_mods(
        replacement_state,
        xkb.XKB_STATE_MODS_DEPRESSED,
    ));
}

test "v2 relative input preserves sequence and layout names are conservative" {
    var record: [record_size]u8 = @splat(0);
    record[0] = protocol_version;
    record[1] = @intFromEnum(CommandType.pointer_relative);
    std.mem.writeInt(u32, record[4..8], @bitCast(@as(f32, -12.5)), .little);
    std.mem.writeInt(u32, record[8..12], @bitCast(@as(f32, 4.25)), .little);
    std.mem.writeInt(u32, record[12..16], 99, .little);
    try std.testing.expectEqual(Command{ .pointer_relative = .{ .dx = -12.5, .dy = 4.25, .sequence = 99 } }, try decodeRecord(&record));
    try std.testing.expect(validLayout("us-intl"));
    try std.testing.expect(!validLayout("../us"));
}

test "remote input records reject out of range pointer coordinates" {
    var record: [record_size]u8 = @splat(0);
    record[0] = protocol_version;
    record[1] = @intFromEnum(CommandType.pointer_motion);
    std.mem.writeInt(u32, record[4..8], pointer_extent + 1, .little);
    try std.testing.expectError(error.InvalidInputRecord, decodeRecord(&record));
}
