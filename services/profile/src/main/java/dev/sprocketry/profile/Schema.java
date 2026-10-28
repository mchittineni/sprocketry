package dev.sprocketry.profile;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import javax.sql.DataSource;

/**
 * The idempotent schema in schema.sql, applied on every replica's start. Concurrent CREATE TABLE IF NOT
 * EXISTS on an empty database fails all but one caller, so the batch starts with a transaction-scoped
 * advisory lock and replicas take turns.
 */
final class Schema {

    static final String LOCK = "SELECT pg_advisory_xact_lock(hashtext('profile-schema'));\n";
    static final String SQL = load();

    private final DataSource dataSource;

    Schema(DataSource dataSource) {
        this.dataSource = dataSource;
    }

    void apply() throws SQLException {
        try (Connection conn = dataSource.getConnection(); Statement stmt = conn.createStatement()) {
            // One explicit transaction holds the lock until every statement in the batch has run.
            conn.setAutoCommit(false);
            try {
                stmt.execute(LOCK + SQL);
                conn.commit();
            } catch (SQLException e) {
                conn.rollback();
                throw e;
            } finally {
                conn.setAutoCommit(true);
            }
        }
    }

    private static String load() {
        try (InputStream in = Schema.class.getResourceAsStream("/schema.sql")) {
            if (in == null) {
                throw new IllegalStateException("schema.sql missing from the classpath");
            }
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
