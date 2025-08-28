const uefi = @import("std").os.uefi;
const std = @import("std");

// Original:https://github.com/nrdmn/uefi-examples/

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

    // loaded_image has a device_handle, file_path(DevicePath), image_base,
    // image_size, image_data_type.

    // Open root directory
    var deviceFileSystem: *uefi.protocol.SimpleFileSystem = undefined;
    status = boot_services.handleProtocol(loaded_image.device_handle.?, &uefi.protocol.SimpleFileSystem.guid, @ptrCast(&deviceFileSystem));
    if (status != .success) {
        log("Unable to get SimpleFileSystem protocol: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    const config: [*:0]const u8 = @ptrFromInt(@intFromPtr(loaded_image.image_base + 0x20000000));
    log("Config: Address: {any}", .{config});
    log("{s}", .{config});

    // Split by newlines
    const configSlice = config[0..strlenA(config)];
    var configLines = std.mem.splitAny(u8, configSlice, "\n");

    // Get first line and parse as int
    const kernelLengthString = configLines.next().?;
    const kernelLength = std.fmt.parseInt(i32, kernelLengthString, 10) catch |err| {
        log("Error parsing number: {}", .{err});
        return .invalid_parameter;
    };
    log("{d}", .{kernelLength});

    // Get the next two string lines
    const kernelCmdLine = configLines.next().?;
    log("{s}", .{kernelCmdLine});
    const initrdSha = configLines.next().?;
    log("{s}", .{initrdSha});

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
    log("DPP {} {}", .{ status, rootDevicePath });

    var kernel_device_path_ptr: ?*const uefi.protocol.DevicePath = null;
    // Create device path for kernel by combining device path with kernel file path
    var kernel_dp_ptr: [*]u8 = undefined;

    const kernel_image_path = toUcs2("\\EFI\\LINUX\\KERNEL.EFI");
    // Allocate space for device path + file path node + end node
    const file_path_node_size = 4 + (kernel_image_path.len * 2); // header + UCS2 string
    const total_size = 256; // Conservative estimate for device path size

    // LLM-generated magic - I had no idea it's so complicated to create a damn path.
    status = boot_services.allocatePool(.loader_data, total_size, @ptrCast(&kernel_dp_ptr));
    if (status == .success) {
        // Copy the base device path (everything except the final end node)
        var current_dp = rootDevicePath;

        // Calculate size needed and copy device path nodes until we hit the end
        var offset: usize = 0;
        while (@intFromEnum(current_dp.type) != 0x7F or current_dp.subtype != 0xFF) { // Not end of device path
            const node_len = @as(usize, current_dp.length);
            @memcpy(kernel_dp_ptr[offset .. offset + node_len], @as([*]u8, @ptrCast(current_dp))[0..node_len]);
            offset += node_len;
            current_dp = @ptrFromInt(@intFromPtr(current_dp) + node_len);
        }

        // Add file path node
        kernel_dp_ptr[offset] = 4; // Media device path type
        kernel_dp_ptr[offset + 1] = 4; // File path subtype
        kernel_dp_ptr[offset + 2] = @intCast(file_path_node_size & 0xFF);
        kernel_dp_ptr[offset + 3] = @intCast((file_path_node_size >> 8) & 0xFF);
        @memcpy(kernel_dp_ptr[offset + 4 .. offset + 4 + (kernel_image_path.len * 2)], @as([*]u8, @ptrCast(@constCast(&kernel_image_path)))[0 .. kernel_image_path.len * 2]);
        offset += file_path_node_size;

        // Add end node
        kernel_dp_ptr[offset] = 0x7F; // End type
        kernel_dp_ptr[offset + 1] = 0xFF; // End subtype
        kernel_dp_ptr[offset + 2] = 4; // End node length (low byte)
        kernel_dp_ptr[offset + 3] = 0; // End node length (high byte)

        kernel_device_path_ptr = @ptrCast(@alignCast(kernel_dp_ptr));
    }

    // Size is pretty large - but virtual
    log("Loaded image: base={*} size={} ", .{ loaded_image.image_base, loaded_image.image_size });
    //log("Path {?} ", .{loaded_image.file_path.getDevicePath()});

    // The fs openVolume
    var root_dir: *const uefi.protocol.File = undefined;
    status = deviceFileSystem.openVolume(&root_dir);
    if (status != .success) {
        log("Unable to open root directory: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    if (!std.mem.eql(u8, initrdSha, "0")) {
        const initrd_image_path = toUcs2("\\EFI\\LINUX\\INITRD.IMG");
        var initrdHandle: *const uefi.protocol.File = undefined;
        status = root_dir.open(&initrdHandle, @ptrCast(&initrd_image_path), uefi.protocol.File.efi_file_mode_read, 0);
        log("initrd {} {}", .{ status, initrdHandle });

        // Read initrd file content and compute SHA-256
        // Use a reasonable buffer size for reading the file
        const max_file_size: usize = 64 * 1024 * 1024; // 64MB max
        var initrd_buffer: [*]u8 = undefined;
        status = boot_services.allocatePool(.loader_data, max_file_size, @ptrCast(&initrd_buffer));
        if (status != .success) {
            log("Unable to allocate: {}", .{status});
            _ = boot_services.stall(30 * 1000 * 1000);
            return .load_error;
        }
        var read_size: usize = max_file_size;
        status = initrdHandle.read(&read_size, initrd_buffer);
        if (status != .success) {
            log("Unable to read initrd: {}", .{status});
            _ = boot_services.stall(30 * 1000 * 1000);
            return .load_error;
        }
        log("Read {} bytes from initrd", .{read_size});

        // Compute SHA-256 hash
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initrd_buffer[0..read_size]);
        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        var initrdLoadedShaBuf: [64]u8 = undefined;
        const initrdLoadedSha = std.fmt.bufPrint(&initrdLoadedShaBuf, "{s}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
        log("Initrd SHA-256: {s}", .{initrdLoadedSha});

        if (!std.mem.eql(u8, initrdSha, initrdLoadedSha)) {
            log("Sha doesn't match: {s}", .{initrdSha});
            _ = boot_services.stall(30 * 1000 * 1000);
            return .load_error;
        }

        // Free the buffer
        _ = boot_services.freePool(@alignCast(initrd_buffer));
    }

    const kernelAddr: [*:0]const u8 = @ptrFromInt(@intFromPtr(loaded_image.image_base + 0x30000000));
    log("{*}", .{kernelAddr});

    var kimage: ?uefi.Handle = undefined;

    if (kernelLength == 0) {
        status = boot_services.loadImage(false, image, kernel_device_path_ptr, null, 0, &kimage);
        log("Loading of embedded Linux (disk): {}", .{status});
    } else {
        status = boot_services.loadImage(false, image, kernel_device_path_ptr, kernelAddr, @intCast(kernelLength), &kimage);
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

    // Convert runtime string to UCS-2 manually since toUcs2 requires comptime
    var cmdx_buffer: [256]u16 = [_]u16{0} ** 256; // Buffer for UCS-2 conversion
    for (kernelCmdLine, 0..) |ch, i| {
        if (i >= cmdx_buffer.len - 1) break; // Leave space for null terminator
        cmdx_buffer[i] = ch;
    }
    kloaded_image.load_options = @ptrCast(@constCast(&cmdx_buffer));
    kloaded_image.load_options_size = @intCast(kernelCmdLine.len * 2);

    log("Execution of embedded Linux image with options: {s}", .{kernelCmdLine});

    status = boot_services.startImage(kimage.?, null, null);

    log("Execution of embedded Linux image failed: {}", .{status});

    _ = boot_services.stall(30 * 1000 * 1000);
    return status;
}

fn log(
    comptime fmt: []const u8,
    args: anytype,
) void {
    std.fmt.format(
        Writer{ .context = {} },
        fmt ++ "\r\n",
        args,
    ) catch unreachable;
}

inline fn toUcs2(comptime s: [:0]const u8) [s.len * 2:0]u16 {
    var ucs2: [s.len * 2:0]u16 = [_:0]u16{0} ** (s.len * 2);
    for (s, 0..) |ch, i| {
        ucs2[i] = ch;
        ucs2[i + 1] = 0;
    }
    return ucs2;
}

const Sto = uefi.protocol.SimpleTextOutput;

var con_out: *Sto = undefined;

const Writer = std.io.Writer(
    void,
    LogError,
    writerFunction,
);

const LogError = error{};
fn writerFunction(_: void, bytes: []const u8) LogError!usize {
    for (bytes) |b| {
        con_out.outputString(&[_:0]u16{b}).err() catch unreachable;
    }
    return bytes.len;
}

fn strlenA(s: [*:0]const u8) usize {
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    return len;
}
