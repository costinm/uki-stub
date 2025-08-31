# Minimal UKI EFI stub

The stub is supposed to just find the kernel/initrd/cmdline and execute them. Nothing else.

It works by adding them as sections to the EFI binary - which can be done
using `objcopy`. 

## Code layout

I forked from version 48 of 10-year old gummibut - only the stub, not the boot loader.

gnu-efi, ovmf, qemu should be installed to build and test.

The stub is pretty simple and clean - it consists of 4 files:
- linux.c - parse kernel header and call the entry point.
  The EFI image and system tables are passed, as well as cmdline and initrd.

- pefile.c - parse the EFI (PE) file and find the kernel, initrd, 
  cmdline sections. The EFI file is like a 'tar' archive - files can have 8 bytes name ('sections'). Gets an 'dir' and 'path' as param.

- util.c - few utils to get 'TSC ticks' (using 'rdtsc' assembly and 1 sec 'Stall' call), efivar wrappers, utf8_to_16, stra_to_str, stra_to_path and file_read.

- stub.c - the entry point, 
    - will get metadata about itself, including DeviceHandle and FilePath 
    - read SecureBoot variable
    - load the sections from the (self) file
    - pass control to linux

I also forked efi-mkuki script - the upstream has gotten complicated and is switching to systemd stub, which is also very complex and full of uncommon features.

The goal of this project is to have clean and simple boot - not to be the
only way to boot, for complex needs the systemd stub (or another) may be
the right solution.

# Use

On a secure build machine:

1. Build or get a kernel.
2. Build an initrd - using a subset of kernel modules/firmware. Ideally using busybox and musl to keep it small.
3. Build a second initrd containing core configs - authorized_keys, mesh root CAs. Include the hash for the verity image or any other entity that needs to be verified.
4. Copy the stub and append the kernel, initrd, cmdline sections.
5. Sign the resulting efi - the signing keys should only be used on the secure build machine, or using a dedicated signing machine or service.

It is also possible to build host-specific EFI files by adding the hostname
and other host-specific configs to the second initrd.

Using different signing keys for hosts or groups of hosts is also possible.

On each host, remove all vendor keys and add only your signing keys.

Test - then enable secure boot and optionally set a BIOS password to prevent changes.


# Security

If secure boot is enabled, the BIOS/firmware  will verify the signature on the EFI file and refuse to run if the signature is wrong.

That includes all sections - so we know the kernel, cmdline and initrd have
not been modified. 

The recommended use is to customize the initrd to include the 'mesh' root key and core configurations for the host (or set of hosts), including a
'control plane' address. 

The signed EFI should be built on a trusted machine - with all expected features (verified inputs, isolated, etc) and should include the verity 
hashes for the images used  during boot, or use the built-in 'mesh' root
to verify signed files containing the hashes.


## Original work

https://gitlab.freedesktop.org/archived-projects/gummiboot from tag 48 (last before the package was abandoned).

## Others

https://github.com/puzzleos/stubby is a fork from the systemd stub, which
in turn (likely) used gummiboot. Clean - but still has a lot of complex
code around command line parsing. The signer of the EFI is expected to
be trusted to provide both a kernel, initrd - and reasonable command line.

There is also code to set various efi vars, etc.

https://github.com/usbarmory/go-boot/tree/main - boot loader in go. 
Includes uefi library
Part of "TagaGo" - bare metal Go ( no linux ) - like tinyGo, for EFI  
Also supports "trusted zone" execution of apps.

github.com/u-root/u-root - initrd in go

https://github.com/nrdmn/uefi-examples - uefi in zig

## Future ideas

- take advantage of watchdog timer (see zig example, setWatchdogTimer)

## SBAT 

SBAT is another complex spec - intended to revoke some components in the boot path, when the complex chainging of bootloader and kernels is used.

The minimal UKI is NOT intended to be chained or used with another bootloader. There is only the EFI firmware and the one signed BOOT.EFI 
file.

If one signed BOOT.EFI has a vulnerability and we want to prevent running it in future: generate a new signing key and update the hosts to use the new key and remove the old ones. It should be possible to do this with a custom EFI program - this is also the mitigation if the signing keys are compromised, rotating the signing keys would invalidate all older binaries.

SBAT is useful if you leave the vendor (Microsoft,etc) public keys - which 
would also allow anyone to boot an OS with grub or windows and take control.
With the minimal stub - all other signing keys should be removed, only 
the user trusted key should be used, and rotated as needed, each user
has their own key, on some secure build machine only.

