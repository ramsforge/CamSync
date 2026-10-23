#pragma once

#include <windows.h>
#include <initguid.h>

// {9E40E35B-1B47-497B-8DC4-666E63A759C1}
DEFINE_GUID(CLSID_CamSyncVirtualCam, 
    0x9e40e35b, 0x1b47, 0x497b, 0x8d, 0xc4, 0x66, 0x6e, 0x63, 0xa7, 0x59, 0xc1);

#define CAMSYNC_FILTER_NAME L"CamSync Virtual Camera"
#define CAMSYNC_CLSID_STR L"{9E40E35B-1B47-497B-8DC4-666E63A759C1}"
