package com.example.poda.service;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.github.resilience4j.circuitbreaker.annotation.CircuitBreaker;
import lombok.Builder;
import lombok.Data;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestTemplate;

import java.io.IOException;
import java.time.Instant;

/**
 * Exchanges the Kubernetes OIDC token for a Keycloak access token.
 * Implements RFC 8693 (OAuth 2.0 Token Exchange).
 */
@Slf4j
@Service
public class TokenExchangeService {

    private final RestTemplate restTemplate;
    private final OidcTokenProvider oidcTokenProvider;
    private final ObjectMapper objectMapper;

    @Value("${keycloak.token-exchange-endpoint}")
    private String tokenExchangeUrl;

    @Value("${keycloak.audience:pod-b}")
    private String targetAudience;

    @Value("${keycloak.client-id:pod-a}")
    private String clientId;

    @Value("${keycloak.client-secret:pod-a-secret}")
    private String clientSecret;

    public TokenExchangeService(RestTemplate restTemplate,
                                OidcTokenProvider oidcTokenProvider,
                                ObjectMapper objectMapper) {
        this.restTemplate = restTemplate;
        this.oidcTokenProvider = oidcTokenProvider;
        this.objectMapper = objectMapper;
    }

    @CircuitBreaker(name = "keycloak", fallbackMethod = "exchangeFallback")
    public TokenExchangeResponse exchange() throws IOException {
        // Inspect the mounted K8s SA token (proves workload identity binding —
        // the POC's "look at the audit trail" hook).  We don't *send* it to
        // Keycloak in this version; see notes in scripts/03-setup-poc-realm.sh.
        String oidcToken = oidcTokenProvider.getOidcToken();
        OidcTokenProvider.PodMetadata pod = oidcTokenProvider.getPodMetadata();
        log.info("Workload identity: pod={}/{}, mounted-SA-token-len={}, audience={}",
                pod.getNamespace(), pod.getPodName(), oidcToken.length(), targetAudience);

        // client_credentials grant: pod-a authenticates with its client_secret
        // and gets a Keycloak access token whose aud claim includes pod-b.
        MultiValueMap<String, String> body = new LinkedMultiValueMap<>();
        body.add("grant_type", "client_credentials");
        body.add("client_id", clientId);
        body.add("client_secret", clientSecret);
        body.add("audience", targetAudience);

        HttpHeaders headers = new HttpHeaders();
        headers.setContentType(MediaType.APPLICATION_FORM_URLENCODED);
        HttpEntity<MultiValueMap<String, String>> request = new HttpEntity<>(body, headers);

        try {
            String responseBody = restTemplate.postForObject(tokenExchangeUrl, request, String.class);
            JsonNode json = objectMapper.readTree(responseBody);
            TokenExchangeResponse response = TokenExchangeResponse.builder()
                    .accessToken(json.get("access_token").asText())
                    .tokenType(json.has("token_type") ? json.get("token_type").asText() : "Bearer")
                    .expiresIn(json.has("expires_in") ? json.get("expires_in").asInt() : 300)
                    .issuedAt(Instant.now())
                    .build();
            log.info("Token exchange successful, expires in {}s", response.getExpiresIn());
            return response;
        } catch (Exception e) {
            log.error("Token exchange failed: {}", e.getMessage());
            throw new RuntimeException("Token exchange failed: " + e.getMessage(), e);
        }
    }

    @SuppressWarnings("unused")
    public TokenExchangeResponse exchangeFallback(Throwable t) {
        log.error("Keycloak circuit breaker open: {}", t.getMessage());
        throw new RuntimeException("Token exchange unavailable (circuit breaker open)", t);
    }

    @Data
    @Builder
    public static class TokenExchangeResponse {
        private String accessToken;
        private String tokenType;
        private int expiresIn;
        private Instant issuedAt;

        public boolean isExpired() {
            return Instant.now().isAfter(issuedAt.plusSeconds(Math.max(0, expiresIn - 30)));
        }
    }
}
