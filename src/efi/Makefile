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

stub = ${out}/boot/linux$(MACHINE_TYPE_NAME).efi.stub
ARCH=x86_64


# ------------------------------------------------------------------------------
# Alpine is using x86_64, debian has linux-gnu suffix.

efi_cflags = \
	-I/usr/include/efi -I/usr/include \
	-I/usr/include/efi/x86_64 \
	-I/usr/include/x86_64-linux-gnu \
	-DMACHINE_TYPE_NAME=\"$(MACHINE_TYPE_NAME)\" \
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
	util.h \
	pefile.h \
	linux.h

stub_sources = \
	util.c \
	pefile.c \
	linux.c \
	stub.c


stub_objects = $(addprefix $(out)/,$(stub_sources:.c=.o))
stub_solib = $(out)/stub.so

all: $(stub)

$(stub): $(stub_solib)
	mkdir -p ${out}/boot
	objcopy -j .text -j .sdata -j .data -j .dynamic \
	  -j .dynsym -j .rel -j .rela -j .reloc \
	  --target=efi-app-$(ARCH) $< $@

$(out)/%.o: $(src)/%.c $(addprefix $(src)/,$(stub_headers))
	mkdir -p  $(out)/
	cc $(efi_cflags) -c $< -o $@

$(stub_solib): $(stub_objects)
	ld $(efi_ldflags) $(stub_objects) \
		-o $@ -lefi -lgnuefi $(shell $(CC) -print-libgcc-file-name); \
	nm -D -u $@ | grep ' U ' && exit 1 || :

%.efi: %.so
	objcopy -j .text -j .sdata -j .data -j .dynamic -j .dynsym -j .rel \
		-j .rela -j .reloc -S --target=$(FORMAT) $^ $@

%.so: %.o
	$(LD) $(LDFLAGS) -o $@ $^ $(shell $(CC) $(CFLAGS) -print-libgcc-file-name)


# %.S: %.c
# 	$(CC) $(INCDIR) $(CFLAGS) $(CPPFLAGS) -S $< -o $@

stub2:
	#cd stub2 && zig build
	./build.sh stub2