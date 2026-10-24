#include <windows.h>
#include <iostream>
#include <cmath>
#include <chrono>
#include <thread>
#include "../shared/CamSyncSharedBuffer.h"

int main() {
    std::cout << "========================================\n";
    std::cout << "   CamSync Test Pattern Generator\n";
    std::cout << "========================================\n";

    bool isGlobal = false;
    HANDLE hSharedMem = CamSyncCreateFileMapping(0, sizeof(CamSyncSharedMemoryLayout), &isGlobal);

    if (!hSharedMem) {
        std::cerr << "Failed to create shared memory file mapping! Error: " << GetLastError() << "\n";
        return 1;
    }

    std::wcout << L"Shared memory created in namespace: " 
               << (isGlobal ? CAMSYNC_SHARED_MEM_NAME_GLOBAL : CAMSYNC_SHARED_MEM_NAME_LOCAL) 
               << L"\n" << std::flush;

    auto* pSharedMem = reinterpret_cast<CamSyncSharedMemoryLayout*>(
        MapViewOfFile(hSharedMem, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(CamSyncSharedMemoryLayout))
    );

    if (!pSharedMem) {
        std::cerr << "Failed to map view of file! Error: " << GetLastError() << "\n";
        CloseHandle(hSharedMem);
        return 1;
    }

    HANDLE hFrameEvent = CamSyncCreateEvent(FALSE, FALSE);
    HANDLE hFrameMutex = CamSyncCreateMutex(FALSE);

    const int width = 1920;
    const int height = 1080;
    const int fps = 60;
    const uint32_t frameSize = width * height * 4;

    std::cout << "Generating animated 1080p @ 60 FPS test pattern into shared memory...\n";
    std::cout << "Open Windows Camera App, OBS Studio, or Zoom to test 'CamSync Virtual Camera'.\n";
    std::cout << "Press Ctrl+C to stop.\n\n" << std::flush;

    uint64_t frameNumber = 0;

    // Standard SMPTE-like test colors in BGRA format
    const uint32_t colors[8] = {
        0xFFFFFFFF, // White
        0xFFFFFF00, // Yellow
        0xFF00FFFF, // Cyan
        0xFF00FF00, // Green
        0xFFFF00FF, // Magenta
        0xFFFF0000, // Red
        0xFF0000FF, // Blue
        0xFF1A1A1A  // Near Black
    };

    auto startTime = std::chrono::steady_clock::now();

    while (true) {
        auto frameStart = std::chrono::steady_clock::now();

        // Alternate double buffer to eliminate tearing
        uint32_t nextBufferIndex = (pSharedMem->header.activeBufferIndex == 0) ? 1 : 0;
        uint8_t* pTargetBuffer = (nextBufferIndex == 0) ? pSharedMem->buffer0 : pSharedMem->buffer1;
        auto* pixels = reinterpret_cast<uint32_t*>(pTargetBuffer);

        // Render Color Bars across width
        int barWidth = width / 8;
        for (int y = 0; y < height; ++y) {
            for (int x = 0; x < width; ++x) {
                int colIdx = x / barWidth;
                if (colIdx > 7) colIdx = 7;
                pixels[y * width + x] = colors[colIdx];
            }
        }

        // Draw animated bouncing scanline / indicator
        int scanY = (frameNumber * 6) % height;
        for (int dy = -6; dy <= 6; ++dy) {
            int y = scanY + dy;
            if (y >= 0 && y < height) {
                for (int x = 0; x < width; ++x) {
                    pixels[y * width + x] = 0xFF00E5FF; // Bright Cyan
                }
            }
        }

        // Draw animated center bouncing circle
        int ballX = static_cast<int>((std::sin(frameNumber * 0.04) * 0.4 + 0.5) * width);
        int ballY = static_cast<int>((std::cos(frameNumber * 0.03) * 0.35 + 0.5) * height);
        int radius = 45;
        for (int dy = -radius; dy <= radius; ++dy) {
            for (int dx = -radius; dx <= radius; ++dx) {
                if (dx * dx + dy * dy <= radius * radius) {
                    int px = ballX + dx;
                    int py = ballY + dy;
                    if (px >= 0 && px < width && py >= 0 && py < height) {
                        pixels[py * width + px] = 0xFF101010; // Dark disc
                    }
                }
            }
        }

        // Acquire mutex and publish frame
        if (WaitForSingleObject(hFrameMutex, 50) == WAIT_OBJECT_0) {
            pSharedMem->header.magic = CAMSYNC_MAGIC;
            pSharedMem->header.version = CAMSYNC_PROTOCOL_VERSION;
            pSharedMem->header.width = width;
            pSharedMem->header.height = height;
            pSharedMem->header.pixelFormat = static_cast<uint32_t>(CamSyncPixelFormat::RGB32);
            pSharedMem->header.stride = width * 4;
            pSharedMem->header.activeBufferIndex = nextBufferIndex;
            pSharedMem->header.frameSize = frameSize;
            pSharedMem->header.frameNumber = frameNumber;
            pSharedMem->header.timestampNs = std::chrono::duration_cast<std::chrono::nanoseconds>(frameStart - startTime).count();
            pSharedMem->header.isStreaming = 1;

            ReleaseMutex(hFrameMutex);

            // Signal new frame event
            SetEvent(hFrameEvent);
        }

        frameNumber++;
        if (frameNumber % 300 == 0) {
            std::cout << "[CamSync Feeder] Published frame " << frameNumber << " (" << (frameNumber / 60) << "s streaming)\n";
        }

        // Maintain ~60 FPS (16.66ms per frame)
        auto frameElapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - frameStart).count();
        if (frameElapsed < 16) {
            std::this_thread::sleep_for(std::chrono::milliseconds(16 - frameElapsed));
        }
    }

    UnmapViewOfFile(pSharedMem);
    CloseHandle(hSharedMem);
    CloseHandle(hFrameEvent);
    CloseHandle(hFrameMutex);
    return 0;
}
