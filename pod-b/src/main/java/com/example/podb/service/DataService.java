package com.example.podb.service;

import org.springframework.stereotype.Service;

import java.time.Instant;
import java.util.LinkedHashMap;
import java.util.Map;

@Service
public class DataService {

    public Map<String, Object> getProtectedData() {
        Map<String, Object> data = new LinkedHashMap<>();
        data.put("source", "pod-b");
        data.put("dataset", "protected");
        data.put("served-at", Instant.now().toString());
        data.put("items", java.util.List.of(
                Map.of("id", 1, "name", "alpha"),
                Map.of("id", 2, "name", "beta")));
        return data;
    }

    public Map<String, Object> createData(Map<String, String> payload) {
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("id", java.util.UUID.randomUUID().toString());
        result.put("payload", payload);
        result.put("created-at", Instant.now().toString());
        return result;
    }
}
