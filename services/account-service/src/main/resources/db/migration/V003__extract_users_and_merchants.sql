-- V003__extract_users_and_merchants.sql  (wallet-service)
--
-- The wallet keeps only money: accounts, transactions, ledger entries, balances.
--   * users     -> move to customer-service (linked to the eKYC)
--   * merchants -> move to merchant-service (its SQL stays in V002 / Git history)
-- accounts.user_id and accounts.merchant_id remain, as plain IDs owned by those services.
--
-- New rule: an account's status is enforced on every ledger entry, in the same
-- transaction as the money movement. customer-service freezes accounts when a user
-- is blocked, AML-flagged or their ID expires; the wallet then refuses debits.

-- ---------------------------------------------------------------
-- 1. Remove cross-service foreign keys
-- ---------------------------------------------------------------
ALTER TABLE ledger.accounts DROP CONSTRAINT accounts_user_id_fkey;
ALTER TABLE ledger.accounts DROP CONSTRAINT accounts_merchant_id_fkey;

COMMENT ON COLUMN ledger.accounts.user_id IS
    'User ID owned by customer-service (same UUID as the eKYC users.id). No foreign key: different database.';
COMMENT ON COLUMN ledger.accounts.merchant_id IS
    'Merchant ID owned by merchant-service. No foreign key: different database.';

-- ---------------------------------------------------------------
-- 2. Drop tables that now belong to other services
--    (their triggers are dropped with them)
-- ---------------------------------------------------------------
DROP TABLE public.merchants;
DROP TABLE public.users;
DROP FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------
-- 3. Account status enforcement
--    active : can send and receive
--    frozen : can receive, cannot send (e.g. KYC expired, AML review)
--    closed : can neither send nor receive
-- ---------------------------------------------------------------
CREATE FUNCTION ledger.check_account_status() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    acc_status text;
BEGIN
    -- FOR SHARE: if customer-service freezes this account at the same moment,
    -- one of the two waits for the other, so a debit can't slip through mid-freeze.
    SELECT status INTO acc_status
      FROM ledger.accounts
     WHERE id = NEW.account_id
       FOR SHARE;

    IF acc_status IS NULL THEN
        RETURN NEW;  -- unknown account: the foreign key on entries rejects it
    END IF;

    IF NEW.direction = 'debit' AND acc_status <> 'active' THEN
        RAISE EXCEPTION 'Account % is % and cannot be debited', NEW.account_id, acc_status;
    END IF;

    IF acc_status = 'closed' THEN
        RAISE EXCEPTION 'Account % is closed and cannot receive funds', NEW.account_id;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER entries_check_account_status
    BEFORE INSERT ON ledger.entries
    FOR EACH ROW EXECUTE FUNCTION ledger.check_account_status();
