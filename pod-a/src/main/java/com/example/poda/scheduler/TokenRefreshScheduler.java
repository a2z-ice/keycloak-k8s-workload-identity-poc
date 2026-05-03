package com.example.poda.scheduler;

import com.example.poda.service.TokenCacheManager;
import lombok.extern.slf4j.Slf4j;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.io.IOException;

@Slf4j
@Component
public class TokenRefreshScheduler {

    private final TokenCacheManager tokenCacheManager;

    public TokenRefreshScheduler(TokenCacheManager tokenCacheManager) {
        this.tokenCacheManager = tokenCacheManager;
    }

    /** Refresh every 4 minutes — token TTL is 5 min. */
    @Scheduled(fixedRateString = "${token.refresh.interval-ms:240000}",
               initialDelayString = "${token.refresh.initial-delay-ms:60000}")
    public void refresh() {
        try {
            tokenCacheManager.invalidate();
            tokenCacheManager.getAccessToken();
            log.debug("Scheduled token refresh complete");
        } catch (IOException e) {
            log.warn("Scheduled token refresh failed: {}", e.getMessage());
        }
    }
}
