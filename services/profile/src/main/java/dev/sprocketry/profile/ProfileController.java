package dev.sprocketry.profile;

import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.http.converter.HttpMessageNotReadableException;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/** The signed-in user's own profile; the user is always the token's subject. */
@RestController
class ProfileController {

    static final int MAX_DISPLAY_NAME = 60;

    private static final Logger log = LoggerFactory.getLogger(ProfileController.class);

    record Profile(String userId, String displayName, String email, Integer defaultCityId) {}

    record UpdateProfile(String displayName, Integer defaultCityId) {}

    private static final class BadRequestException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        BadRequestException(String message) {
            super(message);
        }
    }

    private final ProfileRepository profiles;
    private final ShippingClient shipping;

    ProfileController(ProfileRepository profiles, ShippingClient shipping) {
        this.profiles = profiles;
        this.shipping = shipping;
    }

    @GetMapping("/me")
    Profile get(@AuthenticationPrincipal Jwt token) {
        return profile(token, profiles.find(token.getSubject()).orElse(new ProfileRepository.Stored(null, null)));
    }

    @PutMapping("/me")
    Profile put(@AuthenticationPrincipal Jwt token, @RequestBody UpdateProfile body) {
        String name = body.displayName() == null ? "" : body.displayName().strip();
        int length = name.codePointCount(0, name.length());
        if (length < 1 || length > MAX_DISPLAY_NAME) {
            throw new BadRequestException("displayName must be 1-" + MAX_DISPLAY_NAME + " characters");
        }
        if (body.defaultCityId() != null) {
            shipping.requireCity(body.defaultCityId());
        }
        return profile(token, profiles.upsert(token.getSubject(), name, body.defaultCityId()));
    }

    private static Profile profile(Jwt token, ProfileRepository.Stored stored) {
        String displayName = stored.displayName();
        if (displayName == null) {
            displayName = token.getClaimAsString("name");
        }
        if (displayName == null) {
            displayName = token.getClaimAsString("preferred_username");
        }
        return new Profile(token.getSubject(), displayName, token.getClaimAsString("email"), stored.defaultCityId());
    }

    @ExceptionHandler(BadRequestException.class)
    ResponseEntity<Map<String, String>> badRequest(BadRequestException e) {
        return error(HttpStatus.BAD_REQUEST, e.getMessage());
    }

    @ExceptionHandler(HttpMessageNotReadableException.class)
    ResponseEntity<Map<String, String>> unreadable(HttpMessageNotReadableException e) {
        return error(HttpStatus.BAD_REQUEST, "invalid JSON body");
    }

    @ExceptionHandler(ShippingClient.UnknownCityException.class)
    ResponseEntity<Map<String, String>> unknownCity(ShippingClient.UnknownCityException e) {
        return error(HttpStatus.BAD_REQUEST, "unknown city");
    }

    @ExceptionHandler(ShippingClient.ShippingUnavailableException.class)
    ResponseEntity<Map<String, String>> shippingUnavailable(ShippingClient.ShippingUnavailableException e) {
        log.warn("city check failed: {}", e.getCause().toString());
        return error(HttpStatus.BAD_GATEWAY, "shipping unavailable");
    }

    private static ResponseEntity<Map<String, String>> error(HttpStatus status, String message) {
        return ResponseEntity.status(status).body(Map.of("error", message));
    }
}
