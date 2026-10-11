CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS ledger;

-- App user with limited rights (your app should never connect as the admin)
CREATE ROLE psp_app LOGIN PASSWORD 'DD_pay_2026';
GRANT USAGE ON SCHEMA ledger TO psp_app;