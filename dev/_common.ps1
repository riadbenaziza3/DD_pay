# dev/_common.ps1 — shared helpers for the dev scripts (dot-sourced, not run directly)

# Same fixed IDs as in infra/keycloak/ddpay-realm.json
$DevUsers = @{
    amine = "59b9fb4f-f422-406b-b325-d6b2b08023c3"
    sara  = "7d3c8a52-1f4e-4b6a-9c2d-5e8f0a1b2c3d"
    karim = "3f6a1c9e-8b2d-4e5f-a7c1-0d9e8f7a6b5c"
}

$AccountUrl = "http://localhost:8081"

# Calls an API and prints the JSON error body (code + message) instead of a bare HTTP error.
function Invoke-Api {
    param([string]$Method = "Get", [string]$Uri, [string]$Token, [hashtable]$Headers = @{}, $Body)
    $h = @{ Authorization = "Bearer $Token" } + $Headers
    try {
        if ($null -ne $Body) {
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $h -ContentType "application/json" `
                -Body ($Body | ConvertTo-Json -Depth 5)
        } else {
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $h
        }
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        Write-Host "HTTP $status" -ForegroundColor Red
        if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
    }
}

function ConvertTo-Centimes([decimal]$Dzd) { [long][math]::Round($Dzd * 100) }
