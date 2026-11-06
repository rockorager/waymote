//! A Constrained Baseline H.264 encoder for desktop capture.
//!
//! Keyframes code every macroblock as Intra16x16. In P frames, macroblocks
//! whose source did not change keep their decoded samples, mostly as P_Skip.
//! Changed macroblocks pick the cheaper of Intra16x16 and one whole-pixel
//! motion vector (P_L0_16x16), searched from the zero vector, the neighbors'
//! vectors, and vertical scroll offsets found by matching rows against the
//! previous picture. A scrolled region therefore costs about one vector per
//! row of macroblocks instead of a redraw.
//!
//! Each picture is split into horizontal slices that are encoded on separate
//! threads. The deblocking filter is disabled, so the encoder's reconstruction
//! is exactly the decoded picture and the next reference.

const Encoder = @This();

const std = @import("std");

/// Safety checks follow this module's optimize mode, which build.zig sets to
/// ReleaseFast in release builds of streamd: the checks cost about 40% of
/// encoding time there, while tests and h264-check keep them on.
const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};
const BitWriter = @import("BitWriter.zig");
const cavlc = @import("cavlc.zig");
const transform = @import("transform.zig");

const Block = transform.Block;
const log2_max_frame_num = 16;
/// Largest motion vector component considered, in whole pixels. Level 3.1 and
/// above allow vertical components of up to 512.
const search_range = 256;
const max_slices = 8;
/// How much coarser than the picture's QP an unchanged macroblock must be for
/// spare bits to code it again.
const refine_margin = 4;

pub const Config = struct {
    width: u32,
    height: u32,
    /// Luma quantization parameter, 0 to 51: fixed without a bitrate, and the
    /// finest that rate control uses with one.
    qp: u8 = 28,
    /// Bitrate in kbit/s that rate control holds pictures to; 0 codes every
    /// picture at `qp`.
    bitrate_kbps: u32 = 0,
    /// Pictures per second at full motion, which spreads the bitrate.
    fps: u32 = 30,
    /// Pictures with changes from one IDR picture to the next.
    keyframe_interval: u32 = 30,
    /// Most pictures from one IDR picture to the next, counting refinement
    /// pictures that `keyframe_interval` skips. Waymote's gateway keeps at
    /// most 240 to start new viewers.
    max_gop_length: u32 = 240,
    /// Slices per picture, each encoded on its own thread. 0 picks one per
    /// CPU, up to 8, while keeping at least four macroblock rows per slice.
    slices: u32 = 0,
};

/// An I420 picture of exactly `Config.width` by `Config.height`.
pub const Picture = struct {
    y: []const u8,
    u: []const u8,
    v: []const u8,
    y_stride: usize,
    chroma_stride: usize,
};

/// A half-open range of luma rows that may have changed.
pub const Rows = struct {
    first: u32,
    end: u32,
};

pub const Plane = struct {
    data: []u8,
    stride: usize,
};

/// A motion vector in quarter samples.
pub const Vector = struct {
    x: i32 = 0,
    y: i32 = 0,

    fn eql(a: Vector, b: Vector) bool {
        return a.x == b.x and a.y == b.y;
    }

    fn isZero(self: Vector) bool {
        return self.x == 0 and self.y == 0;
    }
};

/// How the macroblocks of the last picture were coded.
pub const Stats = struct {
    intra: u32 = 0,
    inter: u32 = 0,
    skip: u32 = 0,
    /// Unchanged macroblocks coded again at a finer QP; also counted above.
    refined: u32 = 0,

    fn add(self: *Stats, other: Stats) void {
        self.intra += other.intra;
        self.inter += other.inter;
        self.skip += other.skip;
        self.refined += other.refined;
    }
};

/// What later macroblocks see of a coded macroblock for motion vector
/// prediction (8.4.1.3).
const Motion = struct {
    vector: Vector = .{},
    /// False for intra macroblocks, whose refIdxL0 is -1.
    inter: bool = false,
};

const Slice = struct {
    first_row: usize,
    end_row: usize,
    writer: BitWriter,
    output: std.ArrayList(u8) = .empty,
    skip_run: u32 = 0,
    stats: Stats = .{},
    /// Bits spent on refined macroblocks.
    refine_bits: u64 = 0,
    result: anyerror!void = {},
};

/// Previous-picture row segments by content, for scroll detection.
const ScrollTable = struct {
    entries: []Entry,
    generation: u16 = 0,
    votes: [2 * search_range + 1]u32 = undefined,

    const Entry = struct {
        key: u32,
        y: u16,
        generation: u16,
    };
    const max_probes = 8;

    fn insert(self: *ScrollTable, hash: u64, y: u16) void {
        const mask = self.entries.len - 1;
        const key: u32 = @truncate(hash >> 32);
        var slot: usize = @intCast(hash & mask);
        for (0..max_probes) |_| {
            const entry = &self.entries[slot];
            if (entry.generation != self.generation or entry.key == key) {
                entry.* = .{ .key = key, .y = y, .generation = self.generation };
                return;
            }
            slot = (slot + 1) & mask;
        }
    }

    fn find(self: *const ScrollTable, hash: u64) ?u16 {
        const mask = self.entries.len - 1;
        const key: u32 = @truncate(hash >> 32);
        var slot: usize = @intCast(hash & mask);
        for (0..max_probes) |_| {
            const entry = self.entries[slot];
            if (entry.generation != self.generation) return null;
            if (entry.key == key) return entry.y;
            slot = (slot + 1) & mask;
        }
        return null;
    }
};

allocator: std.mem.Allocator,
config: Config,
mb_width: usize,
mb_height: usize,
/// The current source, padded to whole macroblocks by edge replication.
source: [3]Plane,
/// The previous source's luma, for scroll detection.
previous_luma: Plane,
/// The decoded previous picture, which P frames reference.
reference: [3]Plane,
/// The picture being decoded, which becomes the reference afterwards.
current: [3]Plane,
/// TotalCoeff of every 4x4 luma block, in 4x4-block units across the frame.
luma_counts: []u8,
/// TotalCoeff of every 4x4 chroma AC block, per chroma component.
chroma_counts: [2][]u8,
changed: []bool,
changed_count: usize = 0,
/// Macroblocks whose samples in `current` may differ from `reference` when a
/// picture starts, because the previous picture rewrote them.
modified: []bool,
/// The QP each macroblock of `reference` was effectively coded at: a skipped
/// macroblock keeps its earlier value, a coded one takes its picture's QP.
coded_qp: []u8,
/// `coded_qp` for the picture being coded.
next_coded_qp: []u8,
/// Unchanged macroblocks this picture codes again at its finer QP.
refining: []bool,
/// Macroblocks coarse enough that refining them at `Config.qp` would help.
pending_refinement: usize = 0,
/// The coarsest `coded_qp` among them.
coarsest_qp: u8 = 0,
motion: []Motion,
changed_columns: []bool,
scroll: ScrollTable,
/// Vertical scroll vectors found for this picture.
scroll_candidates: [2]Vector = undefined,
scroll_candidate_count: usize = 0,
/// QP of the picture being coded.
qp: u8,
/// Weight of one bit against one unit of SAD in mode decisions.
lambda: u32,
rate: RateControl,
slices: []Slice,
writer: BitWriter,
output: std.ArrayList(u8) = .empty,
stats: Stats = .{},
/// Pictures with changes since the last IDR picture.
frames_since_keyframe: u32 = 0,
/// All pictures since the last IDR picture, including it.
gop_length: u32 = 0,
frame_num: u16 = 0,
idr_pic_id: u16 = 0,
started: bool = false,

pub fn init(allocator: std.mem.Allocator, config: Config) !Encoder {
    if (config.width == 0 or config.height == 0 or config.width % 2 != 0 or config.height % 2 != 0) {
        return error.UnsupportedDimensions;
    }
    if (config.qp > 51 or config.keyframe_interval == 0 or config.fps == 0 or config.max_gop_length == 0) {
        return error.InvalidEncoderConfig;
    }
    const mb_width = (config.width + 15) / 16;
    const mb_height = (config.height + 15) / 16;
    if (mb_height * 16 > std.math.maxInt(u16)) return error.UnsupportedDimensions;
    const empty_plane: Plane = .{ .data = &.{}, .stride = 0 };
    var self: Encoder = .{
        .allocator = allocator,
        .config = config,
        .mb_width = mb_width,
        .mb_height = mb_height,
        .source = @splat(empty_plane),
        .previous_luma = empty_plane,
        .reference = @splat(empty_plane),
        .current = @splat(empty_plane),
        .luma_counts = &.{},
        .chroma_counts = .{ &.{}, &.{} },
        .changed = &.{},
        .modified = &.{},
        .coded_qp = &.{},
        .next_coded_qp = &.{},
        .refining = &.{},
        .motion = &.{},
        .changed_columns = &.{},
        .scroll = .{ .entries = &.{} },
        .qp = config.qp,
        .lambda = lambdaFor(config.qp),
        .rate = .init(config),
        .slices = &.{},
        .writer = .init(allocator),
    };
    errdefer self.deinit();
    for (0..3) |plane| {
        const stride = if (plane == 0) mb_width * 16 else mb_width * 8;
        const rows = if (plane == 0) mb_height * 16 else mb_height * 8;
        self.source[plane] = .{ .data = try allocator.alloc(u8, stride * rows), .stride = stride };
        self.reference[plane] = .{ .data = try allocator.alloc(u8, stride * rows), .stride = stride };
        self.current[plane] = .{ .data = try allocator.alloc(u8, stride * rows), .stride = stride };
    }
    self.previous_luma = .{ .data = try allocator.alloc(u8, self.source[0].data.len), .stride = mb_width * 16 };
    const macroblocks = mb_width * mb_height;
    self.luma_counts = try allocator.alloc(u8, macroblocks * 16);
    for (&self.chroma_counts) |*counts| counts.* = try allocator.alloc(u8, macroblocks * 4);
    self.changed = try allocator.alloc(bool, macroblocks);
    self.modified = try allocator.alloc(bool, macroblocks);
    self.coded_qp = try allocator.alloc(u8, macroblocks);
    self.next_coded_qp = try allocator.alloc(u8, macroblocks);
    self.refining = try allocator.alloc(bool, macroblocks);
    self.motion = try allocator.alloc(Motion, macroblocks);
    self.changed_columns = try allocator.alloc(bool, mb_width);
    self.scroll.entries = try allocator.alloc(ScrollTable.Entry, try std.math.ceilPowerOfTwo(usize, macroblocks * 32));
    @memset(self.scroll.entries, .{ .key = 0, .y = 0, .generation = 0 });

    const slice_count = sliceCount(config.slices, mb_height);
    self.slices = try allocator.alloc(Slice, slice_count);
    for (self.slices, 0..) |*slice, index| {
        slice.* = .{
            .first_row = mb_height * index / slice_count,
            .end_row = mb_height * (index + 1) / slice_count,
            .writer = .init(allocator),
        };
    }
    return self;
}

pub fn deinit(self: *Encoder) void {
    for (self.source, self.reference, self.current) |source, reference, current| {
        if (source.data.len != 0) self.allocator.free(source.data);
        if (reference.data.len != 0) self.allocator.free(reference.data);
        if (current.data.len != 0) self.allocator.free(current.data);
    }
    if (self.previous_luma.data.len != 0) self.allocator.free(self.previous_luma.data);
    if (self.luma_counts.len != 0) self.allocator.free(self.luma_counts);
    for (self.chroma_counts) |counts| if (counts.len != 0) self.allocator.free(counts);
    if (self.changed.len != 0) self.allocator.free(self.changed);
    if (self.modified.len != 0) self.allocator.free(self.modified);
    if (self.coded_qp.len != 0) self.allocator.free(self.coded_qp);
    if (self.next_coded_qp.len != 0) self.allocator.free(self.next_coded_qp);
    if (self.refining.len != 0) self.allocator.free(self.refining);
    if (self.motion.len != 0) self.allocator.free(self.motion);
    if (self.changed_columns.len != 0) self.allocator.free(self.changed_columns);
    if (self.scroll.entries.len != 0) self.allocator.free(self.scroll.entries);
    for (self.slices) |*slice| {
        slice.writer.deinit();
        slice.output.deinit(self.allocator);
    }
    if (self.slices.len != 0) self.allocator.free(self.slices);
    self.writer.deinit();
    self.output.deinit(self.allocator);
    self.* = undefined;
}

fn sliceCount(requested: u32, mb_height: usize) usize {
    if (requested != 0) return @min(@as(usize, requested), mb_height);
    const cpus = std.Thread.getCpuCount() catch 1;
    return std.math.clamp(@min(cpus, max_slices), 1, @max(1, mb_height / 4));
}

/// sqrt(0.85 * 2^((QP - 12) / 3)), the usual SAD-domain Lagrangian.
fn lambdaFor(qp: u8) u32 {
    const exponent = (@as(f64, @floatFromInt(qp)) - 12) / 3;
    return @max(1, @as(u32, @intFromFloat(@round(@sqrt(0.85 * std.math.pow(f64, 2, exponent))))));
}

/// A leaky bucket that drains at the bitrate, one picture interval per coded
/// picture, and holds one second of it. Each picture's QP is the finest whose
/// predicted size fits a share of the room left, from a model where bits per
/// changed macroblock halve every 6 QP.
const RateControl = struct {
    enabled: bool,
    capacity: f64,
    frame_budget: f64,
    /// Bits the bucket can still take.
    room: f64,
    /// Bits per changed macroblock at QP 0, for P and IDR pictures.
    complexity: [2]f64,
    /// Bits per refined macroblock at QP 0.
    refine_complexity: f64,
    /// QP of the last picture that coded changes.
    last_qp: ?u8 = null,

    fn init(config: Config) RateControl {
        const bitrate: f64 = @floatFromInt(@as(u64, config.bitrate_kbps) * 1000);
        // A rough desktop guess of about 150 bits per macroblock at QP 28
        // until the first pictures calibrate it.
        const guess = 150 * std.math.pow(f64, 2, 28.0 / 6.0);
        return .{
            .enabled = config.bitrate_kbps != 0,
            .capacity = bitrate,
            .frame_budget = bitrate / @as(f64, @floatFromInt(config.fps)),
            .room = bitrate,
            .complexity = .{ guess, guess },
            .refine_complexity = guess,
        };
    }

    /// Drains one picture interval's worth of bits from the bucket.
    fn refill(self: *RateControl) void {
        self.room = @min(self.capacity, self.room + self.frame_budget);
    }

    /// Bits one picture may spend, leaving room for the ones after it. P
    /// pictures also stay within a few pictures' share so that a burst of
    /// them cannot queue a second of video at once.
    fn target(self: RateControl, keyframe: bool) f64 {
        if (keyframe) return self.room * 0.75;
        return @min(self.room * 0.5, 4 * self.frame_budget);
    }

    fn bitsAt(complexity: f64, macroblocks: usize, qp: u8) f64 {
        return complexity * @as(f64, @floatFromInt(macroblocks)) * std.math.pow(f64, 2, -@as(f64, @floatFromInt(qp)) / 6);
    }

    /// `pending` and `coarsest` describe the macroblocks left for refinement,
    /// which pictures without changes code.
    fn chooseQp(self: *const RateControl, minimum: u8, keyframe: bool, changed: usize, pending: usize, coarsest: u8) u8 {
        if (!self.enabled) return minimum;
        if (changed == 0) {
            if (pending == 0) return minimum;
            // Aim to sharpen everything within about a second of bitrate:
            // coarser first when much is left, then again at finer QPs, but
            // always fine enough that some macroblocks qualify.
            const qp = raise(minimum, bitsAt(self.refine_complexity, pending, minimum), self.capacity);
            return @min(qp, coarsest - refine_margin);
        }
        const target_bits = self.target(keyframe);
        if (target_bits <= 0) return 51;
        const qp = raise(minimum, bitsAt(self.complexity[@intFromBool(keyframe)], changed, minimum), target_bits);
        // A P picture much finer than its reference re-codes the difference
        // in every predicted macroblock, which the model cannot foresee, so
        // QP comes down a little per picture.
        const last = self.last_qp orelse return qp;
        return if (keyframe) qp else @max(qp, last -| 2);
    }

    /// The QP at least `qp` that brings `bits` at `qp` under `target_bits`.
    fn raise(qp: u8, bits: f64, target_bits: f64) u8 {
        if (bits <= target_bits) return qp;
        if (target_bits <= 0) return 51;
        const steps = @ceil(6 * std.math.log2(bits / target_bits));
        return @intFromFloat(@min(51, @as(f64, @floatFromInt(qp)) + steps));
    }

    /// How many unchanged macroblocks fit in what this P picture's target
    /// leaves after its changed ones.
    fn refinementAllowance(self: RateControl, qp: u8, changed: usize) usize {
        const spare = self.target(false) - bitsAt(self.complexity[0], changed, qp);
        if (spare <= 0) return 0;
        return @intFromFloat(@min(spare / bitsAt(self.refine_complexity, 1, qp), std.math.maxInt(u32)));
    }

    fn learnRefinement(self: *RateControl, bits: f64, refined: u32, qp: u8) void {
        const observed = bits / @as(f64, @floatFromInt(refined)) * std.math.pow(f64, 2, @as(f64, @floatFromInt(qp)) / 6);
        self.refine_complexity = (self.refine_complexity + observed) / 2;
    }

    fn update(self: *RateControl, bits: f64, refine_bits: f64, qp: u8, keyframe: bool, changed: usize) void {
        self.room -= bits;
        if (changed == 0) return;
        self.last_qp = qp;
        const observed = @max(bits - refine_bits, 0) / @as(f64, @floatFromInt(changed)) *
            std.math.pow(f64, 2, @as(f64, @floatFromInt(qp)) / 6);
        const complexity = &self.complexity[@intFromBool(keyframe)];
        complexity.* = if (keyframe) observed else (complexity.* + observed) / 2;
    }
};

/// The decoded picture from the last `encode` call.
pub fn decoded(self: *const Encoder) [3]Plane {
    return self.reference;
}

/// Encodes one picture into an Annex-B access unit that stays valid until the
/// next call. Rows outside `damage` must be unchanged since the previous
/// picture; pass null when unknown.
pub fn encode(self: *Encoder, picture: Picture, damage: ?Rows, force_keyframe: bool) ![]const u8 {
    self.output.clearRetainingCapacity();
    const keyframe = force_keyframe or !self.started or
        self.frames_since_keyframe >= self.config.keyframe_interval or
        self.gop_length >= self.config.max_gop_length;
    if (keyframe) {
        self.loadSource(picture, .{ .first = 0, .end = self.config.height });
        @memset(self.changed, true);
        self.changed_count = self.changed.len;
        try self.writeParameterSets();
    } else {
        self.loadSource(picture, damage orelse .{ .first = 0, .end = self.config.height });
        self.findScrollCandidates();
    }
    self.rate.refill();
    return self.encodeFrame(keyframe);
}

/// Whether `refine` would sharpen macroblocks that rate control left coarse.
pub fn refinementPending(self: *const Encoder) bool {
    // A full GOP waits for the next keyframe, which only changes bring.
    return self.pending_refinement != 0 and self.gop_length < self.config.max_gop_length;
}

/// Encodes the previous picture again as a P frame that spends the bitrate's
/// spare room on unchanged macroblocks coded coarser than `Config.qp`, for
/// callers to send while the source is idle, once per picture interval. The
/// result is valid until the next call; null means the bitrate has no room
/// this interval and there is nothing to send.
pub fn refine(self: *Encoder) !?[]const u8 {
    std.debug.assert(self.started);
    self.rate.refill();
    if (!self.refinementPending()) return null;
    const qp = self.rate.chooseQp(self.config.qp, false, 0, self.pending_refinement, self.coarsest_qp);
    if (self.rate.refinementAllowance(qp, 0) == 0) return null;
    self.output.clearRetainingCapacity();
    @memset(self.changed, false);
    self.changed_count = 0;
    self.scroll_candidate_count = 0;
    return try self.encodeFrame(false);
}

fn encodeFrame(self: *Encoder, keyframe: bool) ![]const u8 {
    if (keyframe) {
        self.frame_num = 0;
        self.frames_since_keyframe = 0;
        self.gop_length = 0;
    } else {
        self.frame_num +%= 1;
    }
    var qp = self.rate.chooseQp(self.config.qp, keyframe, self.changed_count, self.pending_refinement, self.coarsest_qp);
    var bits: f64 = 0;
    var refine_bits: f64 = 0;
    var attempts: usize = 0;
    while (true) : (attempts += 1) {
        self.qp = qp;
        self.lambda = lambdaFor(qp);
        self.markRefinement(keyframe);
        try self.encodeSlices(keyframe);
        var bytes: usize = 0;
        var refined: u32 = 0;
        refine_bits = 0;
        for (self.slices) |slice| {
            bytes += slice.output.items.len;
            refined += slice.stats.refined;
            refine_bits += @floatFromInt(slice.refine_bits);
        }
        bits = @floatFromInt(bytes * 8);
        if (refined != 0) self.rate.learnRefinement(refine_bits, refined, qp);
        // Coding again rewrites every macroblock of `current`, so a picture
        // that would overflow the bucket can retry.
        if (!self.rate.enabled or bits <= self.rate.room or qp == 51 or attempts == 2) break;
        // The refinement estimate now includes this attempt, so retrying at
        // the same QP refines fewer macroblocks.
        if (refined != 0 and bits - refine_bits <= self.rate.room) continue;
        qp = @max(qp + 2, RateControl.raise(qp, bits, self.rate.target(keyframe)));
        qp = @min(qp, 51);
    }
    self.stats = .{};
    for (self.slices) |*slice| {
        try self.output.appendSlice(self.allocator, slice.output.items);
        self.stats.add(slice.stats);
    }
    self.rate.update(bits, refine_bits, qp, keyframe, self.changed_count);
    std.mem.swap([3]Plane, &self.reference, &self.current);
    std.mem.swap([]u8, &self.coded_qp, &self.next_coded_qp);
    self.savePreviousLuma();
    self.pending_refinement = 0;
    self.coarsest_qp = 0;
    if (self.rate.enabled) {
        for (self.coded_qp) |coded| {
            if (coded < self.config.qp + refine_margin) continue;
            self.pending_refinement += 1;
            self.coarsest_qp = @max(self.coarsest_qp, coded);
        }
    }
    if (keyframe) self.idr_pic_id +%= 1;
    // Pictures without changes do not bring the next periodic keyframe closer.
    if (self.changed_count != 0) self.frames_since_keyframe += 1;
    self.gop_length += 1;
    self.started = true;
    return self.output.items;
}

/// Picks the unchanged macroblocks that this picture codes again, in raster
/// order, as many as the rate allows.
fn markRefinement(self: *Encoder, keyframe: bool) void {
    @setRuntimeSafety(runtime_safety);
    @memset(self.refining, false);
    if (keyframe or !self.rate.enabled) return;
    const allowance = self.rate.refinementAllowance(self.qp, self.changed_count);
    var marked: usize = 0;
    for (self.changed, self.coded_qp, self.refining) |changed, coded, *refining| {
        if (marked == allowance) break;
        if (changed or coded < self.qp + refine_margin) continue;
        refining.* = true;
        marked += 1;
    }
}

/// Copies changed macroblocks of `picture` into the padded source and marks
/// them; macroblocks outside `rows` keep their previous contents.
fn loadSource(self: *Encoder, picture: Picture, rows: Rows) void {
    @setRuntimeSafety(runtime_safety);
    @memset(self.changed, false);
    self.changed_count = 0;
    if (rows.first >= rows.end) return;
    const first_mb_row = @min(rows.first, self.config.height - 1) / 16;
    const end_mb_row = (@min(rows.end, self.config.height) + 15) / 16;
    const width: usize = self.config.width;
    const height: usize = self.config.height;
    for (first_mb_row..end_mb_row) |mb_y| {
        for (0..self.mb_width) |mb_x| {
            var different = false;
            for (0..3) |plane| {
                const size: usize = if (plane == 0) 16 else 8;
                const plane_width = if (plane == 0) width else width / 2;
                const plane_height = if (plane == 0) height else height / 2;
                const input = switch (plane) {
                    0 => picture.y,
                    1 => picture.u,
                    else => picture.v,
                };
                const input_stride = if (plane == 0) picture.y_stride else picture.chroma_stride;
                const target = self.source[plane];
                for (0..size) |row| {
                    const y = mb_y * size + row;
                    const source_row = @min(y, plane_height - 1);
                    const destination = target.data[y * target.stride + mb_x * size ..][0..size];
                    const x0 = mb_x * size;
                    if (x0 + size <= plane_width) {
                        const incoming = input[source_row * input_stride + x0 ..][0..size];
                        if (!different and !std.mem.eql(u8, destination, incoming)) different = true;
                        @memcpy(destination, incoming);
                    } else {
                        for (destination, 0..) |*sample, column| {
                            const x = @min(x0 + column, plane_width - 1);
                            const incoming = input[source_row * input_stride + x];
                            if (sample.* != incoming) different = true;
                            sample.* = incoming;
                        }
                    }
                }
            }
            self.changed[mb_y * self.mb_width + mb_x] = different;
            self.changed_count += @intFromBool(different);
        }
    }
}

fn savePreviousLuma(self: *Encoder) void {
    @setRuntimeSafety(runtime_safety);
    const stride = self.source[0].stride;
    for (self.changed, 0..) |changed, index| {
        if (!changed) continue;
        const x0 = (index % self.mb_width) * 16;
        const y0 = (index / self.mb_width) * 16;
        for (0..16) |row| {
            const offset = (y0 + row) * stride + x0;
            @memcpy(self.previous_luma.data[offset..][0..16], self.source[0].data[offset..][0..16]);
        }
    }
}

/// Hashes the 16 luma samples of one macroblock column on one row, or returns
/// null for a flat segment, which matches everywhere and says nothing.
fn segmentHash(plane: Plane, column: usize, y: usize) ?u64 {
    @setRuntimeSafety(runtime_safety);
    const bytes = plane.data[y * plane.stride + column * 16 ..][0..16];
    const a = std.mem.readInt(u64, bytes[0..8], .little);
    const b = std.mem.readInt(u64, bytes[8..16], .little);
    if (a == b and a == (a & 0xff) *% 0x0101_0101_0101_0101) return null;
    var hash = a *% 0x9e37_79b9_7f4a_7c15 ^ std.math.rotl(u64, b *% 0xc2b2_ae3d_27d4_eb4f, 31) ^
        @as(u64, column) *% 0x1656_67b1_9e37_79f9;
    hash ^= hash >> 29;
    hash *%= 0xbf58_476d_1ce4_e5b9;
    return hash ^ (hash >> 32);
}

/// Finds vertical displacements that map rows of changed macroblocks onto
/// identical rows of the previous source in the same macroblock column, and
/// keeps the most common as motion search candidates.
fn findScrollCandidates(self: *Encoder) void {
    @setRuntimeSafety(runtime_safety);
    self.scroll_candidate_count = 0;
    @memset(self.changed_columns, false);
    var first_row: usize = self.mb_height;
    var end_row: usize = 0;
    for (self.changed, 0..) |changed, index| {
        if (!changed) continue;
        self.changed_columns[index % self.mb_width] = true;
        first_row = @min(first_row, index / self.mb_width);
        end_row = index / self.mb_width + 1;
    }
    if (first_row >= end_row) return;

    const table = &self.scroll;
    table.generation +%= 1;
    if (table.generation == 0) {
        @memset(table.entries, .{ .key = 0, .y = 0, .generation = 0 });
        table.generation = 1;
    }
    const first_y = (first_row * 16) -| search_range;
    const end_y = @min(end_row * 16 + search_range, self.mb_height * 16);
    for (self.changed_columns, 0..) |changed, column| {
        if (!changed) continue;
        for (first_y..end_y) |y| {
            const hash = segmentHash(self.previous_luma, column, y) orelse continue;
            table.insert(hash, @intCast(y));
        }
    }
    @memset(&table.votes, 0);
    for (self.changed, 0..) |changed, index| {
        if (!changed) continue;
        const column = index % self.mb_width;
        const y0 = (index / self.mb_width) * 16;
        for (y0..y0 + 16) |y| {
            const hash = segmentHash(self.source[0], column, y) orelse continue;
            const previous_y = table.find(hash) orelse continue;
            const offset = @as(isize, previous_y) - @as(isize, @intCast(y));
            if (offset == 0 or @abs(offset) > search_range) continue;
            table.votes[@intCast(offset + search_range)] += 1;
        }
    }
    // A candidate needs about one macroblock's worth of matching rows.
    for (&self.scroll_candidates) |*candidate| {
        var best: usize = 0;
        var best_votes: u32 = 15;
        for (table.votes, 0..) |votes, offset| {
            if (votes > best_votes) {
                best = offset;
                best_votes = votes;
            }
        }
        if (best_votes == 15) break;
        table.votes[best] = 0;
        const dy = @as(i32, @intCast(best)) - search_range;
        candidate.* = .{ .y = dy * 4 };
        self.scroll_candidate_count += 1;
    }
}

fn writeParameterSets(self: *Encoder) !void {
    const w = &self.writer;
    // Sequence parameter set (7.3.2.1.1): Constrained Baseline.
    try w.bits(66, 8);
    try w.bits(0b1100_0000, 8);
    try w.bits(levelIdc(self.mb_width * self.mb_height), 8);
    try w.ue(0);
    try w.ue(log2_max_frame_num - 4);
    try w.ue(2);
    try w.ue(1);
    try w.flag(false);
    try w.ue(@intCast(self.mb_width - 1));
    try w.ue(@intCast(self.mb_height - 1));
    try w.flag(true);
    try w.flag(true);
    const crop_right = (self.mb_width * 16 - self.config.width) / 2;
    const crop_bottom = (self.mb_height * 16 - self.config.height) / 2;
    const cropping = crop_right != 0 or crop_bottom != 0;
    try w.flag(cropping);
    if (cropping) {
        try w.ue(0);
        try w.ue(@intCast(crop_right));
        try w.ue(0);
        try w.ue(@intCast(crop_bottom));
    }
    // VUI with bitstream_restriction so decoders output each frame at once.
    try w.flag(true);
    try w.flag(false); // aspect_ratio_info_present_flag
    try w.flag(false); // overscan_info_present_flag
    try w.flag(false); // video_signal_type_present_flag
    try w.flag(false); // chroma_loc_info_present_flag
    try w.flag(false); // timing_info_present_flag
    try w.flag(false); // nal_hrd_parameters_present_flag
    try w.flag(false); // vcl_hrd_parameters_present_flag
    try w.flag(false); // pic_struct_present_flag
    try w.flag(true); // bitstream_restriction_flag
    try w.flag(true); // motion_vectors_over_pic_boundaries_flag
    try w.ue(0); // max_bytes_per_pic_denom
    try w.ue(0); // max_bits_per_mb_denom
    try w.ue(16); // log2_max_mv_length_horizontal
    try w.ue(16); // log2_max_mv_length_vertical
    try w.ue(0); // max_num_reorder_frames
    try w.ue(1); // max_dec_frame_buffering
    try w.trailing();
    try w.finishNal(&self.output, self.allocator, 3, 7);

    // Picture parameter set (7.3.2.2).
    try w.ue(0);
    try w.ue(0);
    try w.flag(false); // entropy_coding_mode_flag: CAVLC
    try w.flag(false); // bottom_field_pic_order_in_frame_present_flag
    try w.ue(0); // num_slice_groups_minus1
    try w.ue(0); // num_ref_idx_l0_default_active_minus1
    try w.ue(0); // num_ref_idx_l1_default_active_minus1
    try w.flag(false); // weighted_pred_flag
    try w.bits(0, 2); // weighted_bipred_idc
    try w.se(@as(i32, self.config.qp) - 26); // pic_init_qp_minus26
    try w.se(0); // pic_init_qs_minus26
    try w.se(0); // chroma_qp_index_offset
    try w.flag(true); // deblocking_filter_control_present_flag
    try w.flag(false); // constrained_intra_pred_flag
    try w.flag(false); // redundant_pic_cnt_present_flag
    try w.trailing();
    try w.finishNal(&self.output, self.allocator, 3, 8);
}

/// The lowest level (Table A-1) whose MaxFS fits the frame, at least 3.1 so
/// decoders accept desktop frame rates.
fn levelIdc(macroblocks: usize) u8 {
    const levels = [_]struct { idc: u8, max_frame_size: usize }{
        .{ .idc = 31, .max_frame_size = 3600 },
        .{ .idc = 32, .max_frame_size = 5120 },
        .{ .idc = 40, .max_frame_size = 8192 },
        .{ .idc = 42, .max_frame_size = 8704 },
        .{ .idc = 50, .max_frame_size = 22080 },
        .{ .idc = 51, .max_frame_size = 36864 },
    };
    for (levels) |level| if (macroblocks <= level.max_frame_size) return level.idc;
    return 52;
}

fn encodeSlices(self: *Encoder, keyframe: bool) !void {
    // Threads cost more than they save on nearly static pictures.
    const parallel = self.changed_count >= 64 * self.slices.len;
    var threads: [max_slices]?std.Thread = @splat(null);
    for (self.slices[1..], 1..) |*slice, index| {
        if (parallel) threads[index] = std.Thread.spawn(.{}, encodeSlice, .{ self, slice, keyframe }) catch null;
        if (threads[index] == null) self.encodeSlice(slice, keyframe);
    }
    self.encodeSlice(&self.slices[0], keyframe);
    for (threads) |thread| if (thread) |t| t.join();
    for (self.slices) |slice| try slice.result;
}

fn encodeSlice(self: *Encoder, slice: *Slice, keyframe: bool) void {
    slice.result = self.writeSlice(slice, keyframe);
}

fn writeSlice(self: *Encoder, slice: *Slice, keyframe: bool) !void {
    slice.output.clearRetainingCapacity();
    slice.skip_run = 0;
    slice.stats = .{};
    slice.refine_bits = 0;
    const w = &slice.writer;
    // Slice header (7.3.3).
    try w.ue(@intCast(slice.first_row * self.mb_width)); // first_mb_in_slice
    try w.ue(if (keyframe) 7 else 5); // slice_type: all I or all P
    try w.ue(0); // pic_parameter_set_id
    try w.bits(self.frame_num, log2_max_frame_num);
    if (keyframe) try w.ue(self.idr_pic_id % 2);
    if (!keyframe) {
        try w.flag(false); // num_ref_idx_active_override_flag
        try w.flag(false); // ref_pic_list_modification_flag_l0
    }
    if (keyframe) {
        try w.flag(false); // no_output_of_prior_pics_flag
        try w.flag(false); // long_term_reference_flag
    } else {
        try w.flag(false); // adaptive_ref_pic_marking_mode_flag
    }
    try w.se(@as(i32, self.qp) - self.config.qp); // slice_qp_delta
    try w.ue(1); // disable_deblocking_filter_idc

    // Slice data (7.3.4).
    for (slice.first_row..slice.end_row) |mb_y| {
        for (0..self.mb_width) |mb_x| try self.encodeMacroblock(slice, mb_x, mb_y, keyframe);
    }
    if (slice.skip_run > 0) try w.ue(slice.skip_run);
    try w.trailing();
    try w.finishNal(&slice.output, self.allocator, 3, if (keyframe) 5 else 1);
}

fn encodeMacroblock(self: *Encoder, slice: *Slice, mb_x: usize, mb_y: usize, keyframe: bool) !void {
    @setRuntimeSafety(runtime_safety);
    const index = mb_y * self.mb_width + mb_x;
    if (keyframe) {
        const source = self.loadLuma(mb_x, mb_y);
        const intra = self.chooseIntraLuma(slice, mb_x, mb_y, &source);
        try self.writeIntraMacroblock(slice, mb_x, mb_y, false, &source, &intra);
        return;
    }
    const prediction = self.predictMotion(slice, mb_x, mb_y);
    if (!self.changed[index] and self.refining[index]) {
        const start = slice.writer.bitCount();
        const source = self.loadLuma(mb_x, mb_y);
        try self.writeInterMacroblock(slice, mb_x, mb_y, &source, .{}, prediction);
        slice.refine_bits += slice.writer.bitCount() - start;
        slice.stats.refined += 1;
        return;
    }
    if (!self.changed[index]) {
        // The source did not change, so keep the previous decoded samples.
        self.next_coded_qp[index] = self.coded_qp[index];
        if (prediction.skip.isZero() or self.predictionMatchesReference(mb_x, mb_y, prediction.skip)) {
            self.skipMacroblock(slice, mb_x, mb_y, prediction.skip);
        } else {
            try writeInterHeader(slice, .{}, prediction.vector, 0);
            self.clearCounts(mb_x, mb_y);
            self.motion[index] = .{ .vector = .{}, .inter = true };
            slice.stats.inter += 1;
        }
        self.keepReference(mb_x, mb_y);
        return;
    }
    const source = self.loadLuma(mb_x, mb_y);
    const inter = self.searchMotion(mb_x, mb_y, prediction);
    // Intra cannot win against a prediction that is already this close.
    if (inter.sad > 512) {
        const intra = self.chooseIntraLuma(slice, mb_x, mb_y, &source);
        if (intra.cost + 8 * self.lambda < inter.cost) {
            try self.writeIntraMacroblock(slice, mb_x, mb_y, true, &source, &intra);
            return;
        }
    }
    try self.writeInterMacroblock(slice, mb_x, mb_y, &source, inter.vector, prediction);
}

fn loadLuma(self: *const Encoder, mb_x: usize, mb_y: usize) [256]i32 {
    @setRuntimeSafety(runtime_safety);
    var samples: [256]i32 = undefined;
    const plane = self.source[0];
    for (0..16) |y| for (0..16) |x| {
        samples[y * 16 + x] = plane.data[(mb_y * 16 + y) * plane.stride + mb_x * 16 + x];
    };
    return samples;
}

fn loadChroma(self: *const Encoder, mb_x: usize, mb_y: usize) [2][64]i32 {
    @setRuntimeSafety(runtime_safety);
    var samples: [2][64]i32 = undefined;
    for (0..2) |component| {
        const plane = self.source[component + 1];
        for (0..8) |y| for (0..8) |x| {
            samples[component][y * 8 + x] = plane.data[(mb_y * 8 + y) * plane.stride + mb_x * 8 + x];
        };
    }
    return samples;
}

/// Leaves a macroblock's reference samples in place as its decoded samples.
fn keepReference(self: *Encoder, mb_x: usize, mb_y: usize) void {
    @setRuntimeSafety(runtime_safety);
    const index = mb_y * self.mb_width + mb_x;
    if (!self.modified[index]) return;
    for (0..3) |plane| {
        const size: usize = if (plane == 0) 16 else 8;
        const stride = self.current[plane].stride;
        for (0..size) |row| {
            const offset = (mb_y * size + row) * stride + mb_x * size;
            @memcpy(self.current[plane].data[offset..][0..size], self.reference[plane].data[offset..][0..size]);
        }
    }
    self.modified[index] = false;
}

fn skipMacroblock(self: *Encoder, slice: *Slice, mb_x: usize, mb_y: usize, vector: Vector) void {
    @setRuntimeSafety(runtime_safety);
    slice.skip_run += 1;
    slice.stats.skip += 1;
    self.clearCounts(mb_x, mb_y);
    self.motion[mb_y * self.mb_width + mb_x] = .{ .vector = vector, .inter = true };
}

fn clearCounts(self: *Encoder, mb_x: usize, mb_y: usize) void {
    @setRuntimeSafety(runtime_safety);
    const luma_stride = self.mb_width * 4;
    for (0..4) |row| @memset(self.luma_counts[(mb_y * 4 + row) * luma_stride + mb_x * 4 ..][0..4], 0);
    const chroma_stride = self.mb_width * 2;
    for (self.chroma_counts) |counts| {
        for (0..2) |row| @memset(counts[(mb_y * 2 + row) * chroma_stride + mb_x * 2 ..][0..2], 0);
    }
}

const MotionPrediction = struct {
    /// mvpLX (8.4.1.3), which motion vector differences are relative to.
    vector: Vector,
    /// The motion vector a P_Skip macroblock here would use (8.4.1.1).
    skip: Vector,
    /// Motion vectors of the inter neighbors A, B, and C, as search hints.
    neighbors: [3]?Vector,
};

const Neighbor = struct {
    available: bool = false,
    motion: Motion = .{},

    fn vector(self: Neighbor) Vector {
        return if (self.available and self.motion.inter) self.motion.vector else .{};
    }

    fn inter(self: Neighbor) bool {
        return self.available and self.motion.inter;
    }
};

fn neighbor(self: *const Encoder, slice: *const Slice, mb_x: isize, mb_y: isize) Neighbor {
    @setRuntimeSafety(runtime_safety);
    if (mb_x < 0 or mb_x >= self.mb_width or mb_y < slice.first_row) return .{};
    const index: usize = @intCast(mb_y * @as(isize, @intCast(self.mb_width)) + mb_x);
    return .{ .available = true, .motion = self.motion[index] };
}

fn median(a: i32, b: i32, c: i32) i32 {
    return @max(@min(a, b), @min(@max(a, b), c));
}

/// Repeats the decoder's motion vector prediction for a 16x16 partition with
/// refIdxL0 0, and the P_Skip vector derivation.
fn predictMotion(self: *const Encoder, slice: *const Slice, mb_x: usize, mb_y: usize) MotionPrediction {
    @setRuntimeSafety(runtime_safety);
    const x: isize = @intCast(mb_x);
    const y: isize = @intCast(mb_y);
    const a = self.neighbor(slice, x - 1, y);
    var b = self.neighbor(slice, x, y - 1);
    var c = self.neighbor(slice, x + 1, y - 1);
    if (!c.available) c = self.neighbor(slice, x - 1, y - 1);

    const skip_is_zero = !a.available or !b.available or
        (a.inter() and a.vector().isZero()) or (b.inter() and b.vector().isZero());
    const hints: [3]?Vector = .{
        if (a.inter()) a.vector() else null,
        if (b.inter()) b.vector() else null,
        if (c.inter()) c.vector() else null,
    };

    if (!b.available and !c.available and a.available) {
        b = a;
        c = a;
    }
    const matches = @as(u2, @intFromBool(a.inter())) + @intFromBool(b.inter()) + @intFromBool(c.inter());
    const vector: Vector = if (matches == 1)
        (if (a.inter()) a.vector() else if (b.inter()) b.vector() else c.vector())
    else
        .{
            .x = median(a.vector().x, b.vector().x, c.vector().x),
            .y = median(a.vector().y, b.vector().y, c.vector().y),
        };
    return .{ .vector = vector, .skip = if (skip_is_zero) .{} else vector, .neighbors = hints };
}

/// Integer-sample luma prediction (8.4.2.2.1) for whole-pixel vectors, with
/// references outside the picture clamped to its edges.
fn predictLumaInter(self: *const Encoder, mb_x: usize, mb_y: usize, vector: Vector, prediction: *[256]u8) void {
    @setRuntimeSafety(runtime_safety);
    std.debug.assert(vector.x & 3 == 0 and vector.y & 3 == 0);
    const plane = self.reference[0];
    const width: isize = @intCast(self.mb_width * 16);
    const height: isize = @intCast(self.mb_height * 16);
    const x0 = @as(isize, @intCast(mb_x * 16)) + (vector.x >> 2);
    const y0 = @as(isize, @intCast(mb_y * 16)) + (vector.y >> 2);
    const inside = x0 >= 0 and y0 >= 0 and x0 + 16 <= width and y0 + 16 <= height;
    for (0..16) |row| {
        const y: usize = @intCast(std.math.clamp(y0 + @as(isize, @intCast(row)), 0, height - 1));
        const destination = prediction[row * 16 ..][0..16];
        if (inside) {
            @memcpy(destination, plane.data[y * plane.stride + @as(usize, @intCast(x0)) ..][0..16]);
        } else {
            for (destination, 0..) |*sample, column| {
                const x: usize = @intCast(std.math.clamp(x0 + @as(isize, @intCast(column)), 0, width - 1));
                sample.* = plane.data[y * plane.stride + x];
            }
        }
    }
}

/// Eighth-sample chroma prediction (8.4.2.2.2) for one 8x8 component.
fn predictChromaInter(self: *const Encoder, component: usize, mb_x: usize, mb_y: usize, vector: Vector, prediction: *[64]i32) void {
    @setRuntimeSafety(runtime_safety);
    const plane = self.reference[component + 1];
    const width: isize = @intCast(self.mb_width * 8);
    const height: isize = @intCast(self.mb_height * 8);
    const x0 = @as(isize, @intCast(mb_x * 8)) + (vector.x >> 3);
    const y0 = @as(isize, @intCast(mb_y * 8)) + (vector.y >> 3);
    const x_fraction = vector.x & 7;
    const y_fraction = vector.y & 7;
    if (x0 >= 0 and y0 >= 0 and x0 + 9 <= width and y0 + 9 <= height) {
        const origin = @as(usize, @intCast(y0)) * plane.stride + @as(usize, @intCast(x0));
        const weights: [4]i32 = .{
            (8 - x_fraction) * (8 - y_fraction),
            x_fraction * (8 - y_fraction),
            (8 - x_fraction) * y_fraction,
            x_fraction * y_fraction,
        };
        for (0..8) |row| {
            const top = plane.data[origin + row * plane.stride ..][0..9];
            const bottom = plane.data[origin + (row + 1) * plane.stride ..][0..9];
            for (0..8) |column| {
                prediction[row * 8 + column] = if (x_fraction == 0 and y_fraction == 0)
                    top[column]
                else
                    (weights[0] * top[column] + weights[1] * top[column + 1] +
                        weights[2] * bottom[column] + weights[3] * bottom[column + 1] + 32) >> 6;
            }
        }
        return;
    }
    for (0..8) |row| {
        const y = y0 + @as(isize, @intCast(row));
        const top: usize = @intCast(std.math.clamp(y, 0, height - 1));
        const bottom: usize = @intCast(std.math.clamp(y + 1, 0, height - 1));
        for (0..8) |column| {
            const x = x0 + @as(isize, @intCast(column));
            const left: usize = @intCast(std.math.clamp(x, 0, width - 1));
            const right: usize = @intCast(std.math.clamp(x + 1, 0, width - 1));
            const a: i32 = plane.data[top * plane.stride + left];
            const b: i32 = plane.data[top * plane.stride + right];
            const c: i32 = plane.data[bottom * plane.stride + left];
            const d: i32 = plane.data[bottom * plane.stride + right];
            prediction[row * 8 + column] = ((8 - x_fraction) * (8 - y_fraction) * a + x_fraction * (8 - y_fraction) * b +
                (8 - x_fraction) * y_fraction * c + x_fraction * y_fraction * d + 32) >> 6;
        }
    }
}

/// Whether predicting from `vector` reproduces the co-located reference
/// macroblock exactly, as over flat areas.
fn predictionMatchesReference(self: *const Encoder, mb_x: usize, mb_y: usize, vector: Vector) bool {
    @setRuntimeSafety(runtime_safety);
    var luma: [256]u8 = undefined;
    self.predictLumaInter(mb_x, mb_y, vector, &luma);
    const plane = self.reference[0];
    for (0..16) |row| {
        const reference = plane.data[(mb_y * 16 + row) * plane.stride + mb_x * 16 ..][0..16];
        if (!std.mem.eql(u8, luma[row * 16 ..][0..16], reference)) return false;
    }
    for (0..2) |component| {
        var chroma: [64]i32 = undefined;
        self.predictChromaInter(component, mb_x, mb_y, vector, &chroma);
        const chroma_plane = self.reference[component + 1];
        for (0..8) |y| for (0..8) |x| {
            if (chroma[y * 8 + x] != chroma_plane.data[(mb_y * 8 + y) * chroma_plane.stride + mb_x * 8 + x]) return false;
        };
    }
    return true;
}

fn lumaSad(self: *const Encoder, mb_x: usize, mb_y: usize, vector: Vector) u32 {
    @setRuntimeSafety(runtime_safety);
    const plane = self.source[0];
    const reference = self.reference[0];
    const x0 = @as(isize, @intCast(mb_x * 16)) + (vector.x >> 2);
    const y0 = @as(isize, @intCast(mb_y * 16)) + (vector.y >> 2);
    var prediction: []const u8 = undefined;
    var prediction_stride: usize = 16;
    var outside: [256]u8 = undefined;
    if (x0 >= 0 and y0 >= 0 and x0 + 16 <= reference.stride and y0 + 16 <= self.mb_height * 16) {
        prediction = reference.data[@as(usize, @intCast(y0)) * reference.stride + @as(usize, @intCast(x0)) ..];
        prediction_stride = reference.stride;
    } else {
        self.predictLumaInter(mb_x, mb_y, vector, &outside);
        prediction = &outside;
    }
    var total: u32 = 0;
    for (0..16) |row| {
        const a: @Vector(16, u8) = plane.data[(mb_y * 16 + row) * plane.stride + mb_x * 16 ..][0..16].*;
        const b: @Vector(16, u8) = prediction[row * prediction_stride ..][0..16].*;
        const difference = @as(@Vector(16, i16), @intCast(a)) - @as(@Vector(16, i16), @intCast(b));
        total += @reduce(.Add, @as(@Vector(16, u32), @intCast(@abs(difference))));
    }
    return total;
}

/// Length of the se(v) code for `value` (9.1.1).
fn signedCodeLength(value: i32) u32 {
    const code: u32 = if (value > 0) @as(u32, @intCast(value)) * 2 - 1 else @as(u32, @intCast(-value)) * 2;
    return 2 * (31 - @clz(code + 1)) + 1;
}

const InterChoice = struct {
    vector: Vector,
    cost: u32,
    sad: u32 = 0,
};

/// Picks the whole-pixel vector with the lowest SAD plus vector cost among
/// the candidates, then walks a small diamond from the best one.
fn searchMotion(self: *const Encoder, mb_x: usize, mb_y: usize, prediction: MotionPrediction) InterChoice {
    @setRuntimeSafety(runtime_safety);
    var best: InterChoice = .{ .vector = .{}, .cost = std.math.maxInt(u32) };
    var tried: [8]Vector = undefined;
    var tried_count: usize = 0;
    var candidates: [8]?Vector = @splat(null);
    candidates[0] = .{};
    candidates[1] = prediction.skip;
    candidates[2] = prediction.vector;
    for (prediction.neighbors, 3..) |hint, slot| candidates[slot] = hint;
    for (self.scroll_candidates[0..self.scroll_candidate_count], 6..) |candidate, slot| candidates[slot] = candidate;
    candidates: for (candidates) |maybe| {
        const candidate = wholePixel(maybe orelse continue);
        for (tried[0..tried_count]) |vector| if (vector.eql(candidate)) continue :candidates;
        tried[tried_count] = candidate;
        tried_count += 1;
        const cost = self.interCost(mb_x, mb_y, candidate, prediction.vector);
        if (cost < best.cost) best = .{ .vector = candidate, .cost = cost };
    }
    var steps: usize = 0;
    while (steps < 16 and best.cost > 0) : (steps += 1) {
        const center = best.vector;
        for ([_][2]i32{ .{ 4, 0 }, .{ -4, 0 }, .{ 0, 4 }, .{ 0, -4 } }) |step| {
            const candidate: Vector = .{ .x = center.x + step[0], .y = center.y + step[1] };
            if (@abs(candidate.x) > search_range * 4 or @abs(candidate.y) > search_range * 4) continue;
            const cost = self.interCost(mb_x, mb_y, candidate, prediction.vector);
            if (cost < best.cost) best = .{ .vector = candidate, .cost = cost };
        }
        if (best.vector.eql(center)) break;
    }
    best.sad = self.lumaSad(mb_x, mb_y, best.vector);
    return best;
}

fn wholePixel(vector: Vector) Vector {
    return .{
        .x = std.math.clamp(vector.x & ~@as(i32, 3), -search_range * 4, search_range * 4),
        .y = std.math.clamp(vector.y & ~@as(i32, 3), -search_range * 4, search_range * 4),
    };
}

fn interCost(self: *const Encoder, mb_x: usize, mb_y: usize, vector: Vector, predicted: Vector) u32 {
    @setRuntimeSafety(runtime_safety);
    const bits = signedCodeLength(vector.x - predicted.x) + signedCodeLength(vector.y - predicted.y);
    return self.lumaSad(mb_x, mb_y, vector) + self.lambda * bits;
}

/// coded_block_pattern to codeNum for inter macroblocks (Table 9-4).
const inter_cbp_code = blk: {
    const code_to_cbp = [48]u8{
        0,  16, 1,  2,  4,  8,  32, 3,  5,  10, 12, 15, 47, 7,  11, 13,
        14, 6,  9,  31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46,
        17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41,
    };
    var table: [48]u8 = undefined;
    for (code_to_cbp, 0..) |cbp, code| table[cbp] = code;
    break :blk table;
};

/// Writes mb_skip_run, then a P_L0_16x16 macroblock layer up to its residual.
fn writeInterHeader(slice: *Slice, vector: Vector, predicted: Vector, cbp: u32) !void {
    @setRuntimeSafety(runtime_safety);
    const w = &slice.writer;
    try w.ue(slice.skip_run);
    slice.skip_run = 0;
    try w.ue(0); // mb_type P_L0_16x16; ref_idx_l0 is absent with one reference
    try w.se(vector.x - predicted.x);
    try w.se(vector.y - predicted.y);
    try w.ue(inter_cbp_code[cbp]);
    if (cbp != 0) try w.se(0); // mb_qp_delta
}

fn writeInterMacroblock(
    self: *Encoder,
    slice: *Slice,
    mb_x: usize,
    mb_y: usize,
    source: *const [256]i32,
    vector: Vector,
    prediction: MotionPrediction,
) !void {
    @setRuntimeSafety(runtime_safety);
    const qp = self.qp;
    const index = mb_y * self.mb_width + mb_x;
    var luma_prediction: [256]u8 = undefined;
    self.predictLumaInter(mb_x, mb_y, vector, &luma_prediction);
    var blocks: [16]Block = undefined;
    var cbp_luma: u32 = 0;
    for (0..4) |block_y| for (0..4) |block_x| {
        const block = &blocks[block_y * 4 + block_x];
        var any = false;
        for (0..4) |y| for (0..4) |x| {
            const sample = (block_y * 4 + y) * 16 + block_x * 4 + x;
            block[y * 4 + x] = source[sample] - luma_prediction[sample];
            any = any or block[y * 4 + x] != 0;
        };
        if (!any) continue;
        transform.forward(block);
        if (transform.quantizeBlock(block, qp, cavlc.maximum_level, false)) {
            cbp_luma |= @as(u32, 1) << @intCast((block_y / 2) * 2 + block_x / 2);
        }
    };
    var chroma_prediction: [2][64]i32 = undefined;
    for (0..2) |component| self.predictChromaInter(component, mb_x, mb_y, vector, &chroma_prediction[component]);
    const chroma_source = self.loadChroma(mb_x, mb_y);
    const chroma = transformChroma(&chroma_source, &chroma_prediction, transform.chromaQp(qp), false);
    const cbp = cbp_luma | chroma.cbp << 4;

    self.motion[index] = .{ .vector = vector, .inter = true };
    // Whatever is left after coding at this QP is below what it can express.
    self.next_coded_qp[index] = qp;
    if (cbp == 0 and vector.eql(prediction.skip)) {
        self.skipMacroblock(slice, mb_x, mb_y, vector);
    } else {
        try writeInterHeader(slice, vector, prediction.vector, cbp);
        const luma_stride = self.mb_width * 4;
        var scan: [16]i32 = undefined;
        for (luma_block_position, 0..) |position, block_index| {
            const bx = mb_x * 4 + position[0];
            const by = mb_y * 4 + position[1];
            var count: u8 = 0;
            if (cbp_luma & (@as(u32, 1) << @intCast(block_index / 4)) != 0) {
                const block = &blocks[position[1] * 4 + position[0]];
                for (0..16) |i| scan[i] = block[transform.zigzag[i]];
                count = try cavlc.writeBlock(
                    &slice.writer,
                    &scan,
                    predictedCount(self.luma_counts, luma_stride, bx, by, slice.first_row * 4),
                );
            }
            self.luma_counts[by * luma_stride + bx] = count;
        }
        try self.writeChroma(slice, &chroma, mb_x, mb_y);
        slice.stats.inter += 1;
    }

    if (cbp == 0 and vector.isZero()) {
        self.keepReference(mb_x, mb_y);
        return;
    }
    // Reconstruct exactly as a decoder will (8.5.12, 8.5.14).
    const plane = self.current[0];
    for (0..4) |block_y| for (0..4) |block_x| {
        var block = blocks[block_y * 4 + block_x];
        const coded = cbp_luma & (@as(u32, 1) << @intCast((block_y / 2) * 2 + block_x / 2)) != 0;
        if (coded) {
            transform.scaleBlock(&block, qp);
            transform.inverse(&block);
        }
        for (0..4) |y| for (0..4) |x| {
            const sample = (block_y * 4 + y) * 16 + block_x * 4 + x;
            const residual = if (coded) block[y * 4 + x] else 0;
            plane.data[(mb_y * 16 + block_y * 4 + y) * plane.stride + mb_x * 16 + block_x * 4 + x] =
                @intCast(clip(@as(i32, luma_prediction[sample]) + residual));
        };
    };
    self.reconstructChroma(&chroma, &chroma_prediction, mb_x, mb_y);
    self.modified[index] = true;
}

/// Intra16x16PredMode and intra_chroma_pred_mode values.
const LumaMode = enum(u2) { vertical = 0, horizontal = 1, dc = 2, plane = 3 };
const ChromaMode = enum(u2) { dc = 0, horizontal = 1, vertical = 2, plane = 3 };

/// Reconstructed samples around a block, read before it is overwritten.
fn Neighbors(comptime size: usize) type {
    return struct {
        top: [size]i32 = undefined,
        left: [size]i32 = undefined,
        top_left: i32 = 0,
        has_top: bool,
        has_left: bool,

        const Self = @This();

        fn read(plane: Plane, x0: usize, y0: usize, has_top: bool, has_left: bool) Self {
            @setRuntimeSafety(runtime_safety);
            var self: Self = .{ .has_top = has_top, .has_left = has_left };
            if (self.has_top) {
                for (0..size) |i| self.top[i] = plane.data[(y0 - 1) * plane.stride + x0 + i];
            }
            if (self.has_left) {
                for (0..size) |i| self.left[i] = plane.data[(y0 + i) * plane.stride + x0 - 1];
            }
            if (self.has_top and self.has_left) self.top_left = plane.data[(y0 - 1) * plane.stride + x0 - 1];
            return self;
        }
    };
}

fn clip(value: i32) i32 {
    return std.math.clamp(value, 0, 255);
}

/// 8.3.3: Intra16x16 luma prediction. Returns false when the mode's
/// neighbors are unavailable.
fn predictLuma(neighbors: Neighbors(16), mode: LumaMode, prediction: *[256]i32) bool {
    @setRuntimeSafety(runtime_safety);
    switch (mode) {
        .vertical => {
            if (!neighbors.has_top) return false;
            for (0..16) |y| @memcpy(prediction[y * 16 ..][0..16], &neighbors.top);
        },
        .horizontal => {
            if (!neighbors.has_left) return false;
            for (0..16) |y| @memset(prediction[y * 16 ..][0..16], neighbors.left[y]);
        },
        .dc => {
            var sum: i32 = 0;
            for (neighbors.top) |sample| sum += if (neighbors.has_top) sample else 0;
            for (neighbors.left) |sample| sum += if (neighbors.has_left) sample else 0;
            const value: i32 = if (neighbors.has_top and neighbors.has_left)
                (sum + 16) >> 5
            else if (neighbors.has_top or neighbors.has_left)
                (sum + 8) >> 4
            else
                128;
            @memset(prediction, value);
        },
        .plane => {
            if (!neighbors.has_top or !neighbors.has_left) return false;
            var h: i32 = 0;
            var v: i32 = 0;
            for (0..8) |i| {
                const weight: i32 = @intCast(i + 1);
                const top_before = if (i == 7) neighbors.top_left else neighbors.top[6 - i];
                const left_before = if (i == 7) neighbors.top_left else neighbors.left[6 - i];
                h += weight * (neighbors.top[8 + i] - top_before);
                v += weight * (neighbors.left[8 + i] - left_before);
            }
            const a = 16 * (neighbors.left[15] + neighbors.top[15]);
            const b = (5 * h + 32) >> 6;
            const c = (5 * v + 32) >> 6;
            for (0..16) |y| for (0..16) |x| {
                const xi: i32 = @intCast(x);
                const yi: i32 = @intCast(y);
                prediction[y * 16 + x] = clip((a + b * (xi - 7) + c * (yi - 7) + 16) >> 5);
            };
        },
    }
    return true;
}

/// 8.3.4: 4:2:0 chroma prediction for one 8x8 component.
fn predictChroma(neighbors: Neighbors(8), mode: ChromaMode, prediction: *[64]i32) bool {
    @setRuntimeSafety(runtime_safety);
    switch (mode) {
        .dc => {
            for (0..2) |block_y| for (0..2) |block_x| {
                var top_sum: i32 = 0;
                var left_sum: i32 = 0;
                for (0..4) |i| {
                    if (neighbors.has_top) top_sum += neighbors.top[block_x * 4 + i];
                    if (neighbors.has_left) left_sum += neighbors.left[block_y * 4 + i];
                }
                const top = neighbors.has_top;
                const left = neighbors.has_left;
                const value: i32 = if (block_x == block_y) // blocks (0,0) and (1,1)
                    (if (top and left) (top_sum + left_sum + 4) >> 3 else if (left) (left_sum + 2) >> 2 else if (top) (top_sum + 2) >> 2 else 128)
                else if (block_y == 0) // top-right block prefers the top edge
                    (if (top) (top_sum + 2) >> 2 else if (left) (left_sum + 2) >> 2 else 128)
                else // bottom-left block prefers the left edge
                    (if (left) (left_sum + 2) >> 2 else if (top) (top_sum + 2) >> 2 else 128);
                for (0..4) |y| @memset(prediction[(block_y * 4 + y) * 8 + block_x * 4 ..][0..4], value);
            };
        },
        .horizontal => {
            if (!neighbors.has_left) return false;
            for (0..8) |y| @memset(prediction[y * 8 ..][0..8], neighbors.left[y]);
        },
        .vertical => {
            if (!neighbors.has_top) return false;
            for (0..8) |y| @memcpy(prediction[y * 8 ..][0..8], &neighbors.top);
        },
        .plane => {
            if (!neighbors.has_top or !neighbors.has_left) return false;
            var h: i32 = 0;
            var v: i32 = 0;
            for (0..4) |i| {
                const weight: i32 = @intCast(i + 1);
                const top_before = if (i == 3) neighbors.top_left else neighbors.top[2 - i];
                const left_before = if (i == 3) neighbors.top_left else neighbors.left[2 - i];
                h += weight * (neighbors.top[4 + i] - top_before);
                v += weight * (neighbors.left[4 + i] - left_before);
            }
            const a = 16 * (neighbors.left[7] + neighbors.top[7]);
            const b = (34 * h + 32) >> 6;
            const c = (34 * v + 32) >> 6;
            for (0..8) |y| for (0..8) |x| {
                const xi: i32 = @intCast(x);
                const yi: i32 = @intCast(y);
                prediction[y * 8 + x] = clip((a + b * (xi - 3) + c * (yi - 3) + 16) >> 5);
            };
        },
    }
    return true;
}

fn sad(source: []const i32, prediction: []const i32) u32 {
    @setRuntimeSafety(runtime_safety);
    var total: u32 = 0;
    for (source, prediction) |a, b| total += @abs(a - b);
    return total;
}

/// Raster position (in 4x4 blocks) of each luma4x4BlkIdx (6.4.3).
const luma_block_position = [16][2]u8{
    .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 2, 0 }, .{ 3, 0 }, .{ 2, 1 }, .{ 3, 1 },
    .{ 0, 2 }, .{ 1, 2 }, .{ 0, 3 }, .{ 1, 3 }, .{ 2, 2 }, .{ 3, 2 }, .{ 2, 3 }, .{ 3, 3 },
};

/// nC from the left and upper neighbors' TotalCoeff (9.2.1). Blocks above
/// `first_row`, the slice's first row of blocks, are in another slice.
fn predictedCount(counts: []const u8, stride: usize, x: usize, y: usize, first_row: usize) i32 {
    @setRuntimeSafety(runtime_safety);
    const has_left = x > 0;
    const has_top = y > first_row;
    const left: i32 = if (has_left) counts[y * stride + x - 1] else 0;
    const top: i32 = if (has_top) counts[(y - 1) * stride + x] else 0;
    if (has_left and has_top) return (left + top + 1) >> 1;
    if (has_left) return left;
    if (has_top) return top;
    return 0;
}

const IntraChoice = struct {
    mode: LumaMode,
    cost: u32,
};

fn lumaNeighbors(self: *const Encoder, slice: *const Slice, mb_x: usize, mb_y: usize) Neighbors(16) {
    return Neighbors(16).read(self.current[0], mb_x * 16, mb_y * 16, mb_y > slice.first_row, mb_x > 0);
}

/// The cheapest available Intra16x16 luma prediction by SAD.
fn chooseIntraLuma(self: *const Encoder, slice: *const Slice, mb_x: usize, mb_y: usize, source: *const [256]i32) IntraChoice {
    @setRuntimeSafety(runtime_safety);
    const neighbors = self.lumaNeighbors(slice, mb_x, mb_y);
    var choice: IntraChoice = .{ .mode = .dc, .cost = std.math.maxInt(u32) };
    var prediction: [256]i32 = undefined;
    for ([_]LumaMode{ .dc, .vertical, .horizontal, .plane }) |mode| {
        if (!predictLuma(neighbors, mode, &prediction)) continue;
        const cost = sad(source, &prediction);
        if (cost < choice.cost) choice = .{ .mode = mode, .cost = cost };
    }
    return choice;
}

const ChromaResidual = struct {
    blocks: [2][4]Block,
    dc: [2][4]i32,
    /// CodedBlockPatternChroma: 0 for nothing, 1 for DC only, 2 for AC too.
    cbp: u32,
};

fn transformChroma(source: *const [2][64]i32, prediction: *const [2][64]i32, qp: u8, intra: bool) ChromaResidual {
    @setRuntimeSafety(runtime_safety);
    var residual: ChromaResidual = undefined;
    var any_dc = false;
    var any_ac = false;
    for (0..2) |component| {
        for (0..4) |block_index| {
            const block = &residual.blocks[component][block_index];
            const bx = block_index % 2;
            const by = block_index / 2;
            var any = false;
            for (0..4) |y| for (0..4) |x| {
                const index = (by * 4 + y) * 8 + bx * 4 + x;
                block[y * 4 + x] = source[component][index] - prediction[component][index];
                any = any or block[y * 4 + x] != 0;
            };
            residual.dc[component][block_index] = 0;
            if (!any) continue;
            transform.forward(block);
            residual.dc[component][block_index] = block[0];
            any_ac = transform.quantizeAc(block, qp, cavlc.maximum_level, intra) or any_ac;
        }
        transform.hadamard2x2(&residual.dc[component]);
        transform.quantizeChromaDc(&residual.dc[component], qp, cavlc.maximum_level, intra);
        for (residual.dc[component]) |level| any_dc = any_dc or level != 0;
    }
    residual.cbp = if (any_ac) 2 else if (any_dc) 1 else 0;
    return residual;
}

fn writeChroma(self: *Encoder, slice: *Slice, residual: *const ChromaResidual, mb_x: usize, mb_y: usize) !void {
    @setRuntimeSafety(runtime_safety);
    if (residual.cbp != 0) {
        for (residual.dc) |levels| _ = try cavlc.writeBlock(&slice.writer, &levels, cavlc.chroma_dc_nc);
    }
    const chroma_stride = self.mb_width * 2;
    var scan: [15]i32 = undefined;
    for (0..2) |component| {
        for (0..4) |block_index| {
            const bx = mb_x * 2 + block_index % 2;
            const by = mb_y * 2 + block_index / 2;
            var count: u8 = 0;
            if (residual.cbp == 2) {
                const block = &residual.blocks[component][block_index];
                for (1..16) |i| scan[i - 1] = block[transform.zigzag[i]];
                count = try cavlc.writeBlock(
                    &slice.writer,
                    &scan,
                    predictedCount(self.chroma_counts[component], chroma_stride, bx, by, slice.first_row * 2),
                );
            }
            self.chroma_counts[component][by * chroma_stride + bx] = count;
        }
    }
}

/// 8.5.11 for both components of a macroblock.
fn reconstructChroma(self: *Encoder, residual: *const ChromaResidual, prediction: *const [2][64]i32, mb_x: usize, mb_y: usize) void {
    @setRuntimeSafety(runtime_safety);
    const qp = transform.chromaQp(self.qp);
    for (0..2) |component| {
        const plane = self.current[component + 1];
        if (residual.cbp == 0) {
            for (0..8) |y| for (0..8) |x| {
                plane.data[(mb_y * 8 + y) * plane.stride + mb_x * 8 + x] = @intCast(prediction[component][y * 8 + x]);
            };
            continue;
        }
        var dc_values = residual.dc[component];
        if (residual.cbp == 0) dc_values = @splat(0);
        transform.scaleChromaDc(&dc_values, qp);
        for (0..4) |block_index| {
            var block = residual.blocks[component][block_index];
            if (residual.cbp != 2) block = @splat(0);
            transform.scaleAc(&block, qp);
            block[0] = dc_values[block_index];
            transform.inverse(&block);
            const bx = block_index % 2;
            const by = block_index / 2;
            for (0..4) |y| for (0..4) |x| {
                const index = (by * 4 + y) * 8 + bx * 4 + x;
                plane.data[(mb_y * 8 + by * 4 + y) * plane.stride + mb_x * 8 + bx * 4 + x] =
                    @intCast(clip(prediction[component][index] + block[y * 4 + x]));
            };
        }
    }
}

fn writeIntraMacroblock(
    self: *Encoder,
    slice: *Slice,
    mb_x: usize,
    mb_y: usize,
    in_p_slice: bool,
    source: *const [256]i32,
    intra: *const IntraChoice,
) !void {
    @setRuntimeSafety(runtime_safety);
    const qp = self.qp;
    const chroma_qp = transform.chromaQp(qp);
    const maximum = cavlc.maximum_level;

    var prediction: [256]i32 = undefined;
    _ = predictLuma(self.lumaNeighbors(slice, mb_x, mb_y), intra.mode, &prediction);

    // Transform each 4x4 residual; gather DC terms by block position.
    var blocks: [16]Block = undefined;
    var dc: Block = undefined;
    for (0..4) |block_y| for (0..4) |block_x| {
        const block = &blocks[block_y * 4 + block_x];
        for (0..4) |y| for (0..4) |x| {
            const index = (block_y * 4 + y) * 16 + block_x * 4 + x;
            block[y * 4 + x] = source[index] - prediction[index];
        };
        transform.forward(block);
        dc[block_y * 4 + block_x] = block[0];
    };
    transform.hadamard(&dc);
    transform.quantizeLumaDc(&dc, qp, maximum);
    var any_ac = false;
    for (&blocks) |*block| any_ac = transform.quantizeAc(block, qp, maximum, true) or any_ac;

    // Chroma: one prediction mode for both components.
    const chroma_source = self.loadChroma(mb_x, mb_y);
    var chroma_neighbors: [2]Neighbors(8) = undefined;
    for (0..2) |component| {
        chroma_neighbors[component] = Neighbors(8).read(
            self.current[component + 1],
            mb_x * 8,
            mb_y * 8,
            mb_y > slice.first_row,
            mb_x > 0,
        );
    }
    var chroma_mode: ChromaMode = .dc;
    var chroma_prediction: [2][64]i32 = undefined;
    var best_cost: u32 = std.math.maxInt(u32);
    for ([_]ChromaMode{ .dc, .horizontal, .vertical, .plane }) |mode| {
        var cost: u32 = 0;
        var available = true;
        for (0..2) |component| {
            available = predictChroma(chroma_neighbors[component], mode, &chroma_prediction[component]);
            if (!available) break;
            cost += sad(&chroma_source[component], &chroma_prediction[component]);
        }
        if (available and cost < best_cost) {
            best_cost = cost;
            chroma_mode = mode;
        }
    }
    for (0..2) |component| _ = predictChroma(chroma_neighbors[component], chroma_mode, &chroma_prediction[component]);
    const chroma = transformChroma(&chroma_source, &chroma_prediction, chroma_qp, true);
    const cbp_luma: u32 = if (any_ac) 15 else 0;

    // Macroblock layer (7.3.5) for Intra16x16.
    const w = &slice.writer;
    if (in_p_slice) {
        try w.ue(slice.skip_run);
        slice.skip_run = 0;
    }
    const mb_type = (if (in_p_slice) @as(u32, 5) else 0) + 1 + @intFromEnum(intra.mode) +
        4 * chroma.cbp + (if (cbp_luma == 15) @as(u32, 12) else 0);
    try w.ue(mb_type);
    try w.ue(@intFromEnum(chroma_mode));
    try w.se(0); // mb_qp_delta

    const luma_stride = self.mb_width * 4;
    const first_block_row = slice.first_row * 4;
    var scan: [16]i32 = undefined;
    for (0..16) |i| scan[i] = dc[transform.zigzag[i]];
    _ = try cavlc.writeBlock(w, &scan, predictedCount(self.luma_counts, luma_stride, mb_x * 4, mb_y * 4, first_block_row));
    for (luma_block_position) |position| {
        const bx = mb_x * 4 + position[0];
        const by = mb_y * 4 + position[1];
        var count: u8 = 0;
        if (cbp_luma == 15) {
            const block = &blocks[position[1] * 4 + position[0]];
            for (1..16) |i| scan[i - 1] = block[transform.zigzag[i]];
            count = try cavlc.writeBlock(w, scan[0..15], predictedCount(self.luma_counts, luma_stride, bx, by, first_block_row));
        }
        self.luma_counts[by * luma_stride + bx] = count;
    }
    try self.writeChroma(slice, &chroma, mb_x, mb_y);

    // Reconstruct exactly as a decoder will (8.5.2, 8.5.10, 8.5.12).
    const luma_plane = self.current[0];
    transform.scaleLumaDc(&dc, qp);
    for (0..4) |block_y| for (0..4) |block_x| {
        var block = blocks[block_y * 4 + block_x];
        if (cbp_luma == 0) {
            // 8.5.12.2 spreads a lone DC term evenly.
            block = @splat((dc[block_y * 4 + block_x] + 32) >> 6);
        } else {
            transform.scaleAc(&block, qp);
            block[0] = dc[block_y * 4 + block_x];
            transform.inverse(&block);
        }
        for (0..4) |y| for (0..4) |x| {
            const index = (block_y * 4 + y) * 16 + block_x * 4 + x;
            luma_plane.data[(mb_y * 16 + block_y * 4 + y) * luma_plane.stride + mb_x * 16 + block_x * 4 + x] =
                @intCast(clip(prediction[index] + block[y * 4 + x]));
        };
    };
    self.reconstructChroma(&chroma, &chroma_prediction, mb_x, mb_y);
    const index = mb_y * self.mb_width + mb_x;
    self.motion[index] = .{};
    self.modified[index] = true;
    self.next_coded_qp[index] = qp;
    slice.stats.intra += 1;
}

test "unchanged pictures become tiny all-skip P frames after the keyframe" {
    var encoder = try Encoder.init(std.testing.allocator, .{ .width = 64, .height = 48, .slices = 1 });
    defer encoder.deinit();
    var luma: [64 * 48]u8 = undefined;
    for (&luma, 0..) |*sample, index| sample.* = @truncate(index * 7);
    const chroma: [32 * 24]u8 = @splat(128);
    const picture: Picture = .{ .y = &luma, .u = &chroma, .v = &chroma, .y_stride = 64, .chroma_stride = 32 };
    const keyframe = try encoder.encode(picture, null, false);
    // SPS, PPS, then an IDR slice.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x67 }, keyframe[0..5]);
    try std.testing.expect(std.mem.indexOf(u8, keyframe, &.{ 0, 0, 0, 1, 0x65 }) != null);
    const unchanged = try encoder.encode(picture, .{ .first = 0, .end = 48 }, false);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x61 }, unchanged[0..5]);
    try std.testing.expect(unchanged.len < 12);
    luma[0] +%= 50;
    const changed = try encoder.encode(picture, .{ .first = 0, .end = 2 }, false);
    try std.testing.expect(changed.len > unchanged.len);
}

test "scrolled content is predicted from the previous picture" {
    const width = 128;
    const height = 128;
    var encoder = try Encoder.init(std.testing.allocator, .{ .width = width, .height = height, .slices = 1 });
    defer encoder.deinit();
    var page: [width * (height + 64)]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    for (&page) |*sample| sample.* = prng.random().int(u8);
    const chroma: [width * height / 4]u8 = @splat(128);
    var offset: usize = 0;
    for (0..3) |_| {
        const picture: Picture = .{
            .y = page[offset * width ..][0 .. width * height],
            .u = &chroma,
            .v = &chroma,
            .y_stride = width,
            .chroma_stride = width / 2,
        };
        _ = try encoder.encode(picture, null, false);
        offset += 24;
    }
    // Noise cannot be predicted spatially, so only matching the scroll keeps
    // macroblocks out of intra; just the rows scrolled into view need it.
    try std.testing.expect(encoder.stats.intra <= 2 * encoder.mb_width);
    try std.testing.expect(encoder.stats.skip > encoder.mb_width * encoder.mb_height / 4);
}

test "rate control holds noisy pictures to the bitrate" {
    const width = 160;
    const height = 96;
    const config: Config = .{ .width = width, .height = height, .qp = 10, .bitrate_kbps = 1000, .fps = 30, .slices = 1 };
    var encoder = try Encoder.init(std.testing.allocator, config);
    defer encoder.deinit();
    var luma: [width * height]u8 = undefined;
    var chroma: [width * height / 4]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(2);
    const frames = 20;
    var bits: usize = 0;
    for (0..frames) |_| {
        prng.random().bytes(&luma);
        prng.random().bytes(&chroma);
        const picture: Picture = .{ .y = &luma, .u = &chroma, .v = &chroma, .y_stride = width, .chroma_stride = width / 2 };
        bits += (try encoder.encode(picture, null, false)).len * 8;
    }
    // The bucket starts with one second of room and gains one picture's share
    // per picture; parameter sets and the first guess may overshoot a little.
    try std.testing.expect(bits <= 1_000_000 + frames * 1_000_000 / 30 + 2_000);
    try std.testing.expect(bits >= frames * 1_000_000 / 30 / 2);
    try std.testing.expect(encoder.qp > 30 and encoder.qp < 51);
}

test "idle refinement sharpens a picture that rate control coded coarsely" {
    const width = 128;
    const height = 96;
    var encoder = try Encoder.init(std.testing.allocator, .{
        .width = width,
        .height = height,
        .qp = 20,
        .bitrate_kbps = 30,
        .fps = 30,
        .slices = 2,
    });
    defer encoder.deinit();
    var luma: [width * height]u8 = undefined;
    for (&luma, 0..) |*sample, index| {
        sample.* = if ((index % width / 3 + index / width / 5) % 2 == 0) 40 else 210;
    }
    const chroma: [width * height / 4]u8 = @splat(128);
    const picture: Picture = .{ .y = &luma, .u = &chroma, .v = &chroma, .y_stride = width, .chroma_stride = width / 2 };
    _ = try encoder.encode(picture, null, false);
    const coarse = lumaError(&encoder, &luma, width, height);
    try std.testing.expect(encoder.refinementPending());
    var intervals: usize = 0;
    while (encoder.refinementPending() and intervals < 600) : (intervals += 1) _ = try encoder.refine();
    try std.testing.expect(!encoder.refinementPending());
    // At least 6 dB closer to the source.
    try std.testing.expect(lumaError(&encoder, &luma, width, height) * 4 < coarse);
}

test "refinement never makes a GOP longer than max_gop_length" {
    const width = 128;
    const height = 96;
    var encoder = try Encoder.init(std.testing.allocator, .{
        .width = width,
        .height = height,
        .qp = 20,
        .bitrate_kbps = 30,
        .fps = 30,
        .slices = 1,
        .max_gop_length = 4,
    });
    defer encoder.deinit();
    var luma: [width * height]u8 = undefined;
    for (&luma, 0..) |*sample, index| sample.* = @truncate(index *% 37);
    const chroma: [width * height / 4]u8 = @splat(128);
    const picture: Picture = .{ .y = &luma, .u = &chroma, .v = &chroma, .y_stride = width, .chroma_stride = width / 2 };
    _ = try encoder.encode(picture, null, false);
    var pictures: usize = 1;
    for (0..100) |_| {
        if (try encoder.refine()) |_| pictures += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), pictures);
    try std.testing.expect(!encoder.refinementPending());
    // The next picture starts a new GOP, after which refinement resumes.
    luma[0] +%= 1;
    const next = try encoder.encode(picture, null, false);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0x67 }, next[0..5]);
    try std.testing.expect(encoder.refinementPending());
}

fn lumaError(encoder: *const Encoder, source: []const u8, width: usize, height: usize) u64 {
    const plane = encoder.decoded()[0];
    var total: u64 = 0;
    for (0..height) |y| for (0..width) |x| {
        const difference = @as(i64, plane.data[y * plane.stride + x]) - source[y * width + x];
        total += @intCast(difference * difference);
    };
    return total;
}

test {
    _ = BitWriter;
    _ = cavlc;
    _ = transform;
}
