# Shared helpers for m365 admin operations.
# Dot-sourced by M365Menu.ps1 (loaded from saasadmin.ps1).

function Write-Step {
    param([Parameter(Mandatory)][string]$Message)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
}

function Confirm-Action {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [switch]$DefaultYes
    )
    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) {
        return [bool]$DefaultYes
    }
    return $answer -match '^(y|yes)$'
}

function Get-M365TenantFilePath {
    if ($script:M365TenantFile) { return $script:M365TenantFile }
    return (Join-Path $PSScriptRoot "..\..\m365tenant.txt")
}

function Get-SelectedTenantId {
    param([string]$TenantIdsFilePath)

    if (-not $TenantIdsFilePath) { $TenantIdsFilePath = Get-M365TenantFilePath }

    if (-not (Test-Path $TenantIdsFilePath)) {
        Write-Host "Tenant file not found: $TenantIdsFilePath" -ForegroundColor Red
        Write-Host "Create a file named 'm365tenant.txt' with your tenants, one per line." -ForegroundColor Red
        Read-Host -Prompt "Press Enter to continue"
        return $null
    }

    $tenants = @(Get-Content -Path $TenantIdsFilePath | Where-Object { $_ -and $_.Trim() -ne "" } | ForEach-Object { $_.Trim() })
    if ($tenants.Count -eq 0) {
        Write-Host "m365tenant.txt is empty. Add at least one tenant (one per line)." -ForegroundColor Red
        Read-Host -Prompt "Press Enter to continue"
        return $null
    }

    Write-Host ""
    Write-Host "Select a Tenant to connect:"
    for ($i = 0; $i -lt $tenants.Count; $i++) {
        Write-Host "  $($i + 1). $($tenants[$i])"
    }
    do {
        $selection = Read-Host "Enter the number of the Tenant (0 to cancel)"
        if ($selection -eq '0') { return $null }
        $valid = ($selection -match '^\d+$') -and ([int]$selection -ge 1) -and ([int]$selection -le $tenants.Count)
        if (-not $valid) { Write-Host "Invalid selection." -ForegroundColor Yellow }
    } while (-not $valid)

    return $tenants[[int]$selection - 1].Trim()
}

function Test-RequiredModules {
    param([Parameter(Mandatory)][string[]]$Modules)
    $missing = @()
    foreach ($m in $Modules) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            $missing += $m
        }
    }
    if ($missing.Count -gt 0) {
        Write-Host ""
        Write-Host "The following required modules are not installed:" -ForegroundColor Red
        foreach ($m in $missing) { Write-Host "  - $m" -ForegroundColor Red }
        Write-Host ""
        Write-Host "Choose 'Install / update Microsoft Graph modules' in the main menu to install them." -ForegroundColor Yellow
        Write-Host ""
        return $false
    }
    return $true
}

function Get-M365ReportDirectory {
    if ($script:M365ReportDir) { return $script:M365ReportDir }
    return (Join-Path $env:USERPROFILE "Downloads\m365admin-reports")
}

function Resolve-MgUser {
    param([Parameter(Mandatory)][string]$Upn)
    try {
        $user = Get-MgUser -Filter "userPrincipalName eq '$Upn'" -Property "Id,UserPrincipalName,DisplayName,Mail,UserType" -ErrorAction Stop
        if (-not $user) {
            Write-Host "  User not found: $Upn" -ForegroundColor Yellow
            return $null
        }
        return $user
    } catch {
        Write-Host "  Failed to resolve $Upn : $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Read-Upn {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [int]$MaxAttempts = 3
    )
    for ($i = 0; $i -lt $MaxAttempts; $i++) {
        $upn = (Read-Host $Prompt).Trim()
        if ($upn -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            $user = Resolve-MgUser -Upn $upn
            if ($user) { return $user }
        } else {
            Write-Host "  '$upn' does not look like a valid UPN." -ForegroundColor Yellow
        }
    }
    Write-Host "  Too many invalid attempts; returning to menu." -ForegroundColor Yellow
    return $null
}

function Invoke-GraphWithRetry {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [object]$Body,
        [string]$ContentType = "application/json",
        [hashtable]$Headers,
        [string]$OutputFilePath,
        [int]$MaxRetries = 5
    )

    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $params = @{
                Method = $Method
                Uri    = $Uri
            }
            if ($Body) {
                if ($Body -is [string]) {
                    $params['Body'] = $Body
                } else {
                    $params['Body'] = ($Body | ConvertTo-Json -Depth 20 -Compress)
                }
            }
            if ($ContentType) { $params['ContentType'] = $ContentType }
            if ($Headers)     { $params['Headers']     = $Headers }
            if ($OutputFilePath) { $params['OutputFilePath'] = $OutputFilePath }

            return Invoke-MgGraphRequest @params -ErrorAction Stop
        } catch {
            $resp = $_.Exception.Response
            $statusCode = $null
            if ($resp -and $resp.StatusCode) {
                $statusCode = [int]$resp.StatusCode
            }
            $retryable = ($statusCode -eq 429) -or ($statusCode -ge 500 -and $statusCode -lt 600)
            if (-not $retryable -or $attempt -ge $MaxRetries) {
                throw
            }
            $retryAfter = 0
            try {
                $h = $resp.Headers['Retry-After']
                if ($h) { $retryAfter = [int]$h }
            } catch { }
            if ($retryAfter -le 0) {
                $retryAfter = [int][Math]::Pow(2, $attempt)
            }
            Write-Host "  Graph request returned $statusCode; waiting $retryAfter s (attempt $attempt/$MaxRetries)..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $retryAfter
        }
    }
}

function Get-AllPaged {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [int]$MaxItems = [int]::MaxValue
    )
    $results = @()
    $next = $Uri
    while ($next -and $results.Count -lt $MaxItems) {
        $resp = Invoke-GraphWithRetry -Method GET -Uri $next
        if ($resp.value) {
            $results += $resp.value
        }
        $next = $resp.'@odata.nextLink'
    }
    return $results
}

function Get-GraphErrorMessage {
    # Reduces a Graph/HTTP error to a single readable line, preferring the
    # error.message that Microsoft Graph returns in its JSON body.
    param(
        [Parameter(Mandatory)]$ErrorRecord,
        [int]$MaxLength = 300
    )

    $statusCode = $null
    $text = $null

    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        try {
            if ($ErrorRecord.Exception.Response -and $ErrorRecord.Exception.Response.StatusCode) {
                $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode
            }
        } catch { }
        $text = [string]$ErrorRecord.Exception.Message
    } else {
        $text = [string]$ErrorRecord
    }

    $message = $null
    $match = [regex]::Match($text, '"message"\s*:\s*"((?:[^"\\]|\\.)*)"')
    if ($match.Success) {
        $message = $match.Groups[1].Value
        $message = $message -replace '\\"', '"' -replace '\\n', ' ' -replace '\\r', ' ' -replace '\\/', '/'
    }

    if (-not $message) {
        $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -gt 0) {
            $message = $lines[0]
            if (($lines.Count -gt 1) -and ($lines[-1].TrimStart().StartsWith('{'))) { $message = $lines[-1] }
        }
    }

    if (-not $message) { $message = "unknown error" }
    $message = $message.Trim()
    if ($message.Length -gt $MaxLength) { $message = $message.Substring(0, $MaxLength) + "..." }

    if ($statusCode) { return "HTTP ${statusCode}: $message" }
    return $message
}

function Remove-GraphSelectParameter {
    param([Parameter(Mandatory)][string]$Uri)
    $withoutSelect = [regex]::Replace($Uri, '([?&])\$select=[^&]*', '$1')
    $withoutSelect = $withoutSelect -replace '\?&', '?'
    $withoutSelect = $withoutSelect -replace '\?$', ''
    $withoutSelect = $withoutSelect -replace '&$', ''
    return $withoutSelect
}

function Invoke-GraphGetWithSelectFallback {
    # GETs a projected ($select) Graph URI and, if the projection itself is
    # rejected (for example a property that does not exist on that type), retries
    # once without $select so the operation degrades instead of aborting.
    param([Parameter(Mandatory)][string]$Uri)

    try {
        return Invoke-GraphWithRetry -Method GET -Uri $Uri
    } catch {
        if ($Uri -notmatch '\$select=') { throw }
        Write-Host "  The projected query was rejected ($(Get-GraphErrorMessage -ErrorRecord $_)); retrying without `$select." -ForegroundColor DarkYellow
        return Invoke-GraphWithRetry -Method GET -Uri (Remove-GraphSelectParameter -Uri $Uri)
    }
}

function Get-AllPagedWithSelectFallback {
    param([Parameter(Mandatory)][string]$Uri)

    $results = @()
    $next = $Uri
    while ($next) {
        if ($next -eq $Uri) {
            $resp = Invoke-GraphGetWithSelectFallback -Uri $next
        } else {
            $resp = Invoke-GraphWithRetry -Method GET -Uri $next
        }
        if ($resp.value) { $results += $resp.value }
        $next = $resp.'@odata.nextLink'
    }
    return $results
}

function Get-M365LogDirectory {
    if ($script:M365LogDir) { return $script:M365LogDir }
    return (Join-Path $env:USERPROFILE "Downloads\m365admin-logs")
}

function New-OperationLog {
    param([Parameter(Mandatory)][string]$OperationName)
    $logDir = Get-M365LogDirectory
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $logPath = Join-Path $logDir "$OperationName-$ts.log"
    "[$([DateTime]::Now.ToString('s'))] $OperationName started" | Out-File -FilePath $logPath -Encoding UTF8
    return $logPath
}

function Write-LogLine {
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$Message
    )
    "[$([DateTime]::Now.ToString('s'))] $Message" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Name.ToCharArray()) {
        if ($invalid -contains $c) { [void]$sb.Append('_') } else { [void]$sb.Append($c) }
    }
    return $sb.ToString()
}
