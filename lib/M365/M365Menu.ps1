# Microsoft 365 admin operations (Microsoft Graph).
# Menu-driven functions dot-sourced by saasadmin.ps1.

# Dot-source the library functions.
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Mailbox-CopyToShared.ps1"
. "$PSScriptRoot\OneDrive-CopyToSharePoint.ps1"
. "$PSScriptRoot\Calendar-Transfer.ps1"
. "$PSScriptRoot\SharePoint-FolderSizes.ps1"

$RequiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Groups',
    'Microsoft.Graph.Mail',
    'Microsoft.Graph.Files',
    'Microsoft.Graph.Sites',
    'Microsoft.Graph.Calendar',
    'Microsoft.Graph.Identity.DirectoryManagement'
)

$Scopes = @(
    'User.Read.All',
    'Group.ReadWrite.All',
    'Directory.Read.All',
    'Mail.ReadWrite',
    'Mail.ReadWrite.Shared',
    'MailboxSettings.Read',
    'Files.ReadWrite.All',
    'Sites.ReadWrite.All',
    'Calendars.ReadWrite',
    'Calendars.ReadWrite.Shared'
) -join ' '

function Connect-ToTenant {
    $tenantId = Get-SelectedTenantId
    if (-not $tenantId) { return $null }

    Write-Host ""
    Write-Host "Connecting to Microsoft Graph for tenant: $tenantId" -ForegroundColor Cyan
    Connect-MgGraph -TenantId $tenantId -Scopes $Scopes -NoWelcome
    $ctx = Get-MgContext
    Write-Host "Connected as: $($ctx.Account)" -ForegroundColor Green
    return $ctx
}

function Disconnect-FromTenant {
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }
}

function Wait-ForEnter {
    Read-Host "`nPress Enter to return to the menu" | Out-Null
}

function Show-M365Menu {
    param($Context)
    Clear-Host
    Write-Host ""
    Write-Host "===============================================" -ForegroundColor DarkCyan
    Write-Host "    Microsoft 365 Admin Operations" -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor DarkCyan
    Write-Host "  Tenant: $($Context.TenantId)" -ForegroundColor Gray
    Write-Host "  Admin:  $($Context.Account)" -ForegroundColor Gray
    Write-Host "-----------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  1. Copy mailbox messages to a shared mailbox"
    Write-Host "  2. Copy OneDrive content to a new SharePoint site"
    Write-Host "  3. Transfer calendars to another account"
    Write-Host "  4. Export SharePoint site folder sizes to a CSV report"
    Write-Host "  5. Switch tenant"
    Write-Host "  6. Back to the main menu"
    Write-Host "==============================================="  -ForegroundColor DarkCyan
    return (Read-Host "Select an option [1-6]")
}

function Invoke-MailboxCopyMenu {
    Write-Step "Copy mailbox messages to a shared mailbox"
    $src = Read-Upn -Prompt "Source user UPN"
    if (-not $src) { return }
    $tgt = Read-Upn -Prompt "Target shared mailbox UPN"
    if (-not $tgt) { return }
    Copy-MailboxToSharedMailbox -SourceUpn $src.UserPrincipalName -TargetSharedMailboxUpn $tgt.UserPrincipalName
}

function Invoke-OneDriveCopyMenu {
    Write-Step "Copy OneDrive content to a new SharePoint site"
    $src = Read-Upn -Prompt "Source user UPN (whose OneDrive to copy)"
    if (-not $src) { return }
    $owner = Read-Upn -Prompt "Owner UPN for the new SharePoint site"
    if (-not $owner) { return }
    Copy-OneDriveToSharePointSite -SourceUpn $src.UserPrincipalName -TargetSiteOwnerUpn $owner.UserPrincipalName
}

function Invoke-CalendarTransferMenu {
    Write-Step "Transfer calendars to another account"
    $src = Read-Upn -Prompt "Source user UPN"
    if (-not $src) { return }
    $tgt = Read-Upn -Prompt "Target user UPN"
    if (-not $tgt) { return }
    $includeSecondary = Confirm-Action -Prompt "Include secondary calendars?" -DefaultYes
    $reassign = Confirm-Action -Prompt "Attempt to reassign future-event ownership? (deletes source events, emails attendees)"
    Copy-CalendarEvents `
        -SourceUpn $src.UserPrincipalName `
        -TargetUpn $tgt.UserPrincipalName `
        -IncludeSecondaryCalendars:$includeSecondary `
        -AttemptOwnershipReassign:$reassign
}

function Invoke-SharePointFolderSizesMenu {
    Write-Step "Export SharePoint site folder sizes to CSV"

    $site = Select-SharePointSite
    if (-not $site) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    $drive = Select-SiteDrive -Site $site
    if (-not $drive) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    Write-Host
    Write-Host "Depth controls how many folder levels are walked and listed:" -ForegroundColor Gray
    Write-Host "  1 = the library's direct child folders" -ForegroundColor Gray
    Write-Host "  2 = levels 1 and 2 (a level 1 size includes the level 2 folders below it)" -ForegroundColor Gray
    Write-Host "  0 = unlimited, every folder is walked (fully recursive sizes, slowest)" -ForegroundColor Gray

    $depth = $null
    while ($null -eq $depth) {
        $answer = Read-Host "How many folder levels should the report cover? (0 = full, default 2, max 10)"
        if ([string]::IsNullOrWhiteSpace($answer)) { $depth = 2; break }
        [int]$parsed = -1
        if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le 10) {
            $depth = $parsed
        } else {
            Write-Host "Invalid value. Enter 0 for a full walk or a number between 1 and 10." -ForegroundColor Yellow
        }
    }

    $depthLabel = if ($depth -eq 0) { "full" } else { "$depth level(s)" }
    if (-not (Confirm-Action -Prompt "Start the folder size report for '$($site.displayName)' (library: $($drive.name), depth: $depthLabel)?" -DefaultYes)) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        return
    }

    Export-SharePointFolderSizesReport -Site $site -Drive $drive -Depth $depth
}

function Invoke-Microsoft365Menu {
    if (-not (Test-RequiredModules -Modules $RequiredModules)) {
        Write-Host "Returning to the main menu. Choose option 3 there to install or update the modules." -ForegroundColor Yellow
        pause
        return
    }

    foreach ($m in $RequiredModules) { Import-Module $m -ErrorAction Stop }

    $context = $null
    try {
        while ($true) {
            if (-not $context) {
                $context = Connect-ToTenant
                if (-not $context) { return }
            }

            $choice = Show-M365Menu -Context $context
            switch ($choice) {
                '1' { Invoke-MailboxCopyMenu;           Wait-ForEnter }
                '2' { Invoke-OneDriveCopyMenu;          Wait-ForEnter }
                '3' { Invoke-CalendarTransferMenu;      Wait-ForEnter }
                '4' { Invoke-SharePointFolderSizesMenu; Wait-ForEnter }
                '5' {
                    Disconnect-FromTenant
                    $context = $null
                }
                '6' { return }
                default { Write-Host "Invalid selection." -ForegroundColor Yellow; Start-Sleep -Seconds 1 }
            }
        }
    }
    finally {
        Disconnect-FromTenant
    }
}
