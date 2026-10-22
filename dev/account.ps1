# dev/account.ps1 — what the customer sees in the app: balance and recent transactions (dev only)
#
#   .\dev\account.ps1 -User amine

param(
    [ValidateSet("amine", "sara")]
    [string]$User = "amine"
)

. "$PSScriptRoot\_common.ps1"
$token = & "$PSScriptRoot\token.ps1" -User $User

$w = Invoke-Api -Uri "$AccountUrl/api/accounts/me" -Token $token
if ($w) {
    Write-Host ("{0}: {1:N2} DZD  (account {2})" -f $User, ($w.balanceCentimes / 100), $w.status) -ForegroundColor Cyan
    $names = @{}
    foreach ($k in $DevUsers.Keys) { $names[$DevUsers[$k]] = $k }

    $tx = Invoke-Api -Uri "$AccountUrl/api/accounts/me/transactions?limit=10" -Token $token
    $tx | ForEach-Object {
        $cp = [string]$_.counterpartyUserId
        [pscustomobject]@{
            when   = ([datetime]$_.createdAt).ToLocalTime().ToString("HH:mm:ss")
            type   = $_.type
            amount = ("{0}{1:N2}" -f $(if ($_.direction -eq "credit") { "+" } else { "-" }), ($_.amountCentimes / 100))
            with   = $(if ($cp -and $names.ContainsKey($cp)) { $names[$cp] } elseif ($cp) { $cp } else { "bank" })
            note   = $_.description
        }
    } | Format-Table -AutoSize
}
