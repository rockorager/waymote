//! Converts captured BGRX/BGRA frames to the I420 planes x264 encodes.
//!
//! Colors use BT.601 limited range, the same matrix FFmpeg's swscale applies
//! for `-pix_fmt yuv420p`, so streams decode with the colors they had before.

const std = @import("std");

/// Safety checks follow this module's optimize mode, which build.zig sets to
/// ReleaseFast in release builds of streamd: the checks cost about 40% of
/// encoding time there, while tests and h264-check keep them on.
const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

pub const Planes = struct {
    y: []u8,
    u: []u8,
    v: []u8,
    y_stride: usize,
    chroma_stride: usize,
};

pub const Source = struct {
    data: []const u8,
    width: usize,
    height: usize,
    stride: usize,
};

/// Rows `[first_row, end_row)` of the destination are written; both bounds
/// must be even so each chroma row is complete.
pub fn convert(
    source: Source,
    width: usize,
    height: usize,
    planes: Planes,
    first_row: usize,
    end_row: usize,
) void {
    @setRuntimeSafety(runtime_safety);
    std.debug.assert(width % 2 == 0 and height % 2 == 0);
    std.debug.assert(first_row % 2 == 0 and end_row % 2 == 0 and end_row <= height);
    if (source.width == width and source.height == height) {
        convertSameSize(source, width, planes, first_row, end_row);
    } else {
        convertScaled(source, width, height, planes, first_row, end_row);
    }
}

inline fn luma(r: u32, g: u32, b: u32) u8 {
    return @intCast(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
}

inline fn chromaU(r: i32, g: i32, b: i32) u8 {
    return @intCast(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
}

inline fn chromaV(r: i32, g: i32, b: i32) u8 {
    return @intCast(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
}

const lanes = 16;
const PixelBlock = @Vector(4 * lanes, u8);
const Channel = @Vector(lanes, u16);
const HalfChannel = @Vector(lanes / 2, i16);

fn laneMask(comptime stride: usize, comptime offset: usize, comptime count: usize) [count]i32 {
    var mask: [count]i32 = undefined;
    for (&mask, 0..) |*value, index| value.* = @intCast(index * stride + offset);
    return mask;
}

/// Splits 16 BGRA pixels into widened blue, green, and red channels.
inline fn splitChannels(pixels: [*]const u8) [3]Channel {
    const block: PixelBlock = pixels[0 .. 4 * lanes].*;
    return .{
        @shuffle(u8, block, undefined, laneMask(4, 0, lanes)),
        @shuffle(u8, block, undefined, laneMask(4, 1, lanes)),
        @shuffle(u8, block, undefined, laneMask(4, 2, lanes)),
    };
}

inline fn lumaVector(rgb: [3]Channel) @Vector(lanes, u8) {
    const b, const g, const r = rgb;
    const y = (r * @as(Channel, @splat(66)) + g * @as(Channel, @splat(129)) +
        b * @as(Channel, @splat(25)) + @as(Channel, @splat(128))) >> @splat(8);
    return @truncate(y + @as(Channel, @splat(16)));
}

/// Averages each 2x2 block of one channel from two rows of 16 pixels.
inline fn blockAverage(top: Channel, bottom: Channel) HalfChannel {
    const sum = top + bottom;
    const even = @shuffle(u16, sum, undefined, laneMask(2, 0, lanes / 2));
    const odd = @shuffle(u16, sum, undefined, laneMask(2, 1, lanes / 2));
    return @intCast((even + odd + @as(@Vector(lanes / 2, u16), @splat(2))) >> @splat(2));
}

inline fn chromaVector(
    r: HalfChannel,
    g: HalfChannel,
    b: HalfChannel,
    comptime coefficients: [3]i16,
) @Vector(lanes / 2, u8) {
    const value = (r * @as(HalfChannel, @splat(coefficients[0])) +
        g * @as(HalfChannel, @splat(coefficients[1])) +
        b * @as(HalfChannel, @splat(coefficients[2])) +
        @as(HalfChannel, @splat(128))) >> @splat(8);
    return @intCast(value + @as(HalfChannel, @splat(128)));
}

fn convertSameSize(
    source: Source,
    width: usize,
    planes: Planes,
    first_row: usize,
    end_row: usize,
) void {
    @setRuntimeSafety(runtime_safety);
    // Bounds were checked by the caller; safety checks here block vectorization.
    @setRuntimeSafety(false);
    const vector_width = width / lanes * lanes;
    var row = first_row;
    while (row < end_row) : (row += 2) {
        const top = source.data.ptr + row * source.stride;
        const bottom = top + source.stride;
        const y_top = planes.y.ptr + row * planes.y_stride;
        const y_bottom = y_top + planes.y_stride;
        const u_row = planes.u.ptr + row / 2 * planes.chroma_stride;
        const v_row = planes.v.ptr + row / 2 * planes.chroma_stride;
        var x: usize = 0;
        while (x < vector_width) : (x += lanes) {
            const upper = splitChannels(top + 4 * x);
            const lower = splitChannels(bottom + 4 * x);
            y_top[x..][0..lanes].* = lumaVector(upper);
            y_bottom[x..][0..lanes].* = lumaVector(lower);
            const b = blockAverage(upper[0], lower[0]);
            const g = blockAverage(upper[1], lower[1]);
            const r = blockAverage(upper[2], lower[2]);
            u_row[x / 2 ..][0 .. lanes / 2].* = chromaVector(r, g, b, .{ -38, -74, 112 });
            v_row[x / 2 ..][0 .. lanes / 2].* = chromaVector(r, g, b, .{ 112, -94, -18 });
        }
        convertScalar(top, bottom, y_top, y_bottom, u_row, v_row, vector_width, width);
    }
}

fn convertScalar(
    top: [*]const u8,
    bottom: [*]const u8,
    y_top: [*]u8,
    y_bottom: [*]u8,
    u_row: [*]u8,
    v_row: [*]u8,
    first_column: usize,
    width: usize,
) void {
    @setRuntimeSafety(runtime_safety);
    @setRuntimeSafety(false);
    for (first_column..width) |x| {
        y_top[x] = luma(top[4 * x + 2], top[4 * x + 1], top[4 * x]);
        y_bottom[x] = luma(bottom[4 * x + 2], bottom[4 * x + 1], bottom[4 * x]);
    }
    for (first_column / 2..width / 2) |x| {
        const b: i32 = (@as(i32, top[8 * x]) + top[8 * x + 4] +
            bottom[8 * x] + bottom[8 * x + 4] + 2) >> 2;
        const g: i32 = (@as(i32, top[8 * x + 1]) + top[8 * x + 5] +
            bottom[8 * x + 1] + bottom[8 * x + 5] + 2) >> 2;
        const r: i32 = (@as(i32, top[8 * x + 2]) + top[8 * x + 6] +
            bottom[8 * x + 2] + bottom[8 * x + 6] + 2) >> 2;
        u_row[x] = chromaU(r, g, b);
        v_row[x] = chromaV(r, g, b);
    }
}

const Rgb = struct { r: u32, g: u32, b: u32 };

/// Bilinear sample at a 16.16 fixed-point source position.
fn sample(source: Source, fx: u64, fy: u64) Rgb {
    @setRuntimeSafety(runtime_safety);
    const x0: usize = @intCast(fx >> 16);
    const y0: usize = @intCast(fy >> 16);
    const x1 = @min(x0 + 1, source.width - 1);
    const y1 = @min(y0 + 1, source.height - 1);
    const wx: u32 = @intCast(fx & 0xffff);
    const wy: u32 = @intCast(fy & 0xffff);
    const p00 = source.data[y0 * source.stride + 4 * x0 ..][0..4];
    const p10 = source.data[y0 * source.stride + 4 * x1 ..][0..4];
    const p01 = source.data[y1 * source.stride + 4 * x0 ..][0..4];
    const p11 = source.data[y1 * source.stride + 4 * x1 ..][0..4];
    var channels: [3]u32 = undefined;
    for (0..3) |channel| {
        const top = @as(u64, p00[channel]) * (0x10000 - wx) + @as(u64, p10[channel]) * wx;
        const bottom = @as(u64, p01[channel]) * (0x10000 - wx) + @as(u64, p11[channel]) * wx;
        channels[channel] = @intCast((top * (0x10000 - wy) + bottom * wy + (1 << 31)) >> 32);
    }
    return .{ .b = channels[0], .g = channels[1], .r = channels[2] };
}

fn sourcePosition(output: usize, output_size: usize, source_size: usize) u64 {
    @setRuntimeSafety(runtime_safety);
    // Pixel centers map to pixel centers: (o + 0.5) * s / d - 0.5, clamped at 0.
    const numerator = (2 * @as(u64, output) + 1) * source_size << 16;
    const center = numerator / (2 * @as(u64, output_size));
    const position = center -| (1 << 15);
    return @min(position, (@as(u64, source_size) - 1) << 16);
}

fn convertScaled(
    source: Source,
    width: usize,
    height: usize,
    planes: Planes,
    first_row: usize,
    end_row: usize,
) void {
    @setRuntimeSafety(runtime_safety);
    var row = first_row;
    while (row < end_row) : (row += 2) {
        const fy0 = sourcePosition(row, height, source.height);
        const fy1 = sourcePosition(row + 1, height, source.height);
        var x: usize = 0;
        while (x < width) : (x += 2) {
            const fx0 = sourcePosition(x, width, source.width);
            const fx1 = sourcePosition(x + 1, width, source.width);
            const pixels = [4]Rgb{
                sample(source, fx0, fy0), sample(source, fx1, fy0),
                sample(source, fx0, fy1), sample(source, fx1, fy1),
            };
            planes.y[row * planes.y_stride + x] = luma(pixels[0].r, pixels[0].g, pixels[0].b);
            planes.y[row * planes.y_stride + x + 1] = luma(pixels[1].r, pixels[1].g, pixels[1].b);
            planes.y[(row + 1) * planes.y_stride + x] = luma(pixels[2].r, pixels[2].g, pixels[2].b);
            planes.y[(row + 1) * planes.y_stride + x + 1] =
                luma(pixels[3].r, pixels[3].g, pixels[3].b);
            var r: i32 = 2;
            var g: i32 = 2;
            var b: i32 = 2;
            for (pixels) |pixel| {
                r += @intCast(pixel.r);
                g += @intCast(pixel.g);
                b += @intCast(pixel.b);
            }
            const chroma_index = row / 2 * planes.chroma_stride + x / 2;
            planes.u[chroma_index] = chromaU(r >> 2, g >> 2, b >> 2);
            planes.v[chroma_index] = chromaV(r >> 2, g >> 2, b >> 2);
        }
    }
}

fn testPlanes(comptime width: usize, comptime height: usize) struct {
    y: [width * height]u8,
    u: [width * height / 4]u8,
    v: [width * height / 4]u8,
} {
    return .{ .y = @splat(0), .u = @splat(0), .v = @splat(0) };
}

fn expectNear(expected: f64, actual: u8) !void {
    if (@abs(expected - @as(f64, @floatFromInt(actual))) > 1.0) {
        std.debug.print("expected {d:.2}, got {d}\n", .{ expected, actual });
        return error.TestExpectedApproxEq;
    }
}

test "solid colors convert to BT.601 limited-range values" {
    const cases = [_][4]u8{
        .{ 0, 0, 0, 255 },
        .{ 255, 255, 255, 255 },
        .{ 0, 0, 255, 255 },
        .{ 0, 255, 0, 255 },
        .{ 255, 0, 0, 255 },
        .{ 40, 120, 200, 255 },
    };
    for (cases) |bgra| {
        // Real-valued BT.601 limited-range definition, independent of the
        // integer approximation under test.
        const b = @as(f64, @floatFromInt(bgra[0])) / 255;
        const g = @as(f64, @floatFromInt(bgra[1])) / 255;
        const r = @as(f64, @floatFromInt(bgra[2])) / 255;
        const y = 16 + 65.481 * r + 128.553 * g + 24.966 * b;
        const u = 128 - 37.797 * r - 74.203 * g + 112.0 * b;
        const v = 128 + 112.0 * r - 93.786 * g - 18.214 * b;
        // 34 columns cover both the 16-pixel vector path and the scalar tail.
        var pixels: [34 * 2 * 4]u8 = undefined;
        for (0..34 * 2) |index| pixels[4 * index ..][0..4].* = bgra;
        var out = testPlanes(34, 2);
        convert(
            .{ .data = &pixels, .width = 34, .height = 2, .stride = 34 * 4 },
            34,
            2,
            .{ .y = &out.y, .u = &out.u, .v = &out.v, .y_stride = 34, .chroma_stride = 17 },
            0,
            2,
        );
        for (out.y) |value| try expectNear(y, value);
        for (out.u) |value| try expectNear(u, value);
        for (out.v) |value| try expectNear(v, value);
    }
}

test "chroma averages each 2x2 block and luma keeps every pixel" {
    // Left 2x2 block is black and white; right block is all white.
    const black = [4]u8{ 0, 0, 0, 255 };
    const white = [4]u8{ 255, 255, 255, 255 };
    const rows = [2][4][4]u8{ .{ black, white, white, white }, .{ white, black, white, white } };
    var pixels: [2 * 4 * 4]u8 = undefined;
    for (rows, 0..) |row, y| for (row, 0..) |pixel, x| {
        pixels[(y * 4 + x) * 4 ..][0..4].* = pixel;
    };
    var out = testPlanes(4, 2);
    convert(
        .{ .data = &pixels, .width = 4, .height = 2, .stride = 16 },
        4,
        2,
        .{ .y = &out.y, .u = &out.u, .v = &out.v, .y_stride = 4, .chroma_stride = 2 },
        0,
        2,
    );
    try std.testing.expectEqualSlices(u8, &.{ 16, 235, 235, 235, 235, 16, 235, 235 }, &out.y);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128 }, &out.u);
    try std.testing.expectEqualSlices(u8, &.{ 128, 128 }, &out.v);
}

test "row range leaves rows outside it untouched" {
    var pixels: [4 * 2 * 4]u8 = @splat(255);
    var out = testPlanes(2, 4);
    convert(
        .{ .data = &pixels, .width = 2, .height = 4, .stride = 8 },
        2,
        4,
        .{ .y = &out.y, .u = &out.u, .v = &out.v, .y_stride = 2, .chroma_stride = 1 },
        2,
        4,
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 235, 235, 235, 235 }, &out.y);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128 }, &out.u);
}

test "downscaling halves a vertical stripe pattern to its average" {
    // 4x2 source of alternating black and white columns scales to 2x2 gray.
    var pixels: [4 * 2 * 4]u8 = undefined;
    for (0..2) |y| for (0..4) |x| {
        const value: u8 = if (x % 2 == 0) 0 else 255;
        pixels[(y * 4 + x) * 4 ..][0..4].* = .{ value, value, value, 255 };
    };
    var out = testPlanes(2, 2);
    convert(
        .{ .data = &pixels, .width = 4, .height = 2, .stride = 16 },
        2,
        2,
        .{ .y = &out.y, .u = &out.u, .v = &out.v, .y_stride = 2, .chroma_stride = 1 },
        0,
        2,
    );
    // Gray 128 in limited range: (219 * 128 + 128) / 256 + 16 = 125 or 126.
    for (out.y) |value| try std.testing.expect(value >= 124 and value <= 127);
    try std.testing.expectEqual(@as(u8, 128), out.u[0]);
}

test "vector path matches the scalar path on varied pixels" {
    const width = 38;
    const height = 4;
    var pixels: [width * height * 4]u8 = undefined;
    var state: u32 = 12345;
    for (&pixels) |*byte| {
        state = state *% 1103515245 +% 12345;
        byte.* = @truncate(state >> 16);
    }
    var vector = testPlanes(width, height);
    convert(
        .{ .data = &pixels, .width = width, .height = height, .stride = width * 4 },
        width,
        height,
        .{ .y = &vector.y, .u = &vector.u, .v = &vector.v, .y_stride = width, .chroma_stride = width / 2 },
        0,
        height,
    );
    var scalar = testPlanes(width, height);
    var row: usize = 0;
    while (row < height) : (row += 2) {
        convertScalar(
            pixels[row * width * 4 ..].ptr,
            pixels[(row + 1) * width * 4 ..].ptr,
            scalar.y[row * width ..].ptr,
            scalar.y[(row + 1) * width ..].ptr,
            scalar.u[row / 2 * width / 2 ..].ptr,
            scalar.v[row / 2 * width / 2 ..].ptr,
            0,
            width,
        );
    }
    try std.testing.expectEqualSlices(u8, &scalar.y, &vector.y);
    try std.testing.expectEqualSlices(u8, &scalar.u, &vector.u);
    try std.testing.expectEqualSlices(u8, &scalar.v, &vector.v);
}
