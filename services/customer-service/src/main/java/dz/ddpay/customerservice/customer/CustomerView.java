package dz.ddpay.customerservice.customer;

import java.time.LocalDate;
import java.util.UUID;

/** What the app sees about the logged-in customer. */
public record CustomerView(
    UUID id,
    String displayName,
    String phone,
    String customerNumber,
    String parcours,
    String kycStatus,
    String amlStatus,
    LocalDate kycValidUntil,
    String status,
    boolean canTransact
) {
    public static CustomerView of(Customer c, boolean canTransact) {
        return new CustomerView(c.getId(), c.getDisplayName(), c.getPhone(), c.getCustomerNumber(),
            c.getParcours(), c.getKycStatus(), c.getAmlStatus(), c.getKycValidUntil(),
            c.getStatus(), canTransact);
    }
}
