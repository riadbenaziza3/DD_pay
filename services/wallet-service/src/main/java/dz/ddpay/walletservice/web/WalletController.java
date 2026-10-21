package dz.ddpay.walletservice.web;

import java.util.List;
import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import dz.ddpay.walletservice.account.AccountService;
import dz.ddpay.walletservice.account.AccountView;
import dz.ddpay.walletservice.ledger.LedgerService;
import dz.ddpay.walletservice.ledger.PostingResult;
import dz.ddpay.walletservice.ledger.TransactionView;
import dz.ddpay.walletservice.ledger.WalletException;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;

/**
 * The logged-in customer's own wallet. The user is always taken from the token,
 * never from the request, so nobody can act on someone else's wallet.
 */
@RestController
@RequestMapping("/api/wallet/me")
public class WalletController {

    private final AccountService accounts;
    private final LedgerService ledger;

    public WalletController(AccountService accounts, LedgerService ledger) {
        this.accounts = accounts;
        this.ledger = ledger;
    }

    public record TransferRequest(
        @NotNull UUID toUserId,
        @NotNull @Positive @Max(100_000_000L) Long amountCentimes,   // max 1,000,000.00 DZD per transfer
        @Size(max = 140) String description
    ) {}

    @GetMapping
    public AccountView myWallet(@AuthenticationPrincipal Jwt jwt) {
        return accounts.findByUser(userId(jwt)).orElseThrow(() -> WalletException.walletNotFound("You"));
    }

    @GetMapping("/transactions")
    public List<TransactionView> myTransactions(@AuthenticationPrincipal Jwt jwt,
                                                @RequestParam(defaultValue = "20") int limit) {
        return ledger.history(userId(jwt), Math.max(1, Math.min(limit, 100)));
    }

    /**
     * The app sends a fresh Idempotency-Key (a UUID) per transfer and reuses it when retrying,
     * so a retry after a timeout never sends the money twice.
     */
    @PostMapping("/transfers")
    public ResponseEntity<PostingResult> transfer(@AuthenticationPrincipal Jwt jwt,
                                                  @RequestHeader("Idempotency-Key") String idempotencyKey,
                                                  @Valid @RequestBody TransferRequest request) {
        Keys.check(idempotencyKey);
        PostingResult result = ledger.transfer(userId(jwt), request.toUserId(),
            request.amountCentimes(), idempotencyKey, request.description());
        return ResponseEntity.status(result.replayed() ? HttpStatus.OK : HttpStatus.CREATED).body(result);
    }

    private static UUID userId(Jwt jwt) {
        return UUID.fromString(jwt.getSubject());
    }
}
