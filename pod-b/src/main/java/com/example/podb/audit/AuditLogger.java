package com.example.podb.audit;

import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.stereotype.Component;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Structured access-audit log. Every entry is a single line prefixed "AUDIT: "
 * followed by a JSON object — the e2e suite parses this in 04-failure-recovery.
 */
@Slf4j
@Component
public class AuditLogger {

    private final ObjectMapper json = new ObjectMapper();

    public void logAccess(String method, String endpoint, Authentication auth, String outcome) {
        Map<String, Object> event = new LinkedHashMap<>();
        event.put("timestamp", Instant.now().toString());
        event.put("method", method);
        event.put("endpoint", endpoint);
        event.put("caller", auth != null ? auth.getName() : "anonymous");
        event.put("roles", auth == null ? java.util.List.of() :
                auth.getAuthorities().stream().map(GrantedAuthority::getAuthority).collect(Collectors.toList()));
        event.put("outcome", outcome);
        try {
            log.info("AUDIT: {}", json.writeValueAsString(event));
        } catch (Exception e) {
            log.info("AUDIT: {}", event);
        }
    }
}
