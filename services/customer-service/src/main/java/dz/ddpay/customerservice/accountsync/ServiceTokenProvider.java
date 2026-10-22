package dz.ddpay.customerservice.accountsync;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;

import org.springframework.http.MediaType;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;

/**
 * Gets a Keycloak token for customer-service itself (OAuth2 "client credentials"):
 * the token that proves to account-service that the caller is customer-service,
 * with the realm role "account-operator". Cached until shortly before it expires.
 */
public class ServiceTokenProvider {

    private final RestClient http;
    private final String tokenUri;
    private final String clientId;
    private final String clientSecret;

    private String token;
    private Instant expiresAt = Instant.EPOCH;

    public ServiceTokenProvider(String tokenUri, String clientId, String clientSecret) {
        SimpleClientHttpRequestFactory factory = new SimpleClientHttpRequestFactory();
        factory.setConnectTimeout(Duration.ofSeconds(3));
        factory.setReadTimeout(Duration.ofSeconds(5));
        this.http = RestClient.builder().requestFactory(factory).build();
        this.tokenUri = tokenUri;
        this.clientId = clientId;
        this.clientSecret = clientSecret;
    }

    public boolean isConfigured() {
        return clientSecret != null && !clientSecret.isBlank();
    }

    public synchronized String token() {
        if (token != null && Instant.now().isBefore(expiresAt)) {
            return token;
        }
        MultiValueMap<String, String> form = new LinkedMultiValueMap<>();
        form.add("grant_type", "client_credentials");
        form.add("client_id", clientId);
        form.add("client_secret", clientSecret);

        Map<?, ?> response = http.post()
            .uri(tokenUri)
            .contentType(MediaType.APPLICATION_FORM_URLENCODED)
            .body(form)
            .retrieve()
            .body(Map.class);

        if (response == null || !(response.get("access_token") instanceof String accessToken)) {
            throw new IllegalStateException("Keycloak returned no access_token");
        }
        long expiresIn = response.get("expires_in") instanceof Number n ? n.longValue() : 60;

        this.token = accessToken;
        this.expiresAt = Instant.now().plusSeconds(Math.max(10, expiresIn - 30));  // renew 30s early
        return token;
    }

    /** Forget the cached token, e.g. after a 401, so the next call gets a fresh one. */
    public synchronized void invalidate() {
        this.token = null;
        this.expiresAt = Instant.EPOCH;
    }
}
