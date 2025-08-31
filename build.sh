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
BASH_SRC=$0 #{BASH_SOURCE[0]}
BASE=$(dirname "${BASH_SRC}")
PROJECT_ROOT="$(cd "${BASE}" && pwd)"
#BUILD_DIR=${BUILD_DIR:-"${PROJECT_ROOT}/build"}
BUILD_DIR=${HOME}/.cache/$(basename ${PROJECT_ROOT})
export ZIG_LOCAL_CACHE_DIR=${BUILD_DIR}/.zig-cache

# QEMU configuration
OVMF_PATH="${PROJECT_ROOT}/prebuilt/OVMF.fd"
MOUNT_DIR="${BUILD_DIR}/mnt"

# Hardcoded in stub - any change must be done in both places.
kernel_offset='0x30000000' 
cfg_offset=0x20000000

mkdir -p "${BUILD_DIR}"

build() {
    (cd src/stub2 && zig build -p ${BUILD_DIR} -freference-trace=8)
    cp ${BUILD_DIR}/img/ministub.efi prebuilt/uki-stub.efi
}

buildr() {
    (cd src/stub2g && cargo build --target x86_64-unknown-uefi)
    cp src/stub2g/target/x86_64-unknown-uefi/debug/uki-stub.efi prebuilt/uki-stub.efi
}

# Generate BOOTx64.EFI
gen() {
    local FATDIR=${1}
    local CFG=${2}

    mkdir -p ${FATDIR}/EFI/BOOT ${FATDIR}/EFI/LINUX

    #cp /x/linux/linux-6.16/arch/x86/boot/bzImage prebuilt/vmlinuz-custom
    # Config can specify 0 as kernel size, stub will load from this fixed location
    #cp prebuilt/vmlinuz-custom ${BUILD_DIR}/qemu/EFI/LINUX/kernel.efi
    
    objcopy \
        --add-section .cfg="${CFG}" --change-section-vma .cfg=$cfg_offset \
        --add-section .linux="prebuilt/vmlinuz-custom"     --change-section-vma ".linux=$kernel_offset"  \
            prebuilt/uki-stub.efi \
            ${FATDIR}/EFI/BOOT/bootx64.efi
}

run_qemu() {    
    FATDIR=${1}
    #readpe ${BUILD_DIR}/efi-verify-stub.efi
    #readpe ${BUILD_DIR}/qemu/EFI/BOOT/bootx64.efi

# -drive id=mysdcard,if=none,format=qcow2,file=/path/to/backing_file.qcow2 \
#   -device sdhci-pci \
#   -device sd-card,drive=mysdcard

# -drive file=nvm.img,if=none,id=nvm
# -device nvme,serial=deadbeef,drive=nvm

    qemu-system-x86_64 \
        -nodefaults \
        -bios "${OVMF_PATH}" \
        -m 1G -smp 2 \
        -drive file=fat:rw:${FATDIR},format=raw \
        -drive file=prebuilt/sidecar.sqfs,format=raw \
        -net none \
        -nographic \
        -enable-kvm -cpu host \
        -no-reboot \
        -chardev stdio,mux=on,id=char0 -serial chardev:char0 -monitor chardev:char0 

}

# Go EFI is an experiment to evaluate go capabilities.
# The size is too big, and temptation to do more and add features
# is too high. Currently requires tamago-go, which also makes it 
# more complicated (no docker image I can find)
buildgo() {
    export GOOS=windows
    export GOARCH=amd64
    export CGO_ENABLED=0

    export PATH=${HOME}/opt/tamago-go/bin:${PATH}
    export GOOS=tamago

    CONSOLE=text
    BUILD_TAGS=linkcpuinit,linkramsize,linkramstart,linkprintk
    # the .txt entry is at 0x10000 offset
    IMAGE_BASE=0x10000000
    TEXT_START=10010000

    GOFLAGS="-tags ${BUILD_TAGS} -trimpath  "

    # Build the Go UEFI application
    echo "Building ${APP}.efi..."
    cd "${PROJECT_ROOT}"
    go build ${GOFLAGS} -ldflags '-s -w -E cpuinit -T 0x10010000 -R 0x1000 ' \
        -o ${BUILD_DIR}/${APP}.elf ./cmd/${APP}/

    objcopy \
            --strip-debug \
            --target efi-app-x86_64 \
            --subsystem=efi-app \
            --image-base ${IMAGE_BASE} \
            --stack=0x10000 \
            ${BUILD_DIR}/${APP}.elf \
            ${BUILD_DIR}/${APP}.efi 

    printf '\x26\x02' | dd of=${BUILD_DIR}/${APP}.efi bs=1 seek=150 count=2 conv=notrunc,fsync 
}

# Verified boot - SHA256 of the initrd included
ver() {
    cfg=${1:-prebuilt/cfg.qemu}
    build

    gen ${BUILD_DIR}/qemu ${cfg}
    cp prebuilt/initrd.img ${BUILD_DIR}/qemu/EFI/LINUX/initrd.img
    #echo "Adjust vma"
    # This corrects putting sections below the base image of the stub.
    objcopy --adjust-vma 0  ${BUILD_DIR}/qemu/EFI/BOOT/bootx64.efi
    run_qemu ${BUILD_DIR}/qemu
}

# Unverified/install mode
unv() {
    cfg=${1:-prebuilt/cfg.qemu}
    build

    mkdir -p ${BUILD_DIR}/qemu-unv/EFI/LINUX ${BUILD_DIR}/qemu-unv/EFI/BOOT
    cp prebuilt/initrd.img ${BUILD_DIR}/qemu-unv/EFI/LINUX/initrd.img
    cp prebuilt/cmdline.qemu ${BUILD_DIR}/qemu-unv/EFI/LINUX/cmdline
    cp prebuilt/vmlinuz-custom ${BUILD_DIR}/qemu-unv/EFI/LINUX/kernel.efi
    cp  ${BUILD_DIR}/img/ministub.efi ${BUILD_DIR}/qemu-unv/EFI/BOOT/bootx64.efi

    run_qemu ${BUILD_DIR}/qemu-unv
}

unvr() {
    cfg=${1:-prebuilt/cfg.qemu}
    buildr

    mkdir -p ${BUILD_DIR}/qemu-unv/EFI/LINUX ${BUILD_DIR}/qemu-unv/EFI/BOOT
    
    cp prebuilt/initrd.img ${BUILD_DIR}/qemu-unv/EFI/LINUX/initrd.img
    cp prebuilt/cmdline.qemu ${BUILD_DIR}/qemu-unv/EFI/LINUX/cmdline
    cp prebuilt/vmlinuz-custom ${BUILD_DIR}/qemu-unv/EFI/LINUX/kernel.efi
                
    cp  prebuilt/uki-stub.efi ${BUILD_DIR}/qemu-unv/EFI/BOOT/bootx64.efi

    run_qemu ${BUILD_DIR}/qemu-unv
}


all() {
    #(cd /x/linux/linux-6.16 && make && cp arch/x86/boot/bzImage ${BUILD_DIR}/qemu/kernel.efi)
    qemu
}

"$@"
