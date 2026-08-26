@echo off
:: BatchGotAdmin
:-------------------------------------
REM --> Check for permissions
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"

REM --> If error flag set, we do not have admin.
if '%errorlevel%' NEQ '0' (
    echo [AirCanvas] Requesting Administrator Privileges...
    goto UACPrompt
) else ( goto gotAdmin )

:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    set params = %*:"=""
    echo UAC.ShellExecute "cmd.exe", "/c ""%~s0"" %params%", "", "runas", 1 >> "%temp%\getadmin.vbs"

    "%temp%\getadmin.vbs"
    del "%temp%\getadmin.vbs"
    exit /B

:gotAdmin
    pushd "%CD%"
    CD /D "%~dp0"
:--------------------------------------

echo ====================================================================
echo      AirCanvas — Windows Firewall Inbound Rules Setup
echo ====================================================================
echo.
echo Allowing AirCanvas TCP Port 9090 (WebSocket) and UDP Port 9091 (Discovery)...
echo.

netsh advfirewall firewall delete rule name="AirCanvas TCP 9090" >nul 2>&1
netsh advfirewall firewall delete rule name="AirCanvas UDP 9091" >nul 2>&1
netsh advfirewall firewall delete rule name="AirCanvas Server App" >nul 2>&1

netsh advfirewall firewall add rule name="AirCanvas TCP 9090" dir=in action=allow protocol=TCP localport=9090 profile=any
netsh advfirewall firewall add rule name="AirCanvas UDP 9091" dir=in action=allow protocol=UDP localport=9091 profile=any

if exist "%~dp0AirCanvas.exe" (
    netsh advfirewall firewall add rule name="AirCanvas Server App" dir=in action=allow program="%~dp0AirCanvas.exe" enable=yes profile=any
)

echo.
echo ====================================================================
echo  [SUCCESS] Windows Firewall successfully configured for AirCanvas!
echo  Your Android phone / tablet can now connect instantly to PC.
echo ====================================================================
echo.
pause
