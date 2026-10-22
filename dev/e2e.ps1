# dev/e2e.ps1 — end-to-end test of the whole platform through its real APIs.
#
# Runs locally (Windows PowerShell or pwsh) and in CI (pwsh on Linux), against the stack
# started by docker compose. Creates two brand-new users in Keycloak on every run, so the
# results don't depend on earlier tests. Exit code 0 = all checks passed, 1 = something failed.
#
#   .\dev\e2e.ps1

param(
    [int]$StartupTimeoutSec = 120,   # how long to wait for the services to be up
    [int]$SyncTimeoutSec = 45        # how long to wait for an account sync to happen
)

$ErrorActionPreference = "Stop"

$Keycloak = "http://localhost:8180"
$Accounts = "http://localhost:8081"
$Customers = "http://localhost:8082"

# ---------------------------------------------------------------------------
# Settings from .env (Keycloak admin, customer-service secret, account DB)
# ---------------------------------------------------------------------------
$envFile = Join-Path (Join-Path $PSScriptRoot "..") ".env"
$cfg = @{}
Get-Content $envFile | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=\s*(.*)$' } | ForEach-Object {
    $cfg[$Matches[1]] = $Matches[2].Trim()
}
$customerServiceSecret = if ($cfg["ACCOUNT_SYNC_CLIENT_SECRET"]) { $cfg["ACCOUNT_SYNC_CLIENT_SECRET"] } else { "customer-service-dev-secret" }

# ---------------------------------------------------------------------------
# Small test framework
# ---------------------------------------------------------------------------
$script:passed = 0
$script:failures = @()

function Section($title) { Write-Host "`n== $title" -ForegroundColor Cyan }

function Check($name, [bool]$ok, $detail = "") {
    if ($ok) {
        $script:passed++
        Write-Host "  PASS  $name" -ForegroundColor Green
    } else {
        $script:failures += $name
        Write-Host "  FAIL  $name  $detail" -ForegroundColor Red
    }
}

# Calls an API and NEVER throws on HTTP errors: returns @{ Status; Body } for both success and failure.
function Call($Method, $Uri, $Token, $Body, [hashtable]$Headers = @{}) {
    $h = @{} + $Headers
    if ($Token) { $h["Authorization"] = "Bearer $Token" }
    $params = @{ Method = $Method; Uri = $Uri; Headers = $h; UseBasicParsing = $true }
    if ($null -ne $Body) {
        $params["ContentType"] = "application/json"
        $params["Body"] = ($Body | ConvertTo-Json -Depth 6)
    }
    try {
        $r = Invoke-WebRequest @params
        $parsed = if ($r.Content) { $r.Content | ConvertFrom-Json } else { $null }
        return [pscustomobject]@{ Status = [int]$r.StatusCode; Body = $parsed; Raw = $r.Content }
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { throw }   # no HTTP answer at all (service down): a real error

        # Error body: pwsh 7 puts it in ErrorDetails; Windows PowerShell 5.1 sometimes doesn't,
        # so read it from the response stream instead.
        $text = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $text = $_.ErrorDetails.Message
        } elseif ($resp -is [System.Net.HttpWebResponse]) {
            try {
                $stream = $resp.GetResponseStream()
                if ($stream.CanSeek) { $stream.Position = 0 }
                $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
            } catch { }
        }
        $parsed = $null
        if ($text) { try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $text } }
        return [pscustomobject]@{ Status = [int]$resp.StatusCode; Body = $parsed; Raw = $text }
    }
}

function WaitUntil($what, $timeoutSec, [scriptblock]$condition) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if (& $condition) { return $true } } catch { }
        Start-Sleep -Seconds 1
    }
    Write-Host "  ...gave up waiting for: $what" -ForegroundColor Yellow
    return $false
}

function Token-ForUser($username) {
    (Invoke-RestMethod -Method Post -Uri "$Keycloak/realms/ddpay/protocol/openid-connect/token" -Body @{
        grant_type = "password"; client_id = "ddpay-app"; username = $username; password = "Test1234!"
    }).access_token
}

function Token-ForService($clientId, $secret) {
    (Invoke-RestMethod -Method Post -Uri "$Keycloak/realms/ddpay/protocol/openid-connect/token" -Body @{
        grant_type = "client_credentials"; client_id = $clientId; client_secret = $secret
    }).access_token
}

# Every KYC event gets a later timestamp than the previous one (customer-service ignores older events).
$script:clock = (Get-Date).ToUniversalTime()
function Send-Kyc($userId, $kyc, $aml, $phone, [string]$eventId = [guid]::NewGuid().ToString()) {
    $script:clock = $script:clock.AddSeconds(1)
    $at = $script:clock.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [cultureinfo]::InvariantCulture)
    Call Post "$Customers/internal/kyc/events" $script:ekycToken @{
        eventId = $eventId; type = "kyc.status_changed"; version = 1; occurredAt = $at; userId = $userId
        data = @{
            kycStatus = $kyc; amlStatus = $aml; parcours = "RESIDENT"; phone = $phone
            displayName = "E2E user"; kycVerifiedAt = $at
            validUntil = (Get-Date).AddYears(5).ToString("yyyy-MM-dd", [cultureinfo]::InvariantCulture)
        }
    }
}

function Account-Of($token) { Call Get "$Accounts/api/accounts/me" $token }

function Transfer($fromToken, $toUserId, $amountCentimes, $key) {
    $headers = @{}
    if ($key) { $headers["Idempotency-Key"] = $key }   # no key = header left out entirely
    Call Post "$Accounts/api/accounts/me/transfers" $fromToken @{
        toUserId = $toUserId; amountCentimes = $amountCentimes; description = "e2e"
    } $headers
}

# ===========================================================================
Section "Platform is up"
# ===========================================================================
$up = WaitUntil "Keycloak, account-service and customer-service" $StartupTimeoutSec {
    (Call Get "$Keycloak/realms/ddpay/.well-known/openid-configuration").Status -eq 200 -and
    (Call Get "$Accounts/actuator/health").Status -eq 200 -and
    (Call Get "$Customers/actuator/health").Status -eq 200
}
Check "Keycloak, account-service and customer-service answer" $up
if (-not $up) { Write-Host "`nPlatform not reachable, stopping." -ForegroundColor Red; exit 1 }

# ===========================================================================
Section "Two brand-new users"
# ===========================================================================
$run = (Get-Date).ToString("MMddHHmmss") + (Get-Random -Maximum 99)
$admin = (Invoke-RestMethod -Method Post -Uri "$Keycloak/realms/master/protocol/openid-connect/token" -Body @{
    grant_type = "password"; client_id = "admin-cli"
    username = $cfg["KEYCLOAK_ADMIN_USER"]; password = $cfg["KEYCLOAK_ADMIN_PASSWORD"]
}).access_token

$users = @{}
foreach ($who in "alice", "bob") {
    $username = "e2e-$who-$run"
    Invoke-RestMethod -Method Post -Uri "$Keycloak/admin/realms/ddpay/users" -Headers @{ Authorization = "Bearer $admin" } `
        -ContentType "application/json" -Body (@{
            username = $username; email = "$username@ddpay.test"; emailVerified = $true; enabled = $true
            firstName = $who; lastName = "E2E"
            credentials = @(@{ type = "password"; value = "Test1234!"; temporary = $false })
        } | ConvertTo-Json -Depth 4) | Out-Null
    $id = (Invoke-RestMethod -Uri "$Keycloak/admin/realms/ddpay/users?username=$username&exact=true" `
        -Headers @{ Authorization = "Bearer $admin" })[0].id
    $users[$who] = @{
        id = $id; token = (Token-ForUser $username)
        phone = "07" + (Get-Random -Minimum 10000000 -Maximum 99999999)
    }
}
$alice = $users["alice"]; $bob = $users["bob"]
Check "alice and bob created and logged in" ($alice.token -and $bob.token)

$script:ekycToken = Token-ForService "ekyc-simulator" "ekyc-simulator-dev-secret"
$serviceToken = Token-ForService "customer-service" $customerServiceSecret

# ===========================================================================
Section "Onboarding and KYC"
# ===========================================================================
$r = Call Post "$Customers/api/customers/me/onboarding" $alice.token
Check "alice starts onboarding -> 201, KYC PENDING, cannot transact" `
    ($r.Status -eq 201 -and $r.Body.kycStatus -eq "PENDING" -and $r.Body.canTransact -eq $false) "got $($r.Status)"

$r = Call Post "$Customers/api/customers/me/onboarding" $alice.token
Check "onboarding again -> 200, nothing created twice" ($r.Status -eq 200)

Check "no account before KYC" ((Account-Of $alice.token).Status -eq 404)

$eventId = [guid]::NewGuid().ToString()
$r = Send-Kyc $alice.id "VERIFIED" "CLEAR" $alice.phone $eventId
Check "eKYC verifies alice -> APPLIED, can transact" ($r.Body.result -eq "APPLIED" -and $r.Body.canTransact -eq $true)

$r = Send-Kyc $alice.id "VERIFIED" "CLEAR" $alice.phone $eventId
Check "same KYC event again -> DUPLICATE" ($r.Body.result -eq "DUPLICATE")

$r = Send-Kyc $bob.id "VERIFIED" "CLEAR" $bob.phone
Check "eKYC verifies bob (never onboarded in the app) -> APPLIED" ($r.Body.result -eq "APPLIED")

$r = Call Get "$Customers/api/customers/me" $alice.token
Check "alice's phone stored in international format" ($r.Body.phone -eq ("+213" + $alice.phone.Substring(1))) "got $($r.Body.phone)"

# ===========================================================================
Section "Accounts open by themselves"
# ===========================================================================
$ok = WaitUntil "alice's account" $SyncTimeoutSec { (Account-Of $alice.token).Status -eq 200 }
Check "alice's account opened automatically" $ok
$ok = WaitUntil "bob's account" $SyncTimeoutSec { (Account-Of $bob.token).Status -eq 200 }
Check "bob's account opened automatically" $ok

$a = (Account-Of $alice.token).Body
Check "alice's account is active, DZD, balance 0" ($a.status -eq "active" -and $a.currency -eq "DZD" -and $a.balanceCentimes -eq 0)

# ===========================================================================
Section "Money"
# ===========================================================================
$r = Call Post "$Accounts/internal/accounts/$($alice.id)/topups" $serviceToken `
    @{ amountCentimes = 500000; description = "e2e top-up" } @{ "Idempotency-Key" = "e2e-topup-$run" }
Check "top-up 5,000.00 DZD to alice -> 201" ($r.Status -eq 201 -and $r.Body.balanceAfterCentimes -eq 500000) "got $($r.Status)"

$key = "e2e-transfer-$run"
$r = Transfer $alice.token $bob.id 125000 $key
Check "alice sends 1,250.00 to bob -> 201, alice has 3,750.00" ($r.Status -eq 201 -and $r.Body.balanceAfterCentimes -eq 375000) "got $($r.Status)"

$r = Transfer $alice.token $bob.id 125000 $key
Check "same transfer retried (same key) -> replayed, not sent twice" ($r.Status -eq 200 -and $r.Body.replayed -eq $true)

$r = Transfer $alice.token $bob.id 999 $key
Check "same key, different amount -> 409 IDEMPOTENCY_KEY_REUSED" ($r.Status -eq 409 -and $r.Body.code -eq "IDEMPOTENCY_KEY_REUSED") "got $($r.Status), body: $($r.Raw)"

Check "bob has exactly 1,250.00" ((Account-Of $bob.token).Body.balanceCentimes -eq 125000)

$r = Transfer $bob.token $alice.id 9999900 "e2e-overdraft-$run"
Check "bob sends more than he has -> 422 INSUFFICIENT_FUNDS" ($r.Status -eq 422 -and $r.Body.code -eq "INSUFFICIENT_FUNDS") "got $($r.Status), body: $($r.Raw)"

$r = Transfer $alice.token $alice.id 100 "e2e-self-$run"
Check "alice sends to herself -> 400 SAME_ACCOUNT" ($r.Status -eq 400 -and $r.Body.code -eq "SAME_ACCOUNT") "got $($r.Status), body: $($r.Raw)"

$r = Transfer $alice.token $bob.id 100 $null
Check "transfer without Idempotency-Key -> 400" ($r.Status -eq 400)

# ===========================================================================
Section "Compliance: AML flag freezes the account"
# ===========================================================================
Send-Kyc $alice.id "VERIFIED" "FLAGGED" $alice.phone | Out-Null
$ok = WaitUntil "alice's account frozen" $SyncTimeoutSec { (Account-Of $alice.token).Body.status -eq "frozen" }
Check "alice flagged -> account frozen automatically" $ok

$r = Transfer $alice.token $bob.id 100 "e2e-frozen-$run"
Check "frozen alice cannot send -> 422 ACCOUNT_FROZEN" ($r.Status -eq 422 -and $r.Body.code -eq "ACCOUNT_FROZEN") "got $($r.Status), body: $($r.Raw)"

$r = Transfer $bob.token $alice.id 10000 "e2e-to-frozen-$run"
Check "frozen alice can still receive -> 201" ($r.Status -eq 201) "got $($r.Status)"

Send-Kyc $alice.id "VERIFIED" "CLEAR" $alice.phone | Out-Null
$ok = WaitUntil "alice's account active again" $SyncTimeoutSec { (Account-Of $alice.token).Body.status -eq "active" }
Check "alice cleared -> account unfrozen automatically" $ok

$r = Transfer $alice.token $bob.id 100 "e2e-after-clear-$run"
Check "alice can send again -> 201" ($r.Status -eq 201) "got $($r.Status)"

# ===========================================================================
Section "Security"
# ===========================================================================
Check "no token -> 401" ((Call Get "$Accounts/api/accounts/me" $null).Status -eq 401)
Check "customer cannot send KYC events -> 403" `
    ((Call Post "$Customers/internal/kyc/events" $alice.token @{ type = "kyc.status_changed" }).Status -eq 403)
Check "customer cannot use internal account API -> 403" `
    ((Call Get "$Accounts/internal/accounts/$($bob.id)" $alice.token).Status -eq 403)
Check "customer cannot top up their own account -> 403" `
    ((Call Post "$Accounts/internal/accounts/$($alice.id)/topups" $alice.token @{ amountCentimes = 100 } @{ "Idempotency-Key" = "e2e-hack-$run" }).Status -eq 403)

# ===========================================================================
Section "Ledger integrity (straight from the account database)"
# ===========================================================================
$dbUser = $cfg["ACCOUNT_DB_USER"]; $dbName = $cfg["ACCOUNT_DB_NAME"]
function Sql($query) { (docker exec account-db psql -tA -U $dbUser -d $dbName -c $query | Out-String).Trim() }

Check "every transaction balances (debits = credits)" ((Sql @"
SELECT count(*) FROM (SELECT transaction_id FROM ledger.entries GROUP BY 1
HAVING SUM(CASE WHEN direction = 'debit' THEN amount ELSE -amount END) <> 0) x
"@) -eq "0")

Check "all accounts together sum to exactly 0" ((Sql @"
SELECT COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount ELSE -amount END), 0) FROM ledger.entries
"@) -eq "0")

Check "no customer account below zero" ((Sql @"
SELECT count(*) FROM ledger.account_balances b JOIN ledger.accounts a ON a.id = b.account_id
 WHERE NOT a.allow_negative AND b.balance_centimes < 0
"@) -eq "0")

# ===========================================================================
$total = $script:passed + $script:failures.Count
Write-Host ""
if ($script:failures.Count -eq 0) {
    Write-Host "=== ALL $total END-TO-END CHECKS PASSED ===" -ForegroundColor Green
    exit 0
} else {
    Write-Host "=== $($script:failures.Count) OF $total CHECKS FAILED ===" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}