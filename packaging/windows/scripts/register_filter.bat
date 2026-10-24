@echo off
setlocal EnableDelayedExpansion
title CamSync Virtual Camera - Registration

:: 1. Check for Administrator Privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo ========================================================
    echo  [ELEVATION REQUIRED] Requesting Administrator rights...
    echo ========================================================
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

@cd /d "%~dp0"
echo ========================================================
echo        CamSync Virtual Camera - System Registration
echo ========================================================
echo.

set DIR=%~dp0
set DLL64=%DIR%..\CamSyncVirtualCam64.dll
if not exist "%DLL64%" set DLL64=%DIR%..\CamSyncVirtualCam.dll
if not exist "%DLL64%" set DLL64=%DIR%CamSyncVirtualCam64.dll
if not exist "%DLL64%" set DLL64=%DIR%..\..\..\dist\CamSync-Portable-v1.0.0\CamSyncVirtualCam64.dll

set DLL32=%DIR%..\CamSyncVirtualCam32.dll
if not exist "%DLL32%" set DLL32=%DIR%CamSyncVirtualCam32.dll
if not exist "%DLL32%" set DLL32=%DIR%..\..\..\dist\CamSync-Portable-v1.0.0\CamSyncVirtualCam32.dll

echo [1/2] Registering 64-bit Virtual Camera Filter...
if exist "%DLL64%" (
    "%SystemRoot%\System32\regsvr32.exe" /s "%DLL64%"
    echo   [OK] 64-bit registered: %DLL64%
) else (
    echo   [ERROR] 64-bit DLL not found!
)

echo.
echo [2/2] Registering 32-bit Virtual Camera Filter (for 32-bit apps/browsers)...
if exist "%DLL32%" (
    if exist "%SystemRoot%\SysWOW64\regsvr32.exe" (
        "%SystemRoot%\SysWOW64\regsvr32.exe" /s "%DLL32%"
        echo   [OK] 32-bit registered: %DLL32%
    ) else (
        echo   [SKIP] 32-bit subsystem not present.
    )
) else (
    echo   [WARN] 32-bit DLL not found: %DLL32%
)

echo.
echo ========================================================
echo  [SUCCESS] CamSync Virtual Camera registered system-wide!
echo.
echo  Please RESTART your target application:
echo    - OBS Studio (under Sources -> Video Capture Device)
echo    - Discord (under Settings -> Voice & Video -> Camera)
echo    - Zoom (under Settings -> Video -> Camera)
echo    - Chrome / Edge / Firefox
echo ========================================================
echo.
pause
