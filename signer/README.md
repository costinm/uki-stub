# UKI builder and signer

This is a container and script for creating a signed UKI EFI boot file.

The Dockerfile creates the signing container - but the actual creation
of the UKI must use local files on the 'admin' machine where the signing
takes place - the private keys for signing, mesh and core settings and other public keys, configs specific to groups of hosts. 

The signed EFI is personalized - either specific to a host or set of hosts.

# TODO

- instead of adding files to initrd, read the secure boot keys and use them to verify the sidecar image signature. This requires loading the EFI public keys.

- build an initrd and cmdline into a custom built kernel, remove the stub.

