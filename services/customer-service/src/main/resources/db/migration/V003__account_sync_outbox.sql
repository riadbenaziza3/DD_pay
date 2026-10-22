-- V003__account_sync_outbox.sql  (customer-service)
--
-- Keeps each customer's account in account-service in line with what customer-service decides:
--   may transact      -> account open and active
--   may not transact  -> account frozen (if it exists)
--
-- How it works (the "outbox" pattern):
--   1. When a customer's KYC data changes, an 'account.sync' row is written to public.outbox
--      IN THE SAME TRANSACTION as the change. Both are saved, or neither.
--   2. A background job reads due rows, calls account-service, and marks them processed.
--      If account-service is down, the row stays and is retried with a growing delay.
--   3. Each sync applies the customer's CURRENT state, not the state when the row was written,
--      so rows can be processed late, twice, or out of order and the result is still correct.
--   4. A periodic job (enqueue_account_sync_drift) catches anything else, e.g. an ID document
--      that expires today, which produces no event at all.

-- ---------------------------------------------------------------
-- What customer-service last successfully told account-service
-- ---------------------------------------------------------------
ALTER TABLE public.customers
    ADD COLUMN account_state_synced text NOT NULL DEFAULT 'none'
        CHECK (account_state_synced IN ('none', 'active', 'frozen', 'closed')),
    ADD COLUMN account_synced_at timestamptz;

COMMENT ON COLUMN public.customers.account_state_synced IS
    'Account state last confirmed by account-service: none (no account), active, frozen, closed.';

-- ---------------------------------------------------------------
-- Outbox
-- ---------------------------------------------------------------
CREATE TABLE public.outbox (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    type             text NOT NULL CHECK (type IN ('account.sync')),
    aggregate_id     uuid NOT NULL,                      -- the customer concerned
    payload          jsonb NOT NULL DEFAULT '{}',        -- why it was written (for debugging)
    created_at       timestamptz NOT NULL DEFAULT now(),
    attempts         integer NOT NULL DEFAULT 0,
    next_attempt_at  timestamptz NOT NULL DEFAULT now(),
    locked_until     timestamptz,                        -- a worker is processing it until then
    last_error       text,
    processed_at     timestamptz                         -- NULL = still to do
);

CREATE INDEX outbox_due_idx ON public.outbox (next_attempt_at, id) WHERE processed_at IS NULL;
CREATE INDEX outbox_aggregate_idx ON public.outbox (aggregate_id) WHERE processed_at IS NULL;

-- ---------------------------------------------------------------
-- The account state a customer SHOULD have right now
-- ---------------------------------------------------------------
CREATE FUNCTION public.desired_account_state(p_customer_id uuid) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT CASE
             WHEN c.account_state_synced = 'closed'        THEN 'closed'  -- final, never reopened
             WHEN public.customer_can_transact(c.id)       THEN 'active'
             WHEN c.account_state_synced = 'none'          THEN 'none'    -- no account, don't open one
             ELSE 'frozen'
           END
      FROM public.customers c
     WHERE c.id = p_customer_id;
$$;

-- ---------------------------------------------------------------
-- Safety net: queue a sync for every customer whose account is not in the desired state
-- and has no sync already waiting. Returns how many were queued.
-- ---------------------------------------------------------------
CREATE FUNCTION public.enqueue_account_sync_drift() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    n integer;
BEGIN
    INSERT INTO public.outbox (type, aggregate_id, payload)
    SELECT 'account.sync', c.id, jsonb_build_object('trigger', 'reconcile')
      FROM public.customers c
     WHERE public.desired_account_state(c.id) <> c.account_state_synced
       AND NOT EXISTS (SELECT 1 FROM public.outbox o
                        WHERE o.aggregate_id = c.id AND o.processed_at IS NULL);
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END $$;
