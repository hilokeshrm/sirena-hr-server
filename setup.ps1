<#
.SYNOPSIS
  One-time setup of the Sirena HR server on this Windows machine. Safe to re-run.

.DESCRIPTION
  Installs PostgreSQL, Node.js, Git, Caddy, NSSM, Tailscale, OpenSSH Server and Flutter;
  creates the database, roles and TLS certificate; clones the repo; builds and starts the
  API and website as Windows services; locks down the firewall; schedules backups.

  Run from an Administrator PowerShell, in this folder:
    powershell -ExecutionPolicy Bypass -File .\setup.ps1
#>
param(
  # Your current public IP, allowed to reach Postgres and SSH. Prompted for if omitted.
  [string]$AllowIp,
  [string]$AllowLabel = 'owner'
)

. "$PSScriptRoot\lib\common.ps1"
Assert-Admin

# ── 1. Folders, config, secrets ─────────────────────────────────────────
Write-Step 'Folders and config'
foreach ($d in @($SirenaRoot, $SecretsDir, $LogsDir, $WwwDir, $ToolsBin, "$SirenaRoot\certs", "$SirenaRoot\files",
    "$BackupsDir\daily", "$BackupsDir\weekly", "$BackupsDir\predeploy", "$BackupsDir\files")) {
  New-Item -ItemType Directory -Force $d | Out-Null
}
Protect-Folder $SecretsDir
Protect-Folder "$SirenaRoot\certs"
# Lets the ops scripts run by path (e.g. over SSH); downloaded scripts still need a signature.
Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force

$localConfig = Join-Path $PSScriptRoot 'config.psd1'
if (Test-Path $localConfig) {
  Copy-Item $localConfig $ConfigPath -Force
} elseif (-not (Test-Path $ConfigPath)) {
  throw "Copy config.example.psd1 to config.psd1 in $PSScriptRoot, fill it in, and run again."
}
$cfg = Get-SirenaConfig
Write-Ok "Config: $ConfigPath (domain $($cfg.Domain), db $($cfg.DbHost))"

foreach ($s in 'pg-superuser', 'db-app', 'db-admin', 'db-ro') { Initialize-Secret $s 32 | Out-Null }
Initialize-Secret 'jwt' 64 | Out-Null
Write-Ok "Secrets: $SecretsDir (Administrators and SYSTEM only)"

# ── 2. Software ─────────────────────────────────────────────────────────
function Install-WingetPackage([string]$Id, [string]$Override) {
  $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  winget list --id $Id -e --accept-source-agreements *> $null
  $installed = ($LASTEXITCODE -eq 0)
  $ErrorActionPreference = $old
  if ($installed) { Write-Ok "$Id already installed"; return }
  $a = @('install', '--id', $Id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements')
  if ($Override) { $a += @('--override', $Override) }
  Invoke-Native winget.exe $a | Out-Null
  Write-Ok "$Id installed"
}

# Copies a winget-installed tool into C:\sirena\tools\bin so services have a fixed path.
function Copy-Tool([string]$Exe, [string]$Prefer) {
  $dest = Join-Path $ToolsBin $Exe
  if (Test-Path $dest) { return $dest }   # in use by a running service on re-runs
  $candidates = @()
  $cmd = Get-Command $Exe -ErrorAction SilentlyContinue
  if ($cmd) {
    $item = Get-Item $cmd.Source
    if ($item.LinkType -and $item.Target) { $candidates += @($item.Target)[0] } else { $candidates += $item.FullName }
  }
  foreach ($r in "$env:ProgramFiles\WinGet\Packages", "$env:LOCALAPPDATA\Microsoft\WinGet\Packages") {
    if (Test-Path $r) { $candidates += @(Get-ChildItem $r -Recurse -Filter $Exe -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
  }
  $found = $candidates | Sort-Object { if ($Prefer -and $_ -match $Prefer) { 0 } else { 1 } } | Select-Object -First 1
  if (-not $found) { throw "Couldn't find $Exe after installing it." }
  Copy-Item $found $dest -Force
  $dest
}

Write-Step 'Installing software (this takes a while the first time)'
Install-WingetPackage 'Git.Git'
Install-WingetPackage 'OpenJS.NodeJS.LTS'
Install-WingetPackage 'NSSM.NSSM'
Install-WingetPackage 'CaddyServer.Caddy'
Install-WingetPackage 'Tailscale.Tailscale'
$pgSuper = Get-Secret 'pg-superuser'
Install-WingetPackage "PostgreSQL.PostgreSQL.$($cfg.PgMajor)" ("--mode unattended --unattendedmodeui none --superpassword $pgSuper " +
  "--serverport $($cfg.PgPort) --datadir $PgDataDir --servicename $PgService --disable-components pgAdmin,stackbuilder")
Update-PathFromRegistry
$nssm = Copy-Tool 'nssm.exe' 'win64'
$caddy = Copy-Tool 'caddy.exe'
$git = 'git.exe'
$openssl = "$env:ProgramFiles\Git\usr\bin\openssl.exe"

# ── 3. OpenSSH Server (key login only) ──────────────────────────────────
Write-Step 'OpenSSH Server'
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service sshd -StartupType Automatic
Start-Service sshd
$sshdConfig = 'C:\ProgramData\ssh\sshd_config'
$conf = Get-Content $sshdConfig
$conf = $conf -replace '^#?\s*PasswordAuthentication\s+.*$', 'PasswordAuthentication no' `
              -replace '^#?\s*PubkeyAuthentication\s+.*$', 'PubkeyAuthentication yes'
if (-not ($conf -match '^PasswordAuthentication no')) { $conf = @('PasswordAuthentication no') + $conf }
[IO.File]::WriteAllLines($sshdConfig, [string[]]$conf)
if (-not (Test-Path $AdminKeysPath)) { New-Item -ItemType File $AdminKeysPath | Out-Null }
Invoke-Native icacls.exe @($AdminKeysPath, '/inheritance:r', '/grant', '*S-1-5-32-544:F', '/grant', '*S-1-5-18:F') | Out-Null
New-Item -Path 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -PropertyType String -Force `
  -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" | Out-Null
Restart-Service sshd
Write-Ok 'sshd running; passwords off. Add keys with add-ssh-key.ps1.'

# ── 4. Tailscale (backup way in) ────────────────────────────────────────
Write-Step 'Tailscale'
$tailscale = "$env:ProgramFiles\Tailscale\tailscale.exe"
$old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
& $tailscale status *> $null
$tsUp = ($LASTEXITCODE -eq 0)
$ErrorActionPreference = $old
if (-not $tsUp) {
  Write-Note 'Sign in to Tailscale in the browser window that opens (or open the link printed below).'
  & $tailscale up --unattended
}
Write-Ok "Tailscale IP: $((& $tailscale ip -4) -join ', ')"

# ── 5. PostgreSQL: settings, TLS, access rules, roles ───────────────────
Write-Step 'PostgreSQL'
if (-not (Get-Service $PgService -ErrorAction SilentlyContinue)) { throw "Service $PgService not found; the PostgreSQL install failed." }

# Our own certificate authority, so clients can verify the server (sslmode=verify-full).
$dbCerts = "$SirenaRoot\certs\db"
New-Item -ItemType Directory -Force $dbCerts | Out-Null
if (-not (Test-Path "$dbCerts\ca.crt")) {
  Invoke-Native $openssl @('req', '-x509', '-new', '-newkey', 'rsa:4096', '-nodes', '-sha256', '-days', '3650',
    '-keyout', "$dbCerts\ca.key", '-out', "$dbCerts\ca.crt", '-subj', '/CN=Sirena HR DB CA') | Out-Null
}
$renew = $true
if (Test-Path "$dbCerts\server.crt") {
  $cur = New-Object Security.Cryptography.X509Certificates.X509Certificate2 "$dbCerts\server.crt"
  $renew = ($cur.NotAfter -lt (Get-Date).AddDays(30)) -or ($cur.Subject -ne "CN=$($cfg.DbHost)")
}
if ($renew) {
  [IO.File]::WriteAllText("$dbCerts\server.ext", "subjectAltName=DNS:$($cfg.DbHost)`nbasicConstraints=CA:FALSE`nkeyUsage=digitalSignature,keyEncipherment`nextendedKeyUsage=serverAuth`n")
  Invoke-Native $openssl @('req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', "$dbCerts\server.key",
    '-out', "$dbCerts\server.csr", '-subj', "/CN=$($cfg.DbHost)") | Out-Null
  Invoke-Native $openssl @('x509', '-req', '-in', "$dbCerts\server.csr", '-CA', "$dbCerts\ca.crt", '-CAkey', "$dbCerts\ca.key",
    '-CAcreateserial', '-out', "$dbCerts\server.crt", '-days', '825', '-sha256', '-extfile', "$dbCerts\server.ext") | Out-Null
  Write-Ok "New DB certificate for $($cfg.DbHost)"
}
# Postgres reads server.crt / server.key from its data folder, where its service account has access.
Copy-Item "$dbCerts\server.crt", "$dbCerts\server.key" $PgDataDir -Force
Copy-Item "$dbCerts\ca.crt" "$SirenaRoot\sirena-db-ca.crt" -Force

[IO.File]::WriteAllLines((Join-Path $PgDataDir 'pg_hba.conf'), [string[]]@(
  '# Managed by ops/windows/setup.ps1 and allow-ip.ps1. Edits outside the allowlist block are overwritten.',
  '# TYPE   DATABASE  USER  ADDRESS        METHOD',
  'host     all       all   127.0.0.1/32   scram-sha-256',
  'host     all       all   ::1/128        scram-sha-256',
  '# BEGIN SIRENA ALLOWLIST',
  '# END SIRENA ALLOWLIST'
))

Invoke-Psql @"
ALTER SYSTEM SET listen_addresses = '*';
ALTER SYSTEM SET ssl = on;
ALTER SYSTEM SET ssl_min_protocol_version = 'TLSv1.2';
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
ALTER SYSTEM SET log_connections = on;
ALTER SYSTEM SET log_line_prefix = '%m [%p] %q%u@%d %h ';
ALTER SYSTEM SET logging_collector = on;
ALTER SYSTEM SET log_rotation_age = '1d';
"@ | Out-Null
Restart-Service $PgService
Start-Sleep -Seconds 3
Initialize-Database
Write-Ok "Database $DbName with roles sirena_app (API), sirena_admin (you), sirena_ro (read-only)"

# ── 6. Allowlist ────────────────────────────────────────────────────────
Write-Step 'Allowlist (who can reach Postgres and SSH from the internet)'
if (-not $AllowIp -and @(Get-Allowlist).Count -eq 0) {
  $AllowIp = Read-Host "Public IP of the laptop you'll manage from (find it at https://ifconfig.me), blank to skip"
}
if ($AllowIp) { & "$PSScriptRoot\allow-ip.ps1" -Ip $AllowIp -Label $AllowLabel -NoSync }
Sync-Allowlist
Get-Allowlist | ForEach-Object { Write-Ok "$($_.ip)  $($_.label)  db=$($_.db) ssh=$($_.ssh)" }

# ── 7. Flutter SDK (builds the website) ─────────────────────────────────
Write-Step 'Flutter SDK'
if (-not (Test-Path $FlutterBat)) {
  Invoke-Native $git @('clone', '--depth', '1', '-b', 'stable', 'https://github.com/flutter/flutter.git', "$SirenaRoot\tools\flutter") | Out-Null
}
Invoke-Native $FlutterBat @('config', '--no-analytics') | Out-Null
Write-Ok ((Invoke-Native $FlutterBat @('--version') | Select-Object -First 1))

# ── 8. Code: read-only deploy key + clone ───────────────────────────────
Write-Step 'Code'
$deployKey = Join-Path $SecretsDir 'deploy_key'
if (-not (Test-Path $deployKey)) {
  Start-Process -FilePath "$env:SystemRoot\System32\OpenSSH\ssh-keygen.exe" -Wait -NoNewWindow `
    -ArgumentList "-t ed25519 -q -N `"`" -C sirena-hr-server -f `"$deployKey`""
}
$sshCommand = "C:/Windows/System32/OpenSSH/ssh.exe -i $($deployKey -replace '\\', '/') -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
if (-not (Test-Path "$RepoDir\.git")) {
  Write-Note 'Add this as a deploy key on GitHub (repo > Settings > Deploy keys > Add deploy key, leave "Allow write access" OFF):'
  Write-Host ''
  Write-Host (Get-Content "$deployKey.pub") -ForegroundColor White
  Write-Host ''
  Read-Host 'Press Enter once the deploy key is added'
  $env:GIT_SSH_COMMAND = $sshCommand
  try { Invoke-Native $git @('clone', '-b', $cfg.Branch, $cfg.RepoSsh, $RepoDir) | Out-Null }
  finally { Remove-Item Env:GIT_SSH_COMMAND }
}
Invoke-Native $git @('-C', $RepoDir, 'config', 'core.sshCommand', $sshCommand) | Out-Null
# Deploys may run as a different Windows user than the one who cloned.
$safe = Invoke-Native $git @('config', '--system', '--get-all', 'safe.directory') -OkCodes 0, 1
if ($safe -notcontains 'C:/sirena/repo') { Invoke-Native $git @('config', '--system', '--add', 'safe.directory', 'C:/sirena/repo') | Out-Null }
Write-Ok "Repo at $RepoDir ($($cfg.Branch))"

# ── 9. API settings ─────────────────────────────────────────────────────
Write-Step 'API settings'
$envFile = @"
DATABASE_URL="postgresql://sirena_app:$(Get-Secret 'db-app')@127.0.0.1:$($cfg.PgPort)/$($DbName)"
JWT_SECRET="$(Get-Secret 'jwt')"
JWT_EXPIRES_IN="12h"
PORT=3000
FILES_DIR="C:/sirena/files"
MEAL_CUTOFF="$($cfg.MealCutoff)"
TRUST_PROXY=true
CORS_ORIGINS="https://$($cfg.Domain)"
"@
[IO.File]::WriteAllText("$RepoDir\backend\.env", $envFile)
Invoke-Native icacls.exe @("$RepoDir\backend\.env", '/inheritance:r', '/grant:r', '*S-1-5-32-544:F', '*S-1-5-18:F') | Out-Null
Write-Ok "$RepoDir\backend\.env written"

# ── 10. HTTPS: Cloudflare origin certificate + Caddy ────────────────────
Write-Step 'HTTPS'
$pem = "$SirenaRoot\certs\origin.pem"; $key = "$SirenaRoot\certs\origin.key"
foreach ($f in $pem, $key) {
  if (-not (Test-Path $f) -or -not (Get-Content $f -Raw -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $f)) { New-Item -ItemType File $f | Out-Null }
    Write-Note "Paste the Cloudflare origin $(if ($f -eq $pem) { 'CERTIFICATE' } else { 'PRIVATE KEY' }) into Notepad, save, and close it."
    Start-Process notepad.exe $f -Wait
  }
}
Update-CloudflareRanges | Out-Null
Write-CaddyConfig
Invoke-Native $caddy @('validate', '--config', "$SirenaRoot\Caddyfile", '--adapter', 'caddyfile') | Out-Null
Write-Ok "Caddyfile valid; port 443 open to Cloudflare only"

# ── 11. Services ────────────────────────────────────────────────────────
Write-Step 'Windows services'
function Install-NssmService([string]$Name, [string]$Exe, [string]$Arguments, [string]$Dir, [string]$Log, [string]$DependsOn) {
  if (-not (Get-Service $Name -ErrorAction SilentlyContinue)) { Invoke-Native $nssm @('install', $Name, $Exe) | Out-Null }
  $settings = @(
    @('Application', $Exe), @('AppParameters', $Arguments), @('AppDirectory', $Dir),
    @('AppStdout', $Log), @('AppStderr', $Log), @('AppRotateFiles', '1'), @('AppRotateOnline', '1'), @('AppRotateBytes', '10485760'),
    @('Start', 'SERVICE_AUTO_START'), @('AppExit', 'Default', 'Restart'), @('AppRestartDelay', '5000')
  )
  if ($DependsOn) { $settings += , @('DependOnService', $DependsOn) }
  foreach ($s in $settings) { Invoke-Native $nssm (@('set', $Name) + $s) | Out-Null }
}
$node = (Get-Command node.exe).Source
Install-NssmService $ApiService $node 'dist\main.js' "$RepoDir\backend" "$LogsDir\api.log" $PgService
Install-NssmService $CaddyService $caddy "run --config $SirenaRoot\Caddyfile --adapter caddyfile" $SirenaRoot "$LogsDir\caddy.log" ''
Write-Ok "$ApiService and $CaddyService installed (auto-start, restart on crash)"

# ── 12. First build and deploy ──────────────────────────────────────────
Write-Step 'First build (API + website)'
& "$PSScriptRoot\deploy.ps1" -SkipBackup -SkipFetch
Start-Service $CaddyService

# ── 13. First data ──────────────────────────────────────────────────────
$people = Invoke-Psql 'SELECT count(*) FROM "Employee";' -Database $DbName -Scalar
if ([int]($people | Select-Object -First 1) -eq 0) {
  Write-Step 'First data'
  Write-Host '    [1] Empty company with one super admin (for real use)'
  Write-Host '    [2] Sample company: 9 demo people, leave types, 2026 holidays (for trying it out)'
  $choice = Read-Host '    Choose 1 or 2'
  if ($choice -eq '2') {
    $env:SEED_PASSWORD = Initialize-Secret 'seed-password' 16
    try { Invoke-Native 'npx.cmd' @('prisma', 'db', 'seed') -WorkDir "$RepoDir\backend" | Out-Null }
    finally { Remove-Item Env:SEED_PASSWORD }
    Write-Ok "Sample data loaded. Every demo login uses the password in $SecretsDir\seed-password.txt"
  } else {
    $env:ADMIN_EMAIL = Read-Host '    Super admin work email'
    $env:ADMIN_NAME = Read-Host '    Full name'
    $env:ADMIN_PASSWORD = Initialize-Secret 'first-admin-password' 16
    try { Invoke-Native $node @('scripts/create-admin.mjs') -WorkDir "$RepoDir\backend" | Out-Null }
    finally { Remove-Item Env:ADMIN_EMAIL, Env:ADMIN_NAME, Env:ADMIN_PASSWORD }
    Write-Ok "Super admin created. Password: $SecretsDir\first-admin-password.txt (change it after first login)"
  }
}

# ── 14. Remote Desktop, power, updates, scheduled jobs ──────────────────
Write-Step 'Remote Desktop, power and scheduled jobs'
if ($cfg.EnableRdp) {
  Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
  Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1
  Set-InboundRule 'Sirena-RDP' 3389 @($TailscaleRange)
  Disable-OtherInboundRules 3389
  Write-Ok 'Remote Desktop on, Tailscale only'
}
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
$wu = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
New-Item -Path $wu -Force | Out-Null
Set-ItemProperty $wu -Name ActiveHoursStart -Value 6
Set-ItemProperty $wu -Name ActiveHoursEnd -Value 23
Write-Ok 'Never sleeps; Windows Update restarts only between 23:00 and 06:00'

function Register-SirenaTask([string]$Name, [string]$Script, $Trigger) {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$RepoDir\ops\windows\$Script`""
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
  Register-ScheduledTask -TaskName $Name -TaskPath '\Sirena\' -Action $action -Trigger $Trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
}
Register-SirenaTask 'Backup' 'backup.ps1' (New-ScheduledTaskTrigger -Daily -At $cfg.BackupTime)
Register-SirenaTask 'Restore test' 'restore-test.ps1' (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At '04:00')
Register-SirenaTask 'Cloudflare IPs' 'refresh-cloudflare.ps1' (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '05:00')
Write-Ok "Scheduled: backup daily $($cfg.BackupTime), restore test Sundays, Cloudflare IP refresh Mondays"

# ── Done ────────────────────────────────────────────────────────────────
Write-Step 'Done'
& "$PSScriptRoot\status.ps1"
Write-Host @"

  Database connection (pgAdmin / DBeaver / psql):
    Host      $($cfg.DbHost)   Port $($cfg.PgPort)   Database $DbName
    User      sirena_admin (read-write) or sirena_ro (read-only)
    Password  $SecretsDir\db-admin.txt / db-ro.txt
    SSL       verify-full, root certificate $SirenaRoot\sirena-db-ca.crt

  Copy those passwords and sirena-db-ca.crt to your laptop (password manager for the passwords).
"@
