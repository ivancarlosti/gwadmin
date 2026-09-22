# Copy all mailbox messages from a source user into a target shared mailbox,
# preserving folder structure. Source mailbox is not modified.

$script:GraphBase = "https://graph.microsoft.com/v1.0"

function Get-MailFolderTree {
    param(
        [Parameter(Mandatory)][string]$UserId,
        [string]$ParentFolderId,
        [int]$Depth = 0
    )
    if ($ParentFolderId) {
        $uri = "$script:GraphBase/users/$UserId/mailFolders/$ParentFolderId/childFolders?`$top=100&`$select=id,displayName,parentFolderId,wellKnownName,totalItemCount,childFolderCount"
    } else {
        $uri = "$script:GraphBase/users/$UserId/mailFolders?`$top=100&`$select=id,displayName,parentFolderId,wellKnownName,totalItemCount,childFolderCount&includeHiddenFolders=true"
    }
    $folders = Get-AllPaged -Uri $uri
    $tree = @()
    foreach ($f in $folders) {
        $node = [pscustomobject]@{
            Id              = $f.id
            DisplayName     = $f.displayName
            ParentFolderId  = $f.parentFolderId
            WellKnownName   = $f.wellKnownName
            TotalItemCount  = $f.totalItemCount
            ChildFolderCount = $f.childFolderCount
            Depth           = $Depth
        }
        $tree += $node
        if ($f.childFolderCount -gt 0) {
            $tree += Get-MailFolderTree -UserId $UserId -ParentFolderId $f.id -Depth ($Depth + 1)
        }
    }
    return $tree
}

function Find-OrCreateTargetFolder {
    param(
        [Parameter(Mandatory)][string]$TargetUserId,
        [Parameter(Mandatory)][string]$DisplayName,
        [string]$ParentFolderId,
        [string]$WellKnownName
    )

    if ($WellKnownName) {
        # Well-known folders (Inbox, SentItems, etc.) already exist on every mailbox.
        try {
            $existing = Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/users/$TargetUserId/mailFolders/$WellKnownName"
            if ($existing.id) { return $existing.id }
        } catch { }
    }

    if ($ParentFolderId) {
        $listUri = "$script:GraphBase/users/$TargetUserId/mailFolders/$ParentFolderId/childFolders?`$filter=displayName eq '$($DisplayName.Replace("'", "''"))'"
        $createUri = "$script:GraphBase/users/$TargetUserId/mailFolders/$ParentFolderId/childFolders"
    } else {
        $listUri = "$script:GraphBase/users/$TargetUserId/mailFolders?`$filter=displayName eq '$($DisplayName.Replace("'", "''"))'"
        $createUri = "$script:GraphBase/users/$TargetUserId/mailFolders"
    }

    $resp = Invoke-GraphWithRetry -Method GET -Uri $listUri
    if ($resp.value -and $resp.value.Count -gt 0) {
        return $resp.value[0].id
    }

    $created = Invoke-GraphWithRetry -Method POST -Uri $createUri -Body @{ displayName = $DisplayName }
    return $created.id
}

function Test-MessageExistsOnTarget {
    param(
        [Parameter(Mandatory)][string]$TargetUserId,
        [Parameter(Mandatory)][string]$InternetMessageId
    )
    $escaped = $InternetMessageId.Replace("'", "''")
    $uri = "$script:GraphBase/users/$TargetUserId/messages?`$filter=internetMessageId eq '$escaped'&`$select=id&`$top=1"
    try {
        $resp = Invoke-GraphWithRetry -Method GET -Uri $uri
        return ($resp.value -and $resp.value.Count -gt 0)
    } catch {
        return $false
    }
}

function Copy-SingleMessageViaMime {
    param(
        [Parameter(Mandatory)][string]$SourceUserId,
        [Parameter(Mandatory)][string]$TargetUserId,
        [Parameter(Mandatory)][string]$SourceMessageId,
        [Parameter(Mandatory)][string]$TargetFolderId
    )

    # Download MIME content. /$value returns raw RFC822 MIME bytes.
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/users/$SourceUserId/messages/$SourceMessageId/`$value" -OutputFilePath $tmp | Out-Null
        $mimeBytes = [System.IO.File]::ReadAllBytes($tmp)
        $b64 = [System.Convert]::ToBase64String($mimeBytes)

        $created = Invoke-GraphWithRetry `
            -Method POST `
            -Uri "$script:GraphBase/users/$TargetUserId/mailFolders/$TargetFolderId/messages" `
            -Body $b64 `
            -ContentType "text/plain"
        return $created
    } finally {
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Copy-MailboxToSharedMailbox {
    param(
        [Parameter(Mandatory)][string]$SourceUpn,
        [Parameter(Mandatory)][string]$TargetSharedMailboxUpn
    )

    Write-Step "Copy mailbox: $SourceUpn -> $TargetSharedMailboxUpn"
    $logPath = New-OperationLog -OperationName "mailcopy-$(Get-SafeFileName $SourceUpn)"
    Write-Host "  Log: $logPath" -ForegroundColor DarkGray

    $source = Resolve-MgUser -Upn $SourceUpn
    $target = Resolve-MgUser -Upn $TargetSharedMailboxUpn
    if (-not $source -or -not $target) {
        Write-Host "  Aborted: could not resolve one or both users." -ForegroundColor Red
        return
    }
    if ($source.Id -eq $target.Id) {
        Write-Host "  Source and target are the same user." -ForegroundColor Red
        return
    }

    Write-Host "  Enumerating source folders..." -ForegroundColor DarkGray
    $sourceTree = Get-MailFolderTree -UserId $source.Id
    $totalMessages = ($sourceTree | Measure-Object -Property TotalItemCount -Sum).Sum
    Write-Host "  Source: $($sourceTree.Count) folders, $totalMessages messages." -ForegroundColor Gray

    if ($totalMessages -eq 0) {
        Write-Host "  Nothing to copy." -ForegroundColor Yellow
        return
    }

    if (-not (Confirm-Action -Prompt "Proceed with copy? Source will NOT be modified.")) {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        return
    }

    Write-LogLine -LogPath $logPath -Message "Source=$SourceUpn Target=$TargetSharedMailboxUpn Folders=$($sourceTree.Count) Messages=$totalMessages"

    # Build folder map (sourceFolderId -> targetFolderId).
    # Process in depth order so parents are mapped before children.
    $folderMap = @{}
    $orderedFolders = $sourceTree | Sort-Object Depth
    foreach ($f in $orderedFolders) {
        $tgtParent = $null
        if ($f.ParentFolderId -and $folderMap.ContainsKey($f.ParentFolderId)) {
            $tgtParent = $folderMap[$f.ParentFolderId]
        }
        try {
            $tgtId = Find-OrCreateTargetFolder -TargetUserId $target.Id -DisplayName $f.DisplayName -ParentFolderId $tgtParent -WellKnownName $f.WellKnownName
            $folderMap[$f.Id] = $tgtId
            Write-LogLine -LogPath $logPath -Message "FOLDER MAP '$($f.DisplayName)' src=$($f.Id) tgt=$tgtId"
        } catch {
            Write-Host "  Failed to map folder '$($f.DisplayName)': $($_.Exception.Message)" -ForegroundColor Yellow
            Write-LogLine -LogPath $logPath -Message "FOLDER MAP FAILED '$($f.DisplayName)': $($_.Exception.Message)"
        }
    }

    $copied = 0
    $skipped = 0
    $failed = 0

    foreach ($f in $sourceTree) {
        if (-not $folderMap.ContainsKey($f.Id)) { continue }
        if ($f.TotalItemCount -eq 0) { continue }

        $tgtFolderId = $folderMap[$f.Id]
        Write-Host ""
        Write-Host "  Folder '$($f.DisplayName)' ($($f.TotalItemCount) messages)..." -ForegroundColor Cyan

        $msgUri = "$script:GraphBase/users/$($source.Id)/mailFolders/$($f.Id)/messages?`$top=50&`$select=id,internetMessageId,isRead,categories,subject"
        $folderCopied = 0
        while ($msgUri) {
            $resp = Invoke-GraphWithRetry -Method GET -Uri $msgUri
            foreach ($msg in $resp.value) {
                if ($msg.internetMessageId -and (Test-MessageExistsOnTarget -TargetUserId $target.Id -InternetMessageId $msg.internetMessageId)) {
                    $skipped++
                    Write-LogLine -LogPath $logPath -Message "SKIP (dup) $($msg.internetMessageId)"
                    continue
                }
                try {
                    $new = Copy-SingleMessageViaMime -SourceUserId $source.Id -TargetUserId $target.Id -SourceMessageId $msg.id -TargetFolderId $tgtFolderId

                    # Preserve flags that MIME re-import resets to default.
                    $patch = @{}
                    if ($msg.PSObject.Properties['isRead']) { $patch['isRead'] = [bool]$msg.isRead }
                    if ($msg.categories -and $msg.categories.Count -gt 0) { $patch['categories'] = $msg.categories }
                    if ($patch.Count -gt 0 -and $new -and $new.id) {
                        try {
                            Invoke-GraphWithRetry -Method PATCH -Uri "$script:GraphBase/users/$($target.Id)/messages/$($new.id)" -Body $patch | Out-Null
                        } catch {
                            Write-LogLine -LogPath $logPath -Message "PATCH FAILED on new message $($new.id): $($_.Exception.Message)"
                        }
                    }

                    $copied++
                    $folderCopied++
                    if ($copied % 25 -eq 0) {
                        Write-Host "    Copied $copied / $totalMessages..." -ForegroundColor DarkGray
                    }
                } catch {
                    $failed++
                    Write-LogLine -LogPath $logPath -Message "FAIL src=$($msg.id) subj='$($msg.subject)': $($_.Exception.Message)"
                }
            }
            $msgUri = $resp.'@odata.nextLink'
        }
        Write-Host "    Folder done: $folderCopied copied." -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "  Copy complete: $copied copied, $skipped skipped (duplicates), $failed failed." -ForegroundColor Green
    Write-LogLine -LogPath $logPath -Message "DONE copied=$copied skipped=$skipped failed=$failed"
}
