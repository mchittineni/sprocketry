package dev.sprocketry.profile;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.zaxxer.hikari.HikariDataSource;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.simple.JdbcClient;

/**
 * Needs a disposable PostgreSQL database in TEST_DATABASE_URL (postgres://... form), which it wipes, so it
 * is skipped when that is not set.
 */
@EnabledIfEnvironmentVariable(named = "TEST_DATABASE_URL", matches = ".+")
class SchemaDatabaseTest {

    private static HikariDataSource db;

    @BeforeAll
    static void connect() {
        db = new DatabaseConfig().dataSource(System.getenv("TEST_DATABASE_URL"));
    }

    @AfterAll
    static void close() {
        db.close();
    }

    private static void dropProfiles() throws SQLException {
        try (Connection conn = db.getConnection(); Statement stmt = conn.createStatement()) {
            stmt.execute("DROP TABLE IF EXISTS profiles");
        }
    }

    // Every replica applies the schema on start; on an empty database they must not fail each other.
    @Test
    void concurrentSchemaApplySucceeds() throws Exception {
        for (int round = 0; round < 5; round++) {
            dropProfiles();
            int replicas = 4;
            CountDownLatch start = new CountDownLatch(1);
            List<Future<?>> results = new ArrayList<>();
            try (ExecutorService pool = Executors.newFixedThreadPool(replicas)) {
                for (int i = 0; i < replicas; i++) {
                    results.add(pool.submit(() -> {
                        start.await();
                        new Schema(db).apply();
                        return null;
                    }));
                }
                start.countDown();
                for (Future<?> result : results) {
                    result.get(); // rethrows the first replica's failure
                }
            }
        }
        assertTrue(JdbcClient.create(db).sql("SELECT to_regclass('profiles') IS NOT NULL").query(Boolean.class).single());
    }

    @Test
    void upsertInsertsThenUpdates() throws Exception {
        dropProfiles();
        new Schema(db).apply();
        ProfileRepository repo = new ProfileRepository(JdbcClient.create(db));

        assertTrue(repo.find("user-1").isEmpty());
        assertEquals(new ProfileRepository.Stored("Ada", 3), repo.upsert("user-1", "Ada", 3));
        assertEquals(new ProfileRepository.Stored("Ada L", null), repo.upsert("user-1", "Ada L", null));
        assertEquals(new ProfileRepository.Stored("Ada L", null), repo.find("user-1").orElseThrow());
        assertTrue(repo.find("user-2").isEmpty());
    }
}
