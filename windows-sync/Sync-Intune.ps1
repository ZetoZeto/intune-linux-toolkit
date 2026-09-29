<#
.SYNOPSIS
    Forces an immediate Intune check-in on a Windows endpoint.
.DESCRIPTION
    Restarts the MDM (EnterpriseMgmt) scheduled tasks for configuration policies, then restarts the
    Intune Management Extension (IME) and triggers its PushLaunch task for apps and scripts.
    Run from an elevated PowerShell session.
#>

Write-Output "--- Starting Intune synchronization ---"

Write-Output "1. MDM sync (configuration policies)..."
Get-ScheduledTask | Where-Object { $_.TaskPath -match "EnterpriseMgmt" } |
    Start-ScheduledTask -ErrorAction SilentlyContinue
Write-Output "[OK] MDM tasks triggered."

Write-Output "2. IME sync (apps and scripts)..."
try {
    Restart-Service -Name "IntuneManagementExtension" -Force -WarningAction SilentlyContinue
    Start-Sleep -Seconds 5
    Get-ScheduledTask -TaskName "PushLaunch" -ErrorAction SilentlyContinue | Start-ScheduledTask
    Write-Output "[OK] Intune agent restarted and triggered."
} catch {
    Write-Output "[ERROR] Could not restart the Intune agent."
}

Write-Output "--- Intune synchronization done ---"
