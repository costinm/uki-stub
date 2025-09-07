# Minimal UKI EFI stub

The main goal of this project is to have the simplest and least configurable
boot that I can find, for both normal and 'secure boot'. For 'secure boot' the 
goal is to only allow kernel/OS that is signed with user-specific keys - and 
disable vendor-signed OS/kernels. 

Linux kernel has EFI support and the simplest boot model is to have a kernel
with command line and initrd included and locked by not allowing command line changes.
The kernel can be signed and used as default boot - there is as simple as it goes
for boot loaders and stubs since none are required. The only problem with this 
approach is configuring the keys required to validate the rootfs (if dm-verity
or equivalent are used), but this can also be handled with an initrd that 
loads a signed rootfs configuration.

For a generic kernel - without command line/initrd baked-in - the stub is 
supposed to just find the kernel/cmdline/initrd and execute them. 
Nothing else - selecting the OS to boot is handled by the firmware already, any
fancy logo or UI can be shown by the firmware (because they are usually bloated
enough to have such features) and the actual rootfs.

There are 2 versions of stubs, one ready to use for 'unverified' boot, and one that needs
to be generated and locked to a user, based on user-owned signing keys. 

The locked version is only intended for 'secure boot', after configuring the user-owned keys as 'PK' (platform owner) and KEK/DB keys, in conjunction with TPM/2 and encrypted disks for advanced users concerned with evil-maid and other fancy attacks.

Note that "secure boot" is a big word - I will use "verified boot", as it only means
that CPU verifies the firmware in flash, the firmware verifies the boot stub, and the boot stub verifies that kernel/cmdline/initrd are signed. The initrd has the public key of the user - and can further verify the rootfs or any configurations. The flash on 
the motherboard is usually easy to modify - do not expect magic, but it is a bit
harder to run an OS not signed by the owner. "Verified boot" with the default keys shipping on a machine is not very secure - generic OSes which provide easy root access can be launched. It is critical to remove all existing keys and only install the user-owned keys, which in turn prevents other generic stubs (grub, systemd, etc) signed with vendor keys from loading and starting generic images.

Anyone with physical access can turn off secure boot - and then boot another OS and get almost full access. If the uEFI firmware allow password protection - it helps to
enable it, but it is still possible to flash the firmware (with a cheap and easy to
use device) and usually this wipes both secure boot and the other settings.

However - the private keys stored in a TPM however are protected - changing the secure boot mode or the keys would disable access to the private keys (if the policy is set correctly), which means the machine will not be able to unlock encrypted disks or use private  data. As long as 'verified boot' and TPM are used - along with encrypted 
disks with keys derived from the TPM - physical access to the machine does not allow access to the encrypted data.

Note that an attacker may disable verification and install a custom OS that looks 
the same and asks for a password to unlock the disk, then capture the password. Using 
the TPM keys only, or in combination with a machine-specific PIN (not the main user password) is likely a better approach.

## Unverified boot - zero config

In the vast majority of cases, and if you are not planning to use the TPM (or the machine is old and doesn't have TPM/2) - the simple stub is good enough, and having the simplest
and most clear startup helps avoiding a lot of pain.

Unlike grub and most other stubs - this stub is not configurable, the locations are 
hardcoded and very clear:
- /EFI/LINUX/KERNEL.EFI
- /EFI/LINUX/CMDLINE
- Optional: /EFI/LINUX/INITRD.IMG
- Stub should be: /EFI/BOOT/BOOTx64.EFI 
- It is expected that 2 or more small EFI partitions exist ( ~64M ), labeled BOOTA,
BOOTB - and for special cases BOOTR, BOOTUSB and "QEMU VVFAT". 
- upgrade will alternately replace BOOTA and BOOTB, set 'next boot', and if everything
works fine change the boot order until the next upgrade.
- you can have any other OSes - on different EFI partitions, or boot from USB and 
get access to any unencrypted disks or modify the CMDLINE, passwords on the rootfs or anything else, as with any other linux distro (including those that use 'secure boot' 
with the broadly open vendor keys).

This repo includes a generic busybox-based initrd - expecting a kernel that has 
EXT4 and storage drivers compiled in. The initrd may provide root access for recovery, if the real root is not found. It is however recommended that only the recovery EFI partition
uses the initrd - it is simpler and faster to directly load the rootfs. The rootfs is expected to be on an EXT4 partition labeled ROOT, and include /sbin/init.

For kernels not including ext4 and storage drivers - it is also possible to create an initrd with the missing drivers, using arch linux mkinitrd script (or in progress - 
extracting the drivers from the distro-generated initrd and using them with the custom
script and busybox).

# Verified ("secure") boot

See the 'security' comments below - this is a very fancy configuration that provides a bit more protection against 'evil maid'/'friends' with physical access. Secure boot
was intended to prevent users from loading their own OS (or attackers replacing the OS) - and only using the vendor-supplied OS.

On a secure build machine:

1. Generate (offline) the PK/KEK and DB keys, as well as a minisign key. 
2. Store DB and minisign keys as 'secrets' for the build machine. 
3. Build or get a kernel. Check if the kernel includes storage drivers and EXT4.
  4. If the kernel does not include this - generate an initrd (TODO: docs)
5. Run the "signer" to generate the efi disk content, including the signed and bound
/EFI/BOOT/BOOTx64.EFI file. 
6. Copy/distribute the EFI gradually to machines.

For initial install:

- on each host, remove all vendor keys and add only your signing keys.
- use a USB disk with the generated disk, and install the DB, KEK and PK keys (in this order).
- then enable secure boot and optionally set a BIOS password to prevent changes. In case of problems - disable secure boot and try with the unverified version.


## Code history

I initially forked from version 48 of 10-year old gummiboot - only the stub, not the boot loader. It still works if compiled with a specific version of the EFI library, but 
I converted it to Zig and used the zig standard library instead.

The resulting bootloader worked as well as the original and no longer had to deal with 
gnu-efi and complicated C build - but it was still far more complex than I wanted it to
be. 

For unverfied boot - there is no need to bother with UKI since nothing is signed. Leaving
the files in fixed and clear locations, and using EFI startImage is far, far simpler.

For verified boot, parsing the PE/COFF and finding sections - combined with an obscure 
script to merge kernel/cmdline/initrd in the same file also seemed far too complicated
and not needed. 

I am still using the UKI idea of adding a section to the EFI file - but that is only 
containing the command line and size and SHA256 of kernel and optional initrd. 

The plan is to move this to a file as well, sign it with minisign (or equivalent) and
only add the signing public key to the EFI, possibly as a build option.

## Original stub 

https://gitlab.freedesktop.org/archived-projects/gummiboot from tag 48 (last before the package was abandoned) was used.

The original gummiboot stub is pretty simple and clean - it consists of 4 files:
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


# Security

If secure boot is enabled, the BIOS/firmware  will verify the signature on the EFI file and refuse to run if the signature is wrong. 

IMPORTANT: there is very little protection against physical access to a machine ('evil maid', or 'friends and family'). In few motherboards I was able to flash the bios
with a cheap adapter - and disable the secure boot and reset the keys. An attacker
can replace almost everything and install a logger that captures your password. 

The main protection when 'verified boot' is enabled is in the TPM-protected keys,
which can be configured to only be available in a certain configuration, with the user-owned keys and secure boot enabled. That in turn protects encrypted disks.

There are still limits - but it is likely the best given the available hardware, 
as long as user-owned PK, TPM/2, encrypted disk are all used.

In the vast majority of cases - you don't need all this. If the laptop is stolen, having
an encrypted disk is good enough. Secure boot and TPM protects against a 'friend' 
replacing the OS to capture the encryption key and password. 


## Links and Others

https://depletionmode.com/uefi-boot.html - in-depth, including most important quote: "Secure Boot is not designed to defend against an attacker with physical access to a machine (keys are, by design, replaceable)."

https://github.com/puzzleos/stubby is a fork from the systemd stub, which
in turn (likely) used gummiboot. Clean - but still has a lot of complex
code around command line parsing. The signer of the EFI is expected to
be trusted to provide both a kernel, initrd - and reasonable command line.

There is also code to set various efi vars, etc.

https://git.sr.ht/~whynothugo/candyboot - rust based, using the 'new' protocol where initrd is loaded by kernel using a custom protocol, implemented by the stub. So far 
I don't think this works well since the kernel must be signed, which in turn means
it can be extracted and used standalone with custom command line.

https://github.com/usbarmory/go-boot/tree/main - boot loader in go. 
Includes uefi library
Part of "TagaGo" - bare metal Go ( no linux ) - like tinyGo, for EFI  
Also supports "trusted zone" execution of apps.

github.com/u-root/u-root - initrd in go

https://github.com/nrdmn/uefi-examples - uefi in zig

## SBAT 

SBAT is another complex spec - intended to revoke some components in the boot path, when the complex chainging of bootloader and kernels is used.

The minimal UKI is NOT intended to be chained or used with another bootloader. There is only the EFI firmware and the one signed BOOT.EFI file. If user keys are compromised - they can simply rotate the keys (DB, KEK and PK) on all machines. Periodic rotations
are also probably a good idea - but may be overkill. If one signed BOOT.EFI has a vulnerability and we want to prevent running it in future: generate a new signing key and update the hosts to use the new key and remove the old ones. It should be possible to do this with a custom EFI program - this is also the mitigation if the signing keys are compromised, rotating the signing keys would invalidate all older binaries.

SBAT is useful if you leave the vendor (Microsoft,etc) public keys - which 
would also allow anyone to boot an OS with grub or windows and take control.
With the minimal stub - all other signing keys should be removed, only 
the user trusted key should be used, and rotated as needed, each user
has their own key, on some secure build machine only.

