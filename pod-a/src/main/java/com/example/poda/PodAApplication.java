package com.example.poda;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@EnableScheduling
public class PodAApplication {
    public static void main(String[] args) {
        SpringApplication.run(PodAApplication.class, args);
    }
}
