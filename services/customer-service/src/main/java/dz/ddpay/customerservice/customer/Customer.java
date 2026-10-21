package dz.ddpay.customerservice.customer;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.UUID;

import org.springframework.data.domain.Persistable;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.PostLoad;
import jakarta.persistence.PostPersist;
import jakarta.persistence.Table;
import jakarta.persistence.Transient;

/**
 * A PSP customer. The id is the eKYC / Keycloak user id: it is never generated here.
 * Identity data (names, NIN, documents) stays in the eKYC; this is only the synced summary.
 */
@Entity
@Table(name = "customers", schema = "public")
public class Customer implements Persistable<UUID> {

    @Id
    private UUID id;

    @Column(name = "keycloak_subject")
    private String keycloakSubject;

    @Column(name = "customer_number")
    private String customerNumber;

    @Column(name = "phone")
    private String phone;

    @Column(name = "display_name")
    private String displayName;

    @Column(name = "parcours")
    private String parcours;

    @Column(name = "kyc_status", nullable = false)
    private String kycStatus = "PENDING";

    @Column(name = "aml_status")
    private String amlStatus;

    @Column(name = "kyc_verified_at")
    private OffsetDateTime kycVerifiedAt;

    @Column(name = "kyc_valid_until")
    private LocalDate kycValidUntil;

    @Column(name = "kyc_synced_at")
    private OffsetDateTime kycSyncedAt;

    @Column(name = "status", nullable = false)
    private String status = "active";

    // Filled by the database (default value and trigger), never written by Java.
    @Column(name = "created_at", insertable = false, updatable = false)
    private OffsetDateTime createdAt;

    @Column(name = "updated_at", insertable = false, updatable = false)
    private OffsetDateTime updatedAt;

    /** Lets Spring Data INSERT directly instead of SELECT-then-INSERT, since we assign the id. */
    @Transient
    private boolean isNew = true;

    protected Customer() {
        // for JPA
    }

    /** A customer who starts onboarding in DD Pay: exists, but KYC is still PENDING. */
    public static Customer startOnboarding(UUID id, String keycloakSubject, String displayName) {
        Customer c = new Customer();
        c.id = id;
        c.keycloakSubject = keycloakSubject;
        c.displayName = displayName;
        return c;
    }

    /** A customer we first hear about from the eKYC (e.g. verified in the bank app). */
    public static Customer fromKyc(UUID id) {
        Customer c = new Customer();
        c.id = id;
        return c;
    }

    /** Overwrites the synced KYC fields with what the eKYC says now. */
    public void applyKyc(String kycStatus, String amlStatus, String parcours, String customerNumber,
                         String phone, String displayName, OffsetDateTime kycVerifiedAt,
                         LocalDate kycValidUntil, OffsetDateTime syncedAt) {
        this.kycStatus = kycStatus;
        this.amlStatus = amlStatus;
        this.parcours = parcours;
        if (customerNumber != null) this.customerNumber = customerNumber;
        if (phone != null) this.phone = phone;
        if (displayName != null) this.displayName = displayName;
        this.kycVerifiedAt = kycVerifiedAt;
        this.kycValidUntil = kycValidUntil;
        this.kycSyncedAt = syncedAt;
    }

    @PostLoad
    @PostPersist
    void markNotNew() {
        this.isNew = false;
    }

    @Override
    public boolean isNew() {
        return isNew;
    }

    @Override
    public UUID getId() { return id; }
    public String getKeycloakSubject() { return keycloakSubject; }
    public void setKeycloakSubject(String keycloakSubject) { this.keycloakSubject = keycloakSubject; }
    public String getCustomerNumber() { return customerNumber; }
    public String getPhone() { return phone; }
    public String getDisplayName() { return displayName; }
    public String getParcours() { return parcours; }
    public String getKycStatus() { return kycStatus; }
    public String getAmlStatus() { return amlStatus; }
    public OffsetDateTime getKycVerifiedAt() { return kycVerifiedAt; }
    public LocalDate getKycValidUntil() { return kycValidUntil; }
    public OffsetDateTime getKycSyncedAt() { return kycSyncedAt; }
    public String getStatus() { return status; }
    public OffsetDateTime getCreatedAt() { return createdAt; }
    public OffsetDateTime getUpdatedAt() { return updatedAt; }
}
