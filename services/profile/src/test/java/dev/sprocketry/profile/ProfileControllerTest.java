package dev.sprocketry.profile;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.jwt;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.util.Optional;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.restclient.test.autoconfigure.AutoConfigureMockRestServiceServer;
import org.springframework.boot.restclient.test.autoconfigure.AutoConfigureRestClient;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.test.web.servlet.request.RequestPostProcessor;

@WebMvcTest(ProfileController.class)
@Import({SecurityConfig.class, ShippingClient.class})
@AutoConfigureRestClient
@AutoConfigureMockRestServiceServer
@TestPropertySource(properties = {
    "profile.oidc.jwks-url=http://keycloak.invalid/certs",
    "profile.oidc.issuer=http://localhost:8180/realms/sprocketry",
    "profile.dapr-http-port=3500",
})
class ProfileControllerTest {

    private static final String QUOTE = "http://localhost:3500/v1.0/invoke/shipping/method/quote/";

    @Autowired
    private MockMvc mvc;

    @Autowired
    private MockRestServiceServer shipping;

    @MockitoBean
    private ProfileRepository profiles;

    @AfterEach
    void allShippingCallsMade() {
        shipping.verify();
    }

    private static RequestPostProcessor user() {
        return jwt().jwt(j -> j.subject("user-1")
                .claim("name", "Ada Lovelace")
                .claim("preferred_username", "ada")
                .claim("email", "ada@example.com"));
    }

    private static MockHttpServletRequestBuilder putMe(String json) {
        return put("/me").with(user()).contentType(MediaType.APPLICATION_JSON).content(json);
    }

    @Test
    void meNeedsAToken() throws Exception {
        mvc.perform(get("/me")).andExpect(status().isUnauthorized());
        mvc.perform(put("/me").contentType(MediaType.APPLICATION_JSON).content("{\"displayName\":\"x\"}"))
                .andExpect(status().isUnauthorized());
    }

    @Test
    void newUserGetsTheirNameFromTheToken() throws Exception {
        when(profiles.find("user-1")).thenReturn(Optional.empty());
        mvc.perform(get("/me").with(user()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.userId").value("user-1"))
                .andExpect(jsonPath("$.displayName").value("Ada Lovelace"))
                .andExpect(jsonPath("$.email").value("ada@example.com"))
                .andExpect(jsonPath("$.defaultCityId").isEmpty());
    }

    @Test
    void fallsBackToPreferredUsernameAndNullEmail() throws Exception {
        when(profiles.find("user-2")).thenReturn(Optional.empty());
        mvc.perform(get("/me").with(jwt().jwt(j -> j.subject("user-2").claim("preferred_username", "bob"))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.displayName").value("bob"))
                .andExpect(jsonPath("$.email").isEmpty());
    }

    @Test
    void storedNameAndCityWin() throws Exception {
        when(profiles.find("user-1")).thenReturn(Optional.of(new ProfileRepository.Stored("Countess", 3)));
        mvc.perform(get("/me").with(user()))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.displayName").value("Countess"))
                .andExpect(jsonPath("$.defaultCityId").value(3));
    }

    @Test
    void putChecksTheCityAndSavesATrimmedName() throws Exception {
        shipping.expect(requestTo(QUOTE + "7")).andExpect(method(HttpMethod.GET))
                .andRespond(withSuccess("{\"city\":\"Paris\"}", MediaType.APPLICATION_JSON));
        when(profiles.upsert("user-1", "Ada", 7)).thenReturn(new ProfileRepository.Stored("Ada", 7));
        mvc.perform(putMe("{\"displayName\":\"  Ada \",\"defaultCityId\":7}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.userId").value("user-1"))
                .andExpect(jsonPath("$.displayName").value("Ada"))
                .andExpect(jsonPath("$.email").value("ada@example.com"))
                .andExpect(jsonPath("$.defaultCityId").value(7));
        verify(profiles).upsert("user-1", "Ada", 7);
    }

    @Test
    void putWithoutCitySkipsShipping() throws Exception {
        when(profiles.upsert("user-1", "Ada", null)).thenReturn(new ProfileRepository.Stored("Ada", null));
        mvc.perform(putMe("{\"displayName\":\"Ada\",\"defaultCityId\":null}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.defaultCityId").isEmpty());
    }

    @Test
    void unknownCityIsABadRequest() throws Exception {
        shipping.expect(requestTo(QUOTE + "999")).andRespond(withStatus(HttpStatus.NOT_FOUND));
        mvc.perform(putMe("{\"displayName\":\"Ada\",\"defaultCityId\":999}"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error").value("unknown city"));
        verify(profiles, never()).upsert(anyString(), anyString(), any());
    }

    @Test
    void shippingFailureIsABadGateway() throws Exception {
        shipping.expect(requestTo(QUOTE + "7")).andRespond(withServerError());
        mvc.perform(putMe("{\"displayName\":\"Ada\",\"defaultCityId\":7}"))
                .andExpect(status().isBadGateway());
        verify(profiles, never()).upsert(anyString(), anyString(), any());
    }

    @Test
    void displayNameMustBeOneToSixtyCharacters() throws Exception {
        for (String body : new String[] {
            "{\"defaultCityId\":null}",
            "{\"displayName\":null}",
            "{\"displayName\":\"   \"}",
            "{\"displayName\":\"" + "x".repeat(61) + "\"}",
        }) {
            mvc.perform(putMe(body))
                    .andExpect(status().isBadRequest())
                    .andExpect(jsonPath("$.error").value("displayName must be 1-60 characters"));
        }
        verify(profiles, never()).upsert(anyString(), anyString(), any());
    }

    @Test
    void sixtyCharactersAfterTrimmingIsAllowed() throws Exception {
        String name = "é".repeat(60);
        when(profiles.upsert("user-1", name, null)).thenReturn(new ProfileRepository.Stored(name, null));
        mvc.perform(putMe("{\"displayName\":\" " + name + " \"}")).andExpect(status().isOk());
    }

    @Test
    void malformedBodyIsABadRequest() throws Exception {
        mvc.perform(putMe("{not json")).andExpect(status().isBadRequest());
        mvc.perform(putMe("{\"displayName\":\"Ada\",\"defaultCityId\":\"paris\"}")).andExpect(status().isBadRequest());
    }
}
