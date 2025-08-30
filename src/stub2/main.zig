const uefi = @import("std").os.uefi;
const std = @import("std");


// The actual entry point is EfiMain. EfiMain takes two parameters, the
// EFI image's handle and the EFI system table, and writes them to
// uefi.handle and uefi.system_table, respectively. The EFI system table
// contains function pointers to access EFI facilities.
//
// main() can return void or usize.
pub fn main() uefi.Status {
    con_out = uefi.system_table.con_out.?;
    const boot_services = uefi.system_table.boot_services.?;
    const image = uefi.handle;

    // Get loaded image protocol - info about the running program, including device.
    var loaded_image: *uefi.protocol.LoadedImage = undefined;
    var status = boot_services.openProtocol(
        image,
        &uefi.protocol.LoadedImage.guid,
        @ptrCast(&loaded_image),
        image,
        null,
        .{ .get_protocol = true },
    );
    if (status != .success) {
        log("Error getting loadedImageProtocol handle: {}", .{status});
        _ = boot_services.stall(3 * 1000 * 1000);
        return status;
    }

    // Open root directory
    var deviceFileSystem: *uefi.protocol.SimpleFileSystem = undefined;
    status = boot_services.handleProtocol(loaded_image.device_handle.?, &uefi.protocol.SimpleFileSystem.guid, @ptrCast(&deviceFileSystem));
    if (status != .success) {
        log("Unable to get SimpleFileSystem protocol: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    // The fs openVolume
    var root_dir: *const uefi.protocol.File = undefined;
    status = deviceFileSystem.openVolume(&root_dir);
    if (status != .success) {
        log("Unable to open root directory: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    // loaded_image has a device_handle, file_path(DevicePath), image_base,
    // image_size, image_data_type.

    const config: [*:0]const u8 = @ptrFromInt(@intFromPtr(loaded_image.image_base + 0x20000000));
    log("Config: Address: {any}", .{config});

    var kernelLength: i32 = 0;
    var kernelCmdLine: []const u8 = "";
    var cmdx_buffer: [256]u16 = [_]u16{0} ** 256; // Buffer for UCS-2 conversion
    var utf16_len: usize = 0;

    if (!std.mem.eql(u8, config[0..3], "UKI")) {
        log("Unverified boot, using \\EFI\\LINUX directory and KERNEL.EFI, CMDLINE ", .{});
        _ = loadCmdline(root_dir, boot_services, &cmdx_buffer, &utf16_len);
    } else {
        log("VERIFIED BOOT: {s}\n---\n", .{config});
        // Split by newlines
        const configSlice = config[0..std.mem.len(config)];
        var configLines = std.mem.splitAny(u8, configSlice, "\n");
        // Skip UKI
        _ = configLines.next().?;

        kernelLength = std.fmt.parseInt(i32, configLines.next().?, 10) catch |err| {
            log("Error parsing number:  {}", .{err});
            return .invalid_parameter;
        };
        kernelCmdLine = configLines.next().?;
        utf16_len = std.unicode.utf8ToUtf16Le(&cmdx_buffer, kernelCmdLine) catch {
            log("Failed to convert cmdline to utf16", .{});
            return .invalid_parameter;
        };
        cmdx_buffer[utf16_len] = 0;

        // If an initrd is used - it should be the next line
        const initrdSha = configLines.next().?;
        log("Initrd SHA: {s}", .{initrdSha});

        if (!std.mem.eql(u8, initrdSha, "0")) {
            status = loadAndSha(root_dir, boot_services, initrdSha);
            if (status != .success) {
                log("Unable to verify initrd: {}", .{status});
                _ = boot_services.stall(30 * 1000 * 1000);
                return .load_error;
            }
        }
    }

    // Construct the path for the kernel - it is not used since binary is added as a section,
    // but it is a required parameter. In some cases we may use the file (with a SHA check),
    // not clear if it has any benefit.
    var rootDevicePath: *uefi.protocol.DevicePath = undefined;
    status = boot_services.handleProtocol(loaded_image.device_handle.?, &uefi.protocol.DevicePath.guid, @ptrCast(&rootDevicePath));
    if (status != .success) {
        log("Unable to get root device path: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    const kernel_image_path = toUcs2("\\EFI\\LINUX\\KERNEL.EFI");

    var buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();
    const kernelDevicePath = rootDevicePath.create_file_device_path(allocator, &kernel_image_path) catch |err| {
        log("Error creating device path: {}", .{err});
        return .invalid_parameter;
    };
    log("kLinePath {any}", .{kernelDevicePath});

    const kernelAddr: [*:0]const u8 = @ptrFromInt(@intFromPtr(loaded_image.image_base + 0x30000000));
    log("{*}", .{kernelAddr});

    var kimage: ?uefi.Handle = undefined;

    if (kernelLength == 0) {
        status = boot_services.loadImage(false, image, kernelDevicePath, null, 0, &kimage);
        log("Loading Linux (disk): {}", .{status});
    } else {
        status = boot_services.loadImage(false, image, kernelDevicePath, kernelAddr, @intCast(kernelLength), &kimage);
        log("Loading of embedded Linux: (mem) {}", .{status});
    }
    if (status != .success) {
        log("Unable to load kernel.efi: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    var kloaded_image: *uefi.protocol.LoadedImage = undefined;
    status = boot_services.openProtocol(
        kimage.?,
        &uefi.protocol.LoadedImage.guid,
        @ptrCast(&kloaded_image),
        kimage,
        null,
        .{ .get_protocol = true },
    );
    if (status != .success) {
        log("Error getting kernel loadedImageProtocol handle: {}", .{status});
        _ = boot_services.stall(3 * 1000 * 1000);
        return status;
    }

    // Convert runtime string to UCS-2

    kloaded_image.load_options = @ptrCast(&cmdx_buffer);
    kloaded_image.load_options_size = @intCast(utf16_len * 2);

    log("Execution of embedded Linux image with options: {s}", .{kernelCmdLine});

    status = boot_services.startImage(kimage.?, null, null);

    log("Execution of embedded Linux image failed: {}", .{status});

    _ = boot_services.stall(30 * 1000 * 1000);
    return status;
}

fn loadAndSha(root_dir: *const uefi.protocol.File, boot_services: *uefi.tables.BootServices, initrdSha: []const u8) uefi.Status {
    const initrd_image_path = toUcs2("\\EFI\\LINUX\\INITRD.IMG");
    var initrdHandle: *const uefi.protocol.File = undefined;
    var status = root_dir.open(&initrdHandle, @ptrCast(&initrd_image_path), uefi.protocol.File.efi_file_mode_read, 0);
    if (status != .success) {
        log("Unable to open: {}", .{status});
        return .load_error;
    }

    // Read initrd file content and compute SHA-256
    // Use a reasonable buffer size for reading the file
    const max_file_size: usize = 64 * 1024 * 1024; // 64MB max
    var initrd_buffer: [*]u8 = undefined;
    status = boot_services.allocatePool(.loader_data, max_file_size, @ptrCast(&initrd_buffer));
    if (status != .success) {
        log("Unable to allocate: {}", .{status});
        return .load_error;
    }

    var read_size: usize = max_file_size;
    status = initrdHandle.read(&read_size, initrd_buffer);
    if (status != .success) {
        log("Unable to read initrd: {}", .{status});
        return .load_error;
    }

    // Compute SHA-256 hash
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(initrd_buffer[0..read_size]);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    var initrdLoadedShaBuf: [64]u8 = undefined;
    const initrdLoadedSha = std.fmt.bufPrint(&initrdLoadedShaBuf, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
    log("Initrd SHA-256: {s}", .{initrdLoadedSha});

    if (!std.mem.eql(u8, initrdSha, initrdLoadedSha)) {
        log("Sha doesn't match: {s} {}", .{ initrdSha, read_size });
        return .load_error;
    }

    // Free the buffer
    _ = boot_services.freePool(@alignCast(initrd_buffer));
    return uefi.Status.success;
}

// loadCmdline will load the CMDLINE file to the utf16 buffer for kernel.
fn loadCmdline(root_dir: *const uefi.protocol.File, boot_services: *uefi.tables.BootServices, dest: []u16, len: *usize) uefi.Status {
    const cmdline_path = toUcs2("\\EFI\\LINUX\\CMDLINE");
    var cmdlineHandle: *const uefi.protocol.File = undefined;
    var status = root_dir.open(&cmdlineHandle, @ptrCast(&cmdline_path), uefi.protocol.File.efi_file_mode_read, 0);
    if (status != .success) {
        log("Unable to open: {}", .{status});
        return .load_error;
    }

    const max_file_size: usize = 64 * 1024; // 64kB max
    var cmdline_buffer: [*]u8 = undefined;
    status = boot_services.allocatePool(.loader_data, max_file_size, @ptrCast(&cmdline_buffer));
    if (status != .success) {
        log("Unable to allocate: {}", .{status});
        return .load_error;
    }

    var read_size: usize = max_file_size;
    status = cmdlineHandle.read(&read_size, cmdline_buffer);
    len.* = read_size * 2;
    if (status != .success) {
        log("Unable to read cmdline: {}", .{status});
        return .load_error;
    }
    log("Cmdline {} bytes{s}", .{ read_size, cmdline_buffer[0..read_size] });
    for (0..read_size) |i| {
        dest[i] = cmdline_buffer[i];
    }

    dest[read_size + 1] = 0;

    // Free the buffer
    _ = boot_services.freePool(@alignCast(cmdline_buffer));
    return uefi.Status.success;
}

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
