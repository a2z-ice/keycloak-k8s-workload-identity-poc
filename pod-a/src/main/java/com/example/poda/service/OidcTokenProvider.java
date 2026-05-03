package com.example.poda.service;

import lombok.Builder;
import lombok.Data;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Reads the Kubernetes-projected OIDC token from the mounted volume.
 * Token location: /var/run/secrets/tokens/jwt.token
 * Audience:        keycloak-poc
 */
@Slf4j
@Service
public class OidcTokenProvider {

    @Value("${oidc.token.path:/var/run/secrets/tokens/jwt.token}")
    private String tokenPath;

    @Value("${kubernetes.namespace:default}")
    private String namespace;

    @Value("${kubernetes.pod.name:unknown}")
    private String podName;

    public String getOidcToken() throws IOException {
        Path path = Paths.get(tokenPath);
        if (!Files.exists(path)) {
            log.warn("OIDC token not found at {}.", tokenPath);
            throw new IllegalStateException(
                    "OIDC token not mounted. Ensure pod has serviceAccountToken projected volume.");
        }
        String token = Files.readString(path).trim();
        log.debug("Read OIDC token for pod={}/{}, length={}", namespace, podName, token.length());
        return token;
    }

    public PodMetadata getPodMetadata() {
        return PodMetadata.builder()
                .namespace(namespace)
                .podName(podName)
                .hostname(System.getenv().getOrDefault("HOSTNAME", "unknown"))
                .build();
    }

    @Data
    @Builder
    public static class PodMetadata {
        private String namespace;
        private String podName;
        private String hostname;
    }
}
