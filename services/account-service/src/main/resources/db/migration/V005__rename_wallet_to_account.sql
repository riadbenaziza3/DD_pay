-- V005__rename_wallet_to_account.sql  (account-service)
--
-- The PSP does not use the term "wallet". Applied migrations (V001-V004) are never edited,
-- since Flyway checks their checksums, so the remaining database names are fixed here:
--   * the one-account-per-user index created by V004
--   * customer accounts created before the rename, named 'Main wallet'
-- (V001-V004 still say "wallet" in their comments; that text is not stored in the database.)

ALTER INDEX ledger.accounts_one_wallet_per_user RENAME TO accounts_one_account_per_user;

UPDATE ledger.accounts
   SET name = 'Main account'
 WHERE owner_type = 'user'
   AND name = 'Main wallet';
