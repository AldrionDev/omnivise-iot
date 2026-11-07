package com.omnivise;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.junit.jupiter.api.Test;

import io.javalin.Javalin;
import io.javalin.micrometer.MicrometerPlugin;
import io.micrometer.core.instrument.Timer;

/**
 * Unit tests for {@link Main#resolveMongoUri}.
 *
 * <p>
 * An explicit non-empty {@code MONGO_URI} is authoritative. When it is absent
 * or empty, the legacy host/port/user/password URI construction is used, and
 * authentication is only added when both a username and a password are present.
 */
class MainTest {

    @Test
    void mongoDatabaseDefaultsOnlyWhenMissing() {
        assertEquals("omnivise_iot", Main.resolveMongoDatabase(null));
        assertEquals("omnivise_iot_test", Main.resolveMongoDatabase("omnivise_iot_test"));
    }

    @Test
    void mongoDatabaseRejectsBlankValues() {
        assertThrows(IllegalArgumentException.class, () -> Main.resolveMongoDatabase(""));
        assertThrows(IllegalArgumentException.class, () -> Main.resolveMongoDatabase("   "));
    }

    @Test
    void explicitMongoUriTakesPrecedenceOverLegacyFields() {
        assertEquals(
                "mongodb://mongodb:27017/?replicaSet=rs0",
                Main.resolveMongoUri(
                        "mongodb://mongodb:27017/?replicaSet=rs0",
                        "legacy-host",
                        "27018",
                        "legacy-user",
                        "legacy-password"));
    }

    @Test
    void userAndPasswordProduceAuthenticatedLegacyUri() {
        assertEquals(
                "mongodb://legacy-user:legacy-password@mongo-host:27019/?directConnection=true",
                Main.resolveMongoUri(
                        "",
                        "mongo-host",
                        "27019",
                        "legacy-user",
                        "legacy-password"));
    }

    @Test
    void hostOnlyConfigurationProducesUnauthenticatedLegacyUri() {
        assertEquals(
                "mongodb://localhost:27017",
                Main.resolveMongoUri(
                        null,
                        "localhost",
                        "27017",
                        null,
                        null));
    }

    @Test
    void emptyMongoUriFallsBackToUnauthenticatedLegacyUri() {
        assertEquals(
                "mongodb://mongo-host:27019",
                Main.resolveMongoUri(
                        "",
                        "mongo-host",
                        "27019",
                        null,
                        null));
    }

    @Test
    void incompleteLegacyCredentialsFallBackToUnauthenticatedLegacyUri() {
        assertEquals(
                "mongodb://mongo-host:27019",
                Main.resolveMongoUri(
                        null,
                        "mongo-host",
                        "27019",
                        "legacy-user",
                        ""));
    }

    @Test
    void clampLimitKeepsAnInRangeValueUnchanged() {
        assertEquals(50, Main.clampLimit(50));
    }

    @Test
    void clampLimitRaisesANonPositiveValueToOne() {
        assertEquals(1, Main.clampLimit(0));
        assertEquals(1, Main.clampLimit(-10));
    }

    @Test
    void clampLimitCapsAnExcessiveValueAtFiveHundred() {
        assertEquals(500, Main.clampLimit(10_000));
    }

    @Test
    void metricsRegistryExposesJvmAndProcessMetrics() {
        try (Main.MetricsResources metricsResources = Main.createMetricsResources()) {
            String scrape = metricsResources.registry().scrape();

            assertTrue(scrape.contains("jvm_memory_used_bytes"));
            assertTrue(scrape.contains("jvm_threads_live_threads"));
            assertTrue(scrape.contains("process_cpu_usage"));
            assertTrue(scrape.contains("system_cpu_usage"));
        }
    }

    @Test
    void httpRequestMetricsUseApprovedLatencyBuckets() {
        try (Main.MetricsResources metricsResources = Main.createMetricsResources()) {
            Timer timer = Timer.builder("jetty.server.requests")
                    .tag("method", "GET")
                    .tag("status", "200")
                    .tag("uri", "/test")
                    .register(metricsResources.registry());

            timer.record(Duration.ofMillis(20));

            String scrape = metricsResources.registry().scrape();

            assertTrue(scrape.contains("le=\"0.01\""));
            assertTrue(scrape.contains("le=\"0.025\""));
            assertTrue(scrape.contains("le=\"0.05\""));
            assertTrue(scrape.contains("le=\"0.1\""));
            assertTrue(scrape.contains("le=\"0.25\""));
            assertTrue(scrape.contains("le=\"0.5\""));
            assertTrue(scrape.contains("le=\"1.0\""));
        }
    }

    @Test
    void httpMetricsKeepUriCardinalityBounded() throws Exception {
        try (Main.MetricsResources metricsResources = Main.createMetricsResources()) {
            Javalin app = Javalin.create(config -> {
                config.registerPlugin(new MicrometerPlugin(pluginConfig -> {
                    pluginConfig.registry = metricsResources.registry();
                }));
                config.showJavalinBanner = false;
            });

            app.get("/api/devices/{deviceId}", ctx -> ctx.result("ok"));
            app.get("/api/sensors/latest", ctx -> ctx.result("ok"));

            app.start(0);

            try {
                HttpClient client = HttpClient.newHttpClient();
                String baseUrl = "http://localhost:" + app.port();

                // Baseline: one request per declared URI category to establish the
                // full set of jetty_server_requests_seconds_count series.
                client.send(
                        HttpRequest.newBuilder()
                                .uri(URI.create(baseUrl + "/api/devices/device-0"))
                                .GET().build(),
                        HttpResponse.BodyHandlers.discarding());
                client.send(
                        HttpRequest.newBuilder()
                                .uri(URI.create(baseUrl + "/random-0"))
                                .GET().build(),
                        HttpResponse.BodyHandlers.discarding());
                client.send(
                        HttpRequest.newBuilder()
                                .uri(URI.create(baseUrl + "/api/sensors/latest?q=0"))
                                .GET().build(),
                        HttpResponse.BodyHandlers.discarding());

                long baselineCountSeries = countSeriesLines(
                        metricsResources.registry().scrape(),
                        "jetty_server_requests_seconds_count{");

                // Stress load: 150 varied requests across 50 raw device IDs, 50
                // random paths, and 50 query-string variations.
                for (int i = 1; i <= 50; i++) {
                    client.send(
                            HttpRequest.newBuilder()
                                    .uri(URI.create(baseUrl + "/api/devices/device-" + i))
                                    .GET()
                                    .build(),
                            HttpResponse.BodyHandlers.discarding());
                }

                for (int i = 1; i <= 50; i++) {
                    client.send(
                            HttpRequest.newBuilder()
                                    .uri(URI.create(baseUrl + "/random-" + i))
                                    .GET()
                                    .build(),
                            HttpResponse.BodyHandlers.discarding());
                }

                for (int i = 1; i <= 50; i++) {
                    client.send(
                            HttpRequest.newBuilder()
                                    .uri(URI.create(
                                            baseUrl
                                                    + "/api/sensors/latest"
                                                    + "?deviceId=device-" + i
                                                    + "&limit=" + ((i % 10) + 1)
                                                    + "&q=random-" + i))
                                    .GET()
                                    .build(),
                            HttpResponse.BodyHandlers.discarding());
                }

                String scrape = metricsResources.registry().scrape();

                // Series-count assertion: _count series (excludes _bucket le= rows) must
                // not grow beyond the baseline established by the three URI categories.
                long postStressCountSeries = countSeriesLines(scrape,
                        "jetty_server_requests_seconds_count{");
                assertEquals(baselineCountSeries, postStressCountSeries,
                        "jetty_server_requests_seconds_count series count must not increase after stress load");

                // URI value set must be exactly the declared bounded set.
                Set<String> uriValues = new java.util.HashSet<>();
                Matcher m = Pattern.compile("uri=\"([^\"]+)\"").matcher(scrape);
                while (m.find()) {
                    uriValues.add(m.group(1));
                }
                assertEquals(
                        Set.of("/api/devices/{deviceId}", "/api/sensors/latest", "NOT_FOUND"),
                        uriValues,
                        "uri label values must be exactly the declared bounded set after cardinality stress load");

                // Negative assertion: raw tokens must never appear as label values.
                assertTrue(scrape.contains("uri=\"/api/devices/{deviceId}\""));
                assertTrue(scrape.contains("uri=\"/api/sensors/latest\""));
                assertTrue(scrape.contains("uri=\"NOT_FOUND\""));

                for (int i = 1; i <= 50; i++) {
                    assertFalse(scrape.contains("uri=\"/api/devices/device-" + i + "\""));
                    assertFalse(scrape.contains("uri=\"/random-" + i + "\""));
                    assertFalse(scrape.contains("device-" + i));
                    assertFalse(scrape.contains("random-" + i));
                }
            } finally {
                app.stop();
            }
        }
    }

    private static long countSeriesLines(String scrape, String prefix) {
        return java.util.Arrays.stream(scrape.split("\n"))
                .filter(line -> line.startsWith(prefix))
                .count();
    }

    @Test
    void metricsEndpointExposesPrometheusContract() throws Exception {
        try (Main.MetricsResources metricsResources = Main.createMetricsResources()) {
            Javalin app = Javalin.create(config -> {
                config.registerPlugin(new MicrometerPlugin(pluginConfig -> {
                    pluginConfig.registry = metricsResources.registry();
                }));
                config.showJavalinBanner = false;
            });

            app.get("/api/probe", ctx -> ctx.result("ok"));
            app.get("/metrics", ctx -> {
                ctx.header("Content-Type", "text/plain; version=0.0.4; charset=utf-8");
                ctx.result(metricsResources.registry().scrape());
            });

            app.start(0);

            try {
                HttpClient client = HttpClient.newHttpClient();
                String baseUrl = "http://localhost:" + app.port();

                // Generate at least one tracked HTTP request so Jetty metrics appear.
                client.send(
                        HttpRequest.newBuilder().uri(URI.create(baseUrl + "/api/probe")).GET().build(),
                        HttpResponse.BodyHandlers.discarding());

                HttpResponse<String> response = client.send(
                        HttpRequest.newBuilder().uri(URI.create(baseUrl + "/metrics")).GET().build(),
                        HttpResponse.BodyHandlers.ofString());

                assertEquals(200, response.statusCode());
                assertTrue(
                        response.headers().firstValue("content-type").orElse("").contains("text/plain"),
                        "Content-Type must be Prometheus text format");
                assertTrue(
                        response.headers().firstValue("content-type").orElse("").contains("version=0.0.4"),
                        "Content-Type must carry Prometheus exposition version 0.0.4");

                String body = response.body();

                assertTrue(body.contains("jvm_"), "jvm_* metrics must be present");
                assertTrue(body.contains("process_"), "process_* metrics must be present");

                // HTTP request count, sum, and bucket for the /api/probe request.
                assertTrue(body.contains("jetty_server_requests_seconds_count"),
                        "HTTP request count metric must be present");
                assertTrue(body.contains("jetty_server_requests_seconds_sum"),
                        "HTTP request sum metric must be present");
                assertTrue(body.contains("jetty_server_requests_seconds_bucket"),
                        "HTTP request histogram buckets must be present");
            } finally {
                app.stop();
            }
        }
    }
}
