package dev.sprocketry.profile;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.sql.Connection;
import java.sql.SQLException;
import javax.sql.DataSource;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.test.context.TestPropertySource;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(HealthController.class)
@Import(SecurityConfig.class)
@TestPropertySource(properties = {
    "profile.oidc.jwks-url=http://keycloak.invalid/certs",
    "profile.oidc.issuer=http://localhost:8180/realms/sprocketry",
})
class HealthControllerTest {

    @Autowired
    private MockMvc mvc;

    @MockitoBean
    private DataSource dataSource;

    @Test
    void healthzNeedsNoTokenOrDatabase() throws Exception {
        when(dataSource.getConnection()).thenThrow(new SQLException("down"));
        mvc.perform(get("/healthz")).andExpect(status().isOk());
    }

    @Test
    void readyzIsOkWhenTheDatabaseAnswers() throws Exception {
        Connection conn = mock(Connection.class);
        when(conn.isValid(2)).thenReturn(true);
        when(dataSource.getConnection()).thenReturn(conn);
        mvc.perform(get("/readyz")).andExpect(status().isOk());
    }

    @Test
    void readyzIsUnavailableWhenTheDatabaseIsDown() throws Exception {
        when(dataSource.getConnection()).thenThrow(new SQLException("down"));
        mvc.perform(get("/readyz")).andExpect(status().isServiceUnavailable());
    }
}
