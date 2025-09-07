#!/bin/bash

# Build and test script
# Modern languages (go/rust/zig) include optimized build systems (and package
# management).
# Makefiles main feature - checking mod time and controlling the build
# is no longer needed.
# 
# Testing on the other side should not be part of a specific language.
# Shell and python seem better fit to work across languages.


set -e

# Build configuration
BASE=$(dirname "$0")
PROJECT_ROOT="$(cd "${BASE}" && pwd)"
SRC=${PROJECT_ROOT}
PROJECT=$(basename ${PROJECT_ROOT})

BUILD_DIR=${HOME}/.cache/${PROJECT}

export ZIG_LOCAL_CACHE_DIR=${BUILD_DIR}/.zig-cache

# QEMU configuration
OVMF_PATH="${PROJECT_ROOT}/prebuilt/OVMF.fd"
MOUNT_DIR="${BUILD_DIR}/mnt"

# Hardcoded in stub - any change must be done in both places.
kernel_offset='0x30000000' 
cfg_offset=0x20000000

#mkdir -p "${BUILD_DIR}"

build() {
    local dir=${1:-src/stub2}
    (cd ${dir} && zig build -p ${BUILD_DIR} -freference-trace=8)
}

buildr() {
    (cd src/stub2g && cargo build --target x86_64-unknown-uefi)
    cp src/stub2g/target/x86_64-unknown-uefi/debug/uki-stub.efi prebuilt/uki-stub.efi
}

run_qemu() {    
    FATDIR=${1}
    local SECURE=${2:-0}

    #readpe ${BUILD_DIR}/efi-verify-stub.efi
    #readpe ${BUILD_DIR}/qemu/EFI/BOOT/bootx64.efi

# -drive id=mysdcard,if=none,format=qcow2,file=/path/to/backing_file.qcow2 \
#   -device sdhci-pci \
#   -device sd-card,drive=mysdcard

# -drive file=nvm.img,if=none,id=nvm
# -device nvme,serial=deadbeef,drive=nvm
#-bios "${OVMF_PATH}" \

#        -drive if=pflash,format=raw,file=prebuilt/OVMF_2M.fd \
    # Using a debian 2.7.0 UEFI, 2M + vars    
#-boot menu=on \

    OVMF="-drive if=pflash,format=raw,file=prebuilt/OVMF.fd"
    if [ ${SECURE} -eq 1 ]; then
        OVMF="${OVMF} --drive if=pflash,format=raw,file=prebuilt/OVMF_VARS.fd"
    fi

    qemu_base="-m 1G -smp 4 -cpu host -enable-kvm"
    #qemu_common="${qemu_base} -display none"
    qemu_common="${qemu_base} -nographic"
    #qemu_common="${qemu_base} -display gtk -vga std"

    # On reboot - exists, let caller to restart
    qemu_common="${qemu_common} -no-reboot"

    #qemu_serial="-serial stdio"
    qemu_serial="-chardev stdio,mux=on,id=char0 -serial chardev:char0 -monitor chardev:char0" 
    # stdio - no input ?
    # mon:stdio - C-a xa
	# -display none -serial stdio

    
    qemu-system-x86_64 -nodefaults ${qemu_common} \
        ${qemu_serial} \
        -drive file=fat:rw:${FATDIR},format=raw \
        -drive file=prebuilt/sidecar.sqfs,format=raw \
         ${OVMF} \
        -net user,hostfwd=tcp::10022-:22 
 
    # user mode network defaults:
    # 10.0.2.2, DNS 10.0.2.3
}


# Verified boot with initrd.
secure() {
    cfg=${1:-prebuilt/cfg.qemu}
    build
    cp ${BUILD_DIR}/img/ministub.efi prebuilt/uki-stub.efi

    [ -f prebuilt/testdata/uefi-keys/db.key ] || init_secrets ${SRC}/prebuilt/testdata

    cctl run ${PROJECT} \
        -e KERNEL_DIR=/ws/prebuilt/boot \
        -e STUB=/ws/prebuilt/uki-stub.efi \
        --entrypoint /ws/signer/sbin/setup-efi \
            signer base_initrd

    SECRETS=${SRC}/prebuilt/testdata \
        cctl run ${PROJECT} \
            -e KERNEL_DIR=/ws/prebuilt/boot \
            -e STUB=/ws/prebuilt/uki-stub.efi \
            --entrypoint /ws/signer/sbin/setup-efi \
                signer efi "console=ttyS0,115200"
                
                
    # initrd=\\EFI\\LINUX\\INITRD.IMG if using the new protocol 
    # rdinit=/bin/sh - to debug the initrd


    #echo "Adjust vma"
    # This corrects putting sections below the base image of the stub.
    #objcopy --adjust-vma 0  ${BUILD_DIR}/qemu/EFI/BOOT/bootx64.efi
    run_qemu ${BUILD_DIR}/efi 1
}

# Install and test environment
# 
# The 'signer' docker image expects:
# /data - the work directory. Some files may be already present - like efi/EFI/LINUX/INITRD.IMG
# /mnt/modloop - an mounted image containing vmlinux and modules
# /var/run/secrets - if SECRETS env var is set, will contain signing keys
# /ws - current dir, optional. If present it can avoid rebuilding the image.
# 
# The script - /sbin/setup-efi - will use few env variables to allow other
# locations to be used for KERNEL, STUB

secure_noinitrd() {
    cfg=${1:-prebuilt/cfg.qemu}
    build
    cp ${BUILD_DIR}/img/ministub.efi prebuilt/uki-stub.efi

    [ -f prebuilt/testdata/uefi-keys/db.key ] || init_secrets ${SRC}/prebuilt/testdata

    SECRETS=${SRC}/prebuilt/testdata \
        cctl run ${PROJECT} \
            -e INITRD=NONE \
            -e KERNEL=/ws/prebuilt/boot/vmlinuz \
            -e STUB=/ws/prebuilt/uki-stub.efi \
            --entrypoint /ws/signer/sbin/setup-efi \
                signer efi "console=ttyS0,115200"
                
    run_qemu ${BUILD_DIR}/efi 1
}

# The base initrd - busybox + script.
initrd() {
    # cctl script starts a container using .cache/PROJECT as /data and
    # current dir as /ws 
    cctl run ${PROJECT} --entrypoint /ws/signer/sbin/setup-efi \
       signer base_initrd
    
    cp ${BUILD_DIR}/efi/EFI/LINUX/INITRD.IMG prebuilt/initrd.img
}

# Init the keys.
init_secrets() {
    local dir=${1:-${HOME}/.ssh/uefi-keys}

    # cctl script starts a container using .cache/PROJECT as /data and
    # current dir as /ws 
    SECRETS=${dir} \
    cctl run ${PROJECT} \
      --entrypoint /ws/signer/sbin/setup-efi \
         signer sign_init
}

sign() {
    # cctl script starts a container using .cache/PROJECT as /data and
    # current dir as /ws 
    SECRETS=${HOME}/.ssh/uefi-keys \
      cctl run ${PROJECT} \
        --entrypoint /ws/signer/sbin/setup-efi \
           signer efi

         
}

# Unverified/install mode, with initrd. For unverified always using initrd.
unv() {
    build src/stub0

    mkdir -p ${BUILD_DIR}/qemu-unv/EFI/LINUX

    initrd
    cp prebuilt/initrd.img ${BUILD_DIR}/qemu-unv/EFI/LINUX/INITRD.IMG

    cp ${HOME}/.ssh/uefi-keys/uefi-keys/*.cer ${BUILD_DIR}/qemu-unv
    cp ${HOME}/.ssh/uefi-keys/uefi-keys/*.esl ${BUILD_DIR}/qemu-unv
    cp ${HOME}/.ssh/uefi-keys/uefi-keys/*.crt ${BUILD_DIR}/qemu-unv

    OUT=${BUILD_DIR}/qemu-unv \
    KERNEL_DIR=${SRC}/prebuilt \
    STUB=${BUILD_DIR}/EFI/BOOT/BOOTx64.EFI \
       ./signer/sbin/setup-efi unsigned

    rm ${BUILD_DIR}/qemu-unv/EFI/BOOT/BOOTx64.EFI



    #mkdir -p ${BUILD_DIR}/qemu-unv/EFI/LINUX ${BUILD_DIR}/qemu-unv/EFI/BOOT
    #cp prebuilt/vmlinuz ${BUILD_DIR}/qemu-unv/EFI/LINUX/kernel.efi
    #cp  ${BUILD_DIR}/img/ministub.efi ${BUILD_DIR}/qemu-unv/EFI/BOOT/bootx64.efi


    # Overwrite the comand line to use ttyS0
    cp prebuilt/cmdline.qemu ${BUILD_DIR}/qemu-unv/EFI/LINUX/CMDLINE

    run_qemu ${BUILD_DIR}/qemu-unv
}



"$@"
