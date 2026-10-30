<#
.SYNOPSIS
  Pulls the latest code, migrates the database, rebuilds and restarts the API, and rebuilds the website.

.DESCRIPTION
  Order: backup > stop API > build API > migrate > start API > health check > build website.
  The API is down for the build (about a minute; Windows locks files a running API uses).
  The website stays up throughout. If the API fails its health check the code is rolled back
  to the previous commit; database migrations are not undone, so a pre-deploy backup is taken first.

.EXAMPLE
  .\deploy.ps1                      # deploy the configured branch
  .\deploy.ps1 -Ref 1a2b3c4         # deploy a specific commit (also how you roll back by hand)
  .\deploy.ps1 -SkipWeb             # API only
#>
param([string]$Ref, [switch]$SkipBackup, [switch]$SkipFetch, [switch]$SkipWeb)

. "$PSScriptRoot\lib\common.ps1"
Assert-Admin
$cfg = Get-SirenaConfig
Update-PathFromRegistry
$backend = "$RepoDir\backend"
$app = "$RepoDir\app"

Start-Transcript -Path "$LogsDir\deploy-$(Get-Date -Format 'yyyyMMdd-HHmmss').log" | Out-Null
try {
  $prev = (Invoke-Native git.exe @('-C', $RepoDir, 'rev-parse', 'HEAD')) | Select-Object -First 1
  if (-not $SkipFetch) {
    Write-Step 'Fetching code'
    Invoke-Native git.exe @('-C', $RepoDir, 'fetch', '--prune', 'origin') | Out-Null
    $target = if ($Ref) { $Ref } else { "origin/$($cfg.Branch)" }
    Invoke-Native git.exe @('-C', $RepoDir, 'reset', '--hard', $target) | Out-Null
  }
  $new = (Invoke-Native git.exe @('-C', $RepoDir, 'rev-parse', 'HEAD')) | Select-Object -First 1
  Write-Ok "$($prev.Substring(0, 7)) -> $($new.Substring(0, 7))"

  if (-not $SkipBackup) {
    Write-Step 'Pre-deploy backup'
    & "$PSScriptRoot\backup.ps1" -Kind predeploy
  }

  function Build-Api {
    Invoke-Native npm.cmd @('ci', '--no-audit', '--no-fund') -WorkDir $backend | Out-Null
    Invoke-Native npx.cmd @('prisma', 'generate') -WorkDir $backend | Out-Null
    Invoke-Native npm.cmd @('run', 'build') -WorkDir $backend | Out-Null
  }

  Write-Step 'API'
  Stop-Service $ApiService -ErrorAction SilentlyContinue
  try {
    Build-Api
    Invoke-Native npx.cmd @('prisma', 'migrate', 'deploy') -WorkDir $backend | Select-Object -Last 3 | ForEach-Object { Write-Ok $_ }
    Grant-ReadOnly
    Start-Service $ApiService
    if (-not (Test-ApiHealth)) { throw 'API did not pass its health check.' }
    Write-Ok 'API healthy'
  } catch {
    $err = $_
    if ($new -ne $prev) {
      Write-Note "Deploy failed: $err"
      Write-Note "Rolling back code to $($prev.Substring(0, 7))"
      Stop-Service $ApiService -ErrorAction SilentlyContinue
      Invoke-Native git.exe @('-C', $RepoDir, 'reset', '--hard', $prev) | Out-Null
      Build-Api
      Start-Service $ApiService
      $ok = Test-ApiHealth
      throw "Deploy of $($new.Substring(0, 7)) failed and was rolled back (API healthy: $ok). Migrations that ran were not undone; the pre-deploy backup is in $BackupsDir\predeploy. Error: $err"
    }
    throw
  }

  if (-not $SkipWeb) {
    Write-Step 'Website'
    Invoke-Native $FlutterBat @('pub', 'get') -WorkDir $app | Out-Null
    Invoke-Native $FlutterBat @('build', 'web', '--release', "--dart-define=API_BASE=https://$($cfg.Domain)/api") -WorkDir $app | Out-Null
    # robocopy exit codes below 8 mean success
    Invoke-Native robocopy.exe @("$app\build\web", $WwwDir, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -OkCodes 0, 1, 2, 3, 4, 5, 6, 7 | Out-Null
    Write-Ok "Website published to $WwwDir"
  }

  [IO.File]::WriteAllText("$SirenaRoot\deployed.txt", "$new $(Get-Date -Format s)")
  Write-Step "Deployed $($new.Substring(0, 7))"
} finally {
  Stop-Transcript | Out-Null
}
