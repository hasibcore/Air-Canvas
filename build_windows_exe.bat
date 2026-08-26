@echo off
echo ======================================================
echo    Building AirCanvas Native Windows Executable
echo ======================================================
C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /target:winexe /out:AirCanvas.exe /optimize+ /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.dll windows_server\AirCanvasServer.cs
if %ERRORLEVEL% EQU 0 (
    echo.
    echo [SUCCESS] AirCanvas.exe successfully created!
    echo Location: %~dp0AirCanvas.exe
) else (
    echo.
    echo [ERROR] Compilation failed.
)
pause
