<#
.SYNOPSIS
  Auto-scales an Azure SQL Database up or down based on Azure Monitor Metric Alerts (DTU %).
  Designed for use with Azure Monitor Action Groups -> Automation Runbook receiver (Common Alert Schema ON).

.PARAMETER WebhookData
  (Optional) Common Alert Schema payload from Azure Monitor. If supplied, the runbook will
  parse database identifiers and decide ScaleUp/ScaleDown from the alert condition.

.PARAMETER ResourceGroupName
.PARAMETER ServerName
.PARAMETER DatabaseName
  (Optional) Explicit identifiers. If WebhookData is not provided, these are required.

.PARAMETER Mode
  (Optional) 'ScaleUp' or 'ScaleDown'. If omitted and WebhookData is present, it is inferred.

.NOTES
  Requires modules Az.Accounts and Az.Sql (imported in the ARM template).
#>

param(
  [Parameter(Mandatory = $false)]
  [object]$WebhookData,

  [Parameter(Mandatory = $false)]
  [string]$ResourceGroupName,

  [Parameter(Mandatory = $false)]
  [string]$ServerName,

  [Parameter(Mandatory = $false)]
  [string]$DatabaseName,

  [Parameter(Mandatory = $false)]
  [ValidateSet('ScaleUp','ScaleDown')]
  [string]$Mode
)

# ------------------------------
# Helper: Log
function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $ts = (Get-Date).ToString('s')
  Write-Output "[$ts][$Level] $Message"
}

# ------------------------------
# Helper: Parse Common Alert Schema (Metric Alert)
function Parse-AlertPayload {
  param([object]$WebhookData)

  if (-not $WebhookData) { return $null }

  try {
    $body = $WebhookData.RequestBody
    if (-not $body) { return $null }

    $payload = $body | ConvertFrom-Json -ErrorAction Stop

    # From Common Alert Schema: data.essentials.alertTargetIDs[0]
    # Example: /subscriptions/.../resourceGroups/<rg>/providers/Microsoft.Sql/servers/<server>/databases/<db>
    $targetId = $payload.data.essentials.alertTargetIDs[0]
    $parts    = $targetId -split '/'

    $rgIndex      = [Array]::IndexOf($parts, 'resourceGroups')
    $serverIndex  = [Array]::IndexOf($parts, 'servers')
    $dbIndex      = [Array]::IndexOf($parts, 'databases')

    $rg      = $parts[$rgIndex+1]
    $server  = $parts[$serverIndex+1]
    $dbName  = $parts[$dbIndex+1]

    # Determine intent: look at first condition
    $cond = $payload.data.alertContext.condition.allOf | Select-Object -First 1
    $operator  = "$($cond.operator)"
    $threshold = "$($cond.threshold)"

    $mode = if ($operator -match 'GreaterThan') { 'ScaleUp' }
            elseif ($operator -match 'LessThan') { 'ScaleDown' }
            else { $null }

    return [pscustomobject]@{
      ResourceGroupName = $rg
      ServerName        = $server
      DatabaseName      = $dbName
      Mode              = $mode
      Operator          = $operator
      Threshold         = $threshold
    }
  }
  catch {
    Write-Log "Failed to parse alert payload: $($_.Exception.Message)" 'WARN'
    return $null
  }
}

# ------------------------------
# Tier map (+2 jumps). Includes Basic->S1->S3 path if starting at Basic.
$tiers = @('Basic','S0','S1','S2','S3','S4','S5','S6','P1','P2','P3','P4')
$editionByTier = @{
  'Basic' = 'Basic'
  'S0'    = 'Standard'
  'S1'    = 'Standard'
  'S2'    = 'Standard'
  'S3'    = 'Standard'
  'S4'    = 'Standard'
  'S5'    = 'Standard'
  'S6'    = 'Standard'
  'P1'    = 'Premium'
  'P2'    = 'Premium'
  'P3'    = 'Premium'
  'P4'    = 'Premium'

}

# ------------------------------
# Resolve inputs either from WebhookData or explicit params
if ($WebhookData) {
  Write-Log "WebhookData provided. Attempting to parse Common Alert Schema payload..."
  $parsed = Parse-AlertPayload -WebhookData $WebhookData
  if ($parsed) {
    if (-not $ResourceGroupName) { $ResourceGroupName = $parsed.ResourceGroupName }
    if (-not $ServerName)        { $ServerName        = $parsed.ServerName }
    if (-not $DatabaseName)      { $DatabaseName      = $parsed.DatabaseName }
    if (-not $Mode)              { $Mode              = $parsed.Mode }
    Write-Log "Parsed target: RG=$ResourceGroupName, Server=$ServerName, DB=$DatabaseName, Mode=$Mode (Operator=$($parsed.Operator), Threshold=$($parsed.Threshold))"
  }
}

# Validate minimum inputs
if (-not $ResourceGroupName -or -not $ServerName -or -not $DatabaseName) {
  throw "ResourceGroupName/ServerName/DatabaseName are required when WebhookData cannot be parsed."
}
if (-not $Mode) {
  throw "Mode is not set. Provide WebhookData from alert or pass -Mode 'ScaleUp' or 'ScaleDown'."
}

# ------------------------------
# Connect with Managed Identity
Write-Log "Authenticating with Managed Identity..."
Connect-AzAccount -Identity | Out-Null

# Fetch current DB
Write-Log "Fetching database..."
$db = Get-AzSqlDatabase -ResourceGroupName $ResourceGroupName -ServerName $ServerName -DatabaseName $DatabaseName -ErrorAction Stop
$currentSO  = $db.CurrentServiceObjectiveName
$currentEd  = $db.Edition
Write-Log "Current tier: Edition=$currentEd, ServiceObjective=$currentSO"

# Store/retrieve original tier in an Automation Variable
$origVarName = "OrigTier_${ServerName}_${DatabaseName}"
try {
  $origTier = Get-AutomationVariable -Name $origVarName -ErrorAction Stop
  Write-Log "Found stored original tier: $origTier"
}
catch {
  # Create it when first seen
  $origTier = $currentSO
  Write-Log "Storing original tier as '$origTier' in automation variable '$origVarName'"
  Set-AutomationVariable -Name $origVarName -Value $origTier
}

# Utility: scale to target service objective
function Invoke-Scale {
  param([string]$TargetSO)

  if (-not $editionByTier.ContainsKey($TargetSO)) {
    throw "Target service objective '$TargetSO' not in supported tier map."
  }
  $targetEdition = $editionByTier[$TargetSO]

  if ($TargetSO -eq $currentSO) {
    Write-Log "TargetSO equals current ($TargetSO). No action required."
    return
  }

  Write-Log "Scaling '$($DatabaseName)' from $currentSO ($currentEd) -> $TargetSO ($targetEdition)..."
  try {
    Set-AzSqlDatabase `
      -ResourceGroupName $ResourceGroupName `
      -ServerName        $ServerName `
      -DatabaseName      $DatabaseName `
      -Edition           $targetEdition `
      -RequestedServiceObjectiveName $TargetSO `
      -ErrorAction Stop

    Write-Log "Scale operation submitted successfully."
  }
  catch {
    Write-Log "Scale failed: $($_.Exception.Message)" 'ERROR'
    throw
  }
}

switch ($Mode) {
  'ScaleUp' {
    # +2 tiers (bounded by list end)
    $curIdx = $tiers.IndexOf($currentSO)
    if ($curIdx -lt 0) {
      throw "Current service objective '$currentSO' not recognized in tier map."
    }

    if ($curIdx -ge ($tiers.Count - 1)) {
      Write-Log "Already at highest configured tier ($currentSO). Nothing to do." 'WARN'
      break
    }

    $targetIdx = [Math]::Min($curIdx + 2, $tiers.Count - 1)
    $targetSO  = $tiers[$targetIdx]

    Invoke-Scale -TargetSO $targetSO
  }

  'ScaleDown' {
    # Restore to original tier we stored
    if (-not $origTier) {
      Write-Log "Original tier not stored; cannot scale down safely." 'WARN'
      break
    }

    # Attempt to restore; if physical DB size exceeds target max size, Azure will throw; we surface the error
    try {
      Invoke-Scale -TargetSO $origTier
    }
    catch {
      Write-Log "Scale down to original tier '$origTier' failed. Ensure DB used size fits target tier and that downgrade constraints are met." 'ERROR'
      throw
    }
  }
  default {
    throw "Unsupported Mode '$Mode'."
  }
}

Write-Log "Runbook completed."
