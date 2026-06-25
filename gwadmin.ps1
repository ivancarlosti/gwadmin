## Google Workspace admin script (gwadmin)

# Set variables
$GAMpath = "C:\GAM7"
$gamsettings = "$env:USERPROFILE\.gam"
$destinationpath = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
$datetime = Get-Date -f yyyy-MM-dd-HH-mm-ss

[console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ------------------------------------------------------------------
# Shared helpers
# ------------------------------------------------------------------

function pause { $null = Read-Host 'Press ENTER key to continue' }

function Get-CurrentDateString {
    $currentdate = Get-Date
    $culture = [System.Globalization.CultureInfo]::GetCultureInfo("en-US")
    return $currentdate.ToString("dddd, dd MMMM yyyy HH:mm:ss", $culture)
}

function Show-FeatureHeader {
    param([string]$title)
    cls
    Write-Host "### $title ###"
    Write-Host
    Write-Host "GAM project selected: $clientName"
    Write-Host "Admin account:        $adminAddress"
    Write-Host "GAM application path: $GAMpath"
    Write-Host "Project path:         $gamsettings"
    Write-Host "Date and time:        $datetime"
    Write-Host
}

function Show-FeatureFooter {
    param([string]$title)
    Write-Host
    Write-Host "### $title COMPLETED ###"
    Write-Host
    Write-Host "Project used by GAM: $clientName"
    Write-Host "Actual date and time: $(Get-CurrentDateString)"
    Write-Host
    pause
}

function Check-AdminAddress {
    param([string]$adminAddress)
    $output = & "$GAMpath\gam.exe" info user $adminAddress 2>&1
    if ($output -match "Does not exist" -or $output -match "Show Info Failed" -or $output -match "ERROR" -or $output -match "Super Admin: False") {
        return $false
    }
    return $true
}

function Check-AdminAuth {
    param([string]$adminAddress)
    $output = & "$GAMpath\gam.exe" user $adminAddress check serviceaccount 2>&1
    if ($output -match "Some scopes failed") {
        return $false
    }
    return $true
}

function Check-EmailAddress {
    param([string]$emailAddress)
    $output = & "$GAMpath\gam.exe" info user $emailAddress 2>&1
    if ($output -match "Does not exist" -or $output -match "Show Info Failed" -or $output -match "ERROR") {
        return $false
    }
    return $true
}

function Check-GroupAddress {
    param([string]$groupAddress)
    $output = & "$GAMpath\gam.exe" info group $groupAddress 2>&1
    if ($output -match "Does not exist" -or $output -match "Show Info Failed" -or $output -match "ERROR") {
        return $false
    }
    return $true
}

function Check-PolicySettings {
    param([string]$filter)
    $output = & "$GAMpath\gam.exe" print policies filter "$filter" 2>&1
    if ($output -match "False,True,ADMIN" -or $output -match "False,False,ADMIN" -or $output -match "Got 0 Policies" -or $output -match "insufficient") {
        Write-Host "WARNING: You can proceed but policies unreachable or mailbox delegation disabled."
        Write-Host "Users may not be able to access the delegated mailbox."
        Write-Host "Please check it in https://admin.google.com/ac/apps/gmail/usersettings"
        Write-Host
        return $false
    }
    Write-Host "Mailbox delegation is enabled, you are good to go."
    Write-Host
    return $true
}

function Prompt-Admin {
    while ($true) {
        $addr = Read-Host "Please enter the admin account"
        if ([string]::IsNullOrWhiteSpace($addr)) { continue }
        if (Check-AdminAddress -adminAddress $addr) {
            while (-not (Check-AdminAuth -adminAddress $addr)) {
                Write-Host "The admin account $addr does not have proper authorization, we will run the command again to let you authorize it:"
                & "$GAMpath\gam.exe" user $addr check serviceaccount
            }
            return $addr
        }
        Write-Host "The admin account $addr does not exist, is not a Super Admin, or we have an ERROR. Please check credentials and try again."
    }
}

function Prompt-User {
    param([string]$promptText)
    while ($true) {
        $addr = Read-Host $promptText
        if ([string]::IsNullOrWhiteSpace($addr)) { continue }
        if (Check-EmailAddress -emailAddress $addr) { return $addr }
        Write-Host "The mailbox $addr does not exist, it's a group, or we have an ERROR. Please check and try again."
    }
}

function Prompt-Group {
    param([string]$promptText)
    while ($true) {
        $addr = Read-Host $promptText
        if ([string]::IsNullOrWhiteSpace($addr)) { continue }
        if (Check-GroupAddress -groupAddress $addr) { return $addr }
        Write-Host "The group $addr does not exist, it's a user mailbox, or we have an ERROR. Please check and try again."
    }
}

# ------------------------------------------------------------------
# Project selection
# ------------------------------------------------------------------

function Select-GAMProject {
    cls
    $directories = Get-ChildItem -Path $gamsettings -Directory -Exclude "gamcache" | Select-Object -ExpandProperty Name

    Write-Host "Projects available:"
    for ($i = 0; $i -lt $directories.Count; $i++) {
        Write-Host "$($i + 1). $($directories[$i])"
    }
    Write-Host

    $selectedProject = $null
    while (-not $selectedProject) {
        $selection = Read-Host "Please enter project number"

        [int]$parsedSelection = 0
        if ([int]::TryParse($selection, [ref]$parsedSelection) -and
            $parsedSelection -ge 1 -and
            $parsedSelection -le $directories.Count) {

            $chosenProject = $directories[$parsedSelection - 1]

            if ((& "$GAMpath\gam.exe" select $chosenProject 2>&1) -match "ERROR") {
                Write-Host "Selected project '$chosenProject' is invalid. Please try again."
            } else {
                $selectedProject = $chosenProject
            }
        } else {
            Write-Host "Invalid selection. Please enter a number between 1 and $($directories.Count)."
        }
    }

    & "$GAMpath\gam.exe" select $selectedProject save
    $global:clientName = $selectedProject
    $global:adminAddress = $null
    Write-Host "GAM project selected: $selectedProject"
}

# ------------------------------------------------------------------
# Feature 1: Move Drive content to a new Shared Drive
# ------------------------------------------------------------------

function Invoke-CopyMessagesToGroup {
    Show-FeatureHeader "USER TO GROUP REDIRECTION AND ARCHIVE"

    $sourceAddress = Prompt-User "Please enter the user's current mailbox address"

    # Break down the email to form the new -old address and the group name
    $parts = $sourceAddress -split "@"
    $username = $parts[0]
    $domain = $parts[1]
    
    $newAddress = "$username-old@$domain"
    $groupName = "redir_$username"

    # Step 1: Rename the user
    Write-Host "`n[1/6] Renaming user account to $newAddress..."
    & "$GAMpath\gam.exe" update user $sourceAddress email $newAddress

    # Step 2: Pause to let Google Workspace generate the automatic alias
    Write-Host "`n[2/6] Pausing for 30 seconds to allow Google Workspace to generate the automatic alias..."
    Start-Sleep -Seconds 30

    # Step 3: Remove the automatic alias that Google created upon renaming
    Write-Host "`n[3/6] Deleting the leftover alias for $sourceAddress..."
    & "$GAMpath\gam.exe" delete alias $sourceAddress

    # Step 3b: Short buffer pause to ensure the alias is fully purged from the directory cache
    Write-Host "Pausing 10 seconds for directory synchronization before group creation..."
    Start-Sleep -Seconds 10

    # Step 4: Create the new group using the original email
    Write-Host "`n[4/6] Creating routing group '$groupName' at $sourceAddress..."
    & "$GAMpath\gam.exe" create group $sourceAddress name $groupName

    # Step 4b: Pause to let Google Workspace fully propagate the new group before use
    Write-Host "Pausing 30 seconds for group propagation before configuring and archiving..."
    Start-Sleep -Seconds 30

    # Step 5: Optional Owner Assignment
    Write-Host "`n[5/6] Assigning permissions and settings..."
    $addOwner = Read-Host "Do you want to add an owner to this new group? (y/N)"
    if ($addOwner -match "^[yY]") {
        $ownerAddress = Read-Host "Please enter the owner's mailbox address"
        if (-not [string]::IsNullOrWhiteSpace($ownerAddress)) {
            Write-Host "Adding $ownerAddress as owner..."
            & "$GAMpath\gam.exe" update group $sourceAddress add owner $ownerAddress
        }
    }

    # Step 5b: Apply the Group Settings based on the image provided
    Write-Host "Applying group policies (External posting allowed, Invite only, Members view only)..."
    & "$GAMpath\gam.exe" update group $sourceAddress `
        who_can_contact_owner anyone_can_contact `
        who_can_view_group all_members_can_view `
        who_can_post_message anyone_can_post `
        who_can_view_membership all_members_can_view `
        who_can_join invited_can_join `
        allow_external_members false

    # Step 6: Archive messages from the renamed account to the newly created group
    Write-Host "`n[6/6] Archiving messages from $newAddress into $sourceAddress..."
    Write-Host "Command running: gam user $newAddress archive messages $sourceAddress max_to_archive 0 doit"
    & "$GAMpath\gam.exe" user $newAddress archive messages $sourceAddress max_to_archive 0 doit

    Show-FeatureFooter "USER TO GROUP REDIRECTION AND ARCHIVE"
}

# ------------------------------------------------------------------
# Feature 2: Automate User to Group Redirection & Archive
# ------------------------------------------------------------------

function Invoke-MoveDriveToSharedDrive {
    Show-FeatureHeader "MOVE DRIVE CONTENT TO A NEW SHARED DRIVE"

    $sourceAddress = Prompt-User "Please enter the source mailbox address (Drive owner)"

    $sharedDriveName = "Migrated from $sourceAddress - $datetime"

    Write-Host
    Write-Host "Creating Shared Drive: $sharedDriveName"
    $createOutput = & "$GAMpath\gam.exe" user $adminAddress create teamdrive $sharedDriveName 2>&1
    $createOutput | ForEach-Object { Write-Host $_ }

    $sdid = $null
    foreach ($line in $createOutput) {
        if ($line -match "id:\s*([A-Za-z0-9_\-]+)") {
            $sdid = $Matches[1]
            break
        }
    }

    if (-not $sdid) {
        Write-Host
        Write-Host "Could not parse the new Shared Drive ID from the create command output."
        Write-Host "Please copy the ID from above and paste it here to continue."
        $sdid = Read-Host "Shared Drive ID"
    }

    Write-Host
    Write-Host "New Shared Drive ID: $sdid"

    # Ask for target administrator email for the new Shared Drive
    $targetAdmin = Read-Host "Please enter the target administrator email for the new Shared Drive (leave blank to skip)"
    if (-not [string]::IsNullOrWhiteSpace($targetAdmin)) {
        Write-Host "Adding $targetAdmin as organizer on the Shared Drive..."
        & "$GAMpath\gam.exe" user $adminAddress add drivefileacl $sdid user $targetAdmin role organizer
    }

    Write-Host
    Write-Host "Granting source user organizer access on the Shared Drive..."
    & "$GAMpath\gam.exe" user $adminAddress add drivefileacl $sdid user $sourceAddress role organizer

    Write-Host
    Write-Host "Running: gam user $sourceAddress move drivefile root teamdriveparentid $sdid mergewithparent"
    & "$GAMpath\gam.exe" user $sourceAddress move drivefile root teamdriveparentid $sdid mergewithparent

    Write-Host
    Write-Host "Drive content moved into Shared Drive '$sharedDriveName' (ID: $sdid)."

    # Pause to let file operations settle before modifying permissions
    Write-Host "Pausing 30 seconds for file operations to settle before modifying permissions..."
    Start-Sleep -Seconds 30

    Write-Host
    Write-Host "Removing source user's organizer permission from the Shared Drive..."
    & "$GAMpath\gam.exe" user $adminAddress del drivefileacl $sdid user $sourceAddress

    Write-Host
    Write-Host "Removing admin user's organizer permission from the Shared Drive..."
    & "$GAMpath\gam.exe" user $adminAddress del drivefileacl $sdid user $adminAddress

    Show-FeatureFooter "MOVE DRIVE CONTENT TO A NEW SHARED DRIVE"
}

# ------------------------------------------------------------------
# Feature 3: Transfer calendars to another account
# ------------------------------------------------------------------

function Invoke-TransferCalendars {
    Show-FeatureHeader "TRANSFER CALENDARS TO ANOTHER ACCOUNT"

    $sourceAddress = Prompt-User "Please enter the source mailbox address"
    $targetAddress = Prompt-User "Please enter the target mailbox address"

    Write-Host
    Write-Host "Phase A: transferring secondary calendars owned by $sourceAddress to $targetAddress"
    Write-Host "Running: gam user $sourceAddress transfer calendars $targetAddress"
    & "$GAMpath\gam.exe" user $sourceAddress transfer calendars $targetAddress

    Write-Host
    Write-Host "Phase B: reassigning organizer of future primary-calendar events to $targetAddress"
    $today = Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"
    $eventsCsv = Join-Path $env:TEMP "gwadmin-events-$datetime.csv"

    Write-Host "Listing future events on $sourceAddress's primary calendar..."
    & "$GAMpath\gam.exe" redirect csv $eventsCsv user $sourceAddress print events $sourceAddress primary timemin $today fields id,organizer

    if (Test-Path $eventsCsv) {
        $events = Import-Csv $eventsCsv
        $count = 0
        foreach ($evt in $events) {
            $eventId = $evt.id
            if ([string]::IsNullOrWhiteSpace($eventId)) { continue }
            $organizer = $evt.'organizer.email'
            if ($organizer -and ($organizer -ne $sourceAddress)) { continue }
            Write-Host "Reassigning event $eventId organizer -> $targetAddress"
            & "$GAMpath\gam.exe" user $sourceAddress update event $eventId calendar primary newowner $targetAddress
            $count++
        }
        Write-Host
        Write-Host "Reassigned $count future primary-calendar event(s) to $targetAddress."
        Remove-Item $eventsCsv -ErrorAction SilentlyContinue
    } else {
        Write-Host "No events CSV produced; primary-calendar event reassignment skipped."
    }

    Write-Host
    Write-Host "Note: the source user's primary calendar itself cannot be transferred (Google limitation)."
    Write-Host "Future events on it now show $targetAddress as organizer, so $targetAddress can cancel them"
    Write-Host "and notify invitees even after $sourceAddress is deleted."

    Show-FeatureFooter "TRANSFER CALENDARS TO ANOTHER ACCOUNT"
}

# ------------------------------------------------------------------
# Feature 4: Mailbox delegation
# ------------------------------------------------------------------

function Invoke-MailboxDelegation {
    Show-FeatureHeader "MANAGE MAILBOX DELEGATION"

    $filter = "setting.type.matches('.*gmail.mail_delegation')"
    [void](Check-PolicySettings -filter $filter)

    $sourceAddress = Prompt-User "Please enter the mailbox address"

    while ($true) {
        Write-Host
        Write-Host "Select an option:"
        Write-Host "1. List Delegates"
        Write-Host "2. Add Delegates"
        Write-Host "3. Remove Delegates"
        Write-Host "4. Back to main menu"
        Write-Host

        $choice = Read-Host "Enter your choice"

        switch ($choice) {
            '1' {
                & "$GAMpath\gam.exe" user $sourceAddress show delegates
            }
            '2' {
                $delegatedAddress = Read-Host "Please enter the mailbox or group to enable access to $sourceAddress's mailbox"
                & "$GAMpath\gam.exe" user $sourceAddress add delegates $delegatedAddress
            }
            '3' {
                $delegatedAddress = Read-Host "Please enter the mailbox or group to remove access to $sourceAddress's mailbox"
                & "$GAMpath\gam.exe" user $sourceAddress del delegates $delegatedAddress
            }
            '4' { break }
            default { Write-Host "Invalid option, please try again." }
        }

        if ($choice -eq '4') { break }
    }

    Show-FeatureFooter "MANAGE MAILBOX DELEGATION"
}

# ------------------------------------------------------------------
# Main menu
# ------------------------------------------------------------------

function Show-Menu {
    cls
    Write-Host "GAM project selected: $clientName"
    Write-Host "Admin account:        $adminAddress"
    Write-Host
    Write-Host "Please choose an option:"
    Write-Host "1. Move Drive content to a new Shared Drive"
    Write-Host "2. Automate User to Group Redirection & Archive"
    Write-Host "3. Transfer calendars to another account"
    Write-Host "4. List, add or remove mailbox delegation"
    Write-Host "5. Change GAM project"
    Write-Host "6. Exit script"
    return (Read-Host -Prompt "Enter your choice")
}

while ($true) {
    if (-not $clientName) {
        Select-GAMProject
    }

    if (-not $adminAddress) {
        cls
        Write-Host "GAM project selected: $clientName"
        Write-Host
        Write-Host "Please provide the admin account that will be used for the operations."
        Write-Host "It will be reused for every option until you change the GAM project."
        Write-Host
        $global:adminAddress = Prompt-Admin
    }

    $option = Show-Menu

    try {
        switch ($option) {
            '1' { Invoke-MoveDriveToSharedDrive }
            '2' { Invoke-CopyMessagesToGroup }
            '3' { Invoke-TransferCalendars }
            '4' { Invoke-MailboxDelegation }
            '5' { Select-GAMProject }
            '6' {
                Write-Output "Exiting script."
                break
            }
            default { Write-Output "Invalid option selected." }
        }
    }
    catch {
        Write-Host "An error occurred: $_"
    }

    if ($option -eq '6') { break }
}
