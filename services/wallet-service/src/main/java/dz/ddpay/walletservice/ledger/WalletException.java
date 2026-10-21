package dz.ddpay.walletservice.ledger;

import org.springframework.http.HttpStatus;

/** A business refusal with a stable code the app can react to (e.g. INSUFFICIENT_FUNDS). */
public class WalletException extends RuntimeException {

    private final String code;
    private final HttpStatus status;

    public WalletException(String code, HttpStatus status, String message) {
        super(message);
        this.code = code;
        this.status = status;
    }

    public String code() { return code; }
    public HttpStatus status() { return status; }

    public static WalletException walletNotFound(String who) {
        return new WalletException("WALLET_NOT_FOUND", HttpStatus.NOT_FOUND, who + " has no wallet");
    }
}
