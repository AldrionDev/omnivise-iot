package com.omnivise.webhook;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.net.URI;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionStage;
import java.util.concurrent.CopyOnWriteArrayList;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.omnivise.model.AlertEvent;

import org.junit.jupiter.api.Test;

/**
 * The optional outbound webhook (issue #73).
 *
 * <p>{@code ALERT_WEBHOOK_URL} unset/blank -> disabled (a no-op). A non-blank
 * but invalid URL is a configuration error and fails construction. When
 * configured, {@code dispatch} builds the approved compact payload and hands it
 * to an <em>asynchronous</em> {@link WebhookSender}
 * ({@code CompletionStage<Void>}); it never blocks on the result and swallows
 * every failure — a slow or failing endpoint must not delay or break alert
 * evaluation.
 */
class AlertWebhookTest {

    private final ObjectMapper mapper = new ObjectMapper();

    private static AlertEvent firing() {
        return new AlertEvent("64b7f0000000000000000001", 17L, "ups-input-voltage-low", "ups-1",
                "input_voltage", "critical", "firing", 2.1, 1.8, "2026-09-10T08:03:15Z", null);
    }

    private static AlertEvent resolved() {
        return new AlertEvent("64b7f0000000000000000001", 18L, "ups-input-voltage-low", "ups-1",
                "input_voltage", "critical", "resolved", 2.1, 231.4,
                "2026-09-10T08:03:15Z", "2026-09-10T08:06:40Z");
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    @Test
    void anUnsetOrBlankUrlProducesADisabledWebhookThatDoesNothing() {
        for (String raw : new String[] {null, "", "   "}) {
            AlertWebhook webhook = AlertWebhook.fromConfig(raw);
            assertInstanceOf(DisabledAlertWebhook.class, webhook);
            assertDoesNotThrow(() -> webhook.dispatch(firing()));
        }
    }

    @Test
    void aNonBlankButInvalidUrlFailsConstruction() {
        for (String bad : new String[] {"not a url", "ftp://example.com/hook", "/relative/only", "http://"}) {
            assertThrows(IllegalStateException.class, () -> AlertWebhook.fromConfig(bad),
                    "should reject: " + bad);
        }
    }

    @Test
    void aValidHttpUrlProducesAnHttpWebhook() {
        assertInstanceOf(HttpAlertWebhook.class,
                AlertWebhook.fromConfig("https://hooks.example.com/omnivise"));
    }

    // ------------------------------------------------------------------
    // Payload
    // ------------------------------------------------------------------

    @Test
    void dispatchPostsTheApprovedFiringPayloadToTheConfiguredUrl() throws Exception {
        RecordingSender sender = new RecordingSender();
        new HttpAlertWebhook(URI.create("https://hooks.example.com/omnivise"), sender).dispatch(firing());

        assertEquals(1, sender.calls.size());
        assertEquals(URI.create("https://hooks.example.com/omnivise"), sender.calls.get(0).url());

        JsonNode body = mapper.readTree(sender.calls.get(0).body());
        assertEquals("firing", body.get("event").asText());
        assertEquals("ups-input-voltage-low", body.get("ruleId").asText());
        assertEquals("critical", body.get("severity").asText());
        assertEquals("ups-1", body.get("deviceId").asText());
        assertEquals("input_voltage", body.get("channel").asText());
        assertEquals(2.1, body.get("value").asDouble(), "firing reports triggeredValue");
        assertEquals("2026-09-10T08:03:15Z", body.get("startedAt").asText());
        assertEquals("64b7f0000000000000000001", body.get("alertId").asText());
        assertFalse(body.has("resolvedAt"), "no resolvedAt on a firing payload");
    }

    @Test
    void dispatchPostsAResolvedPayloadWithResolvedAtAndTheClearingValue() throws Exception {
        RecordingSender sender = new RecordingSender();
        new HttpAlertWebhook(URI.create("https://hooks.example.com/omnivise"), sender).dispatch(resolved());

        JsonNode body = mapper.readTree(sender.calls.get(0).body());
        assertEquals("resolved", body.get("event").asText());
        assertEquals(231.4, body.get("value").asDouble(), "resolved reports lastValue");
        assertEquals("2026-09-10T08:06:40Z", body.get("resolvedAt").asText());
    }

    // ------------------------------------------------------------------
    // Non-blocking + failure-swallowing
    // ------------------------------------------------------------------

    @Test
    void dispatchDoesNotWaitForASlowSenderToComplete() {
        WebhookSender neverCompletes = (url, body) -> new CompletableFuture<>();
        HttpAlertWebhook webhook =
                new HttpAlertWebhook(URI.create("https://hooks.example.com/omnivise"), neverCompletes);

        assertTimeoutPreemptively(Duration.ofSeconds(1), () -> webhook.dispatch(firing()));
    }

    @Test
    void anExceptionallyCompletedSendIsSwallowed() {
        WebhookSender failing = (url, body) ->
                CompletableFuture.failedFuture(new RuntimeException("HTTP 503"));
        HttpAlertWebhook webhook =
                new HttpAlertWebhook(URI.create("https://hooks.example.com/omnivise"), failing);

        assertDoesNotThrow(() -> webhook.dispatch(firing()));
    }

    @Test
    void aSynchronousSenderExceptionIsSwallowed() {
        WebhookSender throwing = (url, body) -> {
            throw new IllegalArgumentException("bad request");
        };
        HttpAlertWebhook webhook =
                new HttpAlertWebhook(URI.create("https://hooks.example.com/omnivise"), throwing);

        assertDoesNotThrow(() -> webhook.dispatch(firing()));
    }

    @Test
    void buildPayloadIsStableAndOmitsResolvedAtForFiring() throws Exception {
        JsonNode firingBody = mapper.readTree(HttpAlertWebhook.buildPayload(firing()));
        JsonNode resolvedBody = mapper.readTree(HttpAlertWebhook.buildPayload(resolved()));

        assertTrue(firingBody.has("event") && firingBody.has("alertId"));
        assertFalse(firingBody.has("resolvedAt"));
        assertTrue(resolvedBody.has("resolvedAt"));
    }

    // ------------------------------------------------------------------

    private record Call(URI url, String body) {
    }

    private static final class RecordingSender implements WebhookSender {
        final List<Call> calls = new CopyOnWriteArrayList<>();

        @Override
        public CompletionStage<Void> send(URI url, String jsonBody) {
            calls.add(new Call(url, jsonBody));
            return CompletableFuture.completedFuture(null);
        }
    }
}
