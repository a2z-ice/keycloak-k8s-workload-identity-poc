package com.example.poda.controller;

import com.example.poda.service.OidcTokenProvider;
import com.example.poda.service.TokenCacheManager;
import com.example.poda.service.TokenExchangeService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.client.RestTemplate;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.Optional;

@Slf4j
@RestController
@RequestMapping("/api")
public class TokenController {

    private final TokenCacheManager tokenCacheManager;
    private final TokenExchangeService tokenExchangeService;
    private final OidcTokenProvider oidcTokenProvider;
    private final RestTemplate restTemplate;

    @Value("${pod-b.url:http://pod-b.poc.svc.cluster.local:8082}")
    private String defaultPodBUrl;

    public TokenController(TokenCacheManager tokenCacheManager,
                           TokenExchangeService tokenExchangeService,
                           OidcTokenProvider oidcTokenProvider,
                           RestTemplate restTemplate) {
        this.tokenCacheManager = tokenCacheManager;
        this.tokenExchangeService = tokenExchangeService;
        this.oidcTokenProvider = oidcTokenProvider;
        this.restTemplate = restTemplate;
    }

    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of(
                "status", "UP",
                "pod", "pod-a"));
    }

    @GetMapping("/tokens/current")
    public ResponseEntity<Map<String, Object>> getCurrentToken() {
        Optional<TokenExchangeService.TokenExchangeResponse> token = tokenCacheManager.getCachedToken();
        if (token.isEmpty()) {
            return ResponseEntity.noContent().build();
        }
        Map<String, Object> response = new HashMap<>();
        response.put("token", token.get().getAccessToken());
        response.put("expiresIn", token.get().getExpiresIn());
        response.put("issuedAt", token.get().getIssuedAt());
        response.put("expired", token.get().isExpired());
        return ResponseEntity.ok(response);
    }

    @PostMapping("/exchange")
    public ResponseEntity<Map<String, Object>> exchangeToken() throws IOException {
        TokenExchangeService.TokenExchangeResponse response = tokenExchangeService.exchange();
        tokenCacheManager.put(response);

        Map<String, Object> result = new HashMap<>();
        result.put("accessToken", response.getAccessToken());
        result.put("tokenType", response.getTokenType());
        result.put("expiresIn", response.getExpiresIn());
        result.put("issuedAt", response.getIssuedAt());
        return ResponseEntity.ok(result);
    }

    @GetMapping("/call-pod-b")
    public ResponseEntity<Map<String, Object>> callPodB(
            @RequestParam(required = false) String podBUrl) throws IOException {

        String url = (podBUrl != null && !podBUrl.isBlank() ? podBUrl : defaultPodBUrl)
                + "/api/protected/data";
        String accessToken = tokenCacheManager.getAccessToken();
        log.info("Calling Pod B at {}", url);

        try {
            HttpHeaders headers = new HttpHeaders();
            headers.setBearerAuth(accessToken);
            HttpEntity<Void> request = new HttpEntity<>(headers);
            ResponseEntity<String> r = restTemplate.exchange(
                    url, org.springframework.http.HttpMethod.GET, request, String.class);

            Map<String, Object> response = new HashMap<>();
            response.put("message", "Successfully called Pod B");
            response.put("response", r.getBody());
            response.put("status", r.getStatusCode().value());
            response.put("url", url);
            return ResponseEntity.ok(response);
        } catch (Exception e) {
            log.error("Failed to call Pod B: {}", e.getMessage());
            Map<String, Object> error = new HashMap<>();
            error.put("error", e.getMessage());
            error.put("url", url);
            return ResponseEntity.status(500).body(error);
        }
    }

    @GetMapping("/oidc/token-info")
    public ResponseEntity<Map<String, Object>> oidcTokenInfo() throws IOException {
        String token = oidcTokenProvider.getOidcToken();
        OidcTokenProvider.PodMetadata pod = oidcTokenProvider.getPodMetadata();
        Map<String, Object> info = new HashMap<>();
        info.put("length", token.length());
        info.put("parts", token.split("\\.").length);
        info.put("namespace", pod.getNamespace());
        info.put("pod", pod.getPodName());
        info.put("hostname", pod.getHostname());
        return ResponseEntity.ok(info);
    }
}
