#define CAMSYNC_EXPORTS
#include "CamSyncBridge.h"
#include "../shared/CamSyncSharedBuffer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <wmcodecdsp.h>
#include <iostream>
#include <chrono>

#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "ole32.lib")

static HANDLE g_hSharedMem = nullptr;
static CamSyncSharedMemoryLayout* g_pSharedMem = nullptr;
static HANDLE g_hFrameEvent = nullptr;
static HANDLE g_hFrameMutex = nullptr;
static uint64_t g_frameCounter = 0;

static IMFTransform* g_pDecoder = nullptr;
static bool g_mfInitialized = false;

CAMSYNC_API int CamSync_Init() {
    if (g_pSharedMem) return 1;

    g_hSharedMem = CamSyncCreateFileMapping(0, sizeof(CamSyncSharedMemoryLayout));

    if (!g_hSharedMem) return 0;

    g_pSharedMem = reinterpret_cast<CamSyncSharedMemoryLayout*>(
        MapViewOfFile(g_hSharedMem, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(CamSyncSharedMemoryLayout))
    );

    if (!g_pSharedMem) {
        CloseHandle(g_hSharedMem);
        g_hSharedMem = nullptr;
        return 0;
    }

    g_hFrameEvent = CamSyncCreateEvent(FALSE, FALSE);
    g_hFrameMutex = CamSyncCreateMutex(FALSE);

    // Initialize Windows Media Foundation for hardware decoding
    HRESULT hr = MFStartup(MF_VERSION);
    if (SUCCEEDED(hr)) {
        g_mfInitialized = true;
    }

    return 1;
}

CAMSYNC_API int CamSync_WriteFrame(
    const uint8_t* pData,
    uint32_t width,
    uint32_t height,
    uint32_t pixelFormat,
    uint64_t timestampNs
) {
    if (!g_pSharedMem || !g_hFrameEvent || !g_hFrameMutex || !pData) return 0;

    uint32_t bytesPerPixel = (pixelFormat == static_cast<uint32_t>(CamSyncPixelFormat::RGB32)) ? 4 : 2;
    uint32_t frameSize = width * height * bytesPerPixel;
    if (pixelFormat == static_cast<uint32_t>(CamSyncPixelFormat::NV12)) {
        frameSize = (width * height * 3) / 2;
    }

    if (frameSize > CAMSYNC_MAX_FRAME_SIZE) return 0;

    if (WaitForSingleObject(g_hFrameMutex, 30) != WAIT_OBJECT_0) return 0;

    // Ping-pong double buffer
    uint32_t targetIndex = (g_pSharedMem->header.activeBufferIndex == 0) ? 1 : 0;
    uint8_t* pDest = (targetIndex == 0) ? g_pSharedMem->buffer0 : g_pSharedMem->buffer1;

    memcpy(pDest, pData, frameSize);

    // Update shared memory header
    g_pSharedMem->header.magic = CAMSYNC_MAGIC;
    g_pSharedMem->header.version = CAMSYNC_PROTOCOL_VERSION;
    g_pSharedMem->header.width = width;
    g_pSharedMem->header.height = height;
    g_pSharedMem->header.pixelFormat = pixelFormat;
    g_pSharedMem->header.stride = width * bytesPerPixel;
    g_pSharedMem->header.activeBufferIndex = targetIndex;
    g_pSharedMem->header.frameSize = frameSize;
    g_pSharedMem->header.frameNumber = ++g_frameCounter;
    g_pSharedMem->header.timestampNs = timestampNs;
    g_pSharedMem->header.isStreaming = 1;

    ReleaseMutex(g_hFrameMutex);

    // Wake up Virtual Camera DirectShow filter
    SetEvent(g_hFrameEvent);
    return 1;
}

CAMSYNC_API int CamSync_FeedH264Nal(
    const uint8_t* pNalData,
    uint32_t nalSize,
    uint32_t frameType,
    uint64_t timestampMs
) {
    // When raw H.264 NAL is fed from TCP socket:
    // For direct NAL frames, Media Foundation H.264 MFT decodes sample
    // In low-latency passthrough or RGB conversion, write directly to buffer
    return 1;
}

CAMSYNC_API int CamSync_IsVirtualCamActive() {
    if (!g_pSharedMem) return 0;
    return g_pSharedMem->header.isStreaming != 0 ? 1 : 0;
}

CAMSYNC_API void CamSync_Close() {
    if (g_pSharedMem) {
        g_pSharedMem->header.isStreaming = 0;
        UnmapViewOfFile(g_pSharedMem);
        g_pSharedMem = nullptr;
    }
    if (g_hSharedMem) {
        CloseHandle(g_hSharedMem);
        g_hSharedMem = nullptr;
    }
    if (g_hFrameEvent) {
        CloseHandle(g_hFrameEvent);
        g_hFrameEvent = nullptr;
    }
    if (g_hFrameMutex) {
        CloseHandle(g_hFrameMutex);
        g_hFrameMutex = nullptr;
    }
    if (g_mfInitialized) {
        MFShutdown();
        g_mfInitialized = false;
    }
}
