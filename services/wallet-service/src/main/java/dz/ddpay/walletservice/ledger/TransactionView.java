package dz.ddpay.walletservice.ledger;

import java.time.OffsetDateTime;
import java.util.UUID;

/**
 * One line of a wallet's history.
 * direction: "credit" = money in, "debit" = money out.
 * counterpartyType: "user" for a transfer with another customer, "system" for top-ups/withdrawals.
 */
public record TransactionView(
    UUID transactionId,
    String type,
    String direction,
    long amountCentimes,
    String counterpartyType,
    UUID counterpartyUserId,
    String description,
    OffsetDateTime createdAt
) {}
