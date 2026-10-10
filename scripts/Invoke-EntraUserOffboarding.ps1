<#
.SYNOPSIS
    Offboards a Microsoft Entra ID user in a safe, logged and repeatable way.

.DESCRIPTION
    Steps, in this order:
      1. Block sign-in (accountEnabled = false)
      2. Revoke all refresh tokens / sessions
      3. Remove the user from all cloud groups with assigned membership
         (dynamic groups and on-prem synced groups are skipped and logged)
      4. Remove all directly assigned licenses (optional, -KeepLicenses to skip)
      5. List the user's Intune devices so IT can collect or wipe them

    Every step is written to a log CSV. Supports -WhatIf.

.PARAMETER UserPrincipalName
    The user to offboard.

.PARAMETER KeepLicenses
    Do not remove licenses (e.g. when the mailbox must stay licensed for a while).

.PARAMETER LogPath
    Path of the log CSV.

.EXAMPLE
    .\Invoke-EntraUserOffboarding.ps1 -UserPrincipalName max.muster@contoso.com -WhatIf

.EXAMPLE
    .\Invoke-EntraUserOffboarding.ps1 -UserPrincipalName max.muster@contoso.com -KeepLicenses

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions,
              Microsoft.Graph.Groups, Microsoft.Graph.DeviceManagement
    Graph permissions (delegated): User.ReadWrite.All, GroupMember.ReadWrite.All,
                                   DeviceManagementManagedDevices.Read.All
    The signed-in admin also needs a matching Entra role (e.g. User Administrator).
    For hybrid users (synced from on-prem AD) disable the account in AD as well -
    otherwise the next sync can re-enable it.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$UserPrincipalName,
    [switch]$KeepLicenses,
    [string]$LogPath = ".\Offboarding_$($UserPrincipalName.Split('@')[0])_$(Get-Date -Format 'yyyy-MM-dd_HHmm').csv"
)

$ErrorActionPreference = 'Stop'
$log = [System.Collections.Generic.List[object]]::new()

function Write-Step {
    param([string]$Step, [string]$Result, [string]$Detail = '')
    $entry = [PSCustomObject]@{ Time = (Get-Date -Format 's'); Step = $Step; Result = $Result; Detail = $Detail }
    $log.Add($entry)
    Write-Host ("[{0}] {1} {2}" -f $entry.Result, $Step, $Detail)
}

Connect-MgGraph -Scopes 'User.ReadWrite.All','GroupMember.ReadWrite.All','DeviceManagementManagedDevices.Read.All' -NoWelcome

$user = Get-MgUser -UserId $UserPrincipalName -Property Id,DisplayName,UserPrincipalName,AccountEnabled,OnPremisesSyncEnabled
Write-Step 'Find user' 'OK' "$($user.DisplayName) ($($user.Id))"

if ($user.OnPremisesSyncEnabled) {
    Write-Step 'Hybrid check' 'WARNING' 'User is synced from on-prem AD - disable the account in AD too.'
}

# 1. Block sign-in
if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Block sign-in')) {
    try {
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
        Write-Step 'Block sign-in' 'OK'
    } catch { Write-Step 'Block sign-in' 'ERROR' $_.Exception.Message }
}

# 2. Revoke sessions
if ($PSCmdlet.ShouldProcess($UserPrincipalName, 'Revoke all sessions')) {
    try {
        Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
        Write-Step 'Revoke sessions' 'OK'
    } catch { Write-Step 'Revoke sessions' 'ERROR' $_.Exception.Message }
}

# 3. Remove group memberships
$groups = Get-MgUserMemberOf -UserId $user.Id -All |
    Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' }

foreach ($g in $groups) {
    $name      = $g.AdditionalProperties['displayName']
    $types     = @($g.AdditionalProperties['groupTypes'])
    $synced    = $g.AdditionalProperties['onPremisesSyncEnabled']

    if ($types -contains 'DynamicMembership') {
        Write-Step 'Remove group' 'SKIPPED' "$name (dynamic group - fix the rule or user attributes)"
        continue
    }
    if ($synced) {
        Write-Step 'Remove group' 'SKIPPED' "$name (synced from on-prem AD - remove in AD)"
        continue
    }
    if ($PSCmdlet.ShouldProcess($name, "Remove $UserPrincipalName from group")) {
        try {
            Remove-MgGroupMemberByRef -GroupId $g.Id -DirectoryObjectId $user.Id
            Write-Step 'Remove group' 'OK' $name
        } catch { Write-Step 'Remove group' 'ERROR' "$name - $($_.Exception.Message)" }
    }
}

# 4. Remove licenses
if ($KeepLicenses) {
    Write-Step 'Remove licenses' 'SKIPPED' '-KeepLicenses was set'
} else {
    $licenses = Get-MgUserLicenseDetail -UserId $user.Id
    if ($licenses -and $PSCmdlet.ShouldProcess($UserPrincipalName, 'Remove all direct licenses')) {
        try {
            Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses @($licenses.SkuId) | Out-Null
            Write-Step 'Remove licenses' 'OK' (($licenses.SkuPartNumber) -join ', ')
        } catch {
            # Group-based licenses cannot be removed per user - they go away with the group membership
            Write-Step 'Remove licenses' 'ERROR' $_.Exception.Message
        }
    } elseif (-not $licenses) {
        Write-Step 'Remove licenses' 'OK' 'No licenses assigned'
    }
}

# 5. List Intune devices (no wipe - that is a deliberate manual decision)
try {
    $devices = Get-MgUserManagedDevice -UserId $user.Id -All
    if ($devices) {
        foreach ($d in $devices) {
            Write-Step 'Intune device' 'TODO' "$($d.DeviceName) | $($d.OperatingSystem) | SN $($d.SerialNumber) - collect device / decide on wipe or retire"
        }
    } else {
        Write-Step 'Intune devices' 'OK' 'No managed devices'
    }
} catch { Write-Step 'Intune devices' 'ERROR' $_.Exception.Message }

$log | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
Write-Host ''
Write-Host "Log saved to: $LogPath"
