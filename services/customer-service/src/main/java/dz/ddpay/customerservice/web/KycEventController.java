package dz.ddpay.customerservice.web;

import java.util.Map;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import dz.ddpay.customerservice.kyc.KycEventService;
import dz.ddpay.customerservice.kyc.KycStatusChangedEvent;
import jakarta.validation.Valid;

/**
 * Webhook the eKYC calls when a user's KYC status changes.
 * Only callers with the Keycloak realm role "kyc-publisher" get here (see SecurityConfig).
 * Always answers 200 for duplicates and stale events, so the sender stops retrying them.
 */
@RestController
@RequestMapping("/internal/kyc")
public class KycEventController {

    private final KycEventService kycEventService;

    public KycEventController(KycEventService kycEventService) {
        this.kycEventService = kycEventService;
    }

    @PostMapping("/events")
    public ResponseEntity<Map<String, Object>> receive(@Valid @RequestBody KycStatusChangedEvent event) {
        if (event.version() != 1) {
            throw new IllegalArgumentException("Unsupported event version " + event.version());
        }
        KycEventService.Outcome outcome = kycEventService.apply(event);
        return ResponseEntity.ok(Map.of(
            "result", outcome.result().name(),
            "customerId", event.userId(),
            "canTransact", outcome.canTransact()));
    }
}
