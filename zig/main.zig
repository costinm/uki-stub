const uefi = @import("std").os.uefi;
const std = @import("std");

// Original:https://github.com/nrdmn/uefi-examples/
// Run: qemu-system-x86_64 -bios /usr/share/edk2-ovmf/OVMF_CODE.fd -hdd fat:rw:. -serial stdio
// Build:

// PE File structures and constants
const DosFileHeader = packed struct {
    magic0: u8,
    magic1: u8,
    last_size: u16,
    n_blocks: u16,
    n_reloc: u16,
    hdr_size: u16,
    min_alloc: u16,
    max_alloc: u16,
    ss: u16,
    sp: u16,
    checksum: u16,
    ip: u16,
    cs: u16,
    reloc_pos: u16,
    n_overlay: u16,
    reserved0: u16,
    reserved1: u16,
    reserved2: u16,
    reserved3: u16,
    oem_id: u16,
    oem_info: u16,
    reserved2_0: u16,
    reserved2_1: u16,
    reserved2_2: u16,
    reserved2_3: u16,
    reserved2_4: u16,
    reserved2_5: u16,
    reserved2_6: u16,
    reserved2_7: u16,
    reserved2_8: u16,
    reserved2_9: u16,
    exe_header: u32,
};

const PE_HEADER_MACHINE_I386: u16 = 0x014c;
const PE_HEADER_MACHINE_X64: u16 = 0x8664;

const PeFileHeader = packed struct {
    machine: u16,
    number_of_sections: u16,
    time_date_stamp: u32,
    pointer_to_symbol_table: u32,
    number_of_symbols: u32,
    size_of_optional_header: u16,
    characteristics: u16,
};

const PeSectionHeader = packed struct {
    name: u64,
    virtual_size: u32,
    virtual_address: u32,
    size_of_raw_data: u32,
    pointer_to_raw_data: u32,
    pointer_to_relocations: u32,
    pointer_to_linenumbers: u32,
    number_of_relocations: u16,
    number_of_linenumbers: u16,
    characteristics: u32,
};

fn strlenA(s: [*:0]const u8) usize {
    var len: usize = 0;
    while (s[len] != 0) : (len += 1) {}
    return len;
}

fn compareMemory(a: [*]const u8, b: [*]const u8, len: usize) i32 {
    for (0..len) |i| {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    return 0;
}

fn simpleChecksum(addr: usize, size: usize) u32 {
    const bytes: [*]const u8 = @ptrFromInt(addr);
    var checksum: u32 = 0;
    for (0..size) |i| {
        checksum +%= bytes[i];
    }
    return checksum;
}

fn hexDump(addr: usize, size: usize) void {
    const bytes: [*]const u8 = @ptrFromInt(addr);
    log("Hex dump at 0x{X} ({} bytes):", .{ addr, size });
    con_out.outputString(&[_:0]u16{ '0', 'x' }).err() catch unreachable;

    var i: usize = 0;
    while (i < size) {
        // if (i % 16 == 0) {
        //     if (i > 0) {
        //         log("", .{});
        //     }
        //     con_out.outputString(&[_:0]u16{ '0', 'x' }).err() catch unreachable;
        //     printHex(@intCast((addr + i) >> 24));
        //     printHex(@intCast((addr + i) >> 16));
        //     printHex(@intCast((addr + i) >> 8));
        //     printHex(@intCast(addr + i));
        //     con_out.outputString(&[_:0]u16{ ':', ' ' }).err() catch unreachable;
        // }

        printHex(bytes[i]);
        con_out.outputString(&[_:0]u16{' '}).err() catch unreachable;

        if (i % 16 == 15 or i == size - 1) {
            const remaining = 16 - (i % 16) - 1;
            for (0..remaining) |_| {
                con_out.outputString(&[_:0]u16{ ' ', ' ', ' ' }).err() catch unreachable;
            }
            con_out.outputString(&[_:0]u16{ ' ', '|' }).err() catch unreachable;

            const line_start = i - (i % 16);
            const line_end = @min(line_start + 16, size);
            for (line_start..line_end) |j| {
                const ch = bytes[j];
                if (ch >= 32 and ch <= 126) {
                    con_out.outputString(&[_:0]u16{ch}).err() catch unreachable;
                } else {
                    con_out.outputString(&[_:0]u16{'.'}).err() catch unreachable;
                }
            }
            con_out.outputString(&[_:0]u16{ '|', '\r', '\n' }).err() catch unreachable;
        }

        i += 1;
    }
}

fn printHex(value: u8) void {
    const hex_chars = "0123456789ABCDEF";
    con_out.outputString(&[_:0]u16{hex_chars[value >> 4]}).err() catch unreachable;
    con_out.outputString(&[_:0]u16{hex_chars[value & 0xF]}).err() catch unreachable;
}

fn pefileLocateSections(
    dir: *const uefi.protocol.File,
    path: [*:0]const u16,
    sections: [*]?[*:0]const u8,
    addrs: ?[*]usize,
    offsets: ?[*]usize,
    sizes: ?[*]usize,
) uefi.Status {
    var handle: *const uefi.protocol.File = undefined;

    const status = dir.open(&handle, path, uefi.protocol.File.efi_file_mode_read, 0);
    if (status != .success) {
        log("dir open failed {*}", .{path});
        return status;
    }
    defer _ = handle.close();

    // Read MS-DOS header
    var dos: DosFileHeader = undefined;
    var len: usize = @sizeOf(DosFileHeader);
    var read_status = handle.read(&len, @ptrCast(&dos));
    if (read_status != .success) {
        log("pefile read failed", .{});
        return read_status;
    }
    if (len != @sizeOf(DosFileHeader)) {
        return .load_error;
    }

    // Check DOS magic
    if (dos.magic0 != 'M' or dos.magic1 != 'Z') {
        log("pefile read failed magic", .{});
        return .load_error;
    }
    log("DOS header {} {x}", .{ len, dos.exe_header });

    // Seek to PE header
    read_status = handle.setPosition(dos.exe_header);
    if (read_status != .success) {
        return read_status;
    }

    // Read PE magic
    var magic: [4]u8 = undefined;
    len = @sizeOf(@TypeOf(magic));
    read_status = handle.read(&len, &magic);
    if (read_status != .success) {
        log("pefile read PE failed", .{});
        return read_status;
    }
    if (len != @sizeOf(@TypeOf(magic))) {
        return .load_error;
    }
    if (compareMemory(&magic, "PE\x00\x00", 4) != 0) {
        return .load_error;
    }
    log("PE magic ok {}", .{len});

    // Read PE file header
    var pe: PeFileHeader = undefined;
    len = @sizeOf(PeFileHeader);
    read_status = handle.read(&len, @ptrCast(&pe));
    if (read_status != .success) {
        return read_status;
    }
    log("Read PE ok2 {x} {}", .{ len, pe });

    if (len != @sizeOf(PeFileHeader)) {
        return .load_error;
    }

    // Validate machine type
    if (pe.machine != PE_HEADER_MACHINE_X64 and pe.machine != PE_HEADER_MACHINE_I386) {
        return .load_error;
    }

    if (pe.number_of_sections > 96) {
        return .load_error;
    }

    // Seek to section headers
    // Sections start after the headers
    var sections_offset = dos.exe_header +
        20 + pe.size_of_optional_header;
    log("Section offset: {x} = {x} 20 {x}", .{ sections_offset, dos.exe_header, pe.size_of_optional_header });
    log("PE size {x} {x}", .{ @sizeOf(PeFileHeader), @sizeOf(@TypeOf(PeFileHeader)) });

    // This was pretty off.
    // We have: 0x80 as PE section header
    //          0xF0 as extra header (170)
    // The pe is 20 bytes - plus 4 magic, 0x18 -

    sections_offset = 0x188;

    read_status = handle.setPosition(sections_offset);
    if (read_status != .success) {
        return read_status;
    }
    // handle.getPosition(position: *u64)
    log("Checking all sections {x} {} nr={}", .{ sections_offset, sections_offset, pe.number_of_sections });

    // Read section headers
    for (0..pe.number_of_sections) |_| {
        var sect: c.PeSectionHeader = undefined;
        len = @sizeOf(c.PeSectionHeader);

        read_status = handle.read(&len, @ptrCast(&sect));
        if (read_status != .success) {
            return read_status;
        }
        if (len != @sizeOf(c.PeSectionHeader)) {
            return .load_error;
        }
        //log("Checking section {} len={} {x} vs={} raw={}", .{ sn, len, sect.Name, sect.VirtualSize, sect.SizeOfRawData });

        // Check if this section matches any requested sections
        var j: usize = 0;
        while (sections[j]) |section_name| : (j += 1) {
            //const section_len = strlenA(section_name);
            //log("Checking in section {s}", .{section_name});
            if (compareMemory(@ptrCast(&sect.Name), section_name, strlenA(section_name)) == 0) {
                log("Found section {s} va={x} rawd={x} vs={x}", .{ section_name, sect.VirtualAddress, sect.PointerToRawData, sect.VirtualSize });
                if (addrs) |addr_array| {
                    addr_array[j] = sect.VirtualAddress;
                }
                if (offsets) |offset_array| {
                    offset_array[j] = sect.PointerToRawData;
                }
                if (sizes) |size_array| {
                    size_array[j] = sect.VirtualSize;
                }
            }
        }
    }

    return .success;
}

const c = @cImport({
    @cInclude("zig.h"); // Include the C header if you have one
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
    cmdline: ?[*:0]const u8,
    cmdline_len: usize,
    linux_addr: usize,
    initrd_addr: usize,
    initrd_size: usize,
) uefi.Status {
    const boot_services = uefi.system_table.boot_services.?;

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
    const pages_needed = (0x4000 + 0xfff) / 0x1000; // EFI_SIZE_TO_PAGES equivalent
    var alloc_status = boot_services.allocatePages(.allocate_max_address, .loader_data, pages_needed, &addr);
    if (alloc_status != .success) {
        log("alloc error {x}", .{pages_needed});
        return alloc_status;
    }

    //log("Linux alloc ok {x} {x}", .{ @intFromPtr(addr), pages_needed });
    var boot_setup: *SetupHeader = @ptrCast(addr);

    // Zero memory and copy setup header
    @memset(@as([*]u8, @ptrCast(boot_setup))[0..0x4000], 0);
    @memcpy(@as([*]u8, @ptrCast(boot_setup))[0..@sizeOf(SetupHeader)], @as([*]const u8, @ptrCast(image_setup))[0..@sizeOf(SetupHeader)]);

    // Set loader ID for EFI protocol
    boot_setup.loader_id = 0xff;

    // Calculate kernel start address
    boot_setup.code32_start = @intCast(linux_addr + (@as(u32, image_setup.setup_secs) + 1) * 512);

    // var cmdline_addr: [*]align(4096) u8 = @ptrFromInt(0xA0000);
    // alloc_status = boot_services.allocatePages(.allocate_max_address, .loader_data, 1, &cmdline_addr);
    // if (alloc_status != .success) {
    //     return alloc_status;
    // }
    // log("cmdline alloc ok {x} {x}", .{ @intFromPtr(cmdline_addr), 1 });
    // const cmdline_max_size =  256;
    // const cmdline1 = cmdline_addr[linux.layout.cmdline .. linux.layout.cmdline + cmdline_max_size];
    //const cmdline_val = "console=ttyS0,115200 loglevel=9 earlyprintk=serial nokaslr \x00";
    // @memset(cmdline1, 0);
    //@memcpy(cmdline_addr[0..cmdline_val.len], cmdline_val);
    //boot_setup.cmd_line_ptr = @intCast(@intFromPtr(cmdline_addr));

    //boot_setup.cmd_line_ptr = @intCast(@intFromPtr(cmdline_addr));

    // Setup command line if provided
    if (cmdline) |cmd| {
        //const cmdline_len = strlenA(cmd) + 1;

        var cmdline_addr: [*]align(4096) u8 = @ptrFromInt(0xA0000);
        const cmdline_pages = (cmdline_len + 0xfff) / 0x1000;
        alloc_status = boot_services.allocatePages(.allocate_max_address, .loader_data, cmdline_pages, &cmdline_addr);
        if (alloc_status != .success) {
            return alloc_status;
        }
        @memset(@as([*]u8, @ptrCast(cmdline_addr))[0..0x1000], 0);

        @memcpy(@as([*]u8, @ptrCast(cmdline_addr))[0..cmdline_len], @as([*]const u8, @ptrCast(cmd))[0..cmdline_len]);
        boot_setup.cmd_line_ptr = @intCast(@intFromPtr(cmdline_addr));
        boot_setup.cmdline_size = @intCast(cmdline_len);
        log("Linux cmdline {x} {}", .{ boot_setup.cmd_line_ptr, cmdline_len });
        log("Linux cmdline {?s}", .{cmdline});

        hexDump(boot_setup.cmd_line_ptr, cmdline_len + 4);
    }

    // Setup initrd
    boot_setup.ramdisk_start = @intCast(initrd_addr);
    boot_setup.ramdisk_len = @intCast(initrd_size);

    // boot_setup.ramdisk_len = 0;
    // boot_setup.ramdisk_start = 0;
    // boot_setup.cmd_line_ptr = 0;
    // boot_setup.cmdline_size = 0;

    // Transfer control to Linux kernel
    //log("Linux handover {x} {x}", .{ boot_setup.ramdisk_start, boot_setup.ramdisk_len });
    //Handover 18F2B000 (18F26000) B713F0 cmd=(9F000)
    //Handover 18f2b000 18f26000 B713f0
    log("Handover {x} {x} {x} cmd={x}", .{ boot_setup.code32_start, linux_addr, boot_setup.handover_offset, boot_setup.cmd_line_ptr });

    linuxEfiHandover(image, boot_setup);
    //c.linux_efi_handover(image, uefi.system_table, boot_setup);
    // Should never return
    return .load_error;
}

fn efiMainStub(image: uefi.Handle) uefi.Status {
    const boot_services = uefi.system_table.boot_services.?;

    // Get loaded image protocol
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
    var fs: *uefi.protocol.SimpleFileSystem = undefined;
    status = boot_services.handleProtocol(loaded_image.device_handle.?, &uefi.protocol.SimpleFileSystem.guid, @ptrCast(&fs));
    if (status != .success) {
        log("Unable to get SimpleFileSystem protocol: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    log("Loaded image: base={*} size={} ", .{ loaded_image.image_base, loaded_image.image_size });
    //log("Path {?} ", .{loaded_image.file_path.getDevicePath()});

    var root_dir: *const uefi.protocol.File = undefined;
    status = fs.openVolume(&root_dir);
    if (status != .success) {
        log("Unable to open root directory: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    // Define sections to locate
    const section_names = [_]?[*:0]const u8{
        ".cmdlin",
        ".linux",
        ".initrd",
        null,
    };

    var addrs = [_]usize{0} ** 3;
    var offs = [_]usize{0} ** 3;
    var szs = [_]usize{0} ** 3;

    // Get the device path string for the loaded image
    // Note: This is a simplified approach - the C version uses DevicePathToStr
    // For now we'll create a basic path representation
    const loaded_image_path = toUcs2("\\EFI\\BOOT\\BOOTX64.EFI");
    //const loaded_image_path = loaded_image.file_path.getDevicePath();

    log("Locating embedded sections in EFI binary...", .{});

    // Use pefile function to locate sections
    status = pefileLocateSections(root_dir, &loaded_image_path, @ptrCast(@constCast(&section_names)), &addrs, &offs, &szs);
    if (status != .success) {
        log("Unable to locate embedded .linux section: {}", .{status});
        _ = boot_services.stall(30 * 1000 * 1000);
        return status;
    }
    log("Found: {x}:{x}:{x} {x}:{x} {x}:{x}", .{ addrs[0], szs[0], offs[0], addrs[1], szs[1], addrs[2], szs[2] });

    const checksum = simpleChecksum(@intFromPtr(loaded_image.image_base) + addrs[1], szs[1]);
    // 5a657375
    log("Checksum for section at {x} (size {}): {x}", .{ addrs[1], szs[1], checksum });
    const checksum2 = simpleChecksum(@intFromPtr(loaded_image.image_base) + addrs[2], szs[2]);
    // 81d40a01
    log("Checksum for section at {x} (size {}): {x}", .{ addrs[2], szs[2], checksum2 });

    var cmdline: ?[*:0]const u8 = null;
    if (szs[0] > 0) {
        cmdline = @ptrFromInt(@intFromPtr(loaded_image.image_base + addrs[0]));
    }
    log("Cmdline: {any} {*}", .{ cmdline, cmdline });
    hexDump(@intFromPtr(loaded_image.image_base + addrs[0]), 16);

    if (szs[1] == 0) {
        log("No embedded Linux kernel found", .{});
        _ = boot_services.stall(30 * 1000 * 1000);
        return .load_error;
    }

    log("Executing Linux kernel...{x} {x} initrdaddr={x} initrdsize={x}", .{ @intFromPtr(loaded_image.image_base), addrs[1], addrs[2], szs[2] });
    status = linuxExec(
        image,
        cmdline,
        szs[0],
        @intFromPtr(loaded_image.image_base) + addrs[1],
        @intFromPtr(loaded_image.image_base) + addrs[2],
        szs[2],
    );

    log("Execution of embedded Linux image failed: {}", .{status});
    _ = boot_services.stall(30 * 1000 * 1000);
    return status;
}

// The actual entry point is EfiMain. EfiMain takes two parameters, the
// EFI image's handle and the EFI system table, and writes them to
// uefi.handle and uefi.system_table, respectively. The EFI system table
// contains function pointers to access EFI facilities.
//
// main() can return void or usize.
pub fn main() uefi.Status {
    con_out = uefi.system_table.con_out.?;

    // Clear screen. reset() returns usize(0) on success, like most
    // EFI functions. reset() can also return something else in case a
    // device error occurs, but we're going to ignore this possibility now.
    //_ = con_out.reset(false);

    // // EFI uses UCS-2 encoded null-terminated strings. UCS-2 encodes
    // // code points in exactly 16 bit. Unlike UTF-16, it does not support all
    // // Unicode code points.
    // _ = con_out.outputString(&[_:0]u16{ 'H', 'e', 'l', 'l', 'o', ',', ' ' });
    // _ = con_out.outputString(&[_:0]u16{ 'w', 'o', 'r', 'l', 'd', '\r', '\n' });
    // // EFI uses \r\n for line breaks (like Windows).

    // Boot services are EFI facilities that are only available during OS
    // initialization, i.e. before your OS takes over full control over the
    // hardware. Among these are functions to configure events, allocate
    // memory, load other EFI images, and access EFI protocols.
    const boot_services = uefi.system_table.boot_services.?;
    // There are also Runtime services which are available during normal
    // OS operation.

    _ = efiMainStub(uefi.handle);
    // var fs: *uefi.protocol.SimpleFileSystem = undefined;
    // var status = boot_services.locateProtocol(&uefi.protocol.SimpleFileSystem.guid, null, @ptrCast(&fs));
    // if (status != .success) {
    //     log("Failed to locate simple file system protocol.", .{});
    //     return status;
    // }
    // log("Located simple file system protocol.", .{});

    // var root_dir: *const uefi.protocol.File = undefined;
    // status = fs.openVolume(&root_dir);
    // if (status != .success) {
    //     log("Failed to open volume.", .{});
    //     return status;
    // }
    // log("Opened filesystem volume.", .{});

    // const kernel = openFile(root_dir, "vmlinuz") catch return .aborted;
    // log("Opened kernel file.", .{});

    // var header_size: usize = @sizeOf(std.elf.Elf64_Ehdr);
    // var header_buffer: [*]align(8) u8 = undefined;
    // status = boot_services.allocatePool(.loader_data, header_size, &header_buffer);
    // if (status != .success) {
    //     log("Failed to allocate memory for kernel ELF header.", .{});
    //     return status;
    // }

    // status = kernel.read(&header_size, header_buffer);
    // if (status != .success) {
    //     log("Failed to read kernel ELF header.", .{});
    //     return status;
    // }

    // c.bootlinux();

    // const elf_header = std.elf.Header.parse(header_buffer[0..@sizeOf(std.elf.Elf64_Ehdr)]) catch |err| {
    //     log("Failed to parse kernel ELF header: {?}", .{err});
    //     return .aborted;
    // };
    // log("Parsed kernel ELF header.", .{});
    // log(
    //     \\Kernel ELF information:
    //     \\  Entry Point         : 0x{X}
    //     \\  Is 64-bit           : {d}
    //     \\  # of Program Headers: {d}
    //     \\  # of Section Headers: {d}
    // ,
    //     .{
    //         elf_header.entry,
    //         @intFromBool(elf_header.is_64),
    //         elf_header.phnum,
    //         elf_header.shnum,
    //     },
    // );

    // uefi.system_table.con_out and uefi.system_table.boot_services should be
    // set to null after you're done initializing everything. Until then, we
    // don't need to worry about them being inaccessible.

    // Wait 5 seconds.
    _ = boot_services.stall(10 * 1000 * 1000);

    // If main()'s type is void, EfiMain will return usize(0). On return,
    // control is transferred back to the calling EFI image.
    return .success;
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

fn openFile(
    root: *const uefi.protocol.File,
    comptime name: [:0]const u8,
) !*const uefi.protocol.File {
    var file: *const uefi.protocol.File = undefined;
    const status = root.open(
        &file,
        &toUcs2(name),
        uefi.protocol.File.efi_file_mode_read,
        0,
    );

    if (status != .success) {
        log("Failed to open file: {s}", .{name});
        return error.aborted;
    }
    return file;
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
