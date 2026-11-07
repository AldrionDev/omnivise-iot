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
}
