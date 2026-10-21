package dz.ddpay.walletservice.web;

import org.springframework.http.HttpStatus;

import dz.ddpay.walletservice.ledger.WalletException;

final class Keys {

    private Keys() {}

    static void check(String idempotencyKey) {
        if (idempotencyKey == null || idempotencyKey.isBlank() || idempotencyKey.length() > 100) {
            throw new WalletException("INVALID_IDEMPOTENCY_KEY", HttpStatus.BAD_REQUEST,
                "Idempotency-Key is required (1 to 100 characters, a UUID is recommended)");
        }
    }
}
