# Copy to config.psd1 (same folder), edit, then run setup.ps1.
# setup.ps1 copies it to C:\sirena\config.psd1, which every other script reads.
@{
  # Public website + API (Cloudflare, proxied / orange cloud)
  Domain       = 'hr.sirenatech.com'
  # Database host name (Cloudflare, DNS only / grey cloud)
  DbHost       = 'db.sirenatech.com'

  # Code. setup.ps1 creates a read-only deploy key for this repo.
  RepoSsh      = 'git@github.com:hilokeshrm/sirena-hr.git'
  Branch       = 'main'

  PgMajor      = 17
  PgPort       = 5432

  # Lunch booking closes at this local time on the day itself
  MealCutoff   = '10:30'

  # Remote Desktop, reachable over Tailscale only
  EnableRdp    = $true

  # Backups
  BackupTime   = '02:00'
  DailyKeep    = 14
  WeeklyKeep   = 8
  # Optional second copy off this disk, e.g. 'D:\SirenaBackups' or '\\nas\backups\sirena'
  OffsiteDir   = ''
  # Optional rclone remote, e.g. 'b2:sirena-backups' (install rclone and run "rclone config" first)
  RcloneRemote = ''
  # Optional Healthchecks.io ping URL; you get an alert if a night's backup doesn't arrive
  BackupPingUrl = ''
}
