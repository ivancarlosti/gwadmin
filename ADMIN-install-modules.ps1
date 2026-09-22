
# Check for administrator privileges
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as Administrator. Please restart PowerShell with elevated privileges." -ForegroundColor Yellow
    Read-Host -Prompt "Press Enter to exit"
    exit
}

# Trust PSGallery if not already trusted
try {
    if ((Get-PSRepository -Name "PSGallery").InstallationPolicy -ne "Trusted") {
        Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted
    }
} catch {
    Write-Warning "Failed to set PSGallery as trusted: $($_.Exception.Message)"
}

# List of required modules
$modules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Mail',
    'Microsoft.Graph.Files',
    'Microsoft.Graph.Sites',
    'Microsoft.Graph.Calendar',
    'Microsoft.Graph.Identity.DirectoryManagement'
)


$updatedModules = @()

foreach ($module in $modules) {
    try {
        $installed = Get-InstalledModule -Name $module -ErrorAction Stop
        Write-Host "`nUpdating module: $module (Current: $($installed.Version))" -ForegroundColor Cyan
        Update-Module -Name $module -Force -ErrorAction Stop
        $updatedModules += $module
        Write-Host "Updated $module to latest version." -ForegroundColor Green
    } catch {
        Write-Host "`nModule not found or update failed: $module. Attempting install..." -ForegroundColor Yellow
        try {
            Install-Module -Name $module -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
            Write-Host "Successfully installed $module." -ForegroundColor Green
            $updatedModules += $module
        } catch {
            Write-Warning ("Failed to install {0}: {1}" -f $module, $_.Exception.Message)
        }
    }
}

# Ask user if they want to remove old versions
if ($updatedModules.Count -gt 0) {
    $response = Read-Host "`nDo you want to remove old versions of the updated modules? (y/n)"
    if ($response -match '^(y|yes)$') {
        foreach ($module in $updatedModules) {
            try {
                $allVersions = Get-InstalledModule -Name $module -AllVersions
                $latest = $allVersions | Sort-Object Version -Descending | Select-Object -First 1
                $oldVersions = $allVersions | Where-Object { $_.Version -ne $latest.Version }

                foreach ($old in $oldVersions) {
                    Write-Host "Removing old version $($old.Version) of $module..." -ForegroundColor DarkGray
                    Uninstall-Module -Name $module -RequiredVersion $old.Version -Force -ErrorAction Stop
                }
                Write-Host "Cleaned up old versions of $module." -ForegroundColor Green
            } catch {
                Write-Warning ("Failed to remove old versions of {0}: {1}" -f $module, $_.Exception.Message)
            }
        }
    } else {
        Write-Host "Skipping module cleanup." -ForegroundColor Yellow
    }
}

Write-Host "`nAll modules processed successfully." -ForegroundColor Cyan
Read-Host -Prompt "Press Enter to exit"
