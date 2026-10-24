@echo off
setlocal EnableDelayedExpansion
title CamSync Virtual Camera - Unregistration

:: Check for Administrator Privileges
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo [ELEVATION REQUIRED] Requesting Administrator rights...
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

@cd /d "%~dp0"
echo ========================================================
echo       CamSync Virtual Camera - System Unregistration
echo ========================================================
echo.

set DIR=%~dp0
set DLL64=%DIR%..\CamSyncVirtualCam64.dll
if not exist "%DLL64%" set DLL64=%DIR%..\CamSyncVirtualCam.dll
if not exist "%DLL64%" set DLL64=%DIR%CamSyncVirtualCam64.dll

set DLL32=%DIR%..\CamSyncVirtualCam32.dll
if not exist "%DLL32%" set DLL32=%DIR%CamSyncVirtualCam32.dll

if exist "%DLL64%" (
    "%SystemRoot%\System32\regsvr32.exe" /u /s "%DLL64%"
    echo   [OK] 64-bit unregistered.
)

if exist "%DLL32%" (
    if exist "%SystemRoot%\SysWOW64\regsvr32.exe" (
        "%SystemRoot%\SysWOW64\regsvr32.exe" /u /s "%DLL32%"
        echo   [OK] 32-bit unregistered.
    )
)

echo.
echo ========================================================
echo  [SUCCESS] CamSync Virtual Camera unregistered.
echo ========================================================
pause
