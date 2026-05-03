package com.example.poda.service;

import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.Optional;
import java.util.concurrent.locks.ReentrantReadWriteLock;

@Slf4j
@Service
public class TokenCacheManager {

    private final TokenExchangeService tokenExchangeService;
    private final ReentrantReadWriteLock lock = new ReentrantReadWriteLock();

    private TokenExchangeService.TokenExchangeResponse cachedToken;

    public TokenCacheManager(TokenExchangeService tokenExchangeService) {
        this.tokenExchangeService = tokenExchangeService;
    }

    public String getAccessToken() throws IOException {
        lock.readLock().lock();
        try {
            if (cachedToken != null && !cachedToken.isExpired()) {
                return cachedToken.getAccessToken();
            }
        } finally {
            lock.readLock().unlock();
        }

        lock.writeLock().lock();
        try {
            if (cachedToken != null && !cachedToken.isExpired()) {
                return cachedToken.getAccessToken();
            }
            log.info("Token expired or missing; refreshing...");
            cachedToken = tokenExchangeService.exchange();
            return cachedToken.getAccessToken();
        } finally {
            lock.writeLock().unlock();
        }
    }

    public Optional<TokenExchangeService.TokenExchangeResponse> getCachedToken() {
        lock.readLock().lock();
        try {
            return Optional.ofNullable(cachedToken);
        } finally {
            lock.readLock().unlock();
        }
    }

    public void invalidate() {
        lock.writeLock().lock();
        try {
            cachedToken = null;
        } finally {
            lock.writeLock().unlock();
        }
    }

    /** Seed the cache with an externally-fetched token (avoids a duplicate exchange). */
    public void put(TokenExchangeService.TokenExchangeResponse token) {
        lock.writeLock().lock();
        try {
            cachedToken = token;
        } finally {
            lock.writeLock().unlock();
        }
    }
}
