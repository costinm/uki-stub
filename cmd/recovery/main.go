package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"log"
	"strings"
	"unicode/utf16"
	"unsafe"

	"runtime"

	_ "github.com/usbarmory/go-boot/cmd"
	"github.com/usbarmory/go-boot/shell"

	"github.com/usbarmory/go-boot/uefi"
	"github.com/usbarmory/go-boot/uefi/x64"
)

var CmdLine = " initrd=\\initrd.img console=tty1 rdinit=/sbin/initos-initrd net.ifnames=0 panic=0 init=/bin/sh console=ttyS0 initos_sidecar=/dev/sdb initos_debug=1 "

// Recovery and install EFI. Expects the EFI to be either
// 'unlocked' (platform keys removed) or locked  with
// the user key that signed the recovery EFI.
//
// The goals are:
// - if unlocked - install the user key as PK
// - if secure mode - rotate PK keys and select a signed kernel/partition
// - if insecure mode - provide a recovery shell and may launch an
// installer image.
func main() {
	// Will start with a shell - booting the recovery linux is one option
	initGoBoot()
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

func executeKernel(path string, cmdline string) (string, error) {
	root, err := x64.UEFI.Root()
	if err != nil {
		return "", fmt.Errorf("could not open root volume, %v", err)
	}

	// TODO: load sig, config, initrd - and verify each sha using the pub key

	data, err := loadAndVerify(path)
	if err != nil {
		fmt.Printf("Error opening %s: %v\n", path, err)
		return "", fmt.Errorf("could not open kernel, %v", err)
	}

	// Use LoadedImage with the already loaded kernel - to not double
	log.Printf("loading EFI image %s", path)

	if cmdline == "" {
		cmddata, err := loadAndVerify("\\EFI\\linux\\cmdline")
		if err != nil {
			fmt.Printf("Error opening default cmdline: %v\n", err)
			cmdline = CmdLine
		} else {
			cmdline = string(cmddata)
		}
	}

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
	limg, rawMemoryAddress, err := x64.UEFI.Boot.LoadImageHandle(h)
	ptr := stringToUTF16Ptr(cmdline)
	fmt.Println("Loaded image", limg)
	addr := uintptr(rawMemoryAddress)
	// Convert the uintptr to a *uint32 pointer
	cmdlineLenPtr := (*uint32)(unsafe.Pointer(addr + 48))
	*cmdlineLenPtr = uint32(len(cmdline) * 2)
	cmdlinePtr := (*uint64)(unsafe.Pointer(addr + 56))
	*cmdlinePtr = uefi.Ptrval(ptr)

	log.Printf("starting EFI image %#x", h)
	return "", x64.UEFI.Boot.StartImage(h)
}

//var SystemTable *uefi.SystemTable

func initGoBoot() {
	banner := fmt.Sprintf("go-boot • %s/%s (%s) • UEFI x64",
		runtime.GOOS, runtime.GOARCH, runtime.Version())

	iface := &shell.Interface{
		Banner:  banner,
		Console: x64.UEFI.Console,
	}
	shell.Add(shell.Cmd{
		Name:   "recovery",
		Args:   2,
		Syntax: "[kernel_path] [cmdline]",
		Help:   "boot linux kernel with command line. Defaults to \\EFI\\linux\\kernel.efi,cmdline",
		Fn: func(c *shell.Interface, arg []string) (res string, err error) {
			log.Println("EFI linux start")
			path := "\\EFI\\linux\\kernel.efi"
			if len(arg) > 0 {
				path = arg[0]
			}
			cmdline := ""
			if len(arg) > 1 {
				cmdline = strings.Join(arg[1:], " ")
			}

			return executeKernel(path, cmdline)
		},
	})

	// disable UEFI watchdog
	x64.UEFI.Boot.SetWatchdogTimer(0)

	iface.ReadWriter = x64.UEFI.Console
	iface.Start(false)

	log.Print("exit")

	if err := x64.UEFI.Boot.Exit(0); err != nil {
		log.Printf("halting due to exit error, %v", err)
		x64.UEFI.Runtime.ResetSystem(uefi.EfiResetShutdown)
	}
}
