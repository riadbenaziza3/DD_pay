# dev/sync-status.ps1 — shows the account sync: each customer's state and the latest outbox rows (dev only)
#
#   .\dev\sync-status.ps1

# Read the customer database name and user from .env
$envFile = Join-Path $PSScriptRoot "..\.env"
$vars = @{}
Get-Content $envFile | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=\s*(.*)$' } | ForEach-Object {
    $vars[$Matches[1]] = $Matches[2].Trim()
}
$db   = $vars["CUSTOMER_DB_NAME"]
$user = $vars["CUSTOMER_DB_USER"]

Write-Host "`nCustomers" -ForegroundColor Cyan
docker exec customer-db psql -q -U $user -d $db -c @"
SELECT left(id::text, 8) AS customer, display_name, kyc_status, aml_status, kyc_valid_until,
       public.customer_can_transact(id) AS can_transact,
       account_state_synced AS account, to_char(account_synced_at, 'HH24:MI:SS') AS synced_at
  FROM public.customers ORDER BY created_at;
"@

Write-Host "Outbox (latest 10)" -ForegroundColor Cyan
docker exec customer-db psql -q -U $user -d $db -c @"
SELECT id, left(aggregate_id::text, 8) AS customer, payload->>'trigger' AS trigger, attempts,
       CASE WHEN processed_at IS NOT NULL AND last_error LIKE 'PERMANENT%' THEN 'FAILED'
            WHEN processed_at IS NOT NULL THEN 'done'
            WHEN next_attempt_at > now() THEN 'retrying'
            ELSE 'pending' END AS state,
       left(last_error, 60) AS last_error
  FROM public.outbox ORDER BY id DESC LIMIT 10;
"@
