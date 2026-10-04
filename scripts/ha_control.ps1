<#
.SYNOPSIS
    Syncs Home Assistant YAML configuration between this repository and the live
    /config directory over SSH, and drives verify / reload / restart over the HA
    REST API.

.DESCRIPTION
    Credentials are read from ..\.env (HA_URL, HA_TOKEN, HA_SSH_USER,
    HA_SSH_HOST, HA_SSH_PORT).

    -Deploy takes a remote backup before it writes. The backup is restored when
    the deployment aborts, or when -Verify reports an invalid configuration, and
    is removed after a clean run. It never outlives the run.

    -Diff, -Pull and -Deploy first rewrite local YAML into one canonical format
    (Tools\ha_yaml.py), so files do not churn between the repo, the Studio Code
    Server add-on and the HA web UI editors. Use -NoFormat to skip that.

.EXAMPLE
    .\ha_control.ps1 -Diff
    Shows what changed on the server, without touching local files.

.EXAMPLE
    .\ha_control.ps1 -Deploy -File ..\packages\ems.yaml -Verify -Reload
    Deploys one file, validates the remote configuration, rolls back if it is
    invalid, then reloads all YAML domains.

.EXAMPLE
    .\ha_control.ps1 -Deploy -WhatIf
    Builds the bundle and reports every remote write it would perform.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
    [switch]$Deploy,
    [switch]$Pull,
    [switch]$Diff,
    [string]$File,
    [switch]$Verify,
    [switch]$Reload,
    [ValidateSet('All', 'Core', 'Automations', 'Scripts', 'Themes', 'Rest', 'Templates', 'TemplateEntities')]
    [string]$Target,
    [switch]$Restart,
    # Lets -Pull overwrite local files that have uncommitted changes.
    [switch]$Force,
    # Skips the canonical YAML reformat of local files.
    [switch]$NoFormat,
    [ValidateRange(10, 3600)]
    [int]$RestartTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:LASTEXITCODE = 0

# --------------------------------------------------------------------------
# State
# --------------------------------------------------------------------------
$script:Cmdlet = $PSCmdlet
$script:OriginalLocation = Get-Location
$script:ExitCode = 0
$script:TempRoot = $null

# Remote backup state, used to roll back a failed deployment.
$script:BackupCreated = $false
$script:BackupMode = ''
$script:BackupRelativePath = ''
$script:RemoteFileExisted = $false
$script:DeployCompleted = $false
$script:VerifiedOk = $false
$script:RemoteBackupTar = '/config/.ha_control_deploy_backup.tar'
# Top-level paths the full-deploy bundle writes; a full rollback replaces them.
$script:BundleTopLevel = @()

$script:TarResolved = $false
$script:TarPrefix = @()
$script:PythonResolved = $false
$script:PythonCmd = $null
$script:YamlTool = Join-Path $PSScriptRoot 'ha_yaml.py'
$script:SourceDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Overall pipeline progress across flags.
$script:ActionList = @()
if ($Pull) { $script:ActionList += 'Pull' }
if ($Diff) { $script:ActionList += 'Diff' }
if ($Deploy) { $script:ActionList += 'Deploy' }
if ($Verify) { $script:ActionList += 'Verify' }
if ($Reload) { $script:ActionList += 'Reload' }
if ($Restart) { $script:ActionList += 'Restart' }
$script:ActionIndex = 0

# --------------------------------------------------------------------------
# Infrastructure helpers
# --------------------------------------------------------------------------
function Show-ActionProgress {
    param([string]$Status, [int]$StepPercent = 0)
    $total = $script:ActionList.Count
    if ($total -le 0 -or $script:ActionIndex -ge $total) { return }
    $basePercent = [math]::Floor(($script:ActionIndex / $total) * 100)
    $stepWeight = 100 / $total
    $overall = [math]::Min(100, [math]::Floor($basePercent + ($stepWeight * ($StepPercent / 100))))
    Write-Progress -Activity "Home Assistant Control ($($script:ActionList[$script:ActionIndex]))" -Status $Status -PercentComplete $overall
}

function Test-Proceed {
    param([string]$TargetDescription, [string]$Action)
    return $script:Cmdlet.ShouldProcess($TargetDescription, $Action)
}

function Get-ResponseValue {
    # StrictMode turns a missing property into a terminating error, so every API
    # response field is read through here.
    param($Response, [string]$Name)
    if ($null -eq $Response) { return $null }
    $property = $Response.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-PosixPath {
    # scp derives the transmitted name from the last '/' in the source path. A
    # Windows path separates with '\', so scp finds none, sends the whole path as
    # the filename - the file lands as '/config/packages/C:\Users\...\ems.yaml',
    # the real target is never touched, and scp still exits 0. Local DESTINATION
    # paths keep their native separators: there the drive letter is all scp has
    # to work with. tar takes the native path too - see Get-TarArguments.
    param([string]$Path)
    return $Path.Replace('\', '/')
}

function ConvertTo-ShellQuoted {
    param([string]$Value)
    return "'" + ($Value -replace "'", "'\''") + "'"
}

function Invoke-Native {
    <#
      Runs an external program with a real argument array - no Invoke-Expression,
      so paths with spaces need no re-parsing and no filename can inject shell
      syntax. $ErrorActionPreference is relaxed for the call: with 'Stop' in
      force, any line a tool writes to stderr (ssh banners, scp progress) is
      promoted to a terminating error.
    #>
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments = @()
    )
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $global:LASTEXITCODE = 0
        $raw = & $Executable @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $lines = @($raw | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{
        Lines    = $lines
        Text     = ($lines -join "`n").Trim()
        ExitCode = $code
    }
}

function Get-TarArguments {
    <#
      GNU tar reads an archive path with a drive letter as host:path and dies with
      "Cannot connect to C:"; it needs --force-local. bsdtar has no such option and
      rejects it outright. Both take the native Windows path, so probe once and
      return the prefix that fits whichever tar is first on PATH.
    #>
    if ($script:TarResolved) { return $script:TarPrefix }
    $script:TarResolved = $true
    $version = Invoke-Native -Executable 'tar.exe' -Arguments @('--version')
    if ($version.Text -match 'GNU tar') { $script:TarPrefix = @('--force-local') }
    return $script:TarPrefix
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory)][string]$RemoteCommand,
        [string]$Description,
        [switch]$NonFatal
    )
    if ($Description) { Write-Host $Description -ForegroundColor Cyan }
    $result = Invoke-Native -Executable 'ssh' -Arguments ($script:SshArgs + @($script:RemoteHost, $RemoteCommand))
    if ($result.ExitCode -ne 0 -and -not $NonFatal) {
        throw "Remote command failed (exit $($result.ExitCode)): $RemoteCommand`n$($result.Text)"
    }
    return $result
}

function Invoke-Scp {
    param(
        [Parameter(Mandatory)][string[]]$Paths,
        [string]$Description,
        [switch]$Recurse
    )
    if ($Description) { Write-Host $Description -ForegroundColor Cyan }
    $scpArguments = $script:ScpArgs
    if ($Recurse) { $scpArguments = $scpArguments + @('-r') }
    $result = Invoke-Native -Executable 'scp' -Arguments ($scpArguments + $Paths)
    if ($result.ExitCode -ne 0) {
        throw "scp failed (exit $($result.ExitCode)): $($Paths -join ' ')`n$($result.Text)"
    }
    return $result
}

# --------------------------------------------------------------------------
# Remote backup and rollback
# --------------------------------------------------------------------------
function Restore-RemoteBackup {
    if (-not $script:BackupCreated) { return }
    $script:BackupCreated = $false

    Write-Host "`nRestoring the Home Assistant configuration to its pre-deployment state..." -ForegroundColor Yellow
    $result = $null
    try {
        if ($script:BackupMode -eq 'Single') {
            $remoteTarget = ConvertTo-ShellQuoted ('/config/' + $script:BackupRelativePath)
            $remoteBackup = ConvertTo-ShellQuoted ('/config/' + $script:BackupRelativePath + '.ha_bak')
            if ($script:RemoteFileExisted) {
                $result = Invoke-Ssh -NonFatal -RemoteCommand "mv -f $remoteBackup $remoteTarget" `
                    -Description "Restoring the previous version of $($script:BackupRelativePath)..."
            } else {
                $result = Invoke-Ssh -NonFatal -RemoteCommand "rm -f $remoteTarget $remoteBackup" `
                    -Description "Removing the new, unverified file $($script:BackupRelativePath)..."
            }
        } elseif ($script:BackupMode -eq 'Full') {
            $tar = ConvertTo-ShellQuoted $script:RemoteBackupTar
            # Extracting alone restores changed files but keeps every file the
            # deployment added. So remove each top-level path the bundle wrote, then
            # extract: paths that existed come back complete from the backup, new
            # ones stay removed. 'tar -tf' first, so a damaged archive never leads
            # to a delete.
            $items = ($script:BundleTopLevel |
                Where-Object { $_ -and $_ -notin @('.', '..') } |
                ForEach-Object { ConvertTo-ShellQuoted $_ }) -join ' '
            $result = Invoke-Ssh -NonFatal -RemoteCommand "cd /config && tar -tf $tar >/dev/null && rm -rf -- $items && tar -xf $tar && rm -f $tar" `
                -Description 'Restoring the full configuration from the backup archive...'
        } else {
            return
        }
    } catch {
        Write-Host "Exception during the remote restore: $_" -ForegroundColor Red
    }

    if ($null -ne $result -and $result.ExitCode -eq 0) {
        Write-Host 'Remote configuration restored.' -ForegroundColor Green
        return
    }

    if ($null -ne $result) { Write-Host $result.Text -ForegroundColor Red }
    Write-Host 'ROLLBACK FAILED. The backup is still on the server:' -ForegroundColor Red
    if ($script:BackupMode -eq 'Full') {
        Write-Host "  $($script:RemoteBackupTar)   (restore with: cd /config && tar -xf <file>)" -ForegroundColor Red
    } else {
        Write-Host "  /config/$($script:BackupRelativePath).ha_bak" -ForegroundColor Red
    }
    $script:ExitCode = 1
}

function Remove-RemoteBackup {
    if (-not $script:BackupCreated) { return }
    $script:BackupCreated = $false
    try {
        if ($script:BackupMode -eq 'Single') {
            $remoteBackup = ConvertTo-ShellQuoted ('/config/' + $script:BackupRelativePath + '.ha_bak')
            Invoke-Ssh -NonFatal -RemoteCommand "rm -f $remoteBackup" | Out-Null
        } elseif ($script:BackupMode -eq 'Full') {
            $tar = ConvertTo-ShellQuoted $script:RemoteBackupTar
            Invoke-Ssh -NonFatal -RemoteCommand "rm -f $tar" | Out-Null
        }
    } catch {
        # Cleanup is best effort; a stale backup file on the server is harmless.
    }
}

function Get-RemoteSha256 {
    param([string]$RemotePath)
    $quoted = ConvertTo-ShellQuoted $RemotePath
    $result = Invoke-Ssh -NonFatal -RemoteCommand "sha256sum $quoted 2>/dev/null | cut -d' ' -f1"
    if ($result.ExitCode -ne 0) { return $null }
    $hash = $result.Text.Trim()
    if ($hash -match '^[0-9a-f]{64}$') { return $hash }
    return $null
}

function Assert-UploadIntact {
    <#
      A zero exit from scp does not prove the bytes landed under the intended
      name (see ConvertTo-PosixPath), and -Verify would then validate the
      untouched remote file and report success. Compare content, not exit codes.
    #>
    param([string]$LocalPath, [string]$RemotePath, [string]$DisplayName)

    $remoteHash = Get-RemoteSha256 -RemotePath $RemotePath
    if ($remoteHash) {
        $localHash = (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($remoteHash -ne $localHash) {
            throw "Upload verification failed for $DisplayName (local sha256 $localHash, remote $remoteHash)."
        }
        Write-Host "Upload verified: $DisplayName (sha256 $($localHash.Substring(0, 12))...)." -ForegroundColor Green
        return
    }

    # Busybox without sha256sum: fall back to a size comparison, which still
    # catches the scp basename bug and any truncated transfer.
    $localSize = (Get-Item -LiteralPath $LocalPath).Length
    $quoted = ConvertTo-ShellQuoted $RemotePath
    $remoteSize = (Invoke-Ssh -NonFatal -RemoteCommand "wc -c < $quoted 2>/dev/null || echo missing").Text.Trim()
    if ($remoteSize -ne "$localSize") {
        throw "Upload verification failed for $DisplayName (local $localSize bytes, remote '$remoteSize')."
    }
    Write-Host "Upload verified: $DisplayName ($localSize bytes; sha256sum unavailable on the server)." -ForegroundColor Green
}

# --------------------------------------------------------------------------
# Local file helpers
# --------------------------------------------------------------------------
function Get-NormalizedRelativePath {
    param([string]$Path, [string]$BaseDirectory)
    if (-not $Path) { throw 'No file path was supplied.' }

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($resolved) {
        $full = $resolved.Path
    } elseif ([System.IO.Path]::IsPathRooted($Path)) {
        $full = [System.IO.Path]::GetFullPath($Path)
    } else {
        $full = [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $Path))
    }

    $baseNormalized = [System.IO.Path]::GetFullPath($BaseDirectory).TrimEnd('\', '/') + '\'
    if (-not $full.StartsWith($baseNormalized, [System.StringComparison]::OrdinalIgnoreCase)) {
        # Falling back to the bare filename here used to send ..\..\other\x.yaml
        # straight to /config/x.yaml.
        throw "'$Path' resolves to '$full', which is outside the configuration root '$BaseDirectory'."
    }
    return ($full.Substring($baseNormalized.Length) -replace '\\', '/')
}

function Get-PythonCommand {
    if ($script:PythonResolved) { return $script:PythonCmd }
    $script:PythonResolved = $true

    $candidates = @(
        [pscustomobject]@{ Exe = 'python'; Prefix = @() },
        [pscustomobject]@{ Exe = 'py'; Prefix = @('-3') },
        [pscustomobject]@{ Exe = 'python3'; Prefix = @() }
    )
    foreach ($candidate in $candidates) {
        if (-not (Get-Command $candidate.Exe -ErrorAction SilentlyContinue)) { continue }
        $probe = Invoke-Native -Executable $candidate.Exe -Arguments (@($candidate.Prefix) + @('-c', 'import ruamel.yaml, yaml'))
        if ($probe.ExitCode -eq 0) {
            $script:PythonCmd = $candidate
            return $script:PythonCmd
        }
    }
    # Hardcoding 'python' used to fail silently: with no interpreter on PATH,
    # $LASTEXITCODE kept its previous value and formatting counted as done.
    Write-Host 'No Python with ruamel.yaml and PyYAML found (tried python, py -3, python3).' -ForegroundColor Yellow
    Write-Host '  Canonical formatting and semantic diffs are unavailable. Install with: pip install ruamel.yaml pyyaml' -ForegroundColor Yellow
    $script:PythonCmd = $null
    return $null
}

function Invoke-YamlTool {
    param([string[]]$ToolArguments)
    $python = Get-PythonCommand
    if (-not $python) { return $null }

    # ha_yaml.py writes UTF-8. PowerShell decodes native output with the console
    # code page (typically IBM437), which garbles €, → and °C, so switch to UTF-8
    # for this call only. Setting it can fail without a console; then decode as-is.
    $previousEncoding = [Console]::OutputEncoding
    $switched = $false
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $switched = $true
    } catch {
        # No console attached: keep the current encoding.
    }
    try {
        return Invoke-Native -Executable $python.Exe -Arguments (@($python.Prefix) + @($script:YamlTool) + $ToolArguments)
    } finally {
        if ($switched) { [Console]::OutputEncoding = $previousEncoding }
    }
}

function Format-Yaml {
    param([string[]]$Files)

    if ($NoFormat) { return }
    $existing = @($Files | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($existing.Count -eq 0) { return }
    if (-not (Test-Proceed -TargetDescription "$($existing.Count) local YAML file(s)" -Action 'Apply canonical formatting')) { return }

    Write-Host "Applying canonical YAML formatting to $($existing.Count) file(s)..." -ForegroundColor Cyan
    $result = Invoke-YamlTool -ToolArguments (@('format') + $existing)
    if ($null -eq $result) { return }
    if ($result.ExitCode -gt 1) {
        Write-Host "  Formatting skipped: ha_yaml.py exited $($result.ExitCode)." -ForegroundColor Yellow
        Write-Host "  $($result.Text)" -ForegroundColor Yellow
        return
    }
    $result.Lines | Where-Object { $_ -like 'formatted:*' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
    $result.Lines | Where-Object { $_ -like 'skip *' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}

function Get-ConfigYaml {
    param([string]$Root)
    $files = @(Get-ChildItem -LiteralPath $Root -Filter *.yaml -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $packages = Join-Path $Root 'packages'
    if (Test-Path -LiteralPath $packages) {
        $files += @(Get-ChildItem -LiteralPath $packages -Filter *.yaml -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    return $files
}

function Show-RawDiff {
    param([string]$LocalFile, [string]$RemoteFile, [string]$DisplayName, [string]$Note)
    $comparison = Compare-Object -ReferenceObject @(Get-Content -LiteralPath $LocalFile) -DifferenceObject @(Get-Content -LiteralPath $RemoteFile)
    if ($comparison) {
        Write-Host "`n--- DIFF FOR $DisplayName ($Note; => means HA, <= means local) ---" -ForegroundColor Magenta
        $comparison | Format-Table -AutoSize
    } else {
        Write-Host "$DisplayName is identical." -ForegroundColor Green
    }
}

function Invoke-YamlDiff {
    param([string]$LocalFile, [string]$RemoteFile, [string]$DisplayName)

    if ($DisplayName -notmatch '\.ya?ml$') {
        Show-RawDiff -LocalFile $LocalFile -RemoteFile $RemoteFile -DisplayName $DisplayName -Note 'raw text'
        return
    }

    $result = Invoke-YamlTool -ToolArguments @('diff', $LocalFile, $RemoteFile, $DisplayName)
    if ($null -eq $result) {
        Show-RawDiff -LocalFile $LocalFile -RemoteFile $RemoteFile -DisplayName $DisplayName -Note 'raw text fallback'
        return
    }

    if ($result.ExitCode -eq 0) {
        Write-Host "$DisplayName is identical (ignoring formatting)." -ForegroundColor Green
    } elseif ($result.ExitCode -eq 1) {
        Write-Host "`n--- DIFF FOR $DisplayName (- local, + HA) ---" -ForegroundColor Magenta
        foreach ($line in $result.Lines) {
            if ($line -like '@@*') { Write-Host $line -ForegroundColor Cyan }
            elseif ($line -like '+*') { Write-Host $line -ForegroundColor Green }
            elseif ($line -like '-*') { Write-Host $line -ForegroundColor Red }
            else { Write-Host $line }
        }
    } else {
        Show-RawDiff -LocalFile $LocalFile -RemoteFile $RemoteFile -DisplayName $DisplayName -Note 'raw text fallback'
    }
}

function Assert-NoLocalChanges {
    param([string[]]$ScopePaths)
    if ($Force) { return }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return }

    $result = Invoke-Native -Executable 'git' -Arguments (@('-C', $script:SourceDir, 'status', '--porcelain', '--') + $ScopePaths)
    if ($result.ExitCode -ne 0) { return }  # not a git repository

    # Skip untracked ('??') lines. Not with -notlike '??*': -like reads '?' as a
    # wildcard, so that pattern matched every line and the guard never blocked.
    $dirty = @($result.Lines | Where-Object { $_.Trim() -and -not $_.StartsWith('??') })
    if ($dirty.Count -eq 0) { return }

    Write-Host 'Uncommitted local changes inside the pull scope:' -ForegroundColor Yellow
    $dirty | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    throw 'Pull would overwrite these files. Commit or stash them first, or re-run with -Force.'
}

function New-TempRoot {
    if ($script:TempRoot) { return $script:TempRoot }
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "ha_control_$PID"
    if (Test-Path -LiteralPath $path) { Remove-Item -Recurse -Force -LiteralPath $path -WhatIf:$false }
    New-Item -ItemType Directory -Path $path -Force -WhatIf:$false | Out-Null
    $script:TempRoot = $path
    return $path
}

# --------------------------------------------------------------------------
# Environment
# --------------------------------------------------------------------------
function Import-DotEnv {
    param([string]$Path)
    $values = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -like 'export *') { $trimmed = $trimmed.Substring(7).Trim() }

        # Split on the FIRST '=' only, so values may contain '='.
        $separator = $trimmed.IndexOf('=')
        if ($separator -lt 1) { continue }

        $name = $trimmed.Substring(0, $separator).Trim()
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }

        $value = $trimmed.Substring($separator + 1).Trim()
        if ($value.Length -ge 2 -and
            (($value.StartsWith('"') -and $value.EndsWith('"')) -or
             ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$name] = $value
    }
    return $values
}

$envFilePath = Join-Path $PSScriptRoot '..\.env'
if (-not (Test-Path -LiteralPath $envFilePath)) {
    Write-Host "Error: .env file not found at $envFilePath." -ForegroundColor Red
    exit 1
}

$envValues = Import-DotEnv -Path $envFilePath
$required = @('HA_URL', 'HA_TOKEN', 'HA_SSH_USER', 'HA_SSH_HOST', 'HA_SSH_PORT')
$missing = @($required | Where-Object { -not $envValues.ContainsKey($_) -or -not $envValues[$_] })
if ($missing.Count -gt 0) {
    Write-Host "Error: .env has no value for: $($missing -join ', ')." -ForegroundColor Red
    exit 1
}

$script:HaUrl = $envValues['HA_URL'].TrimEnd('/')
$script:Headers = @{
    'Authorization' = "Bearer $($envValues['HA_TOKEN'])"
    'Content-Type'  = 'application/json'
}
$script:RemoteHost = "$($envValues['HA_SSH_USER'])@$($envValues['HA_SSH_HOST'])"
$script:SshArgs = @('-c', 'aes256-gcm@openssh.com', '-p', $envValues['HA_SSH_PORT'])
$script:ScpArgs = @('-O', '-c', 'aes256-gcm@openssh.com', '-P', $envValues['HA_SSH_PORT'])

# These flag combinations used to be ignored silently.
if ($Target -and -not $Reload) {
    Write-Host 'Note: -Target only applies to -Reload; ignoring it.' -ForegroundColor Yellow
}
if ($File -and -not ($Deploy -or $Pull -or $Diff)) {
    Write-Host 'Note: -File only applies to -Deploy, -Pull and -Diff; ignoring it.' -ForegroundColor Yellow
}

# --------------------------------------------------------------------------
# Actions
# --------------------------------------------------------------------------
try {
    Set-Location $script:SourceDir

    if ($Pull) {
        Show-ActionProgress 'Pulling the configuration from Home Assistant...' 10

        if ($File) {
            $relativePath = Get-NormalizedRelativePath -Path $File -BaseDirectory $script:SourceDir
            Assert-NoLocalChanges -ScopePaths @($relativePath)
            $localFile = Join-Path $script:SourceDir $relativePath

            if (Test-Proceed -TargetDescription $relativePath -Action 'Overwrite the local file with the server copy') {
                Write-Host "Pulling single file: $relativePath" -ForegroundColor Cyan
                Show-ActionProgress "Downloading $relativePath..." 50
                Invoke-Scp -Paths @("$($script:RemoteHost):/config/$relativePath", $localFile) | Out-Null
                if ($localFile -match '\.ya?ml$') {
                    Show-ActionProgress 'Formatting the pulled YAML...' 90
                    Format-Yaml -Files @($localFile)
                }
            }
        } else {
            # ':(glob)' keeps '*.yaml' to the root, like the scp below; a plain git
            # pathspec '*' also matches '/' and would block on various/*.yaml.
            Assert-NoLocalChanges -ScopePaths @(':(glob)*.yaml', 'packages', 'custom_templates')

            if (Test-Proceed -TargetDescription 'root *.yaml, packages/, custom_templates/' -Action 'Overwrite local files with the server copies') {
                Show-ActionProgress 'Pulling the root YAML files...' 25
                Invoke-Scp -Paths @("$($script:RemoteHost):/config/*.yaml", '.') -Description 'Pulling the root YAML files...' | Out-Null

                Show-ActionProgress 'Pulling the packages directory...' 50
                Invoke-Scp -Recurse -Paths @("$($script:RemoteHost):/config/packages", '.') -Description 'Pulling the packages folder...' | Out-Null

                Show-ActionProgress 'Pulling the custom_templates directory...' 75
                Invoke-Scp -Recurse -Paths @("$($script:RemoteHost):/config/custom_templates", '.') -Description 'Pulling the custom_templates folder...' | Out-Null

                Write-Host 'To pull a file from another subfolder, use -Pull -File <path>.' -ForegroundColor Yellow

                Show-ActionProgress 'Formatting the pulled YAML files...' 90
                Format-Yaml -Files (Get-ConfigYaml -Root $script:SourceDir)
            }
        }

        Show-ActionProgress 'Pull complete.' 100
        Write-Host "Pull complete. Use 'git diff' to review what the HA UI changed." -ForegroundColor Green
        $script:ActionIndex++
    }

    if ($Diff) {
        Show-ActionProgress 'Initialising the dry-run diff...' 10
        # Scope: root *.yaml, packages/ and custom_templates/. -Deploy writes more
        # than this; Tools\.deployignore defines the full bundle.
        $tempDir = Join-Path (New-TempRoot) 'diff'
        New-Item -ItemType Directory -Path $tempDir -Force -WhatIf:$false | Out-Null

        if ($File) {
            $relativePath = Get-NormalizedRelativePath -Path $File -BaseDirectory $script:SourceDir
            $localFile = Join-Path $script:SourceDir $relativePath
            $tempFile = Join-Path $tempDir 'remote_file'

            Show-ActionProgress "Downloading the remote $relativePath..." 50
            # A file that is missing on the server is an answer, not an error, so
            # the download is allowed to fail here.
            $download = Invoke-Native -Executable 'scp' -Arguments ($script:ScpArgs + @("$($script:RemoteHost):/config/$relativePath", $tempFile))
            if ($download.ExitCode -ne 0 -and $download.Text -notmatch 'No such file or directory') {
                throw "scp failed (exit $($download.ExitCode)): $($download.Text)"
            }

            Show-ActionProgress 'Comparing files...' 90
            if (Test-Path -LiteralPath $tempFile) {
                Invoke-YamlDiff -LocalFile $localFile -RemoteFile $tempFile -DisplayName $relativePath
            } elseif (Test-Path -LiteralPath $localFile -PathType Leaf) {
                Write-Host "$relativePath exists locally but NOT on the server." -ForegroundColor Yellow
            } else {
                Write-Host "$relativePath was not found locally or on the server." -ForegroundColor Red
            }
        } else {
            Show-ActionProgress 'Downloading the remote config to a temporary folder...' 40
            Invoke-Scp -Paths @("$($script:RemoteHost):/config/*.yaml", $tempDir) | Out-Null
            Invoke-Scp -Recurse -Paths @("$($script:RemoteHost):/config/packages", $tempDir) | Out-Null
            Invoke-Scp -Recurse -Paths @("$($script:RemoteHost):/config/custom_templates", $tempDir) | Out-Null

            Show-ActionProgress 'Comparing the local and remote files...' 80
            $resolvedTempDir = (Resolve-Path -LiteralPath $tempDir).Path
            Get-ChildItem -LiteralPath $resolvedTempDir -Recurse -File -Include *.yaml, *.jinja | ForEach-Object {
                $relPath = $_.FullName.Substring($resolvedTempDir.Length + 1)
                $localFile = Join-Path $script:SourceDir $relPath
                if (Test-Path -LiteralPath $localFile -PathType Leaf) {
                    Invoke-YamlDiff -LocalFile $localFile -RemoteFile $_.FullName -DisplayName $relPath
                } else {
                    Write-Host "$relPath only exists on the server." -ForegroundColor Yellow
                }
            }

            $localScope = @(Get-ConfigYaml -Root $script:SourceDir)
            $customTemplates = Join-Path $script:SourceDir 'custom_templates'
            if (Test-Path -LiteralPath $customTemplates) {
                $localScope += @(Get-ChildItem -LiteralPath $customTemplates -Recurse -File -Include *.jinja, *.yaml | ForEach-Object { $_.FullName })
            }
            foreach ($localPath in $localScope) {
                $relPath = $localPath.Substring($script:SourceDir.Length + 1)
                if (-not (Test-Path -LiteralPath (Join-Path $resolvedTempDir $relPath) -PathType Leaf)) {
                    Write-Host "$relPath exists locally but NOT on the server." -ForegroundColor Yellow
                }
            }
        }

        Show-ActionProgress 'Diff complete.' 100
        Write-Host 'Diff complete (scope: root *.yaml, packages/, custom_templates/).' -ForegroundColor Green
        $script:ActionIndex++
    }

    if ($Deploy) {
        Show-ActionProgress 'Starting the deployment to Home Assistant...' 10

        if ($File) {
            $relativePath = Get-NormalizedRelativePath -Path $File -BaseDirectory $script:SourceDir
            $localFile = Join-Path $script:SourceDir $relativePath
            if (-not (Test-Path -LiteralPath $localFile -PathType Leaf)) {
                throw "File '$File' not found (resolved to '$localFile')."
            }
            Write-Host "Deploying single file: $relativePath" -ForegroundColor Cyan

            if ($localFile -match '\.ya?ml$') {
                Show-ActionProgress 'Formatting the file...' 30
                Format-Yaml -Files @($localFile)
            }

            if (Test-Proceed -TargetDescription "/config/$relativePath" -Action 'Upload and overwrite') {
                $remoteTarget = '/config/' + $relativePath
                $remoteDir = ('/config/' + (([System.IO.Path]::GetDirectoryName($relativePath)) -replace '\\', '/')).TrimEnd('/')
                if (-not $remoteDir) { $remoteDir = '/config' }

                # One round trip: create the directory and take the backup.
                Show-ActionProgress "Backing up $relativePath on the server..." 60
                $quotedTarget = ConvertTo-ShellQuoted $remoteTarget
                $quotedBackup = ConvertTo-ShellQuoted ($remoteTarget + '.ha_bak')
                $quotedDir = ConvertTo-ShellQuoted $remoteDir
                # A .ha_bak that already exists was left by a failed rollback and is
                # the only copy of the earlier version: stop instead of overwriting it.
                $prepare = Invoke-Ssh -NonFatal -Description "Preparing $remoteDir and backing up the current file..." `
                    -RemoteCommand "if [ -e $quotedBackup ]; then echo BACKUP_EXISTS; exit 3; fi; mkdir -p $quotedDir && if [ -f $quotedTarget ]; then cp -p $quotedTarget $quotedBackup && echo EXISTS; else echo NEW; fi"
                if ($prepare.Text -match 'BACKUP_EXISTS') {
                    throw "A backup from an earlier failed run exists: $remoteTarget.ha_bak. Restore it (mv -f '$remoteTarget.ha_bak' '$remoteTarget') or delete it, then deploy again."
                }
                if ($prepare.ExitCode -ne 0) {
                    throw "Could not back up $relativePath on the server (exit $($prepare.ExitCode)): $($prepare.Text)"
                }

                $script:BackupCreated = $true
                $script:BackupMode = 'Single'
                $script:BackupRelativePath = $relativePath
                $script:RemoteFileExisted = ($prepare.Text -match 'EXISTS')

                Show-ActionProgress "Uploading $relativePath..." 85
                Invoke-Scp -Paths @((ConvertTo-PosixPath $localFile), "$($script:RemoteHost):$remoteDir/") | Out-Null

                Show-ActionProgress "Verifying the upload of $relativePath..." 95
                Assert-UploadIntact -LocalPath $localFile -RemotePath $remoteTarget -DisplayName $relativePath
                $script:DeployCompleted = $true
            }
        } else {
            Write-Host 'Deploying all configuration files (including subfolders)...' -ForegroundColor Cyan

            Show-ActionProgress 'Applying canonical YAML formatting...' 15
            Format-Yaml -Files (Get-ConfigYaml -Root $script:SourceDir)

            # The bundle is built outside the repository: bsdtar packs an archive
            # that lives inside the tree into itself.
            $bundlePath = Join-Path (New-TempRoot) 'config_deploy.tar'

            $excludeArguments = @()
            $ignoreFile = Join-Path $PSScriptRoot '.deployignore'
            if (Test-Path -LiteralPath $ignoreFile) {
                Get-Content -LiteralPath $ignoreFile |
                    Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } |
                    ForEach-Object { $excludeArguments += "--exclude=$($_.Trim())" }
            }
            $excludeArguments += '--exclude=config_deploy.tar'

            Show-ActionProgress 'Bundling the files into a tar archive...' 30
            Write-Host 'Bundling the files locally...' -ForegroundColor Cyan
            $tarPrefix = @(Get-TarArguments)
            $bundle = Invoke-Native -Executable 'tar.exe' -Arguments (@($tarPrefix) + @('-cf', $bundlePath) + $excludeArguments + @('.'))
            if ($bundle.ExitCode -ne 0) {
                throw "Failed to build the deployment bundle: $($bundle.Text)"
            }

            $listing = Invoke-Native -Executable 'tar.exe' -Arguments (@($tarPrefix) + @('-tf', $bundlePath))
            if ($listing.ExitCode -ne 0) {
                throw "Failed to read the deployment bundle: $($listing.Text)"
            }
            # Top-level members of the bundle: exactly what the extract overwrites,
            # and therefore exactly what the backup must cover. The old backup was
            # a fixed list, so anything else the bundle wrote could not be undone.
            $topLevel = @($listing.Lines |
                ForEach-Object { (($_ -replace '^\./', '') -split '/')[0] } |
                Where-Object { $_ -and $_ -ne '.' } |
                Sort-Object -Unique)
            $bundleSizeMb = [math]::Round((Get-Item -LiteralPath $bundlePath).Length / 1MB, 2)
            Write-Host "Bundle: $bundleSizeMb MB, $($listing.Lines.Count) entries. Top level: $($topLevel -join ', ')" -ForegroundColor Gray

            if (Test-Proceed -TargetDescription "/config ($($topLevel.Count) top-level entries)" -Action 'Upload and extract the configuration bundle') {
                Show-ActionProgress 'Creating a remote backup of the affected paths...' 45
                $quotedTar = ConvertTo-ShellQuoted $script:RemoteBackupTar
                $quotedItems = ($topLevel | ForEach-Object { ConvertTo-ShellQuoted $_ }) -join ' '
                # An archive that already exists was left by a failed rollback and is
                # the only copy of the earlier configuration: stop instead of replacing it.
                $backupCommand = 'cd /config && if [ -e __TAR__ ]; then echo BACKUP_EXISTS; exit 3; fi; set -- && for p in __ITEMS__; do [ -e "$p" ] && set -- "$@" "$p"; done; if [ $# -eq 0 ]; then echo COUNT=0; else tar -cf __TAR__ "$@" && echo COUNT=$(tar -tf __TAR__ | wc -l); fi'
                $backupCommand = $backupCommand.Replace('__TAR__', $quotedTar).Replace('__ITEMS__', $quotedItems)
                $backup = Invoke-Ssh -NonFatal -RemoteCommand $backupCommand -Description 'Creating the remote configuration backup...'
                if ($backup.Text -match 'BACKUP_EXISTS') {
                    throw "A backup from an earlier failed run exists: $($script:RemoteBackupTar). Restore it (cd /config && tar -xf <file>) or delete it, then deploy again."
                }

                # 'tar -cf ... || true' used to mask every failure here, so a
                # restore could extract an empty archive and report success.
                $countMatch = [regex]::Match($backup.Text, 'COUNT=(\d+)')
                if (-not $countMatch.Success) {
                    throw "Could not create the remote backup: $($backup.Text)"
                }
                if ([int]$countMatch.Groups[1].Value -le 0) {
                    throw 'The remote backup archive is empty; refusing to deploy without a rollback path.'
                }
                $script:BackupCreated = $true
                $script:BackupMode = 'Full'
                $script:BundleTopLevel = $topLevel
                Write-Host "Remote backup holds $($countMatch.Groups[1].Value) entries." -ForegroundColor Green

                Show-ActionProgress 'Uploading the bundle...' 65
                Invoke-Scp -Description 'Uploading the bundle to Home Assistant...' `
                    -Paths @((ConvertTo-PosixPath $bundlePath), "$($script:RemoteHost):/config/config_deploy.tar") | Out-Null

                Show-ActionProgress 'Verifying the uploaded bundle...' 80
                Assert-UploadIntact -LocalPath $bundlePath -RemotePath '/config/config_deploy.tar' -DisplayName 'config_deploy.tar'

                Show-ActionProgress 'Extracting the bundle on Home Assistant...' 90
                Invoke-Ssh -Description 'Extracting the bundle on Home Assistant...' `
                    -RemoteCommand 'cd /config && tar -xf config_deploy.tar && rm -f config_deploy.tar' | Out-Null
                $script:DeployCompleted = $true
            }
        }

        Show-ActionProgress 'Deployment complete.' 100
        if ($script:DeployCompleted) { Write-Host 'Deployment complete.' -ForegroundColor Green }
        $script:ActionIndex++
    }

    if ($Verify) {
        Show-ActionProgress 'Verifying the Home Assistant configuration...' 50
        Write-Host 'Verifying the Home Assistant configuration...' -ForegroundColor Cyan

        $valid = $false
        try {
            $response = Invoke-RestMethod -Uri "$($script:HaUrl)/api/config/core/check_config" -Method Post -Headers $script:Headers -TimeoutSec 120
            if ((Get-ResponseValue -Response $response -Name 'result') -eq 'valid') {
                $valid = $true
            } else {
                Write-Host 'Configuration is INVALID!' -ForegroundColor Red
                $errors = Get-ResponseValue -Response $response -Name 'errors'
                if ($errors) {
                    Write-Host 'Error details:' -ForegroundColor Red
                    Write-Host $errors -ForegroundColor Red
                }
            }
        } catch {
            Write-Host "Failed to verify the configuration: $_" -ForegroundColor Red
        }

        if (-not $valid) {
            # Roll back here, while the reason is known, rather than leaving it to
            # the exit handler.
            Restore-RemoteBackup
            throw 'Configuration verification failed.'
        }

        Show-ActionProgress 'The configuration is valid.' 100
        Write-Host 'Configuration is VALID!' -ForegroundColor Green
        $script:VerifiedOk = $true
        Remove-RemoteBackup
        $script:ActionIndex++
    }

    if ($Reload) {
        $reloadTarget = if ($Target) { $Target } else { 'All' }
        Show-ActionProgress "Reloading the Home Assistant configuration ($reloadTarget)..." 50
        Write-Host "Reloading the Home Assistant configuration (Target: $reloadTarget)..." -ForegroundColor Cyan

        $reloadMap = @{
            All              = @(
                @{ Service = 'homeassistant/reload_all'; Label = 'All YAML domains' },
                @{ Service = 'frontend/reload_themes'; Label = 'Themes' },
                @{ Service = 'homeassistant/reload_custom_templates'; Label = 'Custom Jinja templates' }
            )
            Core             = @(@{ Service = 'homeassistant/reload_core_config'; Label = 'Core configuration' })
            Automations      = @(@{ Service = 'automation/reload'; Label = 'Automations' })
            Scripts          = @(@{ Service = 'script/reload'; Label = 'Scripts' })
            TemplateEntities = @(@{ Service = 'template/reload'; Label = 'Template entities' })
            Themes           = @(@{ Service = 'frontend/reload_themes'; Label = 'Themes' })
            Rest             = @(@{ Service = 'rest_command/reload'; Label = 'REST commands' })
            Templates        = @(@{ Service = 'homeassistant/reload_custom_templates'; Label = 'Custom Jinja templates' })
        }

        foreach ($operation in $reloadMap[$reloadTarget]) {
            if (-not (Test-Proceed -TargetDescription $operation.Label -Action 'Reload')) { continue }
            try {
                Invoke-RestMethod -Uri "$($script:HaUrl)/api/services/$($operation.Service)" -Method Post -Headers $script:Headers -TimeoutSec 120 | Out-Null
                Write-Host "$($operation.Label) reloaded." -ForegroundColor Green
            } catch {
                # A failed reload used to leave the exit code at 0.
                Write-Host "Failed to reload $($operation.Label): $_" -ForegroundColor Red
                $script:ExitCode = 1
            }
        }

        Show-ActionProgress 'Reload complete.' 100
        $script:ActionIndex++
    }

    if ($Restart) {
        Show-ActionProgress 'Restarting Home Assistant...' 30
        if (Test-Proceed -TargetDescription 'Home Assistant' -Action 'Restart') {
            Write-Host 'Restarting Home Assistant...' -ForegroundColor Cyan
            $sent = $false
            try {
                Invoke-RestMethod -Uri "$($script:HaUrl)/api/services/homeassistant/restart" -Method Post -Headers $script:Headers -TimeoutSec 60 | Out-Null
                $sent = $true
                Write-Host 'Restart command sent.' -ForegroundColor Green
            } catch {
                Write-Host "Failed to restart Home Assistant: $_" -ForegroundColor Red
                $script:ExitCode = 1
            }

            if ($sent) {
                # Wait for the API to answer again, so a chained command sees the
                # real outcome instead of "request accepted".
                Write-Host "Waiting for Home Assistant to come back (timeout $RestartTimeoutSeconds s)..." -ForegroundColor Cyan
                Start-Sleep -Seconds 5
                $deadline = (Get-Date).AddSeconds($RestartTimeoutSeconds)
                $online = $false
                while ((Get-Date) -lt $deadline) {
                    Show-ActionProgress 'Waiting for Home Assistant to come back...' 70
                    try {
                        Invoke-RestMethod -Uri "$($script:HaUrl)/api/" -Method Get -Headers $script:Headers -TimeoutSec 5 | Out-Null
                        $online = $true
                        break
                    } catch {
                        Start-Sleep -Seconds 5
                    }
                }
                if ($online) {
                    Write-Host 'Home Assistant is back online.' -ForegroundColor Green
                } else {
                    Write-Host "Home Assistant did not answer within $RestartTimeoutSeconds s." -ForegroundColor Red
                    $script:ExitCode = 1
                }
            }
        }
        Show-ActionProgress 'Restart complete.' 100
        $script:ActionIndex++
    }

    if (-not ($Deploy -or $Pull -or $Diff -or $Verify -or $Reload -or $Restart)) {
        Write-Host 'Usage: .\ha_control.ps1 [-Deploy] [-Pull] [-Diff] [-File <path>] [-Verify] [-Reload]'
        Write-Host '                        [-Target <All|Core|Automations|Scripts|Themes|Rest|Templates|TemplateEntities>]'
        Write-Host '                        [-Restart] [-Force] [-NoFormat] [-RestartTimeoutSeconds <n>] [-WhatIf]'
        Write-Host ''
        Write-Host 'Run  Get-Help .\ha_control.ps1 -Full  for details.'
    }
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    $script:ExitCode = 1
} finally {
    if ($script:BackupCreated) {
        # A deployment that started but did not finish cleanly is rolled back.
        # This branch used to remove the backup unconditionally, so an aborted
        # upload destroyed the only copy of the previous configuration.
        $clean = $script:DeployCompleted -and ($script:VerifiedOk -or -not $Verify) -and $script:ExitCode -eq 0
        if ($clean) { Remove-RemoteBackup } else { Restore-RemoteBackup }
    }
    if ($script:TempRoot -and (Test-Path -LiteralPath $script:TempRoot)) {
        Remove-Item -Recurse -Force -LiteralPath $script:TempRoot -ErrorAction SilentlyContinue -WhatIf:$false
    }
    Write-Progress -Activity 'Home Assistant Control' -Completed
    Set-Location $script:OriginalLocation
    exit $script:ExitCode
}
