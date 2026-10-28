package dev.sprocketry.profile;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Component;
import org.springframework.web.client.HttpClientErrorException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

/** Asks the shipping service, through the Dapr sidecar, whether a city exists. */
@Component
class ShippingClient {

    /** The city is not one shipping knows. */
    static final class UnknownCityException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        UnknownCityException(int cityId) {
            super("unknown city " + cityId);
        }
    }

    /** Shipping, or the sidecar, could not answer. */
    static final class ShippingUnavailableException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        ShippingUnavailableException(Throwable cause) {
            super("shipping unavailable", cause);
        }
    }

    private final RestClient http;

    ShippingClient(RestClient.Builder builder, @Value("${profile.dapr-http-port}") int daprPort) {
        this.http = builder.baseUrl("http://localhost:" + daprPort + "/v1.0/invoke/shipping/method").build();
    }

    void requireCity(int cityId) {
        try {
            http.get().uri("/quote/{id}", cityId).retrieve().toBodilessEntity();
        } catch (HttpClientErrorException e) {
            if (e.getStatusCode().isSameCodeAs(HttpStatus.NOT_FOUND)) {
                throw new UnknownCityException(cityId);
            }
            throw new ShippingUnavailableException(e);
        } catch (RestClientException e) {
            throw new ShippingUnavailableException(e);
        }
    }
}
