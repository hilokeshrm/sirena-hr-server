<#
.SYNOPSIS
  Proves the latest nightly backup restores: loads it into a scratch database, counts rows, drops it.
  Runs Sundays as SYSTEM (scheduled by setup.ps1). The live database is not touched.
#>
. "$PSScriptRoot\lib\common.ps1"
$cfg = Get-SirenaConfig
$scratch = 'sirena_restore_test'
$result = "$BackupsDir\last-restore-test.txt"

$file = Get-ChildItem "$BackupsDir\daily" -Filter '*.dump' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
try {
  if (-not $file) { throw 'No nightly backup found.' }
  Invoke-Psql "DROP DATABASE IF EXISTS $scratch WITH (FORCE); CREATE DATABASE $scratch;" | Out-Null
  $env:PGPASSWORD = Get-Secret 'pg-superuser'
  try {
    Invoke-Native (Join-Path (Get-PgBin) 'pg_restore.exe') @('-h', '127.0.0.1', '-p', "$($cfg.PgPort)", '-U', 'postgres', '-d', $scratch,
      '--no-owner', '--exit-on-error', $file.FullName) | Out-Null
  } finally { Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue }
  $people = Invoke-Psql 'SELECT count(*) FROM "Employee";' -Database $scratch -Scalar | Select-Object -First 1
  $msg = "$(Get-Date -Format s) OK $($file.Name) restored, $people employees"
} catch {
  $msg = "$(Get-Date -Format s) FAILED $($file.Name): $_"
} finally {
  try { Invoke-Psql "DROP DATABASE IF EXISTS $scratch WITH (FORCE);" | Out-Null } catch { }
}
[IO.File]::WriteAllText($result, $msg)
Add-Content "$LogsDir\backup.log" $msg
Write-Host $msg
if ($msg -match ' FAILED ') { exit 1 }
