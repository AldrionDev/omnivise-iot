package com.omnivise.handler;

import static org.junit.jupiter.api.Assertions.assertEquals;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.omnivise.model.SensorReading;

import org.junit.jupiter.api.Test;

/**
 * The typed WebSocket envelope for live readings (issue #70).
 *
 * <p>Clients must receive {@code { "kind": "reading", "payload": { ... } }} with
 * the reading fields nested under {@code payload}.
 */
class ReadingMessageTest {

    private final ObjectMapper objectMapper = new ObjectMapper();

    @Test
    void serialisesAsAKindReadingEnvelopeWithTheReadingNestedUnderPayload() throws Exception {
        SensorReading reading = new SensorReading(
                "rack-a1", "intake_temp", 22.4, "°C", "2026-09-10T08:00:00Z");

        JsonNode json = objectMapper.readTree(objectMapper.writeValueAsString(ReadingMessage.of(reading)));

        assertEquals("reading", json.get("kind").asText());
        JsonNode payload = json.get("payload");
        assertEquals("rack-a1", payload.get("deviceId").asText());
        assertEquals("intake_temp", payload.get("channel").asText());
        assertEquals(22.4, payload.get("value").asDouble());
        assertEquals("°C", payload.get("unit").asText());
        assertEquals("2026-09-10T08:00:00Z", payload.get("timestamp").asText());
    }

    @Test
    void factoryAlwaysStampsTheReadingKind() {
        ReadingMessage message = ReadingMessage.of(
                new SensorReading("ups-1", "load_pct", 41, "%", "2026-09-10T08:00:00Z"));

        assertEquals("reading", message.kind());
    }
}
