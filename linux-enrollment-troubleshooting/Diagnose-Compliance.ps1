<#
.SYNOPSIS
    Read-only Intune/Graph diagnostic for a Linux device stuck "Not compliant" / "Not evaluated".
.DESCRIPTION
    Explains why a Linux endpoint is non-compliant device-side and "Not evaluated" policy-side, by
    querying: the tenant compliance fallback, Linux compliance policies and their assignments, the
    per-device compliance state, and a comparison between the broken device and a healthy baseline.
    Read-only. No tenant modification. Output: console + ~/diag-compliance-<timestamp>.txt

    Requires PowerShell 7+ and the Microsoft.Graph module. Consents to read-only scopes only.
.PARAMETER Device
    Host name of the device under investigation.
.PARAMETER Baseline
    Host names of known-healthy Linux devices to compare against.
#>
[CmdletBinding()]
param(
    [string]   $Device   = 'linux-test',
    [string[]] $Baseline = @('linux-a', 'linux-b', 'linux-c', 'linux-d')
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$out   = Join-Path $HOME "diag-compliance-$stamp.txt"
Start-Transcript -Path $out -Force | Out-Null

function Section($t) { "`n" + ('=' * 78); "== $t"; ('=' * 78) }
function G($uri) {
    try { Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop }
    catch { "   !! FAILED $uri`n   !! $($_.Exception.Message)" | Write-Host -ForegroundColor Red; $null }
}

Connect-MgGraph -NoWelcome -Scopes @(
    'DeviceManagementManagedDevices.Read.All',
    'DeviceManagementConfiguration.Read.All',
    'DeviceManagementServiceConfig.Read.All',
    'Device.Read.All',
    'Group.Read.All',
    'Directory.Read.All'
)

"Collection timestamp : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
"Tenant : $((Get-MgContext).TenantId)"

# ---------------------------------------------------------------- 1. tenant fallback
Section '1. Tenant fallback - "Mark devices with no compliance policy assigned as"'
$s = G 'https://graph.microsoft.com/beta/deviceManagement/settings'
if ($s) {
    [pscustomobject]@{
        secureByDefault                      = $s.secureByDefault
        deviceComplianceCheckinThresholdDays = $s.deviceComplianceCheckinThresholdDays
        isScheduledActionEnabled             = $s.isScheduledActionEnabled
    } | Format-List
    if ($s.secureByDefault) {
        "  -> secureByDefault = True : a device with NO policy assigned is marked NOT COMPLIANT."
        "     This is candidate #1 for the 'not compliant' state of $Device."
    } else {
        "  -> secureByDefault = False : a device with no policy is marked COMPLIANT."
        "     The 'not compliant' comes from elsewhere: a policy targets the device and a rule fails,"
        "     OR the device exceeds deviceComplianceCheckinThresholdDays without a check-in."
    }
}

# --------------------------------------------------- 2. Linux compliance policies
Section '2. Compliance policies targeting Linux, and their assignments'

$groupCache = @{}
function GroupName($id) {
    if (-not $id) { return '(all resources / All)' }
    if ($groupCache.ContainsKey($id)) { return $groupCache[$id] }
    $g = G "https://graph.microsoft.com/v1.0/groups/$id"
    $n = if ($g) { $g.displayName } else { "(group $id not found)" }
    $groupCache[$id] = $n; $n
}

function ShowAssignments($assignments) {
    if (-not $assignments) { "   (no assignment)"; return }
    foreach ($a in $assignments) {
        $t    = $a.target.'@odata.type'
        $gid  = $a.target.groupId
        $mode = if ($t -match 'exclusionGroupAssignmentTarget') { 'EXCLUDED' }
                elseif ($t -match 'groupAssignmentTarget')      { 'included' }
                elseif ($t -match 'allDevices')                 { 'included (All Devices)' }
                elseif ($t -match 'allLicensedUsers')           { 'included (All Users)' }
                else                                            { $t }
        "   [{0,-22}] {1}" -f $mode, (GroupName $gid)
    }
}

# 2a - "classic" compliance
$classic = G 'https://graph.microsoft.com/beta/deviceManagement/deviceCompliancePolicies?$expand=assignments'
foreach ($p in ($classic.value | Where-Object { $_.'@odata.type' -match 'linux' -or $_.displayName -match 'linux' })) {
    "`n-- [deviceCompliancePolicies] $($p.displayName)   ($($p.'@odata.type'))"
    "   id : $($p.id)"
    ShowAssignments $p.assignments
}

# 2b - settings-catalog compliance (where modern Linux policies live)
$modern = G 'https://graph.microsoft.com/beta/deviceManagement/compliancePolicies?$expand=assignments,scheduledActionsForRule($expand=scheduledActionConfigurations)'
foreach ($p in ($modern.value | Where-Object { $_.technologies -match 'linux' -or $_.platforms -match 'linux' -or $_.name -match 'linux' })) {
    "`n-- [compliancePolicies] $($p.name)"
    "   id : $($p.id)   platforms : $($p.platforms)   technologies : $($p.technologies)"
    foreach ($r in $p.scheduledActionsForRule) {
        foreach ($c in $r.scheduledActionConfigurations) {
            "   action : $($c.actionType) after $($c.gracePeriodHours) h grace"
        }
    }
    ShowAssignments $p.assignments
}

# ------------------------------------------------------- 3. Linux device state
Section '3. managedDevices Linux - filter managementAgent eq mdm'
$md = G "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=managementAgent eq 'mdm'&`$top=200"
$linux = $md.value | Where-Object { $_.operatingSystem -match 'Linux' }
$linux | Select-Object deviceName, complianceState, complianceGracePeriodExpirationDateTime,
    operatingSystem, osVersion, lastSyncDateTime, managementState, azureADDeviceId |
    Sort-Object deviceName | Format-Table -AutoSize -Wrap

"NB : an object with a null azureADDeviceId is a Defender (msSense) record, not an MDM enrollment."

# ------------------------------------- 4. per-policy state, broken vs healthy
Section "4. Per-policy state - $Device vs baseline"
foreach ($name in @($Device) + $Baseline) {
    $d = $linux | Where-Object deviceName -eq $name | Select-Object -First 1
    if (-not $d) { "`n-- $name : ABSENT from the MDM inventory"; continue }
    "`n-- $name  (managedDevice $($d.id))"
    "   complianceState : $($d.complianceState)   lastSync : $($d.lastSyncDateTime)   osVersion : $($d.osVersion)"
    "   grace expires : $($d.complianceGracePeriodExpirationDateTime)"
    $st = G "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($d.id)/deviceCompliancePolicyStates"
    if ($st.value) {
        $st.value | Select-Object displayName, state, settingCount, userPrincipalName | Format-Table -AutoSize
    } else {
        "   (no deviceCompliancePolicyState : NO policy evaluated this device -> 'Not evaluated')"
    }
}

# ------------------------------------------------- 5. Entra object and memberships
Section "5. Entra object of $Device and its groups"
$ent = G "https://graph.microsoft.com/v1.0/devices?`$filter=startswith(displayName,'$Device')"
foreach ($e in $ent.value) {
    "`n-- object $($e.id)   deviceId $($e.deviceId)"
    $e | Select-Object displayName, trustType, managementType, isManaged, isCompliant,
        operatingSystem, operatingSystemVersion, createdDateTime, approximateLastSignInDateTime |
        Format-List
    $mo = G "https://graph.microsoft.com/v1.0/devices/$($e.id)/memberOf"
    $names = @($mo.value | ForEach-Object { $_.displayName })
    "   groups : " + ($(if ($names) { $names -join ', ' } else { '(none)' }))
}

# ------------------------------------------------------------------ 6. baseline Entra
Section '6. Entra objects of the healthy devices, for comparison'
foreach ($name in $Baseline) {
    $b = G "https://graph.microsoft.com/v1.0/devices?`$filter=startswith(displayName,'$name')"
    $b.value | Select-Object displayName, trustType, managementType, isManaged, isCompliant, operatingSystemVersion |
        Format-Table -AutoSize
}

Section 'End'
"Report : $out"
"The file contains tenant ID, host names and UPNs : review it before sharing."
Stop-Transcript | Out-Null
