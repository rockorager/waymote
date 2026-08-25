//! Runs the software video encoder without blocking Wayland capture or input.
//!
//! Capture owns a fixed three-slot pool: one frame may be inside FFmpeg, one
//! may wait, and the third keeps allocation independent of the worker. A new
//! capture replaces the waiting frame rather than building latency. The worker
//! asks the main loop to publish correlation metadata only after a complete raw
//! frame has reached FFmpeg's pipe; the RTP receiver can wait for that metadata.

const VideoEncoder = @This();

const std = @import("std");

const linux = std.os.linux;
const log = std.log.scoped(.video_encoder);
const slot_count = 3;
const initial_restart_delay_ms = 1000;
const maximum_restart_delay_ms = 30_000;
const stable_run_ms = 30_000;

pub const Options = struct {
    ffmpeg_path: []const u8,
    rtp_port: ?u16,
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

const Process = struct {
    child: std.process.Child,
    pidfd: std.posix.fd_t,
    config: Config,
    generation: u32,
    started_at_ms: u64,

    fn kill(self: *Process, io: std.Io) void {
        const result = linux.pidfd_send_signal(self.pidfd, .KILL, null, 0);
        switch (linux.errno(result)) {
            .SUCCESS, .SRCH => self.reap(io, false),
            else => |err| {
                // A valid pidfd for our own child should always accept SIGKILL.
                // Keep Child.kill as an exceptional fallback rather than the
                // normal path: it sends SIGTERM and can wait indefinitely for
                // an encoder blocked in a pipe read.
                log.err("could not force-stop video encoder: {t}", .{err});
                self.child.kill(io);
                _ = linux.close(self.pidfd);
            },
        }
    }

    fn reap(self: *Process, io: std.Io, report_termination: bool) void {
        const term: ?std.process.Child.Term = self.child.wait(io) catch |err| result: {
            log.warn("could not reap video encoder: {t}", .{err});
            self.child.kill(io);
            break :result null;
        };
        _ = linux.close(self.pidfd);
        if (report_termination) {
            if (term) |value| log.warn("video encoder stopped: {any}", .{value});
        }
    }

    fn stop(self: *Process, io: std.Io) void {
        if (processExited(self)) {
            self.reap(io, true);
        } else {
            self.kill(io);
        }
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
    slot.metadata = metadata;
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
    var process: ?Process = null;
    defer if (process) |*value| value.stop(self.io);
    var ever_started = false;
    var last_generation: u32 = 0;
    var reset_prepared = false;
    var next_ssrc: u32 = 1;
    var restart_delay_ms: u32 = initial_restart_delay_ms;
    var retry_at_ms: u64 = 0;

    while (!self.isStopping()) {
        if (process) |*active| {
            if (processExited(active)) {
                active.reap(self.io, true);
                process = null;
                reset_prepared = false;
                retry_at_ms = monotonicMilliseconds() + restart_delay_ms;
                restart_delay_ms = @min(restart_delay_ms * 2, maximum_restart_delay_ms);
                continue;
            }
        }

        const now = monotonicMilliseconds();
        if (process == null and retry_at_ms > now) {
            _ = try self.waitForEvents(null, @intCast(@min(retry_at_ms - now, std.math.maxInt(i32))));
            continue;
        }

        const frame = self.takePending() orelse {
            const event = try self.waitForEvents(if (process) |*active| active else null, -1);
            if (event == .process_exited) {
                process.?.reap(self.io, true);
                process = null;
                reset_prepared = false;
                retry_at_ms = monotonicMilliseconds() + restart_delay_ms;
                restart_delay_ms = @min(restart_delay_ms * 2, maximum_restart_delay_ms);
            }
            continue;
        };
        defer self.release(frame.slot_index);

        var metadata = frame.metadata;
        const config = metadata.config();
        const replacing_process = ever_started and
            (process == null or !std.meta.eql(process.?.config, config));
        if (replacing_process and !reset_prepared) {
            const completion = self.postNotification(.{ .restart = .{
                .generation = metadata.generation,
                .increment_generation = metadata.generation == last_generation,
            } }) orelse break;
            if (!completion.encode) continue;
            metadata.generation = completion.generation;
            reset_prepared = true;
        }

        if (process != null and !std.meta.eql(process.?.config, config)) {
            process.?.stop(self.io);
            process = null;
        }
        if (process == null) {
            process = self.startProcess(config, metadata.generation, next_ssrc) catch |err| {
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
        // Captures queued while a restart handshake was in flight still carry
        // the previous generation. The process owns the media generation.
        metadata.generation = process.?.generation;

        self.writeFrame(&process.?, frame.data) catch |err| {
            log.warn("video encoder write failed: {t}; retrying in {d} ms", .{
                err,
                restart_delay_ms,
            });
            process.?.stop(self.io);
            process = null;
            reset_prepared = false;
            retry_at_ms = monotonicMilliseconds() + restart_delay_ms;
            restart_delay_ms = @min(restart_delay_ms * 2, maximum_restart_delay_ms);
            continue;
        };

        const completion = self.postNotification(.{ .metadata = metadata }) orelse break;
        last_generation = completion.generation;
        reset_prepared = false;
        if (monotonicMilliseconds() -| process.?.started_at_ms >= stable_run_ms) {
            restart_delay_ms = initial_restart_delay_ms;
        }
    }
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

const WorkerEvent = enum { wake, process_exited, timeout };

fn waitForEvents(self: *VideoEncoder, process: ?*const Process, timeout: i32) !WorkerEvent {
    var poll_fds = [_]std.posix.pollfd{
        .{ .fd = self.work_event_fd, .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = if (process) |active| active.pidfd else -1, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const count = try std.posix.poll(&poll_fds, timeout);
    if (poll_fds[0].revents != 0) try drainEvent(self.work_event_fd);
    if (poll_fds[1].revents &
        (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0)
    {
        return .process_exited;
    }
    return if (count == 0) .timeout else .wake;
}

fn startProcess(self: *VideoEncoder, config: Config, generation: u32, ssrc: u32) !Process {
    var size_buffer: [32]u8 = undefined;
    var output_size_buffer: [32]u8 = undefined;
    var rate_buffer: [16]u8 = undefined;
    var bitrate_buffer: [24]u8 = undefined;
    var peak_bitrate_buffer: [24]u8 = undefined;
    var keyframe_buffer: [16]u8 = undefined;
    var ssrc_buffer: [16]u8 = undefined;
    var rtp_url_buffer: [64]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buffer, "{d}x{d}", .{
        config.raw_width,
        config.raw_height,
    });
    const output_size = try std.fmt.bufPrint(&output_size_buffer, "scale={d}:{d}", .{
        config.encoded_width,
        config.encoded_height,
    });
    const rate = try std.fmt.bufPrint(&rate_buffer, "{d}", .{config.fps});
    const bitrate = try std.fmt.bufPrint(&bitrate_buffer, "{d}k", .{config.bitrate_kbps});
    const peak_bitrate = try std.fmt.bufPrint(&peak_bitrate_buffer, "{d}k", .{
        config.bitrate_kbps * 2,
    });
    const keyframe_interval = try std.fmt.bufPrint(&keyframe_buffer, "{d}", .{config.fps});
    const ssrc_text = try std.fmt.bufPrint(&ssrc_buffer, "{d}", .{ssrc});
    const common_argv = [_][]const u8{
        self.options.ffmpeg_path,
        "-hide_banner",
        "-loglevel",
        "warning",
        "-nostdin",
        "-f",
        "rawvideo",
        "-pixel_format",
        "bgra",
        "-video_size",
        size,
        "-framerate",
        rate,
        "-re",
        "-i",
        "pipe:0",
        "-an",
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-tune",
        "zerolatency",
        "-profile:v",
        "baseline",
        "-level:v",
        "5.2",
        "-pix_fmt",
        "yuv420p",
        "-b:v",
        bitrate,
        "-maxrate",
        peak_bitrate,
        "-bufsize",
        peak_bitrate,
        "-g",
        keyframe_interval,
        "-keyint_min",
        keyframe_interval,
        "-sc_threshold",
        "0",
        "-bf",
        "0",
        "-x264-params",
        "aud=1:repeat-headers=1",
    };
    var argv: [common_argv.len + 14][]const u8 = undefined;
    @memcpy(argv[0..common_argv.len], &common_argv);
    var argument_count = common_argv.len;
    argv[argument_count] = "-vf";
    argv[argument_count + 1] = output_size;
    argument_count += 2;
    if (self.options.rtp_port) |port| {
        const url = try std.fmt.bufPrint(&rtp_url_buffer, "rtp://127.0.0.1:{d}?pkt_size=60000", .{port});
        const output_argv = [_][]const u8{
            "-payload_type",
            "96",
            "-ssrc",
            ssrc_text,
            "-rtpflags",
            "skip_rtcp",
            "-f",
            "rtp",
            url,
        };
        @memcpy(argv[argument_count..][0..output_argv.len], &output_argv);
        argument_count += output_argv.len;
    } else {
        const output_argv = [_][]const u8{ "-f", "h264", "pipe:1" };
        @memcpy(argv[argument_count..][0..output_argv.len], &output_argv);
        argument_count += output_argv.len;
    }
    var child = try std.process.spawn(self.io, .{
        .argv = argv[0..argument_count],
        .stdin = .pipe,
        .stdout = if (self.options.rtp_port == null) .inherit else .ignore,
        .stderr = .inherit,
    });
    errdefer child.kill(self.io);
    try setNonblocking(child.stdin.?.handle);
    const pidfd = try openPidfd(child.id.?);
    log.info("capturing {}x{} at {d} FPS and {d} kbps", .{
        config.raw_width,
        config.raw_height,
        config.fps,
        config.bitrate_kbps,
    });
    return .{
        .child = child,
        .pidfd = pidfd,
        .config = config,
        .generation = generation,
        .started_at_ms = monotonicMilliseconds(),
    };
}

fn writeFrame(self: *VideoEncoder, process: *Process, data: []const u8) !void {
    const fd = process.child.stdin.?.handle;
    var written: usize = 0;
    while (written < data.len) {
        const result = linux.write(fd, data.ptr + written, data.len - written);
        switch (linux.errno(result)) {
            .SUCCESS => {
                if (result == 0) return error.VideoEncoderPipeClosed;
                written += result;
            },
            .INTR => continue,
            .AGAIN => {
                var poll_fds = [_]std.posix.pollfd{
                    .{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 },
                    .{ .fd = self.work_event_fd, .events = std.posix.POLL.IN, .revents = 0 },
                    .{ .fd = process.pidfd, .events = std.posix.POLL.IN, .revents = 0 },
                };
                _ = try std.posix.poll(&poll_fds, 100);
                if (poll_fds[1].revents != 0) try drainEvent(self.work_event_fd);
                if (self.isStopping()) return error.VideoEncoderStopped;
                if (poll_fds[2].revents != 0) return error.VideoEncoderExited;
            },
            .PIPE => return error.VideoEncoderPipeClosed,
            else => return error.VideoEncoderWriteFailed,
        }
    }
}

fn processExited(process: *const Process) bool {
    var poll_fd = [_]std.posix.pollfd{
        .{ .fd = process.pidfd, .events = std.posix.POLL.IN, .revents = 0 },
    };
    _ = std.posix.poll(&poll_fd, 0) catch return true;
    return poll_fd[0].revents != 0;
}

fn createEventFd() !std.posix.fd_t {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.EventFdUnavailable,
    };
}

fn openPidfd(pid: std.process.Child.Id) !std.posix.fd_t {
    const result = linux.pidfd_open(pid, 0);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => error.ProcessMonitoringUnavailable,
    };
}

fn setNonblocking(fd: std.posix.fd_t) !void {
    const result = linux.fcntl(fd, linux.F.GETFL, 0);
    const flags: i32 = switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        else => return error.SetNonblockingFailed,
    };
    const set_result = linux.fcntl(
        fd,
        linux.F.SETFL,
        @as(usize, @intCast(flags)) | linux.SOCK.NONBLOCK,
    );
    if (linux.errno(set_result) != .SUCCESS) return error.SetNonblockingFailed;
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

fn monotonicMilliseconds() u64 {
    var timestamp: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &timestamp);
    return @as(u64, @intCast(timestamp.sec)) * std.time.ms_per_s +
        @as(u64, @intCast(timestamp.nsec)) / std.time.ns_per_ms;
}

test "new captures replace only the pending encoder frame" {
    var encoder = try VideoEncoder.init(std.testing.allocator, std.testing.io, .{
        .ffmpeg_path = "ffmpeg",
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
    };
    try std.testing.expectEqual(SubmitResult.queued, try encoder.submit(&.{ 1, 2, 3, 4 }, metadata));
    var replacement = metadata;
    replacement.sequence = 2;
    try std.testing.expectEqual(SubmitResult.replaced, try encoder.submit(&.{ 5, 6, 7, 8 }, replacement));
    const pending = encoder.takePending().?;
    defer encoder.release(pending.slot_index);
    try std.testing.expectEqual(@as(u64, 2), pending.metadata.sequence);
    try std.testing.expectEqualSlices(u8, &.{ 5, 6, 7, 8 }, pending.data);
}
