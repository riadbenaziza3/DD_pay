-- services/customer-service/db-tests/customer_tests.sql
-- Checks that the customer database enforces its rules.
-- Runs in one transaction and is ROLLED BACK at the end: no test data is kept.

\set ON_ERROR_STOP on
BEGIN;

-- Helper: run one SQL statement and require it to FAIL with a given error code.
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

-- ---------------------------------------------------------------
-- Test data
--   a1 = verified, AML clear, active        -> may transact
--   a2 = AML flagged                        -> may not
--   a3 = ID document expired                -> may not
--   a4 = suspended by the PSP               -> may not
--   a5 = KYC still pending                  -> may not
-- ---------------------------------------------------------------
INSERT INTO public.customers (id, phone, display_name, parcours, kyc_status, aml_status, kyc_valid_until, status) VALUES
    ('00000000-0000-0000-0000-0000000000a1', '+213555000001', 'Test OK',        'RESIDENT', 'VERIFIED', 'CLEAR',   current_date + 365, 'active'),
    ('00000000-0000-0000-0000-0000000000a2', '+213555000002', 'Test Flagged',   'RESIDENT', 'VERIFIED', 'FLAGGED', current_date + 365, 'active'),
    ('00000000-0000-0000-0000-0000000000a3', '+213555000003', 'Test Expired',   'DIASPORA', 'VERIFIED', 'CLEAR',   current_date - 1,   'active'),
    ('00000000-0000-0000-0000-0000000000a4', '+213555000004', 'Test Suspended', 'RESIDENT', 'VERIFIED', 'CLEAR',   current_date + 365, 'suspended'),
    ('00000000-0000-0000-0000-0000000000a5', '+213555000005', 'Test Pending',   'RESIDENT', 'PENDING',  NULL,      NULL,               'active');

-- ---------------------------------------------------------------
-- customer_can_transact
-- ---------------------------------------------------------------
DO $$
BEGIN
    IF NOT public.customer_can_transact('00000000-0000-0000-0000-0000000000a1') THEN
        RAISE EXCEPTION 'FAIL: verified, AML clear, active customer should be allowed';
    END IF;
    IF public.customer_can_transact('00000000-0000-0000-0000-0000000000a2') THEN
        RAISE EXCEPTION 'FAIL: AML-flagged customer must be refused';
    END IF;
    IF public.customer_can_transact('00000000-0000-0000-0000-0000000000a3') THEN
        RAISE EXCEPTION 'FAIL: customer with an expired ID document must be refused';
    END IF;
    IF public.customer_can_transact('00000000-0000-0000-0000-0000000000a4') THEN
        RAISE EXCEPTION 'FAIL: suspended customer must be refused';
    END IF;
    IF public.customer_can_transact('00000000-0000-0000-0000-0000000000a5') THEN
        RAISE EXCEPTION 'FAIL: customer with pending KYC must be refused';
    END IF;
    IF public.customer_can_transact('00000000-0000-0000-0000-00000000ffff') THEN
        RAISE EXCEPTION 'FAIL: unknown customer must be refused';
    END IF;
    RAISE NOTICE 'PASS: customer_can_transact (allowed: verified; refused: flagged, expired, suspended, pending, unknown)';
END $$;

-- ---------------------------------------------------------------
-- updated_at is maintained automatically
-- ---------------------------------------------------------------
DO $$
DECLARE
    before_ts timestamptz;
    after_ts  timestamptz;
BEGIN
    UPDATE public.customers SET updated_at = now() - interval '1 day'
     WHERE id = '00000000-0000-0000-0000-0000000000a1';
    SELECT updated_at INTO before_ts FROM public.customers WHERE id = '00000000-0000-0000-0000-0000000000a1';

    IF before_ts < now() - interval '1 minute' THEN
        RAISE EXCEPTION 'FAIL: updated_at should be overwritten by the trigger';
    END IF;
    RAISE NOTICE 'PASS: updated_at is set automatically on update';
END $$;

-- ---------------------------------------------------------------
-- Things that MUST be rejected
-- ---------------------------------------------------------------
SELECT pg_temp.expect_error('customer without an eKYC id',
    $q$INSERT INTO public.customers (phone) VALUES ('+213555000099')$q$,
    '23502');

SELECT pg_temp.expect_error('KYC status not used by the eKYC service',
    $q$INSERT INTO public.customers (id, kyc_status)
       VALUES ('00000000-0000-0000-0000-0000000000a9', 'verified')$q$,
    '23514');

SELECT pg_temp.expect_error('unknown AML status',
    $q$INSERT INTO public.customers (id, aml_status)
       VALUES ('00000000-0000-0000-0000-0000000000a9', 'MAYBE')$q$,
    '23514');

SELECT pg_temp.expect_error('unknown parcours',
    $q$INSERT INTO public.customers (id, parcours)
       VALUES ('00000000-0000-0000-0000-0000000000a9', 'TOURIST')$q$,
    '23514');

SELECT pg_temp.expect_error('phone not in international format',
    $q$INSERT INTO public.customers (id, phone)
       VALUES ('00000000-0000-0000-0000-0000000000a9', '0555123456')$q$,
    '23514');

SELECT pg_temp.expect_error('two customers with the same phone',
    $q$INSERT INTO public.customers (id, phone)
       VALUES ('00000000-0000-0000-0000-0000000000a9', '+213555000001')$q$,
    '23505');

SELECT pg_temp.expect_error('two customers with the same eKYC id',
    $q$INSERT INTO public.customers (id) VALUES ('00000000-0000-0000-0000-0000000000a1')$q$,
    '23505');

INSERT INTO public.audit_log (actor_type, action) VALUES ('system', 'test.event');

SELECT pg_temp.expect_error('editing the audit log',
    $q$UPDATE public.audit_log SET action = 'tampered'$q$,
    'P0001');

\echo ''
\echo '=== ALL CUSTOMER DATABASE TESTS PASSED ==='

ROLLBACK;
