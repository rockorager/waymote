//! Writes an H.264 RBSP bit by bit and wraps finished RBSPs in Annex-B NAL
//! units with emulation prevention.

const BitWriter = @This();

const std = @import("std");

/// Safety checks follow this module's optimize mode, which build.zig sets to
/// ReleaseFast in release builds of streamd: the checks cost about 40% of
/// encoding time there, while tests and h264-check keep them on.
const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

allocator: std.mem.Allocator,
bytes: std.ArrayList(u8) = .empty,
/// Bits not yet flushed to `bytes`, right-aligned.
pending: u64 = 0,
pending_count: u6 = 0,

pub fn init(allocator: std.mem.Allocator) BitWriter {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *BitWriter) void {
    self.bytes.deinit(self.allocator);
    self.* = undefined;
}

pub fn reset(self: *BitWriter) void {
    self.bytes.clearRetainingCapacity();
    self.pending = 0;
    self.pending_count = 0;
}

/// Writes the low `count` bits of `value`, most significant first.
pub fn bits(self: *BitWriter, value: u32, count: u6) !void {
    @setRuntimeSafety(runtime_safety);
    std.debug.assert(count <= 32);
    if (count == 0) return;
    std.debug.assert(count == 32 or value >> @intCast(count) == 0);
    self.pending = (self.pending << count) | value;
    self.pending_count += count;
    while (self.pending_count >= 8) {
        self.pending_count -= 8;
        try self.bytes.append(self.allocator, @truncate(self.pending >> self.pending_count));
    }
    self.pending &= (@as(u64, 1) << self.pending_count) - 1;
}

/// Bits written since the last `reset`.
pub fn bitCount(self: *const BitWriter) u64 {
    return self.bytes.items.len * 8 + self.pending_count;
}

pub fn flag(self: *BitWriter, value: bool) !void {
    try self.bits(@intFromBool(value), 1);
}

/// Unsigned Exp-Golomb, ue(v).
pub fn ue(self: *BitWriter, value: u32) !void {
    @setRuntimeSafety(runtime_safety);
    const code = @as(u64, value) + 1;
    const length: u6 = @intCast(63 - @clz(code));
    try self.bits(0, length);
    if (length + 1 > 32) {
        try self.bits(@intCast(code >> 32), length + 1 - 32);
        try self.bits(@truncate(code), 32);
    } else {
        try self.bits(@intCast(code), length + 1);
    }
}

/// Signed Exp-Golomb, se(v).
pub fn se(self: *BitWriter, value: i32) !void {
    @setRuntimeSafety(runtime_safety);
    const mapped: u32 = if (value > 0)
        @as(u32, @intCast(value)) * 2 - 1
    else
        @as(u32, @intCast(-@as(i64, value))) * 2;
    try self.ue(mapped);
}

/// rbsp_trailing_bits: a stop bit, then zeros to the byte boundary.
pub fn trailing(self: *BitWriter) !void {
    try self.bits(1, 1);
    if (self.pending_count != 0) try self.bits(0, 8 - self.pending_count);
}

/// Appends this RBSP to `output` as a NAL unit with a four-byte start code.
pub fn finishNal(
    self: *BitWriter,
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    nal_ref_idc: u2,
    nal_unit_type: u5,
) !void {
    @setRuntimeSafety(runtime_safety);
    std.debug.assert(self.pending_count == 0);
    try output.appendSlice(allocator, &.{ 0, 0, 0, 1, (@as(u8, nal_ref_idc) << 5) | nal_unit_type });
    var zeros: usize = 0;
    for (self.bytes.items) |byte| {
        if (zeros == 2 and byte <= 3) {
            try output.append(allocator, 3);
            zeros = 0;
        }
        try output.append(allocator, byte);
        zeros = if (byte == 0) zeros + 1 else 0;
    }
    self.reset();
}

test "Exp-Golomb codes match the H.264 codeNum table" {
    var writer = BitWriter.init(std.testing.allocator);
    defer writer.deinit();
    // ue: 0 -> 1, 1 -> 010, 2 -> 011, 3 -> 00100, 7 -> 0001000
    try writer.ue(0);
    try writer.ue(1);
    try writer.ue(2);
    try writer.ue(3);
    try writer.ue(7);
    // se: 1 -> 010, -1 -> 011, 2 -> 00100
    try writer.se(1);
    try writer.se(-1);
    try writer.se(2);
    try writer.trailing();
    // 1 010 011 00100 0001000 010 011 00100, stop bit 1, one padding zero
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0b10100110, 0b01000001, 0b00001001, 0b10010010 },
        writer.bytes.items,
    );
}

test "emulation prevention escapes start-code-like byte runs" {
    var writer = BitWriter.init(std.testing.allocator);
    defer writer.deinit();
    for ([_]u8{ 0, 0, 1, 0, 0, 0, 0, 0, 3, 0, 0, 4 }) |byte| try writer.bits(byte, 8);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    try writer.finishNal(&output, std.testing.allocator, 3, 7);
    try std.testing.expectEqualSlices(u8, &.{
        0, 0, 0, 1, 0x67,
        0, 0, 3, 1, 0,
        0, 3, 0, 0, 3,
        0, 3, 0, 0, 4,
    }, output.items);
}
