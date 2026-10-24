#pragma once

#include <windows.h>
#include <cstdint>

#ifdef CAMSYNC_EXPORTS
#define CAMSYNC_API extern "C" __declspec(dllexport)
#else
#define CAMSYNC_API extern "C" __declspec(dllimport)
#endif

// Returns 1 on success, 0 on failure
CAMSYNC_API int CamSync_Init();

// Writes raw decoded frame (NV12 or RGB32) into shared memory and signals Virtual Camera
CAMSYNC_API int CamSync_WriteFrame(
    const uint8_t* pData,
    uint32_t width,
    uint32_t height,
    uint32_t pixelFormat, // 1 = NV12, 3 = RGB32
    uint64_t timestampNs
);

// Feeds raw H.264 NAL unit into Media Foundation hardware video decoder
CAMSYNC_API int CamSync_FeedH264Nal(
    const uint8_t* pNalData,
    uint32_t nalSize,
    uint32_t frameType, // 1 = Config, 2 = Keyframe, 3 = Delta
    uint64_t timestampMs
);

// Returns 1 if DirectShow virtual camera is actively reading frames, 0 if idle
CAMSYNC_API int CamSync_IsVirtualCamActive();

// Copies latest decoded BGRA frame for desktop UI preview
// Returns 1 if a frame was copied, 0 if no new frame or buffer too small
CAMSYNC_API int CamSync_GetLatestFrame(
    uint8_t* pOutBuffer,
    uint32_t bufferSize,
    uint32_t* pWidth,
    uint32_t* pHeight,
    uint64_t* pFrameNumber
);

// Closes and releases shared memory and decoder handles
CAMSYNC_API void CamSync_Close();
