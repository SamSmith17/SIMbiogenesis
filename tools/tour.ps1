<#
.SYNOPSIS
  Run the SIMbiogenesis feature tour: a short visual demo of every mode, with
  title cards, one clean screenshot per feature, and (optionally) a video.

.DESCRIPTION
  Each tour stop is one file in core/tour/stops/ and names the world it runs
  on (Mount Vernon, Walton or Burning Man). This script runs one harness pass per world
  through tools/harness.ps1 (so every run is sandboxed - the real worlds are
  never changed), then merges the passes into one manifest in FILE order.

    -Mode stills   fast pace, screenshots + manifest (refreshing the docs)
    -Mode live     slow pace, real time - record the screen yourself (OBS);
                   waits for Enter before launching
    -Mode record   Godot Movie Maker writes the video at a fixed frame rate
                   with game audio (smooth whatever the render cost), then
                   ffmpeg cuts one clip per stop, reassembles them in tour
                   order as tour.mp4 and writes chapters.txt (YouTube style)

  Output: %APPDATA%\Godot\app_userdata\SIMbiogenesis\screenshots\<Label>\
    tour_manifest.json      merged manifest (tools/tour_docs.py reads it)
    <world>\stops\<id>\     hero.png + hero.jpg (+ extras) per stop
    tour.mp4, clips\, chapters.txt   (record mode)

  Then:  python tools/tour_docs.py      (docs/FEATURES.md + README gallery)

.EXAMPLE
  tools\tour.ps1 -Mode stills
  tools\tour.ps1 -Mode stills -Stops site_plan,hydro_lab
  tools\tour.ps1 -Mode record
  tools\tour.ps1 -Mode record -Chapters Systems -Resolution 1280x720
  tools\tour.ps1 -Mode live -Pace slow
#>
[CmdletBinding()]
param(
	[ValidateSet("stills", "live", "record")][string]$Mode = "stills",
	[string[]]$Stops = @(),
	[string[]]$Chapters = @(),
	[string]$Pace = "",
	[string]$Resolution = "",
	[switch]$IncludeOptional,
	[switch]$NoCards,
	[int]$Fps = 30,
	[string]$Label = "",
	[string]$Godot = "",
	[int]$Timeout = 0,
	# UI audit at every hero shot: off / report (default) / strict (errors FAIL the stop)
	[ValidateSet("off", "report", "strict")][string]$Audit = "report"
)

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot
$RealUser = Join-Path $env:APPDATA "Godot\app_userdata\SIMbiogenesis"
$StopsDir = Join-Path $Repo "core\tour\stops"
$Harness = Join-Path $PSScriptRoot "harness.ps1"
$Chapters0 = @("World", "Build", "Systems", "People", "Labs")
# PowerShell 5's -Encoding UTF8 writes a BOM; chapters.txt is pasted into
# YouTube and the manifest read by other tools, so write plain UTF-8.
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Step([string]$msg) { Write-Host "[tour] $msg" }
function Split-List([string[]]$a) { @(@($a) | Where-Object { $_ } | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }) }

$wantStops = Split-List $Stops
$wantChapters = Split-List $Chapters
if (-not $Pace) { $Pace = @{ stills = "fast"; live = "slow"; record = "normal" }[$Mode] }
if (-not $Resolution) { $Resolution = $(if ($Mode -eq "stills") { "1600x900" } else { "1920x1080" }) }
if (-not $Label) { $Label = "tour_" + (Get-Date -Format "yyyyMMdd-HHmmss") }

# --- Which stops, on which worlds (parsed from the stop files, same rules as
#     TourCatalog.select: by id / chapter, optional only when asked or named) --
$catalog = @()
$order = 0
foreach ($f in (Get-ChildItem -LiteralPath $StopsDir -Filter "*.gd" | Where-Object { $_.Name -notlike "_*" } | Sort-Object Name)) {
	$txt = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
	$get = { param($k) if ($txt -match ("(?m)^\s*" + $k + '\s*=\s*"([^"]*)"')) { $Matches[1] } else { "" } }
	$id = & $get "id"
	if (-not $id) { $id = ($f.BaseName -replace "^\d+_", "") }
	$catalog += [pscustomobject]@{
		order = $order; id = $id; chapter = (& $get "chapter"); world = (& $get "world");
		optional = ($txt -match "(?m)^\s*optional\s*=\s*true")
	}
	$order++
}
$chosen = @($catalog | Where-Object {
	$named = $wantStops -contains $_.id.ToLower()
	(($wantStops.Count -eq 0) -or $named) -and
	(($wantChapters.Count -eq 0) -or ($wantChapters -contains $_.chapter.ToLower())) -and
	((-not $_.optional) -or $IncludeOptional -or $named)
})
if ($chosen.Count -eq 0) { throw "no tour stops match (known: $(($catalog | ForEach-Object { $_.id }) -join ', '))" }
foreach ($s in $wantStops) { if (-not ($catalog | Where-Object { $_.id -eq $s })) { Write-Step "WARNING: no stop named '$s'" } }
$worlds = @()
foreach ($s in $chosen) { if ($worlds -notcontains $s.world) { $worlds += $s.world } }
Write-Step ("{0} stop(s) on {1}: {2}" -f $chosen.Count, ($worlds -join " + "), (($chosen | ForEach-Object { $_.id }) -join ", "))

# --- ffmpeg (record mode) ---------------------------------------------------------
$ffmpeg = ""
if ($Mode -eq "record") {
	$cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
	if ($cmd) { $ffmpeg = $cmd.Source }
	foreach ($c in @((Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\ffmpeg.exe"),
			"C:\ProgramData\chocolatey\bin\ffmpeg.exe", "C:\Program Files\ffmpeg\bin\ffmpeg.exe")) {
		if (-not $ffmpeg -and (Test-Path -LiteralPath $c)) { $ffmpeg = $c }
	}
	if (-not $ffmpeg) { throw "record mode needs ffmpeg (winget install Gyan.FFmpeg)" }
}

if ($Mode -eq "live") {
	Write-Host ""
	Write-Host "  LIVE tour at pace '$Pace', $Resolution. Start your screen recorder on the Godot"
	Write-Host "  window when it appears (OBS: Window Capture). The tour starts after the map loads."
	Read-Host "  Press Enter to launch"
}

# --- One harness pass per world -----------------------------------------------------
$outRoot = Join-Path $RealUser ("screenshots\" + $Label)
New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
$passes = @()
$worstCode = 0
foreach ($w in $worlds) {
	$ids = @($chosen | Where-Object { $_.world -eq $w } | ForEach-Object { $_.id })
	$sub = "$Label/$w"
	$extra = @("--tour-world=$w", "--tour-stops=$($ids -join ',')", "--tour-pace=$Pace", "--tour-intro-count=$($chosen.Count)", "--tour-audit=$Audit")
	if ($IncludeOptional) { $extra += "--tour-include-optional" }
	if ($NoCards) { $extra += "--tour-no-cards" }
	$engine = @()
	$movie = ""
	if ($Mode -eq "record") {
		$movie = Join-Path $outRoot "$w.avi"
		$engine = @("--write-movie", $movie, "--fixed-fps", "$Fps")
		$extra += "--tour-movie-fps=$Fps"
	}
	# Budgets: the stops' own plus load time; Movie Maker renders slower than real time.
	$t = $Timeout
	if ($t -le 0) { $t = [int](900 + 75 * $ids.Count * $(if ($Mode -eq "record") { 3 } else { 1 })) }
	Write-Step "pass ${w}: $($ids.Count) stop(s)"
	# The project opens MAXIMIZED, which overrides --resolution; the harness
	# resizes the window itself from this (Godot hides --resolution from scripts).
	$extra += "--window-size=$Resolution"
	$hargs = @{ World = $w; Capture = @("tour"); Label = $sub; Resolution = $Resolution; Timeout = $t;
		EngineArgs = $engine; UserArgs = $extra }
	if ($Godot) { $hargs["Godot"] = $Godot }
	& $Harness @hargs
	$code = $LASTEXITCODE
	# A native crash exits NEGATIVE (0xC0000005 = -1073741819): count it, or a
	# pass that died mid-tour reads as a clean run.
	if ($code -lt 0) { $code = 5 }
	if ($code -gt $worstCode) { $worstCode = $code }
	$passes += [pscustomobject]@{ world = $w; dir = (Join-Path $outRoot $w); movie = $movie; code = $code }
}

# --- Merge the manifests in tour (file) order ---------------------------------------
$allStops = @()
$passInfo = @()
foreach ($p in $passes) {
	$mf = Join-Path $p.dir "tour_manifest.json"
	if (-not (Test-Path -LiteralPath $mf)) {
		Write-Step "FAIL: pass $($p.world) wrote no manifest (exit $($p.code)) - its stops did not run"
		if ($worstCode -eq 0) { $worstCode = 1 }
		continue
	}
	$m = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
	$passInfo += [pscustomobject]@{ world = $p.world; manifest = $m; movie = $p.movie; code = $p.code }
	foreach ($s in $m.stops) {
		$s | Add-Member -NotePropertyName pass_world -NotePropertyValue $p.world -Force
		foreach ($k in @("dir", "hero", "hero_png")) { if ($s.$k) { $s.$k = "$($p.world)/$($s.$k)" } }
		$ord = ($catalog | Where-Object { $_.id -eq $s.id } | Select-Object -First 1).order
		$s | Add-Member -NotePropertyName order -NotePropertyValue $ord -Force
		$allStops += $s
	}
}
$allStops = @($allStops | Sort-Object order)
$first = $passInfo | Select-Object -First 1
$merged = [ordered]@{
	version = 1
	generated = (Get-Date).ToString("s")
	label = $Label
	mode = $Mode
	pace = $Pace
	resolution = $Resolution
	git_commit = $(if ($first) { $first.manifest.git_commit } else { "" })
	worlds = $worlds
	chapters_order = $Chapters0
	passed = @($allStops | Where-Object { $_.status -eq "PASS" }).Count
	total = $allStops.Count
	stops = $allStops
}

# --- Record: cut a clip per stop, reassemble in tour order --------------------------
if ($Mode -eq "record" -and $passInfo.Count -gt 0) {
	$clipDir = Join-Path $outRoot "clips"
	New-Item -ItemType Directory -Force -Path $clipDir | Out-Null
	$segments = @()
	function Add-Seg($movie, [double]$a, [double]$b, [string]$name, [string]$title) {
		if (-not (Test-Path -LiteralPath $movie) -or $b -le $a) { return }
		$out = Join-Path $clipDir "$name.mp4"
		& $ffmpeg -hide_banner -loglevel error -y -ss ("{0:F3}" -f $a) -i $movie -t ("{0:F3}" -f ($b - $a)) `
			-c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -r $Fps -c:a aac -b:a 160k -ar 48000 -ac 2 $out
		if ($LASTEXITCODE -eq 0) { $script:segments += [pscustomobject]@{ file = $out; secs = ($b - $a); title = $title } }
		else { Write-Step "WARNING: ffmpeg could not cut $name" }
	}
	$firstPass = $passInfo[0]
	$lastPass = $passInfo[$passInfo.Count - 1]
	$fm = $firstPass.manifest
	$firstStop = @($fm.stops)[0]
	if ($firstStop) { Add-Seg $firstPass.movie ($fm.start_frame / $Fps) ($firstStop.start_frame / $Fps) "000_intro" "Intro" }
	$i = 1
	foreach ($s in $allStops) {
		$pi = $passInfo | Where-Object { $_.world -eq $s.pass_world } | Select-Object -First 1
		Add-Seg $pi.movie ($s.start_frame / $Fps) ($s.end_frame / $Fps) ("{0:D3}_{1}" -f $i, $s.id) $s.title
		$i++
	}
	$lm = $lastPass.manifest
	$lastStop = @($lm.stops)[@($lm.stops).Count - 1]
	if ($lastStop) { Add-Seg $lastPass.movie ($lastStop.end_frame / $Fps) ($lm.end_frame / $Fps) "999_outro" "Outro" }
	if ($segments.Count -gt 0) {
		$list = Join-Path $clipDir "concat.txt"
		($segments | ForEach-Object { "file '" + ($_.file -replace "\\", "/") + "'" }) | Set-Content -LiteralPath $list -Encoding ASCII
		$final = Join-Path $outRoot "tour.mp4"
		& $ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i $list -c copy $final
		$t = 0.0
		$chap = @()
		foreach ($seg in $segments) {
			if ($seg.title -ne "Outro") { $chap += ("{0}:{1:D2} {2}" -f [int][math]::Floor($t / 60), [int][math]::Floor($t % 60), $seg.title) }
			$t += $seg.secs
		}
		[System.IO.File]::WriteAllLines((Join-Path $outRoot "chapters.txt"), [string[]]$chap, $Utf8NoBom)
		$merged["video"] = "tour.mp4"
		$merged["video_secs"] = [math]::Round($t, 1)
		Write-Step ("video: {0} ({1:N0} s, {2} clips in {3})" -f $final, $t, $segments.Count, $clipDir)
		foreach ($p in $passInfo) { if (Test-Path -LiteralPath $p.movie) { Remove-Item -LiteralPath $p.movie -Force } }
	}
}

[System.IO.File]::WriteAllText((Join-Path $outRoot "tour_manifest.json"), ($merged | ConvertTo-Json -Depth 12), $Utf8NoBom)
Set-Content -LiteralPath (Join-Path $RealUser "screenshots\tour_latest.txt") -Value $Label -Encoding ASCII

# --- Report ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("{0,-20} {1,-9} {2,-8} {3,6} {4,9}  {5}" -f "stop", "world", "status", "secs", "ui e/w", "notes")
$uiE = 0; $uiW = 0; $uiKinds = @{}
foreach ($s in $allStops) {
	$why = (@($s.failures) + @($s.notes)) -join "; "
	$ui = ""
	if ($s.ui_audit) {
		$ui = "{0}/{1}" -f $s.ui_audit.errors, $s.ui_audit.warnings
		$uiE += [int]$s.ui_audit.errors; $uiW += [int]$s.ui_audit.warnings
		foreach ($p in $s.ui_audit.counts.PSObject.Properties) { $uiKinds[$p.Name] = [int]$uiKinds[$p.Name] + [int]$p.Value }
	}
	Write-Host ("{0,-20} {1,-9} {2,-8} {3,6:N1} {4,9}  {5}" -f $s.id, $s.pass_world, $s.status, $s.secs, $ui, $why)
}
if ($Audit -ne "off") {
	$kinds = ($uiKinds.Keys | Sort-Object | ForEach-Object { "$_ $($uiKinds[$_])" }) -join ", "
	Write-Step ("UI audit ({0}): {1} errors, {2} warnings across {3} stops - {4}" -f $Resolution, $uiE, $uiW, $allStops.Count, $kinds)
}
Write-Step ("{0} of {1} stop(s) passed; output {2}" -f $merged.passed, $chosen.Count, $outRoot)
$missing = @($chosen | Where-Object { $id = $_.id; -not ($allStops | Where-Object { $_.id -eq $id }) } | ForEach-Object { $_.id })
if ($missing.Count -gt 0) {
	Write-Step ("FAIL: {0} stop(s) never reported (a pass crashed or timed out): {1}" -f $missing.Count, ($missing -join ", "))
	if ($worstCode -eq 0) { $worstCode = 1 }
}
Write-Step "next: python tools/tour_docs.py   (or --run `"$outRoot`")"
exit $worstCode
