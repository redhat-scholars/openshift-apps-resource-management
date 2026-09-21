package com.redhat.developers.greeting;

import static io.restassured.RestAssured.given;
import static org.hamcrest.CoreMatchers.is;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;

@QuarkusTest
class GreetingResourceTest {

    @Test
    void servesAKnownLanguage() {
        given().queryParam("lang", "es")
                .when().get("/")
                .then().statusCode(200)
                .body("code", is("es"))
                .body("hello", is("Hola"));
    }

    @Test
    void fallsBackForAnUnknownLanguage() {
        given().queryParam("lang", "xx")
                .when().get("/")
                .then().statusCode(200)
                .body("code", is("none"))
                .body("hello", is("Hello"));
    }

    @Test
    void fallsBackWhenNoLanguageIsGiven() {
        given().when().get("/")
                .then().statusCode(200)
                .body("code", is("none"))
                .body("hello", is("Hello"));
    }

    @Test
    void ignoresCaseAndRegion() {
        given().queryParam("lang", "EN-GB")
                .when().get("/")
                .then().statusCode(200)
                .body("hello", is("Hello"));
    }

    /**
     * The tutorial's UrlHealthCheck asserts a 200 from exactly this URL, so a regression
     * here turns the student's readiness probe red for reasons that look unrelated.
     */
    @Test
    void answersTheUrlTheTutorialProbes() {
        given().when().get("/?lang=en")
                .then().statusCode(200);
    }

    @Test
    void reportsItsOwnHealth() {
        given().when().get("/q/health/ready")
                .then().statusCode(200);
    }
}
