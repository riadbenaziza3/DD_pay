package dz.ddpay.accountservice.ledger;

import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import dz.ddpay.accountservice.account.AccountService;
import dz.ddpay.accountservice.account.AccountView;

/**
 * The only place where money moves. Every movement is one database transaction:
 * a ledger.transactions row + one debit entry + one credit entry. The database itself
 * refuses unbalanced, overdrawn, frozen-account or duplicate movements; this class
 * translates those refusals into clear API errors.
 */
@Service
public class LedgerService {

    /** Seeded by migration V004. */
    public static final UUID BANK_SETTLEMENT = UUID.fromString("00000000-0000-0000-0000-000000000001");

    private final JdbcClient jdbc;
    private final AccountService accounts;

    public LedgerService(JdbcClient jdbc, AccountService accounts) {
        this.jdbc = jdbc;
        this.accounts = accounts;
    }

    /** Money enters the PSP for a user (dev: by hand; later: card/CIB/Edahabia payment confirmed). */
    @Transactional
    public PostingResult topUp(UUID userId, long amountCentimes, String idempotencyKey, String description) {
        AccountView account = accounts.findByUser(userId)
            .orElseThrow(() -> AccountException.accountNotFound("User " + userId));
        return post("topup:" + idempotencyKey, "deposit", amountCentimes,
            description == null ? "Top-up" : description,
            BANK_SETTLEMENT, account.accountId(), account.accountId());
    }

    /** Customer-to-customer transfer. The key is scoped to the sender, so users can't collide. */
    @Transactional
    public PostingResult transfer(UUID fromUserId, UUID toUserId, long amountCentimes,
                                  String idempotencyKey, String description) {
        if (fromUserId.equals(toUserId)) {
            throw new AccountException("SAME_ACCOUNT", HttpStatus.BAD_REQUEST, "Cannot send money to yourself");
        }
        AccountView from = accounts.findByUser(fromUserId)
            .orElseThrow(() -> AccountException.accountNotFound("You"));
        AccountView to = accounts.findByUser(toUserId)
            .orElseThrow(() -> AccountException.accountNotFound("Recipient"));

        return post("transfer:" + fromUserId + ":" + idempotencyKey, "transfer", amountCentimes,
            description, from.accountId(), to.accountId(), from.accountId());
    }

    @Transactional(readOnly = true)
    public List<TransactionView> history(UUID userId, int limit) {
        AccountView account = accounts.findByUser(userId)
            .orElseThrow(() -> AccountException.accountNotFound("You"));
        return jdbc.sql("""
                SELECT t.id, t.type, e.direction, e.amount, t.description, t.created_at,
                       cp.owner_type AS cp_type, cp.user_id AS cp_user
                  FROM ledger.entries e
                  JOIN ledger.transactions t ON t.id = e.transaction_id
                  LEFT JOIN LATERAL (
                        SELECT a2.owner_type, a2.user_id
                          FROM ledger.entries e2
                          JOIN ledger.accounts a2 ON a2.id = e2.account_id
                         WHERE e2.transaction_id = t.id AND e2.account_id <> e.account_id
                         LIMIT 1) cp ON true
                 WHERE e.account_id = :accountId
                 ORDER BY e.id DESC
                 LIMIT :limit
                """)
            .param("accountId", account.accountId())
            .param("limit", limit)
            .query((rs, n) -> new TransactionView(
                rs.getObject("id", UUID.class),
                rs.getString("type"),
                rs.getString("direction"),
                rs.getLong("amount"),
                rs.getString("cp_type"),
                rs.getObject("cp_user", UUID.class),
                rs.getString("description"),
                rs.getObject("created_at", java.time.OffsetDateTime.class)))
            .list();
    }

    // ------------------------------------------------------------------

    private PostingResult post(String key, String type, long amount, String description,
                               UUID debitAccount, UUID creditAccount, UUID reportBalanceOf) {
        if (amount <= 0) {
            throw new AccountException("INVALID_AMOUNT", HttpStatus.BAD_REQUEST, "Amount must be positive");
        }

        // Lock both accounts in a fixed order (by id). Two opposite transfers at the same time
        // (A->B and B->A) then queue up instead of deadlocking.
        jdbc.sql("SELECT id FROM ledger.accounts WHERE id IN (:a, :b) ORDER BY id FOR UPDATE")
            .param("a", debitAccount)
            .param("b", creditAccount)
            .query(UUID.class)
            .list();

        Optional<UUID> newTx = jdbc.sql("""
                INSERT INTO ledger.transactions (idempotency_key, type, status, amount, description, completed_at)
                VALUES (:key, :type, 'completed', :amount, :description, now())
                ON CONFLICT (idempotency_key) DO NOTHING
                RETURNING id
                """)
            .param("key", key)
            .param("type", type)
            .param("amount", amount)
            .param("description", description)
            .query(UUID.class)
            .optional();

        if (newTx.isEmpty()) {
            return replay(key, type, amount, debitAccount, creditAccount, reportBalanceOf);
        }

        UUID txId = newTx.get();
        try {
            jdbc.sql("""
                    INSERT INTO ledger.entries (transaction_id, account_id, direction, amount) VALUES
                        (:tx, :debit,  'debit',  :amount),
                        (:tx, :credit, 'credit', :amount)
                    """)
                .param("tx", txId)
                .param("debit", debitAccount)
                .param("credit", creditAccount)
                .param("amount", amount)
                .update();
        } catch (DataAccessException e) {
            throw translate(e);
        }

        return new PostingResult(txId, type, "completed", amount, balanceOf(reportBalanceOf), false);
    }

    /** Same key seen before: return the original result, but only if it really is the same request. */
    private PostingResult replay(String key, String type, long amount,
                                 UUID debitAccount, UUID creditAccount, UUID reportBalanceOf) {
        Map<String, Object> existing = jdbc.sql("""
                SELECT t.id, t.type, t.status, t.amount,
                       (SELECT account_id FROM ledger.entries WHERE transaction_id = t.id AND direction = 'debit'  LIMIT 1) AS debit_account,
                       (SELECT account_id FROM ledger.entries WHERE transaction_id = t.id AND direction = 'credit' LIMIT 1) AS credit_account
                  FROM ledger.transactions t
                 WHERE t.idempotency_key = :key
                """)
            .param("key", key)
            .query()
            .singleRow();

        boolean sameRequest = type.equals(existing.get("type"))
            && amount == ((Number) existing.get("amount")).longValue()
            && debitAccount.equals(existing.get("debit_account"))
            && creditAccount.equals(existing.get("credit_account"));

        if (!sameRequest) {
            throw new AccountException("IDEMPOTENCY_KEY_REUSED", HttpStatus.CONFLICT,
                "This Idempotency-Key was already used for a different operation");
        }
        return new PostingResult((UUID) existing.get("id"), type, (String) existing.get("status"),
            amount, balanceOf(reportBalanceOf), true);
    }

    private long balanceOf(UUID accountId) {
        return jdbc.sql("SELECT balance_centimes FROM ledger.account_balances WHERE account_id = :id")
            .param("id", accountId)
            .query(Long.class)
            .single();
    }

    /** The database refused the movement: turn its coded message into an API error. */
    private static RuntimeException translate(DataAccessException e) {
        String msg = String.valueOf(e.getMostSpecificCause().getMessage());
        if (msg.contains("INSUFFICIENT_FUNDS")) {
            return new AccountException("INSUFFICIENT_FUNDS", HttpStatus.UNPROCESSABLE_ENTITY,
                "Not enough money in the account");
        }
        if (msg.contains("ACCOUNT_NOT_ACTIVE")) {
            return new AccountException("ACCOUNT_FROZEN", HttpStatus.UNPROCESSABLE_ENTITY,
                "This account is frozen and cannot send money");
        }
        if (msg.contains("ACCOUNT_CLOSED")) {
            return new AccountException("ACCOUNT_CLOSED", HttpStatus.UNPROCESSABLE_ENTITY,
                "An account involved in this operation is closed");
        }
        return e;
    }
}
