@echo off
echo ======================================================
echo    Building AirCanvas Native Windows Executable
echo ======================================================
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /win32manifest:app.manifest /win32icon:windows\runner\resources\app_icon.ico /out:AirCanvas.exe /optimize+ /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.dll windows_server\AirCanvasServer.cs
if %ERRORLEVEL% EQU 0 (
    copy /y AirCanvas.exe windows_server\AirCanvas.exe >nul
    echo.
    echo [SUCCESS] AirCanvas.exe successfully created with DPI PerMonitorV2 Manifest!
    echo Location: %~dp0AirCanvas.exe
) else (
    echo.
    echo [ERROR] Compilation failed.
)
pause
