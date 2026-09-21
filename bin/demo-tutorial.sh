#!/usr/bin/env bash
#
# Rehearsal script for "Efficient Resource Management with OpenShift".
#
# Runs the whole tutorial end to end against a real cluster, in the same order a
# student would, and asserts the outcomes the documentation promises. Every Java
# file and property is generated from scratch, so the script exercises the code
# listings in the .adoc pages rather than a pre-built copy of the project.
#
#   ./bin/demo-tutorial.sh                # run everything
#   ./bin/demo-tutorial.sh --list         # show the steps
#   ./bin/demo-tutorial.sh --from 8       # resume from step 8
#   ./bin/demo-tutorial.sh --only 9,13    # run just these steps
#   ./bin/demo-tutorial.sh --cleanup      # remove everything from the cluster
#
# Configuration (all overridable via the environment):
#
#   NAMESPACE        target project              (default: current oc project)
#   WORKDIR          scratch directory           (default: /tmp/rm-tutorial-demo)
#   QUARKUS_VERSION  platform version            (default: 3.39.4)
#   IMAGE_MODE       openshift | quay            (default: openshift)
#   REGISTRY         registry for IMAGE_MODE=quay(default: quay.io)
#   REGISTRY_ORG     organisation                (default: myrepo)
#   IMAGE_NAME       image name                  (default: greeting-app)
#   PG_VERSION       postgresql imagestream tag  (default: 15-el9)
#   SKIP_SLOW        1 = skip the OOMKill wait   (default: 0)
#
# IMAGE_MODE=openshift builds the image with an on-cluster binary build and needs
# no registry credentials — use it to rehearse. IMAGE_MODE=quay is the path the
# documentation describes; run `podman login quay.io` first.
#
set -Eeuo pipefail

QUARKUS_VERSION=${QUARKUS_VERSION:-3.39.4}
WORKDIR=${WORKDIR:-/tmp/rm-tutorial-demo}
APP_DIR="$WORKDIR/tutorial-app"
IMAGE_MODE=${IMAGE_MODE:-openshift}
REGISTRY=${REGISTRY:-quay.io}
REGISTRY_ORG=${REGISTRY_ORG:-myrepo}
IMAGE_NAME=${IMAGE_NAME:-greeting-app}
PG_VERSION=${PG_VERSION:-15-el9}
SKIP_SLOW=${SKIP_SLOW:-0}
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
KUBEFILES="$REPO_ROOT/apps/kubefiles"

# ----------------------------------------------------------------------------- output
if [ -t 2 ]; then
  B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; Z=$'\e[0m'
else
  B=''; R=''; G=''; Y=''; C=''; Z=''
fi

FAILURES=()
CURRENT_STEP=""

# Every diagnostic goes to stderr. `run` is used inside pipelines such as
# `run oc process ... | oc apply -f -`, and anything it printed on stdout would
# be piped into the next command — oc then chokes on the ANSI escapes with
# "error converting YAML to JSON: yaml: control characters are not allowed".
banner()  { printf '\n%s┌─ %s %s\n' "$B$C" "$*" "$Z" >&2; }
say()     { printf '%s│%s %s\n' "$C" "$Z" "$*" >&2; }
note()    { printf '%s│%s %s%s%s\n' "$C" "$Z" "$Y" "$*" "$Z" >&2; }
ok()      { printf '%s│%s %sPASS%s %s\n' "$C" "$Z" "$G" "$Z" "$*" >&2; }
bad()     { printf '%s│%s %sFAIL%s %s\n' "$C" "$Z" "$R" "$Z" "$*" >&2; FAILURES+=("[$CURRENT_STEP] $*"); }
echo_cmd() { printf '%s│%s %s$ %s%s\n' "$C" "$Z" "$B" "$*" "$Z" >&2; }

# run <description> -- prints the command as a student would type it, then runs it
run() {
  echo_cmd "$@"
  "$@"
}

# must <label> <command...> -- prints, runs, and aborts the step if it fails
must() {
  local label=$1; shift
  echo_cmd "$@"
  if "$@"; then ok "$label"; return 0; fi
  bad "$label"
  return 1
}

# check <label> <command...> -- records a failure but keeps going
check() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi
}

# expect <label> <expected-substring> <actual>
expect() {
  local label=$1 want=$2 got=$3
  if [[ "$got" == *"$want"* ]]; then
    ok "$label"
  else
    bad "$label — expected to contain '$want', got: ${got:0:300}"
  fi
}

# equals <label> <expected> <actual>
equals() {
  local label=$1 want=$2 got=$3
  if [[ "$got" == "$want" ]]; then ok "$label"; else bad "$label — expected '$want', got '$got'"; fi
}

die() { printf '\n%sABORT:%s %s\n' "$R$B" "$Z" "$*" >&2; exit 1; }

# wait_for <seconds> <label> <command...> -- poll until the command succeeds
wait_for() {
  local timeout=$1 label=$2; shift 2
  local deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    if "$@" >/dev/null 2>&1; then ok "$label"; return 0; fi
    sleep 5
  done
  bad "$label — still not true after ${timeout}s"
  return 1
}

mvnw() { (cd "$APP_DIR" && ./mvnw -B "$@"); }

# Waits for the rollout and, on failure, dumps what the scheduler/kubelet objected to
# instead of leaving a bare "timed out" behind.
wait_rollout() {
  local img; img=$(oc get deployment tutorial-app -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  say "Deployment image: ${img:-<none>}"
  if [[ "$IMAGE_MODE" == "quay" ]]; then
    expect "image is pulled from ${REGISTRY}" "${REGISTRY}/${REGISTRY_ORG}/${IMAGE_NAME}" "$img"
  else
    expect "image is pulled from the internal registry" \
      "image-registry.openshift-image-registry.svc" "$img"
  fi

  must "rollout completed" oc rollout status deployment/tutorial-app --timeout=300s && return 0

  banner "Rollout diagnostics"
  run oc get pods -l app.kubernetes.io/name=tutorial-app
  oc get pods -l app.kubernetes.io/name=tutorial-app \
    -o jsonpath='{range .items[*]}{.metadata.name}: {.status.containerStatuses[0].state}{"\n"}{end}' 2>/dev/null | sed 's/^/    /' >&2
  oc describe pod -l app.kubernetes.io/name=tutorial-app 2>/dev/null \
    | sed -n '/Events:/,$p' | sed 's/^/    /' >&2
  return 1
}

build_and_deploy() {
  if [[ "$IMAGE_MODE" == "quay" ]]; then
    banner "Jib build, push to ${REGISTRY}/${REGISTRY_ORG}/${IMAGE_NAME}, then deploy"
    must "image built, pushed and applied" \
      mvnw clean package -Dquarkus.openshift.deploy=true -Dquarkus.container-image.push=true
  else
    banner "On-cluster binary build (no registry credentials needed)"
    must "image built on the cluster and applied" \
      mvnw clean package -Dquarkus.openshift.deploy=true -Dquarkus.container-image.builder=openshift
  fi
}

# ----------------------------------------------------------------------------- steps
STEP_IDS=(preflight bootstrap extensions local-run code database health deploy
          resources manifest-test metrics limits-demos hpa cleanup)
STEP_DESC=(
  "Preflight — tools, cluster, quota (setup.adoc)"
  "Bootstrap the project (starter.adoc)"
  "Add extensions and pick the jib builder (starter.adoc)"
  "Package and run locally (starter.adoc + compile-and-run.adoc)"
  "Entity, endpoints, test and datasource config (configuration.adoc)"
  "PostgreSQL on the cluster (configuration.adoc)"
  "REST client, startup hook and health checks (health.adoc)"
  "Build the image and deploy (openshift.adoc)"
  "Set requests/limits and load test (resources.adoc)"
  "Mock-server test for a broken manifest (separate.adoc)"
  "Micrometer tags and the ConfigMap override (metrics.adoc)"
  "Pending, OOMKill, overcommit, LimitRange (monitoring.adoc)"
  "Horizontal Pod Autoscaler (monitoring.adoc)"
  "Remove everything from the cluster"
)

# =============================================================================== 1
step_preflight() {
  local missing=()
  for t in oc kubectl mvn java jq hey podman; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if (( ${#missing[@]} )); then
    die "missing required tools: ${missing[*]} — see setup.adoc"
  fi
  ok "oc, kubectl, mvn, java, jq, hey, podman are on PATH"

  local jv; jv=$(java -version 2>&1 | head -1)
  say "$jv"
  if java -version 2>&1 | grep -qE '"(21|22|23|24|25)'; then
    ok "Java 21 or newer"
  else
    bad "Java 21+ required, found: $jv"
  fi

  local mv; mv=$(mvn -v 2>/dev/null | head -1)
  say "$mv"

  oc whoami >/dev/null 2>&1 || die "not logged in — run 'oc login' first"
  say "logged in as $(oc whoami) on $(oc whoami --show-server)"

  : "${NAMESPACE:=$(oc project -q)}"
  oc project "$NAMESPACE" >/dev/null || die "cannot switch to project '$NAMESPACE'"
  ok "using project $NAMESPACE"

  local ver; ver=$(oc version -o json 2>/dev/null | jq -r '.openshiftVersion // "unknown"')
  say "OpenShift $ver / Kubernetes $(oc version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion')"
  [[ "$ver" == 4.2* ]] && ok "OpenShift 4.2x" || note "tutorial was validated on 4.21, cluster reports $ver"

  banner "Quota and LimitRange the tutorial relies on"
  run oc get resourcequota || true
  run oc describe limitrange resource-limits || true

  if oc get resourcequota compute-deploy >/dev/null 2>&1; then
    ok "ResourceQuota compute-deploy present (monitoring.adoc examples assume it)"
  else
    note "no compute-deploy quota — the quota-based PromQL queries will need adjusting"
  fi

  if [[ "$IMAGE_MODE" == "quay" ]]; then
    if grep -q "$REGISTRY" "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json" 2>/dev/null \
       || grep -q "$REGISTRY" "$HOME/.docker/config.json" 2>/dev/null; then
      ok "credentials found for $REGISTRY"
    else
      die "IMAGE_MODE=quay but no credentials for $REGISTRY — run 'podman login $REGISTRY'"
    fi
  else
    note "IMAGE_MODE=openshift — image is built on the cluster, no registry login needed"
  fi

  mkdir -p "$WORKDIR"
}

# =============================================================================== 2
step_bootstrap() {
  rm -rf "$APP_DIR"
  mkdir -p "$WORKDIR"
  # The student runs this from an empty directory, so must we: passing -f would
  # make Maven insist on a pom.xml that does not exist yet.
  ( cd "$WORKDIR" && run mvn -B "io.quarkus.platform:quarkus-maven-plugin:${QUARKUS_VERSION}:create" \
      -DprojectGroupId="com.redhat.developers" \
      -DprojectArtifactId="tutorial-app" \
      -DprojectVersion="1.0-SNAPSHOT" \
      -DclassName="GreetingResource" \
      -Dpath="messages" )

  check "project generated" test -f "$APP_DIR/pom.xml"
  expect "endpoint is mapped to /messages" '@Path("/messages")' \
    "$(cat "$APP_DIR/src/main/java/com/redhat/developers/GreetingResource.java")"
  expect "generated greeting is the Quarkus REST one" 'Hello from Quarkus REST' \
    "$(cat "$APP_DIR/src/main/java/com/redhat/developers/GreetingResource.java")"
}

# =============================================================================== 3
step_extensions() {
  run mvnw quarkus:add-extension -Dextensions="quarkus-rest-jsonb,quarkus-jdbc-postgresql,quarkus-hibernate-orm-panache,quarkus-smallrye-openapi,quarkus-container-image-jib,quarkus-openshift"

  local pom; pom=$(cat "$APP_DIR/pom.xml")
  for e in quarkus-rest-jsonb quarkus-jdbc-postgresql quarkus-hibernate-orm-panache \
           quarkus-smallrye-openapi quarkus-container-image-jib quarkus-openshift; do
    expect "$e installed" "$e" "$pom"
  done

  banner "Without a builder choice the build must fail — that is what starter.adoc warns about"
  if mvnw package -DskipTests >"$WORKDIR/nobuilder.log" 2>&1; then
    bad "build succeeded without quarkus.container-image.builder — starter.adoc's warning is stale"
  else
    expect "two container-image extensions are detected" \
      "at most one container-image extension can be present" "$(cat "$WORKDIR/nobuilder.log")"
  fi

  say "selecting jib"
  echo "quarkus.container-image.builder=jib" >> "$APP_DIR/src/main/resources/application.properties"
}

# =============================================================================== 4
step_local_run() {
  run mvnw package -DskipTests
  check "runnable jar produced" test -f "$APP_DIR/target/quarkus-app/quarkus-run.jar"

  free_port_8080
  say "starting the packaged application"
  (cd "$APP_DIR" && java -jar target/quarkus-app/quarkus-run.jar >"$WORKDIR/local-run.log" 2>&1 &)
  wait_for 60 "application listening on :8080" curl -sf -o /dev/null http://localhost:8080/messages

  local body; body=$(curl -s http://localhost:8080/messages)
  equals "GET /messages" "Hello from Quarkus REST" "$body"

  banner "Startup banner that compile-and-run.adoc documents"
  grep -E 'io.quarkus\] \(main\)' "$WORKDIR/local-run.log" | sed "s/^/  /"
  expect "banner reports the expected platform" "powered by Quarkus ${QUARKUS_VERSION}" \
    "$(cat "$WORKDIR/local-run.log")"
  expect "no entity yet, so Hibernate stays inactive and prod starts without a database" \
    "Profile prod activated" "$(cat "$WORKDIR/local-run.log")"

  free_port_8080
  expect "stop banner" "stopped in" "$(cat "$WORKDIR/local-run.log")"
}

free_port_8080() {
  local pid
  pid=$(ss -lntpH 2>/dev/null | grep -E '[^0-9]8080[[:space:]]' | grep -oP 'pid=\K[0-9]+' | head -1) || true
  if [ -n "${pid:-}" ]; then
    say "stopping the process on :8080 (pid $pid)"
    kill "$pid" 2>/dev/null || true
    sleep 3
  fi
}

# =============================================================================== 5
step_code() {
  local pkg="$APP_DIR/src/main/java/com/redhat/developers"
  local res="$APP_DIR/src/main/resources"

  say "Message entity"
  cat > "$pkg/Message.java" <<'JAVA'
package com.redhat.developers;

import com.fasterxml.jackson.annotation.JsonInclude;
import io.quarkus.hibernate.orm.panache.PanacheEntity;
import jakarta.persistence.Entity;

@Entity
@JsonInclude(JsonInclude.Include.NON_NULL)
public class Message extends PanacheEntity {

    private String content;
    private String language;
    private String country;

    public String getContent() { return content; }
    public void setContent(String content) { this.content = content; }
    public String getLanguage() { return language; }
    public void setLanguage(String language) { this.language = language; }
    public String getCountry() { return country; }
    public void setCountry(String country) { this.country = country; }
}
JAVA

  say "GreetingResource with GET and POST"
  cat > "$pkg/GreetingResource.java" <<'JAVA'
package com.redhat.developers;

import java.util.List;

import jakarta.transaction.Transactional;
import jakarta.ws.rs.Consumes;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.POST;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;

@Path("messages")
public class GreetingResource {

    @POST
    @Produces(MediaType.APPLICATION_JSON)
    @Consumes(MediaType.APPLICATION_JSON)
    @Transactional
    public Message create(Message message) {
        Message.persist(message);
        return message;
    }

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    public List<Message> findAll() {
        return Message.findAll().list();
    }
}
JAVA

  say "GreetingResourceTest"
  cat > "$APP_DIR/src/test/java/com/redhat/developers/GreetingResourceTest.java" <<'JAVA'
package com.redhat.developers;

import io.quarkus.test.junit.QuarkusTest;
import io.restassured.http.ContentType;
import org.junit.jupiter.api.Test;

import static io.restassured.RestAssured.given;
import static org.hamcrest.CoreMatchers.notNullValue;

@QuarkusTest
class GreetingResourceTest {
    @Test
    public void testCreate() {
        Message message = new Message();
        given().contentType(ContentType.JSON).body(message)
                .when().post("/messages")
                .then()
                .statusCode(200)
                .body(notNullValue());
    }
}
JAVA
  rm -f "$APP_DIR/src/test/java/com/redhat/developers/GreetingResourceIT.java"

  say "application.properties — datasource and profiles"
  cat > "$res/application.properties" <<'PROPS'
# Configuration file
# key = value

quarkus.hibernate-orm.sql-load-script=import.sql
quarkus.datasource.db-kind = postgresql
quarkus.container-image.builder=jib
quarkus.hibernate-orm.schema-management.strategy = drop-and-create

%dev.quarkus.hibernate-orm.log.sql=true
%dev.quarkus.hibernate-orm.log.bind-parameters=true

%prod.quarkus.datasource.username = ${POSTGRES_USERNAME:postgres}
%prod.quarkus.datasource.password = ${POSTGRES_PASSWORD:postgres}
%prod.quarkus.datasource.jdbc.url = jdbc:postgresql://${POSTGRES_SERVER:postgres}:5432/postgres
%prod.quarkus.hibernate-orm.log.sql = false

%test.quarkus.datasource.db-kind=h2
%test.quarkus.datasource.username=username-default
%test.quarkus.datasource.jdbc.url=jdbc:h2:mem:default;DB_CLOSE_DELAY=-1
%test.quarkus.hibernate-orm.dialect=org.hibernate.dialect.H2Dialect
%test.quarkus.datasource.jdbc.min-size=3
%test.quarkus.datasource.jdbc.max-size=13
%test.quarkus.datasource.jdbc.driver=org.h2.Driver
PROPS

  say "import.sql — note the sequence restart"
  cat > "$res/import.sql" <<'SQL'
insert into Message(content, country, language, id) values('Hello', 'United Kingdom', 'en', 1);
insert into Message(content, country, language, id) values('Hola', 'Spain', 'es', 2);
insert into Message(content, country, language, id) values('Salut', 'Romania', 'ro', 3);
insert into Message(content, country, language, id) values('Bonjour', 'France', 'fr', 4);
alter sequence Message_SEQ restart with 100;
SQL

  # quarkus-test-h2 only starts an H2 *server* for Dev Services; the JDBC driver
  # (org.h2.Driver) comes from quarkus-jdbc-h2. Without it the build fails with
  # ConfigurationException: Unable to load the datasource driver org.h2.Driver.
  add_pom_dependency io.quarkus quarkus-jdbc-h2 test
  add_pom_dependency io.quarkus quarkus-test-h2 test

  must "tests pass against the H2 test profile (no Dev Services container needed)" \
    mvnw clean test
}

# add_pom_dependency <groupId> <artifactId> [scope]
add_pom_dependency() {
  local g=$1 a=$2 s=${3:-}
  grep -q "<artifactId>$a</artifactId>" "$APP_DIR/pom.xml" && { say "$a already in pom.xml"; return; }
  say "adding $a to pom.xml"
  local dep="        <dependency>\n            <groupId>$g</groupId>\n            <artifactId>$a</artifactId>\n"
  [ -n "$s" ] && dep="$dep            <scope>$s</scope>\n"
  dep="$dep        </dependency>"
  # Match the LAST </dependencies>: the first one closes <dependencyManagement>,
  # and anything added there is never actually put on the classpath.
  perl -0pi -e "s|</dependencies>(?!.*</dependencies>)|$dep\n    </dependencies>|s" "$APP_DIR/pom.xml"
}

# =============================================================================== 6
step_database() {
  if oc get dc postgres >/dev/null 2>&1 || oc get deployment postgres >/dev/null 2>&1; then
    ok "postgres already present in $NAMESPACE"
  else
    banner "This is what the Software Catalog form does behind the scenes"
    run oc process openshift//postgresql-ephemeral \
      -p DATABASE_SERVICE_NAME=postgres \
      -p POSTGRESQL_USER=postgres \
      -p POSTGRESQL_PASSWORD=postgres \
      -p POSTGRESQL_DATABASE=postgres \
      -p POSTGRESQL_VERSION="$PG_VERSION" \
      | oc apply -f -
  fi

  # The template default (10-el8) does not exist in the openshift namespace any more.
  if ! oc get istag "postgresql:$PG_VERSION" -n openshift >/dev/null 2>&1; then
    bad "imagestreamtag postgresql:$PG_VERSION not found in the openshift namespace — pick another PG_VERSION"
    oc get is postgresql -n openshift -o jsonpath='{range .spec.tags[*]}{.name}{"\n"}{end}' | sed 's/^/    /'
    return 1
  fi

  wait_for 240 "postgres pod is ready" \
    bash -c "oc get pods -l name=postgres -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | grep -q true"
  run oc get pods -l name=postgres
}

# =============================================================================== 7
step_health() {
  local pkg="$APP_DIR/src/main/java/com/redhat/developers"
  local res="$APP_DIR/src/main/resources"

  run mvnw quarkus:add-extension -Dextensions="io.quarkus:quarkus-smallrye-health,io.quarkus:quarkus-rest-client,io.quarkus:quarkus-rest-client-jsonb"

  banner "Probes the OpenShift extension generates"
  mvnw package -DskipTests >/dev/null
  local manifest; manifest=$(cat "$APP_DIR/target/kubernetes/openshift.yml")
  expect "livenessProbe generated"  "livenessProbe"  "$manifest"
  expect "readinessProbe generated" "readinessProbe" "$manifest"
  expect "startupProbe generated"   "startupProbe"   "$manifest"
  grep -A9 'startupProbe' "$APP_DIR/target/kubernetes/openshift.yml" | sed 's/^/    /'

  say "ExternalGreeting / HelloService / GreetingRepository / MessageInitializer / CustomHealthCheck"
  cat > "$pkg/ExternalGreeting.java" <<'JAVA'
package com.redhat.developers;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

@JsonIgnoreProperties(ignoreUnknown = true)
public class ExternalGreeting {
    public String hello;
}
JAVA

  cat > "$pkg/HelloService.java" <<'JAVA'
package com.redhat.developers;

import org.eclipse.microprofile.rest.client.inject.RegisterRestClient;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.QueryParam;
import jakarta.ws.rs.core.MediaType;

@RegisterRestClient
@Path("/")
public interface HelloService {

    @GET
    @Path("/")
    @Produces(MediaType.APPLICATION_JSON)
    ExternalGreeting getContent(@QueryParam("lang") String lang);
}
JAVA

  cat > "$pkg/GreetingRepository.java" <<'JAVA'
package com.redhat.developers;

import io.quarkus.hibernate.orm.panache.PanacheRepository;
import io.quarkus.panache.common.Parameters;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.transaction.Transactional;

@ApplicationScoped
public class GreetingRepository implements PanacheRepository<Message> {

    @Transactional
    public int update(String content, String language) {
        return update("content= :content where language= :language ",
                Parameters.with("content", content)
                        .and("language", language));
    }
}
JAVA

  cat > "$pkg/MessageInitializer.java" <<'JAVA'
package com.redhat.developers;

import io.quarkus.arc.profile.UnlessBuildProfile;
import io.quarkus.runtime.Startup;
import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

import org.eclipse.microprofile.rest.client.inject.RestClient;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

@Startup
@ApplicationScoped
@UnlessBuildProfile("test")
public class MessageInitializer {
    private static final Logger LOGGER = LoggerFactory.getLogger(MessageInitializer.class);

    @Inject
    @RestClient
    HelloService helloService;

    @Inject
    GreetingRepository repository;

    @PostConstruct
    public void init() {
        LOGGER.debug("Updating the db from external service");
        List<Message> messages = Message.findAll().list();
        for (Message message : messages) {
            String language = message.getLanguage();
            repository.update(helloService.getContent(language).hello, language);
        }
        LOGGER.debug("End update of the db ");
    }
}
JAVA

  cat > "$pkg/CustomHealthCheck.java" <<'JAVA'
package com.redhat.developers;

import io.smallrye.health.checks.UrlHealthCheck;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.ws.rs.HttpMethod;

import org.eclipse.microprofile.config.inject.ConfigProperty;
import org.eclipse.microprofile.health.HealthCheck;
import org.eclipse.microprofile.health.Readiness;

@ApplicationScoped
public class CustomHealthCheck {

    @ConfigProperty(name = "com.redhat.developers.HelloService/mp-rest/url")
    String externalURL;

    @Readiness
    HealthCheck checkURL() {
        return new UrlHealthCheck(externalURL + "/?lang=en")
                .name("external-url-check").requestMethod(HttpMethod.GET).statusCode(200);
    }
}
JAVA

  cat >> "$res/application.properties" <<'PROPS'

com.redhat.developers.HelloService/mp-rest/url=https://hellosalut.stefanbohacek.com

quarkus.smallrye-health.root-path=/health
PROPS

  banner "The old hellosalut host must still be a redirect — that is why the URL changed"
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://fourtonfish.com/hellosalut/?lang=en" || echo 000)
  if [[ "$code" == "301" || "$code" == "302" ]]; then
    ok "fourtonfish.com still answers $code — health.adoc's warning is accurate"
  else
    note "fourtonfish.com answered $code (health.adoc says it redirects); recheck the chapter"
  fi
  expect "hellosalut.stefanbohacek.com serves the JSON at /" '"hello"' \
    "$(curl -s --max-time 20 'https://hellosalut.stefanbohacek.com/?lang=en')"

  run mvnw clean package -DskipTests
  expect "probe paths follow the custom root-path" "/health/started" \
    "$(cat "$APP_DIR/target/kubernetes/openshift.yml")"

  banner "Verify readiness locally against the cluster database"
  local pf_pid=""
  oc port-forward svc/postgres 5432:5432 >"$WORKDIR/portforward.log" 2>&1 &
  pf_pid=$!
  sleep 5
  free_port_8080
  (cd "$APP_DIR" && POSTGRES_SERVER=localhost java -jar target/quarkus-app/quarkus-run.jar >"$WORKDIR/health-run.log" 2>&1 &)
  if wait_for 90 "application started against the forwarded database" \
       curl -sf -o /dev/null http://localhost:8080/health/ready; then
    local ready; ready=$(curl -s http://localhost:8080/health/ready)
    echo "$ready" | jq . | sed 's/^/    /'
    equals "overall readiness"        "UP" "$(echo "$ready" | jq -r '.status')"
    equals "external-url-check"       "UP" "$(echo "$ready" | jq -r '.checks[]|select(.name=="external-url-check")|.status')"
    equals "datasource check"         "UP" "$(echo "$ready" | jq -r '.checks[]|select(.name|test("Database"))|.status')"
    expect "import.sql loaded and translated by the startup hook" "Hello" \
      "$(curl -s http://localhost:8080/messages)"
    local created; created=$(curl -s -X POST -H 'Content-Type: application/json' \
      -d '{"content":"Ciao","country":"Italy","language":"it"}' http://localhost:8080/messages)
    expect "POST succeeds — the sequence restart in import.sql works" '"id"' "$created"
  fi
  free_port_8080
  kill "$pf_pid" 2>/dev/null || true
}

# =============================================================================== 8
step_deploy() {
  local res="$APP_DIR/src/main/resources"
  # The registry/group/name trio is the documented quay.io + Jib path. It must NOT
  # be set for the on-cluster build: the OpenShift builder pushes to an ImageStream
  # named after the *application* (tutorial-app), while these properties would point
  # the generated Deployment at quay.io/<group>/<name>. The result is a rollout that
  # never completes, with ImagePullBackOff: unauthorized.
  if [[ "$IMAGE_MODE" == "quay" ]]; then
    grep -q "quarkus.container-image.registry" "$res/application.properties" || cat >> "$res/application.properties" <<PROPS

quarkus.container-image.registry=${REGISTRY}
quarkus.container-image.group=${REGISTRY_ORG}
quarkus.container-image.name=${IMAGE_NAME}
quarkus.container-image.tag=1.0-SNAPSHOT
PROPS
  else
    # Strip any leftovers from an earlier IMAGE_MODE=quay run, so re-running a single
    # step does not resurrect a quay.io image reference the cluster cannot pull.
    sed -i '/^quarkus\.container-image\.\(registry\|group\|name\)=/d' "$res/application.properties"
    note "IMAGE_MODE=openshift: leaving container-image.registry/group/name unset so the"
    note "Deployment resolves to the internal registry. Use IMAGE_MODE=quay to rehearse"
    note "the path openshift.adoc actually documents."
  fi

  grep -q "quarkus.openshift.route.expose" "$res/application.properties" || cat >> "$res/application.properties" <<PROPS

quarkus.openshift.route.expose=true
quarkus.openshift.route.tls.termination=edge
quarkus.openshift.route.tls.insecure-edge-termination-policy=Redirect
PROPS

  build_and_deploy || return 1
  wait_rollout || return 1

  banner "Everything is named after the application, not after the image"
  run oc get deployment,svc,route -l app.kubernetes.io/name=tutorial-app
  check "Deployment tutorial-app exists" oc get deployment tutorial-app
  check "Route tutorial-app exists"      oc get route tutorial-app
  if oc get deploymentconfig tutorial-app >/dev/null 2>&1; then
    bad "a DeploymentConfig was generated — openshift.adoc says it should be an apps/v1 Deployment"
  else
    ok "no DeploymentConfig — the extension generated an apps/v1 Deployment"
  fi

  local host; host=$(oc get route tutorial-app -o jsonpath='{.spec.host}')
  local url="https://$host"
  say "route: $url"

  equals "route uses edge TLS termination" "edge" \
    "$(oc get route tutorial-app -o jsonpath='{.spec.tls.termination}')"
  local redirect; redirect=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "http://$host/messages")
  say "plain HTTP request -> $redirect"
  expect "HTTP is redirected to HTTPS by the router" "https://$host/messages" "$redirect"

  wait_for 120 "route answers /messages over HTTPS" curl -sf -o /dev/null "$url/messages"
  expect "messages come back from the database" "Hello" "$(curl -s "$url/messages")"
  equals "readiness on the cluster" "UP" "$(curl -s "$url/health/ready" | jq -r '.status')"
}

# =============================================================================== 9
step_resources() {
  local res="$APP_DIR/src/main/resources"
  grep -q "quarkus.openshift.resources" "$res/application.properties" || cat >> "$res/application.properties" <<'PROPS'

quarkus.openshift.resources.limits.cpu=500m
quarkus.openshift.resources.limits.memory=400Mi
quarkus.openshift.resources.requests.cpu=100m
quarkus.openshift.resources.requests.memory=256Mi
PROPS

  build_and_deploy || return 1
  wait_rollout || return 1

  local actual; actual=$(oc get deployment tutorial-app \
    -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq -S -c .)
  say "resources on the Pod: $actual"
  equals "requests/limits match resources.adoc" \
    '{"limits":{"cpu":"500m","memory":"400Mi"},"requests":{"cpu":"100m","memory":"256Mi"}}' "$actual"

  local restarts; restarts=$(oc get pods -l app.kubernetes.io/name=tutorial-app \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
  if [[ "${restarts:-0}" == "0" ]]; then
    ok "no restarts — 500m is enough CPU for the ~35s startupProbe budget"
  else
    bad "container restarted $restarts times — check the startupProbe/CPU-limit interaction"
  fi

  banner "Load test (resources.adoc uses this to size the limits)"
  local url; url="https://$(oc get route tutorial-app -o jsonpath='{.spec.host}')"
  run hey -z 60s -c 20 "$url/messages" | sed -n '1,18p'

  note "Now open Observe -> Metrics, switch the Project selector to $NAMESPACE, and run:"
  printf '    %s\n' \
    "CPU Usage" \
    "Memory Usage"
}

# =============================================================================== 10
step_manifest_test() {
  mkdir -p "$APP_DIR/src/main/k8s"
  cat > "$APP_DIR/src/main/k8s/deployment.yml" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.openshift.io/runtime: quarkus
    app.kubernetes.io/version: 1.0-SNAPSHOT
    app.kubernetes.io/name: greeting-app
  name: greeting-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/version: 1.0-SNAPSHOT
      app.kubernetes.io/name: greeting-app
  template:
    metadata:
      labels:
        app.openshift.io/runtime: quarkus
        app.kubernetes.io/version: 1.0-SNAPSHOT
        app.kubernetes.io/name: greeting-app
    spec:
      containers:
          image: ${REGISTRY}/${REGISTRY_ORG}/${IMAGE_NAME}:1.0-SNAPSHOT
          imagePullPolicy: IfNotPresent
          name: greeting-app
          ports:
            - containerPort: 8080
              name: http
              protocol: TCP
          resources:
            limits:
              cpu: 500m
              memory: 400Mi
            requests:
              cpu: 100m
              memory: 256Mi
YAML

  add_pom_dependency io.quarkus quarkus-kubernetes-client
  add_pom_dependency io.quarkus quarkus-test-kubernetes-client test

  cat > "$APP_DIR/src/test/java/com/redhat/developers/DeploymentFileTest.java" <<'JAVA'
package com.redhat.developers;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.test.kubernetes.client.KubernetesServer;
import io.quarkus.test.kubernetes.client.KubernetesTestServer;
import io.quarkus.test.kubernetes.client.WithKubernetesTestServer;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertThrows;

@WithKubernetesTestServer
@QuarkusTest
public class DeploymentFileTest {

    @KubernetesTestServer
    KubernetesServer mockServer;

    @Test
    public void testDeploymentFile() {
        String pathToDeployment = "./src/main/k8s/deployment.yml";
        RuntimeException thrown = assertThrows(IllegalArgumentException.class,
                () -> mockServer.getClient().apps().deployments().load(pathToDeployment).dryRun());
        System.out.println("Rejected manifest: " + thrown.getMessage());
    }
}
JAVA

  run mvnw test -Dtest=DeploymentFileTest 2>&1 | tee "$WORKDIR/manifest-test.log" | sed -n '/Rejected manifest/,+2p'
  expect "the broken manifest is rejected with the documented message" \
    "Cannot deserialize value of type" "$(cat "$WORKDIR/manifest-test.log")"
  expect "the error points at spec.template.spec.containers" \
    'PodSpec["containers"]' "$(cat "$WORKDIR/manifest-test.log")"
}

# =============================================================================== 11
step_metrics() {
  local pkg="$APP_DIR/src/main/java/com/redhat/developers"
  local res="$APP_DIR/src/main/resources"

  run mvnw quarkus:add-extension -Dextensions="io.quarkus:quarkus-micrometer,quarkus-micrometer-registry-prometheus"

  cat > "$pkg/GlobalTagsConfig.java" <<'JAVA'
package com.redhat.developers;

import io.smallrye.config.ConfigMapping;

@ConfigMapping(prefix = "global")
interface GlobalTagsConfig {
     String PROFILE = "profile";
     String REGION = "region";
     String COUNTRY = "country";

     String region();
     String country();
}
JAVA

  cat > "$pkg/CustomConfiguration.java" <<'JAVA'
package com.redhat.developers;

import io.micrometer.core.instrument.Tag;
import io.micrometer.core.instrument.config.MeterFilter;
import io.quarkus.runtime.LaunchMode;

import jakarta.enterprise.inject.Produces;
import jakarta.inject.Inject;
import jakarta.inject.Singleton;
import java.util.Arrays;

@Singleton
public class CustomConfiguration {

    @Inject
    GlobalTagsConfig tagsConfig;

    @Produces
    @Singleton
    public MeterFilter configureTagsForAll() {
        return MeterFilter.commonTags(Arrays.asList(
           Tag.of(GlobalTagsConfig.REGION, tagsConfig.region()),
           Tag.of(GlobalTagsConfig.COUNTRY, tagsConfig.country()),
           Tag.of(GlobalTagsConfig.PROFILE, LaunchMode.current().getDefaultProfile())
        ));
    }
}
JAVA

  cat > "$pkg/GreetingResource.java" <<'JAVA'
package com.redhat.developers;

import io.micrometer.core.annotation.Counted;
import io.micrometer.core.annotation.Timed;

import jakarta.transaction.Transactional;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import java.util.List;

@Path("messages")
public class GreetingResource {

    public static final String URI = "uri";
    public static final String API_GREET = "api.greet";

    @POST
    @Produces(MediaType.APPLICATION_JSON)
    @Consumes(MediaType.APPLICATION_JSON)
    @Transactional
    @Timed(value = "greetings.creation", longTask = true, extraTags = {URI, API_GREET})
    public Message create(Message message) {
        Message.persist(message);
        return message;
    }

    @GET
    @Produces(MediaType.APPLICATION_JSON)
    @Counted(value = "http.get.requests", extraTags = {URI, API_GREET})
    public List<Message> findAll() {
        return Message.findAll().list();
    }
}
JAVA

  grep -q "^global.region" "$res/application.properties" || cat >> "$res/application.properties" <<'PROPS'

global.region=${REGION:CEE}
global.country=${COUNTRY:Romania}
PROPS

  build_and_deploy || return 1
  wait_rollout || return 1

  local url; url="https://$(oc get route tutorial-app -o jsonpath='{.spec.host}')"
  curl -s "$url/messages" >/dev/null
  local before; before=$(curl -s "$url/q/metrics" | grep '^http_get_requests_total' | head -1)
  say "$before"
  expect "default tags from application.properties" 'country="Romania"' "$before"
  expect "profile tag resolves to prod in the container" 'profile="prod"' "$before"

  banner "Override the tags with a ConfigMap"
  oc delete cm country-nl --ignore-not-found >/dev/null
  run oc create cm country-nl --from-literal=region=Europe --from-literal=country=Netherlands
  run oc set env --from=configmap/country-nl deployment/tutorial-app
  run oc rollout status deployment/tutorial-app --timeout=300s

  wait_for 120 "route answers after the rollout" curl -sf -o /dev/null "$url/messages"
  curl -s "$url/messages" >/dev/null
  local after; after=$(curl -s "$url/q/metrics" | grep '^http_get_requests_total' | head -1)
  say "$after"
  expect "country tag overridden by the ConfigMap" 'country="Netherlands"' "$after"
  expect "region tag overridden by the ConfigMap"  'region="Europe"'       "$after"

  check "ServiceMonitor generated for Prometheus scraping" oc get servicemonitor tutorial-app
}

# =============================================================================== 12
step_limits_demos() {
  banner "Not enough resources — the Pod should stay Pending (or be refused by the quota)"
  run kubectl apply -f "$KUBEFILES/not-enough-resources-deployment.yaml"
  sleep 20
  run kubectl get pods -l app=quarkus-next-5 || true
  local phase quota_err
  phase=$(kubectl get pods -l app=quarkus-next-5 -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
  quota_err=$(kubectl get events --field-selector reason=FailedCreate -o json 2>/dev/null \
    | jq -r '.items[-5:][]?.message // empty' | grep -c "exceeded quota" || true)
  if [[ "$phase" == "Pending" ]]; then
    ok "Pod is Pending — the scheduler cannot place it"
    kubectl describe pod -l app=quarkus-next-5 2>/dev/null | sed -n '/Events:/,$p' | sed 's/^/    /'
  elif (( quota_err > 0 )); then
    ok "ReplicaSet refused by the ResourceQuota admission plugin (the NOTE in monitoring.adoc)"
    kubectl get events --field-selector reason=FailedCreate -o json | jq -r '.items[-1].message' | sed 's/^/    /'
  else
    bad "expected Pending or a quota rejection, got phase='$phase'"
  fi
  run kubectl delete -f "$KUBEFILES/not-enough-resources-deployment.yaml" --ignore-not-found

  banner "Exceeding the memory limit — the container should be OOMKilled"
  if [[ "$SKIP_SLOW" == "1" ]]; then
    note "SKIP_SLOW=1 — skipping the OOMKill wait"
  else
    run kubectl apply -f "$KUBEFILES/oom-killed-deployment.yaml"
    wait_for 180 "memconsume pod is running" \
      bash -c "kubectl get pods -l app=memconsume -o jsonpath='{.items[0].status.containerStatuses[0].ready}' | grep -q true"
    local pod; pod=$(kubectl get pods -l app=memconsume -o jsonpath='{.items[0].metadata.name}')
    say "asking $pod to consume memory"
    kubectl exec "$pod" -- curl -s --max-time 30 localhost:8080/consume >/dev/null 2>&1 || true
    if wait_for 420 "container was OOMKilled" \
         bash -c "kubectl get pod $pod -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' | grep -q OOMKilled"; then
      kubectl get pod "$pod" -o jsonpath='{.status.containerStatuses[0].lastState.terminated}' | jq . | sed 's/^/    /'
    fi
    run kubectl delete -f "$KUBEFILES/oom-killed-deployment.yaml" --ignore-not-found
  fi

  banner "Overcommitment — both Pods run even though their limits exceed the node memory"
  run kubectl apply -f "$KUBEFILES/sum-exceeding-deployments.yaml"
  sleep 25
  run kubectl get pods -l 'app in (quarkus-next-5,quarkus-next-6)' || true
  local running; running=$(kubectl get pods -l 'app in (quarkus-next-5,quarkus-next-6)' \
    -o jsonpath='{.items[*].status.phase}' | tr ' ' '\n' | grep -c Running || true)
  if (( running >= 1 )); then
    ok "$running Pod(s) Running — limits do not affect scheduling, only runtime"
  else
    bad "expected the overcommitted Pods to be scheduled, none is Running"
  fi
  run kubectl delete -f "$KUBEFILES/sum-exceeding-deployments.yaml" --ignore-not-found

  banner "Containers without a resources section — the LimitRange injects defaults"
  run kubectl apply -f "$KUBEFILES/deployment-resources-limits.yaml"
  run kubectl apply -f "$KUBEFILES/no-resources-section-deployment.yaml"
  run kubectl apply -f "$KUBEFILES/no-resources-section-deployment-2.yaml"
  sleep 25
  run kubectl get pods -l 'app in (memconsume,quarkus-next-5,quarkus-next-6)' || true
  local injected; injected=$(kubectl get pod -l app=quarkus-next-5 \
    -o jsonpath='{.items[0].spec.containers[0].resources}' 2>/dev/null || echo "{}")
  say "resources on a Pod that declares none: $injected"
  if [[ "$injected" == "{}" || -z "$injected" ]]; then
    note "nothing injected — this cluster has no LimitRange, so the 'unless' PromQL query will list these containers"
  else
    ok "LimitRange injected defaults — an empty result from the 'unless' query is the expected outcome"
  fi

  note "Paste these into Observe -> Metrics with the Project selector on $NAMESPACE:"
  printf '    %s\n' \
    "(count by (namespace,pod,container)(kube_pod_container_info{container!=\"\", namespace='$NAMESPACE'}) unless sum by (namespace,pod,container)(kube_pod_container_resource_limits{resource=\"memory\"}))" \
    "topk(10, sum by (pod,container)(container_memory_usage_bytes{container!=\"\", container!=\"POD\", namespace='$NAMESPACE'}))" \
    "100 * sum(kube_pod_container_resource_limits{container!=\"\",resource=\"memory\", namespace='$NAMESPACE'}) / sum(kube_resourcequota{namespace='$NAMESPACE', resource='limits.memory', type='hard'})"

  run kubectl delete -f "$KUBEFILES/no-resources-section-deployment.yaml" --ignore-not-found
  run kubectl delete -f "$KUBEFILES/no-resources-section-deployment-2.yaml" --ignore-not-found
  run kubectl delete -f "$KUBEFILES/deployment-resources-limits.yaml" --ignore-not-found
}

# =============================================================================== 13
step_hpa() {
  run kubectl apply -f "$KUBEFILES/deployment-prime.yaml"
  oc get route bs-mem-mgnt >/dev/null 2>&1 || run oc expose service/bs-mem-mgnt
  run oc get route bs-mem-mgnt
  run kubectl apply -f "$KUBEFILES/hpa.yaml"

  wait_for 240 "bs-mem-mgnt is ready" \
    bash -c "kubectl get pods -l app.kubernetes.io/name=bs-mem-mgnt -o jsonpath='{.items[0].status.containerStatuses[0].ready}' | grep -q true"

  local url; url="http://$(oc get route bs-mem-mgnt -o jsonpath='{.spec.host}')"
  wait_for 120 "route answers /hello/prime" curl -sf -o /dev/null "$url/hello/prime"

  banner "Generate load so the HPA reacts"
  run hey -c 10 -z 15s "$url/hello/prime" | sed -n '1,12p'

  say "waiting for the autoscaler to react"
  local deadline=$(( SECONDS + 180 )) replicas=1
  while (( SECONDS < deadline )); do
    replicas=$(kubectl get deployment bs-mem-mgnt -o jsonpath='{.status.replicas}' 2>/dev/null || echo 1)
    (( replicas > 1 )) && break
    sleep 10
  done
  run kubectl get hpa
  run kubectl get pods -l app.kubernetes.io/name=bs-mem-mgnt
  if (( replicas > 1 )); then
    ok "scaled to $replicas replicas"
  else
    bad "still at $replicas replica after 3 minutes — check that metrics-server data is available"
  fi

  note "Scaling down uses a 5 minute stabilization window, so the replica count stays high for a while."
  run kubectl delete -f "$KUBEFILES/hpa.yaml" --ignore-not-found
  run kubectl delete -f "$KUBEFILES/deployment-prime.yaml" --ignore-not-found
  run oc delete route bs-mem-mgnt --ignore-not-found
}

# =============================================================================== 14
step_cleanup() {
  note "Removing every object this rehearsal created in $NAMESPACE."
  note "Nothing else in the project is touched — do NOT use 'oc delete all --all'."

  for f in not-enough-resources-deployment oom-killed-deployment sum-exceeding-deployments \
           no-resources-section-deployment no-resources-section-deployment-2 \
           deployment-resources-limits deployment-resources-limits-2 \
           exceeding-limits-deployment my-auto-deployment deployment-prime hpa; do
    [ -f "$KUBEFILES/$f.yaml" ] && kubectl delete -f "$KUBEFILES/$f.yaml" --ignore-not-found >/dev/null 2>&1 || true
  done
  oc delete route bs-mem-mgnt --ignore-not-found >/dev/null 2>&1 || true

  run oc delete deployment,svc,route,serviceaccount,rolebinding,servicemonitor,bc,is \
    -l app.kubernetes.io/name=tutorial-app --ignore-not-found || true
  run oc delete cm country-nl --ignore-not-found || true
  run oc delete is "$IMAGE_NAME" --ignore-not-found || true
  run oc delete all,secret,cm,pvc -l template=postgresql-ephemeral-template --ignore-not-found || true

  say "leftovers in $NAMESPACE (should be empty of tutorial objects):"
  oc get deployment,dc,svc,route,hpa 2>/dev/null | sed 's/^/    /' || true
  note "Scratch directory kept at $WORKDIR — remove it with: rm -rf $WORKDIR"
}

# ----------------------------------------------------------------------------- driver
usage() {
  echo "usage: $(basename "$0") [--list] [--from N] [--only N[,N...]] [--cleanup] [--help]"
  echo
  echo "steps:"
  for i in "${!STEP_IDS[@]}"; do printf '  %2d  %-14s %s\n' $((i+1)) "${STEP_IDS[$i]}" "${STEP_DESC[$i]}"; done
}

SELECTED=()
FROM=1
case "${1:-}" in
  --list|-l) usage; exit 0 ;;
  --help|-h) usage; exit 0 ;;
  --cleanup) SELECTED=(14) ;;
  --from)    FROM=${2:?--from needs a step number} ;;
  --only)    IFS=',' read -r -a SELECTED <<< "${2:?--only needs step numbers}" ;;
  "")        ;;
  *)         usage; exit 2 ;;
esac

if (( ${#SELECTED[@]} == 0 )); then
  for ((i=FROM; i<=${#STEP_IDS[@]}; i++)); do SELECTED+=("$i"); done
fi

# Steps other than preflight still need NAMESPACE resolved.
: "${NAMESPACE:=$(oc project -q 2>/dev/null || true)}"
[ -n "$NAMESPACE" ] || die "no project selected — run 'oc login' and 'oc project <ns>'"
export NAMESPACE

START=$SECONDS
printf '%s%s Efficient Resource Management — rehearsal %s\n' "$B$C" "═══" "$Z" >&2
say "project      $NAMESPACE"
say "workdir      $WORKDIR"
say "image mode   $IMAGE_MODE$( [[ $IMAGE_MODE == quay ]] && echo " (${REGISTRY}/${REGISTRY_ORG}/${IMAGE_NAME})" )"
say "quarkus      $QUARKUS_VERSION"

for n in "${SELECTED[@]}"; do
  idx=$((n-1))
  [ -n "${STEP_IDS[$idx]:-}" ] || die "no such step: $n"
  CURRENT_STEP="${STEP_IDS[$idx]}"
  banner "Step $n/${#STEP_IDS[@]} — ${STEP_DESC[$idx]}"
  fn="step_${STEP_IDS[$idx]//-/_}"
  if ! "$fn"; then
    bad "step '${CURRENT_STEP}' returned a non-zero status"
  fi
done

CURRENT_STEP=""
ELAPSED=$((SECONDS-START))
printf '\n%s%s summary %s\n' "$B$C" "═══" "$Z" >&2
printf 'elapsed: %dm%02ds\n' $((ELAPSED/60)) $((ELAPSED%60)) >&2
if (( ${#FAILURES[@]} )); then
  printf '%s%d check(s) failed:%s\n' "$R$B" "${#FAILURES[@]}" "$Z" >&2
  printf '  %s\n' "${FAILURES[@]}" >&2
  exit 1
fi
printf '%sall checks passed%s\n' "$G$B" "$Z" >&2
