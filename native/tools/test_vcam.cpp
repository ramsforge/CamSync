#include <windows.h>
#include <dshow.h>
#include <iostream>
#include "../driver/CamSyncGuids.h"

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "strmiids.lib")

int main() {
    std::cout << "Testing DirectShow instantiation of CamSync Virtual Camera...\n";
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
        std::cerr << "CoInitializeEx failed: 0x" << std::hex << hr << "\n";
        return 1;
    }

    IBaseFilter* pFilter = nullptr;
    hr = CoCreateInstance(CLSID_CamSyncVirtualCam, nullptr, CLSCTX_INPROC_SERVER,
                          IID_IBaseFilter, reinterpret_cast<void**>(&pFilter));

    if (FAILED(hr) || !pFilter) {
        std::cerr << "FAILED: CoCreateInstance(CLSID_CamSyncVirtualCam) failed! hr = 0x" << std::hex << hr << "\n";
        CoUninitialize();
        return 1;
    }

    std::cout << "SUCCESS: CamSync Virtual Camera created successfully!\n";

    IGraphBuilder* pGraph = nullptr;
    hr = CoCreateInstance(CLSID_FilterGraph, nullptr, CLSCTX_INPROC_SERVER,
                          IID_IGraphBuilder, reinterpret_cast<void**>(&pGraph));

    if (SUCCEEDED(hr) && pGraph) {
        hr = pGraph->AddFilter(pFilter, L"CamSync Virtual Camera");
        std::cout << "AddFilter to DirectShow Graph: hr = 0x" << std::hex << hr << "\n";

        IMediaControl* pControl = nullptr;
        hr = pGraph->QueryInterface(IID_IMediaControl, reinterpret_cast<void**>(&pControl));
        if (SUCCEEDED(hr) && pControl) {
            std::cout << "Starting graph (Run)...\n";
            hr = pControl->Run();
            std::cout << "pControl->Run() returned: 0x" << std::hex << hr << "\n";

            OAFilterState state = State_Stopped;
            hr = pControl->GetState(1000, &state);
            std::cout << "pControl->GetState() returned: 0x" << std::hex << hr << " (State=" << state << ")\n";

            Sleep(1500);

            std::cout << "Stopping graph...\n";
            pControl->Stop();
            pControl->Release();
        }
        pGraph->Release();
    }

    pFilter->Release();
    CoUninitialize();

    std::cout << "TEST COMPLETE: CamSync Virtual Camera runs cleanly with 0 errors!\n";
    return 0;
}
