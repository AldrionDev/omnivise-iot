package com.omnivise.mapper;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertInstanceOf;
import static org.junit.jupiter.api.Assertions.assertNull;

import java.time.Instant;
import java.util.Date;

import org.bson.Document;
import org.junit.jupiter.api.Test;

import com.omnivise.model.SensorReading;

/**
 * The single shared {@code Document -> SensorReading} mapper (issue #70).
 *
 * <p>The mapper only understands the new {@code deviceId}/{@code channel} shape.
 * There is deliberately no fallback to the pre-cutover
 * {@code sensor_id}/{@code type}/{@code location} schema.
 */
class SensorReadingMapperTest {

    @Test
    void mapsEveryFieldOfANewShapeDocument() {
        Document doc = new Document()
                .append("deviceId", "rack-a1")
                .append("channel", "intake_temp")
                .append("value", 22.4)
                .append("unit", "°C")
                .append("timestamp", Date.from(Instant.parse("2026-09-10T08:00:00Z")));

        SensorReading reading = SensorReadingMapper.fromDocument(doc);

        assertEquals("rack-a1", reading.deviceId());
        assertEquals("intake_temp", reading.channel());
        assertEquals(22.4, reading.value());
        assertEquals("°C", reading.unit());
        assertEquals("2026-09-10T08:00:00Z", reading.timestamp());
    }

    @Test
    void convertsAStoredBsonDateToAnIso8601UtcString() {
        Document doc = baseDoc()
                .append("timestamp", Date.from(Instant.parse("2026-09-10T12:34:56Z")));

        assertEquals("2026-09-10T12:34:56Z", SensorReadingMapper.fromDocument(doc).timestamp());
    }

    @Test
    void preservesAnIntegerValueWithoutCoercion() {
        Document doc = baseDoc().append("value", 1200).append("channel", "power_draw").append("unit", "W");

        Object value = SensorReadingMapper.fromDocument(doc).value();

        assertInstanceOf(Integer.class, value);
        assertEquals(1200, value);
    }

    @Test
    void preservesABooleanValueWithoutCoercion() {
        Document doc = baseDoc().append("value", true).append("channel", "door_contact").append("unit", "state");

        Object value = SensorReadingMapper.fromDocument(doc).value();

        assertInstanceOf(Boolean.class, value);
        assertEquals(true, value);
    }

    @Test
    void leavesTimestampNullWhenAbsent() {
        Document doc = baseDoc();

        assertNull(SensorReadingMapper.fromDocument(doc).timestamp());
    }

    @Test
    void leavesKeyFieldsNullWhenAbsentRatherThanInventingThem() {
        SensorReading reading = SensorReadingMapper.fromDocument(new Document());

        assertNull(reading.deviceId());
        assertNull(reading.channel());
        assertNull(reading.unit());
        assertNull(reading.value());
    }

    private static Document baseDoc() {
        return new Document()
                .append("deviceId", "rack-a1")
                .append("channel", "intake_temp")
                .append("value", 22.4)
                .append("unit", "°C");
    }
}
