# greeting-api

A stand-in for the public [hellosalut](https://hellosalut.stefanbohacek.com) API, so the
tutorial does not depend on a third-party website.

The tutorial application calls that API from a `@Startup` hook in `MessageInitializer`, and
asserts a `200` from it in a `UrlHealthCheck` readiness probe. That makes an unreachable
host more than a degraded check: the application does not boot at all. Running this service
in the same namespace removes the dependency on the venue network and on somebody else's
uptime.

## The contract

Identical to the public API, including the fallback:

```
GET /?lang=en   ->  {"code":"en","hello":"Hello"}
GET /?lang=es   ->  {"code":"es","hello":"Hola"}
GET /?lang=ro   ->  {"code":"ro","hello":"Salut"}
GET /?lang=fr   ->  {"code":"fr","hello":"Salut"}
GET /?lang=xx   ->  {"code":"none","hello":"Hello"}
GET /           ->  {"code":"none","hello":"Hello"}
```

Because it answers at `/` with the same shape, the student's `HelloService` interface and
`ExternalGreeting` DTO stay exactly as the tutorial writes them. Only the
`com.redhat.developers.HelloService/mp-rest/url` property changes.

## Deploying it

See the
[Greeting API](../../documentation/modules/ROOT/pages/greeting-api.adoc) chapter for the
instructor-facing walkthrough. The short version, from the repository root:

```shell
oc new-build registry.access.redhat.com/ubi9/openjdk-21:latest --binary --name=greeting-api \
  --env MAVEN_S2I_ARTIFACT_DIRS=target/quarkus-app \
  --env S2I_SOURCE_DEPLOYMENTS_FILTER='app lib quarkus quarkus-run.jar' \
  --env JAVA_APP_JAR=quarkus-run.jar
oc start-build greeting-api --from-dir=apps/greeting-api --follow
oc apply -f apps/kubefiles/greeting-api.yaml
```

## Adding a language

Translations are configuration, not code, so no rebuild is needed:

```shell
oc set env deployment/greeting-api GREETING_TRANSLATIONS_JA=Konnichiwa
```

## Running it locally

```shell
mvn quarkus:dev
curl 'http://localhost:8080/?lang=es'
```
