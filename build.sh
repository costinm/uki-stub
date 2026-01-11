0#!/bin/bash

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


build() {
    local dir=${1:-src/stub2}
    (cd ${dir} && zig build -p ${BUILD_DIR} -freference-trace=8)
}

# Run Qemu with UEFI firmware and a stub.
# First param is the directory with the VFAT files placed in the expected locations.
# Only for testing - for a VM it is better to pass the kernel and skip UEFI.
# 
# Env:
# QEMU_UI - start with gtk display (to see the menu)
run_qemu() {  
      
    FATDIR=${1}
    local SECURE=${2:-0}


    # Set OVMF for testing EFI - the prebuilt image is configured with the
    # testdata keys.
    if [ -n "${KERNEL}" ]; then
        OVMF="-kernel ${KERNEL}"
        if [ -n "${INITRD}" ]; then
            OVMF="${OVMF} -initrd ${INITRD}"
        fi
    else 
        if [ ${SECURE} -eq 1 ]; then
            OVMF="-drive if=pflash,format=raw,file=prebuilt/OVMF.fd"
            #OVMF="${OVMF} --drive if=pflash,format=raw,file=prebuilt/OVMF_VARS.fd"
            swtpm socket --tpmstate dir=/tmp/mytpm1   --ctrl type=unixio,path=/tmp/mytpm1/swtpm-sock   --tpm2  &
            tpm="-chardev socket,id=chrtpm,path=/tmp/mytpm1/swtpm-sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0" 
        else
            OVMF="-drive if=pflash,format=raw,file=prebuilt/OVMF_CODE.fd"
        fi
    fi

    qemu_base="-m 4G,maxmem=8G -smp 4 -cpu host -enable-kvm"

    if [ -z "${QEMU_UI}" ]; then
        qemu_base="${qemu_base} -nographic"
    else
        qemu_base="${qemu_base} -display gtk -vga std"
    fi

    # On reboot - exists, let caller to restart
    qemu_base="${qemu_base} -no-reboot"

    # mon:stdio - C-a xa
	qemu_serial="-chardev stdio,mux=on,id=char0 -serial chardev:char0 -monitor chardev:char0" 
    # stdio - no input ?
    # -display none -serial stdio

    vols="${vols} -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=src"
    vols="${vols} -fsdev local,security_model=passthrough,id=fsdev0,path=."
    # Use: mount -t 9p -o trans=virtio,version=9p2000.L src /src

    vols="${vols} -object memory-backend-file,id=mem1,share=on,mem-path=./virtio_pmem.img,size=1G"
    vols="${vols} -device virtio-pmem-pci,memdev=mem1,id=nv1"
    
    qemu-system-x86_64 -nodefaults ${qemu_base} \
        ${qemu_serial} \
        ${vols} \
         ${OVMF} \
         ${tpm} \
        -drive file=fat:rw:${FATDIR},format=raw \
        -drive file=prebuilt/sidecar.sqfs,format=raw \
        -drive file=prebuilt/rootfs.img,format=raw,if=none,id=nvm \
        -device nvme,serial=deadbeef,drive=nvm \
        -netdev user,id=n1,hostfwd=tcp::10022-:22 \
        -device virtio-net-pci,netdev=n1
        
         
        #-net user,hostfwd=tcp::10022-:22 


     # netdev: ,net=192.168.76.0/24,dhcpstart=192.168.76.9
    # tap works as well

    # Can use passt 
    # user mode network defaults: 10.0.2.15
    # GW: 10.0.2.2, DNS 10.0.2.3, SMB 10.0.2.4
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

initrd2() {
    variant=${1:-deb}
    local ep="--entrypoint /ws/signer/sbin/setup-efi"
    #ep="--entrypoint /bin/sh"
    # cctl script starts a container using .cache/PROJECT as /data and
    # current dir as /ws 
    VOLS="--mount type=image,source=modloop:${variant},destination=/mnt/modloop" 
    VOLS=$VOLS cctl run ${PROJECT} ${ep} \
       costinm/signer booster_initrd
       
    mkdir -p ${BUILD_DIR}/${variant}

    cp ${BUILD_DIR}/efi/EFI/LINUX/INITRD.IMG prebuilt/initrd.img
}

debug() {
    variant=${1:-deb}
    local ep="--entrypoint /bin/sh"
    # cctl script starts a container using .cache/PROJECT as /data and
    # current dir as /ws 
    VOLS="--mount type=image,source=modloop:${variant},destination=/mnt/modloop" 
    VOLS=$VOLS cctl run ${PROJECT} ${ep} \
       costinm/signer
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
simple() {
    build src/stub0
    local k=${1:-${SRC}/prebuilt/boot/vmlinuz}

    mkdir -p ${BUILD_DIR}/qemu-unv/EFI/LINUX

    initrd
    cp prebuilt/initrd.img ${BUILD_DIR}/qemu-unv/EFI/LINUX/INITRD.IMG

    cp ${HOME}/.ssh/uefi-keys/uefi-keys/*.cer ${BUILD_DIR}/qemu-unv
    cp ${HOME}/.ssh/uefi-keys/uefi-keys/*.esl ${BUILD_DIR}/qemu-unv
    cp ${HOME}/.ssh/uefi-keys/uefi-keys/*.crt ${BUILD_DIR}/qemu-unv

    OUT=${BUILD_DIR}/qemu-unv \
    KERNEL=$k \
    STUB=${BUILD_DIR}/EFI/BOOT/BOOTx64.EFI \
       ./signer/sbin/setup-efi unsigned

    # Overwrite the comand line to use ttyS0
    cp prebuilt/cmdline.qemu ${BUILD_DIR}/qemu-unv/EFI/LINUX/CMDLINE

    run_qemu ${BUILD_DIR}/qemu-unv
}

# Unverified/install mode, using a distro kernel (no modloop or modules in intird)
# To evaluate which distro includes basic block and ext4.
# - debian: no
# - alpine:
# - arch: 
simple_deb() {
    local k=$1

    build src/stub0

    mkdir -p ${BUILD_DIR}/qemu-unv/EFI/LINUX

    initrd
    cp prebuilt/initrd.img ${BUILD_DIR}/qemu-unv/EFI/LINUX/INITRD.IMG

    OUT=${BUILD_DIR}/qemu-unv \
    KERNEL=${k} \
    STUB=${BUILD_DIR}/EFI/BOOT/BOOTx64.EFI \
       ./signer/sbin/setup-efi unsigned "console=ttyS0,115200 "

    # Overwrite the comand line to use ttyS0
    #cp prebuilt/cmdline.qemu ${BUILD_DIR}/qemu-unv/EFI/LINUX/CMDLINE

    run_qemu ${BUILD_DIR}/qemu-unv
}


"$@"
