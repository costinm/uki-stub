#!/bin/bash

set -e

# Build configuration
BASH_SRC=$0 #{BASH_SOURCE[0]}
BASE=$(dirname "${BASH_SRC}")
PROJECT_ROOT="$(cd "${BASE}" && pwd)"
BUILD_DIR=${BUILD_DIR:-"${PROJECT_ROOT}/build"}

# QEMU configuration
OVMF_PATH="${PROJECT_ROOT}/prebuilt/OVMF.fd"
MOUNT_DIR="${BUILD_DIR}/mnt"

buildgo() {
    APP=${1}
    echo "=== Building UEFI Go Application ==="
    
    # Create build directory
    mkdir -p "${BUILD_DIR}"

    # Set environment variables for UEFI cross-compilation
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

qemu() {
    buildgo efi-verify
    FATDIR=${BUILD_DIR}/qemu

    kernel_offset='0x30000000' 
    #cfg_offset='0x3f000000'
    cfg_offset=0x20000000
#        cp   ${BUILD_DIR}/efi-verify.efi  ${BUILD_DIR}/qemu/EFI/BOOT/bootx64.efi
    mkdir -p ${BUILD_DIR}/qemu/EFI/BOOT

    objcopy \
        --add-section .cfg="prebuilt/cfg.qemu" --change-section-vma .cfg=$cfg_offset \
        --add-section .linux="prebuilt/vmlinuz-custom"     --change-section-vma ".linux=$kernel_offset"  \
            ${BUILD_DIR}/efi-verify.efi \
            ${BUILD_DIR}/qemu/EFI/BOOT/bootx64.efi

    #echo "Adjust vma"
    # This corrects putting sections below the base image of the stub.
    #objcopy --adjust-vma 0  ${BUILD_DIR}/qemu/EFI/BOOT/bootx64.efi
    run_qemu ${FATDIR}
}

qemu2() {
    APP=efiload
    buildgo efiload
    FATDIR=${BUILD_DIR}/qemu

    kernel_offset='0x30000000' 
    #cfg_offset='0x3f000000'
    cfg_offset=0x20000000
#        cp   ${BUILD_DIR}/efi-verify.efi  ${BUILD_DIR}/qemu/EFI/BOOT/bootx64.efi
    mkdir -p ${BUILD_DIR}/qemu/EFI/BOOT

    objcopy \
        --add-section .cfg="prebuilt/cfg.qemu" --change-section-vma .cfg=$cfg_offset \
        --add-section .linux="prebuilt/vmlinuz-custom"     --change-section-vma ".linux=$kernel_offset"  \
            ${BUILD_DIR}/${APP}.efi \
            ${BUILD_DIR}/qemu/EFI/BOOT/bootx64.efi

    #echo "Adjust vma"
    # This corrects putting sections below the base image of the stub.
    #objcopy --adjust-vma 0  ${BUILD_DIR}/qemu/EFI/BOOT/bootx64.efi
    run_qemu ${FATDIR}
}

qemu_recovery() {
    buildgo recovery
    
    FATDIR=${BUILD_DIR}/qemu-recovery

    mkdir -p ${FATDIR}/EFI/BOOT ${FATDIR}/EFI/linux
    
    cp ${BUILD_DIR}/recovery.efi  ${FATDIR}/EFI/BOOT/bootx64.efi

    cp prebuilt/vmlinuz-custom ${FATDIR}/EFI/linux/kernel.efi
    cp prebuilt/initrd.img ${FATDIR}/EFI/linux/initrd.img
    cp prebuilt/cmdline.qemu ${FATDIR}/EFI/linux/cmdline
    
    run_qemu ${FATDIR}
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


all() {
    #(cd /x/linux/linux-6.16 && make && cp arch/x86/boot/bzImage ${BUILD_DIR}/qemu/kernel.efi)
    qemu
}

"$@"
