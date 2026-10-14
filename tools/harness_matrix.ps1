<#
.SYNOPSIS
  Run many harness captures one after another through tools\harness.ps1 (each
  in its own sandbox, on its registered default world) and write a results
  table: mode, world, exit code, seconds, the HARNESS RESULT line.

.EXAMPLE
  tools\harness_matrix.ps1                       # every registered mode except script
  tools\harness_matrix.ps1 -Modes graph,siphon,packing
  tools\harness_matrix.ps1 -World walton -Modes lights,vehicles
#>
[CmdletBinding()]
param(
	[string[]]$Modes = @(),
	[string]$World = "",
	[string]$Out = ""
)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$HarnessRoot = Join-Path $env:LOCALAPPDATA "SIMbiogenesis_harness"
New-Item -ItemType Directory -Force -Path $HarnessRoot | Out-Null

# Registry: "mode": {"fn": ..., "world": "x", ...} lines in harness_registry.gd.
$reg = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $Repo "core\terrain\harness\harness_registry.gd")) {
	if ($line -match '^\s*"([a-z0-9-]+)":\s*\{"fn":\s*"[^"]+",\s*"world":\s*"([a-z]+)"') { $reg[$Matches[1]] = $Matches[2] }
}
if ($Modes.Count -eq 1 -and $Modes[0] -match ",") { $Modes = $Modes[0].Split(",") }
if ($Modes.Count -eq 0) { $Modes = @($reg.Keys | Where-Object { $_ -ne "script" } | Sort-Object) }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
if ([string]::IsNullOrEmpty($Out)) { $Out = Join-Path $HarnessRoot "matrix_$stamp.json" }
$rows = @()
foreach ($m in $Modes) {
	$m = $m.Trim()
	if (-not $reg.ContainsKey($m)) { Write-Host "[matrix] unknown mode $m"; continue }
	$w = if ($World) { $World } else { $reg[$m] }
	Write-Host ("[matrix] {0} on {1} ..." -f $m, $w)
	$t = Get-Date
	$lines = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "harness.ps1") `
		-World $w -Capture $m -Label "mx_${stamp}_$m" 2>&1 | ForEach-Object { "$_" }
	$code = $LASTEXITCODE
	$result = ($lines | Where-Object { $_ -like "HARNESS RESULT*" } | Select-Object -Last 1)
	$unchanged = [bool]($lines | Where-Object { $_ -like "*REAL USER DATA UNCHANGED*" })
	$fails = @($lines | Where-Object { $_ -like "  failure:*" -or $_ -like "  script error:*" } | Select-Object -First 12)
	$logLine = ($lines | Where-Object { $_ -like "*exit code*log*" } | Select-Object -Last 1)
	$row = [ordered]@{ mode = $m; world = $w; exit = $code; secs = [math]::Round(((Get-Date) - $t).TotalSeconds);
		result = $result; real_data_unchanged = $unchanged; failures = $fails; log = $logLine }
	$rows += $row
	Write-Host ("[matrix]   exit {0}  {1}" -f $code, $result)
	$rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Out -Encoding UTF8
}
Write-Host ""
Write-Host "| mode | world | exit | secs | result |"
Write-Host "|---|---|---|---|---|"
foreach ($r in $rows) { Write-Host ("| {0} | {1} | {2} | {3} | {4} |" -f $r.mode, $r.world, $r.exit, $r.secs, $r.result) }
Write-Host "[matrix] results: $Out"
