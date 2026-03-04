[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:USERPROFILE\.config\pcloud-backup\client.windows.json",
    [switch]$DryRun,
    [string]$OnlyTag = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $DefaultValue
    }

    if ($null -eq $prop.Value) {
        return $DefaultValue
    }

    if ($prop.Value -is [string] -and [string]::IsNullOrWhiteSpace($prop.Value)) {
        return $DefaultValue
    }

    return $prop.Value
}

function Convert-ToRsyncPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet("cygdrive", "msys", "native")][string]$Style = "cygdrive"
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    $fullPath = [System.IO.Path]::GetFullPath($expanded)
    $forward = $fullPath -replace "\\", "/"

    if ($Style -eq "native") {
        return $forward
    }

    if ($fullPath -match "^(?<Drive>[A-Za-z]):\\?(?<Rest>.*)$") {
        $drive = $Matches.Drive.ToLower()
        $rest = ($Matches.Rest -replace "\\", "/").TrimStart("/")

        if ($Style -eq "msys") {
            if ([string]::IsNullOrWhiteSpace($rest)) {
                return "/$drive"
            }
            return "/$drive/$rest"
        }

        if ([string]::IsNullOrWhiteSpace($rest)) {
            return "/cygdrive/$drive"
        }
        return "/cygdrive/$drive/$rest"
    }

    return $forward
}

if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
    throw "Config file not found: $ConfigPath"
}

$null = Get-Command rsync -ErrorAction Stop
$null = Get-Command ssh -ErrorAction Stop

$config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

$serverHost = [string](Get-ConfigValue -Object $config -Name "serverHost")
$serverUser = [string](Get-ConfigValue -Object $config -Name "serverUser")
$deviceName = [string](Get-ConfigValue -Object $config -Name "deviceName")
$remoteBaseDir = [string](Get-ConfigValue -Object $config -Name "remoteBaseDir")
$sshKeyPathValue = [string](Get-ConfigValue -Object $config -Name "sshKeyPath")

if ([string]::IsNullOrWhiteSpace($serverHost) -or
    [string]::IsNullOrWhiteSpace($serverUser) -or
    [string]::IsNullOrWhiteSpace($deviceName) -or
    [string]::IsNullOrWhiteSpace($remoteBaseDir) -or
    [string]::IsNullOrWhiteSpace($sshKeyPathValue)) {
    throw "Config is missing one or more required fields: serverHost, serverUser, deviceName, remoteBaseDir, sshKeyPath"
}

$serverPort = [int](Get-ConfigValue -Object $config -Name "serverPort" -DefaultValue 22)
$pathStyle = [string](Get-ConfigValue -Object $config -Name "localPathStyle" -DefaultValue "cygdrive")
$bandwidth = [int](Get-ConfigValue -Object $config -Name "bandwidthLimitKbps" -DefaultValue 0)
$excludeFile = [string](Get-ConfigValue -Object $config -Name "excludeFile" -DefaultValue "")
$backupItems = Get-ConfigValue -Object $config -Name "backupItems"
$extraRsyncArgs = Get-ConfigValue -Object $config -Name "extraRsyncArgs" -DefaultValue @()

if ($null -eq $backupItems -or $backupItems.Count -eq 0) {
    throw "Config backupItems array is empty."
}

$sshKeyPathNative = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($sshKeyPathValue))
if (-not (Test-Path -Path $sshKeyPathNative -PathType Leaf)) {
    throw "SSH key file not found: $sshKeyPathNative"
}

$sshKeyPathForCommand = $sshKeyPathNative -replace "\\", "/"
$sshCommand = "ssh -i `"$sshKeyPathForCommand`" -p $serverPort -o BatchMode=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new"

$baseArgs = @(
    "--archive",
    "--compress",
    "--human-readable",
    "--delete",
    "--partial",
    "--inplace",
    "--protect-args",
    "--itemize-changes"
)

if ($DryRun) {
    $baseArgs += "--dry-run"
}

if ($bandwidth -gt 0) {
    $baseArgs += "--bwlimit=$bandwidth"
}

if (-not [string]::IsNullOrWhiteSpace($excludeFile)) {
    $excludeNative = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($excludeFile))
    if (-not (Test-Path -Path $excludeNative -PathType Leaf)) {
        throw "Exclude file not found: $excludeNative"
    }
    $excludePath = Convert-ToRsyncPath -Path $excludeFile -Style $pathStyle
    $baseArgs += "--exclude-from=$excludePath"
}

if ($extraRsyncArgs -is [System.Array]) {
    $baseArgs += $extraRsyncArgs
}

$success = 0
$skipped = 0
$failed = 0
$matched = 0

foreach ($item in $backupItems) {
    $tag = [string](Get-ConfigValue -Object $item -Name "tag" -DefaultValue "")
    $localPath = [string](Get-ConfigValue -Object $item -Name "localPath" -DefaultValue "")
    $remoteSubdir = [string](Get-ConfigValue -Object $item -Name "remoteSubdir" -DefaultValue "")

    if ([string]::IsNullOrWhiteSpace($tag)) {
        $tag = $remoteSubdir
    }

    if ([string]::IsNullOrWhiteSpace($tag) -or
        [string]::IsNullOrWhiteSpace($localPath) -or
        [string]::IsNullOrWhiteSpace($remoteSubdir)) {
        Write-Log "Skipping malformed backup item in config."
        $skipped++
        continue
    }

    if (-not [string]::IsNullOrWhiteSpace($OnlyTag) -and $tag -ne $OnlyTag) {
        continue
    }

    $matched++

    $localPathNative = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($localPath))
    if (-not (Test-Path -Path $localPathNative)) {
        Write-Log "Skipping [$tag] because local path does not exist: $localPathNative"
        $skipped++
        continue
    }

    $localPathRsync = Convert-ToRsyncPath -Path $localPathNative -Style $pathStyle
    if ((Test-Path -Path $localPathNative -PathType Container) -and -not $localPathRsync.EndsWith("/")) {
        $localPathRsync = "$localPathRsync/"
    }

    $cleanRemoteSubdir = $remoteSubdir.Trim("/")
    $remoteDir = "$($remoteBaseDir.TrimEnd('/'))/$deviceName/$cleanRemoteSubdir"
    $remoteEscaped = $remoteDir -replace "'", "'\''"
    $rsyncPathCmd = "mkdir -p '$remoteEscaped' && rsync"
    $destination = "$serverUser@$($serverHost):$remoteDir/"

    $args = @()
    $args += $baseArgs
    $args += "-e"
    $args += $sshCommand
    $args += "--rsync-path"
    $args += $rsyncPathCmd
    $args += $localPathRsync
    $args += $destination

    Write-Log "Starting [$tag] $localPathNative -> $destination"
    & rsync @args
    if ($LASTEXITCODE -eq 0) {
        $success++
        Write-Log "Completed [$tag]"
    }
    else {
        $failed++
        Write-Log "Failed [$tag] with exit code $LASTEXITCODE"
    }
}

if (-not [string]::IsNullOrWhiteSpace($OnlyTag) -and $matched -eq 0) {
    throw "No backupItems entry matched -OnlyTag '$OnlyTag'."
}

Write-Log "Finished. success=$success skipped=$skipped failed=$failed"

if ($failed -gt 0) {
    exit 1
}
