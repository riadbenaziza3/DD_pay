# dev/token.ps1 — get a login token from the local Keycloak (dev only)
#
#   $token = .\dev\token.ps1 -User amine        # as a customer of the app
#   $ekyc  = .\dev\token.ps1 -EkycSimulator     # as the eKYC service

param(
    [string]$User = "amine",
    [string]$Password = "Test1234!",
    [switch]$EkycSimulator
)

$url = "http://localhost:8180/realms/ddpay/protocol/openid-connect/token"

if ($EkycSimulator) {
    $body = @{
        grant_type    = "client_credentials"
        client_id     = "ekyc-simulator"
        client_secret = "ekyc-simulator-dev-secret"
    }
} else {
    $body = @{
        grant_type = "password"
        client_id  = "ddpay-app"
        username   = $User
        password   = $Password
    }
}

(Invoke-RestMethod -Method Post -Uri $url -Body $body).access_token
