//! Runs the software video encoder without blocking Wayland capture or input.
//!
//! Capture owns a fixed three-slot pool: one frame may be encoding, one may
//! wait, and the third keeps allocation independent of the worker. A new
//! capture replaces the waiting frame rather than building latency. The worker
//! converts each frame to I420, encodes it with Waymote's H.264 encoder, asks
//! the main loop to publish correlation metadata, and only then sends the
//! access unit, so the RTP receiver always finds metadata for a complete frame.

const VideoEncoder = @This();

const std = @import("std");
const ColorConvert = @import("ColorConvert");
const H264Encoder = @import("h264");

const linux = std.os.linux;
const log = std.log.scoped(.video_encoder);
const slot_count = 3;
const initial_restart_delay_ms = 1000;
const maximum_restart_delay_ms = 30_000;
const stable_run_ms = 30_000;
/// The gateway's bootstrap buffer holds at most 240 frames of a GOP.
const max_gop_length = 240;
/// How long captures must pause before the encoder re-sends the last picture
/// to sharpen what rate control left coarse.
const refine_idle_ns = 100 * std.time.ns_per_ms;
const rtp_payload_type = 96;
const rtp_header_size = 12;
/// Matches the `pkt_size=60000` FFmpeg used; loopback UDP carries it whole.
const rtp_packet_size = 60_000;
const rtp_clock_rate = 90_000;

/// The finest QP rate control uses; it codes coarser only to stay within the
/// bitrate.
const finest_qp = 24;

pub const Options = struct {
    rtp_port: ?u16,
};

/// A half-open range of captured rows.
pub const Rows = struct {
    first: u32,
    end: u32,

    fn merge(self: Rows, other: Rows) Rows {
        return .{ .first = @min(self.first, other.first), .end = @max(self.end, other.end) };
    }
};

pub const Metadata = struct {
    generation: u32,
    raw_width: u32,
    raw_height: u32,
    encoded_width: u16,
    encoded_height: u16,
    capture_nanos: u64,
    sequence: u64,
    input_sequence: u32,
    fps: u32,
    bitrate_kbps: u32,
    /// Rows that changed since the previous capture.
    damage: Rows,

    fn config(self: Metadata) Config {
        return .{
            .raw_width = self.raw_width,
            .raw_height = self.raw_height,
            .encoded_width = self.encoded_width,
            .encoded_height = self.encoded_height,
            .fps = self.fps,
            .bitrate_kbps = self.bitrate_kbps,
        };
    }
};

pub const Restart = struct {
    generation: u32,
    increment_generation: bool,
};

pub const Notification = union(enum) {
    restart: Restart,
    metadata: Metadata,
};

pub const Completion = struct {
    generation: u32,
    encode: bool,
};

pub const SubmitResult = enum {
    queued,
    replaced,
};

const Config = struct {
    raw_width: u32,
    raw_height: u32,
    encoded_width: u16,
    encoded_height: u16,
    fps: u32,
    bitrate_kbps: u32,
};

const SlotState = enum { free, pending, encoding };

const Slot = struct {
    data: ?[]u8 = null,
    metadata: Metadata = undefined,
    state: SlotState = .free,
};

const PendingFrame = struct {
    slot_index: usize,
    data: []const u8,
    metadata: Metadata,
};

/// One encoder session. A configuration change replaces the whole session and
/// its RTP SSRC, which tells the gateway the media timeline restarted.
///
/// Unchanged macroblocks are skipped, changed ones are motion-compensated
/// (including scrolls) or intra coded, and macroblocks that rate control left
/// coarse are refined once the screen stops changing.
const Encoder = struct {
    h264: H264Encoder,
    planes: []u8,
    config: Config,
    generation: u32,
    started_at_ms: u64,
    ssrc: u32,
    rtp_sequence: u16,
    frame_index: u64 = 0,
    /// False until the I420 planes hold a whole frame; later frames convert
    /// only their damaged rows.
    planes_complete: bool = false,

    fn open(
        allocator: std.mem.Allocator,
        config: Config,
        generation: u32,
        ssrc: u32,
    ) !Encoder {
        const width: usize = config.encoded_width;
        const height: usize = config.encoded_height;
        const planes = try allocator.alloc(u8, width * height * 3 / 2);
        errdefer allocator.free(planes);
        const h264 = try H264Encoder.init(allocator, .{
            .width = config.encoded_width,
            .height = config.encoded_height,
            .qp = finest_qp,
            .bitrate_kbps = config.bitrate_kbps,
            .fps = config.fps,
            .keyframe_interval = config.fps,
            .max_gop_length = max_gop_length,
        });
        log.info("capturing {}x{} at {d} FPS and {d} kbps", .{
            config.raw_width,
            config.raw_height,
            config.fps,
            config.bitrate_kbps,
        });
        return .{
            .h264 = h264,
            .planes = planes,
            .config = config,
            .generation = generation,
            .started_at_ms = monotonicMilliseconds(),
            .ssrc = ssrc,
            .rtp_sequence = @truncate(ssrc *% 2654435761),
        };
    }

    fn close(self: *Encoder, allocator: std.mem.Allocator) void {
        self.h264.deinit();
        allocator.free(self.planes);
    }

    /// Encodes one captured frame and returns its Annex-B access unit, which
    /// stays valid until the next call.
    fn encode(self: *Encoder, data: []const u8, damage: Rows) ![]const u8 {
        const width: usize = self.config.encoded_width;
        const height: usize = self.config.encoded_height;
        const raw_width: usize = self.config.raw_width;
        const raw_height: usize = self.config.raw_height;
        if (data.len < raw_width * raw_height * 4) return error.ShortVideoFrame;
        const rows: Rows = if (self.planes_complete and width == raw_width and height == raw_height) .{
            .first = damage.first & ~@as(u32, 1),
            .end = @min(@as(u32, @intCast(height)), (damage.end + 1) & ~@as(u32, 1)),
        } else .{ .first = 0, .end = @intCast(height) };
        ColorConvert.convert(
            .{ .data = data, .width = raw_width, .height = raw_height, .stride = raw_width * 4 },
            width,
            height,
            .{
                .y = self.planes[0 .. width * height],
                .u = self.planes[width * height ..][0 .. width * height / 4],
                .v = self.planes[width * height * 5 / 4 ..][0 .. width * height / 4],
                .y_stride = width,
                .chroma_stride = width / 2,
            },
            rows.first,
            rows.end,
        );
        self.planes_complete = true;
        return self.encodePlanes(rows);
    }

    /// Encodes the converted planes, of which only `rows` changed.
    fn encodePlanes(self: *Encoder, rows: Rows) ![]const u8 {
        const width: usize = self.config.encoded_width;
        const height: usize = self.config.encoded_height;
        return self.h264.encode(.{
            .y = self.planes[0 .. width * height],
            .u = self.planes[width * height ..][0 .. width * height / 4],
            .v = self.planes[width * height * 5 / 4 ..][0 .. width * height / 4],
            .y_stride = width,
            .chroma_stride = width / 2,
        }, .{ .first = rows.first, .end = rows.end }, false);
    }

    /// Re-codes macroblocks that rate control left coarse at a finer QP while
    /// nothing changes on screen. Null means there is nothing to send this
    /// interval.
    fn refine(self: *Encoder) !?[]const u8 {
        std.debug.assert(self.planes_complete);
        return self.h264.refine();
    }

    fn rtpTimestamp(self: *const Encoder) u32 {
        return @truncate(self.frame_index * rtp_clock_rate / self.config.fps);
    }
};

allocator: std.mem.Allocator,
io: std.Io,
options: Options,
mutex: std.Io.Mutex = .init,
completion_condition: std.Io.Condition = .init,
slots: [slot_count]Slot = @splat(.{}),
pending_slot: ?usize = null,
notification: ?Notification = null,
completion: Completion = .{ .generation = 0, .encode = false },
stopping: bool = false,
work_event_fd: std.posix.fd_t,
notification_event_fd: std.posix.fd_t,
thread: ?std.Thread = null,

pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !VideoEncoder {
    const work_event_fd = try createEventFd();
    errdefer _ = linux.close(work_event_fd);
    const notification_event_fd = try createEventFd();
    return .{
        .allocator = allocator,
        .io = io,
        .options = options,
        .work_event_fd = work_event_fd,
        .notification_event_fd = notification_event_fd,
    };
}

pub fn start(self: *VideoEncoder) !void {
    std.debug.assert(self.thread == null);
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn deinit(self: *VideoEncoder) void {
    if (self.thread) |thread| {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.completion_condition.broadcast(self.io);
        self.mutex.unlock(self.io);
        signalEvent(self.work_event_fd) catch {};
        thread.join();
    }
    for (&self.slots) |*slot| {
        if (slot.data) |data| self.allocator.free(data);
    }
    _ = linux.close(self.work_event_fd);
    _ = linux.close(self.notification_event_fd);
    self.* = undefined;
}

pub fn submit(self: *VideoEncoder, data: []const u8, metadata: Metadata) !SubmitResult {
    if (data.len == 0) return error.EmptyVideoFrame;
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.stopping) return error.VideoEncoderStopped;

    const replacing = self.pending_slot != null;
    const slot_index = self.pending_slot orelse index: {
        for (&self.slots, 0..) |slot, index| {
            if (slot.state == .free) break :index index;
        }
        return error.VideoFramePoolExhausted;
    };
    const slot = &self.slots[slot_index];
    if (slot.data == null or slot.data.?.len != data.len) {
        if (slot.data) |buffer| self.allocator.free(buffer);
        slot.data = try self.allocator.alloc(u8, data.len);
    }
    @memcpy(slot.data.?, data);
    // A replaced frame is never encoded, so its changes carry forward.
    const damage = if (replacing) slot.metadata.damage.merge(metadata.damage) else metadata.damage;
    slot.metadata = metadata;
    slot.metadata.damage = damage;
    slot.state = .pending;
    self.pending_slot = slot_index;
    try signalEvent(self.work_event_fd);
    return if (replacing) .replaced else .queued;
}

pub fn notificationFd(self: *const VideoEncoder) std.posix.fd_t {
    return self.notification_event_fd;
}

pub fn takeNotification(self: *VideoEncoder) !?Notification {
    try drainEvent(self.notification_event_fd);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.notification;
}

pub fn completeNotification(self: *VideoEncoder, completion: Completion) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.notification == null) return;
    self.completion = completion;
    self.notification = null;
    self.completion_condition.signal(self.io);
}

fn run(self: *VideoEncoder) void {
    self.runInner() catch |err| log.err("video encoder worker stopped: {t}", .{err});
}

fn runInner(self: *VideoEncoder) !void {
    const socket = if (self.options.rtp_port) |port| try openRtpSocket(port) else null;
    defer if (socket) |fd| {
        _ = linux.close(fd);
    };
    var encoder: ?Encoder = null;
    defer if (encoder) |*value| value.close(self.allocator);
    var ever_started = false;
    var last_generation: u32 = 0;
    var reset_prepared = false;
    var next_ssrc: u32 = 1;
    var restart_delay_ms: u32 = initial_restart_delay_ms;
    var retry_at_ms: u64 = 0;
    var next_encode_nanos: u64 = 0;
    var last_metadata: ?Metadata = null;
    var last_capture_nanos: u64 = 0;

    while (!self.isStopping()) {
        const now = monotonicMilliseconds();
        if (encoder == null and retry_at_ms > now) {
            try self.waitForEvents(@intCast(@min(retry_at_ms - now, std.math.maxInt(i32))));
            continue;
        }
        // Encode no faster than the configured frame rate, as FFmpeg's `-re`
        // did. Captures that arrive meanwhile replace the waiting frame.
        const now_nanos = monotonicNanoseconds();
        if (encoder != null and now_nanos < next_encode_nanos) {
            const wait_ms = (next_encode_nanos - now_nanos + std.time.ns_per_ms - 1) /
                std.time.ns_per_ms;
            try self.waitForEvents(@intCast(wait_ms));
            continue;
        }

        const frame = self.takePending() orelse {
            // Without a capture to encode, an idle screen spends spare bitrate
            // sharpening the last picture, paced like captures.
            const active = if (encoder) |*value| value else null;
            if (active == null or last_metadata == null) {
                try self.waitForEvents(-1);
                continue;
            }
            if (!active.?.h264.refinementPending()) {
                try self.waitForEvents(-1);
                continue;
            }
            const refine_at = last_capture_nanos + refine_idle_ns;
            if (now_nanos < refine_at) {
                try self.waitForEvents(@intCast((refine_at - now_nanos + std.time.ns_per_ms - 1) / std.time.ns_per_ms));
                continue;
            }
            const refined = active.?.refine() catch |err| {
                log.warn("idle video encode failed: {t}; retrying in {d} ms", .{ err, restart_delay_ms });
                active.?.close(self.allocator);
                encoder = null;
                reset_prepared = false;
                retry_at_ms = monotonicMilliseconds() + restart_delay_ms;
                restart_delay_ms = @min(restart_delay_ms * 2, maximum_restart_delay_ms);
                continue;
            };
            next_encode_nanos = @max(next_encode_nanos + std.time.ns_per_s / active.?.config.fps, now_nanos);
            // Without room in the bitrate this interval, there is nothing to send.
            const access_unit = refined orelse continue;
            var metadata = last_metadata.?;
            metadata.capture_nanos = monotonicNanoseconds();
            metadata.damage = .{ .first = 0, .end = 0 };
            const completion = (try self.deliver(socket, active.?, access_unit, metadata)) orelse break;
            last_generation = completion.generation;
            continue;
        };
        defer self.release(frame.slot_index);

        var metadata = frame.metadata;
        const config = metadata.config();
        const replacing_encoder = ever_started and
            (encoder == null or !std.meta.eql(encoder.?.config, config));
        if (replacing_encoder and !reset_prepared) {
            const completion = self.postNotification(.{ .restart = .{
                .generation = metadata.generation,
                .increment_generation = metadata.generation == last_generation,
            } }) orelse break;
            if (!completion.encode) continue;
            metadata.generation = completion.generation;
            reset_prepared = true;
        }

        if (encoder != null and !std.meta.eql(encoder.?.config, config)) {
            encoder.?.close(self.allocator);
            encoder = null;
        }
        if (encoder == null) {
            encoder = Encoder.open(self.allocator, config, metadata.generation, next_ssrc) catch |err| {
                log.warn("video encoder start failed: {t}; retrying in {d} ms", .{
                    err,
                    restart_delay_ms,
                });
                retry_at_ms = monotonicMilliseconds() + restart_delay_ms;
                restart_delay_ms = @min(restart_delay_ms * 2, maximum_restart_delay_ms);
                continue;
            };
            next_ssrc +%= 1;
            if (next_ssrc == 0) next_ssrc = 1;
            ever_started = true;
            retry_at_ms = 0;
        }
        const active = &encoder.?;
        // Captures queued while a restart handshake was in flight still carry
        // the previous generation. The encoder owns the media generation.
        metadata.generation = active.generation;

        const access_unit = active.encode(frame.data, metadata.damage) catch |err| {
            log.warn("video encode failed: {t}; retrying in {d} ms", .{ err, restart_delay_ms });
            active.close(self.allocator);
            encoder = null;
            reset_prepared = false;
            retry_at_ms = monotonicMilliseconds() + restart_delay_ms;
            restart_delay_ms = @min(restart_delay_ms * 2, maximum_restart_delay_ms);
            continue;
        };
        next_encode_nanos = @max(next_encode_nanos + std.time.ns_per_s / config.fps, now_nanos);
        last_metadata = metadata;
        last_capture_nanos = now_nanos;

        const completion = (try self.deliver(socket, active, access_unit, metadata)) orelse break;
        last_generation = completion.generation;
        reset_prepared = false;
        if (monotonicMilliseconds() -| active.started_at_ms >= stable_run_ms) {
            restart_delay_ms = initial_restart_delay_ms;
        }
    }
}

/// Reports a frame's metadata to the main thread, then sends its access unit.
/// Returns null when the encoder is stopping.
fn deliver(
    self: *VideoEncoder,
    socket: ?std.posix.fd_t,
    active: *Encoder,
    access_unit: []const u8,
    metadata: Metadata,
) !?Completion {
    const completion = self.postNotification(.{ .metadata = metadata }) orelse return null;
    if (socket) |fd| {
        sendRtp(fd, access_unit, active.ssrc, active.rtpTimestamp(), &active.rtp_sequence);
    } else {
        try writeAll(1, access_unit);
    }
    active.frame_index += 1;
    return completion;
}

fn takePending(self: *VideoEncoder) ?PendingFrame {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    const slot_index = self.pending_slot orelse return null;
    const slot = &self.slots[slot_index];
    std.debug.assert(slot.state == .pending);
    slot.state = .encoding;
    self.pending_slot = null;
    return .{
        .slot_index = slot_index,
        .data = slot.data.?,
        .metadata = slot.metadata,
    };
}

fn release(self: *VideoEncoder, slot_index: usize) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    std.debug.assert(self.slots[slot_index].state == .encoding);
    self.slots[slot_index].state = .free;
}

fn postNotification(self: *VideoEncoder, notification: Notification) ?Completion {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.stopping) return null;
    std.debug.assert(self.notification == null);
    self.notification = notification;
    signalEvent(self.notification_event_fd) catch {
        self.notification = null;
        return null;
    };
    while (self.notification != null and !self.stopping) {
        self.completion_condition.waitUncancelable(self.io, &self.mutex);
    }
    if (self.stopping) return null;
    return self.completion;
}

fn isStopping(self: *VideoEncoder) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.stopping;
}

fn waitForEvents(self: *VideoEncoder, timeout: i32) !void {
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = self.work_event_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = try std.posix.poll(&poll_fds, timeout);
    if (poll_fds[0].revents != 0) try drainEvent(self.work_event_fd);
}

fn openRtpSocket(port: u16) !std.posix.fd_t {
    const result = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    const fd: std.posix.fd_t = switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => return error.RtpSocketFailed,
    };
    errdefer _ = linux.close(fd);
    const address: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f00_0001),
    };
    const connect_result = linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in));
    if (linux.errno(connect_result) != .SUCCESS) return error.RtpConnectFailed;
    return fd;
}

/// Splits an Annex-B byte stream into NAL units without their start codes.
const NalIterator = struct {
    data: []const u8,
    index: usize = 0,

    fn next(self: *NalIterator) ?[]const u8 {
        const nal_start = self.skipStartCode() orelse return null;
        var end = nal_start;
        while (end + 3 <= self.data.len) : (end += 1) {
            if (self.data[end] == 0 and self.data[end + 1] == 0 and
                (self.data[end + 2] == 1 or
                    (self.data[end + 2] == 0 and end + 3 < self.data.len and self.data[end + 3] == 1)))
            {
                self.index = end;
                return self.data[nal_start..end];
            }
        }
        self.index = self.data.len;
        return if (nal_start < self.data.len) self.data[nal_start..] else null;
    }

    fn skipStartCode(self: *NalIterator) ?usize {
        var index = self.index;
        while (index + 3 <= self.data.len) : (index += 1) {
            if (self.data[index] == 0 and self.data[index + 1] == 0) {
                if (self.data[index + 2] == 1) return index + 3;
                if (self.data[index + 2] == 0 and index + 3 < self.data.len and
                    self.data[index + 3] == 1) return index + 4;
            }
        }
        return null;
    }
};

/// Packetizes one access unit as RFC 6184 single NAL unit and FU-A packets,
/// marking its last packet. Loopback delivery failures drop the frame; the
/// gateway then reports it lacks a keyframe, and streamd sends one.
fn sendRtp(
    fd: std.posix.fd_t,
    access_unit: []const u8,
    ssrc: u32,
    timestamp: u32,
    sequence: *u16,
) void {
    var packet: [rtp_packet_size]u8 = undefined;
    const maximum_payload = rtp_packet_size - rtp_header_size;
    var nals: NalIterator = .{ .data = access_unit };
    var current = nals.next();
    while (current) |nal| {
        const following = nals.next();
        const last_nal = following == null;
        if (nal.len <= maximum_payload) {
            writeRtpHeader(&packet, last_nal, sequence, timestamp, ssrc);
            @memcpy(packet[rtp_header_size..][0..nal.len], nal);
            sendPacket(fd, packet[0 .. rtp_header_size + nal.len]);
        } else {
            const indicator = (nal[0] & 0xe0) | 28;
            const nal_type = nal[0] & 0x1f;
            var offset: usize = 1;
            while (offset < nal.len) {
                const chunk = @min(nal.len - offset, maximum_payload - 2);
                const first = offset == 1;
                const last = offset + chunk == nal.len;
                writeRtpHeader(&packet, last_nal and last, sequence, timestamp, ssrc);
                packet[rtp_header_size] = indicator;
                packet[rtp_header_size + 1] = nal_type |
                    (if (first) @as(u8, 0x80) else 0) | (if (last) @as(u8, 0x40) else 0);
                @memcpy(packet[rtp_header_size + 2 ..][0..chunk], nal[offset..][0..chunk]);
                sendPacket(fd, packet[0 .. rtp_header_size + 2 + chunk]);
                offset += chunk;
            }
        }
        current = following;
    }
}

fn writeRtpHeader(packet: []u8, marker: bool, sequence: *u16, timestamp: u32, ssrc: u32) void {
    packet[0] = 0x80;
    packet[1] = rtp_payload_type | (if (marker) @as(u8, 0x80) else 0);
    std.mem.writeInt(u16, packet[2..4], sequence.*, .big);
    std.mem.writeInt(u32, packet[4..8], timestamp, .big);
    std.mem.writeInt(u32, packet[8..12], ssrc, .big);
    sequence.* +%= 1;
}

fn sendPacket(fd: std.posix.fd_t, packet: []const u8) void {
    while (true) {
        const result = linux.write(fd, packet.ptr, packet.len);
        switch (linux.errno(result)) {
            .INTR => continue,
            else => return,
        }
    }
}

fn writeAll(fd: std.posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const result = linux.write(fd, data.ptr + written, data.len - written);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.VideoOutputClosed;
                written += result;
            },
            .INTR => continue,
            else => return error.VideoOutputFailed,
        }
    }
}

fn createEventFd() !std.posix.fd_t {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.EventFdUnavailable,
    };
}

fn signalEvent(fd: std.posix.fd_t) !void {
    var value: u64 = 1;
    const result = linux.write(fd, @ptrCast(&value), @sizeOf(u64));
    switch (linux.errno(result)) {
        .SUCCESS => if (result != @sizeOf(u64)) return error.EventSignalFailed,
        .AGAIN => {},
        else => return error.EventSignalFailed,
    }
}

fn drainEvent(fd: std.posix.fd_t) !void {
    var value: u64 = undefined;
    const result = linux.read(fd, @ptrCast(&value), @sizeOf(u64));
    switch (linux.errno(result)) {
        .SUCCESS => if (result != @sizeOf(u64)) return error.EventReadFailed,
        .AGAIN => {},
        else => return error.EventReadFailed,
    }
}

fn monotonicNanoseconds() u64 {
    var timestamp: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &timestamp);
    return @as(u64, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u64, @intCast(timestamp.nsec));
}

fn monotonicMilliseconds() u64 {
    return monotonicNanoseconds() / std.time.ns_per_ms;
}

test "new captures replace only the pending encoder frame" {
    var encoder = try VideoEncoder.init(std.testing.allocator, std.testing.io, .{
        .rtp_port = 5000,
    });
    defer encoder.deinit();
    const metadata: Metadata = .{
        .generation = 1,
        .raw_width = 2,
        .raw_height = 2,
        .encoded_width = 2,
        .encoded_height = 2,
        .capture_nanos = 1,
        .sequence = 1,
        .input_sequence = 0,
        .fps = 30,
        .bitrate_kbps = 1000,
        .damage = .{ .first = 0, .end = 1 },
    };
    try std.testing.expectEqual(SubmitResult.queued, try encoder.submit(&.{ 1, 2, 3, 4 }, metadata));
    var replacement = metadata;
    replacement.sequence = 2;
    replacement.damage = .{ .first = 1, .end = 2 };
    try std.testing.expectEqual(SubmitResult.replaced, try encoder.submit(&.{ 5, 6, 7, 8 }, replacement));
    const pending = encoder.takePending().?;
    defer encoder.release(pending.slot_index);
    try std.testing.expectEqual(@as(u64, 2), pending.metadata.sequence);
    try std.testing.expectEqual(Rows{ .first = 0, .end = 2 }, pending.metadata.damage);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, pending.data);
}

test "Annex-B access units split into NAL units without start codes" {
    const stream = [_]u8{
        0,    0,    0,    1,    0x09, 0xf0,
        0,    0,    1,    0x67, 0x42, 0x00,
        0,    0,    0,    1,    0x65, 0x88,
        0x00, 0x00, 0x02,
    };
    var nals: NalIterator = .{ .data = &stream };
    try std.testing.expectEqualSlices(u8, &.{ 0x09, 0xf0 }, nals.next().?);
    try std.testing.expectEqualSlices(u8, &.{ 0x67, 0x42, 0x00 }, nals.next().?);
    try std.testing.expectEqualSlices(u8, &.{ 0x65, 0x88, 0x00, 0x00, 0x02 }, nals.next().?);
    try std.testing.expect(nals.next() == null);
}

test "an encoded keyframe starts with headers and an IDR slice" {
    var encoder = try Encoder.open(std.testing.allocator, .{
        .raw_width = 64,
        .raw_height = 32,
        .encoded_width = 64,
        .encoded_height = 32,
        .fps = 30,
        .bitrate_kbps = 1000,
    }, 1, 1);
    defer encoder.close(std.testing.allocator);
    const frame = try std.testing.allocator.alloc(u8, 64 * 32 * 4);
    defer std.testing.allocator.free(frame);
    @memset(frame, 0x80);
    var types: [8]u8 = undefined;
    var count: usize = 0;
    var nals: NalIterator = .{ .data = try encoder.encode(frame, .{ .first = 0, .end = 0 }) };
    while (nals.next()) |nal| : (count += 1) types[count] = nal[0] & 0x1f;
    // SPS, PPS, then one IDR slice per slice group.
    try std.testing.expectEqualSlices(u8, &.{ 7, 8 }, types[0..2]);
    try std.testing.expect(count > 2);
    for (types[2..count]) |nal_type| try std.testing.expectEqual(5, nal_type);
}

test "after a full frame only damaged rows, widened to whole chroma rows, are converted" {
    var encoder = try Encoder.open(std.testing.allocator, .{
        .raw_width = 32,
        .raw_height = 8,
        .encoded_width = 32,
        .encoded_height = 8,
        .fps = 30,
        .bitrate_kbps = 1000,
    }, 1, 1);
    defer encoder.close(std.testing.allocator);
    const frame = try std.testing.allocator.alloc(u8, 32 * 8 * 4);
    defer std.testing.allocator.free(frame);
    @memset(frame, 0);
    _ = try encoder.encode(frame, .{ .first = 0, .end = 0 });
    // Every row turns white, but only row 3 is reported as damaged.
    @memset(frame, 255);
    _ = try encoder.encode(frame, .{ .first = 3, .end = 4 });
    for (0..8) |row| {
        const expected: u8 = if (row == 2 or row == 3) 235 else 16;
        for (encoder.planes[row * 32 ..][0..32]) |value| try std.testing.expectEqual(expected, value);
    }
}
