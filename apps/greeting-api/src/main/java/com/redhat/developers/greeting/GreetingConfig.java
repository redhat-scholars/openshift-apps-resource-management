package com.redhat.developers.greeting;

import java.util.Map;

import io.smallrye.config.ConfigMapping;
import io.smallrye.config.WithDefault;

/**
 * Translations are configuration rather than code so an instructor can add a language
 * without rebuilding the image:
 *
 * <pre>oc set env deployment/greeting-api GREETING_TRANSLATIONS_DE=Hallo</pre>
 */
@ConfigMapping(prefix = "greeting")
public interface GreetingConfig {

    Map<String, String> translations();

    /** Served for a language that has no translation, mirroring the public API. */
    @WithDefault("Hello")
    String fallback();

    /** The {@code code} the public API reports when it does not know the language. */
    @WithDefault("none")
    String fallbackCode();
}
