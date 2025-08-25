// Copyright (c) WithSecure Corporation
//
// Use of this source code is governed by the license
// that can be found in the LICENSE file.

package ueficore

// s.base is the pointer to the table
// 24 bytes header (0x18)

// EFI Runtime Services offset for ResetSystem
const getTime = 0x18
const setTime = 0x20
const getVariable = 0x48
const getNextVariable = 0x50
const setVariable = 0x58
const getNextHighMonotonicCount = 0x60
const resetSystem = 0x68 // 104 = 10 * 8 + 24
const querVariableInfo = 0x80

// EFI_RESET_SYSTEM
const (
	EfiResetCold = iota
	EfiResetWarm
	EfiResetShutdown
	EfiResetPlatformSpecific
)

// ResetSystem calls EFI_RUNTIME_SERVICES.ResetSystem().
func (s *RuntimeServices) ResetSystem(resetType int) (err error) {
	status := callService(s.base+resetSystem,
		[]uint64{
			uint64(resetType),
			EFI_SUCCESS,
			0,
			0,
		},
	)

	return parseStatus(status)
}

func (s *RuntimeServices) GetVariable(name []uint16, guid []uint8) (data []byte, attr uint32, err error) {
	status := callService(s.base+getVariable,
		[]uint64{
			EFI_SUCCESS,
			0,
			0,
		},
	)

	return nil, 0, parseStatus(status)
}
