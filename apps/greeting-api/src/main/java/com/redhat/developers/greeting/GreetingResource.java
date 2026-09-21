package com.redhat.developers.greeting;

import java.util.Locale;
import java.util.Map;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;

/**
 * Serves the greeting at the root path, the same shape and the same place as the public
 * hellosalut API:
 *
 * <pre>
 * GET /?lang=es  ->  {"code":"es","hello":"Hola"}
 * GET /?lang=xx  ->  {"code":"none","hello":"Hello"}
 * </pre>
 *
 * Keeping it at {@code /} is what lets the tutorial's {@code HelloService} interface stay
 * exactly as written — only the {@code mp-rest/url} property changes.
 */
@Path("/")
public class GreetingResource {

    private final GreetingConfig config;

    public GreetingResource(GreetingConfig config) {
        this.config = config;
    }

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public Greeting hello(@QueryParam("lang") String lang) {
        Map<String, String> translations = config.translations();
        if (lang == null || lang.isBlank()) {
            return new Greeting(config.fallbackCode(), config.fallback());
        }
        // Config map keys arrive lowercased, and a caller may well send "EN" or "en-GB".
        String code = lang.trim().toLowerCase(Locale.ROOT);
        String translation = translations.get(code);
        if (translation == null && code.contains("-")) {
            translation = translations.get(code.substring(0, code.indexOf('-')));
        }
        if (translation == null) {
            return new Greeting(config.fallbackCode(), config.fallback());
        }
        return new Greeting(code, translation);
    }
}
