-- V001__core_schema.sql
-- Core PSP schema: users, accounts, transactions, double-entry ledger.
-- Money is stored as BIGINT in centimes (1 DZD = 100 centimes). Never use float.
-- Balance convention: balance = credits - debits (a credit increases a wallet).

CREATE SCHEMA IF NOT EXISTS ledger;

-- ---------------------------------------------------------------
-- Users (linked to your eKYC provider)
-- ---------------------------------------------------------------
CREATE TABLE public.users (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),   -- uuidv7() is built into PostgreSQL 18
    phone           text NOT NULL UNIQUE,
    email           text UNIQUE,
    full_name       text NOT NULL,
    kyc_status      text NOT NULL DEFAULT 'pending'
                    CHECK (kyc_status IN ('pending', 'verified', 'rejected', 'expired')),
    kyc_reference   text,                                -- ID returned by your eKYC provider
    kyc_verified_at timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------
-- Accounts (wallets). One user can have several.
-- 'system' accounts hold the PSP's own money: fees, bank settlement, etc.
-- ---------------------------------------------------------------
CREATE TABLE ledger.accounts (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    owner_type      text NOT NULL CHECK (owner_type IN ('user', 'merchant', 'system')),
    user_id         uuid REFERENCES public.users(id),
    name            text NOT NULL,
    currency        char(3) NOT NULL DEFAULT 'DZD' CHECK (currency = 'DZD'),
    allow_negative  boolean NOT NULL DEFAULT false,      -- true only for system accounts
    status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('active', 'frozen', 'closed')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (owner_type <> 'user' OR user_id IS NOT NULL)
);

CREATE INDEX accounts_user_id_idx ON ledger.accounts (user_id);

-- ---------------------------------------------------------------
-- Transactions: one row per business operation (payment, transfer, refund...)
-- ---------------------------------------------------------------
CREATE TABLE ledger.transactions (
    id               uuid PRIMARY KEY DEFAULT uuidv7(),
    idempotency_key  text NOT NULL UNIQUE,               -- blocks double-charging on retries
    type             text NOT NULL CHECK (type IN
                     ('deposit', 'withdrawal', 'transfer', 'payment', 'refund', 'fee', 'reversal')),
    status           text NOT NULL DEFAULT 'pending'
                     CHECK (status IN ('pending', 'completed', 'failed', 'reversed')),
    amount           bigint NOT NULL CHECK (amount > 0),
    currency         char(3) NOT NULL DEFAULT 'DZD',
    reverses_id      uuid REFERENCES ledger.transactions(id),
    description      text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    completed_at     timestamptz
);

-- ---------------------------------------------------------------
-- Ledger entries: the debit/credit lines. Append-only.
-- ---------------------------------------------------------------
CREATE TABLE ledger.entries (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id  uuid NOT NULL REFERENCES ledger.transactions(id),
    account_id      uuid NOT NULL REFERENCES ledger.accounts(id),
    direction       text NOT NULL CHECK (direction IN ('debit', 'credit')),
    amount          bigint NOT NULL CHECK (amount > 0),
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX entries_account_idx     ON ledger.entries (account_id, created_at);
CREATE INDEX entries_transaction_idx ON ledger.entries (transaction_id);

-- Every transaction must balance (total debits = total credits).
-- Checked at COMMIT, so you insert all lines of a transaction first.
CREATE FUNCTION ledger.check_transaction_balanced() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    diff bigint;
BEGIN
    SELECT COALESCE(SUM(CASE WHEN direction = 'debit' THEN amount ELSE -amount END), 0)
      INTO diff
      FROM ledger.entries
     WHERE transaction_id = NEW.transaction_id;

    IF diff <> 0 THEN
        RAISE EXCEPTION 'Transaction % is unbalanced (debits - credits = %)',
                        NEW.transaction_id, diff;
    END IF;
    RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER entries_balanced
    AFTER INSERT ON ledger.entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ledger.check_transaction_balanced();

-- Entries can never be changed or removed: corrections are reversal transactions.
CREATE FUNCTION ledger.forbid_modification() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'ledger.entries is append-only; post a reversal instead';
END $$;

CREATE TRIGGER entries_no_update_delete
    BEFORE UPDATE OR DELETE ON ledger.entries
    FOR EACH ROW EXECUTE FUNCTION ledger.forbid_modification();

CREATE TRIGGER entries_no_truncate
    BEFORE TRUNCATE ON ledger.entries
    FOR EACH STATEMENT EXECUTE FUNCTION ledger.forbid_modification();

-- ---------------------------------------------------------------
-- Balances are derived from entries, never stored as an editable number.
-- ---------------------------------------------------------------
CREATE VIEW ledger.account_balances AS
SELECT a.id AS account_id,
       a.name,
       COALESCE(SUM(CASE WHEN e.direction = 'credit' THEN e.amount ELSE -e.amount END), 0)
           AS balance_centimes
  FROM ledger.accounts a
  LEFT JOIN ledger.entries e ON e.account_id = a.id
 GROUP BY a.id, a.name;

-- ---------------------------------------------------------------
-- Permissions for the application role (skipped where it doesn't exist, e.g. in CI)
-- ---------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'psp_app') THEN
        GRANT USAGE ON SCHEMA ledger TO psp_app;
        GRANT SELECT, INSERT, UPDATE ON public.users         TO psp_app;
        GRANT SELECT, INSERT, UPDATE ON ledger.accounts      TO psp_app;
        GRANT SELECT, INSERT, UPDATE ON ledger.transactions  TO psp_app;
        GRANT SELECT, INSERT         ON ledger.entries       TO psp_app;  -- no UPDATE/DELETE
        GRANT SELECT ON ledger.account_balances              TO psp_app;
    END IF;
END $$;