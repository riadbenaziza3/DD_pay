package dz.ddpay.walletservice.ledger;

import java.util.UUID;

/**
 * Result of a money movement.
 * replayed = true when the same Idempotency-Key was already used: nothing new happened,
 * the original result is returned (so a retry after a network error never charges twice).
 */
public record PostingResult(
    UUID transactionId,
    String type,
    String status,
    long amountCentimes,
    long balanceAfterCentimes,
    boolean replayed
) {}
