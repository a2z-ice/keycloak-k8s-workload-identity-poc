package com.example.podb.auth;

import lombok.extern.slf4j.Slf4j;
import org.springframework.core.convert.converter.Converter;
import org.springframework.security.authentication.AbstractAuthenticationToken;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationToken;
import org.springframework.stereotype.Component;

import java.util.*;

/**
 * Builds Spring authorities from a Keycloak-issued JWT.
 *   - Realm roles:  realm_access.roles[]
 *   - Resource roles: resource_access.<client>.roles[]
 *   - Top-level "roles" claim if present (RFC 8693 token-exchange minted tokens
 *     sometimes carry roles flat).
 *
 * All discovered roles become ROLE_<name> authorities.
 *
 * The principal name is the 'sub' claim — typically
 * 'system:serviceaccount:poc:pod-a' for tokens minted via the IdP broker.
 */
@Slf4j
@Component
public class PocJwtAuthenticationConverter implements Converter<Jwt, AbstractAuthenticationToken> {

    @Override
    public AbstractAuthenticationToken convert(Jwt jwt) {
        Set<GrantedAuthority> authorities = new HashSet<>();

        // realm_access.roles
        Map<String, Object> realmAccess = jwt.getClaim("realm_access");
        if (realmAccess != null) {
            Object roles = realmAccess.get("roles");
            if (roles instanceof Collection<?> c) {
                for (Object r : c) authorities.add(new SimpleGrantedAuthority("ROLE_" + r));
            }
        }

        // resource_access.<client>.roles for each client
        Map<String, Object> resourceAccess = jwt.getClaim("resource_access");
        if (resourceAccess != null) {
            for (Object v : resourceAccess.values()) {
                if (v instanceof Map<?, ?> m) {
                    Object roles = m.get("roles");
                    if (roles instanceof Collection<?> c) {
                        for (Object r : c) authorities.add(new SimpleGrantedAuthority("ROLE_" + r));
                    }
                }
            }
        }

        // top-level "roles" claim
        Object flat = jwt.getClaim("roles");
        if (flat instanceof Collection<?> c) {
            for (Object r : c) authorities.add(new SimpleGrantedAuthority("ROLE_" + r));
        }

        String principal = jwt.getClaimAsString("sub");
        log.debug("JWT auth: subject={}, authorities={}", principal, authorities);
        return new JwtAuthenticationToken(jwt, authorities, principal);
    }
}
