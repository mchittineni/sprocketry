package dev.sprocketry.profile;

import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.URISyntaxException;
import java.nio.charset.StandardCharsets;

/**
 * A libpq-style {@code postgres://user:pass@host:port/db?sslmode=require} URL, the form every service's
 * DATABASE_URL uses, split into what the JDBC driver needs. Credentials stay out of the JDBC URL so they
 * never show up in its logs. Only {@code sslmode} is carried over: pgjdbc accepts the same values, while
 * other libpq or pgx parameters mean nothing to it.
 */
record DatabaseUrl(String jdbcUrl, String username, String password) {

    static DatabaseUrl parse(String url) {
        URI uri;
        try {
            uri = new URI(url);
        } catch (URISyntaxException e) {
            throw new IllegalArgumentException("DATABASE_URL is not a valid URL", e);
        }
        String scheme = uri.getScheme();
        if (!"postgres".equals(scheme) && !"postgresql".equals(scheme)) {
            throw new IllegalArgumentException("DATABASE_URL must start with postgres:// or postgresql://");
        }
        if (uri.getHost() == null) {
            throw new IllegalArgumentException("DATABASE_URL has no host");
        }
        String database = uri.getRawPath() == null ? "" : uri.getRawPath().replaceFirst("^/", "");
        if (database.isEmpty()) {
            throw new IllegalArgumentException("DATABASE_URL has no database name");
        }

        String username = null;
        String password = null;
        String userInfo = uri.getRawUserInfo();
        if (userInfo != null) {
            int colon = userInfo.indexOf(':');
            username = percentDecode(colon < 0 ? userInfo : userInfo.substring(0, colon));
            password = colon < 0 ? null : percentDecode(userInfo.substring(colon + 1));
        }

        StringBuilder jdbc = new StringBuilder("jdbc:postgresql://").append(uri.getHost());
        jdbc.append(':').append(uri.getPort() < 0 ? 5432 : uri.getPort());
        jdbc.append('/').append(database);
        String sslmode = queryParam(uri.getRawQuery(), "sslmode");
        if (sslmode != null) {
            jdbc.append("?sslmode=").append(sslmode);
        }
        return new DatabaseUrl(jdbc.toString(), username, password);
    }

    private static String queryParam(String rawQuery, String name) {
        if (rawQuery == null) {
            return null;
        }
        for (String pair : rawQuery.split("&")) {
            int eq = pair.indexOf('=');
            if (eq > 0 && pair.substring(0, eq).equals(name)) {
                return pair.substring(eq + 1);
            }
        }
        return null;
    }

    // URI decoding, not form decoding: a '+' in a password is a plus sign, not a space.
    private static String percentDecode(String s) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(s.length());
        int i = 0;
        while (i < s.length()) {
            if (s.charAt(i) == '%' && i + 2 < s.length()) {
                out.write(Integer.parseInt(s, i + 1, i + 3, 16));
                i += 3;
            } else {
                int cp = s.codePointAt(i);
                out.writeBytes(Character.toString(cp).getBytes(StandardCharsets.UTF_8));
                i += Character.charCount(cp);
            }
        }
        return out.toString(StandardCharsets.UTF_8);
    }

    @Override
    public String toString() {
        return "DatabaseUrl[" + jdbcUrl + ", user=" + username + "]";
    }
}
