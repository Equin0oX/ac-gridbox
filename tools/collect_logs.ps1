# Copies the files a GridBox test leaves behind, before the game is started again (the CSP log is wiped at every game start):
#   - Documents\Assetto Corsa\logs\custom_shaders_patch.log   (CSP log; GridBox lines with DEBUG=1)
#   - Documents\Assetto Corsa\cfg\extension\state\lua\shared-gridbox   (the admin's report file and debug ring)
# usage:  powershell -File tools\collect_logs.ps1 [-Label start1] [-Dest <folder>]
# Drivers who are not on this PC run the same with -Dest %USERPROFILE%\Desktop and send the folder, or just copy the first file.
param([string]$Label = "manual", [string]$Dest = (Join-Path (Split-Path $PSScriptRoot -Parent) "..\gridbox_logs"))
$docs = [Environment]::GetFolderPath("MyDocuments")
$sources = @(
  (Join-Path $docs "Assetto Corsa\logs\custom_shaders_patch.log"),
  (Join-Path $docs "Assetto Corsa\cfg\extension\state\lua\shared-gridbox"))
$target = Join-Path $Dest ("{0}_{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), $Label)
New-Item -ItemType Directory -Force $target | Out-Null
foreach ($s in $sources) {
  if (Test-Path $s) { Copy-Item $s $target; "copied $(Split-Path $s -Leaf) ($((Get-Item $s).Length) bytes)" } else { "missing: $s" }
}
"saved in $((Resolve-Path $target).Path)"
