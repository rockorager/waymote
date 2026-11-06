//! Bit-exact conformance check for the H.264 encoder.
//!
//! Encodes deterministic synthetic sequences, decodes them with FFmpeg's
//! reference-quality H.264 decoder, and requires the decoded pictures to equal
//! the encoder's own reconstruction byte for byte. Any bitstream or
//! reconstruction mistake shows up as a decode error or the first mismatch.
//!
//! usage: h264-check OUTPUT_DIRECTORY [FFMPEG]

const std = @import("std");
const Encoder = @import("Encoder.zig");

const Case = struct {
    name: []const u8,
    width: u32,
    height: u32,
    qp: u8,
    keyframe_interval: u32,
    frames: u32,
    scene: Scene = .paint,
    /// 0 lets the encoder choose.
    slices: u32 = 0,
    /// 0 codes every picture at `qp`; otherwise `qp` is the finest allowed.
    bitrate_kbps: u32 = 0,
    /// `Encoder.refine` calls after the last picture, as for an idle desktop.
    refine_frames: u32 = 0,
};

const Scene = enum {
    /// Random rectangles painted over textured quadrants.
    paint,
    /// A tall page scrolling under a fixed header by varying offsets.
    scroll,
    /// A textured sprite moving over a still background, partly off the
    /// picture at times.
    move,
};

const cases = [_]Case{
    .{ .name = "cropped-qp28", .width = 100, .height = 58, .qp = 28, .keyframe_interval = 4, .frames = 10 },
    .{ .name = "escape-qp0", .width = 64, .height = 48, .qp = 0, .keyframe_interval = 3, .frames = 6 },
    .{ .name = "fine-qp4", .width = 96, .height = 64, .qp = 4, .keyframe_interval = 5, .frames = 6 },
    .{ .name = "qp18", .width = 320, .height = 180, .qp = 18, .keyframe_interval = 30, .frames = 12 },
    .{ .name = "coarse-qp40", .width = 320, .height = 182, .qp = 40, .keyframe_interval = 30, .frames = 8 },
    .{ .name = "qp51", .width = 96, .height = 64, .qp = 51, .keyframe_interval = 4, .frames = 6 },
    .{ .name = "hd-qp28", .width = 1280, .height = 720, .qp = 28, .keyframe_interval = 30, .frames = 8 },
    .{ .name = "paint-3-slices", .width = 320, .height = 180, .qp = 26, .keyframe_interval = 5, .frames = 10, .slices = 3 },
    .{ .name = "scroll-qp28", .width = 320, .height = 240, .qp = 28, .keyframe_interval = 30, .frames = 12, .scene = .scroll, .slices = 1 },
    .{ .name = "scroll-4-slices", .width = 640, .height = 360, .qp = 24, .keyframe_interval = 7, .frames = 16, .scene = .scroll, .slices = 4 },
    .{ .name = "scroll-cropped-qp36", .width = 202, .height = 134, .qp = 36, .keyframe_interval = 30, .frames = 12, .scene = .scroll },
    .{ .name = "move-qp28", .width = 320, .height = 240, .qp = 28, .keyframe_interval = 30, .frames = 14, .scene = .move, .slices = 1 },
    .{ .name = "move-2-slices-qp12", .width = 176, .height = 144, .qp = 12, .keyframe_interval = 30, .frames = 14, .scene = .move, .slices = 2 },
    .{ .name = "rate-paint-300k", .width = 320, .height = 180, .qp = 16, .keyframe_interval = 6, .frames = 14, .bitrate_kbps = 300 },
    .{ .name = "rate-scroll-800k", .width = 640, .height = 360, .qp = 18, .keyframe_interval = 30, .frames = 16, .scene = .scroll, .slices = 4, .bitrate_kbps = 800 },
    .{ .name = "refine-scroll-400k", .width = 480, .height = 272, .qp = 22, .keyframe_interval = 30, .frames = 10, .scene = .scroll, .slices = 3, .bitrate_kbps = 400, .refine_frames = 30 },
    .{ .name = "refine-paint-200k", .width = 320, .height = 180, .qp = 20, .keyframe_interval = 30, .frames = 6, .slices = 1, .bitrate_kbps = 200, .refine_frames = 40 },
};

const Frame = struct {
    y: []u8,
    u: []u8,
    v: []u8,
    width: usize,
    height: usize,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Frame {
        return .{
            .y = try allocator.alloc(u8, width * height),
            .u = try allocator.alloc(u8, width * height / 4),
            .v = try allocator.alloc(u8, width * height / 4),
            .width = width,
            .height = height,
        };
    }

    fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.y);
        allocator.free(self.u);
        allocator.free(self.v);
    }

    fn picture(self: Frame) Encoder.Picture {
        return .{ .y = self.y, .u = self.u, .v = self.v, .y_stride = self.width, .chroma_stride = self.width / 2 };
    }

    /// Fills a rectangle (luma coordinates, even-aligned for chroma) with one
    /// of several textures that exercise different prediction modes and
    /// coefficient statistics.
    fn paint(self: Frame, random: std.Random, x0: usize, y0: usize, width: usize, height: usize, texture: u3) void {
        const base_y = random.int(u8);
        const base_u = random.int(u8);
        const base_v = random.int(u8);
        for (y0..y0 + height) |y| for (x0..x0 + width) |x| {
            self.y[y * self.width + x] = switch (texture) {
                0 => base_y, // flat: DC prediction
                1 => @truncate(x * 3 + y * 2 + base_y), // gradient: plane prediction
                2 => random.int(u8), // noise: many large levels
                3 => if ((x / 2) % 2 == 0) 230 else 20, // vertical stripes: text-like edges
                4 => if ((y / 3) % 2 == 0) base_y else 255 - base_y, // horizontal bands
                else => @truncate((x ^ y) *% 7 +% base_y), // high-frequency pattern
            };
        };
        for (y0 / 2..(y0 + height) / 2) |y| for (x0 / 2..(x0 + width) / 2) |x| {
            const index = y * (self.width / 2) + x;
            switch (texture) {
                2 => {
                    self.u[index] = random.int(u8);
                    self.v[index] = random.int(u8);
                },
                1 => {
                    self.u[index] = @truncate(x * 4 + base_u);
                    self.v[index] = @truncate(y * 4 + base_v);
                },
                else => {
                    self.u[index] = base_u;
                    self.v[index] = base_v;
                },
            }
        };
    }
};

const Failure = error{ DecodeFailed, Mismatch };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var arguments = try init.minimal.args.iterateAllocator(allocator);
    defer arguments.deinit();
    _ = arguments.next();
    const directory_path = arguments.next() orelse "/tmp/waymote-h264-check";
    const ffmpeg = arguments.next() orelse "ffmpeg";

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, directory_path);

    var failed = false;
    for (cases) |case| {
        const result = runCase(allocator, io, cwd, directory_path, ffmpeg, case, out) catch |err| switch (err) {
            error.DecodeFailed, error.Mismatch => {
                failed = true;
                try out.flush();
                continue;
            },
            else => return err,
        };
        _ = result;
        try out.flush();
    }
    try out.flush();
    if (failed) std.process.exit(1);
}

fn runCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    directory_path: []const u8,
    ffmpeg: []const u8,
    case: Case,
    out: *std.Io.Writer,
) !void {
    var encoder = try Encoder.init(allocator, .{
        .width = case.width,
        .height = case.height,
        .qp = case.qp,
        .keyframe_interval = case.keyframe_interval,
        .slices = case.slices,
        .bitrate_kbps = case.bitrate_kbps,
        .fps = 30,
    });
    defer encoder.deinit();
    const frame = try Frame.init(allocator, case.width, case.height);
    defer frame.deinit(allocator);
    var prng = std.Random.DefaultPrng.init(case.width * 7919 + case.height * 104729 + case.qp);
    const random = prng.random();

    // Start from four textured quadrants.
    paintQuadrants(frame, random);
    // The scroll scene's page and the move scene's background and sprite.
    const page = try Frame.init(allocator, case.width, case.height * 3);
    defer page.deinit(allocator);
    const background = try Frame.init(allocator, case.width, case.height);
    defer background.deinit(allocator);
    const sprite = try Frame.init(allocator, 48, 40);
    defer sprite.deinit(allocator);
    switch (case.scene) {
        .paint => {},
        .scroll => {
            // Text-like stripes and textured boxes down a tall page.
            page.paint(random, 0, 0, page.width, page.height, 0);
            var y: usize = 0;
            while (y + 24 <= page.height) : (y += 24) {
                page.paint(random, 0, y, page.width, 12, 3);
                const box_width = 2 * (8 + random.uintLessThan(usize, page.width / 4));
                page.paint(random, 2 * random.uintLessThan(usize, (page.width - box_width) / 2 + 1), y + 12, box_width, 12, random.int(u3));
            }
        },
        .move => {
            @memcpy(background.y, frame.y);
            @memcpy(background.u, frame.u);
            @memcpy(background.v, frame.v);
            sprite.paint(random, 0, 0, 48, 20, 1);
            sprite.paint(random, 0, 20, 24, 20, 3);
            sprite.paint(random, 24, 20, 24, 20, 5);
        },
    }
    var scroll_offset: usize = 0;
    var sprite_x: isize = 40;
    var sprite_y: isize = 30;

    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    var reconstruction: std.ArrayList(u8) = .empty;
    defer reconstruction.deinit(allocator);
    var keyframe_bytes: usize = 0;
    var p_frame_bytes: usize = 0;
    var squared_error: f64 = 0;
    var stats: Encoder.Stats = .{};
    var qp_minimum: u8 = 51;
    var qp_maximum: u8 = 0;

    for (0..case.frames) |index| {
        var damage: ?Encoder.Rows = null;
        if (case.scene == .scroll) {
            // Odd offsets leave chroma half a sample off the luma motion.
            const steps = [_]usize{ 0, 3, 8, 16, 5, 1, 24, 0, 13, 2, 32, 7 };
            scroll_offset = @min(scroll_offset + steps[index % steps.len], page.height - case.height);
            drawScroll(frame, page, scroll_offset);
            if (index % 3 != 2) damage = .{ .first = scroll_header, .end = @intCast(case.height) };
        } else if (case.scene == .move) {
            const steps = [_][2]isize{ .{ 0, 0 }, .{ 4, 0 }, .{ 0, 6 }, .{ 3, 5 }, .{ -7, 2 }, .{ 16, -16 }, .{ 1, 1 }, .{ 120, 90 }, .{ 30, 20 }, .{ -5, 9 }, .{ -200, -150 }, .{ -9, -3 }, .{ 2, 3 }, .{ 11, -1 } };
            const step = steps[index % steps.len];
            sprite_x += step[0];
            sprite_y += step[1];
            @memcpy(frame.y, background.y);
            @memcpy(frame.u, background.u);
            @memcpy(frame.v, background.v);
            drawSprite(frame, sprite, sprite_x, sprite_y);
        } else if (index > 0) {
            const shape = index % 4;
            if (shape == 3) {
                // Damage reported but nothing changed: an all-skip P frame.
                damage = .{ .first = 0, .end = @intCast(case.height) };
            } else {
                var first: usize = case.height;
                var end: usize = 0;
                for (0..1 + index % 3) |_| {
                    // Even-aligned rectangles, some touching the right and
                    // bottom edges where macroblocks are padded.
                    const width = 2 + 2 * random.uintLessThan(usize, @max(1, case.width / 6));
                    const height = 2 + 2 * random.uintLessThan(usize, @max(1, case.height / 6));
                    const x = if (random.boolean()) case.width - width else 2 * random.uintLessThan(usize, (case.width - width) / 2 + 1);
                    const y = if (random.uintLessThan(u8, 4) == 0) case.height - height else 2 * random.uintLessThan(usize, (case.height - height) / 2 + 1);
                    frame.paint(random, x, y, width, height, random.int(u3));
                    first = @min(first, y);
                    end = @max(end, y + height);
                }
                // Every other changed frame relies on full comparison.
                if (shape != 2) damage = .{ .first = @intCast(first), .end = @intCast(end) };
            }
        }
        const access_unit = try encoder.encode(frame.picture(), damage, false);
        try stream.appendSlice(allocator, access_unit);
        qp_minimum = @min(qp_minimum, encoder.qp);
        qp_maximum = @max(qp_maximum, encoder.qp);
        if (std.mem.indexOf(u8, access_unit[0..@min(access_unit.len, 8)], &.{ 0, 0, 0, 1, 0x67 }) != null) {
            keyframe_bytes += access_unit.len;
        } else {
            p_frame_bytes += access_unit.len;
            stats.intra += encoder.stats.intra;
            stats.inter += encoder.stats.inter;
            stats.skip += encoder.stats.skip;
        }
        try appendReconstruction(allocator, &reconstruction, &encoder);
        squared_error += lumaSquaredError(&encoder, frame);
    }
    // Refinement must sharpen the last picture while staying decodable.
    const before_refinement = psnrOf(lumaSquaredError(&encoder, frame), case.width * case.height);
    var refine_coded: usize = 0;
    for (0..case.refine_frames) |_| {
        const access_unit = (try encoder.refine()) orelse continue;
        refine_coded += 1;
        try stream.appendSlice(allocator, access_unit);
        p_frame_bytes += access_unit.len;
        stats.refined += encoder.stats.refined;
        try appendReconstruction(allocator, &reconstruction, &encoder);
        squared_error += lumaSquaredError(&encoder, frame);
    }
    const after_refinement = psnrOf(lumaSquaredError(&encoder, frame), case.width * case.height);
    const total_frames = case.frames + refine_coded;
    // Bit-exactness alone would also accept a consistently wrong picture, so
    // the reconstruction must resemble the source too.
    const mse = squared_error / @as(f64, @floatFromInt(case.width * case.height * total_frames));
    const psnr = if (mse == 0) 99.0 else 10 * std.math.log10(255.0 * 255.0 / mse);
    const minimum_psnr: f64 = if (case.bitrate_kbps != 0) 15 else if (case.qp <= 28) 30 else if (case.qp <= 40) 22 else 15;

    const stream_path = try std.fmt.allocPrint(allocator, "{s}/{s}.h264", .{ directory_path, case.name });
    defer allocator.free(stream_path);
    const decoded_path = try std.fmt.allocPrint(allocator, "{s}/{s}.yuv", .{ directory_path, case.name });
    defer allocator.free(decoded_path);
    try cwd.writeFile(io, .{ .sub_path = stream_path, .data = stream.items });

    const result = try std.process.run(allocator, io, .{ .argv = &.{
        ffmpeg,        "-hide_banner", "-loglevel",   "error",      "-xerror",
        "-err_detect", "explode",      "-f",          "h264",       "-i",
        stream_path,   "-fps_mode",    "passthrough", "-f",         "rawvideo",
        "-pix_fmt",    "yuv420p",      "-y",          decoded_path,
    } });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const exited_cleanly = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_cleanly or result.stderr.len != 0) {
        try out.print("FAIL {s}: ffmpeg could not decode the stream\n{s}\n", .{ case.name, result.stderr });
        return error.DecodeFailed;
    }
    const decoded = try cwd.readFileAlloc(io, decoded_path, allocator, .unlimited);
    defer allocator.free(decoded);
    try compare(out, case, reconstruction.items, decoded);
    if (psnr < minimum_psnr) {
        try out.print("FAIL {s}: luma PSNR {d:.1} dB is below {d:.0} dB\n", .{ case.name, psnr, minimum_psnr });
        return error.Mismatch;
    }
    // Every case must reach the motion-compensated path to test it.
    if (stats.inter == 0) {
        try out.print("FAIL {s}: no P frame coded an inter macroblock\n", .{case.name});
        return error.Mismatch;
    }
    if (case.refine_frames != 0) {
        if (stats.refined == 0 or after_refinement < before_refinement + 3) {
            try out.print("FAIL {s}: refinement took the last picture from {d:.1} dB only to {d:.1} dB\n", .{
                case.name,
                before_refinement,
                after_refinement,
            });
            return error.Mismatch;
        }
        try out.print("     {s}: {d} refinement frames refined {d} macroblocks, last picture {d:.1} dB -> {d:.1} dB, {s}pending\n", .{
            case.name,
            case.refine_frames,
            stats.refined,
            before_refinement,
            after_refinement,
            if (encoder.refinementPending()) "still " else "none ",
        });
    }
    try out.print(
        "ok   {s}: {d}x{d} QP {d}-{d}, {d} kbps at 30 FPS, {d} slices, {d} frames bit-exact, Y PSNR {d:.1} dB; {d} bytes in keyframes, {d} in P frames " ++
            "(P macroblocks: {d} intra, {d} inter, {d} skip)\n",
        .{
            case.name,
            case.width,
            case.height,
            qp_minimum,
            qp_maximum,
            (keyframe_bytes + p_frame_bytes) * 8 * 30 / (case.frames + case.refine_frames) / 1000,
            encoder.slices.len,
            total_frames,
            psnr,
            keyframe_bytes,
            p_frame_bytes,
            stats.intra,
            stats.inter,
            stats.skip,
        },
    );
}

fn paintQuadrants(frame: Frame, random: std.Random) void {
    const half_width = frame.width / 2 & ~@as(usize, 1);
    const half_height = frame.height / 2 & ~@as(usize, 1);
    frame.paint(random, 0, 0, half_width, half_height, 1);
    frame.paint(random, half_width, 0, frame.width - half_width, half_height, 2);
    frame.paint(random, 0, half_height, half_width, frame.height - half_height, 3);
    frame.paint(random, half_width, half_height, frame.width - half_width, frame.height - half_height, 5);
}

/// Rows of the scroll scene that stay put, deliberately not a whole number
/// of macroblocks.
const scroll_header = 20;

/// Shows the page from `offset` below a header that keeps the frame's
/// initial top rows.
fn drawScroll(frame: Frame, page: Frame, offset: usize) void {
    for (scroll_header..frame.height) |y| {
        @memcpy(frame.y[y * frame.width ..][0..frame.width], page.y[(y - scroll_header + offset) * page.width ..][0..frame.width]);
    }
    const chroma_width = frame.width / 2;
    for (scroll_header / 2..frame.height / 2) |y| {
        const page_row = y - scroll_header / 2 + offset / 2;
        @memcpy(frame.u[y * chroma_width ..][0..chroma_width], page.u[page_row * chroma_width ..][0..chroma_width]);
        @memcpy(frame.v[y * chroma_width ..][0..chroma_width], page.v[page_row * chroma_width ..][0..chroma_width]);
    }
}

/// Draws `sprite` with its top-left corner at an even position, clipped to
/// the frame.
fn drawSprite(frame: Frame, sprite: Frame, x: isize, y: isize) void {
    const x0 = x & ~@as(isize, 1);
    const y0 = y & ~@as(isize, 1);
    for (0..sprite.height) |row| {
        const frame_y = y0 + @as(isize, @intCast(row));
        if (frame_y < 0 or frame_y >= frame.height) continue;
        for (0..sprite.width) |column| {
            const frame_x = x0 + @as(isize, @intCast(column));
            if (frame_x < 0 or frame_x >= frame.width) continue;
            const fx: usize = @intCast(frame_x);
            const fy: usize = @intCast(frame_y);
            frame.y[fy * frame.width + fx] = sprite.y[row * sprite.width + column];
            if (row % 2 == 0 and column % 2 == 0) {
                const chroma = (fy / 2) * (frame.width / 2) + fx / 2;
                const sprite_chroma = (row / 2) * (sprite.width / 2) + column / 2;
                frame.u[chroma] = sprite.u[sprite_chroma];
                frame.v[chroma] = sprite.v[sprite_chroma];
            }
        }
    }
}

fn appendReconstruction(allocator: std.mem.Allocator, output: *std.ArrayList(u8), encoder: *const Encoder) !void {
    for (encoder.decoded(), 0..) |plane, index| {
        const width: usize = if (index == 0) encoder.config.width else encoder.config.width / 2;
        const height: usize = if (index == 0) encoder.config.height else encoder.config.height / 2;
        for (0..height) |row| try output.appendSlice(allocator, plane.data[row * plane.stride ..][0..width]);
    }
}

fn psnrOf(squared_error: f64, samples: usize) f64 {
    const mse = squared_error / @as(f64, @floatFromInt(samples));
    return if (mse == 0) 99.0 else 10 * std.math.log10(255.0 * 255.0 / mse);
}

fn lumaSquaredError(encoder: *const Encoder, frame: Frame) f64 {
    const plane = encoder.decoded()[0];
    var total: f64 = 0;
    for (0..frame.height) |row| for (0..frame.width) |column| {
        const difference = @as(f64, @floatFromInt(plane.data[row * plane.stride + column])) -
            @as(f64, @floatFromInt(frame.y[row * frame.width + column]));
        total += difference * difference;
    };
    return total;
}

fn compare(out: *std.Io.Writer, case: Case, expected: []const u8, actual: []const u8) !void {
    const frame_size = case.width * case.height * 3 / 2;
    if (expected.len != actual.len) {
        try out.print("FAIL {s}: decoded {d} frames, encoded {d}\n", .{
            case.name,
            actual.len / frame_size,
            expected.len / frame_size,
        });
        return error.Mismatch;
    }
    const index = std.mem.indexOfDiff(u8, expected, actual) orelse return;
    const frame = index / frame_size;
    var offset = index % frame_size;
    const luma_size = case.width * case.height;
    const plane: []const u8, const width: usize = if (offset < luma_size)
        .{ "Y", case.width }
    else if (offset < luma_size * 5 / 4) blk: {
        offset -= luma_size;
        break :blk .{ "U", case.width / 2 };
    } else blk: {
        offset -= luma_size * 5 / 4;
        break :blk .{ "V", case.width / 2 };
    };
    try out.print(
        "FAIL {s}: frame {d} plane {s} at ({d}, {d}) is {d}, encoder reconstructed {d}\n",
        .{ case.name, frame, plane, offset % width, offset / width, actual[index], expected[index] },
    );
    return error.Mismatch;
}
