package com.redhat.developers.greeting;

/**
 * The response body served at {@code /}. The field names are what make this service a
 * drop-in replacement for the public hellosalut API, so do not rename them: the tutorial
 * application deserializes {@code hello} into its own {@code ExternalGreeting} DTO.
 */
public class Greeting {

    public String code;

    public String hello;

    public Greeting() {
    }

    public Greeting(String code, String hello) {
        this.code = code;
        this.hello = hello;
    }
}
