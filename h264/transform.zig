//! Integer transforms, quantization, and the normative scaling and inverse
//! transforms (clause 8.5) the encoder repeats to reconstruct exactly what a
//! decoder will display. Blocks are row-major: `block[row * 4 + column]`.

const std = @import("std");

/// Safety checks follow this module's optimize mode, which build.zig sets to
/// ReleaseFast in release builds of streamd: the checks cost about 40% of
/// encoding time there, while tests and h264-check keep them on.
const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

pub const Block = [16]i32;

/// Frame zig-zag scan (Table 8-13): scan position -> row-major index.
pub const zigzag = [16]u8{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };

/// normAdjust4x4 (8.5.9) for positions with both coordinates even, both odd,
/// and mixed.
const norm_adjust = [6][3]i32{
    .{ 10, 16, 13 },
    .{ 11, 18, 14 },
    .{ 13, 20, 16 },
    .{ 14, 23, 18 },
    .{ 16, 25, 20 },
    .{ 18, 29, 23 },
};

/// Forward quantization multipliers matching `norm_adjust` (encoder choice).
const quant_multiplier = [6][3]i32{
    .{ 13107, 5243, 8066 },
    .{ 11916, 4660, 7490 },
    .{ 10082, 4194, 6554 },
    .{ 9362, 3647, 5825 },
    .{ 8192, 3355, 5243 },
    .{ 7282, 2893, 4559 },
};

fn positionClass(index: usize) usize {
    @setRuntimeSafety(runtime_safety);
    const row = index / 4;
    const column = index % 4;
    if (row % 2 == 0 and column % 2 == 0) return 0;
    if (row % 2 == 1 and column % 2 == 1) return 1;
    return 2;
}

/// LevelScale4x4 with the flat (all 16) scaling matrix.
fn levelScale(qp: u8, index: usize) i32 {
    @setRuntimeSafety(runtime_safety);
    return 16 * norm_adjust[qp % 6][positionClass(index)];
}

/// Table 8-15: QPc for qPI = QPy + chroma_qp_index_offset.
pub fn chromaQp(qp: u8) u8 {
    const table = [_]u8{ 29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39 };
    return if (qp < 30) qp else table[qp - 30];
}

/// Core forward transform W = Cf X Cf^T.
pub fn forward(block: *Block) void {
    @setRuntimeSafety(runtime_safety);
    for (0..4) |row| butterflyForward(block, row * 4, 1);
    for (0..4) |column| butterflyForward(block, column, 4);
}

fn butterflyForward(block: *Block, start: usize, step: usize) void {
    @setRuntimeSafety(runtime_safety);
    const x0 = block[start];
    const x1 = block[start + step];
    const x2 = block[start + 2 * step];
    const x3 = block[start + 3 * step];
    const s0 = x0 + x3;
    const s1 = x1 + x2;
    const d0 = x0 - x3;
    const d1 = x1 - x2;
    block[start] = s0 + s1;
    block[start + step] = 2 * d0 + d1;
    block[start + 2 * step] = s0 - s1;
    block[start + 3 * step] = d0 - 2 * d1;
}

/// 4x4 Hadamard H X H, used forward by the encoder and inverse by 8.5.10.
pub fn hadamard(block: *Block) void {
    @setRuntimeSafety(runtime_safety);
    for (0..4) |row| butterflyHadamard(block, row * 4, 1);
    for (0..4) |column| butterflyHadamard(block, column, 4);
}

fn butterflyHadamard(block: *Block, start: usize, step: usize) void {
    @setRuntimeSafety(runtime_safety);
    const v0 = block[start];
    const v1 = block[start + step];
    const v2 = block[start + 2 * step];
    const v3 = block[start + 3 * step];
    block[start] = v0 + v1 + v2 + v3;
    block[start + step] = v0 + v1 - v2 - v3;
    block[start + 2 * step] = v0 - v1 - v2 + v3;
    block[start + 3 * step] = v0 - v1 + v2 - v3;
}

fn quantize(value: i32, multiplier: i32, offset: i64, shift: u6, maximum: i32) i32 {
    @setRuntimeSafety(runtime_safety);
    const magnitude: i64 = (@as(i64, @abs(value)) * multiplier + offset) >> shift;
    const level: i32 = @intCast(@min(magnitude, maximum));
    return if (value < 0) -level else level;
}

/// The rounding offset as a fraction of one quantization step: intra blocks
/// round more generously than inter blocks, whose prediction is usually good.
fn roundingOffset(shift: u6, intra: bool) i64 {
    return @divTrunc(@as(i64, 1) << shift, @as(i64, if (intra) 3 else 6));
}

/// Quantizes the AC coefficients of a block in place (index 0 is left for
/// the DC path). Returns whether any AC level is nonzero.
pub fn quantizeAc(block: *Block, qp: u8, maximum: i32, intra: bool) bool {
    return quantizeFrom(1, block, qp, maximum, intra);
}

/// Quantizes all 16 coefficients of a block without a separate DC path, as
/// inter luma blocks are coded. Returns whether any level is nonzero.
pub fn quantizeBlock(block: *Block, qp: u8, maximum: i32, intra: bool) bool {
    return quantizeFrom(0, block, qp, maximum, intra);
}

fn quantizeFrom(first: usize, block: *Block, qp: u8, maximum: i32, intra: bool) bool {
    @setRuntimeSafety(runtime_safety);
    const shift: u6 = @intCast(15 + qp / 6);
    const offset = roundingOffset(shift, intra);
    var nonzero = false;
    for (first..16) |index| {
        block[index] = quantize(block[index], quant_multiplier[qp % 6][positionClass(index)], offset, shift, maximum);
        nonzero = nonzero or block[index] != 0;
    }
    return nonzero;
}

/// Quantizes luma DC coefficients after the forward Hadamard, which this
/// halves as the reference encoder does.
pub fn quantizeLumaDc(block: *Block, qp: u8, maximum: i32) void {
    @setRuntimeSafety(runtime_safety);
    const shift: u6 = @intCast(16 + qp / 6);
    const offset: i64 = @divTrunc(@as(i64, 1) << shift, 3);
    for (block) |*value| {
        value.* = quantize(value.* >> 1, quant_multiplier[qp % 6][0], offset, shift, maximum);
    }
}

/// Quantizes the four 4:2:0 chroma DC coefficients after their 2x2 Hadamard.
pub fn quantizeChromaDc(values: *[4]i32, qp: u8, maximum: i32, intra: bool) void {
    @setRuntimeSafety(runtime_safety);
    const shift: u6 = @intCast(16 + qp / 6);
    const offset = roundingOffset(shift, intra);
    for (values) |*value| value.* = quantize(value.*, quant_multiplier[qp % 6][0], offset, shift, maximum);
}

pub fn hadamard2x2(values: *[4]i32) void {
    @setRuntimeSafety(runtime_safety);
    const a = values[0] + values[1];
    const b = values[0] - values[1];
    const c = values[2] + values[3];
    const d = values[2] - values[3];
    values.* = .{ a + c, b + d, a - c, b - d };
}

/// 8.5.12.1 for AC positions of an Intra16x16 or chroma block (d00 comes from
/// the DC path).
pub fn scaleAc(block: *Block, qp: u8) void {
    @setRuntimeSafety(runtime_safety);
    for (1..16) |index| block[index] = scaleCoefficient(block[index], qp, index);
}

/// 8.5.12.1 for every position of a block without a separate DC path.
pub fn scaleBlock(block: *Block, qp: u8) void {
    @setRuntimeSafety(runtime_safety);
    for (0..16) |index| block[index] = scaleCoefficient(block[index], qp, index);
}

fn scaleCoefficient(level: i32, qp: u8, index: usize) i32 {
    @setRuntimeSafety(runtime_safety);
    const scaled = level * levelScale(qp, index);
    if (qp >= 24) return scaled << @intCast(qp / 6 - 4);
    const shift: u5 = @intCast(4 - qp / 6);
    return (scaled + (@as(i32, 1) << (shift - 1))) >> shift;
}

/// 8.5.10: inverse Hadamard and scaling of Intra16x16 luma DC levels.
pub fn scaleLumaDc(block: *Block, qp: u8) void {
    @setRuntimeSafety(runtime_safety);
    hadamard(block);
    const scale = levelScale(qp, 0);
    for (block) |*value| {
        if (qp >= 36) {
            value.* = (value.* * scale) << @intCast(qp / 6 - 6);
        } else {
            const shift: u5 = @intCast(6 - qp / 6);
            value.* = (value.* * scale + (@as(i32, 1) << (shift - 1))) >> shift;
        }
    }
}

/// 8.5.11.2 for 4:2:0: inverse 2x2 transform and scaling of chroma DC levels.
pub fn scaleChromaDc(values: *[4]i32, qp: u8) void {
    @setRuntimeSafety(runtime_safety);
    hadamard2x2(values);
    const scale = levelScale(qp, 0);
    for (values) |*value| value.* = ((value.* * scale) << @intCast(qp / 6)) >> 5;
}

/// 8.5.12.2: inverse transform of scaled coefficients into residuals.
pub fn inverse(block: *Block) void {
    @setRuntimeSafety(runtime_safety);
    for (0..4) |row| butterflyInverse(block, row * 4, 1);
    for (0..4) |column| butterflyInverse(block, column, 4);
    for (block) |*value| value.* = (value.* + 32) >> 6;
}

fn butterflyInverse(block: *Block, start: usize, step: usize) void {
    @setRuntimeSafety(runtime_safety);
    const d0 = block[start];
    const d1 = block[start + step];
    const d2 = block[start + 2 * step];
    const d3 = block[start + 3 * step];
    const e0 = d0 + d2;
    const e1 = d0 - d2;
    const e2 = (d1 >> 1) - d3;
    const e3 = d1 + (d3 >> 1);
    block[start] = e0 + e3;
    block[start + step] = e1 + e2;
    block[start + 2 * step] = e1 - e2;
    block[start + 3 * step] = e0 - e3;
}

test "a residual survives transform, fine quantization, and reconstruction" {
    const residual = Block{ 5, -3, 12, 0, 7, 7, -2, 1, -9, 4, 3, 3, 0, 1, -6, 8 };
    var block = residual;
    forward(&block);
    _ = quantizeBlock(&block, 4, 2047, true);
    scaleBlock(&block, 4);
    inverse(&block);
    for (residual, block) |expected, actual| try std.testing.expect(@abs(expected - actual) <= 1);
}

test "inverse transform of a lone DC spreads it evenly" {
    // 8.5.12.2 with only d00 = 64 * 6 gives (384 + 32) >> 6 = 6 everywhere.
    var block: Block = @splat(0);
    block[0] = 384;
    inverse(&block);
    for (block) |value| try std.testing.expectEqual(@as(i32, 6), value);
}

test "chroma QP follows Table 8-15" {
    try std.testing.expectEqual(@as(u8, 29), chromaQp(29));
    try std.testing.expectEqual(@as(u8, 29), chromaQp(30));
    try std.testing.expectEqual(@as(u8, 34), chromaQp(37));
    try std.testing.expectEqual(@as(u8, 39), chromaQp(51));
}
