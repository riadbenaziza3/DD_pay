-- services/wallet-service/db-tests/balance_tests.sql
-- Checks the no-overdraft rule, one-wallet-per-user and the settlement account (V004).
-- Runs in one transaction and is ROLLED BACK at the end: no test data is kept.

\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.expect_error(test_name text, stmt text, expected_state text, expected_text text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
        SET CONSTRAINTS ALL IMMEDIATE;
    EXCEPTION WHEN OTHERS THEN
        SET CONSTRAINTS ALL DEFERRED;
        IF SQLSTATE = expected_state AND SQLERRM LIKE '%' || expected_text || '%' THEN
            RAISE NOTICE 'PASS: % (rejected: %)', test_name, SQLERRM;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL: % (expected % / %, got % - %)',
                        test_name, expected_state, expected_text, SQLSTATE, SQLERRM;
    END;
    RAISE EXCEPTION 'FAIL: % (was accepted but should have been rejected)', test_name;
END $$;

-- Settlement account exists and may go negative
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ledger.accounts
                    WHERE id = '00000000-0000-0000-0000-000000000001'
                      AND owner_type = 'system' AND allow_negative) THEN
        RAISE EXCEPTION 'FAIL: bank settlement account missing or not allowed to go negative';
    END IF;
    RAISE NOTICE 'PASS: bank settlement account exists';
END $$;

-- Test wallets: d1 gets 1,000.00 DZD, d2 is empty
INSERT INTO ledger.accounts (id, owner_type, user_id, name) VALUES
    ('00000000-0000-0000-0000-0000000000d1', 'user', '00000000-0000-0000-0000-0000000000f1', 'TEST wallet 1'),
    ('00000000-0000-0000-0000-0000000000d2', 'user', '00000000-0000-0000-0000-0000000000f2', 'TEST wallet 2');

DO $$
BEGIN
    INSERT INTO ledger.transactions (id, idempotency_key, type, amount)
    VALUES ('00000000-0000-0000-0000-0000000000c1', 'bal-topup', 'deposit', 100000);
    INSERT INTO ledger.entries (transaction_id, account_id, direction, amount) VALUES
        ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-000000000001', 'debit',  100000),
        ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000d1', 'credit', 100000);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
    RAISE NOTICE 'PASS: top-up from settlement account (settlement goes negative, allowed)';
END $$;

INSERT INTO ledger.transactions (id, idempotency_key, type, amount) VALUES
    ('00000000-0000-0000-0000-0000000000c2', 'bal-too-much', 'transfer', 150000),
    ('00000000-0000-0000-0000-0000000000c4', 'bal-empty',    'transfer', 1);

SELECT pg_temp.expect_error('spending more than the balance',
    $q$INSERT INTO ledger.entries (transaction_id, account_id, direction, amount) VALUES
       ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000d1', 'debit',  150000),
       ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000d2', 'credit', 150000)$q$,
    'P0001', 'INSUFFICIENT_FUNDS');

SELECT pg_temp.expect_error('spending from an empty wallet',
    $q$INSERT INTO ledger.entries (transaction_id, account_id, direction, amount) VALUES
       ('00000000-0000-0000-0000-0000000000c4', '00000000-0000-0000-0000-0000000000d2', 'debit',  1),
       ('00000000-0000-0000-0000-0000000000c4', '00000000-0000-0000-0000-0000000000d1', 'credit', 1)$q$,
    'P0001', 'INSUFFICIENT_FUNDS');

DO $$
DECLARE
    b bigint;
BEGIN
    INSERT INTO ledger.transactions (id, idempotency_key, type, amount)
    VALUES ('00000000-0000-0000-0000-0000000000c3', 'bal-exact', 'transfer', 100000);
    INSERT INTO ledger.entries (transaction_id, account_id, direction, amount) VALUES
        ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000d1', 'debit',  100000),
        ('00000000-0000-0000-0000-0000000000c3', '00000000-0000-0000-0000-0000000000d2', 'credit', 100000);
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    SELECT balance_centimes INTO b FROM ledger.account_balances
     WHERE account_id = '00000000-0000-0000-0000-0000000000d1';
    IF b <> 0 THEN
        RAISE EXCEPTION 'FAIL: wallet should be at exactly 0 after spending its whole balance, got %', b;
    END IF;
    RAISE NOTICE 'PASS: spending exactly the whole balance is allowed (balance now 0)';
END $$;

SELECT pg_temp.expect_error('second wallet for the same user',
    $q$INSERT INTO ledger.accounts (owner_type, user_id, name)
       VALUES ('user', '00000000-0000-0000-0000-0000000000f1', 'TEST second wallet')$q$,
    '23505', 'accounts_one_wallet_per_user');

\echo ''
\echo '=== ALL BALANCE TESTS PASSED ==='

ROLLBACK;
