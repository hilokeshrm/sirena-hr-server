<#
.SYNOPSIS
  Replaces the live database with a backup. Takes a safety backup of the current data first.

.EXAMPLE
  .\restore.ps1 -File C:\sirena\backups\daily\sirena_hr-20261101-020000.dump
  .\restore.ps1 -Latest
#>
param([string]$File, [switch]$Latest, [switch]$Force)

. "$PSScriptRoot\lib\common.ps1"
Assert-Admin
$cfg = Get-SirenaConfig

if ($Latest) {
  $File = Get-ChildItem "$BackupsDir\daily", "$BackupsDir\predeploy", "$BackupsDir\manual" -Filter '*.dump' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $File -or -not (Test-Path $File)) { throw 'Pass -File <path to .dump> or -Latest.' }

Write-Note "This replaces ALL data in $DbName with $File"
if (-not $Force) {
  $typed = Read-Host "Type $DbName to continue"
  if ($typed -ne $DbName) { throw 'Cancelled.' }
}

Write-Step 'Safety backup of the current data'
& "$PSScriptRoot\backup.ps1" -Kind prerestore

Write-Step 'Restoring'
Stop-Service $ApiService -ErrorAction SilentlyContinue
try {
  Invoke-Psql "DROP DATABASE IF EXISTS $DbName WITH (FORCE);" | Out-Null
  Initialize-Database
  $env:PGPASSWORD = Get-Secret 'pg-superuser'
  try {
    Invoke-Native (Join-Path (Get-PgBin) 'pg_restore.exe') @('-h', '127.0.0.1', '-p', "$($cfg.PgPort)", '-U', 'postgres', '-d', $DbName,
      '--no-owner', '--role=sirena_app', '--exit-on-error', $File) | Out-Null
  } finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
  Grant-ReadOnly
} finally {
  Start-Service $ApiService
}
if (-not (Test-ApiHealth)) { throw 'Restored, but the API is not healthy. Check C:\sirena\logs\api.log.' }
$people = Invoke-Psql 'SELECT count(*) FROM "Employee";' -Database $DbName -Scalar
Write-Ok "Restored $File ($people employees). API healthy."
