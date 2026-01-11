package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"unicode/utf16"
	"unsafe"

	//ueficore "github.com/usbarmory/go-boot/uefi"
	"github.com/costinm/uki-stub/pkg/uefi"
	ueficore "github.com/costinm/uki-stub/pkg/ueficore"
	"github.com/usbarmory/go-boot/uefi/x64"
)

var EnvVendor = uefi.EFI_GUID{
	0xaabc54d8, 0x7b8e, 0x5680,
	[...]byte{0x9f, 0x6c, 0x68, 0xda, 0x0d, 0xbb, 0xcd, 0xbf}}

func getkey(key []uefi.CHAR16, vendor *uefi.EFI_GUID) (value []byte, found bool) {
	var (
		dataSize uefi.UINTN
		data     []byte = make([]byte, 16)
	)
	// call with dataSize = 0 so we can be told how big the buffer needs to be; this is passed through dataSize
	status := uefi.ST().RuntimeServices.GetVariable(
		(*uefi.CHAR16)(unsafe.Pointer(&key[0])), // Variable Name
		vendor,                                  // Vendor GUID
		nil,                                     // optional attributes
		&dataSize,                               // Before call: Size of Buffer; after call: how much was written to the buffer
		(*uefi.VOID)(unsafe.Pointer(&data[0])))
	switch status {
	case uefi.EFI_NOT_FOUND:
		fmt.Println("GET VAR NOT FOUND ", key, status, data, dataSize)
		return nil, false
	case uefi.EFI_BUFFER_TOO_SMALL:
		//fmt.Println("GET VAR NEW BUFFER", key, status, data, dataSize)

		data = make([]byte, int(dataSize))
		status = uefi.ST().RuntimeServices.GetVariable(
			(*uefi.CHAR16)(unsafe.Pointer(&key[0])), // Variable Name
			vendor,                                  // Vendor GUID
			nil,                                     // optional attributes
			&dataSize,                               // Before call: Size of Buffer; after call: how much was written to the buffer
			(*uefi.VOID)(unsafe.Pointer(&data[0])))
		if status != uefi.EFI_SUCCESS {
			return nil, false
		}
		return data, true
	default:
		//fmt.Println("GET VAR OK ", key, status, data, dataSize)
		return data[0:dataSize], false
	}
}

func vars() {
	var (
		varKey     = make([]uefi.CHAR16, 1)
		varKeySize = uefi.UINTN(2)
		status     uefi.EFI_STATUS
		vendorGUID uefi.EFI_GUID
	)
	for {
		status = uefi.ST().RuntimeServices.GetNextVariableName(
			&varKeySize,
			(*uefi.CHAR16)(unsafe.Pointer(&varKey[0])),
			&vendorGUID)
		//fmt.Println("Next variable name", varKeySize, varKey[0], status, vendorGUID)
		switch status {
		case uefi.EFI_BUFFER_TOO_SMALL:
			// buffer was too small, the size needed will be in
			// varKeySize.
			newVarKey := make([]uefi.CHAR16, varKeySize)
			copy(newVarKey, varKey)
			varKey = newVarKey[:varKeySize/2]
			continue
		case uefi.EFI_SUCCESS:
			// we read a variable name, if it's ours,  get it
			// and append it to our list

			// if vendorGUID != EnvVendor {
			// 	continue
			// }
			keyString := uefi.UTF16ToString(varKey[:(varKeySize-1)/2])
			val, _ := getkey(varKey[:varKeySize/2], &vendorGUID)
			fmt.Println("VAR", keyString, val)
		case uefi.EFI_NOT_FOUND:
			// all done!
			return
		case uefi.EFI_INVALID_PARAMETER:
			// this gets its own branch because it means something in this function
			// was done incorrectly.
			panic("invalid parameter passed to GetNextVariableName")
		default:
			// something went wrong; cheese it
			print("Status ", status)
			panic(uefi.StatusError(status))
		}
	}

}

func main() {
	ah, sh := x64.UEFI.Handles()
	uefi.Init(uintptr(ah), uintptr(sh))
	vars()

	kernelPath := "\\EFI\\linux\\kernel.efi"

	fmt.Println("Starting")
	kerOff := 0x30000000
	cfgOff := 0x20000000

	cfg := []byte(unsafe.Slice((*byte)(unsafe.Pointer(uintptr(cfgOff))), 10240))
	parts := bytes.SplitN(cfg, []byte{'\n'}, 3)
	fmt.Println("Config: len: ", string(parts[0]), "CMD", string(parts[1]))

	kerLen, _ := strconv.Atoi(string(parts[0]))
	// Kernel length is included in the image - but for now get it from config.
	kerData := []byte(unsafe.Slice((*byte)(unsafe.Pointer(uintptr(kerOff))), kerLen))
	fmt.Println("Kernel length: ", kerLen, kerData[0:16])

	if _, err := executeKernel(kernelPath,
		//"test=example initos_sidecar=/dev/sdb"); err != nil {
		// initrd=\\initrd.img
		//
		kerData,
		string(parts[1])); err != nil {
		fmt.Printf("Error executing kernel: %v\n", err)
		os.Exit(1)
	}
	if err := x64.UEFI.Boot.Exit(0); err != nil {
		x64.UEFI.Runtime.ResetSystem(ueficore.EfiResetShutdown)
	}
	if err := x64.UEFI.Boot.Exit(0); err != nil {
		x64.UEFI.Runtime.ResetSystem(ueficore.EfiResetShutdown)
	}

}

func stringToUTF16Ptr(s string) *uint16 {
	utf16Slice := utf16.Encode([]rune(s))
	utf16Slice = append(utf16Slice, 0) // null terminate
	return &utf16Slice[0]
}

func loadAndVerify(path string) ([]byte, error) {
	// TODO: load sig, config, initrd - and verify each sha using the pub key
	root, err := x64.UEFI.Root()
	if err != nil {
		return nil, fmt.Errorf("could not open root volume, %v", err)
	}

	// TODO: load sig, config, initrd - and verify each sha using the pub key

	bf, err := root.Open(path)
	if err != nil {
		fmt.Printf("Error opening %s: %v\n", path, err)
		return nil, fmt.Errorf("could not open kernel, %v", err)
	}
	fmt.Printf("Opened file %v\n", bf)
	data, err := io.ReadAll(bf)
	if err != nil {
		fmt.Printf("Error reading %s: %v\n", path, err)
		//os.Exit(1)
	} else {
		fmt.Println("Loaded file", len(data))
		hash := sha256.Sum256(data)
		fmt.Printf("SHA256 of %s (%d bytes): %x\n", path, len(data), hash)
	}

	return data, nil
}

func executeKernel(path string, data []byte, cmdline string) (string, error) {
	root, err := x64.UEFI.Root()
	if err != nil {
		return "", fmt.Errorf("could not open root volume, %v", err)
	}
	if data == nil {
		data, err = loadAndVerify(path)
		if err != nil {
			return "", err
		}
		if data == nil {
			return "", fmt.Errorf("could not load kernel")
		}
	}

	// Use LoadedImage with the already loaded kernel - to not double
	h, err := x64.UEFI.Boot.LoadImageMem(0, root, path, data)
	if err != nil {
		return "", fmt.Errorf("could not load image, %v", err)
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


	addr := uintptr(rawMemoryAddress)
	// Convert the uintptr to a *uint32 pointer
	cmdlineLenPtr := (*uint32)(unsafe.Pointer(addr + 48))
	*cmdlineLenPtr = uint32(len(cmdline) * 2)
	cmdlinePtr := (*uint64)(unsafe.Pointer(addr + 56))
	*cmdlinePtr = ueficore.Ptrval(ptr)

	log.Printf("starting EFI image %#x", h)
	return "", x64.UEFI.Boot.StartImage(h)
}
