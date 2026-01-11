package uefi

import (
	"sync"
	"unsafe"
)

var mux sync.Mutex

// defined in uefi.s
func callFn(fn uint64, n int, args []uint64) (status uint64)

// callService calls an UEFI service
func callService(fn uint64, args []uint64) (status uint64) {
	mux.Lock()
	defer mux.Unlock()

	return callFn(fn, len(args), args)
}

func Ptrval(ptr any) uint64 {
	return ptrval(ptr)
}

// This function helps preparing callService arguments, allowing a single call
// for all EFI services.
//
// Obtaining a pointer in this fashion is typically unsafe and tamago/dma
// package would be best to handle this. However, as arguments are prepared
// right before invoking Go assembly, it is considered safe as it is identical
// as having *uint64 as callService prototype.
func ptrval(ptr any) uint64 {
	var p unsafe.Pointer

	switch v := ptr.(type) {
	case *uint64:
		p = unsafe.Pointer(v)
	case *uint32:
		p = unsafe.Pointer(v)
	case *uint16:
		p = unsafe.Pointer(v)
	case *uintptr:
		p = unsafe.Pointer(v)
	case *byte:
		p = unsafe.Pointer(v)
	//case *InputKey:
	//	p = unsafe.Pointer(v)
	default:
		panic("internal error, invalid ptrval")
	}

	return uint64(uintptr(p))
}

//go:nosplit
//export uefiCall0
func UefiCall0(fn uintptr) EFI_STATUS

//go:nosplit
//go:export uefiCall1
func UefiCall1(fn uintptr, a uintptr) EFI_STATUS

//go:nosplit
//go:export uefiCall2
func UefiCall2(fn uintptr, a uintptr, b uintptr) EFI_STATUS

//go:nosplit
//go:export uefiCall3
func UefiCall3(fn uintptr, a uintptr, b uintptr, c uintptr) EFI_STATUS {
	st := callService(uint64(fn), []uint64{uint64(a), uint64(b), uint64(c)})
	return EFI_STATUS(st)
}

// // EFI Status Codes
// const (
// 	EFI_SUCCESS = iota
// 	EFI_LOAD_ERROR
// 	EFI_INVALID_PARAMETER
// 	EFI_UNSUPPORTED
// 	EFI_BAD_BUFFER_SIZE
// 	EFI_BUFFER_TOO_SMALL
// 	EFI_NOT_READY
// 	EFI_DEVICE_ERROR
// 	EFI_WRITE_PROTECTED
// 	EFI_OUT_OF_RESOURCES
// 	EFI_VOLUME_CORRUPTED
// 	EFI_VOLUME_FULL
// 	EFI_NO_MEDIA
// 	EFI_MEDIA_CHANGED
// 	EFI_NOT_FOUND
// 	EFI_ACCESS_DENIED
// 	EFI_NO_RESPONSE
// 	EFI_NO_MAPPING
// 	EFI_TIMEOUT
// 	EFI_NOT_STARTED
// 	EFI_ALREADY_STARTED
// 	EFI_ABORTED
// 	EFI_ICMP_ERROR
// 	EFI_TFTP_ERROR
// 	EFI_PROTOCOL_ERROR
// 	EFI_INCOMPATIBLE_VERSION
// 	EFI_SECURITY_VIOLATION
// 	EFI_CRC_ERROR
// 	EFI_END_OF_MEDIA
// 	EFI_END_OF_FILE
// 	EFI_INVALID_LANGUAGE
// 	EFI_COMPROMISED_DATA
// 	EFI_IP_ADDRESS_CONFLICT
// 	EFI_HTTP_ERROR
// )

// func parseStatus(status uint64) (err error) {
// 	code := status & 0xff

// 	if status != EFI_SUCCESS {
// 		err = fmt.Errorf("EFI_STATUS error %#x (%d)", status, code)
// 	}

// 	return
// }

//go:nosplit
//go:export uefiCall4
func UefiCall4(fn uintptr, a uintptr, b uintptr, c uintptr, d uintptr) EFI_STATUS

//	go:nosplit
//	go:export uefiCall5
//
// func UefiCall5(fn uintptr, a uintptr, b uintptr, c uintptr, d uintptr, e uintptr) EFI_STATUS
func UefiCall5(fn uintptr, a uintptr, b uintptr, c uintptr, d uintptr, e uintptr) EFI_STATUS {
	st := callFn(uint64(fn), 5, []uint64{uint64(a), uint64(b), uint64(c), uint64(d), uint64(e)})
	return EFI_STATUS(st)
}

//go:nosplit
//go:export uefiCall6
func UefiCall6(fn uintptr, a uintptr, b uintptr, c uintptr, d uintptr, e uintptr, f uintptr) EFI_STATUS

//go:nosplit
//go:export uefiCall7
func UefiCall7(fn uintptr, a uintptr, b uintptr, c uintptr, d uintptr, e uintptr, f uintptr, g uintptr) EFI_STATUS

//go:nosplit
//go:export uefiCall8
func UefiCall8(fn uintptr, a uintptr, b uintptr, c uintptr, d uintptr, e uintptr, f uintptr, g uintptr, h uintptr) EFI_STATUS

//go:nosplit
//go:export uefiCall9
func UefiCall9(fn uintptr, a uintptr, b uintptr, c uintptr, d uintptr, e uintptr, f uintptr, g uintptr, h uintptr, i uintptr) EFI_STATUS

//go:nosplit
//go:export uefiCall10
func UefiCall10(fn uintptr, a uintptr, b uintptr, c uintptr, d uintptr, e uintptr, f uintptr, g uintptr, h uintptr, i uintptr, j uintptr) EFI_STATUS
