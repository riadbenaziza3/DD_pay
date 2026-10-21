package dz.ddpay.customerservice.customer;

import java.util.Map;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import dz.ddpay.customerservice.audit.AuditLog;

@Service
public class CustomerService {

    private final CustomerRepository customers;
    private final JdbcClient jdbc;
    private final AuditLog audit;

    public CustomerService(CustomerRepository customers, JdbcClient jdbc, AuditLog audit) {
        this.customers = customers;
        this.jdbc = jdbc;
        this.audit = audit;
    }

    public record OnboardingResult(CustomerView customer, boolean created) {}

    /**
     * Called when a logged-in user starts using DD Pay.
     * Creates the customer as PENDING if they don't exist yet; calling it again changes nothing.
     */
    @Transactional
    public OnboardingResult startOnboarding(Jwt jwt) {
        UUID id = customerIdOf(jwt);

        Optional<Customer> existing = customers.findById(id);
        if (existing.isPresent()) {
            Customer c = existing.get();
            if (c.getKeycloakSubject() == null) {
                // Known from the eKYC (e.g. verified in the bank app) but first time in DD Pay.
                c.setKeycloakSubject(jwt.getSubject());
                customers.saveAndFlush(c);
                audit.record("customer", id, "customer.joined_psp", "customer", id, Map.of());
            }
            return new OnboardingResult(CustomerView.of(c, canTransact(id)), false);
        }

        Customer created = customers.saveAndFlush(
            Customer.startOnboarding(id, jwt.getSubject(), jwt.getClaimAsString("name")));
        audit.record("customer", id, "customer.onboarding_started", "customer", id, Map.of());
        return new OnboardingResult(CustomerView.of(created, canTransact(id)), true);
    }

    @Transactional(readOnly = true)
    public Optional<CustomerView> findMe(Jwt jwt) {
        UUID id = customerIdOf(jwt);
        return customers.findById(id).map(c -> CustomerView.of(c, canTransact(id)));
    }

    /** Asks the database function customer_can_transact: the rule lives in one place only. */
    @Transactional(readOnly = true)
    public boolean canTransact(UUID customerId) {
        return Boolean.TRUE.equals(jdbc.sql("SELECT public.customer_can_transact(:id)")
            .param("id", customerId)
            .query(Boolean.class)
            .single());
    }

    /**
     * Local dev assumption: the customer id is the Keycloak user id ("sub").
     * To be confirmed with the eKYC team (is the eKYC users.id the same UUID as the Keycloak user?).
     */
    static UUID customerIdOf(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
