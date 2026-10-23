#pragma once

#include <windows.h>
#include <dshow.h>
#include <vector>
#include "../shared/CamSyncSharedBuffer.h"

class CamSyncFilter;

struct FormatCapability {
    int width;
    int height;
    int fps;
    GUID subType;
    DWORD biCompression;
    WORD biBitCount;
};

class CamSyncOutputPin : public IPin, public IAMStreamConfig, public IKsPropertySet {
public:
    explicit CamSyncOutputPin(CamSyncFilter* pFilter);
    virtual ~CamSyncOutputPin();

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // IPin
    STDMETHODIMP Connect(IPin* pReceivePin, const AM_MEDIA_TYPE* pmt) override;
    STDMETHODIMP ReceiveConnection(IPin* pConnector, const AM_MEDIA_TYPE* pmt) override;
    STDMETHODIMP Disconnect() override;
    STDMETHODIMP ConnectedTo(IPin** pPin) override;
    STDMETHODIMP ConnectionMediaType(AM_MEDIA_TYPE* pmt) override;
    STDMETHODIMP QueryPinInfo(PIN_INFO* pInfo) override;
    STDMETHODIMP QueryDirection(PIN_DIRECTION* pPinDir) override;
    STDMETHODIMP QueryId(LPWSTR* Id) override;
    STDMETHODIMP QueryAccept(const AM_MEDIA_TYPE* pmt) override;
    STDMETHODIMP EnumMediaTypes(IEnumMediaTypes** ppEnum) override;
    STDMETHODIMP QueryInternalConnections(IPin** apPin, ULONG* nPin) override;
    STDMETHODIMP EndOfStream() override;
    STDMETHODIMP BeginFlush() override;
    STDMETHODIMP EndFlush() override;
    STDMETHODIMP NewSegment(REFERENCE_TIME tStart, REFERENCE_TIME tStop, double dRate) override;

    // IAMStreamConfig
    STDMETHODIMP SetFormat(AM_MEDIA_TYPE* pmt) override;
    STDMETHODIMP GetFormat(AM_MEDIA_TYPE** ppmt) override;
    STDMETHODIMP GetNumberOfCapabilities(int* piCount, int* piSize) override;
    STDMETHODIMP GetStreamCaps(int iIndex, AM_MEDIA_TYPE** ppmt, BYTE* pSCC) override;

    // IKsPropertySet
    STDMETHODIMP Set(REFGUID guidPropSet, DWORD dwPropID, LPVOID pInstanceData, DWORD cbInstanceData, LPVOID pPropData, DWORD cbPropData) override;
    STDMETHODIMP Get(REFGUID guidPropSet, DWORD dwPropID, LPVOID pInstanceData, DWORD cbInstanceData, LPVOID pPropData, DWORD cbPropData, DWORD* pcbReturned) override;
    STDMETHODIMP QuerySupported(REFGUID guidPropSet, DWORD dwPropID, DWORD* pTypeSupport) override;

    // Streaming Control called by Filter
    HRESULT Active();
    HRESULT Inactive();

    static void PopulateMediaType(const FormatCapability& cap, AM_MEDIA_TYPE* pmt);
    static const std::vector<FormatCapability>& GetCapabilities();

private:
    static DWORD WINAPI ThreadWorkerThunk(LPVOID lpParam);
    void ThreadWorker();

    void RenderPlaceholder(BYTE* pDest, int width, int height, DWORD biCompression, uint64_t frameCount);
    bool ConnectSharedMemory();
    void DisconnectSharedMemory();

    CamSyncFilter* m_pFilter;
    LONG m_refCount;
    IPin* m_pConnectedPin;
    IMemInputPin* m_pInputPin;
    IMemAllocator* m_pAllocator;

    AM_MEDIA_TYPE m_mediaType;
    bool m_bMediaTypeSet;

    HANDLE m_hThread;
    HANDLE m_hStopEvent;

    // Shared Memory IPC
    HANDLE m_hSharedMem;
    CamSyncSharedMemoryLayout* m_pSharedMem;
    HANDLE m_hFrameEvent;
    HANDLE m_hFrameMutex;
};
