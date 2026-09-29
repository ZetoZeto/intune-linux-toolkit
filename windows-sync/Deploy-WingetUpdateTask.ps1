<#
.SYNOPSIS
    Deploys a weekly SYSTEM scheduled task that runs `winget upgrade --all`.
.DESCRIPTION
    Intended to be pushed as an Intune Platform Script.
    Intune settings: Run as logged-on credentials = No, Enforce signature check = No, 64-bit = Yes.
    Writes the runner script to C:\ProgramData\IntuneWingetUpdate\, registers the task, and is
    idempotent (an existing task is replaced). Logs: deploy.log, winget-upgrade.log in the same dir.
#>

$ErrorActionPreference = "Stop"

$installDir = "C:\ProgramData\IntuneWingetUpdate"
$scriptPath = Join-Path $installDir "Invoke-WingetUpgrade.ps1"
$deployLog  = Join-Path $installDir "deploy.log"
$taskName   = "IntuneWingetUpdate"

function Write-DeployLog($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -FilePath $deployLog -Append -Encoding utf8
}

try {
    if (-not (Test-Path $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }

    Write-DeployLog "=== Deploying IntuneWingetUpdate ==="

    # --- Runner script content (dropped on the endpoint) ---
    $upgradeScript = @'
# Invoke-WingetUpgrade.ps1
# Executed by the IntuneWingetUpdate scheduled task (SYSTEM)
$ErrorActionPreference = "Stop"
$logDir  = "C:\ProgramData\IntuneWingetUpdate"
$logFile = Join-Path $logDir "winget-upgrade.log"

function Write-Log($msg) {
    "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" | Out-File -FilePath $logFile -Append -Encoding utf8
}

try {
    Write-Log "=== Running winget upgrade --all ==="

    # Resolve winget.exe from WindowsApps (it is not on SYSTEM's PATH)
    $wingetPath = Get-ChildItem "C:\Program Files\WindowsApps" -Filter "winget.exe" -Recurse -ErrorAction SilentlyContinue |
                  Where-Object { $_.FullName -match "Microsoft.DesktopAppInstaller_.*_x64" } |
                  Sort-Object FullName -Descending |
                  Select-Object -First 1 -ExpandProperty FullName

    if (-not $wingetPath) {
        Write-Log "ERROR: winget.exe not found in WindowsApps"
        exit 1
    }
    Write-Log "winget: $wingetPath"

    $wingetArgs = @(
        "upgrade", "--all",
        "--silent",
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--disable-interactivity",
        "--include-unknown"
    )

    $output = & $wingetPath @wingetArgs 2>&1 | Out-String
    Write-Log "winget output:`n$output"
    Write-Log "winget exit code: $LASTEXITCODE"
    Write-Log "=== Done ==="
    exit 0
}
catch {
    Write-Log "EXCEPTION: $_"
    exit 1
}
'@

    Set-Content -Path $scriptPath -Value $upgradeScript -Encoding UTF8 -Force
    Write-DeployLog "Runner script written: $scriptPath"

    # --- Create / update the scheduled task ---
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" `
                    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

    $trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Wednesday -At 3:00AM

    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    $settings  = New-ScheduledTaskSettingsSet `
                    -StartWhenAvailable `
                    -RunOnlyIfNetworkAvailable `
                    -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries `
                    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
                    -MultipleInstances IgnoreNew

    # Remove any existing task first (idempotence)
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-DeployLog "Existing task removed"
    }

    Register-ScheduledTask -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Upgrades all winget packages (deployed via Intune)" | Out-Null

    Write-DeployLog "Scheduled task '$taskName' created (Wednesday 03:00)"
    Write-DeployLog "=== Deploy OK ==="
    exit 0
}
catch {
    Write-DeployLog "EXCEPTION: $_"
    exit 1
}
