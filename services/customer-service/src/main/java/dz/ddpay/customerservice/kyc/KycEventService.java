package dz.ddpay.customerservice.kyc;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Optional;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import dz.ddpay.customerservice.audit.AuditLog;
import dz.ddpay.customerservice.customer.Customer;
import dz.ddpay.customerservice.customer.CustomerRepository;
import dz.ddpay.customerservice.customer.CustomerService;

/**
 * Applies "kyc.status_changed" events from the eKYC to the customer's synced copy.
 *
 * Safe against the three classic messaging problems:
 *   - duplicates   : each eventId is processed once (processed_events table)
 *   - out of order : an event older than the last one applied is ignored ("stale")
 *   - concurrency  : the customer row is locked while the event is applied
 */
@Service
public class KycEventService {

    private static final Logger log = LoggerFactory.getLogger(KycEventService.class);

    public enum Result { APPLIED, DUPLICATE, STALE }

    public record Outcome(Result result, boolean canTransact) {}

    private final CustomerRepository customers;
    private final CustomerService customerService;
    private final JdbcClient jdbc;
    private final AuditLog audit;

    public KycEventService(CustomerRepository customers, CustomerService customerService,
                           JdbcClient jdbc, AuditLog audit) {
        this.customers = customers;
        this.customerService = customerService;
        this.jdbc = jdbc;
        this.audit = audit;
    }

    @Transactional
    public Outcome apply(KycStatusChangedEvent event) {
        // 1. Duplicate? Insert the eventId first; 0 rows inserted means we already had it.
        int inserted = jdbc.sql("""
                INSERT INTO public.processed_events (event_id, event_type, subject_id, occurred_at)
                VALUES (:eventId, :type, :subjectId, :occurredAt)
                ON CONFLICT (event_id) DO NOTHING
                """)
            .param("eventId", event.eventId())
            .param("type", event.type())
            .param("subjectId", event.userId())
            .param("occurredAt", utc(event.occurredAt()))
            .update();

        if (inserted == 0) {
            log.info("KYC event {} already processed, ignored", event.eventId());
            return new Outcome(Result.DUPLICATE, customerService.canTransact(event.userId()));
        }

        // 2. Load (and lock) the customer, or create them if the eKYC knows them before we do.
        Customer customer = customers.findByIdForUpdate(event.userId())
            .orElseGet(() -> Customer.fromKyc(event.userId()));

        OffsetDateTime occurredAt = utc(event.occurredAt());

        // 3. Out of order? Keep the newer information we already have.
        if (customer.getKycSyncedAt() != null && !occurredAt.isAfter(customer.getKycSyncedAt())) {
            jdbc.sql("UPDATE public.processed_events SET result = 'stale' WHERE event_id = :id")
                .param("id", event.eventId())
                .update();
            log.info("KYC event {} is older than the last applied one, ignored", event.eventId());
            return new Outcome(Result.STALE, customerService.canTransact(event.userId()));
        }

        // 4. Apply.
        KycStatusChangedEvent.Data d = event.data();
        Optional<String> phone = PhoneNumbers.normalize(d.phone());
        if (d.phone() != null && phone.isEmpty()) {
            log.warn("KYC event {}: phone '{}' is not a valid number, kept the previous one",
                event.eventId(), d.phone());
        }

        Map<String, Object> details = new LinkedHashMap<>();
        details.put("eventId", event.eventId().toString());
        details.put("kycStatusBefore", customer.isNew() ? null : customer.getKycStatus());
        details.put("kycStatusAfter", d.kycStatus());
        details.put("amlStatusBefore", customer.isNew() ? null : customer.getAmlStatus());
        details.put("amlStatusAfter", d.amlStatus());
        details.put("validUntil", d.validUntil() == null ? null : d.validUntil().toString());

        customer.applyKyc(d.kycStatus(), d.amlStatus(), d.parcours(), d.customerNumber(),
            phone.orElse(null), d.displayName(),
            d.kycVerifiedAt() == null ? null : utc(d.kycVerifiedAt()),
            d.validUntil(), occurredAt);
        customers.saveAndFlush(customer);

        audit.record("system", null, "customer.kyc_synced", "customer", customer.getId(), details);

        boolean canTransact = customerService.canTransact(customer.getId());
        log.info("KYC event {} applied: customer {} is {} / AML {} -> canTransact={}",
            event.eventId(), customer.getId(), d.kycStatus(), d.amlStatus(), canTransact);

        // Step 4 of the plan: here we will also tell account-service to open or freeze the customer's account.
        return new Outcome(Result.APPLIED, canTransact);
    }

    private static OffsetDateTime utc(java.time.Instant instant) {
        return instant.atOffset(ZoneOffset.UTC);
    }
}
