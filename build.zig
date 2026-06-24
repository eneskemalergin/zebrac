const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size (default: ReleaseSmall)",
    ) orelse .ReleaseSmall;
    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse (optimize != .Debug);

    const root_source = b.path("src/main.zig");

    const exe = b.addExecutable(.{
        .name = "zebrac",
        .root_module = b.createModule(.{
            .root_source_file = root_source,
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });

    b.installArtifact(exe);

    const test_mod = b.createModule(.{
        .root_source_file = root_source,
        .target = target,
        .optimize = .Debug,
    });
    const exe_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);

    const progress_test_mod = b.createModule(.{
        .root_source_file = b.path("src/progress.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const progress_tests = b.addTest(.{
        .root_module = progress_test_mod,
    });
    const run_progress_tests = b.addRunArtifact(progress_tests);
    test_step.dependOn(&run_progress_tests.step);

    const ci = b.step("ci", "Tests plus ReleaseSmall cross-builds (same as GitHub Actions build job)");
    ci.dependOn(&run_exe_tests.step);
    ci.dependOn(&run_progress_tests.step);
    const ci_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .riscv64, .os_tag = .linux },
    };
    for (ci_targets) |target_query| {
        const resolved = b.resolveTargetQuery(target_query);
        const ci_exe = b.addExecutable(.{
            .name = "zebrac",
            .root_module = b.createModule(.{
                .root_source_file = root_source,
                .target = resolved,
                .optimize = .ReleaseSmall,
                .strip = true,
            }),
        });
        ci.dependOn(&b.addInstallArtifact(ci_exe, .{}).step);
    }

    // Fuzz targets live in `test` blocks (`std.testing.fuzz`). Example:
    //   zig build test --fuzz
    //   zig build test --fuzz=10M

    const release = b.step("release", "make an upstream binary release");
    const release_targets = [_]std.Target.Query{
        .{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .x86,
            .os_tag = .linux,
        },
        .{
            .cpu_arch = .riscv64,
            .os_tag = .linux,
        },
    };
    for (release_targets) |target_query| {
        const resolved_target = b.resolveTargetQuery(target_query);
        const t = resolved_target.result;
        const rel_exe = b.addExecutable(.{
            .name = "zebrac",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved_target,
                .optimize = .ReleaseSmall,
                .strip = true,
            }),
        });

        const install = b.addInstallArtifact(rel_exe, .{});
        install.dest_dir = .prefix;
        install.dest_sub_path = b.fmt("{s}-{s}-{s}", .{
            @tagName(t.cpu.arch), @tagName(t.os.tag), rel_exe.name,
        });

        release.dependOn(&install.step);
    }
}
