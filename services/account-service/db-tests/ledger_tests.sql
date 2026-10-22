-- services/account-service/db-tests/ledger_tests.sql
-- Checks that the account database itself enforces the money rules.
-- Everything runs inside one transaction and is ROLLED BACK at the end,
-- so it is safe to run against your local database: no test data is kept.
-- Any failure stops the script with an error (and turns CI red).

\set ON_ERROR_STOP on
BEGIN;

-- Helper: run one SQL statement and require it to FAIL with a given error code.
CREATE FUNCTION pg_temp.expect_error(test_name text, stmt text, expected_state text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
        SET CONSTRAINTS ALL IMMEDIATE;   -- force the deferred balance check to run now
    EXCEPTION WHEN OTHERS THEN
        SET CONSTRAINTS ALL DEFERRED;
        IF SQLSTATE = expected_state THEN
            RAISE NOTICE 'PASS: % (rejected: %)', test_name, SQLERRM;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL: % (expected error %, got % - %)',
                        test_name, expected_state, SQLSTATE, SQLERRM;
    END;
    RAISE EXCEPTION 'FAIL: % (was accepted but should have been rejected)', test_name;
END $$;

-- ---------------------------------------------------------------
-- Test data
--   b1 = system settlement account   b2 = active user account
--   b3 = frozen user account          b4 = closed user account
-- User IDs are plain UUIDs: users live in customer-service now.
-- ---------------------------------------------------------------
INSERT INTO ledger.accounts (id, owner_type, user_id, name, allow_negative, status) VALUES
    ('00000000-0000-0000-0000-0000000000b1', 'system', NULL,                                   'TEST bank settlement', true,  'active'),
    ('00000000-0000-0000-0000-0000000000b2', 'user',   '00000000-0000-0000-0000-0000000000a1', 'TEST active account',   false, 'active'),
    ('00000000-0000-0000-0000-0000000000b3', 'user',   '00000000-0000-0000-0000-0000000000a2', 'TEST frozen account',   false, 'frozen'),
    ('00000000-0000-0000-0000-0000000000b4', 'user',   '00000000-0000-0000-0000-0000000000a3', 'TEST closed account',   false, 'closed');

-- ---------------------------------------------------------------
-- Things that MUST work
-- ---------------------------------------------------------------
DO $$
BEGIN
    INSERT INTO ledger.transactions (id, idempotency_key, type, amount)
    VALUES ('00000000-0000-0000-0000-0000000000c1', 'test-deposit-1', 'deposit', 50000);

    INSERT INTO ledger.entries (transaction_id, account_id, direction, amount) VALUES
        ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b1', 'debit',  50000),
        ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000b2', 'credit', 50000);

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'PASS: balanced deposit of 500.00 DZD accepted';
END $$;

DO $$
DECLARE
    b bigint;
BEGIN
    SELECT balance_centimes INTO b
      FROM ledger.account_balances
     WHERE account_id = '00000000-0000-0000-0000-0000000000b2';

    IF b IS DISTINCT FROM 50000 THEN
        RAISE EXCEPTION 'FAIL: account balance should be 50000 centimes, got %', b;
    END IF;
    RAISE NOTICE 'PASS: account balance computed correctly (50000 centimes)';
END $$;

DO $$
BEGIN
    INSERT INTO ledger.transactions (id, idempotency_key, type, amount)
    VALUES ('00000000-0000-0000-0000-0000000000c3', 'test-credit-frozen', 'deposit', 1000);

    INSERT INTO ledger.entries (transaction_id, account_id, direction, amount) VALUES
        ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000b1', 'debit',  1000),
        ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000b3', 'credit', 1000);

    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'PASS: frozen account can still receive funds';
END $$;

-- ---------------------------------------------------------------
-- Things that MUST be rejected: money rules
-- ---------------------------------------------------------------
INSERT INTO ledger.transactions (id, idempotency_key, type, amount)
VALUES ('00000000-0000-0000-0000-0000000000c2', 'test-unbalanced', 'deposit', 1000);

SELECT pg_temp.expect_error('unbalanced transaction (credit with no debit)',
    $q$INSERT INTO ledger.entries (transaction_id, account_id, direction, amount)
       VALUES ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000b2', 'credit', 1000)$q$,
    'P0001');

SELECT pg_temp.expect_error('editing a ledger entry',
    $q$UPDATE ledger.entries SET amount = 1$q$,
    'P0001');

SELECT pg_temp.expect_error('deleting a ledger entry',
    $q$DELETE FROM ledger.entries$q$,
    'P0001');

SELECT pg_temp.expect_error('reusing an idempotency key (double charge)',
    $q$INSERT INTO ledger.transactions (idempotency_key, type, amount)
       VALUES ('test-deposit-1', 'deposit', 50000)$q$,
    '23505');

SELECT pg_temp.expect_error('zero amount',
    $q$INSERT INTO ledger.transactions (idempotency_key, type, amount)
       VALUES ('test-zero', 'deposit', 0)$q$,
    '23514');

-- ---------------------------------------------------------------
-- Things that MUST be rejected: account status (V003)
-- ---------------------------------------------------------------
INSERT INTO ledger.transactions (id, idempotency_key, type, amount) VALUES
    ('00000000-0000-0000-0000-0000000000c4', 'test-debit-frozen', 'transfer', 500),
    ('00000000-0000-0000-0000-0000000000c5', 'test-credit-closed', 'deposit', 500),
    ('00000000-0000-0000-0000-0000000000c6', 'test-debit-closed', 'transfer', 500);

SELECT pg_temp.expect_error('sending money from a frozen account',
    $q$INSERT INTO ledger.entries (transaction_id, account_id, direction, amount) VALUES
       ('00000000-0000-0000-0000-0000000000c4', '00000000-0000-0000-0000-0000000000b3', 'debit',  500),
       ('00000000-0000-0000-0000-0000000000c4', '00000000-0000-0000-0000-0000000000b2', 'credit', 500)$q$,
    'P0001');

SELECT pg_temp.expect_error('sending money to a closed account',
    $q$INSERT INTO ledger.entries (transaction_id, account_id, direction, amount) VALUES
       ('00000000-0000-0000-0000-0000000000c5', '00000000-0000-0000-0000-0000000000b1', 'debit',  500),
       ('00000000-0000-0000-0000-0000000000c5', '00000000-0000-0000-0000-0000000000b4', 'credit', 500)$q$,
    'P0001');

SELECT pg_temp.expect_error('sending money from a closed account',
    $q$INSERT INTO ledger.entries (transaction_id, account_id, direction, amount) VALUES
       ('00000000-0000-0000-0000-0000000000c6', '00000000-0000-0000-0000-0000000000b4', 'debit',  500),
       ('00000000-0000-0000-0000-0000000000c6', '00000000-0000-0000-0000-0000000000b2', 'credit', 500)$q$,
    'P0001');

-- ---------------------------------------------------------------
-- Things that MUST be rejected: account structure
-- ---------------------------------------------------------------
SELECT pg_temp.expect_error('non-DZD currency on an account',
    $q$INSERT INTO ledger.accounts (owner_type, name, currency)
       VALUES ('system', 'TEST euro', 'EUR')$q$,
    '23514');

SELECT pg_temp.expect_error('user account without a user ID',
    $q$INSERT INTO ledger.accounts (owner_type, name)
       VALUES ('user', 'TEST orphan account')$q$,
    '23514');

SELECT pg_temp.expect_error('merchant account without a merchant ID',
    $q$INSERT INTO ledger.accounts (owner_type, name)
       VALUES ('merchant', 'TEST orphan merchant account')$q$,
    '23514');

SELECT pg_temp.expect_error('unknown account status',
    $q$INSERT INTO ledger.accounts (owner_type, name, status)
       VALUES ('system', 'TEST weird', 'sleeping')$q$,
    '23514');

-- ---------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------
INSERT INTO public.audit_log (actor_type, action) VALUES ('system', 'test.event');

SELECT pg_temp.expect_error('editing the audit log',
    $q$UPDATE public.audit_log SET action = 'tampered'$q$,
    'P0001');

-- ---------------------------------------------------------------
-- Users and merchants must no longer exist in the account database
-- ---------------------------------------------------------------
DO $$
BEGIN
    IF to_regclass('public.users') IS NOT NULL OR to_regclass('public.merchants') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: users/merchants tables still exist in the account database';
    END IF;
    RAISE NOTICE 'PASS: account database holds no users or merchants tables';
END $$;

\echo ''
\echo '=== ALL DATABASE TESTS PASSED ==='

ROLLBACK;
