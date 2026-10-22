# dev/account-admin.ps1 — act as a PSP service on someone's account (dev only)
#
#   .\dev\account-admin.ps1 -Action open     -User amine
#   .\dev\account-admin.ps1 -Action topup    -User amine -Amount 5000      # 5,000.00 DZD
#   .\dev\account-admin.ps1 -Action freeze   -User amine
#   .\dev\account-admin.ps1 -Action unfreeze -User amine
#   .\dev\account-admin.ps1 -Action show     -User amine

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
    "open"     { Invoke-Api -Method Post -Uri "$AccountUrl/internal/accounts/$id" -Token $token }
    "show"     { Invoke-Api -Uri "$AccountUrl/internal/accounts/$id" -Token $token }
    "topup"    { Invoke-Api -Method Post -Uri "$AccountUrl/internal/accounts/$id/topups" -Token $token `
                    -Headers @{ "Idempotency-Key" = $Key } `
                    -Body @{ amountCentimes = (ConvertTo-Centimes $Amount); description = "Dev top-up" } }
    "freeze"   { Invoke-Api -Method Put -Uri "$AccountUrl/internal/accounts/$id/status" -Token $token `
                    -Body @{ status = "frozen"; reason = "dev test" } }
    "unfreeze" { Invoke-Api -Method Put -Uri "$AccountUrl/internal/accounts/$id/status" -Token $token `
                    -Body @{ status = "active"; reason = "dev test" } }
}
