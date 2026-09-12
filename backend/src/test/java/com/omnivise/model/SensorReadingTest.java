package com.omnivise.model;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

/**
 * Unit tests for the reshaped {@link SensorReading} record (issue #70).
 *
 * <p>A reading is keyed by {@code deviceId} + {@code channel}; {@code value} is
 * an opaque {@link Object} (numeric or boolean); {@code timestamp} is an
 * ISO-8601 string produced by the shared mapper from a BSON {@code Date}.
 */
public class SensorReadingTest {

    @Test
    void exposesEveryComponentThroughItsAccessor() {
        Object value = 22.4;

        SensorReading reading = new SensorReading(
                "rack-a1",
                "intake_temp",
                value,
                "°C",
                "2026-09-10T08:00:00Z");

        assertEquals("rack-a1", reading.deviceId());
        assertEquals("intake_temp", reading.channel());
        assertEquals(value, reading.value());
        assertEquals("°C", reading.unit());
        assertEquals("2026-09-10T08:00:00Z", reading.timestamp());
    }

    @Test
    void preservesABooleanChannelValue() {
        SensorReading reading = new SensorReading(
                "rack-a1",
                "door_contact",
                Boolean.TRUE,
                "state",
                "2026-09-10T08:30:00Z");

        assertEquals("door_contact", reading.channel());
        assertEquals(true, reading.value());
    }

    @Test
    void equalityIsByValue() {
        SensorReading a = new SensorReading("ups-1", "load_pct", 41.0, "%", "2026-09-10T08:00:00Z");
        SensorReading b = new SensorReading("ups-1", "load_pct", 41.0, "%", "2026-09-10T08:00:00Z");

        assertEquals(a, b);
    }

    @Test
    void toStringCarriesTheKeyAndValue() {
        SensorReading reading = new SensorReading(
                "pdu-a1", "power_draw", 1200, "W", "2026-09-10T08:00:00Z");

        String result = reading.toString();

        assertTrue(result.contains("pdu-a1"));
        assertTrue(result.contains("power_draw"));
        assertTrue(result.contains("1200"));
    }
}
