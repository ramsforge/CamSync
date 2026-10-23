#include <windows.h>
#include <dshow.h>
#include <shlwapi.h>
#include "CamSyncGuids.h"
#include "CamSyncFilter.h"

#pragma comment(lib, "shlwapi.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")
#pragma comment(lib, "advapi32.lib")

static HMODULE g_hModule = nullptr;
static LONG g_serverLocks = 0;

// COM Class Factory
class CamSyncClassFactory : public IClassFactory {
public:
    CamSyncClassFactory() : m_refCount(1) {}

    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IClassFactory) {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    STDMETHODIMP_(ULONG) AddRef() override {
        return InterlockedIncrement(&m_refCount);
    }

    STDMETHODIMP_(ULONG) Release() override {
        ULONG count = InterlockedDecrement(&m_refCount);
        if (count == 0) delete this;
        return count;
    }

    STDMETHODIMP CreateInstance(IUnknown* pUnkOuter, REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        *ppv = nullptr;
        if (pUnkOuter) return CLASS_E_NOAGGREGATION;

        auto* pFilter = new CamSyncFilter();
        HRESULT hr = pFilter->QueryInterface(riid, ppv);
        pFilter->Release();
        return hr;
    }

    STDMETHODIMP LockServer(BOOL fLock) override {
        if (fLock) {
            InterlockedIncrement(&g_serverLocks);
        } else {
            InterlockedDecrement(&g_serverLocks);
        }
        return S_OK;
    }

private:
    LONG m_refCount;
};

// Dll Entry Point
BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    if (fdwReason == DLL_PROCESS_ATTACH) {
        g_hModule = hinstDLL;
        DisableThreadLibraryCalls(hinstDLL);
    }
    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID rclsid, REFIID riid, void** ppv) {
    if (!ppv) return E_POINTER;
    *ppv = nullptr;

    if (rclsid == CLSID_CamSyncVirtualCam) {
        auto* pFactory = new CamSyncClassFactory();
        HRESULT hr = pFactory->QueryInterface(riid, ppv);
        pFactory->Release();
        return hr;
    }

    return CLASS_E_CLASSNOTAVAILABLE;
}

STDAPI DllCanUnloadNow() {
    return (g_serverLocks == 0) ? S_OK : S_FALSE;
}

// Registry helpers with per-user fallback (enables non-admin installation)
static LONG SetRegString(HKEY rootKey, LPCWSTR subKey, LPCWSTR valueName, LPCWSTR data) {
    HKEY hSubKey = nullptr;
    LONG res = RegCreateKeyExW(rootKey, subKey, 0, nullptr, REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &hSubKey, nullptr);
    if (res == ERROR_ACCESS_DENIED && rootKey == HKEY_CLASSES_ROOT) {
        WCHAR hkcuSubKey[512];
        swprintf_s(hkcuSubKey, L"Software\\Classes\\%s", subKey);
        res = RegCreateKeyExW(HKEY_CURRENT_USER, hkcuSubKey, 0, nullptr, REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &hSubKey, nullptr);
    }
    if (res == ERROR_SUCCESS && hSubKey) {
        res = RegSetValueExW(hSubKey, valueName, 0, REG_SZ, reinterpret_cast<const BYTE*>(data), (static_cast<DWORD>(wcslen(data)) + 1) * sizeof(WCHAR));
        RegCloseKey(hSubKey);
    }
    return res;
}

static LONG DeleteRegKeyTree(HKEY rootKey, LPCWSTR subKey) {
    LONG res = RegDeleteTreeW(rootKey, subKey);
    if (rootKey == HKEY_CLASSES_ROOT) {
        WCHAR hkcuSubKey[512];
        swprintf_s(hkcuSubKey, L"Software\\Classes\\%s", subKey);
        RegDeleteTreeW(HKEY_CURRENT_USER, hkcuSubKey);
    }
    return res;
}

STDAPI DllRegisterServer() {
    WCHAR dllPath[MAX_PATH];
    if (!GetModuleFileNameW(g_hModule, dllPath, MAX_PATH)) {
        return HRESULT_FROM_WIN32(GetLastError());
    }

    // 1. Register under HKCR\CLSID\{9E40E35B-1B47-497B-8DC4-666E63A759C1}
    WCHAR clsidKey[256];
    swprintf_s(clsidKey, L"CLSID\\%s", CAMSYNC_CLSID_STR);

    SetRegString(HKEY_CLASSES_ROOT, clsidKey, nullptr, CAMSYNC_FILTER_NAME);

    WCHAR inprocKey[256];
    swprintf_s(inprocKey, L"%s\\InprocServer32", clsidKey);
    SetRegString(HKEY_CLASSES_ROOT, inprocKey, nullptr, dllPath);
    SetRegString(HKEY_CLASSES_ROOT, inprocKey, L"ThreadingModel", L"Both");

    // 2. Register under DirectShow Video Input Device Category
    // HKCR\CLSID\{860BB310-5D01-11d0-BD3B-00A0C911CE86}\Instance\{9E40E35B-1B47-497B-8DC4-666E63A759C1}
    const WCHAR* catGuid = L"{860BB310-5D01-11d0-BD3B-00A0C911CE86}";
    WCHAR catInstanceKey[512];
    swprintf_s(catInstanceKey, L"CLSID\\%s\\Instance\\%s", catGuid, CAMSYNC_CLSID_STR);

    SetRegString(HKEY_CLASSES_ROOT, catInstanceKey, L"CLSID", CAMSYNC_CLSID_STR);
    SetRegString(HKEY_CLASSES_ROOT, catInstanceKey, L"FriendlyName", CAMSYNC_FILTER_NAME);

    // Also register filter pins info with IFilterMapper2 for full DShow discoverability
    HRESULT hr = CoInitialize(nullptr);
    IFilterMapper2* pFM = nullptr;
    hr = CoCreateInstance(CLSID_FilterMapper2, nullptr, CLSCTX_INPROC_SERVER, IID_IFilterMapper2, reinterpret_cast<void**>(&pFM));
    if (SUCCEEDED(hr) && pFM) {
        REGFILTER2 rf2 = {};
        rf2.dwVersion = 1;
        rf2.dwMerit = MERIT_DO_NOT_USE; // Capture devices don't need merit for auto-graph building
        rf2.cPins = 1;

        REGFILTERPINS rfp = {};
        rfp.strName = const_cast<LPWSTR>(L"Capture");
        rfp.bRendered = FALSE;
        rfp.bOutput = TRUE;
        rfp.bZero = FALSE;
        rfp.bMany = FALSE;
        rfp.nMediaTypes = 1;

        REGPINTYPES rpt = {};
        rpt.clsMajorType = &MEDIATYPE_Video;
        rpt.clsMinorType = &MEDIASUBTYPE_RGB32;
        rfp.lpMediaType = &rpt;

        rf2.rgPins = &rfp;

        pFM->RegisterFilter(CLSID_CamSyncVirtualCam, CAMSYNC_FILTER_NAME, nullptr, &CLSID_VideoInputDeviceCategory, nullptr, &rf2);
        pFM->Release();
    }
    CoUninitialize();

    return S_OK;
}

STDAPI DllUnregisterServer() {
    WCHAR clsidKey[256];
    swprintf_s(clsidKey, L"CLSID\\%s", CAMSYNC_CLSID_STR);
    DeleteRegKeyTree(HKEY_CLASSES_ROOT, clsidKey);

    // Remove from Video Input Device Category
    const WCHAR* catGuid = L"{860BB310-5D01-11d0-BD3B-00A0C911CE86}";
    WCHAR catInstanceKey[512];
    swprintf_s(catInstanceKey, L"CLSID\\%s\\Instance\\%s", catGuid, CAMSYNC_CLSID_STR);
    DeleteRegKeyTree(HKEY_CLASSES_ROOT, catInstanceKey);

    // Unregister from FilterMapper2
    HRESULT hr = CoInitialize(nullptr);
    IFilterMapper2* pFM = nullptr;
    hr = CoCreateInstance(CLSID_FilterMapper2, nullptr, CLSCTX_INPROC_SERVER, IID_IFilterMapper2, reinterpret_cast<void**>(&pFM));
    if (SUCCEEDED(hr) && pFM) {
        pFM->UnregisterFilter(&CLSID_VideoInputDeviceCategory, nullptr, CLSID_CamSyncVirtualCam);
        pFM->Release();
    }
    CoUninitialize();

    return S_OK;
}
