package dev.sprocketry.profile;

import static org.junit.jupiter.api.Assertions.assertNotNull;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

/**
 * The database tests are skipped without TEST_DATABASE_URL. CI always provides one, so there a missing
 * database is a broken pipeline that would otherwise pass unnoticed.
 */
@EnabledIfEnvironmentVariable(named = "CI", matches = ".+")
class DatabaseConfiguredInCiTest {

    @Test
    void ciProvidesTestDatabase() {
        assertNotNull(System.getenv("TEST_DATABASE_URL"), "TEST_DATABASE_URL not set in CI");
    }
}
