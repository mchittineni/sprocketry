package dev.sprocketry.profile;

import java.sql.Types;
import java.util.Optional;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

@Repository
class ProfileRepository {

    /** What the service stores for a user; the rest of a profile comes from their token. */
    record Stored(String displayName, Integer defaultCityId) {}

    private final JdbcClient jdbc;

    ProfileRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    Optional<Stored> find(String userId) {
        return jdbc.sql("SELECT display_name, default_city_id FROM profiles WHERE user_id = ?")
                .param(userId)
                .query((rs, n) -> new Stored(rs.getString(1), rs.getObject(2, Integer.class)))
                .optional();
    }

    Stored upsert(String userId, String displayName, Integer defaultCityId) {
        return jdbc.sql("""
                        INSERT INTO profiles (user_id, display_name, default_city_id, updated_at)
                        VALUES (:userId, :displayName, :defaultCityId, now())
                        ON CONFLICT (user_id) DO UPDATE
                           SET display_name = EXCLUDED.display_name,
                               default_city_id = EXCLUDED.default_city_id,
                               updated_at = now()
                        RETURNING display_name, default_city_id
                        """)
                .param("userId", userId)
                .param("displayName", displayName)
                // Typed so a null city binds as an integer, not an unknown-typed null.
                .param("defaultCityId", defaultCityId, Types.INTEGER)
                .query((rs, n) -> new Stored(rs.getString(1), rs.getObject(2, Integer.class)))
                .single();
    }
}
