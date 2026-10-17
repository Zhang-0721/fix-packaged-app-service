#Requires -Version 5.1
<#
.SYNOPSIS
    Repairs orphaned MSIX / Microsoft Store packaged-service registrations that
    block app installs and updates with 0x80073CF6 / 0x80070005.

.DESCRIPTION
    Symptom this tool targets:

        AppX deployment of package <Name>_<Version>_<Arch>__<PublisherId>
        failed with error 0x80073CF6.
        Underlying error: 0x80070005 -- Access is denied while registering
        the windows.service extension.

    Background
    ----------
    An MSIX package can declare a Windows service:

        <desktop6:Extension Category="windows.service" ...>
          <desktop6:Service Name="Vendor.Agent" StartupType="auto"
                            StartAccount="localSystem" />
        </desktop6:Extension>

    Windows materialises that declaration as a real service registration under

        HKLM\SYSTEM\CurrentControlSet\Services\<ServiceName>

    with Type = 0x210 (WIN32_PACKAGED_PROCESS) and ImagePath pointing into the
    package directory, e.g.
        ...\WindowsApps\<Name>_<Version>_<Arch>__<PublisherId>\app\resources\svc.exe

    When a newer version is staged, deployment is supposed to re-point that
    registration at the new version directory.  If that step fails, the
    registration keeps pointing at a package directory that no longer exists and
    every later registration attempt dies on the windows.service extension.

    Why it cannot be fixed the obvious way
    --------------------------------------
    The service object's security descriptor grants SERVICE_ALL_ACCESS only to
    Authenticated Users and to a package SID -- notably WITHOUT
    BUILTIN\Administrators or NT AUTHORITY\SYSTEM.  So even an elevated
    administrator cannot use the SCM to clean it up:

        sc.exe delete <ServiceName>
        [SC] OpenService FAILED 5:
        Access is denied.

    The service's *registry key*, however, is owned by BUILTIN\Administrators
    and grants them Full Control.  The registration can therefore be removed
    straight out of the registry.  A reboot (or at least a SCM restart) is then
    required to drop the cached service record, after which the staged package
    registers normally.

    Modes
    -----
    -Diagnose   Read-only report. No changes. No elevation required. (default)
    -Fix        Phase 1: stop, then remove the orphaned registrations, schedule
                phase 2 for the next logon, and ask for a reboot.
    -Phase2     Phase 2: re-register the affected packages. Normally invoked by
                the scheduled task created in phase 1, but can be run by hand.

.PARAMETER Diagnose
    Print a report and exit. The default when no other mode is given.

.PARAMETER Fix
    Remove orphaned packaged-service registrations and schedule the post-reboot
    repair. Requires elevation; the script re-launches itself elevated if needed.

.PARAMETER Phase2
    Post-reboot stage: re-register the affected packages and verify the result.

.PARAMETER Reboot
    Reboot automatically at the end of phase 1 instead of only prompting.

.PARAMETER Yes
    Do not ask for confirmation.

.PARAMETER ServiceName
    Only consider these service names. Use this for variants where the stale
    registration still points at an existing file (for example when deployment
    reports 0x80073D26 "a different version of the service is installed").

.PARAMETER PackageFamilyName
    Restrict every operation to a single package family, e.g.
    'Vendor.App_1234567890abc'. Recommended for maximum safety.

.PARAMETER MsixPath
    Optional. After the reboot, deploy this .msix/.appx file instead of
    re-registering an already staged package. Use this when the very first
    install never completed.

.PARAMETER LogPath
    Path of the log file. Defaults to
    %ProgramData%\PackagedServiceRepair\repair.log (elevated) or
    %TEMP%\PackagedServiceRepair\repair.log.

.PARAMETER StatePath
    Path of the state file passed from phase 1 to phase 2.

.EXAMPLE
    .\Fix-PackagedAppService.ps1 -Diagnose

    Show what is broken without changing anything.

.EXAMPLE
    .\Fix-PackagedAppService.ps1 -Fix

    Remove the orphaned registrations, then reboot when prompted.

.EXAMPLE
    .\Fix-PackagedAppService.ps1 -Fix -PackageFamilyName 'Vendor.App_1234567890abc' -Reboot

    Same, restricted to one package family, rebooting automatically.

.EXAMPLE
    .\Fix-PackagedAppService.ps1 -Fix -MsixPath .\App-x64.msix

    For a first-time install that never succeeded: clean the stale service
    registration, reboot, then deploy the supplied package.

.NOTES
    Requires Windows 10 1809+ / Windows 11 and Windows PowerShell 5.1.
    This script makes no network calls and contains no credentials.
    Tested against the packaged-service defects reported in:
      https://github.com/openai/codex/issues/53132
      https://github.com/anthropics/claude-code/issues/57035
    Use at your own risk; read the README before running -Fix.
#>

[CmdletBinding()]
param(
    [switch]$Diagnose,
    [switch]$Fix,
    [switch]$Phase2,
    [switch]$Reboot,
    [switch]$Yes,
    [string[]]$ServiceName,
    [string]$PackageFamilyName,
    [string]$MsixPath,
    [string]$LogPath,
    [string]$StatePath
)

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

$script:ToolVersion    = '1.0.0'
$script:ServiceKeyRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services'
$script:TaskName       = 'PackagedServiceRepairPhase2'
$script:IsElevated     = $false

try {
    $identity      = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal     = New-Object Security.Principal.WindowsPrincipal($identity)
    $script:IsElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    $script:IsElevated = $false
}

if ($script:IsElevated) {
    $script:DataDir = Join-Path $env:ProgramData 'PackagedServiceRepair'
} else {
    $script:DataDir = Join-Path $env:TEMP 'PackagedServiceRepair'
}

if (-not (Test-Path -LiteralPath $script:DataDir)) {
    try { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null } catch { }
}

if (-not $LogPath)   { $LogPath   = Join-Path $script:DataDir 'repair.log' }
if (-not $StatePath) { $StatePath = Join-Path $script:DataDir 'state.json' }

# Cached Add-AppxPackage parameter names (older builds lack some switches).
$script:AddAppxParams = @{}
try {
    $cmd = Get-Command -Name 'Add-AppxPackage' -ErrorAction Stop
    foreach ($key in $cmd.Parameters.Keys) { $script:AddAppxParams[$key] = $true }
} catch { }

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Log {
    param([string]$Text)
    try {
        $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch { }
}

function Write-Plain {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
    Write-Log $Text
}

function Write-Head {
    param([string]$Text)
    Write-Host ''
    Write-Host ("== {0} ==" -f $Text) -ForegroundColor White
    Write-Log ("== {0} ==" -f $Text)
}

function Write-Ok   { param([string]$Text) Write-Plain ("  [ ok ] {0}" -f $Text) 'Green' }
function Write-Info { param([string]$Text) Write-Plain ("  [ .. ] {0}" -f $Text) 'Cyan' }
function Write-Note { param([string]$Text) Write-Plain ("  [ !! ] {0}" -f $Text) 'Yellow' }
function Write-Fail { param([string]$Text) Write-Plain ("  [fail] {0}" -f $Text) 'Red' }

function Write-Row {
    param([string]$Text)
    Write-Host $Text -ForegroundColor DarkGray
    Write-Log $Text
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

function Request-Elevation {
    param([string[]]$ExtraArgs)

    if (-not $PSCommandPath) {
        Write-Fail 'Cannot determine the script path, so elevation is not possible.'
        Write-Note 'Run this script from an elevated PowerShell window instead.'
        return $false
    }

    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $exe = 'powershell.exe' }

    $argLine = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}"' -f $PSCommandPath
    if ($ExtraArgs -and $ExtraArgs.Count -gt 0) {
        $argLine = $argLine + ' ' + ($ExtraArgs -join ' ')
    }

    Write-Note 'Administrator rights are required. Re-launching elevated...'
    try {
        Start-Process -FilePath $exe -ArgumentList $argLine -Verb RunAs -ErrorAction Stop
        return $true
    } catch {
        Write-Fail 'Elevation failed or was cancelled.'
        return $false
    }
}

function ConvertTo-ExecutablePath {
    param([string]$Raw)

    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    $value = $Raw.Trim()

    if ($value.StartsWith('"')) {
        $end = $value.IndexOf('"', 1)
        if ($end -gt 1) { return $value.Substring(1, $end - 1) }
        return $value.Trim('"')
    }

    $idx = $value.IndexOf('.exe', [System.StringComparison]::OrdinalIgnoreCase)
    if ($idx -ge 0) { return $value.Substring(0, $idx + 4) }
    return $value
}

function Get-PublisherIdFromFullName {
    param([string]$PackageFullName)

    if ([string]::IsNullOrWhiteSpace($PackageFullName)) { return $null }
    $parts = $PackageFullName.Split('_')
    if ($parts.Length -lt 2) { return $null }
    return $parts[$parts.Length - 1]
}

function Get-PackageNameFromFullName {
    param([string]$PackageFullName)

    if ([string]::IsNullOrWhiteSpace($PackageFullName)) { return $null }
    $parts = $PackageFullName.Split('_')
    return $parts[0]
}

function Get-PackageFamilyFromFullName {
    param([string]$PackageFullName)

    $name = Get-PackageNameFromFullName $PackageFullName
    $pub  = Get-PublisherIdFromFullName $PackageFullName
    if (-not $name -or -not $pub) { return $null }
    return ('{0}_{1}' -f $name, $pub)
}

function Get-PackageFullNameFromPath {
    param([string]$ExecutablePath)

    if ([string]::IsNullOrWhiteSpace($ExecutablePath)) { return $null }
    $match = [regex]::Match($ExecutablePath, '\\WindowsApps\\([^\\]+)\\',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Get-ServiceSddl {
    param([string]$Name)

    $output = & sc.exe sdshow $Name 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    foreach ($line in $output) {
        $text = ([string]$line).Trim()
        if ($text.StartsWith('D:')) { return $text }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Service discovery
# ---------------------------------------------------------------------------

function Get-PackagedServices {
    param([string[]]$OnlyNames)

    $found = New-Object System.Collections.ArrayList

    $keys = @()
    try {
        $keys = Get-ChildItem -Path $script:ServiceKeyRoot -ErrorAction Stop
    } catch {
        Write-Fail ('Cannot enumerate the service registry: ' + $_.Exception.Message)
        return $found
    }

    foreach ($key in $keys) {
        $name = $key.PSChildName

        if ($OnlyNames -and $OnlyNames.Count -gt 0) {
            if ($OnlyNames -notcontains $name) { continue }
        }

        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop } catch { continue }

        # Type 0x210 = WIN32_PACKAGED_PROCESS: a service owned by an MSIX package.
        if ($null -eq $props.Type) { continue }
        if ([int]$props.Type -ne 528) { continue }

        $rawImage  = $null
        if ($props.PSObject.Properties.Name -contains 'ImagePath') { $rawImage = $props.ImagePath }
        $exePath   = ConvertTo-ExecutablePath $rawImage

        $fullName  = $null
        if ($props.PSObject.Properties.Name -contains 'PackageFullName') { $fullName = $props.PackageFullName }
        if (-not $fullName) { $fullName = Get-PackageFullNameFromPath $exePath }

        $appId = $null
        if ($props.PSObject.Properties.Name -contains 'AppUserModelId') { $appId = $props.AppUserModelId }

        $family = Get-PackageFamilyFromFullName $fullName
        if (-not $family -and $appId) {
            $bang = $appId.IndexOf('!')
            if ($bang -gt 0) { $family = $appId.Substring(0, $bang) }
        }

        $exeExists = $false
        if ($exePath -and (Test-Path -LiteralPath $exePath)) { $exeExists = $true }

        $sddl    = Get-ServiceSddl $name
        $hasBA   = $false
        $hasSY   = $false
        $checked = $false
        if ($sddl) {
            $checked = $true
            if ($sddl -match ';;;BA\)') { $hasBA = $true }
            if ($sddl -match ';;;SY\)') { $hasSY = $true }
        }

        $startType = 'unknown'
        if ($null -ne $props.Start) {
            switch ([int]$props.Start) {
                0 { $startType = 'Boot' }
                1 { $startType = 'System' }
                2 { $startType = 'Automatic' }
                3 { $startType = 'Manual' }
                4 { $startType = 'Disabled' }
                default { $startType = [string]$props.Start }
            }
        }

        $item = New-Object psobject
        $item | Add-Member -MemberType NoteProperty -Name 'ServiceName'      -Value $name
        $item | Add-Member -MemberType NoteProperty -Name 'DisplayName'      -Value $props.DisplayName
        $item | Add-Member -MemberType NoteProperty -Name 'ImagePath'        -Value $exePath
        $item | Add-Member -MemberType NoteProperty -Name 'ImagePathExists'  -Value $exeExists
        $item | Add-Member -MemberType NoteProperty -Name 'StartType'        -Value $startType
        $item | Add-Member -MemberType NoteProperty -Name 'PackageFullName'  -Value $fullName
        $item | Add-Member -MemberType NoteProperty -Name 'PackageFamily'    -Value $family
        $item | Add-Member -MemberType NoteProperty -Name 'AppUserModelId'   -Value $appId
        $item | Add-Member -MemberType NoteProperty -Name 'DaclChecked'      -Value $checked
        $item | Add-Member -MemberType NoteProperty -Name 'DaclHasAdmin'     -Value $hasBA
        $item | Add-Member -MemberType NoteProperty -Name 'DaclHasSystem'    -Value $hasSY
        $item | Add-Member -MemberType NoteProperty -Name 'Sddl'             -Value $sddl

        [void]$found.Add($item)
    }

    return $found
}

function Get-RepairTargets {
    $all     = Get-PackagedServices -OnlyNames $ServiceName
    $targets = New-Object System.Collections.ArrayList

    foreach ($svc in $all) {
        if ($PackageFamilyName) {
            if ($svc.PackageFamily -ne $PackageFamilyName) { continue }
        }

        if ($svc.ImagePathExists) {
            # Registration still resolves. Nothing to repair unless it was
            # explicitly named by the operator (version-mismatch variants).
            if ($ServiceName -and $ServiceName.Count -gt 0) {
                if ($ServiceName -contains $svc.ServiceName) {
                    $svc | Add-Member -MemberType NoteProperty -Name 'Reason' -Value 'Requested explicitly' -Force
                    [void]$targets.Add($svc)
                }
            }
            continue
        }

        $svc | Add-Member -MemberType NoteProperty -Name 'Reason' -Value 'Executable path missing' -Force
        [void]$targets.Add($svc)
    }

    return $targets
}

# ---------------------------------------------------------------------------
# Package discovery
# ---------------------------------------------------------------------------

function Get-WindowsAppsRoots {
    $roots = New-Object System.Collections.ArrayList

    $systemRoot = Join-Path $env:ProgramFiles 'WindowsApps'
    if (Test-Path -LiteralPath $systemRoot) { [void]$roots.Add($systemRoot) }

    try {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
            if (-not $drive.IsReady) { continue }
            $candidate = $drive.Name + 'WindowsApps'
            if (Test-Path -LiteralPath $candidate) {
                if ($roots -notcontains $candidate) { [void]$roots.Add($candidate) }
            }
        }
    } catch { }

    return $roots
}

function Find-NewestStagedPackage {
    param([string]$PackageName)

    if ([string]::IsNullOrWhiteSpace($PackageName)) { return $null }

    $prefix     = $PackageName + '_'
    $candidates = New-Object System.Collections.ArrayList

    foreach ($root in (Get-WindowsAppsRoots)) {
        $dirs = @()
        try { $dirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction Stop } catch { continue }

        foreach ($dir in $dirs) {
            if (-not $dir.Name.StartsWith($prefix)) { continue }

            $match = [regex]::Match($dir.Name, '^(?<name>[^_]+)_(?<ver>\d+\.\d+\.\d+\.\d+)_')
            if (-not $match.Success) { continue }
            if ($match.Groups['name'].Value -ne $PackageName) { continue }

            $version = $null
            try { $version = [version]$match.Groups['ver'].Value } catch { continue }

            $manifest = Join-Path $dir.FullName 'AppxManifest.xml'
            if (-not (Test-Path -LiteralPath $manifest)) { continue }

            $entry = New-Object psobject
            $entry | Add-Member -MemberType NoteProperty -Name 'Version'  -Value $version
            $entry | Add-Member -MemberType NoteProperty -Name 'Location' -Value $dir.FullName
            $entry | Add-Member -MemberType NoteProperty -Name 'Manifest' -Value $manifest
            [void]$candidates.Add($entry)
        }
    }

    if ($candidates.Count -eq 0) { return $null }
    $sorted = @($candidates | Sort-Object -Property Version -Descending)
    return $sorted[0]
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

function Show-Environment {
    Write-Head 'Environment'

    $os = 'unknown'
    try {
        $os = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption
    } catch {
        try { $os = [System.Environment]::OSVersion.VersionString } catch { }
    }

    Write-Row ('  Tool version  : {0}' -f $script:ToolVersion)
    Write-Row ('  Computer      : {0}' -f $env:COMPUTERNAME)
    Write-Row ('  User          : {0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
    Write-Row ('  Elevated      : {0}' -f $script:IsElevated)
    Write-Row ('  OS            : {0}' -f $os)
    Write-Row ('  PowerShell    : {0}' -f $PSVersionTable.PSVersion)
    Write-Row ('  Log file      : {0}' -f $LogPath)
}

function Show-PackagedServiceReport {
    $all = Get-PackagedServices -OnlyNames $ServiceName

    Write-Head ('Packaged services found: {0}' -f $all.Count)

    if ($all.Count -eq 0) {
        Write-Note 'No service with Type=0x210 (WIN32_PACKAGED_PROCESS) was found.'
        Write-Note 'Either no MSIX package declares a service, or the filter is too narrow.'
        return
    }

    $rows = @()
    foreach ($svc in $all) {
        $state = 'OK'
        if (-not $svc.ImagePathExists) { $state = 'ORPHANED' }

        $acl = 'unknown'
        if ($svc.DaclChecked) {
            $bits = @()
            if ($svc.DaclHasAdmin)  { $bits += 'BA' }
            if ($svc.DaclHasSystem) { $bits += 'SY' }
            if ($bits.Count -eq 0)  { $acl = 'no BA/SY' } else { $acl = ($bits -join '+') }
        }

        $staged = ''
        $newest = Find-NewestStagedPackage -PackageName (Get-PackageNameFromFullName $svc.PackageFullName)
        if ($newest) { $staged = [string]$newest.Version }

        $rows += ([pscustomobject][ordered]@{
            Service   = $svc.ServiceName
            Family    = $svc.PackageFamily
            PointsTo  = (Get-PackageFullNameFromPath $svc.ImagePath)
            Exists    = $svc.ImagePathExists
            Staged    = $staged
            Acl       = $acl
            State     = $state
        })
    }

    $text = ($rows | Format-Table -AutoSize | Out-String -Width 220)
    foreach ($line in ($text -split "`r?`n")) {
        if ($line.Trim().Length -gt 0) { Write-Row ('  ' + $line) }
    }

    $broken = @($all | Where-Object { -not $_.ImagePathExists })
    Write-Plain ''
    if ($broken.Count -gt 0) {
        Write-Note ('{0} registration(s) point at a directory that no longer exists.' -f $broken.Count)
        Write-Note 'These are the ones that block package registration. Run with -Fix to repair.'
    } else {
        Write-Ok 'Every packaged service resolves to an existing executable.'
    }

    $weak = @($all | Where-Object { $_.DaclChecked -and (-not $_.DaclHasAdmin) -and (-not $_.DaclHasSystem) })
    if ($weak.Count -gt 0) {
        Write-Note ('{0} registration(s) carry a security descriptor without BUILTIN\Administrators' -f $weak.Count)
        Write-Note 'and without NT AUTHORITY\SYSTEM. That is the normal shape for packaged'
        Write-Note 'services -- unrelated Microsoft services show the identical descriptor -- but it'
        Write-Note 'means sc.exe cannot delete or reconfigure them. -Fix goes through the registry'
        Write-Note 'key instead, which does not depend on that descriptor.'
    }
}

function Show-RecentDeploymentErrors {
    param([int]$Minutes = 60)

    Write-Head ('AppX deployment errors in the last {0} minutes' -f $Minutes)

    $events = @()
    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-AppXDeploymentServer/Operational'
            StartTime = (Get-Date).AddMinutes(-$Minutes)
        } -MaxEvents 400 -ErrorAction Stop
    } catch {
        Write-Note 'Deployment log is empty or unreadable.'
        return
    }

    $errors = @($events | Where-Object { $_.Level -le 3 })
    if ($errors.Count -eq 0) {
        Write-Ok 'No error or warning events.'
        return
    }

    foreach ($event in ($errors | Select-Object -First 12)) {
        $message = ($event.Message -replace "`r?`n", ' ')
        if ($message.Length -gt 170) { $message = $message.Substring(0, 170) + '...' }
        Write-Row ('  {0}  id={1}  {2}' -f $event.TimeCreated.ToString('HH:mm:ss'), $event.Id, $message)
    }
}

function Invoke-Diagnose {
    Write-Plain ''
    Write-Plain 'MSIX packaged-service repair -- diagnostic report' 'White'
    Write-Plain 'Nothing will be changed by this mode.' 'DarkGray'

    Show-Environment
    Show-PackagedServiceReport
    Show-RecentDeploymentErrors -Minutes 60

    Write-Head 'Next step'
    Write-Plain '  If a service above is marked ORPHANED, run:'
    Write-Plain '      .\Fix-PackagedAppService.ps1 -Fix'
    Write-Plain '  then reboot and let the scheduled phase 2 finish the job.'
}

# ---------------------------------------------------------------------------
# Phase 1
# ---------------------------------------------------------------------------

function Register-Phase2Task {
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { return $false }

    $argument = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File "{0}" -Phase2' -f $scriptPath
    $user     = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME

    try {
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $user
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                                                  -DontStopIfGoingOnBatteries `
                                                  -StartWhenAvailable `
                                                  -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

        $existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
        if ($existing) { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue }

        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger `
                               -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

        Write-Ok ('Scheduled task "{0}" will run phase 2 at the next logon.' -f $script:TaskName)
        return $true
    } catch {
        Write-Fail ('Could not create the scheduled task: ' + $_.Exception.Message)
        Write-Note 'You can still run phase 2 by hand after the reboot:'
        Write-Note ('  powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Phase2' -f $scriptPath)
        return $false
    }
}

function Remove-ServiceRegistration {
    param([string]$Name)

    $result = New-Object psobject
    $result | Add-Member -MemberType NoteProperty -Name 'Name'    -Value $Name
    $result | Add-Member -MemberType NoteProperty -Name 'Stopped' -Value $false
    $result | Add-Member -MemberType NoteProperty -Name 'Deleted' -Value $false
    $result | Add-Member -MemberType NoteProperty -Name 'Detail'  -Value ''

    try {
        Stop-Service -Name $Name -Force -ErrorAction Stop
        $result.Stopped = $true
    } catch {
        $result.Detail = 'stop: ' + $_.Exception.Message
    }

    $keyPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $Name
    try {
        Remove-Item -LiteralPath $keyPath -Recurse -Force -ErrorAction Stop
        $result.Deleted = $true
    } catch {
        $nativeKey = 'HKLM\SYSTEM\CurrentControlSet\Services\' + $Name
        $null = & reg.exe delete $nativeKey /f 2>&1
        if ($LASTEXITCODE -eq 0) {
            $result.Deleted = $true
        } else {
            $result.Detail = $result.Detail + ' delete: ' + $_.Exception.Message
        }
    }

    return $result
}

function Save-RepairState {
    param([object[]]$Targets)

    $entries = @()
    foreach ($target in $Targets) {
        $entries += [ordered]@{
            ServiceName      = $target.ServiceName
            PackageFullName  = $target.PackageFullName
            PackageFamily    = $target.PackageFamily
            PackageName      = (Get-PackageNameFromFullName $target.PackageFullName)
            ImagePath        = $target.ImagePath
        }
    }

    $state = [ordered]@{
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        MsixPath   = $MsixPath
        Targets    = $entries
    }

    try {
        ($state | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $StatePath -Encoding UTF8 -ErrorAction Stop
        Write-Ok ('Repair state written to {0}' -f $StatePath)
        return $true
    } catch {
        Write-Fail ('Could not write the state file: ' + $_.Exception.Message)
        return $false
    }
}

function Invoke-Phase1 {
    Write-Plain ''
    Write-Plain 'MSIX packaged-service repair -- phase 1' 'White'

    if (-not $script:IsElevated) {
        $relaunched = Request-Elevation -ExtraArgs @('-Fix')
        if ($relaunched) { return }
        exit 1
    }

    Show-Environment

    $targets = Get-RepairTargets
    Write-Head ('Registrations to remove: {0}' -f $targets.Count)

    if ($targets.Count -eq 0) {
        Write-Ok 'Nothing to repair. No packaged service points at a missing directory.'
        Write-Note 'If deployment still fails with 0x80073D26 ("a different version of the'
        Write-Note 'service is installed"), name the service explicitly, for example:'
        Write-Note '  -Fix -ServiceName "Vendor.Agent"'
        return
    }

    foreach ($target in $targets) {
        Write-Row ('  service   : {0}' -f $target.ServiceName)
        Write-Row ('  family    : {0}' -f $target.PackageFamily)
        Write-Row ('  points to : {0}' -f $target.PackageFullName)
        Write-Row ('  path      : {0}  (missing)' -f $target.ImagePath)
        Write-Row ('  reason    : {0}' -f $target.Reason)
        Write-Row ''
    }

    if (-not $Yes) {
        $answer = Read-Host 'Remove these registrations now? Type YES to continue'
        if ($answer -ne 'YES') {
            Write-Note 'Aborted. Nothing was changed.'
            return
        }
    }

    Write-Head 'Removing registrations'

    $removed = New-Object System.Collections.ArrayList
    foreach ($target in $targets) {
        $outcome = Remove-ServiceRegistration -Name $target.ServiceName
        if ($outcome.Deleted) {
            Write-Ok ('Removed {0}' -f $target.ServiceName)
            [void]$removed.Add($target)
        } else {
            Write-Fail ('Could not remove {0}. {1}' -f $target.ServiceName, $outcome.Detail)
            Write-Note 'Make sure you are running elevated and that the registry key is not'
            Write-Note ('read-only: {0}\{1}' -f $script:ServiceKeyRoot, $target.ServiceName)
        }
    }

    if ($removed.Count -eq 0) {
        Write-Fail 'No registration could be removed. Phase 2 will not help.'
        return
    }

    if (-not (Save-RepairState -Targets $removed)) {
        Write-Note 'Continuing without a state file; phase 2 will repair every orphaned package.'
    }

    $scheduled = Register-Phase2Task

    Write-Head 'Reboot required'
    Write-Plain '  The service manager keeps the removed entries in memory until the machine'
    Write-Plain '  restarts. Phase 2 registers the package and only then succeeds.'
    Write-Plain ''
    if ($scheduled) {
        Write-Plain '  After logging back in, phase 2 runs automatically.'
    }
    Write-Plain '  Manual fallback, from an elevated prompt:'
    Write-Plain ('    powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Phase2' -f $PSCommandPath)

    if ($Reboot) {
        Write-Note 'Rebooting now.'
        Restart-Computer -Force
    } else {
        Write-Plain ''
        Write-Plain '  Reboot when convenient with:  Restart-Computer -Force'
    }
}

# ---------------------------------------------------------------------------
# Phase 2
# ---------------------------------------------------------------------------

function Get-RegistrationSplat {
    param([string]$Register, [string]$Path, [switch]$DevelopmentMode)

    $splat = @{ ErrorAction = 'Stop' }
    if ($script:AddAppxParams.ContainsKey('ForceApplicationShutdown')) { $splat['ForceApplicationShutdown'] = $true }
    if ($Register) { $splat['Register'] = $Register }
    if ($Path)     { $splat['Path']     = $Path }
    if ($DevelopmentMode -and $script:AddAppxParams.ContainsKey('DisableDevelopmentMode')) {
        $splat['DisableDevelopmentMode'] = $true
    }
    return $splat
}

function Register-Package {
    param([string]$PackageFamily, [string]$PackageName, [string]$FromFile)

    $failures = New-Object System.Collections.ArrayList

    if ($FromFile) {
        Write-Info ('Deploying {0}' -f $FromFile)
        try {
            $splat = Get-RegistrationSplat -Path $FromFile
            Add-AppxPackage @splat
            return $true
        } catch {
            [void]$failures.Add($_.Exception.Message)
        }
    }

    $newest = Find-NewestStagedPackage -PackageName $PackageName
    if ($newest) {
        Write-Info ('Re-registering staged package {0}' -f $newest.Version)
        Write-Row  ('    manifest: {0}' -f $newest.Manifest)

        try {
            $splat = Get-RegistrationSplat -Register $newest.Manifest
            Add-AppxPackage @splat
            return $true
        } catch {
            [void]$failures.Add($_.Exception.Message)
        }

        try {
            $splat = Get-RegistrationSplat -Register $newest.Manifest -DevelopmentMode
            Add-AppxPackage @splat
            return $true
        } catch {
            [void]$failures.Add($_.Exception.Message)
        }
    } else {
        Write-Note ('No staged package directory found for {0}.' -f $PackageName)
    }

    if ($PackageFamily -and $script:AddAppxParams.ContainsKey('RegisterByFamilyName')) {
        Write-Info ('Registering by package family: {0}' -f $PackageFamily)
        try {
            Add-AppxPackage -RegisterByFamilyName -MainPackage $PackageFamily -ErrorAction Stop
            return $true
        } catch {
            [void]$failures.Add($_.Exception.Message)
        }
    }

    foreach ($failure in $failures) {
        $clean = $failure -replace "`r?`n", ' '
        Write-Fail ('  attempt failed: {0}' -f $clean)
    }
    return $false
}

function Confirm-PackageHealthy {
    param([string]$PackageName)

    $services = @(Get-PackagedServices | Where-Object {
        (Get-PackageNameFromFullName $_.PackageFullName) -eq $PackageName
    })

    if ($services.Count -eq 0) {
        Write-Note ('No packaged service found for {0}; cannot verify the service side.' -f $PackageName)
        return $null
    }

    $allGood = $true
    foreach ($svc in $services) {
        if ($svc.ImagePathExists) {
            Write-Ok ('{0} -> {1}' -f $svc.ServiceName, $svc.ImagePath)
            $running = $null
            try { $running = (Get-Service -Name $svc.ServiceName -ErrorAction Stop).Status } catch { }
            if ($running -and $running -ne 'Running') {
                try { Start-Service -Name $svc.ServiceName -ErrorAction Stop; Write-Ok ('started {0}' -f $svc.ServiceName) }
                catch { Write-Note ('could not start {0}: {1}' -f $svc.ServiceName, $_.Exception.Message) }
            }
        } else {
            Write-Fail ('{0} still points at a missing path: {1}' -f $svc.ServiceName, $svc.ImagePath)
            $allGood = $false
        }
    }
    return $allGood
}

function Invoke-Phase2 {
    Write-Plain ''
    Write-Plain 'MSIX packaged-service repair -- phase 2' 'White'

    if (-not $script:IsElevated) {
        $relaunched = Request-Elevation -ExtraArgs @('-Phase2')
        if ($relaunched) { return }
        exit 1
    }

    Show-Environment

    Write-Info 'Waiting for the shell and the state repository to settle...'
    Start-Sleep -Seconds 8

    $state = $null
    if (Test-Path -LiteralPath $StatePath) {
        try { $state = Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $state = $null }
    }

    $packages = @()

    if ($state -and $state.Targets) {
        Write-Ok ('Loaded the phase 1 state file ({0} target(s)).' -f @($state.Targets).Count)
        foreach ($entry in @($state.Targets)) {
            $packages += New-Object psobject -Property @{
                PackageName  = $entry.PackageName
                PackageFamily= $entry.PackageFamily
                FromFile     = $state.MsixPath
            }
        }
    } else {
        Write-Note 'No state file. Deriving the targets from the current machine state.'
        foreach ($svc in @(Get-PackagedServices)) {
            if ($svc.ImagePathExists) { continue }
            if ($PackageFamilyName -and $svc.PackageFamily -ne $PackageFamilyName) { continue }
            $packages += New-Object psobject -Property @{
                PackageName  = (Get-PackageNameFromFullName $svc.PackageFullName)
                PackageFamily= $svc.PackageFamily
                FromFile     = $MsixPath
            }
        }
    }

    $packages = @($packages | Where-Object { $_.PackageName } | Sort-Object -Property PackageName -Unique)

    if ($packages.Count -eq 0) {
        Write-Ok 'Nothing to register. Either the repair is already complete or phase 1 was not run.'
        Remove-Phase2Task
        return
    }

    Write-Head ('Packages to register: {0}' -f $packages.Count)

    $failed = New-Object System.Collections.ArrayList
    foreach ($package in $packages) {
        Write-Plain ''
        Write-Plain ('-- {0}' -f $package.PackageName) 'White'

        $registered = Register-Package -PackageFamily $package.PackageFamily `
                                       -PackageName $package.PackageName `
                                       -FromFile $package.FromFile
        if (-not $registered) {
            Write-Fail ('Registration failed for {0}' -f $package.PackageName)
            [void]$failed.Add($package.PackageName)
            continue
        }

        Write-Ok ('Package {0} registered.' -f $package.PackageName)
        $null = Confirm-PackageHealthy -PackageName $package.PackageName

        $start = $null
        $shell = Join-Path $env:SystemRoot 'explorer.exe'
        if (Test-Path -LiteralPath $shell) {
            try {
                $aumid = '{0}!App' -f $package.PackageFamily
                Start-Process -FilePath $shell -ArgumentList ('shell:AppsFolder\' + $aumid) -ErrorAction SilentlyContinue
                Write-Info 'Launch request sent (the first start after an update can take a while).'
                $start = $true
            } catch { }
        }
        if (-not $start) {
            Write-Note 'Could not send a launch request from here; start the app from the Start menu.'
        }
    }

    Show-RecentDeploymentErrors -Minutes 15
    Remove-Phase2Task

    Write-Head 'Result'
    if ($failed.Count -eq 0) {
        Write-Ok 'All packages registered successfully.'
        Write-Plain '  The app should now start. The first launch after an update can be slow.'
    } else {
        Write-Fail ('Still failing: {0}' -f ($failed -join ', '))
        Write-Note 'Check the deployment log with -Diagnose, and the README section'
        Write-Note '"If it still fails" for the remaining options.'
    }
}

function Remove-Phase2Task {
    try {
        $existing = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
        if ($existing) { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction Stop }
        Write-Info ('Removed the scheduled task "{0}".' -f $script:TaskName)
    } catch { }

    if (Test-Path -LiteralPath $StatePath) {
        try { Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop } catch { }
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if ($Phase2) {
    Invoke-Phase2
} elseif ($Fix) {
    Invoke-Phase1
} else {
    Invoke-Diagnose
}
