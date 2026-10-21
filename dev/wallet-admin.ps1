# dev/wallet-admin.ps1 — act as a PSP service on someone's wallet (dev only)
#
#   .\dev\wallet-admin.ps1 -Action open     -User amine
#   .\dev\wallet-admin.ps1 -Action topup    -User amine -Amount 5000      # 5,000.00 DZD
#   .\dev\wallet-admin.ps1 -Action freeze   -User amine
#   .\dev\wallet-admin.ps1 -Action unfreeze -User amine
#   .\dev\wallet-admin.ps1 -Action show     -User amine

param(
    [Parameter(Mandatory)][ValidateSet("open", "topup", "freeze", "unfreeze", "show")]
    [string]$Action,
    [ValidateSet("amine", "sara")]
    [string]$User = "amine",
    [decimal]$Amount = 1000,
    [string]$Key = [guid]::NewGuid().ToString()
)

. "$PSScriptRoot\_common.ps1"
$token = & "$PSScriptRoot\token.ps1" -Service customer-service
$id = $DevUsers[$User]

switch ($Action) {
    "open"     { Invoke-Api -Method Post -Uri "$WalletUrl/internal/wallets/$id" -Token $token }
    "show"     { Invoke-Api -Uri "$WalletUrl/internal/wallets/$id" -Token $token }
    "topup"    { Invoke-Api -Method Post -Uri "$WalletUrl/internal/wallets/$id/topups" -Token $token `
                    -Headers @{ "Idempotency-Key" = $Key } `
                    -Body @{ amountCentimes = (ConvertTo-Centimes $Amount); description = "Dev top-up" } }
    "freeze"   { Invoke-Api -Method Put -Uri "$WalletUrl/internal/wallets/$id/status" -Token $token `
                    -Body @{ status = "frozen"; reason = "dev test" } }
    "unfreeze" { Invoke-Api -Method Put -Uri "$WalletUrl/internal/wallets/$id/status" -Token $token `
                    -Body @{ status = "active"; reason = "dev test" } }
}
