@echo off
setlocal
echo ========================================================
echo       CamSync - Assembling Portable Windows Bundle
echo ========================================================

set ROOT=%~dp0..\..\..
set OUT_DIR=%ROOT%\dist\CamSync-Portable-v1.0.0

if exist "%OUT_DIR%" (
    echo Cleaning existing portable output...
    rmdir /s /q "%OUT_DIR%"
)

mkdir "%OUT_DIR%"
mkdir "%OUT_DIR%\tools"
mkdir "%OUT_DIR%\scripts"

echo 1. Copying Flutter Desktop App files...
xcopy /E /I /Y "%ROOT%\apps\desktop\build\windows\x64\runner\Release\*" "%OUT_DIR%\"

echo 2. Copying Native Driver and FFI Bridge DLLs...
copy /Y "%ROOT%\build\native\driver\Release\CamSyncVirtualCam.dll" "%OUT_DIR%\"
copy /Y "%ROOT%\build\native\Release\camsync_native.dll" "%OUT_DIR%\"

echo 3. Copying Diagnostic Tools...
copy /Y "%ROOT%\build\native\Release\camsync_feeder.exe" "%OUT_DIR%\tools\"
copy /Y "%ROOT%\build\native\Release\camsync_list_devices.exe" "%OUT_DIR%\tools\"

echo 4. Copying Registration Helper Scripts...
copy /Y "%ROOT%\packaging\windows\scripts\register_filter.bat" "%OUT_DIR%\scripts\"
copy /Y "%ROOT%\packaging\windows\scripts\unregister_filter.bat" "%OUT_DIR%\scripts\"

echo.
echo ========================================================
echo  [SUCCESS] Portable Bundle created at:
echo  %OUT_DIR%
echo ========================================================
endlocal
