<#
.SYNOPSIS
  Run a windowed SIMbiogenesis harness capture inside a throwaway SANDBOX copy
  of the user data dir, so a test run can never change the player's saved
  worlds, prefs or saves.

.DESCRIPTION
  Godot on Windows builds user:// from the APPDATA environment variable
  (%APPDATA%\Godot\app_userdata\SIMbiogenesis). This launcher seeds a fresh
  copy of that folder under %LOCALAPPDATA%\SIMbiogenesis_harness\runs\<id>\,
  points APPDATA at it for the Godot process only, and runs the capture there.

    copied      worlds, maps, saves, scores, prefs (*.cfg / *.json), catalogs ...
    hard-linked immutable assets (*.glb *.gltf *.fbx *.stl *.mp3 *.ogg *.wav)
                -- a Godot WRITE through a hard link changes the original, so
                only file types the game never rewrites are linked
    junctioned  regenerable caches (terrain_cache subdirs, weather_cache,
                veg_impostors, veg_photocards, shader_cache, vulkan,
                site_reports, graph_previews) and screenshots (so PNGs land
                where they always have)
    skipped     logs, climelapses, objectdb_snapshots

  The harness refuses to run unless it finds the sandbox marker, or -Persist.

  -Persist runs on the REAL user dir (only with -RunScript or -Capture look):
  the world's state files are backed up first and the restore command printed.

.EXAMPLE
  tools\harness.ps1 -World mtvernon -Capture look
  tools\harness.ps1 -World walton -Capture festivalmode -Label fm_check
  tools\harness.ps1 -World mtvernon -Capture graph,siphon
  tools\harness.ps1 -World mtvernon -RunScript res://tools/fixes/my_fix.gd            (dry run)
  tools\harness.ps1 -World mtvernon -RunScript res://tools/fixes/my_fix.gd -Persist   (keeps it)
  tools\harness.ps1 -RestoreBackup <backup folder printed by a -Persist run>
#>
[CmdletBinding()]
param(
	[string]$World = "",
	[string[]]$Capture = @(),
	[string]$Label = "",
	[switch]$Persist,
	[string]$RunScript = "",
	[int]$Timeout = 0,
	[string]$Resolution = "1280x720",
	[int]$Keep = 6,
	[string]$Godot = "",
	[string]$RestoreBackup = "",
	[string]$SeedOnly = "",
	[switch]$NoHashCheck,
	[Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra
)

$ErrorActionPreference = "Stop"
# -Capture a,b binds as an ARRAY in PowerShell; one comma-joined string from here on.
[string]$Cap = (@($Capture) | Where-Object { $_ } | ForEach-Object { $_ -split "," } | Where-Object { $_ }) -join ","
$Repo = Split-Path -Parent $PSScriptRoot
$AppRel = "Godot\app_userdata\SIMbiogenesis"
$RealAppData = $env:APPDATA
$RealUser = Join-Path $RealAppData $AppRel
$HarnessRoot = Join-Path $env:LOCALAPPDATA "SIMbiogenesis_harness"
$RunsRoot = Join-Path $HarnessRoot "runs"
$BackupsRoot = Join-Path $HarnessRoot "backups"
if ([string]::IsNullOrEmpty($Godot)) {
	$Godot = $env:SIMBIO_GODOT
}
if ([string]::IsNullOrEmpty($Godot)) {
	$Godot = "C:\Users\notsa\Downloads\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe"
}

$JunctionDirs = @("weather_cache", "veg_impostors", "veg_photocards", "shader_cache", "vulkan",
	"site_reports", "graph_previews", "screenshots")
$MixedDirs = @("terrain_cache")    # top-level files copied, subdirs junctioned
$SkipDirs = @("logs", "climelapses", "objectdb_snapshots")
$LinkExt = @("*.glb", "*.gltf", "*.fbx", "*.stl", "*.mp3", "*.ogg", "*.wav")

function Write-Step([string]$msg) { Write-Host "[harness] $msg" }

# --- State the revert check / persist backup cover ------------------------------
function Get-StateFiles([string]$root) {
	$files = @()
	foreach ($d in @("worlds", "maps", "saves", "scores")) {
		$p = Join-Path $root $d
		if (Test-Path $p) { $files += Get-ChildItem -Path $p -Recurse -File -Force }
	}
	$files += Get-ChildItem -Path $root -File -Force
	foreach ($d in @("models", "terrain_cache")) {
		$p = Join-Path $root $d
		if (Test-Path $p) { $files += Get-ChildItem -Path $p -File -Filter "*.json" -Force }
	}
	return $files
}

function Get-StateHashes([string]$root) {
	$h = @{}
	foreach ($f in (Get-StateFiles $root)) {
		$rel = $f.FullName.Substring($root.Length).TrimStart("\")
		try { $h[$rel] = (Get-FileHash -Algorithm MD5 -LiteralPath $f.FullName).Hash } catch { $h[$rel] = "unreadable" }
	}
	return $h
}

function Remove-Sandbox([string]$dir) {
	# Junctions FIRST, non-recursively, so a recursive delete can never follow
	# one into the real caches. Then refuse unless it is really a sandbox.
	$full = (Resolve-Path -LiteralPath $dir).Path
	if (-not $full.StartsWith($RunsRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "refusing to delete $full (not under $RunsRoot)" }
	$user = Join-Path $full $AppRel
	foreach ($base in @($user, (Join-Path $user "terrain_cache"))) {
		if (Test-Path -LiteralPath $base) {
			Get-ChildItem -LiteralPath $base -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object {
				[System.IO.Directory]::Delete($_.FullName, $false)
			}
		}
	}
	if (Test-Path -LiteralPath $user) {
		$left = Get-ChildItem -LiteralPath $user -Recurse -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue
		if ($left) { throw "refusing to delete ${full} - junctions remain ($($left[0].FullName))" }
	}
	Remove-Item -LiteralPath $full -Recurse -Force
}

function New-Junction([string]$link, [string]$target) {
	New-Item -ItemType Junction -Path $link -Target $target | Out-Null
}

function Copy-Tree([string]$src, [string]$dst) {
	$rcArgs = @($src, $dst, "/E", "/R:1", "/W:1", "/NFL", "/NDL", "/NJH", "/NJS", "/NP", "/XF") + $LinkExt
	& robocopy @rcArgs | Out-Null
	if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $src" }
	foreach ($pat in $LinkExt) {
		Get-ChildItem -LiteralPath $src -Recurse -File -Filter $pat -Force -ErrorAction SilentlyContinue | ForEach-Object {
			$rel = $_.FullName.Substring($src.Length).TrimStart("\")
			$to = Join-Path $dst $rel
			New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
			New-Item -ItemType HardLink -Path $to -Target $_.FullName | Out-Null
		}
	}
}

function New-Sandbox([string]$sandRoot) {
	$user = Join-Path $sandRoot $AppRel
	New-Item -ItemType Directory -Force -Path $user | Out-Null
	foreach ($item in Get-ChildItem -LiteralPath $RealUser -Force) {
		$name = $item.Name
		$dst = Join-Path $user $name
		if ($item.PSIsContainer) {
			if ($SkipDirs -contains $name) { continue }
			if ($JunctionDirs -contains $name) { New-Junction $dst $item.FullName; continue }
			if ($MixedDirs -contains $name) {
				New-Item -ItemType Directory -Force -Path $dst | Out-Null
				foreach ($sub in Get-ChildItem -LiteralPath $item.FullName -Force) {
					if ($sub.PSIsContainer) { New-Junction (Join-Path $dst $sub.Name) $sub.FullName }
					else { Copy-Item -LiteralPath $sub.FullName -Destination (Join-Path $dst $sub.Name) }
				}
				continue
			}
			Copy-Tree $item.FullName $dst
		} else {
			Copy-Item -LiteralPath $item.FullName -Destination $dst
		}
	}
	$marker = @{ created = (Get-Date).ToString("s"); real_user_dir = $RealUser } | ConvertTo-Json
	Set-Content -LiteralPath (Join-Path $user ".harness_sandbox") -Value $marker -Encoding ASCII
	return $user
}

function Backup-RealState([string]$tag) {
	$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
	$dst = Join-Path $BackupsRoot "$stamp`_$tag"
	foreach ($f in (Get-StateFiles $RealUser)) {
		$rel = $f.FullName.Substring($RealUser.Length).TrimStart("\")
		$to = Join-Path $dst $rel
		New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
		Copy-Item -LiteralPath $f.FullName -Destination $to
	}
	return $dst
}

# --- Seed a sandbox at a given APPDATA root and stop (manual inspection, or a
#     stand-in "real" dir to test -Persist against) -------------------------------
if (-not [string]::IsNullOrEmpty($SeedOnly)) {
	$full = [System.IO.Path]::GetFullPath($SeedOnly)
	if (-not $full.StartsWith($HarnessRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "-SeedOnly must be under $HarnessRoot" }
	if (Test-Path -LiteralPath (Join-Path $full $AppRel)) { throw "$full already holds a user dir" }
	$u = New-Sandbox $full
	Write-Step "seeded $u  (launch with APPDATA=$full)"
	exit 0
}

# --- Restore a persist backup ----------------------------------------------------
if (-not [string]::IsNullOrEmpty($RestoreBackup)) {
	$src = (Resolve-Path -LiteralPath $RestoreBackup).Path
	if (-not $src.StartsWith($BackupsRoot, [StringComparison]::OrdinalIgnoreCase)) { throw "not a harness backup: $src" }
	& robocopy $src $RealUser /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
	if ($LASTEXITCODE -ge 8) { throw "robocopy restore failed ($LASTEXITCODE)" }
	Write-Step "restored $src -> $RealUser (files created since the backup were left in place)"
	exit 0
}

if ([string]::IsNullOrEmpty($Cap) -and [string]::IsNullOrEmpty($RunScript)) {
	throw "give -Capture <mode[,mode]> and/or -RunScript <res://...gd>"
}
if ($Persist -and [string]::IsNullOrEmpty($RunScript) -and $Cap -ne "look") {
	throw "-Persist is only for -RunScript (a fix) or -Capture look; test captures always run in the sandbox"
}
if (-not (Test-Path -LiteralPath $Godot)) { throw "Godot binary not found: $Godot (set -Godot or `$env:SIMBIO_GODOT)" }
if (-not (Test-Path -LiteralPath $RealUser)) { throw "no user data dir at $RealUser" }

$capTag = if ($Cap) { ($Cap -replace "[^A-Za-z0-9+_-]", "+") } else { "script" }
$runId = (Get-Date -Format "yyyyMMdd-HHmmss") + "_" + $capTag
if ([string]::IsNullOrEmpty($Label)) { $Label = "h_$runId" }
New-Item -ItemType Directory -Force -Path $RunsRoot | Out-Null

$before = $null
$sandRoot = ""
$userDir = $RealUser
if ($Persist) {
	$bk = Backup-RealState ($(if ($World) { $World } else { "world" }))
	Write-Step "PERSIST: running on the REAL user dir. Backup of world state: $bk"
	Write-Step "         undo with:  tools\harness.ps1 -RestoreBackup `"$bk`""
} else {
	$sandRoot = Join-Path $RunsRoot $runId
	$t = Get-Date
	$userDir = New-Sandbox $sandRoot
	Write-Step ("sandbox seeded in {0:N1} s: {1}" -f ((Get-Date) - $t).TotalSeconds, $userDir)
	if (-not $NoHashCheck) { $before = Get-StateHashes $RealUser }
}

# --- Launch ------------------------------------------------------------------------
$gArgs = @("--path", $Repo, "--windowed", "--resolution", $Resolution, "--")
if ($World) { $gArgs += "--world=$World" }
if ($Cap) { $gArgs += "--capture=$Cap" }
if ($RunScript) { $gArgs += "--run-script=$RunScript" }
$gArgs += "--shots-dir=$Label"
$gArgs += "--quit-after-capture"
if ($Timeout -gt 0) { $gArgs += "--timeout=$Timeout" }
if ($Persist) { $gArgs += "--persist" }
if ($Extra) { $gArgs += $Extra }
$argLine = ($gArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join " "

$logDir = if ($sandRoot) { $sandRoot } else { Join-Path $HarnessRoot "persist_logs" }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$outLog = Join-Path $logDir "godot.out.log"
$errLog = Join-Path $logDir "godot.err.log"
Write-Step "godot $argLine"

$savedAppData = $env:APPDATA
if (-not $Persist) { $env:APPDATA = $sandRoot }
# The harness writes this the moment it activates; a harness that failed to
# COMPILE never does (Godot then sits in the map chooser).
$startedMarker = Join-Path $userDir "harness_started.json"
Remove-Item -LiteralPath $startedMarker -Force -ErrorAction SilentlyContinue
$t0 = Get-Date
try {
	$p = Start-Process -FilePath $Godot -ArgumentList $argLine -NoNewWindow -PassThru `
		-RedirectStandardOutput $outLog -RedirectStandardError $errLog
	$null = $p.Handle  # keeps ExitCode readable after exit (PS 5.1 quirk)
} finally {
	$env:APPDATA = $savedAppData
}
$hardLimit = $(if ($Timeout -gt 0) { $Timeout } else { 3600 }) + 600
$StartupLimit = 120
$status = ""
function Stop-Tree([int]$procId) {
	# The _console.exe wrapper owns the real Godot process: kill the whole tree.
	& taskkill /PID $procId /T /F 2>&1 | Out-Null
}
while (-not $p.WaitForExit(1000)) {
	$elapsed = ((Get-Date) - $t0).TotalSeconds
	if ((Test-Path -LiteralPath $errLog) -and (Select-String -LiteralPath $errLog -Pattern "Parse Error|Compile Error" -Quiet)) {
		Stop-Tree $p.Id; $status = "SCRIPT_COMPILE_ERROR"; break
	}
	if ($elapsed -gt $StartupLimit -and -not (Test-Path -LiteralPath $startedMarker)) {
		Stop-Tree $p.Id; $status = "HARNESS_NEVER_STARTED"; break
	}
	if ($elapsed -gt $hardLimit) {
		Stop-Tree $p.Id; $status = "KILLED"; break
	}
}
$p.WaitForExit()
$code = $p.ExitCode
if ($status -ne "" -and ($code -eq $null -or $code -eq 0)) { $code = 5 }
$secs = ((Get-Date) - $t0).TotalSeconds

# --- Report ------------------------------------------------------------------------
$out = @()
if (Test-Path $outLog) { $out += Get-Content -LiteralPath $outLog -Encoding UTF8 }
if (Test-Path $errLog) { $out += Get-Content -LiteralPath $errLog -Encoding UTF8 }
$resultLine = ($out | Where-Object { $_ -like "HARNESS RESULT*" } | Select-Object -Last 1)
$scriptErrs = @($out | Where-Object { $_ -like "SCRIPT ERROR*" })
Write-Host ""
foreach ($l in ($out | Where-Object { $_ -like "  failure:*" -or $_ -like "  script error:*" -or $_ -like "  engine error*" } | Select-Object -First 40)) { Write-Host $l }
if ($resultLine) { Write-Host $resultLine } else {
	Write-Host "HARNESS RESULT (none printed) exit=$code $status -- last lines:"
	$out | Select-Object -Last 25 | ForEach-Object { Write-Host "  $_" }
}
Write-Step ("exit code {0}{1}, {2:N0} s; log {3}" -f $code, $(if ($status) { " ($status)" } else { "" }), $secs, $outLog)
Write-Step ("shots: {0}" -f (Join-Path $RealUser "screenshots\$Label"))
if ($scriptErrs.Count -gt 0) { Write-Step ("{0} SCRIPT ERROR line(s) in the log" -f $scriptErrs.Count) }

if ($before -ne $null) {
	$after = Get-StateHashes $RealUser
	$diff = @()
	foreach ($k in $before.Keys) { if (-not $after.ContainsKey($k) -or $after[$k] -ne $before[$k]) { $diff += $k } }
	foreach ($k in $after.Keys) { if (-not $before.ContainsKey($k)) { $diff += "$k (new)" } }
	if ($diff.Count -eq 0) { Write-Step ("REAL USER DATA UNCHANGED ({0} files checked)" -f $before.Count) }
	else {
		Write-Step "WARNING: real user data CHANGED during the run (the game may be open, or a leak):"
		$diff | Select-Object -First 30 | ForEach-Object { Write-Host "    $_" }
		if ($code -eq 0) { $code = 6 }
	}
}

$summary = @{ run_id = $runId; capture = $Cap; world = $World; label = $Label; exit_code = $code;
	status = $status; secs = [math]::Round($secs, 1); result = $resultLine; sandbox = $sandRoot; log = $outLog; persist = [bool]$Persist }
$summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $HarnessRoot "last_run.json") -Encoding ASCII

# --- Prune old sandboxes (keep the newest $Keep) ----------------------------------
$runs = @(Get-ChildItem -LiteralPath $RunsRoot -Directory | Sort-Object Name -Descending)
if ($runs.Count -gt $Keep) {
	foreach ($old in $runs[$Keep..($runs.Count - 1)]) {
		try { Remove-Sandbox $old.FullName } catch { Write-Step "could not prune $($old.Name): $_" }
	}
}
exit $code
