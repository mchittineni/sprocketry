package dev.sprocketry.profile;

import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JOSEObjectType;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.RSAKey;
import com.nimbusds.jose.jwk.gen.RSAKeyGenerator;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.Optional;
import java.util.function.Consumer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

/**
 * Real RS256 tokens checked by the production JwtDecoder against a stub JWKS endpoint, so issuer, audience,
 * expiry and signature checks are exercised rather than bypassed as jwt() does.
 */
@WebMvcTest(ProfileController.class)
@Import(SecurityConfig.class)
class JwtValidationTest {

    private static final String ISSUER = "http://localhost:8180/realms/sprocketry";
    private static final RSAKey KEY = rsaKey("realm-key");
    private static final RSAKey OTHER_KEY = rsaKey("realm-key");
    private static final HttpServer JWKS = jwksServer(new JWKSet(KEY.toPublicJWK()));

    @Autowired
    private MockMvc mvc;

    @MockitoBean
    private ProfileRepository profiles;

    @MockitoBean
    private ShippingClient shipping;

    @DynamicPropertySource
    static void oidc(DynamicPropertyRegistry registry) {
        registry.add("profile.oidc.jwks-url",
                () -> "http://127.0.0.1:" + JWKS.getAddress().getPort() + "/realms/sprocketry/protocol/openid-connect/certs");
        registry.add("profile.oidc.issuer", () -> ISSUER);
        registry.add("profile.oidc.audience", () -> "sprocketry-api");
    }

    @AfterAll
    static void stopJwks() {
        JWKS.stop(0);
    }

    @Test
    void acceptsAValidKeycloakToken() throws Exception {
        when(profiles.find("user-1")).thenReturn(Optional.empty());
        mvc.perform(get("/me").header("Authorization", "Bearer " + token(KEY, c -> {})))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.userId").value("user-1"))
                .andExpect(jsonPath("$.displayName").value("Ada Lovelace"));
    }

    @Test
    void acceptsAStringAudience() throws Exception {
        when(profiles.find("user-1")).thenReturn(Optional.empty());
        mvc.perform(get("/me").header("Authorization", "Bearer " + token(KEY, c -> c.audience("sprocketry-api"))))
                .andExpect(status().isOk());
    }

    @Test
    void rejectsTheWrongAudience() throws Exception {
        expectUnauthorized(token(KEY, c -> c.audience(List.of("account", "storefront"))));
    }

    @Test
    void rejectsAMissingAudience() throws Exception {
        expectUnauthorized(token(KEY, c -> c.audience(List.of())));
    }

    @Test
    void rejectsTheWrongIssuer() throws Exception {
        // The internal Keycloak URL is a different issuer from the public one, even for the same realm.
        expectUnauthorized(token(KEY, c -> c.issuer("http://keycloak:8080/realms/sprocketry")));
    }

    @Test
    void rejectsAnExpiredToken() throws Exception {
        expectUnauthorized(token(KEY, c -> c.expirationTime(Date.from(Instant.now().minusSeconds(300)))));
    }

    @Test
    void rejectsATokenNotYetValid() throws Exception {
        expectUnauthorized(token(KEY, c -> c.notBeforeTime(Date.from(Instant.now().plusSeconds(300)))));
    }

    @Test
    void rejectsATokenSignedByAnotherKey() throws Exception {
        expectUnauthorized(token(OTHER_KEY, c -> {}));
    }

    @Test
    void rejectsGarbage() throws Exception {
        expectUnauthorized("not-a-jwt");
    }

    private void expectUnauthorized(String token) throws Exception {
        mvc.perform(get("/me").header("Authorization", "Bearer " + token)).andExpect(status().isUnauthorized());
    }

    private static String token(RSAKey key, Consumer<JWTClaimsSet.Builder> customize) throws JOSEException {
        Instant now = Instant.now();
        JWTClaimsSet.Builder claims = new JWTClaimsSet.Builder()
                .issuer(ISSUER)
                .subject("user-1")
                .audience(List.of("sprocketry-api", "account"))
                .issueTime(Date.from(now))
                .expirationTime(Date.from(now.plusSeconds(300)))
                .claim("name", "Ada Lovelace")
                .claim("preferred_username", "ada");
        customize.accept(claims);
        SignedJWT jwt = new SignedJWT(
                new JWSHeader.Builder(JWSAlgorithm.RS256).keyID(key.getKeyID()).type(JOSEObjectType.JWT).build(),
                claims.build());
        jwt.sign(new RSASSASigner(key));
        return jwt.serialize();
    }

    private static RSAKey rsaKey(String kid) {
        try {
            return new RSAKeyGenerator(2048).keyID(kid).generate();
        } catch (JOSEException e) {
            throw new IllegalStateException(e);
        }
    }

    private static HttpServer jwksServer(JWKSet keys) {
        try {
            HttpServer server = HttpServer.create(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 0);
            byte[] body = keys.toString().getBytes(StandardCharsets.UTF_8);
            server.createContext("/realms/sprocketry/protocol/openid-connect/certs", exchange -> {
                exchange.getResponseHeaders().add("Content-Type", "application/json");
                exchange.sendResponseHeaders(200, body.length);
                exchange.getResponseBody().write(body);
                exchange.close();
            });
            server.start();
            return server;
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
