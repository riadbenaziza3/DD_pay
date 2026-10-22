package dz.ddpay.customerservice.accountsync;

import java.time.LocalDate;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Propagation;
import org.springframework.transaction.annotation.Transactional;

import dz.ddpay.customerservice.audit.AuditLog;

/** All database work of the account sync: the outbox table and the customer's synced state. */
@Component
public class AccountSyncStore {

    /** How long a worker may hold a row before another worker is allowed to take it over. */
    private static final int LEASE_SECONDS = 60;
    /** Retry delays grow 1s, 2s, 4s ... up to this cap. */
    private static final int MAX_RETRY_DELAY_SECONDS = 60;

    public record Claimed(long id, UUID customerId, int attempts) {}

    /** What the sync needs to know about a customer, read at the moment of syncing. */
    public record CustomerState(UUID id, String kycStatus, String amlStatus, LocalDate validUntil,
                                String status, boolean canTransact, String accountStateSynced) {

        /** Human-readable reason for freezing, stored in account-service's audit log. */
        public String freezeReason() {
            if (!"active".equals(status)) return "customer " + status;
            if (!"VERIFIED".equals(kycStatus)) return "KYC " + kycStatus;
            if (!"CLEAR".equals(amlStatus)) return "AML " + (amlStatus == null ? "not checked" : amlStatus);
            if (validUntil != null && validUntil.isBefore(LocalDate.now(java.time.ZoneOffset.UTC))) {
                return "ID document expired on " + validUntil;
            }
            return "customer may not transact";
        }
    }

    private final JdbcClient jdbc;
    private final AuditLog audit;

    public AccountSyncStore(JdbcClient jdbc, AuditLog audit) {
        this.jdbc = jdbc;
        this.audit = audit;
    }

    /** Queues a sync. MANDATORY: must run inside the caller's transaction (e.g. the KYC update). */
    @Transactional(propagation = Propagation.MANDATORY)
    public void enqueue(UUID customerId, String trigger) {
        jdbc.sql("""
                INSERT INTO public.outbox (type, aggregate_id, payload)
                VALUES ('account.sync', :customerId, jsonb_build_object('trigger', CAST(:trigger AS text)))
                """)
            .param("customerId", customerId)
            .param("trigger", trigger)
            .update();
    }

    /**
     * Takes up to `limit` due rows and leases them to this worker.
     * SKIP LOCKED: if several instances of customer-service run, they never take the same row.
     */
    @Transactional
    public List<Claimed> claimDue(int limit) {
        return jdbc.sql("""
                UPDATE public.outbox o
                   SET locked_until = now() + make_interval(secs => :lease),
                       attempts = o.attempts + 1
                 WHERE o.id IN (SELECT id FROM public.outbox
                                 WHERE processed_at IS NULL
                                   AND next_attempt_at <= now()
                                   AND (locked_until IS NULL OR locked_until < now())
                                 ORDER BY id
                                 LIMIT :limit
                                 FOR UPDATE SKIP LOCKED)
                RETURNING o.id, o.aggregate_id, o.attempts
                """)
            .param("lease", LEASE_SECONDS)
            .param("limit", limit)
            .query((rs, n) -> new Claimed(rs.getLong("id"), rs.getObject("aggregate_id", UUID.class),
                rs.getInt("attempts")))
            .list()
            .stream()
            .sorted(Comparator.comparingLong(Claimed::id))
            .toList();
    }

    @Transactional(readOnly = true)
    public Optional<CustomerState> loadCustomer(UUID customerId) {
        return jdbc.sql("""
                SELECT id, kyc_status, aml_status, kyc_valid_until, status, account_state_synced,
                       public.customer_can_transact(id) AS can_transact
                  FROM public.customers
                 WHERE id = :id
                """)
            .param("id", customerId)
            .query((rs, n) -> new CustomerState(
                rs.getObject("id", UUID.class),
                rs.getString("kyc_status"),
                rs.getString("aml_status"),
                rs.getObject("kyc_valid_until", LocalDate.class),
                rs.getString("status"),
                rs.getBoolean("can_transact"),
                rs.getString("account_state_synced")))
            .optional();
    }

    /** Success: row done, customer's synced state updated, audit line if the state changed. */
    @Transactional
    public void markDone(Claimed row, String newState, String reason) {
        jdbc.sql("""
                UPDATE public.outbox
                   SET processed_at = now(), locked_until = NULL, last_error = NULL
                 WHERE id = :id
                """)
            .param("id", row.id())
            .update();

        String previous = jdbc.sql("""
                SELECT account_state_synced FROM public.customers WHERE id = :id FOR UPDATE
                """)
            .param("id", row.customerId())
            .query(String.class)
            .optional()
            .orElse(null);

        if (previous == null) {
            return;  // customer no longer exists; nothing to record
        }

        jdbc.sql("""
                UPDATE public.customers
                   SET account_state_synced = :state, account_synced_at = now()
                 WHERE id = :id
                """)
            .param("state", newState)
            .param("id", row.customerId())
            .update();

        if (!newState.equals(previous)) {
            Map<String, Object> details = new LinkedHashMap<>();
            details.put("from", previous);
            details.put("to", newState);
            details.put("reason", reason);
            details.put("outboxId", row.id());
            audit.record("system", null, "customer.account_" + newState, "customer", row.customerId(), details);
        }
    }

    /** Temporary failure (account-service down, timeout...): try again later, waiting longer each time. */
    @Transactional
    public void markRetry(Claimed row, String error) {
        int delay = (int) Math.min(MAX_RETRY_DELAY_SECONDS, Math.pow(2, Math.max(0, row.attempts() - 1)));
        jdbc.sql("""
                UPDATE public.outbox
                   SET locked_until = NULL,
                       next_attempt_at = now() + make_interval(secs => :delay),
                       last_error = :error
                 WHERE id = :id
                """)
            .param("delay", delay)
            .param("error", truncate(error))
            .param("id", row.id())
            .update();
    }

    /** Permanent failure (the request itself is refused): stop retrying, keep the error visible. */
    @Transactional
    public void markFailed(Claimed row, String error) {
        jdbc.sql("""
                UPDATE public.outbox
                   SET processed_at = now(), locked_until = NULL, last_error = :error
                 WHERE id = :id
                """)
            .param("error", truncate("PERMANENT: " + error))
            .param("id", row.id())
            .update();
    }

    /** Safety net: queues a sync for every customer whose account isn't in the desired state. */
    @Transactional
    public int enqueueDrift() {
        return jdbc.sql("SELECT public.enqueue_account_sync_drift()")
            .query(Integer.class)
            .single();
    }

    private static String truncate(String s) {
        if (s == null) return null;
        return s.length() <= 1000 ? s : s.substring(0, 1000);
    }
}
