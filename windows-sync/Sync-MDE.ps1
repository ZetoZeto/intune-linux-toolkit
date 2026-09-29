<#
.SYNOPSIS
    Forces a Microsoft Defender for Endpoint (MDE) signature update and telemetry/inventory upload.
.DESCRIPTION
    Updates Defender signatures, then triggers the diagnostic data upload so that the software
    inventory (used by threat & vulnerability management) is reported to the portal without waiting
    for the natural daily cycle. Run from an elevated PowerShell session.
#>

Write-Output "--- Starting MDE synchronization ---"

$mpCmdRun = "C:\Program Files\Windows Defender\MpCmdRun.exe"
if (Test-Path $mpCmdRun) {
    Write-Output "1. Updating Defender signatures..."
    & $mpCmdRun -SignatureUpdate
    Write-Output "[OK] Signatures up to date."

    Write-Output "2. Sending telemetry and TVM inventory..."
    & $mpCmdRun -GetFilesDiagTrack
    Write-Output "[OK] Software inventory pushed to the portal."
} else {
    Write-Output "[ERROR] MpCmdRun.exe not found."
}

Write-Output "--- MDE synchronization done ---"
