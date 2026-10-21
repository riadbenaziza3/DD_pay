-- services/customer-service/db-tests/processed_events_tests.sql
-- Checks the event de-duplication table (V002).
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

INSERT INTO public.processed_events (event_id, event_type, subject_id, occurred_at)
VALUES ('00000000-0000-0000-0000-0000000000e1', 'kyc.status_changed',
        '00000000-0000-0000-0000-0000000000a1', now());

DO $$
DECLARE
    n int;
BEGIN
    -- The pattern the Java code uses: insert, and do nothing if already there.
    INSERT INTO public.processed_events (event_id, event_type, subject_id, occurred_at)
    VALUES ('00000000-0000-0000-0000-0000000000e1', 'kyc.status_changed',
            '00000000-0000-0000-0000-0000000000a1', now())
    ON CONFLICT (event_id) DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;

    IF n <> 0 THEN
        RAISE EXCEPTION 'FAIL: a duplicate event should insert 0 rows, inserted %', n;
    END IF;
    RAISE NOTICE 'PASS: duplicate event detected (0 rows inserted)';
END $$;

SELECT pg_temp.expect_error('event without an eventId',
    $q$INSERT INTO public.processed_events (event_type, occurred_at) VALUES ('kyc.status_changed', now())$q$,
    '23502');

SELECT pg_temp.expect_error('unknown processing result',
    $q$INSERT INTO public.processed_events (event_id, event_type, occurred_at, result)
       VALUES ('00000000-0000-0000-0000-0000000000e2', 'kyc.status_changed', now(), 'maybe')$q$,
    '23514');

\echo ''
\echo '=== ALL PROCESSED-EVENTS TESTS PASSED ==='

ROLLBACK;
