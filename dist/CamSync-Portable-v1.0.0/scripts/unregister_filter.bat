@echo off
setlocal
echo ========================================================
echo       CamSync Virtual Camera - Filter Unregistration
echo ========================================================

set DLL_PATH=%~dp0..\..\..\build\native\driver\Release\CamSyncVirtualCam.dll
if not exist "%DLL_PATH%" (
    set DLL_PATH=%~dp0CamSyncVirtualCam.dll
)

if not exist "%DLL_PATH%" (
    echo [ERROR] Could not find CamSyncVirtualCam.dll!
    pause
    exit /b 1
)

echo Unregistering: %DLL_PATH%
regsvr32.exe /u /s "%DLL_PATH%"

if %ERRORLEVEL% EQU 0 (
    echo [SUCCESS] CamSync Virtual Camera unregistered successfully.
) else (
    echo [ERROR] Unregistration failed with code %ERRORLEVEL%.
)
endlocal
