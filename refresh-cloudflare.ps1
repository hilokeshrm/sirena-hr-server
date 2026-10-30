<#
.SYNOPSIS
  Re-reads Cloudflare's published IP ranges and updates the port 443 firewall rule and Caddy.
  Runs Mondays as SYSTEM (scheduled by setup.ps1).
#>
. "$PSScriptRoot\lib\common.ps1"
$before = if (Test-Path $CloudflareIpsPath) { Get-Content $CloudflareIpsPath -Raw } else { '' }
Update-CloudflareRanges | Out-Null
if ((Get-Content $CloudflareIpsPath -Raw) -eq $before) { Write-Ok 'Cloudflare ranges unchanged'; return }
Write-CaddyConfig
Restart-Service $CaddyService
Write-Ok 'Cloudflare ranges changed; firewall and Caddy updated'
