package dz.ddpay.customerservice.kyc;

import java.time.Instant;
import java.time.LocalDate;
import java.util.UUID;

import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/**
 * The event contract proposed to the eKYC team ("kyc.status_changed", version 1).
 * Today it arrives by REST; later the same JSON will arrive from Kafka.
 */
public record KycStatusChangedEvent(
    @NotNull UUID eventId,
    @NotNull @Pattern(regexp = "kyc\\.status_changed") String type,
    @NotNull Integer version,
    @NotNull Instant occurredAt,
    @NotNull UUID userId,
    @NotNull @Valid Data data
) {
    public record Data(
        @NotNull @Pattern(regexp = "PENDING|VERIFIED|REJECTED|BLOCKED") String kycStatus,
        @Pattern(regexp = "CLEAR|FLAGGED|BLOCKED") String amlStatus,
        @Pattern(regexp = "RESIDENT|DIASPORA") String parcours,
        @Size(max = 50) String customerNumber,
        @Size(max = 30) String phone,
        @Size(max = 200) String displayName,
        Instant kycVerifiedAt,
        LocalDate validUntil
    ) {}
}
