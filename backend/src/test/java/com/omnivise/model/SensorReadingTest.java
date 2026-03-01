package com.omnivise.model;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

/**
 * Unit tests for the SensorReading record.
 * Tests the immutability and accessor methods of the data model.
 */
public class SensorReadingTest {

    @Test
    void testSensorReadingCreation() {
        // Given
        String sensorId = "sensor-001";
        String type = "temperature";
        Object value = 25.5;
        String unit = "C";
        String location = "Office Room 1";
        String timestamp = "2026-03-01T12:00:00Z";

        // When
        SensorReading reading = new SensorReading(sensorId, type, value, unit, location, timestamp);

        // Then
        assertEquals(sensorId, reading.sensorId());
        assertEquals(type, reading.type());
        assertEquals(value, reading.value());
        assertEquals(unit, reading.unit());
        assertEquals(location, reading.location());
        assertEquals(timestamp, reading.timestamp());
    }

    @Test
    void testSensorReadingWithBooleanValue() {
        // Given
        Boolean motionValue = true;

        // When
        SensorReading motionReading = new SensorReading(
                "sensor-042",
                "motion",
                motionValue,
                "boolean",
                "Entrance",
                "2026-03-01T12:30:00Z");

        // Then
        assertEquals("motion", motionReading.type());
        assertEquals(true, motionReading.value());
    }

    @Test
    void testSensorReadingEquality() {
        // Given
        SensorReading reading1 = new SensorReading(
                "sensor-001",
                "temperature",
                25.5,
                "C",
                "Office Room 1",
                "2026-03-01T12:00:00Z");

        SensorReading reading2 = new SensorReading(
                "sensor-001",
                "temperature",
                25.5,
                "C",
                "Office Room 1",
                "2026-03-01T12:00:00Z");

        // Then
        assertEquals(reading1, reading2);
    }

    @Test
    void testSensorReadingToString() {
        // Given
        SensorReading reading = new SensorReading(
                "sensor-001",
                "temperature",
                22.5,
                "C",
                "Office",
                "2026-03-01T12:00:00Z");

        // When
        String result = reading.toString();

        // Then
        assertTrue(result.contains("sensor-001"));
        assertTrue(result.contains("temperature"));
        assertTrue(result.contains("22.5"));
    }
}
