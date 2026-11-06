//! CAVLC residual block coding (ITU-T H.264 clause 9.2) for the encoder.
//!
//! Code tables are indexed `[TotalCoeff * 4 + TrailingOnes]` for coeff_token,
//! `[TotalCoeff - 1][total_zeros]` for total_zeros, and
//! `[min(zerosLeft, 7) - 1][run_before]` for run_before.

const std = @import("std");

/// Safety checks follow this module's optimize mode, which build.zig sets to
/// ReleaseFast in release builds of streamd: the checks cost about 40% of
/// encoding time there, while tests and h264-check keep them on.
const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};
const BitWriter = @import("BitWriter.zig");

/// Largest level magnitude that every suffix length can code with a level
/// prefix of at most 15, the Baseline profile limit.
pub const maximum_level = 2047;

/// Table 9-5 columns for 0 <= nC < 2, 2 <= nC < 4, 4 <= nC < 8, and 8 <= nC.
const coeff_token_length = [4][4 * 17]u8{
    .{
        1,  0,  0,  0,  6,  2,  0,  0,  8,  6,  3,  0,  9,  8,  7,  5,  10, 9,  8,  6,
        11, 10, 9,  7,  13, 11, 10, 8,  13, 13, 11, 9,  13, 13, 13, 10, 14, 14, 13, 11,
        14, 14, 14, 13, 15, 15, 14, 14, 15, 15, 15, 14, 16, 15, 15, 15, 16, 16, 16, 15,
        16, 16, 16, 16, 16, 16, 16, 16,
    },
    .{
        2,  0,  0,  0,  6,  2,  0,  0,  6,  5,  3,  0,  7,  6,  6,  4,  8,  6,  6,  4,
        8,  7,  7,  5,  9,  8,  8,  6,  11, 9,  9,  6,  11, 11, 11, 7,  12, 11, 11, 9,
        12, 12, 12, 11, 12, 12, 12, 11, 13, 13, 13, 12, 13, 13, 13, 13, 13, 14, 13, 13,
        14, 14, 14, 13, 14, 14, 14, 14,
    },
    .{
        4,  0,  0,  0,  6,  4,  0,  0,  6, 5, 4, 0, 6,  5, 5, 4, 7,  5,  5,  4,
        7,  5,  5,  4,  7,  6,  6,  4,  7, 6, 6, 4, 8,  7, 7, 5, 8,  8,  7,  6,
        9,  8,  8,  7,  9,  9,  8,  8,  9, 9, 9, 8, 10, 9, 9, 9, 10, 10, 10, 10,
        10, 10, 10, 10, 10, 10, 10, 10,
    },
    @splat(6),
};

const coeff_token_code = [4][4 * 17]u8{
    .{
        1,  0,  0,  0,  5,  1,  0, 0,  7,  4,  1,  0, 7,  6,  5,  3,  7,  6,  5,  3,
        7,  6,  5,  4,  15, 6,  5, 4,  11, 14, 5,  4, 8,  10, 13, 4,  15, 14, 9,  4,
        11, 10, 13, 12, 15, 14, 9, 12, 11, 10, 13, 8, 15, 1,  9,  12, 11, 14, 13, 8,
        7,  10, 9,  12, 4,  6,  5, 8,
    },
    .{
        3,  0,  0,  0,  11, 2,  0, 0, 7,  7,  3,  0,  7,  10, 9,  5,  7,  6,  5, 4,
        4,  6,  5,  6,  7,  6,  5, 8, 15, 6,  5,  4,  11, 14, 13, 4,  15, 10, 9, 4,
        11, 14, 13, 12, 8,  10, 9, 8, 15, 14, 13, 12, 11, 10, 9,  12, 7,  11, 6, 8,
        9,  8,  10, 1,  7,  6,  5, 4,
    },
    .{
        15, 0,  0,  0,  15, 14, 0,  0,  11, 15, 13, 0, 8,  12, 14, 12, 15, 10, 11, 11,
        11, 8,  9,  10, 9,  14, 13, 9,  8,  10, 9,  8, 15, 14, 13, 13, 11, 14, 10, 12,
        15, 10, 13, 12, 11, 14, 9,  12, 8,  10, 13, 8, 13, 7,  9,  12, 9,  12, 11, 10,
        5,  8,  7,  6,  1,  4,  3,  2,
    },
    fixedLengthCodes(),
};

/// 8 <= nC uses a 6-bit code: TotalCoeff - 1 then TrailingOnes, with 000011
/// for no coefficients.
fn fixedLengthCodes() [4 * 17]u8 {
    var codes: [4 * 17]u8 = @splat(0);
    codes[0] = 3;
    for (1..17) |total| {
        for (0..4) |ones| codes[total * 4 + ones] = @intCast((total - 1) << 2 | ones);
    }
    return codes;
}

/// Table 9-5 column for nC == -1 (4:2:0 chroma DC).
const chroma_dc_coeff_token_length = [4 * 5]u8{
    2, 0, 0, 0, 6, 1, 0, 0, 6, 6, 3, 0, 6, 7, 7, 6, 6, 8, 8, 7,
};
const chroma_dc_coeff_token_code = [4 * 5]u8{
    1, 0, 0, 0, 7, 1, 0, 0, 4, 6, 1, 0, 3, 3, 2, 5, 2, 3, 2, 0,
};

/// Tables 9-7 and 9-8.
const total_zeros_length = [15][16]u8{
    .{ 1, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 9 },
    .{ 3, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 6, 6, 6, 6, 0 },
    .{ 4, 3, 3, 3, 4, 4, 3, 3, 4, 5, 5, 6, 5, 6, 0, 0 },
    .{ 5, 3, 4, 4, 3, 3, 3, 4, 3, 4, 5, 5, 5, 0, 0, 0 },
    .{ 4, 4, 4, 3, 3, 3, 3, 3, 4, 5, 4, 5, 0, 0, 0, 0 },
    .{ 6, 5, 3, 3, 3, 3, 3, 3, 4, 3, 6, 0, 0, 0, 0, 0 },
    .{ 6, 5, 3, 3, 3, 2, 3, 4, 3, 6, 0, 0, 0, 0, 0, 0 },
    .{ 6, 4, 5, 3, 2, 2, 3, 3, 6, 0, 0, 0, 0, 0, 0, 0 },
    .{ 6, 6, 4, 2, 2, 3, 2, 5, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 5, 5, 3, 2, 2, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 4, 4, 3, 3, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 4, 4, 2, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 3, 3, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};
const total_zeros_code = [15][16]u8{
    .{ 1, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 3, 2, 1 },
    .{ 7, 6, 5, 4, 3, 5, 4, 3, 2, 3, 2, 3, 2, 1, 0, 0 },
    .{ 5, 7, 6, 5, 4, 3, 4, 3, 2, 3, 2, 1, 1, 0, 0, 0 },
    .{ 3, 7, 5, 4, 6, 5, 4, 3, 3, 2, 2, 1, 0, 0, 0, 0 },
    .{ 5, 4, 3, 7, 6, 5, 4, 3, 2, 1, 1, 0, 0, 0, 0, 0 },
    .{ 1, 1, 7, 6, 5, 4, 3, 2, 1, 1, 0, 0, 0, 0, 0, 0 },
    .{ 1, 1, 5, 4, 3, 3, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 1, 1, 3, 3, 2, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 0, 1, 3, 2, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 0, 1, 3, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 2, 1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

/// Table 9-9a (4:2:0 chroma DC).
const chroma_dc_total_zeros_length = [3][4]u8{ .{ 1, 2, 3, 3 }, .{ 1, 2, 2, 0 }, .{ 1, 1, 0, 0 } };
const chroma_dc_total_zeros_code = [3][4]u8{ .{ 1, 1, 1, 0 }, .{ 1, 1, 0, 0 }, .{ 1, 0, 0, 0 } };

/// Table 9-10.
const run_before_length = [7][15]u8{
    .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 2, 2, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 2, 2, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 2, 3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 2, 3, 3, 3, 3, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 3, 3, 3, 3, 3, 3, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
};
const run_before_code = [7][15]u8{
    .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 3, 2, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 3, 2, 3, 2, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 3, 0, 1, 3, 2, 5, 4, 0, 0, 0, 0, 0, 0, 0, 0 },
    .{ 7, 6, 5, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1 },
};

/// The nC value that selects the 4:2:0 chroma DC tables.
pub const chroma_dc_nc = -1;

/// Writes residual_block_cavlc for `coefficients`, given in scan order with
/// `coefficients.len` equal to maxNumCoeff, and returns TotalCoeff. Levels
/// must already be within `maximum_level`.
pub fn writeBlock(writer: *BitWriter, coefficients: []const i32, nc: i32) !u8 {
    @setRuntimeSafety(runtime_safety);
    const maximum_count = coefficients.len;
    // Nonzero levels and the zero runs before them, highest frequency first.
    var levels: [16]i32 = undefined;
    var runs: [16]u8 = undefined;
    var total: usize = 0;
    var last_index: usize = 0;
    var index = maximum_count;
    while (index > 0) {
        index -= 1;
        if (coefficients[index] == 0) continue;
        if (total == 0) last_index = index;
        levels[total] = coefficients[index];
        std.debug.assert(@abs(levels[total]) <= maximum_level);
        var run: u8 = 0;
        var below = index;
        while (below > 0 and coefficients[below - 1] == 0) : (below -= 1) run += 1;
        runs[total] = run;
        total += 1;
    }
    var trailing_ones: usize = 0;
    while (trailing_ones < total and trailing_ones < 3 and @abs(levels[trailing_ones]) == 1) {
        trailing_ones += 1;
    }

    const token = total * 4 + trailing_ones;
    if (nc == chroma_dc_nc) {
        try writer.bits(chroma_dc_coeff_token_code[token], @intCast(chroma_dc_coeff_token_length[token]));
    } else {
        const table: usize = if (nc < 2) 0 else if (nc < 4) 1 else if (nc < 8) 2 else 3;
        try writer.bits(coeff_token_code[table][token], @intCast(coeff_token_length[table][token]));
    }
    if (total == 0) return 0;

    var suffix_length: u5 = if (total > 10 and trailing_ones < 3) 1 else 0;
    for (levels[0..total], 0..) |level, level_index| {
        if (level_index < trailing_ones) {
            try writer.flag(level < 0);
            continue;
        }
        var code: u32 = if (level > 0) @intCast(2 * level - 2) else @intCast(-2 * level - 1);
        if (level_index == trailing_ones and trailing_ones < 3) code -= 2;
        try writeLevel(writer, code, suffix_length);
        if (suffix_length == 0) suffix_length = 1;
        if (@abs(level) > (@as(u32, 3) << (suffix_length - 1)) and suffix_length < 6) {
            suffix_length += 1;
        }
    }

    const total_zeros = last_index + 1 - total;
    if (total < maximum_count) {
        if (nc == chroma_dc_nc) {
            try writer.bits(
                chroma_dc_total_zeros_code[total - 1][total_zeros],
                @intCast(chroma_dc_total_zeros_length[total - 1][total_zeros]),
            );
        } else {
            try writer.bits(
                total_zeros_code[total - 1][total_zeros],
                @intCast(total_zeros_length[total - 1][total_zeros]),
            );
        }
    }

    var zeros_left = total_zeros;
    for (runs[0 .. total - 1]) |run| {
        if (zeros_left == 0) break;
        const table = @min(zeros_left, 7) - 1;
        try writer.bits(run_before_code[table][run], @intCast(run_before_length[table][run]));
        zeros_left -= run;
    }
    return @intCast(total);
}

/// Writes level_prefix and level_suffix so the decoding process in 9.2.2.1
/// recovers `code` (levelCode before its trailing-ones adjustment).
fn writeLevel(writer: *BitWriter, code: u32, suffix_length: u5) !void {
    if (suffix_length == 0) {
        if (code < 14) {
            try writePrefix(writer, @intCast(code));
        } else if (code < 30) {
            try writePrefix(writer, 14);
            try writer.bits(code - 14, 4);
        } else {
            std.debug.assert(code - 30 < 4096);
            try writePrefix(writer, 15);
            try writer.bits(code - 30, 12);
        }
        return;
    }
    if (code < @as(u32, 15) << suffix_length) {
        try writePrefix(writer, @intCast(code >> suffix_length));
        try writer.bits(code & ((@as(u32, 1) << suffix_length) - 1), @intCast(suffix_length));
    } else {
        const suffix = code - (@as(u32, 15) << suffix_length);
        std.debug.assert(suffix < 4096);
        try writePrefix(writer, 15);
        try writer.bits(suffix, 12);
    }
}

fn writePrefix(writer: *BitWriter, prefix: u6) !void {
    try writer.bits(1, prefix + 1);
}

fn expectBits(expected: []const u8, coefficients: []const i32, nc: i32) !void {
    var writer = BitWriter.init(std.testing.allocator);
    defer writer.deinit();
    _ = try writeBlock(&writer, coefficients, nc);
    var text: [256]u8 = undefined;
    var length: usize = 0;
    for (writer.bytes.items) |byte| {
        for (0..8) |bit| {
            text[length] = if (byte >> @intCast(7 - bit) & 1 == 1) '1' else '0';
            length += 1;
        }
    }
    for (0..writer.pending_count) |bit| {
        text[length] = if (writer.pending >> @intCast(writer.pending_count - 1 - bit) & 1 == 1) '1' else '0';
        length += 1;
    }
    try std.testing.expectEqualStrings(expected, text[0..length]);
}

test "an empty block is the TotalCoeff 0 coeff_token" {
    try expectBits("1", &@as([16]i32, @splat(0)), 0);
    try expectBits("000011", &@as([16]i32, @splat(0)), 8);
    try expectBits("01", &@as([4]i32, @splat(0)), chroma_dc_nc);
}

test "a block with trailing ones, levels, and zero runs follows Tables 9-5 to 9-10" {
    // Scan order: 0, 3, -1, 0, 0, -1, 1, 0, 1, then zeros.
    var coefficients: [16]i32 = @splat(0);
    coefficients[1] = 3;
    coefficients[2] = -1;
    coefficients[5] = -1;
    coefficients[6] = 1;
    coefficients[8] = 1;
    // TotalCoeff 5 and TrailingOnes 3 with nC 0: coeff_token 0000100.
    // Trailing-one signs, highest frequency first (+1, +1, -1): 001.
    // Level -1 (levelCode 1, suffixLength 0): prefix 01.
    // Level 3 (levelCode 4, suffixLength 1): prefix 001, suffix 0.
    // total_zeros 4 for TotalCoeff 5: 110.
    // run_before 1 (zerosLeft 4): 10; 0 (zerosLeft 3): 11; 2 (zerosLeft 3): 01;
    // 0 (zerosLeft 1): 1. The lowest coefficient's run is implied.
    try expectBits("0000100" ++ "001" ++ "01" ++ "0010" ++ "110" ++ "10" ++ "11" ++ "01" ++ "1", &coefficients, 0);
}

test "large levels escape with a 12-bit suffix" {
    var coefficients: [16]i32 = @splat(0);
    coefficients[0] = 100;
    // TotalCoeff 1, TrailingOnes 0, nC 0: 000101. levelCode 198 - 2 = 196 at
    // suffixLength 0 escapes: prefix 15 (000000000000000 1), suffix 196 - 30.
    // total_zeros 0 for TotalCoeff 1: 1.
    try expectBits("000101" ++ "0000000000000001" ++ "000010100110" ++ "1", &coefficients, 0);
}
