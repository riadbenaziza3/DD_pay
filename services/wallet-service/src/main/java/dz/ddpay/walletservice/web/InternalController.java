package dz.ddpay.walletservice.web;

import java.util.UUID;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import dz.ddpay.walletservice.account.AccountService;
import dz.ddpay.walletservice.account.AccountView;
import dz.ddpay.walletservice.ledger.LedgerService;
import dz.ddpay.walletservice.ledger.PostingResult;
import dz.ddpay.walletservice.ledger.WalletException;
import jakarta.validation.Valid;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Positive;
import jakarta.validation.constraints.Size;

/**
 * Called by other PSP services (role "wallet-operator"), never by the app.
 *   - customer-service opens a wallet when a customer becomes VERIFIED,
 *     and freezes / unfreezes it when KYC or AML status changes.
 *   - top-ups: in dev, done by hand; later they come from the payment-service once
 *     a card/CIB/Edahabia payment is confirmed.
 */
@RestController
@RequestMapping("/internal/wallets")
public class InternalController {

    private final AccountService accounts;
    private final LedgerService ledger;

    public InternalController(AccountService accounts, LedgerService ledger) {
        this.accounts = accounts;
        this.ledger = ledger;
    }

    public record StatusRequest(
        @NotNull @Pattern(regexp = "active|frozen|closed") String status,
        @Size(max = 200) String reason
    ) {}

    public record TopUpRequest(
        @NotNull @Positive @Max(100_000_000L) Long amountCentimes,
        @Size(max = 140) String description
    ) {}

    @PostMapping("/{userId}")
    public ResponseEntity<AccountView> open(@PathVariable UUID userId, @AuthenticationPrincipal Jwt caller) {
        AccountService.OpenResult result = accounts.openForUser(userId, callerName(caller));
        return ResponseEntity.status(result.created() ? HttpStatus.CREATED : HttpStatus.OK).body(result.account());
    }

    @GetMapping("/{userId}")
    public AccountView get(@PathVariable UUID userId) {
        return accounts.findByUser(userId).orElseThrow(() -> WalletException.walletNotFound("User " + userId));
    }

    @PutMapping("/{userId}/status")
    public AccountView setStatus(@PathVariable UUID userId, @Valid @RequestBody StatusRequest request,
                                 @AuthenticationPrincipal Jwt caller) {
        return accounts.setStatus(userId, request.status(), request.reason(), callerName(caller));
    }

    @PostMapping("/{userId}/topups")
    public ResponseEntity<PostingResult> topUp(@PathVariable UUID userId,
                                               @RequestHeader("Idempotency-Key") String idempotencyKey,
                                               @Valid @RequestBody TopUpRequest request) {
        Keys.check(idempotencyKey);
        PostingResult result = ledger.topUp(userId, request.amountCentimes(), idempotencyKey, request.description());
        return ResponseEntity.status(result.replayed() ? HttpStatus.OK : HttpStatus.CREATED).body(result);
    }

    /** Which service made the call: Keycloak puts the client id in the "azp" claim. */
    private static String callerName(Jwt caller) {
        String azp = caller.getClaimAsString("azp");
        return azp != null ? azp : caller.getSubject();
    }
}
