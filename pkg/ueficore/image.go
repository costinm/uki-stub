// Copyright (c) WithSecure Corporation
//
// Use of this source code is governed by the license
// that can be found in the LICENSE file.

package ueficore

import (
	"io/fs"
)

// EFI Boot Services offsets
const (
	loadImage  = 0xc8
	startImage = 0xd0
)

// LoadImage calls EFI_BOOT_SERVICES.LoadImage().
// boot - from boot manager
// root, name - root dir and name
func (s *BootServices) LoadImage(boot int, root *FS, name string) (imageHandle uint64, err error) {
	buf, err := fs.ReadFile(root, name)

	if err != nil {
		return
	}

	_, _, devicePath, err := root.FilePath(name)

	if err != nil {
		return
	}

	// may pass a buffer with the source image.
	status := callService(s.base+loadImage,
		[]uint64{
			uint64(boot),
			s.imageHandle,
			ptrval(&devicePath[0]),
			ptrval(&buf[0]),
			uint64(len(buf)),
			ptrval(&imageHandle),
		},
	)

	return imageHandle, parseStatus(status)
}

// LoadImageMem loads the image from a memory buffer, when the file has already
// been loaded in memory. Useful when doing verification first.
func (s *BootServices) LoadImageMem(boot int, root *FS, name string, buf []byte) (imageHandle uint64, err error) {
	_, _, devicePath, err := root.FilePath(name)

	if err != nil {
		return
	}

	// may pass a buffer with the source image.
	status := callService(s.base+loadImage,
		[]uint64{
			uint64(boot),
			s.imageHandle,
			ptrval(&devicePath[0]),
			ptrval(&buf[0]),
			uint64(len(buf)),
			ptrval(&imageHandle),
		},
	)

	return imageHandle, parseStatus(status)
}

// StartImage calls EFI_BOOT_SERVICES.StartImage().
func (s *BootServices) StartImage(imageHandle uint64) (err error) {
	status := callService(s.base+startImage,
		[]uint64{
			imageHandle,
			0,
			0,
		},
	)

	return parseStatus(status)
}
