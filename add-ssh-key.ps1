<#
.SYNOPSIS
  Authorises an SSH public key to log in as an administrator on this machine.

.EXAMPLE
  .\add-ssh-key.ps1 -Key "ssh-ed25519 AAAAC3Nza... laptop"
  .\add-ssh-key.ps1 -File .\laptop.pub
#>
param([string]$Key, [string]$File)

. "$PSScriptRoot\lib\common.ps1"
Assert-Admin

if ($File) { $Key = (Get-Content $File -Raw) }
$Key = "$Key".Trim()
if ($Key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+) [A-Za-z0-9+/=]+') { throw 'That does not look like an SSH public key (it should start with ssh-ed25519).' }

$existing = @()
if (Test-Path $AdminKeysPath) { $existing = @(Get-Content $AdminKeysPath | Where-Object { $_.Trim() }) }
$blob = ($Key -split ' ')[1]
if ($existing | Where-Object { $_ -like "*$blob*" }) { Write-Ok 'Key already authorised'; return }
[IO.File]::WriteAllLines($AdminKeysPath, [string[]]($existing + $Key))
# sshd ignores this file unless only Administrators and SYSTEM can access it.
Invoke-Native icacls.exe @($AdminKeysPath, '/inheritance:r', '/grant', '*S-1-5-32-544:F', '/grant', '*S-1-5-18:F') | Out-Null
Write-Ok "Key authorised: $(($Key -split ' ') | Select-Object -Skip 2)"
