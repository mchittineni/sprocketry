package dev.sprocketry.profile;

import java.sql.Connection;
import java.sql.SQLException;
import javax.sql.DataSource;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
class HealthController {

    private final DataSource dataSource;

    HealthController(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    @GetMapping("/healthz")
    ResponseEntity<Void> healthz() {
        return ResponseEntity.ok().build();
    }

    @GetMapping("/readyz")
    ResponseEntity<String> readyz() {
        try (Connection conn = dataSource.getConnection()) {
            if (conn.isValid(2)) {
                return ResponseEntity.ok().build();
            }
        } catch (SQLException e) {
            // Fall through: any failure to reach the database means not ready.
        }
        return ResponseEntity.status(HttpStatus.SERVICE_UNAVAILABLE).body("database unavailable");
    }
}
