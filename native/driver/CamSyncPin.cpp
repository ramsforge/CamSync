#include "CamSyncPin.h"
#include "CamSyncFilter.h"
#include <cstdio>
#include <cmath>

#ifndef MAKEFOURCC
#define MAKEFOURCC(ch0, ch1, ch2, ch3) \
    ((DWORD)(BYTE)(ch0) | ((DWORD)(BYTE)(ch1) << 8) | \
    ((DWORD)(BYTE)(ch2) << 16) | ((DWORD)(BYTE)(ch3) << 24))
#endif

#define FOURCC_NV12 MAKEFOURCC('N', 'V', '1', '2')
#define FOURCC_YUY2 MAKEFOURCC('Y', 'U', 'Y', '2')

// Supported capabilities table across major video capture standards
static const std::vector<FormatCapability>& StaticCapabilities() {
    static const std::vector<FormatCapability> caps = {
        // 1080p FHD
        { 1920, 1080, 30, MEDIASUBTYPE_RGB24, BI_RGB, 24 },
        { 1920, 1080, 30, MEDIASUBTYPE_YUY2,  FOURCC_YUY2, 16 },
        { 1920, 1080, 30, MEDIASUBTYPE_RGB32, BI_RGB, 32 },
        { 1920, 1080, 30, MEDIASUBTYPE_NV12,  FOURCC_NV12, 12 },
        { 1920, 1080, 60, MEDIASUBTYPE_RGB24, BI_RGB, 24 },
        { 1920, 1080, 60, MEDIASUBTYPE_YUY2,  FOURCC_YUY2, 16 },
        { 1920, 1080, 60, MEDIASUBTYPE_RGB32, BI_RGB, 32 },
        { 1920, 1080, 60, MEDIASUBTYPE_NV12,  FOURCC_NV12, 12 },

        // 720p HD (Discord & WebRTC preferred)
        { 1280, 720, 30, MEDIASUBTYPE_RGB24, BI_RGB, 24 },
        { 1280, 720, 30, MEDIASUBTYPE_YUY2,  FOURCC_YUY2, 16 },
        { 1280, 720, 30, MEDIASUBTYPE_RGB32, BI_RGB, 32 },
        { 1280, 720, 30, MEDIASUBTYPE_NV12,  FOURCC_NV12, 12 },
        { 1280, 720, 60, MEDIASUBTYPE_YUY2,  FOURCC_YUY2, 16 },
        { 1280, 720, 60, MEDIASUBTYPE_RGB24, BI_RGB, 24 },

        // 480p SD Fallback
        { 640, 480, 30, MEDIASUBTYPE_RGB24, BI_RGB, 24 },
        { 640, 480, 30, MEDIASUBTYPE_YUY2,  FOURCC_YUY2, 16 },
        { 640, 480, 30, MEDIASUBTYPE_RGB32, BI_RGB, 32 }
    };
    return caps;
}

const std::vector<FormatCapability>& CamSyncOutputPin::GetCapabilities() {
    return StaticCapabilities();
}

void CamSyncOutputPin::PopulateMediaType(const FormatCapability& cap, AM_MEDIA_TYPE* pmt) {
    ZeroMemory(pmt, sizeof(AM_MEDIA_TYPE));
    pmt->majortype = MEDIATYPE_Video;
    pmt->subtype = cap.subType;
    pmt->bFixedSizeSamples = TRUE;
    pmt->bTemporalCompression = FALSE;
    pmt->formattype = FORMAT_VideoInfo;

    DWORD imgSize = 0;
    if (cap.biBitCount == 32) {
        imgSize = cap.width * cap.height * 4;
    } else if (cap.biBitCount == 24) {
        imgSize = cap.width * cap.height * 3;
    } else if (cap.biBitCount == 16) {
        imgSize = cap.width * cap.height * 2;
    } else if (cap.biBitCount == 12) {
        imgSize = (cap.width * cap.height * 3) / 2;
    }

    pmt->lSampleSize = imgSize;
    pmt->cbFormat = sizeof(VIDEOINFOHEADER);
    pmt->pbFormat = static_cast<BYTE*>(CoTaskMemAlloc(sizeof(VIDEOINFOHEADER)));
    ZeroMemory(pmt->pbFormat, sizeof(VIDEOINFOHEADER));

    auto* pvi = reinterpret_cast<VIDEOINFOHEADER*>(pmt->pbFormat);
    pvi->rcSource = { 0, 0, cap.width, cap.height };
    pvi->rcTarget = { 0, 0, cap.width, cap.height };
    pvi->dwBitRate = static_cast<DWORD>(imgSize * 8ULL * cap.fps);
    pvi->dwBitErrorRate = 0;
    pvi->AvgTimePerFrame = 10000000LL / cap.fps;

    pvi->bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    pvi->bmiHeader.biWidth = cap.width;
    // For uncompressed RGB, negative height denotes top-down bitmap
    pvi->bmiHeader.biHeight = (cap.biCompression == BI_RGB) ? -cap.height : cap.height;
    pvi->bmiHeader.biPlanes = 1;
    pvi->bmiHeader.biBitCount = cap.biBitCount;
    pvi->bmiHeader.biCompression = cap.biCompression;
    pvi->bmiHeader.biSizeImage = imgSize;
}

// Media type enumerator
class CamSyncEnumMediaTypes : public IEnumMediaTypes {
public:
    explicit CamSyncEnumMediaTypes(ULONG startIndex = 0)
        : m_refCount(1), m_index(startIndex) {}

    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override {
        if (!ppv) return E_POINTER;
        if (riid == IID_IUnknown || riid == IID_IEnumMediaTypes) {
            *ppv = static_cast<IEnumMediaTypes*>(this);
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

    STDMETHODIMP Next(ULONG cMediaTypes, AM_MEDIA_TYPE** ppMediaTypes, ULONG* pcFetched) override {
        if (!ppMediaTypes) return E_POINTER;
        const auto& caps = StaticCapabilities();
        ULONG fetched = 0;

        while (m_index < caps.size() && fetched < cMediaTypes) {
            ppMediaTypes[fetched] = static_cast<AM_MEDIA_TYPE*>(CoTaskMemAlloc(sizeof(AM_MEDIA_TYPE)));
            CamSyncOutputPin::PopulateMediaType(caps[m_index], ppMediaTypes[fetched]);
            m_index++;
            fetched++;
        }

        if (pcFetched) *pcFetched = fetched;
        return (fetched == cMediaTypes) ? S_OK : S_FALSE;
    }

    STDMETHODIMP Skip(ULONG cMediaTypes) override {
        m_index += cMediaTypes;
        return (m_index <= StaticCapabilities().size()) ? S_OK : S_FALSE;
    }

    STDMETHODIMP Reset() override {
        m_index = 0;
        return S_OK;
    }

    STDMETHODIMP Clone(IEnumMediaTypes** ppEnum) override {
        if (!ppEnum) return E_POINTER;
        *ppEnum = new CamSyncEnumMediaTypes(m_index);
        return S_OK;
    }

private:
    LONG m_refCount;
    ULONG m_index;
};

// --- CamSyncOutputPin Implementation ---

CamSyncOutputPin::CamSyncOutputPin(CamSyncFilter* pFilter)
    : m_pFilter(pFilter),
      m_refCount(1),
      m_pConnectedPin(nullptr),
      m_pInputPin(nullptr),
      m_pAllocator(nullptr),
      m_bMediaTypeSet(false),
      m_hThread(nullptr),
      m_hStopEvent(nullptr),
      m_hSharedMem(nullptr),
      m_pSharedMem(nullptr),
      m_hFrameEvent(nullptr),
      m_hFrameMutex(nullptr) {
    ZeroMemory(&m_mediaType, sizeof(AM_MEDIA_TYPE));
    PopulateMediaType(StaticCapabilities()[0], &m_mediaType);
    m_bMediaTypeSet = true;
    m_hStopEvent = CreateEvent(nullptr, TRUE, FALSE, nullptr);
}

CamSyncOutputPin::~CamSyncOutputPin() {
    Inactive();
    if (m_hStopEvent) {
        CloseHandle(m_hStopEvent);
        m_hStopEvent = nullptr;
    }
    if (m_mediaType.pbFormat) {
        CoTaskMemFree(m_mediaType.pbFormat);
        m_mediaType.pbFormat = nullptr;
    }
    Disconnect();
}

STDMETHODIMP CamSyncOutputPin::QueryInterface(REFIID riid, void** ppv) {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IPin) {
        *ppv = static_cast<IPin*>(this);
    } else if (riid == IID_IAMStreamConfig) {
        *ppv = static_cast<IAMStreamConfig*>(this);
    } else if (riid == IID_IKsPropertySet) {
        *ppv = static_cast<IKsPropertySet*>(this);
    } else {
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) CamSyncOutputPin::AddRef() {
    return InterlockedIncrement(&m_refCount);
}

STDMETHODIMP_(ULONG) CamSyncOutputPin::Release() {
    ULONG count = InterlockedDecrement(&m_refCount);
    if (count == 0) delete this;
    return count;
}

STDMETHODIMP CamSyncOutputPin::Connect(IPin* pReceivePin, const AM_MEDIA_TYPE* pmt) {
    if (!pReceivePin) return E_POINTER;
    if (m_pConnectedPin) return VFW_E_ALREADY_CONNECTED;

    HRESULT hr = VFW_E_NO_ACCEPTABLE_TYPES;
    AM_MEDIA_TYPE mt;
    ZeroMemory(&mt, sizeof(AM_MEDIA_TYPE));

    if (pmt) {
        if (QueryAccept(pmt) != S_OK) return VFW_E_TYPE_NOT_ACCEPTED;
        mt = *pmt;
        if (pmt->cbFormat > 0) {
            mt.pbFormat = static_cast<BYTE*>(CoTaskMemAlloc(pmt->cbFormat));
            memcpy(mt.pbFormat, pmt->pbFormat, pmt->cbFormat);
        }
        hr = pReceivePin->ReceiveConnection(this, &mt);
    } else {
        // Multi-format negotiation: try all supported formats until downstream filter accepts
        const auto& caps = StaticCapabilities();
        for (const auto& cap : caps) {
            PopulateMediaType(cap, &mt);
            hr = pReceivePin->ReceiveConnection(this, &mt);
            if (SUCCEEDED(hr)) {
                break;
            }
            if (mt.pbFormat) {
                CoTaskMemFree(mt.pbFormat);
                mt.pbFormat = nullptr;
            }
        }
    }

    if (FAILED(hr)) {
        if (mt.pbFormat) CoTaskMemFree(mt.pbFormat);
        return hr;
    }

    m_pConnectedPin = pReceivePin;
    m_pConnectedPin->AddRef();

    hr = m_pConnectedPin->QueryInterface(IID_IMemInputPin, reinterpret_cast<void**>(&m_pInputPin));
    if (FAILED(hr)) {
        Disconnect();
        if (mt.pbFormat) CoTaskMemFree(mt.pbFormat);
        return hr;
    }

    hr = m_pInputPin->GetAllocator(&m_pAllocator);
    if (FAILED(hr) || !m_pAllocator) {
        hr = CoCreateInstance(CLSID_MemoryAllocator, nullptr, CLSCTX_INPROC_SERVER,
                              IID_IMemAllocator, reinterpret_cast<void**>(&m_pAllocator));
    }

    ALLOCATOR_PROPERTIES propReq = {}, propAct = {};
    propReq.cBuffers = 2;
    propReq.cbBuffer = mt.lSampleSize;
    propReq.cbAlign = 1;
    propReq.cbPrefix = 0;

    m_pAllocator->SetProperties(&propReq, &propAct);
    m_pInputPin->NotifyAllocator(m_pAllocator, FALSE);

    if (m_mediaType.pbFormat) CoTaskMemFree(m_mediaType.pbFormat);
    m_mediaType = mt;
    m_bMediaTypeSet = true;

    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::ReceiveConnection(IPin* pConnector, const AM_MEDIA_TYPE* pmt) {
    return E_UNEXPECTED;
}

STDMETHODIMP CamSyncOutputPin::Disconnect() {
    Inactive();
    if (m_pAllocator) {
        m_pAllocator->Decommit();
        m_pAllocator->Release();
        m_pAllocator = nullptr;
    }
    if (m_pInputPin) {
        m_pInputPin->Release();
        m_pInputPin = nullptr;
    }
    if (m_pConnectedPin) {
        m_pConnectedPin->Release();
        m_pConnectedPin = nullptr;
    }
    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::ConnectedTo(IPin** ppPin) {
    if (!ppPin) return E_POINTER;
    if (!m_pConnectedPin) return VFW_E_NOT_CONNECTED;
    *ppPin = m_pConnectedPin;
    m_pConnectedPin->AddRef();
    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::ConnectionMediaType(AM_MEDIA_TYPE* pmt) {
    if (!pmt) return E_POINTER;
    if (!m_pConnectedPin) return VFW_E_NOT_CONNECTED;
    *pmt = m_mediaType;
    if (m_mediaType.cbFormat > 0) {
        pmt->pbFormat = static_cast<BYTE*>(CoTaskMemAlloc(m_mediaType.cbFormat));
        memcpy(pmt->pbFormat, m_mediaType.pbFormat, m_mediaType.cbFormat);
    }
    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::QueryPinInfo(PIN_INFO* pInfo) {
    if (!pInfo) return E_POINTER;
    pInfo->pFilter = m_pFilter;
    if (m_pFilter) m_pFilter->AddRef();
    pInfo->dir = PINDIR_OUTPUT;
    wcscpy_s(pInfo->achName, L"Capture");
    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::QueryDirection(PIN_DIRECTION* pPinDir) {
    if (!pPinDir) return E_POINTER;
    *pPinDir = PINDIR_OUTPUT;
    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::QueryId(LPWSTR* Id) {
    if (!Id) return E_POINTER;
    const wchar_t* pinId = L"Capture";
    size_t len = (wcslen(pinId) + 1) * sizeof(wchar_t);
    *Id = static_cast<LPWSTR>(CoTaskMemAlloc(len));
    if (!*Id) return E_OUTOFMEMORY;
    memcpy(*Id, pinId, len);
    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::QueryAccept(const AM_MEDIA_TYPE* pmt) {
    if (!pmt) return E_POINTER;
    if (pmt->majortype != MEDIATYPE_Video) return S_FALSE;
    for (const auto& cap : StaticCapabilities()) {
        if (pmt->subtype == cap.subType) return S_OK;
    }
    return S_FALSE;
}

STDMETHODIMP CamSyncOutputPin::EnumMediaTypes(IEnumMediaTypes** ppEnum) {
    if (!ppEnum) return E_POINTER;
    *ppEnum = new CamSyncEnumMediaTypes(0);
    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::QueryInternalConnections(IPin** apPin, ULONG* nPin) {
    return E_NOTIMPL;
}

STDMETHODIMP CamSyncOutputPin::EndOfStream() { return S_OK; }
STDMETHODIMP CamSyncOutputPin::BeginFlush() { return S_OK; }
STDMETHODIMP CamSyncOutputPin::EndFlush() { return S_OK; }

STDMETHODIMP CamSyncOutputPin::NewSegment(REFERENCE_TIME tStart, REFERENCE_TIME tStop, double dRate) {
    return S_OK;
}

// IAMStreamConfig
STDMETHODIMP CamSyncOutputPin::SetFormat(AM_MEDIA_TYPE* pmt) {
    if (!pmt) return E_POINTER;
    if (QueryAccept(pmt) != S_OK) return VFW_E_TYPE_NOT_ACCEPTED;

    if (m_mediaType.pbFormat) CoTaskMemFree(m_mediaType.pbFormat);
    m_mediaType = *pmt;
    if (pmt->cbFormat > 0) {
        m_mediaType.pbFormat = static_cast<BYTE*>(CoTaskMemAlloc(pmt->cbFormat));
        memcpy(m_mediaType.pbFormat, pmt->pbFormat, pmt->cbFormat);
    }
    m_bMediaTypeSet = true;
    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::GetFormat(AM_MEDIA_TYPE** ppmt) {
    if (!ppmt) return E_POINTER;
    *ppmt = static_cast<AM_MEDIA_TYPE*>(CoTaskMemAlloc(sizeof(AM_MEDIA_TYPE)));
    **ppmt = m_mediaType;
    if (m_mediaType.cbFormat > 0) {
        (*ppmt)->pbFormat = static_cast<BYTE*>(CoTaskMemAlloc(m_mediaType.cbFormat));
        memcpy((*ppmt)->pbFormat, m_mediaType.pbFormat, m_mediaType.cbFormat);
    }
    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::GetNumberOfCapabilities(int* piCount, int* piSize) {
    if (!piCount || !piSize) return E_POINTER;
    *piCount = static_cast<int>(StaticCapabilities().size());
    *piSize = sizeof(VIDEO_STREAM_CONFIG_CAPS);
    return S_OK;
}

STDMETHODIMP CamSyncOutputPin::GetStreamCaps(int iIndex, AM_MEDIA_TYPE** ppmt, BYTE* pSCC) {
    if (!ppmt || !pSCC) return E_POINTER;
    const auto& caps = StaticCapabilities();
    if (iIndex < 0 || iIndex >= static_cast<int>(caps.size())) return E_INVALIDARG;

    const auto& cap = caps[iIndex];
    *ppmt = static_cast<AM_MEDIA_TYPE*>(CoTaskMemAlloc(sizeof(AM_MEDIA_TYPE)));
    PopulateMediaType(cap, *ppmt);

    auto* vscc = reinterpret_cast<VIDEO_STREAM_CONFIG_CAPS*>(pSCC);
    ZeroMemory(vscc, sizeof(VIDEO_STREAM_CONFIG_CAPS));
    vscc->guid = FORMAT_VideoInfo;
    vscc->VideoStandard = 0;
    vscc->InputSize = { cap.width, cap.height };
    vscc->MinCroppingSize = { cap.width, cap.height };
    vscc->MaxCroppingSize = { cap.width, cap.height };
    vscc->CropGranularityX = 1;
    vscc->CropGranularityY = 1;
    vscc->CropAlignX = 1;
    vscc->CropAlignY = 1;
    vscc->MinOutputSize = { cap.width, cap.height };
    vscc->MaxOutputSize = { cap.width, cap.height };
    vscc->OutputGranularityX = 1;
    vscc->OutputGranularityY = 1;
    vscc->StretchTapsX = 0;
    vscc->StretchTapsY = 0;
    vscc->ShrinkTapsX = 0;
    vscc->ShrinkTapsY = 0;
    vscc->MinFrameInterval = 10000000LL / cap.fps;
    vscc->MaxFrameInterval = 10000000LL;
    vscc->MinBitsPerSecond = static_cast<LONG>((*ppmt)->lSampleSize * 8ULL * 1);
    vscc->MaxBitsPerSecond = static_cast<LONG>((*ppmt)->lSampleSize * 8ULL * cap.fps);

    return S_OK;
}

// IKsPropertySet
STDMETHODIMP CamSyncOutputPin::Set(REFGUID guidPropSet, DWORD dwPropID, LPVOID pInstanceData, DWORD cbInstanceData, LPVOID pPropData, DWORD cbPropData) {
    return E_NOTIMPL;
}

STDMETHODIMP CamSyncOutputPin::Get(REFGUID guidPropSet, DWORD dwPropID, LPVOID pInstanceData, DWORD cbInstanceData, LPVOID pPropData, DWORD cbPropData, DWORD* pcbReturned) {
    if (guidPropSet == AMPROPSETID_Pin && dwPropID == AMPROPERTY_PIN_CATEGORY) {
        if (!pPropData || cbPropData < sizeof(GUID)) return E_POINTER;
        *reinterpret_cast<GUID*>(pPropData) = PIN_CATEGORY_CAPTURE;
        if (pcbReturned) *pcbReturned = sizeof(GUID);
        return S_OK;
    }
    return E_PROP_SET_UNSUPPORTED;
}

STDMETHODIMP CamSyncOutputPin::QuerySupported(REFGUID guidPropSet, DWORD dwPropID, DWORD* pTypeSupport) {
    if (guidPropSet == AMPROPSETID_Pin && dwPropID == AMPROPERTY_PIN_CATEGORY) {
        if (pTypeSupport) *pTypeSupport = KSPROPERTY_SUPPORT_GET;
        return S_OK;
    }
    return E_PROP_SET_UNSUPPORTED;
}

// --- Streaming & Worker Thread ---

HRESULT CamSyncOutputPin::Active() {
    if (m_hThread) return S_OK;
    ResetEvent(m_hStopEvent);
    ConnectSharedMemory();

    if (m_pAllocator) m_pAllocator->Commit();

    m_hThread = CreateThread(nullptr, 0, ThreadWorkerThunk, this, 0, nullptr);
    return m_hThread ? S_OK : E_FAIL;
}

HRESULT CamSyncOutputPin::Inactive() {
    if (!m_hThread) return S_OK;
    SetEvent(m_hStopEvent);
    WaitForSingleObject(m_hThread, 2000);
    CloseHandle(m_hThread);
    m_hThread = nullptr;

    if (m_pAllocator) m_pAllocator->Decommit();
    DisconnectSharedMemory();
    return S_OK;
}

DWORD WINAPI CamSyncOutputPin::ThreadWorkerThunk(LPVOID lpParam) {
    static_cast<CamSyncOutputPin*>(lpParam)->ThreadWorker();
    return 0;
}

bool CamSyncOutputPin::ConnectSharedMemory() {
    if (m_pSharedMem) return true;

    m_hSharedMem = CamSyncOpenFileMapping(FILE_MAP_READ);
    if (m_hSharedMem) {
        m_pSharedMem = reinterpret_cast<CamSyncSharedMemoryLayout*>(
            MapViewOfFile(m_hSharedMem, FILE_MAP_READ, 0, 0, sizeof(CamSyncSharedMemoryLayout)));
    }

    m_hFrameEvent = CamSyncOpenEvent(SYNCHRONIZE);
    m_hFrameMutex = CamSyncOpenMutex(SYNCHRONIZE);
    return m_pSharedMem != nullptr;
}

void CamSyncOutputPin::DisconnectSharedMemory() {
    if (m_pSharedMem) {
        UnmapViewOfFile(m_pSharedMem);
        m_pSharedMem = nullptr;
    }
    if (m_hSharedMem) {
        CloseHandle(m_hSharedMem);
        m_hSharedMem = nullptr;
    }
    if (m_hFrameEvent) {
        CloseHandle(m_hFrameEvent);
        m_hFrameEvent = nullptr;
    }
    if (m_hFrameMutex) {
        CloseHandle(m_hFrameMutex);
        m_hFrameMutex = nullptr;
    }
}

void CamSyncOutputPin::RenderPlaceholder(BYTE* pDest, int width, int height, DWORD biCompression, uint64_t frameCount) {
    if (biCompression == BI_RGB) {
        auto* pixels = reinterpret_cast<DWORD*>(pDest);
        float pulse = (std::sin(frameCount * 0.05f) + 1.0f) * 0.5f;
        BYTE indicatorBlue = static_cast<BYTE>(120 + pulse * 135);

        for (int y = 0; y < height; ++y) {
            BYTE bg = static_cast<BYTE>(20 + (y * 25) / height);
            DWORD rowColor = (bg << 16) | (bg << 8) | (bg + 4);
            for (int x = 0; x < width; ++x) {
                int dx = x - (width / 2);
                int dy = y - (height / 2);
                if (dx * dx + dy * dy < 1600) {
                    pixels[y * width + x] = (indicatorBlue << 8) | indicatorBlue | 0x00FF0000;
                } else {
                    pixels[y * width + x] = rowColor;
                }
            }
        }
    } else if (biCompression == FOURCC_NV12) {
        int ySize = width * height;
        memset(pDest, 0x20, ySize);
        memset(pDest + ySize, 0x80, ySize / 2);
    } else if (biCompression == FOURCC_YUY2) {
        int count = width * height;
        for (int i = 0; i < count; i += 2) {
            pDest[i * 2 + 0] = 0x20; // Y0
            pDest[i * 2 + 1] = 0x80; // U
            pDest[i * 2 + 2] = 0x20; // Y1
            pDest[i * 2 + 3] = 0x80; // V
        }
    }
}

static void ConvertAndScaleFrame(
    const uint8_t* pSrcRgb32, int srcW, int srcH,
    uint8_t* pDst, int dstW, int dstH,
    DWORD biCompression, WORD biBitCount
) {
    if (biCompression == BI_RGB && biBitCount == 32) {
        if (srcW == dstW && srcH == dstH) {
            memcpy(pDst, pSrcRgb32, dstW * dstH * 4);
        } else {
            const uint32_t* pSrc32 = reinterpret_cast<const uint32_t*>(pSrcRgb32);
            uint32_t* pDst32 = reinterpret_cast<uint32_t*>(pDst);
            for (int y = 0; y < dstH; ++y) {
                int sy = (y * srcH) / dstH;
                const uint32_t* pSrcRow = pSrc32 + sy * srcW;
                uint32_t* pDstRow = pDst32 + y * dstW;
                for (int x = 0; x < dstW; ++x) {
                    pDstRow[x] = pSrcRow[(x * srcW) / dstW];
                }
            }
        }
    } else if (biCompression == BI_RGB && biBitCount == 24) {
        const uint8_t* pSrc = pSrcRgb32;
        uint8_t* pDst24 = pDst;
        for (int y = 0; y < dstH; ++y) {
            int sy = (y * srcH) / dstH;
            const uint8_t* pSrcRow = pSrc + sy * srcW * 4;
            uint8_t* pDstRow = pDst24 + y * dstW * 3;
            for (int x = 0; x < dstW; ++x) {
                int sx = (x * srcW) / dstW;
                int srcIdx = sx * 4;
                int dstIdx = x * 3;
                pDstRow[dstIdx + 0] = pSrcRow[srcIdx + 0]; // B
                pDstRow[dstIdx + 1] = pSrcRow[srcIdx + 1]; // G
                pDstRow[dstIdx + 2] = pSrcRow[srcIdx + 2]; // R
            }
        }
    } else if (biCompression == FOURCC_YUY2) {
        const uint8_t* pSrc = pSrcRgb32;
        uint8_t* pDstYuy2 = pDst;
        for (int y = 0; y < dstH; ++y) {
            int sy = (y * srcH) / dstH;
            const uint8_t* pSrcRow = pSrc + sy * srcW * 4;
            uint8_t* pDstRow = pDstYuy2 + y * dstW * 2;
            for (int x = 0; x < dstW; x += 2) {
                int sx0 = (x * srcW) / dstW;
                int sx1 = ((x + 1) * srcW) / dstW;

                int b0 = pSrcRow[sx0 * 4 + 0], g0 = pSrcRow[sx0 * 4 + 1], r0 = pSrcRow[sx0 * 4 + 2];
                int b1 = pSrcRow[sx1 * 4 + 0], g1 = pSrcRow[sx1 * 4 + 1], r1 = pSrcRow[sx1 * 4 + 2];

                int y0 = ((66 * r0 + 129 * g0 + 25 * b0 + 128) >> 8) + 16;
                int y1 = ((66 * r1 + 129 * g1 + 25 * b1 + 128) >> 8) + 16;
                int ravg = (r0 + r1) / 2, gavg = (g0 + g1) / 2, bavg = (b0 + b1) / 2;
                int u = ((-38 * ravg - 74 * gavg + 112 * bavg + 128) >> 8) + 128;
                int v = ((112 * ravg - 94 * gavg - 18 * bavg + 128) >> 8) + 128;

                pDstRow[x * 2 + 0] = static_cast<uint8_t>(y0 < 0 ? 0 : (y0 > 255 ? 255 : y0));
                pDstRow[x * 2 + 1] = static_cast<uint8_t>(u < 0 ? 0 : (u > 255 ? 255 : u));
                pDstRow[x * 2 + 2] = static_cast<uint8_t>(y1 < 0 ? 0 : (y1 > 255 ? 255 : y1));
                pDstRow[x * 2 + 3] = static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
            }
        }
    } else if (biCompression == FOURCC_NV12) {
        uint8_t* pDstY = pDst;
        uint8_t* pDstUV = pDst + dstW * dstH;
        for (int y = 0; y < dstH; ++y) {
            int sy = (y * srcH) / dstH;
            const uint8_t* pSrcRow = pSrcRgb32 + sy * srcW * 4;
            uint8_t* pDstYRow = pDstY + y * dstW;
            uint8_t* pDstUVRow = pDstUV + (y / 2) * dstW;
            for (int x = 0; x < dstW; ++x) {
                int sx = (x * srcW) / dstW;
                int b = pSrcRow[sx * 4 + 0], g = pSrcRow[sx * 4 + 1], r = pSrcRow[sx * 4 + 2];
                int Y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
                pDstYRow[x] = static_cast<uint8_t>(Y < 0 ? 0 : (Y > 255 ? 255 : Y));
                if ((y % 2 == 0) && (x % 2 == 0)) {
                    int U = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
                    int V = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
                    pDstUVRow[x + 0] = static_cast<uint8_t>(U < 0 ? 0 : (U > 255 ? 255 : U));
                    pDstUVRow[x + 1] = static_cast<uint8_t>(V < 0 ? 0 : (V > 255 ? 255 : V));
                }
            }
        }
    }
}

void CamSyncOutputPin::ThreadWorker() {
    auto* pvi = reinterpret_cast<VIDEOINFOHEADER*>(m_mediaType.pbFormat);
    int width = pvi ? pvi->bmiHeader.biWidth : 1920;
    int height = pvi ? std::abs(pvi->bmiHeader.biHeight) : 1080;
    DWORD biCompression = pvi ? pvi->bmiHeader.biCompression : BI_RGB;
    WORD biBitCount = pvi ? pvi->bmiHeader.biBitCount : 32;
    REFERENCE_TIME avgTime = pvi && pvi->AvgTimePerFrame > 0 ? pvi->AvgTimePerFrame : 333333; // Default 30 FPS

    DWORD timeoutMs = static_cast<DWORD>(avgTime / 10000);
    if (timeoutMs < 5) timeoutMs = 16;

    REFERENCE_TIME streamTime = 0;
    uint64_t frameCount = 0;

    while (WaitForSingleObject(m_hStopEvent, 0) != WAIT_OBJECT_0) {
        if (!m_pAllocator || !m_pInputPin) break;

        if (!m_pSharedMem) {
            ConnectSharedMemory();
        }

        IMediaSample* pSample = nullptr;
        HRESULT hr = m_pAllocator->GetBuffer(&pSample, nullptr, nullptr, 0);
        if (FAILED(hr) || !pSample) {
            Sleep(5);
            continue;
        }

        BYTE* pBuffer = nullptr;
        hr = pSample->GetPointer(&pBuffer);
        long maxLen = pSample->GetSize();

        bool frameCopied = false;

        if (m_pSharedMem && m_hFrameEvent && m_hFrameMutex) {
            DWORD waitRes = WaitForSingleObject(m_hFrameEvent, timeoutMs);
            if (waitRes == WAIT_OBJECT_0) {
                if (WaitForSingleObject(m_hFrameMutex, 10) == WAIT_OBJECT_0) {
                    if (m_pSharedMem->header.magic == CAMSYNC_MAGIC &&
                        m_pSharedMem->header.isStreaming) {
                        
                        const uint8_t* pSrc = (m_pSharedMem->header.activeBufferIndex == 0)
                            ? m_pSharedMem->buffer0
                            : m_pSharedMem->buffer1;

                        int srcW = m_pSharedMem->header.width;
                        int srcH = m_pSharedMem->header.height;

                        ConvertAndScaleFrame(pSrc, srcW, srcH, pBuffer, width, height, biCompression, biBitCount);

                        DWORD expectedSize = m_mediaType.lSampleSize;
                        if (expectedSize > static_cast<DWORD>(maxLen)) expectedSize = maxLen;
                        pSample->SetActualDataLength(expectedSize);
                        frameCopied = true;
                    }
                    ReleaseMutex(m_hFrameMutex);
                }
            }
        }

        if (!frameCopied) {
            RenderPlaceholder(pBuffer, width, height, biCompression, frameCount);
            pSample->SetActualDataLength(m_mediaType.lSampleSize);
        }

        REFERENCE_TIME startTime = streamTime;
        REFERENCE_TIME stopTime = startTime + avgTime;
        pSample->SetTime(&startTime, &stopTime);
        pSample->SetSyncPoint(TRUE);

        m_pInputPin->Receive(pSample);
        pSample->Release();

        streamTime += avgTime;
        frameCount++;

        if (!frameCopied) {
            Sleep(timeoutMs);
        }
    }
}
