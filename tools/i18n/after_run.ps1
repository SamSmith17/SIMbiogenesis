# Waits for a running translate.py to finish, then runs the release update
# (extract -> merge -> translate the new strings -> pseudo -> check), so strings
# wrapped while a long run was writing the .po files are picked up without
# two writers on one file.
#   & .\tools\i18n\after_run.ps1 -Langs es,zh_Hans,ar,hi
param([string[]]$Langs = @("es", "zh_Hans", "ar", "hi"))

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Set-Location $root
function Get-TranslateRun {
    Get-CimInstance Win32_Process -Filter "Name like 'python%'" |
        Where-Object { $_.CommandLine -match 'translate\.py' }
}
while (Get-TranslateRun) {
    Write-Host ("{0:HH:mm} waiting for the running translate.py to finish..." -f (Get-Date))
    Start-Sleep -Seconds 60
}
Write-Host "translate.py finished; running the update for $($Langs -join ",")"
python tools/i18n/update.py --langs ($Langs -join ",")
