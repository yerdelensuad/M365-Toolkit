<#
.SYNOPSIS
    Exports an Intune device inventory and compliance report to CSV.

.DESCRIPTION
    Reads all managed devices from Microsoft Intune through Microsoft Graph and
    writes one CSV row per device. Devices that have not synced for longer than
    -StaleDays are flagged, so you can find lost, broken or retired machines.
    At the end the script prints a short summary by compliance state and OS.

    Read-only: the script does not change anything in the tenant.

.PARAMETER OutputPath
    Path of the CSV file. Default: .\IntuneDeviceReport_<date>.csv

.PARAMETER StaleDays
    Number of days without sync after which a device counts as stale. Default: 30.

.PARAMETER OperatingSystem
    Optional filter, e.g. "Windows", "iOS", "Android".

.EXAMPLE
    .\Get-IntuneDeviceReport.ps1

.EXAMPLE
    .\Get-IntuneDeviceReport.ps1 -OperatingSystem Windows -StaleDays 14 -OutputPath C:\Reports\windows.csv

.NOTES
    Requires: Microsoft.Graph.Authentication, Microsoft.Graph.DeviceManagement
        Install-Module Microsoft.Graph -Scope CurrentUser
    Graph permission (delegated): DeviceManagementManagedDevices.Read.All
#>
[CmdletBinding()]
param(
    [string]$OutputPath = ".\IntuneDeviceReport_$(Get-Date -Format 'yyyy-MM-dd').csv",
    [ValidateRange(1, 365)]
    [int]$StaleDays = 30,
    [string]$OperatingSystem
)

$ErrorActionPreference = 'Stop'

# 1. Connect (read-only scope)
Connect-MgGraph -Scopes 'DeviceManagementManagedDevices.Read.All' -NoWelcome

# 2. Load all managed devices
Write-Host 'Loading managed devices from Intune...'
$devices = Get-MgDeviceManagementManagedDevice -All

if ($OperatingSystem) {
    $devices = $devices | Where-Object { $_.OperatingSystem -eq $OperatingSystem }
}

if (-not $devices) {
    Write-Warning 'No devices found.'
    return
}

# 3. Build report rows
$now = Get-Date
$report = foreach ($d in $devices) {
    $daysSinceSync = if ($d.LastSyncDateTime) {
        [int]($now - $d.LastSyncDateTime).TotalDays
    } else { $null }

    [PSCustomObject]@{
        DeviceName        = $d.DeviceName
        User              = $d.UserPrincipalName
        OperatingSystem   = $d.OperatingSystem
        OSVersion         = $d.OsVersion
        ComplianceState   = $d.ComplianceState
        ManagementAgent   = $d.ManagementAgent      # e.g. mdm, configurationManagerClientMdm (co-managed)
        Ownership         = $d.ManagedDeviceOwnerType
        Manufacturer      = $d.Manufacturer
        Model             = $d.Model
        SerialNumber      = $d.SerialNumber
        Encrypted         = $d.IsEncrypted
        EnrolledDate      = $d.EnrolledDateTime
        LastSync          = $d.LastSyncDateTime
        DaysSinceSync     = $daysSinceSync
        Stale             = ($null -eq $daysSinceSync) -or ($daysSinceSync -gt $StaleDays)
    }
}

# 4. Export
$report | Sort-Object ComplianceState, DeviceName |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'

# 5. Summary
Write-Host ''
Write-Host "Devices total: $($report.Count)"
Write-Host "Stale (> $StaleDays days without sync): $(($report | Where-Object Stale).Count)"
Write-Host "Not encrypted: $(($report | Where-Object { -not $_.Encrypted }).Count)"
Write-Host ''
Write-Host 'By compliance state:'
$report | Group-Object ComplianceState | Sort-Object Count -Descending |
    Format-Table @{n='State';e={$_.Name}}, Count -AutoSize
Write-Host 'By operating system:'
$report | Group-Object OperatingSystem | Sort-Object Count -Descending |
    Format-Table @{n='OS';e={$_.Name}}, Count -AutoSize

Write-Host "Report saved to: $OutputPath"
