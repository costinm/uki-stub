const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .cpu_model = .baseline,
        .os_tag = .uefi,
        .abi = .msvc,
    });
    const optimize = b.standardOptimizeOption(.{});

    const main_module = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "BOOTx64.EFI",
        .root_module = main_module,
        .linkage = .static,
    });

    const out_dir_name = "EFI/BOOT";

    const install = b.addInstallFile(
        exe.getEmittedBin(),
        b.fmt("{s}/BOOTx64.EFI", .{out_dir_name}),
    );

    install.step.dependOn(&exe.step);

    b.getInstallStep().dependOn(&install.step);
    b.installArtifact(exe);

    b.default_step = &install.step;
}
