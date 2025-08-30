const std = @import("std");

const Target = @import("std").Target;
const CrossTarget = @import("std").zig.CrossTarget;
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .baseline,
        .os_tag = .uefi,
        .abi = .msvc,
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ministub.efi",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .linkage = .static,
        .optimize = optimize,
    });

     const out_dir_name = "img";

    const install = b.addInstallFile(
        exe.getEmittedBin(),
        b.fmt("{s}/ministub.efi", .{out_dir_name}),
    );

    install.step.dependOn(&exe.step);
    b.getInstallStep().dependOn(&install.step);
    b.installArtifact(exe);
    b.default_step = &install.step;
}
