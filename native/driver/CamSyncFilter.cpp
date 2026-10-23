#include "CamSyncFilter.h"
#include "CamSyncPin.h"

// Simple IEnumPins implementation
class CamSyncEnumPins : public IEnumPins {
public:
    explicit CamSyncEnumPins(IPin* pPin) : m_refCount(1), m_index(0), m_pPin(pPin) {
        if (m_pPin) m_pPin->AddRef();
    }
    virtual ~CamSyncEnumPins() {
        if (m_pPin) m_pPin->Release();
    }

    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IEnumPins) {
            *ppv = static_cast<IEnumPins*>(this);
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

    STDMETHODIMP Next(ULONG cPins, IPin** ppPins, ULONG* pcFetched) override {
        if (!ppPins) return E_POINTER;
        ULONG fetched = 0;
        if (m_index == 0 && cPins > 0 && m_pPin) {
            ppPins[0] = m_pPin;
            m_pPin->AddRef();
            m_index = 1;
            fetched = 1;
        }
        if (pcFetched) *pcFetched = fetched;
        return (fetched == cPins) ? S_OK : S_FALSE;
    }

    STDMETHODIMP Skip(ULONG cPins) override {
        m_index += cPins;
        return (m_index <= 1) ? S_OK : S_FALSE;
    }

    STDMETHODIMP Reset() override {
        m_index = 0;
        return S_OK;
    }

    STDMETHODIMP Clone(IEnumPins** ppEnum) override {
        if (!ppEnum) return E_POINTER;
        auto* pClone = new CamSyncEnumPins(m_pPin);
        pClone->m_index = m_index;
        *ppEnum = pClone;
        return S_OK;
    }

private:
    LONG m_refCount;
    ULONG m_index;
    IPin* m_pPin;
};

// --- CamSyncFilter Implementation ---

CamSyncFilter::CamSyncFilter()
    : m_refCount(1),
      m_state(State_Stopped),
      m_pGraph(nullptr),
      m_pClock(nullptr) {
    InitializeCriticalSection(&m_cs);
    m_filterName[0] = L'\0';
    m_pPin = new CamSyncOutputPin(this);
}

CamSyncFilter::~CamSyncFilter() {
    if (m_pPin) {
        m_pPin->Release();
        m_pPin = nullptr;
    }
    if (m_pClock) {
        m_pClock->Release();
        m_pClock = nullptr;
    }
    DeleteCriticalSection(&m_cs);
}

STDMETHODIMP CamSyncFilter::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown) {
        *ppv = static_cast<IBaseFilter*>(this);
    } else if (riid == IID_IPersist) {
        *ppv = static_cast<IPersist*>(this);
    } else if (riid == IID_IMediaFilter) {
        *ppv = static_cast<IMediaFilter*>(this);
    } else if (riid == IID_IBaseFilter) {
        *ppv = static_cast<IBaseFilter*>(this);
    } else if (riid == IID_IAMFilterMiscFlags) {
        *ppv = static_cast<IAMFilterMiscFlags*>(this);
    } else {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) CamSyncFilter::AddRef() {
    return InterlockedIncrement(&m_refCount);
}

STDMETHODIMP_(ULONG) CamSyncFilter::Release() {
    ULONG count = InterlockedDecrement(&m_refCount);
    if (count == 0) delete this;
    return count;
}

STDMETHODIMP CamSyncFilter::GetClassID(CLSID* pClassID) {
    if (!pClassID) return E_POINTER;
    *pClassID = CLSID_CamSyncVirtualCam;
    return S_OK;
}

STDMETHODIMP CamSyncFilter::Stop() {
    EnterCriticalSection(&m_cs);
    if (m_state != State_Stopped) {
        m_pPin->Inactive();
        m_state = State_Stopped;
    }
    LeaveCriticalSection(&m_cs);
    return S_OK;
}

STDMETHODIMP CamSyncFilter::Pause() {
    EnterCriticalSection(&m_cs);
    if (m_state == State_Stopped) {
        m_pPin->Active();
    }
    m_state = State_Paused;
    LeaveCriticalSection(&m_cs);
    return S_OK;
}

STDMETHODIMP CamSyncFilter::Run(REFERENCE_TIME tStart) {
    EnterCriticalSection(&m_cs);
    if (m_state == State_Stopped) {
        m_pPin->Active();
    }
    m_state = State_Running;
    LeaveCriticalSection(&m_cs);
    return S_OK;
}

STDMETHODIMP CamSyncFilter::GetState(DWORD dwMilliSecsTimeout, FILTER_STATE* State) {
    if (!State) return E_POINTER;
    EnterCriticalSection(&m_cs);
    *State = m_state;
    LeaveCriticalSection(&m_cs);
    return S_OK;
}

STDMETHODIMP CamSyncFilter::SetSyncSource(IReferenceClock* pClock) {
    EnterCriticalSection(&m_cs);
    if (m_pClock) m_pClock->Release();
    m_pClock = pClock;
    if (m_pClock) m_pClock->AddRef();
    LeaveCriticalSection(&m_cs);
    return S_OK;
}

STDMETHODIMP CamSyncFilter::GetSyncSource(IReferenceClock** ppClock) {
    if (!ppClock) return E_POINTER;
    EnterCriticalSection(&m_cs);
    *ppClock = m_pClock;
    if (m_pClock) m_pClock->AddRef();
    LeaveCriticalSection(&m_cs);
    return S_OK;
}

STDMETHODIMP CamSyncFilter::EnumPins(IEnumPins** ppEnum) {
    if (!ppEnum) return E_POINTER;
    *ppEnum = new CamSyncEnumPins(m_pPin);
    return S_OK;
}

STDMETHODIMP CamSyncFilter::FindPin(LPCWSTR Id, IPin** ppPin) {
    if (!ppPin) return E_POINTER;
    if (Id && wcscmp(Id, L"Capture") == 0) {
        *ppPin = m_pPin;
        m_pPin->AddRef();
        return S_OK;
    }
    *ppPin = nullptr;
    return VFW_E_NOT_FOUND;
}

STDMETHODIMP CamSyncFilter::QueryFilterInfo(FILTER_INFO* pInfo) {
    if (!pInfo) return E_POINTER;
    EnterCriticalSection(&m_cs);
    wcsncpy_s(pInfo->achName, m_filterName, 128);
    pInfo->pGraph = m_pGraph;
    if (m_pGraph) m_pGraph->AddRef();
    LeaveCriticalSection(&m_cs);
    return S_OK;
}

STDMETHODIMP CamSyncFilter::JoinFilterGraph(IFilterGraph* pGraph, LPCWSTR pName) {
    EnterCriticalSection(&m_cs);
    m_pGraph = pGraph;
    if (pName) {
        wcsncpy_s(m_filterName, pName, 128);
    } else {
        m_filterName[0] = L'\0';
    }
    LeaveCriticalSection(&m_cs);
    return S_OK;
}

STDMETHODIMP CamSyncFilter::QueryVendorInfo(LPWSTR* pVendorInfo) {
    if (!pVendorInfo) return E_POINTER;
    const wchar_t* vendor = L"CamSync Open Source Project";
    size_t len = (wcslen(vendor) + 1) * sizeof(wchar_t);
    *pVendorInfo = static_cast<LPWSTR>(CoTaskMemAlloc(len));
    if (!*pVendorInfo) return E_OUTOFMEMORY;
    memcpy(*pVendorInfo, vendor, len);
    return S_OK;
}

STDMETHODIMP_(ULONG) CamSyncFilter::GetMiscFlags() {
    return AM_FILTER_MISC_FLAGS_IS_SOURCE;
}
