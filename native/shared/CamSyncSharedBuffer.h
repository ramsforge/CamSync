#pragma once

#include <windows.h>
#include <sddl.h>
#include <cstdint>

#define CAMSYNC_SHARED_MEM_NAME_GLOBAL   L"Global\\CamSyncSharedBuffer"
#define CAMSYNC_FRAME_EVENT_NAME_GLOBAL  L"Global\\CamSyncNewFrameEvent"
#define CAMSYNC_FRAME_MUTEX_NAME_GLOBAL  L"Global\\CamSyncFrameMutex"

#define CAMSYNC_SHARED_MEM_NAME_LOCAL    L"Local\\CamSyncSharedBuffer"
#define CAMSYNC_FRAME_EVENT_NAME_LOCAL   L"Local\\CamSyncNewFrameEvent"
#define CAMSYNC_FRAME_MUTEX_NAME_LOCAL   L"Local\\CamSyncFrameMutex"

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

// --- Helper Functions for Cross-Session & Non-Admin Shared IPC ---

inline SECURITY_ATTRIBUTES* CamSyncGetSecurityAttributes() {
    static SECURITY_ATTRIBUTES sa;
    static PSECURITY_DESCRIPTOR pSD = nullptr;
    static bool initialized = false;
    if (!initialized) {
        // SDDL string: Everyone full control (D:(A;;GA;;;WD)), Low Mandatory Integrity level (S:(ML;;NW;;;LW))
        // This grants permission to standard non-admin users and sandboxed processes (e.g. Chrome/Edge/Zoom).
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
                L"D:(A;;GA;;;WD)S:(ML;;NW;;;LW)",
                SDDL_REVISION_1,
                &pSD,
                nullptr)) {
            sa.nLength = sizeof(sa);
            sa.lpSecurityDescriptor = pSD;
            sa.bInheritHandle = FALSE;
            initialized = true;
            return &sa;
        }
        initialized = true;
    }
    return (pSD != nullptr) ? &sa : nullptr;
}

inline HANDLE CamSyncCreateFileMapping(DWORD sizeHigh, DWORD sizeLow, bool* pIsGlobal = nullptr) {
    SECURITY_ATTRIBUTES* pSA = CamSyncGetSecurityAttributes();

    // 1. Try Global\ namespace first (works when elevated as Administrator)
    HANDLE hMap = CreateFileMappingW(
        INVALID_HANDLE_VALUE,
        pSA,
        PAGE_READWRITE,
        sizeHigh,
        sizeLow,
        CAMSYNC_SHARED_MEM_NAME_GLOBAL
    );

    if (hMap != nullptr && GetLastError() != ERROR_ACCESS_DENIED) {
        if (pIsGlobal) *pIsGlobal = true;
        return hMap;
    }

    if (hMap != nullptr) {
        CloseHandle(hMap);
    }

    // 2. Fall back to Local\ namespace (works for standard non-admin users)
    hMap = CreateFileMappingW(
        INVALID_HANDLE_VALUE,
        pSA,
        PAGE_READWRITE,
        sizeHigh,
        sizeLow,
        CAMSYNC_SHARED_MEM_NAME_LOCAL
    );

    if (pIsGlobal) *pIsGlobal = false;
    return hMap;
}

inline HANDLE CamSyncOpenFileMapping(DWORD desiredAccess) {
    // 1. Try Global namespace first
    HANDLE hMap = OpenFileMappingW(desiredAccess, FALSE, CAMSYNC_SHARED_MEM_NAME_GLOBAL);
    if (hMap) return hMap;

    // 2. Try Local namespace
    return OpenFileMappingW(desiredAccess, FALSE, CAMSYNC_SHARED_MEM_NAME_LOCAL);
}

inline HANDLE CamSyncCreateEvent(BOOL manualReset, BOOL initialState) {
    SECURITY_ATTRIBUTES* pSA = CamSyncGetSecurityAttributes();
    HANDLE hEvent = CreateEventW(pSA, manualReset, initialState, CAMSYNC_FRAME_EVENT_NAME_GLOBAL);
    if (!hEvent || GetLastError() == ERROR_ACCESS_DENIED) {
        if (hEvent) CloseHandle(hEvent);
        hEvent = CreateEventW(pSA, manualReset, initialState, CAMSYNC_FRAME_EVENT_NAME_LOCAL);
    }
    return hEvent;
}

inline HANDLE CamSyncOpenEvent(DWORD desiredAccess) {
    HANDLE hEvent = OpenEventW(desiredAccess, FALSE, CAMSYNC_FRAME_EVENT_NAME_GLOBAL);
    if (hEvent) return hEvent;
    return OpenEventW(desiredAccess, FALSE, CAMSYNC_FRAME_EVENT_NAME_LOCAL);
}

inline HANDLE CamSyncCreateMutex(BOOL initialOwner) {
    SECURITY_ATTRIBUTES* pSA = CamSyncGetSecurityAttributes();
    HANDLE hMutex = CreateMutexW(pSA, initialOwner, CAMSYNC_FRAME_MUTEX_NAME_GLOBAL);
    if (!hMutex || GetLastError() == ERROR_ACCESS_DENIED) {
        if (hMutex) CloseHandle(hMutex);
        hMutex = CreateMutexW(pSA, initialOwner, CAMSYNC_FRAME_MUTEX_NAME_LOCAL);
    }
    return hMutex;
}

inline HANDLE CamSyncOpenMutex(DWORD desiredAccess) {
    HANDLE hMutex = OpenMutexW(desiredAccess, FALSE, CAMSYNC_FRAME_MUTEX_NAME_GLOBAL);
    if (hMutex) return hMutex;
    return OpenMutexW(desiredAccess, FALSE, CAMSYNC_FRAME_MUTEX_NAME_LOCAL);
}
