package dz.ddpay.customerservice.accountsync;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.scheduling.annotation.EnableScheduling;

@Configuration
@EnableScheduling
public class AccountSyncConfig {

    @Bean
    ServiceTokenProvider serviceTokenProvider(
            @Value("${account-sync.token-uri}") String tokenUri,
            @Value("${account-sync.client-id}") String clientId,
            @Value("${account-sync.client-secret:}") String clientSecret) {
        return new ServiceTokenProvider(tokenUri, clientId, clientSecret);
    }

    @Bean
    AccountClient accountClient(@Value("${account-sync.account-service-url}") String baseUrl,
                                ServiceTokenProvider tokens) {
        return new AccountClient(baseUrl, tokens);
    }
}
