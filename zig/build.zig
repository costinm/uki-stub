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
        .name = "BOOTX64.EFI",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .linkage = .static,
        .optimize = optimize,
    });

    exe.addCSourceFile(.{
        .file = b.path("zig.c"),
        .flags = &.{ // Optional: Add C compiler arguments if needed
            "-Wall",
            "-Wextra",
            "-I/usr/include/efi",
            "-I/usr/include",
            "-I/usr/include/efi/x86_64",
            "-I/usr/include/x86_64-linux-gnu",
            //-DMACHINE_TYPE_NAME=\"$(MACHINE_TYPE_NAME)\" \
            "-nostdinc",
            "-ggdb",
            "-O0",
            //"-fPIC",
            "-fshort-wchar",
            "-ffreestanding",
            "-fno-strict-aliasing",
            "-fno-stack-protector",
            "-Wsign-compare",
            "-mno-sse",
            "-mno-mmx",
            "-mno-red-zone",
            "-m64",
            "-DEFI_FUNCTION_WRAPPER",
            "-DGNU_EFI_USE_MS_ABI",
        },
    });
    //exe.addObjectFile(b.path("crt0-efi-x86_64.o")); // Link with your object file

    // If your C file includes headers from a specific directory, add that include path
    exe.addIncludePath(b.path("./"));

    // EFI directory
    const out_dir_name = "img";
    const install = b.addInstallFile(
        exe.getEmittedBin(),
        b.fmt("{s}/stub.efi", .{out_dir_name}),
    );
    install.step.dependOn(&exe.step);
    b.getInstallStep().dependOn(&install.step);
    b.installArtifact(exe);

    const patch2_cmd = patch(b, exe.name, "cmdline", install);
    const patch3_cmd = patch(b, "initos.efi", "cmdline1", install);

    const qemu_args = [_][]const u8{
        "qemu-system-x86_64",
        "-nodefaults",
        "-m",
        "1G",
        "-smp",
        "4",
        "-bios",
        "bin/OVMF.fd", // "/usr/share/ovmf/OVMF.fd",
        "-drive",
        b.fmt("file=fat:rw:{s}/{s},format=raw", .{ b.install_path, out_dir_name }),
        "-nographic",
        "-serial",
        "mon:stdio",
        "-no-reboot",
        "-enable-kvm",
        "-cpu",
        "host",
        "-s", // gdb on 1234
    };

    const qemu_cmd = b.addSystemCommand(&qemu_args);
    qemu_cmd.step.dependOn(b.getInstallStep());
    const run_qemu_cmd = b.step("run", "Run QEMU");
    run_qemu_cmd.dependOn(&qemu_cmd.step);
    run_qemu_cmd.dependOn(&patch2_cmd.step);
    run_qemu_cmd.dependOn(&patch3_cmd.step);
}

fn patch(b: *std.Build, exename: []const u8, cmdline: []const u8, install: *std.Build.Step.InstallFile) *std.Build.Step.Run {
    const out_dir_name = "img";

    const patch_args = [_][]const u8{
        "objcopy",
        "--add-section",
        b.fmt(".cmdlin=bin/{s}", .{cmdline}),
        "--change-section-vma",
        ".cmdlin=0xA0000",
        "--add-section",
        ".linux=bin/vmlinuz",
        "--change-section-vma",
        ".linux=0x1000000",
        "--add-section",
        ".initrd=bin/initrd.img",
        "--change-section-vma",
        ".initrd=0x3000000",

        //"bin/linux.efi.stub",
        b.fmt("zig-out/{s}/stub.efi", .{out_dir_name}),

        b.fmt("zig-out/{s}/efi/boot/{s}", .{ out_dir_name, exename }),
    };
    const patch_cmd = b.addSystemCommand(&patch_args);
    //b.getInstallStep().dependOn(&patch_cmd.step);
    patch_cmd.step.dependOn(&install.step);

    const patch2_args = [_][]const u8{
        "objcopy",
        "--adjust-vma",
        "0",
        b.fmt("zig-out/{s}/efi/boot/{s}", .{ out_dir_name, exename }),
    };
    const patch2_cmd = b.addSystemCommand(&patch2_args);
    patch2_cmd.step.dependOn(&patch_cmd.step);
    b.getInstallStep().dependOn(&patch2_cmd.step);
    return patch2_cmd;
}
