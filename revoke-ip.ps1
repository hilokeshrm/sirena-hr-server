<#
.SYNOPSIS
  Removes an allowlist entry by IP or label. Its Postgres and SSH access stop immediately.

.EXAMPLE
  .\revoke-ip.ps1 -Ip 203.0.113.7
  .\revoke-ip.ps1 -Label "old office"
#>
param([string]$Ip, [string]$Label)

. "$PSScriptRoot\lib\common.ps1"
Assert-Admin
if (-not $Ip -and -not $Label) { throw 'Pass -Ip or -Label.' }

$cidr = if ($Ip) { ConvertTo-Cidr $Ip } else { $null }
$before = @(Get-Allowlist)
$after = @($before | Where-Object { -not (($cidr -and $_.ip -eq $cidr) -or ($Label -and $_.label -eq $Label)) })
if ($after.Count -eq $before.Count) { throw 'No matching entry. See .\allow-ip.ps1 -List' }
Save-Allowlist $after
Sync-Allowlist
Write-Ok "Removed $($before.Count - $after.Count) entr$(if ($before.Count - $after.Count -eq 1) { 'y' } else { 'ies' })"
