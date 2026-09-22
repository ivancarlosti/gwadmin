# Transfer calendars from a source user to a target user.
# Default: copy events only, source untouched.
# With -AttemptOwnershipReassign: also delete+recreate future events where
# source is the organizer (only Graph-feasible "ownership transfer" path —
# triggers cancellation + new-invite emails to attendees).

$script:GraphBase = "https://graph.microsoft.com/v1.0"

function Convert-EventForRecreate {
    param([Parameter(Mandatory)]$Event)

    $clean = @{}
    $copyFields = @(
        'subject', 'body', 'bodyPreview', 'start', 'end', 'location', 'locations',
        'recurrence', 'attendees', 'categories', 'isAllDay', 'showAs', 'sensitivity',
        'reminderMinutesBeforeStart', 'isReminderOn', 'importance', 'isOnlineMeeting',
        'onlineMeetingProvider', 'allowNewTimeProposals', 'hideAttendees'
    )
    foreach ($f in $copyFields) {
        if ($Event.PSObject.Properties[$f] -and $null -ne $Event.$f) {
            $clean[$f] = $Event.$f
        }
    }
    # Strip attendee responseStatus so target sees them as freshly invited.
    if ($clean.attendees) {
        $clean.attendees = $clean.attendees | ForEach-Object {
            @{
                emailAddress = $_.emailAddress
                type = $_.type
            }
        }
    }
    $clean['transactionId'] = [Guid]::NewGuid().ToString()
    return $clean
}

function Find-OrCreateTargetCalendar {
    param(
        [Parameter(Mandatory)][string]$TargetUserId,
        [Parameter(Mandatory)][string]$Name,
        [switch]$IsDefault
    )
    if ($IsDefault) {
        $defaultCal = Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/users/$TargetUserId/calendar"
        return $defaultCal.id
    }
    $escaped = $Name.Replace("'", "''")
    $listUri = "$script:GraphBase/users/$TargetUserId/calendars?`$filter=name eq '$escaped'"
    $resp = Invoke-GraphWithRetry -Method GET -Uri $listUri
    if ($resp.value -and $resp.value.Count -gt 0) { return $resp.value[0].id }
    $created = Invoke-GraphWithRetry -Method POST -Uri "$script:GraphBase/users/$TargetUserId/calendars" -Body @{ name = $Name }
    return $created.id
}

function Copy-CalendarEvents {
    param(
        [Parameter(Mandatory)][string]$SourceUpn,
        [Parameter(Mandatory)][string]$TargetUpn,
        [switch]$IncludeSecondaryCalendars,
        [switch]$AttemptOwnershipReassign
    )

    Write-Step "Transfer calendars: $SourceUpn -> $TargetUpn"
    $logPath = New-OperationLog -OperationName "calendar-$(Get-SafeFileName $SourceUpn)"
    Write-Host "  Log: $logPath" -ForegroundColor DarkGray

    $source = Resolve-MgUser -Upn $SourceUpn
    $target = Resolve-MgUser -Upn $TargetUpn
    if (-not $source -or -not $target) {
        Write-Host "  Aborted: could not resolve one or both users." -ForegroundColor Red
        return
    }
    if ($source.Id -eq $target.Id) {
        Write-Host "  Source and target are the same user." -ForegroundColor Red
        return
    }

    $sourceLocalPart = ($SourceUpn -split '@')[0]
    $transferTag = "m365admin-transferred-$sourceLocalPart"

    # Enumerate calendars.
    if ($IncludeSecondaryCalendars) {
        $sourceCals = Get-AllPaged -Uri "$script:GraphBase/users/$($source.Id)/calendars?`$select=id,name,isDefaultCalendar"
    } else {
        $defCal = Invoke-GraphWithRetry -Method GET -Uri "$script:GraphBase/users/$($source.Id)/calendar"
        $sourceCals = @($defCal)
    }
    Write-Host "  Source calendars to process: $($sourceCals.Count)" -ForegroundColor Gray

    if (-not (Confirm-Action -Prompt "Proceed with copy?")) {
        Write-Host "  Cancelled." -ForegroundColor Yellow
        return
    }

    if ($AttemptOwnershipReassign) {
        Write-Host ""
        Write-Host "  WARNING: ownership reassignment will DELETE future events organized by" -ForegroundColor Yellow
        Write-Host "  $SourceUpn and recreate them on $TargetUpn's calendar." -ForegroundColor Yellow
        Write-Host "  Attendees will receive cancellation emails followed by new invites." -ForegroundColor Yellow
        Write-Host "  Online meetings (Teams) will get NEW join links." -ForegroundColor Yellow
        if (-not (Confirm-Action -Prompt "  Continue with ownership reassignment?")) {
            Write-Host "  Continuing with copy only (no reassignment)." -ForegroundColor Yellow
            $AttemptOwnershipReassign = $false
        }
    }

    $copied = 0
    $skipped = 0
    $reassigned = 0
    $failed = 0
    $nowIso = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    foreach ($cal in $sourceCals) {
        $calName = if ($cal.name) { $cal.name } else { "Calendar" }
        $isDefault = $cal.isDefaultCalendar -eq $true -or ($cal.PSObject.Properties['isDefaultCalendar'] -eq $null)
        Write-Host ""
        Write-Host "  Calendar '$calName'..." -ForegroundColor Cyan

        try {
            $tgtCalId = Find-OrCreateTargetCalendar -TargetUserId $target.Id -Name $calName -IsDefault:$isDefault
        } catch {
            Write-Host "    Failed to find/create target calendar: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-LogLine -LogPath $logPath -Message "TGT CAL FAIL '$calName': $($_.Exception.Message)"
            continue
        }

        $eventsUri = "$script:GraphBase/users/$($source.Id)/calendars/$($cal.id)/events?`$top=100&`$select=id,subject,start,end,body,location,locations,recurrence,attendees,categories,isAllDay,showAs,sensitivity,reminderMinutesBeforeStart,isReminderOn,importance,isOnlineMeeting,onlineMeetingProvider,organizer,type"

        while ($eventsUri) {
            $resp = Invoke-GraphWithRetry -Method GET -Uri $eventsUri
            foreach ($ev in $resp.value) {
                # Skip occurrences; series masters carry the full recurrence definition.
                if ($ev.type -eq 'occurrence' -or $ev.type -eq 'exception') {
                    continue
                }
                # Skip already-transferred events on re-run.
                if ($ev.categories -and ($ev.categories -contains $transferTag)) {
                    $skipped++
                    continue
                }

                $clean = Convert-EventForRecreate -Event $ev
                if (-not $clean.categories) { $clean.categories = @() }
                $clean.categories += $transferTag

                try {
                    $new = Invoke-GraphWithRetry -Method POST -Uri "$script:GraphBase/users/$($target.Id)/calendars/$tgtCalId/events" -Body $clean
                    $copied++
                    Write-LogLine -LogPath $logPath -Message "COPY '$($ev.subject)' src=$($ev.id) tgt=$($new.id)"
                } catch {
                    $failed++
                    Write-LogLine -LogPath $logPath -Message "COPY FAIL '$($ev.subject)': $($_.Exception.Message)"
                    continue
                }

                # Optional: ownership reassignment (delete-and-recreate semantics).
                if ($AttemptOwnershipReassign) {
                    $isFuture = $false
                    try {
                        if ($ev.start -and $ev.start.dateTime) {
                            $isFuture = ([DateTime]::Parse($ev.start.dateTime)).ToUniversalTime() -ge (Get-Date).ToUniversalTime()
                        }
                    } catch { }
                    $isSourceOrganizer = $false
                    try {
                        if ($ev.organizer -and $ev.organizer.emailAddress -and $ev.organizer.emailAddress.address) {
                            $isSourceOrganizer = $ev.organizer.emailAddress.address -ieq $SourceUpn
                        }
                    } catch { }

                    if ($isFuture -and $isSourceOrganizer) {
                        try {
                            Invoke-GraphWithRetry -Method DELETE -Uri "$script:GraphBase/users/$($source.Id)/events/$($ev.id)" | Out-Null
                            $reassigned++
                            Write-LogLine -LogPath $logPath -Message "REASSIGN delete src=$($ev.id)"
                        } catch {
                            Write-LogLine -LogPath $logPath -Message "REASSIGN delete FAIL src=$($ev.id): $($_.Exception.Message)"
                        }
                    }
                }
            }
            $eventsUri = $resp.'@odata.nextLink'
        }
    }

    Write-Host ""
    Write-Host "  Done: $copied copied, $skipped already-transferred, $failed failed." -ForegroundColor Green
    if ($AttemptOwnershipReassign) {
        Write-Host "  Reassigned (source events deleted): $reassigned" -ForegroundColor Green
    }
    Write-LogLine -LogPath $logPath -Message "DONE copied=$copied skipped=$skipped failed=$failed reassigned=$reassigned"
}
