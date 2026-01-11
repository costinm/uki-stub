package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"strconv"
	"unicode/utf16"
	"unsafe"

	uefi "github.com/costinm/uki-stub/pkg/ueficore"
	"github.com/costinm/uki-stub/pkg/ueficore/x64"
)

// Verified stub must be signed and built with a public key
// that is used to sign all the files used by the stub.
//
// The steps:
//  1. load and verify \EFI\config, using \EFI\config.sig.
//     This includes the command line
//  2. load and verify \EFI\kernel.efi
//  3. if command line includes initrd=\\EFI\\initrd.img,
//     load and verify \EFI\initrd.img (no other options allowed)
//  4. Use EFI to execute the kernel with the command line.
//
// It does not check if secure is enabled - the user and installer
// are responsible for configuring the EFI PK/KEK/DB.
//
// This version is based on 3 separate files (plus 3 signatures).
// Alternative (in zig or the original C) is using the UKI style of
// having the kernel, initrd and command line as sections added
// to the stub, and it is using the (deprecated) kernel bootstrap.
// Functionality is identical, both verify the kernel start.
//
// The main benefit of having the config 'detached' is
// build flexibility - the kernel/rootfs can be built, signed
//
//	and updated independently - the command line with the
//
// hash must still be updated when the kernel or rootfs
// are changed and re-signed.
func main() {
	// This is required - and may be used if a kernel is not built in (unsigned==unverified).
	kernelPath := "\\EFI\\linux\\kernel.efi"

	//fmt.Println("Starting")
	kerOff := 0x30000000
	cfgOff := 0x20000000

	cfg := []byte(unsafe.Slice((*byte)(unsafe.Pointer(uintptr(cfgOff))), 10240))
	parts := bytes.SplitN(cfg, []byte{'\n'}, 3)
	// fmt.Println("Config: len: ", string(parts[0]), "CMD", string(parts[1]))

	kerLen, _ := strconv.Atoi(string(parts[0]))
	// Kernel length is included in the image - but for now get it from config.
	kerData := []byte(unsafe.Slice((*byte)(unsafe.Pointer(uintptr(kerOff))), kerLen))
	// fmt.Println("Kernel length: ", kerLen, kerData[0:16])

	// TODO: read init.sha from config and check it.

	if _, err := executeKernel(kernelPath,
		//"test=example initos_sidecar=/dev/sdb"); err != nil {
		// initrd=\\initrd.img
		//
		kerData,
		string(parts[1])); err != nil {
		// fmt.Printf("Error executing kernel: %v\n", err)
		os.Exit(1)
	}
	if err := x64.UEFI.Boot.Exit(0); err != nil {
		x64.UEFI.Runtime.ResetSystem(uefi.EfiResetShutdown)
	}
}

func stringToUTF16Ptr(s string) *uint16 {
	utf16Slice := utf16.Encode([]rune(s))
	utf16Slice = append(utf16Slice, 0) // null terminate
	return &utf16Slice[0]
}

func load(path string) ([]byte, error) {
	// TODO: load sig, config, initrd - and verify each sha using the pub key
	root, err := x64.UEFI.Root()
	if err != nil {
		return nil, errors.New("could not open root volume " + err.Error())
	}

	// TODO: load sig, config, initrd - and verify each sha using the pub key

	bf, err := root.Open(path)
	if err != nil {
		return nil, errors.New("could not open kernel " + err.Error())
	}

	data, err := io.ReadAll(bf)
	if err != nil {
		return nil, errors.New("Error reading " + path + ":" + err.Error())
		// } else {
		// 	fmt.Println("Loaded file", len(data))
		// 	hash := sha256.Sum256(data)
		// 	fmt.Printf("SHA256 of %s (%d bytes): %x\n", path, len(data), hash)
	}

	return data, nil
}

func executeKernel(path string, data []byte, cmdline string) (string, error) {
	root, err := x64.UEFI.Root()
	if err != nil {
		return "", errors.New("could not open root volume " + err.Error())
	}
	if data == nil {
		data, err = load(path)
		if err != nil {
			return "", err
		}
	}

	// Use LoadedImage with the already loaded kernel - to not double
	h, err := x64.UEFI.Boot.LoadImageMem(0, root, path, data)
	if err != nil {
		return "", errors.New("could not load image " + err.Error())
	}
	// Alternative: load from disk *again*
	// log.Printf("loading EFI image %s", path)
	// h, err := x64.UEFI.Boot.LoadImage(0, root, path)
	// if err != nil {
	// 	return "", fmt.Errorf("could not load image, %v", err)
	// }
	// Note that a sha256 of the image base is NOT the same with the SHA of
	// the bytes loaded from disk - so we can't go the other way

	// Use LoadedImage protocol to get set the command line
	_, rawMemoryAddress, err := x64.UEFI.Boot.LoadImageHandle(h)

	ptr := stringToUTF16Ptr(cmdline)
	//fmt.Println("Loaded image", limg)

	addr := uintptr(rawMemoryAddress)
	// Convert the uintptr to a *uint32 pointer
	cmdlineLenPtr := (*uint32)(unsafe.Pointer(addr + 48))
	*cmdlineLenPtr = uint32(len(cmdline) * 2)
	cmdlinePtr := (*uint64)(unsafe.Pointer(addr + 56))
	*cmdlinePtr = uefi.Ptrval(ptr)

	//log.Printf("starting EFI image %#x", h)
	return "", x64.UEFI.Boot.StartImage(h)
}
