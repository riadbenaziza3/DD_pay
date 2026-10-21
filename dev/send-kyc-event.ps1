# dev/send-kyc-event.ps1 — play the eKYC: tell customer-service a user's KYC status changed (dev only)
#
# Examples:
#   .\dev\send-kyc-event.ps1 -User amine -KycStatus VERIFIED -AmlStatus CLEAR -Phone "0555 12 34 56"
#   .\dev\send-kyc-event.ps1 -User amine -KycStatus VERIFIED -AmlStatus FLAGGED
#   .\dev\send-kyc-event.ps1 -User amine -KycStatus VERIFIED -AmlStatus CLEAR -ValidUntil 2025-01-01
#   .\dev\send-kyc-event.ps1 -User sara  -KycStatus REJECTED
#   .\dev\send-kyc-event.ps1 -User amine -KycStatus VERIFIED -EventId 11111111-1111-1111-1111-111111111111   # send twice to test duplicates

param(
    [ValidateSet("amine", "sara")]
    [string]$User = "amine",

    [ValidateSet("PENDING", "VERIFIED", "REJECTED", "BLOCKED")]
    [string]$KycStatus = "VERIFIED",

    [ValidateSet("CLEAR", "FLAGGED", "BLOCKED")]
    [string]$AmlStatus = "CLEAR",

    [ValidateSet("RESIDENT", "DIASPORA")]
    [string]$Parcours = "RESIDENT",

    [string]$Phone,
    [string]$ValidUntil = (Get-Date).AddYears(5).ToString("yyyy-MM-dd"),
    [string]$EventId = [guid]::NewGuid().ToString(),
    [string]$OccurredAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
)

# Same fixed IDs as in infra/keycloak/ddpay-realm.json
$users = @{
    amine = @{ id = "59b9fb4f-f422-406b-b325-d6b2b08023c3"; name = "Amine Test"; phone = "0555000001"; number = "DAS000001" }
    sara  = @{ id = "7d3c8a52-1f4e-4b6a-9c2d-5e8f0a1b2c3d"; name = "Sara Test";  phone = "0555000002"; number = "DAS000002" }
}
$u = $users[$User]
if (-not $Phone) { $Phone = $u.phone }

$event = [ordered]@{
    eventId    = $EventId
    type       = "kyc.status_changed"
    version    = 1
    occurredAt = $OccurredAt
    userId     = $u.id
    data       = [ordered]@{
        kycStatus      = $KycStatus
        amlStatus      = $AmlStatus
        parcours       = $Parcours
        customerNumber = $u.number
        phone          = $Phone
        displayName    = $u.name
        kycVerifiedAt  = $(if ($KycStatus -eq "VERIFIED") { $OccurredAt } else { $null })
        validUntil     = $ValidUntil
    }
}

$token = & "$PSScriptRoot\token.ps1" -EkycSimulator

Write-Host "Sending event $EventId : $User -> KYC $KycStatus / AML $AmlStatus / valid until $ValidUntil"
Invoke-RestMethod -Method Post -Uri "http://localhost:8082/internal/kyc/events" `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType "application/json" `
    -Body ($event | ConvertTo-Json -Depth 5)
