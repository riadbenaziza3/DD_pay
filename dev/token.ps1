# dev/token.ps1 — get a login token from the local Keycloak (dev only)
#
#   $token = .\dev\token.ps1 -User amine                 # as a customer of the app
#   $ekyc  = .\dev\token.ps1 -EkycSimulator              # as the eKYC service
#   $svc   = .\dev\token.ps1 -Service customer-service   # as a PSP service (wallet-operator)

param(
    [string]$User = "amine",
    [string]$Password = "Test1234!",
    [switch]$EkycSimulator,
    [ValidateSet("", "ekyc-simulator", "customer-service")]
    [string]$Service = ""
)

$url = "http://localhost:8180/realms/ddpay/protocol/openid-connect/token"

# Dev-only secrets, same as in infra/keycloak/ddpay-realm.json
$secrets = @{
    "ekyc-simulator"   = "ekyc-simulator-dev-secret"
    "customer-service" = "customer-service-dev-secret"
}

if ($EkycSimulator) { $Service = "ekyc-simulator" }

if ($Service) {
    $body = @{
        grant_type    = "client_credentials"
        client_id     = $Service
        client_secret = $secrets[$Service]
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
