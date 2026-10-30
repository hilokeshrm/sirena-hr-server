<#
.SYNOPSIS
  Runs SQL against sirena_hr on this machine. Read-only by default.

.EXAMPLE
  .\sql.ps1 'SELECT code, "fullName", role FROM "Employee" ORDER BY code'
  .\sql.ps1 -Write 'UPDATE "Employee" SET role = ''HR'' WHERE email = ''meena.k@sirena.in'''
#>
param(
  [Parameter(Mandatory, Position = 0)][string]$Query,
  # Run as sirena_admin instead of the read-only role.
  [switch]$Write
)

. "$PSScriptRoot\lib\common.ps1"
$user = if ($Write) { 'sirena_admin' } else { 'sirena_ro' }
Invoke-Psql $Query -Database $DbName -User $user -Table
