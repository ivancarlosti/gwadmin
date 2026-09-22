## SaaS Admin (saasadmin)
## Unified launcher for Google Workspace (GAM) and Microsoft 365 (Microsoft Graph) tasks.
## Run it through launcher.bat so the execution policy is bypassed and, when needed,
## the session is elevated.

[CmdletBinding()]
param(
    [ValidateSet('menu', 'google', 'm365', 'install-modules')]
    [string]$Action = 'menu'
)

# ------------------------------------------------------------------
# Configuration (adjust if your install differs from the defaults)
# ------------------------------------------------------------------

$GAMpath = "C:\GAM7"
$gamsettings = "$env:USERPROFILE\.gam"

try {
    $destinationpath = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
} catch {
    $destinationpath = Join-Path ([Environment]::GetFolderPath('UserProfile')) "Downloads"
}

$datetime = Get-Date -f yyyy-MM-dd-HH-mm-ss

# Configuration files, always resolved next to this script
$GwEmailFile = Join-Path $PSScriptRoot "gwemail.txt"
$M365TenantFile = Join-Path $PSScriptRoot "m365tenant.txt"

# Output folders for the Microsoft 365 operations
$M365LogDir = Join-Path $destinationpath "m365admin-logs"
$M365ReportDir = Join-Path $destinationpath "m365admin-reports"

[console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ------------------------------------------------------------------
# Shared helpers
# ------------------------------------------------------------------

function pause { $null = Read-Host 'Press ENTER key to continue' }

function Test-IsElevated {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ------------------------------------------------------------------
# Modules
# ------------------------------------------------------------------

. "$PSScriptRoot\lib\GoogleWorkspace.ps1"
. "$PSScriptRoot\lib\M365\M365Menu.ps1"

# ------------------------------------------------------------------
# Platform menu
# ------------------------------------------------------------------

function Invoke-ModuleInstallation {
    $installer = Join-Path $PSScriptRoot "ADMIN-install-modules.ps1"
    if (-not (Test-Path $installer)) {
        Write-Host "Installer not found: $installer" -ForegroundColor Red
        pause
        return
    }

    if (Test-IsElevated) {
        & $installer
        return
    }

    Write-Host "Administrator privileges are required to install or update the modules." -ForegroundColor Yellow
    Write-Host "Re-launching through launcher.bat (accept the UAC prompt)..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath (Join-Path $PSScriptRoot "launcher.bat") -ArgumentList "-Action", "install-modules" -Verb RunAs
    } catch {
        Write-Host "Could not start launcher.bat elevated: $_" -ForegroundColor Red
        Write-Host "Right-click launcher.bat and choose 'Run as administrator' instead." -ForegroundColor Yellow
        pause
    }
}

function Show-PlatformMenu {
    cls
    Write-Host "===============================================" -ForegroundColor DarkCyan
    Write-Host "    SaaS Admin Operations" -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor DarkCyan
    Write-Host "  1. Google Workspace (GAM)"
    Write-Host "  2. Microsoft 365 (Microsoft Graph)"
    Write-Host "  3. Install / update Microsoft Graph modules (requires elevation)"
    Write-Host "  0. Exit"
    Write-Host "===============================================" -ForegroundColor DarkCyan
    return (Read-Host "Select an option [0-3]")
}

function Start-SaaSAdmin {
    while ($true) {
        $option = Show-PlatformMenu

        try {
            switch ($option) {
                '1' { Invoke-GoogleWorkspaceMenu }
                '2' { Invoke-Microsoft365Menu }
                '3' { Invoke-ModuleInstallation }
                '0' { Write-Host "Exiting."; return }
                default { Write-Host "Invalid option selected." -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
            }
        }
        catch {
            Write-Host "An error occurred: $_" -ForegroundColor Red
            pause
        }
    }
}

# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------

switch ($Action) {
    'google'          { Invoke-GoogleWorkspaceMenu }
    'm365'            { Invoke-Microsoft365Menu }
    'install-modules' { Invoke-ModuleInstallation }
    default           { Start-SaaSAdmin }
}
