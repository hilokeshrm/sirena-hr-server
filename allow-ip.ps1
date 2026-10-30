<#
.SYNOPSIS
  Lets an IP address reach Postgres and/or SSH from the internet. Updates the firewall and pg_hba.conf.

.EXAMPLE
  .\allow-ip.ps1 -Ip 203.0.113.7 -Label "home"
  .\allow-ip.ps1 -Ip 198.51.100.0/24 -Label "office" -DbOnly
  .\allow-ip.ps1 -List
#>
param(
  [string]$Ip,
  [string]$Label,
  [switch]$DbOnly,
  [switch]$SshOnly,
  [switch]$List,
  # Used by setup.ps1, which syncs once afterwards.
  [switch]$NoSync
)

. "$PSScriptRoot\lib\common.ps1"
Assert-Admin

if ($List) {
  Get-Allowlist | Format-Table ip, label, db, ssh, added -AutoSize
  return
}
if (-not $Ip -or -not $Label) { throw 'Pass -Ip and -Label (or -List).' }

$cidr = ConvertTo-Cidr $Ip
$entries = @(Get-Allowlist | Where-Object { $_.ip -ne $cidr })
$entries += [pscustomobject]@{ ip = $cidr; label = $Label; db = (-not $SshOnly); ssh = (-not $DbOnly); added = (Get-Date -Format s) }
Save-Allowlist $entries
if (-not $NoSync) { Sync-Allowlist }
Write-Ok "Allowed $cidr ($Label): db=$(-not $SshOnly) ssh=$(-not $DbOnly)"
