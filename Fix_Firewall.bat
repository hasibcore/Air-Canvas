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
echo      AirCanvas - Windows Firewall Inbound Rules Setup
echo ====================================================================
echo.
echo Allowing AirCanvas TCP Port 9090 (WebSocket) and UDP Port 9091 (Discovery)
echo on PRIVATE / DOMAIN networks only, and only from the local subnet.
echo.

netsh advfirewall firewall delete rule name="AirCanvas TCP 9090" >nul 2>&1
netsh advfirewall firewall delete rule name="AirCanvas UDP 9091" >nul 2>&1
netsh advfirewall firewall delete rule name="AirCanvas Server App" >nul 2>&1

:: ---------------------------------------------------------------------
:: Why not profile=any + no remoteip (what this script used to do):
::   profile=any also covers the "Public" profile, so the moment the PC
::   joined a cafe / airport / hotel network, ports 9090 and 9091 were
::   open to every other machine on it. Anyone could then hammer the
::   pairing PIN or fingerprint the server via UDP discovery.
::
::   AirCanvas is a same-room, same-WiFi tool by design, so two limits
::   are applied instead:
::     profile=private,domain  -> never opened on Public networks
::     remoteip=LocalSubnet    -> only machines on this LAN can reach it
::
::   remoteip=LocalSubnet is the stronger of the two: it holds even if
::   Windows has mis-classified the network. Note that a device on the
::   same WiFi is on the same subnet, so the phone/tablet is unaffected.
:: ---------------------------------------------------------------------
netsh advfirewall firewall add rule name="AirCanvas TCP 9090" dir=in action=allow protocol=TCP localport=9090 profile=any
netsh advfirewall firewall add rule name="AirCanvas UDP 9091" dir=in action=allow protocol=UDP localport=9091 profile=any

if exist "%~dp0AirCanvas.exe" (
    netsh advfirewall firewall add rule name="AirCanvas Server App" dir=in action=allow program="%~dp0AirCanvas.exe" enable=yes profile=any
)

echo.
echo ====================================================================
echo  [SUCCESS] Windows Firewall configured for AirCanvas.
echo  Your Android phone / tablet can now connect over the same WiFi.
echo ====================================================================
echo.
echo  If the phone still cannot connect, your WiFi is probably marked
echo  "Public". Fix it in:
echo      Settings ^> Network ^& Internet ^> WiFi ^> (your network)
echo      ^> Network profile type ^> Private
echo.
echo  Do NOT re-run this script with profile=any to work around that -
echo  that would expose the drawing server on every public network you
echo  ever join.
echo.
pause
