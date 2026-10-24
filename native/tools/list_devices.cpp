#include <windows.h>
#include <dshow.h>
#include <mfapi.h>
#include <mfidl.h>
#include <iostream>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "strmiids.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mf.lib")
#pragma comment(lib, "mfuuid.lib")

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

    // Check Windows Media Foundation (used by Windows Camera App, Chrome, Edge, Teams)
    std::cout << "\n=================================================\n";
    std::cout << " Windows Media Foundation Video Capture Devices:\n";
    std::cout << "=================================================\n";

    hr = MFStartup(MF_VERSION);
    if (SUCCEEDED(hr)) {
        IMFAttributes* pAttributes = nullptr;
        hr = MFCreateAttributes(&pAttributes, 1);
        if (SUCCEEDED(hr)) {
            pAttributes->SetGUID(
                MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
                MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID
            );

            IMFActivate** ppDevices = nullptr;
            UINT32 count = 0;
            hr = MFEnumDeviceSources(pAttributes, &ppDevices, &count);
            std::cout << "MFEnumDeviceSources count: " << count << " (HR: 0x" << std::hex << hr << ")\n";

            bool foundMfCamSync = false;
            for (UINT32 i = 0; i < count; i++) {
                WCHAR* pName = nullptr;
                UINT32 nameLen = 0;
                ppDevices[i]->GetAllocatedString(
                    MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME,
                    &pName,
                    &nameLen
                );
                if (pName) {
                    std::wcout << L" [" << (i + 1) << L"] " << pName << L"\n";
                    if (wcscmp(pName, L"CamSync Virtual Camera") == 0) {
                        foundMfCamSync = true;
                    }
                    CoTaskMemFree(pName);
                }

                // Print all attributes
                UINT32 attrCount = 0;
                ppDevices[i]->GetCount(&attrCount);
                for (UINT32 a = 0; a < attrCount; a++) {
                    GUID guidKey;
                    PROPVARIANT propVal;
                    PropVariantInit(&propVal);
                    if (SUCCEEDED(ppDevices[i]->GetItemByIndex(a, &guidKey, &propVal))) {
                        LPOLESTR pGuidStr = nullptr;
                        StringFromCLSID(guidKey, &pGuidStr);
                        if (propVal.vt == VT_LPWSTR) {
                            std::wcout << L"    attr " << pGuidStr << L" = " << propVal.pwszVal << L"\n";
                        } else if (propVal.vt == VT_CLSID) {
                            LPOLESTR pValStr = nullptr;
                            StringFromCLSID(*propVal.puuid, &pValStr);
                            std::wcout << L"    attr " << pGuidStr << L" = (GUID) " << pValStr << L"\n";
                            CoTaskMemFree(pValStr);
                        } else {
                            std::wcout << L"    attr " << pGuidStr << L" = (vt " << propVal.vt << L")\n";
                        }
                        if (pGuidStr) CoTaskMemFree(pGuidStr);
                        PropVariantClear(&propVal);
                    }
                }

                ppDevices[i]->Release();
            }
            CoTaskMemFree(ppDevices);
            pAttributes->Release();

            std::cout << "-------------------------------------------------\n";
            if (foundMfCamSync) {
                std::cout << " SUCCESS: 'CamSync Virtual Camera' is detected by Media Foundation!\n";
            } else {
                std::cout << " WARNING: 'CamSync Virtual Camera' was not in the Media Foundation list.\n";
            }
        }
        MFShutdown();
    }

    CoUninitialize();
    return 0;
}
