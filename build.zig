//! zebrac build graph. Default: native ReleaseFast binary.
//! Steps: fmt, test, ci, preflight, release.

const std = @import("std");

const linux_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86, .os_tag = .linux },
    .{ .cpu_arch = .x86_64, .os_tag = .linux },
    .{ .cpu_arch = .aarch64, .os_tag = .linux },
    .{ .cpu_arch = .riscv64, .os_tag = .linux },
};

const test_roots = [_][]const u8{
    "src/main.zig",
    "src/progress.zig",
    "src/argv_parse.zig",
    "src/help.zig",
};

const fmt_paths = [_][]const u8{ "build.zig", "src" };
const ship_optimize: std.builtin.OptimizeMode = .ReleaseFast;

fn addZebrac(
    b: *std.Build,
    root_source: std.Build.LazyPath,
    resolved_target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    omit_frame_pointer: bool,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = "zebrac",
        .root_module = b.createModule(.{
            .root_source_file = root_source,
            .target = resolved_target,
            .optimize = optimize,
            .strip = strip,
            .omit_frame_pointer = omit_frame_pointer,
        }),
    });
}

fn addModuleTests(b: *std.Build, source: []const u8, host: std.Build.ResolvedTarget) *std.Build.Step.Run {
    const mod = b.createModule(.{
        .root_source_file = b.path(source),
        .target = host,
        .optimize = .Debug,
    });
    return b.addRunArtifact(b.addTest(.{ .root_module = mod }));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseFast)",
    ) orelse .ReleaseFast;
    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse (optimize != .Debug);
    const omit_frame_pointer = b.option(bool, "omit-frame-pointer", "Omit frame pointers") orelse (optimize != .Debug);

    const root_source = b.path("src/main.zig");
    b.installArtifact(addZebrac(b, root_source, target, optimize, strip, omit_frame_pointer));

    const fmt_check = b.addFmt(.{ .paths = &fmt_paths, .check = true });
    const fmt_step = b.step("fmt", "zig fmt --check on build.zig and src/");
    fmt_step.dependOn(&fmt_check.step);

    const test_step = b.step("test", "Run unit tests");
    var test_runs: [test_roots.len]*std.Build.Step.Run = undefined;
    for (test_roots, 0..) |src, i| {
        test_runs[i] = addModuleTests(b, src, target);
        test_step.dependOn(&test_runs[i].step);
    }

    const ci = b.step("ci", "zig fmt --check and unit tests (GitHub Actions check job)");
    ci.dependOn(&fmt_check.step);
    for (test_runs) |run| ci.dependOn(&run.step);

    const release = b.step("release", "ReleaseFast stripped binaries for all Linux targets");
    for (linux_targets) |q| {
        const resolved = b.resolveTargetQuery(q);
        const bin = addZebrac(b, root_source, resolved, ship_optimize, true, true);
        const t = resolved.result;
        const install = b.addInstallArtifact(bin, .{
            .dest_dir = .{ .override = .prefix },
            .dest_sub_path = b.fmt("{s}-{s}-{s}", .{
                @tagName(t.cpu.arch), @tagName(t.os.tag), bin.name,
            }),
        });
        release.dependOn(&install.step);
    }

    const preflight = b.step("preflight", "fmt --check and unit tests (same as ci)");
    preflight.dependOn(ci);
}
