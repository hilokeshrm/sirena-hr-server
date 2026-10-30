<#
.SYNOPSIS
  Backs up the database and uploaded files, prunes old backups, and copies them off this disk.

.DESCRIPTION
  Runs nightly as SYSTEM (scheduled by setup.ps1) and before every deploy.
  Database: pg_dump custom format, C:\sirena\backups\<kind>\sirena_hr-<time>.dump
  Files:    mirror of C:\sirena\files in C:\sirena\backups\files
  On Sundays the nightly dump is also kept in backups\weekly.
#>
param([ValidateSet('daily', 'predeploy', 'prerestore', 'manual')][string]$Kind = 'daily')

. "$PSScriptRoot\lib\common.ps1"
$cfg = Get-SirenaConfig
$logFile = "$LogsDir\backup.log"
function Log([string]$m) { $line = "$(Get-Date -Format s) [$Kind] $m"; Add-Content $logFile $line; Write-Ok $m }

try {
  $dir = Join-Path $BackupsDir $Kind
  New-Item -ItemType Directory -Force $dir | Out-Null
  $file = Join-Path $dir "$DbName-$(Get-Date -Format 'yyyyMMdd-HHmmss').dump"

  $env:PGPASSWORD = Get-Secret 'pg-superuser'
  try {
    Invoke-Native (Join-Path (Get-PgBin) 'pg_dump.exe') @('-h', '127.0.0.1', '-p', "$($cfg.PgPort)", '-U', 'postgres', '-Fc', '-Z', '6', '-f', $file, $DbName) | Out-Null
  } finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
  $size = '{0:N1} MB' -f ((Get-Item $file).Length / 1MB)
  Log "Database dumped: $file ($size)"

  Invoke-Native robocopy.exe @("$SirenaRoot\files", "$BackupsDir\files", '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -OkCodes 0, 1, 2, 3, 4, 5, 6, 7 | Out-Null
  Log 'Uploaded files mirrored'

  # Retention
  function Prune([string]$Folder, [int]$Keep) {
    Get-ChildItem $Folder -Filter '*.dump' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $Keep | Remove-Item -Force
  }
  if ($Kind -eq 'daily' -and (Get-Date).DayOfWeek -eq 'Sunday') { Copy-Item $file "$BackupsDir\weekly\" -Force }
  Prune "$BackupsDir\daily" $cfg.DailyKeep
  Prune "$BackupsDir\weekly" $cfg.WeeklyKeep
  Prune "$BackupsDir\predeploy" 10
  Prune "$BackupsDir\prerestore" 5

  # Off-machine copies
  if ($cfg.OffsiteDir) {
    Invoke-Native robocopy.exe @($BackupsDir, $cfg.OffsiteDir, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -OkCodes 0, 1, 2, 3, 4, 5, 6, 7 | Out-Null
    Log "Copied to $($cfg.OffsiteDir)"
  }
  if ($cfg.RcloneRemote) {
    Invoke-Native rclone.exe @('sync', $BackupsDir, $cfg.RcloneRemote) | Out-Null
    Log "Synced to $($cfg.RcloneRemote)"
  }

  [IO.File]::WriteAllText("$BackupsDir\last-backup.txt", "$(Get-Date -Format s) $file")
  if ($cfg.BackupPingUrl -and $Kind -eq 'daily') { Invoke-WebRequest $cfg.BackupPingUrl -UseBasicParsing -TimeoutSec 10 | Out-Null }
} catch {
  Log "FAILED: $_"
  if ($cfg.BackupPingUrl -and $Kind -eq 'daily') { try { Invoke-WebRequest "$($cfg.BackupPingUrl)/fail" -UseBasicParsing -TimeoutSec 10 | Out-Null } catch { } }
  throw
}
