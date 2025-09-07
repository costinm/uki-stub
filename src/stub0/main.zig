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
    const selfHandle = uefi.handle;
    var buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

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
        log("Error getting loadedImageProtocol handle: {}", .{status});
        _ = boot_services.stall(3 * 1000 * 1000);
        return status;
    }

    // Open root directory - this is the 'filesystem protocol' on the device handle for the
    // loaded image.
    var deviceFileSystem: *uefi.protocol.SimpleFileSystem = undefined;
    status = boot_services.handleProtocol(selfLoadedImage.device_handle.?, &uefi.protocol.SimpleFileSystem.guid, @ptrCast(&deviceFileSystem));
    if (status != .success) {
        log("Unable to get SimpleFileSystem protocol: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }
    var rootDevicePath: *uefi.protocol.DevicePath = undefined;
    status = boot_services.handleProtocol(selfLoadedImage.device_handle.?, &uefi.protocol.DevicePath.guid, @ptrCast(&rootDevicePath));
    if (status != .success) {
        log("Unable to get root device path: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    // The fs openVolume returns a File object - which is File protocol.
    //
    var root_dir: *const uefi.protocol.File = undefined;
    status = deviceFileSystem.openVolume(&root_dir);
    if (status != .success) {
        log("Unable to open root directory: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    var cmd_size: usize = 64 * 1024; // 64kB max
    var cmdline_buffer: [*]u8 = undefined;
    status = boot_services.allocatePool(.loader_data, cmd_size, @ptrCast(&cmdline_buffer));
    if (status != .success) {
        log("Unable to allocate: {}", .{status});
        return .load_error;
    }
    const cmdline_path = comptime toUcs2("\\EFI\\LINUX\\CMDLINE");
    _ = loadFile(root_dir, &cmdline_path, cmdline_buffer, &cmd_size);
    const cmd = cmdline_buffer[0..cmd_size];
    log("Cmdline: {s} len={}", .{ cmd, cmd.len });
    var cmdx_buffer: [256]u16 = [_]u16{0} ** 256; // Buffer for UCS-2 conversion
    const utf16_len: usize = 2 * cmd_size;
    for (0..cmd_size) |i| {
        cmdx_buffer[i] = cmdline_buffer[i];
    }
    cmdx_buffer[cmd_size + 1] = 0;
    // Free the buffer
    _ = boot_services.freePool(@alignCast(cmdline_buffer));

    // Construct the path for the kernel - it is not used since binary is added as a section,
    // but it is a required parameter. In some cases we may use the file (with a SHA check),
    // not clear if it has any benefit.

    const kernel_image_path = comptime toUcs2("\\EFI\\LINUX\\KERNEL.EFI");

    // acpi.hardware.messaging.media
    const kernelDevicePath = rootDevicePath.create_file_device_path(allocator, &kernel_image_path) catch |err| {
        log("Error creating device path: {}", .{err});
        return .invalid_parameter;
    };

    var kimage: ?uefi.Handle = undefined;
    status = boot_services.loadImage(true, selfHandle, kernelDevicePath, null, 0, &kimage);
    if (status != .success) {
        log("Unable to load kernel.efi: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    // Get the LoadedImage object associated with the loaded
    // kernel image to set the command line.
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

    kloaded_image.load_options = @ptrCast(&cmdx_buffer);
    kloaded_image.load_options_size = @intCast(utf16_len * 2);

    log("Unverified Linux startImage", .{});

    status = boot_services.startImage(kimage.?, null, null);

    log("Execution of embedded Linux image failed: {}", .{status});

    _ = boot_services.stall(30 * 1000 * 1000);
    return status;
}

fn loadFile(root_dir: *const uefi.protocol.File, cmdline_path: []const u16, destBuf: [*]u8, size: *usize) uefi.Status {
    var cmdlineHandle: *const uefi.protocol.File = undefined;
    var status = root_dir.open(&cmdlineHandle, @ptrCast(cmdline_path), uefi.protocol.File.efi_file_mode_read, 0);
    if (status != .success) {
        log("Unable to open: {}", .{status});
        return .load_error;
    }

    status = cmdlineHandle.read(size, destBuf);
    if (status != .success) {
        log("Unable to read cmdline: {}", .{status});
        return .load_error;
    }
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
