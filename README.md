# M365 & Intune Admin Toolkit

PowerShell scripts and lab notes for everyday **Microsoft Intune** and **Microsoft Entra ID** administration, built on the **Microsoft Graph PowerShell SDK**.

I work as an on-site IT specialist (2nd level support and desktop management) for a large steel manufacturer across two sites, where I take part in the move from SCCM to Intune, from Active Directory to Entra ID and from on-premises Exchange to Exchange Online. This repository is where I turn recurring admin tasks into repeatable, documented scripts and record what I learn on my way to Modern Workplace Engineering.

> All scripts are tested in a personal **lab tenant**, never against a production environment. Always run them with `-WhatIf` first.

## Scripts

| Script | What it does | Changes the tenant? |
|---|---|---|
| [`Get-IntuneDeviceReport.ps1`](scripts/Get-IntuneDeviceReport.ps1) | Exports all Intune devices with compliance state, encryption, OS version and last sync; flags stale devices | No (read-only) |
| [`New-EntraBulkUsers.ps1`](scripts/New-EntraBulkUsers.ps1) | Creates users from a CSV, adds them to groups and assigns licenses | Yes (`-WhatIf` supported) |
| [`Invoke-EntraUserOffboarding.ps1`](scripts/Invoke-EntraUserOffboarding.ps1) | Blocks sign-in, revokes sessions, removes groups and licenses, lists Intune devices to collect - with a full log | Yes (`-WhatIf` supported) |

## Quick start

```powershell
# One-time: install the Microsoft Graph PowerShell SDK
Install-Module Microsoft.Graph -Scope CurrentUser

# Read-only device report
.\scripts\Get-IntuneDeviceReport.ps1 -StaleDays 30

# Dry run of a bulk user import
.\scripts\New-EntraBulkUsers.ps1 -CsvPath .\samples\new-users.csv -WhatIf

# Dry run of an offboarding
.\scripts\Invoke-EntraUserOffboarding.ps1 -UserPrincipalName max.mustermann@contoso.onmicrosoft.com -WhatIf
```

Each script asks for only the Graph permissions it needs (least privilege) - see the `.NOTES` section at the top of every script.

## Design principles

- **Least privilege** - every script requests the minimum Graph scopes.
- **Safe by default** - `-WhatIf` on every script that changes something; no device wipe without a human decision.
- **Logged** - results go to a CSV so every action can be traced.
- **Real-world edge cases** - hybrid (synced) users, dynamic groups, group-based licensing.

## Lab notes

The [`labs`](labs/) folder documents hands-on exercises in my lab tenant (Intune, Autopilot, compliance policies, Conditional Access) while preparing for **Microsoft MD-102: Endpoint Administrator**.

## Roadmap

- [ ] Intune: report of apps that failed to install
- [ ] Entra ID: report of users without MFA registration
- [ ] Autopilot: hardware hash export and import
- [ ] AI: Microsoft 365 Copilot readiness check

## About me

Suad Fatih Yerdelen - Microsoft 365 / Modern Workplace - CompTIA Security+
[LinkedIn](https://www.linkedin.com/in/yerdelensuad)

## License

MIT
