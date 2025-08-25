# Go EFI

While translating the simple gummiboot stub to Zig was fun, I want to
take this further - the UKI approach is still to complex.

UKI combines Linux Kernel, initrd and command under a single signature, which can be loaded directly from the uEFI firmware, leaving the initrd
figure out how to verify the rootfs - for example by embedding the hash
in the command line.

But fundamentally the security is derived from the 'platform key' that
is registered in the uEFI (or any other firmware !) and signs the first
efi file executing - which in turn can verify other files either using 
embedded hashes or by checking signatures. 

https://wiki.gentoo.org/wiki/Secure_Boot/GRUB#Installing_the_Keys_to_the_UEFI  

## UEFI keys

PlatformKey is at the root, usually RSA-2048 - and is used as a root certificate for the 'owner'. It can enroll KEKs.

KeyExchangeKey is intended for the OS vendor, as a master key - the images
are signed with another key, which is managed by the KEK. So a 3-layer certificate.

Normally a firmware will have vendor platform keys and MSFT and other KEKs,
meaning if secure boot is enabled A LOT of software can run giving control
over most of the hardware. The first step should be to remove those keys
and only keep 2 keys - the 'owner' (org or user owning the machines) and
one used by the build system that creates the EFI files and signs other
artrifacts.

If no platform key is enrolled - uEFI is in 'setup mode=1' - meaning keys
can be installed without authentication.

"AuditMode=0" - user mode -  is used to still boot untrusted images. Deployed mode is when only signed EFI binaries can be loaded.

BootService.SetVariable is used to set the key - in setup mode self-signed
works, in user mode the new key is signed with the old one (rotation).

DeployedMode=1 enables the secure mode.

KEK can be set at will when PK is not set, otherwise must be signed by PK.

The signature database (DB) is the actual signer

## New EFI initrd protocol

With the not-deprecated but not ready yet protocol - kernel is started
as an EFI program, possibly verified. 

Kernel uses EFI_LOAD_FILE2_PROTOCOL_GUID as a protocol to load the file.

https://uefi.org/specs/UEFI/2.10/index.html

The command line and launch are using the standard EFI mechanism - the problem is how to verify the initrd. So a 'stub' is still required, that 
will check the sha256 of the initrd - before calling linux.

Grub does that using pgp detached signatures - the detached part is great,
no need for complex format for the signed file - but pgp is a bit old.

## Go EFI options

Tamago-go and tinygo both have support for UEFI - unfortunately the tinygo patch
is not [merged](https://github.com/tinygo-org/tinygo/pull/3996/commits/0bbef2a19dbbd2a7d770f8c9d8864542754c8a38#) since 2023. https://github.com/sparques/tinygo-uefi-poc shows an alternative that doesn't require changes to tinygo.

It would be ideal to combine all 3 in a single uefi repo that works with both tamago and
tinygo (and perhaps upstream golang win32), and add common support for all features.

For my needs - tamago with few patches is sufficient and even better as forcing a more
minimal use of EFI - and using go to verify and linux to do the rest.




# TODO

- place linux under ${BOOT}\EFI\Linux ( nod to uapi-group.org - but this is NOT intended for multi-boot loading)
    - initrd and cmdline in the same place
    - manifest - with name, SHA of each file (jar ?)
    - manifest.sig

https://uapi-group.org/specifications/specs/linux_tpm_pcr_registry/
- 0 - core firmware
- 1 - host data
- 2 - including boot roms
- 3 - extra hardware data
- 4 - BOOT LOADERS, extensions
- 5 - GPT table
- 7 - Secure boot state !!!!
- 8,9 - grub commands, 9 includes kernel and initrd
-

https://uapi-group.org/specifications/specs/unified_kernel_image/
- nod - use .linux, .cmdline, .initrd
- ignore everything else, complex and insecure.

