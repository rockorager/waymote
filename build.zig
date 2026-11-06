const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "version embedded in the binaries") orelse "0.1.0-dev";

    const scanner = Scanner.create(b, .{
        .wayland_xml = b.dependency("wayland_source", .{}).path("protocol/wayland.xml"),
        .wayland_protocols = b.dependency("wayland_protocols", .{}).path(""),
    });
    scanner.addSystemProtocol("staging/ext-data-control/ext-data-control-v1.xml");
    scanner.addCustomProtocol(b.path("protocols/wlr-output-management-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wlr-screencopy-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/virtual-keyboard-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/wlr-virtual-pointer-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocols/input-method-unstable-v2.xml"));
    scanner.addSystemProtocol("unstable/text-input/text-input-unstable-v3.xml");
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 9);
    scanner.generate("ext_data_control_manager_v1", 1);
    scanner.generate("zwlr_output_manager_v1", 4);
    scanner.generate("zwlr_screencopy_manager_v1", 3);
    scanner.generate("zwlr_virtual_pointer_manager_v1", 2);
    scanner.generate("zwp_virtual_keyboard_manager_v1", 1);
    scanner.generate("zwp_input_method_manager_v2", 1);
    scanner.generate("zwp_text_input_manager_v3", 1);

    const wayland = b.createModule(.{
        .root_source_file = scanner.result,
        .target = target,
        .optimize = optimize,
    });
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const stream_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Colour conversion and the H.264 encoder are pure computation over
    // captured pixels. Safety checks cost about 40% of their CPU time, so
    // release builds of streamd compile them as ReleaseFast, which their hot
    // functions read to turn the checks off. Their unit tests and h264-check
    // keep the checks and verify the bitstream bit for bit against FFmpeg.
    const pixel_optimize: std.builtin.OptimizeMode = if (optimize == .ReleaseSafe) .ReleaseFast else optimize;
    for ([_][]const u8{ "h264", "ColorConvert" }, [_][]const u8{ "h264/Encoder.zig", "ColorConvert.zig" }) |name, path| {
        stream_module.addImport(name, b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = pixel_optimize,
        }));
    }
    stream_module.addImport("wayland", wayland);
    stream_module.addOptions("build-options", build_options);
    stream_module.linkSystemLibrary("wayland-client", .{});
    stream_module.linkSystemLibrary("xkbcommon", .{});
    const streamd = b.addExecutable(.{
        .name = "waymote-streamd",
        .root_module = stream_module,
    });
    b.installArtifact(streamd);

    const go_build = b.addSystemCommand(&.{
        "go",
        "build",
        "-trimpath",
        "-ldflags",
        b.fmt("-s -w -X main.version={s}", .{version}),
        "-o",
    });
    go_build.setCwd(b.path("gateway"));
    go_build.setEnvironmentVariable("CGO_ENABLED", "0");
    const gateway = go_build.addOutputFileArg("waymote-gateway");
    go_build.addArg(".");
    b.getInstallStep().dependOn(&b.addInstallBinFile(gateway, "waymote-gateway").step);

    const h264_check = b.addExecutable(.{
        .name = "h264-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("h264/check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_h264_check = b.addRunArtifact(h264_check);
    _ = run_h264_check.addOutputDirectoryArg("h264-check");
    run_h264_check.has_side_effects = true;
    const h264_check_step = b.step("h264-check", "Check the H.264 encoder bit-exactly against FFmpeg's decoder");
    h264_check_step.dependOn(&run_h264_check.step);

    const test_step = b.step("test", "Run native and gateway tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = stream_module })).step);
    for ([_][]const u8{ "h264/Encoder.zig", "ColorConvert.zig" }) |path| {
        const tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const go_test = b.addSystemCommand(&.{ "go", "test", "./..." });
    go_test.setCwd(b.path("gateway"));
    test_step.dependOn(&go_test.step);
}
