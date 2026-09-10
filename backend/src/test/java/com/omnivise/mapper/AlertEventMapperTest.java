package com.omnivise.mapper;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.time.Instant;
import java.util.Date;

import org.bson.Document;
import org.bson.types.ObjectId;
import org.junit.jupiter.api.Test;

import com.omnivise.model.AlertEvent;

/**
 * The single {@code Document <-> AlertEvent} mapper (issue #73).
 *
 * <p>Both the hot path ({@code AlertEvaluator} inserts) and the read paths
 * (REST + startup recovery) go through here. Stored dates are BSON {@code Date};
 * the {@link AlertEvent} carries ISO-8601 UTC strings so JSON stays
 * dependency-free (same convention as {@code SensorReadingMapper}).
 * {@code resolvedAt} is present only for a resolved event.
 */
class AlertEventMapperTest {

    private static Document firingDoc() {
        return new Document("_id", new ObjectId("64b7f0000000000000000001"))
                .append("ruleId", "ups-input-voltage-low")
                .append("deviceId", "ups-1")
                .append("channel", "input_voltage")
                .append("severity", "critical")
                .append("state", "firing")
                .append("triggeredValue", 2.1)
                .append("lastValue", 1.8)
                .append("startedAt", Date.from(Instant.parse("2026-09-10T08:03:15Z")));
    }

    @Test
    void mapsAFiringDocumentWithNoResolvedAt() {
        AlertEvent event = AlertEventMapper.fromDocument(firingDoc());

        assertEquals("64b7f0000000000000000001", event.id());
        assertEquals("ups-input-voltage-low", event.ruleId());
        assertEquals("ups-1", event.deviceId());
        assertEquals("input_voltage", event.channel());
        assertEquals("critical", event.severity());
        assertEquals("firing", event.state());
        assertEquals(2.1, event.triggeredValue());
        assertEquals(1.8, event.lastValue());
        assertEquals("2026-09-10T08:03:15Z", event.startedAt());
        assertNull(event.resolvedAt());
    }

    @Test
    void mapsAResolvedDocumentIncludingResolvedAt() {
        Document doc = firingDoc()
                .append("state", "resolved")
                .append("resolvedAt", Date.from(Instant.parse("2026-09-10T08:06:40Z")));

        AlertEvent event = AlertEventMapper.fromDocument(doc);

        assertEquals("resolved", event.state());
        assertEquals("2026-09-10T08:06:40Z", event.resolvedAt());
    }

    @Test
    void toDocumentOmitsIdForANewEventAndStoresDatesAsBsonDate() {
        AlertEvent event = new AlertEvent(null, "rack-intake-temp-high", "rack-a1", "intake_temp",
                "warning", "firing", 34.7, 34.7, "2026-09-10T08:00:00Z", null);

        Document doc = AlertEventMapper.toDocument(event);

        assertFalse(doc.containsKey("_id"), "a new event has no id yet");
        assertFalse(doc.containsKey("resolvedAt"), "a firing event has no resolvedAt");
        assertInstanceOf(Date.class, doc.get("startedAt"));
        assertEquals(Date.from(Instant.parse("2026-09-10T08:00:00Z")), doc.get("startedAt"));
        assertEquals("rack-intake-temp-high", doc.getString("ruleId"));
        assertEquals(34.7, doc.get("triggeredValue"));
    }

    @Test
    void toDocumentKeepsTheIdAndResolvedAtForAResolvedEvent() {
        AlertEvent event = new AlertEvent("64b7f0000000000000000001", "ups-battery-low", "ups-1",
                "battery_pct", "critical", "resolved", 88.0, 98.5,
                "2026-09-10T08:00:00Z", "2026-09-10T08:12:00Z");

        Document doc = AlertEventMapper.toDocument(event);

        assertEquals(new ObjectId("64b7f0000000000000000001"), doc.get("_id"));
        assertInstanceOf(Date.class, doc.get("resolvedAt"));
        assertEquals(Date.from(Instant.parse("2026-09-10T08:12:00Z")), doc.get("resolvedAt"));
    }

    @Test
    void roundTripsAResolvedEventThroughADocument() {
        AlertEvent original = new AlertEvent("64b7f0000000000000000001", "ups-battery-low", "ups-1",
                "battery_pct", "critical", "resolved", 88.0, 98.5,
                "2026-09-10T08:00:00Z", "2026-09-10T08:12:00Z");

        assertEquals(original, AlertEventMapper.fromDocument(AlertEventMapper.toDocument(original)));
    }
}
