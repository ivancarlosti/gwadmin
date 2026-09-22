# Provision a new Microsoft 365 group (which creates a SharePoint site) and
# copy the source user's OneDrive contents into the group's document library.
# Source OneDrive is not modified.

$script:GraphBase = "https://graph.microsoft.com/v1.0"
$script:SmallFileLimit = 4 * 1024 * 1024            # 4 MiB
$script:UploadChunkSize = 10 * 320 * 1024           # ~3.125 MiB, multiple of 320 KiB
$script:MaxGraphFileSize = 250GB

function New-MigrationGroupAndSite {
    param(
        [Parameter(Mandatory)][string]$SourceUpn,
        [Parameter(Mandatory)][string]$OwnerUserId,
        [string]$DisplayNamePrefix = "Migrated from"
    )

    $ts = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $displayName = "$DisplayNamePrefix $SourceUpn - $ts"
    $localPart = ($SourceUpn -split '@')[0]
    $nickRaw = "migrated-$localPart-$(Get-Date -Format yyyyMMddHHmmss)"
    $mailNickname = ($nickRaw -replace '[^a-zA-Z0-9\-]', '').ToLowerInvariant()
    if ($mailNickname.Length -gt 60) { $mailNickname = $mailNickname.Substring(0, 60) }

    $body = @{
        displayName     = $displayName
        mailNickname    = $mailNickname
        groupTypes      = @("Unified")
        mailEnabled     = $true
        securityEnabled = $false
        visibility      = "Private"
        "owners@odata.bind" = @("https://graph.microsoft.com/v1.0/users/$OwnerUserId")
    }

    Write-Host "  Creating Microsoft 365 group:" -ForegroundColor Gray
    Write-Host "    Name : $displayName" -ForegroundColor Gray
    Write-Host "    Nick : $mailNickname" -ForegroundColor Gray
    $group = Invoke-GraphWithRetry -Method POST -Uri "$script:GraphBase/groups" -Body $body
    Write-Host "  Group created: $($group.id)" -ForegroundColor Green
    return $group
}

function Wait-ForGroupDrive {
    param(
        [Parameter(Mandatory)][string]$GroupId,
        [int]$TimeoutSeconds = 300
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    Write-Host "  Waiting for SharePoint site provisioning (up to $TimeoutSeconds s)..." -ForegroundColor Gray
    while ((Get-Date) -lt $deadline) {
        try {
            $drive = Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/groups/$GroupId/drive"
            if ($drive -and $drive.id) {
                Write-Host "  Site ready: $($drive.webUrl)" -ForegroundColor Green
                return $drive
            }
        } catch {
            # 404 expected while provisioning.
        }
        Start-Sleep -Seconds 10
        Write-Host "    ...still provisioning" -ForegroundColor DarkGray
    }
    throw "SharePoint site for group $GroupId did not provision within $TimeoutSeconds seconds."
}

function Send-FileViaUploadSession {
    param(
        [Parameter(Mandatory)][string]$SourceDriveId,
        [Parameter(Mandatory)][string]$SourceItemId,
        [Parameter(Mandatory)][string]$TargetDriveId,
        [Parameter(Mandatory)][string]$TargetParentId,
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][long]$FileSize
    )

    # Stage source content to a temp file.
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/drives/$SourceDriveId/items/$SourceItemId/content" -OutputFilePath $tmp | Out-Null

        $createBody = @{
            item = @{
                "@microsoft.graph.conflictBehavior" = "rename"
                name = $FileName
            }
        }
        $createUri = "$script:GraphBase/drives/$TargetDriveId/items/$($TargetParentId):/$([System.Uri]::EscapeDataString($FileName)):/createUploadSession"
        $session = Invoke-GraphWithRetry -Method POST -Uri $createUri -Body $createBody
        if (-not $session.uploadUrl) { throw "createUploadSession returned no uploadUrl" }

        $fs = [System.IO.File]::OpenRead($tmp)
        try {
            $buffer = New-Object byte[] $script:UploadChunkSize
            $offset = 0L
            $totalSize = $fs.Length
            while ($offset -lt $totalSize) {
                $bytesToRead = [Math]::Min([long]$script:UploadChunkSize, $totalSize - $offset)
                $read = $fs.Read($buffer, 0, [int]$bytesToRead)
                if ($read -le 0) { break }
                $chunk = if ($read -eq $buffer.Length) { $buffer } else { $buffer[0..($read - 1)] }

                $rangeEnd = $offset + $read - 1
                $headers = @{
                    "Content-Length" = "$read"
                    "Content-Range"  = "bytes $offset-$rangeEnd/$totalSize"
                }

                $attempt = 0
                while ($true) {
                    $attempt++
                    try {
                        Invoke-RestMethod -Method Put -Uri $session.uploadUrl -Headers $headers -Body $chunk -ContentType "application/octet-stream" -ErrorAction Stop | Out-Null
                        break
                    } catch {
                        if ($attempt -ge 5) { throw }
                        $wait = [int][Math]::Pow(2, $attempt)
                        Write-Host "      chunk upload failed (attempt $attempt), retry in ${wait}s..." -ForegroundColor DarkYellow
                        Start-Sleep -Seconds $wait
                    }
                }
                $offset += $read
            }
        } finally {
            $fs.Dispose()
        }
    } finally {
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Copy-DriveItemRecursive {
    param(
        [Parameter(Mandatory)][string]$SourceDriveId,
        [Parameter(Mandatory)][string]$SourceParentId,
        [Parameter(Mandatory)][string]$TargetDriveId,
        [Parameter(Mandatory)][string]$TargetParentId,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][ref]$Stats
    )

    $childrenUri = "$script:GraphBase/drives/$SourceDriveId/items/$SourceParentId/children?`$top=200&`$select=id,name,size,folder,file,lastModifiedDateTime"
    while ($childrenUri) {
        $resp = Invoke-GraphWithRetry -Method GET -Uri $childrenUri
        foreach ($item in $resp.value) {
            if ($item.folder) {
                try {
                    $createBody = @{
                        name = $item.name
                        folder = @{}
                        "@microsoft.graph.conflictBehavior" = "rename"
                    }
                    $created = Invoke-GraphWithRetry -Method POST -Uri "$script:GraphBase/drives/$TargetDriveId/items/$TargetParentId/children" -Body $createBody
                    Write-LogLine -LogPath $LogPath -Message "FOLDER '$($item.name)' src=$($item.id) tgt=$($created.id)"
                    Copy-DriveItemRecursive -SourceDriveId $SourceDriveId -SourceParentId $item.id -TargetDriveId $TargetDriveId -TargetParentId $created.id -LogPath $LogPath -Stats $Stats
                } catch {
                    $Stats.Value.FailedFolders++
                    Write-LogLine -LogPath $LogPath -Message "FOLDER FAIL '$($item.name)': $($_.Exception.Message)"
                }
            } elseif ($item.file) {
                if ($item.name -like "*.one") {
                    $Stats.Value.SkippedOneNote++
                    Write-LogLine -LogPath $LogPath -Message "SKIP OneNote '$($item.name)'"
                    continue
                }
                if ($item.size -gt $script:MaxGraphFileSize) {
                    $Stats.Value.SkippedTooLarge++
                    Write-LogLine -LogPath $LogPath -Message "SKIP too-large '$($item.name)' size=$($item.size)"
                    continue
                }
                try {
                    if ($item.size -le $script:SmallFileLimit) {
                        # Small file: stream content directly.
                        $tmp = [System.IO.Path]::GetTempFileName()
                        try {
                            Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/drives/$SourceDriveId/items/$($item.id)/content" -OutputFilePath $tmp | Out-Null
                            $bytes = [System.IO.File]::ReadAllBytes($tmp)
                            $putUri = "$script:GraphBase/drives/$TargetDriveId/items/$($TargetParentId):/$([System.Uri]::EscapeDataString($item.name)):/content"
                            Invoke-GraphWithRetry -Method PUT -Uri $putUri -Body $bytes -ContentType "application/octet-stream" | Out-Null
                        } finally {
                            if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
                        }
                    } else {
                        Send-FileViaUploadSession -SourceDriveId $SourceDriveId -SourceItemId $item.id -TargetDriveId $TargetDriveId -TargetParentId $TargetParentId -FileName $item.name -FileSize $item.size
                    }

                    # Preserve modified date if known.
                    if ($item.lastModifiedDateTime) {
                        try {
                            # We don't know the new item id without a lookup; skip metadata preservation for now.
                            # (left intentionally lightweight to avoid an extra round-trip per file)
                        } catch { }
                    }

                    $Stats.Value.Files++
                    $Stats.Value.Bytes += [long]$item.size
                    if ($Stats.Value.Files % 10 -eq 0) {
                        Write-Host "    Copied $($Stats.Value.Files) files..." -ForegroundColor DarkGray
                    }
                    Write-LogLine -LogPath $LogPath -Message "FILE '$($item.name)' size=$($item.size)"
                } catch {
                    $Stats.Value.FailedFiles++
                    Write-LogLine -LogPath $LogPath -Message "FILE FAIL '$($item.name)': $($_.Exception.Message)"
                }
            }
        }
        $childrenUri = $resp.'@odata.nextLink'
    }
}

function Copy-OneDriveToSharePointSite {
    param(
        [Parameter(Mandatory)][string]$SourceUpn,
        [Parameter(Mandatory)][string]$TargetSiteOwnerUpn,
        [string]$SiteDisplayNamePrefix = "Migrated from",
        [int]$ProvisioningTimeoutSeconds = 300
    )

    Write-Step "Copy OneDrive: $SourceUpn -> new SharePoint site (owner: $TargetSiteOwnerUpn)"
    $logPath = New-OperationLog -OperationName "onedrivecopy-$(Get-SafeFileName $SourceUpn)"
    Write-Host "  Log: $logPath" -ForegroundColor DarkGray

    $source = Resolve-MgUser -Upn $SourceUpn
    $owner = Resolve-MgUser -Upn $TargetSiteOwnerUpn
    if (-not $source -or -not $owner) {
        Write-Host "  Aborted: could not resolve one or both users." -ForegroundColor Red
        return
    }

    Write-Host "  Reading source OneDrive..." -ForegroundColor DarkGray
    try {
        $srcDrive = Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/users/$($source.Id)/drive"
    } catch {
        Write-Host "  Could not access source OneDrive: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $srcDriveId = $srcDrive.id
    Write-Host "  Source drive: $srcDriveId" -ForegroundColor Gray

    if (-not (Confirm-Action -Prompt "Proceed: create SharePoint site and copy OneDrive contents? Source will NOT be modified.")) {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        return
    }

    $group = New-MigrationGroupAndSite -SourceUpn $SourceUpn -OwnerUserId $owner.Id -DisplayNamePrefix $SiteDisplayNamePrefix
    Write-LogLine -LogPath $logPath -Message "Group=$($group.id) Owner=$TargetSiteOwnerUpn"

    $tgtDrive = Wait-ForGroupDrive -GroupId $group.id -TimeoutSeconds $ProvisioningTimeoutSeconds
    $tgtDriveId = $tgtDrive.id
    $tgtRoot = (Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/drives/$tgtDriveId/root").id

    $stats = [pscustomobject]@{
        Files = 0
        Bytes = 0L
        FailedFiles = 0
        FailedFolders = 0
        SkippedOneNote = 0
        SkippedTooLarge = 0
    }
    $statsRef = [ref]$stats

    Write-Host "  Copying files (this may take a while)..." -ForegroundColor Cyan
    $srcRoot = (Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/drives/$srcDriveId/root").id
    Copy-DriveItemRecursive -SourceDriveId $srcDriveId -SourceParentId $srcRoot -TargetDriveId $tgtDriveId -TargetParentId $tgtRoot -LogPath $logPath -Stats $statsRef

    Write-Host ""
    Write-Host "  Done: $($stats.Files) files copied ($([math]::Round($stats.Bytes / 1MB, 1)) MB)" -ForegroundColor Green
    if ($stats.FailedFiles -gt 0 -or $stats.FailedFolders -gt 0) {
        Write-Host "  Failed: $($stats.FailedFiles) files, $($stats.FailedFolders) folders" -ForegroundColor Yellow
    }
    if ($stats.SkippedOneNote -gt 0) {
        Write-Host "  Skipped: $($stats.SkippedOneNote) OneNote notebooks (.one not faithfully streamable via Graph)" -ForegroundColor Yellow
    }
    if ($stats.SkippedTooLarge -gt 0) {
        Write-Host "  Skipped: $($stats.SkippedTooLarge) files over 250 GB" -ForegroundColor Yellow
    }
    Write-Host "  Site URL: $($tgtDrive.webUrl)" -ForegroundColor Green
    Write-LogLine -LogPath $logPath -Message "DONE files=$($stats.Files) bytes=$($stats.Bytes) failed_files=$($stats.FailedFiles) failed_folders=$($stats.FailedFolders) skipped_onenote=$($stats.SkippedOneNote) skipped_toolarge=$($stats.SkippedTooLarge)"
}
