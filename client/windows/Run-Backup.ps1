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

function Resolve-CommandPath {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ConfiguredValue = "",
        [string]$InstallHint = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfiguredValue)) {
        $expandedConfigured = [Environment]::ExpandEnvironmentVariables($ConfiguredValue)
        if (Test-Path -Path $expandedConfigured -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($expandedConfigured)
        }

        $configuredCommand = Get-Command $ConfiguredValue -ErrorAction SilentlyContinue
        if ($null -ne $configuredCommand) {
            return $configuredCommand.Source
        }

        throw "Configured command for '$Name' was not found: $ConfiguredValue"
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    $baseMessage = "Required command '$Name' was not found in PATH."
    if ([string]::IsNullOrWhiteSpace($InstallHint)) {
        throw $baseMessage
    }

    throw "$baseMessage $InstallHint"
}

function Invoke-SshCommand {
    param(
        [Parameter(Mandatory = $true)][string]$SshExe,
        [Parameter(Mandatory = $true)][string]$SshKeyPath,
        [Parameter(Mandatory = $true)][int]$ServerPort,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$RemoteCommand,
        [switch]$Quiet
    )

    $sshArgs = @(
        "-i", $SshKeyPath,
        "-p", "$ServerPort",
        "-o", "BatchMode=yes",
        "-o", "ServerAliveInterval=30",
        "-o", "StrictHostKeyChecking=accept-new",
        $Target,
        $RemoteCommand
    )

    $output = & $SshExe @sshArgs 2>&1
    $exitCode = $LASTEXITCODE

    if (-not $Quiet -and $null -ne $output) {
        foreach ($line in $output) {
            Write-Host $line
        }
    }

    return [int]$exitCode
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
$rsyncCommandConfig = [string](Get-ConfigValue -Object $config -Name "rsyncCommand" -DefaultValue "")
$sshCommandConfig = [string](Get-ConfigValue -Object $config -Name "sshCommand" -DefaultValue "")

if ($null -eq $backupItems -or $backupItems.Count -eq 0) {
    throw "Config backupItems array is empty."
}

$rsyncInstallHint = "Install MSYS2 and rsync: winget install -e --id MSYS2.MSYS2, then in an MSYS2 shell run: pacman -S --noconfirm rsync openssh. After install, either add C:\msys64\usr\bin to PATH or set rsyncCommand/sshCommand in the JSON config."
$sshInstallHint = "Install OpenSSH Client on Windows, or set sshCommand in the JSON config."

$rsyncExe = Resolve-CommandPath -Name "rsync" -ConfiguredValue $rsyncCommandConfig -InstallHint $rsyncInstallHint
$sshExe = Resolve-CommandPath -Name "ssh" -ConfiguredValue $sshCommandConfig -InstallHint $sshInstallHint

$sshKeyPathNative = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($sshKeyPathValue))
if (-not (Test-Path -Path $sshKeyPathNative -PathType Leaf)) {
    throw "SSH key file not found: $sshKeyPathNative"
}

$sshExeForCommand = $sshExe -replace "\\", "/"
$sshKeyPathForCommand = $sshKeyPathNative -replace "\\", "/"
$sshCommand = "`"$sshExeForCommand`" -i `"$sshKeyPathForCommand`" -p $serverPort -o BatchMode=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new"
$sshTarget = "$serverUser@$serverHost"

$remotePreflight = "command -v rsync >/dev/null 2>&1 && echo remote-rsync-ok"
$preflightRc = Invoke-SshCommand -SshExe $sshExe -SshKeyPath $sshKeyPathNative -ServerPort $serverPort -Target $sshTarget -RemoteCommand $remotePreflight -Quiet
if ($preflightRc -ne 0) {
    throw "SSH preflight failed (exit code $preflightRc). Verify SSH key access for $sshTarget and that rsync is installed on the Ubuntu server."
}

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
    Write-Log "Dry-run enabled: no files will be transferred."
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
$availableTags = New-Object System.Collections.Generic.List[string]

foreach ($item in $backupItems) {
    $tag = [string](Get-ConfigValue -Object $item -Name "tag" -DefaultValue "")
    $localPath = [string](Get-ConfigValue -Object $item -Name "localPath" -DefaultValue "")
    $remoteSubdir = [string](Get-ConfigValue -Object $item -Name "remoteSubdir" -DefaultValue "")

    if ([string]::IsNullOrWhiteSpace($tag)) {
        $tag = $remoteSubdir
    }

    if (-not [string]::IsNullOrWhiteSpace($tag)) {
        $availableTags.Add($tag)
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
    $destination = "$serverUser@$($serverHost):$remoteDir/"

    if (-not $DryRun) {
        $remoteEscaped = $remoteDir -replace "'", "'\''"
        $mkdirCommand = "mkdir -p '$remoteEscaped'"
        $mkdirRc = Invoke-SshCommand -SshExe $sshExe -SshKeyPath $sshKeyPathNative -ServerPort $serverPort -Target $sshTarget -RemoteCommand $mkdirCommand
        if ($mkdirRc -ne 0) {
            $failed++
            Write-Log "Failed [$tag] creating remote directory with exit code $mkdirRc"
            continue
        }
    }

    $args = @()
    $args += $baseArgs
    $args += "-e"
    $args += $sshCommand
    $args += $localPathRsync
    $args += $destination

    Write-Log "Starting [$tag] $localPathNative -> $destination"
    & $rsyncExe @args
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
    $distinctTags = @($availableTags | Sort-Object -Unique)
    if ($distinctTags.Count -gt 0) {
        throw "No backupItems entry matched -OnlyTag '$OnlyTag'. Available tags: $($distinctTags -join ', ')"
    }
    throw "No backupItems entry matched -OnlyTag '$OnlyTag'."
}

Write-Log "Finished. success=$success skipped=$skipped failed=$failed"

if ($failed -gt 0) {
    exit 1
}
