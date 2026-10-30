<#
.SYNOPSIS
  One-screen health report: services, API, website, database, backups, certificates, disk, allowlist.
  Lines marked ! need attention.
#>
. "$PSScriptRoot\lib\common.ps1"
$cfg = Get-SirenaConfig
$problems = 0
function Row([string]$Name, [string]$Value, [bool]$Ok = $true) {
  $mark = if ($Ok) { ' ' } else { '!' }
  if (-not $Ok) { $script:problems++ }
  $color = if ($Ok) { 'Gray' } else { 'Red' }
  Write-Host ("  {0} {1,-16} {2}" -f $mark, $Name, $Value) -ForegroundColor $color
}

Write-Host "`nSirena HR server  $env:COMPUTERNAME  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor Cyan

Write-Host "`nServices"
foreach ($s in $PgService, $ApiService, $CaddyService, 'sshd', 'Tailscale') {
  $svc = Get-Service $s -ErrorAction SilentlyContinue
  $state = if ($svc) { "$($svc.Status)" } else { 'not installed' }
  Row $s $state ($state -eq 'Running')
}

Write-Host "`nApp"
$deployed = if (Test-Path "$SirenaRoot\deployed.txt") { Get-Content "$SirenaRoot\deployed.txt" -Raw } else { 'never' }
Row 'Deployed' $deployed.Trim()
try { $h = Invoke-RestMethod 'http://127.0.0.1:3000/api/health' -TimeoutSec 5; Row 'API (local)' "ok $($h.time)" } catch { Row 'API (local)' "$_" $false }
try { $h = Invoke-RestMethod "https://$($cfg.Domain)/api/health" -TimeoutSec 10; Row 'API (public)' "ok via https://$($cfg.Domain)" } catch { Row 'API (public)' "$_" $false }

Write-Host "`nDatabase"
try {
  $size = Invoke-Psql "SELECT pg_size_pretty(pg_database_size('$DbName'));" -Scalar | Select-Object -First 1
  $conns = Invoke-Psql "SELECT count(*) FROM pg_stat_activity WHERE datname = '$DbName';" -Scalar | Select-Object -First 1
  $people = Invoke-Psql 'SELECT count(*) FROM "Employee";' -Database $DbName -Scalar | Select-Object -First 1
  Row 'Size' "$size, $conns connections, $people employees"
} catch { Row 'Query' "$_" $false }
# Rejected remote logins in the last two days of Postgres logs
try {
  $logs = Get-ChildItem "$PgDataDir\log" -Filter '*.log' -ErrorAction Stop | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-2) }
  $fails = @($logs | Select-String -Pattern 'password authentication failed|no pg_hba.conf entry' -ErrorAction SilentlyContinue).Count
  Row 'Failed logins' "$fails in the last 48h" ($fails -lt 50)
} catch { Row 'Failed logins' "can't read $PgDataDir\log" }

Write-Host "`nBackups"
if (Test-Path "$BackupsDir\last-backup.txt") {
  $last = (Get-Content "$BackupsDir\last-backup.txt" -Raw).Trim()
  $age = (Get-Date) - [datetime]($last.Split(' ')[0])
  Row 'Last backup' ("{0} ({1:N0}h ago)" -f $last, $age.TotalHours) ($age.TotalHours -lt 26)
} else { Row 'Last backup' 'none yet' $false }
if (Test-Path "$BackupsDir\last-restore-test.txt") {
  $rt = (Get-Content "$BackupsDir\last-restore-test.txt" -Raw).Trim()
  Row 'Restore test' $rt ($rt -match ' OK ')
} else { Row 'Restore test' 'not run yet (Sundays 04:00)' }
$daily = @(Get-ChildItem "$BackupsDir\daily" -Filter '*.dump' -ErrorAction SilentlyContinue).Count
$weekly = @(Get-ChildItem "$BackupsDir\weekly" -Filter '*.dump' -ErrorAction SilentlyContinue).Count
Row 'Kept' "$daily daily, $weekly weekly"

Write-Host "`nCertificates"
foreach ($c in @(@('Website origin', "$SirenaRoot\certs\origin.pem"), @('Database', "$SirenaRoot\certs\db\server.crt"))) {
  try {
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2 $c[1]
    $days = [int]($cert.NotAfter - (Get-Date)).TotalDays
    Row $c[0] "expires $($cert.NotAfter.ToString('yyyy-MM-dd')) ($days days)" ($days -gt 30)
  } catch { Row $c[0] 'missing' $false }
}

Write-Host "`nMachine"
$disk = Get-PSDrive C
$freeGb = [math]::Round($disk.Free / 1GB)
Row 'Disk C:' "$freeGb GB free" ($freeGb -gt 20)
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Row 'Up since' $boot.ToString('yyyy-MM-dd HH:mm')
try { Row 'Tailscale IP' ((& "$env:ProgramFiles\Tailscale\tailscale.exe" ip -4) -join ', ') } catch { Row 'Tailscale IP' 'unknown' $false }

Write-Host "`nAllowlist (Postgres / SSH from the internet; Tailscale always allowed for SSH)"
$list = @(Get-Allowlist)
if ($list.Count -eq 0) { Row 'Entries' 'none: nobody can reach Postgres from outside' }
foreach ($e in $list) { Row $e.label "$($e.ip)  db=$($e.db) ssh=$($e.ssh)  added $($e.added)" }

Write-Host ''
if ($problems) { Write-Host "  $problems item(s) need attention" -ForegroundColor Red } else { Write-Host '  All good' -ForegroundColor Green }
