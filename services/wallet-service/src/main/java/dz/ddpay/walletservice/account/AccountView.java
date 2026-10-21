package dz.ddpay.walletservice.account;

import java.util.UUID;

/** A wallet as shown to the app and to other services. Amounts are in centimes (1 DZD = 100). */
public record AccountView(
    UUID accountId,
    UUID userId,
    String status,
    String currency,
    long balanceCentimes
) {}
