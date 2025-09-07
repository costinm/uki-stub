const uefi = @import("std").os.uefi;
const std = @import("std");

var boot_services: *uefi.tables.BootServices = undefined;

// Magic section with the config - address is fixed.
const CONFIG_SECTION = 0x20000000;

// The actual entry point is EfiMain. EfiMain takes two parameters, the
// EFI image's handle and the EFI system table, and writes them to
// uefi.handle and uefi.system_table, respectively. The EFI system table
// contains function pointers to access EFI facilities.
//
// main() can return void or usize.
pub fn main() uefi.Status {
    con_out = uefi.system_table.con_out.?;
    boot_services = uefi.system_table.boot_services.?;
    const selfHandle = uefi.handle;

    // Get loaded image protocol - info about the running program, including device.
    var selfLoadedImage: *uefi.protocol.LoadedImage = undefined;
    var status = boot_services.openProtocol(
        selfHandle,
        &uefi.protocol.LoadedImage.guid,
        @ptrCast(&selfLoadedImage),
        selfHandle,
        null,
        .{ .get_protocol = true },
    );
    if (status != .success) {
        return fatal(status, "Error getting loadedImageProtocol handle: {}", .{status});
    }

    // Open root directory - this is the 'filesystem protocol' on the device handle for the
    // loaded image.
    var deviceFileSystem: *uefi.protocol.SimpleFileSystem = undefined;
    status = boot_services.handleProtocol(selfLoadedImage.device_handle.?, &uefi.protocol.SimpleFileSystem.guid, @ptrCast(&deviceFileSystem));
    if (status != .success) {
        return fatal(status, "Unable to get SimpleFileSystem protocol: {}", .{status});
    }

    var rootDevicePath: *uefi.protocol.DevicePath = undefined;
    status = boot_services.handleProtocol(selfLoadedImage.device_handle.?, &uefi.protocol.DevicePath.guid, @ptrCast(&rootDevicePath));
    if (status != .success) {
        return fatal(status, "Unable to get root device path: {}", .{status});
    }

    var root_dir: *const uefi.protocol.File = undefined;
    status = deviceFileSystem.openVolume(&root_dir);
    if (status != .success) {
        return fatal(status, "Unable to open root directory: {}", .{status});
    }

    const config: [*:0]const u8 = @ptrFromInt(@intFromPtr(selfLoadedImage.image_base + CONFIG_SECTION));
    log("Config: Address: {any}", .{config});

    var kernelLength: i32 = 0;
    var kernelCmdLine: []const u8 = "";
    var cmdx_buffer: [256]u16 = [_]u16{0} ** 256; // Buffer for UCS-2 conversion
    var utf16_len: usize = 0;

    if (!std.mem.eql(u8, config[0..3], "UKI")) {
        return fatal(status, "Unsigned/unbound stub", .{});
    }
    log("VERIFIED BOOT: {s}\n---", .{config});

    // Split by newlines
    const configSlice = config[0..std.mem.len(config)];
    var configLines = std.mem.splitAny(u8, configSlice, "\n");
    // Skip UKI
    _ = configLines.next().?;

    kernelLength = std.fmt.parseInt(i32, configLines.next().?, 10) catch |err| {
        log("Error parsing number:  {}", .{err});
        return .invalid_parameter;
    };
    // If an initrd is used - it should be the next line
    const kernelSha = configLines.next().?;
    log("kernel SHA: {s}", .{kernelSha});

    const initrdLength = std.fmt.parseInt(usize, configLines.next().?, 10) catch |err| {
        log("Error parsing number:  {}", .{err});
        return .invalid_parameter;
    };
    const initrdSha = configLines.next().?;

    kernelCmdLine = configLines.next().?;
    utf16_len = std.unicode.utf8ToUtf16Le(&cmdx_buffer, kernelCmdLine) catch {
        log("Failed to convert cmdline to utf16", .{});
        return .invalid_parameter;
    };

    var initrdLen = initrdLength;
    var initrdBuf: [*]align(4096) u8 = undefined;

    // Must be allocated with allocatePages - allocatePool doesn't work
    if (initrdLength > 0) {
        // var addr: [*]align(4096) u8 = @ptrFromInt(0);
        const pages_needed: usize = @intCast(1 + @divTrunc((initrdLength + 0xfff), 0x1000));
        status = boot_services.allocatePages(.allocate_max_address, .loader_data, pages_needed, &initrdBuf);
        if (status != .success) {
            return fatal(status, "Unable to allocate: {}", .{status});
        }
        //initrdBuf = addr;
        const initrdPath2 = toUcs2("\\EFI\\LINUX\\INITRD.IMG");
        status = loadFile(root_dir, &initrdPath2, initrdBuf, &initrdLen);
        status = checkSha(initrdBuf, initrdLen, initrdSha);
        if (status != .success) {
            return fatal(status, "Unable to verify initrd: {}", .{status});
        }
    }

    const kernel_image_path = toUcs2("\\EFI\\LINUX\\KERNEL.EFI");
    var kernelBuf: [*]align(4096) u8 = undefined;

    if (kernelLength > 0) {
        kernelBuf = @ptrFromInt(@intFromPtr(selfLoadedImage.image_base + 0x20000000));
        const pages_needed: usize = @intCast(1 + @divTrunc((kernelLength + 0xfff), 0x1000));
        status = boot_services.allocatePages(.allocate_max_address, .loader_data, pages_needed, &kernelBuf);
        if (status != .success) {
            return fatal(status, "Unable to allocate: {}", .{status});
        }

        var rdKernelLen: usize = @intCast(kernelLength);
        status = loadFile(root_dir, &kernel_image_path, kernelBuf, &rdKernelLen);
        if (status != .success) {
            return fatal(status, "Unable to load kernel: {}", .{status});
        }

        status = checkSha(kernelBuf, rdKernelLen, kernelSha);
        if (status != .success) {
            return fatal(status, "Unable to verify kernel SHA: {}", .{status});
        }
        log("Loaded and checked kernel {} {*}", .{ rdKernelLen, kernelBuf });
    }

    if (true) {
        status = linuxExec(selfHandle, kernelCmdLine, @intFromPtr(kernelBuf), @intFromPtr(initrdBuf), initrdLen);
        if (status != .success) {
            return fatal(status, "Unable to load linux (direct): {}", .{status});
        }
    }

    // const kernelAddr: [*:0]const u8 = @ptrFromInt(@intFromPtr(selfLoadedImage.image_base + 0x30000000));
    // log("{*} {*}", .{ kernelAddr, kernelBuf });
    // var kimage: ?uefi.Handle = undefined;
    // var buffer: [1000]u8 = undefined;
    // var fba = std.heap.FixedBufferAllocator.init(&buffer);
    // const allocator = fba.allocator();
    // const kernelDevicePath = rootDevicePath.create_file_device_path(allocator, &kernel_image_path) catch |err| {
    //     log("Error creating device path: {}", .{err});
    //     return .invalid_parameter;
    // };
    // log("kLinePath {any}", .{kernelDevicePath});

    // cmdx_buffer[utf16_len] = 0;
    // status = boot_services.loadImage(true, selfHandle, kernelDevicePath, kernelAddr, @intCast(kernelLength), &kimage);
    // log("Loading of embedded Linux: (mem) {}", .{status});
    // if (status != .success) {
    //     log("Unable to load kernel.efi: {}", .{status});
    //     _ = boot_services.stall(30 * 1000 * 1000);
    //     return .load_error;
    // }

    // var kloaded_image: *uefi.protocol.LoadedImage = undefined;
    // status = boot_services.openProtocol(
    //     kimage.?,
    //     &uefi.protocol.LoadedImage.guid,
    //     @ptrCast(&kloaded_image),
    //     kimage,
    //     null,
    //     .{ .get_protocol = true },
    // );
    // if (status != .success) {
    //     log("Error getting kernel loadedImageProtocol handle: {}", .{status});
    //     _ = boot_services.stall(3 * 1000 * 1000);
    //     return status;
    // }

    // // Convert runtime string to UCS-2

    // kloaded_image.load_options = @ptrCast(&cmdx_buffer);
    // kloaded_image.load_options_size = @intCast(utf16_len * 2);

    // log("Execution of embedded Linux image with options: {s}", .{kernelCmdLine});

    // status = boot_services.startImage(kimage.?, null, null);

    // log("Execution of embedded Linux image failed: {}", .{status});

    // _ = boot_services.stall(30 * 1000 * 1000);
    return status;
}

const c = @cImport({
    @cInclude("linux.h"); // Include the C header if you have one
});
// Linux boot structures and constants
const SETUP_MAGIC: u32 = 0x53726448; // "HdrS"
const SetupHeader = c.SetupHeader;

// Architecture-specific handover function pointer type
const HandoverFn = *const fn (*anyopaque, *uefi.tables.SystemTable, *SetupHeader) callconv(.{ .x86_64_sysv = .{} }) void;

fn linuxEfiHandover(image: uefi.Handle, setup: *SetupHeader) void {
    // Disable interrupts for x86_64
    asm volatile ("cli");
    const handover_addr = setup.code32_start + 512 + setup.handover_offset;
    const handover: HandoverFn = @ptrFromInt(handover_addr);

    handover(@ptrFromInt(@intFromPtr(image)), uefi.system_table, setup);
}

fn linuxExec(
    image: uefi.Handle,
    cmdline: []const u8, // ?[*:0]const u8,
    linux_addr: usize,
    initrd_addr: usize,
    initrd_size: usize,
) uefi.Status {

    // Get image setup header from loaded kernel
    const image_setup: *SetupHeader = @ptrFromInt(linux_addr);

    // Validate Linux kernel header
    if (image_setup.signature != 0xAA55 or image_setup.header != SETUP_MAGIC) {
        log("Invalid signature {x} {x}", .{ linux_addr, image_setup.signature });
        return .load_error;
    }

    if (image_setup.version < 0x20b or image_setup.relocatable_kernel == 0) {
        log("Invalid version {x}", .{image_setup.version});
        return .load_error;
    }

    // Allocate memory for boot setup (16KB)
    var addr: [*]align(4096) u8 = @ptrFromInt(0x40000000);
    const pages_needed = @divTrunc((0x4000 + 0xfff), 0x1000); // EFI_SIZE_TO_PAGES equivalent
    var status = boot_services.allocatePages(.allocate_max_address, .loader_data, pages_needed, &addr);
    if (status != .success) {
        log("alloc error {x}", .{pages_needed});
        return status;
    }

    var boot_setup: *SetupHeader = @ptrCast(addr);

    // Zero memory and copy setup header
    @memset(@as([*]u8, @ptrCast(boot_setup))[0..0x4000], 0);
    @memcpy(@as([*]u8, @ptrCast(boot_setup))[0..@sizeOf(SetupHeader)], @as([*]const u8, @ptrCast(image_setup))[0..@sizeOf(SetupHeader)]);

    // Set loader ID for EFI protocol
    boot_setup.loader_id = 0xff;

    // Calculate kernel start address
    boot_setup.code32_start = @intCast(linux_addr + (@as(u32, image_setup.setup_secs) + 1) * 512);

    var cmdline_buf: [*]u8 = undefined;

    // const cmdline_pages = (cmdline.len + 0xfff) / 0x1000;
    status = boot_services.allocatePool(.loader_data, cmdline.len * 2, @ptrCast(&cmdline_buf));
    if (status != .success) {
        log("Unable to allocate: {}", .{status});
        return .load_error;
    }

    @memcpy(@as([*]u8, @ptrCast(cmdline_buf))[0..cmdline.len], @as([*]const u8, @ptrCast(cmdline.ptr))[0..cmdline.len]);
    cmdline_buf[cmdline.len] = 0;
    boot_setup.cmd_line_ptr = @intCast(@intFromPtr(cmdline_buf));

    // Setup initrd
    if (initrd_size > 0) {
        boot_setup.ramdisk_start = @intCast(initrd_addr);
        boot_setup.ramdisk_len = @intCast(initrd_size);
    }
    log("Linux handover code32_start={x} linux_addr={x} handover_offset={x} ", .{ boot_setup.code32_start, linux_addr, boot_setup.handover_offset });

    linuxEfiHandover(image, boot_setup);
    // Should never return
    return .load_error;
}

// Compute SHA-256 hash and compare with expected value
fn checkSha(src: [*]u8, src_size: usize, expectedSha: []const u8) uefi.Status {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(src[0..src_size]);

    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    var initrdLoadedShaBuf: [64]u8 = undefined;
    const initrdLoadedSha = std.fmt.bufPrint(&initrdLoadedShaBuf, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;

    if (!std.mem.eql(u8, expectedSha, initrdLoadedSha)) {
        log("Found SHA: {s}", .{initrdLoadedSha});
        log("Sha doesn't match: {s} {}", .{ expectedSha, src_size });
        return .load_error;
    }

    return uefi.Status.success;
}

// load content of the file. size should hold the expected size.
fn loadFile(root_dir: *const uefi.protocol.File, path: []const u16, destBuf: [*]u8, size: *usize) uefi.Status {
    var fileHandle: *const uefi.protocol.File = undefined;
    var status = root_dir.open(&fileHandle, @ptrCast(path), uefi.protocol.File.efi_file_mode_read, 0);
    if (status != .success) {
        log("Unable to open: {}", .{status});
        return .load_error;
    }

    status = fileHandle.read(size, destBuf);
    if (status != .success) {
        log("Unable to read cmdline: {}", .{status});
        return .load_error;
    }
    return uefi.Status.success;
}

// const (compile time) conversion to UCS-2, for the file names.
inline fn toUcs2(comptime s: [:0]const u8) [s.len * 2:0]u16 {
    var ucs2: [s.len * 2:0]u16 = [_:0]u16{0} ** (s.len * 2);
    for (s, 0..) |ch, i| {
        ucs2[i] = ch;
        ucs2[i + 1] = 0;
    }
    return ucs2;
}

// --- Writing to console functions ---

var con_out: *uefi.protocol.SimpleTextOutput = undefined;

const LogError = error{};

// Write to con_out as UTF16. Interface defined by std.io.Writer
fn writerFn(_: void, bytes: []const u8) LogError!usize {
    for (bytes) |b| {
        con_out.outputString(&[_:0]u16{b}).err() catch {};
    }
    return bytes.len;
}

const Writer = std.io.Writer(
    void,
    LogError,
    writerFn,
);

var conWriter = Writer{ .context = {} };

fn log(
    comptime fmt: []const u8,
    args: anytype,
) void {
    std.fmt.format(
        conWriter, // Writer{ .context = {} },
        fmt ++ "\r\n",
        args,
    ) catch {};
}

fn fatal(
    status: uefi.Status,
    comptime fmt: []const u8,
    args: anytype,
) uefi.Status {
    log(fmt, args);
    _ = boot_services.stall(3 * 1000 * 1000);
    return status;
}
