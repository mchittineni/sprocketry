package dev.sprocketry.profile;

import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.restclient.test.autoconfigure.AutoConfigureMockRestServiceServer;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

/** The whole application against the database in TEST_DATABASE_URL; skipped when that is not set. */
@EnabledIfEnvironmentVariable(named = "TEST_DATABASE_URL", matches = ".+")
@SpringBootTest
@AutoConfigureMockMvc
@AutoConfigureMockRestServiceServer
class ApplicationDatabaseTest {

    @DynamicPropertySource
    static void env(DynamicPropertyRegistry registry) {
        registry.add("profile.database-url", () -> System.getenv("TEST_DATABASE_URL"));
        registry.add("profile.oidc.jwks-url", () -> "http://keycloak.invalid/certs");
        registry.add("profile.oidc.issuer", () -> "http://localhost:8180/realms/sprocketry");
    }

    @Autowired
    private MockMvc mvc;

    @Autowired
    private MockRestServiceServer shipping;

    @Test
    void probesAreOpenAndReady() throws Exception {
        mvc.perform(get("/healthz")).andExpect(status().isOk());
        mvc.perform(get("/readyz")).andExpect(status().isOk());
        mvc.perform(get("/me")).andExpect(status().isUnauthorized());
    }

    @Test
    void profileRoundTrip() throws Exception {
        String sub = UUID.randomUUID().toString();
        RequestPostProcessor user = jwt().jwt(j -> j.subject(sub).claim("preferred_username", "ada"));

        mvc.perform(get("/me").with(user))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.displayName").value("ada"))
                .andExpect(jsonPath("$.defaultCityId").isEmpty());

        // MockRestServiceServer takes every expectation before the first request.
        shipping.expect(requestTo("http://localhost:3500/v1.0/invoke/shipping/method/quote/2"))
                .andRespond(withSuccess("{}", MediaType.APPLICATION_JSON));
        shipping.expect(requestTo("http://localhost:3500/v1.0/invoke/shipping/method/quote/404"))
                .andRespond(withStatus(HttpStatus.NOT_FOUND));
        mvc.perform(put("/me").with(user).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"displayName\":\" Ada \",\"defaultCityId\":2}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.displayName").value("Ada"))
                .andExpect(jsonPath("$.defaultCityId").value(2));

        mvc.perform(put("/me").with(user).contentType(MediaType.APPLICATION_JSON)
                        .content("{\"displayName\":\"Other\",\"defaultCityId\":404}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("unknown city"));
        shipping.verify();

        mvc.perform(get("/me").with(user))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.userId").value(sub))
                .andExpect(jsonPath("$.displayName").value("Ada"))
                .andExpect(jsonPath("$.defaultCityId").value(2));
    }
}
