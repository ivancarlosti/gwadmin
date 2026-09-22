# Export the size of every folder of a SharePoint site document library to a CSV file.
#
# Depth semantics (asked interactively, default 2):
#   1 -> lists the library's direct child folders and the size of the files inside them
#   2 -> lists levels 1 and 2; a level 1 folder size includes the level 2 folders below it
#   0 -> unlimited: every folder is walked, so every size is fully recursive (slowest)
# Folders deeper than the selected depth are not listed and their content is not counted,
# so a level 1 total is only the "true" size when depth is 2 or higher (or 0).

$script:GraphBase = "https://graph.microsoft.com/v1.0"

function Get-GraphSiteList {
    param([Parameter(Mandatory)][string]$Search)
    $encoded = [System.Uri]::EscapeDataString($Search)
    return @(Get-AllPaged -Uri "$script:GraphBase/sites?search=$encoded&`$select=id,displayName,name,webUrl,hostname")
}

function Resolve-SharePointSiteFromUrl {
    param([Parameter(Mandatory)][string]$Url)

    # Graph resolves a full site URL through /sites/{hostname}:/sites/{path}
    if ($Url -notmatch '^https?://([^/]+)(/.+)?$') { return $null }
    $siteHost = $Matches[1]
    $sitePath = $Matches[2]
    if (-not $sitePath) { $sitePath = "" }

    try {
        return Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/sites/$siteHost`:$sitePath"
    } catch {
        return $null
    }
}

function Select-SharePointSite {
    while ($true) {
        Write-Host
        $answer = Read-Host "Enter the SharePoint site URL (e.g. https://contoso.sharepoint.com/sites/marketing) or a search term (blank to cancel)"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $null }

        $reference = $answer.Trim()
        if ($reference -match '^https?://') {
            Write-Host "  Resolving the site from the URL..." -ForegroundColor DarkGray
            $site = Resolve-SharePointSiteFromUrl -Url $reference
            if ($site -and $site.id) { return $site }
            Write-Host "  Could not resolve that URL, falling back to a search." -ForegroundColor Yellow
            $reference = ($reference.TrimEnd('/') -split '/')[-1]
        }

        Write-Host "  Searching sites for '$reference'..." -ForegroundColor DarkGray
        $sites = Get-GraphSiteList -Search $reference
        if ($sites.Count -eq 0) {
            Write-Host "  No sites found for '$reference'. Please try again." -ForegroundColor Yellow
            continue
        }

        Write-Host
        Write-Host "Sites found:"
        for ($i = 0; $i -lt $sites.Count; $i++) {
            Write-Host "  $($i + 1). $($sites[$i].displayName) - $($sites[$i].webUrl)"
        }
        Write-Host "  0. Cancel"
        Write-Host

        $selection = Read-Host "Select a site number"
        if ($selection -eq '0') { return $null }
        [int]$parsed = 0
        if ([int]::TryParse($selection, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $sites.Count) {
            return $sites[$parsed - 1]
        }
        Write-Host "  Invalid selection." -ForegroundColor Yellow
    }
}

function Select-SiteDrive {
    param([Parameter(Mandatory)]$Site)

    $drives = @(Get-AllPaged -Uri "$script:GraphBase/sites/$($Site.id)/drives?`$select=id,name,driveType,webUrl")
    if ($drives.Count -eq 0) {
        Write-Host "  No document library was found on this site." -ForegroundColor Yellow
        return $null
    }
    if ($drives.Count -eq 1) { return $drives[0] }

    Write-Host
    Write-Host "Document libraries on '$($Site.displayName)':"
    for ($i = 0; $i -lt $drives.Count; $i++) {
        Write-Host "  $($i + 1). $($drives[$i].name) [$($drives[$i].driveType)]"
    }

    while ($true) {
        $selection = Read-Host "Select a library number (blank for the first one)"
        if ([string]::IsNullOrWhiteSpace($selection)) { return $drives[0] }
        [int]$parsed = 0
        if ([int]::TryParse($selection, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $drives.Count) {
            return $drives[$parsed - 1]
        }
        Write-Host "  Invalid selection." -ForegroundColor Yellow
    }
}

function Get-DriveItemChildren {
    param(
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$ItemId
    )
    $uri = "$script:GraphBase/drives/$DriveId/items/$ItemId/children?`$top=200&`$select=id,name,size,folder,file"
    return @(Get-AllPaged -Uri $uri)
}

function New-FolderSizeRow {
    param(
        [int]$Level,
        [string]$Folder,
        [string]$Path
    )
    return [pscustomobject]@{
        Level           = $Level
        Folder          = $Folder
        Path            = $Path
        SubFolders      = 0
        DirectFiles     = 0
        DirectSizeBytes = 0L
        DirectSizeMB    = 0.0
        TotalFiles      = 0
        TotalSizeBytes  = 0L
        TotalSizeMB     = 0.0
    }
}

function Get-SharePointFolderSizes {
    param(
        [Parameter(Mandatory)][string]$DriveId,
        [Parameter(Mandatory)][string]$LibraryName,
        [int]$Depth = 2,
        [string]$LogPath
    )

    $root = Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/drives/$DriveId/root?`$select=id,name"
    if ([string]::IsNullOrWhiteSpace($LibraryName)) { $LibraryName = "Library" }

    $rows = New-Object System.Collections.Generic.List[object]
    $rowByPath = @{}
    $parentOfPath = @{}

    $rootRow = New-FolderSizeRow -Level 0 -Folder $LibraryName -Path $LibraryName
    $rows.Add($rootRow) | Out-Null
    $rowByPath[$LibraryName] = $rootRow

    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue([pscustomobject]@{ Id = $root.id; Level = 0; Path = $LibraryName })

    $foldersWalked = 0
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $foldersWalked++
        if ($foldersWalked % 25 -eq 0) {
            Write-Host "    walked $foldersWalked folders, $($rows.Count - 1) folders to report so far..." -ForegroundColor DarkGray
        }

        try {
            $children = Get-DriveItemChildren -DriveId $DriveId -ItemId $current.Id
        } catch {
            Write-Host "    Failed to list '$($current.Path)': $($_.Exception.Message)" -ForegroundColor Yellow
            if ($LogPath) { Write-LogLine -LogPath $LogPath -Message "LIST FAIL '$($current.Path)': $($_.Exception.Message)" }
            continue
        }

        $currentRow = $rowByPath[$current.Path]
        $fileBytes = 0L
        $fileCount = 0
        $subFolders = 0

        foreach ($child in $children) {
            if ($child.folder) {
                $subFolders++
                $childLevel = $current.Level + 1
                if (($Depth -eq 0) -or ($childLevel -le $Depth)) {
                    $childPath = "$($current.Path) / $($child.name)"
                    $childRow = New-FolderSizeRow -Level $childLevel -Folder $child.name -Path $childPath
                    $rows.Add($childRow) | Out-Null
                    $rowByPath[$childPath] = $childRow
                    $parentOfPath[$childPath] = $current.Path
                    $queue.Enqueue([pscustomobject]@{ Id = $child.id; Level = $childLevel; Path = $childPath })
                }
            } elseif ($child.file) {
                $fileCount++
                if ($child.size) { $fileBytes += [long]$child.size }
            }
        }

        $currentRow.SubFolders = $subFolders
        $currentRow.DirectFiles = $fileCount
        $currentRow.DirectSizeBytes = $fileBytes
        $currentRow.TotalFiles = $fileCount
        $currentRow.TotalSizeBytes = $fileBytes
    }

    # Roll child totals into their parents, deepest level first.
    foreach ($row in ($rows | Sort-Object -Property Level -Descending)) {
        if (-not $parentOfPath.ContainsKey($row.Path)) { continue }
        $parentRow = $rowByPath[$parentOfPath[$row.Path]]
        $parentRow.TotalFiles += $row.TotalFiles
        $parentRow.TotalSizeBytes += $row.TotalSizeBytes
    }

    foreach ($row in $rows) {
        $row.DirectSizeMB = [math]::Round(($row.DirectSizeBytes / 1MB), 2)
        $row.TotalSizeMB = [math]::Round(($row.TotalSizeBytes / 1MB), 2)
    }

    if ($LogPath) {
        Write-LogLine -LogPath $LogPath -Message "WALK DONE depth=$Depth folders=$($rows.Count - 1)"
    }

    return $rows
}

function Format-ByteSize {
    param([Parameter(Mandatory)][long]$Bytes)
    $units = @('B', 'KB', 'MB', 'GB', 'TB', 'PB')
    $value = [double]$Bytes
    $index = 0
    while (($value -ge 1024) -and ($index -lt ($units.Count - 1))) {
        $value = $value / 1024
        $index++
    }
    if ($index -eq 0) { return ("{0} {1}" -f [long]$value, $units[$index]) }
    return ("{0:N2} {1}" -f $value, $units[$index])
}

function Export-SharePointFolderSizesReport {
    param(
        [Parameter(Mandatory)]$Site,
        [Parameter(Mandatory)]$Drive,
        [int]$Depth = 2
    )

    $logPath = New-OperationLog -OperationName "sharepoint-folders-$(Get-SafeFileName $Site.displayName)"
    Write-Host "  Log: $logPath" -ForegroundColor DarkGray
    Write-LogLine -LogPath $logPath -Message "Site=$($Site.webUrl) Drive=$($Drive.name) ($($Drive.id)) Depth=$Depth"

    $depthLabel = if ($Depth -eq 0) { "unlimited" } else { "$Depth" }
    Write-Host "  Walking folders (levels: $depthLabel)..." -ForegroundColor Cyan

    $rows = Get-SharePointFolderSizes -DriveId $Drive.id -LibraryName $Drive.name -Depth $Depth -LogPath $logPath
    $rootRow = $rows | Where-Object { $_.Level -eq 0 } | Select-Object -First 1

    if (-not $rootRow -or $rows.Count -le 1) {
        Write-Host "  No folders were found in this library." -ForegroundColor Yellow
        Write-LogLine -LogPath $logPath -Message "DONE folders=0 (nothing to report)"
        return
    }

    $reportDir = Get-M365ReportDirectory
    if (-not (Test-Path $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
    $stamp = Get-Date -Format "yyyy-MM-dd-HH-mm-ss"
    $csvPath = Join-Path $reportDir "sharepoint-folders-$(Get-SafeFileName $Site.displayName)-$stamp.csv"

    $rows |
        Sort-Object -Property Level, @{ Expression = 'TotalSizeBytes'; Descending = $true } |
        Select-Object Level, Folder, Path, SubFolders, DirectFiles, DirectSizeBytes, DirectSizeMB, TotalFiles, TotalSizeBytes, TotalSizeMB |
        Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

    Write-Host
    Write-Host "  Report written: $csvPath" -ForegroundColor Green
    Write-Host "  Folders reported: $($rows.Count - 1)" -ForegroundColor Gray
    Write-Host "  Library total: $(Format-ByteSize -Bytes $rootRow.TotalSizeBytes), $($rootRow.TotalFiles) files, $($rootRow.SubFolders) top-level folders" -ForegroundColor Gray

    Write-Host
    Write-Host "  Largest folders:" -ForegroundColor Cyan
    $rows |
        Where-Object { $_.Level -gt 0 } |
        Sort-Object -Property TotalSizeBytes -Descending |
        Select-Object -First 10 |
        ForEach-Object { Write-Host ("    {0,12}  {1}" -f (Format-ByteSize -Bytes $_.TotalSizeBytes), $_.Path) }

    Write-LogLine -LogPath $logPath -Message "DONE folders=$($rows.Count - 1) total_mb=$($rootRow.TotalSizeMB) csv=$csvPath"
}
