-- V002__merchants_and_audit.sql
-- Merchants (businesses receiving payments), audit log, updated_at automation.

-- ---------------------------------------------------------------
-- Keep updated_at correct automatically
-- ---------------------------------------------------------------
CREATE FUNCTION public.set_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON public.users
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------
-- Merchants
-- ---------------------------------------------------------------
CREATE TABLE public.merchants (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    owner_user_id   uuid NOT NULL REFERENCES public.users(id),
    legal_name      text NOT NULL,
    trade_name      text,
    nif             text UNIQUE,      -- Numéro d'Identification Fiscale
    rc_number       text UNIQUE,      -- Registre de Commerce
    settlement_rib  text CHECK (settlement_rib ~ '^[0-9]{20}$'),  -- Algerian RIB: 20 digits
    kyb_status      text NOT NULL DEFAULT 'pending'
                    CHECK (kyb_status IN ('pending', 'verified', 'rejected')),
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'active', 'suspended', 'closed')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX merchants_owner_idx ON public.merchants (owner_user_id);

CREATE TRIGGER merchants_set_updated_at
    BEFORE UPDATE ON public.merchants
    FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Merchant accounts must point to a merchant
ALTER TABLE ledger.accounts
    ADD COLUMN merchant_id uuid REFERENCES public.merchants(id),
    ADD CONSTRAINT accounts_merchant_owner_chk
        CHECK (owner_type <> 'merchant' OR merchant_id IS NOT NULL);

CREATE INDEX accounts_merchant_id_idx ON ledger.accounts (merchant_id);

-- ---------------------------------------------------------------
-- Audit log: who did what, when. Append-only.
-- ---------------------------------------------------------------
CREATE TABLE public.audit_log (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_type   text NOT NULL CHECK (actor_type IN ('user', 'merchant', 'admin', 'system')),
    actor_id     uuid,
    action       text NOT NULL,          -- e.g. 'user.kyc_verified', 'account.frozen'
    entity_type  text,
    entity_id    uuid,
    details      jsonb NOT NULL DEFAULT '{}',
    ip_address   inet,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX audit_entity_idx ON public.audit_log (entity_type, entity_id);
CREATE INDEX audit_actor_idx  ON public.audit_log (actor_id, created_at);

CREATE FUNCTION public.forbid_modification() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END $$;

CREATE TRIGGER audit_no_update_delete
    BEFORE UPDATE OR DELETE ON public.audit_log
    FOR EACH ROW EXECUTE FUNCTION public.forbid_modification();

CREATE TRIGGER audit_no_truncate
    BEFORE TRUNCATE ON public.audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION public.forbid_modification();

-- ---------------------------------------------------------------
-- Permissions for the application role (skipped where it doesn't exist, e.g. in CI)
-- ---------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'psp_app') THEN
        GRANT SELECT, INSERT, UPDATE ON public.merchants TO psp_app;
        GRANT SELECT, INSERT         ON public.audit_log TO psp_app;  -- no UPDATE/DELETE
    END IF;
END $$;