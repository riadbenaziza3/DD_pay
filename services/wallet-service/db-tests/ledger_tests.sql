-- db/tests/ledger_tests.sql
-- Checks that the database itself enforces the money rules.
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
-- ---------------------------------------------------------------
INSERT INTO public.users (id, phone, full_name, kyc_status)
VALUES ('00000000-0000-0000-0000-0000000000a1', '+213555000001', 'Test User', 'verified');

INSERT INTO ledger.accounts (id, owner_type, user_id, name, allow_negative) VALUES
    ('00000000-0000-0000-0000-0000000000b1', 'system', NULL, 'TEST bank settlement', true),
    ('00000000-0000-0000-0000-0000000000b2', 'user', '00000000-0000-0000-0000-0000000000a1', 'TEST wallet', false);

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
        RAISE EXCEPTION 'FAIL: wallet balance should be 50000 centimes, got %', b;
    END IF;
    RAISE NOTICE 'PASS: wallet balance computed correctly (50000 centimes)';
END $$;

-- ---------------------------------------------------------------
-- Things that MUST be rejected
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

SELECT pg_temp.expect_error('non-DZD currency on an account',
    $q$INSERT INTO ledger.accounts (owner_type, name, currency)
       VALUES ('system', 'TEST euro', 'EUR')$q$,
    '23514');

SELECT pg_temp.expect_error('user wallet without a user',
    $q$INSERT INTO ledger.accounts (owner_type, name)
       VALUES ('user', 'TEST orphan wallet')$q$,
    '23514');

SELECT pg_temp.expect_error('merchant account without a merchant',
    $q$INSERT INTO ledger.accounts (owner_type, name)
       VALUES ('merchant', 'TEST orphan merchant account')$q$,
    '23514');

SELECT pg_temp.expect_error('merchant with an invalid RIB',
    $q$INSERT INTO public.merchants (owner_user_id, legal_name, settlement_rib)
       VALUES ('00000000-0000-0000-0000-0000000000a1', 'TEST SARL', '12345')$q$,
    '23514');

INSERT INTO public.audit_log (actor_type, action) VALUES ('system', 'test.event');

SELECT pg_temp.expect_error('editing the audit log',
    $q$UPDATE public.audit_log SET action = 'tampered'$q$,
    'P0001');

\echo ''
\echo '=== ALL DATABASE TESTS PASSED ==='

ROLLBACK;