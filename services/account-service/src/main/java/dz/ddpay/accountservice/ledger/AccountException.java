package dz.ddpay.accountservice.ledger;

import org.springframework.http.HttpStatus;

/** A business refusal with a stable code the app can react to (e.g. INSUFFICIENT_FUNDS). */
public class AccountException extends RuntimeException {

    private final String code;
    private final HttpStatus status;

    public AccountException(String code, HttpStatus status, String message) {
        super(message);
        this.code = code;
        this.status = status;
    }

    public String code() { return code; }
    public HttpStatus status() { return status; }

    public static AccountException accountNotFound(String who) {
        return new AccountException("ACCOUNT_NOT_FOUND", HttpStatus.NOT_FOUND, who + " has no account");
    }
}
