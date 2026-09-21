# greeting-api

A stand-in for the public [hellosalut](https://hellosalut.stefanbohacek.com) API.

> **Not wired into the tutorial.** The documentation still points students at the public
> API, and deliberately makes no mention of this service. It lives here ready to take over
> when we decide to switch, so nothing below changes what a student reads today.

## Why it exists

The tutorial application calls the greeting API from a `@Startup` hook in
`MessageInitializer`, and asserts a `200` from it in a `UrlHealthCheck` readiness probe. The
startup hook is the awkward part: a hook that throws aborts the boot, so an unreachable host
does not merely turn a health check red — the application does not come up at all, and the
student sees `Failed to start quarkus` with an `UnknownHostException`. Thirty laptops
resolving the same third-party host over conference Wi-Fi is a realistic way to lose a
session. One rehearsal run was already lost to exactly that.

Running this service in the workshop namespace removes the dependency on the venue network
and on somebody else's uptime.

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

Those four languages are the ones `import.sql` seeds, and the values deliberately differ
from the seeded ones — `Salut` rather than `Bonjour` for French — so a student can still see
that `MessageInitializer` really did overwrite the rows.

Because it answers at `/` with the same shape, switching to it needs no code change at all:
the `HelloService` interface, the `ExternalGreeting` DTO and the `UrlHealthCheck` all stay
exactly as `health.adoc` writes them. Only the value of
`com.redhat.developers.HelloService/mp-rest/url` differs.

## Deploying it

### Build on the cluster

Needs nothing but `oc` and a clone of this repository — no local Java, Maven, Podman or
registry account. The source is compiled on the cluster by the UBI 9 OpenJDK 21 builder.

From the repository root:

```shell
oc new-build registry.access.redhat.com/ubi9/openjdk-21:latest --binary --name=greeting-api \
  --env MAVEN_S2I_ARTIFACT_DIRS=target/quarkus-app \
  --env S2I_SOURCE_DEPLOYMENTS_FILTER='app lib quarkus quarkus-run.jar' \
  --env JAVA_APP_JAR=quarkus-run.jar
oc start-build greeting-api --from-dir=apps/greeting-api --follow
```

Quarkus produces a _fast-jar_ layout under `target/quarkus-app/` rather than a single
executable jar. Without those three variables the s2i assemble script finds nothing to
deploy, and the resulting image starts and immediately exits. The first build downloads the
Maven dependencies and takes a few minutes.

Once the changes are on the default branch you can build straight from Git instead,
replacing both commands with:

```shell
oc new-build registry.access.redhat.com/ubi9/openjdk-21:latest~https://github.com/redhat-scholars/openshift-apps-resource-management \
  --context-dir=apps/greeting-api --name=greeting-api \
  --env MAVEN_S2I_ARTIFACT_DIRS=target/quarkus-app \
  --env S2I_SOURCE_DEPLOYMENTS_FILTER='app lib quarkus quarkus-run.jar' \
  --env JAVA_APP_JAR=quarkus-run.jar
```

### Create the Deployment, Service and Route

```shell
oc apply -f apps/kubefiles/greeting-api.yaml
oc rollout status deployment/greeting-api
```

Use the manifest rather than `oc new-app greeting-api`: `oc new-app` publishes the Service on
port 8080, while the manifest publishes port 80, which keeps the in-cluster URL
(`http://greeting-api`) the same shape as the Route. The manifest asks for 50m CPU and 64Mi
of memory, capped at 500m and 256Mi — deliberately small, since it shares a namespace with a
tutorial that spends several chapters filling the quota up on purpose.

### Alternative: build locally with Jib and push to a registry

```shell
cd apps/greeting-api
REGISTRY_ORG=<your-quay-org> mvn clean package \
  -Dquarkus.openshift.deploy=true -Dquarkus.container-image.push=true
```

**quay.io creates a new repository as private.** The cluster then cannot pull it and the Pod
sits in `ImagePullBackOff` with `unauthorized: access to the requested resource is not
authorized`. Make `<your-quay-org>/greeting-api` public in the quay.io UI, or link a pull
secret:

```shell
oc create secret docker-registry quay --docker-server=quay.io \
  --docker-username=<your-quay-org> --docker-password=<token>
oc secrets link default quay --for=pull
```

## Verifying it

```shell
GREETING_URL=https://$(oc get route greeting-api -o jsonpath='{.spec.host}')
for l in en es ro fr xx; do curl -s "$GREETING_URL/?lang=$l"; echo; done
```

## Pointing the tutorial application at it

Hand out the value of `$GREETING_URL` and have it replace the public API in
`src/main/resources/application.properties`:

```properties
com.redhat.developers.HelloService/mp-rest/url=https://greeting-api-<namespace>.<cluster-domain>
```

The Route is the URL to hand out, rather than the in-cluster `http://greeting-api`: students
run the application on their own laptop in dev mode for most of the tutorial and only later
deploy it to the cluster, and the Route is the one address that answers in both situations.
It is public, so one copy in a shared namespace serves students working in namespaces of
their own.

The rehearsal script can do all of this for you:

```shell
GREETING_MODE=cluster ./bin/demo-tutorial.sh
```

## Adding a language

Translations are configuration, not code, so there is nothing to rebuild:

```shell
oc set env deployment/greeting-api GREETING_TRANSLATIONS_JA=Konnichiwa
```

The built-in set is in `src/main/resources/application.properties`.

## Running it locally

```shell
mvn quarkus:dev
curl 'http://localhost:8080/?lang=es'
```

## Tearing it down

```shell
oc delete -f apps/kubefiles/greeting-api.yaml
oc delete bc,is greeting-api --ignore-not-found
```
