package dev.sprocketry.profile;

import com.zaxxer.hikari.HikariDataSource;
import javax.sql.DataSource;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration(proxyBeanMethods = false)
class DatabaseConfig {

    @Bean
    HikariDataSource dataSource(@Value("${profile.database-url}") String databaseUrl) {
        DatabaseUrl url = DatabaseUrl.parse(databaseUrl);
        HikariDataSource ds = new HikariDataSource();
        ds.setPoolName("profile");
        ds.setJdbcUrl(url.jdbcUrl());
        ds.setUsername(url.username());
        ds.setPassword(url.password());
        ds.setMaximumPoolSize(10);
        // Fail fast so /readyz answers 503 promptly while the database is down.
        ds.setConnectionTimeout(3_000);
        return ds;
    }

    /** Applied before the web server starts; a failure stops the service, as it does for catalog. */
    @Bean
    Schema schema(DataSource dataSource) throws Exception {
        Schema schema = new Schema(dataSource);
        schema.apply();
        return schema;
    }
}
