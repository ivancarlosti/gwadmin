# Google Workspace admin script (gwadmin)
A PowerShell launcher for common Google Workspace administration tasks driven by [GAM](https://github.com/GAM-team/GAM/). Designed around offboarding-style operations: moving a user's Drive content into a Shared Drive and then cleaning up access delegation, renaming an offboarded user and automatically routing their historical email into a freshly configured Google Group, transferring calendars and event-organizer rights to another account, and managing mailbox delegation.

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

## Features

The launcher exposes a numbered menu. Each item validates the admin account, the source mailbox, and (where applicable) the target before running its GAM command.

1. **Move Drive content to a new Shared Drive** — A clean transfer of a user's entire My Drive into a freshly created Shared Drive, with automatic permission cleanup so no unwanted users remain as organizers:

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
   gam user <admin> del drivefileacl <sdid> user <source>
   gam user <admin> del drivefileacl <sdid> user <admin>
   ```

2. **Automate User to Group Redirection & Archive** — A multi-step offboarding pipeline that transitions a user's address into a collaborative archive group:

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

3. **Transfer calendars to another account** — A two-phase process that moves calendar ownership from a departing user to a target user, including a workaround for Google's primary-calendar transfer limitation:

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

4. **List / add / remove mailbox delegation** — An interactive sub-menu for managing who has delegated access to a mailbox. Before proceeding, the script checks that Gmail mail delegation is enabled in the Google Workspace admin policies and warns if it is not.

   * **List Delegates** — shows all users/groups who currently have delegated access to the mailbox.
   * **Add Delegates** — grants a specified user or group delegated access to the mailbox.
   * **Remove Delegates** — revokes delegated access from a specified user or group.
   * **Back to main menu** — returns to the main feature menu.

   ```
   gam user <source> show delegates
   gam user <source> add delegates <delegate>
   gam user <source> del delegates <delegate>
   ```

5. **Change GAM project** — re-select which GAM multi-project profile to use.
6. **Exit script**.

## Configuration

Set variables at the top of `gwadmin.ps1` if your install differs from the defaults:

   ```
   $GAMpath = "C:\GAM7"
   $gamsettings = "$env:USERPROFILE\.gam"
   $destinationpath = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
   ```

`$GAMpath` — the GAM application folder.
`$gamsettings` — the GAM multi-project settings folder.
`$destinationpath` — where any local output ends up (currently used only for temp files).
Check `testing-guideline.md` as a suggested testing checklist.

## Instructions
* Download the latest release and extract it locally ([releases](https://github.com/ivancarlosti/gwadmin/releases/latest)).
* Adjust the variables in `gwadmin.ps1` if needed.
* Run `gwadmin.ps1` from PowerShell (right-click → Run with PowerShell, or `powershell -ExecutionPolicy Bypass -File .\gwadmin.ps1`).
* Pick a GAM project, then choose a menu option and follow the prompts.

If PowerShell blocks the script with "Running scripts is disabled on this system", see `POWERSHELL_ISSUE.md`.

## Requirements
* Windows 10+ or Windows Server 2019+
* [GAM](https://github.com/GAM-team/GAM/) installed and configured for multi-project use
* PowerShell 5.1 or later


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
