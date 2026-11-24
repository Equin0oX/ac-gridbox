# Keeps copies of the CSP log and the GridBox report file while a test runs, so that nothing is lost when the game is restarted
# (the game wipes the log at every start):
#   watch\csp_latest.log       the CSP log as of the last check (overwritten every few seconds while it changes)
#   watch\csp_<time>_before_restart.log   the last copy before the log got smaller, i.e. before the game was started again
#   watch\csp_<time>.log       a snapshot every 5 minutes
#   watch\shared-gridbox_<time>   the report file, whenever it changes (it is small)
# Stops when watch.pid in the destination folder is deleted, or when the process is stopped.
# usage:  powershell -File tools\watch_logs.ps1 [-Dest <folder>] [-Seconds 5]
param([string]$Dest = (Join-Path (Split-Path $PSScriptRoot -Parent) "..\gridbox_logs"), [int]$Seconds = 5)
$docs = [Environment]::GetFolderPath("MyDocuments")
$csp = Join-Path $docs "Assetto Corsa\logs\custom_shaders_patch.log"
$report = Join-Path $docs "Assetto Corsa\cfg\extension\state\lua\shared-gridbox"
$watch = Join-Path $Dest "watch"
New-Item -ItemType Directory -Force $watch | Out-Null
$pidFile = Join-Path $Dest "watch.pid"
Set-Content $pidFile $PID
$latest = Join-Path $watch "csp_latest.log"
$lastCsp = ""; $lastReport = ""; $lastSnapshot = Get-Date
function Stamp { Get-Date -Format "yyyyMMdd_HHmmss" }
while (Test-Path $pidFile) {
  if (Test-Path $csp) {
    $item = Get-Item $csp
    $key = "{0}|{1}" -f $item.LastWriteTimeUtc.Ticks, $item.Length
    if ($key -ne $lastCsp) {
      if ((Test-Path $latest) -and $item.Length -lt (Get-Item $latest).Length) { Move-Item $latest (Join-Path $watch ("csp_{0}_before_restart.log" -f (Stamp))) -Force }
      try { Copy-Item $csp $latest -Force -ErrorAction Stop; $lastCsp = $key } catch { }
    }
    if (((Get-Date) - $lastSnapshot).TotalMinutes -ge 5) { try { Copy-Item $csp (Join-Path $watch ("csp_{0}.log" -f (Stamp))) -ErrorAction Stop } catch { }; $lastSnapshot = Get-Date }
  }
  if (Test-Path $report) {
    $item = Get-Item $report
    $key = "{0}|{1}" -f $item.LastWriteTimeUtc.Ticks, $item.Length
    if ($key -ne $lastReport) { try { Copy-Item $report (Join-Path $watch ("shared-gridbox_{0}" -f (Stamp))) -ErrorAction Stop; $lastReport = $key } catch { } }
  }
  Get-ChildItem $watch | Sort-Object LastWriteTime -Descending | Select-Object -Skip 400 | Remove-Item -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds $Seconds
}
