# SaaS Admin (saasadmin)
A PowerShell launcher and menu for common **Google Workspace** (driven by [GAM](https://github.com/GAM-team/GAM/)) and **Microsoft 365** (driven by Microsoft Graph) administration tasks, from a single entry point. The Google Workspace side is designed around offboarding-style operations: moving a user's Drive content into a Shared Drive and then cleaning up access delegation, renaming an offboarded user and automatically routing their historical email into a freshly configured Google Group, transferring calendars and event-organizer rights to another account, and managing mailbox delegation. The Microsoft 365 side covers message copies into shared mailboxes, OneDrive migrations into a new SharePoint site, calendar transfers, and SharePoint folder-size reporting.

<!-- buttons -->
[![Stars](https://img.shields.io/github/stars/ivancarlosti/gwadmin?label=⭐%20Stars&color=gold&style=flat)](https://github.com/ivancarlosti/gwadmin/stargazers)
[![Watchers](https://img.shields.io/github/watchers/ivancarlosti/gwadmin?label=Watchers&style=flat&color=red)](https://github.com/sponsors/ivancarlosti)
[![Forks](https://img.shields.io/github/forks/ivancarlosti/gwadmin?label=Forks&style=flat&color=ff69b4)](https://github.com/sponsors/ivancarlosti)
[![Downloads](https://img.shields.io/github/downloads/ivancarlosti/gwadmin/total?label=Downloads&color=success)](https://github.com/ivancarlosti/gwadmin/releases)
[![GitHub commit activity](https://img.shields.io/github/commit-activity/m/ivancarlosti/gwadmin?label=Activity)](https://github.com/ivancarlosti/gwadmin/pulse)
[![GitHub Issues](https://img.shields.io/github/issues/ivancarlosti/gwadmin?label=Issues&color=orange)](https://github.com/ivancarlosti/gwadmin/issues)  
[![License](https://img.shields.io/github/license/ivancarlosti/gwadmin?label=License)](LICENSE)
[![GitHub last commit](https://img.shields.io/github/last-commit/ivancarlosti/gwadmin?label=Last%20Commit)](https://github.com/ivancarlosti/gwadmin/commits)
[![Security](https://img.shields.io/badge/Security-View%20Here-purple)](https://github.com/ivancarlosti/gwadmin/security)
[![Code of Conduct](https://img.shields.io/badge/Code%20of%20Conduct-2.1-4baaaa)](https://github.com/ivancarlosti/gwadmin?tab=coc-ov-file)
<!-- endbuttons -->

## Menus

`launcher.bat` elevates itself when needed and starts `saasadmin.ps1`, which shows a platform menu:

```
1. Google Workspace (GAM)
2. Microsoft 365 (Microsoft Graph)
3. Install / update Microsoft Graph modules (requires elevation)
0. Exit
```

Both sub-menus return to this platform menu, so you can move between Google Workspace and Microsoft 365 without restarting the tool. Option 3 installs or updates the Microsoft Graph PowerShell modules; when the session is not elevated it re-launches `launcher.bat` so you get the usual UAC prompt.

## Google Workspace features (GAM)

The Google Workspace menu validates the admin account, the source mailbox, and (where applicable) the target before running its GAM command.

1. **Move Drive content to a new Shared Drive (create automatically)** — A clean transfer of a user's entire My Drive into a freshly created Shared Drive, with automatic permission cleanup so no unwanted users remain as organizers:

   * Creates a new Shared Drive named `Migrated from <source> - <datetime>` (timestamped for traceability).
   * Prompts for an optional target administrator to assign as organizer on the new Shared Drive.
   * Grants the source user temporary organizer access to enable the file move.
   * Transfers all My Drive content (root) from the source user into the Shared Drive using `mergewithparent`.
   * Waits 30 seconds for file operations to settle before modifying permissions.
   * **Removes the source user's organizer permission** from the Shared Drive.
   * **Removes the admin (GW Admin) user's organizer permission** that Google automatically assigns to the Shared Drive creator — leaving only the explicitly specified target administrator (if any) as organizer.

   ```
   gam user <admin> create teamdrive "Migrated from <source> - <datetime>"
   gam user <admin> add drivefileacl <sdid> user <target-admin> role organizer   (if provided)
   gam user <admin> add drivefileacl <sdid> user <source> role organizer
   gam user <source> move drivefile root teamdriveparentid <sdid> mergewithparent
   (pause 30s for operations to settle)
   gam user <admin> del drivefileacl <sdid> <source>
   gam user <admin> del drivefileacl <sdid> <admin>
   ```

2. **Move Drive content to an existing Shared Drive (choose from list)** — Transfers a user's entire My Drive into a Shared Drive that already exists, selected from a numbered list:

   * Lists every Shared Drive in the domain and asks for the number of the destination.
   * Grants the source user temporary organizer access to enable the file move.
   * Transfers all My Drive content (root) from the source user into the chosen Shared Drive using `mergewithparent`.
   * Waits 30 seconds for file operations to settle.
   * **Removes only the source user's organizer permission** — existing permissions (including the admin's) are left untouched.

   ```
   gam redirect csv <tempfile> print teamdrives fields id,name
   gam user <admin> add drivefileacl <sdid> user <source> role organizer
   gam user <source> move drivefile root teamdriveparentid <sdid> mergewithparent
   (pause 30s for operations to settle)
   gam user <admin> del drivefileacl <sdid> <source>
   ```

3. **Automate User to Group Redirection & Archive (creates a new group)** — A multi-step offboarding pipeline that transitions a user's address into a collaborative archive group:

   * Renames the primary user to `<username>-old@<domain>`.
   * Waits for directory processing and safely deletes the automatically generated email alias.
   * Creates a Mailing group named `redir_<username>` using the user's original email address.
   * Optionally assigns a specified manager as the Group Owner.
   * Configures Mailing group policies: external posting allowed, invite-only joining, members-only visibility, and **`allow_external_members` set to `false`** (no external members permitted).
   * Archives every historical message from the newly-renamed user mailbox into the newly-created group.

   ```
   gam update user <source> email <source>-old@<domain>
   gam delete alias <source>
   gam create group <source> name redir_<username>
   gam update group <source> owner <owner-address>                                    (optional)
   gam update group <source> who_can_contact_owner anyone_can_contact who_can_view_group all_members_can_view who_can_post_message anyone_can_post who_can_view_membership all_members_can_view who_can_join invited_can_join allow_external_members false
   gam user <source>-old@<domain> archive messages <source> max_to_archive 0 doit
   ```

4. **Copy user mailbox to an existing Group (choose from list)** — Archives every historical message from a user's mailbox into a group that already exists, without renaming the user or touching aliases:

   * Prompts for the source mailbox address.
   * Lists every group in the domain and asks for the number of the destination group.
   * Archives all messages from the source mailbox into the selected group.

   ```
   gam redirect csv <tempfile> print groups fields email,name
   gam user <source> archive messages <group> max_to_archive 0 doit
   ```

5. **Transfer calendars to another account** — A two-phase process that moves calendar ownership from a departing user to a target user, including a workaround for Google's primary-calendar transfer limitation:

   * **Phase A — Secondary calendars:** Transfers all secondary (non-primary) calendars owned by the source user to the target user in a single GAM command. Ownership, events, and sharing settings are all moved.
   * **Phase B — Primary calendar events:** Since Google does not allow transferring a user's primary calendar itself, the script instead:
     * Lists all future events on the source user's primary calendar (from the current date/time onward).
     * Filters events where the source user is the organizer.
     * Reassigns the organizer of each matching future event to the target user via `newowner`.
   * After completion, the target user can cancel any of those events and Google will send proper cancellation notices to invitees, even if the source user is later deleted.

   ```
   gam user <source> transfer calendars <target>
   gam user <source> print events <source> primary timemin <today> fields id,organizer
   gam user <source> update event <event-id> calendar primary newowner <target>
   ```

6. **List / add / remove mailbox delegation** — An interactive sub-menu for managing who has delegated access to a mailbox. Before proceeding, the script checks that Gmail mail delegation is enabled in the Google Workspace admin policies and warns if it is not.

   * **List Delegates** — shows all users/groups who currently have delegated access to the mailbox.
   * **Add Delegates** — grants a specified user or group delegated access to the mailbox.
   * **Remove Delegates** — revokes delegated access from a specified user or group.
   * **Back to main menu** — returns to the main feature menu.

   ```
   gam user <source> show delegates
   gam user <source> add delegates <delegate>
   gam user <source> del delegates <delegate>
   ```

7. **Change GAM project** — re-select which GAM multi-project profile to use.
8. **Back to the main menu** — returns to the platform menu (Google Workspace / Microsoft 365).

## Microsoft 365 features (Microsoft Graph)

The Microsoft 365 menu connects to a tenant listed in `m365tenant.txt` and exposes:

1. **Copy mailbox messages to a shared mailbox** — Copies all messages from all folders of a source mailbox into a target shared mailbox, preserving folder structure. Source is not modified. Re-runs dedupe by `internetMessageId`.
2. **Copy OneDrive content to a new SharePoint site** — Provisions a new Microsoft 365 group (which creates a SharePoint site), waits for it to come online, then copies the source user's entire OneDrive into the group's document library. The source OneDrive is not modified.
3. **Transfer calendars to another account** — Copies all events (and optionally secondary calendars) from a source user to a target user. Optional ownership reassignment for future events organized by the source — see the limitations below.
4. **Export SharePoint site folder sizes to a CSV report** — Walks the folders of a SharePoint document library and writes a CSV with the size of each folder (see below).
5. **Switch tenant** — disconnects and lets you pick another tenant from `m365tenant.txt`.
6. **Back to the main menu**.

Every operation writes a log to `Downloads\m365admin-logs\`.

### SharePoint folder size report

Option 4 asks for the site (paste the site URL, or search by name), for the document library (only when the site has more than one), and for how many folder levels the report should cover:

A pasted URL is resolved by matching the site's `webUrl` from a name search, then by a Graph path lookup; if neither works you get a readable reason (for example `HTTP 404: ...`) and the list of sites found by name, so you can pick it manually.

| Value | What is walked | What you get |
|---|---|---|
| `1` | Root and level 1 folders | The library's direct child folders, each with the size of the files directly inside it |
| `2` (default) | Root plus levels 1 and 2 | Levels 1 and 2, where a level 1 size includes the level 2 folders below it |
| `0` | Everything | Fully recursive sizes for every folder (slowest) |

Folders deeper than the selected level are counted in their parent's `SubFolders` column but are not listed, and their content is not counted in any size.

The report is written to `Downloads\m365admin-reports\sharepoint-folders-<site>-<timestamp>.csv` with these columns:

| Column | Meaning |
|---|---|
| `Level` | `0` for the library root, `1` for its direct child folders, and so on |
| `Folder` | Folder name |
| `Path` | Full path inside the library (for example `Documents / Alpha / Alpha1`) |
| `SubFolders` | Number of direct subfolders seen inside that folder |
| `DirectFiles` / `DirectSizeBytes` / `DirectSizeMB` | Files directly inside the folder and their total size |
| `TotalFiles` / `TotalSizeBytes` / `TotalSizeMB` | Files directly inside the folder plus those of the listed subfolders below it |

A depth of `0` walks the entire tree, so it can take a long time on large libraries. Progress is printed every 25 folders, and any folder that cannot be listed is recorded in the log and skipped instead of aborting the whole report.

### Known limitations (Microsoft 365)

* **Mailbox copy**: Microsoft Graph does not support cross-mailbox copy actions, so messages are exported as MIME from the source and re-imported on the target. Headers, attachments and `internetMessageId` are preserved; `isRead` and `categories` are re-applied with a follow-up PATCH.
* **OneDrive copy**: file version history is not preserved (only the current version is copied). OneNote (`.one`) notebooks and files over 250 GB are skipped with a warning.
* **Calendar ownership reassignment**: Microsoft Graph treats `event.organizer` as immutable — there is no Graph equivalent of Google's calendar-transfer API. The opt-in reassignment is implemented as **delete-and-recreate** for future events where the source is the organizer, which sends cancellation emails followed by new invites to all attendees and regenerates any Teams meeting links. This is a Microsoft platform limitation. The feature is opt-in and requires an explicit confirmation prompt.

## Configuration

Set the variables at the top of `saasadmin.ps1` if your install differs from the defaults:

   ```
   $GAMpath = "C:\GAM7"
   $gamsettings = "$env:USERPROFILE\.gam"
   $destinationpath = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
   ```

`$GAMpath` — the GAM application folder.
`$gamsettings` — the GAM multi-project settings folder.
`$destinationpath` — where local output ends up (`Downloads\m365admin-logs\` for logs and `Downloads\m365admin-reports\` for CSV reports; the Google Workspace side uses it only for temp files).

### `m365tenant.txt`

Microsoft 365 tenants to connect to, one per line. The file is read from the repository folder regardless of the current directory:

   ```
   tenantID01.onmicrosoft.com
   tenantID02.onmicrosoft.com
   ```

### `gwemail.txt`

Google Workspace admin accounts, one email address per line (lines starting with `#` are ignored):

   ```
   # one admin account per domain
   gwsadmin@example.com
   gwsadmin@contoso.com
   ```

When you select a GAM project, the script reads that project's primary domain with GAM and uses the account from this file whose domain matches, so you do not have to type the admin account for every operation. If nothing matches — or the file is missing, or the domain cannot be determined — you are prompted for the admin account exactly as before. Either way the account is then validated with `gam info user` and `gam user <admin> check serviceaccount`.

## Instructions
* Download the latest release and extract it locally ([releases](../../releases/latest)).
* Adjust the variables in `saasadmin.ps1` if needed.
* Fill in `m365tenant.txt` (Microsoft 365 tenants) and `gwemail.txt` (Google Workspace admin accounts).
* Run `launcher.bat` (right-click → Run as administrator). It elevates itself through UAC and then runs `saasadmin.ps1` with the execution policy bypassed, so you don't need to deal with PowerShell restrictions manually.
* Pick a platform, then pick an option and follow the prompts.
* Microsoft Graph modules missing or outdated? Use option 3 in the platform menu (it re-launches `launcher.bat` to elevate).

## Requirements
* Windows 10+ or Windows Server 2019+
* [GAM](https://github.com/GAM-team/GAM/) installed and configured for multi-project use
* PowerShell 5.1 or later
* PowerShell modules (installed or updated with option 3 of the platform menu, or by running `ADMIN-install-modules.ps1` as Administrator):
  * `Microsoft.Graph.Authentication`
  * `Microsoft.Graph.Users`
  * `Microsoft.Graph.Groups`
  * `Microsoft.Graph.Mail`
  * `Microsoft.Graph.Files`
  * `Microsoft.Graph.Sites`
  * `Microsoft.Graph.Calendar`
  * `Microsoft.Graph.Identity.DirectoryManagement`

## Required Microsoft Graph scopes

Requested when connecting to a tenant; all require admin consent:

```
User.Read.All Group.ReadWrite.All Directory.Read.All
Mail.ReadWrite Mail.ReadWrite.Shared MailboxSettings.Read
Files.ReadWrite.All Sites.ReadWrite.All
Calendars.ReadWrite Calendars.ReadWrite.Shared
```

For the mailbox copy operation, the signed-in admin must have FullAccess on the target shared mailbox.

## Repository layout

```
launcher.bat                             Elevation + single entry point
saasadmin.ps1                            Platform menu, configuration, module bootstrap
gwemail.txt                              Google Workspace admin accounts (per domain)
m365tenant.txt                           Microsoft 365 tenants
ADMIN-install-modules.ps1                Installs/updates the Microsoft Graph modules (elevated)
POWERSHELL_ISSUE.md                      How to fix "running scripts is disabled" errors
lib/GoogleWorkspace.ps1                  Google Workspace (GAM) features and menu
lib/M365/M365Menu.ps1                    Microsoft 365 menu and connection handling
lib/M365/Common.ps1                      Shared Graph helpers, logging, configuration paths
lib/M365/Mailbox-CopyToShared.ps1        Mailbox copy
lib/M365/OneDrive-CopyToSharePoint.ps1   OneDrive to SharePoint copy
lib/M365/Calendar-Transfer.ps1           Calendar transfer
lib/M365/SharePoint-FolderSizes.ps1      SharePoint folder size CSV report
```


<!-- footer -->
---

## 🧑‍💻 Consulting and technical support
* For personal support and queries, please submit a new issue to have it addressed.
* For commercial related questions, please [**contact me**][ivancarlos] for consulting costs.

[cc]: https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/adding-a-code-of-conduct-to-your-project
[contributing]: https://docs.github.com/en/articles/setting-guidelines-for-repository-contributors
[security]: https://docs.github.com/en/code-security/getting-started/adding-a-security-policy-to-your-repository
[support]: https://docs.github.com/en/articles/adding-support-resources-to-your-project
[it]: https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/configuring-issue-templates-for-your-repository#configuring-the-template-chooser
[prt]: https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/creating-a-pull-request-template-for-your-repository
[funding]: https://docs.github.com/en/articles/displaying-a-sponsor-button-in-your-repository
[ivancarlos]: https://ivancarlos.me
