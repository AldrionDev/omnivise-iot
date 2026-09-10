package com.omnivise.handler;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.omnivise.model.AlertEvent;

import org.junit.jupiter.api.Test;

/**
 * The typed WebSocket envelope for an alert state transition (issue #73).
 *
 * <p>Shares the socket with live readings via the {@code kind} discriminator:
 * clients receive {@code { "kind": "alert", "payload": { ...alert_event... } }}.
 */
class AlertMessageTest {

    private final ObjectMapper objectMapper = new ObjectMapper();

    private static AlertEvent firing() {
        return new AlertEvent("64b7f0000000000000000001", "ups-input-voltage-low", "ups-1",
                "input_voltage", "critical", "firing", 2.1, 1.8, "2026-09-10T08:03:15Z", null);
    }

    @Test
    void serialisesAsAKindAlertEnvelopeWithTheEventNestedUnderPayload() throws Exception {
        JsonNode json = objectMapper.readTree(
                objectMapper.writeValueAsString(AlertMessage.of(firing())));

        assertEquals("alert", json.get("kind").asText());
        JsonNode payload = json.get("payload");
        assertEquals("64b7f0000000000000000001", payload.get("id").asText());
        assertEquals("ups-input-voltage-low", payload.get("ruleId").asText());
        assertEquals("ups-1", payload.get("deviceId").asText());
        assertEquals("input_voltage", payload.get("channel").asText());
        assertEquals("critical", payload.get("severity").asText());
        assertEquals("firing", payload.get("state").asText());
        assertEquals(2.1, payload.get("triggeredValue").asDouble());
        assertEquals(1.8, payload.get("lastValue").asDouble());
        assertEquals("2026-09-10T08:03:15Z", payload.get("startedAt").asText());
        assertTrue(payload.get("resolvedAt").isNull(), "a firing event serialises resolvedAt as null");
    }

    @Test
    void factoryAlwaysStampsTheAlertKind() {
        assertEquals("alert", AlertMessage.of(firing()).kind());
    }

    @Test
    void aResolvedEventCarriesResolvedAt() throws Exception {
        AlertEvent resolved = new AlertEvent("64b7f0000000000000000001", "ups-input-voltage-low",
                "ups-1", "input_voltage", "critical", "resolved", 2.1, 231.4,
                "2026-09-10T08:03:15Z", "2026-09-10T08:06:40Z");

        JsonNode payload = objectMapper.readTree(
                objectMapper.writeValueAsString(AlertMessage.of(resolved))).get("payload");

        assertFalse(payload.get("resolvedAt").isNull());
        assertEquals("2026-09-10T08:06:40Z", payload.get("resolvedAt").asText());
    }
}
