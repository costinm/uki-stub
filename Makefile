#
#  This file is part of gummiboot
#
#  Copyright (C) 2013 Karel Zak <kzak@redhat.com>
#
#  gummiboot is free software; you can redistribute it and/or modify it
#  under the terms of the GNU Lesser General Public License as published by
#  the Free Software Foundation; either version 2.1 of the License, or
#  (at your option) any later version.
#
#  gummiboot is distributed in the hope that it will be useful, but
#  WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
#  Lesser General Public License for more details.
#
#  You should have received a copy of the GNU Lesser General Public License
#  along with systemd; If not, see <http://www.gnu.org/licenses/>.

out?=${HOME}/.cache/initos
build=${out}
src=.

# For testing
cmd=loglevel=0 quiet earlyprintk=efi foo=bar console=ttyS0,115200 rdinit=/sbin/initos-initrd net.ifnames=0 panic=5 debug_init initos_debug=1 -- test123
cmd:=initos_sidecar=/dev/sdc ${cmd}

qemu_disks=-drive file=${build}/efi/initos/sidecar.sqfs 

qemu_base=-m 1G -smp 4 -cpu host -enable-kvm
qemu_common=${qemu_base} -display none
qemu_serial=-chardev stdio,mux=on,id=char0 -serial chardev:char0 -monitor chardev:char0 \

stub = ${out}/boot/linux$(MACHINE_TYPE_NAME).efi.stub
ARCH=x86_64


# ------------------------------------------------------------------------------
# EFI compilation -- this part of the build system uses custom make rules and
# bypasses regular automake to provide absolute control on compiler and linker
# flags.
efi_cppflags = \
	$(EFI_CPPFLAGS) \
	-I/usr/include/efi -I/usr/include \
	-I/usr/include/efi/x86_64 \
	-I/usr/include/x86_64-linux-gnu \
	-DMACHINE_TYPE_NAME=\"$(MACHINE_TYPE_NAME)\"

# Alpine is using x86_64, debian has linux-gnu suffix.

efi_cflags = \
	$(EFI_CFLAGS) \
	-Wall \
	-Wextra \
	-nostdinc \
	-ggdb -O0 \
	-fpic \
	-fshort-wchar \
	-nostdinc \
	-ffreestanding \
	-fno-strict-aliasing \
	-fno-stack-protector \
	-Wsign-compare \
	-mno-sse \
	-mno-mmx



CFLAGS=-I. -I$(INCDIR) -I$(INCDIR)/$(ARCH) \
		-DGNU_EFI_USE_MS_ABI -fPIC -fshort-wchar -ffreestanding \
		-fno-stack-protector -maccumulate-outgoing-args \
		-Wall -D$(ARCH) -Werror

efi_cflags += \
	-mno-red-zone -m64 \
	-DEFI_FUNCTION_WRAPPER \
	-DGNU_EFI_USE_MS_ABI

FORMAT=efi-app-$(ARCH)

efi_ldflags = \
	$(EFI_LDLAGS) \
	-T /usr/lib/elf_$(ARCH)_efi.lds \
	-shared \
	-Bsymbolic \
	-nostdlib \
	-znocombreloc \
	-L /usr/lib \
	/usr/lib/crt0-efi-$(ARCH).o

# ------------------------------------------------------------------------------
stub_headers = \
	src/efi/util.h \
	src/efi/pefile.h \
	src/efi/linux.h

stub_sources = \
	src/efi/util.c \
	src/efi/pefile.c \
	src/efi/linux.c \
	src/efi/stub.c


stub_objects = $(addprefix $(out)/,$(stub_sources:.c=.o))
stub_solib = $(out)/src/efi/stub.so

all: $(stub)

$(stub): $(stub_solib)
	mkdir -p ${out}/boot
	objcopy -j .text -j .sdata -j .data -j .dynamic \
	  -j .dynsym -j .rel -j .rela -j .reloc \
	  --target=efi-app-$(ARCH) $< $@

# Build and test the stub.
btest: ${stub} ${build}/test.img ${build}/boot/initos-patch.img test


# Use qemu - with fat:rw (max 516MB) disk containing the EFI.
test-efi: initos-patch
	mkdir -p ${build}/qemu/boot/EFI/BOOT
	
	bash -x ${src}/../initos/sidecar/sbin/efi-mkuki \
	-S ${stub} \
	-c "${cmd}" \
	-o ${build}/qemu/boot/EFI/BOOT/BOOTx64.EFI \
	 ${build}/boot/vmlinuz-$(shell cat ${build}/boot/version) \
	 ${build}/boot/initos-initrd.img \
	 ${build}/qemu/initos-patch.img

    # stdio - no input ?
    # mon:stdio - C-a x
	# -display none -serial stdio

	qemu-system-x86_64 ${qemu_common}  \
	   -bios /usr/share/qemu/OVMF.fd \
	   -hda fat:rw:${build}/qemu/boot \
	   ${qemu_serial} ${qemu_disks} ${build}/test.img 

build-efi-unsigned: 
	mkdir -p ${build}/qemu/unsigned/EFI/BOOT ${build}/qemu/unsigned/initos

	# (cd ../initos && \
	#     podman build  . -f Dockerfile.dev \
	#        --output ${build}/qemu/unsigned)
	(cd ../initos && \
	   podman run -e TTY=ttyS0  \
	      -v ${build}/qemu/unsigned:/data/efi \
	      -v ${src}/../initos:/src \
		  sidecar \
		     bash -x /src/sidecar/sbin/setup-efi unsigned)
	
	cp ${build}/efi/initos/sidecar.sqfs ${build}/qemu/unsigned/initos
	mv ${build}/qemu/unsigned/InitOS-debug.EFI ${build}/qemu/unsigned/EFI/BOOT/BOOTx64.EFI
	

test-efi-unsigned: 
	qemu-system-x86_64 ${qemu_base} -display none  \
	   -bios /usr/share/qemu/OVMF.fd \
	   -hda fat:rw:${build}/qemu/unsigned \
	   ${qemu_serial} ${qemu_disks} 


test: initos-patch
	cat ${build}/boot/initos-initrd.img ${build}/qemu/initos-patch.img > ${build}/qemu/initos-patched.img
	qemu-system-x86_64 ${qemu_common}  \
	 -kernel ${build}/boot/vmlinuz-$(shell cat ${build}/boot/version)  \
	 -initrd ${build}/qemu/initos-patched.img \
	 -append "${cmd}" \
	${qemu_serial} ${qemu_disks}
	   
initos-patch:
	mkdir -p ${build}/qemu/patch
	cp -a ${src}/../initos/sidecar/sbin ${build}/qemu/patch

	(cd ${build}/qemu/patch; \
   		find . \
   | sort  | cpio --quiet --renumber-inodes -o -H newc \
   | gzip) > ${build}/qemu/initos-patch.img

# Extract the default initrd to a dir - which can be patched and inspected.
initos-extract:
	mkdir -p ${build}/initrd-full; 
	(cd ${build}/initrd-full; gzip -dc < ${build}/boot/initos-initrd.img | cpio -id)


${build}/test.img:
	qemu-img create $@ 16M

$(out)/src/efi/%.o: $(src)/src/efi/%.c $(addprefix $(src)/,$(stub_headers))
	mkdir -p  $(out)/src/efi/
	cc $(efi_cppflags) $(efi_cflags) -c $< -o $@

$(stub_solib): $(stub_objects)
	ld $(efi_ldflags) $(stub_objects) \
		-o $@ -lefi -lgnuefi $(shell $(CC) -print-libgcc-file-name); \
	nm -D -u $@ | grep ' U ' && exit 1 || :

%.efi: %.so
	objcopy -j .text -j .sdata -j .data -j .dynamic -j .dynsym -j .rel \
		-j .rela -j .reloc -S --target=$(FORMAT) $^ $@

%.so: %.o
	$(LD) $(LDFLAGS) -o $@ $^ $(shell $(CC) $(CFLAGS) -print-libgcc-file-name)

%.S: %.c
	$(CC) $(INCDIR) $(CFLAGS) $(CPPFLAGS) -S $< -o $@
