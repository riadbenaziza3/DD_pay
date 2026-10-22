package dz.ddpay.accountservice.account;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import dz.ddpay.accountservice.audit.AuditLog;
import dz.ddpay.accountservice.ledger.AccountException;

@Service
public class AccountService {

    private final JdbcClient jdbc;
    private final AuditLog audit;

    public AccountService(JdbcClient jdbc, AuditLog audit) {
        this.jdbc = jdbc;
        this.audit = audit;
    }

    public record OpenResult(AccountView account, boolean created) {}

    /** Opens the user's account. Calling it again returns the existing account (safe to retry). */
    @Transactional
    public OpenResult openForUser(UUID userId, String requestedBy) {
        int inserted = jdbc.sql("""
                INSERT INTO ledger.accounts (owner_type, user_id, name)
                VALUES ('user', :userId, 'Main account')
                ON CONFLICT (user_id) WHERE owner_type = 'user' DO NOTHING
                """)
            .param("userId", userId)
            .update();

        AccountView account = findByUser(userId).orElseThrow();
        if (inserted == 1) {
            audit.record("system", null, "account.opened", "account", account.accountId(),
                Map.of("userId", userId.toString(), "requestedBy", String.valueOf(requestedBy)));
        }
        return new OpenResult(account, inserted == 1);
    }

    @Transactional(readOnly = true)
    public Optional<AccountView> findByUser(UUID userId) {
        return jdbc.sql("""
                SELECT a.id, a.user_id, a.status, a.currency, b.balance_centimes
                  FROM ledger.accounts a
                  JOIN ledger.account_balances b ON b.account_id = a.id
                 WHERE a.owner_type = 'user' AND a.user_id = :userId
                """)
            .param("userId", userId)
            .query((rs, n) -> new AccountView(
                rs.getObject("id", UUID.class),
                rs.getObject("user_id", UUID.class),
                rs.getString("status"),
                rs.getString("currency"),
                rs.getLong("balance_centimes")))
            .optional();
    }

    /**
     * active <-> frozen, or -> closed (final). Used by customer-service when KYC/AML changes.
     * A closed account can never be reopened.
     */
    @Transactional
    public AccountView setStatus(UUID userId, String newStatus, String reason, String requestedBy) {
        AccountView current = findByUser(userId)
            .orElseThrow(() -> AccountException.accountNotFound("User " + userId));

        if ("closed".equals(current.status())) {
            throw new AccountException("ACCOUNT_CLOSED", HttpStatus.CONFLICT,
                "Account is closed and cannot change status");
        }
        if (current.status().equals(newStatus)) {
            return current;  // nothing to do, safe to retry
        }
        if ("closed".equals(newStatus) && current.balanceCentimes() != 0) {
            throw new AccountException("BALANCE_NOT_ZERO", HttpStatus.CONFLICT,
                "Account still holds " + current.balanceCentimes() + " centimes; pay it out before closing");
        }

        // Locks the row: a payment in progress on this account finishes before the freeze applies.
        jdbc.sql("UPDATE ledger.accounts SET status = :status WHERE id = :id")
            .param("status", newStatus)
            .param("id", current.accountId())
            .update();

        Map<String, Object> details = new LinkedHashMap<>();
        details.put("userId", userId.toString());
        details.put("from", current.status());
        details.put("to", newStatus);
        details.put("reason", reason);
        details.put("requestedBy", requestedBy);
        audit.record("system", null, "account.status_changed", "account", current.accountId(), details);

        return findByUser(userId).orElseThrow();
    }
}
