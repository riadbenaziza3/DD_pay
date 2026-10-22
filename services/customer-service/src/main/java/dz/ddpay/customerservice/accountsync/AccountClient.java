package dz.ddpay.customerservice.accountsync;

import java.time.Duration;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Supplier;

import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.RestClient;

/**
 * Calls account-service's internal API (/internal/accounts/...).
 * All the endpoints used here are safe to call twice: opening an existing account returns it,
 * setting a status it already has changes nothing.
 */
public class AccountClient {

    /** The request itself is refused (e.g. account closed): retrying won't help. */
    public static class PermanentFailure extends RuntimeException {
        public PermanentFailure(String message) {
            super(message);
        }
    }

    private final RestClient http;
    private final ServiceTokenProvider tokens;

    public AccountClient(String baseUrl, ServiceTokenProvider tokens) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(3));
        factory.setReadTimeout(Duration.ofSeconds(5));
        this.http = RestClient.builder().baseUrl(baseUrl).requestFactory(factory).build();
        this.tokens = tokens;
    }

    public boolean isConfigured() {
        return tokens.isConfigured();
    }

    /** Opens the customer's account, or returns the existing one. */
    public Map<?, ?> open(UUID customerId) {
        return call(() -> http.post()
            .uri("/internal/accounts/{id}", customerId)
            .header("Authorization", "Bearer " + tokens.token())
            .retrieve()
            .body(Map.class));
    }

    /** The customer's account, or empty if they don't have one. */
    public Optional<Map<?, ?>> find(UUID customerId) {
        try {
            return Optional.ofNullable(call(() -> http.get()
                .uri("/internal/accounts/{id}", customerId)
                .header("Authorization", "Bearer " + tokens.token())
                .retrieve()
                .body(Map.class)));
        } catch (HttpClientErrorException.NotFound e) {
            return Optional.empty();
        }
    }

    public Map<?, ?> setStatus(UUID customerId, String status, String reason) {
        return call(() -> http.put()
            .uri("/internal/accounts/{id}/status", customerId)
            .header("Authorization", "Bearer " + tokens.token())
            .contentType(MediaType.APPLICATION_JSON)
            .body(Map.of("status", status, "reason", reason))
            .retrieve()
            .body(Map.class));
    }

    /**
     * 401: token expired or revoked -> drop it, the retry gets a new one.
     * 400 / 409 / 422: account-service refuses this request -> permanent.
     * Anything else (404 handled by the caller, 403 config problem, 5xx, timeouts): retried.
     */
    private Map<?, ?> call(Supplier<Map<?, ?>> request) {
        try {
            return request.get();
        } catch (HttpClientErrorException e) {
            int code = e.getStatusCode().value();
            if (code == 401) {
                tokens.invalidate();
            }
            if (code == 400 || code == 409 || code == 422) {
                throw new PermanentFailure("HTTP " + code + " " + e.getResponseBodyAsString());
            }
            throw e;
        }
    }
}
