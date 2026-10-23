#pragma once

#include <windows.h>
#include <dshow.h>
#include <vector>
#include "CamSyncGuids.h"
#include "../shared/CamSyncSharedBuffer.h"

class CamSyncOutputPin;

class CamSyncFilter : public IBaseFilter, public IAMFilterMiscFlags {
public:
    CamSyncFilter();
    virtual ~CamSyncFilter();

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** ppv) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // IPersist
    STDMETHODIMP GetClassID(CLSID* pClassID) override;

    // IMediaFilter
    STDMETHODIMP Stop() override;
    STDMETHODIMP Pause() override;
    STDMETHODIMP Run(REFERENCE_TIME tStart) override;
    STDMETHODIMP GetState(DWORD dwMilliSecsTimeout, FILTER_STATE* State) override;
    STDMETHODIMP SetSyncSource(IReferenceClock* pClock) override;
    STDMETHODIMP GetSyncSource(IReferenceClock** ppClock) override;

    // IBaseFilter
    STDMETHODIMP EnumPins(IEnumPins** ppEnum) override;
    STDMETHODIMP FindPin(LPCWSTR Id, IPin** ppPin) override;
    STDMETHODIMP QueryFilterInfo(FILTER_INFO* pInfo) override;
    STDMETHODIMP JoinFilterGraph(IFilterGraph* pGraph, LPCWSTR pName) override;
    STDMETHODIMP QueryVendorInfo(LPWSTR* pVendorInfo) override;

    // IAMFilterMiscFlags
    STDMETHODIMP_(ULONG) GetMiscFlags() override;

    // Internal helpers
    CRITICAL_SECTION& GetLock() { return m_cs; }
    IFilterGraph* GetGraph() const { return m_pGraph; }
    IReferenceClock* GetClock() const { return m_pClock; }
    FILTER_STATE GetCurrentState() const { return m_state; }

private:
    LONG m_refCount;
    CRITICAL_SECTION m_cs;
    FILTER_STATE m_state;
    IFilterGraph* m_pGraph;
    IReferenceClock* m_pClock;
    WCHAR m_filterName[128];
    CamSyncOutputPin* m_pPin;
};
