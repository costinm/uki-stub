
#include <stdint.h>

#define SETUP_MAGIC             0x53726448      /* "HdrS" */
struct SetupHeader {
        uint8_t boot_sector[0x01f1];
        uint8_t setup_secs;
        uint16_t root_flags;
        uint32_t sys_size;
        uint16_t ram_size;
        uint16_t video_mode;
        uint16_t root_dev;
        uint16_t signature;
        uint16_t jump;
        uint32_t header;
        uint16_t version;
        uint16_t su_switch;
        uint16_t setup_seg;
        uint16_t start_sys;
        uint16_t kernel_ver;
        uint8_t loader_id;
        uint8_t load_flags;
        uint16_t movesize;
        uint32_t code32_start;
        uint32_t ramdisk_start;
        uint32_t ramdisk_len;
        uint32_t bootsect_kludge;
        uint16_t heap_end;
        uint8_t ext_loader_ver;
        uint8_t ext_loader_type;
        uint32_t cmd_line_ptr;
        uint32_t ramdisk_max;
        uint32_t kernel_alignment;
        uint8_t relocatable_kernel;
        uint8_t min_alignment;
        uint16_t xloadflags;
        uint32_t cmdline_size;
        uint32_t hardware_subarch;
        uint64_t hardware_subarch_data;
        uint32_t payload_offset;
        uint32_t payload_length;
        uint64_t setup_data;
        uint64_t pref_address;
        uint32_t init_size;
        uint32_t handover_offset;
} __attribute__((packed));

