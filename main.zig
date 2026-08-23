//! Captures a Wayland output into SHM and feeds a low-latency H.264 encoder.

const Stream = @This();

const std = @import("std");
const build_options = @import("build-options");
const wayland = @import("wayland");
const Clipboard = @import("Clipboard.zig");
const OutputManager = @import("OutputManager.zig");
const RemoteInput = @import("RemoteInput.zig");
const VideoEncoder = @import("VideoEncoder.zig");

const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const log = std.log.scoped(.stream);
const resize_command = 6;
const clipboard_command = 7;
const relative_pointer_command = 8;
const quality_command = 9;
const text_command = 10;
const keyframe_acknowledgement_command = 11;
const stream_frame_metadata = 2;
const stream_resize_applied = 3;
const maximum_text_bytes = 4000;
const minimum_width = 320;
const maximum_width = 6000;
const minimum_height = 180;
const maximum_height = 6000;
const maximum_pixels = maximum_width * maximum_height;
const minimum_scale = 120;
const maximum_scale = 480;
const initial_audio_restart_delay_ms = 1000;
const maximum_audio_restart_delay_ms = 30_000;
const stable_audio_run_ms = 30_000;

const OutputMode = struct {
    width: u32,
    height: u32,
    scale: u32,
};

const usage =
    \\usage: waymote-streamd [OPTIONS]
    \\
    \\Captures the first Wayland output and writes Annex-B H.264 to stdout.
    \\
    \\options:
    \\  --ffmpeg PATH       FFmpeg executable (default: ffmpeg)
    \\  --frame-rate FPS    encoder frame rate (default: 30)
    \\  --bitrate KBPS      encoder target bitrate (default: 12000)
    \\  --rtp-port PORT     send H.264 RTP to a loopback UDP port
    \\  --audio-rtp-port PORT
    \\                      send Opus RTP to a loopback UDP port
    \\  --audio-source NAME PulseAudio monitor source (disabled by default)
    \\  --version           show the Waymote version
    \\  --help              show this help
    \\
;

const Options = struct {
    ffmpeg_path: []const u8 = "ffmpeg",
    frame_rate: u32 = 30,
    bitrate_kbps: u32 = 12000,
    encoded_scale: u32 = 100,
    xkb_layout: [:0]const u8 = "us",
    rtp_port: ?u16 = null,
    audio_rtp_port: ?u16 = null,
    audio_source: ?[]const u8 = null,
    version: bool = false,
    help: bool = false,
};

allocator: std.mem.Allocator,
io: std.Io,
options: Options,
output_mode: ?OutputMode = null,
display: ?*wl.Display = null,
registry: ?*wl.Registry = null,
shm: ?*wl.Shm = null,
output: ?*wl.Output = null,
output_name: ?[]u8 = null,
output_management: OutputManager,
manager: ?*zwlr.ScreencopyManagerV1 = null,
frame: ?*zwlr.ScreencopyFrameV1 = null,
buffer: ?*wl.Buffer = null,
mapping: ?[]align(std.heap.page_size_min) u8 = null,
width: u32 = 0,
height: u32 = 0,
stride: u32 = 0,
capture_format: ?wl.Shm.Format = null,
constraints_received: bool = false,
captured_once: bool = false,
cursor_overlay: bool = false,
acknowledged_keyframe_generation: u32 = 0,
video_encoder: VideoEncoder,
audio_encoder: ?std.process.Child = null,
audio_pidfd: ?std.posix.fd_t = null,
audio_restart_at_ms: ?u64 = null,
audio_restart_delay_ms: u32 = initial_audio_restart_delay_ms,
audio_started_at_ms: u64 = 0,
remote_input: RemoteInput,
clipboard: Clipboard,
control_buffer: std.ArrayList(u8) = .empty,
failed: bool = false,
generation: u32 = 1,
frame_sequence: u64 = 0,
latest_input_sequence: u32 = 0,

pub fn main(init: std.process.Init) !void {
    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();
    _ = arguments.next();
    const options = parseArguments(&arguments) catch |err| {
        var buffer: [2048]u8 = undefined;
        var writer = std.Io.File.stderr().writer(init.io, &buffer);
        writer.interface.print("waymote-streamd: {t}\n\n{s}", .{ err, usage }) catch {};
        writer.interface.flush() catch {};
        std.process.exit(2);
    };
    if (options.help) {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        defer writer.interface.flush() catch {};
        try writer.interface.writeAll(usage);
        return;
    }
    if (options.version) {
        var buffer: [128]u8 = undefined;
        var writer = std.Io.File.stdout().writer(init.io, &buffer);
        defer writer.interface.flush() catch {};
        try writer.interface.print("waymote-streamd {s} (protocol 2)\n", .{build_options.version});
        return;
    }
    var stream: Stream = .{
        .allocator = init.gpa,
        .io = init.io,
        .options = options,
        .output_management = .init(init.gpa),
        .video_encoder = try .init(init.gpa, init.io, .{
            .ffmpeg_path = options.ffmpeg_path,
            .rtp_port = options.rtp_port,
        }),
        .remote_input = .init(init.io, options.xkb_layout),
        .clipboard = .init(init.gpa, init.io),
    };
    defer stream.deinit();
    try stream.connect();
    try stream.run();
    return error.StreamFailed;
}

fn connect(self: *Stream) !void {
    const display = try wl.Display.connect(null);
    self.display = display;
    const registry = try display.getRegistry();
    self.registry = registry;
    registry.setListener(*Stream, registryListener, self);
    if (display.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
    if (self.shm == null or self.output == null or self.manager == null) {
        return error.MissingWaylandGlobal;
    }
    // Object globals bound by the registry listener advertise their initial
    // state after the registry roundtrip's sync request.
    if (display.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
    try self.remote_input.start(self.output.?);
    // Without RTP, stdout is the H.264 media stream and cannot also carry
    // framed clipboard events for the gateway.
    if (self.options.rtp_port != null) {
        self.clipboard.start() catch |err| {
            log.warn("clipboard unavailable: {t}", .{err});
        };
    }
    if (self.options.audio_rtp_port != null) {
        self.startAudioEncoder() catch |err| {
            log.warn("audio unavailable: {t}", .{err});
            self.scheduleAudioRestart();
        };
    }
    try self.video_encoder.start();
    try self.requestFrame();
    if (display.flush() != .SUCCESS) return error.WaylandFlushFailed;
}

fn deinit(self: *Stream) void {
    if (self.frame) |frame| frame.destroy();
    if (self.audio_encoder) |*encoder| encoder.kill(self.io);
    if (self.audio_pidfd) |pidfd| _ = std.os.linux.close(pidfd);
    self.video_encoder.deinit();
    if (self.buffer) |buffer| buffer.destroy();
    if (self.mapping) |mapping| std.posix.munmap(mapping);
    self.control_buffer.deinit(self.allocator);
    self.clipboard.deinit();
    self.remote_input.deinit();
    if (self.manager) |manager| manager.destroy();
    self.output_management.deinit();
    if (self.output_name) |name| self.allocator.free(name);
    if (self.output) |output| {
        if (output.getVersion() >= wl.Output.release_since_version) {
            output.release();
        } else {
            output.destroy();
        }
    }
    if (self.shm) |shm| shm.destroy();
    if (self.registry) |registry| registry.destroy();
    if (self.display) |display| display.disconnect();
    self.* = undefined;
}

fn run(self: *Stream) !void {
    const display = self.display.?;
    while (!self.failed) {
        self.maybeRestartAudio();
        while (!display.prepareRead()) {
            if (display.dispatchPending() != .SUCCESS) return error.WaylandDispatchFailed;
        }

        var display_events: i16 = std.posix.POLL.IN;
        switch (display.flush()) {
            .SUCCESS => {},
            .AGAIN => display_events |= std.posix.POLL.OUT,
            else => {
                display.cancelRead();
                return error.WaylandFlushFailed;
            },
        }
        var poll_fds: [4 + Clipboard.poll_fd_count]std.posix.pollfd = undefined;
        poll_fds[0] = .{ .fd = display.getFd(), .events = display_events, .revents = 0 };
        poll_fds[1] = .{
            .fd = std.Io.File.stdin().handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        poll_fds[2] = .{
            .fd = self.audio_pidfd orelse -1,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        poll_fds[3] = .{
            .fd = self.video_encoder.notificationFd(),
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        self.clipboard.populatePollFds(poll_fds[4..]);
        _ = std.posix.poll(&poll_fds, self.audioRestartTimeout()) catch {
            display.cancelRead();
            return error.PollFailed;
        };

        const display_revents = poll_fds[0].revents;
        if (display_revents & std.posix.POLL.IN != 0) {
            if (display.readEvents() != .SUCCESS) return error.WaylandReadFailed;
        } else {
            display.cancelRead();
        }
        if (display_revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) {
            return error.WaylandConnectionClosed;
        }
        if (display.dispatchPending() != .SUCCESS) return error.WaylandDispatchFailed;

        const control_revents = poll_fds[1].revents;
        if (control_revents & std.posix.POLL.IN != 0) try self.readControl();
        if (control_revents & (std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0 or
            control_revents & std.posix.POLL.HUP != 0 and control_revents & std.posix.POLL.IN == 0)
        {
            self.remote_input.releaseAll();
            return error.ControlConnectionClosed;
        }
        if (poll_fds[2].revents &
            (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0)
        {
            self.reapAudioEncoder();
        }
        if (poll_fds[3].revents &
            (std.posix.POLL.IN | std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0)
        {
            try self.handleVideoEncoderNotification();
        }
        self.clipboard.handleTransfers(poll_fds[4..]);
    }
}

fn readControl(self: *Stream) !void {
    var incoming: [64 * 1024]u8 = undefined;
    const count = try std.posix.read(std.Io.File.stdin().handle, &incoming);
    if (count == 0) return error.ControlConnectionClosed;
    if (self.control_buffer.items.len + count >
        Clipboard.maximum_text_bytes + RemoteInput.record_size + incoming.len)
    {
        return error.ControlMessageTooLarge;
    }
    try self.control_buffer.appendSlice(self.allocator, incoming[0..count]);

    var consumed: usize = 0;
    while (self.control_buffer.items.len - consumed >= RemoteInput.record_size) {
        var record: [RemoteInput.record_size]u8 = undefined;
        @memcpy(&record, self.control_buffer.items[consumed..][0..RemoteInput.record_size]);
        if (record[1] == resize_command) {
            const request_id = std.mem.readInt(u16, record[14..16], .little);
            const mode = try decodeOutputMode(&record);
            self.setOutputMode(mode) catch |err| {
                log.warn("output resize rejected: {t}", .{err});
                consumed += RemoteInput.record_size;
                continue;
            };
            try self.writeResizeApplied(request_id);
        } else if (record[1] == keyframe_acknowledgement_command) {
            if (applyKeyframeReadiness(
                self.generation,
                &self.acknowledged_keyframe_generation,
                try decodeKeyframeAcknowledgement(&record),
            )) try self.rearmCapture();
        } else if (record[1] == quality_command) {
            const quality = try decodeQuality(&record);
            if (quality.bitrate != self.options.bitrate_kbps or quality.fps != self.options.frame_rate or
                quality.scale != self.options.encoded_scale)
            {
                self.options.bitrate_kbps = quality.bitrate;
                self.options.frame_rate = quality.fps;
                self.options.encoded_scale = quality.scale;
                try self.advanceVideoGeneration();
            }
        } else if (record[1] == text_command) {
            const payload_length = try decodeTextLength(&record);
            const message_length = RemoteInput.record_size + payload_length;
            if (self.control_buffer.items.len - consumed < message_length) break;
            const text = self.control_buffer.items[consumed + RemoteInput.record_size ..][0..payload_length];
            if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null)
                return error.InvalidTextRecord;
            self.remote_input.sendText(record[2] == 1, text);
            self.latest_input_sequence = std.mem.readInt(u32, record[8..12], .little);
            consumed += payload_length;
        } else if (record[1] == clipboard_command) {
            const payload_length = try decodeClipboardLength(&record);
            const message_length = RemoteInput.record_size + payload_length;
            if (self.control_buffer.items.len - consumed < message_length) break;
            self.clipboard.setText(
                self.control_buffer.items[consumed + RemoteInput.record_size ..][0..payload_length],
            ) catch |err| log.warn("clipboard set failed: {t}", .{err});
            consumed += payload_length;
        } else {
            const command = try RemoteInput.decodeRecord(&record);
            const cursor_overlay = cursorOverlayForCommand(self.cursor_overlay, command);
            if (cursor_overlay != self.cursor_overlay) try self.setCursorOverlay(cursor_overlay);
            self.remote_input.apply(command);
            if (record[1] != 5) {
                self.latest_input_sequence = std.mem.readInt(u32, record[12..16], .little);
            }
        }
        consumed += RemoteInput.record_size;
    }
    if (consumed != 0) {
        const remaining = self.control_buffer.items.len - consumed;
        std.mem.copyForwards(
            u8,
            self.control_buffer.items[0..remaining],
            self.control_buffer.items[consumed..],
        );
        self.control_buffer.items.len = remaining;
    }
}

fn requestFrame(self: *Stream) !void {
    std.debug.assert(self.frame == null);
    const frame = try self.manager.?.captureOutput(@intFromBool(self.cursor_overlay), self.output.?);
    self.frame = frame;
    self.constraints_received = false;
    frame.setListener(*Stream, frameListener, self);
}

fn cursorOverlayForCommand(current: bool, command: RemoteInput.Command) bool {
    return switch (command) {
        .pointer_relative => true,
        .pointer_motion, .release_all => false,
        else => current,
    };
}

fn setCursorOverlay(self: *Stream, enabled: bool) !void {
    if (self.cursor_overlay == enabled) return;
    self.cursor_overlay = enabled;
    if (self.frame) |frame| {
        frame.destroy();
        self.frame = null;
        self.constraints_received = false;
        if (self.display.?.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
    }
    self.captured_once = false;
    try self.requestFrame();
}

fn modeRequiresVideoGeneration(
    captured_once: bool,
    captured_width: u32,
    captured_height: u32,
    mode: OutputMode,
) bool {
    return captured_once and
        (captured_width != mode.width or captured_height != mode.height);
}

fn waitForDamage(captured_once: bool, generation: u32, acknowledged_generation: u32) bool {
    return captured_once and generation == acknowledged_generation;
}

const KeyframeReadiness = struct {
    generation: u32,
    ready: bool,
};

fn applyKeyframeReadiness(
    generation: u32,
    acknowledged_generation: *u32,
    readiness: KeyframeReadiness,
) bool {
    if (readiness.generation != generation) return false;
    if (readiness.ready) {
        acknowledged_generation.* = generation;
        return false;
    }
    const rearm = acknowledged_generation.* == generation;
    acknowledged_generation.* = 0;
    return rearm;
}

fn advanceVideoGeneration(self: *Stream) !void {
    self.generation +%= 1;
    if (self.generation == 0) self.generation = 1;
    self.acknowledged_keyframe_generation = 0;
    try self.rearmCapture();
}

fn rearmCapture(self: *Stream) !void {
    const frame = self.frame orelse return;
    frame.destroy();
    self.frame = null;
    self.constraints_received = false;
    if (self.display.?.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
    try self.requestFrame();
}

fn setOutputMode(self: *Stream, mode: OutputMode) !void {
    if (self.output_mode) |current| {
        if (std.meta.eql(current, mode)) return;
    }
    if (!self.output_management.available()) return error.OutputManagementUnavailable;
    const new_video_generation = modeRequiresVideoGeneration(
        self.captured_once,
        self.width,
        self.height,
        mode,
    );
    if (self.frame) |frame| {
        frame.destroy();
        self.frame = null;
        self.constraints_received = false;
        if (self.display.?.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
    }

    self.output_management.apply(
        self.display.?,
        self.output_name,
        mode.width,
        mode.height,
        mode.scale,
        self.options.frame_rate * 1000,
    ) catch |err| {
        try self.requestFrame();
        return err;
    };

    self.output_mode = mode;
    if (new_video_generation) {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.acknowledged_keyframe_generation = 0;
    }
    // The resized output has no capture baseline. Bootstrap it immediately;
    // later frames can wait for output damage.
    self.captured_once = false;
    try self.requestFrame();
}

fn ensureBuffer(
    self: *Stream,
    width: u32,
    height: u32,
    stride: u32,
    format: wl.Shm.Format,
) !void {
    if (width == 0 or height == 0 or stride != width * @sizeOf(u32)) {
        return error.UnsupportedBufferLayout;
    }
    if (self.buffer != null and self.width == width and self.height == height and
        self.stride == stride and self.capture_format == format) return;

    if (self.buffer) |buffer| buffer.destroy();
    self.buffer = null;
    if (self.mapping) |mapping| std.posix.munmap(mapping);
    self.mapping = null;

    const byte_count = std.math.mul(usize, height, stride) catch return error.Overflow;
    if (byte_count > std.math.maxInt(i32)) return error.Overflow;
    const fd = try std.posix.memfd_create("waymote-capture", std.os.linux.MFD.CLOEXEC);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(self.io);
    try file.setLength(self.io, byte_count);
    const mapping = try std.posix.mmap(
        null,
        byte_count,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(mapping);
    const pool = try self.shm.?.createPool(fd, @intCast(byte_count));
    defer pool.destroy();
    const buffer = try pool.createBuffer(
        0,
        @intCast(width),
        @intCast(height),
        @intCast(stride),
        format,
    );
    self.mapping = mapping;
    self.buffer = buffer;
    self.width = width;
    self.height = height;
    self.stride = stride;
    self.capture_format = format;
}

fn startAudioEncoder(self: *Stream) !void {
    std.debug.assert(self.audio_encoder == null);
    std.debug.assert(self.audio_pidfd == null);
    const port = self.options.audio_rtp_port orelse return;
    const source = self.options.audio_source orelse return;
    var rtp_url_buffer: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &rtp_url_buffer,
        "rtp://127.0.0.1:{d}?pkt_size=1200",
        .{port},
    );
    const argv = [_][]const u8{
        self.options.ffmpeg_path,
        "-hide_banner",
        "-loglevel",
        "warning",
        "-nostdin",
        "-f",
        "pulse",
        "-sample_rate",
        "48000",
        "-channels",
        "2",
        "-fragment_size",
        "3840",
        "-i",
        source,
        "-vn",
        "-c:a",
        "libopus",
        "-application",
        "lowdelay",
        "-frame_duration",
        "20",
        "-b:a",
        "128k",
        "-ar",
        "48000",
        "-ac",
        "2",
        "-payload_type",
        "97",
        "-rtpflags",
        "skip_rtcp",
        "-f",
        "rtp",
        url,
    };
    var encoder = try std.process.spawn(self.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    errdefer encoder.kill(self.io);
    const pidfd_result = std.os.linux.pidfd_open(encoder.id.?, 0);
    const pidfd: std.posix.fd_t = switch (std.os.linux.errno(pidfd_result)) {
        .SUCCESS => @intCast(pidfd_result),
        else => return error.AudioProcessMonitoringUnavailable,
    };
    self.audio_encoder = encoder;
    self.audio_pidfd = pidfd;
    self.audio_restart_at_ms = null;
    self.audio_started_at_ms = monotonicMilliseconds();
    log.info("capturing session audio from {s} as 128 kbps Opus", .{source});
}

fn maybeRestartAudio(self: *Stream) void {
    if (self.audio_encoder != null or self.options.audio_rtp_port == null or
        self.options.audio_source == null) return;
    const restart_at = self.audio_restart_at_ms orelse return;
    if (monotonicMilliseconds() < restart_at) return;
    self.audio_restart_at_ms = null;
    self.startAudioEncoder() catch |err| {
        log.warn("audio restart failed: {t}", .{err});
        self.scheduleAudioRestart();
    };
}

fn reapAudioEncoder(self: *Stream) void {
    const encoder = if (self.audio_encoder) |*value| value else return;
    const term: ?std.process.Child.Term = encoder.wait(self.io) catch |err| result: {
        log.warn("could not reap audio encoder: {t}", .{err});
        encoder.kill(self.io);
        break :result null;
    };
    self.audio_encoder = null;
    if (self.audio_pidfd) |pidfd| _ = std.os.linux.close(pidfd);
    self.audio_pidfd = null;

    const now = monotonicMilliseconds();
    if (now -| self.audio_started_at_ms >= stable_audio_run_ms) {
        self.audio_restart_delay_ms = initial_audio_restart_delay_ms;
    }
    if (term) |value| log.warn("audio encoder stopped: {any}", .{value});
    self.scheduleAudioRestart();
}

fn scheduleAudioRestart(self: *Stream) void {
    if (self.options.audio_rtp_port == null or self.options.audio_source == null) return;
    const delay = self.audio_restart_delay_ms;
    self.audio_restart_at_ms = monotonicMilliseconds() + delay;
    self.audio_restart_delay_ms = @min(delay * 2, maximum_audio_restart_delay_ms);
    log.info("retrying session audio in {d} ms", .{delay});
}

fn audioRestartTimeout(self: *const Stream) i32 {
    if (self.audio_restart_at_ms) |restart_at| {
        const now = monotonicMilliseconds();
        if (restart_at <= now) return 0;
        return @intCast(@min(restart_at - now, std.math.maxInt(i32)));
    }
    return -1;
}

fn monotonicMilliseconds() u64 {
    var timestamp: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &timestamp);
    return @as(u64, @intCast(timestamp.sec)) * std.time.ms_per_s +
        @as(u64, @intCast(timestamp.nsec)) / std.time.ns_per_ms;
}

fn submitFrame(self: *Stream) void {
    const mapping = self.mapping orelse return self.fail(error.MissingCaptureBuffer);
    var timestamp: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &timestamp);
    const capture_nanos: u64 = @as(u64, @intCast(timestamp.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(timestamp.nsec));
    const metadata: VideoEncoder.Metadata = .{
        .generation = self.generation,
        .raw_width = self.width,
        .raw_height = self.height,
        .encoded_width = @intCast(@max(2, (self.width * self.options.encoded_scale / 100) & ~@as(u32, 1))),
        .encoded_height = @intCast(@max(2, (self.height * self.options.encoded_scale / 100) & ~@as(u32, 1))),
        .capture_nanos = capture_nanos,
        .sequence = self.frame_sequence,
        .input_sequence = self.latest_input_sequence,
        .fps = self.options.frame_rate,
        .bitrate_kbps = self.options.bitrate_kbps,
    };
    _ = self.video_encoder.submit(mapping, metadata) catch |err| {
        self.fail(err);
        return;
    };
    self.frame_sequence += 1;
    const frame = self.frame orelse return self.fail(error.MissingCaptureFrame);
    self.captured_once = true;
    frame.destroy();
    self.frame = null;
    self.requestFrame() catch |err| self.fail(err);
}

fn handleVideoEncoderNotification(self: *Stream) !void {
    const notification = try self.video_encoder.takeNotification() orelse return;
    switch (notification) {
        .restart => |restart| {
            if (restart.generation != self.generation) {
                self.video_encoder.completeNotification(.{
                    .generation = self.generation,
                    .encode = false,
                });
                return;
            }
            if (restart.increment_generation) {
                try self.advanceVideoGeneration();
            }
            self.video_encoder.completeNotification(.{
                .generation = self.generation,
                .encode = true,
            });
        },
        .metadata => |metadata| {
            try self.writeFrameMetadata(metadata);
            self.video_encoder.completeNotification(.{
                .generation = metadata.generation,
                .encode = true,
            });
        },
    }
}

fn writeEvent(self: *Stream, event_type: u8, payload: []const u8) !void {
    if (self.options.rtp_port == null) return;
    var header: [8]u8 = @splat(0);
    header[0] = 2;
    header[1] = event_type;
    std.mem.writeInt(u32, header[4..8], @intCast(payload.len), .little);
    const output = std.Io.File.stdout();
    try output.writeStreamingAll(self.io, &header);
    try output.writeStreamingAll(self.io, payload);
}

fn writeFrameMetadata(self: *Stream, metadata: VideoEncoder.Metadata) !void {
    var payload: [32]u8 = @splat(0);
    std.mem.writeInt(u32, payload[0..4], metadata.generation, .little);
    std.mem.writeInt(u16, payload[4..6], metadata.encoded_width, .little);
    std.mem.writeInt(u16, payload[6..8], metadata.encoded_height, .little);
    std.mem.writeInt(u64, payload[8..16], metadata.capture_nanos, .little);
    std.mem.writeInt(u64, payload[16..24], metadata.sequence, .little);
    std.mem.writeInt(u32, payload[24..28], metadata.input_sequence, .little);
    std.mem.writeInt(u32, payload[28..32], metadata.fps, .little);
    try self.writeEvent(stream_frame_metadata, &payload);
}

fn writeResizeApplied(self: *Stream, request_id: u16) !void {
    const mode = self.output_mode orelse return;
    var payload: [20]u8 = @splat(0);
    std.mem.writeInt(u16, payload[0..2], request_id, .little);
    std.mem.writeInt(u32, payload[4..8], mode.width, .little);
    std.mem.writeInt(u32, payload[8..12], mode.height, .little);
    std.mem.writeInt(u16, payload[12..14], @intCast(mode.scale), .little);
    std.mem.writeInt(u32, payload[16..20], self.generation, .little);
    try self.writeEvent(stream_resize_applied, &payload);
}

fn fail(self: *Stream, err: anyerror) void {
    if (self.failed) return;
    self.failed = true;
    log.err("stream failed: {t}", .{err});
}

fn registryListener(_: *wl.Registry, event: wl.Registry.Event, self: *Stream) void {
    switch (event) {
        .global => |global| {
            const interface = std.mem.span(global.interface);
            self.remote_input.bindGlobal(
                self.registry.?,
                global.name,
                interface,
                global.version,
            ) catch |err| {
                self.fail(err);
                return;
            };
            self.clipboard.bindGlobal(
                self.registry.?,
                global.name,
                interface,
                global.version,
            ) catch |err| {
                self.fail(err);
                return;
            };
            if (std.mem.eql(u8, interface, std.mem.span(wl.Shm.interface.name))) {
                if (self.shm == null) {
                    self.shm = self.registry.?.bind(global.name, wl.Shm, 1) catch |err| {
                        self.fail(err);
                        return;
                    };
                }
            } else if (std.mem.eql(u8, interface, std.mem.span(wl.Output.interface.name))) {
                if (self.output == null) {
                    self.output = self.registry.?.bind(
                        global.name,
                        wl.Output,
                        @min(global.version, wl.Output.generated_version),
                    ) catch |err| {
                        self.fail(err);
                        return;
                    };
                    self.output.?.setListener(*Stream, outputListener, self);
                }
            } else if (std.mem.eql(
                u8,
                interface,
                std.mem.span(zwlr.ScreencopyManagerV1.interface.name),
            )) {
                if (self.manager == null) {
                    self.manager = self.registry.?.bind(
                        global.name,
                        zwlr.ScreencopyManagerV1,
                        @min(global.version, zwlr.ScreencopyManagerV1.generated_version),
                    ) catch |err| {
                        self.fail(err);
                        return;
                    };
                }
            }
            self.output_management.bindGlobal(
                self.registry.?,
                global.name,
                interface,
                global.version,
            ) catch |err| {
                self.fail(err);
                return;
            };
        },
        .global_remove => {},
    }
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, self: *Stream) void {
    switch (event) {
        .name => |name| {
            const duplicate = self.allocator.dupe(u8, std.mem.span(name.name)) catch |err| {
                self.fail(err);
                return;
            };
            if (self.output_name) |old| self.allocator.free(old);
            self.output_name = duplicate;
        },
        .geometry, .mode, .done, .scale, .description => {},
    }
}

fn frameListener(
    _: *zwlr.ScreencopyFrameV1,
    event: zwlr.ScreencopyFrameV1.Event,
    self: *Stream,
) void {
    switch (event) {
        .buffer => |buffer| {
            // Both formats are byte-ordered BGRX/BGRA on little-endian Linux;
            // FFmpeg's bgra input ignores the unused alpha byte for H.264.
            if (buffer.format != .argb8888 and buffer.format != .xrgb8888) {
                return self.fail(error.UnsupportedPixelFormat);
            }
            self.ensureBuffer(buffer.width, buffer.height, buffer.stride, buffer.format) catch |err| {
                self.fail(err);
                return;
            };
            self.constraints_received = true;
        },
        .buffer_done => {
            if (!self.constraints_received) return self.fail(error.MissingBufferConstraints);
            if (waitForDamage(
                self.captured_once,
                self.generation,
                self.acknowledged_keyframe_generation,
            )) {
                self.frame.?.copyWithDamage(self.buffer.?);
            } else {
                self.frame.?.copy(self.buffer.?);
            }
        },
        .flags => |flags| {
            const bits: u32 = @bitCast(flags.flags);
            if (bits != 0) self.fail(error.UnsupportedCaptureTransform);
        },
        .ready => self.submitFrame(),
        .failed => self.fail(error.CaptureFailed),
        .damage, .linux_dmabuf => {},
    }
}

fn decodeOutputMode(record: *const [RemoteInput.record_size]u8) !OutputMode {
    if (record[0] != 2 or record[1] != resize_command or record[2] != 0 or record[3] != 0) {
        return error.InvalidOutputModeRecord;
    }
    const width = std.mem.readInt(u32, record[4..8], .little);
    const height = std.mem.readInt(u32, record[8..12], .little);
    const scale = std.mem.readInt(u16, record[12..14], .little);
    if (width < minimum_width or width > maximum_width or width % 2 != 0 or
        height < minimum_height or height > maximum_height or height % 2 != 0 or
        @as(u64, width) * height > maximum_pixels or
        scale < minimum_scale or scale > maximum_scale)
    {
        return error.InvalidOutputModeRecord;
    }
    if (std.mem.readInt(u16, record[14..16], .little) == 0) {
        return error.InvalidOutputModeRecord;
    }
    return .{ .width = width, .height = height, .scale = scale };
}

const Quality = struct { bitrate: u32, fps: u32, scale: u32 };
fn decodeQuality(record: *const [16]u8) !Quality {
    if (record[0] != 2 or record[1] != quality_command or record[2] != 0 or record[3] != 0)
        return error.InvalidQualityRecord;
    const bitrate = std.mem.readInt(u32, record[4..8], .little);
    const fps = std.mem.readInt(u32, record[8..12], .little);
    const scale = std.mem.readInt(u32, record[12..16], .little);
    if (bitrate < 300 or bitrate > 50_000 or fps < 10 or fps > 120 or scale < 50 or scale > 100)
        return error.InvalidQualityRecord;
    return .{ .bitrate = bitrate, .fps = fps, .scale = scale };
}

fn decodeKeyframeAcknowledgement(
    record: *const [RemoteInput.record_size]u8,
) !KeyframeReadiness {
    if (record[0] != 2 or record[1] != keyframe_acknowledgement_command or
        record[2] > 1 or record[3] != 0 or !std.mem.allEqual(u8, record[8..16], 0))
    {
        return error.InvalidKeyframeAcknowledgement;
    }
    const generation = std.mem.readInt(u32, record[4..8], .little);
    if (generation == 0) return error.InvalidKeyframeAcknowledgement;
    return .{ .generation = generation, .ready = record[2] == 1 };
}

fn decodeTextLength(record: *const [16]u8) !usize {
    if (record[0] != 2 or record[1] != text_command or record[2] > 1 or record[3] != 0 or
        !std.mem.allEqual(u8, record[12..16], 0)) return error.InvalidTextRecord;
    const length = std.mem.readInt(u32, record[4..8], .little);
    if (length > maximum_text_bytes) return error.InvalidTextRecord;
    return length;
}

fn decodeClipboardLength(record: *const [RemoteInput.record_size]u8) !usize {
    if (record[0] != 2 or record[1] != clipboard_command or record[2] != 0 or
        record[3] != 0 or !std.mem.allEqual(u8, record[8..16], 0))
    {
        return error.InvalidClipboardRecord;
    }
    const length = std.mem.readInt(u32, record[4..8], .little);
    if (length > Clipboard.maximum_text_bytes) return error.InvalidClipboardRecord;
    return length;
}

fn parseArguments(arguments: anytype) !Options {
    var options: Options = .{};
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, argument, "--version")) {
            options.version = true;
        } else if (std.mem.eql(u8, argument, "--ffmpeg")) {
            options.ffmpeg_path = arguments.next() orelse return error.MissingArgument;
            if (options.ffmpeg_path.len == 0) return error.InvalidFfmpegPath;
        } else if (std.mem.eql(u8, argument, "--frame-rate")) {
            const value = arguments.next() orelse return error.MissingArgument;
            options.frame_rate = std.fmt.parseInt(u32, value, 10) catch
                return error.InvalidFrameRate;
            if (options.frame_rate == 0 or options.frame_rate > 240) {
                return error.InvalidFrameRate;
            }
        } else if (std.mem.eql(u8, argument, "--bitrate")) {
            const value = arguments.next() orelse return error.MissingArgument;
            options.bitrate_kbps = std.fmt.parseInt(u32, value, 10) catch
                return error.InvalidBitrate;
            if (options.bitrate_kbps < 100 or options.bitrate_kbps > 200_000) {
                return error.InvalidBitrate;
            }
        } else if (std.mem.eql(u8, argument, "--rtp-port")) {
            const value = arguments.next() orelse return error.MissingArgument;
            options.rtp_port = std.fmt.parseInt(u16, value, 10) catch
                return error.InvalidRtpPort;
            if (options.rtp_port.? == 0 or options.rtp_port.? == std.math.maxInt(u16)) {
                return error.InvalidRtpPort;
            }
        } else if (std.mem.eql(u8, argument, "--audio-rtp-port")) {
            const value = arguments.next() orelse return error.MissingArgument;
            options.audio_rtp_port = std.fmt.parseInt(u16, value, 10) catch
                return error.InvalidAudioRtpPort;
            if (options.audio_rtp_port.? == 0 or
                options.audio_rtp_port.? == std.math.maxInt(u16))
            {
                return error.InvalidAudioRtpPort;
            }
        } else if (std.mem.eql(u8, argument, "--audio-source")) {
            const value = arguments.next() orelse return error.MissingArgument;
            if (value.len == 0 or value.len > 255 or std.mem.indexOfScalar(u8, value, 0) != null)
                return error.InvalidAudioSource;
            options.audio_source = value;
        } else if (std.mem.eql(u8, argument, "--xkb-layout")) {
            options.xkb_layout = arguments.next() orelse return error.MissingArgument;
            if (!RemoteInput.validLayout(options.xkb_layout)) return error.InvalidXkbLayout;
        } else {
            return error.InvalidArgument;
        }
    }
    if ((options.audio_rtp_port == null) != (options.audio_source == null))
        return error.IncompleteAudioOptions;
    return options;
}

const TestArguments = struct {
    values: []const [:0]const u8,
    index: usize = 0,

    fn next(self: *TestArguments) ?[:0]const u8 {
        if (self.index == self.values.len) return null;
        defer self.index += 1;
        return self.values[self.index];
    }
};

test "stream options parse encoder settings" {
    var arguments: TestArguments = .{ .values = &.{
        "--ffmpeg",
        "/usr/bin/ffmpeg",
        "--frame-rate",
        "30",
        "--bitrate",
        "8000",
    } };
    const options = try parseArguments(&arguments);
    try std.testing.expectEqualStrings("/usr/bin/ffmpeg", options.ffmpeg_path);
    try std.testing.expectEqual(@as(u32, 30), options.frame_rate);
    try std.testing.expectEqual(@as(u32, 8000), options.bitrate_kbps);

    var version: TestArguments = .{ .values = &.{"--version"} };
    try std.testing.expect((try parseArguments(&version)).version);
}

test "stream options reject unsafe rates" {
    var arguments: TestArguments = .{ .values = &.{ "--frame-rate", "0" } };
    try std.testing.expectError(error.InvalidFrameRate, parseArguments(&arguments));
}

test "stream options accept a loopback RTP port" {
    var arguments: TestArguments = .{ .values = &.{ "--rtp-port", "32000" } };
    const options = try parseArguments(&arguments);
    try std.testing.expectEqual(@as(?u16, 32000), options.rtp_port);

    arguments = .{ .values = &.{ "--rtp-port", "65535" } };
    try std.testing.expectError(error.InvalidRtpPort, parseArguments(&arguments));
}

test "stream options require a paired audio source and RTP port" {
    var arguments: TestArguments = .{ .values = &.{
        "--audio-rtp-port",
        "32002",
        "--audio-source",
        "waymote_session.monitor",
    } };
    const options = try parseArguments(&arguments);
    try std.testing.expectEqual(@as(?u16, 32002), options.audio_rtp_port);
    try std.testing.expectEqualStrings("waymote_session.monitor", options.audio_source.?);

    arguments = .{ .values = &.{ "--audio-rtp-port", "32002" } };
    try std.testing.expectError(error.IncompleteAudioOptions, parseArguments(&arguments));
}

test "output mode records decode bounded even dimensions and fractional scale" {
    var record: [RemoteInput.record_size]u8 = @splat(0);
    record[0] = 2;
    record[1] = resize_command;
    std.mem.writeInt(u32, record[4..8], 1920, .little);
    std.mem.writeInt(u32, record[8..12], 1080, .little);
    std.mem.writeInt(u16, record[12..14], 180, .little);
    std.mem.writeInt(u16, record[14..16], 1, .little);
    try std.testing.expectEqual(
        OutputMode{ .width = 1920, .height = 1080, .scale = 180 },
        try decodeOutputMode(&record),
    );

    std.mem.writeInt(u32, record[4..8], 1696, .little);
    std.mem.writeInt(u32, record[8..12], 2176, .little);
    try std.testing.expectEqual(
        OutputMode{ .width = 1696, .height = 2176, .scale = 180 },
        try decodeOutputMode(&record),
    );

    std.mem.writeInt(u32, record[4..8], 6000, .little);
    std.mem.writeInt(u32, record[8..12], 6000, .little);
    try std.testing.expectEqual(
        OutputMode{ .width = 6000, .height = 6000, .scale = 180 },
        try decodeOutputMode(&record),
    );

    std.mem.writeInt(u32, record[4..8], 6002, .little);
    try std.testing.expectError(error.InvalidOutputModeRecord, decodeOutputMode(&record));

    std.mem.writeInt(u32, record[4..8], 6000, .little);
    std.mem.writeInt(u32, record[8..12], 6002, .little);
    try std.testing.expectError(error.InvalidOutputModeRecord, decodeOutputMode(&record));

    std.mem.writeInt(u32, record[4..8], 1919, .little);
    std.mem.writeInt(u32, record[8..12], 1080, .little);
    try std.testing.expectError(error.InvalidOutputModeRecord, decodeOutputMode(&record));
}

test "only captured pixel-size changes require a new video generation" {
    const current: OutputMode = .{ .width = 1280, .height = 720, .scale = 120 };
    const scaled: OutputMode = .{ .width = 1280, .height = 720, .scale = 180 };
    const resized: OutputMode = .{ .width = 1920, .height = 1080, .scale = 180 };

    try std.testing.expect(!modeRequiresVideoGeneration(false, 1280, 720, resized));
    try std.testing.expect(!modeRequiresVideoGeneration(true, 1280, 720, current));
    try std.testing.expect(!modeRequiresVideoGeneration(true, 1280, 720, scaled));
    try std.testing.expect(modeRequiresVideoGeneration(true, 1280, 720, resized));
}

test "relative pointer input controls cursor compositing" {
    const relative: RemoteInput.Command = .{
        .pointer_relative = .{ .dx = 1, .dy = -1, .sequence = 1 },
    };
    const absolute: RemoteInput.Command = .{
        .pointer_motion = .{ .x = 100, .y = 200, .sequence = 2 },
    };
    const key: RemoteInput.Command = .{
        .keyboard_key = .{ .key = 30, .state = .pressed },
    };

    try std.testing.expect(cursorOverlayForCommand(false, relative));
    try std.testing.expect(cursorOverlayForCommand(true, key));
    try std.testing.expect(!cursorOverlayForCommand(true, absolute));
    try std.testing.expect(!cursorOverlayForCommand(true, .release_all));
}

test "capture waits for damage only after current generation keyframe acknowledgement" {
    var acknowledged_generation: u32 = 0;
    const generation: u32 = 7;

    try std.testing.expect(!waitForDamage(false, generation, acknowledged_generation));
    try std.testing.expect(!waitForDamage(true, generation, acknowledged_generation));

    try std.testing.expect(!applyKeyframeReadiness(
        generation,
        &acknowledged_generation,
        .{ .generation = generation - 1, .ready = true },
    ));
    try std.testing.expectEqual(@as(u32, 0), acknowledged_generation);
    try std.testing.expect(!waitForDamage(true, generation, acknowledged_generation));

    try std.testing.expect(!applyKeyframeReadiness(
        generation,
        &acknowledged_generation,
        .{ .generation = generation, .ready = true },
    ));
    try std.testing.expect(waitForDamage(true, generation, acknowledged_generation));

    try std.testing.expect(applyKeyframeReadiness(
        generation,
        &acknowledged_generation,
        .{ .generation = generation, .ready = false },
    ));
    try std.testing.expect(!waitForDamage(true, generation, acknowledged_generation));

    const next_generation = generation + 1;
    acknowledged_generation = generation;
    try std.testing.expect(!waitForDamage(true, next_generation, acknowledged_generation));
}

test "keyframe acknowledgement records are private fixed-size controls" {
    var record: [RemoteInput.record_size]u8 = @splat(0);
    record[0] = 2;
    record[1] = keyframe_acknowledgement_command;
    record[2] = 1;
    std.mem.writeInt(u32, record[4..8], 9, .little);
    try std.testing.expectEqual(
        KeyframeReadiness{ .generation = 9, .ready = true },
        try decodeKeyframeAcknowledgement(&record),
    );

    record[8] = 1;
    try std.testing.expectError(
        error.InvalidKeyframeAcknowledgement,
        decodeKeyframeAcknowledgement(&record),
    );
}

test "clipboard records decode a bounded payload length" {
    var record: [RemoteInput.record_size]u8 = @splat(0);
    record[0] = 2;
    record[1] = clipboard_command;
    std.mem.writeInt(u32, record[4..8], 4096, .little);
    try std.testing.expectEqual(@as(usize, 4096), try decodeClipboardLength(&record));

    std.mem.writeInt(u32, record[4..8], Clipboard.maximum_text_bytes + 1, .little);
    try std.testing.expectError(error.InvalidClipboardRecord, decodeClipboardLength(&record));
}
