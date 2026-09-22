@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ------------------------------------------------------------------
:: SaaS Admin launcher
::   1. Elevates itself through UAC when required.
::   2. Runs saasadmin.ps1 with the execution policy bypassed, forwarding
::      any arguments it received (for example: launcher.bat -Action install-modules).
:: ------------------------------------------------------------------

set "ENTRY=saasadmin.ps1"
set "ELEVATION_MARKER=__elevated__"

:: Work out whether we were already re-launched through elevation, and strip the
:: marker so that it is never forwarded to PowerShell. Comparing through
:: "!FIRST_ARG: =!" tolerates stray spaces around the first argument.
set "PASS_ARGS=%*"
set "HAD_MARKER="
set "FIRST_ARG=%~1"
if /i "!FIRST_ARG: =!"=="%ELEVATION_MARKER%" (
    set "HAD_MARKER=1"
    set "PASS_ARGS="
    for /f "tokens=1,* delims= " %%A in ("%*") do set "PASS_ARGS=%%B"
)

:: Already elevated: run the script straight away.
fsutil dirty query %systemdrive% >nul 2>&1 && goto :RunScript

:: We came back with the marker but are not elevated, so elevation was refused.
if defined HAD_MARKER (
    echo.
    echo Please right-click on the file and select
    echo "Run as administrator".
    echo Press any key to exit.
    pause >nul 2>&1
    exit /b 1
)

:: Ask for elevation once, forwarding the marker plus the original arguments.
set "ELEV_ARGS=%ELEVATION_MARKER%"
if defined PASS_ARGS set "ELEV_ARGS=%ELEVATION_MARKER% !PASS_ARGS!"

echo.
echo Administrator privileges are required. Requesting elevation through UAC...
echo If you decline the prompt, right-click this file and choose "Run as administrator".
echo.

if exist "%temp%\getadmin.vbs" del "%temp%\getadmin.vbs"
>> "%temp%\getadmin.vbs" echo Set UAC = CreateObject^("Shell.Application"^)
>> "%temp%\getadmin.vbs" echo UAC.ShellExecute "%~f0", "!ELEV_ARGS!", "", "runas", 1
cscript //nologo "%temp%\getadmin.vbs" >nul 2>&1
exit /b 0

:RunScript
cd /d "%~dp0"

if exist "%~dp0%ENTRY%" goto :InvokeEntry

:: Fallback for installs where the unified entry point is missing: run the only
:: PowerShell script in this folder, or let the user pick one when there are several.
set "count=0"
for %%F in ("%~dp0*.ps1") do (
    if exist "%%~fF" (
        set /a count+=1
        set "file[!count!]=%%~nxF"
    )
)

if !count!==0 (
    echo.
    echo No PowerShell ^(.ps1^) files were found in this directory.
    echo.
    pause
    exit /b 1
)

if !count!==1 (
    echo.
    echo "%ENTRY%" was not found, falling back to the only script available.
    set "ENTRY=!file[1]!"
    goto :InvokeEntry
)

echo.
echo "%ENTRY%" was not found. Multiple PowerShell scripts are available:
echo.
for /L %%I in (1, 1, !count!) do (
    echo   [%%I] !file[%%I]!
)
echo.

:SelectScript
set "userChoice="
set /p "userChoice=Select a script number to run (1-!count!): "
if not defined userChoice goto :SelectScript
set "ENTRY="
for %%A in (!userChoice!) do set "ENTRY=!file[%%A]!"
if not defined ENTRY (
    echo.
    echo Invalid selection. Please enter a valid number between 1 and !count!.
    echo.
    goto :SelectScript
)

:InvokeEntry
echo.
echo Executing "%ENTRY%" !PASS_ARGS!...
echo.

:: Run PowerShell bypassing the execution policy for the selected file only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0%ENTRY%" !PASS_ARGS!

pause
