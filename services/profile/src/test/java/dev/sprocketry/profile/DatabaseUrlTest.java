package dev.sprocketry.profile;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import org.junit.jupiter.api.Test;

class DatabaseUrlTest {

    @Test
    void convertsTheLocalUrl() {
        DatabaseUrl url = DatabaseUrl.parse("postgres://sprocketry:sprocketry@postgres:5432/profile");
        assertEquals("jdbc:postgresql://postgres:5432/profile", url.jdbcUrl());
        assertEquals("sprocketry", url.username());
        assertEquals("sprocketry", url.password());
    }

    @Test
    void keepsSslmodeAndDropsParametersPgjdbcDoesNotKnow() {
        DatabaseUrl url = DatabaseUrl.parse(
                "postgres://app:pw@db.example.com:6432/profile?pool_max_conns=4&sslmode=require&connect_timeout=5");
        assertEquals("jdbc:postgresql://db.example.com:6432/profile?sslmode=require", url.jdbcUrl());
    }

    @Test
    void defaultsThePortAndAcceptsThePostgresqlScheme() {
        assertEquals("jdbc:postgresql://db:5432/shop", DatabaseUrl.parse("postgresql://u:p@db/shop").jdbcUrl());
    }

    @Test
    void decodesPercentEncodedCredentialsButKeepsPlus() {
        DatabaseUrl url = DatabaseUrl.parse("postgres://app%40corp:p%3Aw%2Fd+x@db:5432/profile");
        assertEquals("app@corp", url.username());
        assertEquals("p:w/d+x", url.password());
    }

    @Test
    void allowsMissingCredentials() {
        DatabaseUrl url = DatabaseUrl.parse("postgres://db:5432/profile");
        assertNull(url.username());
        assertNull(url.password());
    }

    @Test
    void keepsTheUserWhenThereIsNoPassword() {
        DatabaseUrl url = DatabaseUrl.parse("postgres://app@db/profile");
        assertEquals("app", url.username());
        assertNull(url.password());
    }

    @Test
    void neverPrintsThePassword() {
        assertEquals(false, DatabaseUrl.parse("postgres://u:secret@db/p").toString().contains("secret"));
    }

    @Test
    void rejectsOtherSchemesAndMissingDatabase() {
        assertThrows(IllegalArgumentException.class, () -> DatabaseUrl.parse("mysql://u:p@db/profile"));
        assertThrows(IllegalArgumentException.class, () -> DatabaseUrl.parse("postgres://u:p@db:5432/"));
        assertThrows(IllegalArgumentException.class, () -> DatabaseUrl.parse("not a url"));
    }
}
