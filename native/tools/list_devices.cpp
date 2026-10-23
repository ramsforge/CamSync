#include <windows.h>
#include <dshow.h>
#include <iostream>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "strmiids.lib")

int main() {
    CoInitialize(nullptr);

    ICreateDevEnum* pDevEnum = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_SystemDeviceEnum, nullptr, CLSCTX_INPROC_SERVER,
                                  IID_ICreateDevEnum, reinterpret_cast<void**>(&pDevEnum));

    if (FAILED(hr) || !pDevEnum) {
        std::cerr << "Failed to create ICreateDevEnum! HRESULT: 0x" << std::hex << hr << "\n";
        CoUninitialize();
        return 1;
    }

    IEnumMoniker* pEnum = nullptr;
    hr = pDevEnum->CreateClassEnumerator(CLSID_VideoInputDeviceCategory, &pEnum, 0);

    std::cout << "=================================================\n";
    std::cout << " Windows DirectShow Video Capture Devices:\n";
    std::cout << "=================================================\n";

    if (hr == S_OK && pEnum) {
        IMoniker* pMoniker = nullptr;
        int count = 0;
        bool foundCamSync = false;

        while (pEnum->Next(1, &pMoniker, nullptr) == S_OK) {
            IPropertyBag* pPropBag = nullptr;
            hr = pMoniker->BindToStorage(nullptr, nullptr, IID_IPropertyBag, reinterpret_cast<void**>(&pPropBag));
            if (SUCCEEDED(hr) && pPropBag) {
                VARIANT varName;
                VariantInit(&varName);
                hr = pPropBag->Read(L"FriendlyName", &varName, nullptr);
                if (SUCCEEDED(hr)) {
                    std::wcout << L" [" << ++count << L"] " << varName.bstrVal << L"\n";
                    if (wcscmp(varName.bstrVal, L"CamSync Virtual Camera") == 0) {
                        foundCamSync = true;
                    }
                }
                VariantClear(&varName);
                pPropBag->Release();
            }
            pMoniker->Release();
        }
        pEnum->Release();

        std::cout << "-------------------------------------------------\n";
        if (foundCamSync) {
            std::cout << " SUCCESS: 'CamSync Virtual Camera' is detected by Windows!\n";
        } else {
            std::cout << " FAILURE: 'CamSync Virtual Camera' was not in the enumerated list.\n";
        }
    } else {
        std::cout << "No video capture devices found (or enumerator returned S_FALSE).\n";
    }

    pDevEnum->Release();
    CoUninitialize();
    return 0;
}
