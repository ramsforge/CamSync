#define CAMSYNC_EXPORTS
#include "CamSyncBridge.h"
#include "../shared/CamSyncSharedBuffer.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <wmcodecdsp.h>
#include <iostream>
#include <vector>
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
static uint32_t g_decoderWidth = 1920;
static uint32_t g_decoderHeight = 1080;
static std::vector<uint8_t> g_rgbBuffer;

// CLSID_CMSH264DecoderMFT: 62CE7E72-4C71-4d20-B15D-452831A87D9D
static const GUID CLSID_H264Decoder = { 0x62CE7E72, 0x4C71, 0x4d20, { 0xB1, 0x5D, 0x45, 0x28, 0x31, 0xA8, 0x7D, 0x9D } };

static bool EnsureDecoder(uint32_t width, uint32_t height) {
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

    if (g_pDecoder && g_decoderWidth == width && g_decoderHeight == height) {
        return true;
    }

    if (g_pDecoder) {
        g_pDecoder->Release();
        g_pDecoder = nullptr;
    }

    g_decoderWidth = width;
    g_decoderHeight = height;
    g_rgbBuffer.resize(width * height * 4);

    HRESULT hr = CoCreateInstance(CLSID_H264Decoder, nullptr, CLSCTX_INPROC_SERVER, IID_IMFTransform, (void**)&g_pDecoder);
    if (FAILED(hr) || !g_pDecoder) {
        return false;
    }

    // Set Input Type (H.264)
    IMFMediaType* pInputType = nullptr;
    hr = MFCreateMediaType(&pInputType);
    if (SUCCEEDED(hr)) {
        pInputType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        pInputType->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
        MFSetAttributeSize(pInputType, MF_MT_FRAME_SIZE, width, height);
        hr = g_pDecoder->SetInputType(0, pInputType, 0);
        pInputType->Release();
    }
    if (FAILED(hr)) return false;

    // Set Output Type (NV12)
    DWORD typeIndex = 0;
    IMFMediaType* pAvailableType = nullptr;
    bool outputSet = false;
    while (g_pDecoder->GetOutputAvailableType(0, typeIndex++, &pAvailableType) == S_OK) {
        GUID subtype = GUID_NULL;
        pAvailableType->GetGUID(MF_MT_SUBTYPE, &subtype);
        if (subtype == MFVideoFormat_NV12) {
            hr = g_pDecoder->SetOutputType(0, pAvailableType, 0);
            pAvailableType->Release();
            if (SUCCEEDED(hr)) {
                outputSet = true;
                break;
            }
        }
        pAvailableType->Release();
    }
    if (!outputSet) return false;

    g_pDecoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    g_pDecoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    return true;
}

CAMSYNC_API int CamSync_Init() {
    if (g_pSharedMem) return 1;

    CoInitializeEx(nullptr, COINIT_MULTITHREADED);

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

    EnsureDecoder(1920, 1080);
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
    if (!pNalData || nalSize == 0) return 0;
    if (!EnsureDecoder(g_decoderWidth, g_decoderHeight)) return 0;

    // Check if NAL has Annex B 3-byte or 4-byte start code
    bool hasStartCode = (nalSize >= 4 && pNalData[0] == 0 && pNalData[1] == 0 && pNalData[2] == 0 && pNalData[3] == 1) ||
                        (nalSize >= 3 && pNalData[0] == 0 && pNalData[1] == 0 && pNalData[2] == 1);

    uint32_t totalInputSize = hasStartCode ? nalSize : (nalSize + 4);
    IMFMediaBuffer* pInputBuffer = nullptr;
    HRESULT hr = MFCreateMemoryBuffer(totalInputSize, &pInputBuffer);
    if (FAILED(hr)) return 0;

    BYTE* pDst = nullptr;
    hr = pInputBuffer->Lock(&pDst, nullptr, nullptr);
    if (SUCCEEDED(hr)) {
        if (!hasStartCode) {
            pDst[0] = 0; pDst[1] = 0; pDst[2] = 0; pDst[3] = 1;
            memcpy(pDst + 4, pNalData, nalSize);
        } else {
            memcpy(pDst, pNalData, nalSize);
        }
        pInputBuffer->Unlock();
        pInputBuffer->SetCurrentLength(totalInputSize);
    } else {
        pInputBuffer->Release();
        return 0;
    }

    IMFSample* pInputSample = nullptr;
    hr = MFCreateSample(&pInputSample);
    if (SUCCEEDED(hr)) {
        pInputSample->AddBuffer(pInputBuffer);
        pInputSample->SetSampleTime(timestampMs * 10000ULL);
        hr = g_pDecoder->ProcessInput(0, pInputSample, 0);
        pInputSample->Release();
    }
    pInputBuffer->Release();

    if (FAILED(hr)) return 0;

    // Process output loop (handles format change and all generated frames)
    while (true) {
        MFT_OUTPUT_DATA_BUFFER outputDataBuffer = {};
        outputDataBuffer.dwStreamID = 0;

        MFT_OUTPUT_STREAM_INFO streamInfo = {};
        g_pDecoder->GetOutputStreamInfo(0, &streamInfo);

        IMFSample* pOutputSample = nullptr;
        IMFMediaBuffer* pOutputBuffer = nullptr;

        bool providesSample = (streamInfo.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
        if (!providesSample) {
            hr = MFCreateSample(&pOutputSample);
            if (FAILED(hr)) break;

            DWORD nv12Size = streamInfo.cbSize > 0 ? streamInfo.cbSize : ((g_decoderWidth * g_decoderHeight * 3) / 2);
            hr = MFCreateMemoryBuffer(nv12Size, &pOutputBuffer);
            if (FAILED(hr)) {
                pOutputSample->Release();
                break;
            }
            pOutputSample->AddBuffer(pOutputBuffer);
            outputDataBuffer.pSample = pOutputSample;
        }

        DWORD status = 0;
        hr = g_pDecoder->ProcessOutput(0, 1, &outputDataBuffer, &status);

        if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
            if (pOutputBuffer) pOutputBuffer->Release();
            if (pOutputSample) pOutputSample->Release();
            if (outputDataBuffer.pEvents) outputDataBuffer.pEvents->Release();

            DWORD typeIdx = 0;
            IMFMediaType* pAvail = nullptr;
            while (g_pDecoder->GetOutputAvailableType(0, typeIdx++, &pAvail) == S_OK) {
                GUID sub = GUID_NULL;
                pAvail->GetGUID(MF_MT_SUBTYPE, &sub);
                if (sub == MFVideoFormat_NV12) {
                    UINT32 w = 0, h = 0;
                    if (SUCCEEDED(MFGetAttributeSize(pAvail, MF_MT_FRAME_SIZE, &w, &h)) && w > 0 && h > 0) {
                        g_decoderWidth = w;
                        g_decoderHeight = h;
                        g_rgbBuffer.resize(w * h * 4);
                    }
                    g_pDecoder->SetOutputType(0, pAvail, 0);
                    pAvail->Release();
                    break;
                }
                pAvail->Release();
            }
            continue;
        }

        if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT || FAILED(hr)) {
            if (pOutputBuffer) pOutputBuffer->Release();
            if (pOutputSample) pOutputSample->Release();
            if (outputDataBuffer.pEvents) outputDataBuffer.pEvents->Release();
            break;
        }

        IMFSample* pValidSample = outputDataBuffer.pSample ? outputDataBuffer.pSample : pOutputSample;
        if (pValidSample) {
            IMFMediaBuffer* pMediaBuffer = nullptr;
            if (SUCCEEDED(pValidSample->ConvertToContiguousBuffer(&pMediaBuffer))) {
                BYTE* pNv12 = nullptr;
                DWORD currLen = 0;
                if (SUCCEEDED(pMediaBuffer->Lock(&pNv12, nullptr, &currLen))) {
                    int w = g_decoderWidth;
                    int h = g_decoderHeight;
                    uint8_t* pRgb = g_rgbBuffer.data();

                    // Convert NV12 to BGRA (RGB32)
                    for (int y = 0; y < h; ++y) {
                        int yRow = y * w;
                        int uvRow = w * h + (y / 2) * w;
                        for (int x = 0; x < w; ++x) {
                            int Y = pNv12[yRow + x];
                            int uvIndex = uvRow + (x & ~1);
                            // Mobile hardware camera outputs NV21 (V then U)
                            int V = pNv12[uvIndex];
                            int U = pNv12[uvIndex + 1];

                            int c = Y - 16;
                            int d = U - 128;
                            int e = V - 128;

                            int r = (298 * c + 409 * e + 128) >> 8;
                            int g = (298 * c - 100 * d - 208 * e + 128) >> 8;
                            int b = (298 * c + 516 * d + 128) >> 8;

                            int idx = (yRow + x) * 4;
                            pRgb[idx + 0] = static_cast<uint8_t>(b < 0 ? 0 : (b > 255 ? 255 : b));
                            pRgb[idx + 1] = static_cast<uint8_t>(g < 0 ? 0 : (g > 255 ? 255 : g));
                            pRgb[idx + 2] = static_cast<uint8_t>(r < 0 ? 0 : (r > 255 ? 255 : r));
                            pRgb[idx + 3] = 0xFF;
                        }
                    }

                    pMediaBuffer->Unlock();
                    CamSync_WriteFrame(pRgb, w, h, static_cast<uint32_t>(CamSyncPixelFormat::RGB32), timestampMs * 1000000ULL);
                }
                pMediaBuffer->Release();
            }
        }

        if (pOutputBuffer) pOutputBuffer->Release();
        if (pOutputSample) pOutputSample->Release();
        if (outputDataBuffer.pEvents) outputDataBuffer.pEvents->Release();
    }

    return 1;
}

CAMSYNC_API int CamSync_IsVirtualCamActive() {
    if (!g_pSharedMem) return 0;
    return g_pSharedMem->header.isStreaming != 0 ? 1 : 0;
}

CAMSYNC_API int CamSync_GetLatestFrame(
    uint8_t* pOutBuffer,
    uint32_t bufferSize,
    uint32_t* pWidth,
    uint32_t* pHeight,
    uint64_t* pFrameNumber
) {
    if (!pOutBuffer || !pWidth || !pHeight || !pFrameNumber) return 0;
    if (g_rgbBuffer.empty() || g_frameCounter == 0) return 0;

    uint32_t w = g_decoderWidth;
    uint32_t h = g_decoderHeight;
    uint32_t neededSize = w * h * 4;
    if (bufferSize < neededSize) return 0;

    memcpy(pOutBuffer, g_rgbBuffer.data(), neededSize);
    *pWidth = w;
    *pHeight = h;
    *pFrameNumber = g_frameCounter;
    return 1;
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
    if (g_pDecoder) {
        g_pDecoder->Release();
        g_pDecoder = nullptr;
    }
    if (g_mfInitialized) {
        MFShutdown();
        g_mfInitialized = false;
    }
}
