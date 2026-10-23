#pragma once

#include <cstdint>

#define CAMSYNC_SHARED_MEM_NAME   L"Global\\CamSyncSharedBuffer"
#define CAMSYNC_FRAME_EVENT_NAME  L"Global\\CamSyncNewFrameEvent"
#define CAMSYNC_FRAME_MUTEX_NAME  L"Global\\CamSyncFrameMutex"

#define CAMSYNC_MAGIC 0x43534E43 // 'CSNC'
#define CAMSYNC_PROTOCOL_VERSION 1

enum class CamSyncPixelFormat : uint32_t {
    Unknown = 0,
    NV12    = 1,
    YUY2    = 2,
    RGB32   = 3, // BGRA 32-bit (native DirectShow/GDI format)
    RGB24   = 4
};

// Maximum supported resolution is 4K UHD (3840 x 2160).
// 3840 * 2160 * 4 bytes = 33,177,600 bytes per frame buffer.
#define CAMSYNC_MAX_WIDTH 3840
#define CAMSYNC_MAX_HEIGHT 2160
#define CAMSYNC_MAX_FRAME_SIZE (CAMSYNC_MAX_WIDTH * CAMSYNC_MAX_HEIGHT * 4)

#pragma pack(push, 1)
struct CamSyncSharedHeader {
    uint32_t magic;              // CAMSYNC_MAGIC
    uint32_t version;            // CAMSYNC_PROTOCOL_VERSION
    uint32_t width;              // e.g. 1920
    uint32_t height;             // e.g. 1080
    uint32_t pixelFormat;        // CamSyncPixelFormat
    uint32_t stride;             // bytes per row
    uint32_t activeBufferIndex;  // 0 or 1
    uint32_t frameSize;          // payload size in bytes
    uint64_t frameNumber;        // monotonic sequence counter
    uint64_t timestampNs;        // presentation timestamp
    uint32_t isStreaming;        // 1 if active, 0 if standby/idle
    uint8_t  reserved[60];       // Header padded to 128 bytes
};

struct CamSyncSharedMemoryLayout {
    CamSyncSharedHeader header;
    uint8_t buffer0[CAMSYNC_MAX_FRAME_SIZE];
    uint8_t buffer1[CAMSYNC_MAX_FRAME_SIZE];
};
#pragma pack(pop)
