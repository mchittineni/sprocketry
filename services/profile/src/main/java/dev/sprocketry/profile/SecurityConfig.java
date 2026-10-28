package dev.sprocketry.profile;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.config.Customizer;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2ErrorCodes;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.web.SecurityFilterChain;

/** Bearer-token auth with Keycloak access tokens; only the probes are open. */
@Configuration(proxyBeanMethods = false)
class SecurityConfig {

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        return http
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers("/healthz", "/readyz").permitAll()
                        .anyRequest().authenticated())
                .oauth2ResourceServer(oauth -> oauth.jwt(Customizer.withDefaults()))
                // Stateless bearer-token API: no cookies, so no session and nothing for CSRF to protect.
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                .csrf(AbstractHttpConfigurer::disable)
                .build();
    }

    /**
     * Keys come from the internal JWKS URL while {@code iss} must equal the public issuer URL, so the
     * decoder is built from both directly instead of by OIDC discovery, which would expect them to match.
     */
    @Bean
    JwtDecoder jwtDecoder(
            @Value("${profile.oidc.jwks-url}") String jwksUrl,
            @Value("${profile.oidc.issuer}") String issuer,
            @Value("${profile.oidc.audience}") String audience) {
        require("OIDC_JWKS_URL", jwksUrl);
        require("OIDC_ISSUER", issuer);
        require("OIDC_AUDIENCE", audience);
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(jwksUrl)
                .jwsAlgorithm(SignatureAlgorithm.RS256)
                .build();
        // createDefaultWithIssuer checks exp and nbf (60s clock skew) and that iss matches exactly.
        decoder.setJwtValidator(new DelegatingOAuth2TokenValidator<>(
                JwtValidators.createDefaultWithIssuer(issuer), audienceValidator(audience)));
        return decoder;
    }

    static OAuth2TokenValidator<Jwt> audienceValidator(String audience) {
        OAuth2Error error = new OAuth2Error(OAuth2ErrorCodes.INVALID_TOKEN, "token audience is not " + audience, null);
        return jwt -> jwt.getAudience() != null && jwt.getAudience().contains(audience)
                ? OAuth2TokenValidatorResult.success()
                : OAuth2TokenValidatorResult.failure(error);
    }

    private static void require(String env, String value) {
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(env + " must be set");
        }
    }
}
