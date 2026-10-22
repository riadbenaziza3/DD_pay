# dev/transfer.ps1 — one customer sends money to another, as the app would (dev only)
#
#   .\dev\transfer.ps1 -From amine -To sara -Amount 500
#   .\dev\transfer.ps1 -From amine -To sara -Amount 500 -Key retry-test-1   # run twice: sent only once

param(
    [ValidateSet("amine", "sara", "karim")]
    [string]$From = "amine",
    [ValidateSet("amine", "sara", "karim")]
    [string]$To = "sara",
    [decimal]$Amount = 100,
    [string]$Note = "Dev transfer",
    [string]$Key = [guid]::NewGuid().ToString()
)

. "$PSScriptRoot\_common.ps1"
$token = & "$PSScriptRoot\token.ps1" -User $From

Write-Host ("{0} -> {1}: {2:N2} DZD (Idempotency-Key {3})" -f $From, $To, $Amount, $Key)
Invoke-Api -Method Post -Uri "$AccountUrl/api/accounts/me/transfers" -Token $token `
    -Headers @{ "Idempotency-Key" = $Key } `
    -Body @{ toUserId = $DevUsers[$To]; amountCentimes = (ConvertTo-Centimes $Amount); description = $Note }
