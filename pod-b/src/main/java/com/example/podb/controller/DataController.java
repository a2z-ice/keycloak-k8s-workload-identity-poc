package com.example.podb.controller;

import com.example.podb.audit.AuditLogger;
import com.example.podb.service.DataService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.core.Authentication;
import org.springframework.web.bind.annotation.*;

import java.util.HashMap;
import java.util.Map;
import java.util.stream.Collectors;

@Slf4j
@RestController
@RequestMapping("/api")
public class DataController {

    private final DataService dataService;
    private final AuditLogger auditLogger;

    public DataController(DataService dataService, AuditLogger auditLogger) {
        this.dataService = dataService;
        this.auditLogger = auditLogger;
    }

    @GetMapping("/health")
    public ResponseEntity<Map<String, String>> health() {
        return ResponseEntity.ok(Map.of("status", "UP", "pod", "pod-b"));
    }

    @GetMapping("/public/info")
    public ResponseEntity<Map<String, String>> getPublicInfo() {
        return ResponseEntity.ok(Map.of(
                "app", "pod-b",
                "type", "resource-server",
                "version", "1.0.0"));
    }

    @PreAuthorize("hasRole('data-reader')")
    @GetMapping("/protected/data")
    public ResponseEntity<Map<String, Object>> getProtectedData(Authentication auth) {
        auditLogger.logAccess("GET", "/api/protected/data", auth, "ALLOWED");
        Map<String, Object> data = new HashMap<>(dataService.getProtectedData());
        data.put("callerIdentity", auth.getName());
        data.put("roles", auth.getAuthorities().stream()
                .map(a -> a.getAuthority()).collect(Collectors.toList()));
        return ResponseEntity.ok(data);
    }

    @PreAuthorize("hasRole('data-writer')")
    @PostMapping("/protected/create")
    public ResponseEntity<Map<String, Object>> createData(
            @RequestBody Map<String, String> payload,
            Authentication auth) {
        auditLogger.logAccess("POST", "/api/protected/create", auth, "ALLOWED");
        Map<String, Object> response = new HashMap<>();
        response.put("status", "created");
        response.put("data", dataService.createData(payload));
        response.put("callerIdentity", auth.getName());
        return ResponseEntity.status(201).body(response);
    }
}
