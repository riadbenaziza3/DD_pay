-- services/customer-service/db-tests/account_sync_tests.sql
-- Checks the account-sync outbox and the desired-state rules (V003).
-- Runs in one transaction and is ROLLED BACK at the end: no test data is kept.

\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.expect_error(test_name text, stmt text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = expected_state THEN
            RAISE NOTICE 'PASS: % (rejected: %)', test_name, SQLERRM;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL: % (expected error %, got % - %)',
                        test_name, expected_state, SQLSTATE, SQLERRM;
    END;
    RAISE EXCEPTION 'FAIL: % (was accepted but should have been rejected)', test_name;
END $$;

CREATE FUNCTION pg_temp.expect_state(test_name text, p_id uuid, expected text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    got text := public.desired_account_state(p_id);
BEGIN
    IF got IS DISTINCT FROM expected THEN
        RAISE EXCEPTION 'FAIL: % (expected %, got %)', test_name, expected, got;
    END IF;
    RAISE NOTICE 'PASS: %', test_name;
END $$;

-- ---------------------------------------------------------------
-- Test customers
--   b1 verified, no account yet            -> active (open it)
--   b2 verified, account active            -> active (nothing to do)
--   b3 AML flagged, account active         -> frozen
--   b4 AML flagged, no account             -> none   (never open an account for them)
--   b5 ID expired, account active          -> frozen
--   b6 pending KYC, no account             -> none
--   b7 verified again, account frozen      -> active (unfreeze)
--   b8 account closed                      -> closed (final)
-- ---------------------------------------------------------------
INSERT INTO public.customers (id, kyc_status, aml_status, kyc_valid_until, account_state_synced) VALUES
    ('00000000-0000-0000-0000-0000000000b1', 'VERIFIED', 'CLEAR',   current_date + 365, 'none'),
    ('00000000-0000-0000-0000-0000000000b2', 'VERIFIED', 'CLEAR',   current_date + 365, 'active'),
    ('00000000-0000-0000-0000-0000000000b3', 'VERIFIED', 'FLAGGED', current_date + 365, 'active'),
    ('00000000-0000-0000-0000-0000000000b4', 'VERIFIED', 'FLAGGED', current_date + 365, 'none'),
    ('00000000-0000-0000-0000-0000000000b5', 'VERIFIED', 'CLEAR',   current_date - 1,   'active'),
    ('00000000-0000-0000-0000-0000000000b6', 'PENDING',  NULL,      NULL,               'none'),
    ('00000000-0000-0000-0000-0000000000b7', 'VERIFIED', 'CLEAR',   current_date + 365, 'frozen'),
    ('00000000-0000-0000-0000-0000000000b8', 'VERIFIED', 'CLEAR',   current_date + 365, 'closed');

SELECT pg_temp.expect_state('verified customer without account -> open it',     '00000000-0000-0000-0000-0000000000b1', 'active');
SELECT pg_temp.expect_state('verified customer with active account -> keep',    '00000000-0000-0000-0000-0000000000b2', 'active');
SELECT pg_temp.expect_state('AML flagged with active account -> freeze',        '00000000-0000-0000-0000-0000000000b3', 'frozen');
SELECT pg_temp.expect_state('AML flagged without account -> do not open one',   '00000000-0000-0000-0000-0000000000b4', 'none');
SELECT pg_temp.expect_state('expired ID with active account -> freeze',         '00000000-0000-0000-0000-0000000000b5', 'frozen');
SELECT pg_temp.expect_state('pending KYC -> no account',                        '00000000-0000-0000-0000-0000000000b6', 'none');
SELECT pg_temp.expect_state('cleared again with frozen account -> unfreeze',    '00000000-0000-0000-0000-0000000000b7', 'active');
SELECT pg_temp.expect_state('closed account stays closed',                      '00000000-0000-0000-0000-0000000000b8', 'closed');

-- ---------------------------------------------------------------
-- Drift detection queues exactly the customers that need a change
-- ---------------------------------------------------------------
-- b7 already has a sync waiting: it must not be queued twice.
INSERT INTO public.outbox (type, aggregate_id) VALUES ('account.sync', '00000000-0000-0000-0000-0000000000b7');

DO $$
DECLARE
    n int;
    queued text;
BEGIN
    n := public.enqueue_account_sync_drift();
    SELECT string_agg(right(aggregate_id::text, 2), ',' ORDER BY aggregate_id) INTO queued
      FROM public.outbox WHERE processed_at IS NULL AND payload->>'trigger' = 'reconcile';

    IF n <> 3 OR queued <> 'b1,b3,b5' THEN
        RAISE EXCEPTION 'FAIL: drift should queue b1,b3,b5 (3 rows), got % rows: %', n, queued;
    END IF;
    RAISE NOTICE 'PASS: drift detection queued b1, b3, b5 only (not b7: already waiting)';

    n := public.enqueue_account_sync_drift();
    IF n <> 0 THEN
        RAISE EXCEPTION 'FAIL: running drift detection again should queue nothing, queued %', n;
    END IF;
    RAISE NOTICE 'PASS: drift detection does not queue duplicates';
END $$;

-- ---------------------------------------------------------------
-- Constraints
-- ---------------------------------------------------------------
SELECT pg_temp.expect_error('unknown synced account state',
    $q$UPDATE public.customers SET account_state_synced = 'sleeping'
        WHERE id = '00000000-0000-0000-0000-0000000000b1'$q$,
    '23514');

SELECT pg_temp.expect_error('unknown outbox message type',
    $q$INSERT INTO public.outbox (type, aggregate_id)
       VALUES ('send.money', '00000000-0000-0000-0000-0000000000b1')$q$,
    '23514');

SELECT pg_temp.expect_error('outbox row without a customer',
    $q$INSERT INTO public.outbox (type) VALUES ('account.sync')$q$,
    '23502');

\echo ''
\echo '=== ALL ACCOUNT SYNC TESTS PASSED ==='

ROLLBACK;
