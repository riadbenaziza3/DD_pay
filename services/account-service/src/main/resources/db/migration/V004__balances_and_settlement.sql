-- V004__balances_and_settlement.sql  (wallet-service)
--
-- 1. No overdraft: a debit is refused if the account doesn't have enough money
--    (except accounts explicitly allowed to go negative, like the bank settlement account).
-- 2. One wallet per user.
-- 3. The bank settlement account: the counterpart of every top-up and withdrawal.
--
-- Error messages start with a code (INSUFFICIENT_FUNDS, ACCOUNT_NOT_ACTIVE, ACCOUNT_CLOSED)
-- so the Java code can turn them into clear API errors.

CREATE OR REPLACE FUNCTION ledger.check_account_status() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    acc record;
    bal bigint;
BEGIN
    -- Debits lock the account exclusively: two payments from the same wallet at the same
    -- moment are handled one after the other, so both can't spend the same money.
    IF NEW.direction = 'debit' THEN
        SELECT status, allow_negative INTO acc
          FROM ledger.accounts WHERE id = NEW.account_id FOR UPDATE;
    ELSE
        SELECT status, allow_negative INTO acc
          FROM ledger.accounts WHERE id = NEW.account_id FOR SHARE;
    END IF;

    IF NOT FOUND THEN
        RETURN NEW;  -- unknown account: the foreign key on entries rejects it
    END IF;

    IF acc.status = 'closed' THEN
        RAISE EXCEPTION 'ACCOUNT_CLOSED: account % is closed', NEW.account_id;
    END IF;

    IF NEW.direction = 'debit' AND acc.status <> 'active' THEN
        RAISE EXCEPTION 'ACCOUNT_NOT_ACTIVE: account % is % and cannot be debited',
                        NEW.account_id, acc.status;
    END IF;

    IF NEW.direction = 'debit' AND NOT acc.allow_negative THEN
        SELECT COALESCE(SUM(CASE WHEN direction = 'credit' THEN amount ELSE -amount END), 0)
          INTO bal
          FROM ledger.entries
         WHERE account_id = NEW.account_id;

        IF bal < NEW.amount THEN
            RAISE EXCEPTION 'INSUFFICIENT_FUNDS: account % has % centimes, needs %',
                            NEW.account_id, bal, NEW.amount;
        END IF;
    END IF;

    RETURN NEW;
END $$;

-- One wallet per user (merchant and system accounts are not concerned).
CREATE UNIQUE INDEX accounts_one_wallet_per_user
    ON ledger.accounts (user_id)
    WHERE owner_type = 'user';

-- Bank settlement account: money entering (top-ups) or leaving (withdrawals) the PSP.
-- Allowed to go negative: its balance mirrors what the PSP holds at its partner bank.
INSERT INTO ledger.accounts (id, owner_type, name, allow_negative)
VALUES ('00000000-0000-0000-0000-000000000001', 'system', 'Bank settlement', true);
