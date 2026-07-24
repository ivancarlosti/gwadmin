@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: --- Elevation (keep original behavior) ---
Set "Variable=0" & if exist "%temp%\getadmin.vbs" del "%temp%\getadmin.vbs"
fsutil dirty query %systemdrive% >nul 2>&1 && goto :(Privileges_got)
If "%1"=="%Variable%" (
    echo.
    echo Please right-click on the file and select
    echo "Run as administrator".
    echo Press any key to exit.
    pause >nul 2>&1
    exit /b 1
)
cmd /u /c echo Set UAC = CreateObject^("Shell.Application"^) : UAC.ShellExecute "%~0", "%Variable%", "", "runas", 1 > "%temp%\getadmin.vbs"
cscript //nologo "%temp%\getadmin.vbs" & exit /b

:(Privileges_got)

REM Change directory to the folder where this script is located
cd /d "%~dp0"

REM Search for all .ps1 files in the current folder
set "count=0"
for %%F in ("%~dp0*.ps1") do (
    if exist "%%~fF" (
        set /a count+=1
        set "file[!count!]=%%~nxF"
    )
)

REM Handle scenarios based on the number of .ps1 files found
if !count!==0 (
    echo.
    echo No PowerShell ^(.ps1^) files were found in this directory.
    echo.
    pause
    exit /b
)

if !count!==1 (
    set "target=!file[1]!"
    goto :RunScript
)

:: If multiple files exist, prompt user for selection
echo.
echo Multiple PowerShell scripts found:
echo.
for /L %%I in (1, 1, !count!) do (
    echo   [%%I] !file[%%I]!
)
echo.

:SelectScript
set "userChoice="
set /p "userChoice=Select a script number to run (1-!count!): "

if not defined userChoice goto :SelectScript
set "target="
for %%A in (!userChoice!) do set "target=!file[%%A]!"

if not defined target (
    echo.
    echo Invalid selection. Please enter a valid number between 1 and !count!.
    echo.
    goto :SelectScript
)

:RunScript
echo.
echo Executing "!target!"...
echo.

REM Run PowerShell bypassing the execution policy for the selected file only
powershell -NoProfile -ExecutionPolicy Bypass -File "!target!"

pause