[CmdletBinding()]
param (
    [switch]$Deploy,
    [switch]$Pull,
    [switch]$Diff,
    [string]$File,
    [switch]$Verify,
    [switch]$Reload,
    [ValidateSet('All', 'Core', 'Automations', 'Scripts', 'Themes', 'Rest', 'Templates', 'TemplateEntities')]
    [string]$Target,
    [switch]$Restart
)

$originalLocation = Get-Location

# Track overall pipeline progress across flags
$actionList = @()
if ($Pull)    { $actionList += "Pull" }
if ($Diff)    { $actionList += "Diff" }
if ($Deploy)  { $actionList += "Deploy" }
if ($Verify)  { $actionList += "Verify" }
if ($Reload)  { $actionList += "Reload" }
if ($Restart) { $actionList += "Restart" }

$totalActions = $actionList.Count
$currentActionIndex = 0

function Show-ActionProgress {
    param([string]$Status, [int]$StepPercent = 0)
    if ($totalActions -gt 0 -and $currentActionIndex -lt $totalActions) {
        $basePercent = [math]::Floor(($currentActionIndex / $totalActions) * 100)
        $stepWeight = 100 / $totalActions
        $overallPercent = [math]::Min(100, [math]::Floor($basePercent + ($stepWeight * ($StepPercent / 100))))
        Write-Progress -Activity "Home Assistant Control ($($actionList[$currentActionIndex]))" -Status $Status -PercentComplete $overallPercent
    }
}

function Exec-Command {
    param(
        [string]$Command,
        [string]$Description
    )
    if ($Description) {
        Write-Host $Description -ForegroundColor Cyan
    }
    Invoke-Expression $Command
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: Command failed with exit code $LASTEXITCODE." -ForegroundColor Red
        exit $LASTEXITCODE
    }
}

try {
    $envFilePath = Join-Path $PSScriptRoot "..\.env"
    if (Test-Path $envFilePath) {
        Get-Content $envFilePath | ForEach-Object {
            if ($_ -match '^\s*(?<name>[^=]+)\s*=\s*"?(?<value>[^"]*)"?\s*$') {
                Set-Item -Path "Env:$($matches['name'])" -Value $matches['value']
            }
        }
    } else {
        Write-Host "Error: .env file not found at $envFilePath." -ForegroundColor Red
        exit 1
    }

    $HA_URL = $env:HA_URL
    $HA_SSH_USER = $env:HA_SSH_USER
    $HA_SSH_HOST = $env:HA_SSH_HOST
    $HA_SSH_PORT = $env:HA_SSH_PORT
    $HA_TOKEN = $env:HA_TOKEN
    $CIPHER = "-c aes256-gcm@openssh.com"

    $HEADERS = @{
        "Authorization" = "Bearer $HA_TOKEN"
        "Content-Type"  = "application/json"
    }

    # Track remote backup state for automatic rollback on -Verify failure
    $script:backupCreated = $false
    $script:backupMode = ""
    $script:backupRelativePath = ""
    $script:remoteFileExisted = $false

    function Restore-RemoteBackup {
        if (-not $script:backupCreated) { return }

        Write-Host "`nRestoring Home Assistant configuration to pre-deployment state..." -ForegroundColor Yellow
        try {
            if ($script:backupMode -eq "Single") {
                $remoteTarget = "/config/" + $script:backupRelativePath
                $remoteBak = "$remoteTarget.ha_bak"
                if ($script:remoteFileExisted) {
                    Exec-Command "ssh $CIPHER -p $HA_SSH_PORT ${HA_SSH_USER}@${HA_SSH_HOST} `"mv -f '$remoteBak' '$remoteTarget'`"" "Restoring previous version of $script:backupRelativePath..."
                } else {
                    Exec-Command "ssh $CIPHER -p $HA_SSH_PORT ${HA_SSH_USER}@${HA_SSH_HOST} `"rm -f '$remoteTarget' '$remoteBak'`"" "Removing new unverified file $script:backupRelativePath..."
                }
            } elseif ($script:backupMode -eq "Full") {
                $remoteTar = "/config/.ha_control_deploy_backup.tar"
                Exec-Command "ssh $CIPHER -p $HA_SSH_PORT ${HA_SSH_USER}@${HA_SSH_HOST} `"cd /config && tar -xf '$remoteTar' && rm -f '$remoteTar'`"" "Restoring full configuration from backup archive..."
            }
            Write-Host "Remote configuration successfully restored." -ForegroundColor Green
        } catch {
            Write-Host "Warning: Exception during remote restoration: $_" -ForegroundColor Red
        } finally {
            $script:backupCreated = $false
        }
    }

    function Remove-RemoteBackup {
        if (-not $script:backupCreated) { return }
        try {
            if ($script:backupMode -eq "Single") {
                $remoteBak = "/config/" + $script:backupRelativePath + ".ha_bak"
                Exec-Command "ssh $CIPHER -p $HA_SSH_PORT ${HA_SSH_USER}@${HA_SSH_HOST} `"rm -f '$remoteBak'`""
            } elseif ($script:backupMode -eq "Full") {
                $remoteTar = "/config/.ha_control_deploy_backup.tar"
                Exec-Command "ssh $CIPHER -p $HA_SSH_PORT ${HA_SSH_USER}@${HA_SSH_HOST} `"rm -f '$remoteTar'`""
            }
        } catch {
            # Ignore silent cleanup errors
        } finally {
            $script:backupCreated = $false
        }
    }

    # Path to the shared canonical-formatting helper used by -Diff, -Pull and -Deploy.
    $YamlTool = Join-Path $PSScriptRoot "ha_yaml.py"

    function Format-Yaml {
        param([string[]]$Files)

        $existing = @($Files | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) })
        if ($existing.Count -eq 0) { return }

        Write-Host "Applying canonical YAML formatting to $($existing.Count) file(s)..." -ForegroundColor Cyan
        $output = & python $YamlTool format @existing 2>&1
        if ($LASTEXITCODE -gt 1 -or ($output -match 'not installed')) {
            Write-Host "  Skipped formatting (Python/ruamel.yaml unavailable)." -ForegroundColor Yellow
            return
        }
        $output | Where-Object { $_ -like 'formatted:*' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
        $output | Where-Object { $_ -like 'skip *' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    }

    function Get-ConfigYaml {
        param([string]$Root)
        $files = @(Get-ChildItem -Path $Root -Filter *.yaml -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
        $pkg = Join-Path $Root "packages"
        if (Test-Path $pkg) {
            $files += @(Get-ChildItem -Path $pkg -Filter *.yaml -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object FullName)
        }
        return $files
    }

    function Invoke-YamlDiff {
        param(
            [string]$LocalFile,
            [string]$RemoteFile,
            [string]$DisplayName
        )

        if ($DisplayName -notmatch '\.ya?ml$') {
            $cmp = Compare-Object -ReferenceObject @(Get-Content $LocalFile) -DifferenceObject @(Get-Content $RemoteFile)
            if ($cmp) {
                Write-Host "`n--- DIFF FOR $DisplayName (raw text; => means HA, <= means local) ---" -ForegroundColor Magenta
                $cmp | Format-Table -AutoSize
            } else {
                Write-Host "$DisplayName is identical." -ForegroundColor Green
            }
            return
        }

        $output = & python $YamlTool diff $LocalFile $RemoteFile $DisplayName 2>$null
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Host "$DisplayName is identical (ignoring formatting)." -ForegroundColor Green
        } elseif ($exitCode -eq 1) {
            Write-Host "`n--- DIFF FOR $DisplayName (- local, + HA) ---" -ForegroundColor Magenta
            foreach ($line in $output) {
                if ($line -like '+*') { Write-Host $line -ForegroundColor Green }
                elseif ($line -like '-*') { Write-Host $line -ForegroundColor Red }
                elseif ($line -like '@@*') { Write-Host $line -ForegroundColor Cyan }
                else { Write-Host $line }
            }
        } else {
            $cmp = Compare-Object -ReferenceObject @(Get-Content $LocalFile) -DifferenceObject @(Get-Content $RemoteFile)
            if ($cmp) {
                Write-Host "`n--- DIFF FOR $DisplayName (raw text fallback; => means HA, <= means local) ---" -ForegroundColor Magenta
                $cmp | Format-Table -AutoSize
            } else {
                Write-Host "$DisplayName is identical." -ForegroundColor Green
            }
        }
    }

    if ($Pull) {
        Show-ActionProgress "Pulling configuration from Home Assistant..." 10
        $sourceDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        Set-Location $sourceDir
        
        if ($File) {
            Write-Host "Pulling single file: $File" -ForegroundColor Cyan
            $relativePath = $File -replace "^.\\", "" -replace "^..\\", "" -replace "\\", "/"
            $remoteFile = "/config/$relativePath"
            $localFile = Join-Path $sourceDir $relativePath

            Show-ActionProgress "Downloading $relativePath via SCP..." 50
            Exec-Command "scp -O $CIPHER -P $HA_SSH_PORT `"${HA_SSH_USER}@${HA_SSH_HOST}:$remoteFile`" `"$localFile`""
            if ($localFile -match '\.ya?ml$') {
                Show-ActionProgress "Formatting pulled YAML..." 90
                Format-Yaml -Files @($localFile)
            }
        } else {
            Show-ActionProgress "Pulling root YAML files..." 25
            Exec-Command "scp -O $CIPHER -P $HA_SSH_PORT `"${HA_SSH_USER}@${HA_SSH_HOST}:/config/*.yaml`" ./" "Pulling root YAML files..."
            
            Show-ActionProgress "Pulling packages directory..." 50
            Exec-Command "scp -O -r $CIPHER -P $HA_SSH_PORT `"${HA_SSH_USER}@${HA_SSH_HOST}:/config/packages`" ./" "Pulling packages folder..."
            
            Show-ActionProgress "Pulling custom_templates directory..." 75
            Exec-Command "scp -O -r $CIPHER -P $HA_SSH_PORT `"${HA_SSH_USER}@${HA_SSH_HOST}:/config/custom_templates`" ./" "Pulling custom_templates folder..."
            
            Write-Host "If you want to pull a file from a different subfolder, use -Pull -File <path>." -ForegroundColor Yellow
            
            Show-ActionProgress "Formatting pulled YAML files..." 90
            Format-Yaml -Files (Get-ConfigYaml -Root $sourceDir)
        }

        Show-ActionProgress "Pull complete." 100
        Write-Host "Pull complete. Use 'git diff' to review the changes made by the HA UI!" -ForegroundColor Green
        $currentActionIndex++
    }

    if ($Diff) {
        Show-ActionProgress "Initializing dry run diff..." 10
        $sourceDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        Set-Location $sourceDir
        
        $tempDir = Join-Path $sourceDir ".temp_pull"
        if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }
        
        try {
            if ($File) {
                $relativePath = $File -replace "^.\\", "" -replace "^..\\", "" -replace "\\", "/"
                $remoteFile = "/config/$relativePath"
                $localFile = Join-Path $sourceDir $relativePath
                $tempFile = Join-Path $tempDir "temp_file"
                if (Test-Path $tempFile) { Remove-Item -Force $tempFile }
                
                Show-ActionProgress "Downloading remote $relativePath..." 50
                Exec-Command "scp -O $CIPHER -P $HA_SSH_PORT `"${HA_SSH_USER}@${HA_SSH_HOST}:$remoteFile`" `"$tempFile`""
                
                Show-ActionProgress "Comparing files..." 90
                if (Test-Path $tempFile) {
                    Invoke-YamlDiff -LocalFile $localFile -RemoteFile $tempFile -DisplayName $relativePath
                } elseif (Test-Path $localFile -PathType Leaf) {
                    Write-Host "$relativePath exists locally but NOT on the server." -ForegroundColor Yellow
                } else {
                    Write-Host "$relativePath was not found locally or on the server." -ForegroundColor Red
                }
            } else {
                Show-ActionProgress "Downloading remote config to temporary folder..." 40
                Exec-Command "scp -O $CIPHER -P $HA_SSH_PORT `"${HA_SSH_USER}@${HA_SSH_HOST}:/config/*.yaml`" `"$tempDir`""
                Exec-Command "scp -O -r $CIPHER -P $HA_SSH_PORT `"${HA_SSH_USER}@${HA_SSH_HOST}:/config/packages`" `"$tempDir`""
                Exec-Command "scp -O -r $CIPHER -P $HA_SSH_PORT `"${HA_SSH_USER}@${HA_SSH_HOST}:/config/custom_templates`" `"$tempDir`""

                Show-ActionProgress "Comparing local and remote files..." 80
                $resolvedTempDir = (Resolve-Path $tempDir).Path
                Get-ChildItem -Path $resolvedTempDir -Recurse -File -Include *.yaml, *.jinja | ForEach-Object {
                    $relPath = $_.FullName.Substring($resolvedTempDir.Length + 1)
                    $localFile = Join-Path $sourceDir $relPath
                    if (Test-Path $localFile -PathType Leaf) {
                        Invoke-YamlDiff -LocalFile $localFile -RemoteFile $_.FullName -DisplayName $relPath
                    } else {
                        Write-Host "$relPath only exists on server." -ForegroundColor Yellow
                    }
                }

                $localScope = @(Get-ConfigYaml -Root $sourceDir)
                $ctDir = Join-Path $sourceDir "custom_templates"
                if (Test-Path $ctDir) {
                    $localScope += @(Get-ChildItem -Path $ctDir -Recurse -File -Include *.jinja, *.yaml | ForEach-Object FullName)
                }
                foreach ($lf in $localScope) {
                    $relPath = $lf.Substring($sourceDir.Length + 1)
                    if (-not (Test-Path (Join-Path $resolvedTempDir $relPath) -PathType Leaf)) {
                        Write-Host "$relPath exists locally but NOT on the server." -ForegroundColor Yellow
                    }
                }
            }
        } finally {
            if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
        }

        Show-ActionProgress "Diff complete." 100
        Write-Host "Diff complete." -ForegroundColor Green
        $currentActionIndex++
    }

    if ($Deploy) {
        Show-ActionProgress "Starting deployment to Home Assistant..." 10
        $sourceDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
        Set-Location $sourceDir
        
        if ($File) {
            $relativePath = $File -replace "^.\\", "" -replace "^..\\", "" -replace "\\", "/"
            $localFile = Join-Path $sourceDir $relativePath
            if (-not (Test-Path $localFile)) {
                Write-Host "Error: File '$File' not found (resolved to '$localFile')." -ForegroundColor Red
                exit 1
            }
            Write-Host "Deploying single file: $relativePath" -ForegroundColor Cyan

            if ($localFile -match '\.ya?ml$') {
                Show-ActionProgress "Formatting single file..." 30
                Format-Yaml -Files @($localFile)
            }

            $targetDir = "/config/" + (Split-Path $relativePath -Parent).Replace("\", "/")
            if ($targetDir -ne "/config/") {
                Show-ActionProgress "Creating remote directory..." 50
                Exec-Command "ssh $CIPHER -p $HA_SSH_PORT ${HA_SSH_USER}@${HA_SSH_HOST} `"mkdir -p $targetDir`""
            }

            $remoteTarget = "/config/$relativePath"
            $remoteBak = "$remoteTarget.ha_bak"
            Show-ActionProgress "Creating remote backup of $relativePath..." 70
            $checkOutput = & ssh $CIPHER -p $HA_SSH_PORT "${HA_SSH_USER}@${HA_SSH_HOST}" "if [ -f '$remoteTarget' ]; then cp '$remoteTarget' '$remoteBak'; echo 'EXISTS'; else echo 'NEW'; fi" 2>&1
            $script:backupCreated = $true
            $script:backupMode = "Single"
            $script:backupRelativePath = $relativePath
            $script:remoteFileExisted = ($checkOutput -match 'EXISTS')

            Show-ActionProgress "Uploading $relativePath via SCP..." 90
            Exec-Command "scp -O $CIPHER -P $HA_SSH_PORT `"$localFile`" `"${HA_SSH_USER}@${HA_SSH_HOST}:$targetDir/`""
        } else {
            Write-Host "Deploying all configuration files (including subfolders)..." -ForegroundColor Cyan

            Show-ActionProgress "Applying canonical YAML formatting..." 20
            Format-Yaml -Files (Get-ConfigYaml -Root $sourceDir)

            Show-ActionProgress "Creating remote full configuration backup..." 30
            $remoteTar = "/config/.ha_control_deploy_backup.tar"
            Exec-Command "ssh $CIPHER -p $HA_SSH_PORT ${HA_SSH_USER}@${HA_SSH_HOST} `"cd /config && tar -cf '$remoteTar' *.yaml packages custom_templates 2>/dev/null || true`"" "Creating remote full config backup..."
            $script:backupCreated = $true
            $script:backupMode = "Full"

            Show-ActionProgress "Bundling files into tar archive..." 50
            $ignoreFile = Join-Path $PSScriptRoot ".deployignore"
            $excludeArgs = ""
            if (Test-Path $ignoreFile) {
                Get-Content $ignoreFile | Where-Object { $_.Trim() -ne "" -and -not $_.StartsWith("#") } | ForEach-Object {
                    $excludeArgs += "--exclude=`"$($_.Trim())`" "
                }
            }
            $excludeArgs += "--exclude=`"config_deploy.tar`""
            
            try {
                Exec-Command "tar.exe -cf config_deploy.tar $excludeArgs ." "Bundling files locally..."
                
                Show-ActionProgress "Uploading bundle to Home Assistant via SCP..." 70
                Exec-Command "scp -O $CIPHER -P $HA_SSH_PORT config_deploy.tar ${HA_SSH_USER}@${HA_SSH_HOST}:/config/" "Uploading bundle to Home Assistant..."
                
                Show-ActionProgress "Extracting bundle on Home Assistant..." 90
                Exec-Command "ssh $CIPHER -p $HA_SSH_PORT ${HA_SSH_USER}@${HA_SSH_HOST} `"cd /config && tar -xf config_deploy.tar && rm config_deploy.tar`"" "Extracting bundle on Home Assistant..."
            } finally {
                if (Test-Path "config_deploy.tar") {
                    Write-Host "Cleaning up local bundle..." -ForegroundColor Gray
                    Remove-Item -Force "config_deploy.tar"
                }
            }
        }
        
        Show-ActionProgress "Deployment complete." 100
        Write-Host "Deployment complete." -ForegroundColor Green
        $currentActionIndex++
    }

    if ($Verify) {
        Show-ActionProgress "Verifying Home Assistant configuration..." 50
        Write-Host "Verifying Home Assistant configuration..." -ForegroundColor Cyan
        $verificationSuccess = $false
        try {
            $response = Invoke-RestMethod -Uri "$HA_URL/api/config/core/check_config" -Method Post -Headers $HEADERS -ErrorAction Stop
            if ($response.result -eq "valid") {
                Show-ActionProgress "Configuration is valid!" 100
                Write-Host "Configuration is VALID!" -ForegroundColor Green
                $verificationSuccess = $true
                Remove-RemoteBackup
            } else {
                Write-Host "Configuration is INVALID!" -ForegroundColor Red
                if ($response.errors) {
                    Write-Host "Error details:" -ForegroundColor Red
                    Write-Host $response.errors -ForegroundColor Red
                }
            }
        } catch {
            Write-Host "Failed to verify configuration: $_" -ForegroundColor Red
        }

        if (-not $verificationSuccess) {
            Restore-RemoteBackup
            exit 1
        }
        $currentActionIndex++
    }

    if ($Reload) {
        $reloadTarget = if ($Target) { $Target } else { "All" }
        Show-ActionProgress "Reloading Home Assistant configuration ($reloadTarget)..." 50
        Write-Host "Reloading Home Assistant configuration (Target: $reloadTarget)..." -ForegroundColor Cyan
        try {
            if ($reloadTarget -eq "All") {
                Invoke-RestMethod -Uri "$HA_URL/api/services/homeassistant/reload_all" -Method Post -Headers $HEADERS -ErrorAction Stop
                Write-Host "All YAML domains reloaded (reload_all)." -ForegroundColor Green

                Invoke-RestMethod -Uri "$HA_URL/api/services/frontend/reload_themes" -Method Post -Headers $HEADERS -ErrorAction Stop
                Write-Host "Themes reloaded." -ForegroundColor Green
                
                Invoke-RestMethod -Uri "$HA_URL/api/services/homeassistant/reload_custom_templates" -Method Post -Headers $HEADERS -ErrorAction Stop
                Write-Host "Custom Jinja templates reloaded." -ForegroundColor Green
            } else {
                if ($reloadTarget -eq "Core") {
                    Invoke-RestMethod -Uri "$HA_URL/api/services/homeassistant/reload_core_config" -Method Post -Headers $HEADERS -ErrorAction Stop
                    Write-Host "Core configuration reloaded." -ForegroundColor Green
                }
                if ($reloadTarget -eq "Automations") {
                    Invoke-RestMethod -Uri "$HA_URL/api/services/automation/reload" -Method Post -Headers $HEADERS -ErrorAction Stop
                    Write-Host "Automations reloaded." -ForegroundColor Green
                }
                if ($reloadTarget -eq "Scripts") {
                    Invoke-RestMethod -Uri "$HA_URL/api/services/script/reload" -Method Post -Headers $HEADERS -ErrorAction Stop
                    Write-Host "Scripts reloaded." -ForegroundColor Green
                }
                if ($reloadTarget -eq "TemplateEntities") {
                    Invoke-RestMethod -Uri "$HA_URL/api/services/template/reload" -Method Post -Headers $HEADERS -ErrorAction Stop
                    Write-Host "Template entities reloaded." -ForegroundColor Green
                }
                if ($reloadTarget -eq "Themes") {
                    Invoke-RestMethod -Uri "$HA_URL/api/services/frontend/reload_themes" -Method Post -Headers $HEADERS -ErrorAction Stop
                    Write-Host "Themes reloaded." -ForegroundColor Green
                }
                if ($reloadTarget -eq "Rest") {
                    Invoke-RestMethod -Uri "$HA_URL/api/services/rest_command/reload" -Method Post -Headers $HEADERS -ErrorAction Stop
                    Write-Host "Rest Commands reloaded." -ForegroundColor Green
                }
                if ($reloadTarget -eq "Templates") {
                    Invoke-RestMethod -Uri "$HA_URL/api/services/homeassistant/reload_custom_templates" -Method Post -Headers $HEADERS -ErrorAction Stop
                    Write-Host "Custom Jinja templates reloaded." -ForegroundColor Green
                }
            }
        } catch {
            Write-Host "Failed to reload configuration: $_" -ForegroundColor Red
        }
        Show-ActionProgress "Reload complete." 100
        $currentActionIndex++
    }

    if ($Restart) {
        Show-ActionProgress "Restarting Home Assistant..." 50
        Write-Host "Restarting Home Assistant..." -ForegroundColor Cyan
        try {
            Invoke-RestMethod -Uri "$HA_URL/api/services/homeassistant/restart" -Method Post -Headers $HEADERS -ErrorAction Stop
            Write-Host "Restart command sent successfully." -ForegroundColor Green
        } catch {
            Write-Host "Failed to restart Home Assistant: $_" -ForegroundColor Red
        }
        Show-ActionProgress "Restart request sent." 100
        $currentActionIndex++
    }

    if (-not ($Deploy -or $Pull -or $Diff -or $Verify -or $Reload -or $Restart)) {
        Write-Host "Usage: .\ha_control.ps1 [-Deploy] [-Pull] [-Diff] [-File <path>] [-Verify] [-Reload] [-Target <All|Core|Automations|Scripts|Themes|Rest|Templates|TemplateEntities>] [-Restart]"
    }
} finally {
    Remove-RemoteBackup
    Write-Progress -Activity "Home Assistant Control" -Completed
    Set-Location $originalLocation
}
