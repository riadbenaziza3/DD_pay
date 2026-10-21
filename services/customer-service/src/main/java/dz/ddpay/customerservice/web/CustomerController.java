package dz.ddpay.customerservice.web;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import dz.ddpay.customerservice.customer.CustomerService;
import dz.ddpay.customerservice.customer.CustomerView;

/** Endpoints the DD Pay app calls for the logged-in customer ("me" = owner of the token). */
@RestController
@RequestMapping("/api/customers")
public class CustomerController {

    private final CustomerService customerService;

    public CustomerController(CustomerService customerService) {
        this.customerService = customerService;
    }

    /** First screen after login: registers the user as a DD Pay customer (KYC PENDING). */
    @PostMapping("/me/onboarding")
    public ResponseEntity<CustomerView> startOnboarding(@AuthenticationPrincipal Jwt jwt) {
        CustomerService.OnboardingResult result = customerService.startOnboarding(jwt);
        return ResponseEntity
            .status(result.created() ? HttpStatus.CREATED : HttpStatus.OK)
            .body(result.customer());
    }

    @GetMapping("/me")
    public ResponseEntity<CustomerView> me(@AuthenticationPrincipal Jwt jwt) {
        return customerService.findMe(jwt)
            .map(ResponseEntity::ok)
            .orElseGet(() -> ResponseEntity.notFound().build());
    }
}
