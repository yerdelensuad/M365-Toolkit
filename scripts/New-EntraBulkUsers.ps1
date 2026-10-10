<#
.SYNOPSIS
    Creates Microsoft Entra ID users in bulk from a CSV file.

.DESCRIPTION
    For each row in the CSV the script:
      1. Creates the user (skips the row if the UPN already exists)
      2. Adds the user to the listed groups (by group display name)
      3. Assigns the listed license (by SKU part number, e.g. ENTERPRISEPACK)

    A random initial password is generated per user and the user must change it
    at first sign-in. Results (including the initial passwords) are written to a
    result CSV - store it securely and delete it after handover.

    Supports -WhatIf: run with -WhatIf first to see what would happen.

.PARAMETER CsvPath
    Input CSV. Columns: GivenName;Surname;UserPrincipalName;Department;JobTitle;UsageLocation;Groups;LicenseSku
    Groups = group display names separated by "|". See samples\new-users.csv.

.PARAMETER ResultPath
    Output CSV with the result per user.

.EXAMPLE
    .\New-EntraBulkUsers.ps1 -CsvPath ..\samples\new-users.csv -WhatIf

.EXAMPLE
    .\New-EntraBulkUsers.ps1 -CsvPath ..\samples\new-users.csv

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Groups,
              Microsoft.Graph.Identity.DirectoryManagement, Microsoft.Graph.Users.Actions
    Graph permissions (delegated): User.ReadWrite.All, GroupMember.ReadWrite.All,
                                   Group.Read.All, Organization.Read.All
    Only cloud-only groups with assigned membership can be used (no dynamic or on-prem synced groups).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ })]
    [string]$CsvPath,
    [string]$ResultPath = ".\NewUsers_Result_$(Get-Date -Format 'yyyy-MM-dd_HHmm').csv"
)

$ErrorActionPreference = 'Stop'

function New-RandomPassword {
    # 16 characters, guaranteed upper, lower, digit and symbol
    $upper  = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower  = 'abcdefghijkmnopqrstuvwxyz'
    $digits = '23456789'
    $symbol = '!#$%&*+-=?@'
    $all    = $upper + $lower + $digits + $symbol
    $chars  = @(
        $upper[(Get-Random -Maximum $upper.Length)]
        $lower[(Get-Random -Maximum $lower.Length)]
        $digits[(Get-Random -Maximum $digits.Length)]
        $symbol[(Get-Random -Maximum $symbol.Length)]
    )
    $chars += 1..12 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

Connect-MgGraph -Scopes 'User.ReadWrite.All','GroupMember.ReadWrite.All','Group.Read.All','Organization.Read.All' -NoWelcome

$rows = Import-Csv -Path $CsvPath -Delimiter ';'

# Cache license SKUs and groups so we do not query Graph for every row
$skus = @{}
Get-MgSubscribedSku -All | ForEach-Object { $skus[$_.SkuPartNumber] = $_.SkuId }
$groupCache = @{}

$results = foreach ($r in $rows) {
    $upn    = $r.UserPrincipalName.Trim()
    $status = 'Created'
    $notes  = @()
    $initialPassword    = $null

    try {
        $existing = Get-MgUser -Filter "userPrincipalName eq '$upn'" -ErrorAction SilentlyContinue
        if ($existing) {
            [PSCustomObject]@{ UserPrincipalName = $upn; Status = 'Skipped - already exists'; InitialPassword = ''; Notes = '' }
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($upn, 'Create user, add groups, assign license')) {
            [PSCustomObject]@{ UserPrincipalName = $upn; Status = 'WhatIf'; InitialPassword = ''; Notes = '' }
            continue
        }

        # 1. Create user
        $initialPassword = New-RandomPassword
        $user = New-MgUser -BodyParameter @{
            accountEnabled    = $true
            givenName         = $r.GivenName
            surname           = $r.Surname
            displayName       = "$($r.GivenName) $($r.Surname)"
            userPrincipalName = $upn
            mailNickname      = ($upn.Split('@')[0] -replace '[^a-zA-Z0-9._-]', '')
            department        = $r.Department
            jobTitle          = $r.JobTitle
            usageLocation     = $r.UsageLocation   # required before a license can be assigned
            passwordProfile   = @{ password = $initialPassword; forceChangePasswordNextSignIn = $true }
        }

        # 2. Groups
        if ($r.Groups) {
            foreach ($gName in ($r.Groups -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                if (-not $groupCache.ContainsKey($gName)) {
                    $groupCache[$gName] = Get-MgGroup -Filter "displayName eq '$gName'" -Top 1
                }
                $group = $groupCache[$gName]
                if ($group) {
                    New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $user.Id
                    $notes += "group: $gName"
                } else {
                    $notes += "group NOT FOUND: $gName"
                    $status = 'Created with warnings'
                }
            }
        }

        # 3. License
        if ($r.LicenseSku) {
            $skuId = $skus[$r.LicenseSku.Trim()]
            if ($skuId) {
                Set-MgUserLicense -UserId $user.Id -AddLicenses @(@{ SkuId = $skuId }) -RemoveLicenses @() | Out-Null
                $notes += "license: $($r.LicenseSku)"
            } else {
                $notes += "license NOT FOUND: $($r.LicenseSku)"
                $status = 'Created with warnings'
            }
        }
    }
    catch {
        $status = "Error: $($_.Exception.Message)"
    }

    [PSCustomObject]@{
        UserPrincipalName = $upn
        Status            = $status
        InitialPassword   = $initialPassword
        Notes             = ($notes -join ', ')
    }
}

$results | Export-Csv -Path $ResultPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'
$results | Format-Table UserPrincipalName, Status, Notes -AutoSize
Write-Host "Result saved to: $ResultPath"
Write-Warning 'The result file contains initial passwords. Hand them over securely and delete the file.'
